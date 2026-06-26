const std = @import("std");

const Mat4 = @This();

m: [16]f32,

pub const identity: Mat4 = .{ .m = .{
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    0, 0, 0, 1,
} };

pub fn mul(a: Mat4, b: Mat4) Mat4 {
    var r: Mat4 = undefined;
    for (0..4) |col| {
        for (0..4) |row| {
            var sum: f32 = 0;
            for (0..4) |k| {
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

fn sub(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

fn cross(a: [3]f32, b: [3]f32) [3]f32 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

fn dot(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

fn normalize(a: [3]f32) [3]f32 {
    const len = @sqrt(dot(a, a));
    return .{ a[0] / len, a[1] / len, a[2] / len };
}

pub fn lookAt(eye: [3]f32, center: [3]f32, up: [3]f32) Mat4 {
    const f = normalize(sub(center, eye));
    const s = normalize(cross(f, up));
    const u = cross(s, f);

    return .{ .m = .{
        s[0],         u[0],         -f[0],       0,
        s[1],         u[1],         -f[1],       0,
        s[2],         u[2],         -f[2],       0,
        -dot(s, eye), -dot(u, eye), dot(f, eye), 1,
    } };
}

pub fn translation(x: f32, y: f32, z: f32) Mat4 {
    var m = identity;
    m.m[12] = x;
    m.m[13] = y;
    m.m[14] = z;
    return m;
}

test "identity composed with itself is still identity" {
    const r = identity.mul(identity);
    try std.testing.expectEqualSlices(f32, &identity.m, &r.m);
}

test "perspective's diagonal terms match the standard formula" {
    const fov: f32 = std.math.pi / 2.0;
    const p = perspective(fov, 1.5, 0.1, 100.0);
    const expected_f = 1.0 / @tan(fov / 2.0);
    try std.testing.expectApproxEqAbs(expected_f / 1.5, p.m[0], 1.0e-5);
    try std.testing.expectApproxEqAbs(expected_f, p.m[5], 1.0e-5);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), p.m[11], 1.0e-6);
}

test "lookAt produces an orthonormal basis" {
    const view = lookAt(.{ 0, 0, 5 }, .{ 0, 0, 0 }, .{ 0, 1, 0 });
    const right: [3]f32 = .{ view.m[0], view.m[1], view.m[2] };
    const upv: [3]f32 = .{ view.m[4], view.m[5], view.m[6] };
    const back: [3]f32 = .{ view.m[8], view.m[9], view.m[10] };
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), dot(right, upv), 1.0e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), dot(right, back), 1.0e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), dot(back, back), 1.0e-5);
}
