const std = @import("std");

const math = @import("util.zig");

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
    const p = toSimd(a) * toSimd(b);
    return p[0] + p[1] + p[2];
}

pub fn cross(a: Vec3, b: Vec3) Vec3 {
    return .{
        .x = a.y * b.z - a.z * b.y,
        .y = a.z * b.x - a.x * b.z,
        .z = a.x * b.y - a.y * b.x,
    };
}

pub fn lengthSquared(v: Vec3) f64 {
    const p = toSimd(v) * toSimd(v);
    return p[0] + p[1] + p[2];
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
    return fromSimd(toSimd(v) / @as(Simd, @splat(len)));
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

const intermediate_epsilon: f64 = @as(f32, 1.0e-7);

fn intermediate(a: Vec3, b: Vec3, a_axis: f64, b_axis: f64, plane: f64) ?Vec3 {
    const along = b_axis - a_axis;
    if (along * along < intermediate_epsilon) return null;
    const t = (plane - a_axis) / along;
    if (t < 0.0 or t > 1.0) return null;
    return a.add(b.sub(a).scale(t));
}

pub fn intermediateWithX(a: Vec3, b: Vec3, plane_x: f64) ?Vec3 {
    return intermediate(a, b, a.x, b.x, plane_x);
}

pub fn intermediateWithY(a: Vec3, b: Vec3, plane_y: f64) ?Vec3 {
    return intermediate(a, b, a.y, b.y, plane_y);
}

pub fn intermediateWithZ(a: Vec3, b: Vec3, plane_z: f64) ?Vec3 {
    return intermediate(a, b, a.z, b.z, plane_z);
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

test "normalize divides by the length rather than scaling by its reciprocal" {
    const v = Vec3.init(0.37, 1.5, -2.25);
    const len = v.length();
    const n = v.normalize();

    try std.testing.expectEqual(v.x / len, n.x);
    try std.testing.expectEqual(v.y / len, n.y);
    try std.testing.expectEqual(v.z / len, n.z);
}

test "normalize collapses a vector shorter than the reference cutoff" {
    const tiny = Vec3.init(1.0e-5, 0, 0).normalize();
    try std.testing.expectEqual(@as(f64, 0), tiny.x);
    try std.testing.expectEqual(@as(f64, 0), tiny.y);
    try std.testing.expectEqual(@as(f64, 0), tiny.z);

    const kept = Vec3.init(1.0e-3, 0, 0).normalize();
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), kept.x, 1.0e-6);
}

test "dot and cross agree with worked examples" {
    try std.testing.expectApproxEqAbs(@as(f64, 24.0), Vec3.init(-1, 2, 3).dot(Vec3.init(4, 5, 6)), 1.0e-9);

    const c = Vec3.init(-3, 0, -2).cross(Vec3.init(5, -1, 2));
    try std.testing.expectApproxEqAbs(@as(f64, -2.0), c.x, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -4.0), c.y, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), c.z, 1.0e-9);
}

test "cross is anticommutative and orthogonal to both inputs" {
    const a = Vec3.init(1.5, -2.0, 0.75);
    const b = Vec3.init(-0.25, 3.0, 4.0);
    const c = a.cross(b);

    try std.testing.expectApproxEqAbs(@as(f64, 0), c.dot(a), 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0), c.dot(b), 1.0e-12);

    const flipped = b.cross(a);
    try std.testing.expectApproxEqAbs(-c.x, flipped.x, 1.0e-12);
    try std.testing.expectApproxEqAbs(-c.y, flipped.y, 1.0e-12);
    try std.testing.expectApproxEqAbs(-c.z, flipped.z, 1.0e-12);
}

test "lerp hits both endpoints and the midpoint" {
    const a = Vec3.init(-1, 2, 7);
    const b = Vec3.init(3, -6, 1);

    const start = a.lerp(b, 0.0);
    try std.testing.expectApproxEqAbs(a.x, start.x, 1.0e-12);
    try std.testing.expectApproxEqAbs(a.z, start.z, 1.0e-12);

    const end = a.lerp(b, 1.0);
    try std.testing.expectApproxEqAbs(b.x, end.x, 1.0e-12);
    try std.testing.expectApproxEqAbs(b.z, end.z, 1.0e-12);

    const middle = a.lerp(b, 0.5);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), middle.x, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, -2.0), middle.y, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), middle.z, 1.0e-12);
}

test "rotateX and rotateY turn the axes the way the reference does" {
    const quarter: f32 = std.math.pi / 2.0;

    const x_turned = Vec3.init(0, 0, 1).rotateX(quarter);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), x_turned.y, 1.0e-4);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), x_turned.z, 1.0e-4);

    const y_turned = Vec3.init(1, 0, 0).rotateY(quarter);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), y_turned.x, 1.0e-4);
    try std.testing.expectApproxEqAbs(@as(f64, -1.0), y_turned.z, 1.0e-4);
}

test "a rotation preserves length" {
    const v = Vec3.init(0.3, -1.7, 2.2);
    try std.testing.expectApproxEqAbs(v.length(), v.rotateX(1.1).length(), 1.0e-4);
    try std.testing.expectApproxEqAbs(v.length(), v.rotateY(1.1).length(), 1.0e-4);
}

test "intermediateWith ignores a segment that barely crosses the plane" {
    const a = Vec3.init(0, 0, 0);
    try std.testing.expect(a.intermediateWithX(Vec3.init(3.16e-4, 0, 0), 1.58e-4) == null);
    try std.testing.expect(a.intermediateWithX(Vec3.init(3.17e-4, 0, 0), 1.585e-4) != null);
}

test "each intermediate axis reads its own component" {
    const a = Vec3.init(0, 0, 0);
    const b = Vec3.init(10, 20, 40);

    const on_x = a.intermediateWithX(b, 5.0).?;
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), on_x.x, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), on_x.y, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 20.0), on_x.z, 1.0e-9);

    const on_z = a.intermediateWithZ(b, 10.0).?;
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), on_z.x, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), on_z.y, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), on_z.z, 1.0e-9);

    try std.testing.expect(a.intermediateWithX(b, 20.0) == null);
    try std.testing.expect(a.intermediateWithZ(b, -1.0) == null);
}

test "distanceTo and lengthSquared agree with each other" {
    const a = Vec3.init(1.5, -2.0, 0.75);
    const b = Vec3.init(-0.25, 3.0, 4.0);

    try std.testing.expectApproxEqAbs(b.sub(a).length(), a.distanceTo(b), 1.0e-6);
    try std.testing.expectApproxEqAbs(a.distanceSquaredTo(b), b.distanceSquaredTo(a), 1.0e-9);
    try std.testing.expectApproxEqAbs(b.sub(a).lengthSquared(), a.distanceSquaredTo(b), 1.0e-9);
}

test "dot and lengthSquared sum left to right like the reference" {
    var i: u32 = 1;
    while (i < 2000) : (i += 1) {
        const f: f64 = @floatFromInt(i);
        const v = Vec3.init(f * 0.017, f * -2.3033, f * 0.9111);
        const w = Vec3.init(f * 0.7, f * 1.13, f * -0.31);

        try std.testing.expectEqual((v.x * v.x + v.y * v.y) + v.z * v.z, v.lengthSquared());
        try std.testing.expectEqual((v.x * w.x + v.y * w.y) + v.z * w.z, v.dot(w));
        try std.testing.expectEqual(
            ((w.x - v.x) * (w.x - v.x) + (w.y - v.y) * (w.y - v.y)) + (w.z - v.z) * (w.z - v.z),
            v.distanceSquaredTo(w),
        );
    }
}
