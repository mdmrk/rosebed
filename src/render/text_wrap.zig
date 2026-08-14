const std = @import("std");

const Font = @import("font.zig");

pub const line_height: f32 = 8;
pub const max_lines: usize = 16;
pub const buffer_bytes: usize = 512;

pub const Wrapped = struct {
    bytes: [buffer_bytes]u8 = undefined,
    ends: [max_lines]usize = @splat(0),
    count: usize = 0,

    pub fn line(self: *const Wrapped, index: usize) []const u8 {
        const start = if (index == 0) 0 else self.ends[index - 1];
        return self.bytes[start..self.ends[index]];
    }

    pub fn height(self: *const Wrapped) f32 {
        const drawn: f32 = @floatFromInt(self.count);
        return @max(drawn * line_height, line_height);
    }
};

fn trimmedLen(text: []const u8) usize {
    return std.mem.trim(u8, text, " ").len;
}

const Sink = struct {
    out: *Wrapped,
    written: usize = 0,

    fn emit(self: *Sink, text: []const u8) void {
        if (self.out.count == max_lines) return;
        const room = self.out.bytes.len - self.written;
        const length = @min(text.len, room);
        @memcpy(self.out.bytes[self.written..][0..length], text[0..length]);
        self.written += length;
        self.out.ends[self.out.count] = self.written;
        self.out.count += 1;
    }
};

fn appendWord(buffer: []u8, at: usize, word: []const u8) usize {
    const room = buffer.len - at;
    const taken = @min(word.len + 1, room);
    if (taken == 0) return at;
    @memcpy(buffer[at..][0 .. taken - 1], word[0 .. taken - 1]);
    buffer[at + taken - 1] = ' ';
    return at + taken;
}

fn wrapParagraph(font: Font, text: []const u8, width: u32, sink: *Sink) void {
    var joined: [buffer_bytes]u8 = undefined;

    var words = std.mem.splitScalar(u8, text, ' ');
    var pending: ?[]const u8 = words.next();

    while (pending) |first| {
        var length = appendWord(&joined, 0, first);
        pending = words.next();

        while (pending) |next| {
            const probe = appendWord(&joined, length, next);
            if (font.stringWidth(joined[0 .. probe - 1]) >= width) break;
            length = probe;
            pending = words.next();
        }

        var line = joined[0..length];
        while (font.stringWidth(line) > width) {
            var fits: usize = 0;
            while (fits < line.len and font.stringWidth(line[0 .. fits + 1]) <= width) fits += 1;
            if (fits == 0) break;
            if (trimmedLen(line[0..fits]) > 0) sink.emit(line[0..fits]);
            line = line[fits..];
        }
        if (trimmedLen(line) > 0) sink.emit(line);
    }
}

pub fn wrap(font: Font, text: []const u8, width: u32) Wrapped {
    var out: Wrapped = .{};
    var sink: Sink = .{ .out = &out };

    var paragraphs = std.mem.splitScalar(u8, text, '\n');
    while (paragraphs.next()) |paragraph| wrapParagraph(font, paragraph, width, &sink);

    return out;
}

const testing_font: Font = .{ .texture = 0, .char_width = @splat(6) };

test "a line breaks before the word that would overflow it" {
    const wrapped = wrap(testing_font, "aaa bbb ccc ddd", 42);

    try std.testing.expectEqual(@as(usize, 2), wrapped.count);
    try std.testing.expectEqualStrings("aaa bbb ", wrapped.line(0));
    try std.testing.expectEqualStrings("ccc ddd ", wrapped.line(1));
}

test "text that fits stays on one line and still measures a full line tall" {
    const wrapped = wrap(testing_font, "aaa", 120);

    try std.testing.expectEqual(@as(usize, 1), wrapped.count);
    try std.testing.expectEqualStrings("aaa ", wrapped.line(0));
    try std.testing.expectEqual(@as(f32, 8), wrapped.height());
}

test "a word longer than the whole width is cut where it stops fitting" {
    const wrapped = wrap(testing_font, "aaaaaaaaaa", 30);

    try std.testing.expectEqual(@as(usize, 2), wrapped.count);
    try std.testing.expectEqualStrings("aaaaa", wrapped.line(0));
    try std.testing.expectEqualStrings("aaaaa ", wrapped.line(1));
}

test "each newline starts a fresh paragraph" {
    const wrapped = wrap(testing_font, "aaa\nbbb", 120);

    try std.testing.expectEqual(@as(usize, 2), wrapped.count);
    try std.testing.expectEqualStrings("aaa ", wrapped.line(0));
    try std.testing.expectEqualStrings("bbb ", wrapped.line(1));
    try std.testing.expectEqual(@as(f32, 16), wrapped.height());
}

test "an empty description still takes one line of room" {
    const wrapped = wrap(testing_font, "", 120);

    try std.testing.expectEqual(@as(usize, 0), wrapped.count);
    try std.testing.expectEqual(@as(f32, 8), wrapped.height());
}
