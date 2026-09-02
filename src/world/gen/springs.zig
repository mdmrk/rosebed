const std = @import("std");

const block = @import("../block.zig");
const Block = @import("../block.zig").Block;
const BlockPos = @import("../BlockPos.zig");
const World = @import("../World.zig");

pub fn generate(world_map: *World, pos: BlockPos, liquid_id: Block) !void {
    if (world_map.getBlock(pos.offset(0, 1, 0)) != .stone) return;
    if (world_map.getBlock(pos.offset(0, -1, 0)) != .stone) return;

    const current = world_map.getBlock(pos);
    if (current != .air and current != .stone) return;

    var stone_sides: u32 = 0;
    var open_sides: u32 = 0;
    for ([_][2]i32{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } }) |offset| {
        const neighbor = world_map.getBlock(pos.offset(offset[0], 0, offset[1]));
        if (neighbor == .stone) stone_sides += 1;
        if (neighbor == .air) open_sides += 1;
    }

    if (stone_sides != 3 or open_sides != 1) return;

    world_map.scheduled_updates_are_immediate = true;
    defer world_map.scheduled_updates_are_immediate = false;
    try world_map.setBlockWithNotify(pos, liquid_id);
}

pub fn generateHell(world_map: *World, pos: BlockPos, liquid_id: Block) !void {
    if (world_map.getBlock(pos.offset(0, 1, 0)) != .netherrack) return;

    const current = world_map.getBlock(pos);
    if (current != .air and current != .netherrack) return;

    var netherrack_sides: u32 = 0;
    var open_sides: u32 = 0;
    for ([_][3]i32{ .{ -1, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 0, -1 }, .{ 0, 0, 1 }, .{ 0, -1, 0 } }) |offset| {
        const neighbor = world_map.getBlock(pos.offset(offset[0], offset[1], offset[2]));
        if (neighbor == .netherrack) netherrack_sides += 1;
        if (neighbor == .air) open_sides += 1;
    }

    if (netherrack_sides != 4 or open_sides != 1) return;

    world_map.scheduled_updates_are_immediate = true;
    defer world_map.scheduled_updates_are_immediate = false;
    try world_map.setBlockWithNotify(pos, liquid_id);
}

fn stoneWorldWithOpening(opening_x: i32, opening_z: i32) !World {
    var w = World.init(std.testing.allocator);
    var chunk_x: i32 = -1;
    while (chunk_x <= 1) : (chunk_x += 1) {
        var chunk_z: i32 = -1;
        while (chunk_z <= 1) : (chunk_z += 1) {
            const chunk = try w.createChunk(chunk_x, chunk_z);
            for (0..16) |x| {
                for (0..16) |z| {
                    for (30..40) |y| {
                        chunk.setBlock(@intCast(x), @intCast(y), @intCast(z), .stone);
                    }
                }
            }
        }
    }
    w.setBlock(.init(8, 35, 8), .air);
    w.setBlock(.init(opening_x, 35, opening_z), .air);
    return w;
}

test "a spring forms in a stone wall with a single open side" {
    var w = try stoneWorldWithOpening(9, 8);
    defer w.deinit();

    try generate(&w, .init(8, 35, 8), .flowing_water);
    try std.testing.expectEqual(block.Material.water, w.getBlock(.init(8, 35, 8)).material());
}

test "a water spring has already run its course when generation returns" {
    var w = try stoneWorldWithOpening(9, 8);
    defer w.deinit();
    for (30..35) |y| {
        w.setBlock(.init(9, @intCast(y), 8), .air);
    }

    try generate(&w, .init(8, 35, 8), .flowing_water);

    try std.testing.expectEqual(block.Material.water, w.getBlock(.init(9, 30, 8)).material());
    try std.testing.expectEqual(@as(usize, 0), w.scheduled.items.len);
    try std.testing.expect(!w.scheduled_updates_are_immediate);
}

test "a lava spring has already run its course when generation returns" {
    var w = try stoneWorldWithOpening(9, 8);
    defer w.deinit();
    for (30..35) |y| {
        w.setBlock(.init(9, @intCast(y), 8), .air);
    }

    try generate(&w, .init(8, 35, 8), .flowing_lava);

    try std.testing.expectEqual(block.Material.lava, w.getBlock(.init(9, 30, 8)).material());
    try std.testing.expectEqual(@as(usize, 0), w.scheduled.items.len);
}

fn netherrackWorldWithOpening(opening: [3]i32) !World {
    var w = World.init(std.testing.allocator);
    var chunk_x: i32 = -1;
    while (chunk_x <= 1) : (chunk_x += 1) {
        var chunk_z: i32 = -1;
        while (chunk_z <= 1) : (chunk_z += 1) {
            const chunk = try w.createChunk(chunk_x, chunk_z);
            for (0..16) |x| {
                for (0..16) |z| {
                    for (30..40) |y| {
                        chunk.setBlock(@intCast(x), @intCast(y), @intCast(z), .netherrack);
                    }
                }
            }
        }
    }
    w.setBlock(.init(8, 35, 8), .air);
    w.setBlock(.init(opening[0], opening[1], opening[2]), .air);
    return w;
}

test "a hell lava spring forms in netherrack with a single opening, on a side or below" {
    var beside = try netherrackWorldWithOpening(.{ 9, 35, 8 });
    defer beside.deinit();
    try generateHell(&beside, .init(8, 35, 8), .flowing_lava);
    try std.testing.expectEqual(block.Material.lava, beside.getBlock(.init(8, 35, 8)).material());

    var below = try netherrackWorldWithOpening(.{ 8, 34, 8 });
    defer below.deinit();
    try generateHell(&below, .init(8, 35, 8), .flowing_lava);
    try std.testing.expectEqual(block.Material.lava, below.getBlock(.init(8, 35, 8)).material());
}

test "a hell lava spring needs netherrack overhead and only one way out" {
    var two_open = try netherrackWorldWithOpening(.{ 9, 35, 8 });
    defer two_open.deinit();
    two_open.setBlock(.init(7, 35, 8), .air);
    try generateHell(&two_open, .init(8, 35, 8), .flowing_lava);
    try std.testing.expectEqual(.air, two_open.getBlock(.init(8, 35, 8)));

    var uncapped = try netherrackWorldWithOpening(.{ 9, 35, 8 });
    defer uncapped.deinit();
    uncapped.setBlock(.init(8, 36, 8), .air);
    try generateHell(&uncapped, .init(8, 35, 8), .flowing_lava);
    try std.testing.expectEqual(.air, uncapped.getBlock(.init(8, 35, 8)));

    var stone = try stoneWorldWithOpening(9, 8);
    defer stone.deinit();
    try generateHell(&stone, .init(8, 35, 8), .flowing_lava);
    try std.testing.expectEqual(.air, stone.getBlock(.init(8, 35, 8)));
}

test "a spring does not form where two sides are open" {
    var w = try stoneWorldWithOpening(9, 8);
    defer w.deinit();
    w.setBlock(.init(7, 35, 8), .air);

    try generate(&w, .init(8, 35, 8), .flowing_water);
    try std.testing.expectEqual(.air, w.getBlock(.init(8, 35, 8)));
}

test "a spring does not form without stone above and below" {
    var w = try stoneWorldWithOpening(9, 8);
    defer w.deinit();
    w.setBlock(.init(8, 36, 8), .air);

    try generate(&w, .init(8, 35, 8), .flowing_water);
    try std.testing.expectEqual(.air, w.getBlock(.init(8, 35, 8)));
}
