const std = @import("std");
const JavaRandom = @import("java_random.zig");
const Chunk = @import("chunk.zig");
const block = @import("block.zig");

fn localBlockAt(chunk: *const Chunk, chunk_x: i32, chunk_z: i32, wx: i32, wy: i32, wz: i32) u8 {
    const lx = wx - chunk_x * 16;
    const lz = wz - chunk_z * 16;
    if (lx < 0 or lx >= 16 or lz < 0 or lz >= 16 or wy < 0 or wy >= 128) return block.air;
    return chunk.getBlockId(@intCast(lx), @intCast(wy), @intCast(lz));
}

fn setLocalBlock(chunk: *Chunk, chunk_x: i32, chunk_z: i32, wx: i32, wy: i32, wz: i32, id: u8) void {
    const lx = wx - chunk_x * 16;
    const lz = wz - chunk_z * 16;
    if (lx < 0 or lx >= 16 or lz < 0 or lz >= 16 or wy < 0 or wy >= 128) return;
    chunk.setBlockId(@intCast(lx), @intCast(wy), @intCast(lz), id);
}

const room_height: i32 = 3;

pub fn generate(chunk: *Chunk, chunk_x: i32, chunk_z: i32, rand: *JavaRandom, x: i32, y: i32, z: i32) bool {
    const radius_x = rand.nextIntBound(2) + 2;
    const radius_z = rand.nextIntBound(2) + 2;

    var openings: i32 = 0;
    var dx = -radius_x - 1;
    while (dx <= radius_x + 1) : (dx += 1) {
        var dz = -radius_z - 1;
        while (dz <= radius_z + 1) : (dz += 1) {
            const bottom = localBlockAt(chunk, chunk_x, chunk_z, x + dx, y - 1, z + dz);
            if (!block.isOpaque(bottom)) return false;
            const top = localBlockAt(chunk, chunk_x, chunk_z, x + dx, y + room_height + 1, z + dz);
            if (!block.isOpaque(top)) return false;

            const on_perimeter = dx == -radius_x - 1 or dx == radius_x + 1 or dz == -radius_z - 1 or dz == radius_z + 1;
            if (on_perimeter) {
                const floor_level = localBlockAt(chunk, chunk_x, chunk_z, x + dx, y, z + dz);
                const above_floor = localBlockAt(chunk, chunk_x, chunk_z, x + dx, y + 1, z + dz);
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
                    setLocalBlock(chunk, chunk_x, chunk_z, x + dx2, y + dy, z + dz2, block.air);
                    continue;
                }

                const below = localBlockAt(chunk, chunk_x, chunk_z, x + dx2, y + dy - 1, z + dz2);
                if (!block.isOpaque(below)) {
                    setLocalBlock(chunk, chunk_x, chunk_z, x + dx2, y + dy, z + dz2, block.air);
                } else {
                    const wall_id: u8 = if (dy == -1 and rand.nextIntBound(4) != 0) block.cobblestone_mossy else block.cobblestone;
                    setLocalBlock(chunk, chunk_x, chunk_z, x + dx2, y + dy, z + dz2, wall_id);
                }
            }
        }
    }

    setLocalBlock(chunk, chunk_x, chunk_z, x, y, z, block.mob_spawner);
    return true;
}

test "a dungeon carves a room and places a spawner in solid stone" {
    var chunk = Chunk.init(0, 0);
    for (0..16) |x| {
        for (0..128) |y| {
            for (0..16) |z| {
                chunk.setBlockId(@intCast(x), @intCast(y), @intCast(z), block.stone);
            }
        }
    }

    chunk.setBlockId(11, 40, 8, block.air);
    chunk.setBlockId(11, 41, 8, block.air);
    chunk.setBlockId(12, 40, 8, block.air);
    chunk.setBlockId(12, 41, 8, block.air);

    var rand = JavaRandom.init(1);
    const made = generate(&chunk, 0, 0, &rand, 8, 40, 8);
    try std.testing.expect(made);
    try std.testing.expectEqual(@as(u8, block.mob_spawner), chunk.getBlockId(8, 40, 8));
    try std.testing.expectEqual(@as(u8, block.air), chunk.getBlockId(8, 41, 8));

    var found_wall = false;
    for (0..16) |x| {
        for (0..16) |z| {
            const id = chunk.getBlockId(@intCast(x), 40, @intCast(z));
            if (id == block.cobblestone or id == block.cobblestone_mossy) found_wall = true;
        }
    }
    try std.testing.expect(found_wall);
}

test "a dungeon refuses to carve into open air" {
    var chunk = Chunk.init(0, 0);
    var rand = JavaRandom.init(1);
    const made = generate(&chunk, 0, 0, &rand, 8, 40, 8);
    try std.testing.expect(!made);
}
