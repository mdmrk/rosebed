const std = @import("std");
const math = @import("math");

pub const Color = [3]f32;

fn dayFactor(celestial_angle: f32) f32 {
    return std.math.clamp(math.util.cos(celestial_angle * std.math.pi * 2.0) * 2.0 + 0.5, 0.0, 1.0);
}

fn level(value: f32) u8 {
    return @intFromFloat(value * 255.0 + 0.5);
}

fn hsbToRgb(hue: f32, saturation: f32, brightness: f32) [3]u8 {
    if (saturation == 0.0) {
        const gray = level(brightness);
        return .{ gray, gray, gray };
    }

    const wrapped = (hue - @floor(hue)) * 6.0;
    const fraction = wrapped - @floor(wrapped);
    const p = brightness * (1.0 - saturation);
    const q = brightness * (1.0 - saturation * fraction);
    const t = brightness * (1.0 - saturation * (1.0 - fraction));

    return switch (@as(u3, @intFromFloat(wrapped))) {
        0 => .{ level(brightness), level(t), level(p) },
        1 => .{ level(q), level(brightness), level(p) },
        2 => .{ level(p), level(brightness), level(t) },
        3 => .{ level(p), level(q), level(brightness) },
        4 => .{ level(t), level(p), level(brightness) },
        else => .{ level(brightness), level(p), level(q) },
    };
}

pub fn skyColorByTemp(temperature: f32) [3]u8 {
    const scaled = std.math.clamp(temperature / 3.0, -1.0, 1.0);
    return hsbToRgb(224.0 / 360.0 - scaled * 0.05, 0.5 + scaled * 0.1, 1.0);
}

pub fn skyColor(temperature: f32, celestial_angle: f32) Color {
    const rgb = skyColorByTemp(temperature);
    const factor = dayFactor(celestial_angle);
    return .{
        @as(f32, @floatFromInt(rgb[0])) / 255.0 * factor,
        @as(f32, @floatFromInt(rgb[1])) / 255.0 * factor,
        @as(f32, @floatFromInt(rgb[2])) / 255.0 * factor,
    };
}

pub fn fogColor(celestial_angle: f32) Color {
    const factor = dayFactor(celestial_angle);
    return .{
        192.0 / 255.0 * (factor * 0.94 + 0.06),
        216.0 / 255.0 * (factor * 0.94 + 0.06),
        factor * 0.91 + 0.09,
    };
}

pub fn farPlaneDistance(render_distance: u2) f32 {
    return @floatFromInt(@as(u32, 256) >> render_distance);
}

pub fn blendedFogColor(sky: Color, fog: Color, render_distance: u2) Color {
    const near_fraction = 1.0 / @as(f32, @floatFromInt(4 - @as(u32, render_distance)));
    const weight = 1.0 - std.math.pow(f32, near_fraction, 0.25);
    return .{
        fog[0] + (sky[0] - fog[0]) * weight,
        fog[1] + (sky[1] - fog[1]) * weight,
        fog[2] + (sky[2] - fog[2]) * weight,
    };
}

test "skyColorByTemp matches java.awt.Color.getHSBColor for the vanilla temperature range" {
    try std.testing.expectEqual([3]u8{ 0x80, 0xa1, 0xff }, skyColorByTemp(0.0));
    try std.testing.expectEqual([3]u8{ 0x7e, 0xa3, 0xff }, skyColorByTemp(0.2));
    try std.testing.expectEqual([3]u8{ 0x7c, 0xa4, 0xff }, skyColorByTemp(0.4));
    try std.testing.expectEqual([3]u8{ 0x7b, 0xa5, 0xff }, skyColorByTemp(0.5));
    try std.testing.expectEqual([3]u8{ 0x7a, 0xa6, 0xff }, skyColorByTemp(0.6));
    try std.testing.expectEqual([3]u8{ 0x79, 0xa7, 0xff }, skyColorByTemp(0.8));
    try std.testing.expectEqual([3]u8{ 0x77, 0xa9, 0xff }, skyColorByTemp(1.0));
}

test "fogColor at noon matches WorldProvider's daylight value" {
    const fog = fogColor(0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.752941191), fog[0], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.847058833), fog[1], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), fog[2], 1.0e-6);
}

test "a shorter render distance pulls the horizon closer and leaves less sky in the fog" {
    try std.testing.expectEqual(@as(f32, 256.0), farPlaneDistance(0));
    try std.testing.expectEqual(@as(f32, 32.0), farPlaneDistance(3));

    const sky: Color = .{ 0.0, 0.0, 0.0 };
    const fog: Color = .{ 1.0, 1.0, 1.0 };
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), blendedFogColor(sky, fog, 3)[0], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.7071068), blendedFogColor(sky, fog, 0)[0], 1.0e-6);
}
