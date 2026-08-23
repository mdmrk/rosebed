const std = @import("std");

const math = @import("math");
const world = @import("world");

const Entity = @import("Entity.zig");
const physics = @import("physics.zig");

const Boat = @This();

base: Entity,
yaw: f32 = 0,
pitch: f32 = 0,
prev_yaw: f32 = 0,
prev_pitch: f32 = 0,
damage: i32 = 0,
time_since_hit: i32 = 0,
rock_direction: i32 = 1,
rider: Entity.Id = Entity.no_id,
dead: bool = false,

pub const width: f64 = 1.5;
pub const height: f64 = 0.6;
pub const y_offset: f64 = height / 2.0;
pub const mounted_offset: f64 = -0.3;
pub const rider_reach: f64 = 0.4;

pub const buoyancy_slices: usize = 5;
pub const damage_per_hit: i32 = 10;
pub const break_damage: i32 = 40;
pub const hit_ticks: i32 = 10;
pub const plank_drops: usize = 3;
pub const stick_drops: usize = 2;
pub const wake_speed: f64 = 0.15;
pub const max_yaw_step: f64 = 20.0;

const sink_pull: f64 = 0.04;
const float_lift: f64 = 0.007;
const rider_push: f64 = 0.2;
const speed_cap: f64 = 0.4;
const ground_drag: f64 = 0.5;
const horizontal_drag: f64 = 0.99;
const vertical_drag: f64 = 0.95;
const turn_threshold: f64 = 0.001;
const splash_drop: f64 = 0.125;
const corner_reach: f64 = 0.8;

pub fn spawn(x: f64, y: f64, z: f64) Boat {
    return .{ .base = Entity.init(math.Vec3.init(x, y, z), width, height) };
}

pub fn submergedFraction(self: Boat, world_map: *const world.World) f64 {
    const box = self.base.boundingBox();
    const span = box.max_y - box.min_y;
    var submerged: f64 = 0;

    for (0..buoyancy_slices) |slice| {
        const from: f64 = @floatFromInt(slice);
        const to: f64 = @floatFromInt(slice + 1);
        const slices: f64 = @floatFromInt(buoyancy_slices);
        const low = box.min_y + span * from / slices - splash_drop;
        const high = box.min_y + span * to / slices - splash_drop;
        const layer = math.Aabb.init(box.min_x, low, box.min_z, box.max_x, high, box.max_z);
        if (physics.isBoxInMaterial(world_map, layer, .water)) submerged += 1.0 / slices;
    }

    return submerged;
}

pub const Wake = struct {
    position: math.Vec3,
    motion: math.Vec3,
};

pub const Step = struct {
    speed: f64 = 0,
    broke_up: bool = false,
};

pub fn tick(self: *Boat, world_map: *const world.World, rider_motion: ?math.Vec3) Step {
    self.base.beginTick();
    self.prev_yaw = self.yaw;
    self.prev_pitch = self.pitch;

    if (self.time_since_hit > 0) self.time_since_hit -= 1;
    if (self.damage > 0) self.damage -= 1;

    const submerged = self.submergedFraction(world_map);
    if (submerged < 1.0) {
        self.base.motion.y += sink_pull * (submerged * 2.0 - 1.0);
    } else {
        if (self.base.motion.y < 0.0) self.base.motion.y /= 2.0;
        self.base.motion.y += float_lift;
    }

    if (rider_motion) |push| {
        self.base.motion.x += push.x * rider_push;
        self.base.motion.z += push.z * rider_push;
    }

    self.base.motion.x = std.math.clamp(self.base.motion.x, -speed_cap, speed_cap);
    self.base.motion.z = std.math.clamp(self.base.motion.z, -speed_cap, speed_cap);

    if (self.base.on_ground) {
        self.base.motion.x *= ground_drag;
        self.base.motion.y *= ground_drag;
        self.base.motion.z *= ground_drag;
    }

    _ = self.base.move(world_map);

    const speed = @sqrt(self.base.motion.x * self.base.motion.x + self.base.motion.z * self.base.motion.z);

    var step: Step = .{ .speed = speed };
    if (self.base.blocked_horizontally and speed > wake_speed) {
        step.broke_up = true;
        self.dead = true;
    } else {
        self.base.motion.x *= horizontal_drag;
        self.base.motion.y *= vertical_drag;
        self.base.motion.z *= horizontal_drag;
    }

    self.pitch = 0;
    self.settleYaw();
    return step;
}

fn settleYaw(self: *Boat) void {
    var target: f64 = self.yaw;
    const back_x = self.base.prev_position.x - self.base.position.x;
    const back_z = self.base.prev_position.z - self.base.position.z;
    if (back_x * back_x + back_z * back_z > turn_threshold) {
        target = @as(f32, @floatCast(std.math.atan2(back_z, back_x) * 180.0 / std.math.pi));
    }

    var delta = target - @as(f64, self.yaw);
    while (delta >= 180.0) delta -= 360.0;
    while (delta < -180.0) delta += 360.0;
    self.yaw += @floatCast(std.math.clamp(delta, -max_yaw_step, max_yaw_step));
}

pub const collision_reach: f64 = 0.2;
const shove: f64 = 0.05;

pub fn collideWith(self: *Boat, other: *Boat) void {
    var dx = other.base.position.x - self.base.position.x;
    var dz = other.base.position.z - self.base.position.z;

    // Entity.applyEntityCollision takes the larger of the two gaps and square-roots that,
    // not the distance between the boats. Kept as vanilla has it.
    const widest = @max(@abs(dx), @abs(dz));
    if (widest < 0.01) return;

    const spread = @sqrt(widest);
    dx /= spread;
    dz /= spread;
    const scale = @min(1.0 / spread, 1.0);
    dx *= scale * shove;
    dz *= scale * shove;

    self.base.motion.x -= dx;
    self.base.motion.z -= dz;
    other.base.motion.x += dx;
    other.base.motion.z += dz;
}

pub fn hurt(self: *Boat, amount: i32) bool {
    if (self.dead) return true;
    self.rock_direction = -self.rock_direction;
    self.time_since_hit = hit_ticks;
    self.damage += amount * damage_per_hit;
    if (self.damage > break_damage) self.dead = true;
    return true;
}

pub fn riderPosition(self: Boat) math.Vec3 {
    const radians = @as(f64, self.yaw) * std.math.pi / 180.0;
    return math.Vec3.init(
        self.base.position.x + @cos(radians) * rider_reach,
        self.base.position.y,
        self.base.position.z + @sin(radians) * rider_reach,
    );
}

pub fn wakeAt(self: Boat, rand: *world.JavaRandom) Wake {
    const radians = @as(f64, self.yaw) * std.math.pi / 180.0;
    const along = @cos(radians);
    const across = @sin(radians);
    const drift: f64 = @floatCast(rand.nextFloat() * 2.0 - 1.0);
    const side: f64 = @as(f64, @floatFromInt(rand.nextIntBound(2) * 2 - 1)) * 0.7;

    const surface = self.base.position.y + y_offset - splash_drop;
    const position = if (rand.nextBoolean()) math.Vec3.init(
        self.base.position.x - along * drift * 0.8 + across * side,
        surface,
        self.base.position.z - across * drift * 0.8 - along * side,
    ) else math.Vec3.init(
        self.base.position.x + along + across * drift * 0.7,
        surface,
        self.base.position.z + across - along * drift * 0.7,
    );

    return .{ .position = position, .motion = self.base.motion };
}

pub fn wakeCount(speed: f64) usize {
    if (speed <= wake_speed) return 0;
    return @intFromFloat(@floor(1.0 + speed * 60.0));
}

pub fn crushedSnow(self: Boat, corner: usize) [3]i32 {
    const across: f64 = @floatFromInt(corner % 2);
    const along: f64 = @floatFromInt(corner / 2);
    return .{
        math.util.floorDouble(self.base.position.x + (across - 0.5) * corner_reach),
        math.util.floorDouble(self.base.position.y + y_offset),
        math.util.floorDouble(self.base.position.z + (along - 0.5) * corner_reach),
    };
}

pub fn toRecord(self: Boat) world.entity_nbt.Boat {
    return .{ .base = .{
        .position = .{ self.base.position.x, self.base.position.y, self.base.position.z },
        .motion = .{ self.base.motion.x, self.base.motion.y, self.base.motion.z },
        .yaw = self.yaw,
        .pitch = self.pitch,
        .on_ground = self.base.on_ground,
    } };
}

pub fn fromRecord(record: world.entity_nbt.Boat) Boat {
    var self = Boat.spawn(record.base.position[0], record.base.position[1], record.base.position[2]);
    self.base.motion = math.Vec3.init(record.base.motion[0], record.base.motion[1], record.base.motion[2]);
    self.base.on_ground = record.base.on_ground;
    self.yaw = record.base.yaw;
    self.pitch = record.base.pitch;
    self.prev_yaw = record.base.yaw;
    self.prev_pitch = record.base.pitch;
    return self;
}

test "a boat is the size EntityBoat sets itself to" {
    const boat = Boat.spawn(8.5, 64, 8.5);
    try std.testing.expectEqual(@as(f64, 1.5), boat.base.width);
    try std.testing.expectEqual(@as(f64, 0.6), boat.base.height);
    try std.testing.expectEqual(@as(i32, 1), boat.rock_direction);
}

test "a boat out of water sinks and one in water is held up" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 4);
    defer w.deinit();

    var dry = Boat.spawn(8.5, 20, 8.5);
    _ = dry.tick(&w, null);
    try std.testing.expect(dry.base.motion.y < 0);

    for (0..world.constants.chunk_width) |x| {
        for (0..world.constants.chunk_width) |z| {
            w.getChunk(0, 0).?.setBlock(@intCast(x), 4, @intCast(z), .stationary_water);
        }
    }

    var sunk = Boat.spawn(8.5, 4.0, 8.5);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), sunk.submergedFraction(&w), 1.0e-9);
    _ = sunk.tick(&w, null);
    try std.testing.expect(sunk.base.motion.y > 0);

    var floating = Boat.spawn(8.5, 4.2, 8.5);
    for (0..80) |_| _ = floating.tick(&w, null);
    try std.testing.expect(floating.base.position.y > 4.0);
    try std.testing.expect(floating.base.position.y < 6.0);
    try std.testing.expect(floating.submergedFraction(&w) > 0);
}

test "a rider's push drives the boat but never past the speed cap" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 4);
    defer w.deinit();

    var boat = Boat.spawn(8.5, 20, 8.5);
    for (0..80) |_| _ = boat.tick(&w, math.Vec3.init(10.0, 0, 10.0));

    try std.testing.expect(boat.base.motion.x <= 0.4);
    try std.testing.expect(boat.base.motion.z <= 0.4);
    try std.testing.expect(boat.base.motion.x > 0.3);
}

test "two overlapping boats shove each other apart" {
    var left = Boat.spawn(8.0, 64, 8.5);
    var right = Boat.spawn(8.9, 64, 8.5);

    right.collideWith(&left);

    try std.testing.expect(right.base.motion.x > 0);
    try std.testing.expect(left.base.motion.x < 0);
    try std.testing.expectApproxEqAbs(right.base.motion.x, -left.base.motion.x, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0), right.base.motion.z, 1.0e-12);
}

test "boats sitting on the same spot are left alone" {
    var a = Boat.spawn(8.5, 64, 8.5);
    var b = Boat.spawn(8.505, 64, 8.5);

    b.collideWith(&a);
    try std.testing.expectEqual(@as(f64, 0), b.base.motion.x);
    try std.testing.expectEqual(@as(f64, 0), a.base.motion.x);
}

test "a boat breaks up after enough damage and shrugs off a little" {
    var light = Boat.spawn(0, 0, 0);
    _ = light.hurt(1);
    try std.testing.expectEqual(@as(i32, 10), light.damage);
    try std.testing.expectEqual(@as(i32, -1), light.rock_direction);
    try std.testing.expectEqual(@as(i32, 10), light.time_since_hit);
    try std.testing.expect(!light.dead);

    var doomed = Boat.spawn(0, 0, 0);
    _ = doomed.hurt(5);
    try std.testing.expect(doomed.dead);
}

test "the rider sits ahead of the boat's centre along its heading" {
    var boat = Boat.spawn(8.5, 64, 8.5);
    boat.yaw = 0;
    const east = boat.riderPosition();
    try std.testing.expectApproxEqAbs(@as(f64, 8.9), east.x, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 64), east.y, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 8.5), east.z, 1.0e-9);

    boat.yaw = 90;
    const south = boat.riderPosition();
    try std.testing.expectApproxEqAbs(@as(f64, 8.5), south.x, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 8.9), south.z, 1.0e-9);
}

test "a boat turns toward where it came from, no more than twenty degrees a tick" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 4);
    defer w.deinit();

    var boat = Boat.spawn(8.5, 20, 8.5);
    boat.yaw = 0;
    boat.base.motion = math.Vec3.init(0, 0, 0.3);
    _ = boat.tick(&w, null);

    try std.testing.expect(@abs(boat.yaw - boat.prev_yaw) <= 20.0);
    try std.testing.expect(boat.yaw < 0);
}

test "a boat only throws a wake once it is moving" {
    try std.testing.expectEqual(@as(usize, 0), wakeCount(0.0));
    try std.testing.expectEqual(@as(usize, 0), wakeCount(wake_speed));
    try std.testing.expect(wakeCount(0.3) > 1);
}

test "the four corners a boat crushes snow under straddle its position" {
    var boat = Boat.spawn(9.0, 64, 9.0);

    var seen_x: [4]i32 = undefined;
    var seen_z: [4]i32 = undefined;
    for (0..4) |corner| {
        const cell = boat.crushedSnow(corner);
        seen_x[corner] = cell[0];
        seen_z[corner] = cell[1 + 1];
        try std.testing.expectEqual(@as(i32, 64), cell[1]);
    }

    try std.testing.expectEqual([4]i32{ 8, 9, 8, 9 }, seen_x);
    try std.testing.expectEqual([4]i32{ 8, 8, 9, 9 }, seen_z);
}

test "a boat's position, motion and heading survive a record round trip" {
    var boat = Boat.spawn(-12.25, 63.5, 7.75);
    boat.base.motion = math.Vec3.init(0.1, -0.2, 0.3);
    boat.yaw = 42.5;

    const restored = Boat.fromRecord(boat.toRecord());
    try std.testing.expectEqual(boat.base.position, restored.base.position);
    try std.testing.expectEqual(boat.base.motion, restored.base.motion);
    try std.testing.expectEqual(boat.yaw, restored.yaw);
}
