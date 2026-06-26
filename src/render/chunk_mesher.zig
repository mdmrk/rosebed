const std = @import("std");
const world = @import("world");

const Atlas = @import("atlas.zig");
const MeshBuilder = @import("mesh_builder.zig");

const FaceDir = struct {
    side: u3,
    normal: [3]i32,
    corners: [4][3]f32,
};

const faces = [6]FaceDir{
    .{ .side = world.block.down, .normal = .{ 0, -1, 0 }, .corners = .{
        .{ 0, 0, 0 }, .{ 0, 0, 1 }, .{ 1, 0, 1 }, .{ 1, 0, 0 },
    } },
    .{ .side = world.block.up, .normal = .{ 0, 1, 0 }, .corners = .{
        .{ 0, 1, 1 }, .{ 0, 1, 0 }, .{ 1, 1, 0 }, .{ 1, 1, 1 },
    } },
    .{ .side = world.block.north, .normal = .{ 0, 0, -1 }, .corners = .{
        .{ 1, 0, 0 }, .{ 1, 1, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 0 },
    } },
    .{ .side = world.block.south, .normal = .{ 0, 0, 1 }, .corners = .{
        .{ 0, 0, 1 }, .{ 0, 1, 1 }, .{ 1, 1, 1 }, .{ 1, 0, 1 },
    } },
    .{ .side = world.block.west, .normal = .{ -1, 0, 0 }, .corners = .{
        .{ 0, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 1, 1 }, .{ 0, 0, 1 },
    } },
    .{ .side = world.block.east, .normal = .{ 1, 0, 0 }, .corners = .{
        .{ 1, 0, 1 }, .{ 1, 1, 1 }, .{ 1, 1, 0 }, .{ 1, 0, 0 },
    } },
};

fn neighborIsOpaque(world_map: *const world.World, chunk: *const world.Chunk, x: i32, y: i32, z: i32) bool {
    const world_x = chunk.x * world.constants.chunk_width + x;
    const world_z = chunk.z * world.constants.chunk_width + z;
    return world.block.isOpaque(world_map.getBlockId(world_x, y, world_z));
}

pub fn build(gpa: std.mem.Allocator, world_map: *const world.World, chunk: *const world.Chunk) !MeshBuilder {
    var mesh: MeshBuilder = .{};
    errdefer mesh.deinit(gpa);

    const origin_x: f32 = @floatFromInt(chunk.x * world.constants.chunk_width);
    const origin_z: f32 = @floatFromInt(chunk.z * world.constants.chunk_width);

    for (0..world.constants.chunk_width) |lx| {
        for (0..world.constants.chunk_height) |ly| {
            for (0..world.constants.chunk_width) |lz| {
                const id = chunk.getBlockId(@intCast(lx), @intCast(ly), @intCast(lz));
                if (!world.block.isOpaque(id)) continue;

                const textures = world.block.faceTextures(id);
                const bx = origin_x + @as(f32, @floatFromInt(lx));
                const by: f32 = @floatFromInt(ly);
                const bz = origin_z + @as(f32, @floatFromInt(lz));

                for (faces) |face| {
                    const nx: i32 = @as(i32, @intCast(lx)) + face.normal[0];
                    const ny: i32 = @as(i32, @intCast(ly)) + face.normal[1];
                    const nz: i32 = @as(i32, @intCast(lz)) + face.normal[2];
                    if (neighborIsOpaque(world_map, chunk, nx, ny, nz)) continue;

                    const uv = Atlas.tileUv(textures[face.side]);
                    var positions: [4][3]f32 = undefined;
                    for (face.corners, 0..) |corner, i| {
                        positions[i] = .{ bx + corner[0], by + corner[1], bz + corner[2] };
                    }
                    const uvs = [4][2]f32{
                        .{ uv.u0, uv.v1 },
                        .{ uv.u0, uv.v0 },
                        .{ uv.u1, uv.v0 },
                        .{ uv.u1, uv.v1 },
                    };

                    try mesh.quad(gpa, positions, uvs, .{ 255, 255, 255, 255 });
                }
            }
        }
    }

    return mesh;
}

test "a lone block emits all 6 faces" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    var chunk = world.Chunk.init(0, 0);
    chunk.setBlockId(0, 0, 0, world.block.stone);
    try world_map.chunks.put(gpa, .{ .x = 0, .z = 0 }, chunk);

    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?);
    defer mesh.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 6 * 4), mesh.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 6 * 6), mesh.indices.items.len);
}

test "adjacent blocks cull their shared face" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    var chunk = world.Chunk.init(0, 0);
    chunk.setBlockId(0, 0, 0, world.block.stone);
    chunk.setBlockId(1, 0, 0, world.block.stone);
    try world_map.chunks.put(gpa, .{ .x = 0, .z = 0 }, chunk);

    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?);
    defer mesh.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 10 * 4), mesh.vertices.items.len);
}

test "an all-air chunk produces an empty mesh" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    try world_map.chunks.put(gpa, .{ .x = 0, .z = 0 }, world.Chunk.init(0, 0));

    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?);
    defer mesh.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), mesh.vertices.items.len);
}

test "a block at a chunk boundary culls its face against a loaded neighbor chunk" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    var a = world.Chunk.init(0, 0);
    a.setBlockId(15, 0, 0, world.block.stone);
    var b = world.Chunk.init(1, 0);
    b.setBlockId(0, 0, 0, world.block.stone);
    try world_map.chunks.put(gpa, .{ .x = 0, .z = 0 }, a);
    try world_map.chunks.put(gpa, .{ .x = 1, .z = 0 }, b);

    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?);
    defer mesh.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 5 * 4), mesh.vertices.items.len);
}
