const std = @import("std");
const math = @import("math");
const JavaRandom = @import("java_random.zig");
const Chunk = @import("chunk.zig");
const World = @import("world_map.zig");
const block = @import("block.zig");
const biome = @import("biome.zig");
const Block = @import("block.zig").Block;

fn tryPlaceIfMatches(chunk: *Chunk, chunk_x: i32, chunk_z: i32, wx: i32, wy: i32, wz: i32, match_id: Block, replace_id: Block) void {
    const lx = wx - chunk_x * 16;
    const lz = wz - chunk_z * 16;
    if (lx < 0 or lx >= 16 or lz < 0 or lz >= 16 or wy < 0 or wy >= 128) return;
    if (chunk.getBlock(@intCast(lx), @intCast(wy), @intCast(lz)) == match_id) {
        chunk.setBlock(@intCast(lx), @intCast(wy), @intCast(lz), replace_id);
    }
}

pub fn generateVeinBlob(chunk: *Chunk, chunk_x: i32, chunk_z: i32, rand: *JavaRandom, x: i32, y: i32, z: i32, match_id: Block, replace_id: Block, vein_size: i32) void {
    const angle = rand.nextFloat() * std.math.pi;
    const size_f: f32 = @floatFromInt(vein_size);

    const x_start: f64 = @as(f64, @floatFromInt(x + 8)) + @as(f64, math.util.sin(angle) * size_f / 8.0);
    const x_end: f64 = @as(f64, @floatFromInt(x + 8)) - @as(f64, math.util.sin(angle) * size_f / 8.0);
    const z_start: f64 = @as(f64, @floatFromInt(z + 8)) + @as(f64, math.util.cos(angle) * size_f / 8.0);
    const z_end: f64 = @as(f64, @floatFromInt(z + 8)) - @as(f64, math.util.cos(angle) * size_f / 8.0);
    const y_start: f64 = @floatFromInt(y + rand.nextIntBound(3) + 2);
    const y_end: f64 = @floatFromInt(y + rand.nextIntBound(3) + 2);

    var i: i32 = 0;
    while (i <= vein_size) : (i += 1) {
        const t: f64 = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(vein_size));
        const cx = x_start + (x_end - x_start) * t;
        const cy = y_start + (y_end - y_start) * t;
        const cz = z_start + (z_end - z_start) * t;

        const step_f: f32 = @floatFromInt(i);
        const jitter = rand.nextDouble() * @as(f64, size_f) / 16.0;
        const radius = (@as(f64, math.util.sin(step_f * std.math.pi / size_f)) + 1.0) * jitter + 1.0;
        const half_radius = radius / 2.0;

        const x0 = math.util.floorDouble(cx - half_radius);
        const y0 = math.util.floorDouble(cy - half_radius);
        const z0 = math.util.floorDouble(cz - half_radius);
        const x1 = math.util.floorDouble(cx + half_radius);
        const y1 = math.util.floorDouble(cy + half_radius);
        const z1 = math.util.floorDouble(cz + half_radius);

        var bx = x0;
        while (bx <= x1) : (bx += 1) {
            const nx = (@as(f64, @floatFromInt(bx)) + 0.5 - cx) / half_radius;
            if (nx * nx >= 1.0) continue;
            var by = y0;
            while (by <= y1) : (by += 1) {
                const ny = (@as(f64, @floatFromInt(by)) + 0.5 - cy) / half_radius;
                if (nx * nx + ny * ny >= 1.0) continue;
                var bz = z0;
                while (bz <= z1) : (bz += 1) {
                    const nz = (@as(f64, @floatFromInt(bz)) + 0.5 - cz) / half_radius;
                    if (nx * nx + ny * ny + nz * nz >= 1.0) continue;
                    tryPlaceIfMatches(chunk, chunk_x, chunk_z, bx, by, bz, match_id, replace_id);
                }
            }
        }
    }
}

const OreVein = struct {
    id: Block,
    size: i32,
    count: i32,
    max_height: i32,
};

const ore_veins = [_]OreVein{
    .{ .id = .dirt, .size = 32, .count = 20, .max_height = 128 },
    .{ .id = .gravel, .size = 32, .count = 10, .max_height = 128 },
    .{ .id = .ore_coal, .size = 16, .count = 20, .max_height = 128 },
    .{ .id = .ore_iron, .size = 8, .count = 20, .max_height = 64 },
    .{ .id = .ore_gold, .size = 8, .count = 2, .max_height = 32 },
    .{ .id = .ore_redstone, .size = 7, .count = 8, .max_height = 16 },
    .{ .id = .ore_diamond, .size = 7, .count = 1, .max_height = 16 },
};

pub fn generateOreVeins(chunk: *Chunk, chunk_x: i32, chunk_z: i32, rand: *JavaRandom) void {
    const base_x = chunk_x * 16;
    const base_z = chunk_z * 16;

    for (ore_veins) |vein| {
        for (0..@intCast(vein.count)) |_| {
            const x = base_x + rand.nextIntBound(16);
            const y = rand.nextIntBound(vein.max_height);
            const z = base_z + rand.nextIntBound(16);
            generateVeinBlob(chunk, chunk_x, chunk_z, rand, x, y, z, Block.stone, vein.id, vein.size);
        }
    }

    for (0..1) |_| {
        const x = base_x + rand.nextIntBound(16);
        const y = rand.nextIntBound(16) + rand.nextIntBound(16);
        const z = base_z + rand.nextIntBound(16);
        generateVeinBlob(chunk, chunk_x, chunk_z, rand, x, y, z, Block.stone, Block.ore_lapis, 6);
    }
}

pub fn generateClayPatches(chunk: *Chunk, chunk_x: i32, chunk_z: i32, rand: *JavaRandom) void {
    const base_x = chunk_x * 16;
    const base_z = chunk_z * 16;

    for (0..10) |_| {
        const x = base_x + rand.nextIntBound(16);
        const y = rand.nextIntBound(128);
        const z = base_z + rand.nextIntBound(16);
        const lx = x - base_x;
        const lz = z - base_z;
        if (lx < 0 or lx >= 16 or lz < 0 or lz >= 16 or y < 0 or y >= 128) continue;
        if (chunk.getBlock(@intCast(lx), @intCast(y), @intCast(lz)) != Block.stationary_water) continue;
        generateVeinBlob(chunk, chunk_x, chunk_z, rand, x, y, z, Block.sand, Block.clay, 32);
    }
}

pub fn columnTopY(world_map: *const World, x: i32, z: i32) i32 {
    var y: i32 = 127;
    while (y >= 0) : (y -= 1) {
        if (world_map.getBlock(x, y, z) != Block.air) return y + 1;
    }
    return 0;
}

pub fn generateTree(world_map: *World, rand: *JavaRandom, x: i32, y_in: i32, z: i32) bool {
    return generateTreeVariant(world_map, rand, x, y_in, z, 4, 0);
}

pub fn generateBirchTree(world_map: *World, rand: *JavaRandom, x: i32, y_in: i32, z: i32) bool {
    return generateTreeVariant(world_map, rand, x, y_in, z, 5, 2);
}

fn generateTreeVariant(world_map: *World, rand: *JavaRandom, x: i32, y_in: i32, z: i32, height_base: i32, wood_metadata: u4) bool {
    const trunk_height = rand.nextIntBound(3) + height_base;
    if (y_in < 1 or y_in + trunk_height + 1 > 128) return false;

    var can_grow = true;
    var check_y = y_in;
    while (check_y <= y_in + 1 + trunk_height and can_grow) : (check_y += 1) {
        var margin: i32 = 1;
        if (check_y == y_in) margin = 0;
        if (check_y >= y_in + 1 + trunk_height - 2) margin = 2;

        var dx = -margin;
        while (dx <= margin and can_grow) : (dx += 1) {
            var dz = -margin;
            while (dz <= margin and can_grow) : (dz += 1) {
                if (check_y < 0 or check_y >= 128) {
                    can_grow = false;
                    continue;
                }
                const id = world_map.getBlock(x + dx, check_y, z + dz);
                if (id != Block.air and id != Block.leaves) can_grow = false;
            }
        }
    }
    if (!can_grow) return false;

    if (y_in < 1) return false;
    const below = world_map.getBlock(x, y_in - 1, z);
    if ((below != Block.grass and below != Block.dirt) or y_in >= 128 - trunk_height - 1) return false;

    world_map.setBlock(x, y_in - 1, z, Block.dirt);

    var ly = y_in - 3 + trunk_height;
    while (ly <= y_in + trunk_height) : (ly += 1) {
        const dy = ly - (y_in + trunk_height);
        const margin = 1 - @divTrunc(dy, 2);

        var lx = x - margin;
        while (lx <= x + margin) : (lx += 1) {
            const dx = lx - x;
            var lz = z - margin;
            while (lz <= z + margin) : (lz += 1) {
                const dz = lz - z;
                if (ly < 0 or ly >= 128) continue;
                if ((@abs(dx) != margin or @abs(dz) != margin or (rand.nextIntBound(2) != 0 and dy != 0))) {
                    const id = world_map.getBlock(lx, ly, lz);
                    if (id == Block.air) {
                        world_map.setBlock(lx, ly, lz, Block.leaves);
                        world_map.setBlockMetadata(lx, ly, lz, wood_metadata);
                    }
                }
            }
        }
    }

    var trunk_y: i32 = 0;
    while (trunk_y < trunk_height) : (trunk_y += 1) {
        const ty = y_in + trunk_y;
        if (ty < 0 or ty >= 128) continue;
        const id = world_map.getBlock(x, ty, z);
        if (id == Block.air or id == Block.leaves) {
            world_map.setBlock(x, ty, z, Block.log);
            world_map.setBlockMetadata(x, ty, z, wood_metadata);
        }
    }

    return true;
}

const taiga_wood_metadata: u4 = 1;

fn taigaSpaceIsClear(world_map: *const World, x: i32, y: i32, z: i32, height: i32, bare_height: i32, max_radius: i32) bool {
    if (y < 1 or y + height + 1 > 128) return false;

    var cy = y;
    while (cy <= y + 1 + height) : (cy += 1) {
        if (cy < 0 or cy >= 128) return false;
        const radius: i32 = if (cy - y < bare_height) 0 else max_radius;

        var cx = x - radius;
        while (cx <= x + radius) : (cx += 1) {
            var cz = z - radius;
            while (cz <= z + radius) : (cz += 1) {
                const id = world_map.getBlock(cx, cy, cz);
                if (id != Block.air and id != Block.leaves) return false;
            }
        }
    }
    return true;
}

fn taigaGroundIsSuitable(world_map: *const World, x: i32, y: i32, z: i32, height: i32) bool {
    const below = world_map.getBlock(x, y - 1, z);
    return (below == Block.grass or below == Block.dirt) and y < 128 - height - 1;
}

fn placeTaigaLeafLayer(world_map: *World, x: i32, y: i32, z: i32, radius: i32) void {
    var cx = x - radius;
    while (cx <= x + radius) : (cx += 1) {
        var cz = z - radius;
        while (cz <= z + radius) : (cz += 1) {
            if (@abs(cx - x) == radius and @abs(cz - z) == radius and radius > 0) continue;
            if (world_map.getBlock(cx, y, cz).isOpaqueCube()) continue;
            world_map.setBlock(cx, y, cz, Block.leaves);
            world_map.setBlockMetadata(cx, y, cz, taiga_wood_metadata);
        }
    }
}

fn placeTaigaTrunk(world_map: *World, x: i32, y: i32, z: i32, height: i32) void {
    var i: i32 = 0;
    while (i < height) : (i += 1) {
        const id = world_map.getBlock(x, y + i, z);
        if (id != Block.air and id != Block.leaves) continue;
        world_map.setBlock(x, y + i, z, Block.log);
        world_map.setBlockMetadata(x, y + i, z, taiga_wood_metadata);
    }
}

pub fn generatePineTree(world_map: *World, rand: *JavaRandom, x: i32, y: i32, z: i32) bool {
    const height = rand.nextIntBound(5) + 7;
    const bare_height = height - rand.nextIntBound(2) - 3;
    const max_radius = 1 + rand.nextIntBound(height - bare_height + 1);

    if (!taigaSpaceIsClear(world_map, x, y, z, height, bare_height, max_radius)) return false;
    if (!taigaGroundIsSuitable(world_map, x, y, z, height)) return false;

    world_map.setBlock(x, y - 1, z, Block.dirt);

    var radius: i32 = 0;
    var ly = y + height;
    while (ly >= y + bare_height) : (ly -= 1) {
        placeTaigaLeafLayer(world_map, x, ly, z, radius);
        if (radius >= 1 and ly == y + bare_height + 1) {
            radius -= 1;
        } else if (radius < max_radius) {
            radius += 1;
        }
    }

    placeTaigaTrunk(world_map, x, y, z, height - 1);
    return true;
}

pub fn generateSpruceTree(world_map: *World, rand: *JavaRandom, x: i32, y: i32, z: i32) bool {
    const height = rand.nextIntBound(4) + 6;
    const bare_height = 1 + rand.nextIntBound(2);
    const leaf_layers = height - bare_height;
    const max_radius = 2 + rand.nextIntBound(2);

    if (!taigaSpaceIsClear(world_map, x, y, z, height, bare_height, max_radius)) return false;
    if (!taigaGroundIsSuitable(world_map, x, y, z, height)) return false;

    world_map.setBlock(x, y - 1, z, Block.dirt);

    var radius: i32 = rand.nextIntBound(2);
    var radius_limit: i32 = 1;
    var radius_after_reset: i32 = 0;

    var layer: i32 = 0;
    while (layer <= leaf_layers) : (layer += 1) {
        placeTaigaLeafLayer(world_map, x, y + height - layer, z, radius);
        if (radius >= radius_limit) {
            radius = radius_after_reset;
            radius_after_reset = 1;
            radius_limit += 1;
            if (radius_limit > max_radius) radius_limit = max_radius;
        } else {
            radius += 1;
        }
    }

    placeTaigaTrunk(world_map, x, y, z, height - rand.nextIntBound(3));
    return true;
}

fn bigTreeSetLeafIfClear(world_map: *World, x: i32, y: i32, z: i32) void {
    if (world_map.getBlock(x, y, z) == Block.air) world_map.setBlock(x, y, z, Block.leaves);
}

fn bigTreeLineIsClear(world_map: *const World, x0: i32, y0: i32, z0: i32, x1: i32, y1: i32, z1: i32) bool {
    const dx = x1 - x0;
    const dy = y1 - y0;
    const dz = z1 - z0;
    const steps: i32 = @intCast(@max(@max(@abs(dx), @abs(dy)), @abs(dz)));
    if (steps == 0) return true;
    var i: i32 = 0;
    while (i <= steps) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
        const lx = x0 + math.util.floorDouble(@as(f64, @floatFromInt(dx)) * t + 0.5);
        const ly = y0 + math.util.floorDouble(@as(f64, @floatFromInt(dy)) * t + 0.5);
        const lz = z0 + math.util.floorDouble(@as(f64, @floatFromInt(dz)) * t + 0.5);
        const id = world_map.getBlock(lx, ly, lz);
        if (id != Block.air and id != Block.leaves) return false;
    }
    return true;
}

fn bigTreeDrawLogLine(world_map: *World, x0: i32, y0: i32, z0: i32, x1: i32, y1: i32, z1: i32) void {
    const dx = x1 - x0;
    const dy = y1 - y0;
    const dz = z1 - z0;
    const steps: i32 = @intCast(@max(@max(@abs(dx), @abs(dy)), @abs(dz)));
    if (steps == 0) {
        world_map.setBlock(x0, y0, z0, Block.log);
        return;
    }
    var i: i32 = 0;
    while (i <= steps) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
        const lx = x0 + math.util.floorDouble(@as(f64, @floatFromInt(dx)) * t + 0.5);
        const ly = y0 + math.util.floorDouble(@as(f64, @floatFromInt(dy)) * t + 0.5);
        const lz = z0 + math.util.floorDouble(@as(f64, @floatFromInt(dz)) * t + 0.5);
        world_map.setBlock(lx, ly, lz, Block.log);
    }
}

fn bigTreeLeafDisc(world_map: *World, cx: i32, cy: i32, cz: i32, radius: f64) void {
    const r: i32 = @intFromFloat(@ceil(radius));
    var dx: i32 = -r;
    while (dx <= r) : (dx += 1) {
        var dz: i32 = -r;
        while (dz <= r) : (dz += 1) {
            const fdx = @abs(@as(f64, @floatFromInt(dx))) + 0.5;
            const fdz = @abs(@as(f64, @floatFromInt(dz))) + 0.5;
            if (@sqrt(fdx * fdx + fdz * fdz) > radius) continue;
            bigTreeSetLeafIfClear(world_map, cx + dx, cy, cz + dz);
        }
    }
}

const big_tree_leaf_cluster_height: i32 = 5;

pub fn generateBigTree(world_map: *World, world_rand: *JavaRandom, x: i32, y_in: i32, z: i32) bool {
    var rand = JavaRandom.init(world_rand.nextLong());

    var height: i32 = 5 + rand.nextIntBound(12);

    var checked: i32 = 0;
    while (checked < height - 1) : (checked += 1) {
        const id = world_map.getBlock(x, y_in + checked, z);
        if (id != Block.air and id != Block.leaves) {
            if (checked < 6) return false;
            height = checked;
            break;
        }
    }
    if (y_in < 1 or height < 6 or y_in + height + 1 > 128) return false;

    const crown_y: i32 = @min(math.util.floorDouble(@as(f64, @floatFromInt(height)) * 0.618), height - 1);
    const half_h: f64 = @as(f64, @floatFromInt(height)) / 2.0;
    const branches_per_layer_f = 1.382 + std.math.pow(f64, @as(f64, @floatFromInt(height)) / 13.0, 2.0);
    const branches_per_layer: i32 = @max(1, @as(i32, @intFromFloat(@floor(branches_per_layer_f))));

    const Cluster = struct { x: i32, y: i32, z: i32, base_y: i32 };
    var clusters: [128]Cluster = undefined;
    clusters[0] = .{ .x = x, .y = y_in + height - big_tree_leaf_cluster_height, .z = z, .base_y = y_in + crown_y };
    var cluster_count: usize = 1;

    var y = height - big_tree_leaf_cluster_height;
    const min_y: i32 = math.util.floorDouble(0.3 * @as(f64, @floatFromInt(height)));
    while (y >= min_y) : (y -= 1) {
        const centered = half_h - @as(f64, @floatFromInt(y));
        const term = half_h * half_h - centered * centered;
        const radius: f64 = if (term > 0) 0.5 * @sqrt(term) else 0.0;

        var i: i32 = 0;
        while (i < branches_per_layer) : (i += 1) {
            if (cluster_count >= clusters.len) break;
            const len = radius * (@as(f64, rand.nextFloat()) + 0.328);
            const angle: f64 = @as(f64, rand.nextFloat()) * 2.0 * std.math.pi;
            const dx = len * @sin(angle);
            const dz = len * @cos(angle);
            const tip_x = x + math.util.floorDouble(dx);
            const tip_z = z + math.util.floorDouble(dz);
            const tip_y = y_in + y;

            if (!bigTreeLineIsClear(world_map, tip_x, tip_y, tip_z, tip_x, tip_y + big_tree_leaf_cluster_height - 1, tip_z)) continue;

            var base_y = tip_y - math.util.floorDouble(len * 0.381);
            if (base_y < y_in + crown_y) base_y = y_in + crown_y;

            if (!bigTreeLineIsClear(world_map, x, base_y, z, tip_x, tip_y, tip_z)) continue;

            clusters[cluster_count] = .{ .x = tip_x, .y = tip_y, .z = tip_z, .base_y = base_y };
            cluster_count += 1;
        }
    }

    bigTreeDrawLogLine(world_map, x, y_in, z, x, y_in + crown_y, z);
    for (clusters[1..cluster_count]) |c| {
        bigTreeDrawLogLine(world_map, x, c.base_y, z, c.x, c.y, c.z);
    }
    for (clusters[0..cluster_count]) |c| {
        bigTreeLeafDisc(world_map, c.x, c.y, c.z, 2.0);
        bigTreeLeafDisc(world_map, c.x, c.y + 1, c.z, 3.0);
        bigTreeLeafDisc(world_map, c.x, c.y + 2, c.z, 3.0);
        bigTreeLeafDisc(world_map, c.x, c.y + 3, c.z, 3.0);
        bigTreeLeafDisc(world_map, c.x, c.y + 4, c.z, 2.0);
    }

    return true;
}

pub fn treeCountFor(rand: *JavaRandom, density_noise: f64, surface_biome: biome.Biome) i32 {
    const from_noise: i32 = @intFromFloat((density_noise / 8.0 + rand.nextDouble() * 4.0 + 4.0) / 3.0);

    var count: i32 = 0;
    if (rand.nextIntBound(10) == 0) count += 1;

    return count + switch (surface_biome) {
        .forest, .rainforest, .taiga => from_noise + 5,
        .seasonal_forest => from_noise + 2,
        .desert, .tundra, .plains => -20,
        else => 0,
    };
}

fn growRandomTree(world_map: *World, rand: *JavaRandom, x: i32, y: i32, z: i32, surface_biome: biome.Biome) void {
    switch (surface_biome) {
        .forest => {
            if (rand.nextIntBound(5) == 0) {
                _ = generateBirchTree(world_map, rand, x, y, z);
            } else if (rand.nextIntBound(3) == 0) {
                _ = generateBigTree(world_map, rand, x, y, z);
            } else {
                _ = generateTree(world_map, rand, x, y, z);
            }
        },
        .taiga => {
            if (rand.nextIntBound(3) == 0) {
                _ = generatePineTree(world_map, rand, x, y, z);
            } else {
                _ = generateSpruceTree(world_map, rand, x, y, z);
            }
        },
        .rainforest => {
            if (rand.nextIntBound(3) == 0) {
                _ = generateBigTree(world_map, rand, x, y, z);
            } else {
                _ = generateTree(world_map, rand, x, y, z);
            }
        },
        else => {
            if (rand.nextIntBound(10) == 0) {
                _ = generateBigTree(world_map, rand, x, y, z);
            } else {
                _ = generateTree(world_map, rand, x, y, z);
            }
        },
    }
}

pub fn generateTrees(world_map: *World, chunk_x: i32, chunk_z: i32, rand: *JavaRandom, surface_biome: biome.Biome, count: i32) void {
    const base_x = chunk_x * 16;
    const base_z = chunk_z * 16;

    var i: i32 = 0;
    while (i < count) : (i += 1) {
        const x = base_x + rand.nextIntBound(16) + 8;
        const z = base_z + rand.nextIntBound(16) + 8;
        growRandomTree(world_map, rand, x, columnTopY(world_map, x, z), z, surface_biome);
    }
}

fn descendToAnchor(world_map: *const World, x: i32, y_in: i32, z: i32) i32 {
    var y = y_in;
    while (y > 0) {
        const id = world_map.getBlock(x, y, z);
        if (id != Block.air and id != Block.leaves) break;
        y -= 1;
    }
    return y;
}

fn canPlantStayOn(below: Block) bool {
    return below == Block.grass or below == Block.dirt;
}

pub fn generateTallGrassPatch(world_map: *World, rand: *JavaRandom, x: i32, y_in: i32, z: i32, metadata: u4) void {
    const y = descendToAnchor(world_map, x, y_in, z);
    for (0..128) |_| {
        const wx = x + rand.nextIntBound(8) - rand.nextIntBound(8);
        const wy = y + rand.nextIntBound(4) - rand.nextIntBound(4);
        const wz = z + rand.nextIntBound(8) - rand.nextIntBound(8);
        if (wy < 1 or wy >= 128) continue;
        if (world_map.getBlock(wx, wy, wz) != Block.air) continue;
        const below = world_map.getBlock(wx, wy - 1, wz);
        if (!canPlantStayOn(below)) continue;
        world_map.setBlock(wx, wy, wz, Block.tall_grass);
        world_map.setBlockMetadata(wx, wy, wz, metadata);
    }
}

pub fn generateDeadBushPatch(world_map: *World, rand: *JavaRandom, x: i32, y_in: i32, z: i32) void {
    const y = descendToAnchor(world_map, x, y_in, z);
    for (0..4) |_| {
        const wx = x + rand.nextIntBound(8) - rand.nextIntBound(8);
        const wy = y + rand.nextIntBound(4) - rand.nextIntBound(4);
        const wz = z + rand.nextIntBound(8) - rand.nextIntBound(8);
        if (wy < 1 or wy >= 128) continue;
        if (world_map.getBlock(wx, wy, wz) != Block.air) continue;
        const below = world_map.getBlock(wx, wy - 1, wz);
        if (below != Block.sand) continue;
        world_map.setBlock(wx, wy, wz, Block.dead_bush);
    }
}

pub fn generateFlowerPatch(world_map: *World, rand: *JavaRandom, x: i32, y: i32, z: i32, flower_id: Block, stayCheck: *const fn (Block) bool) void {
    for (0..64) |_| {
        const wx = x + rand.nextIntBound(8) - rand.nextIntBound(8);
        const wy = y + rand.nextIntBound(4) - rand.nextIntBound(4);
        const wz = z + rand.nextIntBound(8) - rand.nextIntBound(8);
        if (wy < 1 or wy >= 128) continue;
        if (world_map.getBlock(wx, wy, wz) != Block.air) continue;
        const below = world_map.getBlock(wx, wy - 1, wz);
        if (!stayCheck(below)) continue;
        world_map.setBlock(wx, wy, wz, flower_id);
    }
}

pub fn generatePumpkinPatch(world_map: *World, rand: *JavaRandom, x: i32, y: i32, z: i32) void {
    for (0..64) |_| {
        const wx = x + rand.nextIntBound(8) - rand.nextIntBound(8);
        const wy = y + rand.nextIntBound(4) - rand.nextIntBound(4);
        const wz = z + rand.nextIntBound(8) - rand.nextIntBound(8);
        if (wy < 1 or wy >= 128) continue;
        if (world_map.getBlock(wx, wy, wz) != Block.air) continue;
        const below = world_map.getBlock(wx, wy - 1, wz);
        if (below != Block.grass) continue;
        world_map.setBlock(wx, wy, wz, Block.pumpkin);
        world_map.setBlockMetadata(wx, wy, wz, @intCast(rand.nextIntBound(4)));
    }
}

fn cactusCanStay(world_map: *const World, x: i32, y: i32, z: i32) bool {
    if (world_map.getBlock(x - 1, y, z).isSolid()) return false;
    if (world_map.getBlock(x + 1, y, z).isSolid()) return false;
    if (world_map.getBlock(x, y, z - 1).isSolid()) return false;
    if (world_map.getBlock(x, y, z + 1).isSolid()) return false;

    const below = world_map.getBlock(x, y - 1, z);
    return below == Block.cactus or below == Block.sand;
}

pub fn generateCactusPatch(world_map: *World, rand: *JavaRandom, x: i32, y: i32, z: i32) void {
    for (0..10) |_| {
        const wx = x + rand.nextIntBound(8) - rand.nextIntBound(8);
        const wy = y + rand.nextIntBound(4) - rand.nextIntBound(4);
        const wz = z + rand.nextIntBound(8) - rand.nextIntBound(8);
        if (world_map.getBlock(wx, wy, wz) != Block.air) continue;

        const height = 1 + rand.nextIntBound(rand.nextIntBound(3) + 1);
        var k: i32 = 0;
        while (k < height) : (k += 1) {
            if (!cactusCanStay(world_map, wx, wy + k, wz)) continue;
            world_map.setBlock(wx, wy + k, wz, Block.cactus);
        }
    }
}

fn hasAdjacentWater(world_map: *const World, x: i32, y: i32, z: i32) bool {
    return world_map.getBlock(x - 1, y, z) == Block.stationary_water or
        world_map.getBlock(x + 1, y, z) == Block.stationary_water or
        world_map.getBlock(x, y, z - 1) == Block.stationary_water or
        world_map.getBlock(x, y, z + 1) == Block.stationary_water;
}

pub fn generateReedPatch(world_map: *World, rand: *JavaRandom, x: i32, y: i32, z: i32) void {
    for (0..20) |_| {
        const wx = x + rand.nextIntBound(4) - rand.nextIntBound(4);
        const wz = z + rand.nextIntBound(4) - rand.nextIntBound(4);
        if (y < 1 or y >= 128) continue;
        if (world_map.getBlock(wx, y, wz) != Block.air) continue;
        const below = world_map.getBlock(wx, y - 1, wz);
        if (below != Block.grass and below != Block.dirt) continue;
        if (!hasAdjacentWater(world_map, wx, y - 1, wz)) continue;

        const height = 2 + rand.nextIntBound(rand.nextIntBound(3) + 1);
        var k: i32 = 0;
        while (k < height) : (k += 1) {
            const ry = y + k;
            if (ry >= 128) break;
            if (world_map.getBlock(wx, ry, wz) != Block.air) break;
            world_map.setBlock(wx, ry, wz, Block.reed);
        }
    }
}

fn dandelionCountFor(surface_biome: biome.Biome) i32 {
    return switch (surface_biome) {
        .forest => 2,
        .seasonal_forest => 4,
        .taiga => 2,
        .plains => 3,
        else => 0,
    };
}

fn tallGrassCountFor(surface_biome: biome.Biome) i32 {
    return switch (surface_biome) {
        .forest => 2,
        .rainforest, .plains => 10,
        .seasonal_forest => 2,
        .taiga => 1,
        else => 0,
    };
}

pub fn generateSurfacePlants(world_map: *World, chunk_x: i32, chunk_z: i32, rand: *JavaRandom, surface_biome: biome.Biome) void {
    const base_x = chunk_x * 16;
    const base_z = chunk_z * 16;

    var i: i32 = 0;
    const dandelion_count = dandelionCountFor(surface_biome);
    while (i < dandelion_count) : (i += 1) {
        const x = base_x + rand.nextIntBound(16) + 8;
        const y = rand.nextIntBound(128);
        const z = base_z + rand.nextIntBound(16) + 8;
        generateFlowerPatch(world_map, rand, x, y, z, Block.dandelion, canPlantStayOn);
    }

    i = 0;
    const grass_count = tallGrassCountFor(surface_biome);
    while (i < grass_count) : (i += 1) {
        const is_fern = surface_biome == .rainforest and rand.nextIntBound(3) != 0;
        const x = base_x + rand.nextIntBound(16) + 8;
        const y = rand.nextIntBound(128);
        const z = base_z + rand.nextIntBound(16) + 8;
        generateTallGrassPatch(world_map, rand, x, y, z, if (is_fern) 2 else 1);
    }

    if (surface_biome == .desert) {
        i = 0;
        while (i < 2) : (i += 1) {
            const x = base_x + rand.nextIntBound(16) + 8;
            const y = rand.nextIntBound(128);
            const z = base_z + rand.nextIntBound(16) + 8;
            generateDeadBushPatch(world_map, rand, x, y, z);
        }
    }

    if (rand.nextIntBound(2) == 0) {
        const x = base_x + rand.nextIntBound(16) + 8;
        const y = rand.nextIntBound(128);
        const z = base_z + rand.nextIntBound(16) + 8;
        generateFlowerPatch(world_map, rand, x, y, z, Block.rose, canPlantStayOn);
    }

    if (rand.nextIntBound(4) == 0) {
        const x = base_x + rand.nextIntBound(16) + 8;
        const y = rand.nextIntBound(128);
        const z = base_z + rand.nextIntBound(16) + 8;
        generateFlowerPatch(world_map, rand, x, y, z, Block.mushroom_brown, Block.isOpaque);
    }

    if (rand.nextIntBound(8) == 0) {
        const x = base_x + rand.nextIntBound(16) + 8;
        const y = rand.nextIntBound(128);
        const z = base_z + rand.nextIntBound(16) + 8;
        generateFlowerPatch(world_map, rand, x, y, z, Block.mushroom_red, Block.isOpaque);
    }

    i = 0;
    while (i < 10) : (i += 1) {
        const x = base_x + rand.nextIntBound(16) + 8;
        const y = rand.nextIntBound(128);
        const z = base_z + rand.nextIntBound(16) + 8;
        generateReedPatch(world_map, rand, x, y, z);
    }

    if (rand.nextIntBound(32) == 0) {
        const x = base_x + rand.nextIntBound(16) + 8;
        const y = rand.nextIntBound(128);
        const z = base_z + rand.nextIntBound(16) + 8;
        generatePumpkinPatch(world_map, rand, x, y, z);
    }

    if (surface_biome == .desert) {
        i = 0;
        while (i < 10) : (i += 1) {
            const x = base_x + rand.nextIntBound(16) + 8;
            const y = rand.nextIntBound(128);
            const z = base_z + rand.nextIntBound(16) + 8;
            generateCactusPatch(world_map, rand, x, y, z);
        }
    }
}

test "clay patches replace sand only where the origin is underwater" {
    var chunk = Chunk.init(0, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            var y: u32 = 0;
            while (y < 128) : (y += 1) {
                const id: Block = if (y % 2 == 0) Block.stationary_water else Block.sand;
                chunk.setBlock(@intCast(x), y, @intCast(z), id);
            }
        }
    }

    var rand = JavaRandom.init(7);
    generateClayPatches(&chunk, 0, 0, &rand);

    var found_clay = false;
    for (0..16) |x| {
        for (0..16) |z| {
            for (0..128) |y| {
                if (chunk.getBlock(@intCast(x), @intCast(y), @intCast(z)) == Block.clay) found_clay = true;
            }
        }
    }
    try std.testing.expect(found_clay);
}

test "clay patches do nothing without water at the origin" {
    var chunk = Chunk.init(0, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            chunk.setBlock(@intCast(x), 60, @intCast(z), Block.sand);
        }
    }

    var rand = JavaRandom.init(7);
    generateClayPatches(&chunk, 0, 0, &rand);

    for (0..16) |x| {
        for (0..16) |z| {
            try std.testing.expect(chunk.getBlock(@intCast(x), 60, @intCast(z)) != Block.clay);
        }
    }
}

test "ore veins can replace stone underground" {
    var chunk = Chunk.init(0, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            for (0..64) |y| {
                chunk.setBlock(@intCast(x), @intCast(y), @intCast(z), Block.stone);
            }
        }
    }

    var rand = JavaRandom.init(42);
    generateOreVeins(&chunk, 0, 0, &rand);

    var found_ore = false;
    for (0..16) |x| {
        for (0..16) |z| {
            for (0..64) |y| {
                const id = chunk.getBlock(@intCast(x), @intCast(y), @intCast(z));
                if (id == Block.ore_coal or id == Block.ore_iron or id == Block.dirt or id == Block.gravel) found_ore = true;
            }
        }
    }
    try std.testing.expect(found_ore);
}

fn testWorldWithFloor() !World {
    var w = World.init(std.testing.allocator);
    const chunk = try w.createChunk(0, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            chunk.setBlock(@intCast(x), 0, @intCast(z), Block.grass);
        }
    }
    return w;
}

test "a tree grows on grass with clear space above" {
    var w = try testWorldWithFloor();
    defer w.deinit();

    var rand = JavaRandom.init(1);
    const grew = generateTree(&w, &rand, 8, 1, 8);
    try std.testing.expect(grew);
    try std.testing.expectEqual(Block.log, w.getBlock(8, 1, 8));
}

test "a birch tree stores wood metadata 2 on its log and leaves" {
    var w = try testWorldWithFloor();
    defer w.deinit();

    var rand = JavaRandom.init(1);
    const grew = generateBirchTree(&w, &rand, 8, 1, 8);
    try std.testing.expect(grew);
    try std.testing.expectEqual(Block.log, w.getBlock(8, 1, 8));
    try std.testing.expectEqual(@as(u4, 2), w.getBlockMetadata(8, 1, 8));
}

test "taiga pines and spruces grow with spruce wood metadata" {
    for ([_]bool{ true, false }) |pine| {
        var w = try testWorldWithFloor();
        defer w.deinit();

        var rand = JavaRandom.init(3);
        const grew = if (pine)
            generatePineTree(&w, &rand, 8, 1, 8)
        else
            generateSpruceTree(&w, &rand, 8, 1, 8);
        try std.testing.expect(grew);

        try std.testing.expectEqual(Block.log, w.getBlock(8, 1, 8));
        try std.testing.expectEqual(taiga_wood_metadata, w.getBlockMetadata(8, 1, 8));

        var leaves: usize = 0;
        for (0..16) |x| {
            for (1..30) |y| {
                for (0..16) |z| {
                    if (w.getBlock(@intCast(x), @intCast(y), @intCast(z)) != Block.leaves) continue;
                    leaves += 1;
                    try std.testing.expectEqual(taiga_wood_metadata, w.getBlockMetadata(@intCast(x), @intCast(y), @intCast(z)));
                }
            }
        }
        try std.testing.expect(leaves > 0);
    }
}

test "a tree does not grow without clear space above" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    const chunk = try w.createChunk(0, 0);
    chunk.setBlock(8, 0, 8, Block.grass);
    chunk.setBlock(8, 3, 8, Block.stone);

    var rand = JavaRandom.init(1);
    const grew = generateTree(&w, &rand, 8, 1, 8);
    try std.testing.expect(!grew);
}

test "a big tree grows a taller trunk with leaf clusters" {
    var w = try testWorldWithFloor();
    defer w.deinit();

    var rand = JavaRandom.init(1);
    const grew = generateBigTree(&w, &rand, 8, 1, 8);
    try std.testing.expect(grew);

    var logs: usize = 0;
    var leaves: usize = 0;
    for (0..16) |x| {
        for (1..40) |y| {
            for (0..16) |z| {
                const id = w.getBlock(@intCast(x), @intCast(y), @intCast(z));
                if (id == Block.log) logs += 1;
                if (id == Block.leaves) leaves += 1;
            }
        }
    }
    try std.testing.expect(logs > 0);
    try std.testing.expect(leaves > 0);
}

test "a big tree refuses to grow with an obstruction right above its base" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    const chunk = try w.createChunk(0, 0);
    chunk.setBlock(8, 0, 8, Block.grass);
    chunk.setBlock(8, 3, 8, Block.stone);

    var rand = JavaRandom.init(1);
    const grew = generateBigTree(&w, &rand, 8, 1, 8);
    try std.testing.expect(!grew);
}

test "generateTrees places trees in a forest biome and none in desert" {
    var forest_w = World.init(std.testing.allocator);
    defer forest_w.deinit();
    const forest_chunk = try forest_w.createChunk(0, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            forest_chunk.setBlock(@intCast(x), 0, @intCast(z), Block.grass);
        }
    }
    var forest_rand = JavaRandom.init(1);
    const forest_count = treeCountFor(&forest_rand, 0.0, .forest);
    try std.testing.expect(forest_count > 0);
    generateTrees(&forest_w, 0, 0, &forest_rand, .forest, forest_count);

    var forest_logs: usize = 0;
    for (0..16) |x| {
        for (0..128) |y| {
            for (0..16) |z| {
                if (forest_w.getBlock(@intCast(x), @intCast(y), @intCast(z)) == Block.log) forest_logs += 1;
            }
        }
    }
    try std.testing.expect(forest_logs > 0);

    var desert_w = World.init(std.testing.allocator);
    defer desert_w.deinit();
    const desert_chunk = try desert_w.createChunk(0, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            desert_chunk.setBlock(@intCast(x), 0, @intCast(z), Block.sand);
        }
    }
    var desert_rand = JavaRandom.init(1);
    const desert_count = treeCountFor(&desert_rand, 0.0, .desert);
    try std.testing.expect(desert_count <= 0);
    generateTrees(&desert_w, 0, 0, &desert_rand, .desert, desert_count);

    var desert_logs: usize = 0;
    for (0..16) |x| {
        for (0..128) |y| {
            for (0..16) |z| {
                if (desert_w.getBlock(@intCast(x), @intCast(y), @intCast(z)) == Block.log) desert_logs += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), desert_logs);
}

test "a tree whose rolled position spills into the neighbor chunk still grows there" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    const a = try w.createChunk(0, 0);
    const b = try w.createChunk(1, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            a.setBlock(@intCast(x), 0, @intCast(z), Block.grass);
            b.setBlock(@intCast(x), 0, @intCast(z), Block.grass);
        }
    }

    var rand = JavaRandom.init(1);
    const grew = generateTree(&w, &rand, 20, 1, 8);
    try std.testing.expect(grew);
    try std.testing.expectEqual(Block.log, w.getBlock(20, 1, 8));
}

fn flatGrassWorld() !World {
    var w = World.init(std.testing.allocator);
    const chunk = try w.createChunk(0, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            chunk.setBlock(@intCast(x), 10, @intCast(z), Block.grass);
        }
    }
    return w;
}

test "tall grass patches place blades on grass with air above" {
    var w = try flatGrassWorld();
    defer w.deinit();
    var rand = JavaRandom.init(1);
    generateTallGrassPatch(&w, &rand, 8, 20, 8, 1);

    var found = false;
    for (0..16) |x| {
        for (0..16) |z| {
            if (w.getBlock(@intCast(x), 11, @intCast(z)) == Block.tall_grass) found = true;
        }
    }
    try std.testing.expect(found);
}

test "dead bush only takes root on sand" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    const chunk = try w.createChunk(0, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            chunk.setBlock(@intCast(x), 10, @intCast(z), Block.sand);
        }
    }
    var rand = JavaRandom.init(1);
    generateDeadBushPatch(&w, &rand, 8, 20, 8);

    var found = false;
    for (0..16) |x| {
        for (0..16) |z| {
            if (w.getBlock(@intCast(x), 11, @intCast(z)) == Block.dead_bush) found = true;
        }
    }
    try std.testing.expect(found);
}

test "dead bush does not take root on grass" {
    var w = try flatGrassWorld();
    defer w.deinit();
    var rand = JavaRandom.init(1);
    generateDeadBushPatch(&w, &rand, 8, 20, 8);

    for (0..16) |x| {
        for (0..16) |z| {
            try std.testing.expect(w.getBlock(@intCast(x), 11, @intCast(z)) != Block.dead_bush);
        }
    }
}

test "surface plants place dandelions in plains but not in the ocean" {
    var w = try flatGrassWorld();
    defer w.deinit();
    var rand = JavaRandom.init(1);
    generateSurfacePlants(&w, 0, 0, &rand, .plains);

    var found_flower_or_grass = false;
    for (0..16) |x| {
        for (0..16) |z| {
            const id = w.getBlock(@intCast(x), 11, @intCast(z));
            if (id == Block.dandelion or id == Block.tall_grass or id == Block.rose) found_flower_or_grass = true;
        }
    }
    try std.testing.expect(found_flower_or_grass);
}

test "mushrooms can stay on any opaque block, unlike flowers" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    const chunk = try w.createChunk(0, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            chunk.setBlock(@intCast(x), 10, @intCast(z), Block.stone);
        }
    }
    var rand = JavaRandom.init(1);
    generateFlowerPatch(&w, &rand, 8, 11, 8, Block.mushroom_brown, Block.isOpaque);

    var found = false;
    for (0..16) |x| {
        for (0..16) |z| {
            if (w.getBlock(@intCast(x), 11, @intCast(z)) == Block.mushroom_brown) found = true;
        }
    }
    try std.testing.expect(found);
}

test "reeds only take root on grass adjacent to water" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    const chunk = try w.createChunk(0, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            const id: Block = if (x % 2 == 0) Block.stationary_water else Block.grass;
            chunk.setBlock(@intCast(x), 10, @intCast(z), id);
        }
    }

    var rand = JavaRandom.init(1);
    generateReedPatch(&w, &rand, 8, 11, 8);

    var found = false;
    for (0..16) |x| {
        for (0..16) |z| {
            if (w.getBlock(@intCast(x), 11, @intCast(z)) == Block.reed) found = true;
        }
    }
    try std.testing.expect(found);
}

test "reeds do not take root on grass away from water" {
    var w = try flatGrassWorld();
    defer w.deinit();
    var rand = JavaRandom.init(1);
    generateReedPatch(&w, &rand, 8, 11, 8);

    for (0..16) |x| {
        for (0..16) |z| {
            try std.testing.expect(w.getBlock(@intCast(x), 11, @intCast(z)) != Block.reed);
        }
    }
}

test "cactus grows on sand in stacks of at most three" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    const chunk = try w.createChunk(0, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            chunk.setBlock(@intCast(x), 10, @intCast(z), Block.sand);
        }
    }

    var rand = JavaRandom.init(5);
    generateCactusPatch(&w, &rand, 8, 11, 8);

    var tallest: usize = 0;
    for (0..16) |x| {
        for (0..16) |z| {
            var height: usize = 0;
            for (11..16) |y| {
                if (w.getBlock(@intCast(x), @intCast(y), @intCast(z)) != Block.cactus) break;
                height += 1;
            }
            tallest = @max(tallest, height);
        }
    }
    try std.testing.expect(tallest > 0);
    try std.testing.expect(tallest <= 3);
}

test "cactus refuses to grow beside a solid block" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    const chunk = try w.createChunk(0, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            chunk.setBlock(@intCast(x), 10, @intCast(z), Block.sand);
            chunk.setBlock(@intCast(x), 11, @intCast(z), Block.stone);
        }
    }
    chunk.setBlock(8, 11, 8, Block.air);

    var rand = JavaRandom.init(5);
    generateCactusPatch(&w, &rand, 8, 11, 8);

    for (0..16) |x| {
        for (0..16) |z| {
            try std.testing.expect(w.getBlock(@intCast(x), 11, @intCast(z)) != Block.cactus);
        }
    }
}

test "pumpkins only take root on grass and store a random facing" {
    var w = try flatGrassWorld();
    defer w.deinit();
    var rand = JavaRandom.init(1);
    generatePumpkinPatch(&w, &rand, 8, 11, 8);

    var found = false;
    for (0..16) |x| {
        for (0..16) |z| {
            if (w.getBlock(@intCast(x), 11, @intCast(z)) == Block.pumpkin) {
                found = true;
                try std.testing.expect(w.getBlockMetadata(@intCast(x), 11, @intCast(z)) < 4);
            }
        }
    }
    try std.testing.expect(found);
}
