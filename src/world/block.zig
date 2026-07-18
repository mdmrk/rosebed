const std = @import("std");

const item = @import("item.zig");
const Item = item.Item;
const JavaRandom = @import("java_random.zig");

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
    door,
    trapdoor,
    stairs,
    partial: f32,

    pub fn heightScale(self: Shape) f32 {
        return switch (self) {
            .partial => |height| height,
            else => 1.0,
        };
    }
};

pub const Bounds = struct { min: [3]f32, max: [3]f32 };

const full_cube_box = [1]Bounds{.{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 1 } }};

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
            .block => |id| id.displayName(self.blockMeta()),
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
    slab_double = 43,
    slab = 44,
    brick = 45,
    tnt = 46,
    bookshelf = 47,
    cobblestone_mossy = 48,
    obsidian = 49,
    torch = 50,
    mob_spawner = 52,
    stairs_wood = 53,
    chest = 54,
    ore_diamond = 56,
    block_diamond = 57,
    workbench = 58,
    furnace = 61,
    burning_furnace = 62,
    door_wood = 64,
    stairs_cobblestone = 67,
    door_iron = 71,
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
    trapdoor = 96,
    _,

    pub fn material(self: Block) Material {
        return switch (self) {
            .air => .air,
            .stone, .cobblestone, .cobblestone_mossy, .bedrock, .mob_spawner, .stairs_cobblestone => .rock,
            .ore_gold, .ore_iron, .ore_coal, .ore_lapis, .ore_diamond, .ore_redstone => .rock,
            .block_lapis, .sandstone, .brick, .obsidian, .netherrack, .glowstone => .rock,
            .slab, .slab_double => .rock,
            .furnace, .burning_furnace => .rock,
            .block_gold, .block_iron, .block_diamond, .door_iron => .iron,
            .grass, .dirt => .ground,
            .sand, .gravel, .soul_sand => .sand,
            .planks, .log, .note_block, .bookshelf, .workbench, .jukebox, .chest, .door_wood, .trapdoor, .stairs_wood => .wood,
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
            .door_wood, .door_iron => .door,
            .trapdoor => .trapdoor,
            .stairs_wood, .stairs_cobblestone => .stairs,
            .snow_layer => .{ .partial = 0.125 },
            .slab => .{ .partial = 0.5 },
            else => .cube,
        };
    }

    pub fn isCross(self: Block) bool {
        return self.shape() == .cross;
    }

    pub fn isDoor(self: Block) bool {
        return self.shape() == .door;
    }

    pub fn isTrapdoor(self: Block) bool {
        return self.shape() == .trapdoor;
    }

    pub fn isStairs(self: Block) bool {
        return self.shape() == .stairs;
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
            .leaves, .glass, .ice, .cactus, .door_wood, .door_iron, .trapdoor => false,
            .stairs_wood, .stairs_cobblestone => false,
            .slab => false,
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
            .door_wood, .door_iron => doorBounds(metadata),
            .trapdoor => trapdoorBounds(metadata),
            else => .{ .min = .{ 0, 0, 0 }, .max = .{ 1, self.heightScale(), 1 } },
        };
    }

    pub fn itemRenderBoxes(self: Block) []const Bounds {
        return switch (self) {
            .trapdoor => &trapdoor_item_boxes,
            .slab => &slab_item_boxes,
            .stairs_wood, .stairs_cobblestone => &stairs_item_boxes,
            else => &full_cube_box,
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
        if (self == .slab or self == .slab_double) {
            if (side == .up) return true;
            if (!neighbor.isOpaqueCube()) return side == .down or neighbor != self;
            return false;
        }
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
            .furnace, .burning_furnace => furnaceTextures(self, furnace_default_facing),
            .door_wood => uniform(door_bottom_tile),
            .door_iron => uniform(door_bottom_tile + 1),
            .trapdoor => uniform(trapdoor_tile),
            .slab, .slab_double => slabTextures(0),
            .stairs_wood => uniform(4),
            .stairs_cobblestone => uniform(16),
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
            .stairs_wood, .stairs_cobblestone => 2.0,
            .slab, .slab_double => 2.0,
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
            .furnace, .burning_furnace => 3.5,
            .door_wood, .trapdoor => 3.0,
            .door_iron => 5.0,
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

    pub fn displayName(self: Block, metadata: u4) []const u8 {
        return switch (self) {
            .wool => wool_names[~metadata],
            .slab, .slab_double => slabName(metadata),
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
            .block_gold => "Block of Gold",
            .block_iron => "Block of Iron",
            .brick => "Bricks",
            .tnt => "TNT",
            .bookshelf => "Bookshelf",
            .obsidian => "Obsidian",
            .torch => "Torch",
            .block_diamond => "Block of Diamond",
            .workbench => "Crafting Table",
            .furnace, .burning_furnace => "Furnace",
            .door_wood => "Wooden Door",
            .trapdoor => "Trapdoor",
            .stairs_wood => "Wooden Stairs",
            .stairs_cobblestone => "Stone Stairs",
            .door_iron => "Iron Door",
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
            .slab => .{ .id = .{ .block = .slab }, .count = 1, .meta = meta },
            .slab_double => .{ .id = .{ .block = .slab }, .count = 2, .meta = meta },
            .stairs_wood => .{ .id = .{ .block = .planks }, .count = 1 },
            .stairs_cobblestone => .{ .id = .{ .block = .cobblestone }, .count = 1 },
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
            .furnace, .burning_furnace => .{ .id = .{ .block = .furnace }, .count = 1 },
            .door_wood => if (meta & door_top_bit != 0) null else .{ .id = .{ .item = .door_wood }, .count = 1 },
            .door_iron => if (meta & door_top_bit != 0) null else .{ .id = .{ .item = .door_iron }, .count = 1 },
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

const wool_names: [16][]const u8 = .{
    "Black Wool",
    "Red Wool",
    "Green Wool",
    "Brown Wool",
    "Blue Wool",
    "Purple Wool",
    "Cyan Wool",
    "Light Gray Wool",
    "Gray Wool",
    "Pink Wool",
    "Lime Wool",
    "Yellow Wool",
    "Light Blue Wool",
    "Magenta Wool",
    "Orange Wool",
    "Wool",
};

fn slabName(metadata: u4) []const u8 {
    return switch (metadata) {
        slab_sandstone => "Sandstone Slab",
        slab_wood => "Wooden Slab",
        else => "Stone Slab",
    };
}

pub fn woolTile(metadata: u4) u8 {
    if (metadata == 0) return 64;
    const inverted: u8 = ~metadata;
    return 113 + ((inverted & 8) >> 3) + (inverted & 7) * 16;
}

pub const grass_side_tile: u8 = 3;
pub const grass_side_overlay_tile: u8 = 38;
const snow_side_tile: u8 = 68;

pub fn grassSideTile(above: Block) u8 {
    return switch (above.material()) {
        .snow, .built_snow => snow_side_tile,
        else => grass_side_tile,
    };
}

pub fn logSideTile(metadata: u4) u8 {
    return switch (metadata) {
        1 => 116,
        2 => 117,
        else => 20,
    };
}

const furnace_side_tile: u8 = 45;
const furnace_top_tile: u8 = 62;
const furnace_front_tile: u8 = 44;
const furnace_front_lit_tile: u8 = 61;
pub const furnace_default_facing: u4 = @intFromEnum(Side.south);

pub fn furnaceFacing(metadata: u4) Side {
    return switch (metadata) {
        @intFromEnum(Side.north), @intFromEnum(Side.west), @intFromEnum(Side.east) => @enumFromInt(metadata),
        else => .south,
    };
}

pub fn furnaceFacingFromYaw(yaw: f32) u4 {
    const quarter = @floor(@mod(yaw, 360.0) * 4.0 / 360.0 + 0.5);
    return switch (@as(u2, @intFromFloat(@mod(quarter, 4.0)))) {
        0 => @intFromEnum(Side.north),
        1 => @intFromEnum(Side.east),
        2 => @intFromEnum(Side.south),
        3 => @intFromEnum(Side.west),
    };
}

pub const door_open_bit: u4 = 4;
pub const door_top_bit: u4 = 8;
pub const door_thickness: f32 = 3.0 / 16.0;
const door_bottom_tile: u8 = 97;
const door_tile_row: u8 = 16;

pub fn doorState(metadata: u4) u2 {
    return @truncate(if (metadata & door_open_bit == 0) metadata -% 1 else metadata);
}

pub fn doorIsTop(metadata: u4) bool {
    return metadata & door_top_bit != 0;
}

pub fn doorIsOpen(metadata: u4) bool {
    return metadata & door_open_bit != 0;
}

pub fn doorBounds(metadata: u4) Bounds {
    return switch (doorState(metadata)) {
        0 => .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, door_thickness } },
        1 => .{ .min = .{ 1 - door_thickness, 0, 0 }, .max = .{ 1, 1, 1 } },
        2 => .{ .min = .{ 0, 0, 1 - door_thickness }, .max = .{ 1, 1, 1 } },
        3 => .{ .min = .{ 0, 0, 0 }, .max = .{ door_thickness, 1, 1 } },
    };
}

pub const DoorFace = struct { tile: u8, mirrored: bool };

pub fn doorFaceTile(id: Block, side: Side, metadata: u4) DoorFace {
    const bottom: u8 = if (id == .door_iron) door_bottom_tile + 1 else door_bottom_tile;
    if (side == .down or side == .up) return .{ .tile = bottom, .mirrored = false };

    const state: u8 = doorState(metadata);
    const index: u8 = @intFromEnum(side);
    if ((state == 0 or state == 2) != (index <= @intFromEnum(Side.south))) {
        return .{ .tile = bottom, .mirrored = false };
    }

    const opened: u8 = if (doorIsOpen(metadata)) 1 else 0;
    const turned = state / 2 + ((index & 1) ^ state) + opened;
    return .{
        .tile = if (doorIsTop(metadata)) bottom - door_tile_row else bottom,
        .mirrored = turned & 1 != 0,
    };
}

pub fn doorFacingFromYaw(yaw: f32) u2 {
    const quarter = @floor((@mod(yaw, 360.0) + 180.0) * 4.0 / 360.0 - 0.5);
    return @intCast(@mod(@as(i32, @intFromFloat(quarter)), 4));
}

pub fn doorHingeStep(facing: u2) [2]i32 {
    return switch (facing) {
        0 => .{ 0, 1 },
        1 => .{ -1, 0 },
        2 => .{ 0, -1 },
        3 => .{ 1, 0 },
    };
}

pub const trapdoor_open_bit: u4 = 4;
pub const trapdoor_thickness: f32 = 3.0 / 16.0;
const trapdoor_tile: u8 = 84;

const trapdoor_item_boxes = [1]Bounds{.{
    .min = .{ 0, 0.5 - trapdoor_thickness / 2.0, 0 },
    .max = .{ 1, 0.5 + trapdoor_thickness / 2.0, 1 },
}};

pub fn trapdoorIsOpen(metadata: u4) bool {
    return metadata & trapdoor_open_bit != 0;
}

pub fn trapdoorBounds(metadata: u4) Bounds {
    if (!trapdoorIsOpen(metadata)) {
        return .{ .min = .{ 0, 0, 0 }, .max = .{ 1, trapdoor_thickness, 1 } };
    }
    return switch (@as(u2, @truncate(metadata))) {
        0 => .{ .min = .{ 0, 0, 1 - trapdoor_thickness }, .max = .{ 1, 1, 1 } },
        1 => .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, trapdoor_thickness } },
        2 => .{ .min = .{ 1 - trapdoor_thickness, 0, 0 }, .max = .{ 1, 1, 1 } },
        3 => .{ .min = .{ 0, 0, 0 }, .max = .{ trapdoor_thickness, 1, 1 } },
    };
}

pub fn trapdoorSupportStep(metadata: u4) [3]i32 {
    return switch (@as(u2, @truncate(metadata))) {
        0 => .{ 0, 0, 1 },
        1 => .{ 0, 0, -1 },
        2 => .{ 1, 0, 0 },
        3 => .{ -1, 0, 0 },
    };
}

pub fn trapdoorFacingFromFace(face: Side) ?u4 {
    return switch (face) {
        .north => 0,
        .south => 1,
        .west => 2,
        .east => 3,
        .up, .down => null,
    };
}

const stairs_item_boxes = [2]Bounds{
    .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 0.5 } },
    .{ .min = .{ 0, 0, 0.5 }, .max = .{ 1, 0.5, 1 } },
};

pub fn stairsBoxes(metadata: u4) [2]Bounds {
    return switch (@as(u2, @truncate(metadata))) {
        0 => .{
            .{ .min = .{ 0, 0, 0 }, .max = .{ 0.5, 0.5, 1 } },
            .{ .min = .{ 0.5, 0, 0 }, .max = .{ 1, 1, 1 } },
        },
        1 => .{
            .{ .min = .{ 0, 0, 0 }, .max = .{ 0.5, 1, 1 } },
            .{ .min = .{ 0.5, 0, 0 }, .max = .{ 1, 0.5, 1 } },
        },
        2 => .{
            .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 0.5, 0.5 } },
            .{ .min = .{ 0, 0, 0.5 }, .max = .{ 1, 1, 1 } },
        },
        3 => .{
            .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 0.5 } },
            .{ .min = .{ 0, 0, 0.5 }, .max = .{ 1, 0.5, 1 } },
        },
    };
}

pub fn stairsFacingFromYaw(yaw: f32) u4 {
    const quarter = @floor(@mod(yaw, 360.0) * 4.0 / 360.0 + 0.5);
    return switch (@as(u2, @intFromFloat(@mod(quarter, 4.0)))) {
        0 => 2,
        1 => 1,
        2 => 3,
        3 => 0,
    };
}

const slab_item_boxes = [1]Bounds{.{ .min = .{ 0, 0, 0 }, .max = .{ 1, 0.5, 1 } }};

pub const slab_stone: u4 = 0;
pub const slab_sandstone: u4 = 1;
pub const slab_wood: u4 = 2;
pub const slab_cobblestone: u4 = 3;

pub fn slabTextures(metadata: u4) FaceTextures {
    return switch (metadata) {
        slab_sandstone => topAndSide(176, 208, 192),
        slab_wood => uniform(4),
        slab_cobblestone => uniform(16),
        else => topAndSide(6, 6, 5),
    };
}

pub fn furnaceTextures(id: Block, metadata: u4) FaceTextures {
    var textures = FaceTextures.initFill(furnace_side_tile);
    textures.set(.down, furnace_top_tile);
    textures.set(.up, furnace_top_tile);
    textures.set(
        furnaceFacing(metadata),
        if (id == .burning_furnace) furnace_front_lit_tile else furnace_front_tile,
    );
    return textures;
}

test "the furnace turns its face towards the side its metadata names" {
    const idle = furnaceTextures(.furnace, @intFromEnum(Side.west));
    try std.testing.expectEqual(@as(u8, 44), idle.get(.west));
    try std.testing.expectEqual(@as(u8, 45), idle.get(.south));
    try std.testing.expectEqual(@as(u8, 62), idle.get(.up));
    try std.testing.expectEqual(@as(u8, 62), idle.get(.down));

    const lit = furnaceTextures(.burning_furnace, @intFromEnum(Side.north));
    try std.testing.expectEqual(@as(u8, 61), lit.get(.north));
    try std.testing.expectEqual(@as(u8, 45), lit.get(.east));
}

test "a furnace faces the player who placed it, whichever way they were turned" {
    try std.testing.expectEqual(@intFromEnum(Side.north), furnaceFacingFromYaw(0));
    try std.testing.expectEqual(@intFromEnum(Side.east), furnaceFacingFromYaw(90));
    try std.testing.expectEqual(@intFromEnum(Side.south), furnaceFacingFromYaw(180));
    try std.testing.expectEqual(@intFromEnum(Side.west), furnaceFacingFromYaw(270));
    try std.testing.expectEqual(@intFromEnum(Side.west), furnaceFacingFromYaw(-90));
    try std.testing.expectEqual(@intFromEnum(Side.north), furnaceFacingFromYaw(-720));
    try std.testing.expectEqual(@intFromEnum(Side.east), furnaceFacingFromYaw(3690));
}

test "a furnace with no facing yet still shows its front, as GuiFurnace's item does" {
    try std.testing.expectEqual(@as(u8, 44), .furnace.faceTextures().get(.south));
    try std.testing.expectEqual(@as(u8, 61), .burning_furnace.faceTextures().get(.south));
    try std.testing.expectEqual(@as(u8, 45), .furnace.faceTextures().get(.north));
}

test "both furnace states drop the idle block" {
    var rand = JavaRandom.init(0);
    try std.testing.expectEqual(Id{ .block = .furnace }, .furnace.drop(0, &rand).?.id);
    try std.testing.expectEqual(Id{ .block = .furnace }, .burning_furnace.drop(3, &rand).?.id);
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
    try std.testing.expect(!.leaves.isOpaqueCube());
    try std.testing.expect(.leaves.isOpaque());
    try std.testing.expect(.stone.shouldRenderFace(.leaves, .up, true));
    try std.testing.expect(.stone.shouldRenderFace(.leaves, .up, false));
}

test "only fast graphics culls the face between two leaf blocks" {
    try std.testing.expect(.leaves.shouldRenderFace(.leaves, .up, true));
    try std.testing.expect(!.leaves.shouldRenderFace(.leaves, .up, false));
    try std.testing.expect(!.leaves.shouldRenderFace(.stone, .up, true));
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
    try std.testing.expectEqual(Shape.cube, .stone.shape());
    try std.testing.expectEqual(Shape.cross, .tall_grass.shape());
    try std.testing.expectEqual(@as(f32, 0.125), .snow_layer.shape().heightScale());
    try std.testing.expectEqual(@as(f32, 1.0), .stone.heightScale());
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
    try std.testing.expect(!.stone.harvestableWith(null));
    try std.testing.expect(!.ore_diamond.harvestableWith(null));
}

test "an effective tool divides the dig time by its material's efficiency" {
    const wood: Stack = .{ .id = .{ .item = .pickaxe_wood }, .count = 1 };
    const diamond: Stack = .{ .id = .{ .item = .pickaxe_diamond }, .count = 1 };
    try std.testing.expectApproxEqAbs(@as(f32, 22.5), digTicks(.stone, wood), 1.0e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 5.625), digTicks(.stone, diamond), 1.0e-4);
}

test "the wrong tool still harvests rock, only no faster than a hand" {
    const shovel: Stack = .{ .id = .{ .item = .shovel_iron }, .count = 1 };
    try std.testing.expect(!.stone.harvestableWith(shovel));
    try std.testing.expectApproxEqAbs(@as(f32, 150.0), digTicks(.stone, shovel), 1.0e-4);

    const axe: Stack = .{ .id = .{ .item = .axe_diamond }, .count = 1 };
    try std.testing.expectApproxEqAbs(@as(f32, 7.5), digTicks(.log, axe), 1.0e-4);
}

test "an ore only drops for a pickaxe at or above its harvest level" {
    const wood: Stack = .{ .id = .{ .item = .pickaxe_wood }, .count = 1 };
    const stone: Stack = .{ .id = .{ .item = .pickaxe_stone }, .count = 1 };
    const iron: Stack = .{ .id = .{ .item = .pickaxe_iron }, .count = 1 };
    const diamond: Stack = .{ .id = .{ .item = .pickaxe_diamond }, .count = 1 };

    try std.testing.expect(.stone.harvestableWith(wood));
    try std.testing.expect(.ore_coal.harvestableWith(wood));
    try std.testing.expect(!.ore_iron.harvestableWith(wood));
    try std.testing.expect(.ore_iron.harvestableWith(stone));
    try std.testing.expect(!.ore_diamond.harvestableWith(stone));
    try std.testing.expect(.ore_diamond.harvestableWith(iron));
    try std.testing.expect(!.obsidian.harvestableWith(iron));
    try std.testing.expect(.obsidian.harvestableWith(diamond));
}

test "swimming or airborne slows a tool down, but not a bare-handed dig" {
    const pickaxe: Stack = .{ .id = .{ .item = .pickaxe_diamond }, .count = 1 };
    try std.testing.expectApproxEqAbs(@as(f32, 28.125), 1.0 / .stone.strength(pickaxe, 0.2), 1.0e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 150.0), 1.0 / .stone.strength(null, 0.2), 1.0e-4);
}

test "a gold pickaxe digs fastest but harvests least, matching its level of zero" {
    const gold: Stack = .{ .id = .{ .item = .pickaxe_gold }, .count = 1 };
    try std.testing.expectApproxEqAbs(@as(f32, 3.75), digTicks(.stone, gold), 1.0e-4);
    try std.testing.expect(!.ore_iron.harvestableWith(gold));
}

test "snow only drops for a shovel, which is the one thing a shovel harvests" {
    const shovel: Stack = .{ .id = .{ .item = .shovel_wood }, .count = 1 };
    const pickaxe: Stack = .{ .id = .{ .item = .pickaxe_diamond }, .count = 1 };
    try std.testing.expect(!.snow_layer.harvestableWith(null));
    try std.testing.expect(!.snow_block.harvestableWith(pickaxe));
    try std.testing.expect(.snow_layer.harvestableWith(shovel));
    try std.testing.expect(.snow_block.harvestableWith(shovel));
}

test "a sword digs everything at 1.5x, but not what it cannot harvest" {
    const sword: Stack = .{ .id = .{ .item = .sword_diamond }, .count = 1 };
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), digTicks(.dirt, sword), 1.0e-4);
    try std.testing.expect(!.stone.harvestableWith(sword));
    try std.testing.expectApproxEqAbs(@as(f32, 150.0), digTicks(.stone, sword), 1.0e-4);
}

test "bedrock is unbreakable" {
    try std.testing.expectEqual(@as(f32, 0.0), .bedrock.strength(null, 1.0));
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
    try std.testing.expectEqual(@as(f32, 0.125), .snow_layer.heightScale());
    try std.testing.expectEqual(@as(f32, 1.0), .stone.heightScale());
    try std.testing.expect(!.snow_layer.isOpaque());
}

test "grass has a distinct top, bottom and side texture" {
    const textures = .grass.faceTextures();
    try std.testing.expectEqual(@as(u8, 0), textures.get(.up));
    try std.testing.expectEqual(@as(u8, 2), textures.get(.down));
    try std.testing.expectEqual(@as(u8, 3), textures.get(.north));
    try std.testing.expectEqual(@as(u8, 3), textures.get(.east));
}

test "air and cross-shaped plants are the only non-opaque blocks" {
    try std.testing.expect(!.air.isOpaque());
    try std.testing.expect(!.tall_grass.isOpaque());
    try std.testing.expect(.stone.isOpaque());
    try std.testing.expect(.bedrock.isOpaque());
}

test "tall grass picks the fern tile only at metadata 2" {
    try std.testing.expectEqual(@as(u8, 39), .tall_grass.crossTile(1));
    try std.testing.expectEqual(@as(u8, 56), .tall_grass.crossTile(2));
}

test "log side texture varies by wood type metadata" {
    try std.testing.expectEqual(@as(u8, 20), logSideTile(0));
    try std.testing.expectEqual(@as(u8, 116), logSideTile(1));
    try std.testing.expectEqual(@as(u8, 117), logSideTile(2));
}

test "stone drops cobblestone, not itself" {
    var rand = JavaRandom.init(0);
    const dropped = .stone.drop(0, &rand).?;
    try std.testing.expectEqual(Id{ .block = .cobblestone }, dropped.id);
    try std.testing.expectEqual(@as(u8, 1), dropped.count);
}

test "grass drops dirt" {
    var rand = JavaRandom.init(0);
    try std.testing.expectEqual(Id{ .block = .dirt }, .grass.drop(0, &rand).?.id);
}

test "ore blocks drop their raw item form" {
    var rand = JavaRandom.init(0);
    try std.testing.expectEqual(Id{ .item = .coal }, .ore_coal.drop(0, &rand).?.id);
    try std.testing.expectEqual(Id{ .item = .diamond }, .ore_diamond.drop(0, &rand).?.id);
}

test "gold and iron ore self-drop, unlike coal/diamond/lapis/redstone" {
    var rand = JavaRandom.init(0);
    try std.testing.expectEqual(Id{ .block = .ore_gold }, .ore_gold.drop(0, &rand).?.id);
    try std.testing.expectEqual(Id{ .block = .ore_iron }, .ore_iron.drop(0, &rand).?.id);
}

test "lapis ore drops 4-8 lapis dye" {
    var rand = JavaRandom.init(0);
    for (0..50) |_| {
        const dropped = .ore_lapis.drop(0, &rand).?;
        try std.testing.expectEqual(Id{ .item = .dye }, dropped.id);
        try std.testing.expectEqual(item.dye_meta_lapis, dropped.meta);
        try std.testing.expect(dropped.count >= 4 and dropped.count <= 8);
    }
}

test "redstone ore drops 4-5 redstone" {
    var rand = JavaRandom.init(0);
    for (0..50) |_| {
        const dropped = .ore_redstone.drop(0, &rand).?;
        try std.testing.expectEqual(Id{ .item = .redstone }, dropped.id);
        try std.testing.expect(dropped.count >= 4 and dropped.count <= 5);
    }
}

test "log preserves its wood-type metadata when dropped" {
    var rand = JavaRandom.init(0);
    try std.testing.expectEqual(@as(u4, 1), .log.drop(1, &rand).?.meta);
}

test "gravel occasionally drops flint instead of itself" {
    var rand = JavaRandom.init(0);
    var saw_flint = false;
    var saw_gravel = false;
    for (0..200) |_| {
        const dropped = .gravel.drop(0, &rand).?;
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
        if (.leaves.drop(1, &rand)) |dropped| {
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
        if (.tall_grass.drop(0, &rand)) |dropped| {
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
    try std.testing.expect(.dead_bush.drop(0, &rand) == null);
    try std.testing.expect(.mob_spawner.drop(0, &rand) == null);
    try std.testing.expect(.stationary_water.drop(0, &rand) == null);
    try std.testing.expect(.flowing_lava.drop(0, &rand) == null);
}

test "clay always drops 4 clay balls" {
    var rand = JavaRandom.init(0);
    const dropped = .clay.drop(0, &rand).?;
    try std.testing.expectEqual(Id{ .item = .clay_ball }, dropped.id);
    try std.testing.expectEqual(@as(u8, 4), dropped.count);
}

test "reed drops its item form and snow drops a snowball" {
    var rand = JavaRandom.init(0);
    try std.testing.expectEqual(Id{ .item = .reed }, .reed.drop(0, &rand).?.id);
    try std.testing.expectEqual(Id{ .item = .snowball }, .snow_layer.drop(0, &rand).?.id);
}

test "blocks without a special drop rule self-drop with metadata reset to 0" {
    var rand = JavaRandom.init(0);
    const dropped = .pumpkin.drop(3, &rand).?;
    try std.testing.expectEqual(Id{ .block = .pumpkin }, dropped.id);
    try std.testing.expectEqual(@as(u4, 0), dropped.meta);
}

test "only sand and gravel are falling blocks" {
    try std.testing.expect(.sand.isFalling());
    try std.testing.expect(.gravel.isFalling());
    try std.testing.expect(!.stone.isFalling());
    try std.testing.expect(!.dirt.isFalling());
}

test "a falling block can fall into air or liquid, not solid ground" {
    try std.testing.expect(.air.canFallInto());
    try std.testing.expect(.stationary_water.canFallInto());
    try std.testing.expect(.flowing_lava.canFallInto());
    try std.testing.expect(!.stone.canFallInto());
}

test "display names come from the real en_US lang keys, not the enum names" {
    try std.testing.expectEqualStrings("Cobblestone", .cobblestone.displayName(0));
    try std.testing.expectEqualStrings("Wooden Planks", .planks.displayName(0));
    try std.testing.expectEqualStrings("Wood", .log.displayName(0));
    try std.testing.expectEqualStrings("Flower", .dandelion.displayName(0));
    try std.testing.expectEqualStrings("Moss Stone", .cobblestone_mossy.displayName(0));
}

test "blocks with no lang entry have no display name" {
    try std.testing.expectEqualStrings("", .tall_grass.displayName(0));
    try std.testing.expectEqualStrings("", .dead_bush.displayName(0));
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
    try std.testing.expect(.glass.shouldRenderFace(.ice, .up, true));
    try std.testing.expect(.stone.shouldRenderFace(.glass, .up, true));
}

test "glass, bookshelves and ice drop nothing when broken" {
    var rand = JavaRandom.init(0);
    for ([_]Block{ .glass, .bookshelf, .ice }) |id| {
        try std.testing.expectEqual(@as(?Stack, null), id.drop(0, &rand));
    }
}

test "snow blocks and glowstone drop their item form, wool keeps its colour" {
    var rand = JavaRandom.init(0);
    const snow = .snow_block.drop(0, &rand).?;
    try std.testing.expectEqual(Id{ .item = .snowball }, snow.id);
    try std.testing.expectEqual(@as(u8, 4), snow.count);

    const dust = .glowstone.drop(0, &rand).?;
    try std.testing.expectEqual(Id{ .item = .glowstone_dust }, dust.id);
    try std.testing.expect(dust.count >= 2 and dust.count <= 4);

    const wool = .wool.drop(9, &rand).?;
    try std.testing.expectEqual(Id{ .block = .wool }, wool.id);
    try std.testing.expectEqual(@as(u16, 9), wool.meta);
}

test "rock and iron blocks need a tool, other new blocks do not" {
    try std.testing.expectApproxEqAbs(@as(f32, 200.0), digTicks(.brick, null), 1.0e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 500.0), digTicks(.block_iron, null), 1.0e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 24.0), digTicks(.wool, null), 1.0e-4);
}

test "liquids and plants are not solid, so nothing collides with them" {
    try std.testing.expect(!.stationary_water.isSolid());
    try std.testing.expect(!.flowing_water.isSolid());
    try std.testing.expect(!.flowing_lava.isSolid());
    try std.testing.expect(!.air.isSolid());
    try std.testing.expect(!.rose.isSolid());
    try std.testing.expect(!.snow_layer.isSolid());
    try std.testing.expect(.stone.isSolid());
    try std.testing.expect(.leaves.isSolid());
}

test "both water blocks share one material, texture and tick rate" {
    try std.testing.expectEqual(Material.water, .flowing_water.material());
    try std.testing.expectEqual(Material.water, .stationary_water.material());
    try std.testing.expectEqual(.stationary_water.faceTextures(), .flowing_water.faceTextures());
    try std.testing.expectEqual(@as(u32, 5), .flowing_water.tickRate());
    try std.testing.expectEqual(@as(u32, 30), .flowing_lava.tickRate());
    try std.testing.expect(.flowing_water.isTranslucent());
}

test "a liquid culls the face it shares with its own material or with ice" {
    try std.testing.expect(!.flowing_water.shouldRenderFace(.stationary_water, .north, true));
    try std.testing.expect(!.stationary_water.shouldRenderFace(.flowing_water, .north, true));
    try std.testing.expect(!.stationary_water.shouldRenderFace(.ice, .north, true));
    try std.testing.expect(.stationary_water.shouldRenderFace(.flowing_lava, .north, true));
    try std.testing.expect(.stationary_water.shouldRenderFace(.air, .north, true));
}

test "a liquid always draws its top face unless the same liquid sits above it" {
    try std.testing.expect(.stationary_water.shouldRenderFace(.stone, .up, true));
    try std.testing.expect(!.stationary_water.shouldRenderFace(.stationary_water, .up, true));
}

test "saplings draw as a cross, with a tile per tree kind" {
    try std.testing.expect(.sapling.isCross());
    try std.testing.expectEqual(@as(u8, 15), .sapling.crossTile(0));
    try std.testing.expectEqual(@as(u8, 63), .sapling.crossTile(1));
    try std.testing.expectEqual(@as(u8, 79), .sapling.crossTile(2));
    try std.testing.expectEqual(@as(u8, 15), .sapling.crossTile(3));
}

test "a torch is not solid, so nothing collides with it or plants on it" {
    try std.testing.expect(!.torch.isSolid());
    try std.testing.expect(!.torch.isOpaque());
    try std.testing.expect(!.torch.isOpaqueCube());
    try std.testing.expectEqual(Material.circuits, .torch.material());
}

test "a torch breaks instantly and drops itself" {
    var rand = JavaRandom.init(0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), digTicks(.torch, null), 1.0e-4);
    const dropped = .torch.drop(5, &rand).?;
    try std.testing.expectEqual(Id{ .block = .torch }, dropped.id);
    try std.testing.expectEqual(@as(u8, 1), dropped.count);
    try std.testing.expectEqualStrings("Torch", .torch.displayName(0));
}

test "a wall torch stands in the quarter of the block its wall is on" {
    const west = .torch.selectionBounds(1);
    try std.testing.expectEqual(@as(f32, 0.0), west.min[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), west.max[0], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), west.min[1], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), west.max[1], 1.0e-6);

    const east = .torch.selectionBounds(2);
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), east.min[0], 1.0e-6);
    try std.testing.expectEqual(@as(f32, 1.0), east.max[0]);

    const north = .torch.selectionBounds(3);
    try std.testing.expectEqual(@as(f32, 0.0), north.min[2]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), north.max[2], 1.0e-6);

    const south = .torch.selectionBounds(4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), south.min[2], 1.0e-6);
    try std.testing.expectEqual(@as(f32, 1.0), south.max[2]);
}

test "a standing torch is a thin column in the middle of the block" {
    const standing = .torch.selectionBounds(5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), standing.min[0], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), standing.max[0], 1.0e-6);
    try std.testing.expectEqual(@as(f32, 0.0), standing.min[1]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), standing.max[1], 1.0e-6);
    try std.testing.expectEqual(standing, .torch.selectionBounds(0));
}

test "a torch leaves the world as a flat sprite, like a plant does" {
    try std.testing.expectEqual(@as(?u8, 80), .torch.flatItemTile(2));
    try std.testing.expectEqual(@as(?u8, .rose.crossTile(0)), .rose.flatItemTile(0));
    try std.testing.expectEqual(@as(?u8, null), .stone.flatItemTile(0));
    try std.testing.expectEqual(@as(?u8, null), .snow_layer.flatItemTile(0));
}

test "only air, liquids and snow give way to a block placed on top of them" {
    try std.testing.expect(.air.isReplaceable());
    try std.testing.expect(.stationary_water.isReplaceable());
    try std.testing.expect(.flowing_water.isReplaceable());
    try std.testing.expect(.flowing_lava.isReplaceable());
    try std.testing.expect(.snow_layer.isReplaceable());

    try std.testing.expect(!.torch.isReplaceable());
    try std.testing.expect(!.stone.isReplaceable());
    try std.testing.expect(!.tall_grass.isReplaceable());
    try std.testing.expect(!.rose.isReplaceable());
}

test "a closed door fills the three-sixteenths strip on the side it was hung" {
    const north = .door_wood.selectionBounds(1);
    try std.testing.expectEqual(@as(f32, 0.0), north.min[2]);
    try std.testing.expectApproxEqAbs(door_thickness, north.max[2], 1.0e-6);
    try std.testing.expectEqual(@as(f32, 1.0), north.max[0]);
    try std.testing.expectEqual(@as(f32, 1.0), north.max[1]);

    const east = .door_wood.selectionBounds(2);
    try std.testing.expectApproxEqAbs(1.0 - door_thickness, east.min[0], 1.0e-6);
    try std.testing.expectEqual(@as(f32, 1.0), east.max[0]);

    const south = .door_wood.selectionBounds(3);
    try std.testing.expectApproxEqAbs(1.0 - door_thickness, south.min[2], 1.0e-6);

    const west = .door_wood.selectionBounds(0);
    try std.testing.expectApproxEqAbs(door_thickness, west.max[0], 1.0e-6);
}

test "opening a door swings it a quarter turn around its hinge" {
    try std.testing.expectEqual(@as(u2, 3), doorState(0));
    try std.testing.expectEqual(@as(u2, 0), doorState(0 | door_open_bit));
    try std.testing.expectEqual(@as(u2, 0), doorState(1));
    try std.testing.expectEqual(@as(u2, 1), doorState(1 | door_open_bit));
    try std.testing.expectEqual(doorBounds(1), doorBounds(1 | door_top_bit));
}

test "both halves of a door share the state their metadata names" {
    try std.testing.expect(doorIsTop(door_top_bit));
    try std.testing.expect(!doorIsTop(3));
    try std.testing.expect(doorIsOpen(door_open_bit | 2));
    try std.testing.expect(!doorIsOpen(2));
    try std.testing.expectEqual(doorState(2), doorState(2 | door_top_bit));
}

test "a door shows its edge tile on the two sides it is thin against" {
    for ([_]Side{ .west, .east, .up, .down }) |side| {
        const edge = doorFaceTile(.door_wood, side, 1);
        try std.testing.expectEqual(@as(u8, 97), edge.tile);
        try std.testing.expect(!edge.mirrored);
    }
    for ([_]Side{ .north, .south, .up, .down }) |side| {
        try std.testing.expectEqual(@as(u8, 97), doorFaceTile(.door_wood, side, 2).tile);
    }
}

test "the upper half of a door takes the tile a row above the lower one" {
    try std.testing.expectEqual(@as(u8, 97), doorFaceTile(.door_wood, .north, 1).tile);
    try std.testing.expectEqual(@as(u8, 81), doorFaceTile(.door_wood, .north, 1 | door_top_bit).tile);
    try std.testing.expectEqual(@as(u8, 98), doorFaceTile(.door_iron, .north, 1).tile);
    try std.testing.expectEqual(@as(u8, 82), doorFaceTile(.door_iron, .north, 1 | door_top_bit).tile);
}

test "the two faces of a door mirror each other" {
    const north = doorFaceTile(.door_wood, .north, 1);
    const south = doorFaceTile(.door_wood, .south, 1);
    try std.testing.expectEqual(north.tile, south.tile);
    try std.testing.expect(north.mirrored != south.mirrored);

    const west = doorFaceTile(.door_wood, .west, 2);
    const east = doorFaceTile(.door_wood, .east, 2);
    try std.testing.expectEqual(west.tile, east.tile);
    try std.testing.expect(west.mirrored != east.mirrored);
}

test "an open door still shows its face tiles across the way it now stands" {
    const west = doorFaceTile(.door_wood, .west, 1 | door_open_bit);
    const east = doorFaceTile(.door_wood, .east, 1 | door_open_bit);
    try std.testing.expectEqual(@as(u8, 97), west.tile);
    try std.testing.expectEqual(@as(u8, 97), east.tile);
    try std.testing.expect(west.mirrored != east.mirrored);
    try std.testing.expectEqual(@as(u8, 97), doorFaceTile(.door_wood, .north, 1 | door_open_bit).tile);
}

test "a door faces away from the player who placed it, whichever way they were turned" {
    try std.testing.expectEqual(@as(u2, 1), doorFacingFromYaw(0));
    try std.testing.expectEqual(@as(u2, 2), doorFacingFromYaw(90));
    try std.testing.expectEqual(@as(u2, 3), doorFacingFromYaw(180));
    try std.testing.expectEqual(@as(u2, 0), doorFacingFromYaw(270));
    try std.testing.expectEqual(@as(u2, 0), doorFacingFromYaw(-90));
    try std.testing.expectEqual(@as(u2, 1), doorFacingFromYaw(720));
}

test "the hinge step runs across the doorway the facing opens" {
    try std.testing.expectEqual([2]i32{ 0, 1 }, doorHingeStep(0));
    try std.testing.expectEqual([2]i32{ -1, 0 }, doorHingeStep(1));
    try std.testing.expectEqual([2]i32{ 0, -1 }, doorHingeStep(2));
    try std.testing.expectEqual([2]i32{ 1, 0 }, doorHingeStep(3));
}

test "only the lower half of a door drops the item, and iron needs a pickaxe" {
    var rand = JavaRandom.init(0);
    const dropped = .door_wood.drop(1, &rand).?;
    try std.testing.expectEqual(Id{ .item = .door_wood }, dropped.id);
    try std.testing.expectEqual(@as(u8, 1), dropped.count);
    try std.testing.expectEqual(@as(?Stack, null), .door_wood.drop(1 | door_top_bit, &rand));

    try std.testing.expectEqual(Id{ .item = .door_iron }, .door_iron.drop(1, &rand).?.id);
    try std.testing.expectEqual(@as(?Stack, null), .door_iron.drop(1 | door_top_bit, &rand));

    const pickaxe: Stack = .{ .id = .{ .item = .pickaxe_wood }, .count = 1 };
    try std.testing.expect(.door_wood.harvestableWith(null));
    try std.testing.expect(!.door_iron.harvestableWith(null));
    try std.testing.expect(.door_iron.harvestableWith(pickaxe));
}

test "a door is solid to walk into but never culls the face beside it" {
    try std.testing.expect(.door_wood.isSolid());
    try std.testing.expect(.door_iron.isSolid());
    try std.testing.expect(!.door_wood.isOpaqueCube());
    try std.testing.expect(!.door_iron.isOpaqueCube());
    try std.testing.expect(.stone.shouldRenderFace(.door_wood, .north, true));
    try std.testing.expect(.door_wood.isDoor());
    try std.testing.expect(!.planks.isDoor());
}

test "a slab's metadata picks which block it was cut from" {
    const stone = slabTextures(slab_stone);
    try std.testing.expectEqual(@as(u8, 6), stone.get(.up));
    try std.testing.expectEqual(@as(u8, 6), stone.get(.down));
    try std.testing.expectEqual(@as(u8, 5), stone.get(.north));

    const sand = slabTextures(slab_sandstone);
    try std.testing.expectEqual(@as(u8, 176), sand.get(.up));
    try std.testing.expectEqual(@as(u8, 208), sand.get(.down));
    try std.testing.expectEqual(@as(u8, 192), sand.get(.east));

    try std.testing.expectEqual(uniform(4), slabTextures(slab_wood));
    try std.testing.expectEqual(uniform(16), slabTextures(slab_cobblestone));

    for (4..16) |meta| {
        try std.testing.expectEqual(stone, slabTextures(@intCast(meta)));
    }
}

test "a single slab is the bottom half of its block, a double slab the whole of it" {
    const half = .slab.selectionBounds(0);
    try std.testing.expectEqual([3]f32{ 0, 0, 0 }, half.min);
    try std.testing.expectEqual([3]f32{ 1, 0.5, 1 }, half.max);

    const whole = .slab_double.selectionBounds(0);
    try std.testing.expectEqual([3]f32{ 1, 1, 1 }, whole.max);

    try std.testing.expect(!.slab.isOpaqueCube());
    try std.testing.expect(.slab_double.isOpaqueCube());
    try std.testing.expect(.slab.isSolid() and .slab_double.isSolid());
}

test "a slab always draws its top face, even buried" {
    for ([_]Block{ .slab, .slab_double }) |id| {
        try std.testing.expect(id.shouldRenderFace(.stone, .up, true));
        try std.testing.expect(id.shouldRenderFace(id, .up, true));

        try std.testing.expect(!id.shouldRenderFace(.stone, .down, true));
        try std.testing.expect(id.shouldRenderFace(.air, .down, true));
    }

    try std.testing.expect(.slab.shouldRenderFace(.slab, .down, true));
    try std.testing.expect(!.slab_double.shouldRenderFace(.slab_double, .down, true));
}

test "a slab hides the side it shares with a slab of its own id" {
    try std.testing.expect(!.slab.shouldRenderFace(.slab, .north, true));
    try std.testing.expect(!.slab_double.shouldRenderFace(.slab_double, .east, true));

    try std.testing.expect(!.slab.shouldRenderFace(.slab_double, .north, true));
    try std.testing.expect(.slab_double.shouldRenderFace(.slab, .north, true));
    try std.testing.expect(.slab.shouldRenderFace(.air, .north, true));
    try std.testing.expect(!.slab.shouldRenderFace(.stone, .north, true));
}

test "a double slab drops two single slabs, both keeping the metadata" {
    var rand = JavaRandom.init(0);
    for ([_]u4{ slab_stone, slab_sandstone, slab_wood, slab_cobblestone }) |meta| {
        const single = .slab.drop(meta, &rand).?;
        try std.testing.expectEqual(Id{ .block = .slab }, single.id);
        try std.testing.expectEqual(@as(u8, 1), single.count);
        try std.testing.expectEqual(@as(u16, meta), single.meta);

        const double = .slab_double.drop(meta, &rand).?;
        try std.testing.expectEqual(Id{ .block = .slab }, double.id);
        try std.testing.expectEqual(@as(u8, 2), double.count);
        try std.testing.expectEqual(@as(u16, meta), double.meta);
    }
}

test "a stair splits into a half-height tread and a full-height back" {
    for (0..4) |facing| {
        const boxes = stairsBoxes(@intCast(facing));
        var half_count: usize = 0;
        for (boxes) |box| {
            try std.testing.expectEqual(@as(f32, 0.0), box.min[1]);
            if (box.max[1] == 0.5) half_count += 1 else try std.testing.expectEqual(@as(f32, 1.0), box.max[1]);

            const width = (box.max[0] - box.min[0]) * (box.max[2] - box.min[2]);
            try std.testing.expectApproxEqAbs(@as(f32, 0.5), width, 1.0e-6);
        }
        try std.testing.expectEqual(@as(usize, 1), half_count);
    }
}

test "the two halves of a stair meet without a gap or an overlap" {
    for (0..4) |facing| {
        const boxes = stairsBoxes(@intCast(facing));
        const split_axis: usize = if (facing < 2) 0 else 2;
        const low = if (boxes[0].min[split_axis] == 0.0) boxes[0] else boxes[1];
        const high = if (boxes[0].min[split_axis] == 0.0) boxes[1] else boxes[0];
        try std.testing.expectEqual(@as(f32, 0.5), low.max[split_axis]);
        try std.testing.expectEqual(@as(f32, 0.5), high.min[split_axis]);
        try std.testing.expectEqual(@as(f32, 1.0), high.max[split_axis]);
    }
}

test "a stair's tall half turns away from the player who placed it" {
    try std.testing.expectEqual(@as(u4, 2), stairsFacingFromYaw(0));
    try std.testing.expectEqual(@as(u4, 1), stairsFacingFromYaw(90));
    try std.testing.expectEqual(@as(u4, 3), stairsFacingFromYaw(180));
    try std.testing.expectEqual(@as(u4, 0), stairsFacingFromYaw(270));
    try std.testing.expectEqual(@as(u4, 0), stairsFacingFromYaw(-90));
    try std.testing.expectEqual(@as(u4, 2), stairsFacingFromYaw(-720));

    const facing_north = stairsBoxes(stairsFacingFromYaw(0));
    try std.testing.expectEqual(@as(f32, 1.0), facing_north[1].max[1]);
    try std.testing.expectEqual(@as(f32, 0.5), facing_north[1].min[2]);
}

test "a stair keeps its neighbours' faces and is selected as a whole block" {
    for ([_]Block{ .stairs_wood, .stairs_cobblestone }) |id| {
        try std.testing.expect(id.isStairs());
        try std.testing.expect(id.isSolid());
        try std.testing.expect(!id.isOpaqueCube());
        try std.testing.expect(.stone.shouldRenderFace(id, .north, true));

        const cube: Bounds = .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 1 } };
        try std.testing.expectEqual(cube, id.selectionBounds(0));
        try std.testing.expectEqual(cube, id.selectionBounds(3));
    }
    try std.testing.expect(!.planks.isStairs());
}

test "a stair drops the block it was cut from, not itself" {
    var rand = JavaRandom.init(0);
    try std.testing.expectEqual(Id{ .block = .planks }, .stairs_wood.drop(0, &rand).?.id);
    try std.testing.expectEqual(Id{ .block = .cobblestone }, .stairs_cobblestone.drop(0, &rand).?.id);
}

test "a shut trapdoor is the bottom three sixteenths of its block" {
    const shut = .trapdoor.selectionBounds(0);
    try std.testing.expectEqual([3]f32{ 0, 0, 0 }, shut.min);
    try std.testing.expectEqual(@as(f32, 1.0), shut.max[0]);
    try std.testing.expectApproxEqAbs(trapdoor_thickness, shut.max[1], 1.0e-6);
    try std.testing.expectEqual(@as(f32, 1.0), shut.max[2]);

    for (0..4) |facing| {
        try std.testing.expectEqual(shut, .trapdoor.selectionBounds(@intCast(facing)));
    }
}

test "an open trapdoor stands up against the wall that holds it" {
    const open = trapdoor_open_bit;

    const south = .trapdoor.selectionBounds(open);
    try std.testing.expectApproxEqAbs(1.0 - trapdoor_thickness, south.min[2], 1.0e-6);
    try std.testing.expectEqual(@as(f32, 1.0), south.max[1]);

    const north = .trapdoor.selectionBounds(open + 1);
    try std.testing.expectApproxEqAbs(trapdoor_thickness, north.max[2], 1.0e-6);

    const east = .trapdoor.selectionBounds(open + 2);
    try std.testing.expectApproxEqAbs(1.0 - trapdoor_thickness, east.min[0], 1.0e-6);

    const west = .trapdoor.selectionBounds(open + 3);
    try std.testing.expectApproxEqAbs(trapdoor_thickness, west.max[0], 1.0e-6);
}

test "a trapdoor hangs off the wall it was clicked onto" {
    try std.testing.expectEqual(@as(?u4, 0), trapdoorFacingFromFace(.north));
    try std.testing.expectEqual(@as(?u4, 1), trapdoorFacingFromFace(.south));
    try std.testing.expectEqual(@as(?u4, 2), trapdoorFacingFromFace(.west));
    try std.testing.expectEqual(@as(?u4, 3), trapdoorFacingFromFace(.east));
    try std.testing.expectEqual(@as(?u4, null), trapdoorFacingFromFace(.up));
    try std.testing.expectEqual(@as(?u4, null), trapdoorFacingFromFace(.down));
}

test "the wall holding a trapdoor sits opposite the face it was placed against" {
    try std.testing.expectEqual([3]i32{ 0, 0, 1 }, trapdoorSupportStep(0));
    try std.testing.expectEqual([3]i32{ 0, 0, -1 }, trapdoorSupportStep(1));
    try std.testing.expectEqual([3]i32{ 1, 0, 0 }, trapdoorSupportStep(2));
    try std.testing.expectEqual([3]i32{ -1, 0, 0 }, trapdoorSupportStep(3));
    try std.testing.expectEqual(trapdoorSupportStep(2), trapdoorSupportStep(2 | trapdoor_open_bit));
}

test "a trapdoor is wood that drops itself with its swing forgotten" {
    var rand = JavaRandom.init(0);
    const dropped = .trapdoor.drop(2 | trapdoor_open_bit, &rand).?;
    try std.testing.expectEqual(Id{ .block = .trapdoor }, dropped.id);
    try std.testing.expectEqual(@as(u16, 0), dropped.meta);

    try std.testing.expectEqual(Material.wood, .trapdoor.material());
    try std.testing.expect(.trapdoor.harvestableWith(null));
    try std.testing.expect(.trapdoor.isTrapdoor());
    try std.testing.expect(!.trapdoor.isOpaqueCube());
    try std.testing.expectEqual(@as(u8, 84), .trapdoor.faceTextures().get(.down));
    try std.testing.expectEqualStrings("Trapdoor", .trapdoor.displayName(0));
}

test "grass wears the snow side texture when snow is piled on it" {
    try std.testing.expectEqual(grass_side_tile, grassSideTile(.air));
    try std.testing.expectEqual(grass_side_tile, grassSideTile(.stone));
    try std.testing.expectEqual(@as(u8, 68), grassSideTile(.snow_layer));
    try std.testing.expectEqual(@as(u8, 68), grassSideTile(.snow_block));
}

test "a full cube is the default model when held, dropped or drawn in a slot" {
    const cube: Bounds = .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 1 } };
    for ([_]Block{ .stone, .snow_layer, .door_wood, .cactus, .torch }) |id| {
        try std.testing.expectEqualSlices(Bounds, &.{cube}, id.itemRenderBoxes());
    }

    const plate = .trapdoor.itemRenderBoxes()[0];
    try std.testing.expectEqual([2]f32{ 0, 0 }, [2]f32{ plate.min[0], plate.min[2] });
    try std.testing.expectEqual([2]f32{ 1, 1 }, [2]f32{ plate.max[0], plate.max[2] });
    try std.testing.expectApproxEqAbs(trapdoor_thickness, plate.max[1] - plate.min[1], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), (plate.max[1] + plate.min[1]) / 2.0, 1.0e-6);
}

test "each wool colour is named by its inverted metadata, as ItemCloth does" {
    const expected = [16][]const u8{
        "Wool",            "Orange Wool", "Magenta Wool", "Light Blue Wool",
        "Yellow Wool",     "Lime Wool",   "Pink Wool",    "Gray Wool",
        "Light Gray Wool", "Cyan Wool",   "Purple Wool",  "Blue Wool",
        "Brown Wool",      "Green Wool",  "Red Wool",     "Black Wool",
    };
    for (expected, 0..) |name, meta| {
        try std.testing.expectEqualStrings(name, .wool.displayName(@intCast(meta)));
    }
}

test "a wool stack carries its colour through to the name shown in a slot" {
    const black: Stack = .{ .id = .{ .block = .wool }, .count = 1, .meta = 15 };
    try std.testing.expectEqualStrings("Black Wool", black.displayName());

    const white: Stack = .{ .id = .{ .block = .wool }, .count = 1, .meta = 0 };
    try std.testing.expectEqualStrings("Wool", white.displayName());
}

test "the sheep's fleece colours all name a wool a player would recognise" {
    try std.testing.expectEqualStrings("Black Wool", .wool.displayName(15));
    try std.testing.expectEqualStrings("Gray Wool", .wool.displayName(7));
    try std.testing.expectEqualStrings("Light Gray Wool", .wool.displayName(8));
    try std.testing.expectEqualStrings("Brown Wool", .wool.displayName(12));
    try std.testing.expectEqualStrings("Pink Wool", .wool.displayName(6));
    try std.testing.expectEqualStrings("Wool", .wool.displayName(0));
}

test "a slab is named after the block it was cut from" {
    try std.testing.expectEqualStrings("Stone Slab", .slab.displayName(slab_stone));
    try std.testing.expectEqualStrings("Sandstone Slab", .slab.displayName(slab_sandstone));
    try std.testing.expectEqualStrings("Wooden Slab", .slab.displayName(slab_wood));
    try std.testing.expectEqualStrings("Stone Slab", .slab.displayName(slab_cobblestone));
    try std.testing.expectEqualStrings("Wooden Slab", .slab_double.displayName(slab_wood));

    const stack: Stack = .{ .id = .{ .block = .slab }, .count = 1, .meta = slab_sandstone };
    try std.testing.expectEqualStrings("Sandstone Slab", stack.displayName());
}

test "blocks without variants read the same whatever metadata they carry" {
    for (0..16) |meta| {
        try std.testing.expectEqualStrings("Cobblestone", .cobblestone.displayName(@intCast(meta)));
        try std.testing.expectEqualStrings("Wood", .log.displayName(@intCast(meta)));
    }
}
