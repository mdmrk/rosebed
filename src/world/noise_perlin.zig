const std = @import("std");
const JavaRandom = @import("java_random.zig");

const NoiseGeneratorPerlin = @This();

permutations: [512]i32,
x_coord: f64,
y_coord: f64,
z_coord: f64,

pub fn init(rand: *JavaRandom) NoiseGeneratorPerlin {
    var self: NoiseGeneratorPerlin = undefined;
    self.x_coord = rand.nextDouble() * 256.0;
    self.y_coord = rand.nextDouble() * 256.0;
    self.z_coord = rand.nextDouble() * 256.0;

    for (0..256) |i| self.permutations[i] = @intCast(i);

    for (0..256) |i| {
        const j: usize = @intCast(rand.nextIntBound(@intCast(256 - i)) + @as(i32, @intCast(i)));
        const tmp = self.permutations[i];
        self.permutations[i] = self.permutations[j];
        self.permutations[j] = tmp;
        self.permutations[i + 256] = self.permutations[i];
    }

    return self;
}

fn lerp(t: f64, a: f64, b: f64) f64 {
    return a + t * (b - a);
}

fn grad(hash: i32, x: f64, y: f64, z: f64) f64 {
    const h: u32 = @as(u32, @bitCast(hash)) & 15;
    const u = if (h < 8) x else y;
    const v = if (h < 4) y else (if (h != 12 and h != 14) z else x);
    return (if (h & 1 == 0) u else -u) + (if (h & 2 == 0) v else -v);
}

pub fn noise(self: NoiseGeneratorPerlin, x_in: f64, y_in: f64, z_in: f64) f64 {
    const x0 = x_in + self.x_coord;
    const y0 = y_in + self.y_coord;
    const z0 = z_in + self.z_coord;

    var ix: i32 = @intFromFloat(x0);
    var iy: i32 = @intFromFloat(y0);
    var iz: i32 = @intFromFloat(z0);
    if (x0 < @as(f64, @floatFromInt(ix))) ix -= 1;
    if (y0 < @as(f64, @floatFromInt(iy))) iy -= 1;
    if (z0 < @as(f64, @floatFromInt(iz))) iz -= 1;

    const xi: usize = @intCast(ix & 255);
    const yi: usize = @intCast(iy & 255);
    const zi: usize = @intCast(iz & 255);

    const x = x0 - @as(f64, @floatFromInt(ix));
    const y = y0 - @as(f64, @floatFromInt(iy));
    const z = z0 - @as(f64, @floatFromInt(iz));

    const u = x * x * x * (x * (x * 6.0 - 15.0) + 10.0);
    const v = y * y * y * (y * (y * 6.0 - 15.0) + 10.0);
    const w = z * z * z * (z * (z * 6.0 - 15.0) + 10.0);

    const p = self.permutations;
    const a: usize = @intCast(p[xi] + @as(i32, @intCast(yi)));
    const aa: usize = @intCast(p[a] + @as(i32, @intCast(zi)));
    const ab: usize = @intCast(p[a + 1] + @as(i32, @intCast(zi)));
    const b: usize = @intCast(p[xi + 1] + @as(i32, @intCast(yi)));
    const ba: usize = @intCast(p[b] + @as(i32, @intCast(zi)));
    const bb: usize = @intCast(p[b + 1] + @as(i32, @intCast(zi)));

    return lerp(w, lerp(v, lerp(u, grad(p[aa], x, y, z), grad(p[ba], x - 1.0, y, z)), lerp(u, grad(p[ab], x, y - 1.0, z), grad(p[bb], x - 1.0, y - 1.0, z))), lerp(v, lerp(u, grad(p[aa + 1], x, y, z - 1.0), grad(p[ba + 1], x - 1.0, y, z - 1.0)), lerp(u, grad(p[ab + 1], x, y - 1.0, z - 1.0), grad(p[bb + 1], x - 1.0, y - 1.0, z - 1.0))));
}

test "permutation table and coords match java.util.Random(42) reference" {
    var rand = JavaRandom.init(42);
    const gen = NoiseGeneratorPerlin.init(&rand);
    try std.testing.expectApproxEqAbs(@as(f64, 186.25630208841423), gen.x_coord, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 174.90520877052043), gen.y_coord, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 79.0321805651609), gen.z_coord, 1.0e-9);
    try std.testing.expectEqual(@as(i32, 70), gen.permutations[0]);
    try std.testing.expectEqual(@as(i32, 234), gen.permutations[1]);
    try std.testing.expectEqual(@as(i32, 27), gen.permutations[255]);
    try std.testing.expectEqual(@as(i32, 70), gen.permutations[256]);
    try std.testing.expectEqual(@as(i32, 6), gen.permutations[300]);
}

test "noise matches java.util.Random(42)-seeded NoiseGeneratorPerlin reference" {
    var rand = JavaRandom.init(42);
    const gen = NoiseGeneratorPerlin.init(&rand);
    try std.testing.expectApproxEqAbs(@as(f64, -0.255587766876179), gen.noise(1.5, 2.5, 3.5), 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.07034195718122457), gen.noise(0, 0, 0), 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, -0.3246944282694318), gen.noise(100.25, 0, -40.75), 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, -0.16956139820596045), gen.noise(-5.1, 10.2, 7.3), 1.0e-12);
}
