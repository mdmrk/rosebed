const std = @import("std");

const math = @import("math");
const world = @import("world");

const Entity = @import("../Entity.zig");
const Player = @import("../Player.zig");
const projectile = @import("projectile.zig");
const raycast = @import("../raycast.zig");

const Arrow = @This();

base: Entity,
yaw: f32 = 0,
pitch: f32 = 0,
prev_yaw: f32 = 0,
prev_pitch: f32 = 0,
tile: [3]i32 = .{ -1, -1, -1 },
in_tile: world.Block = .air,
in_tile_metadata: u4 = 0,
in_ground: bool = false,
from_player: bool = false,
owner: Entity.Id = Entity.no_id,
shake: i32 = 0,
ticks_in_ground: i32 = 0,
ticks_in_air: i32 = 0,
dead: bool = false,

pub const size: f64 = 0.5;
pub const damage: i32 = 4;
pub const hit_border: f64 = 0.3;
pub const owner_grace_ticks: i32 = 5;
pub const bubbles_per_trail: usize = 4;
pub const shake_ticks: i32 = 7;
pub const impact_volume: f32 = 1.0;

const eye_offset: f32 = 0.12;
const hand_offset: f32 = 0.16;
const hand_drop: f32 = 0.1;
const launch_speed: f32 = 1.5;
const launch_spread: f32 = 1.0;
const ground_lifetime: i32 = 1200;
const stick_backoff: f32 = 0.05;
const deflect_rebound: f32 = -0.1;
const pop_out_scale: f32 = 0.2;

pub fn impactPitch(rand: *world.JavaRandom) f32 {
    return 1.2 / (rand.nextFloat() * 0.2 + 0.9);
}

pub fn shotBy(player: Player, rand: *world.JavaRandom) Arrow {
    const eye = player.eyePosition();
    const yaw_radians = player.yaw / 180.0 * std.math.pi;
    const pitch_radians = player.pitch / 180.0 * std.math.pi;

    const position = math.Vec3.init(
        eye.x - @as(f64, math.util.cos(yaw_radians) * hand_offset),
        eye.y + @as(f64, eye_offset) - @as(f64, hand_drop),
        eye.z - @as(f64, math.util.sin(yaw_radians) * hand_offset),
    );

    var arrow: Arrow = .{
        .base = Entity.init(position, size, size),
        .from_player = true,
        .owner = player.base.id,
    };

    const heading = math.Vec3.init(
        -math.util.sin(yaw_radians) * math.util.cos(pitch_radians),
        -math.util.sin(pitch_radians),
        math.util.cos(yaw_radians) * math.util.cos(pitch_radians),
    );
    arrow.setHeading(heading, launch_speed, launch_spread, rand);
    return arrow;
}

pub fn loosedBy(owner: Entity.Id, from: math.Vec3, toward: math.Vec3, speed: f32, spread: f32, rand: *world.JavaRandom) Arrow {
    var arrow: Arrow = .{ .base = Entity.init(from, size, size), .owner = owner };
    arrow.setHeading(toward, speed, spread, rand);
    return arrow;
}

fn setHeading(self: *Arrow, direction: math.Vec3, speed: f32, spread: f32, rand: *world.JavaRandom) void {
    projectile.setHeading(self, direction, speed, spread, rand);
    self.ticks_in_ground = 0;
}

pub fn settle(self: *Arrow, world_map: *const world.World, rand: *world.JavaRandom) bool {
    self.base.beginTick();
    self.prev_yaw = self.yaw;
    self.prev_pitch = self.pitch;
    self.base.updateWaterState(world_map);
    if (self.base.position.y < projectile.void_floor) self.dead = true;

    if (self.buriedInTile(world_map)) self.in_ground = true;
    if (self.shake > 0) self.shake -= 1;

    if (!self.in_ground) {
        self.ticks_in_air += 1;
        return false;
    }

    const block = world_map.getBlock(.init(self.tile[0], self.tile[1], self.tile[2]));
    const metadata = world_map.getBlockMetadata(.init(self.tile[0], self.tile[1], self.tile[2]));
    if (block == self.in_tile and metadata == self.in_tile_metadata) {
        self.ticks_in_ground += 1;
        if (self.ticks_in_ground == ground_lifetime) self.dead = true;
        return true;
    }

    self.in_ground = false;
    self.base.motion.x *= @as(f64, rand.nextFloat()) * pop_out_scale;
    self.base.motion.y *= @as(f64, rand.nextFloat()) * pop_out_scale;
    self.base.motion.z *= @as(f64, rand.nextFloat()) * pop_out_scale;
    self.ticks_in_ground = 0;
    self.ticks_in_air = 0;
    return true;
}

fn buriedInTile(self: Arrow, world_map: *const world.World) bool {
    const block = world_map.getBlock(.init(self.tile[0], self.tile[1], self.tile[2]));
    if (!block.isSolid()) return false;

    const bounds = block.selectionBounds(world_map.getBlockMetadata(.init(self.tile[0], self.tile[1], self.tile[2])));
    const point = [3]f64{ self.base.position.x, self.base.position.y, self.base.position.z };
    for (0..3) |axis| {
        const base: f64 = @floatFromInt(self.tile[axis]);
        if (point[axis] <= base + bounds.min[axis] or point[axis] >= base + bounds.max[axis]) return false;
    }
    return true;
}

pub fn blockImpact(self: Arrow, world_map: *const world.World) ?raycast.Hit {
    return raycast.castCollision(world_map, self.base.position, self.base.motion, 1.0);
}

pub fn reachedThisTick(self: Arrow, fraction: f64) math.Vec3 {
    return math.Vec3.init(
        self.base.position.x + self.base.motion.x * fraction,
        self.base.position.y + self.base.motion.y * fraction,
        self.base.position.z + self.base.motion.z * fraction,
    );
}

pub fn stickInto(self: *Arrow, world_map: *const world.World, hit: raycast.Hit) void {
    self.tile = .{ hit.pos.x, hit.pos.y, hit.pos.z };
    self.in_tile = world_map.getBlock(hit.pos);
    self.in_tile_metadata = world_map.getBlockMetadata(hit.pos);

    const reach = self.reachedThisTick(hit.distance);
    const dx: f64 = @as(f32, @floatCast(reach.x - self.base.position.x));
    const dy: f64 = @as(f32, @floatCast(reach.y - self.base.position.y));
    const dz: f64 = @as(f32, @floatCast(reach.z - self.base.position.z));
    self.base.motion = math.Vec3.init(dx, dy, dz);

    const length: f64 = math.util.sqrtF(dx * dx + dy * dy + dz * dz);
    self.base.position.x -= dx / length * stick_backoff;
    self.base.position.y -= dy / length * stick_backoff;
    self.base.position.z -= dz / length * stick_backoff;

    self.in_ground = true;
    self.shake = shake_ticks;
}

pub fn deflect(self: *Arrow) void {
    self.base.motion.x *= deflect_rebound;
    self.base.motion.y *= deflect_rebound;
    self.base.motion.z *= deflect_rebound;
    self.yaw += 180.0;
    self.prev_yaw += 180.0;
    self.ticks_in_air = 0;
}

pub fn fly(self: *Arrow) ?projectile.BubbleTrail {
    return projectile.fly(self);
}

pub fn canBePickedUp(self: Arrow) bool {
    return self.in_ground and self.from_player and self.shake <= 0;
}

pub fn renderYaw(self: Arrow, partial_ticks: f32) f32 {
    return self.prev_yaw + (self.yaw - self.prev_yaw) * partial_ticks;
}

pub fn renderPitch(self: Arrow, partial_ticks: f32) f32 {
    return self.prev_pitch + (self.pitch - self.prev_pitch) * partial_ticks;
}

fn testPlayer(position: math.Vec3, yaw: f32, pitch: f32) Player {
    var player = Player.spawn(position);
    player.yaw = yaw;
    player.pitch = pitch;
    return player;
}

test "an arrow leaves the bow at eye height, just off the hand, at one and a half blocks a tick" {
    var rand = world.JavaRandom.init(4);
    const player = testPlayer(math.Vec3.init(8, 10, 8), 0, 0);
    const arrow = shotBy(player, &rand);

    try std.testing.expectApproxEqAbs(@as(f64, 8.0 - 0.16), arrow.base.position.x, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0 + Player.eye_height + 0.12 - 0.1), arrow.base.position.y, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), arrow.base.position.z, 1.0e-6);

    const speed = @sqrt(
        arrow.base.motion.x * arrow.base.motion.x +
            arrow.base.motion.y * arrow.base.motion.y +
            arrow.base.motion.z * arrow.base.motion.z,
    );
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), speed, 0.02);
    try std.testing.expect(arrow.base.motion.z > 1.4);
    try std.testing.expect(arrow.from_player);
}

test "the shot scatters around where the bow was pointed" {
    var rand = world.JavaRandom.init(7);
    const player = testPlayer(math.Vec3.init(8, 10, 8), 0, 0);

    var spread_seen = false;
    for (0..50) |_| {
        const arrow = shotBy(player, &rand);
        try std.testing.expect(@abs(arrow.base.motion.x) < 0.05);
        try std.testing.expect(@abs(arrow.base.motion.y) < 0.05);
        if (arrow.base.motion.x != 0.0) spread_seen = true;
    }
    try std.testing.expect(spread_seen);
}

test "an arrow in open air arcs downward and keeps most of its speed" {
    const gpa = std.testing.allocator;
    var w = world.World.init(gpa);
    defer w.deinit();
    _ = try w.createChunk(0, 0);

    var rand = world.JavaRandom.init(3);
    const player = testPlayer(math.Vec3.init(8, 40, 8), 0, 0);
    var arrow = shotBy(player, &rand);

    const started = arrow.base.position.z;
    try std.testing.expect(!arrow.settle(&w, &rand));
    try std.testing.expect(arrow.blockImpact(&w) == null);
    try std.testing.expect(arrow.fly() == null);

    try std.testing.expect(arrow.base.position.z - started > 1.4);
    try std.testing.expect(arrow.base.motion.y < 0.0);
    try std.testing.expect(arrow.base.motion.z > 1.4 * projectile.drag - 0.01);
    try std.testing.expectEqual(@as(i32, 1), arrow.ticks_in_air);
}

test "an arrow that meets a wall stops just short of it and sticks" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();
    const chunk = w.getChunk(0, 0).?;
    chunk.setBlock(10, 5, 8, .stone);

    var rand = world.JavaRandom.init(3);
    var arrow: Arrow = .{ .base = Entity.init(math.Vec3.init(8.5, 5.5, 8.5), size, size) };
    arrow.base.motion = math.Vec3.init(1.5, 0, 0);

    try std.testing.expect(!arrow.settle(&w, &rand));
    const hit = arrow.blockImpact(&w).?;
    try std.testing.expectEqual(@as(i32, 10), hit.pos.x);

    arrow.stickInto(&w, hit);
    _ = arrow.fly();

    try std.testing.expect(arrow.in_ground);
    try std.testing.expectEqual(shake_ticks, arrow.shake);
    try std.testing.expectEqual(world.Block.stone, arrow.in_tile);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0 - 0.05), arrow.base.position.x, 1.0e-6);
}

test "an arrow flies straight through grass without sticking in it" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();
    const chunk = w.getChunk(0, 0).?;
    chunk.setBlock(9, 5, 8, .tall_grass);

    var arrow: Arrow = .{ .base = Entity.init(math.Vec3.init(8.5, 5.5, 8.5), size, size) };
    arrow.base.motion = math.Vec3.init(1.0, 0, 0);

    try std.testing.expect(arrow.blockImpact(&w) == null);
}

test "an arrow stuck in a block that is mined away drops out of it" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();
    const chunk = w.getChunk(0, 0).?;
    chunk.setBlock(10, 5, 8, .stone);

    var rand = world.JavaRandom.init(3);
    var arrow: Arrow = .{ .base = Entity.init(math.Vec3.init(8.5, 5.5, 8.5), size, size) };
    arrow.base.motion = math.Vec3.init(1.5, 0, 0);
    _ = arrow.settle(&w, &rand);
    arrow.stickInto(&w, arrow.blockImpact(&w).?);
    _ = arrow.fly();

    try std.testing.expect(arrow.settle(&w, &rand));
    try std.testing.expect(arrow.in_ground);
    try std.testing.expectEqual(@as(i32, 1), arrow.ticks_in_ground);

    chunk.setBlock(10, 5, 8, .air);
    try std.testing.expect(arrow.settle(&w, &rand));
    try std.testing.expect(!arrow.in_ground);
    try std.testing.expectEqual(@as(i32, 0), arrow.ticks_in_ground);
    try std.testing.expect(@abs(arrow.base.motion.x) < 1.5 * pop_out_scale);
}

test "an arrow left in the ground gives up after a minute" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var rand = world.JavaRandom.init(3);
    var arrow: Arrow = .{ .base = Entity.init(math.Vec3.init(8.5, 0.5, 8.5), size, size) };
    arrow.tile = .{ 8, 0, 8 };
    arrow.in_tile = w.getBlock(.init(8, 0, 8));
    arrow.in_ground = true;

    for (0..ground_lifetime - 1) |_| {
        try std.testing.expect(arrow.settle(&w, &rand));
        try std.testing.expect(!arrow.dead);
    }
    try std.testing.expect(arrow.settle(&w, &rand));
    try std.testing.expect(arrow.dead);
}

test "an arrow cannot be picked up until it has stopped shaking" {
    var arrow: Arrow = .{ .base = Entity.init(math.Vec3.init(8, 5, 8), size, size), .from_player = true };
    try std.testing.expect(!arrow.canBePickedUp());

    arrow.in_ground = true;
    arrow.shake = shake_ticks;
    try std.testing.expect(!arrow.canBePickedUp());

    arrow.shake = 0;
    try std.testing.expect(arrow.canBePickedUp());

    arrow.from_player = false;
    try std.testing.expect(!arrow.canBePickedUp());
}

test "an arrow shot into water slows down and trails bubbles" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();
    const chunk = w.getChunk(0, 0).?;
    for (1..6) |y| {
        for (6..12) |x| chunk.setBlock(@intCast(x), @intCast(y), 8, .stationary_water);
    }

    var rand = world.JavaRandom.init(3);
    var arrow: Arrow = .{ .base = Entity.init(math.Vec3.init(8.5, 3.5, 8.5), size, size) };
    arrow.base.motion = math.Vec3.init(0.5, 0, 0);

    try std.testing.expect(!arrow.settle(&w, &rand));
    try std.testing.expect(arrow.base.in_water);
    const trail = arrow.fly().?;

    try std.testing.expect(trail.position.x < arrow.base.position.x);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5 * projectile.water_drag), arrow.base.motion.x, 1.0e-9);
}

test "a deflected arrow turns around and loses almost all its speed" {
    var arrow: Arrow = .{ .base = Entity.init(math.Vec3.init(8, 5, 8), size, size) };
    arrow.base.motion = math.Vec3.init(1.0, 0.5, -1.0);
    arrow.yaw = 90;
    arrow.prev_yaw = 90;
    arrow.ticks_in_air = 12;

    arrow.deflect();

    try std.testing.expectApproxEqAbs(@as(f64, -0.1), arrow.base.motion.x, 1.0e-7);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), arrow.base.motion.z, 1.0e-7);
    try std.testing.expectEqual(@as(f32, 270), arrow.yaw);
    try std.testing.expectEqual(@as(i32, 0), arrow.ticks_in_air);
}

test "an arrow that falls out of the world stops existing" {
    const gpa = std.testing.allocator;
    var w = world.World.init(gpa);
    defer w.deinit();

    var rand = world.JavaRandom.init(3);
    var arrow: Arrow = .{ .base = Entity.init(math.Vec3.init(8, -70, 8), size, size) };
    _ = arrow.settle(&w, &rand);
    try std.testing.expect(arrow.dead);
}

pub fn toRecord(self: Arrow) world.entity_nbt.Arrow {
    return .{
        .base = .{
            .position = .{
                .x = self.base.position.x,
                .y = self.base.position.y + self.base.y_size,
                .z = self.base.position.z,
            },
            .motion = self.base.motion,
            .yaw = self.yaw,
            .pitch = self.pitch,
            .on_ground = self.base.on_ground,
        },
        .tile = .{
            @intCast(self.tile[0]),
            @intCast(self.tile[1]),
            @intCast(self.tile[2]),
        },
        .in_tile = @intFromEnum(self.in_tile),
        .in_data = self.in_tile_metadata,
        .shake = @intCast(@max(0, self.shake)),
        .in_ground = self.in_ground,
        .from_player = self.from_player,
    };
}

pub fn fromRecord(record: world.entity_nbt.Arrow) Arrow {
    var arrow = Arrow{
        .base = Entity.init(record.base.position, size, size),
        .yaw = record.base.yaw,
        .pitch = record.base.pitch,
        .prev_yaw = record.base.yaw,
        .prev_pitch = record.base.pitch,
        .tile = .{ record.tile[0], record.tile[1], record.tile[2] },
        .in_tile = @enumFromInt(record.in_tile),
        .in_tile_metadata = @truncate(record.in_data),
        .in_ground = record.in_ground,
        .from_player = record.from_player,
        .shake = record.shake,
    };
    arrow.base.motion = record.base.motion;
    arrow.base.on_ground = record.base.on_ground;
    return arrow;
}
