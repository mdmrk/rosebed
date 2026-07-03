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

pub const RenderDistance = enum(u2) {
    far,
    normal,
    short,
    tiny,

    pub fn label(self: RenderDistance) []const u8 {
        return switch (self) {
            .far => "Far",
            .normal => "Normal",
            .short => "Short",
            .tiny => "Tiny",
        };
    }

    pub fn next(self: RenderDistance) RenderDistance {
        return @enumFromInt(@intFromEnum(self) +% 1);
    }
};

pub const FramerateLimit = enum(u2) {
    max,
    balanced,
    power_saver,

    pub fn label(self: FramerateLimit) []const u8 {
        return switch (self) {
            .max => "Max FPS",
            .balanced => "Balanced",
            .power_saver => "Power saver",
        };
    }

    pub fn next(self: FramerateLimit) FramerateLimit {
        return switch (self) {
            .max => .balanced,
            .balanced => .power_saver,
            .power_saver => .max,
        };
    }
};

pub const GuiScale = enum(u2) {
    auto,
    small,
    normal,
    large,

    pub fn label(self: GuiScale) []const u8 {
        return switch (self) {
            .auto => "Auto",
            .small => "Small",
            .normal => "Normal",
            .large => "Large",
        };
    }

    pub fn next(self: GuiScale) GuiScale {
        return @enumFromInt(@intFromEnum(self) +% 1);
    }

    pub fn limit(self: GuiScale) f32 {
        return if (self == .auto) 1000 else @floatFromInt(@intFromEnum(self));
    }
};

const Settings = @This();

music_volume: f32 = 1.0,
sound_volume: f32 = 1.0,
sensitivity: f32 = 0.5,
invert_mouse: bool = false,
difficulty: Difficulty = .normal,
fancy_graphics: bool = true,
render_distance: RenderDistance = .far,
ambient_occlusion: bool = true,
framerate_limit: FramerateLimit = .balanced,
anaglyph: bool = false,
view_bobbing: bool = true,
gui_scale: GuiScale = .auto,
advanced_opengl: bool = false,

test "difficulty cycles through all four and wraps" {
    try std.testing.expectEqual(Difficulty.easy, Difficulty.peaceful.next());
    try std.testing.expectEqual(Difficulty.hard, Difficulty.normal.next());
    try std.testing.expectEqual(Difficulty.peaceful, Difficulty.hard.next());
}
