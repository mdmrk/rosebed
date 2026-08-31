const std = @import("std");

const world = @import("world");

pub const folder_name = "texturepacks";
pub const default_name = "Default";
pub const default_line = "The default look of Minecraft";
pub const max_line_len = 34;
pub const max_resource_bytes = 16 * 1024 * 1024;

const end_record_sig = [4]u8{ 'P', 'K', 5, 6 };
const central_header_sig = [4]u8{ 'P', 'K', 1, 2 };
const local_header_sig = [4]u8{ 'P', 'K', 3, 4 };
const end_record_len = 22;
const central_header_len = 46;
const local_header_len = 30;

pub const Pack = struct {
    name: []u8,
    lines: [2][]u8,
    thumbnail: ?[]u8,

    pub fn deinit(self: *Pack, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        for (self.lines) |line| gpa.free(line);
        if (self.thumbnail) |bytes| gpa.free(bytes);
    }
};

fn readInt(comptime T: type, bytes: []const u8, offset: usize) T {
    const size = @sizeOf(T);
    return std.mem.readInt(T, bytes[offset..][0..size], .little);
}

fn findEndRecord(archive: []const u8) ?usize {
    if (archive.len < end_record_len) return null;
    var start = archive.len - end_record_len;
    while (true) : (start -= 1) {
        if (std.mem.eql(u8, archive[start..][0..4], &end_record_sig)) {
            const comment_len = readInt(u16, archive, start + 20);
            if (start + end_record_len + comment_len == archive.len) return start;
        }
        if (start == 0) return null;
    }
}

pub fn readArchiveEntry(
    gpa: std.mem.Allocator,
    archive: []const u8,
    path: []const u8,
    limit: usize,
) !?[]u8 {
    const end = findEndRecord(archive) orelse return error.NotAnArchive;
    const count = readInt(u16, archive, end + 10);
    var offset: usize = readInt(u32, archive, end + 16);

    for (0..count) |_| {
        if (offset + central_header_len > archive.len) return error.CorruptArchive;
        if (!std.mem.eql(u8, archive[offset..][0..4], &central_header_sig)) return error.CorruptArchive;

        const method = readInt(u16, archive, offset + 10);
        const compressed_len: usize = readInt(u32, archive, offset + 20);
        const plain_len: usize = readInt(u32, archive, offset + 24);
        const name_len: usize = readInt(u16, archive, offset + 28);
        const extra_len: usize = readInt(u16, archive, offset + 30);
        const comment_len: usize = readInt(u16, archive, offset + 32);
        const local_offset: usize = readInt(u32, archive, offset + 42);

        const name_start = offset + central_header_len;
        if (name_start + name_len > archive.len) return error.CorruptArchive;

        if (std.mem.eql(u8, archive[name_start..][0..name_len], path)) {
            if (plain_len > limit) return error.StreamTooLong;
            if (local_offset + local_header_len > archive.len) return error.CorruptArchive;
            if (!std.mem.eql(u8, archive[local_offset..][0..4], &local_header_sig)) return error.CorruptArchive;

            const local_name_len: usize = readInt(u16, archive, local_offset + 26);
            const local_extra_len: usize = readInt(u16, archive, local_offset + 28);
            const data = local_offset + local_header_len + local_name_len + local_extra_len;
            if (data + compressed_len > archive.len) return error.CorruptArchive;

            return switch (method) {
                0 => try gpa.dupe(u8, archive[data..][0..compressed_len]),
                8 => try world.deflate.decompressAlloc(gpa, .raw, archive[data..][0..compressed_len], limit),
                else => error.UnsupportedCompression,
            };
        }

        offset = name_start + name_len + extra_len + comment_len;
    }

    return null;
}

pub fn readArchive(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8) ![]u8 {
    const file = try dir.openFile(io, name, .{});
    defer file.close(io);

    const size = try file.length(io);
    if (size > max_resource_bytes) return error.StreamTooLong;

    const bytes = try gpa.alloc(u8, @intCast(size));
    errdefer gpa.free(bytes);
    if (try file.readPositionalAll(io, bytes, 0) != bytes.len) return error.EndOfStream;
    return bytes;
}

pub fn readResource(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    archive_name: []const u8,
    path: []const u8,
) !?[]u8 {
    const archive = try readArchive(gpa, io, dir, archive_name);
    defer gpa.free(archive);
    return readArchiveEntry(gpa, archive, path, max_resource_bytes);
}

fn truncated(gpa: std.mem.Allocator, line: []const u8) ![]u8 {
    return gpa.dupe(u8, line[0..@min(line.len, max_line_len)]);
}

pub fn descriptionLines(gpa: std.mem.Allocator, pack_txt: []const u8) ![2][]u8 {
    var lines: [2][]u8 = .{ &.{}, &.{} };
    errdefer for (lines) |line| gpa.free(line);

    var iterator = std.mem.splitScalar(u8, pack_txt, '\n');
    for (&lines) |*line| {
        const raw = iterator.next() orelse break;
        line.* = try truncated(gpa, std.mem.trimEnd(u8, raw, "\r"));
    }
    return lines;
}

fn defaultPack(gpa: std.mem.Allocator) !Pack {
    return .{
        .name = try gpa.dupe(u8, default_name),
        .lines = .{ try gpa.dupe(u8, default_line), try gpa.dupe(u8, "") },
        .thumbnail = null,
    };
}

fn customPack(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8) !Pack {
    const archive = try readArchive(gpa, io, dir, name);
    defer gpa.free(archive);

    var lines: [2][]u8 = .{ try gpa.dupe(u8, ""), try gpa.dupe(u8, "") };
    errdefer for (lines) |line| gpa.free(line);

    if (readArchiveEntry(gpa, archive, "pack.txt", max_resource_bytes) catch null) |text| {
        defer gpa.free(text);
        for (lines) |line| gpa.free(line);
        lines = try descriptionLines(gpa, text);
    }

    const thumbnail = readArchiveEntry(gpa, archive, "pack.png", max_resource_bytes) catch null;
    errdefer if (thumbnail) |bytes| gpa.free(bytes);

    return .{ .name = try gpa.dupe(u8, name), .lines = lines, .thumbnail = thumbnail };
}

fn nameLess(_: void, a: Pack, b: Pack) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

pub fn open(io: std.Io, base: std.Io.Dir) !std.Io.Dir {
    return base.createDirPathOpen(io, folder_name, .{ .open_options = .{ .iterate = true } });
}

pub fn scan(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) ![]Pack {
    var found: std.ArrayList(Pack) = .empty;
    errdefer {
        for (found.items) |*pack| pack.deinit(gpa);
        found.deinit(gpa);
    }

    try found.append(gpa, try defaultPack(gpa));

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.ascii.endsWithIgnoreCase(entry.name, ".zip")) continue;
        try found.append(gpa, customPack(gpa, io, dir, entry.name) catch continue);
    }

    const packs = try found.toOwnedSlice(gpa);
    std.mem.sort(Pack, packs[1..], {}, nameLess);
    return packs;
}

pub fn deinitAll(gpa: std.mem.Allocator, packs: []Pack) void {
    for (packs) |*pack| pack.deinit(gpa);
    gpa.free(packs);
}

pub fn isDefault(pack: Pack) bool {
    return std.mem.eql(u8, pack.name, default_name);
}

pub fn indexOf(packs: []const Pack, name: []const u8) ?usize {
    for (packs, 0..) |pack, index| {
        if (std.mem.eql(u8, pack.name, name)) return index;
    }
    return null;
}

const testing_archive = struct {
    fn appendInt(list: *std.ArrayList(u8), gpa: std.mem.Allocator, comptime T: type, value: T) !void {
        var bytes: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &bytes, value, .little);
        try list.appendSlice(gpa, &bytes);
    }

    fn build(gpa: std.mem.Allocator, names: []const []const u8, bodies: []const []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);

        var offsets: [8]u32 = undefined;
        for (names, bodies, 0..) |name, body, index| {
            offsets[index] = @intCast(out.items.len);
            try out.appendSlice(gpa, &local_header_sig);
            try appendInt(&out, gpa, u16, 20);
            try appendInt(&out, gpa, u16, 0);
            try appendInt(&out, gpa, u16, 0);
            try appendInt(&out, gpa, u16, 0);
            try appendInt(&out, gpa, u16, 0);
            try appendInt(&out, gpa, u32, 0);
            try appendInt(&out, gpa, u32, @intCast(body.len));
            try appendInt(&out, gpa, u32, @intCast(body.len));
            try appendInt(&out, gpa, u16, @intCast(name.len));
            try appendInt(&out, gpa, u16, 0);
            try out.appendSlice(gpa, name);
            try out.appendSlice(gpa, body);
        }

        const central_start: u32 = @intCast(out.items.len);
        for (names, bodies, 0..) |name, body, index| {
            try out.appendSlice(gpa, &central_header_sig);
            try appendInt(&out, gpa, u16, 20);
            try appendInt(&out, gpa, u16, 20);
            try appendInt(&out, gpa, u16, 0);
            try appendInt(&out, gpa, u16, 0);
            try appendInt(&out, gpa, u16, 0);
            try appendInt(&out, gpa, u16, 0);
            try appendInt(&out, gpa, u32, 0);
            try appendInt(&out, gpa, u32, @intCast(body.len));
            try appendInt(&out, gpa, u32, @intCast(body.len));
            try appendInt(&out, gpa, u16, @intCast(name.len));
            try appendInt(&out, gpa, u16, 0);
            try appendInt(&out, gpa, u16, 0);
            try appendInt(&out, gpa, u16, 0);
            try appendInt(&out, gpa, u16, 0);
            try appendInt(&out, gpa, u32, 0);
            try appendInt(&out, gpa, u32, offsets[index]);
            try out.appendSlice(gpa, name);
        }
        const central_size: u32 = @intCast(out.items.len - central_start);

        try out.appendSlice(gpa, &end_record_sig);
        try appendInt(&out, gpa, u16, 0);
        try appendInt(&out, gpa, u16, 0);
        try appendInt(&out, gpa, u16, @intCast(names.len));
        try appendInt(&out, gpa, u16, @intCast(names.len));
        try appendInt(&out, gpa, u32, central_size);
        try appendInt(&out, gpa, u32, central_start);
        try appendInt(&out, gpa, u16, 0);

        return out.toOwnedSlice(gpa);
    }
};

test "a stored entry comes back byte for byte, and a missing one comes back null" {
    const gpa = std.testing.allocator;
    const archive = try testing_archive.build(
        gpa,
        &.{ "pack.txt", "terrain.png" },
        &.{ "A pack\nby someone", "not really a png" },
    );
    defer gpa.free(archive);

    const text = (try readArchiveEntry(gpa, archive, "pack.txt", max_resource_bytes)).?;
    defer gpa.free(text);
    try std.testing.expectEqualStrings("A pack\nby someone", text);

    const png = (try readArchiveEntry(gpa, archive, "terrain.png", max_resource_bytes)).?;
    defer gpa.free(png);
    try std.testing.expectEqualStrings("not really a png", png);

    try std.testing.expectEqual(@as(?[]u8, null), try readArchiveEntry(gpa, archive, "gui/gui.png", max_resource_bytes));
}

test "a deflated entry is inflated on the way out" {
    const gpa = std.testing.allocator;

    const plain = "the same line over and over, the same line over and over, again";
    const packed_bytes = try world.deflate.compressAlloc(gpa, .raw, plain);
    defer gpa.free(packed_bytes);

    var archive = try testing_archive.build(gpa, &.{"pack.txt"}, &.{packed_bytes});
    defer gpa.free(archive);

    std.mem.writeInt(u16, archive[8..10], 8, .little);
    const central = std.mem.indexOf(u8, archive, &central_header_sig).?;
    std.mem.writeInt(u16, archive[central + 10 ..][0..2], 8, .little);
    std.mem.writeInt(u32, archive[central + 24 ..][0..4], @intCast(plain.len), .little);

    const text = (try readArchiveEntry(gpa, archive, "pack.txt", max_resource_bytes)).?;
    defer gpa.free(text);
    try std.testing.expectEqualStrings(plain, text);
}

test "something that is not an archive is refused rather than read" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.NotAnArchive, readArchiveEntry(gpa, "hello", "pack.txt", max_resource_bytes));
    try std.testing.expectError(error.NotAnArchive, readArchiveEntry(gpa, "", "pack.txt", max_resource_bytes));
}

test "an entry larger than the limit is refused before it is unpacked" {
    const gpa = std.testing.allocator;
    const archive = try testing_archive.build(gpa, &.{"pack.txt"}, &.{"0123456789"});
    defer gpa.free(archive);
    try std.testing.expectError(error.StreamTooLong, readArchiveEntry(gpa, archive, "pack.txt", 4));
}

test "pack.txt gives up to two lines, each cut to the width the slot has" {
    const gpa = std.testing.allocator;

    const two = try descriptionLines(gpa, "first\nsecond\nthird");
    defer for (two) |line| gpa.free(line);
    try std.testing.expectEqualStrings("first", two[0]);
    try std.testing.expectEqualStrings("second", two[1]);

    const one = try descriptionLines(gpa, "only one");
    defer for (one) |line| gpa.free(line);
    try std.testing.expectEqualStrings("only one", one[0]);
    try std.testing.expectEqualStrings("", one[1]);

    const long = "a" ** 40;
    const cut = try descriptionLines(gpa, long);
    defer for (cut) |line| gpa.free(line);
    try std.testing.expectEqual(@as(usize, max_line_len), cut[0].len);
}

test "a carriage return from a windows-written pack.txt is not shown" {
    const gpa = std.testing.allocator;
    const lines = try descriptionLines(gpa, "first\r\nsecond\r\n");
    defer for (lines) |line| gpa.free(line);
    try std.testing.expectEqualStrings("first", lines[0]);
    try std.testing.expectEqualStrings("second", lines[1]);
}

test "a pack is found by name, and Default is always the one at the front" {
    const gpa = std.testing.allocator;
    var packs = [_]Pack{
        .{ .name = try gpa.dupe(u8, default_name), .lines = .{ try gpa.dupe(u8, ""), try gpa.dupe(u8, "") }, .thumbnail = null },
        .{ .name = try gpa.dupe(u8, "sphax.zip"), .lines = .{ try gpa.dupe(u8, ""), try gpa.dupe(u8, "") }, .thumbnail = null },
    };
    defer for (&packs) |*pack| pack.deinit(gpa);

    try std.testing.expectEqual(@as(?usize, 0), indexOf(&packs, default_name));
    try std.testing.expectEqual(@as(?usize, 1), indexOf(&packs, "sphax.zip"));
    try std.testing.expectEqual(@as(?usize, null), indexOf(&packs, "missing.zip"));
}

test "the built-in pack is the one that is not a file on disk" {
    const gpa = std.testing.allocator;
    var packs = [_]Pack{
        .{ .name = try gpa.dupe(u8, default_name), .lines = .{ try gpa.dupe(u8, ""), try gpa.dupe(u8, "") }, .thumbnail = null },
        .{ .name = try gpa.dupe(u8, "sphax.zip"), .lines = .{ try gpa.dupe(u8, ""), try gpa.dupe(u8, "") }, .thumbnail = null },
    };
    defer for (&packs) |*pack| pack.deinit(gpa);

    try std.testing.expect(isDefault(packs[0]));
    try std.testing.expect(!isDefault(packs[1]));
}

test "scanning a folder lists Default first, then the archives in name order" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = try std.Io.Dir.cwd().createDirPathOpen(io, "zig-out/test-texturepacks", .{ .open_options = .{ .iterate = true } });
    defer tmp.close(io);
    defer std.Io.Dir.cwd().deleteTree(io, "zig-out/test-texturepacks") catch {};

    for ([_][]const u8{ "zebra.zip", "alpha.zip" }) |name| {
        const archive = try testing_archive.build(gpa, &.{"pack.txt"}, &.{"a line\nand another"});
        defer gpa.free(archive);
        const file = try tmp.createFile(io, name, .{});
        defer file.close(io);
        try file.writePositionalAll(io, archive, 0);
    }

    const ignored = try tmp.createFile(io, "notes.txt", .{});
    ignored.close(io);

    const packs = try scan(gpa, io, tmp);
    defer deinitAll(gpa, packs);

    try std.testing.expectEqual(@as(usize, 3), packs.len);
    try std.testing.expectEqualStrings(default_name, packs[0].name);
    try std.testing.expectEqualStrings(default_line, packs[0].lines[0]);
    try std.testing.expectEqualStrings("alpha.zip", packs[1].name);
    try std.testing.expectEqualStrings("zebra.zip", packs[2].name);
    try std.testing.expectEqualStrings("a line", packs[1].lines[0]);
    try std.testing.expectEqualStrings("and another", packs[1].lines[1]);
    try std.testing.expect(packs[1].thumbnail == null);
}

test "a zip that is not really a zip is still listed, with an empty description" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = try std.Io.Dir.cwd().createDirPathOpen(io, "zig-out/test-badpacks", .{ .open_options = .{ .iterate = true } });
    defer tmp.close(io);
    defer std.Io.Dir.cwd().deleteTree(io, "zig-out/test-badpacks") catch {};

    const file = try tmp.createFile(io, "broken.zip", .{});
    try file.writePositionalAll(io, "this is not an archive", 0);
    file.close(io);

    const packs = try scan(gpa, io, tmp);
    defer deinitAll(gpa, packs);

    try std.testing.expectEqual(@as(usize, 2), packs.len);
    try std.testing.expectEqualStrings(default_name, packs[0].name);
    try std.testing.expectEqualStrings("broken.zip", packs[1].name);
    try std.testing.expectEqualStrings("", packs[1].lines[0]);
    try std.testing.expectEqualStrings("", packs[1].lines[1]);
    try std.testing.expect(packs[1].thumbnail == null);
}
