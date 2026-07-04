const std = @import("std");
const block = @import("block.zig");
const constants = @import("constants.zig");
const Chunk = @import("chunk.zig");
const World = @import("world_map.zig");

pub const max_level: u4 = 15;

pub const Kind = enum { sky, block };

pub fn opacity(id: u8) u8 {
    return switch (id) {
        block.stationary_water => 3,
        block.leaves => 1,
        else => if (block.isOpaque(id)) 255 else 0,
    };
}

pub fn emission(id: u8) u4 {
    return switch (id) {
        block.flowing_lava => 15,
        else => 0,
    };
}

pub const brightness_table: [16]f32 = blk: {
    const ambient: f32 = 0.05;
    var table: [16]f32 = undefined;
    for (&table, 0..) |*entry, level| {
        const darkness = 1.0 - @as(f32, level) / 15.0;
        entry.* = (1.0 - darkness) / (darkness * 3.0 + 1.0) * (1.0 - ambient) + ambient;
    }
    break :blk table;
};

pub fn levelAt(world_map: *const World, x: i32, y: i32, z: i32) u4 {
    const sky = world_map.getSkyLight(x, y, z) -| world_map.skylight_subtracted;
    return @max(sky, world_map.getBlockLight(x, y, z));
}

pub fn brightnessAt(world_map: *const World, x: i32, y: i32, z: i32, minimum: u4) f32 {
    return brightness_table[@max(levelAt(world_map, x, y, z), minimum)];
}

fn spreadCost(id: u8) u8 {
    return @max(opacity(id), 1);
}

pub fn generateHeightMap(chunk: *Chunk) void {
    for (0..Chunk.width) |x| {
        for (0..Chunk.width) |z| {
            var y: u32 = constants.chunk_height - 1;
            while (y > 0 and opacity(chunk.getBlockId(@intCast(x), y - 1, @intCast(z))) == 0) y -= 1;
            chunk.setHeightValue(@intCast(x), @intCast(z), @intCast(y));
        }
    }
}

const Node = struct { x: i32, y: i32, z: i32 };

const Propagation = struct {
    world_map: *World,
    queue: std.ArrayList(Node) = .empty,
    kind: Kind,
    min_x: i32,
    min_z: i32,

    fn get(self: *const Propagation, x: i32, y: i32, z: i32) u4 {
        return switch (self.kind) {
            .sky => self.world_map.getSkyLight(x, y, z),
            .block => self.world_map.getBlockLight(x, y, z),
        };
    }

    fn set(self: *Propagation, x: i32, y: i32, z: i32, value: u4) void {
        switch (self.kind) {
            .sky => self.world_map.setSkyLight(x, y, z, value),
            .block => self.world_map.setBlockLight(x, y, z, value),
        }
    }

    fn inside(self: *const Propagation, x: i32, y: i32, z: i32) bool {
        return y >= 0 and y < constants.chunk_height and
            x >= self.min_x and x < self.min_x + constants.chunk_width and
            z >= self.min_z and z < self.min_z + constants.chunk_width;
    }

    fn seed(self: *Propagation, gpa: std.mem.Allocator, x: i32, y: i32, z: i32) !void {
        try self.queue.append(gpa, .{ .x = x, .y = y, .z = z });
    }

    fn run(self: *Propagation, gpa: std.mem.Allocator) !void {
        const offsets = [6][3]i32{
            .{ -1, 0, 0 }, .{ 1, 0, 0 },
            .{ 0, -1, 0 }, .{ 0, 1, 0 },
            .{ 0, 0, -1 }, .{ 0, 0, 1 },
        };

        var head: usize = 0;
        while (head < self.queue.items.len) : (head += 1) {
            const node = self.queue.items[head];
            const level = self.get(node.x, node.y, node.z);
            if (level <= 1) continue;

            for (offsets) |offset| {
                const nx = node.x + offset[0];
                const ny = node.y + offset[1];
                const nz = node.z + offset[2];
                if (!self.inside(nx, ny, nz)) continue;

                const cost = spreadCost(self.world_map.getBlockId(nx, ny, nz));
                if (level <= cost) continue;

                const spread: u4 = @intCast(level - cost);
                if (spread <= self.get(nx, ny, nz)) continue;

                self.set(nx, ny, nz, spread);
                try self.seed(gpa, nx, ny, nz);
            }
        }
    }
};

fn skyCanSpread(chunk: *const Chunk, lx: usize, ly: usize, lz: usize, sky_floor: u8) bool {
    if (ly == sky_floor) return true;
    const last = Chunk.width - 1;
    if (lx > 0 and chunk.getHeightValue(@intCast(lx - 1), @intCast(lz)) > ly) return true;
    if (lx < last and chunk.getHeightValue(@intCast(lx + 1), @intCast(lz)) > ly) return true;
    if (lz > 0 and chunk.getHeightValue(@intCast(lx), @intCast(lz - 1)) > ly) return true;
    if (lz < last and chunk.getHeightValue(@intCast(lx), @intCast(lz + 1)) > ly) return true;
    return false;
}

pub fn relightChunk(gpa: std.mem.Allocator, world_map: *World, chunk_x: i32, chunk_z: i32) !void {
    const chunk = world_map.getChunk(chunk_x, chunk_z) orelse return;
    generateHeightMap(chunk);

    chunk.sky_light = .{};
    chunk.block_light = .{};

    const min_x = chunk_x * constants.chunk_width;
    const min_z = chunk_z * constants.chunk_width;

    var sky: Propagation = .{ .world_map = world_map, .kind = .sky, .min_x = min_x, .min_z = min_z };
    defer sky.queue.deinit(gpa);
    var lamps: Propagation = .{ .world_map = world_map, .kind = .block, .min_x = min_x, .min_z = min_z };
    defer lamps.queue.deinit(gpa);

    for (0..Chunk.width) |lx| {
        for (0..Chunk.width) |lz| {
            const sky_floor = chunk.getHeightValue(@intCast(lx), @intCast(lz));
            const x = min_x + @as(i32, @intCast(lx));
            const z = min_z + @as(i32, @intCast(lz));

            for (0..constants.chunk_height) |ly| {
                const y: i32 = @intCast(ly);
                if (ly >= sky_floor) {
                    chunk.setSkyLight(@intCast(lx), @intCast(ly), @intCast(lz), max_level);
                    if (skyCanSpread(chunk, lx, ly, lz, sky_floor)) try sky.seed(gpa, x, y, z);
                }
                const emitted = emission(chunk.getBlockId(@intCast(lx), @intCast(ly), @intCast(lz)));
                if (emitted > 0) {
                    chunk.setBlockLight(@intCast(lx), @intCast(ly), @intCast(lz), emitted);
                    try lamps.seed(gpa, x, y, z);
                }
            }
        }
    }

    try seedBorder(gpa, &sky, chunk_x, chunk_z);
    try seedBorder(gpa, &lamps, chunk_x, chunk_z);

    try sky.run(gpa);
    try lamps.run(gpa);
}

pub fn relightAround(gpa: std.mem.Allocator, world_map: *World, x: i32, z: i32) !void {
    const width = constants.chunk_width;
    const chunk_x = @divFloor(x, width);
    const chunk_z = @divFloor(z, width);
    const local_x = @mod(x, width);
    const local_z = @mod(z, width);

    try relightChunk(gpa, world_map, chunk_x, chunk_z);
    if (local_x == 0) try relightChunk(gpa, world_map, chunk_x - 1, chunk_z);
    if (local_x == width - 1) try relightChunk(gpa, world_map, chunk_x + 1, chunk_z);
    if (local_z == 0) try relightChunk(gpa, world_map, chunk_x, chunk_z - 1);
    if (local_z == width - 1) try relightChunk(gpa, world_map, chunk_x, chunk_z + 1);
}

const Side = struct { chunk_x: i32, chunk_z: i32, local_x: ?u32, local_z: ?u32 };

fn seedBorder(gpa: std.mem.Allocator, propagation: *Propagation, chunk_x: i32, chunk_z: i32) !void {
    const last = constants.chunk_width - 1;
    const sides = [4]Side{
        .{ .chunk_x = chunk_x - 1, .chunk_z = chunk_z, .local_x = last, .local_z = null },
        .{ .chunk_x = chunk_x + 1, .chunk_z = chunk_z, .local_x = 0, .local_z = null },
        .{ .chunk_x = chunk_x, .chunk_z = chunk_z - 1, .local_x = null, .local_z = last },
        .{ .chunk_x = chunk_x, .chunk_z = chunk_z + 1, .local_x = null, .local_z = 0 },
    };

    for (sides) |side| {
        const neighbor = propagation.world_map.getChunk(side.chunk_x, side.chunk_z) orelse continue;
        const origin_x = side.chunk_x * constants.chunk_width;
        const origin_z = side.chunk_z * constants.chunk_width;

        for (0..constants.chunk_width) |along| {
            const lx = side.local_x orelse @as(u32, @intCast(along));
            const lz = side.local_z orelse @as(u32, @intCast(along));
            for (0..constants.chunk_height) |ly| {
                const level = switch (propagation.kind) {
                    .sky => neighbor.getSkyLight(lx, @intCast(ly), lz),
                    .block => neighbor.getBlockLight(lx, @intCast(ly), lz),
                };
                if (level > 1) {
                    try propagation.seed(gpa, origin_x + @as(i32, @intCast(lx)), @intCast(ly), origin_z + @as(i32, @intCast(lz)));
                }
            }
        }
    }
}

test "an open column is fully sky lit down to the ground" {
    const gpa = std.testing.allocator;
    var world_map = World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    for (0..Chunk.width) |x| {
        for (0..Chunk.width) |z| {
            chunk.setBlockId(@intCast(x), 0, @intCast(z), block.stone);
        }
    }

    try relightChunk(gpa, &world_map, 0, 0);

    try std.testing.expectEqual(@as(u4, 15), world_map.getSkyLight(4, 1, 4));
    try std.testing.expectEqual(@as(u4, 15), world_map.getSkyLight(4, 64, 4));
    try std.testing.expectEqual(@as(u4, 0), world_map.getSkyLight(4, 0, 4));
}

test "sky light decays by one per block sideways under an overhang" {
    const gpa = std.testing.allocator;
    var world_map = World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    for (0..Chunk.width) |x| {
        for (0..Chunk.width) |z| {
            chunk.setBlockId(@intCast(x), 0, @intCast(z), block.stone);
            if (x > 0) chunk.setBlockId(@intCast(x), 2, @intCast(z), block.stone);
        }
    }

    try relightChunk(gpa, &world_map, 0, 0);

    try std.testing.expectEqual(@as(u4, 15), world_map.getSkyLight(0, 1, 8));
    try std.testing.expectEqual(@as(u4, 14), world_map.getSkyLight(1, 1, 8));
    try std.testing.expectEqual(@as(u4, 13), world_map.getSkyLight(2, 1, 8));
    try std.testing.expectEqual(@as(u4, 12), world_map.getSkyLight(3, 1, 8));
}

test "water dims the sky light passing through it" {
    const gpa = std.testing.allocator;
    var world_map = World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    for (0..Chunk.width) |x| {
        for (0..Chunk.width) |z| {
            chunk.setBlockId(@intCast(x), 0, @intCast(z), block.stone);
            chunk.setBlockId(@intCast(x), 1, @intCast(z), block.stationary_water);
            chunk.setBlockId(@intCast(x), 2, @intCast(z), block.stationary_water);
        }
    }

    try relightChunk(gpa, &world_map, 0, 0);

    try std.testing.expectEqual(@as(u4, 15), world_map.getSkyLight(8, 3, 8));
    try std.testing.expectEqual(@as(u4, 12), world_map.getSkyLight(8, 2, 8));
    try std.testing.expectEqual(@as(u4, 9), world_map.getSkyLight(8, 1, 8));
}

test "lava lights a sealed cave and nothing lights an empty one" {
    const gpa = std.testing.allocator;
    var world_map = World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    for (0..Chunk.width) |x| {
        for (0..Chunk.width) |z| {
            for (0..8) |y| chunk.setBlockId(@intCast(x), @intCast(y), @intCast(z), block.stone);
        }
    }
    chunk.setBlockId(4, 4, 4, block.air);
    chunk.setBlockId(5, 4, 4, block.air);
    chunk.setBlockId(6, 4, 4, block.air);

    try relightChunk(gpa, &world_map, 0, 0);
    try std.testing.expectEqual(@as(u4, 0), world_map.getBlockLight(5, 4, 4));

    chunk.setBlockId(4, 4, 4, block.flowing_lava);
    try relightChunk(gpa, &world_map, 0, 0);

    try std.testing.expectEqual(@as(u4, 15), world_map.getBlockLight(4, 4, 4));
    try std.testing.expectEqual(@as(u4, 14), world_map.getBlockLight(5, 4, 4));
    try std.testing.expectEqual(@as(u4, 13), world_map.getBlockLight(6, 4, 4));
}

test "light crosses a chunk seam from an already lit neighbor" {
    const gpa = std.testing.allocator;
    var world_map = World.init(gpa);
    defer world_map.deinit();
    const open = try world_map.createChunk(0, 0);
    const roofed = try world_map.createChunk(1, 0);
    for (0..Chunk.width) |x| {
        for (0..Chunk.width) |z| {
            for (0..2) |y| {
                open.setBlockId(@intCast(x), @intCast(y), @intCast(z), block.stone);
                roofed.setBlockId(@intCast(x), @intCast(y), @intCast(z), block.stone);
            }
            roofed.setBlockId(@intCast(x), 3, @intCast(z), block.stone);
        }
    }

    try relightChunk(gpa, &world_map, 0, 0);
    try relightChunk(gpa, &world_map, 1, 0);

    try std.testing.expectEqual(@as(u4, 15), world_map.getSkyLight(15, 2, 8));
    try std.testing.expectEqual(@as(u4, 14), world_map.getSkyLight(16, 2, 8));
    try std.testing.expectEqual(@as(u4, 13), world_map.getSkyLight(17, 2, 8));
}

test "a generated chunk is lit down to its surface and dark at bedrock" {
    const gpa = std.testing.allocator;
    const TerrainGenerator = @import("terrain_gen.zig");

    const generator = try TerrainGenerator.init(gpa, 1);
    defer generator.deinit(gpa);
    var world_map = World.init(gpa);
    defer world_map.deinit();
    try world_map.ensureDecorated(generator, 0, 0);

    const chunk = world_map.getChunk(0, 0).?;
    var lit_surfaces: u32 = 0;
    for (0..Chunk.width) |x| {
        for (0..Chunk.width) |z| {
            const surface = chunk.getHeightValue(@intCast(x), @intCast(z));
            try std.testing.expect(surface > 0);
            if (world_map.getSkyLight(@intCast(x), surface, @intCast(z)) == max_level) lit_surfaces += 1;
            try std.testing.expectEqual(@as(u4, 0), world_map.getSkyLight(@intCast(x), 1, @intCast(z)));
        }
    }
    try std.testing.expectEqual(@as(u32, Chunk.width * Chunk.width), lit_surfaces);
}

test "the brightness table matches WorldProvider's curve" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), brightness_table[0], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), brightness_table[15], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2611111), brightness_table[8], 1.0e-6);
}
