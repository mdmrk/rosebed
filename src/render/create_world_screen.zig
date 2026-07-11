const std = @import("std");
const gl = @import("gl");

const MeshBuilder = @import("mesh_builder.zig");
const button = @import("button.zig");
const gui = @import("gui.zig");
const text_field = @import("text_field.zig");

const title_color: [4]u8 = .{ 255, 255, 255, 255 };
const label_color: [4]u8 = .{ 160, 160, 160, 255 };

pub const field_width: f32 = 200;
pub const name_y: f32 = 60;
pub const seed_y: f32 = 116;

pub const Mode = enum { create, rename };

pub const Hit = enum { name_field, seed_field, confirm, cancel };

pub const State = struct {
    mode: Mode,
    name: text_field.TextField = .{ .focused = true },
    seed: text_field.TextField = .{},
    folder: [64]u8 = undefined,
    folder_len: usize = 0,

    pub fn folderName(self: *const State) []const u8 {
        return self.folder[0..self.folder_len];
    }

    pub fn setFolderName(self: *State, value: []const u8) void {
        self.folder_len = @min(value.len, self.folder.len);
        @memcpy(self.folder[0..self.folder_len], value[0..self.folder_len]);
    }

    pub fn tick(self: *State) void {
        self.name.tick();
        self.seed.tick();
    }

    pub fn focus(self: *State, hit: Hit) void {
        self.name.focused = hit == .name_field;
        self.seed.focused = hit == .seed_field and self.mode == .create;
    }

    pub fn typeText(self: *State, value: []const u8) void {
        if (self.name.focused) self.name.insert(value);
        if (self.seed.focused) self.seed.insert(value);
    }

    pub fn backspace(self: *State) void {
        if (self.name.focused) self.name.backspace();
        if (self.seed.focused) self.seed.backspace();
    }
};

pub fn init(mode: Mode) State {
    return .{ .mode = mode };
}

pub fn fieldLeft(res: gui.Scaled) f32 {
    return @floor(res.width / 2.0) - field_width / 2.0;
}

pub fn nameRect(res: gui.Scaled) text_field.Rect {
    return .{ .x = fieldLeft(res), .y = name_y, .w = field_width };
}

pub fn seedRect(res: gui.Scaled) text_field.Rect {
    return .{ .x = fieldLeft(res), .y = seed_y, .w = field_width };
}

fn confirmLabel(mode: Mode) []const u8 {
    return switch (mode) {
        .create => "Create New World",
        .rename => "Rename",
    };
}

fn buttons(res: gui.Scaled, mode: Mode, can_confirm: bool) [2]struct { button: button.Button, hit: Hit } {
    const cx = @floor(res.width / 2.0);
    const quarter = @floor(res.height / 4.0);
    return .{
        .{ .button = .{ .x = cx - 100, .y = quarter + 96 + 12, .w = 200, .label = confirmLabel(mode), .enabled = can_confirm }, .hit = .confirm },
        .{ .button = .{ .x = cx - 100, .y = quarter + 120 + 12, .w = 200, .label = "Cancel", .enabled = true }, .hit = .cancel },
    };
}

pub fn hitAt(mouse_x: f32, mouse_y: f32, res: gui.Scaled, state: *const State) ?Hit {
    const gx = mouse_x / res.factor;
    const gy = mouse_y / res.factor;

    if (text_field.contains(nameRect(res), gx, gy)) return .name_field;
    if (state.mode == .create and text_field.contains(seedRect(res), gx, gy)) return .seed_field;

    for (buttons(res, state.mode, state.name.text().len > 0)) |entry| {
        if (entry.button.enabled and button.contains(entry.button, gx, gy)) return entry.hit;
    }
    return null;
}

pub fn draw(ui: gui.Ui, state: *const State) !void {
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

    for (buttons(ui.res, state.mode, state.name.text().len > 0)) |entry| {
        const hovered = entry.button.enabled and button.contains(entry.button, gx, gy);
        try button.append(&backgrounds, &text, ui.gpa, ui.font, entry.button, hovered, ui.res);
    }

    try text_field.append(&backgrounds, &text, ui.gpa, ui.font, &state.name, nameRect(ui.res), ui.res);
    if (state.mode == .create) {
        try text_field.append(&backgrounds, &text, ui.gpa, ui.font, &state.seed, seedRect(ui.res), ui.res);
    }

    const left = fieldLeft(ui.res);
    const title = switch (state.mode) {
        .create => "Create New World",
        .rename => "Rename World",
    };
    const title_width: f32 = @floatFromInt(ui.font.stringWidth(title));
    try gui.appendTextColor(&text, ui.gpa, ui.font, title, @floor(ui.res.width / 2.0) - @floor(title_width / 2.0), @floor(ui.res.height / 4.0) - 60 + 20, title_color, ui.res);

    try gui.appendTextColor(&text, ui.gpa, ui.font, "World Name", left, 47, label_color, ui.res);

    if (state.mode == .create) {
        var folder_buffer: [96]u8 = undefined;
        const folder_line = std.fmt.bufPrint(&folder_buffer, "Will be saved in: {s}", .{state.folderName()}) catch "Will be saved in:";
        try gui.appendTextColor(&text, ui.gpa, ui.font, folder_line, left, 85, label_color, ui.res);
        try gui.appendTextColor(&text, ui.gpa, ui.font, "Seed for the World Generator", left, 104, label_color, ui.res);
        try gui.appendTextColor(&text, ui.gpa, ui.font, "Leave blank for a random seed", left, 140, label_color, ui.res);
    }

    try gui.drawTexturedMesh(&backgrounds, ui.shader, ui.textures.gui);
    try gui.drawTexturedMesh(&text, ui.shader, ui.font);

    gl.Disable(gl.BLEND);
    gl.Enable(gl.DEPTH_TEST);
}

pub fn seedFromText(text: []const u8, fallback: i64) i64 {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return fallback;
    if (std.fmt.parseInt(i64, trimmed, 10)) |parsed| {
        if (parsed != 0) return parsed;
        return fallback;
    } else |_| {}

    var hash: i32 = 0;
    for (trimmed) |c| hash = hash *% 31 +% @as(i32, c);
    return hash;
}

test "a numeric seed is used verbatim and a blank one falls back to random" {
    try std.testing.expectEqual(@as(i64, 2024), seedFromText("2024", 99));
    try std.testing.expectEqual(@as(i64, -55), seedFromText(" -55 ", 99));
    try std.testing.expectEqual(@as(i64, 99), seedFromText("", 99));
    try std.testing.expectEqual(@as(i64, 99), seedFromText("0", 99));
}

test "a non-numeric seed hashes the way Java's String.hashCode does" {
    try std.testing.expectEqual(@as(i64, -1623774494), seedFromText("gargamel", 1));
    try std.testing.expectEqual(@as(i64, 97), seedFromText("a", 1));
    try std.testing.expectEqual(@as(i64, 108181935), seedFromText("glacier", 1));
}

test "clicking the fields focuses exactly one of them" {
    const res = gui.scaledResolution(640, 480, 1000);
    var state = init(.create);

    const left = fieldLeft(res);
    try std.testing.expectEqual(@as(?Hit, .name_field), hitAt((left + 10) * res.factor, (name_y + 10) * res.factor, res, &state));
    try std.testing.expectEqual(@as(?Hit, .seed_field), hitAt((left + 10) * res.factor, (seed_y + 10) * res.factor, res, &state));

    state.focus(.seed_field);
    try std.testing.expect(!state.name.focused);
    try std.testing.expect(state.seed.focused);
}

test "renaming hides the seed field" {
    const res = gui.scaledResolution(640, 480, 1000);
    var state = init(.rename);
    const left = fieldLeft(res);
    try std.testing.expectEqual(@as(?Hit, null), hitAt((left + 10) * res.factor, (seed_y + 10) * res.factor, res, &state));

    state.focus(.seed_field);
    try std.testing.expect(!state.seed.focused);
}

test "the confirm button stays disabled until a name is typed" {
    const res = gui.scaledResolution(640, 480, 1000);
    var state = init(.create);
    const cx = @floor(res.width / 2.0);
    const confirm_y = (@floor(res.height / 4.0) + 96 + 12 + 10) * res.factor;

    try std.testing.expectEqual(@as(?Hit, null), hitAt(cx * res.factor, confirm_y, res, &state));
    state.name.insert("New World");
    try std.testing.expectEqual(@as(?Hit, .confirm), hitAt(cx * res.factor, confirm_y, res, &state));
}

test "typing goes to whichever field has focus" {
    var state = init(.create);

    state.typeText("Hello");
    try std.testing.expectEqualStrings("Hello", state.name.text());
    try std.testing.expectEqualStrings("", state.seed.text());

    state.focus(.seed_field);
    state.typeText("123");
    try std.testing.expectEqualStrings("Hello", state.name.text());
    try std.testing.expectEqualStrings("123", state.seed.text());

    state.backspace();
    try std.testing.expectEqualStrings("12", state.seed.text());
}

test "the fields and buttons follow the window when it is resized" {
    var state = init(.create);
    state.name.insert("New World");

    const small = gui.scaledResolution(854, 480, 1000);
    const wide = gui.scaledResolution(1600, 900, 1000);
    try std.testing.expect(fieldLeft(small) != fieldLeft(wide));

    for ([_]gui.Scaled{ small, wide }) |res| {
        const name = nameRect(res);
        try std.testing.expectEqual(
            @as(?Hit, .name_field),
            hitAt((name.x + name.w / 2) * res.factor, (name.y + 10) * res.factor, res, &state),
        );

        const seed = seedRect(res);
        try std.testing.expectEqual(
            @as(?Hit, .seed_field),
            hitAt((seed.x + seed.w / 2) * res.factor, (seed.y + 10) * res.factor, res, &state),
        );

        const confirm = buttons(res, .create, true)[0].button;
        try std.testing.expectEqual(
            @as(?Hit, .confirm),
            hitAt((confirm.x + confirm.w / 2) * res.factor, (confirm.y + 10) * res.factor, res, &state),
        );

        try std.testing.expectEqual(name.x, seed.x);
        try std.testing.expectEqual(@floor(res.width / 2.0), name.x + name.w / 2);
    }
}
