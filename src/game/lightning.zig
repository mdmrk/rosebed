const std = @import("std");

const math = @import("math");
const world = @import("world");

const Entity = @import("entity.zig");

const Lightning = @This();

base: Entity,
seed: i64 = 0,
life: i32 = first_flash,
flashes_left: i32 = 0,
next_flash: i32 = 0,
dead: bool = false,

pub const size: f64 = 0.0;
pub const first_flash: i32 = 2;
pub const strike_reach: f64 = 3.0;
pub const strike_lift: f64 = 6.0;
pub const fire_damage: i32 = 5;
pub const burn_ticks: i32 = 300;
pub const scatter_fires: usize = 4;
pub const flash_span: i32 = 10;
pub const max_extra_flashes: i32 = 3;
pub const thunder_volume: f32 = 10000.0;
pub const crack_volume: f32 = 2.0;

pub fn strike(at: math.Vec3, rand: *world.JavaRandom) Lightning {
    return .{
        .base = Entity.init(at, size, size),
        .seed = rand.nextLong(),
        .flashes_left = rand.nextIntBound(max_extra_flashes) + 1,
    };
}

pub fn scorch(self: *const Lightning, world_map: *world.World, rand: *world.JavaRandom) !void {
    const x = math.util.floorDouble(self.base.position.x);
    const y = math.util.floorDouble(self.base.position.y);
    const z = math.util.floorDouble(self.base.position.z);
    try lightFire(world_map, x, y, z);

    for (0..scatter_fires) |_| {
        try lightFire(
            world_map,
            x + rand.nextIntBound(3) - 1,
            y + rand.nextIntBound(3) - 1,
            z + rand.nextIntBound(3) - 1,
        );
    }
}

fn lightFire(world_map: *world.World, x: i32, y: i32, z: i32) !void {
    if (y < 0 or y >= world.constants.chunk_height) return;
    if (world_map.getBlock(x, y, z) != .air) return;
    if (!world.block_update.canPlaceAt(world_map, x, y, z, .fire)) return;
    try world_map.setBlockWithNotify(x, y, z, .fire);
}

pub const Step = struct {
    struck: bool = false,
    reflash: bool = false,
};

pub fn tick(self: *Lightning, rand: *world.JavaRandom) Step {
    var step: Step = .{};

    if (self.life == first_flash) step.struck = true;

    self.life -= 1;
    if (self.life < 0) {
        if (self.flashes_left == 0) {
            self.dead = true;
        } else if (self.life < -self.next_flash) {
            self.flashes_left -= 1;
            self.life = 1;
            self.seed = rand.nextLong();
            self.next_flash = rand.nextIntBound(flash_span);
            step.reflash = true;
        }
    }
    return step;
}

pub fn isVisible(self: Lightning) bool {
    return self.life >= 0;
}

pub fn boundingBox(self: Lightning) math.AABB {
    return math.AABB.init(
        self.base.position.x - strike_reach,
        self.base.position.y - strike_reach,
        self.base.position.z - strike_reach,
        self.base.position.x + strike_reach,
        self.base.position.y + strike_lift + strike_reach,
        self.base.position.z + strike_reach,
    );
}

test "a bolt flashes once, then a few more times before it dies" {
    var rand = world.JavaRandom.init(4);
    var bolt = Lightning.strike(math.Vec3.init(8, 70, 8), &rand);

    try std.testing.expect(bolt.flashes_left >= 1 and bolt.flashes_left <= max_extra_flashes);

    const first = bolt.tick(&rand);
    try std.testing.expect(first.struck);
    try std.testing.expect(!bolt.dead);

    var reflashes: usize = 0;
    for (0..200) |_| {
        if (bolt.dead) break;
        if (bolt.tick(&rand).reflash) reflashes += 1;
    }
    try std.testing.expect(bolt.dead);
    try std.testing.expect(reflashes > 0);
}

test "a bolt is only drawn while its flash is alight" {
    var rand = world.JavaRandom.init(9);
    var bolt = Lightning.strike(math.Vec3.init(0, 64, 0), &rand);

    try std.testing.expect(bolt.isVisible());
    bolt.life = -1;
    try std.testing.expect(!bolt.isVisible());
}

test "a bolt sets the ground alight where it lands" {
    var w = try world.testing.flatWorld(std.testing.allocator, 4);
    defer w.deinit();

    var rand = world.JavaRandom.init(3);
    const bolt = Lightning.strike(math.Vec3.init(8, 4, 8), &rand);
    try bolt.scorch(&w, &rand);

    try std.testing.expectEqual(world.Block.fire, w.getBlock(8, 4, 8));
}

test "the strike box reaches out three blocks and six up" {
    var rand = world.JavaRandom.init(2);
    const bolt = Lightning.strike(math.Vec3.init(10, 64, -4), &rand);
    const box = bolt.boundingBox();

    try std.testing.expectApproxEqAbs(@as(f64, 7.0), box.min_x, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 13.0), box.max_x, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 61.0), box.min_y, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 73.0), box.max_y, 1.0e-9);
}
