const std = @import("std");

const world = @import("world");

const chunk_mesher = @import("chunk_mesher.zig");
const Colorizer = @import("colorizer.zig");
const MeshBuilder = @import("mesh_builder.zig");

pub const expand: f32 = 0.002;
pub const outline_color: [4]u8 = .{ 0, 0, 0, 102 };

pub fn appendOutline(mesh: *MeshBuilder, gpa: std.mem.Allocator, id: world.Block, meta: u4, x: i32, y: i32, z: i32) !void {
    const bounds = id.selectionBounds(meta);
    const origin = [3]f32{ @floatFromInt(x), @floatFromInt(y), @floatFromInt(z) };

    var min: [3]f32 = undefined;
    var max: [3]f32 = undefined;
    for (0..3) |axis| {
        min[axis] = origin[axis] + bounds.min[axis] - expand;
        max[axis] = origin[axis] + bounds.max[axis] + expand;
    }

    for ([2]f32{ min[1], max[1] }) |edge_y| {
        try mesh.line(gpa, .{ min[0], edge_y, min[2] }, .{ max[0], edge_y, min[2] }, outline_color);
        try mesh.line(gpa, .{ max[0], edge_y, min[2] }, .{ max[0], edge_y, max[2] }, outline_color);
        try mesh.line(gpa, .{ max[0], edge_y, max[2] }, .{ min[0], edge_y, max[2] }, outline_color);
        try mesh.line(gpa, .{ min[0], edge_y, max[2] }, .{ min[0], edge_y, min[2] }, outline_color);
    }

    for ([2]f32{ min[0], max[0] }) |edge_x| {
        for ([2]f32{ min[2], max[2] }) |edge_z| {
            try mesh.line(gpa, .{ edge_x, min[1], edge_z }, .{ edge_x, max[1], edge_z }, outline_color);
        }
    }
}

pub const first_crack_tile: u8 = 240;
pub const crack_stages: u8 = 10;

pub fn crackTile(progress: f32) u8 {
    const stage: u8 = @intFromFloat(std.math.clamp(progress, 0.0, 1.0) * @as(f32, crack_stages));
    return first_crack_tile + @min(stage, crack_stages - 1);
}

pub const crack_color: [4]u8 = .{ 255, 255, 255, 255 };

pub fn appendCrack(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    colorizer: Colorizer,
    id: world.Block,
    meta: u4,
    x: i32,
    y: i32,
    z: i32,
    progress: f32,
) !void {
    const first_vertex = mesh.vertices.items.len;
    const origin = [3]f32{ @floatFromInt(x), @floatFromInt(y), @floatFromInt(z) };
    const view = world.ChunkView.at(world_map, x, z);

    try chunk_mesher.buildBlockAt(
        mesh,
        gpa,
        &view,
        id,
        meta,
        x,
        y,
        z,
        origin,
        colorizer,
        chunk_mesher.climateAt(&view, x, z),
        .{ .override_tile = crackTile(progress) },
    );

    mesh.paintColors(first_vertex, crack_color);
}

test "the crack texture walks the ten destroy stages" {
    try std.testing.expectEqual(first_crack_tile, crackTile(0.0));
    try std.testing.expectEqual(first_crack_tile + 4, crackTile(0.45));
    try std.testing.expectEqual(first_crack_tile + 9, crackTile(0.95));
    try std.testing.expectEqual(first_crack_tile + 9, crackTile(1.0));
}

fn crackMesh(gpa: std.mem.Allocator, mesh: *MeshBuilder, id: world.Block, meta: u4) !void {
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    _ = try world_map.createChunk(0, 0);

    try appendCrack(mesh, gpa, &world_map, Colorizer.untinted, id, meta, 0, 0, 0, 0.5);
}

test "a sign takes no crack overlay, having no block model to lay one over" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);

    try crackMesh(gpa, &mesh, .sign_post, 8);
    try crackMesh(gpa, &mesh, .wall_sign, 2);
    try std.testing.expectEqual(@as(usize, 0), mesh.vertices.items.len);

    try crackMesh(gpa, &mesh, .planks, 0);
    try std.testing.expect(mesh.vertices.items.len > 0);
}

test "the crack is cropped to a slab's bounds rather than squashed onto them" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);

    try crackMesh(gpa, &mesh, .slab, 0);

    const uv = @import("atlas.zig").tileUv(crackTile(0.5));
    const north = mesh.vertices.items[2 * 4 ..][0..4];
    var v_low: f32 = std.math.floatMax(f32);
    var v_high: f32 = -std.math.floatMax(f32);
    for (north) |vertex| {
        v_low = @min(v_low, vertex.v);
        v_high = @max(v_high, vertex.v);
    }

    try std.testing.expectApproxEqAbs((uv.v0 + uv.v1) / 2.0, v_low, 1.0e-6);
    try std.testing.expectApproxEqAbs(uv.v1, v_high, 1.0e-6);
}

test "cracking a piston head marks its shaft as well as its plate" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);

    try crackMesh(gpa, &mesh, .piston_head, world.block.pistonFacingValue(.up));

    var lowest_y: f32 = std.math.floatMax(f32);
    for (mesh.vertices.items) |vertex| lowest_y = @min(lowest_y, vertex.y);
    try std.testing.expectApproxEqAbs(@as(f32, 12.0 / 16.0 - 1.0), lowest_y, 1.0e-6);
}

test "a lever cracks over its own stick, not over the box it is picked by" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);

    try crackMesh(gpa, &mesh, .lever, 5);

    const bounds = world.Block.lever.selectionBounds(5);
    var leans_out = false;
    for (mesh.vertices.items) |vertex| {
        if (vertex.z > bounds.max[2] + 1.0e-4) leans_out = true;
    }
    try std.testing.expect(leans_out);

    const uv = @import("atlas.zig").tileUv(crackTile(0.5));
    for (mesh.vertices.items) |vertex| {
        try std.testing.expect(vertex.u >= uv.u0 - 1.0e-4 and vertex.u <= uv.u1 + 1.0e-4);
        try std.testing.expect(vertex.v >= uv.v0 - 1.0e-4 and vertex.v <= uv.v1 + 1.0e-4);
    }
}

test "the crack takes a flat white so the block's own tint cannot colour it" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);

    try crackMesh(gpa, &mesh, .grass, 0);

    try std.testing.expect(mesh.vertices.items.len > 0);
    for (mesh.vertices.items) |vertex| try std.testing.expectEqual(crack_color, vertex.color);
}

test "a sign still takes a selection outline, cut to its own thin bounds" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);

    try appendOutline(&mesh, gpa, .wall_sign, 2, 0, 0, 0);
    try std.testing.expectEqual(@as(usize, 12 * 2), mesh.vertices.items.len);

    var lowest_z: f32 = std.math.floatMax(f32);
    for (mesh.vertices.items) |v| lowest_z = @min(lowest_z, v.z);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 - 2.0 / 16.0 - expand), lowest_z, 1.0e-6);
}

test "an outline is twelve edges expanded past the block's own bounds" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);

    try appendOutline(&mesh, gpa, .stone, 0, 3, 4, 5);

    try std.testing.expectEqual(@as(usize, 12 * 2), mesh.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 12 * 2), mesh.indices.items.len);

    var lowest: f32 = std.math.floatMax(f32);
    var highest: f32 = -std.math.floatMax(f32);
    for (mesh.vertices.items) |v| {
        lowest = @min(lowest, v.y);
        highest = @max(highest, v.y);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 4.0 - expand), lowest, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0 + expand), highest, 1.0e-6);
}

test "a snow layer's outline is only as tall as the layer" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);

    try appendOutline(&mesh, gpa, .snow_layer, 0, 0, 0, 0);

    var highest: f32 = -std.math.floatMax(f32);
    for (mesh.vertices.items) |v| highest = @max(highest, v.y);
    try std.testing.expectApproxEqAbs(@as(f32, 0.125 + expand), highest, 1.0e-6);
}

test "a cactus outline hugs the inset sides but stands a full block tall" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);

    try appendOutline(&mesh, gpa, .cactus, 0, 0, 0, 0);

    var lowest_x: f32 = std.math.floatMax(f32);
    var highest_y: f32 = -std.math.floatMax(f32);
    for (mesh.vertices.items) |v| {
        lowest_x = @min(lowest_x, v.x);
        highest_y = @max(highest_y, v.y);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 16.0 - expand), lowest_x, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 + expand), highest_y, 1.0e-6);
}

test "a flower's outline is the narrow plant box, not a full cube" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);

    try appendOutline(&mesh, gpa, .rose, 0, 0, 0, 0);

    var lowest_x: f32 = std.math.floatMax(f32);
    var highest_y: f32 = -std.math.floatMax(f32);
    for (mesh.vertices.items) |v| {
        lowest_x = @min(lowest_x, v.x);
        highest_y = @max(highest_y, v.y);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0.3 - expand), lowest_x, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6 + expand), highest_y, 1.0e-6);
}
