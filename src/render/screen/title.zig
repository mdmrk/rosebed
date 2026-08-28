const std = @import("std");
const builtin = @import("builtin");

const gl = @import("gl");
const math = @import("math");

const Atlas = @import("../Atlas.zig");
const button = @import("../button.zig");
const gui = @import("../gui.zig");
const MeshBuilder = @import("../MeshBuilder.zig");

const wasm = builtin.cpu.arch.isWasm();

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
const github_gap: f32 = 4;
const github_icon_size: f32 = 16;

pub const Action = enum { singleplayer, multiplayer, texture_packs, options, quit, github };

const Entry = struct { button: button.Button, action: ?Action };

const hide_quit = wasm;
const menu_len = if (hide_quit) 4 else 5;

fn entries(scaled_width: f32, scaled_height: f32) [menu_len]Entry {
    const cx = @floor(scaled_width / 2.0);
    const top = @floor(scaled_height / 4.0) + 48.0;
    const bottom_row = if (hide_quit) top + 72 else top + 84;

    var list: [menu_len]Entry = undefined;
    list[0] = .{ .button = .{ .x = cx - 100, .y = top, .w = 200, .label = "Singleplayer", .enabled = true }, .action = .singleplayer };
    list[1] = .{ .button = .{ .x = cx - 100, .y = top + 24, .w = 200, .label = "Multiplayer", .enabled = !wasm }, .action = .multiplayer };
    list[2] = .{ .button = .{ .x = cx - 100, .y = top + 48, .w = 200, .label = "Mods and Texture Packs", .enabled = true }, .action = .texture_packs };
    list[3] = .{ .button = .{ .x = cx - 100, .y = bottom_row, .w = if (hide_quit) 200 else 98, .label = "Options...", .enabled = true }, .action = .options };
    if (!hide_quit) {
        list[4] = .{ .button = .{ .x = cx + 2, .y = bottom_row, .w = 98, .label = "Quit Game", .enabled = true }, .action = .quit };
    }
    return list;
}

fn githubButton(scaled_width: f32, scaled_height: f32) button.Button {
    const options = entries(scaled_width, scaled_height)[3].button;
    return .{
        .x = options.x - button.height - github_gap,
        .y = options.y,
        .w = button.height,
        .label = "",
        .enabled = true,
    };
}

pub fn actionAt(mouse_x: f32, mouse_y: f32, res: gui.Scaled) ?Action {
    const gx = mouse_x / res.factor;
    const gy = mouse_y / res.factor;
    for (entries(res.width, res.height)) |entry| {
        if (entry.button.enabled and button.contains(entry.button, gx, gy)) return entry.action;
    }
    if (wasm and button.contains(githubButton(res.width, res.height), gx, gy)) return .github;
    return null;
}

pub fn draw(
    ui: gui.Ui,
    splash: []const u8,
    time_ms: u64,
    github_icon: ?Atlas,
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

    const github: ?button.Button = if (wasm) githubButton(ui.res.width, ui.res.height) else null;
    if (github) |entry| {
        const state: f32 = if (button.contains(entry, gx, gy)) 2 else 1;
        try button.appendBackground(&backgrounds, ui.gpa, entry.x, entry.y, entry.w, state, ui.res);
    }

    const splash_width: f32 = @floatFromInt(ui.font.stringWidth(splash));
    const pulse: f32 = @floatFromInt(time_ms % 1000);
    const throb = 1.8 - @abs(math.util.sin(pulse / 1000.0 * std.math.pi * 2.0) * 0.1);
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

    if (github) |entry| if (github_icon) |atlas| {
        var mark: MeshBuilder = .{};
        defer mark.deinit(ui.gpa);
        const inset = @floor((entry.w - github_icon_size) / 2.0);
        const uv = gui.pixelUv(0, 0, github_icon_size, github_icon_size, github_icon_size, github_icon_size);
        try gui.appendRect(&mark, ui.gpa, entry.x + inset, entry.y + inset, github_icon_size, github_icon_size, uv, ui.res);
        try gui.drawTexturedMesh(&mark, ui.shader, atlas);
    };

    gl.Disable(gl.BLEND);
    gl.Enable(gl.DEPTH_TEST);
}

test "singleplayer is clickable and enters the world" {
    try std.testing.expectEqual(@as(?Action, .singleplayer), actionAt(320, 240, gui.scaledResolution(640, 480, 1000)));
}

test "quit game is clickable" {
    try std.testing.expectEqual(@as(?Action, .quit), actionAt(340, 408, gui.scaledResolution(640, 480, 1000)));
}

test "the github button is a square sitting left of options" {
    const res = gui.scaledResolution(640, 480, 1000);
    const options = entries(res.width, res.height)[3].button;
    const entry = githubButton(res.width, res.height);
    try std.testing.expectEqual(button.height, entry.w);
    try std.testing.expectEqual(options.y, entry.y);
    try std.testing.expectEqual(options.x - github_gap, entry.x + entry.w);
}

test "multiplayer sits between singleplayer and the texture packs" {
    try std.testing.expectEqual(@as(?Action, .multiplayer), actionAt(320, 288, gui.scaledResolution(640, 480, 1000)));
}
