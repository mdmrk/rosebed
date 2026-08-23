const std = @import("std");

const Block = @import("block.zig").Block;
const Chunk = @import("Chunk.zig");
const constants = @import("constants.zig");
pub const blocks_len = constants.chunk_volume;
pub const size_x: u8 = constants.chunk_width;
pub const size_y: u8 = constants.chunk_height;
pub const size_z: u8 = constants.chunk_width;
const deflate = @import("deflate.zig");

pub const nibbles_len = constants.chunk_volume / 2;
pub const full_len = blocks_len + nibbles_len * 3;

pub fn writeFull(chunk: *const Chunk, out: *[full_len]u8) void {
    for (chunk.blocks, out[0..blocks_len]) |block, *byte| byte.* = @intFromEnum(block);
    @memcpy(out[blocks_len..][0..nibbles_len], &chunk.metadata.data);
    @memcpy(out[blocks_len + nibbles_len ..][0..nibbles_len], &chunk.block_light.data);
    @memcpy(out[blocks_len + nibbles_len * 2 ..][0..nibbles_len], &chunk.sky_light.data);
}

pub fn compressFull(gpa: std.mem.Allocator, chunk: *const Chunk) ![]u8 {
    const raw = try gpa.create([full_len]u8);
    defer gpa.destroy(raw);

    writeFull(chunk, raw);
    return deflate.compressAlloc(gpa, .zlib, raw);
}

pub const ReadError = error{WrongSize};

pub fn readFull(chunk: *Chunk, raw: []const u8) ReadError!void {
    if (raw.len != full_len) return error.WrongSize;

    for (raw[0..blocks_len], &chunk.blocks) |byte, *block| block.* = @enumFromInt(byte);
    @memcpy(&chunk.metadata.data, raw[blocks_len..][0..nibbles_len]);
    @memcpy(&chunk.block_light.data, raw[blocks_len + nibbles_len ..][0..nibbles_len]);
    @memcpy(&chunk.sky_light.data, raw[blocks_len + nibbles_len * 2 ..][0..nibbles_len]);
}

pub fn decompressFull(gpa: std.mem.Allocator, chunk: *Chunk, compressed: []const u8) !void {
    const raw = try deflate.decompressAlloc(gpa, .zlib, compressed, full_len);
    defer gpa.free(raw);
    try readFull(chunk, raw);
}

test "the payload is the size vanilla allocates for a whole chunk" {
    try std.testing.expectEqual(@as(usize, 16 * 128 * 16 * 5 / 2), full_len);
    try std.testing.expectEqual(@as(usize, 81920), full_len);
}

test "the payload is blocks, then metadata, then block light, then sky light" {
    const gpa = std.testing.allocator;

    const chunk = try gpa.create(Chunk);
    defer gpa.destroy(chunk);
    chunk.* = Chunk.init(0, 0);

    chunk.setBlock(1, 2, 3, .stone);
    chunk.setBlockMetadata(1, 2, 3, 9);
    chunk.setBlockLight(1, 2, 3, 7);
    chunk.setSkyLight(1, 2, 3, 15);

    const out = try gpa.create([full_len]u8);
    defer gpa.destroy(out);
    writeFull(chunk, out);

    const index = (@as(usize, 1) << 11) | (@as(usize, 3) << 7) | 2;
    try std.testing.expectEqual(@intFromEnum(Block.stone), out[index]);
    try std.testing.expectEqual(@as(u8, 9), out[blocks_len + index / 2] & 0x0f);
    try std.testing.expectEqual(@as(u8, 7), out[blocks_len + nibbles_len + index / 2] & 0x0f);
    try std.testing.expectEqual(@as(u8, 15), out[blocks_len + nibbles_len * 2 + index / 2] & 0x0f);
}

test "a compressed chunk inflates back to exactly what was written" {
    const gpa = std.testing.allocator;

    const chunk = try gpa.create(Chunk);
    defer gpa.destroy(chunk);
    chunk.* = Chunk.init(0, 0);

    for (0..constants.chunk_width) |x| {
        for (0..constants.chunk_width) |z| {
            chunk.setBlock(@intCast(x), 0, @intCast(z), .bedrock);
            chunk.setBlock(@intCast(x), 1, @intCast(z), .dirt);
            chunk.setSkyLight(@intCast(x), 2, @intCast(z), 15);
        }
    }

    const compressed = try compressFull(gpa, chunk);
    defer gpa.free(compressed);
    try std.testing.expect(compressed.len < full_len);

    const inflated = try deflate.decompressAlloc(gpa, .zlib, compressed, full_len);
    defer gpa.free(inflated);

    const expected = try gpa.create([full_len]u8);
    defer gpa.destroy(expected);
    writeFull(chunk, expected);

    try std.testing.expectEqualSlices(u8, expected, inflated);
}

test "a chunk read back from its payload matches the one that was written" {
    const gpa = std.testing.allocator;

    const sent = try gpa.create(Chunk);
    defer gpa.destroy(sent);
    sent.* = Chunk.init(3, -4);

    var seed: u32 = 1;
    for (0..constants.chunk_width) |x| {
        for (0..constants.chunk_width) |z| {
            for (0..40) |y| {
                seed = seed *% 1664525 +% 1013904223;
                sent.setBlock(@intCast(x), @intCast(y), @intCast(z), @enumFromInt(@as(u8, @truncate(seed >> 16))));
                sent.setBlockMetadata(@intCast(x), @intCast(y), @intCast(z), @truncate(seed >> 8));
                sent.setBlockLight(@intCast(x), @intCast(y), @intCast(z), @truncate(seed >> 4));
                sent.setSkyLight(@intCast(x), @intCast(y), @intCast(z), @truncate(seed));
            }
        }
    }

    const compressed = try compressFull(gpa, sent);
    defer gpa.free(compressed);

    const received = try gpa.create(Chunk);
    defer gpa.destroy(received);
    received.* = Chunk.init(3, -4);
    try decompressFull(gpa, received, compressed);

    try std.testing.expectEqualSlices(Block, &sent.blocks, &received.blocks);
    try std.testing.expectEqualSlices(u8, &sent.metadata.data, &received.metadata.data);
    try std.testing.expectEqualSlices(u8, &sent.block_light.data, &received.block_light.data);
    try std.testing.expectEqualSlices(u8, &sent.sky_light.data, &received.sky_light.data);
}

test "a payload of the wrong length is refused" {
    const gpa = std.testing.allocator;

    const chunk = try gpa.create(Chunk);
    defer gpa.destroy(chunk);
    chunk.* = Chunk.init(0, 0);

    try std.testing.expectError(error.WrongSize, readFull(chunk, &.{ 1, 2, 3 }));
}
