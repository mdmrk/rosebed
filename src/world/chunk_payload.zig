const std = @import("std");

const Block = @import("block.zig").Block;
const Chunk = @import("Chunk.zig");
pub const blocks_len = Chunk.volume;
pub const size_x: u8 = Chunk.width;
pub const size_y: u8 = Chunk.height;
pub const size_z: u8 = Chunk.width;
const deflate = @import("deflate.zig");

pub const nibbles_len = Chunk.volume / 2;
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

pub const Box = struct {
    x: u32,
    y: u32,
    z: u32,
    size_x: u32,
    size_y: u32,
    size_z: u32,

    pub fn len(self: Box) usize {
        return @as(usize, self.size_x) * self.size_y * self.size_z * 5 / 2;
    }

    fn fits(self: Box) bool {
        if (self.size_y % 2 != 0 or self.y % 2 != 0) return false;
        if (self.x + self.size_x > Chunk.width) return false;
        if (self.y + self.size_y > Chunk.height) return false;
        if (self.z + self.size_z > Chunk.width) return false;
        return self.size_x > 0 and self.size_y > 0 and self.size_z > 0;
    }
};

fn runIndex(x: u32, y: u32, z: u32) usize {
    return (@as(usize, x) << 11) | (@as(usize, z) << 7) | y;
}

pub fn writeBox(chunk: *const Chunk, box: Box, out: []u8) void {
    var at: usize = 0;

    for (box.x..box.x + box.size_x) |x| {
        for (box.z..box.z + box.size_z) |z| {
            const start = runIndex(@intCast(x), box.y, @intCast(z));
            for (chunk.blocks[start..][0..box.size_y], out[at..][0..box.size_y]) |id, *byte| {
                byte.* = @intFromEnum(id);
            }
            at += box.size_y;
        }
    }

    for ([_]*const [nibbles_len]u8{
        &chunk.metadata.data,
        &chunk.block_light.data,
        &chunk.sky_light.data,
    }) |nibbles| {
        for (box.x..box.x + box.size_x) |x| {
            for (box.z..box.z + box.size_z) |z| {
                const start = runIndex(@intCast(x), box.y, @intCast(z)) / 2;
                const run = box.size_y / 2;
                @memcpy(out[at..][0..run], nibbles[start..][0..run]);
                at += run;
            }
        }
    }
}

pub fn compressBox(gpa: std.mem.Allocator, chunk: *const Chunk, box: Box) ![]u8 {
    std.debug.assert(box.fits());

    const raw = try gpa.alloc(u8, box.len());
    defer gpa.free(raw);

    writeBox(chunk, box, raw);
    return deflate.compressAlloc(gpa, .zlib, raw);
}

pub fn readBox(chunk: *Chunk, box: Box, raw: []const u8) ReadError!void {
    if (!box.fits() or raw.len != box.len()) return error.WrongSize;

    var at: usize = 0;

    for (box.x..box.x + box.size_x) |x| {
        for (box.z..box.z + box.size_z) |z| {
            const start = runIndex(@intCast(x), box.y, @intCast(z));
            for (raw[at..][0..box.size_y], chunk.blocks[start..][0..box.size_y]) |byte, *id| {
                id.* = @enumFromInt(byte);
            }
            at += box.size_y;
        }
    }

    for ([_]*[nibbles_len]u8{
        &chunk.metadata.data,
        &chunk.block_light.data,
        &chunk.sky_light.data,
    }) |nibbles| {
        for (box.x..box.x + box.size_x) |x| {
            for (box.z..box.z + box.size_z) |z| {
                const start = runIndex(@intCast(x), box.y, @intCast(z)) / 2;
                const run = box.size_y / 2;
                @memcpy(nibbles[start..][0..run], raw[at..][0..run]);
                at += run;
            }
        }
    }
}

pub fn decompressBox(gpa: std.mem.Allocator, chunk: *Chunk, box: Box, compressed: []const u8) !void {
    if (!box.fits()) return error.WrongSize;

    const raw = try deflate.decompressAlloc(gpa, .zlib, compressed, box.len());
    defer gpa.free(raw);
    try readBox(chunk, box, raw);
}

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

    for (0..Chunk.width) |x| {
        for (0..Chunk.width) |z| {
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
    for (0..Chunk.width) |x| {
        for (0..Chunk.width) |z| {
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

fn speckledChunk(chunk: *Chunk) void {
    for (0..Chunk.width) |x| {
        for (0..Chunk.width) |z| {
            for (0..Chunk.height) |y| {
                const seed: u32 = @intCast(x * 31 + z * 17 + y * 7);
                chunk.setBlock(@intCast(x), @intCast(y), @intCast(z), @enumFromInt(@as(u8, @truncate(seed))));
                chunk.setBlockMetadata(@intCast(x), @intCast(y), @intCast(z), @truncate(seed));
                chunk.setBlockLight(@intCast(x), @intCast(y), @intCast(z), @truncate(seed >> 1));
                chunk.setSkyLight(@intCast(x), @intCast(y), @intCast(z), @truncate(seed >> 2));
            }
        }
    }
}

test "a box round trips through the payload the way a whole chunk does" {
    const gpa = std.testing.allocator;

    const source = try gpa.create(Chunk);
    defer gpa.destroy(source);
    source.* = .init(0, 0);
    speckledChunk(source);

    const box: Box = .{ .x = 3, .y = 40, .z = 11, .size_x = 4, .size_y = 6, .size_z = 2 };
    const raw = try gpa.alloc(u8, box.len());
    defer gpa.free(raw);
    writeBox(source, box, raw);

    const target = try gpa.create(Chunk);
    defer gpa.destroy(target);
    target.* = .init(0, 0);
    try readBox(target, box, raw);

    for (0..Chunk.width) |x| {
        for (0..Chunk.width) |z| {
            for (0..Chunk.height) |y| {
                const inside = x >= box.x and x < box.x + box.size_x and
                    y >= box.y and y < box.y + box.size_y and
                    z >= box.z and z < box.z + box.size_z;
                const want = if (inside)
                    source.getBlock(@intCast(x), @intCast(y), @intCast(z))
                else
                    Block.air;
                try std.testing.expectEqual(want, target.getBlock(@intCast(x), @intCast(y), @intCast(z)));
                if (!inside) continue;
                try std.testing.expectEqual(
                    source.getBlockMetadata(@intCast(x), @intCast(y), @intCast(z)),
                    target.getBlockMetadata(@intCast(x), @intCast(y), @intCast(z)),
                );
                try std.testing.expectEqual(
                    source.getBlockLight(@intCast(x), @intCast(y), @intCast(z)),
                    target.getBlockLight(@intCast(x), @intCast(y), @intCast(z)),
                );
                try std.testing.expectEqual(
                    source.getSkyLight(@intCast(x), @intCast(y), @intCast(z)),
                    target.getSkyLight(@intCast(x), @intCast(y), @intCast(z)),
                );
            }
        }
    }
}

test "a box payload is the five halves per cell Packet51MapChunk sizes it at" {
    const box: Box = .{ .x = 0, .y = 0, .z = 0, .size_x = 4, .size_y = 6, .size_z = 2 };
    try std.testing.expectEqual(@as(usize, 4 * 6 * 2 * 5 / 2), box.len());
}

test "a box that straddles a nibble or leaves the chunk is refused" {
    const gpa = std.testing.allocator;
    const chunk = try gpa.create(Chunk);
    defer gpa.destroy(chunk);
    chunk.* = .init(0, 0);

    const odd_height: Box = .{ .x = 0, .y = 0, .z = 0, .size_x = 1, .size_y = 3, .size_z = 1 };
    const odd_start: Box = .{ .x = 0, .y = 1, .z = 0, .size_x = 1, .size_y = 2, .size_z = 1 };
    const outside: Box = .{ .x = 14, .y = 0, .z = 0, .size_x = 4, .size_y = 2, .size_z = 1 };

    for ([_]Box{ odd_height, odd_start, outside }) |box| {
        const raw = try gpa.alloc(u8, box.len());
        defer gpa.free(raw);
        try std.testing.expectError(error.WrongSize, readBox(chunk, box, raw));
    }
}

test "a box payload survives being compressed and blown back up" {
    const gpa = std.testing.allocator;

    const source = try gpa.create(Chunk);
    defer gpa.destroy(source);
    source.* = .init(0, 0);
    speckledChunk(source);

    const box: Box = .{ .x = 2, .y = 60, .z = 5, .size_x = 3, .size_y = 4, .size_z = 3 };
    const compressed = try compressBox(gpa, source, box);
    defer gpa.free(compressed);

    const target = try gpa.create(Chunk);
    defer gpa.destroy(target);
    target.* = .init(0, 0);
    try decompressBox(gpa, target, box, compressed);

    try std.testing.expectEqual(
        source.getBlock(box.x + 1, box.y + 2, box.z + 1),
        target.getBlock(box.x + 1, box.y + 2, box.z + 1),
    );
}
