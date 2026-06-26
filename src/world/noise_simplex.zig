const std = @import("std");
const JavaRandom = @import("java_random.zig");

const NoiseGenerator2 = @This();

const f2: f64 = 0.5 * (@sqrt(3.0) - 1.0);
const g2: f64 = (3.0 - @sqrt(3.0)) / 6.0;

const gradients = [12][2]i32{
    .{ 1, 1 },   .{ -1, 1 },  .{ 1, -1 },  .{ -1, -1 },
    .{ 1, 0 },   .{ -1, 0 },  .{ 1, 0 },   .{ -1, 0 },
    .{ 0, 1 },   .{ 0, -1 },  .{ 0, 1 },   .{ 0, -1 },
};

permutations: [512]i32,
x_offset: f64,
y_offset: f64,
z_offset: f64,

pub fn init(rand: *JavaRandom) NoiseGenerator2 {
    var self: NoiseGenerator2 = undefined;
    self.x_offset = rand.nextDouble() * 256.0;
    self.y_offset = rand.nextDouble() * 256.0;
    self.z_offset = rand.nextDouble() * 256.0;

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

fn wrap(v: f64) i32 {
    const t: i32 = @intFromFloat(v);
    return if (v > 0.0) t else t - 1;
}

fn dot(g: [2]i32, x: f64, y: f64) f64 {
    return @as(f64, @floatFromInt(g[0])) * x + @as(f64, @floatFromInt(g[1])) * y;
}

pub const BatchSize = struct { x: usize, y: usize };
pub const BatchOffset = struct { x: f64, y: f64 };
pub const BatchScale = struct { x: f64, y: f64 };

pub fn addBatch(
    self: NoiseGenerator2,
    out: []f64,
    offset: BatchOffset,
    size: BatchSize,
    scale: BatchScale,
    amplitude: f64,
) void {
    const p = self.permutations;
    var index: usize = 0;
    for (0..size.x) |ix| {
        const x_in = (offset.x + @as(f64, @floatFromInt(ix))) * scale.x + self.x_offset;
        for (0..size.y) |iy| {
            const y_in = (offset.y + @as(f64, @floatFromInt(iy))) * scale.y + self.y_offset;

            const skew = (x_in + y_in) * f2;
            const i = wrap(x_in + skew);
            const j = wrap(y_in + skew);
            const unskew = @as(f64, @floatFromInt(i + j)) * g2;
            const x0_origin = @as(f64, @floatFromInt(i)) - unskew;
            const y0_origin = @as(f64, @floatFromInt(j)) - unskew;
            const x0 = x_in - x0_origin;
            const y0 = y_in - y0_origin;

            const off_i: i32 = if (x0 > y0) 1 else 0;
            const off_j: i32 = if (x0 > y0) 0 else 1;

            const x1 = x0 - @as(f64, @floatFromInt(off_i)) + g2;
            const y1 = y0 - @as(f64, @floatFromInt(off_j)) + g2;
            const x2 = x0 - 1.0 + 2.0 * g2;
            const y2 = y0 - 1.0 + 2.0 * g2;

            const ii: usize = @intCast(i & 255);
            const jj: usize = @intCast(j & 255);
            const gi0: usize = @intCast(@rem(p[ii + @as(usize, @intCast(p[jj]))], 12));
            const gi1: usize = @intCast(@rem(p[ii + @as(usize, @intCast(off_i)) + @as(usize, @intCast(p[jj + @as(usize, @intCast(off_j))]))], 12));
            const gi2: usize = @intCast(@rem(p[ii + 1 + @as(usize, @intCast(p[jj + 1]))], 12));

            var t0 = 0.5 - x0 * x0 - y0 * y0;
            const n0 = if (t0 < 0.0) 0.0 else blk: {
                t0 *= t0;
                break :blk t0 * t0 * dot(gradients[gi0], x0, y0);
            };

            var t1 = 0.5 - x1 * x1 - y1 * y1;
            const n1 = if (t1 < 0.0) 0.0 else blk: {
                t1 *= t1;
                break :blk t1 * t1 * dot(gradients[gi1], x1, y1);
            };

            var t2 = 0.5 - x2 * x2 - y2 * y2;
            const n2 = if (t2 < 0.0) 0.0 else blk: {
                t2 *= t2;
                break :blk t2 * t2 * dot(gradients[gi2], x2, y2);
            };

            out[index] += 70.0 * (n0 + n1 + n2) * amplitude;
            index += 1;
        }
    }
}

test "permutation table and offsets match java.util.Random(42) reference" {
    var rand = JavaRandom.init(42);
    const gen = NoiseGenerator2.init(&rand);
    try std.testing.expectApproxEqAbs(@as(f64, 186.25630208841423), gen.x_offset, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 174.90520877052043), gen.y_offset, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 79.0321805651609), gen.z_offset, 1.0e-9);
}

test "addBatch matches a real Minecraft NoiseGenerator2(seed 42) 3x3 grid" {
    var rand = JavaRandom.init(42);
    const gen = NoiseGenerator2.init(&rand);

    var out = [_]f64{0} ** 9;
    gen.addBatch(&out, .{ .x = 5.0, .y = -3.0 }, .{ .x = 3, .y = 3 }, .{ .x = 0.05, .y = 0.05 }, 1.0);

    const expected = [9]f64{
        -0.11985956360249195, -0.24815785602001716, -0.3468924884640519,
        -0.15643394656591092, -0.31290372880986494, -0.4329661166171078,
        -0.17569389996841378, -0.3519222174103727,  -0.48744613998348624,
    };
    for (expected, out) |e, v| {
        try std.testing.expectApproxEqAbs(e, v, 1.0e-9);
    }
}
