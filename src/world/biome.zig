const std = @import("std");
const block = @import("block.zig");

pub const Biome = enum {
    tundra,
    savanna,
    desert,
    swampland,
    taiga,
    shrubland,
    forest,
    plains,
    seasonal_forest,
    rainforest,

    pub fn topBlock(self: Biome) u8 {
        return switch (self) {
            .desert => block.sand,
            else => block.grass,
        };
    }

    pub fn fillerBlock(self: Biome) u8 {
        return switch (self) {
            .desert => block.sand,
            else => block.dirt,
        };
    }
};

fn classifyExact(temperature: f64, humidity: f64) Biome {
    const rainfall = humidity * temperature;
    if (temperature < 0.1) return .tundra;
    if (rainfall < 0.2) {
        if (temperature < 0.5) return .tundra;
        if (temperature < 0.95) return .savanna;
        return .desert;
    }
    if (rainfall > 0.5 and temperature < 0.7) return .swampland;
    if (temperature < 0.5) return .taiga;
    if (temperature < 0.97) {
        if (rainfall < 0.35) return .shrubland;
        return .forest;
    }
    if (rainfall < 0.45) return .plains;
    if (rainfall < 0.9) return .seasonal_forest;
    return .rainforest;
}

pub fn classify(temperature: f64, humidity: f64) Biome {
    const q_temp: f64 = @as(f64, @floatFromInt(@as(i32, @intFromFloat(temperature * 63.0)))) / 63.0;
    const q_humidity: f64 = @as(f64, @floatFromInt(@as(i32, @intFromFloat(humidity * 63.0)))) / 63.0;
    return classifyExact(q_temp, q_humidity);
}

test "cold and dry is tundra" {
    try std.testing.expectEqual(Biome.tundra, classify(0.05, 0.5));
}

test "hot and dry is desert" {
    try std.testing.expectEqual(Biome.desert, classify(0.98, 0.1));
}

test "hot and very wet is rainforest" {
    try std.testing.expectEqual(Biome.rainforest, classify(0.99, 0.99));
}

test "default 0.5/0.5 climate is taiga after quantization" {
    try std.testing.expectEqual(Biome.taiga, classify(0.5, 0.5));
}

test "desert biome tops with sand, others with grass" {
    try std.testing.expectEqual(@as(u8, block.sand), Biome.desert.topBlock());
    try std.testing.expectEqual(@as(u8, block.grass), Biome.forest.topBlock());
}
