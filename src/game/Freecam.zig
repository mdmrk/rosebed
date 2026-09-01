const std = @import("std");

const math = @import("math");

const Player = @import("Player.zig");

const Freecam = @This();

pub const speed: f64 = 0.5;

active: bool = false,
position: math.Vec3 = math.Vec3.init(0, 0, 0),
prev_position: math.Vec3 = math.Vec3.init(0, 0, 0),
yaw: f32 = 0,
prev_yaw: f32 = 0,
pitch: f32 = 0,
prev_pitch: f32 = 0,

pub fn enter(self: *Freecam, eye: math.Vec3, yaw: f32, pitch: f32) void {
    self.* = .{
        .active = true,
        .position = eye,
        .prev_position = eye,
        .yaw = yaw,
        .prev_yaw = yaw,
        .pitch = pitch,
        .prev_pitch = pitch,
    };
}

pub fn leave(self: *Freecam) void {
    self.active = false;
}

pub fn turn(self: *Freecam, dx: f32, dy: f32, sensitivity: f32, invert: bool) void {
    const factor = Player.turnFactor(sensitivity);
    const pitch_delta = if (invert) -dy else dy;
    self.yaw += dx * factor * Player.turn_scale;
    self.pitch = std.math.clamp(self.pitch + pitch_delta * factor * Player.turn_scale, -90.0, 90.0);
}

pub fn beginTick(self: *Freecam) void {
    self.prev_position = self.position;
    self.prev_yaw = self.yaw;
    self.prev_pitch = self.pitch;
}

pub fn move(self: *Freecam, strafe: f32, forward: f32, up: f32) void {
    const yaw_rad = self.yaw * std.math.pi / 180.0;
    const pitch_rad = self.pitch * std.math.pi / 180.0;
    const sin_yaw: f64 = @sin(yaw_rad);
    const cos_yaw: f64 = @cos(yaw_rad);
    const cos_pitch: f64 = @cos(pitch_rad);

    const ahead: f64 = forward;
    const sideways: f64 = strafe;
    var delta = math.Vec3.init(
        -sin_yaw * cos_pitch * ahead + cos_yaw * sideways,
        -@as(f64, @sin(pitch_rad)) * ahead + @as(f64, up),
        cos_yaw * cos_pitch * ahead + sin_yaw * sideways,
    );

    const length = delta.length();
    if (length == 0) return;
    if (length > 1.0) delta = delta.scale(1.0 / length);
    self.position = self.position.add(delta.scale(speed));
}

pub fn renderPosition(self: Freecam, partial_ticks: f32) math.Vec3 {
    return self.prev_position.lerp(self.position, partial_ticks);
}

pub fn rotationMatrix(self: Freecam, partial_ticks: f32) math.Mat4 {
    const degrees = std.math.pi / 180.0;
    const yaw = self.prev_yaw + (self.yaw - self.prev_yaw) * partial_ticks;
    const pitch = self.prev_pitch + (self.pitch - self.prev_pitch) * partial_ticks;
    return math.Mat4.rotationX(pitch * degrees)
        .mul(math.Mat4.rotationY((yaw + 180.0) * degrees));
}

pub fn viewMatrix(self: Freecam, partial_ticks: f32) math.Mat4 {
    const eye = self.renderPosition(partial_ticks);
    return self.rotationMatrix(partial_ticks).mul(math.Mat4.translation(
        @floatCast(-eye.x),
        @floatCast(-eye.y),
        @floatCast(-eye.z),
    ));
}

test "entering adopts the eye it was handed and starts still" {
    var camera: Freecam = .{};
    camera.enter(math.Vec3.init(1, 2, 3), 45, -10);

    try std.testing.expect(camera.active);
    try std.testing.expectEqual(math.Vec3.init(1, 2, 3), camera.position);
    try std.testing.expectEqual(math.Vec3.init(1, 2, 3), camera.prev_position);
    try std.testing.expectEqual(@as(f32, 45), camera.yaw);
    try std.testing.expectEqual(@as(f32, -10), camera.prev_pitch);
}

test "walking forward at zero yaw travels one speed along positive z" {
    var camera: Freecam = .{};
    camera.enter(math.Vec3.init(0, 0, 0), 0, 0);
    camera.beginTick();
    camera.move(0, 1, 0);

    try std.testing.expectApproxEqAbs(@as(f64, 0), camera.position.x, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0), camera.position.y, 1.0e-9);
    try std.testing.expectApproxEqAbs(speed, camera.position.z, 1.0e-9);
}

test "looking down sends forward travel downward" {
    var camera: Freecam = .{};
    camera.enter(math.Vec3.init(0, 0, 0), 0, 90);
    camera.beginTick();
    camera.move(0, 1, 0);

    try std.testing.expectApproxEqAbs(-speed, camera.position.y, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 0), camera.position.z, 1.0e-6);
}

test "jump and sneak lift and drop the camera without leaning it" {
    var camera: Freecam = .{};
    camera.enter(math.Vec3.init(0, 64, 0), 0, 0);
    camera.beginTick();
    camera.move(0, 0, 1);
    try std.testing.expectApproxEqAbs(64 + speed, camera.position.y, 1.0e-9);

    camera.beginTick();
    camera.move(0, 0, -1);
    try std.testing.expectApproxEqAbs(@as(f64, 64), camera.position.y, 1.0e-9);
}

test "diagonal travel is no faster than travel along one axis" {
    var camera: Freecam = .{};
    camera.enter(math.Vec3.init(0, 0, 0), 0, 0);
    camera.beginTick();
    camera.move(1, 1, 1);

    const travelled = camera.position.sub(camera.prev_position).length();
    try std.testing.expectApproxEqAbs(speed, travelled, 1.0e-9);
}

test "a still camera holds its place" {
    var camera: Freecam = .{};
    camera.enter(math.Vec3.init(5, 70, -3), 30, 15);
    camera.beginTick();
    camera.move(0, 0, 0);

    try std.testing.expectEqual(math.Vec3.init(5, 70, -3), camera.position);
}

test "the rendered position eases between ticks" {
    var camera: Freecam = .{};
    camera.enter(math.Vec3.init(0, 0, 0), 0, 0);
    camera.beginTick();
    camera.move(0, 1, 0);

    const halfway = camera.renderPosition(0.5);
    try std.testing.expectApproxEqAbs(speed / 2.0, halfway.z, 1.0e-9);
}

test "leaving stops the camera being the one that draws" {
    var camera: Freecam = .{};
    camera.enter(math.Vec3.init(0, 0, 0), 0, 0);
    camera.leave();
    try std.testing.expect(!camera.active);
}
