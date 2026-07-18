const std = @import("std");

const deflate = @import("deflate.zig");

const RegionFile = @This();

pub const sector_bytes = 4096;
pub const region_chunks = 32;
const entry_count = region_chunks * region_chunks;
const header_bytes = sector_bytes * 2;
const max_chunk_bytes = 1024 * 1024;

const compression_gzip: u8 = 1;
const compression_zlib: u8 = 2;

file: std.Io.File,
offsets: [entry_count]u32,
timestamps: [entry_count]u32,
sector_free: std.ArrayList(bool),

pub fn regionCoord(chunk_coord: i32) i32 {
    return chunk_coord >> 5;
}

pub fn localCoord(chunk_coord: i32) u32 {
    return @intCast(chunk_coord & 31);
}

pub fn fileName(buffer: []u8, region_x: i32, region_z: i32) ![]u8 {
    return std.fmt.bufPrint(buffer, "r.{d}.{d}.mcr", .{ region_x, region_z });
}

pub fn open(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, region_x: i32, region_z: i32) !RegionFile {
    var name_buffer: [64]u8 = undefined;
    const name = try fileName(&name_buffer, region_x, region_z);

    const file = try dir.createFile(io, name, .{ .read = true, .truncate = false });
    errdefer file.close(io);

    var self: RegionFile = .{
        .file = file,
        .offsets = @splat(0),
        .timestamps = @splat(0),
        .sector_free = .empty,
    };
    errdefer self.sector_free.deinit(gpa);

    var length = try file.length(io);
    if (length % sector_bytes != 0) {
        length += sector_bytes - length % sector_bytes;
    }
    if (length < header_bytes) length = header_bytes;
    try file.setLength(io, length);

    const sectors: usize = @intCast(length / sector_bytes);
    try self.sector_free.appendNTimes(gpa, true, sectors);
    self.sector_free.items[0] = false;
    self.sector_free.items[1] = false;

    var header: [entry_count * 2]u32 = undefined;
    const header_slice = std.mem.sliceAsBytes(&header);
    if (try file.readPositionalAll(io, header_slice, 0) != header_slice.len) return error.EndOfStream;
    for (&header) |*value| value.* = std.mem.bigToNative(u32, value.*);

    for (header[0..entry_count], 0..) |entry, i| {
        self.offsets[i] = entry;
        if (entry == 0) continue;

        const start = entry >> 8;
        const count = entry & 255;
        if (start + count > sectors) continue;
        for (0..count) |n| self.sector_free.items[start + n] = false;
    }
    @memcpy(&self.timestamps, header[entry_count..]);

    return self;
}

pub fn close(self: *RegionFile, gpa: std.mem.Allocator, io: std.Io) void {
    self.sector_free.deinit(gpa);
    self.file.close(io);
}

fn entryIndex(local_x: u32, local_z: u32) usize {
    return local_x + local_z * region_chunks;
}

pub fn hasChunk(self: *const RegionFile, local_x: u32, local_z: u32) bool {
    if (local_x >= region_chunks or local_z >= region_chunks) return false;
    return self.offsets[entryIndex(local_x, local_z)] != 0;
}

pub fn readChunk(self: *RegionFile, gpa: std.mem.Allocator, io: std.Io, local_x: u32, local_z: u32) !?[]u8 {
    if (local_x >= region_chunks or local_z >= region_chunks) return null;

    const entry = self.offsets[entryIndex(local_x, local_z)];
    if (entry == 0) return null;

    const start = entry >> 8;
    const count = entry & 255;
    if (start + count > self.sector_free.items.len) return null;

    const position = @as(u64, start) * sector_bytes;
    var header: [5]u8 = undefined;
    if (try self.file.readPositionalAll(io, &header, position) != header.len) return null;

    const length = std.mem.readInt(u32, header[0..4], .big);
    if (length == 0 or length > sector_bytes * count) return null;

    const payload = try gpa.alloc(u8, length - 1);
    defer gpa.free(payload);
    if (try self.file.readPositionalAll(io, payload, position + header.len) != payload.len) return null;

    return switch (header[4]) {
        compression_gzip => try deflate.decompressAlloc(gpa, .gzip, payload, max_chunk_bytes),
        compression_zlib => try deflate.decompressAlloc(gpa, .zlib, payload, max_chunk_bytes),
        else => null,
    };
}

pub fn writeChunk(self: *RegionFile, gpa: std.mem.Allocator, io: std.Io, local_x: u32, local_z: u32, data: []const u8) !void {
    if (local_x >= region_chunks or local_z >= region_chunks) return;

    const compressed = try deflate.compressAlloc(gpa, .zlib, data);
    defer gpa.free(compressed);

    const needed_sectors = (compressed.len + 5) / sector_bytes + 1;
    if (needed_sectors >= 256) return error.ChunkTooLarge;

    const index = entryIndex(local_x, local_z);
    const entry = self.offsets[index];
    const current_start = entry >> 8;
    const current_count = entry & 255;

    if (current_start != 0 and current_count == needed_sectors) {
        try self.writeSectors(io, current_start, compressed);
        try self.stampTimestamp(io, index);
        return;
    }

    for (0..current_count) |n| self.sector_free.items[current_start + n] = true;

    const start = self.findFreeRun(needed_sectors) orelse grow: {
        const first_new = self.sector_free.items.len;
        try self.sector_free.appendNTimes(gpa, true, needed_sectors);
        try self.file.setLength(io, @as(u64, self.sector_free.items.len) * sector_bytes);
        break :grow first_new;
    };

    for (0..needed_sectors) |n| self.sector_free.items[start + n] = false;
    try self.writeSectors(io, @intCast(start), compressed);
    try self.setOffset(io, index, @intCast((start << 8) | needed_sectors));
    try self.stampTimestamp(io, index);
}

fn findFreeRun(self: *const RegionFile, needed: usize) ?usize {
    var run_start: usize = 0;
    var run_length: usize = 0;
    for (self.sector_free.items, 0..) |free, i| {
        if (!free) {
            run_length = 0;
            continue;
        }
        if (run_length == 0) run_start = i;
        run_length += 1;
        if (run_length >= needed) return run_start;
    }
    return null;
}

fn writeSectors(self: *RegionFile, io: std.Io, start: u32, compressed: []const u8) !void {
    var header: [5]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], @intCast(compressed.len + 1), .big);
    header[4] = compression_zlib;

    const position = @as(u64, start) * sector_bytes;
    try self.file.writePositionalAll(io, &header, position);
    try self.file.writePositionalAll(io, compressed, position + header.len);
}

fn writeEntry(self: *RegionFile, io: std.Io, position: u64, value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .big);
    try self.file.writePositionalAll(io, &bytes, position);
}

fn setOffset(self: *RegionFile, io: std.Io, index: usize, entry: u32) !void {
    self.offsets[index] = entry;
    try self.writeEntry(io, index * 4, entry);
}

pub fn unixSeconds(io: std.Io) i64 {
    const nanoseconds = std.Io.Timestamp.now(io, .real).nanoseconds;
    return @intCast(@divTrunc(nanoseconds, std.time.ns_per_s));
}

fn stampTimestamp(self: *RegionFile, io: std.Io, index: usize) !void {
    const now: u32 = @intCast(unixSeconds(io));
    self.timestamps[index] = now;
    try self.writeEntry(io, sector_bytes + index * 4, now);
}

test "a chunk written to a region file reads back byte for byte" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const payload = "chunk payload" ** 100;

    var region = try open(gpa, io, tmp.dir, 0, 0);
    defer region.close(gpa, io);

    try std.testing.expect(!region.hasChunk(3, 7));
    try region.writeChunk(gpa, io, 3, 7, payload);
    try std.testing.expect(region.hasChunk(3, 7));

    const read_back = (try region.readChunk(gpa, io, 3, 7)).?;
    defer gpa.free(read_back);
    try std.testing.expectEqualStrings(payload, read_back);
}

test "an absent chunk reads as null" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var region = try open(gpa, io, tmp.dir, 0, 0);
    defer region.close(gpa, io);

    try std.testing.expectEqual(@as(?[]u8, null), try region.readChunk(gpa, io, 0, 0));
    try std.testing.expectEqual(@as(?[]u8, null), try region.readChunk(gpa, io, 31, 31));
}

test "many chunks coexist in one region file and survive reopening" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var buffer: [64]u8 = undefined;
    {
        var region = try open(gpa, io, tmp.dir, -1, 2);
        defer region.close(gpa, io);

        for (0..16) |i| {
            const payload = try std.fmt.bufPrint(&buffer, "chunk number {d}", .{i});
            try region.writeChunk(gpa, io, @intCast(i), @intCast(i * 2), payload);
        }
    }

    var region = try open(gpa, io, tmp.dir, -1, 2);
    defer region.close(gpa, io);

    for (0..16) |i| {
        const expected = try std.fmt.bufPrint(&buffer, "chunk number {d}", .{i});
        const read_back = (try region.readChunk(gpa, io, @intCast(i), @intCast(i * 2))).?;
        defer gpa.free(read_back);
        try std.testing.expectEqualStrings(expected, read_back);
    }
}

test "rewriting a chunk that outgrows its sectors relocates it without clobbering its neighbour" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var region = try open(gpa, io, tmp.dir, 0, 0);
    defer region.close(gpa, io);

    try region.writeChunk(gpa, io, 1, 1, "small");
    try region.writeChunk(gpa, io, 2, 2, "neighbour that must not be clobbered");

    const grown = try gpa.alloc(u8, 40000);
    defer gpa.free(grown);
    var rand = std.Random.DefaultPrng.init(9);
    rand.random().bytes(grown);
    try region.writeChunk(gpa, io, 1, 1, grown);

    const read_grown = (try region.readChunk(gpa, io, 1, 1)).?;
    defer gpa.free(read_grown);
    try std.testing.expectEqualSlices(u8, grown, read_grown);

    const read_neighbour = (try region.readChunk(gpa, io, 2, 2)).?;
    defer gpa.free(read_neighbour);
    try std.testing.expectEqualStrings("neighbour that must not be clobbered", read_neighbour);
}

test "region coordinates split chunk coordinates into a file and a local part" {
    try std.testing.expectEqual(@as(i32, 0), regionCoord(0));
    try std.testing.expectEqual(@as(i32, 0), regionCoord(31));
    try std.testing.expectEqual(@as(i32, 1), regionCoord(32));
    try std.testing.expectEqual(@as(i32, -1), regionCoord(-1));
    try std.testing.expectEqual(@as(i32, -1), regionCoord(-32));
    try std.testing.expectEqual(@as(i32, -2), regionCoord(-33));

    try std.testing.expectEqual(@as(u32, 31), localCoord(-1));
    try std.testing.expectEqual(@as(u32, 0), localCoord(-32));
    try std.testing.expectEqual(@as(u32, 5), localCoord(37));

    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("r.-1.2.mcr", try fileName(&buffer, -1, 2));
}
