const std = @import("std");
const gl = @import("gl");

const Atlas = @import("atlas.zig");
const Font = @import("font.zig");
const MeshBuilder = @import("mesh_builder.zig");
const Shader = @import("shader.zig");
const button = @import("button.zig");
const hud = @import("hud.zig");

const logo_texture_size: f32 = 256;
const dirt_tile_scale: f32 = 32;
const dirt_tint: [4]u8 = .{ 64, 64, 64, 255 };
const version_color: [4]u8 = .{ 80, 80, 80, 255 };
const copyright_color: [4]u8 = .{ 255, 255, 255, 255 };

pub const Action = enum { singleplayer, quit };

const Entry = struct { button: button.Button, action: ?Action };

fn entries(scaled_width: f32, scaled_height: f32) [5]Entry {
    const cx = scaled_width / 2.0;
    const top = scaled_height / 4.0 + 48.0;
    return .{
        .{ .button = .{ .x = cx - 100, .y = top, .w = 200, .label = "Singleplayer", .enabled = true }, .action = .singleplayer },
        .{ .button = .{ .x = cx - 100, .y = top + 24, .w = 200, .label = "Multiplayer", .enabled = false }, .action = null },
        .{ .button = .{ .x = cx - 100, .y = top + 48, .w = 200, .label = "Mods and Texture Packs", .enabled = false }, .action = null },
        .{ .button = .{ .x = cx - 100, .y = top + 84, .w = 98, .label = "Options...", .enabled = false }, .action = null },
        .{ .button = .{ .x = cx + 2, .y = top + 84, .w = 98, .label = "Quit Game", .enabled = true }, .action = .quit },
    };
}

pub fn actionAt(mouse_x: f32, mouse_y: f32, screen_width: f32, screen_height: f32) ?Action {
    const gx = mouse_x / hud.gui_scale;
    const gy = mouse_y / hud.gui_scale;
    const scaled_width = screen_width / hud.gui_scale;
    const scaled_height = screen_height / hud.gui_scale;
    for (entries(scaled_width, scaled_height)) |entry| {
        if (entry.button.enabled and button.contains(entry.button, gx, gy)) return entry.action;
    }
    return null;
}

pub fn draw(
    gpa: std.mem.Allocator,
    icon_shader: Shader,
    dirt_texture: Atlas,
    logo_texture: Atlas,
    gui_texture: Atlas,
    font: Font,
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

    var dirt: MeshBuilder = .{};
    defer dirt.deinit(gpa);
    const dirt_uv: Atlas.Uv = .{ .u0 = 0, .v0 = 0, .u1 = scaled_width / dirt_tile_scale, .v1 = scaled_height / dirt_tile_scale };
    try hud.appendRectColor(&dirt, gpa, 0, 0, scaled_width, scaled_height, dirt_uv, dirt_tint, scaled_width, scaled_height);
    try hud.drawTexturedMesh(&dirt, icon_shader, dirt_texture);

    var logo: MeshBuilder = .{};
    defer logo.deinit(gpa);
    const logo_left = scaled_width / 2.0 - 137.0;
    try hud.appendRect(&logo, gpa, logo_left, 30, 155, 44, hud.pixelUv(0, 0, 155, 44, logo_texture_size, logo_texture_size), scaled_width, scaled_height);
    try hud.appendRect(&logo, gpa, logo_left + 155, 30, 155, 44, hud.pixelUv(0, 45, 155, 44, logo_texture_size, logo_texture_size), scaled_width, scaled_height);
    try hud.drawTexturedMesh(&logo, icon_shader, logo_texture);

    var backgrounds: MeshBuilder = .{};
    defer backgrounds.deinit(gpa);
    var text: MeshBuilder = .{};
    defer text.deinit(gpa);

    for (entries(scaled_width, scaled_height)) |entry| {
        const hovered = button.contains(entry.button, gx, gy);
        try button.append(&backgrounds, &text, gpa, font, entry.button, hovered, scaled_width, scaled_height);
    }

    try hud.appendTextColor(&text, gpa, font, "Minecraft Beta 1.7.3", 2, 2, version_color, scaled_width, scaled_height);
    const copyright = "Copyright Mojang AB. Do not distribute.";
    const copyright_width: f32 = @floatFromInt(font.stringWidth(copyright));
    try hud.appendTextColor(&text, gpa, font, copyright, scaled_width - copyright_width - 2, scaled_height - 10, copyright_color, scaled_width, scaled_height);

    try hud.drawTexturedMesh(&backgrounds, icon_shader, gui_texture);
    try hud.drawTexturedMesh(&text, icon_shader, font);

    gl.Disable(gl.BLEND);
    gl.Enable(gl.DEPTH_TEST);
}

test "singleplayer is clickable and enters the world" {
    try std.testing.expectEqual(@as(?Action, .singleplayer), actionAt(320, 240, 640, 480));
}

test "quit game is clickable" {
    try std.testing.expectEqual(@as(?Action, .quit), actionAt(340, 408, 640, 480));
}

test "multiplayer is disabled offline" {
    try std.testing.expectEqual(@as(?Action, null), actionAt(320, 288, 640, 480));
}
