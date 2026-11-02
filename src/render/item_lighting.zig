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
