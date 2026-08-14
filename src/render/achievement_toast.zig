const std = @import("std");

const game = @import("game");
const achievements = game.achievements;
const gl = @import("gl");

const Atlas = @import("atlas.zig");
const gui = @import("gui.zig");
const MeshBuilder = @import("mesh_builder.zig");
const text_wrap = @import("text_wrap.zig");

pub const window_width: f32 = 160;
pub const window_height: f32 = 32;
pub const window_u: f32 = 96;
pub const window_v: f32 = 202;
pub const texture_size: f32 = 256;

pub const show_millis: f64 = 3000;
pub const hint_head_start: f64 = 2500;
pub const drop_height: f64 = 36;
pub const description_width: u32 = 120;

const text_x: f32 = 30;
const first_line_y: f32 = 7;
const second_line_y: f32 = 18;
const icon_x: f32 = 8;
const icon_y: f32 = 8;

const banner_color: [4]u8 = .{ 255, 255, 0, 255 };
const title_color: [4]u8 = .{ 255, 255, 255, 255 };

pub const Kind = enum { taken, hint };

pub const State = struct {
    shown: ?achievements.Id = null,
    kind: Kind = .taken,
    started_ms: f64 = 0,

    pub fn announce(self: *State, id: achievements.Id, now_ms: f64) void {
        self.shown = id;
        self.kind = .taken;
        self.started_ms = now_ms;
    }

    pub fn hint(self: *State, id: achievements.Id, now_ms: f64) void {
        self.shown = id;
        self.kind = .hint;
        self.started_ms = now_ms - hint_head_start;
    }

    pub fn progress(self: State, now_ms: f64) f64 {
        return (now_ms - self.started_ms) / show_millis;
    }

    pub fn visible(self: State, now_ms: f64) bool {
        if (self.shown == null) return false;
        if (self.kind == .hint) return true;
        const at = self.progress(now_ms);
        return at >= 0.0 and at <= 1.0;
    }
};

pub fn slideOffset(at: f64) f64 {
    var eased = at * 2.0;
    if (eased > 1.0) eased = 2.0 - eased;
    eased *= 4.0;
    eased = 1.0 - eased;
    if (eased < 0.0) eased = 0.0;
    eased *= eased;
    eased *= eased;
    return -(eased * drop_height);
}

fn windowUv() Atlas.Uv {
    return gui.pixelUv(window_u, window_v, window_width, window_height, texture_size, texture_size);
}

pub fn draw(ui: gui.Ui, state: State, now_ms: f64, inventory_key: []const u8) !void {
    const id = state.shown orelse return;
    if (!state.visible(now_ms)) return;

    const entry = id.def();
    const x = ui.res.width - window_width;
    const y: f32 = @floatCast(slideOffset(state.progress(now_ms)));

    gl.Disable(gl.DEPTH_TEST);
    gl.Enable(gl.BLEND);
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

    var window: MeshBuilder = .{};
    defer window.deinit(ui.gpa);
    try gui.appendRect(&window, ui.gpa, x, y, window_width, window_height, windowUv(), ui.res);
    try gui.drawTexturedMesh(&window, ui.shader, ui.textures.achievement);

    var text: MeshBuilder = .{};
    defer text.deinit(ui.gpa);
    switch (state.kind) {
        .hint => {
            var buffer: [text_wrap.buffer_bytes]u8 = undefined;
            const described = achievements.describe(&buffer, id, inventory_key);
            const wrapped = text_wrap.wrap(ui.font, described, description_width);
            for (0..wrapped.count) |index| {
                const line_y = y + first_line_y + @as(f32, @floatFromInt(index)) * text_wrap.line_height;
                try gui.appendTextColor(&text, ui.gpa, ui.font, wrapped.line(index), x + text_x, line_y, title_color, ui.res);
            }
        },
        .taken => {
            try gui.appendTextColor(&text, ui.gpa, ui.font, achievements.get_banner, x + text_x, y + first_line_y, banner_color, ui.res);
            try gui.appendTextColor(&text, ui.gpa, ui.font, entry.title, x + text_x, y + second_line_y, title_color, ui.res);
        },
    }
    try gui.drawTexturedMesh(&text, ui.shader, ui.font);

    var blocks: MeshBuilder = .{};
    defer blocks.deinit(ui.gpa);
    var items: MeshBuilder = .{};
    defer items.deinit(ui.gpa);
    var bars: MeshBuilder = .{};
    defer bars.deinit(ui.gpa);
    var counts: MeshBuilder = .{};
    defer counts.deinit(ui.gpa);
    try gui.appendStackIcon(
        &blocks,
        &items,
        &bars,
        &counts,
        ui.gpa,
        ui.font,
        .{ .id = entry.icon, .count = 1 },
        x + icon_x,
        y + icon_y,
        ui.res,
    );
    try gui.drawTexturedMesh(&blocks, ui.shader, ui.textures.terrain);
    try gui.drawTexturedMesh(&items, ui.shader, ui.textures.items);

    gl.Disable(gl.BLEND);
    gl.Enable(gl.DEPTH_TEST);
}

fn argb(value: i32) [4]u8 {
    const bits: u32 = @bitCast(value);
    return .{
        @truncate(bits >> 16),
        @truncate(bits >> 8),
        @truncate(bits),
        @truncate(bits >> 24),
    };
}

test "the two lines are lettered the colours GuiAchievement draws them with" {
    try std.testing.expectEqual(argb(-256), banner_color);
    try std.testing.expectEqual(argb(-1), title_color);
}

test "a taken toast shows for three seconds and then stops" {
    var state: State = .{};
    state.announce(.mine_wood, 1000);

    try std.testing.expect(state.visible(1000));
    try std.testing.expect(state.visible(2500));
    try std.testing.expect(state.visible(4000));
    try std.testing.expect(!state.visible(4001));
}

test "the hint stays put for as long as it is queued" {
    var state: State = .{};
    state.hint(.open_inventory, 1000);

    try std.testing.expect(state.visible(1000));
    try std.testing.expect(state.visible(1_000_000));
}

test "the window slides in, rests fully down, and slides back out" {
    try std.testing.expectApproxEqAbs(@as(f64, -drop_height), slideOffset(0.0), 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0), slideOffset(0.5), 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -drop_height), slideOffset(1.0), 1.0e-9);

    try std.testing.expect(slideOffset(0.1) > -drop_height);
    try std.testing.expect(slideOffset(0.1) < 0.0);
    try std.testing.expect(slideOffset(0.9) > -drop_height);
    try std.testing.expect(slideOffset(0.9) < 0.0);
}

test "a hint queued this instant is already resting at the bottom of its slide" {
    var state: State = .{};
    state.hint(.open_inventory, 5000);

    try std.testing.expectApproxEqAbs(@as(f64, 0), slideOffset(state.progress(5000)), 1.0e-9);
}

test "nothing draws before an achievement has ever been queued" {
    const state: State = .{};
    try std.testing.expect(!state.visible(0));
    try std.testing.expect(!state.visible(100_000));
}
