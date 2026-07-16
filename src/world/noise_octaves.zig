const std = @import("std");
const JavaRandom = @import("java_random.zig");
const NoiseGeneratorPerlin = @import("noise_perlin.zig");

const NoiseGeneratorOctaves = @This();

generators: []NoiseGeneratorPerlin,

pub fn init(gpa: std.mem.Allocator, rand: *JavaRandom, octaves: usize) !NoiseGeneratorOctaves {
    const generators = try gpa.alloc(NoiseGeneratorPerlin, octaves);
    for (generators) |*g| g.* = NoiseGeneratorPerlin.init(rand);
    return .{ .generators = generators };
}

pub fn deinit(self: NoiseGeneratorOctaves, gpa: std.mem.Allocator) void {
    gpa.free(self.generators);
}

pub const Size = NoiseGeneratorPerlin.BatchSize;
pub const Offset = NoiseGeneratorPerlin.BatchOffset;
pub const Scale = NoiseGeneratorPerlin.BatchScale;

pub fn generate(
    self: NoiseGeneratorOctaves,
    out: []f64,
    offset: Offset,
    size: Size,
    scale: Scale,
) void {
    @memset(out, 0);

    var amplitude: f64 = 1.0;
    for (self.generators) |gen| {
        gen.addBatch(out, offset, size, .{
            .x = scale.x * amplitude,
            .y = scale.y * amplitude,
            .z = scale.z * amplitude,
        }, amplitude);
        amplitude /= 2.0;
    }
}

pub fn samplePoint2D(self: NoiseGeneratorOctaves, x: f64, z: f64) f64 {
    var total: f64 = 0.0;
    var frequency: f64 = 1.0;
    for (self.generators) |gen| {
        total += gen.noise(x * frequency, z * frequency, 0.0) / frequency;
        frequency /= 2.0;
    }
    return total;
}

test "matches a real Minecraft NoiseGeneratorOctaves(seed 999, 4 octaves) 2D grid" {
    const gpa = std.testing.allocator;
    var rand = JavaRandom.init(999);
    const gen = try NoiseGeneratorOctaves.init(gpa, &rand, 4);
    defer gen.deinit(gpa);

    var out: [9]f64 = undefined;
    gen.generate(&out, .{ .x = 0, .y = 0, .z = 0 }, .{ .x = 3, .y = 1, .z = 3 }, .{ .x = 0.5, .y = 1.0, .z = 0.5 });

    const expected = [9]f64{
        -2.3476111711921055, -2.073983024344857,   -1.248488154380864,
        -2.0104567690882815, -1.1038516965238554,  -0.2925834261411864,
        -1.2302402996403607, -0.39842265849835323, 0.14175092962260183,
    };
    for (expected, out) |e, v| {
        try std.testing.expectApproxEqAbs(e, v, 1.0e-9);
    }
}

test "matches a real Minecraft NoiseGeneratorOctaves(seed 999, 4 octaves) 3D grid" {
    const gpa = std.testing.allocator;
    var rand = JavaRandom.init(999);
    const gen = try NoiseGeneratorOctaves.init(gpa, &rand, 4);
    defer gen.deinit(gpa);

    var discard: [9]f64 = undefined;
    gen.generate(&discard, .{ .x = 0, .y = 0, .z = 0 }, .{ .x = 3, .y = 1, .z = 3 }, .{ .x = 0.5, .y = 1.0, .z = 0.5 });

    var out: [8]f64 = undefined;
    gen.generate(&out, .{ .x = 5, .y = 10, .z = -3 }, .{ .x = 2, .y = 2, .z = 2 }, .{ .x = 0.25, .y = 0.3, .z = 0.25 });

    const expected = [8]f64{
        2.6572896182133023, 2.9316832555096046,
        2.17116530373257,   2.445437800358423,
        2.874732399704451,  3.2362426127460093,
        2.350706744324838,  2.711174597052445,
    };
    for (expected, out) |e, v| {
        try std.testing.expectApproxEqAbs(e, v, 1.0e-9);
    }
}
