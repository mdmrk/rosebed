const std = @import("std");
const gl = @import("gl");
const game = @import("game");

const Atlas = @import("atlas.zig");
const Font = @import("font.zig");
const MeshBuilder = @import("mesh_builder.zig");
const Shader = @import("shader.zig");
const button = @import("button.zig");
const gui = @import("gui.zig");

const gui_texture_size: f32 = 256;
const opt_width: f32 = 150;
const dirt_tile_scale: f32 = 32;
const dirt_tint: [4]u8 = .{ 64, 64, 64, 255 };
const title_color: [4]u8 = .{ 255, 255, 255, 255 };

pub const Backdrop = enum { dirt, veil };
pub const Slider = enum { music, sound, sensitivity };
pub const Hit = union(enum) { slider: Slider, toggle_invert, cycle_difficulty, video, controls, done };

const Control = struct { x: f32, y: f32, w: f32, hit: Hit };

fn controls(scaled_width: f32, scaled_height: f32) [8]Control {
    const cx = @floor(scaled_width / 2.0);
    const sixth = @floor(scaled_height / 6.0);
    const left = cx - 155.0;
    const right = cx - 155.0 + 160.0;
    return .{
        .{ .x = left, .y = sixth, .w = opt_width, .hit = .{ .slider = .music } },
        .{ .x = right, .y = sixth, .w = opt_width, .hit = .{ .slider = .sound } },
        .{ .x = left, .y = sixth + 24, .w = opt_width, .hit = .toggle_invert },
        .{ .x = right, .y = sixth + 24, .w = opt_width, .hit = .{ .slider = .sensitivity } },
        .{ .x = left, .y = sixth + 48, .w = opt_width, .hit = .cycle_difficulty },
        .{ .x = cx - 100, .y = sixth + 96 + 12, .w = 200, .hit = .video },
        .{ .x = cx - 100, .y = sixth + 120 + 12, .w = 200, .hit = .controls },
        .{ .x = cx - 100, .y = sixth + 168, .w = 200, .hit = .done },
    };
}

pub fn hitAt(mouse_x: f32, mouse_y: f32, res: gui.Scaled) ?Hit {
    const gx = mouse_x / res.factor;
    const gy = mouse_y / res.factor;
    for (controls(res.width, res.height)) |control| {
        if (gx >= control.x and gx < control.x + control.w and gy >= control.y and gy < control.y + button.height) {
            return control.hit;
        }
    }
    return null;
}

fn sliderX(which: Slider, scaled_width: f32) f32 {
    const cx = @floor(scaled_width / 2.0);
    return switch (which) {
        .music => cx - 155.0,
        .sensitivity => cx - 155.0 + 160.0,
        .sound => cx - 155.0 + 160.0,
    };
}

pub fn sliderValueAt(which: Slider, mouse_x: f32, res: gui.Scaled) f32 {
    const gx = mouse_x / res.factor;
    const x = sliderX(which, res.width);
    const value = (gx - (x + 4.0)) / (opt_width - 8.0);
    return std.math.clamp(value, 0.0, 1.0);
}

fn percentLabel(buf: []u8, prefix: []const u8, value: f32, scale: f32) []const u8 {
    if (value == 0.0) return std.fmt.bufPrint(buf, "{s}OFF", .{prefix}) catch prefix;
    return std.fmt.bufPrint(buf, "{s}{d}%", .{ prefix, @as(u32, @intFromFloat(value * scale)) }) catch prefix;
}

fn controlLabel(hit: Hit, settings: game.Settings, buf: []u8) []const u8 {
    return switch (hit) {
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
    res: gui.Scaled,
) !void {
    try button.appendBackground(bg, gpa, control.x, control.y, control.w, 0, res);
    const handle_x = control.x + value * (control.w - 8.0);
    try gui.appendRect(bg, gpa, handle_x, control.y, 4, button.height, gui.pixelUv(0, 66, 4, button.height, gui_texture_size, gui_texture_size), res);
    try gui.appendRect(bg, gpa, handle_x + 4, control.y, 4, button.height, gui.pixelUv(196, 66, 4, button.height, gui_texture_size, gui_texture_size), res);
    const color = if (hovered) button.text_hover else button.text_normal;
    try button.appendLabel(text, gpa, font, control.x, control.y, control.w, label, color, res);
}

pub fn draw(
    ui: gui.Ui,
    settings: game.Settings,
    backdrop: Backdrop,
) !void {
    const gx = ui.mouse_x / ui.res.factor;
    const gy = ui.mouse_y / ui.res.factor;

    gl.Disable(gl.DEPTH_TEST);
    gl.Enable(gl.BLEND);
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

    var back: MeshBuilder = .{};
    defer back.deinit(ui.gpa);
    switch (backdrop) {
        .dirt => {
            const dirt_uv: Atlas.Uv = .{ .u0 = 0, .v0 = 0, .u1 = ui.res.width / dirt_tile_scale, .v1 = ui.res.height / dirt_tile_scale };
            try gui.appendRectColor(&back, ui.gpa, 0, 0, ui.res.width, ui.res.height, dirt_uv, dirt_tint, ui.res);
            try gui.drawTexturedMesh(&back, ui.shader, ui.textures.dirt);
        },
        .veil => {
            try gui.appendVeil(&back, ui.gpa, ui.res);
            try gui.drawTexturedMesh(&back, ui.shader, ui.textures.gui);
        },
    }

    var backgrounds: MeshBuilder = .{};
    defer backgrounds.deinit(ui.gpa);
    var text: MeshBuilder = .{};
    defer text.deinit(ui.gpa);

    for (controls(ui.res.width, ui.res.height)) |control| {
        const hovered = gx >= control.x and gx < control.x + control.w and gy >= control.y and gy < control.y + button.height;
        var buf: [64]u8 = undefined;
        const label = controlLabel(control.hit, settings, &buf);
        switch (control.hit) {
            .slider => |s| {
                const value = switch (s) {
                    .music => settings.music_volume,
                    .sound => settings.sound_volume,
                    .sensitivity => settings.sensitivity,
                };
                try appendSlider(&backgrounds, &text, ui.gpa, ui.font, control, value, label, hovered, ui.res);
            },
            else => try button.append(&backgrounds, &text, ui.gpa, ui.font, .{ .x = control.x, .y = control.y, .w = control.w, .label = label, .enabled = true }, hovered, ui.res),
        }
    }

    const title = "Options";
    const title_width: f32 = @floatFromInt(ui.font.stringWidth(title));
    try gui.appendTextColor(&text, ui.gpa, ui.font, title, @floor(ui.res.width / 2.0) - @floor(title_width / 2.0), 20, title_color, ui.res);

    try gui.drawTexturedMesh(&backgrounds, ui.shader, ui.textures.gui);
    try gui.drawTexturedMesh(&text, ui.shader, ui.font);

    gl.Disable(gl.BLEND);
    gl.Enable(gl.DEPTH_TEST);
}

test "clicking Done returns the done hit" {
    try std.testing.expectEqual(@as(?Hit, .done), hitAt(320, 416, gui.scaledResolution(640, 480, 1000)));
}

test "clicking the difficulty toggle returns cycle_difficulty" {
    try std.testing.expectEqual(@as(?Hit, .cycle_difficulty), hitAt(80, 176, gui.scaledResolution(640, 480, 1000)));
}

test "clicking a slider returns its id" {
    try std.testing.expectEqual(@as(?Hit, .{ .slider = .music }), hitAt(80, 80, gui.scaledResolution(640, 480, 1000)));
}

test "video settings and controls both open" {
    const res = gui.scaledResolution(640, 480, 1000);
    try std.testing.expectEqual(@as(?Hit, .video), hitAt(320, 296, res));
    try std.testing.expectEqual(@as(?Hit, .controls), hitAt(320, 344, res));
}

test "slider value maps click x to 0..1 clamped" {
    try std.testing.expectEqual(@as(f32, 0.0), sliderValueAt(.music, 0, gui.scaledResolution(640, 480, 1000)));
    try std.testing.expect(sliderValueAt(.music, 100000, gui.scaledResolution(640, 480, 1000)) == 1.0);
}
