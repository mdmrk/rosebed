const std = @import("std");

const game = @import("game");
pub const Scheme = game.Settings.TouchScheme;

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
            .joystick => pad_px,
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
            .joystick => .{ .x = outer, .y = cluster + pitch, .w = size, .h = size },
            .dpad => .{ .x = margin + button, .y = floor - 2.0 * button, .w = size, .h = size },
        },
        .interact => .{ .x = outer, .y = cluster + 2.0 * pitch, .w = size, .h = size },
        .attack => .{ .x = inner, .y = cluster + stagger_px * u, .w = size, .h = size },
        .drop => .{ .x = inner, .y = cluster + stagger_px * u + pitch, .w = size, .h = size },
        else => unreachable,
    };
}

pub fn controlAt(gx: f32, gy: f32, scheme: Scheme, res: gui.Scaled) ?Control {
    for (std.enums.values(Control)) |control| {
        if (control == .move) continue;
        if (rect(control, scheme, res).contains(gx, gy)) return control;
    }
    if (rect(.move, scheme, res).contains(gx, gy)) return .move;
    return null;
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

pub fn moveAt(gx: f32, gy: f32, scheme: Scheme, res: gui.Scaled) [2]f32 {
    const zone = rect(.move, scheme, res);
    switch (scheme) {
        .joystick => return stickAt(gx, gy, zone),
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
    move: ?[2]f32 = null,
    held: Held = .initEmpty(),
};

fn appendStick(sprites: *MeshBuilder, ui: gui.Ui, state: State) !void {
    const zone = rect(.move, .joystick, ui.res);
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
        if (control == .move) continue;
        const box = rect(control, state.scheme, ui.res);
        const tint = if (state.held.contains(control)) tint_held else tint_normal;
        try gui.appendRectColor(&sprites, ui.gpa, box.x, box.y, box.w, box.h, control.uv(), tint, ui.res);
    }

    switch (state.scheme) {
        .joystick => try appendStick(&sprites, ui, state),
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
        for ([_]Scheme{ .joystick, .dpad }) |scheme| {
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
        for ([_]Scheme{ .joystick, .dpad }) |scheme| {
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

test "the stick reads its centre as neutral and clamps to the unit circle" {
    const pad = rect(.move, .joystick, widest);
    const centre = moveAt(pad.x + pad.w / 2.0, pad.y + pad.h / 2.0, .joystick, widest);
    try std.testing.expectEqual(@as(f32, 0), centre[0]);
    try std.testing.expectEqual(@as(f32, 0), centre[1]);

    const far = moveAt(pad.x + pad.w * 4, pad.y + pad.h * 4, .joystick, widest);
    try std.testing.expect(@sqrt(far[0] * far[0] + far[1] * far[1]) <= 1.001);
}

test "the d-pad quantises to its nine cells and holds still in the middle" {
    const pad = rect(.move, .dpad, widest);
    const centre = moveAt(pad.x + pad.w / 2.0, pad.y + pad.h / 2.0, .dpad, widest);
    try std.testing.expectEqual([2]f32{ 0, 0 }, centre);
    try std.testing.expectEqual([2]f32{ -1, -1 }, moveAt(pad.x + 1, pad.y + 1, .dpad, widest));
    try std.testing.expectEqual([2]f32{ 1, -1 }, moveAt(pad.x + pad.w - 1, pad.y + 1, .dpad, widest));
    try std.testing.expectEqual([2]f32{ 0, 1 }, moveAt(pad.x + pad.w / 2.0, pad.y + pad.h - 1, .dpad, widest));
    try std.testing.expectEqual([2]f32{ 1, 1 }, moveAt(pad.x + pad.w * 4, pad.y + pad.h * 4, .dpad, widest));
}

test "taps land on the buttons the layout advertises" {
    for ([_]Scheme{ .joystick, .dpad }) |scheme| {
        for (std.enums.values(Control)) |control| {
            const box = rect(control, scheme, widest);
            const fraction: f32 = if (control == .move) 6.0 else 2.0;
            const gx = box.x + box.w / fraction;
            const gy = box.y + box.h / fraction;
            try std.testing.expectEqual(control, controlAt(gx, gy, scheme, widest).?);
        }
    }
    try std.testing.expectEqual(@as(?Control, null), controlAt(widest.width / 2.0, widest.height / 2.0, .joystick, widest));
}

test "the d-pad centre is the sneak button, not a ninth direction" {
    const pad = rect(.move, .dpad, widest);
    const sneak = rect(.sneak, .dpad, widest);
    try std.testing.expectEqual(pad.x + pad.w / 3.0, sneak.x);
    try std.testing.expectEqual(pad.y + pad.h / 3.0, sneak.y);
    try std.testing.expectEqual(
        @as(?Control, .sneak),
        controlAt(sneak.x + sneak.w / 2.0, sneak.y + sneak.h / 2.0, .dpad, widest),
    );
}
