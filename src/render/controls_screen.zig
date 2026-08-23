const std = @import("std");

const game = @import("game");
pub const Binding = game.Settings.Binding;
const gl = @import("gl");
const sdl3 = @import("sdl3");

const button = @import("button.zig");
const gui = @import("gui.zig");
const MeshBuilder = @import("MeshBuilder.zig");
const options_screen = @import("options_screen.zig");
pub const Backdrop = options_screen.Backdrop;

const bind_width: f32 = 70;
const description_gap: f32 = 6;
const description_offset_y: f32 = 7;
const title_color: [4]u8 = .{ 255, 255, 255, 255 };
const description_color: [4]u8 = .{ 255, 255, 255, 255 };
const unknown_key = "???";

pub const Hit = union(enum) { binding: Binding, done };

const order = std.enums.values(Binding);

const Control = struct { x: f32, y: f32, w: f32, hit: Hit };

fn controls(scaled_width: f32, scaled_height: f32) [order.len + 1]Control {
    const cx = @floor(scaled_width / 2.0);
    const sixth = @floor(scaled_height / 6.0);
    var result: [order.len + 1]Control = undefined;
    for (order, 0..) |binding, i| {
        const column: f32 = @floatFromInt(i % 2);
        const row: f32 = @floatFromInt(i >> 1);
        result[i] = .{
            .x = cx - 155.0 + column * 160.0,
            .y = sixth + row * 24.0,
            .w = bind_width,
            .hit = .{ .binding = binding },
        };
    }
    result[order.len] = .{ .x = cx - 100.0, .y = sixth + 168.0, .w = 200, .hit = .done };
    return result;
}

pub fn hitAt(mouse_x: f32, mouse_y: f32, res: gui.Scaled) ?Hit {
    const gx = mouse_x / res.factor;
    const gy = mouse_y / res.factor;
    for (controls(res.width, res.height)) |control| {
        if (gx >= control.x and gx < control.x + control.w and gy >= control.y and gy < control.y + button.height) {
            return control.hit;
        }
    }
    return null;
}

pub fn keyName(code: u32) []const u8 {
    const key = sdl3.keycode.Keycode.fromSdl(code) orelse return unknown_key;
    return sdl3.keyboard.getKeyName(key) orelse unknown_key;
}

fn controlLabel(hit: Hit, settings: game.Settings, rebinding: ?Binding, buf: []u8) []const u8 {
    const binding = switch (hit) {
        .done => return "Done",
        .binding => |b| b,
    };
    const name = keyName(settings.keys.get(binding));
    if (rebinding != binding) return name;
    return std.fmt.bufPrint(buf, "> {s} <", .{name}) catch name;
}

pub fn draw(
    ui: gui.Ui,
    settings: game.Settings,
    backdrop: Backdrop,
    rebinding: ?Binding,
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
        const hovered = gx >= control.x and gx < control.x + control.w and gy >= control.y and gy < control.y + button.height;
        var buf: [64]u8 = undefined;
        const label = controlLabel(control.hit, settings, rebinding, &buf);
        try button.append(&backgrounds, &text, ui.gpa, ui.font, .{
            .x = control.x,
            .y = control.y,
            .w = control.w,
            .label = label,
            .enabled = true,
        }, hovered, ui.res);
        switch (control.hit) {
            .binding => |binding| try gui.appendTextColor(
                &text,
                ui.gpa,
                ui.font,
                binding.label(),
                control.x + control.w + description_gap,
                control.y + description_offset_y,
                description_color,
                ui.res,
            ),
            .done => {},
        }
    }

    const title = "Controls";
    const title_width: f32 = @floatFromInt(ui.font.stringWidth(title));
    try gui.appendTextColor(&text, ui.gpa, ui.font, title, @floor(ui.res.width / 2.0) - @floor(title_width / 2.0), 20, title_color, ui.res);

    try gui.drawTexturedMesh(&backgrounds, ui.shader, ui.textures.gui);
    try gui.drawTexturedMesh(&text, ui.shader, ui.font);

    gl.Disable(gl.BLEND);
    gl.Enable(gl.DEPTH_TEST);
}

test "the ten bindings sit in two columns of five rows" {
    const res = gui.scaledResolution(640, 480, 1000);
    const list = controls(res.width, res.height);
    try std.testing.expectEqual(@as(usize, 11), list.len);
    try std.testing.expectEqual(@as(f32, 5), list[0].x);
    try std.testing.expectEqual(@as(f32, 165), list[1].x);
    try std.testing.expectEqual(list[0].y, list[1].y);
    try std.testing.expectEqual(list[0].y + 24, list[2].y);
    try std.testing.expectEqual(list[0].y + 96, list[8].y);
    try std.testing.expectEqual(@as(f32, 70), list[0].w);
}

test "the buttons follow the vanilla binding order" {
    const res = gui.scaledResolution(640, 480, 1000);
    const list = controls(res.width, res.height);
    try std.testing.expectEqual(@as(Hit, .{ .binding = .forward }), list[0].hit);
    try std.testing.expectEqual(@as(Hit, .{ .binding = .left }), list[1].hit);
    try std.testing.expectEqual(@as(Hit, .{ .binding = .sneak }), list[5].hit);
    try std.testing.expectEqual(@as(Hit, .done), list[10].hit);
}

test "clicking a binding returns it, clicking Done returns done" {
    const res = gui.scaledResolution(640, 480, 1000);
    try std.testing.expectEqual(@as(?Hit, .{ .binding = .forward }), hitAt(80, 80, res));
    try std.testing.expectEqual(@as(?Hit, .{ .binding = .left }), hitAt(400, 80, res));
    try std.testing.expectEqual(@as(?Hit, .done), hitAt(320, 416, res));
    try std.testing.expectEqual(@as(?Hit, null), hitAt(600, 80, res));
}

test "the selected binding is bracketed" {
    const settings: game.Settings = .{};
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("W", controlLabel(.{ .binding = .forward }, settings, null, &buf));
    try std.testing.expectEqualStrings("> W <", controlLabel(.{ .binding = .forward }, settings, .forward, &buf));
    try std.testing.expectEqualStrings("A", controlLabel(.{ .binding = .left }, settings, .forward, &buf));
    try std.testing.expectEqualStrings("Done", controlLabel(.done, settings, .forward, &buf));
}

test "the default keycodes name the vanilla keys" {
    const settings: game.Settings = .{};
    try std.testing.expectEqualStrings("Space", keyName(settings.keys.get(.jump)));
    try std.testing.expectEqualStrings("Left Shift", keyName(settings.keys.get(.sneak)));
    try std.testing.expectEqual(
        @intFromEnum(sdl3.keycode.Keycode.left_shift),
        settings.keys.get(.sneak),
    );
}
