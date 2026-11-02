const std = @import("std");

const Block = @import("../block.zig").Block;

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
            .desert => .sand,
            else => .grass,
        };
    }

    pub fn fillerBlock(self: Biome) Block {
        return switch (self) {
            .desert => .sand,
            else => .dirt,
        };
    }

    pub fn snows(self: Biome) bool {
        return switch (self) {
            .tundra, .taiga => true,
            else => false,
        };
    }

    pub fn rains(self: Biome) bool {
        return self != .desert;
    }

    pub fn canSpawnLightningBolt(self: Biome) bool {
        return !self.snows() and self.rains();
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
