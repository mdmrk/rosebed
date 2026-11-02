const std = @import("std");

const game = @import("game");
pub const Scheme = game.Settings.TouchScheme;
pub const Buttons = game.Settings.TouchButtons;

const Atlas = @import("Atlas.zig");
const gui = @import("gui.zig");
const hud = @import("hud.zig");
const MeshBuilder = @import("MeshBuilder.zig");

const texture_size: f32 = 256;

const button_px: f32 = 22;
const small_px: f32 = 18;
const pad_px: f32 = 64;
const knob_px: f32 = 32;
const dpad_px: f32 = button_px * 3;
const travel_px: f32 = (pad_px - knob_px) / 2.0;
const pitch_px: f32 = 33;
const stagger_px: f32 = 17;
const gap_px: f32 = 4;
const margin_px: f32 = 11;

const button_screen_fraction: f32 = 0.126;

fn buttonUv(x: f32, y: f32) Atlas.Uv {
    return gui.pixelUv(x, y, button_px, button_px, texture_size, texture_size);
}

fn smallUv(x: f32, y: f32) Atlas.Uv {
    return gui.pixelUv(x, y, small_px, small_px, texture_size, texture_size);
}

const pad_uv = gui.pixelUv(0, 0, pad_px, pad_px, texture_size, texture_size);
const knob_uv = gui.pixelUv(pad_px, 0, knob_px, knob_px, texture_size, texture_size);

const dpad_uv: [3][3]?Atlas.Uv = .{
    .{ buttonUv(0, 64), buttonUv(22, 64), buttonUv(44, 64) },
    .{ buttonUv(0, 86), null, buttonUv(44, 86) },
    .{ buttonUv(0, 108), buttonUv(22, 108), buttonUv(44, 108) },
};

const tint_normal: [4]u8 = .{ 255, 255, 255, 255 };
const tint_held: [4]u8 = .{ 170, 170, 170, 255 };

pub const dead_zone: f32 = 0.3;

pub const Control = enum {
    move,
    jump,
    sneak,
    attack,
    interact,
    drop,
    inventory,
    menu,
    chat,
    perspective,
    debug,

    fn uv(control: Control) Atlas.Uv {
        return switch (control) {
            .move => pad_uv,
            .jump => buttonUv(0, 130),
            .sneak => buttonUv(22, 86),
            .attack => buttonUv(22, 130),
            .interact => buttonUv(44, 130),
            .drop => buttonUv(66, 130),
            .chat => smallUv(0, 152),
            .menu => smallUv(18, 152),
            .perspective => smallUv(36, 152),
            .inventory => smallUv(54, 152),
            .debug => smallUv(72, 152),
        };
    }

    pub fn shown(control: Control, buttons: Buttons) bool {
        return buttons == .full or (control != .attack and control != .interact);
    }

    fn strip(control: Control) ?f32 {
        return switch (control) {
            .debug => 0,
            .perspective => 1,
            .inventory => 2,
            .chat => 3,
            .menu => 4,
            else => null,
        };
    }

    fn sizePx(control: Control, scheme: Scheme) f32 {
        if (control == .move) return switch (scheme) {
            .joystick, .floating => pad_px,
            .dpad => dpad_px,
        };
        return if (control.strip() != null) small_px else button_px;
    }
};

const strip_span: f32 = span: {
    var slots: f32 = 0;
    for (std.enums.values(Control)) |control| {
        if (control.strip() != null) slots += 1;
    }
    break :span slots * small_px + (slots - 1) * gap_px;
};

pub const Held = std.EnumSet(Control);

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn contains(self: Rect, gx: f32, gy: f32) bool {
        return gx >= self.x and gx < self.x + self.w and gy >= self.y and gy < self.y + self.h;
    }
};

fn unit(res: gui.Scaled) f32 {
    const steps = @round(button_screen_fraction * res.ortho_height * res.factor / button_px);
    return @max(1, steps) / res.factor;
}

pub fn rect(control: Control, scheme: Scheme, res: gui.Scaled) Rect {
    const u = unit(res);
    const size = control.sizePx(scheme) * u;
    const button = button_px * u;
    const margin = margin_px * u;
    const pitch = pitch_px * u;
    const floor = res.height - hud.hotbar_height - margin;
    const outer = res.width - margin - button;
    const inner = outer - gap_px * u - button;
    const cluster = floor - 2.0 * pitch - button;

    if (control.strip()) |slot| {
        const left = @floor((res.width - strip_span * u) / 2.0);
        return .{ .x = left + slot * (small_px + gap_px) * u, .y = margin, .w = size, .h = size };
    }

    return switch (control) {
        .move => .{ .x = margin, .y = floor - size, .w = size, .h = size },
        .jump => .{ .x = outer, .y = cluster, .w = size, .h = size },
        .sneak => switch (scheme) {
            .joystick, .floating => .{ .x = outer, .y = cluster + pitch, .w = size, .h = size },
            .dpad => .{ .x = margin + button, .y = floor - 2.0 * button, .w = size, .h = size },
        },
        .interact => .{ .x = outer, .y = cluster + 2.0 * pitch, .w = size, .h = size },
        .attack => .{ .x = inner, .y = cluster + stagger_px * u, .w = size, .h = size },
        .drop => .{ .x = inner, .y = cluster + stagger_px * u + pitch, .w = size, .h = size },
        else => unreachable,
    };
}

pub fn floatingZone(res: gui.Scaled) Rect {
    const u = unit(res);
    const top = (margin_px + small_px + gap_px) * u;
    const hotbar_left = @floor(res.width / 2.0) - 91.0;
    const right = @min(@floor(res.width * 0.45), hotbar_left);
    return .{ .x = 0, .y = top, .w = right, .h = res.height - top };
}

pub fn controlAt(gx: f32, gy: f32, scheme: Scheme, buttons: Buttons, res: gui.Scaled) ?Control {
    for (std.enums.values(Control)) |control| {
        if (control == .move or !control.shown(buttons)) continue;
        if (rect(control, scheme, res).contains(gx, gy)) return control;
    }
    const zone = if (scheme == .floating) floatingZone(res) else rect(.move, scheme, res);
    if (zone.contains(gx, gy)) return .move;
    return null;
}

fn stickZone(scheme: Scheme, origin: ?[2]f32, res: gui.Scaled) Rect {
    const zone = rect(.move, scheme, res);
    if (scheme != .floating) return zone;
    const at = origin orelse return zone;
    return .{ .x = at[0] - zone.w / 2.0, .y = at[1] - zone.h / 2.0, .w = zone.w, .h = zone.h };
}

fn stickAt(gx: f32, gy: f32, zone: Rect) [2]f32 {
    const radius = zone.w / 2.0;
    const offset: [2]f32 = .{
        (gx - (zone.x + radius)) / radius,
        (gy - (zone.y + radius)) / radius,
    };
    const length = @sqrt(offset[0] * offset[0] + offset[1] * offset[1]);
    if (length <= 1.0) return offset;
    return .{ offset[0] / length, offset[1] / length };
}

fn dpadCell(gx: f32, gy: f32, zone: Rect) [2]usize {
    const cell = zone.w / 3.0;
    const col = std.math.clamp(@floor((gx - zone.x) / cell), 0, 2);
    const row = std.math.clamp(@floor((gy - zone.y) / cell), 0, 2);
    return .{ @intFromFloat(col), @intFromFloat(row) };
}

pub fn moveAt(gx: f32, gy: f32, scheme: Scheme, origin: ?[2]f32, res: gui.Scaled) [2]f32 {
    const zone = stickZone(scheme, origin, res);
    switch (scheme) {
        .joystick, .floating => return stickAt(gx, gy, zone),
        .dpad => {
            const cell = dpadCell(gx, gy, zone);
            return .{
                @as(f32, @floatFromInt(cell[0])) - 1.0,
                @as(f32, @floatFromInt(cell[1])) - 1.0,
            };
        },
    }
}

pub const State = struct {
    scheme: Scheme = .joystick,
    buttons: Buttons = .full,
    origin: ?[2]f32 = null,
    move: ?[2]f32 = null,
    held: Held = .empty,
};

fn appendStick(sprites: *MeshBuilder, ui: gui.Ui, state: State) !void {
    const zone = stickZone(state.scheme, if (state.move != null) state.origin else null, ui.res);
    try gui.appendRectColor(sprites, ui.gpa, zone.x, zone.y, zone.w, zone.h, pad_uv, tint_normal, ui.res);

    const u = unit(ui.res);
    const travel = travel_px * u;
    const stick = state.move orelse [2]f32{ 0, 0 };
    try gui.appendRectColor(
        sprites,
        ui.gpa,
        zone.x + travel + stick[0] * travel,
        zone.y + travel + stick[1] * travel,
        knob_px * u,
        knob_px * u,
        knob_uv,
        if (state.move != null) tint_held else tint_normal,
        ui.res,
    );
}

fn appendDpad(sprites: *MeshBuilder, ui: gui.Ui, state: State) !void {
    const zone = rect(.move, .dpad, ui.res);
    const cell = zone.w / 3.0;
    const active: ?[2]usize = if (state.move) |move|
        .{ @intFromFloat(move[0] + 1.0), @intFromFloat(move[1] + 1.0) }
    else
        null;
    for (dpad_uv, 0..) |row_uv, row| {
        for (row_uv, 0..) |maybe_uv, col| {
            const uv = maybe_uv orelse continue;
            const lit = if (active) |at| at[0] == col and at[1] == row else false;
            try gui.appendRectColor(
                sprites,
                ui.gpa,
                zone.x + @as(f32, @floatFromInt(col)) * cell,
                zone.y + @as(f32, @floatFromInt(row)) * cell,
                cell,
                cell,
                uv,
                if (lit) tint_held else tint_normal,
                ui.res,
            );
        }
    }
}

pub fn draw(ui: gui.Ui, state: State, atlas: Atlas) !void {
    gui.beginOverlay();

    var sprites: MeshBuilder = .{};
    defer sprites.deinit(ui.gpa);

    for (std.enums.values(Control)) |control| {
        if (control == .move or !control.shown(state.buttons)) continue;
        const box = rect(control, state.scheme, ui.res);
        const tint = if (state.held.contains(control)) tint_held else tint_normal;
        try gui.appendRectColor(&sprites, ui.gpa, box.x, box.y, box.w, box.h, control.uv(), tint, ui.res);
    }

    switch (state.scheme) {
        .joystick, .floating => try appendStick(&sprites, ui, state),
        .dpad => try appendDpad(&sprites, ui, state),
    }

    try gui.drawTexturedMesh(&sprites, ui.shader, atlas);
}

const smallest: gui.Scaled = .{ .factor = 4, .ortho_width = 320, .ortho_height = 240, .width = 320, .height = 240 };
const widest: gui.Scaled = .{ .factor = 2, .ortho_width = 600, .ortho_height = 340, .width = 600, .height = 340 };
const phone: gui.Scaled = .{ .factor = 4, .ortho_width = 585, .ortho_height = 270, .width = 585, .height = 270 };
const unscaled: gui.Scaled = .{ .factor = 1, .ortho_width = 320, .ortho_height = 240, .width = 320, .height = 240 };

test "controls sit on screen, clear of the hotbar, and never overlap" {
    const controls = std.enums.values(Control);
    for ([_]gui.Scaled{ smallest, widest, phone, unscaled }) |res| {
        for ([_]Scheme{ .joystick, .dpad, .floating }) |scheme| {
            const hotbar_x = @floor(res.width / 2.0) - 91.0;
            for (controls, 0..) |control, i| {
                const box = rect(control, scheme, res);
                try std.testing.expect(box.x >= 0 and box.y >= 0);
                try std.testing.expect(box.x + box.w <= res.width);
                try std.testing.expect(box.y + box.h <= res.height);

                const over_hotbar = box.x + box.w > hotbar_x and box.x < hotbar_x + 182.0;
                if (over_hotbar) try std.testing.expect(box.y + box.h <= res.height - hud.hotbar_height);

                for (controls[i + 1 ..]) |other| {
                    if (scheme == .dpad and control == .move and other == .sneak) continue;
                    const rhs = rect(other, scheme, res);
                    const apart = box.x + box.w <= rhs.x or rhs.x + rhs.w <= box.x or
                        box.y + box.h <= rhs.y or rhs.y + rhs.h <= box.y;
                    try std.testing.expect(apart);
                }
            }
        }
    }
}

test "every control lands on whole device pixels at a whole multiple of its sprite" {
    for ([_]gui.Scaled{ smallest, widest, phone, unscaled }) |res| {
        const steps = unit(res) * res.factor;
        try std.testing.expectEqual(steps, @round(steps));
        for ([_]Scheme{ .joystick, .dpad, .floating }) |scheme| {
            for (std.enums.values(Control)) |control| {
                const box = rect(control, scheme, res);
                for ([_]f32{ box.x, box.y, box.w, box.h }) |value| {
                    const device = value * res.factor;
                    try std.testing.expectEqual(device, @round(device));
                }
                try std.testing.expectEqual(control.sizePx(scheme) * steps, box.w * res.factor);
            }
        }
    }
}

test "taps land on the buttons the layout advertises" {
    for ([_]Scheme{ .joystick, .dpad, .floating }) |scheme| {
        for (std.enums.values(Control)) |control| {
            const box = rect(control, scheme, widest);
            const fraction: f32 = if (control == .move) 6.0 else 2.0;
            const gx = box.x + box.w / fraction;
            const gy = box.y + box.h / fraction;
            try std.testing.expectEqual(control, controlAt(gx, gy, scheme, .full, widest).?);
        }
    }
    try std.testing.expectEqual(@as(?Control, null), controlAt(widest.width / 2.0, widest.height / 2.0, .joystick, .full, widest));
}

test "a floating stick starts wherever the thumb lands on the left and is centred on it" {
    const gx = widest.width * 0.3;
    const gy = widest.height * 0.4;
    try std.testing.expectEqual(Control.move, controlAt(gx, gy, .floating, .full, widest).?);
    try std.testing.expectEqual(@as(?Control, null), controlAt(gx, gy, .joystick, .full, widest));

    const still = moveAt(gx, gy, .floating, .{ gx, gy }, widest);
    try std.testing.expectEqual([2]f32{ 0, 0 }, still);
    const pushed = moveAt(gx + 100, gy, .floating, .{ gx, gy }, widest);
    try std.testing.expectEqual([2]f32{ 1, 0 }, pushed);
}

test "the minimal layout hands attack and use over to the open screen" {
    for ([_]Control{ .attack, .interact }) |control| {
        const box = rect(control, .joystick, widest);
        const gx = box.x + box.w / 2.0;
        const gy = box.y + box.h / 2.0;
        try std.testing.expectEqual(control, controlAt(gx, gy, .joystick, .full, widest).?);
        try std.testing.expectEqual(@as(?Control, null), controlAt(gx, gy, .joystick, .minimal, widest));
    }
}
