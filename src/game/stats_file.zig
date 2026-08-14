const std = @import("std");

const assets = @import("assets");

const stats = @import("stats.zig");

pub const dir_name = "stats";
pub const default_username = "Player";

const session_id = "local";
const max_file_bytes = 1 << 20;

const Entry = struct { id: u32, value: i32 };

pub fn guid(stat_id: u32) ?[]const u8 {
    var prefix_buffer: [16]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buffer, "{d},", .{stat_id}) catch return null;
    var lines = std.mem.tokenizeAny(u8, assets.achievement.map_txt.bytes, "\r\n");
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, prefix)) return line[prefix.len..];
    }
    return null;
}

fn md5Hex(buffer: *[32]u8, input: []const u8) []const u8 {
    var digest: [std.crypto.hash.Md5.digest_length]u8 = undefined;
    std.crypto.hash.Md5.hash(input, &digest, .{});

    const alphabet = "0123456789abcdef";
    for (digest, 0..) |byte, index| {
        buffer[index * 2] = alphabet[byte >> 4];
        buffer[index * 2 + 1] = alphabet[byte & 0xF];
    }

    var start: usize = 0;
    while (start + 1 < buffer.len and buffer[start] == '0') start += 1;
    return buffer[start..];
}

pub fn fileName(buffer: []u8, username: []const u8, extension: []const u8) ![]const u8 {
    var lowered: [64]u8 = undefined;
    const length = @min(username.len, lowered.len);
    for (username[0..length], 0..) |c, index| lowered[index] = std.ascii.toLower(c);
    return std.fmt.bufPrint(buffer, "stats_{s}{s}", .{ lowered[0..length], extension });
}

fn sortedEntries(gpa: std.mem.Allocator, source: *const stats.Stats) ![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(gpa);

    var it = source.counts.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* == 0) continue;
        try entries.append(gpa, .{ .id = stats.statId(entry.key_ptr.*), .value = entry.value_ptr.* });
    }

    std.mem.sort(Entry, entries.items, {}, struct {
        fn less(_: void, a: Entry, b: Entry) bool {
            return a.id < b.id;
        }
    }.less);
    return entries.toOwnedSlice(gpa);
}

pub fn encode(gpa: std.mem.Allocator, username: []const u8, source: *const stats.Stats) ![]u8 {
    const entries = try sortedEntries(gpa, source);
    defer gpa.free(entries);

    var checksum_input: std.Io.Writer.Allocating = .init(gpa);
    defer checksum_input.deinit();
    try checksum_input.writer.writeAll(session_id);

    var document: std.Io.Writer.Allocating = .init(gpa);
    errdefer document.deinit();
    const out = &document.writer;

    try out.writeAll("{\r\n");
    try out.writeAll("  \"user\":{\r\n");
    try out.print("    \"name\":\"{s}\",\r\n", .{username});
    try out.print("    \"sessionid\":\"{s}\"\r\n", .{session_id});
    try out.writeAll("  },\r\n");
    try out.writeAll("  \"stats-change\":[");

    for (entries, 0..) |entry, index| {
        if (index > 0) try out.writeAll("},");
        try out.print("\r\n    {{\"{d}\":{d}", .{ entry.id, entry.value });
        try checksum_input.writer.print("{s},{d},", .{ guid(entry.id) orelse "null", entry.value });
    }
    if (entries.len > 0) try out.writeAll("}");

    try out.writeAll("\r\n  ],\r\n");
    var hex: [32]u8 = undefined;
    try out.print("  \"checksum\":\"{s}\"\r\n", .{md5Hex(&hex, checksum_input.written())});
    try out.writeAll("}");

    return document.toOwnedSlice();
}

fn decodeInto(gpa: std.mem.Allocator, text: []const u8, loaded: *stats.Stats) !bool {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch return false;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return false,
    };
    const changes = switch (root.get("stats-change") orelse return false) {
        .array => |array| array,
        else => return false,
    };

    var checksum_input: std.Io.Writer.Allocating = .init(gpa);
    defer checksum_input.deinit();
    try checksum_input.writer.writeAll(session_id);

    for (changes.items) |change| {
        const fields = switch (change) {
            .object => |object| object,
            else => return false,
        };
        var it = fields.iterator();
        const field = it.next() orelse return false;
        const id = std.fmt.parseInt(u32, field.key_ptr.*, 10) catch return false;
        const value: i32 = switch (field.value_ptr.*) {
            .integer => |number| std.math.cast(i32, number) orelse return false,
            .number_string, .string => |number| std.fmt.parseInt(i32, number, 10) catch return false,
            else => return false,
        };

        try checksum_input.writer.print("{s},{d},", .{ guid(id) orelse "null", value });
        const key = stats.keyFromStatId(id) orelse continue;
        try loaded.add(gpa, key, value);
    }

    const stored = switch (root.get("checksum") orelse return false) {
        .string => |value| value,
        else => return false,
    };
    var hex: [32]u8 = undefined;
    return std.mem.eql(u8, stored, md5Hex(&hex, checksum_input.written()));
}

pub fn decode(gpa: std.mem.Allocator, text: []const u8) !?stats.Stats {
    var loaded: stats.Stats = .{};
    errdefer loaded.deinit(gpa);

    if (!try decodeInto(gpa, text, &loaded)) {
        loaded.deinit(gpa);
        return null;
    }
    return loaded;
}

pub fn load(gpa: std.mem.Allocator, io: std.Io, base: std.Io.Dir, username: []const u8) !stats.Stats {
    var dir = base.openDir(io, dir_name, .{}) catch return .{};
    defer dir.close(io);

    for ([_][]const u8{ ".dat", ".old", ".tmp" }) |extension| {
        var name_buffer: [96]u8 = undefined;
        const name = try fileName(&name_buffer, username, extension);

        const file = dir.openFile(io, name, .{}) catch continue;
        defer file.close(io);

        const size = file.length(io) catch continue;
        if (size == 0 or size > max_file_bytes) continue;

        const text = try gpa.alloc(u8, @intCast(size));
        defer gpa.free(text);
        if ((file.readPositionalAll(io, text, 0) catch continue) != text.len) continue;

        if (try decode(gpa, text)) |loaded| return loaded;
    }

    return .{};
}

pub fn save(gpa: std.mem.Allocator, io: std.Io, base: std.Io.Dir, username: []const u8, source: *const stats.Stats) !void {
    var dir = try base.createDirPathOpen(io, dir_name, .{});
    defer dir.close(io);

    const text = try encode(gpa, username, source);
    defer gpa.free(text);

    var current_buffer: [96]u8 = undefined;
    const current = try fileName(&current_buffer, username, ".dat");
    var previous_buffer: [96]u8 = undefined;
    const previous = try fileName(&previous_buffer, username, ".old");
    var pending_buffer: [96]u8 = undefined;
    const pending = try fileName(&pending_buffer, username, ".tmp");

    {
        const file = try dir.createFile(io, pending, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, text);
    }

    dir.deleteFile(io, previous) catch {};
    dir.rename(current, dir, previous, io) catch {};
    try dir.rename(pending, dir, current, io);
}

test "guids come from the achievement map and fall back to null" {
    try std.testing.expectEqualStrings("43ddd8b48469d9a8c011718aa846facb", guid(1000).?);
    try std.testing.expectEqualStrings("c9ee0d494e0524c86a577cf684f5816d", guid(2000).?);
    try std.testing.expectEqualStrings("8099ff561e194072c9086dea38757a89", guid(5242880).?);
    try std.testing.expectEqual(@as(?[]const u8, null), guid(4242));
}

test "the md5 hex drops leading zeros the way BigInteger.toString does" {
    var hex: [32]u8 = undefined;
    try std.testing.expectEqualStrings("d41d8cd98f00b204e9800998ecf8427e", md5Hex(&hex, ""));
    try std.testing.expectEqualStrings("900150983cd24fb0d6963f7d28e17f72", md5Hex(&hex, "abc"));
    try std.testing.expectEqualStrings("2e74f10e0327ad868d138f2b4fdd6f0", md5Hex(&hex, "27"));
}

test "the stats file name is the lower-cased user name" {
    var buffer: [96]u8 = undefined;
    try std.testing.expectEqualStrings("stats_player.dat", try fileName(&buffer, "Player", ".dat"));
    try std.testing.expectEqualStrings("stats_player.tmp", try fileName(&buffer, "PLAYER", ".tmp"));
}

test "an encoded file carries the user block, the sorted changes and a checksum" {
    const gpa = std.testing.allocator;
    var source: stats.Stats = .{};
    defer source.deinit(gpa);

    try source.add(gpa, .{ .general = .jump }, 7);
    try source.add(gpa, .{ .general = .start_game }, 2);

    const text = try encode(gpa, "Player", &source);
    defer gpa.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "\"name\":\"Player\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"sessionid\":\"local\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "{\"1000\":2}") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "{\"2010\":7}") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "{\"1000\":2}").? < std.mem.indexOf(u8, text, "{\"2010\":7}").?);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"checksum\":\"") != null);
}

test "an empty stat set still encodes a valid document" {
    const gpa = std.testing.allocator;
    var source: stats.Stats = .{};
    defer source.deinit(gpa);

    const text = try encode(gpa, "Player", &source);
    defer gpa.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "\"stats-change\":[\r\n  ],") != null);

    var restored = (try decode(gpa, text)).?;
    defer restored.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 0), restored.counts.count());
}

test "counters round-trip through the encoded file" {
    const gpa = std.testing.allocator;
    var source: stats.Stats = .{};
    defer source.deinit(gpa);

    try source.add(gpa, .{ .general = .distance_walked }, 12345);
    try source.mine(gpa, .stone);
    try source.craft(gpa, .{ .block = .planks }, 4);
    try source.use(gpa, .{ .item = .stick });

    const text = try encode(gpa, "Player", &source);
    defer gpa.free(text);

    var restored = (try decode(gpa, text)).?;
    defer restored.deinit(gpa);

    try std.testing.expectEqual(@as(i32, 12345), restored.get(.{ .general = .distance_walked }));
    try std.testing.expectEqual(@as(i32, 1), restored.get(.{ .mined = .{ .block = .stone } }));
    try std.testing.expectEqual(@as(i32, 4), restored.get(.{ .crafted = .{ .block = .planks } }));
    try std.testing.expectEqual(@as(i32, 1), restored.get(.{ .used = .{ .item = .stick } }));
}

test "unlocked achievements round-trip through the encoded file" {
    const gpa = std.testing.allocator;
    var source: stats.Stats = .{};
    defer source.deinit(gpa);

    try std.testing.expect(try source.award(gpa, .open_inventory));
    try std.testing.expect(try source.award(gpa, .mine_wood));

    const text = try encode(gpa, "Player", &source);
    defer gpa.free(text);

    var restored = (try decode(gpa, text)).?;
    defer restored.deinit(gpa);

    try std.testing.expect(restored.hasAchievement(.open_inventory));
    try std.testing.expect(restored.hasAchievement(.mine_wood));
    try std.testing.expect(!restored.hasAchievement(.build_work_bench));
    try std.testing.expect(restored.canUnlock(.build_work_bench));
}

test "a tampered file is rejected by its checksum" {
    const gpa = std.testing.allocator;
    var source: stats.Stats = .{};
    defer source.deinit(gpa);
    try source.add(gpa, .{ .general = .jump }, 7);

    const text = try encode(gpa, "Player", &source);
    defer gpa.free(text);

    const tampered = try std.mem.replaceOwned(u8, gpa, text, "\"2010\":7", "\"2010\":700");
    defer gpa.free(tampered);

    try std.testing.expectEqual(@as(?stats.Stats, null), try decode(gpa, tampered));
}
