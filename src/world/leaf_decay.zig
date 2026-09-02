const std = @import("std");

const block = @import("block.zig");
const Block = block.Block;
const BlockPos = @import("BlockPos.zig");
const World = @import("World.zig");

pub const check_bit: u4 = 8;
const reach: i32 = 4;
const side: usize = @intCast(reach * 2 + 1);

pub fn onBlockRemoved(world_map: *World, pos: BlockPos, removed: Block) void {
    const radius: i32 = switch (removed) {
        .log => reach,
        .leaves => 1,
        else => return,
    };
    if (!world_map.chunksExist(pos.x - radius - 1, pos.y - radius - 1, pos.z - radius - 1, pos.x + radius + 1, pos.y + radius + 1, pos.z + radius + 1)) return;

    var dx = -radius;
    while (dx <= radius) : (dx += 1) {
        var dy = -radius;
        while (dy <= radius) : (dy += 1) {
            var dz = -radius;
            while (dz <= radius) : (dz += 1) {
                if (world_map.getBlock(pos.offset(dx, dy, dz)) != .leaves) continue;
                const meta = world_map.getBlockMetadata(pos.offset(dx, dy, dz));
                world_map.setBlockMetadata(pos.offset(dx, dy, dz), meta | check_bit);
            }
        }
    }
}

pub fn tick(world_map: *World, pos: BlockPos) !void {
    if (world_map.getBlock(pos) != .leaves) return;
    const meta = world_map.getBlockMetadata(pos);
    if (meta & check_bit == 0) return;
    if (!world_map.chunksExist(pos.x - reach - 1, pos.y - reach - 1, pos.z - reach - 1, pos.x + reach + 1, pos.y + reach + 1, pos.z + reach + 1)) return;

    if (hasLogInReach(world_map, pos)) {
        world_map.setBlockMetadata(pos, meta & ~check_bit);
        return;
    }

    if (Block.leaves.drop(meta, &world_map.rand)) |stack| {
        try world_map.dropped.append(world_map.allocator, .{
            .pos = .{ .x = pos.x, .y = pos.y, .z = pos.z },
            .stack = stack,
        });
    }
    try world_map.setBlockWithNotify(pos, .air);
}

fn hasLogInReach(world_map: *const World, pos: BlockPos) bool {
    var cells: [side][side][side]i8 = undefined;
    for (0..side) |ix| {
        for (0..side) |iy| {
            for (0..side) |iz| {
                cells[ix][iy][iz] = switch (world_map.getBlock(
                    .init(pos.x + @as(i32, @intCast(ix)) - reach, pos.y + @as(i32, @intCast(iy)) - reach, pos.z + @as(i32, @intCast(iz)) - reach),
                )) {
                    .log => 0,
                    .leaves => -2,
                    else => -1,
                };
            }
        }
    }

    var step: i8 = 1;
    while (step <= reach) : (step += 1) {
        for (0..side) |ix| {
            for (0..side) |iy| {
                for (0..side) |iz| {
                    if (cells[ix][iy][iz] != step - 1) continue;
                    spreadFrom(&cells, ix, iy, iz, step);
                }
            }
        }
    }

    const center: usize = @intCast(reach);
    return cells[center][center][center] >= 0;
}

fn spreadFrom(cells: *[side][side][side]i8, ix: usize, iy: usize, iz: usize, step: i8) void {
    const offsets = [6][3]i32{
        .{ -1, 0, 0 }, .{ 1, 0, 0 },
        .{ 0, -1, 0 }, .{ 0, 1, 0 },
        .{ 0, 0, -1 }, .{ 0, 0, 1 },
    };
    for (offsets) |offset| {
        const nx = @as(i32, @intCast(ix)) + offset[0];
        const ny = @as(i32, @intCast(iy)) + offset[1];
        const nz = @as(i32, @intCast(iz)) + offset[2];
        if (nx < 0 or ny < 0 or nz < 0) continue;
        if (nx >= side or ny >= side or nz >= side) continue;
        const cell = &cells[@intCast(nx)][@intCast(ny)][@intCast(nz)];
        if (cell.* == -2) cell.* = step;
    }
}

test "removing a log flags the leaves around it for a decay check" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    _ = try w.createChunk(0, 0);

    w.setBlock(.init(8, 20, 8), .log);
    w.setBlock(.init(8, 24, 8), .leaves);
    w.setBlock(.init(12, 20, 12), .leaves);
    w.setBlock(.init(8, 20, 13), .leaves);

    try w.setBlockWithNotify(.init(8, 20, 8), .air);

    try std.testing.expect(w.getBlockMetadata(.init(8, 24, 8)) & check_bit != 0);
    try std.testing.expect(w.getBlockMetadata(.init(12, 20, 12)) & check_bit != 0);
    try std.testing.expect(w.getBlockMetadata(.init(8, 20, 13)) & check_bit == 0);
}

test "harvesting leaves flags only the directly neighbouring leaves" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    _ = try w.createChunk(0, 0);

    w.setBlock(.init(8, 20, 8), .leaves);
    w.setBlock(.init(9, 20, 8), .leaves);
    w.setBlock(.init(11, 20, 8), .leaves);

    try w.setBlockWithNotify(.init(8, 20, 8), .air);

    try std.testing.expect(w.getBlockMetadata(.init(9, 20, 8)) & check_bit != 0);
    try std.testing.expect(w.getBlockMetadata(.init(11, 20, 8)) & check_bit == 0);
}

test "a flagged leaf within reach of a log keeps its foliage" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    _ = try w.createChunk(0, 0);

    w.setBlock(.init(8, 20, 8), .log);
    var y: i32 = 21;
    while (y <= 24) : (y += 1) w.setBlock(.init(8, y, 8), .leaves);
    w.setBlockMetadata(.init(8, 24, 8), check_bit);

    try tick(&w, .init(8, 24, 8));

    try std.testing.expectEqual(.leaves, w.getBlock(.init(8, 24, 8)));
    try std.testing.expectEqual(@as(u4, 0), w.getBlockMetadata(.init(8, 24, 8)));
}

test "a flagged leaf out of reach of any log decays away" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    _ = try w.createChunk(0, 0);

    w.setBlock(.init(8, 20, 8), .log);
    var y: i32 = 21;
    while (y <= 25) : (y += 1) w.setBlock(.init(8, y, 8), .leaves);
    w.setBlockMetadata(.init(8, 25, 8), check_bit);

    try tick(&w, .init(8, 25, 8));

    try std.testing.expectEqual(.air, w.getBlock(.init(8, 25, 8)));
    try std.testing.expect(w.getBlockMetadata(.init(8, 24, 8)) & check_bit != 0);
}

test "an unflagged leaf is left alone" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    _ = try w.createChunk(0, 0);

    w.setBlock(.init(8, 30, 8), .leaves);

    try tick(&w, .init(8, 30, 8));

    try std.testing.expectEqual(.leaves, w.getBlock(.init(8, 30, 8)));
}

test "decayed pine leaves occasionally drop a pine sapling" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    _ = try w.createChunk(0, 0);

    var x: i32 = 0;
    while (x < 16) : (x += 1) {
        var z: i32 = 0;
        while (z < 16) : (z += 1) {
            w.setBlock(.init(x, 40, z), .leaves);
            w.setBlockMetadata(.init(x, 40, z), 1 | check_bit);
        }
    }

    x = 0;
    while (x < 16) : (x += 1) {
        var z: i32 = 0;
        while (z < 16) : (z += 1) {
            try tick(&w, .init(x, 40, z));
        }
    }

    try std.testing.expect(w.dropped.items.len > 0);
    for (w.dropped.items) |entry| {
        try std.testing.expectEqual(block.Id{ .block = .sapling }, entry.stack.id);
        try std.testing.expectEqual(@as(u16, 1), entry.stack.meta);
    }
}

test "random ticks eventually decay a flagged floating canopy" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    _ = try w.createChunk(0, 0);

    var x: i32 = 0;
    while (x < 16) : (x += 1) {
        var z: i32 = 0;
        while (z < 16) : (z += 1) {
            w.setBlock(.init(x, 64, z), .leaves);
            w.setBlockMetadata(.init(x, 64, z), check_bit);
        }
    }

    var decayed: usize = 0;
    var ticks: usize = 0;
    while (ticks < 2000 and decayed == 0) : (ticks += 1) {
        try w.tickRandomBlocks(0, 0);
        x = 0;
        while (x < 16) : (x += 1) {
            var z: i32 = 0;
            while (z < 16) : (z += 1) {
                if (w.getBlock(.init(x, 64, z)) == .air) decayed += 1;
            }
        }
    }

    try std.testing.expect(decayed > 0);
}
