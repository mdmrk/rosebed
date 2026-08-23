const std = @import("std");

pub const TagId = enum(u8) {
    end = 0,
    byte = 1,
    short = 2,
    int = 3,
    long = 4,
    float = 5,
    double = 6,
    byte_array = 7,
    string = 8,
    list = 9,
    compound = 10,
};

pub const Compound = std.array_hash_map.String(Tag);

pub const List = struct {
    element_type: TagId,
    items: []Tag,
};

pub const Tag = union(TagId) {
    end: void,
    byte: i8,
    short: i16,
    int: i32,
    long: i64,
    float: f32,
    double: f64,
    byte_array: []u8,
    string: []u8,
    list: List,
    compound: Compound,
};

pub const NamedTag = struct {
    name: []u8,
    tag: Tag,
};

pub fn putDuped(gpa: std.mem.Allocator, compound: *Compound, key: []const u8, tag: Tag) !void {
    try compound.put(gpa, try gpa.dupe(u8, key), tag);
}

pub fn intField(compound: Compound, key: []const u8) ?i32 {
    return switch (compound.get(key) orelse return null) {
        .int => |value| value,
        else => null,
    };
}

pub fn shortField(compound: Compound, key: []const u8) i16 {
    return switch (compound.get(key) orelse return 0) {
        .short => |value| value,
        else => 0,
    };
}

fn writeString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeInt(u16, @intCast(s.len), .big);
    try w.writeAll(s);
}

fn writePayload(w: *std.Io.Writer, tag: Tag) !void {
    switch (tag) {
        .end => {},
        .byte => |v| try w.writeInt(i8, v, .big),
        .short => |v| try w.writeInt(i16, v, .big),
        .int => |v| try w.writeInt(i32, v, .big),
        .long => |v| try w.writeInt(i64, v, .big),
        .float => |v| try w.writeInt(u32, @bitCast(v), .big),
        .double => |v| try w.writeInt(u64, @bitCast(v), .big),
        .byte_array => |v| {
            try w.writeInt(i32, @intCast(v.len), .big);
            try w.writeAll(v);
        },
        .string => |v| try writeString(w, v),
        .list => |l| {
            try w.writeByte(@intFromEnum(l.element_type));
            try w.writeInt(i32, @intCast(l.items.len), .big);
            for (l.items) |item| try writePayload(w, item);
        },
        .compound => |c| {
            var it = c.iterator();
            while (it.next()) |entry| {
                try w.writeByte(@intFromEnum(std.meta.activeTag(entry.value_ptr.*)));
                try writeString(w, entry.key_ptr.*);
                try writePayload(w, entry.value_ptr.*);
            }
            try w.writeByte(0);
        },
    }
}

pub fn writeNamed(w: *std.Io.Writer, name: []const u8, tag: Tag) !void {
    try w.writeByte(@intFromEnum(std.meta.activeTag(tag)));
    try writeString(w, name);
    try writePayload(w, tag);
}

fn readString(gpa: std.mem.Allocator, r: *std.Io.Reader) ![]u8 {
    const len = try r.takeInt(u16, .big);
    const buf = try gpa.alloc(u8, len);
    errdefer gpa.free(buf);
    try r.readSliceAll(buf);
    return buf;
}

fn readPayload(gpa: std.mem.Allocator, r: *std.Io.Reader, id: TagId) anyerror!Tag {
    return switch (id) {
        .end => .{ .end = {} },
        .byte => .{ .byte = try r.takeInt(i8, .big) },
        .short => .{ .short = try r.takeInt(i16, .big) },
        .int => .{ .int = try r.takeInt(i32, .big) },
        .long => .{ .long = try r.takeInt(i64, .big) },
        .float => .{ .float = @bitCast(try r.takeInt(u32, .big)) },
        .double => .{ .double = @bitCast(try r.takeInt(u64, .big)) },
        .byte_array => blk: {
            const len = try r.takeInt(i32, .big);
            const buf = try gpa.alloc(u8, @intCast(len));
            errdefer gpa.free(buf);
            try r.readSliceAll(buf);
            break :blk .{ .byte_array = buf };
        },
        .string => .{ .string = try readString(gpa, r) },
        .list => blk: {
            const elem_id: TagId = @enumFromInt(try r.takeByte());
            const count = try r.takeInt(i32, .big);
            const items = try gpa.alloc(Tag, @intCast(count));
            for (items) |*item| item.* = try readPayload(gpa, r, elem_id);
            break :blk .{ .list = .{ .element_type = elem_id, .items = items } };
        },
        .compound => blk: {
            var map: Compound = .{};
            while (true) {
                const type_byte = try r.takeByte();
                if (type_byte == 0) break;
                const child_id: TagId = @enumFromInt(type_byte);
                const name = try readString(gpa, r);
                const value = try readPayload(gpa, r, child_id);
                try map.put(gpa, name, value);
            }
            break :blk .{ .compound = map };
        },
    };
}

pub fn readNamed(gpa: std.mem.Allocator, r: *std.Io.Reader) !NamedTag {
    const type_byte = try r.takeByte();
    const id: TagId = @enumFromInt(type_byte);
    const name = try readString(gpa, r);
    const tag = try readPayload(gpa, r, id);
    return .{ .name = name, .tag = tag };
}

pub fn deinit(gpa: std.mem.Allocator, tag: *Tag) void {
    switch (tag.*) {
        .byte_array => |v| gpa.free(v),
        .string => |v| gpa.free(v),
        .list => |*l| {
            for (l.items) |*item| deinit(gpa, item);
            gpa.free(l.items);
        },
        .compound => |*c| {
            for (c.keys()) |key| gpa.free(key);
            for (c.values()) |*value| deinit(gpa, value);
            c.deinit(gpa);
        },
        else => {},
    }
}

test "round-trips a compound with every tag type, including a nested list and compound" {
    const gpa = std.testing.allocator;

    var inner: Compound = .{};
    try inner.put(gpa, try gpa.dupe(u8, "greeting"), .{ .string = try gpa.dupe(u8, "hello") });

    var list_items = try gpa.alloc(Tag, 3);
    list_items[0] = .{ .int = 1 };
    list_items[1] = .{ .int = 2 };
    list_items[2] = .{ .int = 3 };

    var root: Compound = .{};
    try root.put(gpa, try gpa.dupe(u8, "a_byte"), .{ .byte = -12 });
    try root.put(gpa, try gpa.dupe(u8, "a_short"), .{ .short = -1234 });
    try root.put(gpa, try gpa.dupe(u8, "an_int"), .{ .int = -123456 });
    try root.put(gpa, try gpa.dupe(u8, "a_long"), .{ .long = -123456789 });
    try root.put(gpa, try gpa.dupe(u8, "a_float"), .{ .float = 1.5 });
    try root.put(gpa, try gpa.dupe(u8, "a_double"), .{ .double = 2.5 });
    try root.put(gpa, try gpa.dupe(u8, "bytes"), .{ .byte_array = try gpa.dupe(u8, &.{ 1, 2, 3 }) });
    try root.put(gpa, try gpa.dupe(u8, "a_string"), .{ .string = try gpa.dupe(u8, "world") });
    try root.put(gpa, try gpa.dupe(u8, "a_list"), .{ .list = .{ .element_type = .int, .items = list_items } });
    try root.put(gpa, try gpa.dupe(u8, "a_compound"), .{ .compound = inner });

    var root_tag: Tag = .{ .compound = root };
    defer deinit(gpa, &root_tag);

    var allocating: std.Io.Writer.Allocating = .init(gpa);
    defer allocating.deinit();
    try writeNamed(&allocating.writer, "root", root_tag);

    const bytes = allocating.written();
    var reader = std.Io.Reader.fixed(bytes);
    var parsed = try readNamed(gpa, &reader);
    defer gpa.free(parsed.name);
    defer deinit(gpa, &parsed.tag);

    try std.testing.expectEqualStrings("root", parsed.name);
    const parsed_compound = parsed.tag.compound;
    try std.testing.expectEqual(@as(i8, -12), parsed_compound.get("a_byte").?.byte);
    try std.testing.expectEqual(@as(i16, -1234), parsed_compound.get("a_short").?.short);
    try std.testing.expectEqual(@as(i32, -123456), parsed_compound.get("an_int").?.int);
    try std.testing.expectEqual(@as(i64, -123456789), parsed_compound.get("a_long").?.long);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), parsed_compound.get("a_float").?.float, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), parsed_compound.get("a_double").?.double, 1.0e-9);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, parsed_compound.get("bytes").?.byte_array);
    try std.testing.expectEqualStrings("world", parsed_compound.get("a_string").?.string);

    const parsed_list = parsed_compound.get("a_list").?.list;
    try std.testing.expectEqual(TagId.int, parsed_list.element_type);
    try std.testing.expectEqual(@as(usize, 3), parsed_list.items.len);
    try std.testing.expectEqual(@as(i32, 2), parsed_list.items[1].int);

    const parsed_inner = parsed_compound.get("a_compound").?.compound;
    try std.testing.expectEqualStrings("hello", parsed_inner.get("greeting").?.string);
}

test "an empty compound round-trips to just a TAG_End terminator" {
    const gpa = std.testing.allocator;
    const root: Compound = .{};
    var root_tag: Tag = .{ .compound = root };
    defer deinit(gpa, &root_tag);

    var allocating: std.Io.Writer.Allocating = .init(gpa);
    defer allocating.deinit();
    try writeNamed(&allocating.writer, "", root_tag);

    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 0, 0 }, allocating.written());
}
