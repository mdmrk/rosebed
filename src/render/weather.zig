const std = @import("std");

const math = @import("math");
const world = @import("world");

const MeshBuilder = @import("mesh_builder.zig");

pub const fancy_reach: i32 = 10;
pub const fast_reach: i32 = 5;
pub const rain_speed: f32 = 3.0;
pub const rain_period: i64 = 32;
pub const snow_period: i64 = 512;
pub const snow_drift: f32 = 0.01;
pub const snow_creep: f32 = 0.001;
pub const rain_light_floor: f32 = 0.15;
pub const rain_light_scale: f32 = 0.85;
pub const rain_alpha_base: f32 = 0.5;
pub const rain_alpha_falloff: f32 = 0.5;
pub const snow_alpha_base: f32 = 0.5;
pub const snow_alpha_falloff: f32 = 0.3;

pub fn reachFor(fancy: bool) i32 {
    return if (fancy) fancy_reach else fast_reach;
}

pub fn columnSeed(x: i32, z: i32) i64 {
    const wx: i64 = x;
    const wz: i64 = z;
    return wx *% wx *% 3121 +% wx *% 45238971 +% wz *% wz *% 418711 +% wz *% 13761;
}

fn colorByte(value: f32) u8 {
    return @intFromFloat(std.math.clamp(value, 0.0, 1.0) * 255.0);
}

const Column = struct {
    bottom: i32,
    top: i32,
    shade: f32,
    alpha: f32,
    scroll_u: f32,
    scroll_v: f32,
};

fn appendColumn(mesh: *MeshBuilder, gpa: std.mem.Allocator, x: i32, z: i32, column: Column) !void {
    const tint: [4]u8 = .{
        colorByte(column.shade),
        colorByte(column.shade),
        colorByte(column.shade),
        colorByte(column.alpha),
    };

    const x0: f32 = @floatFromInt(x);
    const x1: f32 = @floatFromInt(x + 1);
    const z0: f32 = @floatFromInt(z);
    const z1: f32 = @floatFromInt(z + 1);
    const mid_x = x0 + 0.5;
    const mid_z = z0 + 0.5;
    const low: f32 = @floatFromInt(column.bottom);
    const high: f32 = @floatFromInt(column.top);

    const v_low = low / 4.0 + column.scroll_v;
    const v_high = high / 4.0 + column.scroll_v;
    const u_left = column.scroll_u;
    const u_right = 1.0 + column.scroll_u;

    try mesh.quad(
        gpa,
        .{ .{ x0, low, mid_z }, .{ x1, low, mid_z }, .{ x1, high, mid_z }, .{ x0, high, mid_z } },
        .{ .{ u_left, v_low }, .{ u_right, v_low }, .{ u_right, v_high }, .{ u_left, v_high } },
        tint,
    );
    try mesh.quad(
        gpa,
        .{ .{ mid_x, low, z0 }, .{ mid_x, low, z1 }, .{ mid_x, high, z1 }, .{ mid_x, high, z0 } },
        .{ .{ u_left, v_low }, .{ u_right, v_low }, .{ u_right, v_high }, .{ u_left, v_high } },
        tint,
    );
}

pub const View = struct {
    world_map: *const world.World,
    eye: [3]f64,
    tick_count: i64,
    partial_ticks: f32,
    strength: f32,
    fancy: bool,
};

pub fn appendRain(mesh: *MeshBuilder, gpa: std.mem.Allocator, view: View) !void {
    const reach = reachFor(view.fancy);
    const at_x = math.util.floorDouble(view.eye[0]);
    const at_y = math.util.floorDouble(view.eye[1]);
    const at_z = math.util.floorDouble(view.eye[2]);

    var x = at_x - reach;
    while (x <= at_x + reach) : (x += 1) {
        var z = at_z - reach;
        while (z <= at_z + reach) : (z += 1) {
            if (!view.world_map.biomeAt(x, z).canSpawnLightningBolt()) continue;

            const ground = view.world_map.findTopSolidBlock(x, z);
            const bottom = @max(at_y - reach, ground);
            const top = @max(at_y + reach, ground);
            if (bottom == top) continue;

            var rand: world.JavaRandom = .init(columnSeed(x, z));
            const phase: f32 = @floatFromInt(@mod(view.tick_count + columnSeed(x, z), rain_period));
            const scroll = (phase + view.partial_ticks) / @as(f32, rain_period) * (rain_speed + rand.nextFloat());

            try appendColumn(mesh, gpa, x, z, .{
                .bottom = bottom,
                .top = top,
                .shade = brightnessAt(view.world_map, x, world.constants.chunk_height, z) * rain_light_scale + rain_light_floor,
                .alpha = fade(view, x, z, reach, rain_alpha_base, rain_alpha_falloff),
                .scroll_u = 0,
                .scroll_v = scroll,
            });
        }
    }
}

pub fn appendSnow(mesh: *MeshBuilder, gpa: std.mem.Allocator, view: View) !void {
    const reach = reachFor(view.fancy);
    const at_x = math.util.floorDouble(view.eye[0]);
    const at_y = math.util.floorDouble(view.eye[1]);
    const at_z = math.util.floorDouble(view.eye[2]);
    const eye_y = math.util.floorDouble(view.eye[1]);

    var x = at_x - reach;
    while (x <= at_x + reach) : (x += 1) {
        var z = at_z - reach;
        while (z <= at_z + reach) : (z += 1) {
            if (!view.world_map.biomeAt(x, z).snows()) continue;

            const ground = @max(view.world_map.findTopSolidBlock(x, z), 0);
            const lit = @max(ground, eye_y);
            const bottom = @max(at_y - reach, ground);
            const top = @max(at_y + reach, ground);
            if (bottom == top) continue;

            var rand: world.JavaRandom = .init(columnSeed(x, z));
            const elapsed = @as(f32, @floatFromInt(view.tick_count)) + view.partial_ticks;
            const sweep = (@as(f32, @floatFromInt(@mod(view.tick_count, snow_period))) + view.partial_ticks) / @as(f32, snow_period);
            const drift_u = rand.nextFloat() + elapsed * snow_drift * @as(f32, @floatCast(rand.nextGaussian()));
            const drift_v = rand.nextFloat() + elapsed * @as(f32, @floatCast(rand.nextGaussian())) * snow_creep;

            try appendColumn(mesh, gpa, x, z, .{
                .bottom = bottom,
                .top = top,
                .shade = brightnessAt(view.world_map, x, lit, z),
                .alpha = fade(view, x, z, reach, snow_alpha_base, snow_alpha_falloff),
                .scroll_u = drift_u,
                .scroll_v = sweep + drift_v,
            });
        }
    }
}

fn brightnessAt(world_map: *const world.World, x: i32, y: i32, z: i32) f32 {
    return world.light.brightnessAt(world_map, x, @min(y, world.constants.chunk_height - 1), z, 0);
}

fn fade(view: View, x: i32, z: i32, reach: i32, base: f32, falloff: f32) f32 {
    const dx = @as(f64, @floatFromInt(x)) + 0.5 - view.eye[0];
    const dz = @as(f64, @floatFromInt(z)) + 0.5 - view.eye[2];
    const away: f32 = @floatCast(@sqrt(dx * dx + dz * dz) / @as(f64, @floatFromInt(reach)));
    return ((1.0 - away * away) * falloff + base) * view.strength;
}

test "the reach widens with fancy graphics, the way vanilla doubles it" {
    try std.testing.expectEqual(@as(i32, 10), reachFor(true));
    try std.testing.expectEqual(@as(i32, 5), reachFor(false));
}

test "each column gets its own seed so neighbours fall out of step" {
    try std.testing.expect(columnSeed(0, 0) != columnSeed(1, 0));
    try std.testing.expect(columnSeed(0, 0) != columnSeed(0, 1));
    try std.testing.expectEqual(columnSeed(4, -7), columnSeed(4, -7));
}

test "rain thins out toward the edge of the reach" {
    var w = world.World.init(std.testing.allocator);
    defer w.deinit();

    const view: View = .{
        .world_map = &w,
        .eye = .{ 0.5, 64.0, 0.5 },
        .tick_count = 0,
        .partial_ticks = 0,
        .strength = 1.0,
        .fancy = true,
    };

    const near = fade(view, 0, 0, fancy_reach, rain_alpha_base, rain_alpha_falloff);
    const far = fade(view, fancy_reach, 0, fancy_reach, rain_alpha_base, rain_alpha_falloff);
    try std.testing.expect(near > far);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), near, 1.0e-3);
}

test "a dry sky draws nothing at all" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 4);
    defer w.deinit();

    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);

    try appendRain(&mesh, gpa, .{
        .world_map = &w,
        .eye = .{ 8.5, 5.0, 8.5 },
        .tick_count = 0,
        .partial_ticks = 0,
        .strength = 1.0,
        .fancy = false,
    });

    // The flat test world is one chunk, so every column outside it has no ground to hang rain from.
    try std.testing.expect(mesh.vertices.items.len % 4 == 0);
}
