const std = @import("std");
const Chunk = @import("chunk.zig");
const World = @import("world_map.zig");
const block = @import("block.zig");
const constants = @import("constants.zig");

pub fn flatWorld(allocator: std.mem.Allocator, floor_height: u32) !World {
    var w = World.init(allocator);
    errdefer w.deinit();

    const chunk = try w.createChunk(0, 0);
    for (0..constants.chunk_width) |x| {
        for (0..constants.chunk_width) |z| {
            var y: u32 = 0;
            while (y < floor_height) : (y += 1) {
                chunk.setBlockId(@intCast(x), y, @intCast(z), block.stone);
            }
        }
    }
    return w;
}

test "the floor is solid up to the requested height and open above it" {
    var w = try flatWorld(std.testing.allocator, 2);
    defer w.deinit();

    try std.testing.expectEqual(block.stone, w.getBlockId(8, 0, 8));
    try std.testing.expectEqual(block.stone, w.getBlockId(8, 1, 8));
    try std.testing.expectEqual(block.air, w.getBlockId(8, 2, 8));
}

test "a zero-height floor still loads the chunk" {
    var w = try flatWorld(std.testing.allocator, 0);
    defer w.deinit();

    try std.testing.expect(w.getChunk(0, 0) != null);
    try std.testing.expectEqual(block.air, w.getBlockId(8, 0, 8));
}
