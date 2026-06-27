pub const Chunk = @import("chunk.zig");
pub const NibbleArray = @import("nibble_array.zig");
pub const constants = @import("constants.zig");
pub const block = @import("block.zig");
pub const JavaRandom = @import("java_random.zig");
pub const NoiseGeneratorPerlin = @import("noise_perlin.zig");
pub const NoiseGeneratorOctaves = @import("noise_octaves.zig");
pub const TerrainGenerator = @import("terrain_gen.zig");
pub const NoiseGenerator2 = @import("noise_simplex.zig");
pub const NoiseGeneratorOctaves2 = @import("noise_simplex_octaves.zig");
pub const biome = @import("biome.zig");
pub const Climate = @import("climate.zig");
pub const caves = @import("caves.zig");
pub const decorate = @import("decorate.zig");
pub const lakes = @import("lakes.zig");
pub const dungeons = @import("dungeons.zig");
pub const World = @import("world_map.zig");

test {
    _ = Chunk;
    _ = NibbleArray;
    _ = block;
    _ = JavaRandom;
    _ = NoiseGeneratorPerlin;
    _ = NoiseGeneratorOctaves;
    _ = TerrainGenerator;
    _ = NoiseGenerator2;
    _ = NoiseGeneratorOctaves2;
    _ = biome;
    _ = Climate;
    _ = caves;
    _ = decorate;
    _ = lakes;
    _ = dungeons;
    _ = World;
}
