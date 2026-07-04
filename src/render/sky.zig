const std = @import("std");
const math = @import("math");
const world = @import("world");

const MeshBuilder = @import("mesh_builder.zig");

pub const Color = [3]f32;

pub const dome_height: f32 = 16.0;
pub const void_height: f32 = -16.0;
pub const sun_radius: f32 = 30.0;
pub const moon_radius: f32 = 20.0;
pub const body_distance: f32 = 100.0;
pub const star_count: u32 = 1500;
pub const star_seed: i64 = 10842;

const plane_step: i32 = 64;
const plane_reach: i32 = plane_step * (256 / plane_step + 2);

const white: [4]u8 = .{ 255, 255, 255, 255 };

fn appendPlane(mesh: *MeshBuilder, gpa: std.mem.Allocator, height: f32, facing_up: bool) !void {
    var x: i32 = -plane_reach;
    while (x <= plane_reach) : (x += plane_step) {
        var z: i32 = -plane_reach;
        while (z <= plane_reach) : (z += plane_step) {
            const x0: f32 = @floatFromInt(x);
            const z0: f32 = @floatFromInt(z);
            const x1: f32 = @floatFromInt(x + plane_step);
            const z1: f32 = @floatFromInt(z + plane_step);
            const corners: [4][3]f32 = if (facing_up) .{
                .{ x0, height, z0 }, .{ x1, height, z0 }, .{ x1, height, z1 }, .{ x0, height, z1 },
            } else .{
                .{ x1, height, z0 }, .{ x0, height, z0 }, .{ x0, height, z1 }, .{ x1, height, z1 },
            };
            try mesh.quad(gpa, corners, .{ .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 } }, white);
        }
    }
}

pub fn appendDome(mesh: *MeshBuilder, gpa: std.mem.Allocator) !void {
    try appendPlane(mesh, gpa, dome_height, true);
}

pub fn appendVoidPlane(mesh: *MeshBuilder, gpa: std.mem.Allocator) !void {
    try appendPlane(mesh, gpa, void_height, false);
}

pub fn appendBody(mesh: *MeshBuilder, gpa: std.mem.Allocator, radius: f32, above: bool) !void {
    const y: f32 = if (above) body_distance else -body_distance;
    const corners: [4][3]f32 = if (above) .{
        .{ -radius, y, -radius }, .{ radius, y, -radius }, .{ radius, y, radius }, .{ -radius, y, radius },
    } else .{
        .{ -radius, y, radius }, .{ radius, y, radius }, .{ radius, y, -radius }, .{ -radius, y, -radius },
    };
    const uvs: [4][2]f32 = if (above) .{
        .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 },
    } else .{
        .{ 1, 1 }, .{ 0, 1 }, .{ 0, 0 }, .{ 1, 0 },
    };
    try mesh.quad(gpa, corners, uvs, white);
}

pub fn appendStars(mesh: *MeshBuilder, gpa: std.mem.Allocator) !void {
    var rand = world.JavaRandom.init(star_seed);

    for (0..star_count) |_| {
        var x: f64 = @as(f64, rand.nextFloat()) * 2.0 - 1.0;
        var y: f64 = @as(f64, rand.nextFloat()) * 2.0 - 1.0;
        var z: f64 = @as(f64, rand.nextFloat()) * 2.0 - 1.0;
        const size: f64 = 0.25 + @as(f64, rand.nextFloat()) * 0.25;
        const length_squared = x * x + y * y + z * z;
        if (length_squared >= 1.0 or length_squared <= 0.01) continue;

        const scale = 1.0 / @sqrt(length_squared);
        x *= scale;
        y *= scale;
        z *= scale;
        const center_x = x * 100.0;
        const center_y = y * 100.0;
        const center_z = z * 100.0;

        const yaw = std.math.atan2(x, z);
        const sin_yaw = @sin(yaw);
        const cos_yaw = @cos(yaw);
        const pitch = std.math.atan2(@sqrt(x * x + z * z), y);
        const sin_pitch = @sin(pitch);
        const cos_pitch = @cos(pitch);
        const spin = rand.nextDouble() * std.math.pi * 2.0;
        const sin_spin = @sin(spin);
        const cos_spin = @cos(spin);

        var corners: [4][3]f32 = undefined;
        for (0..4) |corner| {
            const offset_a = @as(f64, @floatFromInt((@as(i32, @intCast(corner)) & 2) - 1)) * size;
            const offset_b = @as(f64, @floatFromInt((@as(i32, @intCast(corner)) + 1 & 2) - 1)) * size;
            const spun_a = offset_a * cos_spin - offset_b * sin_spin;
            const spun_b = offset_b * cos_spin + offset_a * sin_spin;
            const tilted = spun_a * sin_pitch;
            const depth = -spun_a * cos_pitch;
            corners[corner] = .{
                @floatCast(center_x + depth * sin_yaw - spun_b * cos_yaw),
                @floatCast(center_y + tilted),
                @floatCast(center_z + spun_b * sin_yaw + depth * cos_yaw),
            };
        }
        try mesh.quad(gpa, corners, .{ .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 } }, white);
    }
}

pub const Sunrise = struct { color: [4]f32, angle: f32 };

pub fn sunriseColors(celestial_angle: f32) ?Sunrise {
    const reach: f32 = 0.4;
    const height = math.util.cos(celestial_angle * std.math.pi * 2.0);
    if (height < -reach or height > reach) return null;

    const position = height / reach * 0.5 + 0.5;
    var alpha = 1.0 - (1.0 - math.util.sin(position * std.math.pi)) * 0.99;
    alpha *= alpha;
    return .{
        .color = .{
            position * 0.3 + 0.7,
            position * position * 0.7 + 0.2,
            position * position * 0.0 + 0.2,
            alpha,
        },
        .angle = celestial_angle,
    };
}

pub fn appendSunriseGlow(mesh: *MeshBuilder, gpa: std.mem.Allocator, sunrise: Sunrise) !void {
    const segments = 16;
    const center: [4]u8 = .{
        level(sunrise.color[0]),
        level(sunrise.color[1]),
        level(sunrise.color[2]),
        level(sunrise.color[3]),
    };
    const rim: [4]u8 = .{ center[0], center[1], center[2], 0 };

    for (0..segments) |segment| {
        const first = @as(f32, @floatFromInt(segment)) * std.math.pi * 2.0 / segments;
        const second = @as(f32, @floatFromInt(segment + 1)) * std.math.pi * 2.0 / segments;
        const points = [2]f32{ first, second };
        var edge: [2][3]f32 = undefined;
        for (points, 0..) |theta, i| {
            const sin = math.util.sin(theta);
            const cos = math.util.cos(theta);
            edge[i] = .{ sin * 120.0, cos * 120.0, -cos * 40.0 * sunrise.color[3] };
        }
        try mesh.quadShaded(
            gpa,
            .{ .{ 0, 100, 0 }, edge[0], edge[1], edge[1] },
            .{ .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 } },
            .{ center, rim, rim, rim },
        );
    }
}

pub fn starBrightness(celestial_angle: f32) f32 {
    const visibility = std.math.clamp(1.0 - (math.util.cos(celestial_angle * std.math.pi * 2.0) * 2.0 + 12.0 / 16.0), 0.0, 1.0);
    return visibility * visibility * 0.5;
}

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

test "the sky planes cover the original's grid extent" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);

    try appendDome(&mesh, gpa);
    const span = 2 * plane_reach / plane_step + 1;
    try std.testing.expectEqual(@as(usize, @intCast(span * span * 4)), mesh.vertices.items.len);

    var lowest: f32 = std.math.floatMax(f32);
    var highest: f32 = -std.math.floatMax(f32);
    for (mesh.vertices.items) |v| {
        lowest = @min(lowest, v.x);
        highest = @max(highest, v.x);
        try std.testing.expectEqual(dome_height, v.y);
    }
    try std.testing.expectEqual(@as(f32, -@as(f32, plane_reach)), lowest);
    try std.testing.expectEqual(@as(f32, @as(f32, plane_reach) + plane_step), highest);
}

test "stars land on a sphere of radius 100 and are fewer than the attempts" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);

    try appendStars(&mesh, gpa);

    const drawn = mesh.vertices.items.len / 4;
    try std.testing.expect(drawn > 0);
    try std.testing.expect(drawn < star_count);

    for (mesh.vertices.items) |v| {
        const distance = @sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
        try std.testing.expect(distance > 95.0 and distance < 105.0);
    }
}

test "the sunrise glow only appears near dawn and dusk" {
    try std.testing.expect(sunriseColors(0.0) == null);
    try std.testing.expect(sunriseColors(0.5) == null);
    try std.testing.expect(sunriseColors(0.25) != null);
    try std.testing.expect(sunriseColors(0.75) != null);

    const dawn = sunriseColors(0.25).?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.85), dawn.color[0], 1.0e-3);
    try std.testing.expect(dawn.color[3] > 0.0 and dawn.color[3] <= 1.0);
}

test "stars are invisible by day and brightest at midnight" {
    try std.testing.expectEqual(@as(f32, 0.0), starBrightness(0.0));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), starBrightness(0.5), 1.0e-4);
    try std.testing.expect(starBrightness(0.25) < 0.5);
}
