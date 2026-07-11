const std = @import("std");
const block = @import("block.zig");
const Block = @import("block.zig").Block;

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

    pub fn topBlock(self: Biome) Block {
        return switch (self) {
            .desert => Block.sand,
            else => Block.grass,
        };
    }

    pub fn fillerBlock(self: Biome) Block {
        return switch (self) {
            .desert => Block.sand,
            else => Block.dirt,
        };
    }
};

fn classifyExact(temperature: f32, humidity: f32) Biome {
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
    const q_temp: i32 = @intFromFloat(temperature * 63.0);
    const q_humidity: i32 = @intFromFloat(humidity * 63.0);
    return classifyExact(@as(f32, @floatFromInt(q_temp)) / 63.0, @as(f32, @floatFromInt(q_humidity)) / 63.0);
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
    try std.testing.expectEqual(Block.sand, Biome.desert.topBlock());
    try std.testing.expectEqual(Block.grass, Biome.forest.topBlock());
}
