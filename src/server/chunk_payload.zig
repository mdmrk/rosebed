const std = @import("std");

const world = @import("world");

pub const blocks_len = world.constants.chunk_volume;
pub const nibbles_len = world.constants.chunk_volume / 2;
pub const full_len = blocks_len + nibbles_len * 3;

pub const size_x: u8 = world.constants.chunk_width;
pub const size_y: u8 = world.constants.chunk_height;
pub const size_z: u8 = world.constants.chunk_width;

pub fn writeFull(chunk: *const world.Chunk, out: *[full_len]u8) void {
    for (chunk.blocks, out[0..blocks_len]) |block, *byte| byte.* = @intFromEnum(block);
    @memcpy(out[blocks_len..][0..nibbles_len], &chunk.metadata.data);
    @memcpy(out[blocks_len + nibbles_len ..][0..nibbles_len], &chunk.block_light.data);
    @memcpy(out[blocks_len + nibbles_len * 2 ..][0..nibbles_len], &chunk.sky_light.data);
}

pub fn compressFull(gpa: std.mem.Allocator, chunk: *const world.Chunk) ![]u8 {
    const raw = try gpa.create([full_len]u8);
    defer gpa.destroy(raw);

    writeFull(chunk, raw);
    return world.deflate.compressAlloc(gpa, .zlib, raw);
}

test "the payload is the size vanilla allocates for a whole chunk" {
    try std.testing.expectEqual(@as(usize, 16 * 128 * 16 * 5 / 2), full_len);
    try std.testing.expectEqual(@as(usize, 81920), full_len);
}

test "the payload is blocks, then metadata, then block light, then sky light" {
    const gpa = std.testing.allocator;

    const chunk = try gpa.create(world.Chunk);
    defer gpa.destroy(chunk);
    chunk.* = world.Chunk.init(0, 0);

    chunk.setBlock(1, 2, 3, .stone);
    chunk.setBlockMetadata(1, 2, 3, 9);
    chunk.setBlockLight(1, 2, 3, 7);
    chunk.setSkyLight(1, 2, 3, 15);

    const out = try gpa.create([full_len]u8);
    defer gpa.destroy(out);
    writeFull(chunk, out);

    const index = (@as(usize, 1) << 11) | (@as(usize, 3) << 7) | 2;
    try std.testing.expectEqual(@intFromEnum(world.Block.stone), out[index]);
    try std.testing.expectEqual(@as(u8, 9), out[blocks_len + index / 2] & 0x0f);
    try std.testing.expectEqual(@as(u8, 7), out[blocks_len + nibbles_len + index / 2] & 0x0f);
    try std.testing.expectEqual(@as(u8, 15), out[blocks_len + nibbles_len * 2 + index / 2] & 0x0f);
}

test "a compressed chunk inflates back to exactly what was written" {
    const gpa = std.testing.allocator;

    const chunk = try gpa.create(world.Chunk);
    defer gpa.destroy(chunk);
    chunk.* = world.Chunk.init(0, 0);

    for (0..world.constants.chunk_width) |x| {
        for (0..world.constants.chunk_width) |z| {
            chunk.setBlock(@intCast(x), 0, @intCast(z), .bedrock);
            chunk.setBlock(@intCast(x), 1, @intCast(z), .dirt);
            chunk.setSkyLight(@intCast(x), 2, @intCast(z), 15);
        }
    }

    const compressed = try compressFull(gpa, chunk);
    defer gpa.free(compressed);
    try std.testing.expect(compressed.len < full_len);

    const inflated = try world.deflate.decompressAlloc(gpa, .zlib, compressed, full_len);
    defer gpa.free(inflated);

    const expected = try gpa.create([full_len]u8);
    defer gpa.destroy(expected);
    writeFull(chunk, expected);

    try std.testing.expectEqualSlices(u8, expected, inflated);
}
