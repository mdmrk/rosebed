const std = @import("std");

const block = @import("block.zig");
const Block = block.Block;
const block_update = @import("block_update.zig");
const BlockPos = @import("BlockPos.zig");
const Chunk = @import("Chunk.zig");
const decorate = @import("gen/decorate.zig");
const light = @import("light.zig");
const testing_world = @import("testing.zig");
const World = @import("World.zig");

pub const tickPlant = block_update.popIfUnsupported;

const grass_death_light: u4 = 4;
const grass_death_opacity: u8 = 2;
const grass_death_odds: i32 = 4;
const grass_spread_light: u4 = 9;
const grass_seed_light: u4 = 4;

pub fn tickGrass(world_map: *World, pos: BlockPos, _: Block) std.mem.Allocator.Error!void {
    const rand = &world_map.rand;
    const above = pos.offset(0, 1, 0);
    const overhead = light.levelAt(world_map, above);

    if (overhead < grass_death_light and light.opacity(world_map.getBlock(above)) > grass_death_opacity) {
        if (rand.nextIntBound(grass_death_odds) != 0) return;
        try world_map.setBlockWithNotify(pos, .dirt);
        return;
    }
    if (overhead < grass_spread_light) return;

    const seed: BlockPos = .init(
        pos.x + rand.nextIntBound(3) - 1,
        pos.y + rand.nextIntBound(5) - 3,
        pos.z + rand.nextIntBound(3) - 1,
    );
    const over_seed = seed.offset(0, 1, 0);
    if (world_map.getBlock(seed) != .dirt) return;
    if (light.levelAt(world_map, over_seed) < grass_seed_light) return;
    if (light.opacity(world_map.getBlock(over_seed)) > grass_death_opacity) return;
    try world_map.setBlockWithNotify(seed, .grass);
}

const sapling_kind_mask: u4 = 3;
const sapling_ready: u4 = 8;
const sapling_growth_light: u4 = 9;
const sapling_growth_odds: i32 = 30;
const sapling_spruce: u4 = 1;
const sapling_birch: u4 = 2;
const big_tree_odds: i32 = 10;

pub fn tickSapling(world_map: *World, pos: BlockPos, id: Block) std.mem.Allocator.Error!void {
    try tickPlant(world_map, pos, id);
    if (world_map.getBlock(pos) != id) return;

    if (light.levelAt(world_map, pos.offset(0, 1, 0)) < sapling_growth_light) return;
    if (world_map.rand.nextIntBound(sapling_growth_odds) != 0) return;

    const metadata = world_map.getBlockMetadata(pos);
    if (metadata & sapling_ready == 0) {
        try world_map.setBlockMetadataWithNotify(pos, metadata | sapling_ready);
        return;
    }
    try growTree(world_map, pos, metadata & sapling_kind_mask);
}

fn growTree(world_map: *World, pos: BlockPos, kind: u4) std.mem.Allocator.Error!void {
    const rand = &world_map.rand;
    world_map.setBlock(pos, .air);

    const grown = switch (kind) {
        sapling_spruce => decorate.generateSpruceTree(world_map, rand, pos),
        sapling_birch => decorate.generateBirchTree(world_map, rand, pos.x, pos.y, pos.z),
        else => if (rand.nextIntBound(big_tree_odds) == 0)
            decorate.generateBigTree(world_map, rand, pos.x, pos.y, pos.z)
        else
            decorate.generateTree(world_map, rand, pos.x, pos.y, pos.z),
    };

    if (!grown) {
        world_map.setBlock(pos, .sapling);
        world_map.setBlockMetadata(pos, kind);
        return;
    }
    try markTreeColumns(world_map, pos);
}

fn markTreeColumns(world_map: *World, pos: BlockPos) std.mem.Allocator.Error!void {
    const half = Chunk.width / 2;
    const chunk_x = @divFloor(pos.x, Chunk.width);
    const chunk_z = @divFloor(pos.z, Chunk.width);

    var dx: i32 = -1;
    while (dx <= 1) : (dx += 1) {
        var dz: i32 = -1;
        while (dz <= 1) : (dz += 1) {
            try world_map.markChanged(.init(
                (chunk_x + dx) * Chunk.width + half,
                pos.y,
                (chunk_z + dz) * Chunk.width + half,
            ));
        }
    }
}

const stalk_max_height: i32 = 3;
const stalk_ripe: u4 = 15;

pub fn tickStalk(world_map: *World, pos: BlockPos, id: Block) std.mem.Allocator.Error!void {
    const above = pos.offset(0, 1, 0);
    if (world_map.getBlock(above) != .air) return;

    var height: i32 = 1;
    while (world_map.getBlock(pos.offset(0, -height, 0)) == id) height += 1;
    if (height >= stalk_max_height) return;

    const metadata = world_map.getBlockMetadata(pos);
    if (metadata != stalk_ripe) {
        try world_map.setBlockMetadataWithNotify(pos, metadata + 1);
        return;
    }
    try world_map.setBlockWithNotify(above, id);
    try world_map.setBlockMetadataWithNotify(pos, 0);
}

const mushroom_spread_odds: i32 = 100;
const mushroom_discarded_draws: usize = 2;

pub fn tickMushroom(world_map: *World, pos: BlockPos, id: Block) std.mem.Allocator.Error!void {
    const rand = &world_map.rand;
    if (rand.nextIntBound(mushroom_spread_odds) != 0) return;

    const to: BlockPos = .init(
        pos.x + rand.nextIntBound(3) - 1,
        pos.y + rand.nextIntBound(2) - rand.nextIntBound(2),
        pos.z + rand.nextIntBound(3) - 1,
    );
    if (world_map.getBlock(to) != .air) return;
    if (!block_update.canStayAt(world_map, to, id)) return;

    for (0..mushroom_discarded_draws) |_| _ = rand.nextIntBound(3);
    try world_map.setBlockWithNotify(to, id);
}

const melt_light: u8 = 11;

fn meltInto(world_map: *World, pos: BlockPos, id: Block, becomes: Block) std.mem.Allocator.Error!void {
    if (id.drop(world_map.getBlockMetadata(pos), &world_map.rand)) |stack| {
        try world_map.dropped.append(world_map.allocator, .{
            .pos = .{ .x = pos.x, .y = pos.y, .z = pos.z },
            .stack = stack,
        });
    }
    try world_map.setBlockWithNotify(pos, becomes);
}

pub fn meltIce(world_map: *World, pos: BlockPos, id: Block) std.mem.Allocator.Error!void {
    if (world_map.getBlockLight(pos) <= melt_light - light.opacity(.ice)) return;
    try meltInto(world_map, pos, id, .stationary_water);
}

pub fn meltSnow(world_map: *World, pos: BlockPos, id: Block) std.mem.Allocator.Error!void {
    if (world_map.getBlockLight(pos) <= melt_light) return;
    try meltInto(world_map, pos, id, .air);
}

test "grass in the dark under a solid block turns back to dirt" {
    var w = try testing_world.flatWorld(std.testing.allocator, 1);
    defer w.deinit();

    w.setBlock(.init(8, 1, 8), .grass);
    w.setBlock(.init(8, 2, 8), .stone);
    try light.relightChunk(std.testing.allocator, &w, 0, 0);

    var rolls: usize = 0;
    while (rolls < 64 and w.getBlock(.init(8, 1, 8)) == .grass) : (rolls += 1) {
        try tickGrass(&w, .init(8, 1, 8), .grass);
    }
    try std.testing.expectEqual(Block.dirt, w.getBlock(.init(8, 1, 8)));
}

test "grass under open sky stays grass however long it is ticked" {
    var w = try testing_world.flatWorld(std.testing.allocator, 1);
    defer w.deinit();

    w.setBlock(.init(8, 1, 8), .grass);
    try light.relightChunk(std.testing.allocator, &w, 0, 0);

    for (0..64) |_| try tickGrass(&w, .init(8, 1, 8), .grass);
    try std.testing.expectEqual(Block.grass, w.getBlock(.init(8, 1, 8)));
}

test "lit grass seeds the dirt around it" {
    var w = try testing_world.flatWorld(std.testing.allocator, 1);
    defer w.deinit();

    var x: i32 = 6;
    while (x <= 10) : (x += 1) {
        var z: i32 = 6;
        while (z <= 10) : (z += 1) w.setBlock(.init(x, 1, z), .dirt);
    }
    w.setBlock(.init(8, 1, 8), .grass);
    try light.relightChunk(std.testing.allocator, &w, 0, 0);

    for (0..256) |_| try tickGrass(&w, .init(8, 1, 8), .grass);

    var spread: usize = 0;
    x = 6;
    while (x <= 10) : (x += 1) {
        var z: i32 = 6;
        while (z <= 10) : (z += 1) {
            if (w.getBlock(.init(x, 1, z)) == .grass) spread += 1;
        }
    }
    try std.testing.expect(spread > 1);
}

test "grass never seeds dirt that is roofed over" {
    var w = try testing_world.flatWorld(std.testing.allocator, 1);
    defer w.deinit();

    w.setBlock(.init(8, 1, 8), .grass);
    w.setBlock(.init(9, 1, 8), .dirt);
    w.setBlock(.init(9, 2, 8), .stone);
    try light.relightChunk(std.testing.allocator, &w, 0, 0);

    for (0..256) |_| try tickGrass(&w, .init(8, 1, 8), .grass);
    try std.testing.expectEqual(Block.dirt, w.getBlock(.init(9, 1, 8)));
}

fn saplingWorld() !World {
    var w = try testing_world.flatWorld(std.testing.allocator, 3);
    errdefer w.deinit();

    w.setBlock(.init(8, 1, 8), .dirt);
    try w.setBlockWithNotify(.init(8, 2, 8), .sapling);
    try light.relightChunk(std.testing.allocator, &w, 0, 0);
    return w;
}

test "a sapling arms itself before it grows" {
    var w = try saplingWorld();
    defer w.deinit();

    while (w.getBlockMetadata(.init(8, 2, 8)) & sapling_ready == 0) {
        try tickSapling(&w, .init(8, 2, 8), .sapling);
        try std.testing.expectEqual(Block.sapling, w.getBlock(.init(8, 2, 8)));
    }
}

test "an armed sapling grows into a tree" {
    var w = try saplingWorld();
    defer w.deinit();

    try w.setBlockMetadataWithNotify(.init(8, 2, 8), sapling_ready);

    var ticks: usize = 0;
    while (ticks < 4096 and w.getBlock(.init(8, 2, 8)) == .sapling) : (ticks += 1) {
        try tickSapling(&w, .init(8, 2, 8), .sapling);
    }
    try std.testing.expectEqual(Block.log, w.getBlock(.init(8, 2, 8)));

    var leaves: usize = 0;
    for (0..16) |x| {
        for (0..16) |z| {
            var y: u32 = 0;
            while (y < 32) : (y += 1) {
                if (w.getChunk(0, 0).?.getBlock(@intCast(x), y, @intCast(z)) == .leaves) leaves += 1;
            }
        }
    }
    try std.testing.expect(leaves > 0);
}

test "a grown tree tells the world about every column it could have reached" {
    var w = try saplingWorld();
    defer w.deinit();

    try w.setBlockMetadataWithNotify(.init(8, 2, 8), sapling_ready);
    w.changed.clearRetainingCapacity();

    var ticks: usize = 0;
    while (ticks < 4096 and w.getBlock(.init(8, 2, 8)) == .sapling) : (ticks += 1) {
        try tickSapling(&w, .init(8, 2, 8), .sapling);
    }
    try std.testing.expectEqual(Block.log, w.getBlock(.init(8, 2, 8)));

    var columns: [3][3]bool = @splat(@splat(false));
    for (w.changed.items) |at| {
        const dx = @divFloor(at.x, Chunk.width) + 1;
        const dz = @divFloor(at.z, Chunk.width) + 1;
        if (dx < 0 or dx > 2 or dz < 0 or dz > 2) continue;
        columns[@intCast(dx)][@intCast(dz)] = true;
    }
    for (columns) |row| {
        for (row) |seen| try std.testing.expect(seen);
    }
}

test "a sapling with no room over its head stays a sapling, keeping the kind it was" {
    var w = try testing_world.flatWorld(std.testing.allocator, 1);
    defer w.deinit();

    w.setBlock(.init(8, 125, 8), .dirt);
    try w.setBlockAndMetadataWithNotify(.init(8, 126, 8), .sapling, sapling_ready | sapling_birch);
    try light.relightChunk(std.testing.allocator, &w, 0, 0);

    for (0..256) |_| try tickSapling(&w, .init(8, 126, 8), .sapling);
    try std.testing.expectEqual(Block.sapling, w.getBlock(.init(8, 126, 8)));
    try std.testing.expectEqual(sapling_birch, w.getBlockMetadata(.init(8, 126, 8)) & sapling_kind_mask);
}

test "a sapling lit to exactly eight holds its ground without growing" {
    var w = try roofedWorld(1, 6);
    defer w.deinit();

    w.setBlock(.init(8, 1, 8), .dirt);
    try w.setBlockAndMetadataWithNotify(.init(8, 2, 8), .sapling, sapling_ready);
    try light.relightChunk(std.testing.allocator, &w, 0, 0);
    w.setBlockLight(.init(8, 2, 8), 8);
    w.setBlockLight(.init(8, 3, 8), 8);

    for (0..1024) |_| try tickSapling(&w, .init(8, 2, 8), .sapling);
    try std.testing.expectEqual(Block.sapling, w.getBlock(.init(8, 2, 8)));
}

test "a sapling left with nothing under it pops off before it can grow" {
    var w = try saplingWorld();
    defer w.deinit();

    w.setBlock(.init(8, 1, 8), .air);
    try tickSapling(&w, .init(8, 2, 8), .sapling);
    try std.testing.expectEqual(Block.air, w.getBlock(.init(8, 2, 8)));
}

fn roofedWorld(floor_height: u32, roof_y: u32) !World {
    var w = try testing_world.flatWorld(std.testing.allocator, floor_height);
    errdefer w.deinit();

    const chunk = w.getChunk(0, 0).?;
    for (0..Chunk.width) |x| {
        for (0..Chunk.width) |z| chunk.setBlock(@intCast(x), roof_y, @intCast(z), .stone);
    }
    return w;
}

fn stalkWorld(id: Block, footing: Block) !World {
    var w = try testing_world.flatWorld(std.testing.allocator, 1);
    errdefer w.deinit();

    w.setBlock(.init(8, 1, 8), footing);
    if (id == .reed) w.setBlock(.init(7, 1, 8), .stationary_water);
    w.setBlock(.init(8, 2, 8), id);
    return w;
}

test "a cactus ripens through its metadata and then puts up a new block" {
    var w = try stalkWorld(.cactus, .sand);
    defer w.deinit();

    var ticks: usize = 0;
    while (ticks <= stalk_ripe) : (ticks += 1) {
        try std.testing.expectEqual(@as(u4, @intCast(ticks)), w.getBlockMetadata(.init(8, 2, 8)));
        try std.testing.expectEqual(Block.air, w.getBlock(.init(8, 3, 8)));
        try tickStalk(&w, .init(8, 2, 8), .cactus);
    }
    try std.testing.expectEqual(Block.cactus, w.getBlock(.init(8, 3, 8)));
    try std.testing.expectEqual(@as(u4, 0), w.getBlockMetadata(.init(8, 2, 8)));
}

test "sugar cane grows the same way a cactus does" {
    var w = try stalkWorld(.reed, .dirt);
    defer w.deinit();

    for (0..@as(usize, stalk_ripe) + 1) |_| try tickStalk(&w, .init(8, 2, 8), .reed);
    try std.testing.expectEqual(Block.reed, w.getBlock(.init(8, 3, 8)));
}

test "a stalk stops at three blocks tall" {
    var w = try stalkWorld(.cactus, .sand);
    defer w.deinit();

    w.setBlock(.init(8, 3, 8), .cactus);
    w.setBlock(.init(8, 4, 8), .cactus);
    w.setBlockMetadata(.init(8, 4, 8), stalk_ripe);

    for (0..64) |_| try tickStalk(&w, .init(8, 4, 8), .cactus);
    try std.testing.expectEqual(Block.air, w.getBlock(.init(8, 5, 8)));
    try std.testing.expectEqual(stalk_ripe, w.getBlockMetadata(.init(8, 4, 8)));
}

test "a stalk with a block over its head does not grow at all" {
    var w = try stalkWorld(.cactus, .sand);
    defer w.deinit();

    w.setBlock(.init(8, 3, 8), .stone);
    w.setBlockMetadata(.init(8, 2, 8), stalk_ripe);

    for (0..64) |_| try tickStalk(&w, .init(8, 2, 8), .cactus);
    try std.testing.expectEqual(stalk_ripe, w.getBlockMetadata(.init(8, 2, 8)));
}

fn mushroomWorld() !World {
    var w = try roofedWorld(3, 8);
    errdefer w.deinit();

    w.setBlock(.init(8, 3, 8), .mushroom_brown);
    try light.relightChunk(std.testing.allocator, &w, 0, 0);
    return w;
}

fn spreadNextTo(world_map: *const World, pos: BlockPos, id: Block) bool {
    var x = pos.x - 1;
    while (x <= pos.x + 1) : (x += 1) {
        var z = pos.z - 1;
        while (z <= pos.z + 1) : (z += 1) {
            if (x == pos.x and z == pos.z) continue;
            if (world_map.getBlock(.init(x, pos.y, z)) == id) return true;
        }
    }
    return false;
}

test "a mushroom spreads onto a dark neighbouring block" {
    var w = try mushroomWorld();
    defer w.deinit();

    for (0..4096) |_| try tickMushroom(&w, .init(8, 3, 8), .mushroom_brown);
    try std.testing.expect(spreadNextTo(&w, .init(8, 3, 8), .mushroom_brown));
}

test "a mushroom is too bright to spread under an open sky" {
    var w = try testing_world.flatWorld(std.testing.allocator, 3);
    defer w.deinit();

    w.setBlock(.init(8, 3, 8), .mushroom_brown);
    try light.relightChunk(std.testing.allocator, &w, 0, 0);

    for (0..4096) |_| try tickMushroom(&w, .init(8, 3, 8), .mushroom_brown);
    try std.testing.expect(!spreadNextTo(&w, .init(8, 3, 8), .mushroom_brown));
}

test "a spreading mushroom draws the two offsets BlockMushroom discards" {
    var w = try mushroomWorld();
    defer w.deinit();

    var spread = false;
    var ticks: usize = 0;
    while (ticks < 4096 and !spread) : (ticks += 1) {
        var expected = w.rand;
        try tickMushroom(&w, .init(8, 3, 8), .mushroom_brown);
        if (!spreadNextTo(&w, .init(8, 3, 8), .mushroom_brown)) continue;

        _ = expected.nextIntBound(mushroom_spread_odds);
        _ = expected.nextIntBound(3);
        _ = expected.nextIntBound(2);
        _ = expected.nextIntBound(2);
        _ = expected.nextIntBound(3);
        for (0..mushroom_discarded_draws) |_| _ = expected.nextIntBound(3);
        try std.testing.expectEqual(expected.seed, w.rand.seed);
        spread = true;
    }
    try std.testing.expect(spread);
}

test "ice melts into still water once the block light passes eight" {
    var w = try testing_world.flatWorld(std.testing.allocator, 1);
    defer w.deinit();

    w.setBlock(.init(8, 1, 8), .ice);
    w.setBlockLight(.init(8, 1, 8), 8);
    try meltIce(&w, .init(8, 1, 8), .ice);
    try std.testing.expectEqual(Block.ice, w.getBlock(.init(8, 1, 8)));

    w.setBlockLight(.init(8, 1, 8), 9);
    try meltIce(&w, .init(8, 1, 8), .ice);
    try std.testing.expectEqual(Block.stationary_water, w.getBlock(.init(8, 1, 8)));
    try std.testing.expectEqual(@as(usize, 0), w.dropped.items.len);
}

test "a snow layer melts away leaving nothing behind" {
    var w = try testing_world.flatWorld(std.testing.allocator, 1);
    defer w.deinit();

    w.setBlock(.init(8, 1, 8), .snow_layer);
    w.setBlockLight(.init(8, 1, 8), 11);
    try meltSnow(&w, .init(8, 1, 8), .snow_layer);
    try std.testing.expectEqual(Block.snow_layer, w.getBlock(.init(8, 1, 8)));

    w.setBlockLight(.init(8, 1, 8), 12);
    try meltSnow(&w, .init(8, 1, 8), .snow_layer);
    try std.testing.expectEqual(Block.air, w.getBlock(.init(8, 1, 8)));
    try std.testing.expectEqual(@as(usize, 0), w.dropped.items.len);
}

test "a melting snow block leaves its four snowballs" {
    var w = try testing_world.flatWorld(std.testing.allocator, 1);
    defer w.deinit();

    w.setBlock(.init(8, 1, 8), .snow_block);
    w.setBlockLight(.init(8, 1, 8), 12);
    try meltSnow(&w, .init(8, 1, 8), .snow_block);

    try std.testing.expectEqual(Block.air, w.getBlock(.init(8, 1, 8)));
    try std.testing.expectEqual(@as(usize, 1), w.dropped.items.len);
    try std.testing.expectEqual(block.Id{ .item = .snowball }, w.dropped.items[0].stack.id);
    try std.testing.expectEqual(@as(u8, 4), w.dropped.items[0].stack.count);
}

test "the world's own random tick seam grows grass over a dirt field" {
    var w = try testing_world.flatWorld(std.testing.allocator, 2);
    defer w.deinit();

    const chunk = w.getChunk(0, 0).?;
    for (0..Chunk.width) |x| {
        for (0..Chunk.width) |z| chunk.setBlock(@intCast(x), 1, @intCast(z), .dirt);
    }
    w.setBlock(.init(8, 1, 8), .grass);
    try light.relightChunk(std.testing.allocator, &w, 0, 0);

    for (0..512) |_| try w.tickRandomBlocks(0, 0);

    var grass: usize = 0;
    for (0..Chunk.width) |x| {
        for (0..Chunk.width) |z| {
            if (chunk.getBlock(@intCast(x), 1, @intCast(z)) == .grass) grass += 1;
        }
    }
    try std.testing.expect(grass > 1);
}

test "the random tick registry reaches every block that grows or melts" {
    for ([_]Block{
        .grass,
        .sapling,
        .cactus,
        .reed,
        .mushroom_brown,
        .mushroom_red,
        .dandelion,
        .rose,
        .tall_grass,
        .dead_bush,
        .ice,
        .snow_layer,
        .snow_block,
        .crops,
        .farmland,
        .locked_chest,
    }) |id| {
        try std.testing.expect(id.def().on_random_tick != null);
    }
    try std.testing.expect(Block.stone.def().on_random_tick == null);
    try std.testing.expect(Block.dirt.def().on_random_tick == null);
}
