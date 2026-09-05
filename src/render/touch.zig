const std = @import("std");

const Atlas = @import("Atlas.zig");
const Font = @import("Font.zig");
const gui = @import("gui.zig");
const MeshBuilder = @import("MeshBuilder.zig");

const margin: f32 = 24;
const gap: f32 = 6;
const pad_size: f32 = 64;
const knob_size: f32 = 32;
const button_size: f32 = 22;

const texture_size: f32 = 128;
const pad_uv = gui.pixelUv(0, 0, pad_size, pad_size, texture_size, texture_size);
const knob_uv = gui.pixelUv(64, 0, knob_size, knob_size, texture_size, texture_size);
const jump_uv = gui.pixelUv(96, 0, button_size, button_size, texture_size, texture_size);
const sneak_uv = gui.pixelUv(96, 22, button_size, button_size, texture_size, texture_size);
const blank_uv = gui.pixelUv(96, 44, button_size, button_size, texture_size, texture_size);
const attack_uv = gui.pixelUv(96, 66, button_size, button_size, texture_size, texture_size);

const tint_normal: [4]u8 = .{ 255, 255, 255, 255 };
const tint_held: [4]u8 = .{ 170, 170, 170, 255 };
const label_color: [4]u8 = .{ 224, 224, 224, 255 };

pub const dead_zone: f32 = 0.3;

pub const Control = enum {
    move,
    jump,
    attack,
    sneak,
    inventory,
    pause,

    fn uv(control: Control) Atlas.Uv {
        return switch (control) {
            .move => pad_uv,
            .jump => jump_uv,
            .attack => attack_uv,
            .sneak => sneak_uv,
            .inventory, .pause => blank_uv,
        };
    }

    fn label(control: Control) []const u8 {
        return switch (control) {
            .move, .jump, .attack, .sneak => "",
            .inventory => "E",
            .pause => "II",
        };
    }
};

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn contains(self: Rect, gx: f32, gy: f32) bool {
        return gx >= self.x and gx < self.x + self.w and gy >= self.y and gy < self.y + self.h;
    }
};

pub fn rect(control: Control, res: gui.Scaled) Rect {
    const right = res.width - margin - button_size;
    const bottom = res.height - margin - button_size;
    return switch (control) {
        .move => .{ .x = margin, .y = res.height - margin - pad_size, .w = pad_size, .h = pad_size },
        .jump => .{ .x = right, .y = bottom, .w = button_size, .h = button_size },
        .attack => .{ .x = right - gap - button_size, .y = bottom, .w = button_size, .h = button_size },
        .sneak => .{ .x = right, .y = bottom - gap - button_size, .w = button_size, .h = button_size },
        .inventory => .{ .x = right, .y = bottom - (gap + button_size) * 2, .w = button_size, .h = button_size },
        .pause => .{ .x = margin, .y = margin, .w = button_size, .h = button_size },
    };
}

pub fn controlAt(gx: f32, gy: f32, res: gui.Scaled) ?Control {
    for (std.enums.values(Control)) |control| {
        if (rect(control, res).contains(gx, gy)) return control;
    }
    return null;
}

pub fn stickAt(gx: f32, gy: f32, res: gui.Scaled) [2]f32 {
    const pad = rect(.move, res);
    const radius = pad_size / 2.0;
    const offset: [2]f32 = .{
        (gx - (pad.x + radius)) / radius,
        (gy - (pad.y + radius)) / radius,
    };
    const length = @sqrt(offset[0] * offset[0] + offset[1] * offset[1]);
    if (length <= 1.0) return offset;
    return .{ offset[0] / length, offset[1] / length };
}

pub const State = struct {
    stick: ?[2]f32 = null,
    jump: bool = false,
    attack: bool = false,
    sneak: bool = false,

    fn held(self: State, control: Control) bool {
        return switch (control) {
            .move => false,
            .jump => self.jump,
            .attack => self.attack,
            .sneak => self.sneak,
            .inventory, .pause => false,
        };
    }
};

pub fn draw(ui: gui.Ui, state: State, atlas: Atlas) !void {
    gui.beginOverlay();

    var sprites: MeshBuilder = .{};
    defer sprites.deinit(ui.gpa);
    var text: MeshBuilder = .{};
    defer text.deinit(ui.gpa);

    for (std.enums.values(Control)) |control| {
        const box = rect(control, ui.res);
        const tint = if (state.held(control)) tint_held else tint_normal;
        try gui.appendRectColor(&sprites, ui.gpa, box.x, box.y, box.w, box.h, control.uv(), tint, ui.res);

        const label = control.label();
        if (label.len == 0) continue;
        const label_width: f32 = @floatFromInt(ui.font.stringWidth(label));
        try gui.appendTextColor(
            &text,
            ui.gpa,
            ui.font,
            label,
            box.x + @floor((box.w - label_width) / 2.0),
            box.y + @floor((box.h - Font.glyph_size) / 2.0),
            label_color,
            ui.res,
        );
    }

    const pad = rect(.move, ui.res);
    const travel = (pad_size - knob_size) / 2.0;
    const stick = state.stick orelse [2]f32{ 0, 0 };
    try gui.appendRectColor(
        &sprites,
        ui.gpa,
        pad.x + travel + stick[0] * travel,
        pad.y + travel + stick[1] * travel,
        knob_size,
        knob_size,
        knob_uv,
        if (state.stick != null) tint_held else tint_normal,
        ui.res,
    );

    try gui.drawTexturedMesh(&sprites, ui.shader, atlas);
    try gui.drawTexturedMesh(&text, ui.shader, ui.font);
}

test "controls sit inside the screen and do not overlap" {
    const res: gui.Scaled = .{ .factor = 2, .ortho_width = 600, .ortho_height = 340, .width = 600, .height = 340 };
    const controls = std.enums.values(Control);
    for (controls, 0..) |control, i| {
        const box = rect(control, res);
        try std.testing.expect(box.x >= 0 and box.y >= 0);
        try std.testing.expect(box.x + box.w <= res.width);
        try std.testing.expect(box.y + box.h <= res.height);
        for (controls[i + 1 ..]) |other| {
            const rhs = rect(other, res);
            const apart = box.x + box.w <= rhs.x or rhs.x + rhs.w <= box.x or
                box.y + box.h <= rhs.y or rhs.y + rhs.h <= box.y;
            try std.testing.expect(apart);
        }
    }
}

test "the stick reads its centre as neutral and clamps to the unit circle" {
    const res: gui.Scaled = .{ .factor = 2, .ortho_width = 600, .ortho_height = 340, .width = 600, .height = 340 };
    const pad = rect(.move, res);
    const centre = stickAt(pad.x + pad_size / 2.0, pad.y + pad_size / 2.0, res);
    try std.testing.expectEqual(@as(f32, 0), centre[0]);
    try std.testing.expectEqual(@as(f32, 0), centre[1]);

    const far = stickAt(pad.x + pad_size * 4, pad.y + pad_size * 4, res);
    try std.testing.expect(@sqrt(far[0] * far[0] + far[1] * far[1]) <= 1.001);
    try std.testing.expectEqual(.jump, controlAt(res.width - margin - 1, res.height - margin - 1, res));
    try std.testing.expectEqual(@as(?Control, null), controlAt(res.width / 2, res.height / 2, res));
}
