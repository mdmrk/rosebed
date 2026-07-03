const std = @import("std");
const Chunk = @import("chunk.zig");
const constants = @import("constants.zig");
const block = @import("block.zig");
const TerrainGenerator = @import("terrain_gen.zig");
const JavaRandom = @import("java_random.zig");
const light = @import("light.zig");

const World = @This();

pub const ChunkCoord = struct { x: i32, z: i32 };

allocator: std.mem.Allocator,
chunks: std.AutoHashMapUnmanaged(ChunkCoord, *Chunk) = .{},
decorated: std.AutoHashMapUnmanaged(ChunkCoord, void) = .{},
rand: JavaRandom = JavaRandom.init(0),

pub fn init(allocator: std.mem.Allocator) World {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *World) void {
    var it = self.chunks.valueIterator();
    while (it.next()) |chunk| self.allocator.destroy(chunk.*);
    self.chunks.deinit(self.allocator);
    self.decorated.deinit(self.allocator);
}

pub fn getChunk(self: *const World, chunk_x: i32, chunk_z: i32) ?*Chunk {
    return self.chunks.get(.{ .x = chunk_x, .z = chunk_z });
}

pub fn createChunk(self: *World, chunk_x: i32, chunk_z: i32) !*Chunk {
    const coord = ChunkCoord{ .x = chunk_x, .z = chunk_z };
    const entry = try self.chunks.getOrPut(self.allocator, coord);
    if (entry.found_existing) return entry.value_ptr.*;

    const chunk = self.allocator.create(Chunk) catch |err| {
        _ = self.chunks.remove(coord);
        return err;
    };
    chunk.* = Chunk.init(chunk_x, chunk_z);
    entry.value_ptr.* = chunk;
    return chunk;
}

pub fn getOrGenerateChunk(self: *World, generator: TerrainGenerator, chunk_x: i32, chunk_z: i32) !*Chunk {
    if (self.getChunk(chunk_x, chunk_z)) |existing| return existing;
    const chunk = try self.createChunk(chunk_x, chunk_z);
    generator.generateShape(chunk);
    return chunk;
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
    try light.relightChunk(self.allocator, self, chunk_x, chunk_z);
}

fn floorDiv(value: i32, divisor: i32) i32 {
    return @divFloor(value, divisor);
}

fn floorMod(value: i32, divisor: i32) i32 {
    return @mod(value, divisor);
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

pub fn getSkyLight(self: *const World, x: i32, y: i32, z: i32) u4 {
    if (y < 0) return 0;
    if (y >= constants.chunk_height) return 15;
    const chunk = self.getChunk(floorDiv(x, constants.chunk_width), floorDiv(z, constants.chunk_width)) orelse return 0;
    return chunk.getSkyLight(@intCast(floorMod(x, constants.chunk_width)), @intCast(y), @intCast(floorMod(z, constants.chunk_width)));
}

pub fn setSkyLight(self: *World, x: i32, y: i32, z: i32, value: u4) void {
    if (y < 0 or y >= constants.chunk_height) return;
    const chunk = self.getChunk(floorDiv(x, constants.chunk_width), floorDiv(z, constants.chunk_width)) orelse return;
    chunk.setSkyLight(@intCast(floorMod(x, constants.chunk_width)), @intCast(y), @intCast(floorMod(z, constants.chunk_width)), value);
}

pub fn getBlockLight(self: *const World, x: i32, y: i32, z: i32) u4 {
    if (y < 0 or y >= constants.chunk_height) return 0;
    const chunk = self.getChunk(floorDiv(x, constants.chunk_width), floorDiv(z, constants.chunk_width)) orelse return 0;
    return chunk.getBlockLight(@intCast(floorMod(x, constants.chunk_width)), @intCast(y), @intCast(floorMod(z, constants.chunk_width)));
}

pub fn setBlockLight(self: *World, x: i32, y: i32, z: i32, value: u4) void {
    if (y < 0 or y >= constants.chunk_height) return;
    const chunk = self.getChunk(floorDiv(x, constants.chunk_width), floorDiv(z, constants.chunk_width)) orelse return;
    chunk.setBlockLight(@intCast(floorMod(x, constants.chunk_width)), @intCast(y), @intCast(floorMod(z, constants.chunk_width)), value);
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

    const a = try w.createChunk(0, 0);
    a.setBlockId(15, 5, 0, block.stone);
    const b = try w.createChunk(1, 0);
    b.setBlockId(0, 5, 0, block.dirt);

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
    const neg = try w.createChunk(-1, -1);
    neg.setBlockId(15, 5, 15, block.stone);
    try std.testing.expectEqual(block.stone, w.getBlockId(-1, 5, -1));
    try std.testing.expectEqual(block.air, w.getBlockId(-2, 5, -1));
}

test "setBlockId writes through to the owning chunk" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    _ = try w.createChunk(0, 0);
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
