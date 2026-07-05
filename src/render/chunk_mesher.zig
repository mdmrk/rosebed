const std = @import("std");
const world = @import("world");

const Atlas = @import("atlas.zig");
const Colorizer = @import("colorizer.zig");
const MeshBuilder = @import("mesh_builder.zig");

const FaceDir = struct {
    side: u3,
    shade: f32,
    normal: [3]i32,
    corners: [4][3]f32,
    axis_u: u2,
    axis_v: u2,
};

const faces = [6]FaceDir{
    .{ .side = world.block.down, .shade = 0.5, .normal = .{ 0, -1, 0 }, .axis_u = 0, .axis_v = 2, .corners = .{
        .{ 0, 0, 0 }, .{ 0, 0, 1 }, .{ 1, 0, 1 }, .{ 1, 0, 0 },
    } },
    .{ .side = world.block.up, .shade = 1.0, .normal = .{ 0, 1, 0 }, .axis_u = 0, .axis_v = 2, .corners = .{
        .{ 0, 1, 1 }, .{ 0, 1, 0 }, .{ 1, 1, 0 }, .{ 1, 1, 1 },
    } },
    .{ .side = world.block.north, .shade = 0.8, .normal = .{ 0, 0, -1 }, .axis_u = 0, .axis_v = 1, .corners = .{
        .{ 1, 0, 0 }, .{ 1, 1, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 0 },
    } },
    .{ .side = world.block.south, .shade = 0.8, .normal = .{ 0, 0, 1 }, .axis_u = 0, .axis_v = 1, .corners = .{
        .{ 0, 0, 1 }, .{ 0, 1, 1 }, .{ 1, 1, 1 }, .{ 1, 0, 1 },
    } },
    .{ .side = world.block.west, .shade = 0.6, .normal = .{ -1, 0, 0 }, .axis_u = 2, .axis_v = 1, .corners = .{
        .{ 0, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 1, 1 }, .{ 0, 0, 1 },
    } },
    .{ .side = world.block.east, .shade = 0.6, .normal = .{ 1, 0, 0 }, .axis_u = 2, .axis_v = 1, .corners = .{
        .{ 1, 0, 1 }, .{ 1, 1, 1 }, .{ 1, 1, 0 }, .{ 1, 0, 0 },
    } },
};

fn shadeColor(shade: f32, tint: [3]u8) [4]u8 {
    var color: [4]u8 = .{ 0, 0, 0, 255 };
    for (0..3) |i| {
        const multiplier = @as(f32, @floatFromInt(tint[i])) / 255.0;
        color[i] = @intFromFloat(shade * multiplier * 255.0);
    }
    return color;
}

pub fn blockTint(colorizer: Colorizer, id: u8, metadata: u4, side: u3, temperature: f64, humidity: f64) [3]u8 {
    return switch (id) {
        world.block.grass => if (side == world.block.up)
            colorizer.grassColor(temperature, humidity)
        else
            Colorizer.white,
        world.block.leaves => if (metadata & 1 == 1)
            Colorizer.pine
        else if (metadata & 2 == 2)
            Colorizer.birch
        else
            colorizer.foliageColor(temperature, humidity),
        world.block.tall_grass => if (metadata == 0)
            Colorizer.white
        else
            colorizer.grassColor(temperature, humidity),
        else => Colorizer.white,
    };
}

fn stepAlong(axis: u2, corner: [3]f32) [3]i32 {
    var step: [3]i32 = .{ 0, 0, 0 };
    step[axis] = if (corner[axis] == 1) 1 else -1;
    return step;
}

fn offsetBy(cell: [3]i32, step: [3]i32) [3]i32 {
    return .{ cell[0] + step[0], cell[1] + step[1], cell[2] + step[2] };
}

fn brightnessOf(world_map: *const world.World, cell: [3]i32, minimum: u4) f32 {
    return world.light.brightnessAt(world_map, cell[0], cell[1], cell[2], minimum);
}

fn blocksGrass(world_map: *const world.World, cell: [3]i32) bool {
    return world.block.isOpaque(world_map.getBlockId(cell[0], cell[1], cell[2]));
}

fn smoothBrightness(
    world_map: *const world.World,
    face: FaceDir,
    x: i32,
    y: i32,
    z: i32,
    minimum: u4,
) [4]f32 {
    const cell = offsetBy(.{ x, y, z }, face.normal);
    const center = brightnessOf(world_map, cell, minimum);

    var result: [4]f32 = undefined;
    for (face.corners, 0..) |corner, i| {
        const step_u = stepAlong(face.axis_u, corner);
        const step_v = stepAlong(face.axis_v, corner);
        const cell_u = offsetBy(cell, step_u);
        const cell_v = offsetBy(cell, step_v);
        const edge_u = brightnessOf(world_map, cell_u, minimum);
        const edge_v = brightnessOf(world_map, cell_v, minimum);
        const diagonal = if (blocksGrass(world_map, cell_u) and blocksGrass(world_map, cell_v))
            edge_u
        else
            brightnessOf(world_map, offsetBy(cell_u, step_v), minimum);
        result[i] = (center + edge_u + edge_v + diagonal) / 4.0;
    }
    return result;
}

fn neighborId(world_map: *const world.World, chunk: *const world.Chunk, x: i32, y: i32, z: i32) u8 {
    const world_x = chunk.x * world.constants.chunk_width + x;
    const world_z = chunk.z * world.constants.chunk_width + z;
    return world_map.getBlockId(world_x, y, world_z);
}

pub const Options = struct {
    smooth: bool = false,
    fancy: bool = false,
};

pub const Mesh = struct {
    solid: MeshBuilder = .{},
    translucent: MeshBuilder = .{},

    pub fn deinit(self: *Mesh, gpa: std.mem.Allocator) void {
        self.solid.deinit(gpa);
        self.translucent.deinit(gpa);
    }
};

pub fn buildCube(mesh: *MeshBuilder, gpa: std.mem.Allocator, min: [3]f32, max: [3]f32, face_textures: [6]u8) !void {
    try buildCubeColored(mesh, gpa, min, max, face_textures, null);
}

pub fn buildCubeColored(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    min: [3]f32,
    max: [3]f32,
    face_textures: [6]u8,
    color: ?[4]u8,
) !void {
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
        try mesh.quad(gpa, positions, uvs, color orelse shadeColor(face.shade, Colorizer.white));
    }
}

fn buildCross(mesh: *MeshBuilder, gpa: std.mem.Allocator, tile: u8, tint: [3]u8, brightness: f32, bx: f32, by: f32, bz: f32) !void {
    const uv = Atlas.tileUv(tile);
    const uvs = [4][2]f32{
        .{ uv.u0, uv.v1 },
        .{ uv.u1, uv.v1 },
        .{ uv.u1, uv.v0 },
        .{ uv.u0, uv.v0 },
    };
    try mesh.quad(gpa, .{
        .{ bx, by, bz }, .{ bx + 1, by, bz + 1 }, .{ bx + 1, by + 1, bz + 1 }, .{ bx, by + 1, bz },
    }, uvs, shadeColor(brightness, tint));
    try mesh.quad(gpa, .{
        .{ bx + 1, by, bz }, .{ bx, by, bz + 1 }, .{ bx, by + 1, bz + 1 }, .{ bx + 1, by + 1, bz },
    }, uvs, shadeColor(brightness, tint));
}

pub fn build(gpa: std.mem.Allocator, world_map: *const world.World, chunk: *const world.Chunk, colorizer: Colorizer, options: Options) !Mesh {
    var mesh: Mesh = .{};
    errdefer mesh.deinit(gpa);

    const origin_x: f32 = @floatFromInt(chunk.x * world.constants.chunk_width);
    const origin_z: f32 = @floatFromInt(chunk.z * world.constants.chunk_width);

    for (0..world.constants.chunk_width) |lx| {
        for (0..world.constants.chunk_width) |lz| {
            const column_temperature = chunk.getTemperature(@intCast(lx), @intCast(lz));
            const column_humidity = chunk.getHumidity(@intCast(lx), @intCast(lz));
            for (0..world.constants.chunk_height) |ly| {
                const id = chunk.getBlockId(@intCast(lx), @intCast(ly), @intCast(lz));
                if (id == world.block.air) continue;

                const bx = origin_x + @as(f32, @floatFromInt(lx));
                const by: f32 = @floatFromInt(ly);
                const bz = origin_z + @as(f32, @floatFromInt(lz));

                const metadata = chunk.getBlockMetadata(@intCast(lx), @intCast(ly), @intCast(lz));

                const world_x: i32 = @intFromFloat(bx);
                const world_y: i32 = @intCast(ly);
                const world_z: i32 = @intFromFloat(bz);
                const emitted = world.light.emission(id);
                const own_brightness = world.light.brightnessAt(world_map, world_x, world_y, world_z, emitted);

                const target = if (world.block.isTranslucent(id)) &mesh.translucent else &mesh.solid;

                if (world.block.isCross(id)) {
                    const tint = blockTint(colorizer, id, metadata, world.block.up, column_temperature, column_humidity);
                    try buildCross(target, gpa, world.block.crossTile(id, metadata), tint, own_brightness, bx, by, bz);
                    continue;
                }

                var textures = world.block.faceTextures(id);
                if (id == world.block.log) {
                    const side_tile = world.block.logSideTile(metadata);
                    textures[world.block.north] = side_tile;
                    textures[world.block.south] = side_tile;
                    textures[world.block.west] = side_tile;
                    textures[world.block.east] = side_tile;
                } else if (id == world.block.leaves) {
                    textures = @splat(world.block.leafTile(metadata, options.fancy));
                }

                const height_scale = world.block.heightScale(id);

                for (faces) |face| {
                    const nx: i32 = @as(i32, @intCast(lx)) + face.normal[0];
                    const ny: i32 = @as(i32, @intCast(ly)) + face.normal[1];
                    const nz: i32 = @as(i32, @intCast(lz)) + face.normal[2];
                    if (!world.block.shouldRenderFace(id, neighborId(world_map, chunk, nx, ny, nz), face.side, options.fancy)) continue;

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

                    const tint = blockTint(colorizer, id, metadata, face.side, column_temperature, column_humidity);

                    if (options.smooth) {
                        const corner_brightness = smoothBrightness(world_map, face, world_x, world_y, world_z, emitted);
                        var colors: [4][4]u8 = undefined;
                        for (corner_brightness, 0..) |brightness, i| {
                            colors[i] = shadeColor(face.shade * brightness, tint);
                        }
                        try target.quadShaded(gpa, positions, uvs, colors);
                        continue;
                    }

                    const partial_top = face.side == world.block.up and height_scale != 1.0 and !world.block.isLiquid(id);
                    const brightness = if (partial_top)
                        own_brightness
                    else
                        world.light.brightnessAt(world_map, world_x + face.normal[0], world_y + face.normal[1], world_z + face.normal[2], emitted);

                    try target.quad(gpa, positions, uvs, shadeColor(face.shade * brightness, tint));
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

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?, Colorizer.untinted, .{});
    defer mesh.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2 * 4), mesh.solid.vertices.items.len);
}

test "a solid neighbor does not cull a cross-shaped plant" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlockId(0, 0, 0, world.block.stone);
    chunk.setBlockId(1, 0, 0, world.block.tall_grass);

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?, Colorizer.untinted, .{});
    defer mesh.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 6 * 4 + 2 * 4), mesh.solid.vertices.items.len);
}

test "a snow layer renders as a thin partial-height cube" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlockId(0, 1, 0, world.block.stone);
    chunk.setBlockId(0, 2, 0, world.block.snow_layer);

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?, Colorizer.untinted, .{});
    defer mesh.deinit(gpa);

    var max_y: f32 = 0;
    for (mesh.solid.vertices.items) |v| {
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

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?, Colorizer.untinted, .{});
    defer mesh.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 6 * 4), mesh.solid.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 6 * 6), mesh.solid.indices.items.len);
}

test "each cube face carries its own directional shade" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlockId(8, 0, 8, world.block.stone);

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?, Colorizer.untinted, .{});
    defer mesh.deinit(gpa);

    const expected = [6]u8{ 6, 255, 204, 204, 153, 153 };
    for (expected, 0..) |level, face| {
        for (mesh.solid.vertices.items[face * 4 ..][0..4]) |v| {
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

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?, Colorizer.untinted, .{});
    defer mesh.deinit(gpa);

    for (mesh.solid.vertices.items) |v| {
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

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?, Colorizer.untinted, .{});
    defer mesh.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 10 * 4), mesh.solid.vertices.items.len);
}

test "an all-air chunk produces an empty mesh" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    _ = try world_map.createChunk(0, 0);

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?, Colorizer.untinted, .{});
    defer mesh.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), mesh.solid.vertices.items.len);
}

test "a block at a chunk boundary culls its face against a loaded neighbor chunk" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const a = try world_map.createChunk(0, 0);
    a.setBlockId(15, 0, 0, world.block.stone);
    const b = try world_map.createChunk(1, 0);
    b.setBlockId(0, 0, 0, world.block.stone);

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?, Colorizer.untinted, .{});
    defer mesh.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 5 * 4), mesh.solid.vertices.items.len);
}

test "only the grass block's top face takes the biome tint" {
    const gpa = std.testing.allocator;
    const table = try gpa.alloc([3]u8, 256 * 256);
    defer gpa.free(table);
    @memset(table, .{ 100, 200, 50 });
    const colorizer: Colorizer = .{ .grass = table, .foliage = table };

    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlockId(8, 0, 8, world.block.grass);

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?, colorizer, .{});
    defer mesh.deinit(gpa);

    try std.testing.expectEqual([4]u8{ 100, 200, 50, 255 }, mesh.solid.vertices.items[1 * 4].color);
    try std.testing.expectEqual([4]u8{ 204, 204, 204, 255 }, mesh.solid.vertices.items[2 * 4].color);
}

test "birch leaves take the fixed foliage color instead of the biome lookup" {
    const gpa = std.testing.allocator;
    const table = try gpa.alloc([3]u8, 256 * 256);
    defer gpa.free(table);
    @memset(table, .{ 100, 200, 50 });
    const colorizer: Colorizer = .{ .grass = table, .foliage = table };

    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlockId(8, 0, 8, world.block.leaves);
    chunk.setBlockMetadata(8, 0, 8, 2);
    chunk.setBlockId(11, 0, 11, world.block.leaves);

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?, colorizer, .{});
    defer mesh.deinit(gpa);

    const birch_top = mesh.solid.vertices.items[1 * 4].color;
    const oak_top = mesh.solid.vertices.items[(6 + 1) * 4].color;
    try std.testing.expectEqual([4]u8{ Colorizer.birch[0], Colorizer.birch[1], Colorizer.birch[2], 255 }, birch_top);
    try std.testing.expectEqual([4]u8{ 100, 200, 50, 255 }, oak_top);
}

test "water builds into the translucent pass, not the solid one" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlockId(8, 0, 8, world.block.stationary_water);

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?, Colorizer.untinted, .{});
    defer mesh.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), mesh.solid.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 6 * 4), mesh.translucent.vertices.items.len);
}

test "touching water faces are culled but the surface between water and air is not" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlockId(8, 0, 8, world.block.stationary_water);
    chunk.setBlockId(8, 1, 8, world.block.stationary_water);

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?, Colorizer.untinted, .{});
    defer mesh.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 10 * 4), mesh.translucent.vertices.items.len);
}

test "a solid block keeps the face it shares with water" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlockId(8, 0, 8, world.block.stone);
    chunk.setBlockId(8, 1, 8, world.block.stationary_water);

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?, Colorizer.untinted, .{});
    defer mesh.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 6 * 4), mesh.solid.vertices.items.len);
}

test "fancy leaves keep the face two leaf blocks share, fast leaves cull it" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlockId(8, 0, 8, world.block.leaves);
    chunk.setBlockId(9, 0, 8, world.block.leaves);
    try world.light.relightChunk(gpa, &world_map, 0, 0);

    var fast = try build(gpa, &world_map, world_map.getChunk(0, 0).?, Colorizer.untinted, .{});
    defer fast.deinit(gpa);
    var fancy = try build(gpa, &world_map, world_map.getChunk(0, 0).?, Colorizer.untinted, .{ .fancy = true });
    defer fancy.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 10 * 4), fast.solid.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 12 * 4), fancy.solid.vertices.items.len);
}

test "leaves never cull a neighbouring block's face" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlockId(8, 0, 8, world.block.stone);
    chunk.setBlockId(9, 0, 8, world.block.leaves);
    try world.light.relightChunk(gpa, &world_map, 0, 0);

    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?, Colorizer.untinted, .{ .fancy = true });
    defer mesh.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 11 * 4), mesh.solid.vertices.items.len);
}

test "an unobstructed face lights all four corners the same" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlockId(8, 0, 8, world.block.stone);

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    const corners = smoothBrightness(&world_map, faces[world.block.up], 8, 0, 8, 0);
    for (corners) |corner| try std.testing.expectApproxEqAbs(@as(f32, 1.0), corner, 1.0e-6);
}

test "a block beside the face darkens the two corners nearest it" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlockId(8, 0, 8, world.block.stone);
    chunk.setBlockId(9, 1, 8, world.block.stone);

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    const corners = smoothBrightness(&world_map, faces[world.block.up], 8, 0, 8, 0);

    try std.testing.expectApproxEqAbs(@as(f32, 1.0), corners[0], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), corners[1], 1.0e-6);
    try std.testing.expect(corners[2] < 1.0);
    try std.testing.expect(corners[3] < 1.0);
    try std.testing.expectApproxEqAbs(corners[2], corners[3], 1.0e-6);
}

test "a diagonal block darkens only the corner it touches" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlockId(8, 0, 8, world.block.stone);
    chunk.setBlockId(9, 1, 9, world.block.stone);

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    const corners = smoothBrightness(&world_map, faces[world.block.up], 8, 0, 8, 0);

    const dark = world.light.brightnessAt(&world_map, 9, 1, 9, 0);
    try std.testing.expectApproxEqAbs((3.0 + dark) / 4.0, corners[3], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), corners[0], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), corners[1], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), corners[2], 1.0e-6);
}

test "two solid edges hide whatever is diagonally behind them" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlockId(8, 0, 8, world.block.stone);
    chunk.setBlockId(9, 1, 8, world.block.stone);
    chunk.setBlockId(8, 1, 9, world.block.stone);

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    const corners = smoothBrightness(&world_map, faces[world.block.up], 8, 0, 8, 0);

    const dark = world.light.brightnessAt(&world_map, 9, 1, 8, 0);
    try std.testing.expect(world.light.brightnessAt(&world_map, 9, 1, 9, 0) > dark);
    try std.testing.expectApproxEqAbs((1.0 + 3.0 * dark) / 4.0, corners[3], 1.0e-6);
}

test "a seam face needs its neighbour lit before it shades correctly" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    const near = try world_map.createChunk(0, 0);
    const far = try world_map.createChunk(1, 0);
    for (0..world.constants.chunk_width) |x| {
        for (0..world.constants.chunk_width) |z| {
            near.setBlockId(@intCast(x), 0, @intCast(z), world.block.stone);
            far.setBlockId(@intCast(x), 0, @intCast(z), world.block.stone);
        }
    }

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    const unlit_neighbour = smoothBrightness(&world_map, faces[world.block.up], 15, 0, 8, 0);
    try std.testing.expect(unlit_neighbour[2] < 1.0);
    try std.testing.expect(unlit_neighbour[3] < 1.0);

    try world.light.relightChunk(gpa, &world_map, 1, 0);
    const lit_neighbour = smoothBrightness(&world_map, faces[world.block.up], 15, 0, 8, 0);
    const interior = smoothBrightness(&world_map, faces[world.block.up], 8, 0, 8, 0);
    for (lit_neighbour, interior) |seam, inside| {
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), seam, 1.0e-6);
        try std.testing.expectApproxEqAbs(inside, seam, 1.0e-6);
    }
}

test "smooth lighting varies a face's vertex colors, flat lighting does not" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlockId(8, 0, 8, world.block.stone);
    chunk.setBlockId(9, 1, 8, world.block.stone);
    try world.light.relightChunk(gpa, &world_map, 0, 0);

    var flat = try build(gpa, &world_map, world_map.getChunk(0, 0).?, Colorizer.untinted, .{});
    defer flat.deinit(gpa);
    var smooth = try build(gpa, &world_map, world_map.getChunk(0, 0).?, Colorizer.untinted, .{ .smooth = true });
    defer smooth.deinit(gpa);

    try std.testing.expectEqual(flat.solid.vertices.items.len, smooth.solid.vertices.items.len);
    try std.testing.expect(!uniformQuads(smooth.solid));
    try std.testing.expect(uniformQuads(flat.solid));
}

fn uniformQuads(mesh: MeshBuilder) bool {
    var i: usize = 0;
    while (i < mesh.vertices.items.len) : (i += 4) {
        const first = mesh.vertices.items[i].color;
        for (mesh.vertices.items[i .. i + 4]) |vertex| {
            if (!std.mem.eql(u8, &first, &vertex.color)) return false;
        }
    }
    return true;
}
