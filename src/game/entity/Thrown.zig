const std = @import("std");

const math = @import("math");
const world = @import("world");

const Entity = @import("../Entity.zig");
const Player = @import("../Player.zig");
const raycast = @import("../raycast.zig");
const projectile = @import("projectile.zig");

const Thrown = @This();

kind: Kind,
base: Entity,
yaw: f32 = 0,
pitch: f32 = 0,
prev_yaw: f32 = 0,
prev_pitch: f32 = 0,
owner: Entity.Id = Entity.no_id,
from_player: bool = false,
ticks_in_air: i32 = 0,
dead: bool = false,

pub const Kind = enum {
    egg,
    snowball,

    pub fn item(self: Kind) world.Item {
        return switch (self) {
            .egg => .egg,
            .snowball => .snowball,
        };
    }
};

pub const size: f64 = 0.25;
pub const hit_border: f64 = 0.3;
pub const owner_grace_ticks: i32 = 5;
pub const bubbles_per_trail: usize = 4;
pub const poof_particles: usize = 8;
pub const hatch_chance: i32 = 8;
pub const brood_chance: i32 = 32;
pub const brood_size: usize = 4;

const eye_offset: f32 = 0.12;
const hand_offset: f32 = 0.16;
const hand_drop: f32 = 0.1;
const launch_speed: f32 = 1.5;
const launch_spread: f32 = 1.0;

pub fn thrownBy(kind: Kind, player: Player, rand: *world.JavaRandom) Thrown {
    const eye = player.eyePosition();
    const yaw_radians = player.yaw / 180.0 * std.math.pi;
    const pitch_radians = player.pitch / 180.0 * std.math.pi;

    const position = math.Vec3.init(
        eye.x - @as(f64, math.util.cos(yaw_radians) * hand_offset),
        eye.y + @as(f64, eye_offset) - @as(f64, hand_drop),
        eye.z - @as(f64, math.util.sin(yaw_radians) * hand_offset),
    );

    var thrown: Thrown = .{
        .kind = kind,
        .base = Entity.init(position, size, size),
        .owner = player.base.id,
        .from_player = true,
    };

    const heading = math.Vec3.init(
        -math.util.sin(yaw_radians) * math.util.cos(pitch_radians),
        -math.util.sin(pitch_radians),
        math.util.cos(yaw_radians) * math.util.cos(pitch_radians),
    );
    thrown.setHeading(heading, launch_speed, launch_spread, rand);
    return thrown;
}

pub fn dispensedFrom(
    kind: Kind,
    from: math.Vec3,
    toward: math.Vec3,
    speed: f32,
    spread: f32,
    rand: *world.JavaRandom,
) Thrown {
    var thrown: Thrown = .{ .kind = kind, .base = Entity.init(from, size, size) };
    thrown.setHeading(toward, speed, spread, rand);
    return thrown;
}

fn setHeading(self: *Thrown, direction: math.Vec3, speed: f32, spread: f32, rand: *world.JavaRandom) void {
    projectile.setHeading(self, direction, speed, spread, rand);
}

pub fn settle(self: *Thrown, world_map: *const world.World) void {
    self.base.beginTick();
    self.prev_yaw = self.yaw;
    self.prev_pitch = self.pitch;
    self.base.updateWaterState(world_map);
    if (self.base.position.y < projectile.void_floor) self.dead = true;
    self.ticks_in_air += 1;
}

pub fn blockImpact(self: Thrown, world_map: *const world.World) ?raycast.Hit {
    return raycast.castCollision(world_map, self.base.position, self.base.motion, 1.0);
}

pub fn hatched(rand: *world.JavaRandom) usize {
    if (rand.nextIntBound(hatch_chance) != 0) return 0;
    return if (rand.nextIntBound(brood_chance) == 0) brood_size else 1;
}

pub fn fly(self: *Thrown) ?projectile.BubbleTrail {
    return projectile.fly(self);
}

pub fn renderYaw(self: Thrown, partial_ticks: f32) f32 {
    return self.prev_yaw + (self.yaw - self.prev_yaw) * partial_ticks;
}

pub fn renderPitch(self: Thrown, partial_ticks: f32) f32 {
    return self.prev_pitch + (self.pitch - self.prev_pitch) * partial_ticks;
}

test "an egg leaves the hand at eye height, at one and a half blocks a tick" {
    var rand = world.JavaRandom.init(4);
    var player = Player.spawn(math.Vec3.init(8, 10, 8));
    player.yaw = 0;
    player.pitch = 0;

    const egg = thrownBy(.egg, player, &rand);

    try std.testing.expectApproxEqAbs(@as(f64, 8.0 - 0.16), egg.base.position.x, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0 + Player.eye_height + 0.12 - 0.1), egg.base.position.y, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), egg.base.position.z, 1.0e-6);

    const speed = @sqrt(
        egg.base.motion.x * egg.base.motion.x +
            egg.base.motion.y * egg.base.motion.y +
            egg.base.motion.z * egg.base.motion.z,
    );
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), speed, 0.02);
    try std.testing.expect(egg.base.motion.z > 1.4);
    try std.testing.expect(egg.from_player);
    try std.testing.expectEqual(player.base.id, egg.owner);
}

test "an egg in open air arcs downward and keeps most of its speed" {
    const gpa = std.testing.allocator;
    var w = world.World.init(gpa);
    defer w.deinit();
    _ = try w.createChunk(0, 0);

    var rand = world.JavaRandom.init(3);
    const player = Player.spawn(math.Vec3.init(8, 40, 8));
    var egg = thrownBy(.egg, player, &rand);

    const started = egg.base.position.z;
    egg.settle(&w);
    try std.testing.expect(egg.blockImpact(&w) == null);
    try std.testing.expect(egg.fly() == null);

    try std.testing.expect(egg.base.position.z - started > 1.4);
    try std.testing.expect(egg.base.motion.y < 0.0);
    try std.testing.expectEqual(@as(i32, 1), egg.ticks_in_air);
}

test "an egg that meets a wall reports where it would strike it" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();
    const chunk = w.getChunk(0, 0).?;
    chunk.setBlock(10, 5, 8, .stone);

    var egg: Thrown = .{ .kind = .egg, .base = Entity.init(math.Vec3.init(8.5, 5.5, 8.5), size, size) };
    egg.base.motion = math.Vec3.init(1.5, 0, 0);
    egg.settle(&w);

    const hit = egg.blockImpact(&w).?;
    try std.testing.expectEqual(@as(i32, 10), hit.pos.x);
}

test "an egg trails bubbles once it is under water" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();
    const chunk = w.getChunk(0, 0).?;
    for (1..6) |y| {
        for (6..12) |x| chunk.setBlock(@intCast(x), @intCast(y), 8, .stationary_water);
    }

    var egg: Thrown = .{ .kind = .egg, .base = Entity.init(math.Vec3.init(8.5, 3.5, 8.5), size, size) };
    egg.base.motion = math.Vec3.init(0.5, 0, 0);
    egg.settle(&w);
    try std.testing.expect(egg.base.in_water);

    const trail = egg.fly().?;
    try std.testing.expect(trail.position.x < egg.base.position.x);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5 * @as(f64, projectile.water_drag)), egg.base.motion.x, 1.0e-9);
}

test "an egg hatches about one throw in eight, and a whole brood far more rarely" {
    var rand = world.JavaRandom.init(9);

    var hatches: usize = 0;
    var broods: usize = 0;
    for (0..4096) |_| {
        const chicks = hatched(&rand);
        if (chicks == 0) continue;
        hatches += 1;
        if (chicks == brood_size) broods += 1;
    }

    try std.testing.expect(hatches > 4096 / 12 and hatches < 4096 / 5);
    try std.testing.expect(broods > 0 and broods < hatches / 4);
}

test "an egg that falls out of the world stops existing" {
    const gpa = std.testing.allocator;
    var w = world.World.init(gpa);
    defer w.deinit();

    var egg: Thrown = .{ .kind = .egg, .base = Entity.init(math.Vec3.init(8, -70, 8), size, size) };
    egg.settle(&w);
    try std.testing.expect(egg.dead);
}
