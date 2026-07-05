const std = @import("std");
const JavaRandom = @import("java_random.zig");
const World = @import("world_map.zig");
const Chunk = @import("chunk.zig");
const block = @import("block.zig");
const Block = @import("block.zig").Block;

const grid_x = 16;
const grid_z = 16;
const grid_y = 8;
const flag_count = grid_x * grid_z * grid_y;

fn flagIndex(x: usize, z: usize, y: usize) usize {
    return (x * grid_z + z) * grid_y + y;
}

fn isShellCell(flags: *const [flag_count]bool, x: usize, z: usize, y: usize) bool {
    if (flags[flagIndex(x, z, y)]) return false;
    if (x > 0 and flags[flagIndex(x - 1, z, y)]) return true;
    if (x < grid_x - 1 and flags[flagIndex(x + 1, z, y)]) return true;
    if (z > 0 and flags[flagIndex(x, z - 1, y)]) return true;
    if (z < grid_z - 1 and flags[flagIndex(x, z + 1, y)]) return true;
    if (y > 0 and flags[flagIndex(x, z, y - 1)]) return true;
    if (y < grid_y - 1 and flags[flagIndex(x, z, y + 1)]) return true;
    return false;
}

pub fn generate(world_map: *World, rand: *JavaRandom, x_in: i32, y_in: i32, z_in: i32, liquid_id: Block) bool {
    const ox = x_in - 8;
    const oz = z_in - 8;
    var oy = y_in;
    while (oy > 0 and world_map.getBlock(ox, oy, oz) == Block.air) : (oy -= 1) {}
    oy -= 4;
    if (oy < 0) oy = 0;

    var flags: [flag_count]bool = [_]bool{false} ** flag_count;

    const blob_count = rand.nextIntBound(4) + 4;
    for (0..@intCast(blob_count)) |_| {
        const size_x = rand.nextDouble() * 6.0 + 3.0;
        const size_y = rand.nextDouble() * 4.0 + 2.0;
        const size_z = rand.nextDouble() * 6.0 + 3.0;
        const center_x = rand.nextDouble() * (16.0 - size_x - 2.0) + 1.0 + size_x / 2.0;
        const center_y = rand.nextDouble() * (8.0 - size_y - 4.0) + 2.0 + size_y / 2.0;
        const center_z = rand.nextDouble() * (16.0 - size_z - 2.0) + 1.0 + size_z / 2.0;

        var bx: usize = 1;
        while (bx < 15) : (bx += 1) {
            const fx = (@as(f64, @floatFromInt(bx)) - center_x) / (size_x / 2.0);
            var bz: usize = 1;
            while (bz < 15) : (bz += 1) {
                const fz = (@as(f64, @floatFromInt(bz)) - center_z) / (size_z / 2.0);
                var by: usize = 1;
                while (by < 7) : (by += 1) {
                    const fy = (@as(f64, @floatFromInt(by)) - center_y) / (size_y / 2.0);
                    if (fx * fx + fy * fy + fz * fz < 1.0) flags[flagIndex(bx, bz, by)] = true;
                }
            }
        }
    }

    for (0..grid_x) |x| {
        for (0..grid_z) |z| {
            for (0..grid_y) |y| {
                if (!isShellCell(&flags, x, z, y)) continue;
                const wx = ox + @as(i32, @intCast(x));
                const wy = oy + @as(i32, @intCast(y));
                const wz = oz + @as(i32, @intCast(z));
                const existing = world_map.getBlock(wx, wy, wz);
                if (y >= 4) {
                    if (existing.isLiquid()) return false;
                } else {
                    if (!existing.isOpaque() and existing != liquid_id) return false;
                }
            }
        }
    }

    for (0..grid_x) |x| {
        for (0..grid_z) |z| {
            for (0..grid_y) |y| {
                if (!flags[flagIndex(x, z, y)]) continue;
                const wx = ox + @as(i32, @intCast(x));
                const wy = oy + @as(i32, @intCast(y));
                const wz = oz + @as(i32, @intCast(z));
                const id: Block = if (y >= 4) Block.air else liquid_id;
                world_map.setBlock(wx, wy, wz, id);
            }
        }
    }

    if (liquid_id == Block.flowing_lava) {
        for (0..grid_x) |x| {
            for (0..grid_z) |z| {
                for (0..grid_y) |y| {
                    if (!isShellCell(&flags, x, z, y)) continue;
                    if (y >= 4 and rand.nextIntBound(2) == 0) continue;
                    const wx = ox + @as(i32, @intCast(x));
                    const wy = oy + @as(i32, @intCast(y));
                    const wz = oz + @as(i32, @intCast(z));
                    if (world_map.getBlock(wx, wy, wz).isOpaque()) {
                        world_map.setBlock(wx, wy, wz, Block.stone);
                    }
                }
            }
        }
    }

    return true;
}

fn testWorldWithChunk() !World {
    var w = World.init(std.testing.allocator);
    const chunk = try w.createChunk(0, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            for (0..80) |y| {
                chunk.setBlock(@intCast(x), @intCast(y), @intCast(z), Block.stone);
            }
        }
    }
    return w;
}

test "a water lake carves an air basin over a liquid floor" {
    var w = try testWorldWithChunk();
    defer w.deinit();

    var rand = JavaRandom.init(1);
    const made = generate(&w, &rand, 8, 64, 8, Block.stationary_water);
    try std.testing.expect(made);

    var found_air = false;
    var found_water = false;
    for (0..16) |x| {
        for (0..16) |z| {
            for (0..80) |y| {
                const id = w.getBlock(@intCast(x), @intCast(y), @intCast(z));
                if (id == Block.air) found_air = true;
                if (id == Block.stationary_water) found_water = true;
            }
        }
    }
    try std.testing.expect(found_air);
    try std.testing.expect(found_water);
}

test "a lava lake seals its shell with stone" {
    var w = try testWorldWithChunk();
    defer w.deinit();

    var rand = JavaRandom.init(2);
    const made = generate(&w, &rand, 8, 40, 8, Block.flowing_lava);
    try std.testing.expect(made);

    var found_lava = false;
    for (0..16) |x| {
        for (0..16) |z| {
            for (0..80) |y| {
                if (w.getBlock(@intCast(x), @intCast(y), @intCast(z)) == Block.flowing_lava) found_lava = true;
            }
        }
    }
    try std.testing.expect(found_lava);
}

test "refuses to carve when surrounded by open air instead of solid ground" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    _ = try w.createChunk(0, 0);

    var rand = JavaRandom.init(1);
    const made = generate(&w, &rand, 8, 64, 8, Block.stationary_water);
    try std.testing.expect(!made);
}

test "a lake spills across a chunk boundary into the neighbor chunk" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    const a = try w.createChunk(0, 0);
    const b = try w.createChunk(1, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            for (0..80) |y| {
                a.setBlock(@intCast(x), @intCast(y), @intCast(z), Block.stone);
                b.setBlock(@intCast(x), @intCast(y), @intCast(z), Block.stone);
            }
        }
    }

    var rand = JavaRandom.init(1);
    const made = generate(&w, &rand, 15, 64, 8, Block.stationary_water);
    try std.testing.expect(made);

    var found_in_neighbor = false;
    for (0..16) |x| {
        for (0..16) |z| {
            for (0..80) |y| {
                const id = w.getBlock(16 + @as(i32, @intCast(x)), @intCast(y), @as(i32, @intCast(z)));
                if (id == Block.air or id == Block.stationary_water) found_in_neighbor = true;
            }
        }
    }
    try std.testing.expect(found_in_neighbor);
}
