const std = @import("std");

const Chunk = @import("../Chunk.zig");
const Climate = @import("Climate.zig");
const NetherGenerator = @import("NetherGenerator.zig");
const TerrainGenerator = @import("TerrainGenerator.zig");
const World = @import("../World.zig");

pub const Dimension = enum(i8) {
    overworld = 0,
    nether = -1,

    pub fn coordinateScale(self: Dimension) f64 {
        return switch (self) {
            .overworld => 1.0,
            .nether => 8.0,
        };
    }

    pub fn hasSky(self: Dimension) bool {
        return self == .overworld;
    }

    pub fn ambientLight(self: Dimension) f32 {
        return switch (self) {
            .overworld => 0.05,
            .nether => 0.1,
        };
    }

    pub fn fogColor(self: Dimension) [3]f32 {
        return switch (self) {
            .overworld => .{ 0.7529412, 0.84705883, 1.0 },
            .nether => .{ 0.2, 0.03, 0.03 },
        };
    }

    pub fn other(self: Dimension) Dimension {
        return switch (self) {
            .overworld => .nether,
            .nether => .overworld,
        };
    }

    pub fn regionPath(self: Dimension) []const u8 {
        return switch (self) {
            .overworld => "region",
            .nether => "DIM-1/region",
        };
    }
};

pub const Generator = union(Dimension) {
    overworld: TerrainGenerator,
    nether: NetherGenerator,

    pub fn init(gpa: std.mem.Allocator, which: Dimension, seed: i64) !Generator {
        return switch (which) {
            .overworld => .{ .overworld = try TerrainGenerator.init(gpa, seed) },
            .nether => .{ .nether = try NetherGenerator.init(gpa, seed) },
        };
    }

    pub fn deinit(self: Generator, gpa: std.mem.Allocator) void {
        switch (self) {
            .overworld => |gen| gen.deinit(gpa),
            .nether => |gen| gen.deinit(gpa),
        }
    }

    pub fn dimension(self: Generator) Dimension {
        return self;
    }

    pub fn worldSeed(self: Generator) i64 {
        return switch (self) {
            .overworld => |gen| gen.world_seed,
            .nether => |gen| gen.world_seed,
        };
    }

    pub fn generateShape(self: *Generator, chunk: *Chunk) void {
        switch (self.*) {
            .overworld => |gen| gen.generateShape(chunk),
            .nether => |*gen| gen.generateShape(chunk),
        }
    }

    pub fn decorateChunk(self: *Generator, world_map: *World, chunk_x: i32, chunk_z: i32) !void {
        switch (self.*) {
            .overworld => |gen| try gen.decorateChunk(world_map, chunk_x, chunk_z),
            .nether => |*gen| try gen.decorateChunk(world_map, chunk_x, chunk_z),
        }
    }

    pub fn sampleClimate(self: *const Generator, x: i32, z: i32) Climate.Sample {
        return switch (self.*) {
            .overworld => |gen| gen.sampleClimate(x, z),
            .nether => |gen| gen.sampleClimate(x, z),
        };
    }

    pub fn temperatureAt(self: *const Generator, x: i32, z: i32) f64 {
        return switch (self.*) {
            .overworld => |gen| gen.climate.temperatureAt(x, z),
            .nether => NetherGenerator.temperature,
        };
    }
};

test "a dimension names the world on the other side of a portal" {
    try std.testing.expectEqual(Dimension.nether, Dimension.overworld.other());
    try std.testing.expectEqual(Dimension.overworld, Dimension.nether.other());
    try std.testing.expectEqual(@as(i8, -1), @intFromEnum(Dimension.nether));
    try std.testing.expectEqual(@as(i8, 0), @intFromEnum(Dimension.overworld));
}

test "the nether packs eight overworld blocks into one, and hides the sky" {
    try std.testing.expectEqual(@as(f64, 8.0), Dimension.nether.coordinateScale());
    try std.testing.expectEqual(@as(f64, 1.0), Dimension.overworld.coordinateScale());
    try std.testing.expect(!Dimension.nether.hasSky());
    try std.testing.expect(Dimension.overworld.hasSky());
    try std.testing.expectEqualStrings("DIM-1/region", Dimension.nether.regionPath());
    try std.testing.expectEqualStrings("region", Dimension.overworld.regionPath());
}

test "either generator answers the same calls, and reports its own dimension" {
    const gpa = std.testing.allocator;

    var overworld = try Generator.init(gpa, .overworld, 12345);
    defer overworld.deinit(gpa);
    var nether = try Generator.init(gpa, .nether, 12345);
    defer nether.deinit(gpa);

    try std.testing.expectEqual(Dimension.overworld, overworld.dimension());
    try std.testing.expectEqual(Dimension.nether, nether.dimension());
    try std.testing.expectEqual(@as(i64, 12345), overworld.worldSeed());
    try std.testing.expectEqual(@as(i64, 12345), nether.worldSeed());

    var overworld_chunk = Chunk.init(0, 0);
    overworld.generateShape(&overworld_chunk);
    var nether_chunk = Chunk.init(0, 0);
    nether.generateShape(&nether_chunk);

    try std.testing.expectEqual(.bedrock, nether_chunk.getBlock(8, 127, 8));
    try std.testing.expect(overworld_chunk.getBlock(8, 127, 8) != .bedrock);
    try std.testing.expectEqual(@as(f64, 1.0), nether.temperatureAt(0, 0));
}
