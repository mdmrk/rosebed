const std = @import("std");

const JavaRandom = @import("java_random.zig");

const Weather = @This();

pub const rain_threshold: f32 = 0.2;
pub const thunder_threshold: f32 = 0.9;
pub const strength_step: f64 = 0.01;
pub const flash_ticks: i32 = 2;

pub const clear_spell: i32 = 168000;
pub const wet_spell: i32 = 12000;
pub const storm_spell: i32 = 12000;
pub const storm_floor: i32 = 3600;
pub const spell_floor: i32 = 12000;

raining: bool = false,
rain_time: i32 = 0,
thundering: bool = false,
thunder_time: i32 = 0,
rain_strength: f32 = 0,
prev_rain_strength: f32 = 0,
thunder_strength: f32 = 0,
prev_thunder_strength: f32 = 0,
flash: i32 = 0,

fn countdown(time: *i32, active: *bool, rand: *JavaRandom, quiet_spell: i32, busy_spell: i32, floor: i32) void {
    if (time.* <= 0) {
        time.* = rand.nextIntBound(if (active.*) busy_spell else quiet_spell) + floor;
        return;
    }
    time.* -= 1;
    if (time.* <= 0) active.* = !active.*;
}

fn ease(strength: *f32, active: bool) void {
    const step: f64 = if (active) strength_step else -strength_step;
    strength.* = std.math.clamp(@as(f32, @floatCast(@as(f64, strength.*) + step)), 0.0, 1.0);
}

pub fn tick(self: *Weather, rand: *JavaRandom) void {
    countdown(&self.thunder_time, &self.thundering, rand, clear_spell, storm_spell, storm_floor);
    countdown(&self.rain_time, &self.raining, rand, clear_spell, wet_spell, spell_floor);
    self.tickStrength();
}

pub fn tickStrength(self: *Weather) void {
    if (self.flash > 0) self.flash -= 1;

    self.prev_rain_strength = self.rain_strength;
    ease(&self.rain_strength, self.raining);

    self.prev_thunder_strength = self.thunder_strength;
    ease(&self.thunder_strength, self.thundering);
}

pub fn rainStrength(self: Weather, partial_ticks: f32) f32 {
    return self.prev_rain_strength + (self.rain_strength - self.prev_rain_strength) * partial_ticks;
}

pub fn thunderStrength(self: Weather, partial_ticks: f32) f32 {
    return (self.prev_thunder_strength +
        (self.thunder_strength - self.prev_thunder_strength) * partial_ticks) * self.rainStrength(partial_ticks);
}

pub fn isRaining(self: Weather) bool {
    return self.rainStrength(1.0) > rain_threshold;
}

pub fn isThundering(self: Weather) bool {
    return self.thunderStrength(1.0) > thunder_threshold;
}

pub fn settle(self: *Weather) void {
    if (!self.raining) return;
    self.rain_strength = 1.0;
    self.prev_rain_strength = 1.0;
    if (!self.thundering) return;
    self.thunder_strength = 1.0;
    self.prev_thunder_strength = 1.0;
}

pub fn clear(self: *Weather) void {
    self.rain_time = 0;
    self.raining = false;
    self.thunder_time = 0;
    self.thundering = false;
}

test "a dry spell is rolled long and a wet one short" {
    var rand = JavaRandom.init(7);
    var weather: Weather = .{};

    weather.tick(&rand);
    try std.testing.expect(weather.rain_time >= spell_floor);
    try std.testing.expect(weather.rain_time < spell_floor + clear_spell);
    try std.testing.expect(!weather.raining);

    weather.rain_time = 1;
    weather.tick(&rand);
    try std.testing.expect(weather.raining);

    weather.tick(&rand);
    try std.testing.expect(weather.rain_time >= spell_floor);
    try std.testing.expect(weather.rain_time < spell_floor + wet_spell);
}

test "rain fades in and out a hundredth at a time" {
    var rand = JavaRandom.init(1);
    var weather: Weather = .{ .raining = true, .rain_time = 10000 };

    for (0..50) |_| weather.tick(&rand);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), weather.rain_strength, 1.0e-4);

    weather.raining = false;
    for (0..25) |_| weather.tick(&rand);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), weather.rain_strength, 1.0e-4);

    for (0..100) |_| weather.tick(&rand);
    try std.testing.expectEqual(@as(f32, 0.0), weather.rain_strength);
}

test "it only counts as raining once the sky is more than a fifth wet" {
    var weather: Weather = .{};
    weather.rain_strength = 0.2;
    weather.prev_rain_strength = 0.2;
    try std.testing.expect(!weather.isRaining());

    weather.rain_strength = 0.21;
    weather.prev_rain_strength = 0.21;
    try std.testing.expect(weather.isRaining());
}

test "a storm needs the rain behind it to count as thunder" {
    var weather: Weather = .{};
    weather.thunder_strength = 1.0;
    weather.prev_thunder_strength = 1.0;
    try std.testing.expect(!weather.isThundering());

    weather.rain_strength = 1.0;
    weather.prev_rain_strength = 1.0;
    try std.testing.expect(weather.isThundering());

    weather.rain_strength = 0.5;
    weather.prev_rain_strength = 0.5;
    try std.testing.expect(!weather.isThundering());
}

test "loading a wet world starts it already pouring" {
    var weather: Weather = .{ .raining = true, .thundering = true };
    weather.settle();

    try std.testing.expectEqual(@as(f32, 1.0), weather.rain_strength);
    try std.testing.expectEqual(@as(f32, 1.0), weather.thunder_strength);
    try std.testing.expect(weather.isRaining());
    try std.testing.expect(weather.isThundering());
}
