const std = @import("std");

const math = @import("math");
const world = @import("world");

const Entity = @import("Entity.zig");
const raycast = @import("raycast.zig");

const Fireball = @This();

base: Entity,
yaw: f32 = 0,
pitch: f32 = 0,
prev_yaw: f32 = 0,
prev_pitch: f32 = 0,
acceleration: math.Vec3 = math.Vec3.init(0, 0, 0),
shooter: Entity.Id = Entity.no_id,
ticks_in_air: i32 = 0,
dead: bool = false,

pub const size: f64 = 1.0;
pub const hit_border: f64 = 0.3;
pub const owner_grace_ticks: i32 = 25;
pub const explosion_size: f32 = 1.0;
pub const explosion_is_flaming: bool = true;
pub const bubbles_per_trail: usize = 4;

const launch_speed: f64 = 0.1;
const launch_spread: f64 = 0.4;
const drag: f64 = 0.95;
const water_drag: f64 = 0.8;
const rotation_smoothing: f32 = 0.2;
const trail_back: f64 = 0.25;
const smoke_lift: f64 = 0.5;
const void_floor: f64 = -64.0;
const float_pi: f64 = @as(f32, std.math.pi);

pub const BubbleTrail = struct {
    position: math.Vec3,
    drift: math.Vec3,
};

pub fn shotBy(
    from: math.Vec3,
    shooter: Entity.Id,
    toward: math.Vec3,
    rand: *world.JavaRandom,
) Fireball {
    const x = toward.x + rand.nextGaussian() * launch_spread;
    const y = toward.y + rand.nextGaussian() * launch_spread;
    const z = toward.z + rand.nextGaussian() * launch_spread;
    const length: f64 = @as(f32, @floatCast(@sqrt(x * x + y * y + z * z)));

    return .{
        .base = Entity.init(from, size, size),
        .shooter = shooter,
        .acceleration = math.Vec3.init(
            x / length * launch_speed,
            y / length * launch_speed,
            z / length * launch_speed,
        ),
    };
}

pub fn settle(self: *Fireball, world_map: *const world.World) void {
    self.base.beginTick();
    self.prev_yaw = self.yaw;
    self.prev_pitch = self.pitch;
    self.base.updateWaterState(world_map);
    if (self.base.position.y < void_floor) self.dead = true;
    self.ticks_in_air += 1;
}

pub fn blockImpact(self: Fireball, world_map: *const world.World) ?raycast.Hit {
    const motion = [3]f64{ self.base.motion.x, self.base.motion.y, self.base.motion.z };
    const reach = @sqrt(motion[0] * motion[0] + motion[1] * motion[1] + motion[2] * motion[2]);
    if (reach == 0.0) return null;

    const along = [3]f64{ motion[0] / reach, motion[1] / reach, motion[2] / reach };
    return raycast.castBlocks(world_map, self.base.position, along, reach);
}

pub fn smokeTrailPosition(self: Fireball) math.Vec3 {
    return math.Vec3.init(self.base.position.x, self.base.position.y + smoke_lift, self.base.position.z);
}

pub fn fly(self: *Fireball) ?BubbleTrail {
    self.base.position.x += self.base.motion.x;
    self.base.position.y += self.base.motion.y;
    self.base.position.z += self.base.motion.z;

    const flat: f64 = @as(f32, @floatCast(@sqrt(
        self.base.motion.x * self.base.motion.x + self.base.motion.z * self.base.motion.z,
    )));
    self.yaw = @floatCast(std.math.atan2(self.base.motion.x, self.base.motion.z) * 180.0 / float_pi);
    self.pitch = @floatCast(std.math.atan2(self.base.motion.y, flat) * 180.0 / float_pi);

    while (self.pitch - self.prev_pitch < -180.0) self.prev_pitch -= 360.0;
    while (self.pitch - self.prev_pitch >= 180.0) self.prev_pitch += 360.0;
    while (self.yaw - self.prev_yaw < -180.0) self.prev_yaw -= 360.0;
    while (self.yaw - self.prev_yaw >= 180.0) self.prev_yaw += 360.0;
    self.pitch = self.prev_pitch + (self.pitch - self.prev_pitch) * rotation_smoothing;
    self.yaw = self.prev_yaw + (self.yaw - self.prev_yaw) * rotation_smoothing;

    const trail: ?BubbleTrail = if (self.base.in_water) .{
        .position = math.Vec3.init(
            self.base.position.x - self.base.motion.x * trail_back,
            self.base.position.y - self.base.motion.y * trail_back,
            self.base.position.z - self.base.motion.z * trail_back,
        ),
        .drift = self.base.motion,
    } else null;

    const factor: f64 = if (self.base.in_water) water_drag else drag;
    self.base.motion.x = (self.base.motion.x + self.acceleration.x) * factor;
    self.base.motion.y = (self.base.motion.y + self.acceleration.y) * factor;
    self.base.motion.z = (self.base.motion.z + self.acceleration.z) * factor;

    return trail;
}

pub fn renderYaw(self: Fireball, partial_ticks: f32) f32 {
    return self.prev_yaw + (self.yaw - self.prev_yaw) * partial_ticks;
}

pub fn renderPitch(self: Fireball, partial_ticks: f32) f32 {
    return self.prev_pitch + (self.pitch - self.prev_pitch) * partial_ticks;
}

test "a fireball leaves with a tenth of a block of acceleration, roughly toward the target" {
    var rand = world.JavaRandom.init(5);
    const ball = shotBy(math.Vec3.init(8, 40, 8), 1, math.Vec3.init(0, 0, 20), &rand);

    const speed = @sqrt(
        ball.acceleration.x * ball.acceleration.x +
            ball.acceleration.y * ball.acceleration.y +
            ball.acceleration.z * ball.acceleration.z,
    );
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), speed, 1.0e-6);
    try std.testing.expect(ball.acceleration.z > 0.09);

    try std.testing.expectEqual(@as(f64, 0), ball.base.motion.x);
    try std.testing.expectEqual(@as(f64, 0), ball.base.motion.z);
}

test "the aim scatters around the line to the target" {
    var rand = world.JavaRandom.init(11);

    var spread_seen = false;
    for (0..50) |_| {
        const ball = shotBy(math.Vec3.init(8, 40, 8), 1, math.Vec3.init(0, 0, 20), &rand);
        if (ball.acceleration.x != 0.0) spread_seen = true;
        try std.testing.expect(ball.acceleration.z > 0.0);
    }
    try std.testing.expect(spread_seen);
}

test "a fireball speeds up along its aim and never falls" {
    const gpa = std.testing.allocator;
    var w = world.World.init(gpa);
    defer w.deinit();
    _ = try w.createChunk(0, 0);

    var rand = world.JavaRandom.init(3);
    var ball = shotBy(math.Vec3.init(8, 40, 8), 1, math.Vec3.init(0, 0, 20), &rand);

    var last_speed: f64 = 0;
    for (0..20) |_| {
        ball.settle(&w);
        try std.testing.expect(ball.fly() == null);

        const speed = @abs(ball.base.motion.z);
        try std.testing.expect(speed > last_speed);
        last_speed = speed;

        // Nothing pulls it down: the only vertical motion is the aim it was given.
        try std.testing.expect(ball.base.motion.y * ball.acceleration.y >= 0.0);
    }

    try std.testing.expect(ball.base.position.z > 8.0);
    try std.testing.expectEqual(@as(i32, 20), ball.ticks_in_air);
}

test "a fireball aimed at a wall reports where it would strike it" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();
    w.getChunk(0, 0).?.setBlock(12, 5, 8, .stone);

    var ball: Fireball = .{ .base = Entity.init(math.Vec3.init(8.5, 5.5, 8.5), size, size) };
    ball.base.motion = math.Vec3.init(4.0, 0, 0);

    ball.settle(&w);
    const hit = ball.blockImpact(&w).?;
    try std.testing.expectEqual(@as(i32, 12), hit.x);

    ball.base.motion = math.Vec3.init(-4.0, 0, 0);
    try std.testing.expect(ball.blockImpact(&w) == null);
}

test "a fireball trails bubbles once it is under water" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    const chunk = w.getChunk(0, 0).?;
    for (0..world.Chunk.width) |x| {
        for (0..world.Chunk.width) |z| {
            var y: u32 = 1;
            while (y < 8) : (y += 1) chunk.setBlock(@intCast(x), y, @intCast(z), .stationary_water);
        }
    }

    var ball: Fireball = .{ .base = Entity.init(math.Vec3.init(8.5, 4, 8.5), size, size) };
    ball.base.motion = math.Vec3.init(0, 0, 0.5);

    ball.settle(&w);
    try std.testing.expect(ball.base.in_water);
    try std.testing.expect(ball.fly() != null);
}
