const std = @import("std");

const math = @import("math");
const world = @import("world");
const testing_world = world.testing;

const Entity = @import("entity.zig");
const physics = @import("physics.zig");
const Player = @import("player.zig");

const FishHook = @This();

base: Entity,
yaw: f32 = 0,
pitch: f32 = 0,
prev_yaw: f32 = 0,
prev_pitch: f32 = 0,
angler: Entity.Id = Entity.no_id,
tile: [3]i32 = .{ -1, -1, -1 },
in_tile: world.Block = .air,
in_ground: bool = false,
shake: i32 = 0,
ticks_in_ground: i32 = 0,
ticks_in_air: i32 = 0,
ticks_catchable: i32 = 0,
dead: bool = false,

pub const size: f64 = 0.25;
pub const cast_speed: f32 = 0.4;
pub const cast_spread: f32 = 1.0;
pub const launch_scale: f32 = 1.5;
pub const owner_grace_ticks: i32 = 5;
pub const stuck_lifetime: i32 = 1200;
pub const reel_range_squared: f64 = 1024.0;
pub const buoyancy_slices: usize = 5;
pub const bite_chance: i32 = 500;
pub const bite_chance_rain: i32 = 300;

const hand_offset: f32 = 0.16;
const hand_drop: f64 = 0.1;
const eye_height: f64 = 1.62;
const drag: f64 = 0.92;
const ground_drag: f64 = 0.5;
const water_drag: f64 = 0.9;
const water_sink: f64 = 0.8;
const buoyancy: f64 = 0.04;
const bite_dip: f64 = 0.2;
const turn_smoothing: f32 = 0.2;
const reel_pull: f64 = 0.1;
const reel_lift: f64 = 0.08;

pub fn castBy(player: Player, rand: *world.JavaRandom) FishHook {
    const yaw_radians = player.yaw / 180.0 * std.math.pi;
    const pitch_radians = player.pitch / 180.0 * std.math.pi;

    const position = math.Vec3.init(
        player.base.position.x - @as(f64, math.util.cos(yaw_radians) * hand_offset),
        player.base.position.y + eye_height - player.y_size - hand_drop,
        player.base.position.z - @as(f64, math.util.sin(yaw_radians) * hand_offset),
    );

    var hook: FishHook = .{
        .base = Entity.init(position, size, size),
        .angler = player.base.id,
        .yaw = player.yaw,
        .pitch = player.pitch,
        .prev_yaw = player.yaw,
        .prev_pitch = player.pitch,
    };

    const heading = math.Vec3.init(
        -math.util.sin(yaw_radians) * math.util.cos(pitch_radians) * cast_speed,
        -math.util.sin(pitch_radians) * cast_speed,
        math.util.cos(yaw_radians) * math.util.cos(pitch_radians) * cast_speed,
    );
    hook.setHeading(heading, launch_scale, cast_spread, rand);
    return hook;
}

fn setHeading(self: *FishHook, direction: math.Vec3, speed: f32, spread: f32, rand: *world.JavaRandom) void {
    const length = math.util.sqrtF(
        direction.x * direction.x + direction.y * direction.y + direction.z * direction.z,
    );

    var x = direction.x / length;
    var y = direction.y / length;
    var z = direction.z / length;

    x += rand.nextGaussian() * 0.0075 * spread;
    y += rand.nextGaussian() * 0.0075 * spread;
    z += rand.nextGaussian() * 0.0075 * spread;

    x *= speed;
    y *= speed;
    z *= speed;

    self.base.motion = math.Vec3.init(x, y, z);
    const flat = math.util.sqrtF(x * x + z * z);
    self.yaw = @floatCast(std.math.atan2(x, z) * 180.0 / std.math.pi);
    self.pitch = @floatCast(std.math.atan2(y, flat) * 180.0 / std.math.pi);
    self.prev_yaw = self.yaw;
    self.prev_pitch = self.pitch;
}

pub fn submergedFraction(self: FishHook, world_map: *const world.World) f64 {
    const box = self.base.boundingBox();
    const span = box.max_y - box.min_y;
    var submerged: f64 = 0;

    for (0..buoyancy_slices) |slice| {
        const from: f64 = @floatFromInt(slice);
        const to: f64 = @floatFromInt(slice + 1);
        const slices: f64 = @floatFromInt(buoyancy_slices);
        const low = box.min_y + span * from / slices;
        const high = box.min_y + span * to / slices;
        const layer = math.AABB.init(box.min_x, low, box.min_z, box.max_x, high, box.max_z);
        if (physics.isBoxInMaterial(world_map, layer, .water)) submerged += 1.0 / slices;
    }

    return submerged;
}

pub const Step = struct {
    bit: bool = false,
};

pub fn tick(self: *FishHook, world_map: *const world.World, rand: *world.JavaRandom) Step {
    self.base.beginTick();
    self.prev_yaw = self.yaw;
    self.prev_pitch = self.pitch;

    var step: Step = .{};
    if (self.shake > 0) self.shake -= 1;

    if (self.in_ground) {
        if (world_map.getBlock(self.tile[0], self.tile[1], self.tile[2]) == self.in_tile) {
            self.ticks_in_ground += 1;
            if (self.ticks_in_ground == stuck_lifetime) self.dead = true;
            return step;
        }

        self.in_ground = false;
        self.base.motion.x *= @as(f64, rand.nextFloat()) * 0.2;
        self.base.motion.y *= @as(f64, rand.nextFloat()) * 0.2;
        self.base.motion.z *= @as(f64, rand.nextFloat()) * 0.2;
        self.ticks_in_ground = 0;
        self.ticks_in_air = 0;
    } else {
        self.ticks_in_air += 1;
    }

    const moved = self.base.move(world_map);
    if (moved.blocked_y and self.base.motion.y <= 0) self.settleInto(world_map);
    if (self.in_ground) return step;

    const flat = math.util.sqrtF(self.base.motion.x * self.base.motion.x + self.base.motion.z * self.base.motion.z);
    self.yaw = @floatCast(std.math.atan2(self.base.motion.x, self.base.motion.z) * 180.0 / std.math.pi);
    self.pitch = @floatCast(std.math.atan2(self.base.motion.y, flat) * 180.0 / std.math.pi);
    self.pitch = self.prev_pitch + (self.pitch - self.prev_pitch) * turn_smoothing;
    self.yaw = self.prev_yaw + (self.yaw - self.prev_yaw) * turn_smoothing;

    var slip: f64 = drag;
    if (self.base.on_ground or self.base.blocked_horizontally) slip = ground_drag;

    const submerged = self.submergedFraction(world_map);
    if (submerged > 0.0) {
        if (self.ticks_catchable > 0) {
            self.ticks_catchable -= 1;
        } else {
            if (rand.nextIntBound(bite_chance) == 0) {
                self.ticks_catchable = rand.nextIntBound(30) + 10;
                self.base.motion.y -= bite_dip;
                step.bit = true;
            }
        }
    }

    if (self.ticks_catchable > 0) {
        const tug = @as(f64, rand.nextFloat()) * @as(f64, rand.nextFloat()) * @as(f64, rand.nextFloat());
        self.base.motion.y -= tug * bite_dip;
    }

    self.base.motion.y += buoyancy * (submerged * 2.0 - 1.0);
    if (submerged > 0.0) {
        slip *= water_drag;
        self.base.motion.y *= water_sink;
    }

    self.base.motion.x *= slip;
    self.base.motion.y *= slip;
    self.base.motion.z *= slip;
    return step;
}

fn settleInto(self: *FishHook, world_map: *const world.World) void {
    const x = math.util.floorDouble(self.base.position.x);
    const y = math.util.floorDouble(self.base.position.y);
    const z = math.util.floorDouble(self.base.position.z);
    const under = world_map.getBlock(x, y - 1, z);
    if (under == .air or under.isLiquid()) return;

    self.tile = .{ x, y - 1, z };
    self.in_tile = under;
    self.in_ground = true;
    self.base.motion = math.Vec3.init(0, 0, 0);
}

pub const Catch = enum(u8) { nothing = 0, fish = 1, stuck = 2 };

pub fn reelIn(self: *FishHook) Catch {
    self.dead = true;
    if (self.ticks_catchable > 0) return .fish;
    if (self.in_ground) return .stuck;
    return .nothing;
}

pub fn pullToward(self: FishHook, angler: math.Vec3) math.Vec3 {
    const dx = angler.x - self.base.position.x;
    const dy = angler.y - self.base.position.y;
    const dz = angler.z - self.base.position.z;
    const distance = math.util.sqrtF(dx * dx + dy * dy + dz * dz);
    return math.Vec3.init(
        dx * reel_pull,
        dy * reel_pull + math.util.sqrtF(distance) * reel_lift,
        dz * reel_pull,
    );
}

pub fn outOfRange(self: FishHook, angler: math.Vec3) bool {
    const dx = angler.x - self.base.position.x;
    const dy = angler.y - self.base.position.y;
    const dz = angler.z - self.base.position.z;
    return dx * dx + dy * dy + dz * dz > reel_range_squared;
}

test "a cast bobber leaves the rod with the speed EntityFish gives it" {
    var rand = world.JavaRandom.init(7);
    var player = Player.spawn(math.Vec3.init(8.5, 12, 8.5));
    player.yaw = 0;
    player.pitch = 0;

    const hook = FishHook.castBy(player, &rand);
    try std.testing.expectEqual(@as(f64, size), hook.base.width);
    try std.testing.expect(hook.base.motion.z > 0.5);
    try std.testing.expect(@abs(hook.base.motion.x) < 0.1);
    try std.testing.expectEqual(player.base.id, hook.angler);
}

test "a bobber floats where it lands in water" {
    const gpa = std.testing.allocator;
    var w = try testing_world.flatWorld(gpa, 4);
    defer w.deinit();
    for (0..world.constants.chunk_width) |x| {
        for (0..world.constants.chunk_width) |z| {
            w.getChunk(0, 0).?.setBlock(@intCast(x), 4, @intCast(z), .stationary_water);
        }
    }

    var rand = world.JavaRandom.init(1);
    var hook: FishHook = .{ .base = Entity.init(math.Vec3.init(8.5, 8.0, 8.5), size, size) };

    for (0..200) |_| _ = hook.tick(&w, &rand);

    try std.testing.expect(hook.base.position.y > 4.0);
    try std.testing.expect(hook.base.position.y < 6.0);
    try std.testing.expect(!hook.in_ground);
}

test "a bobber that hits the ground sticks and eventually gives up" {
    const gpa = std.testing.allocator;
    var w = try testing_world.flatWorld(gpa, 12);
    defer w.deinit();

    var rand = world.JavaRandom.init(1);
    var hook: FishHook = .{ .base = Entity.init(math.Vec3.init(8.5, 14.0, 8.5), size, size) };

    for (0..40) |_| _ = hook.tick(&w, &rand);
    try std.testing.expect(hook.in_ground);
    try std.testing.expectEqual(world.Block.stone, hook.in_tile);

    hook.ticks_in_ground = stuck_lifetime - 1;
    _ = hook.tick(&w, &rand);
    try std.testing.expect(hook.dead);
}

test "reeling in reports what was on the line" {
    var empty: FishHook = .{ .base = Entity.init(math.Vec3.init(0, 0, 0), size, size) };
    try std.testing.expectEqual(Catch.nothing, empty.reelIn());
    try std.testing.expect(empty.dead);

    var biting: FishHook = .{ .base = Entity.init(math.Vec3.init(0, 0, 0), size, size) };
    biting.ticks_catchable = 5;
    try std.testing.expectEqual(Catch.fish, biting.reelIn());

    var snagged: FishHook = .{ .base = Entity.init(math.Vec3.init(0, 0, 0), size, size) };
    snagged.in_ground = true;
    try std.testing.expectEqual(Catch.stuck, snagged.reelIn());
}

test "a caught fish is thrown back toward the angler" {
    var hook: FishHook = .{ .base = Entity.init(math.Vec3.init(8.5, 12.0, 12.5), size, size) };
    const toss = hook.pullToward(math.Vec3.init(8.5, 13.0, 8.5));

    try std.testing.expectApproxEqAbs(@as(f64, 0), toss.x, 1.0e-12);
    try std.testing.expect(toss.z < 0);
    try std.testing.expect(toss.y > 0);
}

test "a bobber cast too far away is out of range" {
    var hook: FishHook = .{ .base = Entity.init(math.Vec3.init(0, 0, 0), size, size) };
    try std.testing.expect(!hook.outOfRange(math.Vec3.init(10, 0, 10)));
    try std.testing.expect(hook.outOfRange(math.Vec3.init(40, 0, 0)));
}
