const std = @import("std");

pub const air: u8 = 0;
pub const stone: u8 = 1;
pub const grass: u8 = 2;
pub const dirt: u8 = 3;
pub const bedrock: u8 = 7;
pub const stationary_water: u8 = 9;
pub const flowing_lava: u8 = 10;
pub const sand: u8 = 12;
pub const gravel: u8 = 13;
pub const ore_gold: u8 = 14;
pub const ore_iron: u8 = 15;
pub const ore_coal: u8 = 16;
pub const log: u8 = 17;
pub const leaves: u8 = 18;
pub const ore_lapis: u8 = 21;
pub const ore_diamond: u8 = 56;
pub const ore_redstone: u8 = 73;
pub const clay: u8 = 82;
pub const tall_grass: u8 = 31;
pub const dead_bush: u8 = 32;
pub const dandelion: u8 = 37;
pub const rose: u8 = 38;
pub const mushroom_brown: u8 = 39;
pub const mushroom_red: u8 = 40;
pub const pumpkin: u8 = 86;
pub const reed: u8 = 83;

pub fn isCross(id: u8) bool {
    return id == tall_grass or id == dead_bush or id == dandelion or id == rose or
        id == mushroom_brown or id == mushroom_red or id == reed;
}

pub fn isOpaque(id: u8) bool {
    return id != air and !isCross(id);
}

pub fn isLiquid(id: u8) bool {
    return id == stationary_water or id == flowing_lava;
}

pub fn logSideTile(metadata: u4) u8 {
    return switch (metadata) {
        1 => 116,
        2 => 117,
        else => 20,
    };
}

pub fn crossTile(id: u8, metadata: u4) u8 {
    return switch (id) {
        tall_grass => if (metadata == 2) 56 else 39,
        dead_bush => 55,
        dandelion => 13,
        rose => 12,
        mushroom_brown => 29,
        mushroom_red => 28,
        reed => 73,
        else => 0,
    };
}

pub const down = 0;
pub const up = 1;
pub const north = 2;
pub const south = 3;
pub const west = 4;
pub const east = 5;

pub fn faceTextures(id: u8) [6]u8 {
    return switch (id) {
        stone => .{ 1, 1, 1, 1, 1, 1 },
        grass => .{ 2, 0, 3, 3, 3, 3 },
        dirt => .{ 2, 2, 2, 2, 2, 2 },
        bedrock => .{ 17, 17, 17, 17, 17, 17 },
        stationary_water => .{ 205, 205, 205, 205, 205, 205 },
        flowing_lava => .{ 237, 237, 237, 237, 237, 237 },
        sand => .{ 18, 18, 18, 18, 18, 18 },
        gravel => .{ 19, 19, 19, 19, 19, 19 },
        ore_gold => .{ 32, 32, 32, 32, 32, 32 },
        ore_iron => .{ 33, 33, 33, 33, 33, 33 },
        ore_coal => .{ 34, 34, 34, 34, 34, 34 },
        log => .{ 21, 21, 20, 20, 20, 20 },
        leaves => .{ 52, 52, 52, 52, 52, 52 },
        ore_lapis => .{ 160, 160, 160, 160, 160, 160 },
        ore_diamond => .{ 50, 50, 50, 50, 50, 50 },
        ore_redstone => .{ 51, 51, 51, 51, 51, 51 },
        clay => .{ 72, 72, 72, 72, 72, 72 },
        pumpkin => .{ 102, 102, 118, 118, 118, 118 },
        else => .{ 0, 0, 0, 0, 0, 0 },
    };
}

fn hardness(id: u8) f32 {
    return switch (id) {
        stone => 1.5,
        grass => 0.6,
        dirt => 0.5,
        bedrock => -1.0,
        stationary_water => 100.0,
        flowing_lava => 0.0,
        sand => 0.5,
        gravel => 0.6,
        ore_gold, ore_iron, ore_coal, ore_lapis, ore_diamond, ore_redstone => 3.0,
        log => 2.0,
        leaves => 0.2,
        clay => 0.6,
        pumpkin => 1.0,
        else => 0.0,
    };
}

fn isHarvestableByHand(id: u8) bool {
    return switch (id) {
        stone, ore_gold, ore_iron, ore_coal, ore_lapis, ore_diamond, ore_redstone => false,
        else => true,
    };
}

pub fn digTicksRequired(id: u8) ?f32 {
    const h = hardness(id);
    if (h < 0.0) return null;
    const divisor: f32 = if (isHarvestableByHand(id)) 30.0 else 100.0;
    return h * divisor;
}

test "digTicksRequired matches hardness*30 for hand-harvestable blocks" {
    try std.testing.expectApproxEqAbs(@as(f32, 15.0), digTicksRequired(dirt).?, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 60.0), digTicksRequired(log).?, 1.0e-6);
}

test "digTicksRequired matches hardness*100 for blocks needing a tool" {
    try std.testing.expectApproxEqAbs(@as(f32, 150.0), digTicksRequired(stone).?, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 300.0), digTicksRequired(ore_diamond).?, 1.0e-6);
}

test "bedrock is unbreakable" {
    try std.testing.expect(digTicksRequired(bedrock) == null);
}

test "grass has a distinct top, bottom and side texture" {
    const textures = faceTextures(grass);
    try std.testing.expectEqual(@as(u8, 0), textures[up]);
    try std.testing.expectEqual(@as(u8, 2), textures[down]);
    try std.testing.expectEqual(@as(u8, 3), textures[north]);
    try std.testing.expectEqual(@as(u8, 3), textures[east]);
}

test "air and cross-shaped plants are the only non-opaque blocks" {
    try std.testing.expect(!isOpaque(air));
    try std.testing.expect(!isOpaque(tall_grass));
    try std.testing.expect(isOpaque(stone));
    try std.testing.expect(isOpaque(bedrock));
}

test "tall grass picks the fern tile only at metadata 2" {
    try std.testing.expectEqual(@as(u8, 39), crossTile(tall_grass, 1));
    try std.testing.expectEqual(@as(u8, 56), crossTile(tall_grass, 2));
}

test "log side texture varies by wood type metadata" {
    try std.testing.expectEqual(@as(u8, 20), logSideTile(0));
    try std.testing.expectEqual(@as(u8, 116), logSideTile(1));
    try std.testing.expectEqual(@as(u8, 117), logSideTile(2));
}
