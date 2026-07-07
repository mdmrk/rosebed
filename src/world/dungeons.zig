const std = @import("std");
const JavaRandom = @import("java_random.zig");
const World = @import("world_map.zig");
const Chunk = @import("chunk.zig");
const block = @import("block.zig");
const Block = @import("block.zig").Block;

const room_height: i32 = 3;

pub fn generate(world_map: *World, rand: *JavaRandom, x: i32, y: i32, z: i32) bool {
    const radius_x = rand.nextIntBound(2) + 2;
    const radius_z = rand.nextIntBound(2) + 2;

    var openings: i32 = 0;
    var dx = -radius_x - 1;
    while (dx <= radius_x + 1) : (dx += 1) {
        var dz = -radius_z - 1;
        while (dz <= radius_z + 1) : (dz += 1) {
            const bottom = world_map.getBlock(x + dx, y - 1, z + dz);
            if (!bottom.isSolid()) return false;
            const top = world_map.getBlock(x + dx, y + room_height + 1, z + dz);
            if (!top.isSolid()) return false;

            const on_perimeter = dx == -radius_x - 1 or dx == radius_x + 1 or dz == -radius_z - 1 or dz == radius_z + 1;
            if (on_perimeter) {
                const floor_level = world_map.getBlock(x + dx, y, z + dz);
                const above_floor = world_map.getBlock(x + dx, y + 1, z + dz);
                if (floor_level == Block.air and above_floor == Block.air) openings += 1;
            }
        }
    }
    if (openings < 1 or openings > 5) return false;

    var dy = room_height;
    while (dy >= -1) : (dy -= 1) {
        var dx2 = -radius_x - 1;
        while (dx2 <= radius_x + 1) : (dx2 += 1) {
            var dz2 = -radius_z - 1;
            while (dz2 <= radius_z + 1) : (dz2 += 1) {
                const on_perimeter = dx2 == -radius_x - 1 or dx2 == radius_x + 1 or dz2 == -radius_z - 1 or dz2 == radius_z + 1;
                if (!on_perimeter and dy != -1) {
                    world_map.setBlock(x + dx2, y + dy, z + dz2, Block.air);
                    continue;
                }

                if (y + dy >= 0 and !world_map.getBlock(x + dx2, y + dy - 1, z + dz2).isSolid()) {
                    world_map.setBlock(x + dx2, y + dy, z + dz2, Block.air);
                } else if (world_map.getBlock(x + dx2, y + dy, z + dz2).isSolid()) {
                    const wall_id: Block = if (dy == -1 and rand.nextIntBound(4) != 0) Block.cobblestone_mossy else Block.cobblestone;
                    world_map.setBlock(x + dx2, y + dy, z + dz2, wall_id);
                }
            }
        }
    }

    world_map.setBlock(x, y, z, Block.mob_spawner);
    return true;
}

fn testWorldWithChunk() !World {
    var w = World.init(std.testing.allocator);
    const chunk = try w.createChunk(0, 0);
    for (0..16) |x| {
        for (0..128) |y| {
            for (0..16) |z| {
                chunk.setBlock(@intCast(x), @intCast(y), @intCast(z), Block.stone);
            }
        }
    }
    return w;
}

test "a dungeon carves a room and places a spawner in solid stone" {
    var w = try testWorldWithChunk();
    defer w.deinit();

    w.setBlock(11, 40, 8, Block.air);
    w.setBlock(11, 41, 8, Block.air);
    w.setBlock(12, 40, 8, Block.air);
    w.setBlock(12, 41, 8, Block.air);

    var rand = JavaRandom.init(1);
    const made = generate(&w, &rand, 8, 40, 8);
    try std.testing.expect(made);
    try std.testing.expectEqual(Block.mob_spawner, w.getBlock(8, 40, 8));
    try std.testing.expectEqual(Block.air, w.getBlock(8, 41, 8));

    var found_wall = false;
    for (0..16) |x| {
        for (0..16) |z| {
            const id = w.getBlock(@intCast(x), 40, @intCast(z));
            if (id == Block.cobblestone or id == Block.cobblestone_mossy) found_wall = true;
        }
    }
    try std.testing.expect(found_wall);
}

test "a dungeon refuses to carve into open air" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    _ = try w.createChunk(0, 0);

    var rand = JavaRandom.init(1);
    const made = generate(&w, &rand, 8, 40, 8);
    try std.testing.expect(!made);
}

test "a dungeon spills across a chunk boundary into the neighbor chunk" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    const a = try w.createChunk(0, 0);
    const b = try w.createChunk(1, 0);
    for (0..16) |x| {
        for (0..128) |y| {
            for (0..16) |z| {
                a.setBlock(@intCast(x), @intCast(y), @intCast(z), Block.stone);
                b.setBlock(@intCast(x), @intCast(y), @intCast(z), Block.stone);
            }
        }
    }

    w.setBlock(19, 40, 8, Block.air);
    w.setBlock(19, 41, 8, Block.air);
    w.setBlock(20, 40, 8, Block.air);
    w.setBlock(20, 41, 8, Block.air);

    var rand = JavaRandom.init(1);
    const made = generate(&w, &rand, 15, 40, 8);
    try std.testing.expect(made);

    var found_wall_in_neighbor = false;
    for (0..16) |x| {
        for (0..16) |z| {
            const id = w.getBlock(16 + @as(i32, @intCast(x)), 40, @as(i32, @intCast(z)));
            if (id == Block.cobblestone or id == Block.cobblestone_mossy or id == Block.air) found_wall_in_neighbor = true;
        }
    }
    try std.testing.expect(found_wall_in_neighbor);
}

test "a dungeon leaves the stone above its room untouched" {
    var w = try testWorldWithChunk();
    defer w.deinit();

    w.setBlock(11, 40, 8, Block.air);
    w.setBlock(11, 41, 8, Block.air);
    w.setBlock(12, 40, 8, Block.air);
    w.setBlock(12, 41, 8, Block.air);

    var rand = JavaRandom.init(1);
    try std.testing.expect(generate(&w, &rand, 8, 40, 8));

    try std.testing.expectEqual(Block.air, w.getBlock(8, 43, 8));
    for (0..16) |x| {
        for (0..16) |z| {
            const id = w.getBlock(@intCast(x), 44, @intCast(z));
            try std.testing.expect(id != Block.cobblestone and id != Block.cobblestone_mossy);
        }
    }
}
