const std = @import("std");
const Chunk = @import("chunk.zig");
const constants = @import("constants.zig");
const block = @import("block.zig");
const TerrainGenerator = @import("terrain_gen.zig");
const JavaRandom = @import("java_random.zig");

const World = @This();

pub const ChunkCoord = struct { x: i32, z: i32 };

allocator: std.mem.Allocator,
chunks: std.AutoHashMapUnmanaged(ChunkCoord, Chunk) = .{},
decorated: std.AutoHashMapUnmanaged(ChunkCoord, void) = .{},
rand: JavaRandom = JavaRandom.init(0),

pub fn init(allocator: std.mem.Allocator) World {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *World) void {
    self.chunks.deinit(self.allocator);
    self.decorated.deinit(self.allocator);
}

pub fn getChunk(self: *const World, chunk_x: i32, chunk_z: i32) ?*Chunk {
    return self.chunks.getPtr(.{ .x = chunk_x, .z = chunk_z });
}

pub fn getOrGenerateChunk(self: *World, generator: TerrainGenerator, chunk_x: i32, chunk_z: i32) !*Chunk {
    const entry = try self.chunks.getOrPut(self.allocator, .{ .x = chunk_x, .z = chunk_z });
    if (!entry.found_existing) entry.value_ptr.* = generator.generateShape(chunk_x, chunk_z);
    return entry.value_ptr;
}

pub fn ensureDecorated(self: *World, generator: TerrainGenerator, chunk_x: i32, chunk_z: i32) !void {
    if (self.decorated.contains(.{ .x = chunk_x, .z = chunk_z })) return;

    var dx: i32 = -1;
    while (dx <= 1) : (dx += 1) {
        var dz: i32 = -1;
        while (dz <= 1) : (dz += 1) {
            _ = try self.getOrGenerateChunk(generator, chunk_x + dx, chunk_z + dz);
        }
    }

    generator.decorateChunk(self, chunk_x, chunk_z);
    try self.decorated.put(self.allocator, .{ .x = chunk_x, .z = chunk_z }, {});
}

fn floorDiv(value: i32, divisor: i32) i32 {
    return @intCast(std.math.divFloor(i32, value, divisor) catch unreachable);
}

fn floorMod(value: i32, divisor: i32) i32 {
    return @intCast(std.math.mod(i32, value, divisor) catch unreachable);
}

pub fn getBlockId(self: *const World, x: i32, y: i32, z: i32) u8 {
    if (y < 0 or y >= constants.chunk_height) return block.air;
    const chunk = self.getChunk(floorDiv(x, constants.chunk_width), floorDiv(z, constants.chunk_width)) orelse return block.air;
    return chunk.getBlockId(@intCast(floorMod(x, constants.chunk_width)), @intCast(y), @intCast(floorMod(z, constants.chunk_width)));
}

pub fn setBlockId(self: *World, x: i32, y: i32, z: i32, id: u8) void {
    if (y < 0 or y >= constants.chunk_height) return;
    const chunk = self.getChunk(floorDiv(x, constants.chunk_width), floorDiv(z, constants.chunk_width)) orelse return;
    chunk.setBlockId(@intCast(floorMod(x, constants.chunk_width)), @intCast(y), @intCast(floorMod(z, constants.chunk_width)), id);
}

pub fn getBlockMetadata(self: *const World, x: i32, y: i32, z: i32) u4 {
    if (y < 0 or y >= constants.chunk_height) return 0;
    const chunk = self.getChunk(floorDiv(x, constants.chunk_width), floorDiv(z, constants.chunk_width)) orelse return 0;
    return chunk.getBlockMetadata(@intCast(floorMod(x, constants.chunk_width)), @intCast(y), @intCast(floorMod(z, constants.chunk_width)));
}

pub fn setBlockMetadata(self: *World, x: i32, y: i32, z: i32, value: u4) void {
    if (y < 0 or y >= constants.chunk_height) return;
    const chunk = self.getChunk(floorDiv(x, constants.chunk_width), floorDiv(z, constants.chunk_width)) orelse return;
    chunk.setBlockMetadata(@intCast(floorMod(x, constants.chunk_width)), @intCast(y), @intCast(floorMod(z, constants.chunk_width)), value);
}

test "block access spans chunk boundaries using world coordinates" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();

    var a = Chunk.init(0, 0);
    a.setBlockId(15, 5, 0, block.stone);
    var b = Chunk.init(1, 0);
    b.setBlockId(0, 5, 0, block.dirt);
    try w.chunks.put(std.testing.allocator, .{ .x = 0, .z = 0 }, a);
    try w.chunks.put(std.testing.allocator, .{ .x = 1, .z = 0 }, b);

    try std.testing.expectEqual(block.stone, w.getBlockId(15, 5, 0));
    try std.testing.expectEqual(block.dirt, w.getBlockId(16, 5, 0));
}

test "reading an unloaded chunk returns air" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    try std.testing.expectEqual(block.air, w.getBlockId(1000, 5, 1000));
}

test "negative coordinates resolve to the correct chunk" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    var neg = Chunk.init(-1, -1);
    neg.setBlockId(15, 5, 15, block.stone);
    try w.chunks.put(std.testing.allocator, .{ .x = -1, .z = -1 }, neg);
    try std.testing.expectEqual(block.stone, w.getBlockId(-1, 5, -1));
    try std.testing.expectEqual(block.air, w.getBlockId(-2, 5, -1));
}

test "setBlockId writes through to the owning chunk" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    try w.chunks.put(std.testing.allocator, .{ .x = 0, .z = 0 }, Chunk.init(0, 0));
    w.setBlockId(3, 10, 4, block.stone);
    try std.testing.expectEqual(block.stone, w.getBlockId(3, 10, 4));
}

test "ensureDecorated shape-generates the full 3x3 neighbor block" {
    const gpa = std.testing.allocator;
    const gen = try TerrainGenerator.init(gpa, 1);
    defer gen.deinit(gpa);

    var w = World.init(gpa);
    defer w.deinit();
    try w.ensureDecorated(gen, 0, 0);

    var dx: i32 = -1;
    while (dx <= 1) : (dx += 1) {
        var dz: i32 = -1;
        while (dz <= 1) : (dz += 1) {
            try std.testing.expect(w.getChunk(dx, dz) != null);
        }
    }
}

test "ensureDecorated only decorates a chunk once" {
    const gpa = std.testing.allocator;
    const gen = try TerrainGenerator.init(gpa, 1);
    defer gen.deinit(gpa);

    var w = World.init(gpa);
    defer w.deinit();
    try w.ensureDecorated(gen, 0, 0);

    var before: [16 * 128 * 16]u8 = undefined;
    var idx: usize = 0;
    for (0..16) |x| {
        for (0..128) |y| {
            for (0..16) |z| {
                before[idx] = w.getBlockId(@intCast(x), @intCast(y), @intCast(z));
                idx += 1;
            }
        }
    }

    try w.ensureDecorated(gen, 0, 0);

    idx = 0;
    for (0..16) |x| {
        for (0..128) |y| {
            for (0..16) |z| {
                try std.testing.expectEqual(before[idx], w.getBlockId(@intCast(x), @intCast(y), @intCast(z)));
                idx += 1;
            }
        }
    }
}
