const std = @import("std");
const world = @import("world");

const Atlas = @import("atlas.zig");
const MeshBuilder = @import("mesh_builder.zig");

const FaceDir = struct {
    side: u3,
    shade: f32,
    normal: [3]i32,
    corners: [4][3]f32,
};

const faces = [6]FaceDir{
    .{ .side = world.block.down, .shade = 0.5, .normal = .{ 0, -1, 0 }, .corners = .{
        .{ 0, 0, 0 }, .{ 0, 0, 1 }, .{ 1, 0, 1 }, .{ 1, 0, 0 },
    } },
    .{ .side = world.block.up, .shade = 1.0, .normal = .{ 0, 1, 0 }, .corners = .{
        .{ 0, 1, 1 }, .{ 0, 1, 0 }, .{ 1, 1, 0 }, .{ 1, 1, 1 },
    } },
    .{ .side = world.block.north, .shade = 0.8, .normal = .{ 0, 0, -1 }, .corners = .{
        .{ 1, 0, 0 }, .{ 1, 1, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 0 },
    } },
    .{ .side = world.block.south, .shade = 0.8, .normal = .{ 0, 0, 1 }, .corners = .{
        .{ 0, 0, 1 }, .{ 0, 1, 1 }, .{ 1, 1, 1 }, .{ 1, 0, 1 },
    } },
    .{ .side = world.block.west, .shade = 0.6, .normal = .{ -1, 0, 0 }, .corners = .{
        .{ 0, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 1, 1 }, .{ 0, 0, 1 },
    } },
    .{ .side = world.block.east, .shade = 0.6, .normal = .{ 1, 0, 0 }, .corners = .{
        .{ 1, 0, 1 }, .{ 1, 1, 1 }, .{ 1, 1, 0 }, .{ 1, 0, 0 },
    } },
};

fn shadeColor(shade: f32) [4]u8 {
    const level: u8 = @intFromFloat(shade * 255.0);
    return .{ level, level, level, 255 };
}

fn neighborIsOpaque(world_map: *const world.World, chunk: *const world.Chunk, x: i32, y: i32, z: i32) bool {
    const world_x = chunk.x * world.constants.chunk_width + x;
    const world_z = chunk.z * world.constants.chunk_width + z;
    return world.block.isOpaque(world_map.getBlockId(world_x, y, world_z));
}

pub fn buildCube(mesh: *MeshBuilder, gpa: std.mem.Allocator, min: [3]f32, max: [3]f32, face_textures: [6]u8) !void {
    for (faces) |face| {
        const uv = Atlas.tileUv(face_textures[face.side]);
        var positions: [4][3]f32 = undefined;
        for (face.corners, 0..) |corner, i| {
            positions[i] = .{
                if (corner[0] == 0) min[0] else max[0],
                if (corner[1] == 0) min[1] else max[1],
                if (corner[2] == 0) min[2] else max[2],
            };
        }
        const uvs = [4][2]f32{
            .{ uv.u0, uv.v1 },
            .{ uv.u0, uv.v0 },
            .{ uv.u1, uv.v0 },
            .{ uv.u1, uv.v1 },
        };
        try mesh.quad(gpa, positions, uvs, shadeColor(face.shade));
    }
}

fn buildCross(mesh: *MeshBuilder, gpa: std.mem.Allocator, tile: u8, bx: f32, by: f32, bz: f32) !void {
    const uv = Atlas.tileUv(tile);
    const uvs = [4][2]f32{
        .{ uv.u0, uv.v1 },
        .{ uv.u1, uv.v1 },
        .{ uv.u1, uv.v0 },
        .{ uv.u0, uv.v0 },
    };
    try mesh.quad(gpa, .{
        .{ bx, by, bz }, .{ bx + 1, by, bz + 1 }, .{ bx + 1, by + 1, bz + 1 }, .{ bx, by + 1, bz },
    }, uvs, .{ 255, 255, 255, 255 });
    try mesh.quad(gpa, .{
        .{ bx + 1, by, bz }, .{ bx, by, bz + 1 }, .{ bx, by + 1, bz + 1 }, .{ bx + 1, by + 1, bz },
    }, uvs, .{ 255, 255, 255, 255 });
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
                if (id == world.block.air) continue;

                const bx = origin_x + @as(f32, @floatFromInt(lx));
                const by: f32 = @floatFromInt(ly);
                const bz = origin_z + @as(f32, @floatFromInt(lz));

                if (world.block.isCross(id)) {
                    const metadata = chunk.getBlockMetadata(@intCast(lx), @intCast(ly), @intCast(lz));
                    try buildCross(&mesh, gpa, world.block.crossTile(id, metadata), bx, by, bz);
                    continue;
                }

                var textures = world.block.faceTextures(id);
                if (id == world.block.log) {
                    const metadata = chunk.getBlockMetadata(@intCast(lx), @intCast(ly), @intCast(lz));
                    const side_tile = world.block.logSideTile(metadata);
                    textures[world.block.north] = side_tile;
                    textures[world.block.south] = side_tile;
                    textures[world.block.west] = side_tile;
                    textures[world.block.east] = side_tile;
                }

                const height_scale = world.block.heightScale(id);

                for (faces) |face| {
                    const nx: i32 = @as(i32, @intCast(lx)) + face.normal[0];
                    const ny: i32 = @as(i32, @intCast(ly)) + face.normal[1];
                    const nz: i32 = @as(i32, @intCast(lz)) + face.normal[2];
                    if (neighborIsOpaque(world_map, chunk, nx, ny, nz)) continue;

                    const uv = Atlas.tileUv(textures[face.side]);
                    var positions: [4][3]f32 = undefined;
                    for (face.corners, 0..) |corner, i| {
                        positions[i] = .{ bx + corner[0], by + corner[1] * height_scale, bz + corner[2] };
                    }
                    const uvs = [4][2]f32{
                        .{ uv.u0, uv.v1 },
                        .{ uv.u0, uv.v0 },
                        .{ uv.u1, uv.v0 },
                        .{ uv.u1, uv.v1 },
                    };

                    try mesh.quad(gpa, positions, uvs, shadeColor(face.shade));
                }
            }
        }
    }

    return mesh;
}

test "a cross-shaped plant emits two crossing quads instead of a cube" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlockId(0, 0, 0, world.block.tall_grass);

    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?);
    defer mesh.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2 * 4), mesh.vertices.items.len);
}

test "a solid neighbor does not cull a cross-shaped plant" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlockId(0, 0, 0, world.block.stone);
    chunk.setBlockId(1, 0, 0, world.block.tall_grass);

    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?);
    defer mesh.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 6 * 4 + 2 * 4), mesh.vertices.items.len);
}

test "a snow layer renders as a thin partial-height cube" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlockId(0, 1, 0, world.block.stone);
    chunk.setBlockId(0, 2, 0, world.block.snow_layer);

    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?);
    defer mesh.deinit(gpa);

    var max_y: f32 = 0;
    for (mesh.vertices.items) |v| {
        if (v.y > 2.0 and v.y < 3.0) max_y = @max(max_y, v.y);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 2.125), max_y, 1.0e-5);
}

test "a lone block emits all 6 faces" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlockId(0, 0, 0, world.block.stone);

    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?);
    defer mesh.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 6 * 4), mesh.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 6 * 6), mesh.indices.items.len);
}

test "each cube face carries its own directional shade" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlockId(0, 0, 0, world.block.stone);

    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?);
    defer mesh.deinit(gpa);

    const expected = [6]u8{ 127, 255, 204, 204, 153, 153 };
    for (expected, 0..) |level, face| {
        for (mesh.vertices.items[face * 4 ..][0..4]) |v| {
            try std.testing.expectEqual([4]u8{ level, level, level, 255 }, v.color);
        }
    }
}

test "a cross-shaped plant is not directionally shaded" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlockId(0, 0, 0, world.block.rose);

    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?);
    defer mesh.deinit(gpa);

    for (mesh.vertices.items) |v| {
        try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, v.color);
    }
}

test "adjacent blocks cull their shared face" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlockId(0, 0, 0, world.block.stone);
    chunk.setBlockId(1, 0, 0, world.block.stone);

    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?);
    defer mesh.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 10 * 4), mesh.vertices.items.len);
}

test "an all-air chunk produces an empty mesh" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    _ = try world_map.createChunk(0, 0);

    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?);
    defer mesh.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), mesh.vertices.items.len);
}

test "a block at a chunk boundary culls its face against a loaded neighbor chunk" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const a = try world_map.createChunk(0, 0);
    a.setBlockId(15, 0, 0, world.block.stone);
    const b = try world_map.createChunk(1, 0);
    b.setBlockId(0, 0, 0, world.block.stone);

    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?);
    defer mesh.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 5 * 4), mesh.vertices.items.len);
}
