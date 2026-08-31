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
    const raw: i32 = std.math.lossyCast(i32, x);
    return @truncate(@as(u32, @bitCast(raw)));
}

pub fn sin(x: f32) f32 {
    return sin_table[tableIndex(x * 10430.378)];
}

pub fn cos(x: f32) f32 {
    return sin_table[tableIndex(x * 10430.378 + 16384.0)];
}

pub fn sqrtF(x: f64) f32 {
    return @floatCast(@sqrt(x));
}

pub fn floorFloat(x: f32) i32 {
    return @intFromFloat(@floor(x));
}

pub fn floorDouble(x: f64) i32 {
    return @intFromFloat(@floor(x));
}

pub fn absMax(a: f64, b: f64) f64 {
    return @max(@abs(a), @abs(b));
}

test "sin/cos track the real functions across a wide sweep" {
    var x: f32 = -100.0;
    while (x <= 100.0) : (x += 0.12) {
        try std.testing.expectApproxEqAbs(@sin(x), sin(x), 1.0e-4);
        try std.testing.expectApproxEqAbs(@cos(x), cos(x), 1.0e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), sin(x) * sin(x) + cos(x) * cos(x), 1.0e-4);
    }
}

test "the table's quarter-turn anchors are exact" {
    try std.testing.expectEqual(@as(f32, 0.0), sin(0.0));
    try std.testing.expectEqual(@as(f32, 1.0), cos(0.0));
    try std.testing.expectEqual(@as(f32, 1.0), sin(std.math.pi / 2.0));
    try std.testing.expectEqual(@as(f32, -1.0), cos(std.math.pi));
}

test "the table wraps rather than trapping on extreme arguments" {
    inline for (.{ 1.0e9, -1.0e9, 3.0e38, -3.0e38, std.math.inf(f32), -std.math.inf(f32) }) |x| {
        try std.testing.expect(@abs(sin(x)) <= 1.0);
        try std.testing.expect(@abs(cos(x)) <= 1.0);
    }

    try std.testing.expectEqual(@as(f32, 0.0), sin(std.math.nan(f32)));
    try std.testing.expectEqual(@as(f32, 0.0), cos(std.math.nan(f32)));
}

test "absMax picks the larger magnitude whatever the signs" {
    try std.testing.expectEqual(@as(f64, 5.0), absMax(-5.0, 3.0));
    try std.testing.expectEqual(@as(f64, 5.0), absMax(3.0, -5.0));
    try std.testing.expectEqual(@as(f64, 5.0), absMax(-5.0, -3.0));
    try std.testing.expectEqual(@as(f64, 0.0), absMax(0.0, -0.0));
}

test "sqrtF rounds to the float precision the reference works in" {
    try std.testing.expectEqual(@as(f32, 5.0), sqrtF(25.0));
    try std.testing.expectEqual(@as(f32, @floatCast(@sqrt(@as(f64, 2.0)))), sqrtF(2.0));
}

test "floorFloat/floorDouble round toward negative infinity" {
    try std.testing.expectEqual(@as(i32, 1), floorFloat(1.5));
    try std.testing.expectEqual(@as(i32, -2), floorFloat(-1.5));
    try std.testing.expectEqual(@as(i32, -1), floorDouble(-0.5));
}

test "floorFloat/floorDouble leave exact integers and zero alone" {
    try std.testing.expectEqual(@as(i32, 3), floorFloat(3.0));
    try std.testing.expectEqual(@as(i32, -3), floorFloat(-3.0));
    try std.testing.expectEqual(@as(i32, 0), floorDouble(0.0));
    try std.testing.expectEqual(@as(i32, 0), floorDouble(-0.0));
    try std.testing.expectEqual(@as(i32, -1), floorDouble(-0.000001));
}
