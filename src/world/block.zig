const std = @import("std");
const JavaRandom = @import("java_random.zig");
const item = @import("item.zig");
const Item = item.Item;

pub const Side = enum(u3) {
    down,
    up,
    north,
    south,
    west,
    east,
};

pub const Material = enum {
    air,
    rock,
    iron,
    ground,
    sand,
    wood,
    leaves,
    plants,
    sponge,
    cloth,
    glass,
    tnt,
    water,
    lava,
    snow,
    built_snow,
    ice,
    clay,
    pumpkin,
    cactus,
    circuits,

    pub fn blocksGrass(self: Material) bool {
        return switch (self) {
            .air, .plants, .snow, .circuits => false,
            else => true,
        };
    }

    pub fn isLiquid(self: Material) bool {
        return switch (self) {
            .water, .lava => true,
            else => false,
        };
    }

    pub fn isSolid(self: Material) bool {
        return self.blocksGrass() and !self.isLiquid();
    }

    pub fn isHarvestable(self: Material) bool {
        return switch (self) {
            .rock, .iron, .snow, .built_snow => false,
            else => true,
        };
    }
};

pub const Shape = union(enum) {
    cube,
    cross,
    torch,
    partial: f32,

    pub fn heightScale(self: Shape) f32 {
        return switch (self) {
            .partial => |height| height,
            else => 1.0,
        };
    }
};

pub const Bounds = struct { min: [3]f32, max: [3]f32 };

pub const FaceTextures = std.EnumArray(Side, u8);

fn uniform(tile: u8) FaceTextures {
    return FaceTextures.initFill(tile);
}

fn topAndSide(top: u8, bottom: u8, side: u8) FaceTextures {
    return FaceTextures.init(.{
        .down = bottom,
        .up = top,
        .north = side,
        .south = side,
        .west = side,
        .east = side,
    });
}

fn plantBounds(half_width: f32, height: f32) Bounds {
    return .{
        .min = .{ 0.5 - half_width, 0.0, 0.5 - half_width },
        .max = .{ 0.5 + half_width, height, 0.5 + half_width },
    };
}

fn torchBounds(metadata: u4) Bounds {
    const wall: f32 = 0.15;
    return switch (metadata & 7) {
        1 => .{ .min = .{ 0.0, 0.2, 0.5 - wall }, .max = .{ wall * 2.0, 0.8, 0.5 + wall } },
        2 => .{ .min = .{ 1.0 - wall * 2.0, 0.2, 0.5 - wall }, .max = .{ 1.0, 0.8, 0.5 + wall } },
        3 => .{ .min = .{ 0.5 - wall, 0.2, 0.0 }, .max = .{ 0.5 + wall, 0.8, wall * 2.0 } },
        4 => .{ .min = .{ 0.5 - wall, 0.2, 1.0 - wall * 2.0 }, .max = .{ 0.5 + wall, 0.8, 1.0 } },
        else => plantBounds(0.1, 0.6),
    };
}

pub const Stack = struct {
    id: Id,
    count: u8,
    meta: u16 = 0,

    pub fn displayName(self: Stack) []const u8 {
        return switch (self.id) {
            .block => |id| id.displayName(),
            .item => |id| id.displayName(self.meta),
        };
    }

    pub fn blockMeta(self: Stack) u4 {
        return @truncate(self.meta);
    }

    pub fn maxDamage(self: Stack) u16 {
        return switch (self.id) {
            .block => 0,
            .item => |id| id.maxDamage(),
        };
    }

    pub fn isDamaged(self: Stack) bool {
        return self.maxDamage() > 0 and self.meta > 0;
    }

    pub fn damage(self: *Stack, amount: u16) void {
        if (self.maxDamage() == 0) return;
        self.meta += amount;
        if (self.meta <= self.maxDamage()) return;
        self.count -|= 1;
        self.meta = 0;
    }
};

pub const Id = union(enum) {
    block: Block,
    item: Item,

    pub fn eql(self: Id, other: Id) bool {
        return switch (self) {
            .block => |b| other == .block and other.block == b,
            .item => |i| other == .item and other.item == i,
        };
    }

    pub fn maxStackSize(self: Id) u8 {
        return switch (self) {
            .block => 64,
            .item => |id| id.maxStackSize(),
        };
    }
};

pub const Block = enum(u8) {
    air = 0,
    stone = 1,
    grass = 2,
    dirt = 3,
    cobblestone = 4,
    planks = 5,
    sapling = 6,
    bedrock = 7,
    flowing_water = 8,
    stationary_water = 9,
    flowing_lava = 10,
    stationary_lava = 11,
    sand = 12,
    gravel = 13,
    ore_gold = 14,
    ore_iron = 15,
    ore_coal = 16,
    log = 17,
    leaves = 18,
    sponge = 19,
    glass = 20,
    ore_lapis = 21,
    block_lapis = 22,
    sandstone = 24,
    note_block = 25,
    tall_grass = 31,
    dead_bush = 32,
    wool = 35,
    dandelion = 37,
    rose = 38,
    mushroom_brown = 39,
    mushroom_red = 40,
    block_gold = 41,
    block_iron = 42,
    brick = 45,
    tnt = 46,
    bookshelf = 47,
    cobblestone_mossy = 48,
    obsidian = 49,
    torch = 50,
    mob_spawner = 52,
    chest = 54,
    ore_diamond = 56,
    block_diamond = 57,
    workbench = 58,
    ore_redstone = 73,
    snow_layer = 78,
    ice = 79,
    snow_block = 80,
    cactus = 81,
    clay = 82,
    reed = 83,
    jukebox = 84,
    pumpkin = 86,
    netherrack = 87,
    soul_sand = 88,
    glowstone = 89,
    jack_o_lantern = 91,
    _,

    pub fn material(self: Block) Material {
        return switch (self) {
            .air => .air,
            .stone, .cobblestone, .cobblestone_mossy, .bedrock, .mob_spawner => .rock,
            .ore_gold, .ore_iron, .ore_coal, .ore_lapis, .ore_diamond, .ore_redstone => .rock,
            .block_lapis, .sandstone, .brick, .obsidian, .netherrack, .glowstone => .rock,
            .block_gold, .block_iron, .block_diamond => .iron,
            .grass, .dirt => .ground,
            .sand, .gravel, .soul_sand => .sand,
            .planks, .log, .note_block, .bookshelf, .workbench, .jukebox, .chest => .wood,
            .leaves => .leaves,
            .sponge => .sponge,
            .wool => .cloth,
            .glass => .glass,
            .tnt => .tnt,
            .ice => .ice,
            .snow_block => .built_snow,
            .sapling, .tall_grass, .dead_bush, .dandelion, .rose, .mushroom_brown, .mushroom_red, .reed => .plants,
            .flowing_water, .stationary_water => .water,
            .flowing_lava, .stationary_lava => .lava,
            .snow_layer => .snow,
            .clay => .clay,
            .cactus => .cactus,
            .pumpkin, .jack_o_lantern => .pumpkin,
            .torch => .circuits,
            else => .rock,
        };
    }

    pub fn shape(self: Block) Shape {
        return switch (self) {
            .sapling, .tall_grass, .dead_bush, .dandelion, .rose, .mushroom_brown, .mushroom_red, .reed => .cross,
            .torch => .torch,
            .snow_layer => .{ .partial = 0.125 },
            else => .cube,
        };
    }

    pub fn isCross(self: Block) bool {
        return self.shape() == .cross;
    }

    pub fn heightScale(self: Block) f32 {
        return self.shape().heightScale();
    }

    pub fn sideInset(self: Block) f32 {
        return switch (self) {
            .cactus => 1.0 / 16.0,
            else => 0.0,
        };
    }

    pub fn isOpaque(self: Block) bool {
        return self.material().blocksGrass();
    }

    pub fn isLiquid(self: Block) bool {
        return self.material().isLiquid();
    }

    pub fn isSolid(self: Block) bool {
        return self.material().isSolid();
    }

    pub fn tickRate(self: Block) u32 {
        if (self.isFalling()) return 3;
        return switch (self.material()) {
            .water => 5,
            .lava => 30,
            else => 0,
        };
    }

    pub fn isOpaqueCube(self: Block) bool {
        return switch (self) {
            .leaves, .glass, .ice, .cactus => false,
            else => self.isOpaque() and !self.isLiquid(),
        };
    }

    pub fn isBreakable(self: Block) bool {
        return self == .glass or self == .ice;
    }

    pub fn isTranslucent(self: Block) bool {
        return self.material() == .water or self == .ice;
    }

    pub fn isFalling(self: Block) bool {
        return self == .sand or self == .gravel;
    }

    pub fn canFallInto(self: Block) bool {
        return self == .air or self.isLiquid();
    }

    pub fn isReplaceable(self: Block) bool {
        return self == .air or self.isLiquid() or self == .snow_layer;
    }

    pub fn selectionBounds(self: Block, metadata: u4) Bounds {
        return switch (self) {
            .tall_grass, .dead_bush => plantBounds(0.4, 0.8),
            .dandelion, .rose => plantBounds(0.2, 0.6),
            .mushroom_brown, .mushroom_red => plantBounds(0.2, 0.4),
            .reed => plantBounds(6.0 / 16.0, 1.0),
            .cactus => plantBounds(7.0 / 16.0, 1.0),
            .torch => torchBounds(metadata),
            else => .{ .min = .{ 0, 0, 0 }, .max = .{ 1, self.heightScale(), 1 } },
        };
    }

    pub fn shouldRenderFace(self: Block, neighbor: Block, side: Side, fancy: bool) bool {
        if (self.isLiquid()) {
            if (neighbor.material() == self.material()) return false;
            if (neighbor.material() == .ice) return false;
            if (side == .up) return true;
        }
        if (self == .leaves and !fancy and neighbor == .leaves) return false;
        if (self.isBreakable() and neighbor == self) return false;
        return !neighbor.isOpaqueCube();
    }

    pub fn faceTextures(self: Block) FaceTextures {
        return switch (self) {
            .stone => uniform(1),
            .grass => topAndSide(0, 2, 3),
            .dirt => uniform(2),
            .planks => uniform(4),
            .bedrock => uniform(17),
            .flowing_water, .stationary_water => topAndSide(205, 205, 206),
            .flowing_lava, .stationary_lava => topAndSide(237, 237, 238),
            .sand => uniform(18),
            .gravel => uniform(19),
            .ore_gold => uniform(32),
            .ore_iron => uniform(33),
            .ore_coal => uniform(34),
            .log => topAndSide(21, 21, 20),
            .leaves => uniform(52),
            .ore_lapis => uniform(160),
            .ore_diamond => uniform(50),
            .ore_redstone => uniform(51),
            .clay => uniform(72),
            .cactus => topAndSide(69, 71, 70),
            .pumpkin => topAndSide(102, 102, 118),
            .snow_layer => uniform(66),
            .cobblestone => uniform(16),
            .cobblestone_mossy => uniform(36),
            .mob_spawner => uniform(65),
            .sponge => uniform(48),
            .glass => uniform(49),
            .block_lapis => uniform(144),
            .sandstone => topAndSide(176, 208, 192),
            .note_block => uniform(74),
            .wool => uniform(woolTile(0)),
            .block_gold => uniform(23),
            .block_iron => uniform(22),
            .brick => uniform(7),
            .tnt => topAndSide(9, 10, 8),
            .bookshelf => topAndSide(4, 4, 35),
            .obsidian => uniform(37),
            .torch => uniform(80),
            .block_diamond => uniform(24),
            .workbench => FaceTextures.init(.{
                .down = 4,
                .up = 43,
                .north = 60,
                .south = 59,
                .west = 60,
                .east = 59,
            }),
            .ice => uniform(67),
            .snow_block => uniform(66),
            .jukebox => topAndSide(75, 74, 74),
            .netherrack => uniform(103),
            .soul_sand => uniform(104),
            .glowstone => uniform(105),
            .jack_o_lantern => FaceTextures.init(.{
                .down = 102,
                .up = 102,
                .north = 118,
                .south = 120,
                .west = 118,
                .east = 118,
            }),
            else => uniform(0),
        };
    }

    pub fn crossTile(self: Block, metadata: u4) u8 {
        return switch (self) {
            .sapling => switch (metadata & 3) {
                1 => 63,
                2 => 79,
                else => 15,
            },
            .tall_grass => if (metadata == 2) 56 else 39,
            .dead_bush => 55,
            .dandelion => 13,
            .rose => 12,
            .mushroom_brown => 29,
            .mushroom_red => 28,
            .reed => 73,
            else => 0,
        };
    }

    pub fn flatItemTile(self: Block, metadata: u4) ?u8 {
        return switch (self.shape()) {
            .cross => self.crossTile(metadata),
            .torch => self.faceTextures().get(.down),
            else => null,
        };
    }

    fn hardness(self: Block) f32 {
        return switch (self) {
            .stone => 1.5,
            .grass => 0.6,
            .dirt => 0.5,
            .planks => 2.0,
            .bedrock => -1.0,
            .flowing_water, .stationary_water => 100.0,
            .flowing_lava => 0.0,
            .stationary_lava => 100.0,
            .sand => 0.5,
            .gravel => 0.6,
            .ore_gold, .ore_iron, .ore_coal, .ore_lapis, .ore_diamond, .ore_redstone => 3.0,
            .log => 2.0,
            .leaves => 0.2,
            .clay => 0.6,
            .cactus => 0.4,
            .pumpkin => 1.0,
            .snow_layer => 0.1,
            .cobblestone, .cobblestone_mossy => 2.0,
            .mob_spawner => 5.0,
            .sponge => 0.6,
            .glass => 0.3,
            .block_lapis => 3.0,
            .sandstone => 0.8,
            .note_block => 0.8,
            .wool => 0.8,
            .block_gold => 3.0,
            .block_iron => 5.0,
            .brick => 2.0,
            .tnt => 0.0,
            .bookshelf => 1.5,
            .obsidian => 10.0,
            .torch => 0.0,
            .block_diamond => 5.0,
            .workbench => 2.5,
            .ice => 0.5,
            .snow_block => 0.2,
            .jukebox => 2.0,
            .netherrack => 0.4,
            .soul_sand => 0.5,
            .glowstone => 0.3,
            .jack_o_lantern => 1.0,
            else => 0.0,
        };
    }

    pub fn harvestableWith(self: Block, held: ?Stack) bool {
        if (self.material().isHarvestable()) return true;
        const stack = held orelse return false;
        return switch (stack.id) {
            .block => false,
            .item => |id| id.canHarvestBlock(self),
        };
    }

    pub fn strVsBlock(self: Block, held: ?Stack) f32 {
        const stack = held orelse return 1.0;
        return switch (stack.id) {
            .block => 1.0,
            .item => |id| id.strVsBlock(self),
        };
    }

    pub fn strength(self: Block, held: ?Stack, speed_factor: f32) f32 {
        const h = self.hardness();
        if (h < 0.0) return 0.0;
        if (!self.harvestableWith(held)) return 1.0 / h / 100.0;
        return self.strVsBlock(held) * speed_factor / h / 30.0;
    }

    pub fn displayName(self: Block) []const u8 {
        return switch (self) {
            .stone => "Stone",
            .grass => "Grass",
            .dirt => "Dirt",
            .cobblestone => "Cobblestone",
            .planks => "Wooden Planks",
            .sapling => "Sapling",
            .bedrock => "Bedrock",
            .flowing_water, .stationary_water => "Water",
            .flowing_lava, .stationary_lava => "Lava",
            .sand => "Sand",
            .gravel => "Gravel",
            .ore_gold => "Gold Ore",
            .ore_iron => "Iron Ore",
            .ore_coal => "Coal Ore",
            .log => "Wood",
            .leaves => "Leaves",
            .ore_lapis => "Lapis Lazuli Ore",
            .dandelion => "Flower",
            .rose => "Rose",
            .mushroom_brown, .mushroom_red => "Mushroom",
            .cobblestone_mossy => "Moss Stone",
            .mob_spawner => "Monster Spawner",
            .ore_diamond => "Diamond Ore",
            .ore_redstone => "Redstone Ore",
            .snow_layer => "Snow",
            .clay => "Clay",
            .cactus => "Cactus",
            .reed => "Sugar cane",
            .pumpkin => "Pumpkin",
            .sponge => "Sponge",
            .glass => "Glass",
            .block_lapis => "Lapis Lazuli Block",
            .sandstone => "Sandstone",
            .note_block => "Note Block",
            .wool => "Wool",
            .block_gold => "Block of Gold",
            .block_iron => "Block of Iron",
            .brick => "Bricks",
            .tnt => "TNT",
            .bookshelf => "Bookshelf",
            .obsidian => "Obsidian",
            .torch => "Torch",
            .block_diamond => "Block of Diamond",
            .workbench => "Crafting Table",
            .ice => "Ice",
            .snow_block => "Snow",
            .jukebox => "Jukebox",
            .netherrack => "Netherrack",
            .soul_sand => "Soul Sand",
            .glowstone => "Glowstone",
            .jack_o_lantern => "Jack 'o' Lantern",
            else => "",
        };
    }

    pub fn drop(self: Block, meta: u4, rand: *JavaRandom) ?Stack {
        return switch (self) {
            .stone => .{ .id = .{ .block = .cobblestone }, .count = 1 },
            .grass => .{ .id = .{ .block = .dirt }, .count = 1 },
            .gravel => if (rand.nextIntBound(10) == 0)
                .{ .id = .{ .item = .flint }, .count = 1 }
            else
                .{ .id = .{ .block = .gravel }, .count = 1 },
            .ore_coal => .{ .id = .{ .item = .coal }, .count = 1 },
            .ore_diamond => .{ .id = .{ .item = .diamond }, .count = 1 },
            .ore_redstone => .{ .id = .{ .item = .redstone }, .count = @intCast(4 + rand.nextIntBound(2)) },
            .ore_lapis => .{ .id = .{ .item = .dye }, .count = @intCast(4 + rand.nextIntBound(5)), .meta = item.dye_meta_lapis },
            .log => .{ .id = .{ .block = .log }, .count = 1, .meta = meta },
            .leaves => if (rand.nextIntBound(20) == 0) .{ .id = .{ .block = .sapling }, .count = 1, .meta = meta & 3 } else null,
            .clay => .{ .id = .{ .item = .clay_ball }, .count = 4 },
            .tall_grass => if (rand.nextIntBound(8) == 0) .{ .id = .{ .item = .seeds }, .count = 1 } else null,
            .dead_bush => null,
            .reed => .{ .id = .{ .item = .reed }, .count = 1 },
            .snow_layer => .{ .id = .{ .item = .snowball }, .count = 1 },
            .snow_block => .{ .id = .{ .item = .snowball }, .count = 4 },
            .glowstone => .{ .id = .{ .item = .glowstone_dust }, .count = @intCast(2 + rand.nextIntBound(3)) },
            .wool => .{ .id = .{ .block = .wool }, .count = 1, .meta = meta },
            .glass, .bookshelf, .ice => null,
            .mob_spawner => null,
            .flowing_water, .stationary_water, .flowing_lava, .stationary_lava => null,
            else => .{ .id = .{ .block = self }, .count = 1 },
        };
    }
};

pub fn leafTile(metadata: u4, fancy: bool) u8 {
    const base: u8 = if (fancy) 52 else 53;
    return if (metadata & 3 == 1) base + 80 else base;
}

pub fn woolTile(metadata: u4) u8 {
    if (metadata == 0) return 64;
    const inverted: u8 = ~metadata;
    return 113 + ((inverted & 8) >> 3) + (inverted & 7) * 16;
}

pub fn logSideTile(metadata: u4) u8 {
    return switch (metadata) {
        1 => 116,
        2 => 117,
        else => 20,
    };
}

test "leaf tiles follow the graphics level, and pine has its own" {
    try std.testing.expectEqual(@as(u8, 52), leafTile(0, true));
    try std.testing.expectEqual(@as(u8, 53), leafTile(0, false));
    try std.testing.expectEqual(@as(u8, 132), leafTile(1, true));
    try std.testing.expectEqual(@as(u8, 133), leafTile(1, false));
    try std.testing.expectEqual(@as(u8, 52), leafTile(2, true));
    try std.testing.expectEqual(@as(u8, 52), leafTile(8, true));
}

test "leaves are not an opaque cube, so they never cull a neighbour" {
    try std.testing.expect(!Block.leaves.isOpaqueCube());
    try std.testing.expect(Block.leaves.isOpaque());
    try std.testing.expect(Block.stone.shouldRenderFace(.leaves, .up, true));
    try std.testing.expect(Block.stone.shouldRenderFace(.leaves, .up, false));
}

test "only fast graphics culls the face between two leaf blocks" {
    try std.testing.expect(Block.leaves.shouldRenderFace(.leaves, .up, true));
    try std.testing.expect(!Block.leaves.shouldRenderFace(.leaves, .up, false));
    try std.testing.expect(!Block.leaves.shouldRenderFace(.stone, .up, true));
}

test "a material decides whether its blocks are opaque and liquid" {
    try std.testing.expect(!Material.air.blocksGrass());
    try std.testing.expect(!Material.plants.blocksGrass());
    try std.testing.expect(!Material.snow.blocksGrass());
    try std.testing.expect(Material.rock.blocksGrass());
    try std.testing.expect(Material.water.blocksGrass());
    try std.testing.expect(Material.water.isLiquid());
    try std.testing.expect(!Material.rock.isLiquid());
}

test "shape carries the partial height instead of a separate lookup" {
    try std.testing.expectEqual(Shape.cube, Block.stone.shape());
    try std.testing.expectEqual(Shape.cross, Block.tall_grass.shape());
    try std.testing.expectEqual(@as(f32, 0.125), Block.snow_layer.shape().heightScale());
    try std.testing.expectEqual(@as(f32, 1.0), Block.stone.heightScale());
}

fn digTicks(id: Block, held: ?Stack) f32 {
    return 1.0 / id.strength(held, 1.0);
}

test "bare hands take hardness*30 ticks on a hand-harvestable block" {
    try std.testing.expectApproxEqAbs(@as(f32, 15.0), digTicks(.dirt, null), 1.0e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 60.0), digTicks(.log, null), 1.0e-4);
}

test "bare hands take hardness*100 on a block that needs a tool, and drop nothing" {
    try std.testing.expectApproxEqAbs(@as(f32, 150.0), digTicks(.stone, null), 1.0e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 300.0), digTicks(.ore_diamond, null), 1.0e-4);
    try std.testing.expect(!Block.stone.harvestableWith(null));
    try std.testing.expect(!Block.ore_diamond.harvestableWith(null));
}

test "an effective tool divides the dig time by its material's efficiency" {
    const wood: Stack = .{ .id = .{ .item = .pickaxe_wood }, .count = 1 };
    const diamond: Stack = .{ .id = .{ .item = .pickaxe_diamond }, .count = 1 };
    try std.testing.expectApproxEqAbs(@as(f32, 22.5), digTicks(.stone, wood), 1.0e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 5.625), digTicks(.stone, diamond), 1.0e-4);
}

test "the wrong tool still harvests rock, only no faster than a hand" {
    const shovel: Stack = .{ .id = .{ .item = .shovel_iron }, .count = 1 };
    try std.testing.expect(!Block.stone.harvestableWith(shovel));
    try std.testing.expectApproxEqAbs(@as(f32, 150.0), digTicks(.stone, shovel), 1.0e-4);

    const axe: Stack = .{ .id = .{ .item = .axe_diamond }, .count = 1 };
    try std.testing.expectApproxEqAbs(@as(f32, 7.5), digTicks(.log, axe), 1.0e-4);
}

test "an ore only drops for a pickaxe at or above its harvest level" {
    const wood: Stack = .{ .id = .{ .item = .pickaxe_wood }, .count = 1 };
    const stone: Stack = .{ .id = .{ .item = .pickaxe_stone }, .count = 1 };
    const iron: Stack = .{ .id = .{ .item = .pickaxe_iron }, .count = 1 };
    const diamond: Stack = .{ .id = .{ .item = .pickaxe_diamond }, .count = 1 };

    try std.testing.expect(Block.stone.harvestableWith(wood));
    try std.testing.expect(Block.ore_coal.harvestableWith(wood));
    try std.testing.expect(!Block.ore_iron.harvestableWith(wood));
    try std.testing.expect(Block.ore_iron.harvestableWith(stone));
    try std.testing.expect(!Block.ore_diamond.harvestableWith(stone));
    try std.testing.expect(Block.ore_diamond.harvestableWith(iron));
    try std.testing.expect(!Block.obsidian.harvestableWith(iron));
    try std.testing.expect(Block.obsidian.harvestableWith(diamond));
}

test "swimming or airborne slows a tool down, but not a bare-handed dig" {
    const pickaxe: Stack = .{ .id = .{ .item = .pickaxe_diamond }, .count = 1 };
    try std.testing.expectApproxEqAbs(@as(f32, 28.125), 1.0 / Block.stone.strength(pickaxe, 0.2), 1.0e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 150.0), 1.0 / Block.stone.strength(null, 0.2), 1.0e-4);
}

test "a gold pickaxe digs fastest but harvests least, matching its level of zero" {
    const gold: Stack = .{ .id = .{ .item = .pickaxe_gold }, .count = 1 };
    try std.testing.expectApproxEqAbs(@as(f32, 3.75), digTicks(.stone, gold), 1.0e-4);
    try std.testing.expect(!Block.ore_iron.harvestableWith(gold));
}

test "snow only drops for a shovel, which is the one thing a shovel harvests" {
    const shovel: Stack = .{ .id = .{ .item = .shovel_wood }, .count = 1 };
    const pickaxe: Stack = .{ .id = .{ .item = .pickaxe_diamond }, .count = 1 };
    try std.testing.expect(!Block.snow_layer.harvestableWith(null));
    try std.testing.expect(!Block.snow_block.harvestableWith(pickaxe));
    try std.testing.expect(Block.snow_layer.harvestableWith(shovel));
    try std.testing.expect(Block.snow_block.harvestableWith(shovel));
}

test "a sword digs everything at 1.5x, but not what it cannot harvest" {
    const sword: Stack = .{ .id = .{ .item = .sword_diamond }, .count = 1 };
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), digTicks(.dirt, sword), 1.0e-4);
    try std.testing.expect(!Block.stone.harvestableWith(sword));
    try std.testing.expectApproxEqAbs(@as(f32, 150.0), digTicks(.stone, sword), 1.0e-4);
}

test "bedrock is unbreakable" {
    try std.testing.expectEqual(@as(f32, 0.0), Block.bedrock.strength(null, 1.0));
}

test "a stack wears out after exactly its material's uses" {
    var pickaxe: Stack = .{ .id = .{ .item = .pickaxe_wood }, .count = 1 };
    for (0..59) |_| pickaxe.damage(1);
    try std.testing.expectEqual(@as(u8, 1), pickaxe.count);
    try std.testing.expectEqual(@as(u16, 59), pickaxe.meta);
    pickaxe.damage(1);
    try std.testing.expectEqual(@as(u8, 0), pickaxe.count);
    try std.testing.expectEqual(@as(u16, 0), pickaxe.meta);
}

test "an undamageable stack ignores wear, so block metadata survives" {
    var log: Stack = .{ .id = .{ .block = .log }, .count = 5, .meta = 2 };
    log.damage(3);
    try std.testing.expectEqual(@as(u16, 2), log.meta);
    try std.testing.expectEqual(@as(u8, 5), log.count);
}

test "only tools and armour stack alone" {
    try std.testing.expectEqual(@as(u8, 1), (Id{ .item = .pickaxe_iron }).maxStackSize());
    try std.testing.expectEqual(@as(u8, 1), (Id{ .item = .chestplate_diamond }).maxStackSize());
    try std.testing.expectEqual(@as(u8, 64), (Id{ .item = .ingot_iron }).maxStackSize());
    try std.testing.expectEqual(@as(u8, 64), (Id{ .block = .stone }).maxStackSize());
}

test "snow layers are thin and non-opaque, unlike regular blocks" {
    try std.testing.expectEqual(@as(f32, 0.125), Block.snow_layer.heightScale());
    try std.testing.expectEqual(@as(f32, 1.0), Block.stone.heightScale());
    try std.testing.expect(!Block.snow_layer.isOpaque());
}

test "grass has a distinct top, bottom and side texture" {
    const textures = Block.grass.faceTextures();
    try std.testing.expectEqual(@as(u8, 0), textures.get(.up));
    try std.testing.expectEqual(@as(u8, 2), textures.get(.down));
    try std.testing.expectEqual(@as(u8, 3), textures.get(.north));
    try std.testing.expectEqual(@as(u8, 3), textures.get(.east));
}

test "air and cross-shaped plants are the only non-opaque blocks" {
    try std.testing.expect(!Block.air.isOpaque());
    try std.testing.expect(!Block.tall_grass.isOpaque());
    try std.testing.expect(Block.stone.isOpaque());
    try std.testing.expect(Block.bedrock.isOpaque());
}

test "tall grass picks the fern tile only at metadata 2" {
    try std.testing.expectEqual(@as(u8, 39), Block.tall_grass.crossTile(1));
    try std.testing.expectEqual(@as(u8, 56), Block.tall_grass.crossTile(2));
}

test "log side texture varies by wood type metadata" {
    try std.testing.expectEqual(@as(u8, 20), logSideTile(0));
    try std.testing.expectEqual(@as(u8, 116), logSideTile(1));
    try std.testing.expectEqual(@as(u8, 117), logSideTile(2));
}

test "stone drops cobblestone, not itself" {
    var rand = JavaRandom.init(0);
    const dropped = Block.stone.drop(0, &rand).?;
    try std.testing.expectEqual(Id{ .block = .cobblestone }, dropped.id);
    try std.testing.expectEqual(@as(u8, 1), dropped.count);
}

test "grass drops dirt" {
    var rand = JavaRandom.init(0);
    try std.testing.expectEqual(Id{ .block = .dirt }, Block.grass.drop(0, &rand).?.id);
}

test "ore blocks drop their raw item form" {
    var rand = JavaRandom.init(0);
    try std.testing.expectEqual(Id{ .item = .coal }, Block.ore_coal.drop(0, &rand).?.id);
    try std.testing.expectEqual(Id{ .item = .diamond }, Block.ore_diamond.drop(0, &rand).?.id);
}

test "gold and iron ore self-drop, unlike coal/diamond/lapis/redstone" {
    var rand = JavaRandom.init(0);
    try std.testing.expectEqual(Id{ .block = .ore_gold }, Block.ore_gold.drop(0, &rand).?.id);
    try std.testing.expectEqual(Id{ .block = .ore_iron }, Block.ore_iron.drop(0, &rand).?.id);
}

test "lapis ore drops 4-8 lapis dye" {
    var rand = JavaRandom.init(0);
    for (0..50) |_| {
        const dropped = Block.ore_lapis.drop(0, &rand).?;
        try std.testing.expectEqual(Id{ .item = .dye }, dropped.id);
        try std.testing.expectEqual(item.dye_meta_lapis, dropped.meta);
        try std.testing.expect(dropped.count >= 4 and dropped.count <= 8);
    }
}

test "redstone ore drops 4-5 redstone" {
    var rand = JavaRandom.init(0);
    for (0..50) |_| {
        const dropped = Block.ore_redstone.drop(0, &rand).?;
        try std.testing.expectEqual(Id{ .item = .redstone }, dropped.id);
        try std.testing.expect(dropped.count >= 4 and dropped.count <= 5);
    }
}

test "log preserves its wood-type metadata when dropped" {
    var rand = JavaRandom.init(0);
    try std.testing.expectEqual(@as(u4, 1), Block.log.drop(1, &rand).?.meta);
}

test "gravel occasionally drops flint instead of itself" {
    var rand = JavaRandom.init(0);
    var saw_flint = false;
    var saw_gravel = false;
    for (0..200) |_| {
        const dropped = Block.gravel.drop(0, &rand).?;
        try std.testing.expectEqual(@as(u8, 1), dropped.count);
        if (dropped.id.eql(.{ .item = .flint })) saw_flint = true;
        if (dropped.id.eql(.{ .block = .gravel })) saw_gravel = true;
    }
    try std.testing.expect(saw_flint);
    try std.testing.expect(saw_gravel);
}

test "leaves rarely drop a sapling, preserving wood type in its metadata" {
    var rand = JavaRandom.init(0);
    var saw_sapling = false;
    var saw_nothing = false;
    for (0..200) |_| {
        if (Block.leaves.drop(1, &rand)) |dropped| {
            try std.testing.expectEqual(Id{ .block = .sapling }, dropped.id);
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
        if (Block.tall_grass.drop(0, &rand)) |dropped| {
            try std.testing.expectEqual(Id{ .item = .seeds }, dropped.id);
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
    try std.testing.expect(Block.dead_bush.drop(0, &rand) == null);
    try std.testing.expect(Block.mob_spawner.drop(0, &rand) == null);
    try std.testing.expect(Block.stationary_water.drop(0, &rand) == null);
    try std.testing.expect(Block.flowing_lava.drop(0, &rand) == null);
}

test "clay always drops 4 clay balls" {
    var rand = JavaRandom.init(0);
    const dropped = Block.clay.drop(0, &rand).?;
    try std.testing.expectEqual(Id{ .item = .clay_ball }, dropped.id);
    try std.testing.expectEqual(@as(u8, 4), dropped.count);
}

test "reed drops its item form and snow drops a snowball" {
    var rand = JavaRandom.init(0);
    try std.testing.expectEqual(Id{ .item = .reed }, Block.reed.drop(0, &rand).?.id);
    try std.testing.expectEqual(Id{ .item = .snowball }, Block.snow_layer.drop(0, &rand).?.id);
}

test "blocks without a special drop rule self-drop with metadata reset to 0" {
    var rand = JavaRandom.init(0);
    const dropped = Block.pumpkin.drop(3, &rand).?;
    try std.testing.expectEqual(Id{ .block = .pumpkin }, dropped.id);
    try std.testing.expectEqual(@as(u4, 0), dropped.meta);
}

test "only sand and gravel are falling blocks" {
    try std.testing.expect(Block.sand.isFalling());
    try std.testing.expect(Block.gravel.isFalling());
    try std.testing.expect(!Block.stone.isFalling());
    try std.testing.expect(!Block.dirt.isFalling());
}

test "a falling block can fall into air or liquid, not solid ground" {
    try std.testing.expect(Block.air.canFallInto());
    try std.testing.expect(Block.stationary_water.canFallInto());
    try std.testing.expect(Block.flowing_lava.canFallInto());
    try std.testing.expect(!Block.stone.canFallInto());
}

test "display names come from the real en_US lang keys, not the enum names" {
    try std.testing.expectEqualStrings("Cobblestone", Block.cobblestone.displayName());
    try std.testing.expectEqualStrings("Wooden Planks", Block.planks.displayName());
    try std.testing.expectEqualStrings("Wood", Block.log.displayName());
    try std.testing.expectEqualStrings("Flower", Block.dandelion.displayName());
    try std.testing.expectEqualStrings("Moss Stone", Block.cobblestone_mossy.displayName());
}

test "blocks with no lang entry have no display name" {
    try std.testing.expectEqualStrings("", Block.tall_grass.displayName());
    try std.testing.expectEqualStrings("", Block.dead_bush.displayName());
}

test "log wood types all share one display name" {
    for (0..4) |meta| {
        const stack: Stack = .{ .id = .{ .block = .log }, .count = 1, .meta = @intCast(meta) };
        try std.testing.expectEqualStrings("Wood", stack.displayName());
    }
}

test "woolTile matches BlockCloth's inverted-metadata tile formula" {
    const want = [16]u8{ 64, 210, 194, 178, 162, 146, 130, 114, 225, 209, 193, 177, 161, 145, 129, 113 };
    for (want, 0..) |tile, meta| {
        try std.testing.expectEqual(tile, woolTile(@intCast(meta)));
    }
}

test "breakable blocks hide only the face they share with their own kind" {
    for ([_]Block{ .glass, .ice }) |id| {
        try std.testing.expect(!id.shouldRenderFace(id, .up, true));
        try std.testing.expect(id.shouldRenderFace(.air, .up, true));
        try std.testing.expect(!id.isOpaqueCube());
    }
    try std.testing.expect(Block.glass.shouldRenderFace(.ice, .up, true));
    try std.testing.expect(Block.stone.shouldRenderFace(.glass, .up, true));
}

test "glass, bookshelves and ice drop nothing when broken" {
    var rand = JavaRandom.init(0);
    for ([_]Block{ .glass, .bookshelf, .ice }) |id| {
        try std.testing.expectEqual(@as(?Stack, null), id.drop(0, &rand));
    }
}

test "snow blocks and glowstone drop their item form, wool keeps its colour" {
    var rand = JavaRandom.init(0);
    const snow = Block.snow_block.drop(0, &rand).?;
    try std.testing.expectEqual(Id{ .item = .snowball }, snow.id);
    try std.testing.expectEqual(@as(u8, 4), snow.count);

    const dust = Block.glowstone.drop(0, &rand).?;
    try std.testing.expectEqual(Id{ .item = .glowstone_dust }, dust.id);
    try std.testing.expect(dust.count >= 2 and dust.count <= 4);

    const wool = Block.wool.drop(9, &rand).?;
    try std.testing.expectEqual(Id{ .block = .wool }, wool.id);
    try std.testing.expectEqual(@as(u16, 9), wool.meta);
}

test "rock and iron blocks need a tool, other new blocks do not" {
    try std.testing.expectApproxEqAbs(@as(f32, 200.0), digTicks(.brick, null), 1.0e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 500.0), digTicks(.block_iron, null), 1.0e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 24.0), digTicks(.wool, null), 1.0e-4);
}

test "liquids and plants are not solid, so nothing collides with them" {
    try std.testing.expect(!Block.stationary_water.isSolid());
    try std.testing.expect(!Block.flowing_water.isSolid());
    try std.testing.expect(!Block.flowing_lava.isSolid());
    try std.testing.expect(!Block.air.isSolid());
    try std.testing.expect(!Block.rose.isSolid());
    try std.testing.expect(!Block.snow_layer.isSolid());
    try std.testing.expect(Block.stone.isSolid());
    try std.testing.expect(Block.leaves.isSolid());
}

test "both water blocks share one material, texture and tick rate" {
    try std.testing.expectEqual(Material.water, Block.flowing_water.material());
    try std.testing.expectEqual(Material.water, Block.stationary_water.material());
    try std.testing.expectEqual(Block.stationary_water.faceTextures(), Block.flowing_water.faceTextures());
    try std.testing.expectEqual(@as(u32, 5), Block.flowing_water.tickRate());
    try std.testing.expectEqual(@as(u32, 30), Block.flowing_lava.tickRate());
    try std.testing.expect(Block.flowing_water.isTranslucent());
}

test "a liquid culls the face it shares with its own material or with ice" {
    try std.testing.expect(!Block.flowing_water.shouldRenderFace(.stationary_water, .north, true));
    try std.testing.expect(!Block.stationary_water.shouldRenderFace(.flowing_water, .north, true));
    try std.testing.expect(!Block.stationary_water.shouldRenderFace(.ice, .north, true));
    try std.testing.expect(Block.stationary_water.shouldRenderFace(.flowing_lava, .north, true));
    try std.testing.expect(Block.stationary_water.shouldRenderFace(.air, .north, true));
}

test "a liquid always draws its top face unless the same liquid sits above it" {
    try std.testing.expect(Block.stationary_water.shouldRenderFace(.stone, .up, true));
    try std.testing.expect(!Block.stationary_water.shouldRenderFace(.stationary_water, .up, true));
}

test "saplings draw as a cross, with a tile per tree kind" {
    try std.testing.expect(Block.sapling.isCross());
    try std.testing.expectEqual(@as(u8, 15), Block.sapling.crossTile(0));
    try std.testing.expectEqual(@as(u8, 63), Block.sapling.crossTile(1));
    try std.testing.expectEqual(@as(u8, 79), Block.sapling.crossTile(2));
    try std.testing.expectEqual(@as(u8, 15), Block.sapling.crossTile(3));
}

test "a torch is not solid, so nothing collides with it or plants on it" {
    try std.testing.expect(!Block.torch.isSolid());
    try std.testing.expect(!Block.torch.isOpaque());
    try std.testing.expect(!Block.torch.isOpaqueCube());
    try std.testing.expectEqual(Material.circuits, Block.torch.material());
}

test "a torch breaks instantly and drops itself" {
    var rand = JavaRandom.init(0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), digTicks(.torch, null), 1.0e-4);
    const dropped = Block.torch.drop(5, &rand).?;
    try std.testing.expectEqual(Id{ .block = .torch }, dropped.id);
    try std.testing.expectEqual(@as(u8, 1), dropped.count);
    try std.testing.expectEqualStrings("Torch", Block.torch.displayName());
}

test "a wall torch stands in the quarter of the block its wall is on" {
    const west = Block.torch.selectionBounds(1);
    try std.testing.expectEqual(@as(f32, 0.0), west.min[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), west.max[0], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), west.min[1], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), west.max[1], 1.0e-6);

    const east = Block.torch.selectionBounds(2);
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), east.min[0], 1.0e-6);
    try std.testing.expectEqual(@as(f32, 1.0), east.max[0]);

    const north = Block.torch.selectionBounds(3);
    try std.testing.expectEqual(@as(f32, 0.0), north.min[2]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), north.max[2], 1.0e-6);

    const south = Block.torch.selectionBounds(4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), south.min[2], 1.0e-6);
    try std.testing.expectEqual(@as(f32, 1.0), south.max[2]);
}

test "a standing torch is a thin column in the middle of the block" {
    const standing = Block.torch.selectionBounds(5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), standing.min[0], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), standing.max[0], 1.0e-6);
    try std.testing.expectEqual(@as(f32, 0.0), standing.min[1]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), standing.max[1], 1.0e-6);
    try std.testing.expectEqual(standing, Block.torch.selectionBounds(0));
}

test "a torch leaves the world as a flat sprite, like a plant does" {
    try std.testing.expectEqual(@as(?u8, 80), Block.torch.flatItemTile(2));
    try std.testing.expectEqual(@as(?u8, Block.rose.crossTile(0)), Block.rose.flatItemTile(0));
    try std.testing.expectEqual(@as(?u8, null), Block.stone.flatItemTile(0));
    try std.testing.expectEqual(@as(?u8, null), Block.snow_layer.flatItemTile(0));
}

test "only air, liquids and snow give way to a block placed on top of them" {
    try std.testing.expect(Block.air.isReplaceable());
    try std.testing.expect(Block.stationary_water.isReplaceable());
    try std.testing.expect(Block.flowing_water.isReplaceable());
    try std.testing.expect(Block.flowing_lava.isReplaceable());
    try std.testing.expect(Block.snow_layer.isReplaceable());

    try std.testing.expect(!Block.torch.isReplaceable());
    try std.testing.expect(!Block.stone.isReplaceable());
    try std.testing.expect(!Block.tall_grass.isReplaceable());
    try std.testing.expect(!Block.rose.isReplaceable());
}
