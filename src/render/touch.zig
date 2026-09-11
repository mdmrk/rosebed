const std = @import("std");

const game = @import("game");
pub const Scheme = game.Settings.TouchScheme;

const Atlas = @import("Atlas.zig");
const gui = @import("gui.zig");
const hud = @import("hud.zig");
const MeshBuilder = @import("MeshBuilder.zig");

const margin: f32 = 10;
const gap: f32 = 4;
const button_size: f32 = 32;
const pad_size: f32 = 80;
const knob_size: f32 = 40;
const dpad_cell: f32 = 32;
const dpad_size: f32 = dpad_cell * 3;

const texture_size: f32 = 256;

fn tileUv(x: f32, y: f32) Atlas.Uv {
    return gui.pixelUv(x, y, button_size, button_size, texture_size, texture_size);
}

const pad_uv = gui.pixelUv(0, 0, pad_size, pad_size, texture_size, texture_size);
const knob_uv = gui.pixelUv(pad_size, 0, knob_size, knob_size, texture_size, texture_size);
const blank_uv = tileUv(32, 112);

const dpad_uv: [3][3]Atlas.Uv = .{
    .{ tileUv(192, 112), tileUv(64, 112), tileUv(224, 112) },
    .{ tileUv(128, 112), blank_uv, tileUv(160, 112) },
    .{ tileUv(0, 144), tileUv(96, 112), tileUv(32, 144) },
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

    fn uv(control: Control) Atlas.Uv {
        return switch (control) {
            .move => pad_uv,
            .jump => tileUv(0, 80),
            .sneak => tileUv(32, 80),
            .attack => tileUv(64, 80),
            .interact => tileUv(96, 80),
            .inventory => tileUv(128, 80),
            .menu => tileUv(160, 80),
            .chat => tileUv(192, 80),
            .perspective => tileUv(224, 80),
            .drop => tileUv(0, 112),
        };
    }
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

fn moveSize(scheme: Scheme) f32 {
    return switch (scheme) {
        .joystick => pad_size,
        .dpad => dpad_size,
    };
}

pub fn rect(control: Control, scheme: Scheme, res: gui.Scaled) Rect {
    const floor = res.height - hud.hotbar_height - gap;
    const right = res.width - margin - button_size;
    const left = right - gap - button_size;
    const bottom = floor - button_size;
    const middle = bottom - gap - button_size;
    const top = middle - gap - button_size;
    return switch (control) {
        .move => .{ .x = margin, .y = floor - moveSize(scheme), .w = moveSize(scheme), .h = moveSize(scheme) },
        .jump => .{ .x = right, .y = bottom, .w = button_size, .h = button_size },
        .attack => .{ .x = left, .y = bottom, .w = button_size, .h = button_size },
        .sneak => .{ .x = right, .y = middle, .w = button_size, .h = button_size },
        .interact => .{ .x = left, .y = middle, .w = button_size, .h = button_size },
        .inventory => .{ .x = right, .y = top, .w = button_size, .h = button_size },
        .drop => .{ .x = left, .y = top, .w = button_size, .h = button_size },
        .menu => .{ .x = margin, .y = margin, .w = button_size, .h = button_size },
        .chat => .{ .x = margin + button_size + gap, .y = margin, .w = button_size, .h = button_size },
        .perspective => .{ .x = right, .y = margin, .w = button_size, .h = button_size },
    };
}

pub fn controlAt(gx: f32, gy: f32, scheme: Scheme, res: gui.Scaled) ?Control {
    for (std.enums.values(Control)) |control| {
        if (rect(control, scheme, res).contains(gx, gy)) return control;
    }
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
    const col = std.math.clamp(@floor((gx - zone.x) / dpad_cell), 0, 2);
    const row = std.math.clamp(@floor((gy - zone.y) / dpad_cell), 0, 2);
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

    const travel = (pad_size - knob_size) / 2.0;
    const stick = state.move orelse [2]f32{ 0, 0 };
    try gui.appendRectColor(
        sprites,
        ui.gpa,
        zone.x + travel + stick[0] * travel,
        zone.y + travel + stick[1] * travel,
        knob_size,
        knob_size,
        knob_uv,
        if (state.move != null) tint_held else tint_normal,
        ui.res,
    );
}

fn appendDpad(sprites: *MeshBuilder, ui: gui.Ui, state: State) !void {
    const zone = rect(.move, .dpad, ui.res);
    const active: ?[2]usize = if (state.move) |move|
        .{ @intFromFloat(move[0] + 1.0), @intFromFloat(move[1] + 1.0) }
    else
        null;
    for (dpad_uv, 0..) |row_uv, row| {
        for (row_uv, 0..) |uv, col| {
            const lit = if (active) |cell| cell[0] == col and cell[1] == row else false;
            try gui.appendRectColor(
                sprites,
                ui.gpa,
                zone.x + @as(f32, @floatFromInt(col)) * dpad_cell,
                zone.y + @as(f32, @floatFromInt(row)) * dpad_cell,
                dpad_cell,
                dpad_cell,
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

test "controls sit on screen, clear of the hotbar, and never overlap" {
    const controls = std.enums.values(Control);
    for ([_]gui.Scaled{ smallest, widest }) |res| {
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
                    const rhs = rect(other, scheme, res);
                    const apart = box.x + box.w <= rhs.x or rhs.x + rhs.w <= box.x or
                        box.y + box.h <= rhs.y or rhs.y + rhs.h <= box.y;
                    try std.testing.expect(apart);
                }
            }
        }
    }
}

test "the stick reads its centre as neutral and clamps to the unit circle" {
    const pad = rect(.move, .joystick, widest);
    const centre = moveAt(pad.x + pad_size / 2.0, pad.y + pad_size / 2.0, .joystick, widest);
    try std.testing.expectEqual(@as(f32, 0), centre[0]);
    try std.testing.expectEqual(@as(f32, 0), centre[1]);

    const far = moveAt(pad.x + pad_size * 4, pad.y + pad_size * 4, .joystick, widest);
    try std.testing.expect(@sqrt(far[0] * far[0] + far[1] * far[1]) <= 1.001);
}

test "the d-pad quantises to its nine cells and holds still in the middle" {
    const pad = rect(.move, .dpad, widest);
    const centre = moveAt(pad.x + dpad_size / 2.0, pad.y + dpad_size / 2.0, .dpad, widest);
    try std.testing.expectEqual([2]f32{ 0, 0 }, centre);
    try std.testing.expectEqual([2]f32{ -1, -1 }, moveAt(pad.x + 1, pad.y + 1, .dpad, widest));
    try std.testing.expectEqual([2]f32{ 1, -1 }, moveAt(pad.x + dpad_size - 1, pad.y + 1, .dpad, widest));
    try std.testing.expectEqual([2]f32{ 0, 1 }, moveAt(pad.x + dpad_size / 2.0, pad.y + dpad_size - 1, .dpad, widest));
    try std.testing.expectEqual([2]f32{ 1, 1 }, moveAt(pad.x + dpad_size * 4, pad.y + dpad_size * 4, .dpad, widest));
}

test "taps land on the buttons the layout advertises" {
    for ([_]Scheme{ .joystick, .dpad }) |scheme| {
        for (std.enums.values(Control)) |control| {
            const box = rect(control, scheme, widest);
            try std.testing.expectEqual(control, controlAt(box.x + box.w / 2.0, box.y + box.h / 2.0, scheme, widest).?);
        }
    }
    try std.testing.expectEqual(@as(?Control, null), controlAt(widest.width / 2.0, widest.height / 2.0, .joystick, widest));
}
