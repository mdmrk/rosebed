const std = @import("std");
const math = @import("math");
const JavaRandom = @import("java_random.zig");
const Chunk = @import("chunk.zig");
const World = @import("world_map.zig");
const block = @import("block.zig");
const biome = @import("biome.zig");

fn tryPlaceIfMatches(chunk: *Chunk, chunk_x: i32, chunk_z: i32, wx: i32, wy: i32, wz: i32, match_id: u8, replace_id: u8) void {
    const lx = wx - chunk_x * 16;
    const lz = wz - chunk_z * 16;
    if (lx < 0 or lx >= 16 or lz < 0 or lz >= 16 or wy < 0 or wy >= 128) return;
    if (chunk.getBlockId(@intCast(lx), @intCast(wy), @intCast(lz)) == match_id) {
        chunk.setBlockId(@intCast(lx), @intCast(wy), @intCast(lz), replace_id);
    }
}

pub fn generateVeinBlob(chunk: *Chunk, chunk_x: i32, chunk_z: i32, rand: *JavaRandom, x: i32, y: i32, z: i32, match_id: u8, replace_id: u8, vein_size: i32) void {
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
    id: u8,
    size: i32,
    count: i32,
    max_height: i32,
};

const ore_veins = [_]OreVein{
    .{ .id = block.dirt, .size = 32, .count = 20, .max_height = 128 },
    .{ .id = block.gravel, .size = 32, .count = 10, .max_height = 128 },
    .{ .id = block.ore_coal, .size = 16, .count = 20, .max_height = 128 },
    .{ .id = block.ore_iron, .size = 8, .count = 20, .max_height = 64 },
    .{ .id = block.ore_gold, .size = 8, .count = 2, .max_height = 32 },
    .{ .id = block.ore_redstone, .size = 7, .count = 8, .max_height = 16 },
    .{ .id = block.ore_diamond, .size = 7, .count = 1, .max_height = 16 },
};

pub fn generateOreVeins(chunk: *Chunk, chunk_x: i32, chunk_z: i32, rand: *JavaRandom) void {
    const base_x = chunk_x * 16;
    const base_z = chunk_z * 16;

    for (ore_veins) |vein| {
        for (0..@intCast(vein.count)) |_| {
            const x = base_x + rand.nextIntBound(16);
            const y = rand.nextIntBound(vein.max_height);
            const z = base_z + rand.nextIntBound(16);
            generateVeinBlob(chunk, chunk_x, chunk_z, rand, x, y, z, block.stone, vein.id, vein.size);
        }
    }

    for (0..1) |_| {
        const x = base_x + rand.nextIntBound(16);
        const y = rand.nextIntBound(16) + rand.nextIntBound(16);
        const z = base_z + rand.nextIntBound(16);
        generateVeinBlob(chunk, chunk_x, chunk_z, rand, x, y, z, block.stone, block.ore_lapis, 6);
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
        if (chunk.getBlockId(@intCast(lx), @intCast(y), @intCast(lz)) != block.stationary_water) continue;
        generateVeinBlob(chunk, chunk_x, chunk_z, rand, x, y, z, block.sand, block.clay, 32);
    }
}

pub fn columnTopY(world_map: *const World, x: i32, z: i32) i32 {
    var y: i32 = 127;
    while (y >= 0) : (y -= 1) {
        if (world_map.getBlockId(x, y, z) != block.air) return y + 1;
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
                const id = world_map.getBlockId(x + dx, check_y, z + dz);
                if (id != block.air and id != block.leaves) can_grow = false;
            }
        }
    }
    if (!can_grow) return false;

    if (y_in < 1) return false;
    const below = world_map.getBlockId(x, y_in - 1, z);
    if ((below != block.grass and below != block.dirt) or y_in >= 128 - trunk_height - 1) return false;

    world_map.setBlockId(x, y_in - 1, z, block.dirt);

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
                    const id = world_map.getBlockId(lx, ly, lz);
                    if (id == block.air) {
                        world_map.setBlockId(lx, ly, lz, block.leaves);
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
        const id = world_map.getBlockId(x, ty, z);
        if (id == block.air or id == block.leaves) {
            world_map.setBlockId(x, ty, z, block.log);
            world_map.setBlockMetadata(x, ty, z, wood_metadata);
        }
    }

    return true;
}

fn bigTreeSetLeafIfClear(world_map: *World, x: i32, y: i32, z: i32) void {
    if (world_map.getBlockId(x, y, z) == block.air) world_map.setBlockId(x, y, z, block.leaves);
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
        const id = world_map.getBlockId(lx, ly, lz);
        if (id != block.air and id != block.leaves) return false;
    }
    return true;
}

fn bigTreeDrawLogLine(world_map: *World, x0: i32, y0: i32, z0: i32, x1: i32, y1: i32, z1: i32) void {
    const dx = x1 - x0;
    const dy = y1 - y0;
    const dz = z1 - z0;
    const steps: i32 = @intCast(@max(@max(@abs(dx), @abs(dy)), @abs(dz)));
    if (steps == 0) {
        world_map.setBlockId(x0, y0, z0, block.log);
        return;
    }
    var i: i32 = 0;
    while (i <= steps) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
        const lx = x0 + math.util.floorDouble(@as(f64, @floatFromInt(dx)) * t + 0.5);
        const ly = y0 + math.util.floorDouble(@as(f64, @floatFromInt(dy)) * t + 0.5);
        const lz = z0 + math.util.floorDouble(@as(f64, @floatFromInt(dz)) * t + 0.5);
        world_map.setBlockId(lx, ly, lz, block.log);
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
        const id = world_map.getBlockId(x, y_in + checked, z);
        if (id != block.air and id != block.leaves) {
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

fn treeCountFor(surface_biome: biome.Biome) i32 {
    return switch (surface_biome) {
        .forest, .rainforest, .taiga => 10,
        .seasonal_forest => 7,
        .desert, .tundra, .plains => 0,
        else => 0,
    };
}

pub fn generateTrees(world_map: *World, chunk_x: i32, chunk_z: i32, rand: *JavaRandom, surface_biome: biome.Biome) void {
    const base_x = chunk_x * 16;
    const base_z = chunk_z * 16;
    const count = treeCountFor(surface_biome);

    var i: i32 = 0;
    while (i < count) : (i += 1) {
        const x = base_x + rand.nextIntBound(16) + 8;
        const z = base_z + rand.nextIntBound(16) + 8;
        const y = columnTopY(world_map, x, z);

        if (surface_biome == .forest) {
            if (rand.nextIntBound(5) == 0) {
                _ = generateBirchTree(world_map, rand, x, y, z);
            } else if (rand.nextIntBound(3) == 0) {
                _ = generateBigTree(world_map, rand, x, y, z);
            } else {
                _ = generateTree(world_map, rand, x, y, z);
            }
        } else if (rand.nextIntBound(10) == 0) {
            _ = generateBigTree(world_map, rand, x, y, z);
        } else {
            _ = generateTree(world_map, rand, x, y, z);
        }
    }
}

fn descendToAnchor(world_map: *const World, x: i32, y_in: i32, z: i32) i32 {
    var y = y_in;
    while (y > 0) {
        const id = world_map.getBlockId(x, y, z);
        if (id != block.air and id != block.leaves) break;
        y -= 1;
    }
    return y;
}

fn canPlantStayOn(below: u8) bool {
    return below == block.grass or below == block.dirt;
}

pub fn generateTallGrassPatch(world_map: *World, rand: *JavaRandom, x: i32, y_in: i32, z: i32, metadata: u4) void {
    const y = descendToAnchor(world_map, x, y_in, z);
    for (0..128) |_| {
        const wx = x + rand.nextIntBound(8) - rand.nextIntBound(8);
        const wy = y + rand.nextIntBound(4) - rand.nextIntBound(4);
        const wz = z + rand.nextIntBound(8) - rand.nextIntBound(8);
        if (wy < 1 or wy >= 128) continue;
        if (world_map.getBlockId(wx, wy, wz) != block.air) continue;
        const below = world_map.getBlockId(wx, wy - 1, wz);
        if (!canPlantStayOn(below)) continue;
        world_map.setBlockId(wx, wy, wz, block.tall_grass);
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
        if (world_map.getBlockId(wx, wy, wz) != block.air) continue;
        const below = world_map.getBlockId(wx, wy - 1, wz);
        if (below != block.sand) continue;
        world_map.setBlockId(wx, wy, wz, block.dead_bush);
    }
}

pub fn generateFlowerPatch(world_map: *World, rand: *JavaRandom, x: i32, y: i32, z: i32, flower_id: u8, stayCheck: *const fn (u8) bool) void {
    for (0..64) |_| {
        const wx = x + rand.nextIntBound(8) - rand.nextIntBound(8);
        const wy = y + rand.nextIntBound(4) - rand.nextIntBound(4);
        const wz = z + rand.nextIntBound(8) - rand.nextIntBound(8);
        if (wy < 1 or wy >= 128) continue;
        if (world_map.getBlockId(wx, wy, wz) != block.air) continue;
        const below = world_map.getBlockId(wx, wy - 1, wz);
        if (!stayCheck(below)) continue;
        world_map.setBlockId(wx, wy, wz, flower_id);
    }
}

pub fn generatePumpkinPatch(world_map: *World, rand: *JavaRandom, x: i32, y: i32, z: i32) void {
    for (0..64) |_| {
        const wx = x + rand.nextIntBound(8) - rand.nextIntBound(8);
        const wy = y + rand.nextIntBound(4) - rand.nextIntBound(4);
        const wz = z + rand.nextIntBound(8) - rand.nextIntBound(8);
        if (wy < 1 or wy >= 128) continue;
        if (world_map.getBlockId(wx, wy, wz) != block.air) continue;
        const below = world_map.getBlockId(wx, wy - 1, wz);
        if (below != block.grass) continue;
        world_map.setBlockId(wx, wy, wz, block.pumpkin);
        world_map.setBlockMetadata(wx, wy, wz, @intCast(rand.nextIntBound(4)));
    }
}

fn hasAdjacentWater(world_map: *const World, x: i32, y: i32, z: i32) bool {
    return world_map.getBlockId(x - 1, y, z) == block.stationary_water or
        world_map.getBlockId(x + 1, y, z) == block.stationary_water or
        world_map.getBlockId(x, y, z - 1) == block.stationary_water or
        world_map.getBlockId(x, y, z + 1) == block.stationary_water;
}

pub fn generateReedPatch(world_map: *World, rand: *JavaRandom, x: i32, y: i32, z: i32) void {
    for (0..20) |_| {
        const wx = x + rand.nextIntBound(4) - rand.nextIntBound(4);
        const wz = z + rand.nextIntBound(4) - rand.nextIntBound(4);
        if (y < 1 or y >= 128) continue;
        if (world_map.getBlockId(wx, y, wz) != block.air) continue;
        const below = world_map.getBlockId(wx, y - 1, wz);
        if (below != block.grass and below != block.dirt) continue;
        if (!hasAdjacentWater(world_map, wx, y - 1, wz)) continue;

        const height = 2 + rand.nextIntBound(rand.nextIntBound(3) + 1);
        var k: i32 = 0;
        while (k < height) : (k += 1) {
            const ry = y + k;
            if (ry >= 128) break;
            if (world_map.getBlockId(wx, ry, wz) != block.air) break;
            world_map.setBlockId(wx, ry, wz, block.reed);
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
        generateFlowerPatch(world_map, rand, x, y, z, block.dandelion, canPlantStayOn);
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
        generateFlowerPatch(world_map, rand, x, y, z, block.rose, canPlantStayOn);
    }

    if (rand.nextIntBound(4) == 0) {
        const x = base_x + rand.nextIntBound(16) + 8;
        const y = rand.nextIntBound(128);
        const z = base_z + rand.nextIntBound(16) + 8;
        generateFlowerPatch(world_map, rand, x, y, z, block.mushroom_brown, block.isOpaque);
    }

    if (rand.nextIntBound(8) == 0) {
        const x = base_x + rand.nextIntBound(16) + 8;
        const y = rand.nextIntBound(128);
        const z = base_z + rand.nextIntBound(16) + 8;
        generateFlowerPatch(world_map, rand, x, y, z, block.mushroom_red, block.isOpaque);
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
}

test "clay patches replace sand only where the origin is underwater" {
    var chunk = Chunk.init(0, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            var y: u32 = 0;
            while (y < 128) : (y += 1) {
                const id: u8 = if (y % 2 == 0) block.stationary_water else block.sand;
                chunk.setBlockId(@intCast(x), y, @intCast(z), id);
            }
        }
    }

    var rand = JavaRandom.init(7);
    generateClayPatches(&chunk, 0, 0, &rand);

    var found_clay = false;
    for (0..16) |x| {
        for (0..16) |z| {
            for (0..128) |y| {
                if (chunk.getBlockId(@intCast(x), @intCast(y), @intCast(z)) == block.clay) found_clay = true;
            }
        }
    }
    try std.testing.expect(found_clay);
}

test "clay patches do nothing without water at the origin" {
    var chunk = Chunk.init(0, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            chunk.setBlockId(@intCast(x), 60, @intCast(z), block.sand);
        }
    }

    var rand = JavaRandom.init(7);
    generateClayPatches(&chunk, 0, 0, &rand);

    for (0..16) |x| {
        for (0..16) |z| {
            try std.testing.expect(chunk.getBlockId(@intCast(x), 60, @intCast(z)) != block.clay);
        }
    }
}

test "ore veins can replace stone underground" {
    var chunk = Chunk.init(0, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            for (0..64) |y| {
                chunk.setBlockId(@intCast(x), @intCast(y), @intCast(z), block.stone);
            }
        }
    }

    var rand = JavaRandom.init(42);
    generateOreVeins(&chunk, 0, 0, &rand);

    var found_ore = false;
    for (0..16) |x| {
        for (0..16) |z| {
            for (0..64) |y| {
                const id = chunk.getBlockId(@intCast(x), @intCast(y), @intCast(z));
                if (id == block.ore_coal or id == block.ore_iron or id == block.dirt or id == block.gravel) found_ore = true;
            }
        }
    }
    try std.testing.expect(found_ore);
}

fn testWorldWithFloor() !World {
    var w = World.init(std.testing.allocator);
    var chunk = Chunk.init(0, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            chunk.setBlockId(@intCast(x), 0, @intCast(z), block.grass);
        }
    }
    try w.chunks.put(std.testing.allocator, .{ .x = 0, .z = 0 }, chunk);
    return w;
}

test "a tree grows on grass with clear space above" {
    var w = try testWorldWithFloor();
    defer w.deinit();

    var rand = JavaRandom.init(1);
    const grew = generateTree(&w, &rand, 8, 1, 8);
    try std.testing.expect(grew);
    try std.testing.expectEqual(@as(u8, block.log), w.getBlockId(8, 1, 8));
}

test "a birch tree stores wood metadata 2 on its log and leaves" {
    var w = try testWorldWithFloor();
    defer w.deinit();

    var rand = JavaRandom.init(1);
    const grew = generateBirchTree(&w, &rand, 8, 1, 8);
    try std.testing.expect(grew);
    try std.testing.expectEqual(@as(u8, block.log), w.getBlockId(8, 1, 8));
    try std.testing.expectEqual(@as(u4, 2), w.getBlockMetadata(8, 1, 8));
}

test "a tree does not grow without clear space above" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    var chunk = Chunk.init(0, 0);
    chunk.setBlockId(8, 0, 8, block.grass);
    chunk.setBlockId(8, 3, 8, block.stone);
    try w.chunks.put(std.testing.allocator, .{ .x = 0, .z = 0 }, chunk);

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
                const id = w.getBlockId(@intCast(x), @intCast(y), @intCast(z));
                if (id == block.log) logs += 1;
                if (id == block.leaves) leaves += 1;
            }
        }
    }
    try std.testing.expect(logs > 0);
    try std.testing.expect(leaves > 0);
}

test "a big tree refuses to grow with an obstruction right above its base" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    var chunk = Chunk.init(0, 0);
    chunk.setBlockId(8, 0, 8, block.grass);
    chunk.setBlockId(8, 3, 8, block.stone);
    try w.chunks.put(std.testing.allocator, .{ .x = 0, .z = 0 }, chunk);

    var rand = JavaRandom.init(1);
    const grew = generateBigTree(&w, &rand, 8, 1, 8);
    try std.testing.expect(!grew);
}

test "generateTrees places trees in a forest biome and none in desert" {
    var forest_w = World.init(std.testing.allocator);
    defer forest_w.deinit();
    var forest_chunk = Chunk.init(0, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            forest_chunk.setBlockId(@intCast(x), 0, @intCast(z), block.grass);
        }
    }
    try forest_w.chunks.put(std.testing.allocator, .{ .x = 0, .z = 0 }, forest_chunk);
    var forest_rand = JavaRandom.init(1);
    generateTrees(&forest_w, 0, 0, &forest_rand, .forest);

    var forest_logs: usize = 0;
    for (0..16) |x| {
        for (0..128) |y| {
            for (0..16) |z| {
                if (forest_w.getBlockId(@intCast(x), @intCast(y), @intCast(z)) == block.log) forest_logs += 1;
            }
        }
    }
    try std.testing.expect(forest_logs > 0);

    var desert_w = World.init(std.testing.allocator);
    defer desert_w.deinit();
    var desert_chunk = Chunk.init(0, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            desert_chunk.setBlockId(@intCast(x), 0, @intCast(z), block.sand);
        }
    }
    try desert_w.chunks.put(std.testing.allocator, .{ .x = 0, .z = 0 }, desert_chunk);
    var desert_rand = JavaRandom.init(1);
    generateTrees(&desert_w, 0, 0, &desert_rand, .desert);

    var desert_logs: usize = 0;
    for (0..16) |x| {
        for (0..128) |y| {
            for (0..16) |z| {
                if (desert_w.getBlockId(@intCast(x), @intCast(y), @intCast(z)) == block.log) desert_logs += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), desert_logs);
}

test "a tree whose rolled position spills into the neighbor chunk still grows there" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    var a = Chunk.init(0, 0);
    var b = Chunk.init(1, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            a.setBlockId(@intCast(x), 0, @intCast(z), block.grass);
            b.setBlockId(@intCast(x), 0, @intCast(z), block.grass);
        }
    }
    try w.chunks.put(std.testing.allocator, .{ .x = 0, .z = 0 }, a);
    try w.chunks.put(std.testing.allocator, .{ .x = 1, .z = 0 }, b);

    var rand = JavaRandom.init(1);
    const grew = generateTree(&w, &rand, 20, 1, 8);
    try std.testing.expect(grew);
    try std.testing.expectEqual(@as(u8, block.log), w.getBlockId(20, 1, 8));
}

fn flatGrassWorld() !World {
    var w = World.init(std.testing.allocator);
    var chunk = Chunk.init(0, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            chunk.setBlockId(@intCast(x), 10, @intCast(z), block.grass);
        }
    }
    try w.chunks.put(std.testing.allocator, .{ .x = 0, .z = 0 }, chunk);
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
            if (w.getBlockId(@intCast(x), 11, @intCast(z)) == block.tall_grass) found = true;
        }
    }
    try std.testing.expect(found);
}

test "dead bush only takes root on sand" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    var chunk = Chunk.init(0, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            chunk.setBlockId(@intCast(x), 10, @intCast(z), block.sand);
        }
    }
    try w.chunks.put(std.testing.allocator, .{ .x = 0, .z = 0 }, chunk);
    var rand = JavaRandom.init(1);
    generateDeadBushPatch(&w, &rand, 8, 20, 8);

    var found = false;
    for (0..16) |x| {
        for (0..16) |z| {
            if (w.getBlockId(@intCast(x), 11, @intCast(z)) == block.dead_bush) found = true;
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
            try std.testing.expect(w.getBlockId(@intCast(x), 11, @intCast(z)) != block.dead_bush);
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
            const id = w.getBlockId(@intCast(x), 11, @intCast(z));
            if (id == block.dandelion or id == block.tall_grass or id == block.rose) found_flower_or_grass = true;
        }
    }
    try std.testing.expect(found_flower_or_grass);
}

test "mushrooms can stay on any opaque block, unlike flowers" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    var chunk = Chunk.init(0, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            chunk.setBlockId(@intCast(x), 10, @intCast(z), block.stone);
        }
    }
    try w.chunks.put(std.testing.allocator, .{ .x = 0, .z = 0 }, chunk);
    var rand = JavaRandom.init(1);
    generateFlowerPatch(&w, &rand, 8, 11, 8, block.mushroom_brown, block.isOpaque);

    var found = false;
    for (0..16) |x| {
        for (0..16) |z| {
            if (w.getBlockId(@intCast(x), 11, @intCast(z)) == block.mushroom_brown) found = true;
        }
    }
    try std.testing.expect(found);
}

test "reeds only take root on grass adjacent to water" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    var chunk = Chunk.init(0, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            const id: u8 = if (x % 2 == 0) block.stationary_water else block.grass;
            chunk.setBlockId(@intCast(x), 10, @intCast(z), id);
        }
    }
    try w.chunks.put(std.testing.allocator, .{ .x = 0, .z = 0 }, chunk);

    var rand = JavaRandom.init(1);
    generateReedPatch(&w, &rand, 8, 11, 8);

    var found = false;
    for (0..16) |x| {
        for (0..16) |z| {
            if (w.getBlockId(@intCast(x), 11, @intCast(z)) == block.reed) found = true;
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
            try std.testing.expect(w.getBlockId(@intCast(x), 11, @intCast(z)) != block.reed);
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
            if (w.getBlockId(@intCast(x), 11, @intCast(z)) == block.pumpkin) {
                found = true;
                try std.testing.expect(w.getBlockMetadata(@intCast(x), 11, @intCast(z)) < 4);
            }
        }
    }
    try std.testing.expect(found);
}
