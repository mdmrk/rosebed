const std = @import("std");
const gl = @import("gl");
const game = @import("game");

const Atlas = @import("atlas.zig");
const Font = @import("font.zig");
const MeshBuilder = @import("mesh_builder.zig");
const Shader = @import("shader.zig");
const button = @import("button.zig");
const hud = @import("hud.zig");

const gui_texture_size: f32 = 256;
const opt_width: f32 = 150;
const overlay_color: [4]u8 = .{ 16, 16, 16, 196 };
const dirt_tile_scale: f32 = 32;
const dirt_tint: [4]u8 = .{ 64, 64, 64, 255 };
const title_color: [4]u8 = .{ 255, 255, 255, 255 };

pub const Backdrop = enum { dirt, veil };
pub const Slider = enum { music, sound, sensitivity };
pub const Hit = union(enum) { slider: Slider, toggle_invert, cycle_difficulty, done };

const Kind = union(enum) { slider: Slider, toggle_invert, cycle_difficulty, video, controls, done };
const Control = struct { x: f32, y: f32, w: f32, kind: Kind, enabled: bool };

fn controls(scaled_width: f32, scaled_height: f32) [8]Control {
    const cx = scaled_width / 2.0;
    const sixth = scaled_height / 6.0;
    const left = cx - 155.0;
    const right = cx - 155.0 + 160.0;
    return .{
        .{ .x = left, .y = sixth, .w = opt_width, .kind = .{ .slider = .music }, .enabled = true },
        .{ .x = right, .y = sixth, .w = opt_width, .kind = .{ .slider = .sound }, .enabled = true },
        .{ .x = left, .y = sixth + 24, .w = opt_width, .kind = .toggle_invert, .enabled = true },
        .{ .x = right, .y = sixth + 24, .w = opt_width, .kind = .{ .slider = .sensitivity }, .enabled = true },
        .{ .x = left, .y = sixth + 48, .w = opt_width, .kind = .cycle_difficulty, .enabled = true },
        .{ .x = cx - 100, .y = sixth + 96 + 12, .w = 200, .kind = .video, .enabled = false },
        .{ .x = cx - 100, .y = sixth + 120 + 12, .w = 200, .kind = .controls, .enabled = false },
        .{ .x = cx - 100, .y = sixth + 168, .w = 200, .kind = .done, .enabled = true },
    };
}

fn kindHit(kind: Kind) ?Hit {
    return switch (kind) {
        .slider => |s| .{ .slider = s },
        .toggle_invert => .toggle_invert,
        .cycle_difficulty => .cycle_difficulty,
        .done => .done,
        .video, .controls => null,
    };
}

pub fn hitAt(mouse_x: f32, mouse_y: f32, screen_width: f32, screen_height: f32) ?Hit {
    const gx = mouse_x / hud.gui_scale;
    const gy = mouse_y / hud.gui_scale;
    const scaled_width = screen_width / hud.gui_scale;
    const scaled_height = screen_height / hud.gui_scale;
    for (controls(scaled_width, scaled_height)) |control| {
        if (!control.enabled) continue;
        if (gx >= control.x and gx < control.x + control.w and gy >= control.y and gy < control.y + button.height) {
            return kindHit(control.kind);
        }
    }
    return null;
}

fn sliderX(which: Slider, scaled_width: f32) f32 {
    const cx = scaled_width / 2.0;
    return switch (which) {
        .music => cx - 155.0,
        .sensitivity => cx - 155.0 + 160.0,
        .sound => cx - 155.0 + 160.0,
    };
}

pub fn sliderValueAt(which: Slider, mouse_x: f32, screen_width: f32) f32 {
    const gx = mouse_x / hud.gui_scale;
    const scaled_width = screen_width / hud.gui_scale;
    const x = sliderX(which, scaled_width);
    const value = (gx - (x + 4.0)) / (opt_width - 8.0);
    return std.math.clamp(value, 0.0, 1.0);
}

fn percentLabel(buf: []u8, prefix: []const u8, value: f32, scale: f32) []const u8 {
    if (value == 0.0) return std.fmt.bufPrint(buf, "{s}OFF", .{prefix}) catch prefix;
    return std.fmt.bufPrint(buf, "{s}{d}%", .{ prefix, @as(u32, @intFromFloat(value * scale)) }) catch prefix;
}

fn controlLabel(kind: Kind, settings: game.Settings, buf: []u8) []const u8 {
    return switch (kind) {
        .slider => |s| switch (s) {
            .music => percentLabel(buf, "Music: ", settings.music_volume, 100),
            .sound => percentLabel(buf, "Sound: ", settings.sound_volume, 100),
            .sensitivity => if (settings.sensitivity == 0.0)
                "Sensitivity: *yawn*"
            else if (settings.sensitivity == 1.0)
                "Sensitivity: HYPERSPEED!!!"
            else
                std.fmt.bufPrint(buf, "Sensitivity: {d}%", .{@as(u32, @intFromFloat(settings.sensitivity * 200.0))}) catch "Sensitivity: ",
        },
        .toggle_invert => if (settings.invert_mouse) "Invert Mouse: ON" else "Invert Mouse: OFF",
        .cycle_difficulty => std.fmt.bufPrint(buf, "Difficulty: {s}", .{settings.difficulty.label()}) catch "Difficulty: ",
        .video => "Video Settings...",
        .controls => "Controls...",
        .done => "Done",
    };
}

fn appendSlider(
    bg: *MeshBuilder,
    text: *MeshBuilder,
    gpa: std.mem.Allocator,
    font: Font,
    control: Control,
    value: f32,
    label: []const u8,
    hovered: bool,
    scaled_width: f32,
    scaled_height: f32,
) !void {
    try button.appendBackground(bg, gpa, control.x, control.y, control.w, 0, scaled_width, scaled_height);
    const handle_x = control.x + value * (control.w - 8.0);
    try hud.appendRect(bg, gpa, handle_x, control.y, 4, button.height, hud.pixelUv(0, 66, 4, button.height, gui_texture_size, gui_texture_size), scaled_width, scaled_height);
    try hud.appendRect(bg, gpa, handle_x + 4, control.y, 4, button.height, hud.pixelUv(196, 66, 4, button.height, gui_texture_size, gui_texture_size), scaled_width, scaled_height);
    const color = if (hovered) button.text_hover else button.text_normal;
    try button.appendLabel(text, gpa, font, control.x, control.y, control.w, label, color, scaled_width, scaled_height);
}

pub fn draw(
    gpa: std.mem.Allocator,
    icon_shader: Shader,
    dirt_texture: Atlas,
    gui_texture: Atlas,
    font: Font,
    settings: game.Settings,
    backdrop: Backdrop,
    mouse_x: f32,
    mouse_y: f32,
    screen_width: f32,
    screen_height: f32,
) !void {
    const scaled_width = screen_width / hud.gui_scale;
    const scaled_height = screen_height / hud.gui_scale;
    const gx = mouse_x / hud.gui_scale;
    const gy = mouse_y / hud.gui_scale;

    gl.Disable(gl.DEPTH_TEST);
    gl.Enable(gl.BLEND);
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

    var back: MeshBuilder = .{};
    defer back.deinit(gpa);
    switch (backdrop) {
        .dirt => {
            const dirt_uv: Atlas.Uv = .{ .u0 = 0, .v0 = 0, .u1 = scaled_width / dirt_tile_scale, .v1 = scaled_height / dirt_tile_scale };
            try hud.appendRectColor(&back, gpa, 0, 0, scaled_width, scaled_height, dirt_uv, dirt_tint, scaled_width, scaled_height);
            try hud.drawTexturedMesh(&back, icon_shader, dirt_texture);
        },
        .veil => {
            const opaque_texel: Atlas.Uv = .{ .u0 = 2.5 / gui_texture_size, .v0 = 2.5 / gui_texture_size, .u1 = 2.5 / gui_texture_size, .v1 = 2.5 / gui_texture_size };
            try hud.appendRectColor(&back, gpa, 0, 0, scaled_width, scaled_height, opaque_texel, overlay_color, scaled_width, scaled_height);
            try hud.drawTexturedMesh(&back, icon_shader, gui_texture);
        },
    }

    var backgrounds: MeshBuilder = .{};
    defer backgrounds.deinit(gpa);
    var text: MeshBuilder = .{};
    defer text.deinit(gpa);

    for (controls(scaled_width, scaled_height)) |control| {
        const hovered = control.enabled and gx >= control.x and gx < control.x + control.w and gy >= control.y and gy < control.y + button.height;
        var buf: [64]u8 = undefined;
        const label = controlLabel(control.kind, settings, &buf);
        switch (control.kind) {
            .slider => |s| {
                const value = switch (s) {
                    .music => settings.music_volume,
                    .sound => settings.sound_volume,
                    .sensitivity => settings.sensitivity,
                };
                try appendSlider(&backgrounds, &text, gpa, font, control, value, label, hovered, scaled_width, scaled_height);
            },
            else => try button.append(&backgrounds, &text, gpa, font, .{ .x = control.x, .y = control.y, .w = control.w, .label = label, .enabled = control.enabled }, hovered, scaled_width, scaled_height),
        }
    }

    const title = "Options";
    const title_width: f32 = @floatFromInt(font.stringWidth(title));
    try hud.appendTextColor(&text, gpa, font, title, scaled_width / 2.0 - title_width / 2.0, 20, title_color, scaled_width, scaled_height);

    try hud.drawTexturedMesh(&backgrounds, icon_shader, gui_texture);
    try hud.drawTexturedMesh(&text, icon_shader, font);

    gl.Disable(gl.BLEND);
    gl.Enable(gl.DEPTH_TEST);
}

test "clicking Done returns the done hit" {
    try std.testing.expectEqual(@as(?Hit, .done), hitAt(320, 416, 640, 480));
}

test "clicking the difficulty toggle returns cycle_difficulty" {
    try std.testing.expectEqual(@as(?Hit, .cycle_difficulty), hitAt(80, 176, 640, 480));
}

test "clicking a slider returns its id" {
    try std.testing.expectEqual(@as(?Hit, .{ .slider = .music }), hitAt(80, 80, 640, 480));
}

test "disabled video/controls buttons are not hit" {
    try std.testing.expectEqual(@as(?Hit, null), hitAt(320, 296, 640, 480));
}

test "slider value maps click x to 0..1 clamped" {
    try std.testing.expectEqual(@as(f32, 0.0), sliderValueAt(.music, 0, 640));
    try std.testing.expect(sliderValueAt(.music, 100000, 640) == 1.0);
}
