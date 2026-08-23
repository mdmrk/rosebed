const std = @import("std");

const Mat4 = @This();

m: @Vector(16, f32),

pub const identity: Mat4 = .{ .m = .{
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    0, 0, 0, 1,
} };

pub fn mul(a: Mat4, b: Mat4) Mat4 {
    var r: Mat4 = undefined;
    inline for (0..4) |col| {
        inline for (0..4) |row| {
            var sum: f32 = 0;
            inline for (0..4) |k| {
                sum += a.m[k * 4 + row] * b.m[col * 4 + k];
            }
            r.m[col * 4 + row] = sum;
        }
    }
    return r;
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
    const cells: [16]f32 = m.m;
    var out: [4]f32 = .{ 0, 0, 0, 0 };
    inline for (0..4) |col| {
        inline for (0..4) |row| out[row] += cells[col * 4 + row] * v[col];
    }
    return out;
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
