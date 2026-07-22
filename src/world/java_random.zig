const std = @import("std");

const JavaRandom = @This();

const multiplier: i64 = 0x5DEECE66D;
const addend: i64 = 0xB;
const mask: i64 = (1 << 48) - 1;

seed: i64,
spare_gaussian: ?f64 = null,

pub fn init(seed: i64) JavaRandom {
    return .{ .seed = (seed ^ multiplier) & mask };
}

pub fn setSeed(self: *JavaRandom, seed: i64) void {
    self.seed = (seed ^ multiplier) & mask;
    self.spare_gaussian = null;
}

fn next(self: *JavaRandom, bits: u6) i32 {
    self.seed = (self.seed *% multiplier +% addend) & mask;
    const shifted = self.seed >> @intCast(48 - bits);
    return @truncate(shifted);
}

pub fn nextInt(self: *JavaRandom) i32 {
    return self.next(32);
}

pub fn nextIntBound(self: *JavaRandom, bound: i32) i32 {
    if ((bound & -%bound) == bound) {
        return @intCast((@as(i64, bound) *% @as(i64, self.next(31))) >> 31);
    }
    while (true) {
        const bits = self.next(31);
        const val = @rem(bits, bound);
        if (bits -% val +% (bound - 1) >= 0) return val;
    }
}

pub fn nextDouble(self: *JavaRandom) f64 {
    const hi: i64 = self.next(26);
    const lo: i64 = self.next(27);
    const combined = (hi << 27) +% lo;
    return @as(f64, @floatFromInt(combined)) / @as(f64, @floatFromInt(@as(i64, 1) << 53));
}

pub fn nextFloat(self: *JavaRandom) f32 {
    return @as(f32, @floatFromInt(self.next(24))) / @as(f32, @floatFromInt(@as(i32, 1) << 24));
}

pub fn nextGaussian(self: *JavaRandom) f64 {
    if (self.spare_gaussian) |spare| {
        self.spare_gaussian = null;
        return spare;
    }

    while (true) {
        const v1 = 2.0 * self.nextDouble() - 1.0;
        const v2 = 2.0 * self.nextDouble() - 1.0;
        const s = v1 * v1 + v2 * v2;
        if (s >= 1.0 or s == 0.0) continue;

        const multiplied = @sqrt(-2.0 * @log(s) / s);
        self.spare_gaussian = v2 * multiplied;
        return v1 * multiplied;
    }
}

pub fn nextLong(self: *JavaRandom) i64 {
    const hi: i64 = self.next(32);
    const lo: i64 = self.next(32);
    return (hi << 32) +% lo;
}

test "nextInt matches java.util.Random(12345).nextInt()" {
    var r = JavaRandom.init(12345);
    const expected = [_]i32{ 1553932502, -2090749135, -287790814, -355989640, -716867186 };
    for (expected) |e| {
        try std.testing.expectEqual(e, r.nextInt());
    }
}

test "nextDouble matches java.util.Random(12345).nextDouble()" {
    var r = JavaRandom.init(12345);
    const expected = [_]f64{ 0.3618031071604718, 0.932993485288541, 0.8330913489710237, 0.32647575623792624, 0.2355237906476252 };
    for (expected) |e| {
        try std.testing.expectApproxEqAbs(e, r.nextDouble(), 1.0e-15);
    }
}

test "nextIntBound(100) matches java.util.Random(12345).nextInt(100)" {
    var r = JavaRandom.init(12345);
    const expected = [_]i32{ 51, 80, 41, 28, 55 };
    for (expected) |e| {
        try std.testing.expectEqual(e, r.nextIntBound(100));
    }
}

test "nextIntBound(37) matches java.util.Random(12345).nextInt(37), non-power-of-2 rejection path" {
    var r = JavaRandom.init(12345);
    const expected = [_]i32{ 32, 33, 20, 29, 7 };
    for (expected) |e| {
        try std.testing.expectEqual(e, r.nextIntBound(37));
    }
}

test "nextLong matches java.util.Random(12345).nextLong()" {
    var r = JavaRandom.init(12345);
    const expected = [_]i64{ 6674089274190705457, -1236052134575208584, -3078921119283744887, 6022414958441676900, 4344647195749500666 };
    for (expected) |e| {
        try std.testing.expectEqual(e, r.nextLong());
    }
}

test "nextGaussian matches java.util.Random(12345).nextGaussian()" {
    var r = JavaRandom.init(12345);
    const expected = [_]f64{
        -0.187808989658912,
        0.5884363051154796,
        0.9488047804400426,
        -0.49428072062604445,
        -1.223411937180115,
        -0.6979609783968826,
    };
    for (expected) |e| {
        try std.testing.expectApproxEqAbs(e, r.nextGaussian(), 1.0e-15);
    }
}

test "the gaussian held back from a pair survives an unrelated draw in between" {
    var r = JavaRandom.init(1);
    try std.testing.expectApproxEqAbs(@as(f64, 1.561581040188955), r.nextGaussian(), 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.20771484130971707), r.nextDouble(), 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, -0.6081826070068602), r.nextGaussian(), 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, -0.0542290976338066), r.nextGaussian(), 1.0e-15);
}

test "setSeed on an existing instance matches a freshly-initialized one" {
    var r = JavaRandom.init(1);
    _ = r.nextInt();
    _ = r.nextInt();
    r.setSeed(12345);

    var expected = JavaRandom.init(12345);
    try std.testing.expectEqual(expected.nextInt(), r.nextInt());
    try std.testing.expectEqual(expected.nextInt(), r.nextInt());
}

test "nextLong matches java.util.Random(-987654321).nextLong()" {
    var r = JavaRandom.init(-987654321);
    const expected = [_]i64{ -5646896605836454244, -7312776516532582084, -3244340451393990214 };
    for (expected) |e| {
        try std.testing.expectEqual(e, r.nextLong());
    }
}
