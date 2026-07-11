const std = @import("std");
const gl = @import("gl");
const math = @import("math");

const MeshBuilder = @import("mesh_builder.zig");
const button = @import("button.zig");
const gui = @import("gui.zig");

const logo_texture_size: f32 = 256;
const logo_piece_width: f32 = 155;
const logo_height: f32 = 44;
const logo_layout_width: f32 = 274;
const logo_top: f32 = 30;
const version_color: [4]u8 = .{ 80, 80, 80, 255 };
const copyright_color: [4]u8 = .{ 255, 255, 255, 255 };
const splash_color: [4]u8 = .{ 255, 255, 0, 255 };
const splash_offset_x: f32 = 90;
const splash_y: f32 = 70;
const splash_rotation: f32 = -20.0 * std.math.pi / 180.0;

pub const Action = enum { singleplayer, options, quit };

const Entry = struct { button: button.Button, action: ?Action };

fn entries(scaled_width: f32, scaled_height: f32) [5]Entry {
    const cx = @floor(scaled_width / 2.0);
    const top = @floor(scaled_height / 4.0) + 48.0;
    return .{
        .{ .button = .{ .x = cx - 100, .y = top, .w = 200, .label = "Singleplayer", .enabled = true }, .action = .singleplayer },
        .{ .button = .{ .x = cx - 100, .y = top + 24, .w = 200, .label = "Multiplayer", .enabled = false }, .action = null },
        .{ .button = .{ .x = cx - 100, .y = top + 48, .w = 200, .label = "Mods and Texture Packs", .enabled = true }, .action = null },
        .{ .button = .{ .x = cx - 100, .y = top + 84, .w = 98, .label = "Options...", .enabled = true }, .action = .options },
        .{ .button = .{ .x = cx + 2, .y = top + 84, .w = 98, .label = "Quit Game", .enabled = true }, .action = .quit },
    };
}

pub fn actionAt(mouse_x: f32, mouse_y: f32, res: gui.Scaled) ?Action {
    const gx = mouse_x / res.factor;
    const gy = mouse_y / res.factor;
    for (entries(res.width, res.height)) |entry| {
        if (entry.button.enabled and button.contains(entry.button, gx, gy)) return entry.action;
    }
    return null;
}

pub fn draw(
    ui: gui.Ui,
    splash: []const u8,
    time_ms: u64,
) !void {
    const gx = ui.mouse_x / ui.res.factor;
    const gy = ui.mouse_y / ui.res.factor;

    gl.Disable(gl.DEPTH_TEST);
    gl.Enable(gl.BLEND);
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

    try gui.drawDirtBackground(ui);

    var logo: MeshBuilder = .{};
    defer logo.deinit(ui.gpa);
    const logo_left = @floor(ui.res.width / 2.0) - @floor(logo_layout_width / 2.0);
    try gui.appendRect(&logo, ui.gpa, logo_left, logo_top, logo_piece_width, logo_height, gui.pixelUv(0, 0, logo_piece_width, logo_height, logo_texture_size, logo_texture_size), ui.res);
    try gui.appendRect(&logo, ui.gpa, logo_left + logo_piece_width, logo_top, logo_piece_width, logo_height, gui.pixelUv(0, 45, logo_piece_width, logo_height, logo_texture_size, logo_texture_size), ui.res);
    try gui.drawTexturedMesh(&logo, ui.shader, ui.textures.logo);

    var backgrounds: MeshBuilder = .{};
    defer backgrounds.deinit(ui.gpa);
    var text: MeshBuilder = .{};
    defer text.deinit(ui.gpa);

    for (entries(ui.res.width, ui.res.height)) |entry| {
        const hovered = button.contains(entry.button, gx, gy);
        try button.append(&backgrounds, &text, ui.gpa, ui.font, entry.button, hovered, ui.res);
    }

    const splash_width: f32 = @floatFromInt(ui.font.stringWidth(splash));
    const pulse: f32 = @floatFromInt(time_ms % 1000);
    const throb = 1.8 - math.util.abs(math.util.sin(pulse / 1000.0 * std.math.pi * 2.0) * 0.1);
    const splash_transform: gui.Transform = .{
        .x = @floor(ui.res.width / 2.0) + splash_offset_x,
        .y = splash_y,
        .scale = throb * 100.0 / (splash_width + 32.0),
        .rotation = splash_rotation,
    };
    const splash_x = -@floor(splash_width / 2.0);
    try gui.appendTextTransformed(&text, ui.gpa, ui.font, splash, splash_x, -8, splash_color, splash_transform, ui.res);

    try gui.appendTextColor(&text, ui.gpa, ui.font, "Minecraft Beta 1.7.3", 2, 2, version_color, ui.res);
    const copyright = "Copyright Mojang AB. Do not distribute.";
    const copyright_width: f32 = @floatFromInt(ui.font.stringWidth(copyright));
    try gui.appendTextColor(&text, ui.gpa, ui.font, copyright, ui.res.width - copyright_width - 2, ui.res.height - 10, copyright_color, ui.res);

    try gui.drawTexturedMesh(&backgrounds, ui.shader, ui.textures.gui);
    try gui.drawTexturedMesh(&text, ui.shader, ui.font);

    gl.Disable(gl.BLEND);
    gl.Enable(gl.DEPTH_TEST);
}

test "singleplayer is clickable and enters the world" {
    try std.testing.expectEqual(@as(?Action, .singleplayer), actionAt(320, 240, gui.scaledResolution(640, 480, 1000)));
}

test "quit game is clickable" {
    try std.testing.expectEqual(@as(?Action, .quit), actionAt(340, 408, gui.scaledResolution(640, 480, 1000)));
}

test "multiplayer is disabled offline" {
    try std.testing.expectEqual(@as(?Action, null), actionAt(320, 288, gui.scaledResolution(640, 480, 1000)));
}
