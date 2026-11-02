const std = @import("std");

const Font = @import("Font.zig");
const gui = @import("gui.zig");
const MeshBuilder = @import("MeshBuilder.zig");

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
    scroll: usize = 0,

    message_bytes: [max_message_length]u8 = undefined,
    message_len: usize = 0,
    blink: u32 = 0,

    history: [max_lines][max_message_length]u8 = undefined,
    history_lengths: [max_lines]usize = @splat(0),
    history_line_count: usize = 0,
    history_pointer: usize = 0,

    pub fn message(self: *const State) []const u8 {
        return self.message_bytes[0..self.message_len];
    }

    pub fn openInput(self: *State) void {
        self.open = true;
        self.scroll = 0;
        self.message_len = 0;
        self.blink = 0;
        self.history_pointer = 0;
    }

    pub fn closeInput(self: *State) void {
        self.open = false;
        self.scroll = 0;
        self.message_len = 0;
        self.history_pointer = 0;
    }

    pub fn typeText(self: *State, value: []const u8) void {
        for (value) |c| {
            if (self.message_len == max_message_length) return;
            if (!isAllowed(c)) continue;

            self.message_bytes[self.message_len] = c;
            self.message_len += 1;
        }
    }

    pub fn setText(self: *State, text: []const u8) void {
        const len = @min(text.len, max_message_length);
        @memcpy(self.message_bytes[0..len], text[0..len]);
        self.message_len = len;
    }

    pub fn backspace(self: *State, word_delete: bool) void {
        if (self.message_len > 0) {
            if (word_delete) {
                while (self.message_len > 0 and std.ascii.isWhitespace(self.message_bytes[self.message_len - 1])) {
                    self.message_len -= 1;
                }
                while (self.message_len > 0 and !std.ascii.isWhitespace(self.message_bytes[self.message_len - 1])) {
                    self.message_len -= 1;
                }
            } else {
                self.message_len -= 1;
            }
        }
    }

    // history_pointer is a depth, not an index: 0 is the empty line the player is typing on,
    // and depth d recalls history[d - 1]. History is newest-first, so walking back (offset -1)
    // walks the depth forward.
    pub fn setTextFromHistory(self: *State, offset: i32) void {
        if (self.history_line_count == 0) return;

        const current: i32 = @intCast(self.history_pointer);
        const oldest: i32 = @intCast(self.history_line_count);

        const next: usize = @intCast(std.math.clamp(current - offset, 0, oldest));
        self.history_pointer = next;

        if (next == 0) {
            self.setText("");
            return;
        }

        const index = next - 1;
        self.setText(self.history[index][0..self.history_lengths[index]]);
    }

    pub fn tick(self: *State) void {
        for (self.lines[0..self.line_count]) |*line| line.age +|= 1;
        if (self.open) self.blink +%= 1;
    }

    pub fn clear(self: *State) void {
        self.line_count = 0;
        self.scroll = 0;
    }

    pub fn scrollBy(self: *State, lines: i32) void {
        const max_scroll = self.line_count -| open_line_limit;
        const next = @as(i64, @intCast(self.scroll)) + lines;
        self.scroll = @intCast(std.math.clamp(next, 0, @as(i64, @intCast(max_scroll))));
    }

    pub fn addMessage(self: *State, font: Font, text: []const u8) void {
        var rest = text;

        while (font.stringWidth(rest) > wrap_width) {
            var split: usize = 1;
            while (split < rest.len and
                font.stringWidth(rest[0 .. split + 1]) <= wrap_width) : (split += 1)
            {}

            self.pushLine(rest[0..split]);
            rest = rest[split..];
        }

        self.pushLine(rest);
    }

    fn pushLine(self: *State, text: []const u8) void {
        if (self.line_count < max_lines) self.line_count += 1;
        if (self.scroll > 0) self.scroll = @min(self.scroll + 1, self.line_count -| open_line_limit);

        var i = self.line_count - 1;
        while (i > 0) : (i -= 1) self.lines[i] = self.lines[i - 1];

        const len = @min(text.len, max_message_length);
        @memcpy(self.lines[0].bytes[0..len], text[0..len]);
        self.lines[0].len = len;
        self.lines[0].age = 0;
    }

    pub fn pushHistory(self: *State, text: []const u8) void {
        const len = @min(text.len, max_message_length);

        if (self.history_line_count < max_lines) {
            self.history_line_count += 1;
        }

        var i = self.history_line_count - 1;
        while (i > 0) : (i -= 1) {
            const old_len = self.history_lengths[i - 1];

            self.history_lengths[i] = old_len;

            if (old_len > 0) {
                @memcpy(
                    self.history[i][0..old_len],
                    self.history[i - 1][0..old_len],
                );
            }
        }

        if (len > 0) {
            @memcpy(self.history[0][0..len], text[0..len]);
        }
        self.history_lengths[0] = len;
        self.history_pointer = 0;
    }

    fn cursorVisible(self: *const State) bool {
        return (self.blink / cursor_blink_ticks) % 2 == 0;
    }
};

pub fn draw(ui: gui.Ui, state: *const State) !void {
    gui.beginOverlay();

    var backgrounds: MeshBuilder = .{};
    defer backgrounds.deinit(ui.gpa);
    var text: MeshBuilder = .{};
    defer text.deinit(ui.gpa);

    const limit: usize = if (state.open) open_line_limit else closed_line_limit;
    const base_y = ui.res.height - 48;
    const first = if (state.open) state.scroll else 0;
    const last = @min(state.line_count, first + limit);
    for (state.lines[first..last], 0..) |line, i| {
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

    gui.endOverlay();
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

test "history owns copied message data" {
    var state: State = .{};

    var input: [max_message_length]u8 = undefined;
    @memcpy(input[0..5], "first");
    state.pushHistory(input[0..5]);

    @memcpy(input[0..6], "second");
    state.pushHistory(input[0..6]);

    try std.testing.expectEqual(@as(usize, 2), state.history_line_count);
    try std.testing.expectEqualStrings("second", state.history[0][0..state.history_lengths[0]]);
    try std.testing.expectEqualStrings("first", state.history[1][0..state.history_lengths[1]]);
}

test "history navigation goes newest to oldest and back to empty" {
    var state: State = .{};
    state.pushHistory("first");
    state.pushHistory("second");

    state.openInput();

    state.setTextFromHistory(-1);
    try std.testing.expectEqualStrings("second", state.message());

    state.setTextFromHistory(-1);
    try std.testing.expectEqualStrings("first", state.message());

    state.setTextFromHistory(1);
    try std.testing.expectEqualStrings("second", state.message());

    state.setTextFromHistory(1);
    try std.testing.expectEqualStrings("", state.message());
}

test "history navigation stops at both ends rather than wrapping" {
    var state: State = .{};
    state.pushHistory("first");
    state.pushHistory("second");
    state.openInput();

    for (0..5) |_| state.setTextFromHistory(-1);
    try std.testing.expectEqualStrings("first", state.message());

    for (0..5) |_| state.setTextFromHistory(1);
    try std.testing.expectEqualStrings("", state.message());
}

test "sending a line puts history back at the empty end" {
    var state: State = .{};
    state.pushHistory("first");
    state.openInput();

    state.setTextFromHistory(-1);
    try std.testing.expectEqualStrings("first", state.message());

    state.pushHistory("second");
    try std.testing.expectEqual(@as(usize, 0), state.history_pointer);

    state.setTextFromHistory(-1);
    try std.testing.expectEqualStrings("second", state.message());
}

test "the backlog stops at fifty lines and drops the oldest" {
    var state: State = .{};
    for (0..max_lines + 5) |i| {
        var buf: [8]u8 = undefined;
        state.addMessage(test_font, std.mem.print(&buf, "{d}", .{i}) catch unreachable);
    }

    try std.testing.expectEqual(max_lines, state.line_count);
    try std.testing.expectEqualStrings("54", state.lines[0].text());
    try std.testing.expectEqualStrings("5", state.lines[max_lines - 1].text());
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
