const std = @import("std");

const Block = @import("block.zig").Block;
const BlockPos = @import("BlockPos.zig");
const Chunk = @import("Chunk.zig");
const light = @import("light.zig");
const World = @import("World.zig");

const ChunkView = @This();

pub const span = 3;

world_map: *const World,
chunks: [span * span]?*Chunk,
base_x: i32,
base_z: i32,
skylight_subtracted: u4,
brightness: [16]f32,
light_cache: ?*LightCache = null,

pub const LightCache = struct {
    pub const width = Chunk.width + 2;
    pub const height = Chunk.height + 2;
    const unknown: u8 = 0xFF;
    const opaque_bit: u8 = 0x10;

    cells: [width * width * height]u8,

    pub fn reset(self: *LightCache) void {
        @memset(&self.cells, unknown);
    }
};

pub const CellLight = struct {
    level: u4,
    is_opaque: bool,
};

pub fn around(world_map: *const World, chunk_x: i32, chunk_z: i32) ChunkView {
    var view: ChunkView = .{
        .world_map = world_map,
        .chunks = undefined,
        .base_x = chunk_x - 1,
        .base_z = chunk_z - 1,
        .skylight_subtracted = world_map.skylight_subtracted,
        .brightness = world_map.brightness,
    };
    for (0..span) |dz| {
        for (0..span) |dx| {
            view.chunks[dz * span + dx] = world_map.getChunk(
                view.base_x + @as(i32, @intCast(dx)),
                view.base_z + @as(i32, @intCast(dz)),
            );
        }
    }
    return view;
}

pub fn at(world_map: *const World, x: i32, z: i32) ChunkView {
    return around(
        world_map,
        @divFloor(x, Chunk.width),
        @divFloor(z, Chunk.width),
    );
}

pub fn getChunk(self: *const ChunkView, chunk_x: i32, chunk_z: i32) ?*Chunk {
    const dx = chunk_x - self.base_x;
    const dz = chunk_z - self.base_z;
    if (dx < 0 or dx >= span or dz < 0 or dz >= span) {
        return self.world_map.getChunk(chunk_x, chunk_z);
    }
    return self.chunks[@intCast(dz * span + dx)];
}

fn chunkFor(self: *const ChunkView, x: i32, z: i32) ?*Chunk {
    return self.getChunk(
        @divFloor(x, Chunk.width),
        @divFloor(z, Chunk.width),
    );
}

fn localX(x: i32) u32 {
    return @intCast(@mod(x, Chunk.width));
}

fn localZ(z: i32) u32 {
    return @intCast(@mod(z, Chunk.width));
}

pub fn getBlock(self: *const ChunkView, pos: BlockPos) Block {
    if (pos.y < 0 or pos.y >= Chunk.height) return .air;
    const chunk = self.chunkFor(pos.x, pos.z) orelse return .air;
    return chunk.getBlock(localX(pos.x), @intCast(pos.y), localZ(pos.z));
}

pub fn getSkyLight(self: *const ChunkView, pos: BlockPos) u4 {
    if (pos.y < 0) return 0;
    if (pos.y >= Chunk.height) return 15;
    const chunk = self.chunkFor(pos.x, pos.z) orelse return 0;
    return chunk.getSkyLight(localX(pos.x), @intCast(pos.y), localZ(pos.z));
}

pub fn getBlockLight(self: *const ChunkView, pos: BlockPos) u4 {
    if (pos.y < 0 or pos.y >= Chunk.height) return 0;
    const chunk = self.chunkFor(pos.x, pos.z) orelse return 0;
    return chunk.getBlockLight(localX(pos.x), @intCast(pos.y), localZ(pos.z));
}

fn lightCacheSlot(self: *const ChunkView, pos: BlockPos) ?*u8 {
    const cache = self.light_cache orelse return null;
    const x = pos.x - (self.base_x + 1) * Chunk.width + 1;
    const z = pos.z - (self.base_z + 1) * Chunk.width + 1;
    const y = pos.y + 1;
    if (x < 0 or x >= LightCache.width or z < 0 or z >= LightCache.width or y < 0 or y >= LightCache.height) return null;
    return &cache.cells[@intCast((x * LightCache.width + z) * LightCache.height + y)];
}

pub fn cellLight(self: *const ChunkView, pos: BlockPos) CellLight {
    const slot = self.lightCacheSlot(pos) orelse return .{
        .level = light.levelAt(self, pos),
        .is_opaque = self.getBlock(pos).isOpaque(),
    };
    if (slot.* == LightCache.unknown) {
        const level = light.levelAt(self, pos);
        const flag: u8 = if (self.getBlock(pos).isOpaque()) LightCache.opaque_bit else 0;
        slot.* = @as(u8, level) | flag;
    }
    return .{
        .level = @truncate(slot.*),
        .is_opaque = slot.* & LightCache.opaque_bit != 0,
    };
}

pub fn getBlockMetadata(self: *const ChunkView, pos: BlockPos) u4 {
    if (pos.y < 0 or pos.y >= Chunk.height) return 0;
    const chunk = self.chunkFor(pos.x, pos.z) orelse return 0;
    return chunk.getBlockMetadata(localX(pos.x), @intCast(pos.y), localZ(pos.z));
}

test "the light cache answers exactly like an uncached lookup" {
    const gpa = std.testing.allocator;
    var world_map = World.init(gpa);
    defer world_map.deinit();

    var prng: std.Random.DefaultPrng = .init(1);
    const random = prng.random();
    const palette = [_]Block{ .air, .air, .stone, .glass, .slab, .stairs_wood, .leaves, .stationary_water };

    var chunk_z: i32 = -1;
    while (chunk_z <= 1) : (chunk_z += 1) {
        var chunk_x: i32 = -1;
        while (chunk_x <= 1) : (chunk_x += 1) {
            const chunk = try world_map.createChunk(chunk_x, chunk_z);
            for (0..Chunk.width) |x| for (0..Chunk.height) |y| for (0..Chunk.width) |z| {
                chunk.setBlock(@intCast(x), @intCast(y), @intCast(z), palette[random.uintLessThan(usize, palette.len)]);
                chunk.setSkyLight(@intCast(x), @intCast(y), @intCast(z), random.int(u4));
                chunk.setBlockLight(@intCast(x), @intCast(y), @intCast(z), random.int(u4));
            };
        }
    }
    world_map.skylight_subtracted = 4;

    const plain = ChunkView.around(&world_map, 0, 0);
    var cached = plain;
    const cache = try gpa.create(LightCache);
    defer gpa.destroy(cache);
    cache.reset();
    cached.light_cache = cache;

    for (0..2) |_| {
        var x: i32 = -2;
        while (x <= Chunk.width + 1) : (x += 1) {
            var z: i32 = -2;
            while (z <= Chunk.width + 1) : (z += 1) {
                var y: i32 = -2;
                while (y <= Chunk.height + 1) : (y += 1) {
                    const pos: BlockPos = .init(x, y, z);
                    try std.testing.expectEqual(plain.cellLight(pos), cached.cellLight(pos));
                }
            }
        }
    }
}
