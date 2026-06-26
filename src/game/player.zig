const std = @import("std");
const math = @import("math");
const world = @import("world");
const physics = @import("physics.zig");

const Player = @This();

position: math.Vec3,
prev_position: math.Vec3 = math.Vec3.init(0, 0, 0),
yaw: f32 = 0,
pitch: f32 = 0,
motion: math.Vec3 = math.Vec3.init(0, 0, 0),
on_ground: bool = false,

pub const width: f64 = 0.6;
pub const height: f64 = 1.8;
pub const eye_height: f64 = 1.62;

const base_sensitivity = 0.5;
const turn_scale = 0.15;

const gravity: f64 = 0.08;
const vertical_drag: f64 = 0.98;
const air_friction: f64 = 0.91;
const ground_friction: f64 = 0.6 * 0.91;
const ground_speed: f64 = 0.1;
const air_speed: f64 = 0.02;
const jump_velocity: f64 = 0.42;

pub fn tick(self: *Player, chunk: *const world.Chunk, strafe: f32, forward: f32, jump: bool) void {
    self.prev_position = self.position;

    if (self.on_ground and jump) {
        self.motion.y = jump_velocity;
    }

    const speed: f64 = if (self.on_ground) ground_speed else air_speed;
    const dir = self.moveDirection(strafe, forward);
    self.motion.x += @as(f64, dir[0]) * speed;
    self.motion.z += @as(f64, dir[2]) * speed;

    const result = physics.moveEntity(chunk, self.boundingBox(), self.motion.x, self.motion.y, self.motion.z);

    self.position = .{
        .x = (result.aabb.min_x + result.aabb.max_x) / 2.0,
        .y = result.aabb.min_y,
        .z = (result.aabb.min_z + result.aabb.max_z) / 2.0,
    };

    self.on_ground = self.motion.y != result.dy and self.motion.y < 0.0;
    if (self.motion.x != result.dx) self.motion.x = 0;
    if (self.motion.y != result.dy) self.motion.y = 0;
    if (self.motion.z != result.dz) self.motion.z = 0;

    self.motion.y -= gravity;
    self.motion.y *= vertical_drag;
    const friction: f64 = if (self.on_ground) ground_friction else air_friction;
    self.motion.x *= friction;
    self.motion.z *= friction;
}

pub fn boundingBox(self: Player) math.AABB {
    const half_width = width / 2.0;
    return math.AABB.init(
        self.position.x - half_width,
        self.position.y,
        self.position.z - half_width,
        self.position.x + half_width,
        self.position.y + height,
        self.position.z + half_width,
    );
}

fn turnFactor() f32 {
    const s = base_sensitivity * 0.6 + 0.2;
    return s * s * s * 8.0;
}

pub fn turn(self: *Player, dx: f32, dy: f32) void {
    const factor = turnFactor();
    self.yaw += dx * factor * turn_scale;
    self.pitch += dy * factor * turn_scale;
    self.pitch = std.math.clamp(self.pitch, -90.0, 90.0);
}

pub fn lookVector(self: Player) [3]f32 {
    const yaw_rad = self.yaw * std.math.pi / 180.0;
    const pitch_rad = self.pitch * std.math.pi / 180.0;
    return .{
        -@sin(yaw_rad) * @cos(pitch_rad),
        -@sin(pitch_rad),
        @cos(yaw_rad) * @cos(pitch_rad),
    };
}

pub fn moveDirection(self: Player, strafe: f32, forward: f32) [3]f32 {
    const yaw_rad = self.yaw * std.math.pi / 180.0;
    const s = @sin(yaw_rad);
    const c = @cos(yaw_rad);
    var dir = [3]f32{ strafe * c - forward * s, 0, forward * c + strafe * s };
    const len = @sqrt(dir[0] * dir[0] + dir[2] * dir[2]);
    if (len > 1.0e-4) {
        dir[0] /= len;
        dir[2] /= len;
    }
    return dir;
}

pub fn renderPosition(self: Player, partial_ticks: f32) math.Vec3 {
    const t: f64 = partial_ticks;
    return .{
        .x = self.prev_position.x + (self.position.x - self.prev_position.x) * t,
        .y = self.prev_position.y + (self.position.y - self.prev_position.y) * t,
        .z = self.prev_position.z + (self.position.z - self.prev_position.z) * t,
    };
}

pub fn viewMatrix(self: Player, partial_ticks: f32) math.Mat4 {
    const render_position = self.renderPosition(partial_ticks);
    const eye = [3]f32{
        @floatCast(render_position.x),
        @floatCast(render_position.y + eye_height),
        @floatCast(render_position.z),
    };
    const look = self.lookVector();
    const center = [3]f32{ eye[0] + look[0], eye[1] + look[1], eye[2] + look[2] };
    return math.Mat4.lookAt(eye, center, .{ 0, 1, 0 });
}

test "boundingBox is centered on x/z and rests on the feet position" {
    const player: Player = .{ .position = math.Vec3.init(2, 5, 3) };
    const box = player.boundingBox();
    try std.testing.expectApproxEqAbs(@as(f64, 1.7), box.min_x, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2.3), box.max_x, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), box.min_y, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 6.8), box.max_y, 1.0e-9);
}

test "turn at default sensitivity applies the 0.15 deg/pixel scale" {
    var player: Player = .{ .position = math.Vec3.init(0, 0, 0) };
    player.turn(10, 4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), player.yaw, 1.0e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), player.pitch, 1.0e-4);
}

test "pitch clamps to +/-90 degrees" {
    var player: Player = .{ .position = math.Vec3.init(0, 0, 0) };
    player.turn(0, 10000);
    try std.testing.expectApproxEqAbs(@as(f32, 90.0), player.pitch, 1.0e-4);
    player.turn(0, -20000);
    try std.testing.expectApproxEqAbs(@as(f32, -90.0), player.pitch, 1.0e-4);
}

test "lookVector faces +Z at yaw 0, pitch 0" {
    const player: Player = .{ .position = math.Vec3.init(0, 0, 0) };
    const look = player.lookVector();
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), look[0], 1.0e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), look[1], 1.0e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), look[2], 1.0e-5);
}

test "positive pitch looks down, negative pitch looks up" {
    var player: Player = .{ .position = math.Vec3.init(0, 0, 0) };
    player.pitch = 90;
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), player.lookVector()[1], 1.0e-4);
    player.pitch = -90;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), player.lookVector()[1], 1.0e-4);
}

test "moveDirection at yaw 0 matches forward/strafe axes" {
    const player: Player = .{ .position = math.Vec3.init(0, 0, 0) };
    const forward = player.moveDirection(0, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), forward[0], 1.0e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), forward[2], 1.0e-5);

    const strafe = player.moveDirection(1, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), strafe[0], 1.0e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), strafe[2], 1.0e-5);
}

test "renderPosition interpolates between the previous and current tick" {
    const player: Player = .{
        .position = math.Vec3.init(10, 0, 0),
        .prev_position = math.Vec3.init(0, 0, 0),
    };
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), player.renderPosition(0.0).x, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), player.renderPosition(0.5).x, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), player.renderPosition(1.0).x, 1.0e-9);
}

fn testChunkWithFloor() world.Chunk {
    var chunk = world.Chunk.init(0, 0);
    for (0..world.constants.chunk_width) |x| {
        for (0..world.constants.chunk_width) |z| {
            chunk.setBlockId(@intCast(x), 0, @intCast(z), world.block.stone);
        }
    }
    return chunk;
}

test "resting on the ground stays grounded" {
    const chunk = testChunkWithFloor();
    var player: Player = .{
        .position = math.Vec3.init(8, 1, 8),
        .on_ground = true,
        .motion = math.Vec3.init(0, -0.0784, 0),
    };
    player.tick(&chunk, 0, 0, false);
    try std.testing.expect(player.on_ground);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), player.position.y, 1.0e-9);
}

test "gravity accelerates a falling player" {
    const chunk = world.Chunk.init(0, 0);
    var player: Player = .{ .position = math.Vec3.init(8, 50, 8) };
    player.tick(&chunk, 0, 0, false);
    try std.testing.expectApproxEqAbs(@as(f64, -0.0784), player.motion.y, 1.0e-9);
}

test "jumping from the ground sets the jump velocity" {
    const chunk = testChunkWithFloor();
    var player: Player = .{ .position = math.Vec3.init(8, 1, 8), .on_ground = true };
    player.tick(&chunk, 0, 0, true);
    try std.testing.expectApproxEqAbs(@as(f64, (0.42 - 0.08) * 0.98), player.motion.y, 1.0e-9);
}

test "forward input on the ground moves the player each tick" {
    const chunk = testChunkWithFloor();
    var player: Player = .{ .position = math.Vec3.init(8, 1, 8), .on_ground = true };
    player.tick(&chunk, 0, 1, false);
    try std.testing.expectApproxEqAbs(@as(f64, 8.1), player.position.z, 1.0e-9);
}
