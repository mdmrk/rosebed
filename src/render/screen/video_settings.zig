const std = @import("std");
const builtin = @import("builtin");

const game = @import("game");
const gl = @import("gl");

const button = @import("../button.zig");
const gui = @import("../gui.zig");
const MeshBuilder = @import("../MeshBuilder.zig");
const options_screen = @import("options.zig");
pub const Backdrop = options_screen.Backdrop;

const wasm = builtin.cpu.arch.isWasm();
const android = builtin.abi == .android or builtin.abi == .androideabi;

const opt_width: f32 = 150;
const title_color: [4]u8 = .{ 255, 255, 255, 255 };

pub const Hit = enum {
    graphics,
    render_distance,
    ambient_occlusion,
    framerate_limit,
    anaglyph,
    view_bobbing,
    gui_scale,
    advanced_opengl,
    fullscreen,
    done,
};

const order = [_]Hit{
    .graphics,
    .render_distance,
    .ambient_occlusion,
    .framerate_limit,
    .anaglyph,
    .view_bobbing,
    .gui_scale,
    .advanced_opengl,
} ++ if (wasm or android) [_]Hit{} else [_]Hit{.fullscreen};

const Control = struct { x: f32, y: f32, w: f32, hit: Hit };

fn controls(scaled_width: f32, scaled_height: f32) [order.len + 1]Control {
    const cx = @floor(scaled_width / 2.0);
    const sixth = @floor(scaled_height / 6.0);
    var result: [order.len + 1]Control = undefined;
    for (order, 0..) |hit, i| {
        const column: f32 = @floatFromInt(i % 2);
        const row: f32 = @floatFromInt(i >> 1);
        result[i] = .{ .x = cx - 155.0 + column * 160.0, .y = sixth + row * 24.0, .w = opt_width, .hit = hit };
    }
    result[order.len] = .{ .x = cx - 100.0, .y = sixth + 168.0, .w = 200, .hit = .done };
    return result;
}

pub fn hitAt(mouse_x: f32, mouse_y: f32, res: gui.Scaled) ?Hit {
    const gx = mouse_x / res.factor;
    const gy = mouse_y / res.factor;
    for (controls(res.width, res.height)) |control| {
        if (button.contains(control, gx, gy)) {
            return control.hit;
        }
    }
    return null;
}

pub fn cycle(settings: *game.Settings, hit: Hit) void {
    switch (hit) {
        .graphics => settings.fancy_graphics = !settings.fancy_graphics,
        .render_distance => settings.render_distance = settings.render_distance.next(),
        .ambient_occlusion => settings.ambient_occlusion = !settings.ambient_occlusion,
        .framerate_limit => settings.framerate_limit = settings.framerate_limit.next(),
        .anaglyph => settings.anaglyph = !settings.anaglyph,
        .view_bobbing => settings.view_bobbing = !settings.view_bobbing,
        .gui_scale => settings.gui_scale = settings.gui_scale.next(),
        .advanced_opengl => settings.advanced_opengl = !settings.advanced_opengl,
        .fullscreen => settings.fullscreen = !settings.fullscreen,
        .done => {},
    }
}

fn onOff(value: bool) []const u8 {
    return if (value) "ON" else "OFF";
}

fn controlLabel(hit: Hit, settings: game.Settings, buf: []u8) []const u8 {
    return switch (hit) {
        .graphics => if (settings.fancy_graphics) "Graphics: Fancy" else "Graphics: Fast",
        .render_distance => std.fmt.bufPrint(buf, "Render Distance: {s}", .{settings.render_distance.label()}) catch "Render Distance: ",
        .ambient_occlusion => std.fmt.bufPrint(buf, "Smooth Lighting: {s}", .{onOff(settings.ambient_occlusion)}) catch "Smooth Lighting: ",
        .framerate_limit => std.fmt.bufPrint(buf, "Performance: {s}", .{settings.framerate_limit.label()}) catch "Performance: ",
        .anaglyph => std.fmt.bufPrint(buf, "3D Anaglyph: {s}", .{onOff(settings.anaglyph)}) catch "3D Anaglyph: ",
        .view_bobbing => std.fmt.bufPrint(buf, "View Bobbing: {s}", .{onOff(settings.view_bobbing)}) catch "View Bobbing: ",
        .gui_scale => std.fmt.bufPrint(buf, "GUI Scale: {s}", .{settings.gui_scale.label()}) catch "GUI Scale: ",
        .advanced_opengl => std.fmt.bufPrint(buf, "Advanced OpenGL: {s}", .{onOff(settings.advanced_opengl)}) catch "Advanced OpenGL: ",
        .fullscreen => std.fmt.bufPrint(buf, "Fullscreen: {s}", .{onOff(settings.fullscreen)}) catch "Fullscreen: ",
        .done => "Done",
    };
}

pub fn draw(
    ui: gui.Ui,
    settings: game.Settings,
    backdrop: Backdrop,
) !void {
    const gx = ui.mouse_x / ui.res.factor;
    const gy = ui.mouse_y / ui.res.factor;

    gl.Disable(gl.DEPTH_TEST);
    gl.Enable(gl.BLEND);
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

    try gui.drawBackdrop(ui, backdrop);

    var backgrounds: MeshBuilder = .{};
    defer backgrounds.deinit(ui.gpa);
    var text: MeshBuilder = .{};
    defer text.deinit(ui.gpa);

    for (controls(ui.res.width, ui.res.height)) |control| {
        const hovered = button.contains(control, gx, gy);
        var buf: [64]u8 = undefined;
        const label = controlLabel(control.hit, settings, &buf);
        try button.append(&backgrounds, &text, ui.gpa, ui.font, .{
            .x = control.x,
            .y = control.y,
            .w = control.w,
            .label = label,
            .enabled = true,
        }, hovered, ui.res);
    }

    const title = "Video Settings";
    const title_width: f32 = @floatFromInt(ui.font.stringWidth(title));
    try gui.appendTextColor(&text, ui.gpa, ui.font, title, @floor(ui.res.width / 2.0) - @floor(title_width / 2.0), 20, title_color, ui.res);

    try gui.drawTexturedMesh(&backgrounds, ui.shader, ui.textures.gui);
    try gui.drawTexturedMesh(&text, ui.shader, ui.font);

    gl.Disable(gl.BLEND);
    gl.Enable(gl.DEPTH_TEST);
}

test "the options fill two columns, row by row" {
    const res = gui.scaledResolution(640, 480, 1000);
    const list = controls(res.width, res.height);
    try std.testing.expectEqual(@as(f32, 5), list[0].x);
    try std.testing.expectEqual(@as(f32, 165), list[1].x);
    try std.testing.expectEqual(list[0].y, list[1].y);
    try std.testing.expectEqual(list[0].y + 24, list[2].y);
    try std.testing.expectEqual(list[0].y + 72, list[6].y);
}

test "the last row clears the Done button" {
    const res = gui.scaledResolution(640, 480, 1000);
    const list = controls(res.width, res.height);
    const last = list[order.len - 1];
    try std.testing.expectEqual(list[0].y + 24 * @as(f32, (order.len - 1) >> 1), last.y);
    try std.testing.expect(last.y + button.height <= list[order.len].y);
}

test "fullscreen is offered only where the window is not already the whole screen" {
    try std.testing.expectEqual(!wasm and !android, std.mem.indexOfScalar(Hit, &order, .fullscreen) != null);
}

test "fullscreen toggles off and on" {
    var settings: game.Settings = .{};
    try std.testing.expect(!settings.fullscreen);
    cycle(&settings, .fullscreen);
    try std.testing.expect(settings.fullscreen);
    cycle(&settings, .fullscreen);
    try std.testing.expect(!settings.fullscreen);
}

test "clicking Done returns the done hit" {
    const res = gui.scaledResolution(640, 480, 1000);
    try std.testing.expectEqual(@as(?Hit, .done), hitAt(320, 416, res));
}

test "graphics toggles between fancy and fast" {
    var settings: game.Settings = .{};
    try std.testing.expect(settings.fancy_graphics);
    cycle(&settings, .graphics);
    try std.testing.expect(!settings.fancy_graphics);
}

test "gui scale cycles auto, small, normal, large and wraps" {
    var settings: game.Settings = .{};
    try std.testing.expectEqual(game.Settings.GuiScale.auto, settings.gui_scale);
    try std.testing.expectEqual(@as(f32, 1000), settings.gui_scale.limit());
    cycle(&settings, .gui_scale);
    try std.testing.expectEqual(game.Settings.GuiScale.small, settings.gui_scale);
    try std.testing.expectEqual(@as(f32, 1), settings.gui_scale.limit());
    cycle(&settings, .gui_scale);
    cycle(&settings, .gui_scale);
    try std.testing.expectEqual(game.Settings.GuiScale.large, settings.gui_scale);
    cycle(&settings, .gui_scale);
    try std.testing.expectEqual(game.Settings.GuiScale.auto, settings.gui_scale);
}
