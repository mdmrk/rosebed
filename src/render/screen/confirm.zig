const std = @import("std");

const gl = @import("gl");

const button = @import("../button.zig");
const gui = @import("../gui.zig");
const MeshBuilder = @import("../MeshBuilder.zig");

const title_color: [4]u8 = .{ 255, 255, 255, 255 };
const message_color: [4]u8 = .{ 255, 255, 255, 255 };

pub const Hit = enum { confirm, cancel };

fn buttons(res: gui.Scaled, confirm_label: []const u8) [2]struct { button: button.Button, hit: Hit } {
    const cx = @floor(res.width / 2.0);
    const top = @floor(res.height / 6.0) + 96;
    return .{
        .{ .button = .{ .x = cx - 155, .y = top, .w = 150, .label = confirm_label, .enabled = true }, .hit = .confirm },
        .{ .button = .{ .x = cx - 155 + 160, .y = top, .w = 150, .label = "Cancel", .enabled = true }, .hit = .cancel },
    };
}

pub fn hitAt(mouse_x: f32, mouse_y: f32, res: gui.Scaled, confirm_label: []const u8) ?Hit {
    const gx = mouse_x / res.factor;
    const gy = mouse_y / res.factor;
    for (buttons(res, confirm_label)) |entry| {
        if (button.contains(entry.button, gx, gy)) return entry.hit;
    }
    return null;
}

pub fn draw(ui: gui.Ui, title: []const u8, message: []const u8, confirm_label: []const u8) !void {
    const gx = ui.mouse_x / ui.res.factor;
    const gy = ui.mouse_y / ui.res.factor;

    gl.Disable(gl.DEPTH_TEST);
    gl.Enable(gl.BLEND);
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

    try gui.drawDirtBackground(ui);

    var backgrounds: MeshBuilder = .{};
    defer backgrounds.deinit(ui.gpa);
    var text: MeshBuilder = .{};
    defer text.deinit(ui.gpa);

    for (buttons(ui.res, confirm_label)) |entry| {
        try button.append(&backgrounds, &text, ui.gpa, ui.font, entry.button, button.contains(entry.button, gx, gy), ui.res);
    }

    const cx = @floor(ui.res.width / 2.0);
    const title_width: f32 = @floatFromInt(ui.font.stringWidth(title));
    try gui.appendTextColor(&text, ui.gpa, ui.font, title, cx - @floor(title_width / 2.0), 70, title_color, ui.res);

    const message_width: f32 = @floatFromInt(ui.font.stringWidth(message));
    try gui.appendTextColor(&text, ui.gpa, ui.font, message, cx - @floor(message_width / 2.0), 90, message_color, ui.res);

    try gui.drawTexturedMesh(&backgrounds, ui.shader, ui.textures.gui);
    try gui.drawTexturedMesh(&text, ui.shader, ui.font);

    gl.Disable(gl.BLEND);
    gl.Enable(gl.DEPTH_TEST);
}

test "the confirm and cancel buttons sit side by side" {
    const res = gui.scaledResolution(640, 480, 1000);
    const cx = @floor(res.width / 2.0);
    const y = (@floor(res.height / 6.0) + 96 + 10) * res.factor;

    try std.testing.expectEqual(@as(?Hit, .confirm), hitAt((cx - 80) * res.factor, y, res, "Delete"));
    try std.testing.expectEqual(@as(?Hit, .cancel), hitAt((cx + 80) * res.factor, y, res, "Delete"));
    try std.testing.expectEqual(@as(?Hit, null), hitAt(cx * res.factor, 0, res, "Delete"));
}
