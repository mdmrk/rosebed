const std = @import("std");
const JavaRandom = @import("java_random.zig");
const NoiseGeneratorOctaves2 = @import("noise_simplex_octaves.zig");
const biome = @import("biome.zig");

const Climate = @This();

pub const grid_size = 16;

temperature_noise: NoiseGeneratorOctaves2,
humidity_noise: NoiseGeneratorOctaves2,
blend_noise: NoiseGeneratorOctaves2,

pub fn init(gpa: std.mem.Allocator, world_seed: i64) !Climate {
    var temperature_rand = JavaRandom.init(world_seed *% 9871);
    var humidity_rand = JavaRandom.init(world_seed *% 39811);
    var blend_rand = JavaRandom.init(world_seed *% 543321);
    return .{
        .temperature_noise = try NoiseGeneratorOctaves2.init(gpa, &temperature_rand, 4),
        .humidity_noise = try NoiseGeneratorOctaves2.init(gpa, &humidity_rand, 4),
        .blend_noise = try NoiseGeneratorOctaves2.init(gpa, &blend_rand, 2),
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

    pub fn biomeAt(self: Sample, x: usize, z: usize) biome.Biome {
        const i = x * grid_size + z;
        return biome.classify(self.temperature[i], self.humidity[i]);
    }
};

pub fn sample(self: Climate, x_offset: i32, z_offset: i32) Sample {
    var result: Sample = undefined;
    const fx: f64 = @floatFromInt(x_offset);
    const fz: f64 = @floatFromInt(z_offset);

    self.temperature_noise.generateDefault(&result.temperature, .{ .x = fx, .y = fz }, .{ .x = grid_size, .y = grid_size }, .{ .x = 0.025, .y = 0.025 }, 0.25);
    self.humidity_noise.generateDefault(&result.humidity, .{ .x = fx, .y = fz }, .{ .x = grid_size, .y = grid_size }, .{ .x = 0.05, .y = 0.05 }, 1.0 / 3.0);

    var blend: [grid_size * grid_size]f64 = undefined;
    self.blend_noise.generateDefault(&blend, .{ .x = fx, .y = fz }, .{ .x = grid_size, .y = grid_size }, .{ .x = 0.25, .y = 0.25 }, 0.5882352941176471);

    for (0..grid_size * grid_size) |i| {
        const blended = blend[i] * 1.1 + 0.5;

        var temperature = (result.temperature[i] * 0.15 + 0.7) * 0.99 + blended * 0.01;
        temperature = 1.0 - (1.0 - temperature) * (1.0 - temperature);
        temperature = std.math.clamp(temperature, 0.0, 1.0);

        var humidity = (result.humidity[i] * 0.15 + 0.5) * 0.998 + blended * 0.002;
        humidity = std.math.clamp(humidity, 0.0, 1.0);

        result.temperature[i] = temperature;
        result.humidity[i] = humidity;
    }

    return result;
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
