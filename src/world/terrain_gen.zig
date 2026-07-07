const std = @import("std");
const JavaRandom = @import("java_random.zig");
const NoiseGeneratorOctaves = @import("noise_octaves.zig");
const Chunk = @import("chunk.zig");
const block = @import("block.zig");
const Climate = @import("climate.zig");
const biome = @import("biome.zig");
const caves = @import("caves.zig");
const decorate = @import("decorate.zig");
const lakes = @import("lakes.zig");
const springs = @import("springs.zig");
const dungeons = @import("dungeons.zig");
const World = @import("world_map.zig");
const Block = @import("block.zig").Block;

const TerrainGenerator = @This();

main_noise: NoiseGeneratorOctaves,
upper_noise: NoiseGeneratorOctaves,
blend_noise: NoiseGeneratorOctaves,
surface_noise: NoiseGeneratorOctaves,
depth_variation_noise: NoiseGeneratorOctaves,
scale_noise: NoiseGeneratorOctaves,
depth_noise: NoiseGeneratorOctaves,
tree_noise: NoiseGeneratorOctaves,
climate: Climate,
world_seed: i64,

const sea_level: i32 = 64;
const density_x = 5;
const density_y = 17;
const density_z = 5;
const horizontal_cells = 4;
const vertical_cells = 16;
const climate_downsample_step = Climate.grid_size / density_x;

pub fn init(gpa: std.mem.Allocator, seed: i64) !TerrainGenerator {
    var rand = JavaRandom.init(seed);
    const main_noise = try NoiseGeneratorOctaves.init(gpa, &rand, 16);
    const upper_noise = try NoiseGeneratorOctaves.init(gpa, &rand, 16);
    const blend_noise = try NoiseGeneratorOctaves.init(gpa, &rand, 8);
    const surface_noise = try NoiseGeneratorOctaves.init(gpa, &rand, 4);
    const depth_variation_noise = try NoiseGeneratorOctaves.init(gpa, &rand, 4);
    const scale_noise = try NoiseGeneratorOctaves.init(gpa, &rand, 10);
    const depth_noise = try NoiseGeneratorOctaves.init(gpa, &rand, 16);
    const tree_noise = try NoiseGeneratorOctaves.init(gpa, &rand, 8);
    return .{
        .main_noise = main_noise,
        .upper_noise = upper_noise,
        .blend_noise = blend_noise,
        .surface_noise = surface_noise,
        .depth_variation_noise = depth_variation_noise,
        .scale_noise = scale_noise,
        .depth_noise = depth_noise,
        .tree_noise = tree_noise,
        .climate = try Climate.init(gpa, seed),
        .world_seed = seed,
    };
}

pub fn deinit(self: TerrainGenerator, gpa: std.mem.Allocator) void {
    self.main_noise.deinit(gpa);
    self.upper_noise.deinit(gpa);
    self.blend_noise.deinit(gpa);
    self.surface_noise.deinit(gpa);
    self.depth_variation_noise.deinit(gpa);
    self.scale_noise.deinit(gpa);
    self.depth_noise.deinit(gpa);
    self.tree_noise.deinit(gpa);
    self.climate.deinit(gpa);
}

fn densityIndex(ix: usize, iz: usize, iy: usize) usize {
    return (ix * density_z + iz) * density_y + iy;
}

fn computeDensityField(self: TerrainGenerator, out: *[density_x * density_y * density_z]f64, x_offset: i32, z_offset: i32, climate_sample: *const Climate.Sample) void {
    const xz_scale = 684.412;
    const fx: f64 = @floatFromInt(x_offset);
    const fz: f64 = @floatFromInt(z_offset);

    var scale_field: [density_x * density_z]f64 = undefined;
    self.scale_noise.generate(&scale_field, .{ .x = fx, .y = 0, .z = fz }, .{ .x = density_x, .y = 1, .z = density_z }, .{ .x = 1.121, .y = 1.0, .z = 1.121 });

    var depth_field: [density_x * density_z]f64 = undefined;
    self.depth_noise.generate(&depth_field, .{ .x = fx, .y = 0, .z = fz }, .{ .x = density_x, .y = 1, .z = density_z }, .{ .x = 200.0, .y = 1.0, .z = 200.0 });

    var main_field: [density_x * density_y * density_z]f64 = undefined;
    self.main_noise.generate(&main_field, .{ .x = fx, .y = 0, .z = fz }, .{ .x = density_x, .y = density_y, .z = density_z }, .{ .x = xz_scale, .y = xz_scale, .z = xz_scale });

    var upper_field: [density_x * density_y * density_z]f64 = undefined;
    self.upper_noise.generate(&upper_field, .{ .x = fx, .y = 0, .z = fz }, .{ .x = density_x, .y = density_y, .z = density_z }, .{ .x = xz_scale, .y = xz_scale, .z = xz_scale });

    var blend_field: [density_x * density_y * density_z]f64 = undefined;
    self.blend_noise.generate(&blend_field, .{ .x = fx, .y = 0, .z = fz }, .{ .x = density_x, .y = density_y, .z = density_z }, .{ .x = xz_scale / 80.0, .y = xz_scale / 160.0, .z = xz_scale / 80.0 });

    for (0..density_x) |ix| {
        for (0..density_z) |iz| {
            const col = ix * density_z + iz;
            const sample_x = ix * climate_downsample_step + climate_downsample_step / 2;
            const sample_z = iz * climate_downsample_step + climate_downsample_step / 2;
            const climate_idx = sample_x * Climate.grid_size + sample_z;
            const temperature = climate_sample.temperature[climate_idx];
            const humidity = climate_sample.humidity[climate_idx];

            var scale = (scale_field[col] + 256.0) / 512.0;
            var weight: f64 = 1.0 - humidity * temperature;
            weight *= weight;
            weight *= weight;
            weight = 1.0 - weight;
            scale *= weight;
            if (scale > 1.0) scale = 1.0;

            var depth = depth_field[col] / 8000.0;
            if (depth < 0.0) depth = -depth * 0.3;
            depth = depth * 3.0 - 2.0;
            if (depth < 0.0) {
                depth /= 2.0;
                if (depth < -1.0) depth = -1.0;
                depth /= 1.4;
                depth /= 2.0;
                scale = 0.0;
            } else {
                if (depth > 1.0) depth = 1.0;
                depth /= 8.0;
            }
            if (scale < 0.0) scale = 0.0;
            scale += 0.5;
            depth = depth * @as(f64, density_y) / 16.0;
            const target_height = @as(f64, density_y) / 2.0 + depth * 4.0;

            for (0..density_y) |iy| {
                var falloff = (@as(f64, @floatFromInt(iy)) - target_height) * 12.0 / scale;
                if (falloff < 0.0) falloff *= 4.0;

                const idx = densityIndex(ix, iz, iy);
                const lower = main_field[idx] / 512.0;
                const upper = upper_field[idx] / 512.0;
                const blend = (blend_field[idx] / 10.0 + 1.0) / 2.0;

                var density: f64 = undefined;
                if (blend < 0.0) {
                    density = lower;
                } else if (blend > 1.0) {
                    density = upper;
                } else {
                    density = lower + (upper - lower) * blend;
                }
                density -= falloff;

                if (iy > density_y - 4) {
                    const t: f64 = @as(f64, @floatFromInt(iy - (density_y - 4))) / 3.0;
                    density = density * (1.0 - t) + -10.0 * t;
                }

                out[idx] = density;
            }
        }
    }
}

pub fn generateShape(self: TerrainGenerator, chunk: *Chunk) void {
    const chunk_x = chunk.x;
    const chunk_z = chunk.z;
    const climate_sample = self.climate.sample(chunk_x * Climate.grid_size, chunk_z * Climate.grid_size);

    for (0..Chunk.width) |x| {
        for (0..Chunk.width) |z| {
            const i = x * Climate.grid_size + z;
            chunk.setClimate(@intCast(x), @intCast(z), @floatCast(climate_sample.temperature[i]), @floatCast(climate_sample.humidity[i]));
        }
    }

    var density: [density_x * density_y * density_z]f64 = undefined;
    self.computeDensityField(&density, chunk_x * horizontal_cells, chunk_z * horizontal_cells, &climate_sample);

    for (0..horizontal_cells) |cx| {
        for (0..horizontal_cells) |cz| {
            for (0..vertical_cells) |cy| {
                var corner_x0z0 = density[densityIndex(cx, cz, cy)];
                var corner_x0z1 = density[densityIndex(cx, cz + 1, cy)];
                var corner_x1z0 = density[densityIndex(cx + 1, cz, cy)];
                var corner_x1z1 = density[densityIndex(cx + 1, cz + 1, cy)];
                const step_x0z0 = (density[densityIndex(cx, cz, cy + 1)] - corner_x0z0) / 8.0;
                const step_x0z1 = (density[densityIndex(cx, cz + 1, cy + 1)] - corner_x0z1) / 8.0;
                const step_x1z0 = (density[densityIndex(cx + 1, cz, cy + 1)] - corner_x1z0) / 8.0;
                const step_x1z1 = (density[densityIndex(cx + 1, cz + 1, cy + 1)] - corner_x1z1) / 8.0;

                for (0..8) |sub_y| {
                    var edge_z0 = corner_x0z0;
                    var edge_z1 = corner_x0z1;
                    const step_edge_z0 = (corner_x1z0 - corner_x0z0) / 4.0;
                    const step_edge_z1 = (corner_x1z1 - corner_x0z1) / 4.0;

                    for (0..4) |sub_x| {
                        const bx: u32 = @intCast(cx * 4 + sub_x);
                        const by: u32 = @intCast(cy * 8 + sub_y);
                        var value = edge_z0;
                        const step_value = (edge_z1 - edge_z0) / 4.0;

                        for (0..4) |sub_z| {
                            const bz: u32 = @intCast(cz * 4 + sub_z);
                            var id: Block = .air;
                            if (by < sea_level) {
                                const temperature = climate_sample.temperature[bx * Climate.grid_size + bz];
                                if (temperature < 0.5 and by >= sea_level - 1) {
                                    id = Block.ice;
                                } else {
                                    id = Block.stationary_water;
                                }
                            }
                            if (value > 0.0) {
                                id = Block.stone;
                            }
                            chunk.setBlock(bx, by, bz, id);
                            value += step_value;
                        }

                        edge_z0 += step_edge_z0;
                        edge_z1 += step_edge_z1;
                    }

                    corner_x0z0 += step_x0z0;
                    corner_x0z1 += step_x0z1;
                    corner_x1z0 += step_x1z0;
                    corner_x1z1 += step_x1z1;
                }
            }
        }
    }

    self.dressSurface(chunk, &climate_sample);
    caves.carve(chunk, chunk_x, chunk_z, self.world_seed);
}

pub fn decorateChunk(self: TerrainGenerator, world_map: *World, chunk_x: i32, chunk_z: i32) !void {
    const surface_biome = self.climate.biomeAt(chunk_x * 16 + 16, chunk_z * 16 + 16);

    var decorate_rand = JavaRandom.init(self.world_seed);
    const mult_x = @divTrunc(decorate_rand.nextLong(), 2) *% 2 +% 1;
    const mult_z = @divTrunc(decorate_rand.nextLong(), 2) *% 2 +% 1;
    const decorate_seed = (@as(i64, chunk_x) *% mult_x +% @as(i64, chunk_z) *% mult_z) ^ self.world_seed;
    decorate_rand.setSeed(decorate_seed);

    const base_x = chunk_x * 16;
    const base_z = chunk_z * 16;

    if (decorate_rand.nextIntBound(4) == 0) {
        const x = base_x + decorate_rand.nextIntBound(16) + 8;
        const y = decorate_rand.nextIntBound(128);
        const z = base_z + decorate_rand.nextIntBound(16) + 8;
        _ = lakes.generate(world_map, &decorate_rand, x, y, z, Block.stationary_water);
    }

    if (decorate_rand.nextIntBound(8) == 0) {
        const x = base_x + decorate_rand.nextIntBound(16) + 8;
        const y = decorate_rand.nextIntBound(decorate_rand.nextIntBound(120) + 8);
        const z = base_z + decorate_rand.nextIntBound(16) + 8;
        if (y < 64 or decorate_rand.nextIntBound(10) == 0) {
            _ = lakes.generate(world_map, &decorate_rand, x, y, z, Block.flowing_lava);
        }
    }

    for (0..8) |_| {
        const x = base_x + decorate_rand.nextIntBound(16) + 8;
        const y = decorate_rand.nextIntBound(128);
        const z = base_z + decorate_rand.nextIntBound(16) + 8;
        _ = dungeons.generate(world_map, &decorate_rand, x, y, z);
    }

    decorate.generateClayPatches(world_map, chunk_x, chunk_z, &decorate_rand);
    decorate.generateOreVeins(world_map, chunk_x, chunk_z, &decorate_rand);

    const tree_density = self.tree_noise.samplePoint2D(@as(f64, @floatFromInt(base_x)) * 0.5, @as(f64, @floatFromInt(base_z)) * 0.5);
    const tree_count = decorate.treeCountFor(&decorate_rand, tree_density, surface_biome);
    decorate.generateTrees(world_map, chunk_x, chunk_z, &decorate_rand, surface_biome, tree_count);
    decorate.generateSurfacePlants(world_map, chunk_x, chunk_z, &decorate_rand, surface_biome);

    for (0..50) |_| {
        const x = base_x + decorate_rand.nextIntBound(16) + 8;
        const y = decorate_rand.nextIntBound(decorate_rand.nextIntBound(120) + 8);
        const z = base_z + decorate_rand.nextIntBound(16) + 8;
        try springs.generate(world_map, x, y, z, Block.flowing_water);
    }

    for (0..20) |_| {
        const x = base_x + decorate_rand.nextIntBound(16) + 8;
        const y = decorate_rand.nextIntBound(decorate_rand.nextIntBound(decorate_rand.nextIntBound(112) + 8) + 8);
        const z = base_z + decorate_rand.nextIntBound(16) + 8;
        try springs.generate(world_map, x, y, z, Block.flowing_lava);
    }

    const snow_climate = self.climate.sample(base_x + 8, base_z + 8);
    try placeSnowLayers(world_map, base_x, base_z, &snow_climate.temperature);
}

fn findTopSolidBlock(world_map: *const World, x: i32, z: i32) i32 {
    var y: i32 = 127;
    while (y > 0) : (y -= 1) {
        const material = world_map.getBlock(x, y, z).material();
        if (material.isSolid() or material.isLiquid()) return y + 1;
    }
    return -1;
}

fn placeSnowLayers(world_map: *World, base_x: i32, base_z: i32, temperatures: *const [Climate.grid_size * Climate.grid_size]f64) !void {
    const origin_x = base_x + 8;
    const origin_z = base_z + 8;

    var x = origin_x;
    while (x < origin_x + 16) : (x += 1) {
        var z = origin_z;
        while (z < origin_z + 16) : (z += 1) {
            const top_y = findTopSolidBlock(world_map, x, z);
            const climate_idx: usize = @intCast((x - origin_x) * Climate.grid_size + (z - origin_z));
            const altitude_penalty = @as(f64, @floatFromInt(top_y - 64)) / 64.0 * 0.3;
            const temperature = temperatures[climate_idx] - altitude_penalty;
            if (temperature >= 0.5 or top_y <= 0 or top_y >= 128) continue;

            if (world_map.getBlock(x, top_y, z) != Block.air) continue;
            const below = world_map.getBlock(x, top_y - 1, z).material();
            if (!below.isSolid() or below == .ice) continue;

            try world_map.setBlockWithNotify(x, top_y, z, Block.snow_layer);
        }
    }
}

fn dressSurface(self: TerrainGenerator, chunk: *Chunk, climate_sample: *const Climate.Sample) void {
    var rand = JavaRandom.init(@as(i64, chunk.x) *% 341873128712 +% @as(i64, chunk.z) *% 132897987541);

    const noise_scale = 1.0 / 32.0;
    const base_x: f64 = @floatFromInt(chunk.x * 16);
    const base_z: f64 = @floatFromInt(chunk.z * 16);

    var sand_field: [256]f64 = undefined;
    self.surface_noise.generate(&sand_field, .{ .x = base_x, .y = base_z, .z = 0.0 }, .{ .x = 16, .y = 16, .z = 1 }, .{ .x = noise_scale, .y = noise_scale, .z = 1.0 });

    var gravel_field: [256]f64 = undefined;
    self.surface_noise.generate(&gravel_field, .{ .x = base_x, .y = 109.0134, .z = base_z }, .{ .x = 16, .y = 1, .z = 16 }, .{ .x = noise_scale, .y = 1.0, .z = noise_scale });

    var depth_field: [256]f64 = undefined;
    self.depth_variation_noise.generate(&depth_field, .{ .x = base_x, .y = base_z, .z = 0.0 }, .{ .x = 16, .y = 16, .z = 1 }, .{ .x = noise_scale * 2.0, .y = noise_scale * 2.0, .z = noise_scale * 2.0 });

    for (0..16) |x| {
        for (0..16) |z| {
            const surface_biome = climate_sample.biomeAt(x, z);
            const noise_index = x + z * 16;
            const sandy = sand_field[noise_index] + rand.nextDouble() * 0.2 > 0.0;
            const gravelly = gravel_field[noise_index] + rand.nextDouble() * 0.2 > 3.0;
            const surface_depth: i32 = @intFromFloat(depth_field[noise_index] / 3.0 + 3.0 + rand.nextDouble() * 0.25);

            var remaining_filler: i32 = -1;
            var top_block = surface_biome.topBlock();
            var filler_block = surface_biome.fillerBlock();

            var y: i32 = 127;
            while (y >= 0) : (y -= 1) {
                if (y <= rand.nextIntBound(5)) {
                    chunk.setBlock(@intCast(x), @intCast(y), @intCast(z), Block.bedrock);
                    continue;
                }

                const current = chunk.getBlock(@intCast(x), @intCast(y), @intCast(z));
                if (current == Block.air) {
                    remaining_filler = -1;
                    continue;
                }
                if (current != Block.stone) continue;

                if (remaining_filler == -1) {
                    if (surface_depth <= 0) {
                        top_block = Block.air;
                        filler_block = Block.stone;
                    } else if (y >= sea_level - 4 and y <= sea_level + 1) {
                        top_block = surface_biome.topBlock();
                        filler_block = surface_biome.fillerBlock();
                        if (gravelly) {
                            top_block = Block.air;
                            filler_block = Block.gravel;
                        }
                        if (sandy) {
                            top_block = Block.sand;
                            filler_block = Block.sand;
                        }
                    }

                    if (y < sea_level and top_block == Block.air) top_block = Block.stationary_water;

                    remaining_filler = surface_depth;
                    const placed = if (y >= sea_level - 1) top_block else filler_block;
                    chunk.setBlock(@intCast(x), @intCast(y), @intCast(z), placed);
                } else if (remaining_filler > 0) {
                    remaining_filler -= 1;
                    chunk.setBlock(@intCast(x), @intCast(y), @intCast(z), filler_block);
                    if (remaining_filler == 0 and filler_block == Block.sand) {
                        remaining_filler = rand.nextIntBound(4);
                        filler_block = Block.sandstone;
                    }
                }
            }
        }
    }
}

fn grassPlateauWorld() !World {
    var w = World.init(std.testing.allocator);
    var chunk_x: i32 = 0;
    while (chunk_x <= 1) : (chunk_x += 1) {
        var chunk_z: i32 = 0;
        while (chunk_z <= 1) : (chunk_z += 1) {
            const chunk = try w.createChunk(chunk_x, chunk_z);
            for (0..16) |x| {
                for (0..16) |z| {
                    chunk.setBlock(@intCast(x), 70, @intCast(z), Block.grass);
                }
            }
        }
    }
    return w;
}

fn uniformTemperatures(value: f64) [Climate.grid_size * Climate.grid_size]f64 {
    return [_]f64{value} ** (Climate.grid_size * Climate.grid_size);
}

test "snow layers form on solid ground in cold climates but not warm ones" {
    var cold_world = try grassPlateauWorld();
    defer cold_world.deinit();
    const cold = uniformTemperatures(0.1);
    try placeSnowLayers(&cold_world, 0, 0, &cold);

    var found_snow = false;
    for (8..24) |x| {
        for (8..24) |z| {
            if (cold_world.getBlock(@intCast(x), 71, @intCast(z)) == Block.snow_layer) found_snow = true;
        }
    }
    try std.testing.expect(found_snow);

    var warm_world = try grassPlateauWorld();
    defer warm_world.deinit();
    const warm = uniformTemperatures(0.9);
    try placeSnowLayers(&warm_world, 0, 0, &warm);

    for (8..24) |x| {
        for (8..24) |z| {
            try std.testing.expect(warm_world.getBlock(@intCast(x), 71, @intCast(z)) != Block.snow_layer);
        }
    }
}

test "the snow pass covers the 16x16 area starting eight blocks into the chunk" {
    var w = try grassPlateauWorld();
    defer w.deinit();
    const cold = uniformTemperatures(0.1);
    try placeSnowLayers(&w, 0, 0, &cold);

    for (8..24) |x| {
        for (8..24) |z| {
            try std.testing.expectEqual(Block.snow_layer, w.getBlock(@intCast(x), 71, @intCast(z)));
        }
    }
    try std.testing.expectEqual(Block.air, w.getBlock(7, 71, 8));
    try std.testing.expectEqual(Block.air, w.getBlock(8, 71, 7));
    try std.testing.expectEqual(Block.air, w.getBlock(24, 71, 24));
}

test "snow does not settle on ice" {
    var w = try grassPlateauWorld();
    defer w.deinit();
    w.setBlock(12, 70, 12, Block.ice);

    const cold = uniformTemperatures(0.1);
    try placeSnowLayers(&w, 0, 0, &cold);

    try std.testing.expectEqual(Block.air, w.getBlock(12, 71, 12));
    try std.testing.expectEqual(Block.snow_layer, w.getBlock(13, 71, 12));
}

fn uniformClimate(temperature: f64, humidity: f64) Climate.Sample {
    var sample: Climate.Sample = undefined;
    for (0..Climate.grid_size * Climate.grid_size) |i| {
        sample.temperature[i] = temperature;
        sample.humidity[i] = humidity;
    }
    return sample;
}

test "surface dressing lays sandstone under a desert's sand" {
    const gpa = std.testing.allocator;
    const gen = try TerrainGenerator.init(gpa, 4242);
    defer gen.deinit(gpa);

    var chunk = Chunk.init(0, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            for (0..81) |y| {
                chunk.setBlock(@intCast(x), @intCast(y), @intCast(z), Block.stone);
            }
        }
    }

    const desert = uniformClimate(0.99, 0.05);
    try std.testing.expectEqual(biome.Biome.desert, desert.biomeAt(0, 0));
    gen.dressSurface(&chunk, &desert);

    try std.testing.expectEqual(Block.sand, chunk.getBlock(8, 80, 8));

    var found_sandstone = false;
    for (0..16) |x| {
        for (0..16) |z| {
            var y: u32 = 79;
            while (y > 5) : (y -= 1) {
                if (chunk.getBlock(@intCast(x), y, @intCast(z)) == Block.sandstone) found_sandstone = true;
            }
        }
    }
    try std.testing.expect(found_sandstone);
}

test "surface dressing stops the stone column with a jagged bedrock floor" {
    const gpa = std.testing.allocator;
    const gen = try TerrainGenerator.init(gpa, 4242);
    defer gen.deinit(gpa);

    var chunk = Chunk.init(0, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            for (0..81) |y| {
                chunk.setBlock(@intCast(x), @intCast(y), @intCast(z), Block.stone);
            }
        }
    }

    const plains = uniformClimate(0.99, 0.4);
    gen.dressSurface(&chunk, &plains);

    var lowest_top: u32 = 127;
    var highest_top: u32 = 0;
    for (0..16) |x| {
        for (0..16) |z| {
            try std.testing.expectEqual(Block.bedrock, chunk.getBlock(@intCast(x), 0, @intCast(z)));

            var top: u32 = 0;
            var y: u32 = 0;
            while (y < 8) : (y += 1) {
                if (chunk.getBlock(@intCast(x), y, @intCast(z)) == Block.bedrock) top = y;
            }
            try std.testing.expect(top <= 4);
            lowest_top = @min(lowest_top, top);
            highest_top = @max(highest_top, top);
        }
    }
    try std.testing.expect(lowest_top < highest_top);
}

test "generated chunk has bedrock at the bottom and grass somewhere" {
    const gpa = std.testing.allocator;
    const gen = try TerrainGenerator.init(gpa, 12345);
    defer gen.deinit(gpa);

    var w = World.init(gpa);
    defer w.deinit();
    const chunk = try w.getOrGenerateChunk(gen, 0, 0);

    try std.testing.expectEqual(Block.bedrock, chunk.getBlock(8, 0, 8));

    var found_grass = false;
    for (0..16) |x| {
        for (0..16) |z| {
            for (0..128) |y| {
                if (chunk.getBlock(@intCast(x), @intCast(y), @intCast(z)) == Block.grass) {
                    found_grass = true;
                }
            }
        }
    }
    try std.testing.expect(found_grass);
}

test "different seeds produce different terrain" {
    const gpa = std.testing.allocator;
    const gen_a = try TerrainGenerator.init(gpa, 1);
    defer gen_a.deinit(gpa);
    const gen_b = try TerrainGenerator.init(gpa, 2);
    defer gen_b.deinit(gpa);

    var w_a = World.init(gpa);
    defer w_a.deinit();
    var w_b = World.init(gpa);
    defer w_b.deinit();
    const chunk_a = try w_a.getOrGenerateChunk(gen_a, 0, 0);
    const chunk_b = try w_b.getOrGenerateChunk(gen_b, 0, 0);

    var any_different = false;
    for (0..16) |x| {
        for (0..128) |y| {
            for (0..16) |z| {
                if (chunk_a.getBlock(@intCast(x), @intCast(y), @intCast(z)) != chunk_b.getBlock(@intCast(x), @intCast(y), @intCast(z))) {
                    any_different = true;
                }
            }
        }
    }
    try std.testing.expect(any_different);
}

test "the same seed and chunk position are deterministic" {
    const gpa = std.testing.allocator;
    const gen = try TerrainGenerator.init(gpa, 777);
    defer gen.deinit(gpa);

    var w_a = World.init(gpa);
    defer w_a.deinit();
    var w_b = World.init(gpa);
    defer w_b.deinit();
    const chunk_a = try w_a.getOrGenerateChunk(gen, 3, -2);
    const chunk_b = try w_b.getOrGenerateChunk(gen, 3, -2);

    for (0..16) |x| {
        for (0..128) |y| {
            for (0..16) |z| {
                try std.testing.expectEqual(
                    chunk_a.getBlock(@intCast(x), @intCast(y), @intCast(z)),
                    chunk_b.getBlock(@intCast(x), @intCast(y), @intCast(z)),
                );
            }
        }
    }
}


test "a cold ocean freezes over at sea level" {
    const gpa = std.testing.allocator;
    const gen = try TerrainGenerator.init(gpa, 777);
    defer gen.deinit(gpa);

    var w = World.init(gpa);
    defer w.deinit();
    const chunk = try w.getOrGenerateChunk(gen, -12, -12);

    for (0..16) |x| {
        for (0..16) |z| {
            try std.testing.expect(chunk.getTemperature(@intCast(x), @intCast(z)) < 0.5);
            try std.testing.expectEqual(Block.ice, chunk.getBlock(@intCast(x), 63, @intCast(z)));
            try std.testing.expectEqual(Block.stationary_water, chunk.getBlock(@intCast(x), 62, @intCast(z)));
        }
    }
}

test "a warm ocean keeps water at sea level" {
    const gpa = std.testing.allocator;
    const gen = try TerrainGenerator.init(gpa, 1);
    defer gen.deinit(gpa);

    var w = World.init(gpa);
    defer w.deinit();
    const chunk = try w.getOrGenerateChunk(gen, 0, 0);

    for (0..16) |x| {
        for (0..16) |z| {
            try std.testing.expect(chunk.getBlock(@intCast(x), 63, @intCast(z)) != Block.ice);
        }
    }
}
