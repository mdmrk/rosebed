const std = @import("std");

const math = @import("math");

const block = @import("../block.zig");
const Block = @import("../block.zig").Block;
const Chunk = @import("../Chunk.zig");
const JavaRandom = @import("../JavaRandom.zig");
const light = @import("../light.zig");
const World = @import("../World.zig");
const biome = @import("biome.zig");

fn tryPlaceIfMatches(world_map: *World, wx: i32, wy: i32, wz: i32, match_id: Block, replace_id: Block) void {
    if (world_map.getBlock(wx, wy, wz) == match_id) {
        world_map.setBlock(wx, wy, wz, replace_id);
    }
}

pub fn generateVeinBlob(world_map: *World, rand: *JavaRandom, x: i32, y: i32, z: i32, match_id: Block, replace_id: Block, vein_size: i32) void {
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
                    tryPlaceIfMatches(world_map, bx, by, bz, match_id, replace_id);
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

pub fn generateOreVeins(world_map: *World, chunk_x: i32, chunk_z: i32, rand: *JavaRandom) void {
    const base_x = chunk_x * 16;
    const base_z = chunk_z * 16;

    for (ore_veins) |vein| {
        for (0..@intCast(vein.count)) |_| {
            const x = base_x + rand.nextIntBound(16);
            const y = rand.nextIntBound(vein.max_height);
            const z = base_z + rand.nextIntBound(16);
            generateVeinBlob(world_map, rand, x, y, z, .stone, vein.id, vein.size);
        }
    }

    for (0..1) |_| {
        const x = base_x + rand.nextIntBound(16);
        const y = rand.nextIntBound(16) + rand.nextIntBound(16);
        const z = base_z + rand.nextIntBound(16);
        generateVeinBlob(world_map, rand, x, y, z, .stone, .ore_lapis, 6);
    }
}

pub fn generateClayPatches(world_map: *World, chunk_x: i32, chunk_z: i32, rand: *JavaRandom) void {
    const base_x = chunk_x * 16;
    const base_z = chunk_z * 16;

    for (0..10) |_| {
        const x = base_x + rand.nextIntBound(16);
        const y = rand.nextIntBound(128);
        const z = base_z + rand.nextIntBound(16);
        if (world_map.getBlock(x, y, z).material() != .water) continue;
        generateVeinBlob(world_map, rand, x, y, z, .sand, .clay, 32);
    }
}

pub fn heightValueAt(world_map: *const World, x: i32, z: i32) i32 {
    var y: i32 = 127;
    while (y > 0 and light.opacity(world_map.getBlock(x, y - 1, z)) == 0) y -= 1;
    return y;
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
                if (id != .air and id != .leaves) can_grow = false;
            }
        }
    }
    if (!can_grow) return false;

    if (y_in < 1) return false;
    const below = world_map.getBlock(x, y_in - 1, z);
    if ((below != .grass and below != .dirt) or y_in >= 128 - trunk_height - 1) return false;

    world_map.setBlock(x, y_in - 1, z, .dirt);

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
                    if (!world_map.getBlock(lx, ly, lz).isOpaqueCube()) {
                        world_map.setBlock(lx, ly, lz, .leaves);
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
        if (id == .air or id == .leaves) {
            world_map.setBlock(x, ty, z, .log);
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
                if (id != .air and id != .leaves) return false;
            }
        }
    }
    return true;
}

fn taigaGroundIsSuitable(world_map: *const World, x: i32, y: i32, z: i32, height: i32) bool {
    const below = world_map.getBlock(x, y - 1, z);
    return (below == .grass or below == .dirt) and y < 128 - height - 1;
}

fn placeTaigaLeafLayer(world_map: *World, x: i32, y: i32, z: i32, radius: i32) void {
    var cx = x - radius;
    while (cx <= x + radius) : (cx += 1) {
        var cz = z - radius;
        while (cz <= z + radius) : (cz += 1) {
            if (@abs(cx - x) == radius and @abs(cz - z) == radius and radius > 0) continue;
            if (world_map.getBlock(cx, y, cz).isOpaqueCube()) continue;
            world_map.setBlock(cx, y, cz, .leaves);
            world_map.setBlockMetadata(cx, y, cz, taiga_wood_metadata);
        }
    }
}

fn placeTaigaTrunk(world_map: *World, x: i32, y: i32, z: i32, height: i32) void {
    var i: i32 = 0;
    while (i < height) : (i += 1) {
        const id = world_map.getBlock(x, y + i, z);
        if (id != .air and id != .leaves) continue;
        world_map.setBlock(x, y + i, z, .log);
        world_map.setBlockMetadata(x, y + i, z, taiga_wood_metadata);
    }
}

pub fn generatePineTree(world_map: *World, rand: *JavaRandom, x: i32, y: i32, z: i32) bool {
    const height = rand.nextIntBound(5) + 7;
    const bare_height = height - rand.nextIntBound(2) - 3;
    const max_radius = 1 + rand.nextIntBound(height - bare_height + 1);

    if (!taigaSpaceIsClear(world_map, x, y, z, height, bare_height, max_radius)) return false;
    if (!taigaGroundIsSuitable(world_map, x, y, z, height)) return false;

    world_map.setBlock(x, y - 1, z, .dirt);

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

    world_map.setBlock(x, y - 1, z, .dirt);

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

const big_tree_leaf_cluster_height: i32 = 5;
const big_tree_axis_pair = [6]usize{ 2, 0, 0, 1, 2, 1 };

fn bigTreeDominantAxis(delta: [3]i32) usize {
    var dominant: usize = 0;
    for (0..3) |axis| {
        if (@abs(delta[axis]) > @abs(delta[dominant])) dominant = axis;
    }
    return dominant;
}

fn bigTreeLineIsClear(world_map: *const World, from: [3]i32, to: [3]i32) bool {
    var delta: [3]i32 = undefined;
    for (0..3) |axis| delta[axis] = to[axis] - from[axis];

    const dominant = bigTreeDominantAxis(delta);
    if (delta[dominant] == 0) return true;

    const first = big_tree_axis_pair[dominant];
    const second = big_tree_axis_pair[dominant + 3];
    const step: i32 = if (delta[dominant] > 0) 1 else -1;
    const first_slope = @as(f64, @floatFromInt(delta[first])) / @as(f64, @floatFromInt(delta[dominant]));
    const second_slope = @as(f64, @floatFromInt(delta[second])) / @as(f64, @floatFromInt(delta[dominant]));

    var at: [3]i32 = undefined;
    var i: i32 = 0;
    const end = delta[dominant] + step;
    while (i != end) : (i += step) {
        at[dominant] = from[dominant] + i;
        at[first] = math.util.floorDouble(@as(f64, @floatFromInt(from[first])) + @as(f64, @floatFromInt(i)) * first_slope);
        at[second] = math.util.floorDouble(@as(f64, @floatFromInt(from[second])) + @as(f64, @floatFromInt(i)) * second_slope);
        const id = world_map.getBlock(at[0], at[1], at[2]);
        if (id != .air and id != .leaves) return false;
    }
    return true;
}

fn bigTreeDrawLogLine(world_map: *World, from: [3]i32, to: [3]i32) void {
    var delta: [3]i32 = undefined;
    for (0..3) |axis| delta[axis] = to[axis] - from[axis];

    const dominant = bigTreeDominantAxis(delta);
    if (delta[dominant] == 0) return;

    const first = big_tree_axis_pair[dominant];
    const second = big_tree_axis_pair[dominant + 3];
    const step: i32 = if (delta[dominant] > 0) 1 else -1;
    const first_slope = @as(f64, @floatFromInt(delta[first])) / @as(f64, @floatFromInt(delta[dominant]));
    const second_slope = @as(f64, @floatFromInt(delta[second])) / @as(f64, @floatFromInt(delta[dominant]));

    var at: [3]i32 = undefined;
    var i: i32 = 0;
    const end = delta[dominant] + step;
    while (i != end) : (i += step) {
        at[dominant] = from[dominant] + i;
        at[first] = math.util.floorDouble(@as(f64, @floatFromInt(from[first])) + @as(f64, @floatFromInt(i)) * first_slope + 0.5);
        at[second] = math.util.floorDouble(@as(f64, @floatFromInt(from[second])) + @as(f64, @floatFromInt(i)) * second_slope + 0.5);
        world_map.setBlock(at[0], at[1], at[2], .log);
    }
}

fn bigTreeLeafDisc(world_map: *World, center: [3]i32, radius: f32) void {
    const reach: i32 = @intFromFloat(@as(f64, radius) + 0.618);
    var dx: i32 = -reach;
    while (dx <= reach) : (dx += 1) {
        var dz: i32 = -reach;
        while (dz <= reach) : (dz += 1) {
            const fdx = @as(f64, @floatFromInt(@abs(dx))) + 0.5;
            const fdz = @as(f64, @floatFromInt(@abs(dz))) + 0.5;
            if (@sqrt(std.math.pow(f64, fdx, 2.0) + std.math.pow(f64, fdz, 2.0)) > @as(f64, radius)) continue;
            const id = world_map.getBlock(center[0] + dx, center[1], center[2] + dz);
            if (id != .air and id != .leaves) continue;
            world_map.setBlock(center[0] + dx, center[1], center[2] + dz, .leaves);
        }
    }
}

fn bigTreeLeafRadius(offset: i32) f32 {
    if (offset < 0 or offset >= big_tree_leaf_cluster_height) return -1.0;
    return if (offset != 0 and offset != big_tree_leaf_cluster_height - 1) 3.0 else 2.0;
}

fn bigTreeLayerSize(trunk_size: i32, layer: i32) f32 {
    const trunk_size_f: f32 = @floatFromInt(trunk_size);
    if (@as(f64, @floatFromInt(layer)) < @as(f64, trunk_size_f) * 0.3) return -1.618;

    const half = trunk_size_f / 2.0;
    const offset = half - @as(f32, @floatFromInt(layer));

    var size: f32 = undefined;
    if (offset == 0.0) {
        size = half;
    } else if (@abs(offset) >= half) {
        size = 0.0;
    } else {
        size = @floatCast(@sqrt(std.math.pow(f64, @abs(@as(f64, half)), 2.0) - std.math.pow(f64, @abs(@as(f64, offset)), 2.0)));
    }
    return size * 0.5;
}

pub fn generateBigTree(world_map: *World, world_rand: *JavaRandom, x: i32, y_in: i32, z: i32) bool {
    var rand = JavaRandom.init(world_rand.nextLong());
    const base = [3]i32{ x, y_in, z };

    var trunk_size: i32 = 5 + rand.nextIntBound(12);

    const below = world_map.getBlock(x, y_in - 1, z);
    if (below != .grass and below != .dirt) return false;

    var probed: i32 = 0;
    while (probed < trunk_size) : (probed += 1) {
        const id = world_map.getBlock(x, y_in + probed, z);
        if (id == .air or id == .leaves) continue;
        if (probed < 6) return false;
        trunk_size = probed;
        break;
    }

    const crown_height: i32 = @min(math.util.floorDouble(@as(f64, @floatFromInt(trunk_size)) * 0.618), trunk_size - 1);
    const trunk_top = base[1] + crown_height;

    const branches_per_layer_f = 1.382 + std.math.pow(f64, @as(f64, @floatFromInt(trunk_size)) / 13.0, 2.0);
    const branches_per_layer: i32 = @max(1, @as(i32, @intFromFloat(branches_per_layer_f)));

    const Cluster = struct { x: i32, y: i32, z: i32, base_y: i32 };
    var clusters: [128]Cluster = undefined;

    var cluster_y = base[1] + trunk_size - big_tree_leaf_cluster_height;
    var layer = cluster_y - base[1];
    clusters[0] = .{ .x = base[0], .y = cluster_y, .z = base[2], .base_y = trunk_top };
    var cluster_count: usize = 1;
    cluster_y -= 1;

    while (layer >= 0) : ({
        cluster_y -= 1;
        layer -= 1;
    }) {
        const layer_size = bigTreeLayerSize(trunk_size, layer);
        if (layer_size < 0.0) continue;

        var i: i32 = 0;
        while (i < branches_per_layer) : (i += 1) {
            const reach = @as(f64, layer_size) * (@as(f64, rand.nextFloat()) + 0.328);
            const angle = @as(f64, rand.nextFloat()) * 2.0 * 3.14159;
            const tip = [3]i32{
                math.util.floorDouble(reach * @sin(angle) + @as(f64, @floatFromInt(base[0])) + 0.5),
                cluster_y,
                math.util.floorDouble(reach * @cos(angle) + @as(f64, @floatFromInt(base[2])) + 0.5),
            };
            if (!bigTreeLineIsClear(world_map, tip, .{ tip[0], tip[1] + big_tree_leaf_cluster_height, tip[2] })) continue;

            const spread = @sqrt(std.math.pow(f64, @as(f64, @floatFromInt(@abs(base[0] - tip[0]))), 2.0) +
                std.math.pow(f64, @as(f64, @floatFromInt(@abs(base[2] - tip[2]))), 2.0));
            const tip_y_f = @as(f64, @floatFromInt(tip[1]));
            const drop = spread * 0.381;
            const branch_base_y: i32 = if (tip_y_f - drop > @as(f64, @floatFromInt(trunk_top)))
                trunk_top
            else
                @intFromFloat(tip_y_f - drop);

            if (!bigTreeLineIsClear(world_map, .{ base[0], branch_base_y, base[2] }, tip)) continue;

            if (cluster_count >= clusters.len) break;
            clusters[cluster_count] = .{ .x = tip[0], .y = tip[1], .z = tip[2], .base_y = branch_base_y };
            cluster_count += 1;
        }
    }

    for (clusters[0..cluster_count]) |c| {
        var offset: i32 = 0;
        while (offset < big_tree_leaf_cluster_height) : (offset += 1) {
            bigTreeLeafDisc(world_map, .{ c.x, c.y + offset, c.z }, bigTreeLeafRadius(offset));
        }
    }

    bigTreeDrawLogLine(world_map, base, .{ base[0], trunk_top, base[2] });

    for (clusters[0..cluster_count]) |c| {
        if (@as(f64, @floatFromInt(c.base_y - base[1])) < @as(f64, @floatFromInt(trunk_size)) * 0.2) continue;
        bigTreeDrawLogLine(world_map, .{ base[0], c.base_y, base[2] }, .{ c.x, c.y, c.z });
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
        growRandomTree(world_map, rand, x, heightValueAt(world_map, x, z), z, surface_biome);
    }
}

fn descendToAnchor(world_map: *const World, x: i32, y_in: i32, z: i32) i32 {
    var y = y_in;
    while (y > 0) {
        const id = world_map.getBlock(x, y, z);
        if (id != .air and id != .leaves) break;
        y -= 1;
    }
    return y;
}

fn canPlantStayOn(below: Block) bool {
    return below == .grass or below == .dirt;
}

fn flowerCanStayAt(world_map: *const World, x: i32, y: i32, z: i32) bool {
    if (light.columnSkyLight(world_map, x, y, z) < 8) return false;
    return canPlantStayOn(world_map.getBlock(x, y - 1, z));
}

fn deadBushCanStayAt(world_map: *const World, x: i32, y: i32, z: i32) bool {
    if (light.columnSkyLight(world_map, x, y, z) < 8) return false;
    return world_map.getBlock(x, y - 1, z) == .sand;
}

pub fn mushroomCanStayAt(world_map: *const World, x: i32, y: i32, z: i32) bool {
    if (light.columnSkyLight(world_map, x, y, z) >= 13) return false;
    return world_map.getBlock(x, y - 1, z).isOpaque();
}

pub fn generateTallGrassPatch(world_map: *World, rand: *JavaRandom, x: i32, y_in: i32, z: i32, metadata: u4) void {
    const y = descendToAnchor(world_map, x, y_in, z);
    for (0..128) |_| {
        const wx = x + rand.nextIntBound(8) - rand.nextIntBound(8);
        const wy = y + rand.nextIntBound(4) - rand.nextIntBound(4);
        const wz = z + rand.nextIntBound(8) - rand.nextIntBound(8);
        if (wy < 1 or wy >= 128) continue;
        if (world_map.getBlock(wx, wy, wz) != .air) continue;
        if (!flowerCanStayAt(world_map, wx, wy, wz)) continue;
        world_map.setBlock(wx, wy, wz, .tall_grass);
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
        if (world_map.getBlock(wx, wy, wz) != .air) continue;
        if (!deadBushCanStayAt(world_map, wx, wy, wz)) continue;
        world_map.setBlock(wx, wy, wz, .dead_bush);
    }
}

pub fn generateFlowerPatch(world_map: *World, rand: *JavaRandom, x: i32, y: i32, z: i32, flower_id: Block, stayCheck: *const fn (*const World, i32, i32, i32) bool) void {
    for (0..64) |_| {
        const wx = x + rand.nextIntBound(8) - rand.nextIntBound(8);
        const wy = y + rand.nextIntBound(4) - rand.nextIntBound(4);
        const wz = z + rand.nextIntBound(8) - rand.nextIntBound(8);
        if (wy < 1 or wy >= 128) continue;
        if (world_map.getBlock(wx, wy, wz) != .air) continue;
        if (!stayCheck(world_map, wx, wy, wz)) continue;
        world_map.setBlock(wx, wy, wz, flower_id);
    }
}

pub fn generatePumpkinPatch(world_map: *World, rand: *JavaRandom, x: i32, y: i32, z: i32) void {
    for (0..64) |_| {
        const wx = x + rand.nextIntBound(8) - rand.nextIntBound(8);
        const wy = y + rand.nextIntBound(4) - rand.nextIntBound(4);
        const wz = z + rand.nextIntBound(8) - rand.nextIntBound(8);
        if (wy < 1 or wy >= 128) continue;
        if (world_map.getBlock(wx, wy, wz) != .air) continue;
        const below = world_map.getBlock(wx, wy - 1, wz);
        if (below != .grass) continue;
        world_map.setBlock(wx, wy, wz, .pumpkin);
        world_map.setBlockMetadata(wx, wy, wz, @intCast(rand.nextIntBound(4)));
    }
}

fn cactusCanStay(world_map: *const World, x: i32, y: i32, z: i32) bool {
    if (world_map.getBlock(x - 1, y, z).isSolid()) return false;
    if (world_map.getBlock(x + 1, y, z).isSolid()) return false;
    if (world_map.getBlock(x, y, z - 1).isSolid()) return false;
    if (world_map.getBlock(x, y, z + 1).isSolid()) return false;

    const below = world_map.getBlock(x, y - 1, z);
    return below == .cactus or below == .sand;
}

pub fn generateCactusPatch(world_map: *World, rand: *JavaRandom, x: i32, y: i32, z: i32) void {
    for (0..10) |_| {
        const wx = x + rand.nextIntBound(8) - rand.nextIntBound(8);
        const wy = y + rand.nextIntBound(4) - rand.nextIntBound(4);
        const wz = z + rand.nextIntBound(8) - rand.nextIntBound(8);
        if (world_map.getBlock(wx, wy, wz) != .air) continue;

        const height = 1 + rand.nextIntBound(rand.nextIntBound(3) + 1);
        var k: i32 = 0;
        while (k < height) : (k += 1) {
            if (!cactusCanStay(world_map, wx, wy + k, wz)) continue;
            world_map.setBlock(wx, wy + k, wz, .cactus);
        }
    }
}

fn hasAdjacentWater(world_map: *const World, x: i32, y: i32, z: i32) bool {
    return world_map.getBlock(x - 1, y, z).material() == .water or
        world_map.getBlock(x + 1, y, z).material() == .water or
        world_map.getBlock(x, y, z - 1).material() == .water or
        world_map.getBlock(x, y, z + 1).material() == .water;
}

fn reedCanStayAt(world_map: *const World, x: i32, y: i32, z: i32) bool {
    const below = world_map.getBlock(x, y - 1, z);
    if (below == .reed) return true;
    if (below != .grass and below != .dirt) return false;
    return hasAdjacentWater(world_map, x, y - 1, z);
}

pub fn generateReedPatch(world_map: *World, rand: *JavaRandom, x: i32, y: i32, z: i32) void {
    for (0..20) |_| {
        const wx = x + rand.nextIntBound(4) - rand.nextIntBound(4);
        const wz = z + rand.nextIntBound(4) - rand.nextIntBound(4);
        if (world_map.getBlock(wx, y, wz) != .air) continue;
        if (!hasAdjacentWater(world_map, wx, y - 1, wz)) continue;

        const height = 2 + rand.nextIntBound(rand.nextIntBound(3) + 1);
        var k: i32 = 0;
        while (k < height) : (k += 1) {
            if (!reedCanStayAt(world_map, wx, y + k, wz)) continue;
            world_map.setBlock(wx, y + k, wz, .reed);
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
        generateFlowerPatch(world_map, rand, x, y, z, .dandelion, flowerCanStayAt);
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
        generateFlowerPatch(world_map, rand, x, y, z, .rose, flowerCanStayAt);
    }

    if (rand.nextIntBound(4) == 0) {
        const x = base_x + rand.nextIntBound(16) + 8;
        const y = rand.nextIntBound(128);
        const z = base_z + rand.nextIntBound(16) + 8;
        generateFlowerPatch(world_map, rand, x, y, z, .mushroom_brown, mushroomCanStayAt);
    }

    if (rand.nextIntBound(8) == 0) {
        const x = base_x + rand.nextIntBound(16) + 8;
        const y = rand.nextIntBound(128);
        const z = base_z + rand.nextIntBound(16) + 8;
        generateFlowerPatch(world_map, rand, x, y, z, .mushroom_red, mushroomCanStayAt);
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

fn filledWorld(chunk_count: i32, fill: *const fn (chunk: *Chunk) void) !World {
    var w = World.init(std.testing.allocator);
    var chunk_x: i32 = 0;
    while (chunk_x < chunk_count) : (chunk_x += 1) {
        var chunk_z: i32 = 0;
        while (chunk_z < chunk_count) : (chunk_z += 1) {
            fill(try w.createChunk(chunk_x, chunk_z));
        }
    }
    return w;
}

test "clay patches replace sand only where the origin is underwater" {
    var w = try filledWorld(1, struct {
        fn fill(chunk: *Chunk) void {
            for (0..16) |x| {
                for (0..16) |z| {
                    var y: u32 = 0;
                    while (y < 128) : (y += 1) {
                        const id: Block = if (y % 2 == 0) .stationary_water else .sand;
                        chunk.setBlock(@intCast(x), y, @intCast(z), id);
                    }
                }
            }
        }
    }.fill);
    defer w.deinit();

    var rand = JavaRandom.init(7);
    generateClayPatches(&w, 0, 0, &rand);

    var found_clay = false;
    for (0..16) |x| {
        for (0..16) |z| {
            for (0..128) |y| {
                if (w.getBlock(@intCast(x), @intCast(y), @intCast(z)) == .clay) found_clay = true;
            }
        }
    }
    try std.testing.expect(found_clay);
}

test "clay patches do nothing without water at the origin" {
    var w = try filledWorld(1, struct {
        fn fill(chunk: *Chunk) void {
            for (0..16) |x| {
                for (0..16) |z| {
                    chunk.setBlock(@intCast(x), 60, @intCast(z), .sand);
                }
            }
        }
    }.fill);
    defer w.deinit();

    var rand = JavaRandom.init(7);
    generateClayPatches(&w, 0, 0, &rand);

    for (0..16) |x| {
        for (0..16) |z| {
            try std.testing.expect(w.getBlock(@intCast(x), 60, @intCast(z)) != .clay);
        }
    }
}

fn fillStoneToSixtyFour(chunk: *Chunk) void {
    for (0..16) |x| {
        for (0..16) |z| {
            for (0..64) |y| {
                chunk.setBlock(@intCast(x), @intCast(y), @intCast(z), .stone);
            }
        }
    }
}

test "ore veins can replace stone underground" {
    var w = try filledWorld(1, fillStoneToSixtyFour);
    defer w.deinit();

    var rand = JavaRandom.init(42);
    generateOreVeins(&w, 0, 0, &rand);

    var found_ore = false;
    for (0..16) |x| {
        for (0..16) |z| {
            for (0..64) |y| {
                const id = w.getBlock(@intCast(x), @intCast(y), @intCast(z));
                if (id == .ore_coal or id == .ore_iron or id == .dirt or id == .gravel) found_ore = true;
            }
        }
    }
    try std.testing.expect(found_ore);
}

test "an ore vein rolled near the edge spills into the neighbor chunk" {
    var w = try filledWorld(2, fillStoneToSixtyFour);
    defer w.deinit();

    var rand = JavaRandom.init(3);
    generateVeinBlob(&w, &rand, 14, 32, 8, .stone, .ore_coal, 32);

    var found_across = false;
    for (16..32) |x| {
        for (0..16) |z| {
            for (0..64) |y| {
                if (w.getBlock(@intCast(x), @intCast(y), @intCast(z)) == .ore_coal) found_across = true;
            }
        }
    }
    try std.testing.expect(found_across);
}

fn testWorldWithFloor() !World {
    var w = World.init(std.testing.allocator);
    const chunk = try w.createChunk(0, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            chunk.setBlock(@intCast(x), 0, @intCast(z), .grass);
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
    try std.testing.expectEqual(.log, w.getBlock(8, 1, 8));
}

test "a birch tree stores wood metadata 2 on its log and leaves" {
    var w = try testWorldWithFloor();
    defer w.deinit();

    var rand = JavaRandom.init(1);
    const grew = generateBirchTree(&w, &rand, 8, 1, 8);
    try std.testing.expect(grew);
    try std.testing.expectEqual(.log, w.getBlock(8, 1, 8));
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

        try std.testing.expectEqual(.log, w.getBlock(8, 1, 8));
        try std.testing.expectEqual(taiga_wood_metadata, w.getBlockMetadata(8, 1, 8));

        var leaves: usize = 0;
        for (0..16) |x| {
            for (1..30) |y| {
                for (0..16) |z| {
                    if (w.getBlock(@intCast(x), @intCast(y), @intCast(z)) != .leaves) continue;
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
    chunk.setBlock(8, 0, 8, .grass);
    chunk.setBlock(8, 3, 8, .stone);

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
                if (id == .log) logs += 1;
                if (id == .leaves) leaves += 1;
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
    chunk.setBlock(8, 0, 8, .grass);
    chunk.setBlock(8, 3, 8, .stone);

    var rand = JavaRandom.init(1);
    const grew = generateBigTree(&w, &rand, 8, 1, 8);
    try std.testing.expect(!grew);
}

test "a big tree refuses to grow on anything but grass or dirt" {
    for ([_]Block{ .sand, .stone, .stationary_water }) |ground| {
        var w = World.init(std.testing.allocator);
        defer w.deinit();
        const chunk = try w.createChunk(0, 0);
        for (0..16) |x| {
            for (0..16) |z| {
                chunk.setBlock(@intCast(x), 0, @intCast(z), ground);
            }
        }

        var rand = JavaRandom.init(1);
        try std.testing.expect(!generateBigTree(&w, &rand, 8, 1, 8));
    }
}

test "a big tree's trunk runs unbroken from the ground to its topmost leaf cluster" {
    var seed: i64 = 1;
    while (seed <= 40) : (seed += 1) {
        var w = try testWorldWithFloor();
        defer w.deinit();

        var rand = JavaRandom.init(seed);
        try std.testing.expect(generateBigTree(&w, &rand, 8, 1, 8));

        var highest_leaf: i32 = 0;
        var y: i32 = 1;
        while (y < 128) : (y += 1) {
            var x: i32 = 0;
            while (x < 16) : (x += 1) {
                var z: i32 = 0;
                while (z < 16) : (z += 1) {
                    if (w.getBlock(x, y, z) == .leaves) highest_leaf = y;
                }
            }
        }

        const trunk_size = highest_leaf - 1 + 1;
        const crown_height = math.util.floorDouble(@as(f64, @floatFromInt(trunk_size)) * 0.618);
        const trunk_top = 1 + @max(crown_height, trunk_size - big_tree_leaf_cluster_height);

        y = 1;
        while (y <= trunk_top) : (y += 1) {
            try std.testing.expectEqual(.log, w.getBlock(8, y, 8));
        }
        try std.testing.expect(w.getBlock(8, trunk_top + 1, 8) != .log);
    }
}

test "the height value ignores blocks that do not block light, like the original's heightmap" {
    var w = try flatGrassWorld();
    defer w.deinit();

    try std.testing.expectEqual(@as(i32, 11), heightValueAt(&w, 8, 8));

    w.setBlock(8, 11, 8, .tall_grass);
    try std.testing.expectEqual(@as(i32, 11), heightValueAt(&w, 8, 8));

    w.setBlock(8, 11, 8, .dandelion);
    try std.testing.expectEqual(@as(i32, 11), heightValueAt(&w, 8, 8));

    w.setBlock(8, 11, 8, .stone);
    try std.testing.expectEqual(@as(i32, 12), heightValueAt(&w, 8, 8));
}

test "the height value stops on water and leaves, which do block light" {
    var w = try flatGrassWorld();
    defer w.deinit();

    w.setBlock(8, 11, 8, .stationary_water);
    try std.testing.expectEqual(@as(i32, 12), heightValueAt(&w, 8, 8));

    w.setBlock(8, 11, 8, .leaves);
    try std.testing.expectEqual(@as(i32, 12), heightValueAt(&w, 8, 8));
}

test "generateTrees places trees in a forest biome and none in desert" {
    var forest_w = World.init(std.testing.allocator);
    defer forest_w.deinit();
    const forest_chunk = try forest_w.createChunk(0, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            forest_chunk.setBlock(@intCast(x), 0, @intCast(z), .grass);
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
                if (forest_w.getBlock(@intCast(x), @intCast(y), @intCast(z)) == .log) forest_logs += 1;
            }
        }
    }
    try std.testing.expect(forest_logs > 0);

    var desert_w = World.init(std.testing.allocator);
    defer desert_w.deinit();
    const desert_chunk = try desert_w.createChunk(0, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            desert_chunk.setBlock(@intCast(x), 0, @intCast(z), .sand);
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
                if (desert_w.getBlock(@intCast(x), @intCast(y), @intCast(z)) == .log) desert_logs += 1;
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
            a.setBlock(@intCast(x), 0, @intCast(z), .grass);
            b.setBlock(@intCast(x), 0, @intCast(z), .grass);
        }
    }

    var rand = JavaRandom.init(1);
    const grew = generateTree(&w, &rand, 20, 1, 8);
    try std.testing.expect(grew);
    try std.testing.expectEqual(.log, w.getBlock(20, 1, 8));
}

fn flatGrassWorld() !World {
    var w = World.init(std.testing.allocator);
    const chunk = try w.createChunk(0, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            chunk.setBlock(@intCast(x), 10, @intCast(z), .grass);
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
            if (w.getBlock(@intCast(x), 11, @intCast(z)) == .tall_grass) found = true;
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
            chunk.setBlock(@intCast(x), 10, @intCast(z), .sand);
        }
    }
    var rand = JavaRandom.init(1);
    generateDeadBushPatch(&w, &rand, 8, 20, 8);

    var found = false;
    for (0..16) |x| {
        for (0..16) |z| {
            if (w.getBlock(@intCast(x), 11, @intCast(z)) == .dead_bush) found = true;
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
            try std.testing.expect(w.getBlock(@intCast(x), 11, @intCast(z)) != .dead_bush);
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
            if (id == .dandelion or id == .tall_grass or id == .rose) found_flower_or_grass = true;
        }
    }
    try std.testing.expect(found_flower_or_grass);
}

test "mushrooms can stay on any opaque block, but only away from full daylight" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    const chunk = try w.createChunk(0, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            chunk.setBlock(@intCast(x), 10, @intCast(z), .stone);
            chunk.setBlock(@intCast(x), 14, @intCast(z), .stone);
        }
    }
    var rand = JavaRandom.init(1);
    generateFlowerPatch(&w, &rand, 8, 11, 8, .mushroom_brown, mushroomCanStayAt);

    var found = false;
    for (0..16) |x| {
        for (0..16) |z| {
            if (w.getBlock(@intCast(x), 11, @intCast(z)) == .mushroom_brown) found = true;
        }
    }
    try std.testing.expect(found);

    var uncovered = World.init(std.testing.allocator);
    defer uncovered.deinit();
    const open_chunk = try uncovered.createChunk(0, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            open_chunk.setBlock(@intCast(x), 10, @intCast(z), .stone);
        }
    }
    var open_rand = JavaRandom.init(1);
    generateFlowerPatch(&uncovered, &open_rand, 8, 11, 8, .mushroom_brown, mushroomCanStayAt);

    for (0..16) |x| {
        for (0..16) |z| {
            try std.testing.expect(uncovered.getBlock(@intCast(x), 11, @intCast(z)) != .mushroom_brown);
        }
    }
}

test "reeds only take root on grass adjacent to water" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    const chunk = try w.createChunk(0, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            const id: Block = if (x % 2 == 0) .stationary_water else .grass;
            chunk.setBlock(@intCast(x), 10, @intCast(z), id);
        }
    }

    var rand = JavaRandom.init(1);
    generateReedPatch(&w, &rand, 8, 11, 8);

    var found = false;
    for (0..16) |x| {
        for (0..16) |z| {
            if (w.getBlock(@intCast(x), 11, @intCast(z)) == .reed) found = true;
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
            try std.testing.expect(w.getBlock(@intCast(x), 11, @intCast(z)) != .reed);
        }
    }
}

test "cactus grows on sand in stacks of at most three" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    const chunk = try w.createChunk(0, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            chunk.setBlock(@intCast(x), 10, @intCast(z), .sand);
        }
    }

    var rand = JavaRandom.init(5);
    generateCactusPatch(&w, &rand, 8, 11, 8);

    var tallest: usize = 0;
    for (0..16) |x| {
        for (0..16) |z| {
            var height: usize = 0;
            for (11..16) |y| {
                if (w.getBlock(@intCast(x), @intCast(y), @intCast(z)) != .cactus) break;
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
            chunk.setBlock(@intCast(x), 10, @intCast(z), .sand);
            chunk.setBlock(@intCast(x), 11, @intCast(z), .stone);
        }
    }
    chunk.setBlock(8, 11, 8, .air);

    var rand = JavaRandom.init(5);
    generateCactusPatch(&w, &rand, 8, 11, 8);

    for (0..16) |x| {
        for (0..16) |z| {
            try std.testing.expect(w.getBlock(@intCast(x), 11, @intCast(z)) != .cactus);
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
            if (w.getBlock(@intCast(x), 11, @intCast(z)) == .pumpkin) {
                found = true;
                try std.testing.expect(w.getBlockMetadata(@intCast(x), 11, @intCast(z)) < 4);
            }
        }
    }
    try std.testing.expect(found);
}
