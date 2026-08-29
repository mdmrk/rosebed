const std = @import("std");

const gl = @import("gl");
const math = @import("math");

pub const Pass = ?u1;

const projection_shift: f32 = 0.07;
const view_shift: f32 = 0.1;

fn eyeSign(eye: u1) f32 {
    return if (eye == 0) -1.0 else 1.0;
}

pub fn tint(enabled: bool, rgb: [3]u8) [3]u8 {
    if (!enabled) return rgb;
    const r: u32 = rgb[0];
    const g: u32 = rgb[1];
    const b: u32 = rgb[2];
    return .{
        @intCast((r * 30 + g * 59 + b * 11) / 100),
        @intCast((r * 30 + g * 70) / 100),
        @intCast((r * 30 + b * 70) / 100),
    };
}

pub fn color(enabled: bool, rgb: [3]f32) [3]f32 {
    if (!enabled) return rgb;
    return .{
        (rgb[0] * 30.0 + rgb[1] * 59.0 + rgb[2] * 11.0) / 100.0,
        (rgb[0] * 30.0 + rgb[1] * 70.0) / 100.0,
        (rgb[0] * 30.0 + rgb[2] * 70.0) / 100.0,
    };
}

pub fn pixels(enabled: bool, rgba: []u8) void {
    if (!enabled) return;
    var offset: usize = 0;
    while (offset + 4 <= rgba.len) : (offset += 4) {
        rgba[offset..][0..3].* = tint(true, rgba[offset..][0..3].*);
    }
}

pub fn projection(pass: Pass, proj: math.Mat4) math.Mat4 {
    const eye = pass orelse return proj;
    return math.Mat4.translation(-eyeSign(eye) * projection_shift, 0, 0).mul(proj);
}

pub fn view(pass: Pass, model: math.Mat4) math.Mat4 {
    const eye = pass orelse return model;
    return math.Mat4.translation(eyeSign(eye) * view_shift, 0, 0).mul(model);
}

pub fn beginPass(pass: Pass) void {
    const eye = pass orelse {
        gl.ColorMask(gl.TRUE, gl.TRUE, gl.TRUE, gl.TRUE);
        return;
    };
    if (eye == 0) {
        gl.ColorMask(gl.FALSE, gl.TRUE, gl.TRUE, gl.FALSE);
    } else {
        gl.ColorMask(gl.TRUE, gl.FALSE, gl.FALSE, gl.FALSE);
    }
}

pub fn restoreMask(pass: Pass) void {
    const eye = pass orelse {
        gl.ColorMask(gl.TRUE, gl.TRUE, gl.TRUE, gl.TRUE);
        return;
    };
    if (eye == 0) {
        gl.ColorMask(gl.FALSE, gl.TRUE, gl.TRUE, gl.TRUE);
    } else {
        gl.ColorMask(gl.TRUE, gl.FALSE, gl.FALSE, gl.TRUE);
    }
}

pub fn endPasses() void {
    gl.ColorMask(gl.TRUE, gl.TRUE, gl.TRUE, gl.FALSE);
}

test "grey stays put and a saturated colour spreads across the channels" {
    try std.testing.expectEqual([3]u8{ 255, 255, 255 }, tint(true, .{ 255, 255, 255 }));
    try std.testing.expectEqual([3]u8{ 0, 0, 0 }, tint(true, .{ 0, 0, 0 }));
    try std.testing.expectEqual([3]u8{ 76, 76, 76 }, tint(true, .{ 255, 0, 0 }));
    try std.testing.expectEqual([3]u8{ 150, 178, 0 }, tint(true, .{ 0, 255, 0 }));
}

test "disabled conversion hands the colour back untouched" {
    try std.testing.expectEqual([3]u8{ 12, 34, 56 }, tint(false, .{ 12, 34, 56 }));
    try std.testing.expectEqual([3]f32{ 0.25, 0.5, 0.75 }, color(false, .{ 0.25, 0.5, 0.75 }));
}

test "the float and byte conversions agree" {
    const converted = color(true, .{ 1.0, 0.0, 0.0 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), converted[0], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), converted[1], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), converted[2], 1.0e-6);
}

test "every pixel of an image is converted, alpha untouched" {
    var image = [_]u8{ 255, 0, 0, 200, 0, 0, 255, 100 };
    pixels(true, &image);
    try std.testing.expectEqual([_]u8{ 76, 76, 76, 200, 28, 0, 178, 100 }, image);
}

test "the two eyes shift the camera opposite ways" {
    const left = view(0, math.Mat4.identity);
    const right = view(1, math.Mat4.identity);
    try std.testing.expectApproxEqAbs(@as(f32, -0.1), left.m[12], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), right.m[12], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.07), projection(0, math.Mat4.identity).m[12], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -0.07), projection(1, math.Mat4.identity).m[12], 1.0e-6);
}

test "with anaglyph off the camera is left alone" {
    try std.testing.expectEqual(math.Mat4.identity.m, view(null, math.Mat4.identity).m);
    try std.testing.expectEqual(math.Mat4.identity.m, projection(null, math.Mat4.identity).m);
}
