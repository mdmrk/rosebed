const std = @import("std");

const Block = @import("../block.zig").Block;
const BlockPos = @import("../BlockPos.zig");
const Chunk = @import("../Chunk.zig");
const JavaRandom = @import("../JavaRandom.zig");
const World = @import("../World.zig");
const caves = @import("caves.zig");
const Climate = @import("Climate.zig");
const decorate = @import("decorate.zig");
const density = @import("density.zig");
const density_x = density.size_x;
const density_y = density.size_y;
const density_z = density.size_z;
const densityIndex = density.index;
const PerlinOctaves = @import("PerlinOctaves.zig");
const springs = @import("springs.zig");

const NetherGenerator = @This();

main_noise: PerlinOctaves,
upper_noise: PerlinOctaves,
blend_noise: PerlinOctaves,
surface_noise: PerlinOctaves,
depth_variation_noise: PerlinOctaves,
scale_noise: PerlinOctaves,
depth_noise: PerlinOctaves,
rand: JavaRandom,
world_seed: i64,

pub const temperature: f64 = 1.0;
pub const humidity: f64 = 0.0;

const lava_level: u32 = 32;
const surface_level: i32 = 64;

pub fn init(gpa: std.mem.Allocator, seed: i64) !NetherGenerator {
    var rand = JavaRandom.init(seed);
    const main_noise = try PerlinOctaves.init(gpa, &rand, 16);
    const upper_noise = try PerlinOctaves.init(gpa, &rand, 16);
    const blend_noise = try PerlinOctaves.init(gpa, &rand, 8);
    const surface_noise = try PerlinOctaves.init(gpa, &rand, 4);
    const depth_variation_noise = try PerlinOctaves.init(gpa, &rand, 4);
    const scale_noise = try PerlinOctaves.init(gpa, &rand, 10);
    const depth_noise = try PerlinOctaves.init(gpa, &rand, 16);
    return .{
        .main_noise = main_noise,
        .upper_noise = upper_noise,
        .blend_noise = blend_noise,
        .surface_noise = surface_noise,
        .depth_variation_noise = depth_variation_noise,
        .scale_noise = scale_noise,
        .depth_noise = depth_noise,
        .rand = JavaRandom.init(seed),
        .world_seed = seed,
    };
}

pub fn deinit(self: NetherGenerator, gpa: std.mem.Allocator) void {
    self.main_noise.deinit(gpa);
    self.upper_noise.deinit(gpa);
    self.blend_noise.deinit(gpa);
    self.surface_noise.deinit(gpa);
    self.depth_variation_noise.deinit(gpa);
    self.scale_noise.deinit(gpa);
    self.depth_noise.deinit(gpa);
}

pub fn sampleClimate(_: NetherGenerator, _: i32, _: i32) Climate.Sample {
    return .{
        .temperature = @splat(temperature),
        .humidity = @splat(humidity),
    };
}

fn pillarProfile() [density_y]f64 {
    var out: [density_y]f64 = undefined;
    for (&out, 0..) |*entry, iy| {
        entry.* = @cos(@as(f64, @floatFromInt(iy)) * std.math.pi * 6.0 / @as(f64, density_y)) * 2.0;

        var edge: f64 = @floatFromInt(iy);
        if (iy > density_y / 2) edge = @floatFromInt(density_y - 1 - iy);
        if (edge < 4.0) {
            edge = 4.0 - edge;
            entry.* -= edge * edge * edge * 10.0;
        }
    }
    return out;
}

fn computeDensityField(self: NetherGenerator, out: *[density_x * density_y * density_z]f64, x_offset: i32, z_offset: i32) void {
    const xz_scale = 684.412;
    const y_scale = 2053.236;
    const fx: f64 = @floatFromInt(x_offset);
    const fz: f64 = @floatFromInt(z_offset);

    var blend_field: [density_x * density_y * density_z]f64 = undefined;
    self.blend_noise.generate(&blend_field, .{ .x = fx, .y = 0, .z = fz }, .{ .x = density_x, .y = density_y, .z = density_z }, .{ .x = xz_scale / 80.0, .y = y_scale / 60.0, .z = xz_scale / 80.0 });

    var main_field: [density_x * density_y * density_z]f64 = undefined;
    self.main_noise.generate(&main_field, .{ .x = fx, .y = 0, .z = fz }, .{ .x = density_x, .y = density_y, .z = density_z }, .{ .x = xz_scale, .y = y_scale, .z = xz_scale });

    var upper_field: [density_x * density_y * density_z]f64 = undefined;
    self.upper_noise.generate(&upper_field, .{ .x = fx, .y = 0, .z = fz }, .{ .x = density_x, .y = density_y, .z = density_z }, .{ .x = xz_scale, .y = y_scale, .z = xz_scale });

    const pillar = pillarProfile();

    for (0..density_x) |ix| {
        for (0..density_z) |iz| {
            for (0..density_y) |iy| {
                const idx = densityIndex(ix, iz, iy);
                var value = density.blend(main_field[idx], upper_field[idx], blend_field[idx]);
                value -= pillar[iy];

                if (iy > density_y - 4) {
                    const ramp: f32 = @as(f32, @floatFromInt(iy - (density_y - 4))) / 3.0;
                    const t: f64 = ramp;
                    value = value * (1.0 - t) + -10.0 * t;
                }

                out[idx] = value;
            }
        }
    }
}

const Picker = struct {
    pub fn pick(_: Picker, bx: u32, by: u32, bz: u32, value: f64) Block {
        _ = bx;
        _ = bz;
        if (value > 0.0) return .netherrack;
        return if (by < lava_level) .stationary_lava else .air;
    }
};

pub fn generateShape(self: *NetherGenerator, chunk: *Chunk) void {
    self.rand.setSeed(@as(i64, chunk.x) *% 341873128712 +% @as(i64, chunk.z) *% 132897987541);

    for (0..Chunk.width) |x| {
        for (0..Chunk.width) |z| {
            chunk.setClimate(@intCast(x), @intCast(z), @floatCast(temperature), @floatCast(humidity));
        }
    }

    var field: density.Field = undefined;
    self.computeDensityField(&field, chunk.x * density.cells_xz, chunk.z * density.cells_xz);

    density.fill(chunk, &field, Picker{});

    self.dressSurface(chunk);
    caves.carve(.nether, chunk, chunk.x, chunk.z, self.world_seed);
}

fn dressSurface(self: *NetherGenerator, chunk: *Chunk) void {
    const noise_scale = 1.0 / 32.0;
    const base_x: f64 = @floatFromInt(chunk.x * 16);
    const base_z: f64 = @floatFromInt(chunk.z * 16);

    var soul_field: [256]f64 = undefined;
    self.surface_noise.generate(&soul_field, .{ .x = base_x, .y = base_z, .z = 0.0 }, .{ .x = 16, .y = 16, .z = 1 }, .{ .x = noise_scale, .y = noise_scale, .z = 1.0 });

    var gravel_field: [256]f64 = undefined;
    self.surface_noise.generate(&gravel_field, .{ .x = base_x, .y = 109.0134, .z = base_z }, .{ .x = 16, .y = 1, .z = 16 }, .{ .x = noise_scale, .y = 1.0, .z = noise_scale });

    var depth_field: [256]f64 = undefined;
    self.depth_variation_noise.generate(&depth_field, .{ .x = base_x, .y = base_z, .z = 0.0 }, .{ .x = 16, .y = 16, .z = 1 }, .{ .x = noise_scale * 2.0, .y = noise_scale * 2.0, .z = noise_scale * 2.0 });

    for (0..16) |z| {
        for (0..16) |x| {
            const noise_index = x * 16 + z;
            const soulish = soul_field[noise_index] + self.rand.nextDouble() * 0.2 > 0.0;
            const gravelly = gravel_field[noise_index] + self.rand.nextDouble() * 0.2 > 0.0;
            const surface_depth: i32 = @intFromFloat(depth_field[noise_index] / 3.0 + 3.0 + self.rand.nextDouble() * 0.25);

            var remaining_filler: i32 = -1;
            var top_block: Block = .netherrack;
            var filler_block: Block = .netherrack;

            var y: i32 = 127;
            while (y >= 0) : (y -= 1) {
                if (y >= 127 - self.rand.nextIntBound(5)) {
                    chunk.setBlock(@intCast(x), @intCast(y), @intCast(z), .bedrock);
                    continue;
                }
                if (y <= self.rand.nextIntBound(5)) {
                    chunk.setBlock(@intCast(x), @intCast(y), @intCast(z), .bedrock);
                    continue;
                }

                const current = chunk.getBlock(@intCast(x), @intCast(y), @intCast(z));
                if (current == .air) {
                    remaining_filler = -1;
                    continue;
                }
                if (current != .netherrack) continue;

                if (remaining_filler == -1) {
                    if (surface_depth <= 0) {
                        top_block = .air;
                        filler_block = .netherrack;
                    } else if (y >= surface_level - 4 and y <= surface_level + 1) {
                        top_block = .netherrack;
                        filler_block = .netherrack;
                        if (gravelly) {
                            top_block = .gravel;
                            filler_block = .netherrack;
                        }
                        if (soulish) {
                            top_block = .soul_sand;
                            filler_block = .soul_sand;
                        }
                    }

                    if (y < surface_level and top_block == .air) top_block = .stationary_lava;

                    remaining_filler = surface_depth;
                    const placed = if (y >= surface_level - 1) top_block else filler_block;
                    chunk.setBlock(@intCast(x), @intCast(y), @intCast(z), placed);
                } else if (remaining_filler > 0) {
                    remaining_filler -= 1;
                    chunk.setBlock(@intCast(x), @intCast(y), @intCast(z), filler_block);
                }
            }
        }
    }
}

pub fn decorateChunk(self: *NetherGenerator, world_map: *World, chunk_x: i32, chunk_z: i32) !void {
    const base_x = chunk_x * 16;
    const base_z = chunk_z * 16;

    for (0..8) |_| {
        const x = base_x + self.rand.nextIntBound(16) + 8;
        const y = self.rand.nextIntBound(120) + 4;
        const z = base_z + self.rand.nextIntBound(16) + 8;
        try springs.generateHell(world_map, .init(x, y, z), .flowing_lava);
    }

    var patches = self.rand.nextIntBound(self.rand.nextIntBound(10) + 1) + 1;
    for (0..@intCast(patches)) |_| {
        const x = base_x + self.rand.nextIntBound(16) + 8;
        const y = self.rand.nextIntBound(120) + 4;
        const z = base_z + self.rand.nextIntBound(16) + 8;
        try generateFirePatch(world_map, &self.rand, .init(x, y, z));
    }

    patches = self.rand.nextIntBound(self.rand.nextIntBound(10) + 1);
    for (0..@intCast(patches)) |_| {
        const x = base_x + self.rand.nextIntBound(16) + 8;
        const y = self.rand.nextIntBound(120) + 4;
        const z = base_z + self.rand.nextIntBound(16) + 8;
        try generateGlowstoneCluster(world_map, &self.rand, .init(x, y, z));
    }

    for (0..10) |_| {
        const x = base_x + self.rand.nextIntBound(16) + 8;
        const y = self.rand.nextIntBound(128);
        const z = base_z + self.rand.nextIntBound(16) + 8;
        try generateGlowstoneCluster(world_map, &self.rand, .init(x, y, z));
    }

    // Both mushroom rolls are vanilla's nextInt(1): always 0, but they still draw, so
    // dropping the condition would shift every roll a neighbouring chunk makes after it.
    if (self.rand.nextIntBound(1) == 0) {
        const x = base_x + self.rand.nextIntBound(16) + 8;
        const y = self.rand.nextIntBound(128);
        const z = base_z + self.rand.nextIntBound(16) + 8;
        decorate.generateFlowerPatch(world_map, &self.rand, .init(x, y, z), .mushroom_brown, decorate.mushroomCanStayAt);
    }

    if (self.rand.nextIntBound(1) == 0) {
        const x = base_x + self.rand.nextIntBound(16) + 8;
        const y = self.rand.nextIntBound(128);
        const z = base_z + self.rand.nextIntBound(16) + 8;
        decorate.generateFlowerPatch(world_map, &self.rand, .init(x, y, z), .mushroom_red, decorate.mushroomCanStayAt);
    }
}

fn generateFirePatch(world_map: *World, rand: *JavaRandom, pos: BlockPos) !void {
    for (0..64) |_| {
        const wx = pos.x + rand.nextIntBound(8) - rand.nextIntBound(8);
        const wy = pos.y + rand.nextIntBound(4) - rand.nextIntBound(4);
        const wz = pos.z + rand.nextIntBound(8) - rand.nextIntBound(8);
        if (world_map.getBlock(.init(wx, wy, wz)) != .air) continue;
        if (world_map.getBlock(.init(wx, wy - 1, wz)) != .netherrack) continue;
        try world_map.setBlockWithNotify(.init(wx, wy, wz), .fire);
    }
}

const glowstone_spread_attempts = 1500;

fn generateGlowstoneCluster(world_map: *World, rand: *JavaRandom, pos: BlockPos) !void {
    if (world_map.getBlock(pos) != .air) return;
    if (world_map.getBlock(pos.offset(0, 1, 0)) != .netherrack) return;

    try world_map.setBlockWithNotify(pos, .glowstone);

    for (0..glowstone_spread_attempts) |_| {
        const wx = pos.x + rand.nextIntBound(8) - rand.nextIntBound(8);
        const wy = pos.y - rand.nextIntBound(12);
        const wz = pos.z + rand.nextIntBound(8) - rand.nextIntBound(8);
        if (world_map.getBlock(.init(wx, wy, wz)) != .air) continue;

        var touching: u32 = 0;
        for ([_][3]i32{ .{ -1, 0, 0 }, .{ 1, 0, 0 }, .{ 0, -1, 0 }, .{ 0, 1, 0 }, .{ 0, 0, -1 }, .{ 0, 0, 1 } }) |offset| {
            if (world_map.getBlock(.init(wx + offset[0], wy + offset[1], wz + offset[2])) == .glowstone) touching += 1;
        }
        if (touching != 1) continue;

        try world_map.setBlockWithNotify(.init(wx, wy, wz), .glowstone);
    }
}

fn generatedChunk(gpa: std.mem.Allocator, seed: i64, chunk_x: i32, chunk_z: i32) !struct { gen: NetherGenerator, chunk: Chunk } {
    var gen = try NetherGenerator.init(gpa, seed);
    var chunk = Chunk.init(chunk_x, chunk_z);
    gen.generateShape(&chunk);
    return .{ .gen = gen, .chunk = chunk };
}

test "a generated chunk matches the ChunkProviderHell reference block for block" {
    const gpa = std.testing.allocator;
    var generated = try generatedChunk(gpa, 12345, 0, 0);
    defer generated.gen.deinit(gpa);

    var ids: [16 * 16 * 128]u8 = undefined;
    var at: usize = 0;
    for (0..16) |x| {
        for (0..16) |z| {
            for (0..128) |y| {
                ids[at] = @intFromEnum(generated.chunk.getBlock(@intCast(x), @intCast(y), @intCast(z)));
                at += 1;
            }
        }
    }

    try std.testing.expectEqual(@as(u32, 1303422068), std.hash.Crc32.hash(&ids));
}

test "the nether is sealed by bedrock at both ends, jagged on the inside faces" {
    const gpa = std.testing.allocator;
    var generated = try generatedChunk(gpa, 777, 2, -3);
    defer generated.gen.deinit(gpa);
    const chunk = &generated.chunk;

    var lowest_ceiling: u32 = 127;
    var highest_floor: u32 = 0;
    for (0..16) |x| {
        for (0..16) |z| {
            try std.testing.expectEqual(.bedrock, chunk.getBlock(@intCast(x), 0, @intCast(z)));
            try std.testing.expectEqual(.bedrock, chunk.getBlock(@intCast(x), 127, @intCast(z)));

            var floor: u32 = 0;
            var y: u32 = 0;
            while (y < 8) : (y += 1) {
                if (chunk.getBlock(@intCast(x), y, @intCast(z)) == .bedrock) floor = y;
            }
            var ceiling: u32 = 127;
            y = 127;
            while (y > 119) : (y -= 1) {
                if (chunk.getBlock(@intCast(x), y, @intCast(z)) == .bedrock) ceiling = y;
            }
            try std.testing.expect(floor <= 4);
            try std.testing.expect(ceiling >= 123);
            lowest_ceiling = @min(lowest_ceiling, ceiling);
            highest_floor = @max(highest_floor, floor);
        }
    }
    try std.testing.expect(highest_floor > 0);
    try std.testing.expect(lowest_ceiling < 127);
}

test "the nether is netherrack over a lava sea, with no overworld stone or water" {
    const gpa = std.testing.allocator;
    var generated = try generatedChunk(gpa, 4242, 0, 0);
    defer generated.gen.deinit(gpa);
    const chunk = &generated.chunk;

    var netherrack: usize = 0;
    var lava: usize = 0;
    for (0..16) |x| {
        for (0..16) |z| {
            for (0..128) |y| {
                const id = chunk.getBlock(@intCast(x), @intCast(y), @intCast(z));
                try std.testing.expect(id != .stone);
                try std.testing.expect(id != .stationary_water);
                try std.testing.expect(id != .dirt and id != .grass);
                if (id == .netherrack) netherrack += 1;
                if (id == .stationary_lava) {
                    lava += 1;
                    try std.testing.expect(y < lava_level);
                }
            }
        }
    }
    try std.testing.expect(netherrack > 0);
    try std.testing.expect(lava > 0);
}

fn countBlock(gpa: std.mem.Allocator, seed: i64, chunk_x: i32, chunk_z: i32, wanted: Block) !usize {
    var generated = try generatedChunk(gpa, seed, chunk_x, chunk_z);
    defer generated.gen.deinit(gpa);

    var found: usize = 0;
    for (0..16) |x| {
        for (0..16) |z| {
            for (0..128) |y| {
                if (generated.chunk.getBlock(@intCast(x), @intCast(y), @intCast(z)) == wanted) found += 1;
            }
        }
    }
    return found;
}

test "soul sand and gravel dress the shoreline around y64, as thinly as the reference does" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 49), try countBlock(gpa, 777, 1, 2, .gravel));
    try std.testing.expectEqual(@as(usize, 468), try countBlock(gpa, 909, 2, 1, .soul_sand));
    try std.testing.expectEqual(@as(usize, 0), try countBlock(gpa, 909, 0, 0, .soul_sand));
}

test "the same seed and chunk position generate the same nether" {
    const gpa = std.testing.allocator;
    var first = try generatedChunk(gpa, 55, -4, 9);
    defer first.gen.deinit(gpa);
    var second = try generatedChunk(gpa, 55, -4, 9);
    defer second.gen.deinit(gpa);

    for (0..16) |x| {
        for (0..128) |y| {
            for (0..16) |z| {
                try std.testing.expectEqual(
                    first.chunk.getBlock(@intCast(x), @intCast(y), @intCast(z)),
                    second.chunk.getBlock(@intCast(x), @intCast(y), @intCast(z)),
                );
            }
        }
    }
}

test "every nether column reads as the hot dry climate WorldChunkManagerHell reports" {
    const gpa = std.testing.allocator;
    var generated = try generatedChunk(gpa, 3, 0, 0);
    defer generated.gen.deinit(gpa);

    for (0..16) |x| {
        for (0..16) |z| {
            try std.testing.expectEqual(@as(f32, 1.0), generated.chunk.getTemperature(@intCast(x), @intCast(z)));
            try std.testing.expectEqual(@as(f32, 0.0), generated.chunk.getHumidity(@intCast(x), @intCast(z)));
        }
    }

    const sample = generated.gen.sampleClimate(0, 0);
    try std.testing.expectEqual(@as(f64, 1.0), sample.temperature[0]);
    try std.testing.expectEqual(@as(f64, 0.0), sample.humidity[0]);
}

fn netherrackCeiling(gpa: std.mem.Allocator) !World {
    var w = World.init(gpa);
    var chunk_x: i32 = -1;
    while (chunk_x <= 1) : (chunk_x += 1) {
        var chunk_z: i32 = -1;
        while (chunk_z <= 1) : (chunk_z += 1) {
            const chunk = try w.createChunk(chunk_x, chunk_z);
            for (0..16) |x| {
                for (0..16) |z| {
                    for (60..70) |y| {
                        chunk.setBlock(@intCast(x), @intCast(y), @intCast(z), .netherrack);
                    }
                }
            }
        }
    }
    return w;
}

test "a glowstone cluster hangs from a netherrack ceiling and spreads downwards" {
    const gpa = std.testing.allocator;
    var w = try netherrackCeiling(gpa);
    defer w.deinit();

    var rand = JavaRandom.init(7);
    try generateGlowstoneCluster(&w, &rand, .init(8, 59, 8));

    try std.testing.expectEqual(.glowstone, w.getBlock(.init(8, 59, 8)));

    var hanging: usize = 0;
    var x: i32 = 0;
    while (x < 16) : (x += 1) {
        var z: i32 = 0;
        while (z < 16) : (z += 1) {
            var y: i32 = 47;
            while (y < 60) : (y += 1) {
                if (w.getBlock(.init(x, y, z)) == .glowstone) hanging += 1;
            }
        }
    }
    try std.testing.expect(hanging > 1);
}

test "a glowstone cluster needs air under netherrack to start" {
    const gpa = std.testing.allocator;
    var w = try netherrackCeiling(gpa);
    defer w.deinit();
    w.setBlock(.init(8, 59, 8), .netherrack);

    var rand = JavaRandom.init(7);
    try generateGlowstoneCluster(&w, &rand, .init(8, 59, 8));
    try std.testing.expectEqual(.netherrack, w.getBlock(.init(8, 59, 8)));

    var open = try netherrackCeiling(gpa);
    defer open.deinit();
    open.setBlock(.init(8, 70, 8), .air);
    try generateGlowstoneCluster(&open, &rand, .init(8, 70, 8));
    try std.testing.expectEqual(.air, open.getBlock(.init(8, 70, 8)));
}

test "fire settles on netherrack and nowhere else" {
    const gpa = std.testing.allocator;
    var w = World.init(gpa);
    defer w.deinit();
    const chunk = try w.createChunk(0, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            chunk.setBlock(@intCast(x), 50, @intCast(z), if (x < 8) .netherrack else .soul_sand);
        }
    }

    var rand = JavaRandom.init(11);
    try generateFirePatch(&w, &rand, .init(8, 51, 8));

    var lit: usize = 0;
    var x: i32 = 0;
    while (x < 16) : (x += 1) {
        var z: i32 = 0;
        while (z < 16) : (z += 1) {
            if (w.getBlock(.init(x, 51, z)) != .fire) continue;
            lit += 1;
            try std.testing.expectEqual(.netherrack, w.getBlock(.init(x, 50, z)));
        }
    }
    try std.testing.expect(lit > 0);
}

test "decorating a nether chunk carries the generator rng on, as ChunkProviderHell does" {
    const gpa = std.testing.allocator;
    var gen = try NetherGenerator.init(gpa, 12345);
    defer gen.deinit(gpa);

    var w = World.init(gpa);
    defer w.deinit();
    _ = try w.getOrGenerateChunk(&gen, 0, 0);
    const after_shape = gen.rand;

    try gen.decorateChunk(&w, 0, 0);
    try std.testing.expect(gen.rand.seed != after_shape.seed);

    var replay = try NetherGenerator.init(gpa, 12345);
    defer replay.deinit(gpa);
    var replay_world = World.init(gpa);
    defer replay_world.deinit();
    _ = try replay_world.getOrGenerateChunk(&replay, 0, 0);
    try std.testing.expectEqual(after_shape.seed, replay.rand.seed);
}

test "a nether world generates and decorates through the World seam" {
    const gpa = std.testing.allocator;
    var gen = try NetherGenerator.init(gpa, 2024);
    defer gen.deinit(gpa);

    var w = World.init(gpa);
    defer w.deinit();
    try w.ensureDecorated(&gen, 0, 0);

    try std.testing.expect(w.isDecorated(0, 0));
    try std.testing.expectEqual(.bedrock, w.getBlock(.init(8, 0, 8)));
    try std.testing.expectEqual(.bedrock, w.getBlock(.init(8, 127, 8)));
}
