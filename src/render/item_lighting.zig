const std = @import("std");

const math = @import("math");

pub const ambient: f32 = 0.4;
pub const diffuse: f32 = 0.6;

pub fn normalized(v: [3]f32) [3]f32 {
    const length = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    return .{ v[0] / length, v[1] / length, v[2] / length };
}

const directions: [2][3]f32 = .{
    normalized(.{ 0.2, 1.0, -0.7 }),
    normalized(.{ -0.2, 1.0, 0.7 }),
};

pub fn shade(normal: [3]f32) f32 {
    var lit = ambient;
    for (directions) |direction| {
        const facing = normal[0] * direction[0] + normal[1] * direction[1] + normal[2] * direction[2];
        lit += diffuse * @max(0.0, facing);
    }
    return lit;
}

pub const unrotated: [3][3]f32 = .{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } };

pub const Lit = struct {
    orient: [3][3]f32 = unrotated,
    material: [4]u8 = .{ 255, 255, 255, 255 },
};

pub fn material(brightness: f32, tint: [3]f32) [4]u8 {
    var color: [4]u8 = .{ 0, 0, 0, 255 };
    for (0..3) |channel| {
        color[channel] = @intFromFloat(@min(255.0, brightness * tint[channel] * 255.0));
    }
    return color;
}

pub fn orientOf(matrix: math.Mat4) [3][3]f32 {
    var orient: [3][3]f32 = undefined;
    inline for (0..3) |row| {
        inline for (0..3) |col| orient[row][col] = matrix.m[col * 4 + row];
    }
    return orient;
}

pub fn turned(orient: [3][3]f32, v: [3]f32) [3]f32 {
    return .{
        orient[0][0] * v[0] + orient[0][1] * v[1] + orient[0][2] * v[2],
        orient[1][0] * v[0] + orient[1][1] * v[1] + orient[1][2] * v[2],
        orient[2][0] * v[0] + orient[2][1] * v[1] + orient[2][2] * v[2],
    };
}

pub fn shaded(color: [4]u8, amount: f32) [4]u8 {
    var out = color;
    for (0..3) |channel| {
        out[channel] = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(color[channel])) * amount));
    }
    return out;
}

pub fn faceColor(lit: Lit, normal: [3]f32) [4]u8 {
    return shaded(lit.material, shade(normalized(turned(lit.orient, normal))));
}

test "the two lamps of RenderHelper's standard item lighting shade each facing" {
    try std.testing.expectApproxEqAbs(@as(f32, 1.3701424), shade(.{ 0, 1, 0 }), 1.0e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), shade(.{ 0, -1, 0 }), 1.0e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.7395496), shade(.{ 0, 0, 1 }), 1.0e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.7395496), shade(.{ 0, 0, -1 }), 1.0e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4970141), shade(.{ 1, 0, 0 }), 1.0e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4970141), shade(.{ -1, 0, 0 }), 1.0e-5);
}

test "a lit face saturates rather than wrapping when the lamps overshoot" {
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, faceColor(.{}, .{ 0, 1, 0 }));
    try std.testing.expectEqual(
        [4]u8{ 102, 102, 102, 255 },
        faceColor(.{}, .{ 0, -1, 0 }),
    );
}

test "a quarter turn about Y swaps which faces the lamps favour" {
    const quarter = orientOf(math.Mat4.rotationY(std.math.pi / 2.0));
    try std.testing.expectApproxEqAbs(
        shade(.{ 0, 0, 1 }),
        shade(normalized(turned(quarter, .{ 1, 0, 0 }))),
        1.0e-5,
    );
}
