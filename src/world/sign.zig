const std = @import("std");

const BlockPos = @import("BlockPos.zig");
const nbt = @import("nbt.zig");
const tile = @import("tile.zig");

pub const id_key = "Sign";
pub const line_count = 4;
pub const max_line_length = 15;

pub const Sign = struct {
    lines: [line_count][max_line_length]u8 = @splat(@splat(0)),
    lengths: [line_count]u8 = @splat(0),

    pub fn line(self: *const Sign, index: usize) []const u8 {
        return self.lines[index][0..self.lengths[index]];
    }

    pub fn setLine(self: *Sign, index: usize, text: []const u8) void {
        const kept = @min(text.len, max_line_length);
        @memcpy(self.lines[index][0..kept], text[0..kept]);
        self.lengths[index] = @intCast(kept);
    }

    pub fn append(self: *Sign, index: usize, char: u8) void {
        if (self.lengths[index] >= max_line_length) return;
        self.lines[index][self.lengths[index]] = char;
        self.lengths[index] += 1;
    }

    pub fn backspace(self: *Sign, index: usize) void {
        if (self.lengths[index] == 0) return;
        self.lengths[index] -= 1;
    }

    pub fn isBlank(self: *const Sign) bool {
        for (self.lengths) |length| {
            if (length > 0) return false;
        }
        return true;
    }
};

const line_keys = [line_count][]const u8{ "Text1", "Text2", "Text3", "Text4" };

pub fn store(gpa: std.mem.Allocator, pos: BlockPos, state: Sign) !nbt.Tag {
    var compound: nbt.Compound = .{};
    errdefer {
        var owned: nbt.Tag = .{ .compound = compound };
        nbt.deinit(gpa, &owned);
    }

    try tile.header(gpa, &compound, id_key, pos);

    for (line_keys, 0..) |key, index| {
        try nbt.putDuped(gpa, &compound, key, .{ .string = try gpa.dupe(u8, state.line(index)) });
    }

    return .{ .compound = compound };
}

pub const Placed = struct {
    pos: BlockPos,
    state: Sign,
};

pub fn isSign(compound: nbt.Compound) bool {
    return tile.isKind(compound, id_key);
}

fn stringField(compound: nbt.Compound, key: []const u8) []const u8 {
    return switch (compound.get(key) orelse return "") {
        .string => |value| value,
        else => "",
    };
}

pub fn load(compound: nbt.Compound) ?Placed {
    if (!isSign(compound)) return null;

    var state: Sign = .{};
    for (line_keys, 0..) |key, index| {
        state.setLine(index, stringField(compound, key));
    }

    return .{
        .pos = tile.position(compound) orelse return null,
        .state = state,
    };
}

test "a fresh sign is blank on every line" {
    var state: Sign = .{};
    try std.testing.expect(state.isBlank());
    try std.testing.expectEqualStrings("", state.line(0));

    state.append(2, 'x');
    try std.testing.expect(!state.isBlank());
    try std.testing.expectEqualStrings("x", state.line(2));
}

test "a line stops taking characters at fifteen" {
    var state: Sign = .{};
    for (0..20) |i| state.append(0, @intCast('a' + i % 26));

    try std.testing.expectEqual(@as(usize, max_line_length), state.line(0).len);
    try std.testing.expectEqualStrings("abcdefghijklmno", state.line(0));
}

test "backspace gives a line back one character at a time and stops when empty" {
    var state: Sign = .{};
    state.setLine(1, "hi");

    state.backspace(1);
    try std.testing.expectEqualStrings("h", state.line(1));
    state.backspace(1);
    try std.testing.expectEqualStrings("", state.line(1));
    state.backspace(1);
    try std.testing.expectEqualStrings("", state.line(1));
}

test "text longer than a line fits is cut where vanilla cuts it on load" {
    var state: Sign = .{};
    state.setLine(0, "a sign with far too much text on it");
    try std.testing.expectEqualStrings("a sign with far", state.line(0));
}

test "a sign's four lines survive a trip through NBT" {
    const gpa = std.testing.allocator;

    var state: Sign = .{};
    state.setLine(0, "Welcome");
    state.setLine(1, "");
    state.setLine(2, "to the mine");
    state.setLine(3, "mind the lava");

    var tag = try store(gpa, .init(4, 63, -7), state);
    defer nbt.deinit(gpa, &tag);

    const restored = load(tag.compound).?;
    try std.testing.expectEqual(BlockPos.init(4, 63, -7), restored.pos);
    try std.testing.expectEqualStrings("Welcome", restored.state.line(0));
    try std.testing.expectEqualStrings("", restored.state.line(1));
    try std.testing.expectEqualStrings("to the mine", restored.state.line(2));
    try std.testing.expectEqualStrings("mind the lava", restored.state.line(3));
}

test "a compound that is not a sign is not loaded as one" {
    const gpa = std.testing.allocator;
    var compound: nbt.Compound = .{};
    try nbt.putDuped(gpa, &compound, "id", .{ .string = try gpa.dupe(u8, "Furnace") });
    var tag: nbt.Tag = .{ .compound = compound };
    defer nbt.deinit(gpa, &tag);

    try std.testing.expect(!isSign(tag.compound));
    try std.testing.expect(load(tag.compound) == null);
}
