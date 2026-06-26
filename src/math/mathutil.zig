//! Numeric helpers ported from Minecraft Beta 1.7.3's `MathHelper`.
//!
//! The sine/cosine lookup table is reproduced exactly (not a direct `@sin`
//! call) because vanilla tuned several animations and rotations against its
//! 65536-entry quantization.
const std = @import("std");

const sin_table: [65536]f32 = blk: {
    @setEvalBranchQuota(2_000_000);
    var table: [65536]f32 = undefined;
    for (&table, 0..) |*v, i| {
        v.* = @floatCast(@sin(@as(f64, @floatFromInt(i)) * std.math.pi * 2.0 / 65536.0));
    }
    break :blk table;
};

fn tableIndex(x: f32) u16 {
    const raw: i32 = @intFromFloat(x);
    return @truncate(@as(u32, @bitCast(raw)));
}

/// Matches `MathHelper.sin`.
pub fn sin(x: f32) f32 {
    return sin_table[tableIndex(x * 10430.378)];
}

/// Matches `MathHelper.cos`.
pub fn cos(x: f32) f32 {
    return sin_table[tableIndex(x * 10430.378 + 16384.0)];
}

/// Matches `MathHelper.sqrt_float`/`sqrt_double`: both just narrow a `sqrt`
/// result to f32, so there is no need for two separate functions.
pub fn sqrtF(x: f64) f32 {
    return @floatCast(@sqrt(x));
}

/// Matches `MathHelper.floor_float`.
pub fn floorFloat(x: f32) i32 {
    const i: i32 = @intFromFloat(x);
    return if (x < @as(f32, @floatFromInt(i))) i - 1 else i;
}

/// Matches `MathHelper.floor_double`.
pub fn floorDouble(x: f64) i32 {
    const i: i32 = @intFromFloat(x);
    return if (x < @as(f64, @floatFromInt(i))) i - 1 else i;
}

/// Matches `MathHelper.abs`.
pub fn abs(x: f32) f32 {
    return if (x >= 0.0) x else -x;
}

/// Matches `MathHelper.abs_max`.
pub fn absMax(a: f64, b: f64) f64 {
    return @max(@abs(a), @abs(b));
}

/// Matches `MathHelper.bucketInt`: integer division that floors toward
/// negative infinity instead of truncating toward zero.
pub fn bucketInt(a: i32, b: i32) i32 {
    return if (a < 0) -(@divTrunc(-a - 1, b)) - 1 else @divTrunc(a, b);
}

test "sin/cos match std.math at the table's resolution" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), sin(0.0), 1.0e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), cos(0.0), 1.0e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), sin(std.math.pi / 2.0), 1.0e-3);
}

test "floorFloat/floorDouble round toward negative infinity" {
    try std.testing.expectEqual(@as(i32, 1), floorFloat(1.5));
    try std.testing.expectEqual(@as(i32, -2), floorFloat(-1.5));
    try std.testing.expectEqual(@as(i32, -1), floorDouble(-0.5));
}

test "bucketInt floors negative division like the original" {
    try std.testing.expectEqual(@as(i32, 0), bucketInt(15, 16));
    try std.testing.expectEqual(@as(i32, -1), bucketInt(-1, 16));
    try std.testing.expectEqual(@as(i32, -1), bucketInt(-16, 16));
    try std.testing.expectEqual(@as(i32, -2), bucketInt(-17, 16));
}
