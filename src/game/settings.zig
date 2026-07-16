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

    fn targetFps(self: FramerateLimit) u32 {
        return switch (self) {
            .max => 200,
            .balanced => 120,
            .power_saver => 40,
        };
    }

    pub fn rebuildDeadlineNs(self: FramerateLimit, frame_end_ns: u64) u64 {
        if (self == .max) return 0;
        return frame_end_ns +% std.time.ns_per_s / self.targetFps();
    }

    pub fn fpsCap(self: FramerateLimit, refresh_rate: ?f32) ?f32 {
        return switch (self) {
            .max => null,
            .balanced => refresh_rate,
            .power_saver => @floatFromInt(self.targetFps()),
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

pub const Binding = enum {
    forward,
    left,
    back,
    right,
    jump,
    sneak,
    drop,
    inventory,
    chat,
    fog,

    pub fn label(self: Binding) []const u8 {
        return switch (self) {
            .forward => "Forward",
            .left => "Left",
            .back => "Back",
            .right => "Right",
            .jump => "Jump",
            .sneak => "Sneak",
            .drop => "Drop",
            .inventory => "Inventory",
            .chat => "Chat",
            .fog => "Toggle Fog",
        };
    }
};

pub const KeyBindings = std.EnumArray(Binding, u32);

const scancode_mask: u32 = 1 << 30;
const left_shift: u32 = scancode_mask | 225;

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
keys: KeyBindings = .init(.{
    .forward = 'w',
    .left = 'a',
    .back = 's',
    .right = 'd',
    .jump = ' ',
    .sneak = left_shift,
    .drop = 'q',
    .inventory = 'e',
    .chat = 't',
    .fog = 'f',
}),

test "difficulty cycles through all four and wraps" {
    try std.testing.expectEqual(Difficulty.easy, Difficulty.peaceful.next());
    try std.testing.expectEqual(Difficulty.hard, Difficulty.normal.next());
    try std.testing.expectEqual(Difficulty.peaceful, Difficulty.hard.next());
}

test "balanced sleeps to the monitor, power saver to forty, max fps not at all" {
    try std.testing.expectEqual(@as(?f32, null), FramerateLimit.max.fpsCap(144));
    try std.testing.expectEqual(@as(?f32, 144), FramerateLimit.balanced.fpsCap(144));
    try std.testing.expectEqual(@as(?f32, 40), FramerateLimit.power_saver.fpsCap(144));
}

test "balanced runs uncapped when the monitor reports no refresh rate" {
    try std.testing.expectEqual(@as(?f32, null), FramerateLimit.balanced.fpsCap(null));
    try std.testing.expectEqual(@as(?f32, 40), FramerateLimit.power_saver.fpsCap(null));
}

test "max fps leaves no time for distant chunks, the others budget a frame" {
    try std.testing.expectEqual(@as(u64, 0), FramerateLimit.max.rebuildDeadlineNs(1_000));
    try std.testing.expectEqual(
        @as(u64, 1_000 + std.time.ns_per_s / 120),
        FramerateLimit.balanced.rebuildDeadlineNs(1_000),
    );
    try std.testing.expectEqual(
        @as(u64, 1_000 + std.time.ns_per_s / 40),
        FramerateLimit.power_saver.rebuildDeadlineNs(1_000),
    );
}

test "bindings default to the vanilla layout" {
    const settings: Settings = .{};
    try std.testing.expectEqual(@as(u32, 'w'), settings.keys.get(.forward));
    try std.testing.expectEqual(@as(u32, 'a'), settings.keys.get(.left));
    try std.testing.expectEqual(@as(u32, ' '), settings.keys.get(.jump));
    try std.testing.expectEqual(@as(u32, 'e'), settings.keys.get(.inventory));
}

test "rebinding a key replaces the old one" {
    var settings: Settings = .{};
    settings.keys.set(.forward, 'z');
    try std.testing.expectEqual(@as(u32, 'z'), settings.keys.get(.forward));
    try std.testing.expectEqual(@as(u32, 'a'), settings.keys.get(.left));
}
