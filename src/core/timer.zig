//! Fixed-rate game timer ported from Minecraft Beta 1.7.3's `Timer`. Tracks
//! how many logic ticks have elapsed since the last frame, plus a fractional
//! remainder used to interpolate rendering between two tick states.
const std = @import("std");

const Timer = @This();

const max_ticks_per_frame = 10;

ticks_per_second: f32,
timer_speed: f32 = 1.0,
last_time_ns: u64,
elapsed_ticks: i32 = 0,
elapsed_partial_ticks: f32 = 0.0,
render_partial_ticks: f32 = 0.0,

pub fn init(ticks_per_second: f32, now_ns: u64) Timer {
    return .{ .ticks_per_second = ticks_per_second, .last_time_ns = now_ns };
}

// The original derived elapsed time from two clocks (a coarse wall clock
// resynced against a monotonic one) to smooth over System.currentTimeMillis
// jumps. The caller's `now_ns` is already monotonic, so that resync isn't
// needed here.
pub fn advance(self: *Timer, now_ns: u64) void {
    var dt: f64 = @as(f64, @floatFromInt(now_ns - self.last_time_ns)) / std.time.ns_per_s;
    self.last_time_ns = now_ns;
    dt = std.math.clamp(dt, 0.0, 1.0);

    const partial: f64 = @as(f64, self.elapsed_partial_ticks) + dt * @as(f64, self.timer_speed) * @as(f64, self.ticks_per_second);
    self.elapsed_partial_ticks = @floatCast(partial);
    self.elapsed_ticks = @intFromFloat(self.elapsed_partial_ticks);
    self.elapsed_partial_ticks -= @as(f32, @floatFromInt(self.elapsed_ticks));
    if (self.elapsed_ticks > max_ticks_per_frame) self.elapsed_ticks = max_ticks_per_frame;
    self.render_partial_ticks = self.elapsed_partial_ticks;
}

test "advance produces one tick per 1/20s at 20 ticks/second" {
    var t = Timer.init(20.0, 0);
    t.advance(std.time.ns_per_s / 20);
    try std.testing.expectEqual(@as(i32, 1), t.elapsed_ticks);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), t.render_partial_ticks, 1.0e-4);
}

test "advance accumulates a fractional remainder" {
    var t = Timer.init(20.0, 0);
    t.advance(std.time.ns_per_s / 40); // half a tick
    try std.testing.expectEqual(@as(i32, 0), t.elapsed_ticks);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), t.render_partial_ticks, 1.0e-4);
}

test "advance caps ticks per frame to avoid a spiral of death" {
    var t = Timer.init(20.0, 0);
    t.advance(std.time.ns_per_s * 5); // 5 seconds stalled -> 100 ticks owed
    try std.testing.expectEqual(@as(i32, 10), t.elapsed_ticks);
}
