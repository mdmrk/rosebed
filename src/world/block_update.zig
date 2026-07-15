const std = @import("std");
const World = @import("world_map.zig");
const block = @import("block.zig");
const Block = block.Block;
const light = @import("light.zig");

const fall_check_radius: i32 = 32;

fn plantGrowsOn(id: Block, below: Block) bool {
    return switch (id) {
        .dead_bush => below == .sand,
        .mushroom_brown, .mushroom_red => below.isOpaqueCube(),
        else => below == .grass or below == .dirt,
    };
}

fn reedCanStay(world_map: *const World, x: i32, y: i32, z: i32) bool {
    const below = world_map.getBlock(x, y - 1, z);
    if (below == .reed) return true;
    if (below != .grass and below != .dirt) return false;
    return world_map.getBlock(x - 1, y - 1, z).material() == .water or
        world_map.getBlock(x + 1, y - 1, z).material() == .water or
        world_map.getBlock(x, y - 1, z - 1).material() == .water or
        world_map.getBlock(x, y - 1, z + 1).material() == .water;
}

fn cactusCanStay(world_map: *const World, x: i32, y: i32, z: i32) bool {
    if (world_map.getBlock(x - 1, y, z).isSolid()) return false;
    if (world_map.getBlock(x + 1, y, z).isSolid()) return false;
    if (world_map.getBlock(x, y, z - 1).isSolid()) return false;
    if (world_map.getBlock(x, y, z + 1).isSolid()) return false;

    const below = world_map.getBlock(x, y - 1, z);
    return below == .cactus or below == .sand;
}

pub fn canStayAt(world_map: *const World, x: i32, y: i32, z: i32, id: Block) bool {
    return switch (id) {
        .sapling, .dandelion, .rose, .tall_grass, .dead_bush => (light.levelAt(world_map, x, y, z) >= 8 or
            world_map.canBlockSeeTheSky(x, y, z)) and plantGrowsOn(id, world_map.getBlock(x, y - 1, z)),
        .mushroom_brown, .mushroom_red => light.levelAt(world_map, x, y, z) <= 13 and
            plantGrowsOn(id, world_map.getBlock(x, y - 1, z)),
        .reed => reedCanStay(world_map, x, y, z),
        .cactus => cactusCanStay(world_map, x, y, z),
        .snow_layer => world_map.getBlock(x, y - 1, z).isOpaqueCube(),
        else => true,
    };
}

pub fn canPlaceAt(world_map: *const World, x: i32, y: i32, z: i32, id: Block) bool {
    return switch (id) {
        .sapling, .dandelion, .rose, .tall_grass, .dead_bush, .mushroom_brown, .mushroom_red => plantGrowsOn(id, world_map.getBlock(x, y - 1, z)),
        else => canStayAt(world_map, x, y, z, id),
    };
}

pub fn onNeighborChange(world_map: *World, x: i32, y: i32, z: i32) std.mem.Allocator.Error!void {
    const id = world_map.getBlock(x, y, z);
    if (canStayAt(world_map, x, y, z, id)) return;

    if (id.drop(world_map.getBlockMetadata(x, y, z), &world_map.rand)) |stack| {
        try world_map.dropped.append(world_map.allocator, .{
            .pos = .{ .x = x, .y = y, .z = z },
            .stack = stack,
        });
    }
    try world_map.setBlockWithNotify(x, y, z, .air);
}

/// The falling entity itself lives in the game layer, so the world only queues
/// the spawn. Far from any loaded chunk the block drops to its resting place at
/// once, the way the original skips the entity while generating terrain.
pub fn tickFalling(world_map: *World, x: i32, y: i32, z: i32) std.mem.Allocator.Error!void {
    if (y < 0) return;
    if (!world_map.getBlock(x, y - 1, z).canFallInto()) return;
    const id = world_map.getBlock(x, y, z);

    if (!world_map.scheduled_updates_are_immediate and world_map.chunksExist(
        x - fall_check_radius,
        y - fall_check_radius,
        z - fall_check_radius,
        x + fall_check_radius,
        y + fall_check_radius,
        z + fall_check_radius,
    )) {
        try world_map.falling.append(world_map.allocator, .{
            .pos = .{ .x = x, .y = y, .z = z },
            .id = id,
        });
        try world_map.setBlockWithNotify(x, y, z, .air);
        return;
    }

    try world_map.setBlockWithNotify(x, y, z, .air);
    var rest = y;
    while (rest > 0 and world_map.getBlock(x, rest - 1, z).canFallInto()) rest -= 1;
    if (rest > 0) try world_map.setBlockWithNotify(x, rest, z, id);
}

const testing_world = @import("testing.zig");

fn reedWorld(height: i32) !World {
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    errdefer w.deinit();

    w.setBlock(8, 11, 8, .grass);
    w.setBlock(7, 11, 8, .stationary_water);
    var y: i32 = 0;
    while (y < height) : (y += 1) w.setBlock(8, 12 + y, 8, .reed);
    return w;
}

test "breaking the bottom of a sugar cane column takes the whole column with it" {
    var w = try reedWorld(3);
    defer w.deinit();

    try w.setBlockWithNotify(8, 12, 8, .air);

    try std.testing.expectEqual(Block.air, w.getBlock(8, 13, 8));
    try std.testing.expectEqual(Block.air, w.getBlock(8, 14, 8));
    try std.testing.expectEqual(@as(usize, 2), w.dropped.items.len);
}

test "breaking the middle of a sugar cane column leaves the part below standing" {
    var w = try reedWorld(3);
    defer w.deinit();

    try w.setBlockWithNotify(8, 13, 8, .air);

    try std.testing.expectEqual(Block.reed, w.getBlock(8, 12, 8));
    try std.testing.expectEqual(Block.air, w.getBlock(8, 14, 8));
    try std.testing.expectEqual(@as(usize, 1), w.dropped.items.len);
}

test "digging out the soil takes the sugar cane standing on it" {
    var w = try reedWorld(2);
    defer w.deinit();

    try w.setBlockWithNotify(8, 11, 8, .air);

    try std.testing.expectEqual(Block.air, w.getBlock(8, 12, 8));
    try std.testing.expectEqual(Block.air, w.getBlock(8, 13, 8));
}

test "a flower pops and drops itself when the dirt under it is dug out" {
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    defer w.deinit();
    w.setBlock(8, 11, 8, .dirt);
    w.setBlock(8, 12, 8, .rose);

    try w.setBlockWithNotify(8, 11, 8, .air);

    try std.testing.expectEqual(Block.air, w.getBlock(8, 12, 8));
    try std.testing.expectEqual(@as(usize, 1), w.dropped.items.len);
    try std.testing.expectEqual(Block.rose, w.dropped.items[0].stack.id.block);
}

test "a mushroom needs an opaque cube under it, a flower needs grass or dirt" {
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    defer w.deinit();

    try std.testing.expect(canStayAt(&w, 8, 12, 8, .mushroom_brown));
    try std.testing.expect(!canStayAt(&w, 8, 12, 8, .rose));
    try std.testing.expect(!canStayAt(&w, 8, 12, 8, .dead_bush));

    w.setBlock(8, 11, 8, .grass);
    try std.testing.expect(canStayAt(&w, 8, 12, 8, .rose));
    try std.testing.expect(canStayAt(&w, 8, 12, 8, .tall_grass));

    w.setBlock(8, 11, 8, .sand);
    try std.testing.expect(canStayAt(&w, 8, 12, 8, .dead_bush));
    try std.testing.expect(!canStayAt(&w, 8, 12, 8, .rose));
}

test "a cactus pops when a solid block is put beside it" {
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    defer w.deinit();
    w.setBlock(8, 11, 8, .sand);
    w.setBlock(8, 12, 8, .cactus);
    w.setBlock(8, 13, 8, .cactus);

    try w.setBlockWithNotify(9, 12, 8, .stone);

    try std.testing.expectEqual(Block.air, w.getBlock(8, 12, 8));
    try std.testing.expectEqual(Block.air, w.getBlock(8, 13, 8));
    try std.testing.expectEqual(@as(usize, 2), w.dropped.items.len);
}

test "a snow layer pops when the block holding it up goes away" {
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    defer w.deinit();
    w.setBlock(8, 12, 8, .snow_layer);

    try std.testing.expect(canStayAt(&w, 8, 12, 8, .snow_layer));
    try w.setBlockWithNotify(8, 11, 8, .air);
    try std.testing.expectEqual(Block.air, w.getBlock(8, 12, 8));
}

test "placing ignores the light level but still needs the right block below" {
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    defer w.deinit();
    w.setBlock(8, 11, 8, .grass);

    try std.testing.expect(canPlaceAt(&w, 8, 12, 8, .rose));
    try std.testing.expect(!canPlaceAt(&w, 8, 12, 8, .reed));
    try std.testing.expect(canPlaceAt(&w, 8, 12, 8, .stone));

    w.setBlock(7, 11, 8, .stationary_water);
    try std.testing.expect(canPlaceAt(&w, 8, 12, 8, .reed));
}

/// A sand column only schedules an update once the chunks around it are loaded,
/// so these tests need more than the single chunk a flat world gives them.
fn pillarWorld() !World {
    var w = World.init(std.testing.allocator);
    errdefer w.deinit();

    var chunk_x: i32 = -3;
    while (chunk_x <= 3) : (chunk_x += 1) {
        var chunk_z: i32 = -3;
        while (chunk_z <= 3) : (chunk_z += 1) _ = try w.createChunk(chunk_x, chunk_z);
    }

    var y: i32 = 0;
    while (y < 12) : (y += 1) w.setBlock(8, y, 8, .stone);
    return w;
}

test "digging out the block under a sand column drops the column one at a time" {
    var w = try pillarWorld();
    defer w.deinit();
    w.setBlock(8, 12, 8, .sand);
    w.setBlock(8, 13, 8, .sand);

    try w.setBlockWithNotify(8, 11, 8, .air);
    try std.testing.expectEqual(@as(usize, 0), w.falling.items.len);

    w.time += 3;
    try w.tickUpdates();
    try std.testing.expectEqual(@as(usize, 1), w.falling.items.len);
    try std.testing.expectEqual(Block.air, w.getBlock(8, 12, 8));

    w.time += 3;
    try w.tickUpdates();
    try std.testing.expectEqual(@as(usize, 2), w.falling.items.len);
    try std.testing.expectEqual(Block.air, w.getBlock(8, 13, 8));
}

test "with immediate updates sand slides down to its resting place at once" {
    var w = try pillarWorld();
    defer w.deinit();
    w.scheduled_updates_are_immediate = true;

    try w.setBlockWithNotify(8, 20, 8, .sand);

    try std.testing.expectEqual(Block.air, w.getBlock(8, 20, 8));
    try std.testing.expectEqual(Block.sand, w.getBlock(8, 12, 8));
    try std.testing.expectEqual(@as(usize, 0), w.falling.items.len);
}
