const std = @import("std");
const builtin = @import("builtin");

const world = @import("world");
pub const Difficulty = world.Difficulty;

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
        return @fromBackingInt(@intCast(@backingInt(self) +% 1));
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
        return @fromBackingInt(@intCast(@backingInt(self) +% 1));
    }

    pub fn limit(self: GuiScale) f32 {
        return if (self == .auto) 1000 else @floatFromInt(@backingInt(self));
    }
};

pub const TouchScheme = enum(u2) {
    joystick,
    dpad,
    floating,

    pub fn label(self: TouchScheme) []const u8 {
        return switch (self) {
            .joystick => "Joystick",
            .dpad => "D-Pad",
            .floating => "Floating",
        };
    }

    pub fn next(self: TouchScheme) TouchScheme {
        return switch (self) {
            .joystick => .floating,
            .floating => .dpad,
            .dpad => .joystick,
        };
    }
};

pub const TextureFiltering = enum(u2) {
    off,
    mipmaps,
    anisotropic_4x,
    anisotropic_16x,

    pub fn label(self: TextureFiltering) []const u8 {
        return switch (self) {
            .off => "OFF",
            .mipmaps => "ON",
            .anisotropic_4x => "4x AF",
            .anisotropic_16x => "16x AF",
        };
    }

    pub fn next(self: TextureFiltering) TextureFiltering {
        return @fromBackingInt(@backingInt(self) +% 1);
    }

    pub fn usesMipmaps(self: TextureFiltering) bool {
        return self != .off;
    }

    pub fn anisotropy(self: TextureFiltering) f32 {
        return switch (self) {
            .off, .mipmaps => 1,
            .anisotropic_4x => 4,
            .anisotropic_16x => 16,
        };
    }
};

pub const TouchButtons = enum(u1) {
    full,
    minimal,

    pub fn label(self: TouchButtons) []const u8 {
        return switch (self) {
            .full => "Full",
            .minimal => "Minimal",
        };
    }

    pub fn next(self: TouchButtons) TouchButtons {
        return if (self == .full) .minimal else .full;
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

pub const default_skin = "Default";

pub const Name = struct {
    bytes: [128]u8 = @splat(0),
    len: usize = 0,

    pub fn init(value: []const u8) Name {
        var name: Name = .{};
        name.set(value);
        return name;
    }

    pub fn text(self: *const Name) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn set(self: *Name, value: []const u8) void {
        self.len = @min(value.len, self.bytes.len);
        @memcpy(self.bytes[0..self.len], value[0..self.len]);
    }
};

const scancode_mask: u32 = 1 << 30;
const left_shift: u32 = scancode_mask | 225;

const Settings = @This();

const touch = builtin.target.abi == .android or builtin.target.abi == .androideabi or builtin.target.os.tag == .ios;

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
texture_filtering: TextureFiltering = .off,
fullscreen: bool = false,
auto_jump: bool = touch,
touch_scheme: TouchScheme = .joystick,
touch_buttons: TouchButtons = .full,
skin: Name = .init(default_skin),
last_server: Name = .{},
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
