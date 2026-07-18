const std = @import("std");

const gl = @import("gl");

const Font = @import("font.zig");
const gui = @import("gui.zig");
const MeshBuilder = @import("mesh_builder.zig");

pub const max_message_length = 100;
pub const max_lines = 50;
pub const wrap_width = 320;
pub const fade_ticks = 200;

const line_height: f32 = 9;
const closed_line_limit = 10;
const open_line_limit = 20;
const cursor_blink_ticks = 6;

const line_color: [4]u8 = .{ 255, 255, 255, 255 };
const input_color: [4]u8 = .{ 224, 224, 224, 255 };
const input_background: [4]u8 = .{ 0, 0, 0, 128 };

const Line = struct {
    bytes: [max_message_length]u8 = undefined,
    len: usize = 0,
    age: u32 = 0,

    fn text(self: *const Line) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub fn isAllowed(c: u8) bool {
    return c >= 32 and c < 127 and c != '`';
}

pub fn lineAlpha(age: u32, open: bool) u8 {
    if (open) return 255;
    if (age >= fade_ticks) return 0;
    const faded = 1.0 - @as(f64, @floatFromInt(age)) / 200.0;
    const opacity = std.math.clamp(faded * 10.0, 0.0, 1.0);
    return @intFromFloat(255.0 * opacity * opacity);
}

pub const State = struct {
    lines: [max_lines]Line = @splat(.{}),
    line_count: usize = 0,
    open: bool = false,
    message_bytes: [max_message_length]u8 = undefined,
    message_len: usize = 0,
    blink: u32 = 0,

    pub fn message(self: *const State) []const u8 {
        return self.message_bytes[0..self.message_len];
    }

    pub fn openInput(self: *State) void {
        self.open = true;
        self.message_len = 0;
        self.blink = 0;
    }

    pub fn closeInput(self: *State) void {
        self.open = false;
        self.message_len = 0;
    }

    pub fn typeText(self: *State, value: []const u8) void {
        for (value) |c| {
            if (self.message_len == max_message_length) return;
            if (!isAllowed(c)) continue;
            self.message_bytes[self.message_len] = c;
            self.message_len += 1;
        }
    }

    pub fn backspace(self: *State) void {
        if (self.message_len > 0) self.message_len -= 1;
    }

    pub fn tick(self: *State) void {
        for (self.lines[0..self.line_count]) |*line| line.age +|= 1;
        if (self.open) self.blink +%= 1;
    }

    pub fn clear(self: *State) void {
        self.line_count = 0;
    }

    pub fn addMessage(self: *State, font: Font, text: []const u8) void {
        var rest = text;
        while (font.stringWidth(rest) > wrap_width) {
            var split: usize = 1;
            while (split < rest.len and font.stringWidth(rest[0 .. split + 1]) <= wrap_width) : (split += 1) {}
            self.pushLine(rest[0..split]);
            rest = rest[split..];
        }
        self.pushLine(rest);
    }

    fn pushLine(self: *State, text: []const u8) void {
        if (self.line_count < max_lines) self.line_count += 1;
        var i = self.line_count - 1;
        while (i > 0) : (i -= 1) self.lines[i] = self.lines[i - 1];

        const len = @min(text.len, max_message_length);
        @memcpy(self.lines[0].bytes[0..len], text[0..len]);
        self.lines[0].len = len;
        self.lines[0].age = 0;
    }

    fn cursorVisible(self: *const State) bool {
        return (self.blink / cursor_blink_ticks) % 2 == 0;
    }
};

pub fn draw(ui: gui.Ui, state: *const State) !void {
    gl.Disable(gl.DEPTH_TEST);
    gl.Enable(gl.BLEND);
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

    var backgrounds: MeshBuilder = .{};
    defer backgrounds.deinit(ui.gpa);
    var text: MeshBuilder = .{};
    defer text.deinit(ui.gpa);

    const limit: usize = if (state.open) open_line_limit else closed_line_limit;
    const base_y = ui.res.height - 48;
    for (state.lines[0..@min(state.line_count, limit)], 0..) |line, i| {
        const alpha = lineAlpha(line.age, state.open);
        if (alpha == 0) continue;

        const y = base_y - @as(f32, @floatFromInt(i)) * line_height;
        try gui.appendRectColor(&backgrounds, ui.gpa, 2, y - 1, wrap_width, line_height, gui.opaque_texel, .{ 0, 0, 0, alpha / 2 }, ui.res);
        try gui.appendTextColor(&text, ui.gpa, ui.font, line.text(), 2, y, .{ line_color[0], line_color[1], line_color[2], alpha }, ui.res);
    }

    if (state.open) {
        try gui.appendRectColor(&backgrounds, ui.gpa, 2, ui.res.height - 14, ui.res.width - 4, 12, gui.opaque_texel, input_background, ui.res);

        var shown: [max_message_length + 3]u8 = undefined;
        const prompt = "> ";
        @memcpy(shown[0..prompt.len], prompt);
        var shown_len = prompt.len;
        @memcpy(shown[shown_len..][0..state.message_len], state.message());
        shown_len += state.message_len;
        if (state.cursorVisible()) {
            shown[shown_len] = '_';
            shown_len += 1;
        }
        try gui.appendTextColor(&text, ui.gpa, ui.font, shown[0..shown_len], 4, ui.res.height - 12, input_color, ui.res);
    }

    try gui.drawColorMesh(&backgrounds, ui.shader);
    try gui.drawTexturedMesh(&text, ui.shader, ui.font);

    gl.Disable(gl.BLEND);
    gl.Enable(gl.DEPTH_TEST);
}

const test_font: Font = .{ .texture = 0, .char_width = @splat(6) };

test "a line fades out over two hundred ticks the way the overlay squares it" {
    try std.testing.expectEqual(@as(u8, 255), lineAlpha(0, false));
    try std.testing.expectEqual(@as(u8, 255), lineAlpha(179, false));
    try std.testing.expectEqual(@as(u8, 254), lineAlpha(180, false));
    try std.testing.expectEqual(@as(u8, 163), lineAlpha(184, false));
    try std.testing.expectEqual(@as(u8, 63), lineAlpha(190, false));
    try std.testing.expectEqual(@as(u8, 2), lineAlpha(198, false));
    try std.testing.expectEqual(@as(u8, 0), lineAlpha(199, false));
    try std.testing.expectEqual(@as(u8, 0), lineAlpha(200, false));
    try std.testing.expectEqual(@as(u8, 0), lineAlpha(5000, false));
}

test "an open chat holds every line at full opacity" {
    try std.testing.expectEqual(@as(u8, 255), lineAlpha(0, true));
    try std.testing.expectEqual(@as(u8, 255), lineAlpha(5000, true));
}

test "the newest message sits at index zero" {
    var state: State = .{};
    state.addMessage(test_font, "first");
    state.addMessage(test_font, "second");

    try std.testing.expectEqual(@as(usize, 2), state.line_count);
    try std.testing.expectEqualStrings("second", state.lines[0].text());
    try std.testing.expectEqualStrings("first", state.lines[1].text());
}

test "a message wider than 320 pixels splits, head first" {
    var state: State = .{};
    state.addMessage(test_font, "x" ** 60);

    try std.testing.expectEqual(@as(usize, 2), state.line_count);
    try std.testing.expectEqualStrings("x" ** 53, state.lines[1].text());
    try std.testing.expectEqualStrings("x" ** 7, state.lines[0].text());
    try std.testing.expect(test_font.stringWidth(state.lines[1].text()) <= wrap_width);
}

test "the backlog stops at fifty lines and drops the oldest" {
    var state: State = .{};
    for (0..max_lines + 5) |i| {
        var buf: [8]u8 = undefined;
        state.addMessage(test_font, std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable);
    }

    try std.testing.expectEqual(max_lines, state.line_count);
    try std.testing.expectEqualStrings("54", state.lines[0].text());
    try std.testing.expectEqualStrings("5", state.lines[max_lines - 1].text());
}

test "typing keeps only characters the font sheet lists" {
    var state: State = .{};
    state.typeText("hello");
    state.typeText("`\t\n");
    try std.testing.expectEqualStrings("hello", state.message());
}

test "a message never grows past a hundred characters" {
    var state: State = .{};
    state.typeText("y" ** (max_message_length * 2));
    try std.testing.expectEqual(max_message_length, state.message().len);
}

test "closing the input throws the half-typed message away" {
    var state: State = .{};
    state.openInput();
    state.typeText("half typed");
    state.closeInput();

    try std.testing.expect(!state.open);
    try std.testing.expectEqualStrings("", state.message());
}

test "only an open input blinks the cursor" {
    var state: State = .{};
    for (0..cursor_blink_ticks) |_| state.tick();
    try std.testing.expect(state.cursorVisible());

    state.openInput();
    try std.testing.expect(state.cursorVisible());
    for (0..cursor_blink_ticks) |_| state.tick();
    try std.testing.expect(!state.cursorVisible());
    for (0..cursor_blink_ticks) |_| state.tick();
    try std.testing.expect(state.cursorVisible());
}

test "ticking ages every line that is still in the backlog" {
    var state: State = .{};
    state.addMessage(test_font, "one");
    state.tick();
    state.addMessage(test_font, "two");
    state.tick();

    try std.testing.expectEqual(@as(u32, 1), state.lines[0].age);
    try std.testing.expectEqual(@as(u32, 2), state.lines[1].age);
}
