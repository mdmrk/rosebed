const std = @import("std");

const math = @import("mathutil.zig");

const Vec3 = @This();

x: f64,
y: f64,
z: f64,

pub fn init(x: f64, y: f64, z: f64) Vec3 {
    return .{ .x = x, .y = y, .z = z };
}

const Simd = @Vector(3, f64);

fn toSimd(v: Vec3) Simd {
    return .{ v.x, v.y, v.z };
}

fn fromSimd(v: Simd) Vec3 {
    return .{ .x = v[0], .y = v[1], .z = v[2] };
}

pub fn add(a: Vec3, b: Vec3) Vec3 {
    return fromSimd(toSimd(a) + toSimd(b));
}

pub fn sub(a: Vec3, b: Vec3) Vec3 {
    return fromSimd(toSimd(a) - toSimd(b));
}

pub fn scale(v: Vec3, s: f64) Vec3 {
    return fromSimd(toSimd(v) * @as(Simd, @splat(s)));
}

pub fn lerp(a: Vec3, b: Vec3, t: f64) Vec3 {
    return fromSimd(toSimd(a) + (toSimd(b) - toSimd(a)) * @as(Simd, @splat(t)));
}

pub fn dot(a: Vec3, b: Vec3) f64 {
    return @reduce(.Add, toSimd(a) * toSimd(b));
}

pub fn cross(a: Vec3, b: Vec3) Vec3 {
    return .{
        .x = a.y * b.z - a.z * b.y,
        .y = a.z * b.x - a.x * b.z,
        .z = a.x * b.y - a.y * b.x,
    };
}

pub fn lengthSquared(v: Vec3) f64 {
    const s = toSimd(v);
    return @reduce(.Add, s * s);
}

pub fn length(v: Vec3) f64 {
    return math.sqrtF(v.lengthSquared());
}

pub fn distanceSquaredTo(a: Vec3, b: Vec3) f64 {
    return b.sub(a).lengthSquared();
}

pub fn distanceTo(a: Vec3, b: Vec3) f64 {
    return math.sqrtF(a.distanceSquaredTo(b));
}

pub fn normalize(v: Vec3) Vec3 {
    const len = v.length();
    if (len < 1.0e-4) return .{ .x = 0, .y = 0, .z = 0 };
    return v.scale(1.0 / len);
}

pub fn rotateX(v: Vec3, angle: f32) Vec3 {
    const c = math.cos(angle);
    const s = math.sin(angle);
    return .{
        .x = v.x,
        .y = v.y * c + v.z * s,
        .z = v.z * c - v.y * s,
    };
}

pub fn rotateY(v: Vec3, angle: f32) Vec3 {
    const c = math.cos(angle);
    const s = math.sin(angle);
    return .{
        .x = v.x * c + v.z * s,
        .y = v.y,
        .z = v.z * c - v.x * s,
    };
}

pub fn intermediateWithX(a: Vec3, b: Vec3, plane_x: f64) ?Vec3 {
    const d = b.sub(a);
    if (d.x * d.x < 1.0e-7) return null;
    const t = (plane_x - a.x) / d.x;
    if (t < 0.0 or t > 1.0) return null;
    return a.add(d.scale(t));
}

pub fn intermediateWithY(a: Vec3, b: Vec3, plane_y: f64) ?Vec3 {
    const d = b.sub(a);
    if (d.y * d.y < 1.0e-7) return null;
    const t = (plane_y - a.y) / d.y;
    if (t < 0.0 or t > 1.0) return null;
    return a.add(d.scale(t));
}

pub fn intermediateWithZ(a: Vec3, b: Vec3, plane_z: f64) ?Vec3 {
    const d = b.sub(a);
    if (d.z * d.z < 1.0e-7) return null;
    const t = (plane_z - a.z) / d.z;
    if (t < 0.0 or t > 1.0) return null;
    return a.add(d.scale(t));
}

test "length/distanceTo match a 3-4-5 triangle" {
    const v = Vec3.init(3.0, 4.0, 0.0);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), v.length(), 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), Vec3.init(0, 0, 0).distanceTo(v), 1.0e-6);
}

test "normalize produces a unit vector" {
    const v = Vec3.init(3.0, 4.0, 0.0).normalize();
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), v.length(), 1.0e-6);
}

test "cross product of orthogonal unit axes" {
    const x = Vec3.init(1, 0, 0);
    const y = Vec3.init(0, 1, 0);
    const z = x.cross(y);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), z.x, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), z.y, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), z.z, 1.0e-9);
}

test "intermediateWithY finds the segment/plane crossing" {
    const a = Vec3.init(0, 0, 0);
    const b = Vec3.init(0, 10, 0);
    const hit = a.intermediateWithY(b, 5.0).?;
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), hit.y, 1.0e-9);
    try std.testing.expect(a.intermediateWithY(b, 20.0) == null);
}
