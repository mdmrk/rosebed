const std = @import("std");
const world = @import("world");

const MeshBuilder = @import("mesh_builder.zig");

pub const expand: f32 = 0.002;
pub const outline_color: [4]u8 = .{ 0, 0, 0, 102 };

pub fn appendOutline(mesh: *MeshBuilder, gpa: std.mem.Allocator, id: world.Block, x: i32, y: i32, z: i32) !void {
    const bounds = id.selectionBounds();
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

pub fn appendCrack(mesh: *MeshBuilder, gpa: std.mem.Allocator, id: world.Block, x: i32, y: i32, z: i32, progress: f32) !void {
    const bounds = id.selectionBounds();
    const tile = crackTile(progress);
    const min = [3]f32{
        @as(f32, @floatFromInt(x)) + bounds.min[0],
        @as(f32, @floatFromInt(y)) + bounds.min[1],
        @as(f32, @floatFromInt(z)) + bounds.min[2],
    };
    const max = [3]f32{
        @as(f32, @floatFromInt(x)) + bounds.max[0],
        @as(f32, @floatFromInt(y)) + bounds.max[1],
        @as(f32, @floatFromInt(z)) + bounds.max[2],
    };
    try @import("chunk_mesher.zig").buildCubeColored(mesh, gpa, min, max, world.block.FaceTextures.initFill(tile), .{ 255, 255, 255, 255 });
}

test "the crack texture walks the ten destroy stages" {
    try std.testing.expectEqual(first_crack_tile, crackTile(0.0));
    try std.testing.expectEqual(first_crack_tile + 4, crackTile(0.45));
    try std.testing.expectEqual(first_crack_tile + 9, crackTile(0.95));
    try std.testing.expectEqual(first_crack_tile + 9, crackTile(1.0));
}

test "an outline is twelve edges expanded past the block's own bounds" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);

    try appendOutline(&mesh, gpa, world.Block.stone, 3, 4, 5);

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

    try appendOutline(&mesh, gpa, world.Block.snow_layer, 0, 0, 0);

    var highest: f32 = -std.math.floatMax(f32);
    for (mesh.vertices.items) |v| highest = @max(highest, v.y);
    try std.testing.expectApproxEqAbs(@as(f32, 0.125 + expand), highest, 1.0e-6);
}

test "a flower's outline is the narrow plant box, not a full cube" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);

    try appendOutline(&mesh, gpa, world.Block.rose, 0, 0, 0);

    var lowest_x: f32 = std.math.floatMax(f32);
    var highest_y: f32 = -std.math.floatMax(f32);
    for (mesh.vertices.items) |v| {
        lowest_x = @min(lowest_x, v.x);
        highest_y = @max(highest_y, v.y);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0.3 - expand), lowest_x, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6 + expand), highest_y, 1.0e-6);
}
