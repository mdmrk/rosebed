const std = @import("std");
const JavaRandom = @import("java_random.zig");
const Chunk = @import("chunk.zig");
const block = @import("block.zig");

const grid_x = 16;
const grid_z = 16;
const grid_y = 8;
const flag_count = grid_x * grid_z * grid_y;

fn flagIndex(x: usize, z: usize, y: usize) usize {
    return (x * grid_z + z) * grid_y + y;
}

fn localOf(chunk_x: i32, chunk_z: i32, wx: i32, wz: i32) ?struct { x: u32, z: u32 } {
    const lx = wx - chunk_x * 16;
    const lz = wz - chunk_z * 16;
    if (lx < 0 or lx >= 16 or lz < 0 or lz >= 16) return null;
    return .{ .x = @intCast(lx), .z = @intCast(lz) };
}

fn blockAt(chunk: *const Chunk, chunk_x: i32, chunk_z: i32, wx: i32, wy: i32, wz: i32) u8 {
    if (wy < 0 or wy >= 128) return block.air;
    const local = localOf(chunk_x, chunk_z, wx, wz) orelse return block.air;
    return chunk.getBlockId(local.x, @intCast(wy), local.z);
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

pub fn generate(chunk: *Chunk, chunk_x: i32, chunk_z: i32, rand: *JavaRandom, x_in: i32, y_in: i32, z_in: i32, liquid_id: u8) bool {
    const ox = x_in - 8;
    const oz = z_in - 8;
    var oy = y_in;
    if (localOf(chunk_x, chunk_z, ox, oz)) |local| {
        while (oy > 0 and chunk.getBlockId(local.x, @intCast(oy), local.z) == block.air) : (oy -= 1) {}
    }
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
                const existing = blockAt(chunk, chunk_x, chunk_z, wx, wy, wz);
                if (y >= 4) {
                    if (block.isLiquid(existing)) return false;
                } else {
                    if (!block.isOpaque(existing) and existing != liquid_id) return false;
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
                const local = localOf(chunk_x, chunk_z, wx, wz) orelse continue;
                if (wy < 0 or wy >= 128) continue;
                const id: u8 = if (y >= 4) block.air else liquid_id;
                chunk.setBlockId(local.x, @intCast(wy), local.z, id);
            }
        }
    }

    if (liquid_id == block.flowing_lava) {
        for (0..grid_x) |x| {
            for (0..grid_z) |z| {
                for (0..grid_y) |y| {
                    if (!isShellCell(&flags, x, z, y)) continue;
                    if (y >= 4 and rand.nextIntBound(2) == 0) continue;
                    const wx = ox + @as(i32, @intCast(x));
                    const wy = oy + @as(i32, @intCast(y));
                    const wz = oz + @as(i32, @intCast(z));
                    const local = localOf(chunk_x, chunk_z, wx, wz) orelse continue;
                    if (wy < 0 or wy >= 128) continue;
                    if (block.isOpaque(chunk.getBlockId(local.x, @intCast(wy), local.z))) {
                        chunk.setBlockId(local.x, @intCast(wy), local.z, block.stone);
                    }
                }
            }
        }
    }

    return true;
}

test "a water lake carves an air basin over a liquid floor" {
    var chunk = Chunk.init(0, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            for (0..80) |y| {
                chunk.setBlockId(@intCast(x), @intCast(y), @intCast(z), block.stone);
            }
        }
    }

    var rand = JavaRandom.init(1);
    const made = generate(&chunk, 0, 0, &rand, 8, 64, 8, block.stationary_water);
    try std.testing.expect(made);

    var found_air = false;
    var found_water = false;
    for (0..16) |x| {
        for (0..16) |z| {
            for (0..80) |y| {
                const id = chunk.getBlockId(@intCast(x), @intCast(y), @intCast(z));
                if (id == block.air) found_air = true;
                if (id == block.stationary_water) found_water = true;
            }
        }
    }
    try std.testing.expect(found_air);
    try std.testing.expect(found_water);
}

test "a lava lake seals its shell with stone" {
    var chunk = Chunk.init(0, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            for (0..80) |y| {
                chunk.setBlockId(@intCast(x), @intCast(y), @intCast(z), block.stone);
            }
        }
    }

    var rand = JavaRandom.init(2);
    const made = generate(&chunk, 0, 0, &rand, 8, 40, 8, block.flowing_lava);
    try std.testing.expect(made);

    var found_lava = false;
    for (0..16) |x| {
        for (0..16) |z| {
            for (0..80) |y| {
                if (chunk.getBlockId(@intCast(x), @intCast(y), @intCast(z)) == block.flowing_lava) found_lava = true;
            }
        }
    }
    try std.testing.expect(found_lava);
}

test "refuses to carve when surrounded by open air instead of solid ground" {
    var chunk = Chunk.init(0, 0);

    var rand = JavaRandom.init(1);
    const made = generate(&chunk, 0, 0, &rand, 8, 64, 8, block.stationary_water);
    try std.testing.expect(!made);
}
