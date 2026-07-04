const std = @import("std");
const game = @import("game");
const world = @import("world");

const Atlas = @import("atlas.zig");
const MeshBuilder = @import("mesh_builder.zig");
const chunk_mesher = @import("chunk_mesher.zig");
const mob_model = @import("mob_model.zig");

const white = [4]u8{ 255, 255, 255, 255 };

fn brightnessOf(world_map: *const world.World, base: game.Entity) f32 {
    const sample = base.lightSamplePosition();
    return world.light.brightnessAt(world_map, sample[0], sample[1], sample[2], 0);
}


pub fn appendItem(mesh: *MeshBuilder, gpa: std.mem.Allocator, world_map: *const world.World, item: game.ItemEntity, partial_ticks: f32) !void {
    if (item.stack.id > 255) return;

    const first_vertex = mesh.vertices.items.len;

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

    mesh.scaleColors(first_vertex, brightnessOf(world_map, item.base));
}

pub fn appendFallingBlock(mesh: *MeshBuilder, gpa: std.mem.Allocator, world_map: *const world.World, block: game.FallingBlock, partial_ticks: f32) !void {
    const first_vertex = mesh.vertices.items.len;
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

    mesh.scaleColors(first_vertex, brightnessOf(world_map, block.base));
}

pub fn appendPig(mesh: *MeshBuilder, gpa: std.mem.Allocator, world_map: *const world.World, pig: game.Pig, partial_ticks: f32) !void {
    const first_vertex = mesh.vertices.items.len;
    const pos = pig.base.renderPosition(partial_ticks);
    const entity_pos = [3]f32{ @floatCast(pos.x), @floatCast(pos.y), @floatCast(pos.z) };
    const yaw_rad = pig.yaw * std.math.pi / 180.0;
    const swing = @cos(pig.walk_distance * 0.6662) * 1.4;

    for (mob_model.pig.parts, 0..) |part, i| {
        var p = part;
        if (i >= 2) p.rotate_x = if (i == 2 or i == 5) swing else -swing;
        try mob_model.appendPart(mesh, gpa, p, mob_model.pig.texture_width, mob_model.pig.texture_height, entity_pos, yaw_rad);
    }

    mesh.scaleColors(first_vertex, brightnessOf(world_map, pig.base));
}

test "a block item renders as two crossing quads" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    var rand = world.JavaRandom.init(0);
    const item = game.ItemEntity.spawn(.{ .x = 0, .y = 0, .z = 0 }, .{ .id = world.block.stone, .count = 1 }, &rand);
    try appendItem(&mesh, gpa, &world_map, item, 0);

    try std.testing.expectEqual(@as(usize, 2 * 4), mesh.vertices.items.len);
}

test "a true item stack has no world geometry yet" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    var rand = world.JavaRandom.init(0);
    const item = game.ItemEntity.spawn(.{ .x = 0, .y = 0, .z = 0 }, .{ .id = world.item.coal, .count = 1 }, &rand);
    try appendItem(&mesh, gpa, &world_map, item, 0);

    try std.testing.expectEqual(@as(usize, 0), mesh.vertices.items.len);
}

test "a falling block renders as a full cube" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    const block = game.FallingBlock.spawn(.{ .x = 0, .y = 0, .z = 0 }, world.block.sand);
    try appendFallingBlock(&mesh, gpa, &world_map, block, 0);

    try std.testing.expectEqual(@as(usize, 6 * 4), mesh.vertices.items.len);
}

test "a pig renders all six body parts" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    const pig = game.Pig.spawn(.{ .x = 0, .y = 0, .z = 0 });
    try appendPig(&mesh, gpa, &world_map, pig, 0);

    try std.testing.expectEqual(@as(usize, 6 * 6 * 4), mesh.vertices.items.len);
}

test "an entity in the open is lit brighter than one sealed in the dark" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    const chunk = try world_map.createChunk(0, 0);
    for (0..world.Chunk.width) |x| {
        for (0..world.Chunk.width) |z| {
            chunk.setBlockId(@intCast(x), 0, @intCast(z), world.block.stone);
            if (x >= 8) chunk.setBlockId(@intCast(x), 4, @intCast(z), world.block.stone);
        }
    }
    try world.light.relightChunk(gpa, &world_map, 0, 0);

    var lit: MeshBuilder = .{};
    defer lit.deinit(gpa);
    var dark: MeshBuilder = .{};
    defer dark.deinit(gpa);

    try appendPig(&lit, gpa, &world_map, game.Pig.spawn(.{ .x = 2, .y = 1, .z = 8 }), 0);
    try appendPig(&dark, gpa, &world_map, game.Pig.spawn(.{ .x = 14, .y = 1, .z = 8 }), 0);

    try std.testing.expectEqual(@as(u8, 255), lit.vertices.items[0].color[0]);
    try std.testing.expect(dark.vertices.items[0].color[0] < 255);
}

test "an entity samples light two thirds of the way up its own box" {
    const pig = game.Pig.spawn(.{ .x = 3.7, .y = 64.0, .z = -2.2 });
    const sample = pig.base.lightSamplePosition();
    try std.testing.expectEqual(@as(i32, 3), sample[0]);
    try std.testing.expectEqual(@as(i32, -3), sample[2]);
    try std.testing.expectEqual(@as(i32, 64), sample[1]);
    try std.testing.expect(pig.base.height * 0.66 < 1.0);
}
