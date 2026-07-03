const std = @import("std");
const game = @import("game");
const world = @import("world");

const Atlas = @import("atlas.zig");
const MeshBuilder = @import("mesh_builder.zig");
const chunk_mesher = @import("chunk_mesher.zig");
const mob_model = @import("mob_model.zig");

const white = [4]u8{ 255, 255, 255, 255 };

pub fn appendItem(mesh: *MeshBuilder, gpa: std.mem.Allocator, item: game.ItemEntity, partial_ticks: f32) !void {
    if (item.stack.id > 255) return;

    const pos = item.base.renderPosition(partial_ticks);
    const tile = world.block.faceTextures(@intCast(item.stack.id))[world.block.up];
    const uv = Atlas.tileUv(tile);
    const uvs = [4][2]f32{
        .{ uv.u0, uv.v1 }, .{ uv.u1, uv.v1 }, .{ uv.u1, uv.v0 }, .{ uv.u0, uv.v0 },
    };

    const half: f32 = @floatCast(game.ItemEntity.width / 2.0);
    const cx: f32 = @floatCast(pos.x);
    const cz: f32 = @floatCast(pos.z);
    const y0: f32 = @floatCast(pos.y);
    const y1: f32 = @floatCast(pos.y + game.ItemEntity.height);
    const minx = cx - half;
    const maxx = cx + half;
    const minz = cz - half;
    const maxz = cz + half;

    try mesh.quad(gpa, .{
        .{ minx, y0, minz }, .{ maxx, y0, maxz }, .{ maxx, y1, maxz }, .{ minx, y1, minz },
    }, uvs, white);
    try mesh.quad(gpa, .{
        .{ maxx, y0, minz }, .{ minx, y0, maxz }, .{ minx, y1, maxz }, .{ maxx, y1, minz },
    }, uvs, white);
}

pub fn appendFallingBlock(mesh: *MeshBuilder, gpa: std.mem.Allocator, block: game.FallingBlock, partial_ticks: f32) !void {
    const pos = block.base.renderPosition(partial_ticks);
    const size: f32 = @floatCast(game.FallingBlock.size);
    const half = size / 2.0;
    const cx: f32 = @floatCast(pos.x);
    const cy: f32 = @floatCast(pos.y);
    const cz: f32 = @floatCast(pos.z);
    try chunk_mesher.buildCube(
        mesh,
        gpa,
        .{ cx - half, cy, cz - half },
        .{ cx + half, cy + size, cz + half },
        world.block.faceTextures(block.block_id),
    );
}

pub fn appendPig(mesh: *MeshBuilder, gpa: std.mem.Allocator, pig: game.Pig, partial_ticks: f32) !void {
    const pos = pig.base.renderPosition(partial_ticks);
    const entity_pos = [3]f32{ @floatCast(pos.x), @floatCast(pos.y), @floatCast(pos.z) };
    const yaw_rad = pig.yaw * std.math.pi / 180.0;
    const swing = @cos(pig.walk_distance * 0.6662) * 1.4;

    for (mob_model.pig.parts, 0..) |part, i| {
        var p = part;
        if (i >= 2) p.rotate_x = if (i == 2 or i == 5) swing else -swing;
        try mob_model.appendPart(mesh, gpa, p, mob_model.pig.texture_width, mob_model.pig.texture_height, entity_pos, yaw_rad);
    }
}

test "a block item renders as two crossing quads" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);

    var rand = world.JavaRandom.init(0);
    const item = game.ItemEntity.spawn(.{ .x = 0, .y = 0, .z = 0 }, .{ .id = world.block.stone, .count = 1 }, &rand);
    try appendItem(&mesh, gpa, item, 0);

    try std.testing.expectEqual(@as(usize, 2 * 4), mesh.vertices.items.len);
}

test "a true item stack has no world geometry yet" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);

    var rand = world.JavaRandom.init(0);
    const item = game.ItemEntity.spawn(.{ .x = 0, .y = 0, .z = 0 }, .{ .id = world.item.coal, .count = 1 }, &rand);
    try appendItem(&mesh, gpa, item, 0);

    try std.testing.expectEqual(@as(usize, 0), mesh.vertices.items.len);
}

test "a falling block renders as a full cube" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);

    const block = game.FallingBlock.spawn(.{ .x = 0, .y = 0, .z = 0 }, world.block.sand);
    try appendFallingBlock(&mesh, gpa, block, 0);

    try std.testing.expectEqual(@as(usize, 6 * 4), mesh.vertices.items.len);
}

test "a pig renders all six body parts" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);

    const pig = game.Pig.spawn(.{ .x = 0, .y = 0, .z = 0 });
    try appendPig(&mesh, gpa, pig, 0);

    try std.testing.expectEqual(@as(usize, 6 * 6 * 4), mesh.vertices.items.len);
}
