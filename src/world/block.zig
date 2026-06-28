const std = @import("std");
const JavaRandom = @import("java_random.zig");
const item = @import("item.zig");

pub const air: u8 = 0;
pub const stone: u8 = 1;
pub const grass: u8 = 2;
pub const dirt: u8 = 3;
pub const sapling: u8 = 6;
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
pub const snow_layer: u8 = 78;
pub const cobblestone: u8 = 4;
pub const cobblestone_mossy: u8 = 48;
pub const mob_spawner: u8 = 52;

pub fn isCross(id: u8) bool {
    return id == tall_grass or id == dead_bush or id == dandelion or id == rose or
        id == mushroom_brown or id == mushroom_red or id == reed;
}

pub fn heightScale(id: u8) f32 {
    return if (id == snow_layer) 0.125 else 1.0;
}

pub fn isOpaque(id: u8) bool {
    return id != air and !isCross(id) and id != snow_layer;
}

pub fn isLiquid(id: u8) bool {
    return id == stationary_water or id == flowing_lava;
}

pub fn isFalling(id: u8) bool {
    return id == sand or id == gravel;
}

pub fn canFallInto(id: u8) bool {
    return id == air or isLiquid(id);
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
        snow_layer => .{ 66, 66, 66, 66, 66, 66 },
        cobblestone => .{ 16, 16, 16, 16, 16, 16 },
        cobblestone_mossy => .{ 36, 36, 36, 36, 36, 36 },
        mob_spawner => .{ 65, 65, 65, 65, 65, 65 },
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
        snow_layer => 0.1,
        cobblestone, cobblestone_mossy => 2.0,
        mob_spawner => 5.0,
        else => 0.0,
    };
}

fn isHarvestableByHand(id: u8) bool {
    return switch (id) {
        stone, ore_gold, ore_iron, ore_coal, ore_lapis, ore_diamond, ore_redstone, cobblestone, cobblestone_mossy, mob_spawner => false,
        else => true,
    };
}

pub fn digTicksRequired(id: u8) ?f32 {
    const h = hardness(id);
    if (h < 0.0) return null;
    const divisor: f32 = if (isHarvestableByHand(id)) 30.0 else 100.0;
    return h * divisor;
}

pub const Drop = struct { id: u16, count: u8, meta: u4 = 0 };

pub fn drop(id: u8, meta: u4, rand: *JavaRandom) ?Drop {
    return switch (id) {
        stone => .{ .id = cobblestone, .count = 1 },
        grass => .{ .id = dirt, .count = 1 },
        gravel => if (rand.nextIntBound(10) == 0)
            .{ .id = item.flint, .count = 1 }
        else
            .{ .id = gravel, .count = 1 },
        ore_coal => .{ .id = item.coal, .count = 1 },
        ore_diamond => .{ .id = item.diamond, .count = 1 },
        ore_redstone => .{ .id = item.redstone, .count = @intCast(4 + rand.nextIntBound(2)) },
        ore_lapis => .{ .id = item.dye, .count = @intCast(4 + rand.nextIntBound(5)), .meta = item.dye_meta_lapis },
        log => .{ .id = log, .count = 1, .meta = meta },
        leaves => if (rand.nextIntBound(20) == 0) .{ .id = sapling, .count = 1, .meta = meta & 3 } else null,
        clay => .{ .id = item.clay_ball, .count = 4 },
        tall_grass => if (rand.nextIntBound(8) == 0) .{ .id = item.seeds, .count = 1 } else null,
        dead_bush => null,
        reed => .{ .id = item.reed, .count = 1 },
        snow_layer => .{ .id = item.snowball, .count = 1 },
        mob_spawner => null,
        stationary_water, flowing_lava => null,
        else => .{ .id = id, .count = 1 },
    };
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

test "snow layers are thin and non-opaque, unlike regular blocks" {
    try std.testing.expectEqual(@as(f32, 0.125), heightScale(snow_layer));
    try std.testing.expectEqual(@as(f32, 1.0), heightScale(stone));
    try std.testing.expect(!isOpaque(snow_layer));
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

test "stone drops cobblestone, not itself" {
    var rand = JavaRandom.init(0);
    const dropped = drop(stone, 0, &rand).?;
    try std.testing.expectEqual(@as(u16, cobblestone), dropped.id);
    try std.testing.expectEqual(@as(u8, 1), dropped.count);
}

test "grass drops dirt" {
    var rand = JavaRandom.init(0);
    const dropped = drop(grass, 0, &rand).?;
    try std.testing.expectEqual(@as(u16, dirt), dropped.id);
}

test "ore ids drop their raw item form" {
    var rand = JavaRandom.init(0);
    try std.testing.expectEqual(@as(u16, item.coal), drop(ore_coal, 0, &rand).?.id);
    try std.testing.expectEqual(@as(u16, item.diamond), drop(ore_diamond, 0, &rand).?.id);
}

test "gold and iron ore self-drop, unlike coal/diamond/lapis/redstone" {
    var rand = JavaRandom.init(0);
    try std.testing.expectEqual(@as(u16, ore_gold), drop(ore_gold, 0, &rand).?.id);
    try std.testing.expectEqual(@as(u16, ore_iron), drop(ore_iron, 0, &rand).?.id);
}

test "lapis ore drops 4-8 lapis dye" {
    var rand = JavaRandom.init(0);
    for (0..50) |_| {
        const dropped = drop(ore_lapis, 0, &rand).?;
        try std.testing.expectEqual(@as(u16, item.dye), dropped.id);
        try std.testing.expectEqual(item.dye_meta_lapis, dropped.meta);
        try std.testing.expect(dropped.count >= 4 and dropped.count <= 8);
    }
}

test "redstone ore drops 4-5 redstone" {
    var rand = JavaRandom.init(0);
    for (0..50) |_| {
        const dropped = drop(ore_redstone, 0, &rand).?;
        try std.testing.expectEqual(@as(u16, item.redstone), dropped.id);
        try std.testing.expect(dropped.count >= 4 and dropped.count <= 5);
    }
}

test "log preserves its wood-type metadata when dropped" {
    var rand = JavaRandom.init(0);
    try std.testing.expectEqual(@as(u4, 1), drop(log, 1, &rand).?.meta);
}

test "gravel occasionally drops flint instead of itself" {
    var rand = JavaRandom.init(0);
    var saw_flint = false;
    var saw_gravel = false;
    for (0..200) |_| {
        const dropped = drop(gravel, 0, &rand).?;
        try std.testing.expectEqual(@as(u8, 1), dropped.count);
        if (dropped.id == item.flint) saw_flint = true;
        if (dropped.id == gravel) saw_gravel = true;
    }
    try std.testing.expect(saw_flint);
    try std.testing.expect(saw_gravel);
}

test "leaves rarely drop a sapling, preserving wood type in its metadata" {
    var rand = JavaRandom.init(0);
    var saw_sapling = false;
    var saw_nothing = false;
    for (0..200) |_| {
        if (drop(leaves, 1, &rand)) |dropped| {
            try std.testing.expectEqual(@as(u16, sapling), dropped.id);
            try std.testing.expectEqual(@as(u4, 1), dropped.meta);
            saw_sapling = true;
        } else {
            saw_nothing = true;
        }
    }
    try std.testing.expect(saw_sapling);
    try std.testing.expect(saw_nothing);
}

test "tall grass rarely drops seeds, otherwise nothing" {
    var rand = JavaRandom.init(0);
    var saw_seeds = false;
    var saw_nothing = false;
    for (0..200) |_| {
        if (drop(tall_grass, 0, &rand)) |dropped| {
            try std.testing.expectEqual(@as(u16, item.seeds), dropped.id);
            saw_seeds = true;
        } else {
            saw_nothing = true;
        }
    }
    try std.testing.expect(saw_seeds);
    try std.testing.expect(saw_nothing);
}

test "dead bush, the mob spawner and liquids never drop anything" {
    var rand = JavaRandom.init(0);
    try std.testing.expect(drop(dead_bush, 0, &rand) == null);
    try std.testing.expect(drop(mob_spawner, 0, &rand) == null);
    try std.testing.expect(drop(stationary_water, 0, &rand) == null);
    try std.testing.expect(drop(flowing_lava, 0, &rand) == null);
}

test "clay always drops 4 clay balls" {
    var rand = JavaRandom.init(0);
    const dropped = drop(clay, 0, &rand).?;
    try std.testing.expectEqual(@as(u16, item.clay_ball), dropped.id);
    try std.testing.expectEqual(@as(u8, 4), dropped.count);
}

test "reed drops its item form and snow drops a snowball" {
    var rand = JavaRandom.init(0);
    try std.testing.expectEqual(@as(u16, item.reed), drop(reed, 0, &rand).?.id);
    try std.testing.expectEqual(@as(u16, item.snowball), drop(snow_layer, 0, &rand).?.id);
}

test "blocks without a special drop rule self-drop with metadata reset to 0" {
    var rand = JavaRandom.init(0);
    const dropped = drop(pumpkin, 3, &rand).?;
    try std.testing.expectEqual(@as(u16, pumpkin), dropped.id);
    try std.testing.expectEqual(@as(u4, 0), dropped.meta);
}

test "only sand and gravel are falling blocks" {
    try std.testing.expect(isFalling(sand));
    try std.testing.expect(isFalling(gravel));
    try std.testing.expect(!isFalling(stone));
    try std.testing.expect(!isFalling(dirt));
}

test "a falling block can fall into air or liquid, not solid ground" {
    try std.testing.expect(canFallInto(air));
    try std.testing.expect(canFallInto(stationary_water));
    try std.testing.expect(canFallInto(flowing_lava));
    try std.testing.expect(!canFallInto(stone));
}
