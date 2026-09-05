const std = @import("std");

const math = @import("math");

const button = @import("button.zig");
const gui = @import("gui.zig");
const MeshBuilder = @import("MeshBuilder.zig");

const title_color: [4]u8 = .{ 255, 255, 255, 255 };
const saving_label = "Saving level..";
const saving_hold_ticks: u32 = 20;

pub const Action = enum { resume_game, achievements, statistics, options, quit_to_title };

const Entry = struct { button: button.Button, action: ?Action };

fn entries(scaled_width: f32, scaled_height: f32) [5]Entry {
    const cx = @floor(scaled_width / 2.0);
    const quarter = @floor(scaled_height / 4.0);
    const top = quarter - 16.0;
    return .{
        .{ .button = .{ .x = cx - 100, .y = top + 24, .w = 200, .label = "Back to game", .enabled = true }, .action = .resume_game },
        .{ .button = .{ .x = cx - 100, .y = top + 48, .w = 98, .label = "Achievements", .enabled = true }, .action = .achievements },
        .{ .button = .{ .x = cx + 2, .y = top + 48, .w = 98, .label = "Statistics", .enabled = true }, .action = .statistics },
        .{ .button = .{ .x = cx - 100, .y = top + 96, .w = 200, .label = "Options...", .enabled = true }, .action = .options },
        .{ .button = .{ .x = cx - 100, .y = top + 120, .w = 200, .label = "Save and quit to title", .enabled = true }, .action = .quit_to_title },
    };
}

pub fn actionAt(mouse_x: f32, mouse_y: f32, res: gui.Scaled) ?Action {
    const gx = mouse_x / res.factor;
    const gy = mouse_y / res.factor;
    const list = entries(res.width, res.height);
    if (button.indexAt(list, gx, gy)) |index| return list[index].action;
    return null;
}

pub fn savingColor(ticks: u32, partial: f32) [4]u8 {
    const phase = (@as(f32, @floatFromInt(ticks % 10)) + partial) / 10.0;
    const pulse = math.util.sin(phase * std.math.pi * 2.0) * 0.2 + 0.8;
    const level: u8 = @intFromFloat(255.0 * pulse);
    return .{ level, level, level, 255 };
}

pub fn draw(
    ui: gui.Ui,
    saving: bool,
    ticks: u32,
    partial: f32,
) !void {
    const gx = ui.mouse_x / ui.res.factor;
    const gy = ui.mouse_y / ui.res.factor;

    gui.beginOverlay();

    var backgrounds: MeshBuilder = .{};
    defer backgrounds.deinit(ui.gpa);
    var text: MeshBuilder = .{};
    defer text.deinit(ui.gpa);

    try gui.appendVeil(&backgrounds, ui.gpa, ui.res);

    for (entries(ui.res.width, ui.res.height)) |entry| {
        const hovered = button.contains(entry.button, gx, gy);
        try button.append(&backgrounds, &text, ui.gpa, ui.font, entry.button, hovered, ui.res);
    }

    if (saving or ticks < saving_hold_ticks) {
        try gui.appendTextColor(&text, ui.gpa, ui.font, saving_label, 8, ui.res.height - 16, savingColor(ticks, partial), ui.res);
    }

    const title = "Game menu";
    try gui.appendCenteredText(&text, ui.gpa, ui.font, title, 40, title_color, ui.res);

    try gui.drawTexturedMesh(&backgrounds, ui.shader, ui.textures.gui);
    try gui.drawTexturedMesh(&text, ui.shader, ui.font);

    gui.endOverlay();
}

test "back to game resumes" {
    try std.testing.expectEqual(@as(?Action, .resume_game), actionAt(320, 168, gui.scaledResolution(640, 480, 1000)));
}

test "save and quit to title returns to the title screen" {
    try std.testing.expectEqual(@as(?Action, .quit_to_title), actionAt(320, 360, gui.scaledResolution(640, 480, 1000)));
}

test "every button on the pause menu leads somewhere" {
    for (entries(640, 480)) |entry| {
        try std.testing.expect(entry.button.enabled);
        try std.testing.expect(entry.action != null);
    }
}

test "statistics opens from the right half of the second row" {
    const res = gui.scaledResolution(640, 480, 1000);
    try std.testing.expectEqual(@as(?Action, .statistics), actionAt(340, 216, res));
}

test "achievements opens from the left half of the second row" {
    const res = gui.scaledResolution(640, 480, 1000);
    try std.testing.expectEqual(@as(?Action, .achievements), actionAt(300, 216, res));
}

test "the saving pulse swings between the original's dim and bright grey" {
    try std.testing.expectEqual([4]u8{ 204, 204, 204, 255 }, savingColor(0, 0));

    var dimmest: u8 = 255;
    var brightest: u8 = 0;
    for (0..10) |tick| {
        for (0..10) |step| {
            const color = savingColor(@intCast(tick), @as(f32, @floatFromInt(step)) / 10.0);
            try std.testing.expectEqual(color[0], color[1]);
            try std.testing.expectEqual(color[0], color[2]);
            try std.testing.expectEqual(@as(u8, 255), color[3]);
            dimmest = @min(dimmest, color[0]);
            brightest = @max(brightest, color[0]);
        }
    }
    try std.testing.expectEqual(@as(u8, 153), dimmest);
    try std.testing.expectEqual(@as(u8, 255), brightest);
}

test "clicking empty space does nothing" {
    try std.testing.expectEqual(@as(?Action, null), actionAt(10, 10, gui.scaledResolution(640, 480, 1000)));
}
