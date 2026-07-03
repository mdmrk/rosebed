const std = @import("std");
const gl = @import("gl");

const Atlas = @import("atlas.zig");
const Font = @import("font.zig");
const MeshBuilder = @import("mesh_builder.zig");
const Shader = @import("shader.zig");
const button = @import("button.zig");
const hud = @import("hud.zig");

const logo_texture_size: f32 = 256;
const logo_width: f32 = 256;
const logo_height: f32 = 44;
const dirt_tile_scale: f32 = 32;
const dirt_tint: [4]u8 = .{ 64, 64, 64, 255 };
const version_color: [4]u8 = .{ 80, 80, 80, 255 };
const copyright_color: [4]u8 = .{ 255, 255, 255, 255 };

pub const Action = enum { singleplayer, options, quit };

const Entry = struct { button: button.Button, action: ?Action };

fn entries(scaled_width: f32, scaled_height: f32) [5]Entry {
    const cx = @floor(scaled_width / 2.0);
    const top = @floor(scaled_height / 4.0) + 48.0;
    return .{
        .{ .button = .{ .x = cx - 100, .y = top, .w = 200, .label = "Singleplayer", .enabled = true }, .action = .singleplayer },
        .{ .button = .{ .x = cx - 100, .y = top + 24, .w = 200, .label = "Multiplayer", .enabled = false }, .action = null },
        .{ .button = .{ .x = cx - 100, .y = top + 48, .w = 200, .label = "Mods and Texture Packs", .enabled = false }, .action = null },
        .{ .button = .{ .x = cx - 100, .y = top + 84, .w = 98, .label = "Options...", .enabled = true }, .action = .options },
        .{ .button = .{ .x = cx + 2, .y = top + 84, .w = 98, .label = "Quit Game", .enabled = true }, .action = .quit },
    };
}

pub fn actionAt(mouse_x: f32, mouse_y: f32, screen_width: f32, screen_height: f32) ?Action {
    const res = hud.scaledResolution(screen_width, screen_height);
    const gx = mouse_x / res.factor;
    const gy = mouse_y / res.factor;
    for (entries(res.width, res.height)) |entry| {
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
    const res = hud.scaledResolution(screen_width, screen_height);
    const gx = mouse_x / res.factor;
    const gy = mouse_y / res.factor;

    gl.Disable(gl.DEPTH_TEST);
    gl.Enable(gl.BLEND);
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

    var dirt: MeshBuilder = .{};
    defer dirt.deinit(gpa);
    const dirt_uv: Atlas.Uv = .{ .u0 = 0, .v0 = 0, .u1 = res.width / dirt_tile_scale, .v1 = res.height / dirt_tile_scale };
    try hud.appendRectColor(&dirt, gpa, 0, 0, res.width, res.height, dirt_uv, dirt_tint, res);
    try hud.drawTexturedMesh(&dirt, icon_shader, dirt_texture);

    var logo: MeshBuilder = .{};
    defer logo.deinit(gpa);
    const logo_left = @floor(res.width / 2.0) - logo_width / 2.0;
    try hud.appendRect(&logo, gpa, logo_left, 30, logo_width, logo_height, hud.pixelUv(0, 0, logo_width, logo_height, logo_texture_size, logo_texture_size), res);
    try hud.drawTexturedMesh(&logo, icon_shader, logo_texture);

    var backgrounds: MeshBuilder = .{};
    defer backgrounds.deinit(gpa);
    var text: MeshBuilder = .{};
    defer text.deinit(gpa);

    for (entries(res.width, res.height)) |entry| {
        const hovered = button.contains(entry.button, gx, gy);
        try button.append(&backgrounds, &text, gpa, font, entry.button, hovered, res);
    }

    try hud.appendTextColor(&text, gpa, font, "Minecraft Beta 1.7.3", 2, 2, version_color, res);
    const copyright = "Copyright Mojang AB. Do not distribute.";
    const copyright_width: f32 = @floatFromInt(font.stringWidth(copyright));
    try hud.appendTextColor(&text, gpa, font, copyright, res.width - copyright_width - 2, res.height - 10, copyright_color, res);

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
