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
