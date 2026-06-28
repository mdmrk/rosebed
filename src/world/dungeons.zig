const std = @import("std");
const JavaRandom = @import("java_random.zig");
const World = @import("world_map.zig");
const Chunk = @import("chunk.zig");
const block = @import("block.zig");

const room_height: i32 = 3;

pub fn generate(world_map: *World, rand: *JavaRandom, x: i32, y: i32, z: i32) bool {
    const radius_x = rand.nextIntBound(2) + 2;
    const radius_z = rand.nextIntBound(2) + 2;

    var openings: i32 = 0;
    var dx = -radius_x - 1;
    while (dx <= radius_x + 1) : (dx += 1) {
        var dz = -radius_z - 1;
        while (dz <= radius_z + 1) : (dz += 1) {
            const bottom = world_map.getBlockId(x + dx, y - 1, z + dz);
            if (!block.isOpaque(bottom)) return false;
            const top = world_map.getBlockId(x + dx, y + room_height + 1, z + dz);
            if (!block.isOpaque(top)) return false;

            const on_perimeter = dx == -radius_x - 1 or dx == radius_x + 1 or dz == -radius_z - 1 or dz == radius_z + 1;
            if (on_perimeter) {
                const floor_level = world_map.getBlockId(x + dx, y, z + dz);
                const above_floor = world_map.getBlockId(x + dx, y + 1, z + dz);
                if (floor_level == block.air and above_floor == block.air) openings += 1;
            }
        }
    }
    if (openings < 1 or openings > 5) return false;

    var dy = room_height + 1;
    while (dy >= -1) : (dy -= 1) {
        var dx2 = -radius_x - 1;
        while (dx2 <= radius_x + 1) : (dx2 += 1) {
            var dz2 = -radius_z - 1;
            while (dz2 <= radius_z + 1) : (dz2 += 1) {
                const on_perimeter = dx2 == -radius_x - 1 or dx2 == radius_x + 1 or dz2 == -radius_z - 1 or dz2 == radius_z + 1;
                const is_boundary = on_perimeter or dy == -1 or dy == room_height + 1;
                if (!is_boundary) {
                    world_map.setBlockId(x + dx2, y + dy, z + dz2, block.air);
                    continue;
                }

                const below = world_map.getBlockId(x + dx2, y + dy - 1, z + dz2);
                if (!block.isOpaque(below)) {
                    world_map.setBlockId(x + dx2, y + dy, z + dz2, block.air);
                } else {
                    const wall_id: u8 = if (dy == -1 and rand.nextIntBound(4) != 0) block.cobblestone_mossy else block.cobblestone;
                    world_map.setBlockId(x + dx2, y + dy, z + dz2, wall_id);
                }
            }
        }
    }

    world_map.setBlockId(x, y, z, block.mob_spawner);
    return true;
}

fn testWorldWithChunk() !World {
    var w = World.init(std.testing.allocator);
    var chunk = Chunk.init(0, 0);
    for (0..16) |x| {
        for (0..128) |y| {
            for (0..16) |z| {
                chunk.setBlockId(@intCast(x), @intCast(y), @intCast(z), block.stone);
            }
        }
    }
    try w.chunks.put(std.testing.allocator, .{ .x = 0, .z = 0 }, chunk);
    return w;
}

test "a dungeon carves a room and places a spawner in solid stone" {
    var w = try testWorldWithChunk();
    defer w.deinit();

    w.setBlockId(11, 40, 8, block.air);
    w.setBlockId(11, 41, 8, block.air);
    w.setBlockId(12, 40, 8, block.air);
    w.setBlockId(12, 41, 8, block.air);

    var rand = JavaRandom.init(1);
    const made = generate(&w, &rand, 8, 40, 8);
    try std.testing.expect(made);
    try std.testing.expectEqual(@as(u8, block.mob_spawner), w.getBlockId(8, 40, 8));
    try std.testing.expectEqual(@as(u8, block.air), w.getBlockId(8, 41, 8));

    var found_wall = false;
    for (0..16) |x| {
        for (0..16) |z| {
            const id = w.getBlockId(@intCast(x), 40, @intCast(z));
            if (id == block.cobblestone or id == block.cobblestone_mossy) found_wall = true;
        }
    }
    try std.testing.expect(found_wall);
}

test "a dungeon refuses to carve into open air" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    try w.chunks.put(std.testing.allocator, .{ .x = 0, .z = 0 }, Chunk.init(0, 0));

    var rand = JavaRandom.init(1);
    const made = generate(&w, &rand, 8, 40, 8);
    try std.testing.expect(!made);
}

test "a dungeon spills across a chunk boundary into the neighbor chunk" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    var a = Chunk.init(0, 0);
    var b = Chunk.init(1, 0);
    for (0..16) |x| {
        for (0..128) |y| {
            for (0..16) |z| {
                a.setBlockId(@intCast(x), @intCast(y), @intCast(z), block.stone);
                b.setBlockId(@intCast(x), @intCast(y), @intCast(z), block.stone);
            }
        }
    }
    try w.chunks.put(std.testing.allocator, .{ .x = 0, .z = 0 }, a);
    try w.chunks.put(std.testing.allocator, .{ .x = 1, .z = 0 }, b);

    w.setBlockId(19, 40, 8, block.air);
    w.setBlockId(19, 41, 8, block.air);
    w.setBlockId(20, 40, 8, block.air);
    w.setBlockId(20, 41, 8, block.air);

    var rand = JavaRandom.init(1);
    const made = generate(&w, &rand, 15, 40, 8);
    try std.testing.expect(made);

    var found_wall_in_neighbor = false;
    for (0..16) |x| {
        for (0..16) |z| {
            const id = w.getBlockId(16 + @as(i32, @intCast(x)), 40, @as(i32, @intCast(z)));
            if (id == block.cobblestone or id == block.cobblestone_mossy or id == block.air) found_wall_in_neighbor = true;
        }
    }
    try std.testing.expect(found_wall_in_neighbor);
}
