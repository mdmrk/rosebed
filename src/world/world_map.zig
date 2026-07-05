const std = @import("std");
const Chunk = @import("chunk.zig");
const constants = @import("constants.zig");
const block = @import("block.zig");
const Block = block.Block;
const TerrainGenerator = @import("terrain_gen.zig");
const JavaRandom = @import("java_random.zig");
const light = @import("light.zig");
const math = @import("math");

const World = @This();

pub const ChunkCoord = struct { x: i32, z: i32 };

allocator: std.mem.Allocator,
chunks: std.AutoHashMapUnmanaged(ChunkCoord, *Chunk) = .{},
decorated: std.AutoHashMapUnmanaged(ChunkCoord, void) = .{},
rand: JavaRandom = JavaRandom.init(0),
time: i64 = 0,
skylight_subtracted: u4 = 0,

pub const ticks_per_day: i64 = 24000;

pub fn celestialAngle(self: *const World, partial_ticks: f32) f32 {
    const day_time: f32 = @floatFromInt(@mod(self.time, ticks_per_day));
    var fraction = (day_time + partial_ticks) / @as(f32, ticks_per_day) - 0.25;
    if (fraction < 0.0) fraction += 1.0;
    if (fraction > 1.0) fraction -= 1.0;

    const linear = fraction;
    const eased: f32 = 1.0 - @as(f32, @floatCast((@cos(@as(f64, linear) * std.math.pi) + 1.0) / 2.0));
    return linear + (eased - linear) / 3.0;
}

pub fn calculateSkylightSubtracted(self: *const World, partial_ticks: f32) u4 {
    const angle = self.celestialAngle(partial_ticks);
    const darkness = std.math.clamp(1.0 - (math.util.cos(angle * std.math.pi * 2.0) * 2.0 + 0.5), 0.0, 1.0);
    return @intFromFloat(darkness * 11.0);
}

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

pub fn isDecorated(self: *const World, chunk_x: i32, chunk_z: i32) bool {
    return self.decorated.contains(.{ .x = chunk_x, .z = chunk_z });
}

pub fn ensureDecorated(self: *World, generator: TerrainGenerator, chunk_x: i32, chunk_z: i32) !void {
    if (self.isDecorated(chunk_x, chunk_z)) return;

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

pub fn getBlock(self: *const World, x: i32, y: i32, z: i32) Block {
    if (y < 0 or y >= constants.chunk_height) return Block.air;
    const chunk = self.getChunk(floorDiv(x, constants.chunk_width), floorDiv(z, constants.chunk_width)) orelse return Block.air;
    return chunk.getBlock(@intCast(floorMod(x, constants.chunk_width)), @intCast(y), @intCast(floorMod(z, constants.chunk_width)));
}

pub fn setBlock(self: *World, x: i32, y: i32, z: i32, id: Block) void {
    if (y < 0 or y >= constants.chunk_height) return;
    const chunk = self.getChunk(floorDiv(x, constants.chunk_width), floorDiv(z, constants.chunk_width)) orelse return;
    chunk.setBlock(@intCast(floorMod(x, constants.chunk_width)), @intCast(y), @intCast(floorMod(z, constants.chunk_width)), id);
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
    a.setBlock(15, 5, 0, Block.stone);
    const b = try w.createChunk(1, 0);
    b.setBlock(0, 5, 0, Block.dirt);

    try std.testing.expectEqual(Block.stone, w.getBlock(15, 5, 0));
    try std.testing.expectEqual(Block.dirt, w.getBlock(16, 5, 0));
}

test "reading an unloaded chunk returns air" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    try std.testing.expectEqual(Block.air, w.getBlock(1000, 5, 1000));
}

test "negative coordinates resolve to the correct chunk" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    const neg = try w.createChunk(-1, -1);
    neg.setBlock(15, 5, 15, Block.stone);
    try std.testing.expectEqual(Block.stone, w.getBlock(-1, 5, -1));
    try std.testing.expectEqual(Block.air, w.getBlock(-2, 5, -1));
}

test "setBlock writes through to the owning chunk" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    _ = try w.createChunk(0, 0);
    w.setBlock(3, 10, 4, Block.stone);
    try std.testing.expectEqual(Block.stone, w.getBlock(3, 10, 4));
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

    var before: [16 * 128 * 16]Block = undefined;
    var idx: usize = 0;
    for (0..16) |x| {
        for (0..128) |y| {
            for (0..16) |z| {
                before[idx] = w.getBlock(@intCast(x), @intCast(y), @intCast(z));
                idx += 1;
            }
        }
    }

    try w.ensureDecorated(gen, 0, 0);

    idx = 0;
    for (0..16) |x| {
        for (0..128) |y| {
            for (0..16) |z| {
                try std.testing.expectEqual(before[idx], w.getBlock(@intCast(x), @intCast(y), @intCast(z)));
                idx += 1;
            }
        }
    }
}

test "celestialAngle matches WorldProvider across the day" {
    var world_map = World.init(std.testing.allocator);
    defer world_map.deinit();

    const cases = [_]struct { time: i64, angle: f32 }{
        .{ .time = 0, .angle = 0.784517825 },
        .{ .time = 1000, .angle = 0.826669991 },
        .{ .time = 6000, .angle = 0.0 },
        .{ .time = 12000, .angle = 0.215482190 },
        .{ .time = 18000, .angle = 0.5 },
        .{ .time = 22000, .angle = 0.694444478 },
    };
    for (cases) |case| {
        world_map.time = case.time;
        try std.testing.expectApproxEqAbs(case.angle, world_map.celestialAngle(0.0), 1.0e-6);
    }
}

test "skylight is only subtracted between dusk and dawn" {
    var world_map = World.init(std.testing.allocator);
    defer world_map.deinit();

    const cases = [_]struct { time: i64, subtracted: u4 }{
        .{ .time = 0, .subtracted = 0 },
        .{ .time = 6000, .subtracted = 0 },
        .{ .time = 12000, .subtracted = 0 },
        .{ .time = 13000, .subtracted = 6 },
        .{ .time = 15000, .subtracted = 11 },
        .{ .time = 18000, .subtracted = 11 },
        .{ .time = 22000, .subtracted = 11 },
        .{ .time = 23999, .subtracted = 0 },
    };
    for (cases) |case| {
        world_map.time = case.time;
        try std.testing.expectEqual(case.subtracted, world_map.calculateSkylightSubtracted(0.0));
    }
}

test "a day wraps around without discontinuity" {
    var world_map = World.init(std.testing.allocator);
    defer world_map.deinit();

    world_map.time = 24000;
    const wrapped = world_map.celestialAngle(0.0);
    world_map.time = 0;
    try std.testing.expectEqual(world_map.celestialAngle(0.0), wrapped);
}
