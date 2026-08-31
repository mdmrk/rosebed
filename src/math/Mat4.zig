const std = @import("std");

const Mat4 = @This();

m: @Vector(16, f32),

pub const identity: Mat4 = .{ .m = .{
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    0, 0, 0, 1,
} };

const Column = @Vector(4, f32);

fn column(m: Mat4, comptime index: usize) Column {
    return .{ m.m[index * 4], m.m[index * 4 + 1], m.m[index * 4 + 2], m.m[index * 4 + 3] };
}

fn combine(m: Mat4, weights: Column) Column {
    var acc: Column = @splat(0);
    inline for (0..4) |col| acc += column(m, col) * @as(Column, @splat(weights[col]));
    return acc;
}

pub fn mul(a: Mat4, b: Mat4) Mat4 {
    var r: [16]f32 = undefined;
    inline for (0..4) |col| r[col * 4 ..][0..4].* = combine(a, column(b, col));
    return .{ .m = r };
}

pub fn perspective(fov_y_radians: f32, aspect: f32, near: f32, far: f32) Mat4 {
    const f = 1.0 / @tan(fov_y_radians / 2.0);
    var m = [_]f32{0} ** 16;
    m[0] = f / aspect;
    m[5] = f;
    m[10] = (far + near) / (near - far);
    m[11] = -1;
    m[14] = (2 * far * near) / (near - far);
    return .{ .m = m };
}

pub fn rotationX(radians: f32) Mat4 {
    const c = @cos(radians);
    const s = @sin(radians);
    return .{ .m = .{
        1, 0,  0, 0,
        0, c,  s, 0,
        0, -s, c, 0,
        0, 0,  0, 1,
    } };
}

pub fn rotationY(radians: f32) Mat4 {
    const c = @cos(radians);
    const s = @sin(radians);
    return .{ .m = .{
        c, 0, -s, 0,
        0, 1, 0,  0,
        s, 0, c,  0,
        0, 0, 0,  1,
    } };
}

pub fn rotationZ(radians: f32) Mat4 {
    const c = @cos(radians);
    const s = @sin(radians);
    return .{ .m = .{
        c,  s, 0, 0,
        -s, c, 0, 0,
        0,  0, 1, 0,
        0,  0, 0, 1,
    } };
}

pub fn rotationAxis(axis_x: f32, axis_y: f32, axis_z: f32, radians: f32) Mat4 {
    const length = @sqrt(axis_x * axis_x + axis_y * axis_y + axis_z * axis_z);
    if (length == 0.0) return identity;

    const x = axis_x / length;
    const y = axis_y / length;
    const z = axis_z / length;
    const c = @cos(radians);
    const s = @sin(radians);
    const t = 1.0 - c;

    return .{ .m = .{
        t * x * x + c,     t * x * y + s * z, t * x * z - s * y, 0,
        t * x * y - s * z, t * y * y + c,     t * y * z + s * x, 0,
        t * x * z + s * y, t * y * z - s * x, t * z * z + c,     0,
        0,                 0,                 0,                 1,
    } };
}

pub fn scale(x: f32, y: f32, z: f32) Mat4 {
    return .{ .m = .{
        x, 0, 0, 0,
        0, y, 0, 0,
        0, 0, z, 0,
        0, 0, 0, 1,
    } };
}

pub fn translation(x: f32, y: f32, z: f32) Mat4 {
    var m = identity;
    m.m[12] = x;
    m.m[13] = y;
    m.m[14] = z;
    return m;
}

fn transform(m: Mat4, v: [4]f32) [4]f32 {
    return combine(m, v);
}

test "rotationX turns +y toward +z" {
    const r = transform(rotationX(std.math.pi / 2.0), .{ 0, 1, 0, 0 });
    try std.testing.expectApproxEqAbs(@as(f32, 0), r[0], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), r[1], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), r[2], 1.0e-6);
}

test "rotationY turns +z toward +x" {
    const r = transform(rotationY(std.math.pi / 2.0), .{ 0, 0, 1, 0 });
    try std.testing.expectApproxEqAbs(@as(f32, 1), r[0], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), r[1], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), r[2], 1.0e-6);
}

test "rotationZ turns +x toward +y" {
    const r = transform(rotationZ(std.math.pi / 2.0), .{ 1, 0, 0, 0 });
    try std.testing.expectApproxEqAbs(@as(f32, 0), r[0], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), r[1], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), r[2], 1.0e-6);
}

test "a zero rotation is the identity" {
    try std.testing.expectEqual(identity.m, rotationX(0).m);
    try std.testing.expectEqual(identity.m, rotationY(0).m);
    try std.testing.expectEqual(identity.m, rotationZ(0).m);
}

test "identity composed with itself is still identity" {
    const r = identity.mul(identity);
    try std.testing.expectEqual(identity.m, r.m);
}

test "perspective's diagonal terms match the standard formula" {
    const fov: f32 = std.math.pi / 2.0;
    const p = perspective(fov, 1.5, 0.1, 100.0);
    const expected_f = 1.0 / @tan(fov / 2.0);
    try std.testing.expectApproxEqAbs(expected_f / 1.5, p.m[0], 1.0e-5);
    try std.testing.expectApproxEqAbs(expected_f, p.m[5], 1.0e-5);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), p.m[11], 1.0e-6);
}

test "an axis rotation matches the cardinal ones it generalises" {
    const angle: f32 = 0.7;
    const about_x = rotationAxis(1, 0, 0, angle);
    const about_y = rotationAxis(0, 1, 0, angle);
    const about_z = rotationAxis(0, 0, 1, angle);

    inline for (0..16) |i| {
        try std.testing.expectApproxEqAbs(rotationX(angle).m[i], about_x.m[i], 1.0e-6);
        try std.testing.expectApproxEqAbs(rotationY(angle).m[i], about_y.m[i], 1.0e-6);
        try std.testing.expectApproxEqAbs(rotationZ(angle).m[i], about_z.m[i], 1.0e-6);
    }
}

test "an axis rotation normalises the axis it is handed, and ignores a zero one" {
    const unit = rotationAxis(0, 1, 1, 0.5);
    const scaled = rotationAxis(0, 4, 4, 0.5);
    inline for (0..16) |i| try std.testing.expectApproxEqAbs(unit.m[i], scaled.m[i], 1.0e-6);

    try std.testing.expectEqual(identity.m, rotationAxis(0, 0, 0, 0.5).m);
}

test "an axis rotation keeps the axis itself fixed" {
    const spun = rotationAxis(0, 1, 1, 1.3);
    const along = transform(spun, .{ 0, 1, 1, 0 });

    try std.testing.expectApproxEqAbs(@as(f32, 0.0), along[0], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), along[1], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), along[2], 1.0e-6);
}

test "mul matches a hand-computed product" {
    const a: Mat4 = .{ .m = .{
        0.1, 0.5, 0.9, 1.3,
        0.2, 0.6, 1.0, 1.4,
        0.3, 0.7, 1.1, 1.5,
        0.4, 0.8, 1.2, 1.6,
    } };
    const b: Mat4 = .{ .m = .{
        1.7, 2.1, 2.5, 2.9,
        1.8, 2.2, 2.6, 3.0,
        1.9, 2.3, 2.7, 3.1,
        2.0, 2.4, 2.8, 3.2,
    } };
    const expected = [16]f32{
        2.5, 6.18, 9.86,  13.54,
        2.6, 6.44, 10.28, 14.12,
        2.7, 6.70, 10.70, 14.70,
        2.8, 6.96, 11.12, 15.28,
    };

    const c = a.mul(b);
    inline for (0..16) |i| try std.testing.expectApproxEqAbs(expected[i], c.m[i], 1.0e-4);
}

test "mul composes transforms right to left" {
    const a = rotationZ(0.6);
    const b = translation(2, -3, 5);
    const v = [4]f32{ 1, 2, 3, 1 };

    const combined = transform(a.mul(b), v);
    const stepwise = transform(a, transform(b, v));
    inline for (0..4) |i| try std.testing.expectApproxEqAbs(stepwise[i], combined[i], 1.0e-5);
}

test "identity is a unit on both sides of mul" {
    const m = rotationY(0.4).mul(translation(1, 2, 3));
    inline for (0..16) |i| {
        try std.testing.expectApproxEqAbs(m.m[i], identity.mul(m).m[i], 1.0e-6);
        try std.testing.expectApproxEqAbs(m.m[i], m.mul(identity).m[i], 1.0e-6);
    }
}

test "an opposite rotation undoes a rotation" {
    const angle: f32 = 0.9;
    inline for (.{ rotationX, rotationY, rotationZ }) |rotate| {
        const round_trip = rotate(angle).mul(rotate(-angle));
        inline for (0..16) |i| try std.testing.expectApproxEqAbs(identity.m[i], round_trip.m[i], 1.0e-6);
    }

    const spun = rotationAxis(0.3, 1.0, -0.7, 1.4).mul(rotationAxis(0.3, 1.0, -0.7, -1.4));
    inline for (0..16) |i| try std.testing.expectApproxEqAbs(identity.m[i], spun.m[i], 1.0e-6);
}

test "rotations preserve length" {
    const v = [4]f32{ 0.3, -1.7, 2.2, 0 };
    const before = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);

    inline for (.{ rotationX, rotationY, rotationZ }) |rotate| {
        const r = transform(rotate(1.1), v);
        try std.testing.expectApproxEqAbs(before, @sqrt(r[0] * r[0] + r[1] * r[1] + r[2] * r[2]), 1.0e-5);
    }

    const s = transform(rotationAxis(1, -2, 0.5, 1.1), v);
    try std.testing.expectApproxEqAbs(before, @sqrt(s[0] * s[0] + s[1] * s[1] + s[2] * s[2]), 1.0e-5);
}

test "translation and scale sit in the columns OpenGL expects" {
    const moved = transform(translation(2, -3, 5), .{ 1, 1, 1, 1 });
    try std.testing.expectApproxEqAbs(@as(f32, 3), moved[0], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -2), moved[1], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 6), moved[2], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), moved[3], 1.0e-6);

    const stretched = transform(scale(2, 3, 4), .{ 1, 1, 1, 1 });
    try std.testing.expectApproxEqAbs(@as(f32, 2), stretched[0], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 3), stretched[1], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 4), stretched[2], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), stretched[3], 1.0e-6);
}

test "perspective maps the near and far planes onto the depth range" {
    const near: f32 = 0.05;
    const far: f32 = 1000.0;
    const p = perspective(70.0 * std.math.pi / 180.0, 16.0 / 9.0, near, far);

    const at_near = transform(p, .{ 0, 0, -near, 1 });
    try std.testing.expectApproxEqAbs(near, at_near[3], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), at_near[2] / at_near[3], 1.0e-4);

    const at_far = transform(p, .{ 0, 0, -far, 1 });
    try std.testing.expectApproxEqAbs(far, at_far[3], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), at_far[2] / at_far[3], 1.0e-4);
}

test "a full turn about an axis is the identity" {
    const full = rotationAxis(0.3, 1.0, -0.7, 2.0 * std.math.pi);
    inline for (0..16) |i| try std.testing.expectApproxEqAbs(identity.m[i], full.m[i], 1.0e-6);
}
