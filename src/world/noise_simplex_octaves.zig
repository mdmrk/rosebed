const std = @import("std");

const JavaRandom = @import("java_random.zig");
const NoiseGenerator2 = @import("noise_simplex.zig");
pub const Size = NoiseGenerator2.BatchSize;
pub const Offset = NoiseGenerator2.BatchOffset;
pub const Scale = NoiseGenerator2.BatchScale;

const NoiseGeneratorOctaves2 = @This();

generators: []NoiseGenerator2,

pub fn init(gpa: std.mem.Allocator, rand: *JavaRandom, octaves: usize) !NoiseGeneratorOctaves2 {
    const generators = try gpa.alloc(NoiseGenerator2, octaves);
    for (generators) |*g| g.* = NoiseGenerator2.init(rand);
    return .{ .generators = generators };
}

pub fn deinit(self: NoiseGeneratorOctaves2, gpa: std.mem.Allocator) void {
    gpa.free(self.generators);
}

pub fn generate(
    self: NoiseGeneratorOctaves2,
    out: []f64,
    offset: Offset,
    size: Size,
    scale: Scale,
    frequency_persistence: f64,
    amplitude_persistence: f64,
) void {
    @memset(out, 0);

    const x_scale = scale.x / 1.5;
    const y_scale = scale.y / 1.5;
    var freq_mult: f64 = 1.0;
    var amp_divisor: f64 = 1.0;
    for (self.generators) |gen| {
        gen.addBatch(out, offset, size, .{ .x = x_scale * freq_mult, .y = y_scale * freq_mult }, 0.55 / amp_divisor);
        freq_mult *= frequency_persistence;
        amp_divisor *= amplitude_persistence;
    }
}

pub fn generateDefault(
    self: NoiseGeneratorOctaves2,
    out: []f64,
    offset: Offset,
    size: Size,
    scale: Scale,
    frequency_persistence: f64,
) void {
    self.generate(out, offset, size, scale, frequency_persistence, 0.5);
}

test "generateDefault matches a real Minecraft NoiseGeneratorOctaves2(seed 777, 4 octaves)" {
    const gpa = std.testing.allocator;
    var rand = JavaRandom.init(777);
    const gen = try NoiseGeneratorOctaves2.init(gpa, &rand, 4);
    defer gen.deinit(gpa);

    var out: [16]f64 = undefined;
    gen.generateDefault(&out, .{ .x = 10.0, .y = 20.0 }, .{ .x = 4, .y = 4 }, .{ .x = 0.025, .y = 0.025 }, 0.25);

    const expected = [16]f64{
        -0.2396670549214286,  -0.23133092413737488, -0.22353621613738772, -0.2163362663282009,
        -0.27602004224555143, -0.2666886047712902,  -0.25760539657844417, -0.24884075413803552,
        -0.3123206505239051,  -0.30209895210553706, -0.29181183549138545, -0.2815451067198227,
        -0.3480508825931028,  -0.33704804558259394, -0.3256499027215405,  -0.313956137241191,
    };
    for (expected, out) |e, v| {
        try std.testing.expectApproxEqAbs(e, v, 1.0e-9);
    }
}

test "generate with custom persistence matches the same real generator, second call" {
    const gpa = std.testing.allocator;
    var rand = JavaRandom.init(777);
    const gen = try NoiseGeneratorOctaves2.init(gpa, &rand, 4);
    defer gen.deinit(gpa);

    var discard: [16]f64 = undefined;
    gen.generateDefault(&discard, .{ .x = 10.0, .y = 20.0 }, .{ .x = 4, .y = 4 }, .{ .x = 0.025, .y = 0.025 }, 0.25);

    var out: [9]f64 = undefined;
    gen.generate(&out, .{ .x = 10.0, .y = 20.0 }, .{ .x = 3, .y = 3 }, .{ .x = 0.25, .y = 0.25 }, 0.5882352941176471, 0.5);

    const expected = [9]f64{
        0.17429145770567955, 0.5096707432903411, 0.6450440161283324,
        0.5567442351296987,  1.0022362085807135, 1.1970912264204645,
        1.0360861829820962,  1.4625661975117232, 1.6500785513169447,
    };
    for (expected, out) |e, v| {
        try std.testing.expectApproxEqAbs(e, v, 1.0e-9);
    }
}
