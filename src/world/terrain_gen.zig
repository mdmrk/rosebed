const std = @import("std");
const JavaRandom = @import("java_random.zig");
const NoiseGeneratorOctaves = @import("noise_octaves.zig");
const Chunk = @import("chunk.zig");
const block = @import("block.zig");
const Climate = @import("climate.zig");
const biome = @import("biome.zig");
const caves = @import("caves.zig");

const TerrainGenerator = @This();

main_noise: NoiseGeneratorOctaves,
upper_noise: NoiseGeneratorOctaves,
blend_noise: NoiseGeneratorOctaves,
scale_noise: NoiseGeneratorOctaves,
depth_noise: NoiseGeneratorOctaves,
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
    return .{
        .main_noise = try NoiseGeneratorOctaves.init(gpa, &rand, 16),
        .upper_noise = try NoiseGeneratorOctaves.init(gpa, &rand, 16),
        .blend_noise = try NoiseGeneratorOctaves.init(gpa, &rand, 8),
        .scale_noise = try NoiseGeneratorOctaves.init(gpa, &rand, 10),
        .depth_noise = try NoiseGeneratorOctaves.init(gpa, &rand, 16),
        .climate = try Climate.init(gpa, seed),
        .world_seed = seed,
    };
}

pub fn deinit(self: TerrainGenerator, gpa: std.mem.Allocator) void {
    self.main_noise.deinit(gpa);
    self.upper_noise.deinit(gpa);
    self.blend_noise.deinit(gpa);
    self.scale_noise.deinit(gpa);
    self.depth_noise.deinit(gpa);
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

pub fn generateChunk(self: TerrainGenerator, chunk_x: i32, chunk_z: i32) Chunk {
    var chunk = Chunk.init(chunk_x, chunk_z);

    const climate_sample = self.climate.sample(chunk_x * Climate.grid_size, chunk_z * Climate.grid_size);

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
                            var id: u8 = block.air;
                            if (by < sea_level) {
                                id = block.stationary_water;
                            }
                            if (value > 0.0) {
                                id = block.stone;
                            }
                            chunk.setBlockId(bx, by, bz, id);
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

    dressSurface(&chunk, &climate_sample);
    caves.carve(&chunk, chunk_x, chunk_z, self.world_seed);
    return chunk;
}

fn dressSurface(chunk: *Chunk, climate_sample: *const Climate.Sample) void {
    for (0..16) |x| {
        for (0..16) |z| {
            const surface_biome = climate_sample.biomeAt(x, z);
            const top_block = surface_biome.topBlock();
            const filler_block = surface_biome.fillerBlock();

            var y: u32 = 127;
            while (y > 0) : (y -= 1) {
                if (chunk.getBlockId(@intCast(x), y, @intCast(z)) == block.stone) {
                    chunk.setBlockId(@intCast(x), y, @intCast(z), top_block);
                    if (y > 0) chunk.setBlockId(@intCast(x), y - 1, @intCast(z), filler_block);
                    if (y > 1) chunk.setBlockId(@intCast(x), y - 2, @intCast(z), filler_block);
                    if (y > 2) chunk.setBlockId(@intCast(x), y - 3, @intCast(z), filler_block);
                    break;
                }
            }
            for (0..5) |by| {
                chunk.setBlockId(@intCast(x), @intCast(by), @intCast(z), block.bedrock);
            }
        }
    }
}

test "generated chunk has bedrock at the bottom and grass somewhere" {
    const gpa = std.testing.allocator;
    const gen = try TerrainGenerator.init(gpa, 12345);
    defer gen.deinit(gpa);

    const chunk = gen.generateChunk(0, 0);

    try std.testing.expectEqual(@as(u8, block.bedrock), chunk.getBlockId(8, 0, 8));

    var found_grass = false;
    for (0..16) |x| {
        for (0..16) |z| {
            for (0..128) |y| {
                if (chunk.getBlockId(@intCast(x), @intCast(y), @intCast(z)) == block.grass) {
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

    const chunk_a = gen_a.generateChunk(0, 0);
    const chunk_b = gen_b.generateChunk(0, 0);

    var any_different = false;
    for (0..16) |x| {
        for (0..128) |y| {
            for (0..16) |z| {
                if (chunk_a.getBlockId(@intCast(x), @intCast(y), @intCast(z)) != chunk_b.getBlockId(@intCast(x), @intCast(y), @intCast(z))) {
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

    const chunk_a = gen.generateChunk(3, -2);
    const chunk_b = gen.generateChunk(3, -2);

    for (0..16) |x| {
        for (0..128) |y| {
            for (0..16) |z| {
                try std.testing.expectEqual(
                    chunk_a.getBlockId(@intCast(x), @intCast(y), @intCast(z)),
                    chunk_b.getBlockId(@intCast(x), @intCast(y), @intCast(z)),
                );
            }
        }
    }
}
