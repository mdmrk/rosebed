const std = @import("std");

const JavaRandom = @import("../JavaRandom.zig");
const biome = @import("biome.zig");
const SimplexOctaves = @import("SimplexOctaves.zig");

const Climate = @This();

pub const grid_size = 16;

temperature_noise: SimplexOctaves,
humidity_noise: SimplexOctaves,
blend_noise: SimplexOctaves,

pub fn init(gpa: std.mem.Allocator, world_seed: i64) !Climate {
    var temperature_rand = JavaRandom.init(world_seed *% 9871);
    var humidity_rand = JavaRandom.init(world_seed *% 39811);
    var blend_rand = JavaRandom.init(world_seed *% 543321);
    return .{
        .temperature_noise = try SimplexOctaves.init(gpa, &temperature_rand, 4),
        .humidity_noise = try SimplexOctaves.init(gpa, &humidity_rand, 4),
        .blend_noise = try SimplexOctaves.init(gpa, &blend_rand, 2),
    };
}

pub fn deinit(self: Climate, gpa: std.mem.Allocator) void {
    self.temperature_noise.deinit(gpa);
    self.humidity_noise.deinit(gpa);
    self.blend_noise.deinit(gpa);
}

pub const Sample = struct {
    temperature: [grid_size * grid_size]f64,
    humidity: [grid_size * grid_size]f64,

    pub fn biomeAt(self: *const Sample, x: usize, z: usize) biome.Biome {
        const i = x * grid_size + z;
        return biome.classify(self.temperature[i], self.humidity[i]);
    }
};

fn generate(
    self: Climate,
    comptime size: usize,
    x_offset: i32,
    z_offset: i32,
    temperature_out: *[size * size]f64,
    humidity_out: *[size * size]f64,
) void {
    const fx: f64 = @floatFromInt(x_offset);
    const fz: f64 = @floatFromInt(z_offset);

    const temperature_scale: f64 = @as(f32, 0.025);
    const humidity_scale: f64 = @as(f32, 0.05);
    self.temperature_noise.generateDefault(temperature_out, .{ .x = fx, .y = fz }, .{ .x = size, .y = size }, .{ .x = temperature_scale, .y = temperature_scale }, 0.25);
    self.humidity_noise.generateDefault(humidity_out, .{ .x = fx, .y = fz }, .{ .x = size, .y = size }, .{ .x = humidity_scale, .y = humidity_scale }, 1.0 / 3.0);

    var blend: [size * size]f64 = undefined;
    self.blend_noise.generateDefault(&blend, .{ .x = fx, .y = fz }, .{ .x = size, .y = size }, .{ .x = 0.25, .y = 0.25 }, 0.5882352941176471);

    for (0..size * size) |i| {
        const blended = blend[i] * 1.1 + 0.5;

        var temperature = (temperature_out[i] * 0.15 + 0.7) * 0.99 + blended * 0.01;
        temperature = 1.0 - (1.0 - temperature) * (1.0 - temperature);
        temperature = std.math.clamp(temperature, 0.0, 1.0);

        var humidity = (humidity_out[i] * 0.15 + 0.5) * 0.998 + blended * 0.002;
        humidity = std.math.clamp(humidity, 0.0, 1.0);

        temperature_out[i] = temperature;
        humidity_out[i] = humidity;
    }
}

pub fn sample(self: Climate, x_offset: i32, z_offset: i32) Sample {
    var result: Sample = undefined;
    self.generate(grid_size, x_offset, z_offset, &result.temperature, &result.humidity);
    return result;
}

pub fn temperatureAt(self: Climate, x: i32, z: i32) f64 {
    var temperature: [1]f64 = undefined;
    var humidity: [1]f64 = undefined;
    self.generate(1, x, z, &temperature, &humidity);
    return temperature[0];
}

pub fn biomeAt(self: Climate, x: i32, z: i32) biome.Biome {
    var temperature: [1]f64 = undefined;
    var humidity: [1]f64 = undefined;
    self.generate(1, x, z, &temperature, &humidity);
    return biome.classify(temperature[0], humidity[0]);
}

test "sample produces climate values in range and varies across a chunk" {
    const gpa = std.testing.allocator;
    const climate = try Climate.init(gpa, 1);
    defer climate.deinit(gpa);

    const s = climate.sample(0, 0);
    for (s.temperature) |t| {
        try std.testing.expect(t >= 0.0 and t <= 1.0);
    }
    for (s.humidity) |h| {
        try std.testing.expect(h >= 0.0 and h <= 1.0);
    }

    var any_different = false;
    for (1..grid_size * grid_size) |i| {
        if (s.temperature[i] != s.temperature[0] or s.humidity[i] != s.humidity[0]) any_different = true;
    }
    try std.testing.expect(any_different);
}

test "temperatureAt matches the same position inside a full grid sample" {
    const gpa = std.testing.allocator;
    const climate = try Climate.init(gpa, 1);
    defer climate.deinit(gpa);

    const s = climate.sample(48, -32);
    try std.testing.expectEqual(s.temperature[0], climate.temperatureAt(48, -32));
}

test "different world seeds produce different climate" {
    const gpa = std.testing.allocator;
    const climate_a = try Climate.init(gpa, 1);
    defer climate_a.deinit(gpa);
    const climate_b = try Climate.init(gpa, 2);
    defer climate_b.deinit(gpa);

    const sample_a = climate_a.sample(0, 0);
    const sample_b = climate_b.sample(0, 0);
    try std.testing.expect(sample_a.temperature[0] != sample_b.temperature[0]);
}
