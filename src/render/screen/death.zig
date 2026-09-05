const std = @import("std");

const button = @import("../button.zig");
const gui = @import("../gui.zig");
const MeshBuilder = @import("../MeshBuilder.zig");

const title_color: [4]u8 = .{ 255, 255, 255, 255 };
const veil_top: [4]u8 = .{ 80, 0, 0, 96 };
const veil_bottom: [4]u8 = .{ 128, 48, 48, 160 };

pub const Action = enum { respawn, title_menu };

const Entry = struct { button: button.Button, action: Action };

fn entries(res: gui.Scaled) [2]Entry {
    const cx = @floor(res.width / 2.0);
    const quarter = @floor(res.height / 4.0);
    return .{
        .{ .button = .{ .x = cx - 100, .y = quarter + 72, .w = 200, .label = "Respawn", .enabled = true }, .action = .respawn },
        .{ .button = .{ .x = cx - 100, .y = quarter + 96, .w = 200, .label = "Title menu", .enabled = true }, .action = .title_menu },
    };
}

pub fn actionAt(mouse_x: f32, mouse_y: f32, res: gui.Scaled) ?Action {
    const gx = mouse_x / res.factor;
    const gy = mouse_y / res.factor;
    for (entries(res)) |entry| {
        if (button.contains(entry.button, gx, gy)) return entry.action;
    }
    return null;
}

pub fn draw(ui: gui.Ui) !void {
    const gx = ui.mouse_x / ui.res.factor;
    const gy = ui.mouse_y / ui.res.factor;

    gui.beginOverlay();

    var backgrounds: MeshBuilder = .{};
    defer backgrounds.deinit(ui.gpa);
    var text: MeshBuilder = .{};
    defer text.deinit(ui.gpa);

    try gui.appendGradientRect(
        &backgrounds,
        ui.gpa,
        0,
        0,
        ui.res.width,
        ui.res.height,
        gui.opaque_texel,
        veil_top,
        veil_bottom,
        ui.res,
    );

    for (entries(ui.res)) |entry| {
        try button.append(&backgrounds, &text, ui.gpa, ui.font, entry.button, button.contains(entry.button, gx, gy), ui.res);
    }

    const title = "Game over!";
    try gui.appendCenteredText(&text, ui.gpa, ui.font, title, 30, title_color, ui.res);

    try gui.drawTexturedMesh(&backgrounds, ui.shader, ui.textures.gui);
    try gui.drawTexturedMesh(&text, ui.shader, ui.font);

    gui.endOverlay();
}

test "respawn sits above the title menu button" {
    const res = gui.scaledResolution(640, 480, 1000);
    const cx = res.width / 2.0 * res.factor;
    const quarter = @floor(res.height / 4.0);
    try std.testing.expectEqual(@as(?Action, .respawn), actionAt(cx, (quarter + 82) * res.factor, res));
    try std.testing.expectEqual(@as(?Action, .title_menu), actionAt(cx, (quarter + 106) * res.factor, res));
}

test "clicking empty space does nothing" {
    try std.testing.expectEqual(@as(?Action, null), actionAt(10, 10, gui.scaledResolution(640, 480, 1000)));
}
