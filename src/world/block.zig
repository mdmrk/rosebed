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
    ground,
    sand,
    wood,
    leaves,
    plants,
    water,
    lava,
    snow,
    clay,
    pumpkin,

    pub fn blocksGrass(self: Material) bool {
        return switch (self) {
            .air, .plants, .snow => false,
            else => true,
        };
    }

    pub fn isLiquid(self: Material) bool {
        return switch (self) {
            .water, .lava => true,
            else => false,
        };
    }
};

pub const Shape = union(enum) {
    cube,
    cross,
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

pub const Stack = struct {
    id: Id,
    count: u8,
    meta: u4 = 0,
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
    stationary_water = 9,
    flowing_lava = 10,
    sand = 12,
    gravel = 13,
    ore_gold = 14,
    ore_iron = 15,
    ore_coal = 16,
    log = 17,
    leaves = 18,
    ore_lapis = 21,
    tall_grass = 31,
    dead_bush = 32,
    dandelion = 37,
    rose = 38,
    mushroom_brown = 39,
    mushroom_red = 40,
    cobblestone_mossy = 48,
    mob_spawner = 52,
    ore_diamond = 56,
    ore_redstone = 73,
    snow_layer = 78,
    clay = 82,
    reed = 83,
    pumpkin = 86,
    _,

    pub fn material(self: Block) Material {
        return switch (self) {
            .air => .air,
            .stone, .cobblestone, .cobblestone_mossy, .bedrock, .mob_spawner => .rock,
            .ore_gold, .ore_iron, .ore_coal, .ore_lapis, .ore_diamond, .ore_redstone => .rock,
            .grass, .dirt => .ground,
            .sand, .gravel => .sand,
            .planks, .log => .wood,
            .leaves => .leaves,
            .sapling, .tall_grass, .dead_bush, .dandelion, .rose, .mushroom_brown, .mushroom_red, .reed => .plants,
            .stationary_water => .water,
            .flowing_lava => .lava,
            .snow_layer => .snow,
            .clay => .clay,
            .pumpkin => .pumpkin,
            else => .rock,
        };
    }

    pub fn shape(self: Block) Shape {
        return switch (self) {
            .tall_grass, .dead_bush, .dandelion, .rose, .mushroom_brown, .mushroom_red, .reed => .cross,
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

    pub fn isOpaque(self: Block) bool {
        return self.material().blocksGrass();
    }

    pub fn isLiquid(self: Block) bool {
        return self.material().isLiquid();
    }

    pub fn isOpaqueCube(self: Block) bool {
        return self.isOpaque() and !self.isLiquid() and self != .leaves;
    }

    pub fn isTranslucent(self: Block) bool {
        return self == .stationary_water;
    }

    pub fn isFalling(self: Block) bool {
        return self == .sand or self == .gravel;
    }

    pub fn canFallInto(self: Block) bool {
        return self == .air or self.isLiquid();
    }

    pub fn selectionBounds(self: Block) Bounds {
        return switch (self) {
            .tall_grass, .dead_bush => plantBounds(0.4, 0.8),
            .dandelion, .rose => plantBounds(0.2, 0.6),
            .mushroom_brown, .mushroom_red => plantBounds(0.2, 0.4),
            .reed => plantBounds(6.0 / 16.0, 1.0),
            else => .{ .min = .{ 0, 0, 0 }, .max = .{ 1, self.heightScale(), 1 } },
        };
    }

    pub fn shouldRenderFace(self: Block, neighbor: Block, side: Side, fancy: bool) bool {
        if (self.isLiquid()) {
            if (neighbor == self) return false;
            if (side == .up) return true;
        }
        if (self == .leaves and !fancy and neighbor == .leaves) return false;
        return !neighbor.isOpaqueCube();
    }

    pub fn faceTextures(self: Block) FaceTextures {
        return switch (self) {
            .stone => uniform(1),
            .grass => topAndSide(0, 2, 3),
            .dirt => uniform(2),
            .planks => uniform(4),
            .bedrock => uniform(17),
            .stationary_water => topAndSide(205, 205, 206),
            .flowing_lava => topAndSide(237, 237, 238),
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
            .pumpkin => topAndSide(102, 102, 118),
            .snow_layer => uniform(66),
            .cobblestone => uniform(16),
            .cobblestone_mossy => uniform(36),
            .mob_spawner => uniform(65),
            else => uniform(0),
        };
    }

    pub fn crossTile(self: Block, metadata: u4) u8 {
        return switch (self) {
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

    fn hardness(self: Block) f32 {
        return switch (self) {
            .stone => 1.5,
            .grass => 0.6,
            .dirt => 0.5,
            .planks => 2.0,
            .bedrock => -1.0,
            .stationary_water => 100.0,
            .flowing_lava => 0.0,
            .sand => 0.5,
            .gravel => 0.6,
            .ore_gold, .ore_iron, .ore_coal, .ore_lapis, .ore_diamond, .ore_redstone => 3.0,
            .log => 2.0,
            .leaves => 0.2,
            .clay => 0.6,
            .pumpkin => 1.0,
            .snow_layer => 0.1,
            .cobblestone, .cobblestone_mossy => 2.0,
            .mob_spawner => 5.0,
            else => 0.0,
        };
    }

    fn isHarvestableByHand(self: Block) bool {
        return switch (self) {
            .stone, .ore_gold, .ore_iron, .ore_coal, .ore_lapis, .ore_diamond, .ore_redstone, .cobblestone, .cobblestone_mossy, .mob_spawner => false,
            else => true,
        };
    }

    pub fn digTicksRequired(self: Block) ?f32 {
        const h = self.hardness();
        if (h < 0.0) return null;
        const divisor: f32 = if (self.isHarvestableByHand()) 30.0 else 100.0;
        return h * divisor;
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
            .mob_spawner => null,
            .stationary_water, .flowing_lava => null,
            else => .{ .id = .{ .block = self }, .count = 1 },
        };
    }
};

pub fn leafTile(metadata: u4, fancy: bool) u8 {
    const base: u8 = if (fancy) 52 else 53;
    return if (metadata & 3 == 1) base + 80 else base;
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

test "digTicksRequired matches hardness*30 for hand-harvestable blocks" {
    try std.testing.expectApproxEqAbs(@as(f32, 15.0), Block.dirt.digTicksRequired().?, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 60.0), Block.log.digTicksRequired().?, 1.0e-6);
}

test "digTicksRequired matches hardness*100 for blocks needing a tool" {
    try std.testing.expectApproxEqAbs(@as(f32, 150.0), Block.stone.digTicksRequired().?, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 300.0), Block.ore_diamond.digTicksRequired().?, 1.0e-6);
}

test "bedrock is unbreakable" {
    try std.testing.expect(Block.bedrock.digTicksRequired() == null);
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
