const std = @import("std");

const math = @import("math");

const JavaRandom = @import("../JavaRandom.zig");

const PerlinNoise = @This();

permutations: [512]i32,
x_coord: f64,
y_coord: f64,
z_coord: f64,

pub fn init(rand: *JavaRandom) PerlinNoise {
    var self: PerlinNoise = undefined;
    self.x_coord = rand.nextDouble() * 256.0;
    self.y_coord = rand.nextDouble() * 256.0;
    self.z_coord = rand.nextDouble() * 256.0;

    for (0..256) |i| self.permutations[i] = @intCast(i);

    for (0..256) |i| {
        const j: usize = @intCast(rand.nextIntBound(@intCast(256 - i)) + @as(i32, @intCast(i)));
        std.mem.swap(i32, &self.permutations[i], &self.permutations[j]);
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

pub fn noise(self: PerlinNoise, x_in: f64, y_in: f64, z_in: f64) f64 {
    const x0 = x_in + self.x_coord;
    const y0 = y_in + self.y_coord;
    const z0 = z_in + self.z_coord;

    var ix: i32 = math.util.truncateDouble(x0);
    var iy: i32 = math.util.truncateDouble(y0);
    var iz: i32 = math.util.truncateDouble(z0);
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

fn floorAndFrac(v_in: f64) struct { i: i32, frac: f64 } {
    var i: i32 = math.util.truncateDouble(v_in);
    if (v_in < @as(f64, @floatFromInt(i))) i -= 1;
    return .{ .i = i, .frac = v_in - @as(f64, @floatFromInt(i)) };
}

fn fade(t: f64) f64 {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

pub const BatchSize = struct { x: usize, y: usize, z: usize };
pub const BatchOffset = struct { x: f64, y: f64, z: f64 };
pub const BatchScale = struct { x: f64, y: f64, z: f64 };

pub fn addBatch(
    self: PerlinNoise,
    out: []f64,
    offset: BatchOffset,
    size: BatchSize,
    scale: BatchScale,
    noise_scale: f64,
) void {
    const p = self.permutations;
    const inv_scale = 1.0 / noise_scale;

    if (size.y == 1) {
        var index: usize = 0;
        for (0..size.x) |ix| {
            const xf = floorAndFrac((offset.x + @as(f64, @floatFromInt(ix))) * scale.x + self.x_coord);
            const x_idx: usize = @intCast(xf.i & 255);
            const fade_x = fade(xf.frac);

            for (0..size.z) |iz| {
                const zf = floorAndFrac((offset.z + @as(f64, @floatFromInt(iz))) * scale.z + self.z_coord);
                const z_idx: usize = @intCast(zf.i & 255);
                const fade_z = fade(zf.frac);

                const a: usize = @intCast(p[x_idx]);
                const aa: usize = @intCast(p[a] + @as(i32, @intCast(z_idx)));
                const b: usize = @intCast(p[x_idx + 1]);
                const bb: usize = @intCast(p[b] + @as(i32, @intCast(z_idx)));

                const lo = lerp(fade_x, grad(p[aa], xf.frac, 0.0, zf.frac), grad(p[bb], xf.frac - 1.0, 0.0, zf.frac));
                const hi = lerp(fade_x, grad(p[aa + 1], xf.frac, 0.0, zf.frac - 1.0), grad(p[bb + 1], xf.frac - 1.0, 0.0, zf.frac - 1.0));
                out[index] += lerp(fade_z, lo, hi) * inv_scale;
                index += 1;
            }
        }
        return;
    }

    var index: usize = 0;
    var cached_y_idx: i32 = -1;
    var corner_ll: f64 = 0;
    var corner_lh: f64 = 0;
    var corner_hl: f64 = 0;
    var corner_hh: f64 = 0;
    for (0..size.x) |ix| {
        const xf = floorAndFrac((offset.x + @as(f64, @floatFromInt(ix))) * scale.x + self.x_coord);
        const x_idx: usize = @intCast(xf.i & 255);
        const fade_x = fade(xf.frac);

        for (0..size.z) |iz| {
            const zf = floorAndFrac((offset.z + @as(f64, @floatFromInt(iz))) * scale.z + self.z_coord);
            const z_idx: usize = @intCast(zf.i & 255);
            const fade_z = fade(zf.frac);

            for (0..size.y) |iy| {
                const yf = floorAndFrac((offset.y + @as(f64, @floatFromInt(iy))) * scale.y + self.y_coord);
                const y_idx: i32 = yf.i & 255;
                const fade_y = fade(yf.frac);

                if (iy == 0 or y_idx != cached_y_idx) {
                    cached_y_idx = y_idx;
                    const a: usize = @intCast(p[x_idx] + y_idx);
                    const aa: usize = @intCast(p[a] + @as(i32, @intCast(z_idx)));
                    const ab: usize = @intCast(p[a + 1] + @as(i32, @intCast(z_idx)));
                    const b: usize = @intCast(p[x_idx + 1] + y_idx);
                    const ba: usize = @intCast(p[b] + @as(i32, @intCast(z_idx)));
                    const bb: usize = @intCast(p[b + 1] + @as(i32, @intCast(z_idx)));

                    corner_ll = lerp(fade_x, grad(p[aa], xf.frac, yf.frac, zf.frac), grad(p[ba], xf.frac - 1.0, yf.frac, zf.frac));
                    corner_lh = lerp(fade_x, grad(p[ab], xf.frac, yf.frac - 1.0, zf.frac), grad(p[bb], xf.frac - 1.0, yf.frac - 1.0, zf.frac));
                    corner_hl = lerp(fade_x, grad(p[aa + 1], xf.frac, yf.frac, zf.frac - 1.0), grad(p[ba + 1], xf.frac - 1.0, yf.frac, zf.frac - 1.0));
                    corner_hh = lerp(fade_x, grad(p[ab + 1], xf.frac, yf.frac - 1.0, zf.frac - 1.0), grad(p[bb + 1], xf.frac - 1.0, yf.frac - 1.0, zf.frac - 1.0));
                }

                const lo = lerp(fade_y, corner_ll, corner_lh);
                const hi = lerp(fade_y, corner_hl, corner_hh);
                out[index] += lerp(fade_z, lo, hi) * inv_scale;
                index += 1;
            }
        }
    }
}

test "permutation table and coords match java.util.Random(42) reference" {
    var rand = JavaRandom.init(42);
    const gen = PerlinNoise.init(&rand);
    try std.testing.expectApproxEqAbs(@as(f64, 186.25630208841423), gen.x_coord, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 174.90520877052043), gen.y_coord, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 79.0321805651609), gen.z_coord, 1.0e-9);
    try std.testing.expectEqual(@as(i32, 70), gen.permutations[0]);
    try std.testing.expectEqual(@as(i32, 234), gen.permutations[1]);
    try std.testing.expectEqual(@as(i32, 27), gen.permutations[255]);
    try std.testing.expectEqual(@as(i32, 70), gen.permutations[256]);
    try std.testing.expectEqual(@as(i32, 6), gen.permutations[300]);
}

test "noise matches java.util.Random(42)-seeded PerlinNoise reference" {
    var rand = JavaRandom.init(42);
    const gen = PerlinNoise.init(&rand);
    try std.testing.expectApproxEqAbs(@as(f64, -0.255587766876179), gen.noise(1.5, 2.5, 3.5), 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.07034195718122457), gen.noise(0, 0, 0), 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, -0.3246944282694318), gen.noise(100.25, 0, -40.75), 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, -0.16956139820596045), gen.noise(-5.1, 10.2, 7.3), 1.0e-12);
}
