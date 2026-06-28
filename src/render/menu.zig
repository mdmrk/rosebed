const std = @import("std");
const gl = @import("gl");

const Atlas = @import("atlas.zig");
const Font = @import("font.zig");
const MeshBuilder = @import("mesh_builder.zig");
const Shader = @import("shader.zig");
const button = @import("button.zig");
const hud = @import("hud.zig");

const gui_texture_size: f32 = 256;
const overlay_color: [4]u8 = .{ 16, 16, 16, 196 };
const title_color: [4]u8 = .{ 255, 255, 255, 255 };

pub const Action = enum { resume_game, options, quit_to_title };

const Entry = struct { button: button.Button, action: ?Action };

fn entries(scaled_width: f32, scaled_height: f32) [5]Entry {
    const cx = scaled_width / 2.0;
    const quarter = scaled_height / 4.0;
    const top = quarter - 16.0;
    return .{
        .{ .button = .{ .x = cx - 100, .y = top + 24, .w = 200, .label = "Back to game", .enabled = true }, .action = .resume_game },
        .{ .button = .{ .x = cx - 100, .y = top + 48, .w = 98, .label = "Achievements", .enabled = false }, .action = null },
        .{ .button = .{ .x = cx + 2, .y = top + 48, .w = 98, .label = "Statistics", .enabled = false }, .action = null },
        .{ .button = .{ .x = cx - 100, .y = top + 96, .w = 200, .label = "Options...", .enabled = true }, .action = .options },
        .{ .button = .{ .x = cx - 100, .y = top + 120, .w = 200, .label = "Save and quit to title", .enabled = true }, .action = .quit_to_title },
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

    for (entries(scaled_width, scaled_height)) |entry| {
        const hovered = button.contains(entry.button, gx, gy);
        try button.append(&backgrounds, &text, gpa, font, entry.button, hovered, scaled_width, scaled_height);
    }

    const title = "Game menu";
    const title_width: f32 = @floatFromInt(font.stringWidth(title));
    try hud.appendTextColor(&text, gpa, font, title, scaled_width / 2.0 - title_width / 2.0, 40, title_color, scaled_width, scaled_height);

    try hud.drawTexturedMesh(&backgrounds, icon_shader, gui_texture);
    try hud.drawTexturedMesh(&text, icon_shader, font);

    gl.Disable(gl.BLEND);
    gl.Enable(gl.DEPTH_TEST);
}

test "back to game resumes" {
    try std.testing.expectEqual(@as(?Action, .resume_game), actionAt(320, 168, 640, 480));
}

test "save and quit to title returns to the title screen" {
    try std.testing.expectEqual(@as(?Action, .quit_to_title), actionAt(320, 360, 640, 480));
}

test "clicking a disabled button does nothing" {
    try std.testing.expectEqual(@as(?Action, null), actionAt(200, 200, 640, 480));
}

test "clicking empty space does nothing" {
    try std.testing.expectEqual(@as(?Action, null), actionAt(10, 10, 640, 480));
}
