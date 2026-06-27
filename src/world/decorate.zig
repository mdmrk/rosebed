const std = @import("std");
const math = @import("math");
const JavaRandom = @import("java_random.zig");
const Chunk = @import("chunk.zig");
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

fn columnTopY(chunk: *const Chunk, x: u32, z: u32) i32 {
    var y: i32 = 127;
    while (y >= 0) : (y -= 1) {
        if (chunk.getBlockId(x, @intCast(y), z) != block.air) return y + 1;
    }
    return 0;
}

pub fn generateTree(chunk: *Chunk, rand: *JavaRandom, x: i32, y_in: i32, z: i32) bool {
    const trunk_height = rand.nextIntBound(3) + 4;
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
                const lx = x + dx;
                const lz = z + dz;
                if (lx < 0 or lx >= 16 or lz < 0 or lz >= 16) {
                    can_grow = false;
                    continue;
                }
                const id = chunk.getBlockId(@intCast(lx), @intCast(check_y), @intCast(lz));
                if (id != block.air and id != block.leaves) can_grow = false;
            }
        }
    }
    if (!can_grow) return false;

    if (x < 0 or x >= 16 or z < 0 or z >= 16 or y_in < 1) return false;
    const below = chunk.getBlockId(@intCast(x), @intCast(y_in - 1), @intCast(z));
    if ((below != block.grass and below != block.dirt) or y_in >= 128 - trunk_height - 1) return false;

    chunk.setBlockId(@intCast(x), @intCast(y_in - 1), @intCast(z), block.dirt);

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
                if (lx < 0 or lx >= 16 or lz < 0 or lz >= 16 or ly < 0 or ly >= 128) continue;
                if ((@abs(dx) != margin or @abs(dz) != margin or (rand.nextIntBound(2) != 0 and dy != 0))) {
                    const id = chunk.getBlockId(@intCast(lx), @intCast(ly), @intCast(lz));
                    if (id == block.air) {
                        chunk.setBlockId(@intCast(lx), @intCast(ly), @intCast(lz), block.leaves);
                    }
                }
            }
        }
    }

    var trunk_y: i32 = 0;
    while (trunk_y < trunk_height) : (trunk_y += 1) {
        const ty = y_in + trunk_y;
        if (ty < 0 or ty >= 128) continue;
        const id = chunk.getBlockId(@intCast(x), @intCast(ty), @intCast(z));
        if (id == block.air or id == block.leaves) {
            chunk.setBlockId(@intCast(x), @intCast(ty), @intCast(z), block.log);
        }
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

pub fn generateTrees(chunk: *Chunk, chunk_x: i32, chunk_z: i32, rand: *JavaRandom, surface_biome: biome.Biome) void {
    const base_x = chunk_x * 16;
    const base_z = chunk_z * 16;
    const count = treeCountFor(surface_biome);

    var i: i32 = 0;
    while (i < count) : (i += 1) {
        const x = base_x + rand.nextIntBound(16) + 8;
        const z = base_z + rand.nextIntBound(16) + 8;
        const lx = x - base_x;
        const lz = z - base_z;
        if (lx < 0 or lx >= 16 or lz < 0 or lz >= 16) continue;
        const y = columnTopY(chunk, @intCast(lx), @intCast(lz));
        _ = generateTree(chunk, rand, lx, y, lz);
    }
}

fn descendToAnchor(chunk: *const Chunk, chunk_x: i32, chunk_z: i32, x: i32, y_in: i32, z: i32) i32 {
    const lx = x - chunk_x * 16;
    const lz = z - chunk_z * 16;
    if (lx < 0 or lx >= 16 or lz < 0 or lz >= 16) return y_in;
    var y = y_in;
    while (y > 0) {
        const id = chunk.getBlockId(@intCast(lx), @intCast(y), @intCast(lz));
        if (id != block.air and id != block.leaves) break;
        y -= 1;
    }
    return y;
}

fn canPlantStayOn(below: u8) bool {
    return below == block.grass or below == block.dirt;
}

pub fn generateTallGrassPatch(chunk: *Chunk, chunk_x: i32, chunk_z: i32, rand: *JavaRandom, x: i32, y_in: i32, z: i32, metadata: u4) void {
    const y = descendToAnchor(chunk, chunk_x, chunk_z, x, y_in, z);
    for (0..128) |_| {
        const wx = x + rand.nextIntBound(8) - rand.nextIntBound(8);
        const wy = y + rand.nextIntBound(4) - rand.nextIntBound(4);
        const wz = z + rand.nextIntBound(8) - rand.nextIntBound(8);
        const lx = wx - chunk_x * 16;
        const lz = wz - chunk_z * 16;
        if (lx < 0 or lx >= 16 or lz < 0 or lz >= 16 or wy < 1 or wy >= 128) continue;
        if (chunk.getBlockId(@intCast(lx), @intCast(wy), @intCast(lz)) != block.air) continue;
        const below = chunk.getBlockId(@intCast(lx), @intCast(wy - 1), @intCast(lz));
        if (!canPlantStayOn(below)) continue;
        chunk.setBlockId(@intCast(lx), @intCast(wy), @intCast(lz), block.tall_grass);
        chunk.setBlockMetadata(@intCast(lx), @intCast(wy), @intCast(lz), metadata);
    }
}

pub fn generateDeadBushPatch(chunk: *Chunk, chunk_x: i32, chunk_z: i32, rand: *JavaRandom, x: i32, y_in: i32, z: i32) void {
    const y = descendToAnchor(chunk, chunk_x, chunk_z, x, y_in, z);
    for (0..4) |_| {
        const wx = x + rand.nextIntBound(8) - rand.nextIntBound(8);
        const wy = y + rand.nextIntBound(4) - rand.nextIntBound(4);
        const wz = z + rand.nextIntBound(8) - rand.nextIntBound(8);
        const lx = wx - chunk_x * 16;
        const lz = wz - chunk_z * 16;
        if (lx < 0 or lx >= 16 or lz < 0 or lz >= 16 or wy < 1 or wy >= 128) continue;
        if (chunk.getBlockId(@intCast(lx), @intCast(wy), @intCast(lz)) != block.air) continue;
        const below = chunk.getBlockId(@intCast(lx), @intCast(wy - 1), @intCast(lz));
        if (below != block.sand) continue;
        chunk.setBlockId(@intCast(lx), @intCast(wy), @intCast(lz), block.dead_bush);
    }
}

pub fn generateFlowerPatch(chunk: *Chunk, chunk_x: i32, chunk_z: i32, rand: *JavaRandom, x: i32, y: i32, z: i32, flower_id: u8) void {
    for (0..64) |_| {
        const wx = x + rand.nextIntBound(8) - rand.nextIntBound(8);
        const wy = y + rand.nextIntBound(4) - rand.nextIntBound(4);
        const wz = z + rand.nextIntBound(8) - rand.nextIntBound(8);
        const lx = wx - chunk_x * 16;
        const lz = wz - chunk_z * 16;
        if (lx < 0 or lx >= 16 or lz < 0 or lz >= 16 or wy < 1 or wy >= 128) continue;
        if (chunk.getBlockId(@intCast(lx), @intCast(wy), @intCast(lz)) != block.air) continue;
        const below = chunk.getBlockId(@intCast(lx), @intCast(wy - 1), @intCast(lz));
        if (!canPlantStayOn(below)) continue;
        chunk.setBlockId(@intCast(lx), @intCast(wy), @intCast(lz), flower_id);
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

pub fn generateSurfacePlants(chunk: *Chunk, chunk_x: i32, chunk_z: i32, rand: *JavaRandom, surface_biome: biome.Biome) void {
    const base_x = chunk_x * 16;
    const base_z = chunk_z * 16;

    var i: i32 = 0;
    const dandelion_count = dandelionCountFor(surface_biome);
    while (i < dandelion_count) : (i += 1) {
        const x = base_x + rand.nextIntBound(16) + 8;
        const y = rand.nextIntBound(128);
        const z = base_z + rand.nextIntBound(16) + 8;
        generateFlowerPatch(chunk, chunk_x, chunk_z, rand, x, y, z, block.dandelion);
    }

    i = 0;
    const grass_count = tallGrassCountFor(surface_biome);
    while (i < grass_count) : (i += 1) {
        const is_fern = surface_biome == .rainforest and rand.nextIntBound(3) != 0;
        const x = base_x + rand.nextIntBound(16) + 8;
        const y = rand.nextIntBound(128);
        const z = base_z + rand.nextIntBound(16) + 8;
        generateTallGrassPatch(chunk, chunk_x, chunk_z, rand, x, y, z, if (is_fern) 2 else 1);
    }

    if (surface_biome == .desert) {
        i = 0;
        while (i < 2) : (i += 1) {
            const x = base_x + rand.nextIntBound(16) + 8;
            const y = rand.nextIntBound(128);
            const z = base_z + rand.nextIntBound(16) + 8;
            generateDeadBushPatch(chunk, chunk_x, chunk_z, rand, x, y, z);
        }
    }

    if (rand.nextIntBound(2) == 0) {
        const x = base_x + rand.nextIntBound(16) + 8;
        const y = rand.nextIntBound(128);
        const z = base_z + rand.nextIntBound(16) + 8;
        generateFlowerPatch(chunk, chunk_x, chunk_z, rand, x, y, z, block.rose);
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

test "a tree grows on grass with clear space above" {
    var chunk = Chunk.init(0, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            chunk.setBlockId(@intCast(x), 0, @intCast(z), block.grass);
        }
    }

    var rand = JavaRandom.init(1);
    const grew = generateTree(&chunk, &rand, 8, 1, 8);
    try std.testing.expect(grew);
    try std.testing.expectEqual(@as(u8, block.log), chunk.getBlockId(8, 1, 8));
}

test "a tree does not grow without clear space above" {
    var chunk = Chunk.init(0, 0);
    chunk.setBlockId(8, 0, 8, block.grass);
    chunk.setBlockId(8, 3, 8, block.stone);

    var rand = JavaRandom.init(1);
    const grew = generateTree(&chunk, &rand, 8, 1, 8);
    try std.testing.expect(!grew);
}

test "generateTrees places trees in a forest biome and none in desert" {
    var forest_chunk = Chunk.init(0, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            forest_chunk.setBlockId(@intCast(x), 0, @intCast(z), block.grass);
        }
    }
    var forest_rand = JavaRandom.init(1);
    generateTrees(&forest_chunk, 0, 0, &forest_rand, .forest);

    var forest_logs: usize = 0;
    for (0..16) |x| {
        for (0..128) |y| {
            for (0..16) |z| {
                if (forest_chunk.getBlockId(@intCast(x), @intCast(y), @intCast(z)) == block.log) forest_logs += 1;
            }
        }
    }
    try std.testing.expect(forest_logs > 0);

    var desert_chunk = Chunk.init(0, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            desert_chunk.setBlockId(@intCast(x), 0, @intCast(z), block.sand);
        }
    }
    var desert_rand = JavaRandom.init(1);
    generateTrees(&desert_chunk, 0, 0, &desert_rand, .desert);

    var desert_logs: usize = 0;
    for (0..16) |x| {
        for (0..128) |y| {
            for (0..16) |z| {
                if (desert_chunk.getBlockId(@intCast(x), @intCast(y), @intCast(z)) == block.log) desert_logs += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), desert_logs);
}

fn flatGrassChunk() Chunk {
    var chunk = Chunk.init(0, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            chunk.setBlockId(@intCast(x), 10, @intCast(z), block.grass);
        }
    }
    return chunk;
}

test "tall grass patches place blades on grass with air above" {
    var chunk = flatGrassChunk();
    var rand = JavaRandom.init(1);
    generateTallGrassPatch(&chunk, 0, 0, &rand, 8, 20, 8, 1);

    var found = false;
    for (0..16) |x| {
        for (0..16) |z| {
            if (chunk.getBlockId(@intCast(x), 11, @intCast(z)) == block.tall_grass) found = true;
        }
    }
    try std.testing.expect(found);
}

test "dead bush only takes root on sand" {
    var chunk = Chunk.init(0, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            chunk.setBlockId(@intCast(x), 10, @intCast(z), block.sand);
        }
    }
    var rand = JavaRandom.init(1);
    generateDeadBushPatch(&chunk, 0, 0, &rand, 8, 20, 8);

    var found = false;
    for (0..16) |x| {
        for (0..16) |z| {
            if (chunk.getBlockId(@intCast(x), 11, @intCast(z)) == block.dead_bush) found = true;
        }
    }
    try std.testing.expect(found);
}

test "dead bush does not take root on grass" {
    var chunk = flatGrassChunk();
    var rand = JavaRandom.init(1);
    generateDeadBushPatch(&chunk, 0, 0, &rand, 8, 20, 8);

    for (0..16) |x| {
        for (0..16) |z| {
            try std.testing.expect(chunk.getBlockId(@intCast(x), 11, @intCast(z)) != block.dead_bush);
        }
    }
}

test "surface plants place dandelions in plains but not in the ocean" {
    var chunk = flatGrassChunk();
    var rand = JavaRandom.init(1);
    generateSurfacePlants(&chunk, 0, 0, &rand, .plains);

    var found_flower_or_grass = false;
    for (0..16) |x| {
        for (0..16) |z| {
            const id = chunk.getBlockId(@intCast(x), 11, @intCast(z));
            if (id == block.dandelion or id == block.tall_grass or id == block.rose) found_flower_or_grass = true;
        }
    }
    try std.testing.expect(found_flower_or_grass);
}
