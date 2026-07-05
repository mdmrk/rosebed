const std = @import("std");
const math = @import("math");
const world = @import("world");
const Entity = @import("entity.zig");

const Pig = @This();

base: Entity,
yaw: f32 = 0,
walk_distance: f32 = 0,
wander_ticks_left: u16 = 0,
is_moving: bool = false,

pub const width: f64 = 0.9;
pub const height: f64 = 0.9;

const gravity: f64 = 0.08;
const vertical_drag: f64 = 0.98;
const air_friction: f64 = 0.91;
const ground_friction: f64 = 0.6 * 0.91;
const walk_speed: f64 = 0.1;

pub fn spawn(position: math.Vec3) Pig {
    return .{ .base = Entity.init(position, width, height) };
}

fn rerollWander(self: *Pig, rand: *world.JavaRandom) void {
    self.is_moving = rand.nextIntBound(4) != 0;
    if (self.is_moving) self.yaw = @floatFromInt(rand.nextIntBound(360));
    self.wander_ticks_left = @intCast(20 + rand.nextIntBound(40));
}

pub fn tick(self: *Pig, world_map: *const world.World, rand: *world.JavaRandom) void {
    self.base.beginTick();

    if (self.wander_ticks_left == 0) {
        self.rerollWander(rand);
    } else {
        self.wander_ticks_left -= 1;
    }

    if (self.is_moving) {
        const yaw_rad = self.yaw * std.math.pi / 180.0;
        self.base.motion.x += @as(f64, -@sin(yaw_rad)) * walk_speed;
        self.base.motion.z += @as(f64, @cos(yaw_rad)) * walk_speed;
    }

    const moved = self.base.move(world_map);

    self.base.motion.y -= gravity;
    self.base.motion.y *= vertical_drag;
    const friction: f64 = if (self.base.on_ground) ground_friction else air_friction;
    self.base.motion.x *= friction;
    self.base.motion.z *= friction;

    if (moved.blocked_x or moved.blocked_z) self.wander_ticks_left = 0;

    if (self.is_moving and self.base.on_ground) {
        self.walk_distance += @floatCast(@sqrt(moved.dx * moved.dx + moved.dz * moved.dz));
    }
}

test "gravity pulls a spawned pig down" {
    var w = try world.testing.flatWorld(std.testing.allocator, 1);
    defer w.deinit();
    var rand = world.JavaRandom.init(0);
    var pig = Pig.spawn(math.Vec3.init(8, 5, 8));
    pig.tick(&w, &rand);
    try std.testing.expect(pig.base.position.y <= 5.0);
}

test "a freshly spawned pig picks a wander state within one tick" {
    var w = try world.testing.flatWorld(std.testing.allocator, 1);
    defer w.deinit();
    var rand = world.JavaRandom.init(0);
    var pig = Pig.spawn(math.Vec3.init(8, 1, 8));
    try std.testing.expectEqual(@as(u16, 0), pig.wander_ticks_left);
    pig.tick(&w, &rand);
    try std.testing.expect(pig.wander_ticks_left > 0);
}

test "walk distance only accumulates while moving on the ground" {
    var w = try world.testing.flatWorld(std.testing.allocator, 1);
    defer w.deinit();
    var rand = world.JavaRandom.init(0);
    var pig = Pig.spawn(math.Vec3.init(8, 1, 8));
    pig.is_moving = false;
    pig.wander_ticks_left = 100;
    pig.base.on_ground = true;
    pig.tick(&w, &rand);
    try std.testing.expectEqual(@as(f32, 0), pig.walk_distance);
}

test "hitting a wall cuts the current wander leg short" {
    var w = try world.testing.flatWorld(std.testing.allocator, 0);
    defer w.deinit();
    const chunk = w.getChunk(0, 0).?;
    for (0..world.constants.chunk_width) |x| {
        chunk.setBlock(@intCast(x), 0, 0, world.Block.stone);
    }
    chunk.setBlock(9, 1, 0, world.Block.stone);

    var rand = world.JavaRandom.init(0);
    var pig = Pig.spawn(math.Vec3.init(8, 1, 0));
    pig.is_moving = true;
    pig.yaw = 270;
    pig.wander_ticks_left = 50;
    pig.base.on_ground = true;
    var saw_reset = false;
    for (0..20) |_| {
        pig.tick(&w, &rand);
        if (pig.wander_ticks_left == 0) saw_reset = true;
    }
    try std.testing.expect(saw_reset);
}
