const std = @import("std");

pub const Difficulty = enum(u2) {
    peaceful,
    easy,
    normal,
    hard,

    pub fn label(self: Difficulty) []const u8 {
        return switch (self) {
            .peaceful => "Peaceful",
            .easy => "Easy",
            .normal => "Normal",
            .hard => "Hard",
        };
    }

    pub fn next(self: Difficulty) Difficulty {
        return @enumFromInt(@intFromEnum(self) +% 1);
    }
};

const Settings = @This();

music_volume: f32 = 1.0,
sound_volume: f32 = 1.0,
sensitivity: f32 = 0.5,
invert_mouse: bool = false,
difficulty: Difficulty = .normal,

test "difficulty cycles through all four and wraps" {
    try std.testing.expectEqual(Difficulty.easy, Difficulty.peaceful.next());
    try std.testing.expectEqual(Difficulty.hard, Difficulty.normal.next());
    try std.testing.expectEqual(Difficulty.peaceful, Difficulty.hard.next());
}
