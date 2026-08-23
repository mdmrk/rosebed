const std = @import("std");

const Block = @import("block.zig").Block;
const Chunk = @import("Chunk.zig");
const constants = @import("constants.zig");
const World = @import("World.zig");

const ChunkView = @This();

pub const span = 3;

world_map: *const World,
chunks: [span * span]?*Chunk,
base_x: i32,
base_z: i32,
skylight_subtracted: u4,
brightness: [16]f32,

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
        @divFloor(x, constants.chunk_width),
        @divFloor(z, constants.chunk_width),
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
        @divFloor(x, constants.chunk_width),
        @divFloor(z, constants.chunk_width),
    );
}

fn localX(x: i32) u32 {
    return @intCast(@mod(x, constants.chunk_width));
}

fn localZ(z: i32) u32 {
    return @intCast(@mod(z, constants.chunk_width));
}

pub fn getBlock(self: *const ChunkView, x: i32, y: i32, z: i32) Block {
    if (y < 0 or y >= constants.chunk_height) return .air;
    const chunk = self.chunkFor(x, z) orelse return .air;
    return chunk.getBlock(localX(x), @intCast(y), localZ(z));
}

pub fn getSkyLight(self: *const ChunkView, x: i32, y: i32, z: i32) u4 {
    if (y < 0) return 0;
    if (y >= constants.chunk_height) return 15;
    const chunk = self.chunkFor(x, z) orelse return 0;
    return chunk.getSkyLight(localX(x), @intCast(y), localZ(z));
}

pub fn getBlockLight(self: *const ChunkView, x: i32, y: i32, z: i32) u4 {
    if (y < 0 or y >= constants.chunk_height) return 0;
    const chunk = self.chunkFor(x, z) orelse return 0;
    return chunk.getBlockLight(localX(x), @intCast(y), localZ(z));
}

pub fn getBlockMetadata(self: *const ChunkView, x: i32, y: i32, z: i32) u4 {
    if (y < 0 or y >= constants.chunk_height) return 0;
    const chunk = self.chunkFor(x, z) orelse return 0;
    return chunk.getBlockMetadata(localX(x), @intCast(y), localZ(z));
}
