const std = @import("std");

const Font = @import("font.zig");
const gui = @import("gui.zig");
const MeshBuilder = @import("mesh_builder.zig");

pub const height: f32 = 20;
pub const max_length = 32;
pub const cursor_blink_ticks = 6;

const border_color: [4]u8 = .{ 160, 160, 160, 255 };
const fill_color: [4]u8 = .{ 0, 0, 0, 255 };
const text_color: [4]u8 = .{ 224, 224, 224, 255 };

pub const Rect = struct { x: f32, y: f32, w: f32 };

pub fn contains(rect: Rect, gx: f32, gy: f32) bool {
    return gx >= rect.x and gx < rect.x + rect.w and gy >= rect.y and gy < rect.y + height;
}

pub const TextField = struct {
    buffer: [max_length]u8 = undefined,
    len: usize = 0,
    focused: bool = false,
    blink: u32 = 0,

    pub fn text(self: *const TextField) []const u8 {
        return self.buffer[0..self.len];
    }

    pub fn setText(self: *TextField, value: []const u8) void {
        self.len = @min(value.len, max_length);
        @memcpy(self.buffer[0..self.len], value[0..self.len]);
    }

    pub fn insert(self: *TextField, value: []const u8) void {
        for (value) |c| {
            if (self.len == max_length) return;
            if (!isAllowed(c)) continue;
            self.buffer[self.len] = c;
            self.len += 1;
        }
    }

    pub fn backspace(self: *TextField) void {
        if (self.len > 0) self.len -= 1;
    }

    pub fn tick(self: *TextField) void {
        self.blink +%= 1;
    }

    fn cursorVisible(self: *const TextField) bool {
        return self.focused and (self.blink / cursor_blink_ticks) % 2 == 0;
    }
};

pub fn isAllowed(c: u8) bool {
    return c >= 32 and c < 127 and c != '/' and c != '\\' and c != '"' and c != ':';
}

pub fn append(
    background: *MeshBuilder,
    text_mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    font: Font,
    field: *const TextField,
    rect: Rect,
    res: gui.Scaled,
) !void {
    try gui.appendRectColor(background, gpa, rect.x - 1, rect.y - 1, rect.w + 2, height + 2, gui.opaque_texel, border_color, res);
    try gui.appendRectColor(background, gpa, rect.x, rect.y, rect.w, height, gui.opaque_texel, fill_color, res);

    var shown: [max_length + 1]u8 = undefined;
    const content = field.text();
    @memcpy(shown[0..content.len], content);
    var shown_len = content.len;
    if (field.cursorVisible() and shown_len < shown.len) {
        shown[shown_len] = '_';
        shown_len += 1;
    }

    try gui.appendTextColor(
        text_mesh,
        gpa,
        font,
        shown[0..shown_len],
        rect.x + 4,
        rect.y + (height - Font.glyph_size) / 2.0,
        text_color,
        res,
    );
}

test "typing appends only characters that are legal in a name" {
    var field: TextField = .{};
    field.insert("My World");
    try std.testing.expectEqualStrings("My World", field.text());

    field.insert("/\\:\"");
    try std.testing.expectEqualStrings("My World", field.text());
}

test "backspace removes the last character and stops at empty" {
    var field: TextField = .{};
    field.insert("ab");
    field.backspace();
    try std.testing.expectEqualStrings("a", field.text());
    field.backspace();
    field.backspace();
    try std.testing.expectEqualStrings("", field.text());
}

test "a field never takes more than its maximum length" {
    var field: TextField = .{};
    field.insert("x" ** (max_length * 2));
    try std.testing.expectEqual(max_length, field.text().len);
}

test "setText replaces the contents and truncates overlong input" {
    var field: TextField = .{};
    field.setText("hello");
    try std.testing.expectEqualStrings("hello", field.text());
    field.setText("y" ** (max_length + 5));
    try std.testing.expectEqual(max_length, field.text().len);
}

test "the cursor blinks only while the field is focused" {
    var field: TextField = .{};
    try std.testing.expect(!field.cursorVisible());

    field.focused = true;
    try std.testing.expect(field.cursorVisible());
    for (0..cursor_blink_ticks) |_| field.tick();
    try std.testing.expect(!field.cursorVisible());
    for (0..cursor_blink_ticks) |_| field.tick();
    try std.testing.expect(field.cursorVisible());
}

test "contains hits inside the box the caller lays out" {
    const rect: Rect = .{ .x = 100, .y = 60, .w = 200 };
    try std.testing.expect(contains(rect, 150, 70));
    try std.testing.expect(!contains(rect, 150, 90));
    try std.testing.expect(!contains(rect, 90, 70));
}
