const std = @import("std");
const gl = @import("gl");

const Atlas = @import("atlas.zig");
const Font = @import("font.zig");
const MeshBuilder = @import("mesh_builder.zig");
const Shader = @import("shader.zig");
const button = @import("button.zig");
const gui = @import("gui.zig");

const title_color: [4]u8 = .{ 255, 255, 255, 255 };

pub const Action = enum { resume_game, options, quit_to_title };

const Entry = struct { button: button.Button, action: ?Action };

fn entries(scaled_width: f32, scaled_height: f32) [5]Entry {
    const cx = @floor(scaled_width / 2.0);
    const quarter = @floor(scaled_height / 4.0);
    const top = quarter - 16.0;
    return .{
        .{ .button = .{ .x = cx - 100, .y = top + 24, .w = 200, .label = "Back to game", .enabled = true }, .action = .resume_game },
        .{ .button = .{ .x = cx - 100, .y = top + 48, .w = 98, .label = "Achievements", .enabled = false }, .action = null },
        .{ .button = .{ .x = cx + 2, .y = top + 48, .w = 98, .label = "Statistics", .enabled = false }, .action = null },
        .{ .button = .{ .x = cx - 100, .y = top + 96, .w = 200, .label = "Options...", .enabled = true }, .action = .options },
        .{ .button = .{ .x = cx - 100, .y = top + 120, .w = 200, .label = "Save and quit to title", .enabled = true }, .action = .quit_to_title },
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
) !void {
    const gx = ui.mouse_x / ui.res.factor;
    const gy = ui.mouse_y / ui.res.factor;

    gl.Disable(gl.DEPTH_TEST);
    gl.Enable(gl.BLEND);
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

    var backgrounds: MeshBuilder = .{};
    defer backgrounds.deinit(ui.gpa);
    var text: MeshBuilder = .{};
    defer text.deinit(ui.gpa);

    try gui.appendVeil(&backgrounds, ui.gpa, ui.res);

    for (entries(ui.res.width, ui.res.height)) |entry| {
        const hovered = button.contains(entry.button, gx, gy);
        try button.append(&backgrounds, &text, ui.gpa, ui.font, entry.button, hovered, ui.res);
    }

    const title = "Game menu";
    const title_width: f32 = @floatFromInt(ui.font.stringWidth(title));
    try gui.appendTextColor(&text, ui.gpa, ui.font, title, @floor(ui.res.width / 2.0) - @floor(title_width / 2.0), 40, title_color, ui.res);

    try gui.drawTexturedMesh(&backgrounds, ui.shader, ui.textures.gui);
    try gui.drawTexturedMesh(&text, ui.shader, ui.font);

    gl.Disable(gl.BLEND);
    gl.Enable(gl.DEPTH_TEST);
}

test "back to game resumes" {
    try std.testing.expectEqual(@as(?Action, .resume_game), actionAt(320, 168, gui.scaledResolution(640, 480, 1000)));
}

test "save and quit to title returns to the title screen" {
    try std.testing.expectEqual(@as(?Action, .quit_to_title), actionAt(320, 360, gui.scaledResolution(640, 480, 1000)));
}

test "clicking a disabled button does nothing" {
    try std.testing.expectEqual(@as(?Action, null), actionAt(200, 200, gui.scaledResolution(640, 480, 1000)));
}

test "clicking empty space does nothing" {
    try std.testing.expectEqual(@as(?Action, null), actionAt(10, 10, gui.scaledResolution(640, 480, 1000)));
}
