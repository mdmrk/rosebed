const std = @import("std");
const gl = @import("gl");

const Atlas = @import("atlas.zig");
const Font = @import("font.zig");
const MeshBuilder = @import("mesh_builder.zig");
const Shader = @import("shader.zig");
const hud = @import("hud.zig");

const gui_texture_size: f32 = 256;
const button_height: f32 = 20;
const button_tex_row: f32 = 46;
const overlay_color: [4]u8 = .{ 16, 16, 16, 196 };

const text_normal: [4]u8 = .{ 224, 224, 224, 255 };
const text_hover: [4]u8 = .{ 255, 255, 160, 255 };
const text_disabled: [4]u8 = .{ 160, 160, 160, 255 };
const title_color: [4]u8 = .{ 255, 255, 255, 255 };

pub const Action = enum { resume_game };

pub const Button = struct {
    x: f32,
    y: f32,
    w: f32,
    label: []const u8,
    enabled: bool,
    action: ?Action,
};

pub fn buttons(scaled_width: f32, scaled_height: f32) [5]Button {
    const cx = scaled_width / 2.0;
    const quarter = scaled_height / 4.0;
    const top = quarter - 16.0;
    return .{
        .{ .x = cx - 100, .y = top + 24, .w = 200, .label = "Back to game", .enabled = true, .action = .resume_game },
        .{ .x = cx - 100, .y = top + 48, .w = 98, .label = "Achievements", .enabled = false, .action = null },
        .{ .x = cx + 2, .y = top + 48, .w = 98, .label = "Statistics", .enabled = false, .action = null },
        .{ .x = cx - 100, .y = top + 96, .w = 200, .label = "Options...", .enabled = false, .action = null },
        .{ .x = cx - 100, .y = top + 120, .w = 200, .label = "Save and quit to title", .enabled = false, .action = null },
    };
}

fn hoverState(button: Button, hovered: bool) f32 {
    if (!button.enabled) return 0;
    if (hovered) return 2;
    return 1;
}

pub fn actionAt(mouse_x: f32, mouse_y: f32, screen_width: f32, screen_height: f32) ?Action {
    const gx = mouse_x / hud.gui_scale;
    const gy = mouse_y / hud.gui_scale;
    const scaled_width = screen_width / hud.gui_scale;
    const scaled_height = screen_height / hud.gui_scale;
    for (buttons(scaled_width, scaled_height)) |button| {
        if (!button.enabled) continue;
        if (gx >= button.x and gx < button.x + button.w and gy >= button.y and gy < button.y + button_height) {
            return button.action;
        }
    }
    return null;
}

fn appendButton(
    bg: *MeshBuilder,
    text: *MeshBuilder,
    gpa: std.mem.Allocator,
    font: Font,
    button: Button,
    hovered: bool,
    scaled_width: f32,
    scaled_height: f32,
) !void {
    const row = button_tex_row + hoverState(button, hovered) * button_height;
    const half = button.w / 2.0;
    try hud.appendRect(bg, gpa, button.x, button.y, half, button_height, hud.pixelUv(0, row, half, button_height, gui_texture_size, gui_texture_size), scaled_width, scaled_height);
    try hud.appendRect(bg, gpa, button.x + half, button.y, half, button_height, hud.pixelUv(200 - half, row, half, button_height, gui_texture_size, gui_texture_size), scaled_width, scaled_height);

    const color = if (!button.enabled) text_disabled else if (hovered) text_hover else text_normal;
    const label_width: f32 = @floatFromInt(font.stringWidth(button.label));
    const text_x = button.x + button.w / 2.0 - label_width / 2.0;
    const text_y = button.y + (button_height - Font.glyph_size) / 2.0;
    try hud.appendTextColor(text, gpa, font, button.label, text_x, text_y, color, scaled_width, scaled_height);
}

pub fn draw(
    gpa: std.mem.Allocator,
    icon_shader: Shader,
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

    var backgrounds: MeshBuilder = .{};
    defer backgrounds.deinit(gpa);
    var text: MeshBuilder = .{};
    defer text.deinit(gpa);

    const opaque_texel: Atlas.Uv = .{ .u0 = 2.5 / gui_texture_size, .v0 = 2.5 / gui_texture_size, .u1 = 2.5 / gui_texture_size, .v1 = 2.5 / gui_texture_size };
    try hud.appendRectColor(&backgrounds, gpa, 0, 0, scaled_width, scaled_height, opaque_texel, overlay_color, scaled_width, scaled_height);

    for (buttons(scaled_width, scaled_height)) |button| {
        const hovered = gx >= button.x and gx < button.x + button.w and gy >= button.y and gy < button.y + button_height;
        try appendButton(&backgrounds, &text, gpa, font, button, hovered, scaled_width, scaled_height);
    }

    const title = "Game menu";
    const title_width: f32 = @floatFromInt(font.stringWidth(title));
    try hud.appendTextColor(&text, gpa, font, title, scaled_width / 2.0 - title_width / 2.0, 40, title_color, scaled_width, scaled_height);

    try hud.drawTexturedMesh(&backgrounds, icon_shader, gui_texture);
    try hud.drawTexturedMesh(&text, icon_shader, font);

    gl.Disable(gl.BLEND);
    gl.Enable(gl.DEPTH_TEST);
}

test "back to game is the only clickable button and it resumes" {
    try std.testing.expectEqual(@as(?Action, .resume_game), actionAt(320, 168, 640, 480));
}

test "clicking a disabled button does nothing" {
    try std.testing.expectEqual(@as(?Action, null), actionAt(320, 280, 640, 480));
}

test "clicking empty space does nothing" {
    try std.testing.expectEqual(@as(?Action, null), actionAt(10, 10, 640, 480));
}

test "only back to game is enabled" {
    const bs = buttons(320, 240);
    var enabled_count: usize = 0;
    for (bs) |b| {
        if (b.enabled) enabled_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), enabled_count);
}
