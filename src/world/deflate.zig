const std = @import("std");

pub const Container = std.compress.flate.Container;

pub fn compressAlloc(gpa: std.mem.Allocator, container: Container, data: []const u8) ![]u8 {
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);

    var allocating: std.Io.Writer.Allocating = try .initCapacity(gpa, @max(data.len / 2, 64));
    errdefer allocating.deinit();

    var compress = try std.compress.flate.Compress.init(&allocating.writer, window, container, .default);
    try compress.writer.writeAll(data);
    try compress.finish();

    return allocating.toOwnedSlice();
}

pub fn decompressAlloc(gpa: std.mem.Allocator, container: Container, data: []const u8, limit: usize) ![]u8 {
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);

    var input = std.Io.Reader.fixed(data);
    var decompress = std.compress.flate.Decompress.init(&input, container, window);

    var allocating: std.Io.Writer.Allocating = .init(gpa);
    errdefer allocating.deinit();

    _ = try decompress.reader.streamRemaining(&allocating.writer);
    if (allocating.written().len > limit) return error.StreamTooLong;

    return allocating.toOwnedSlice();
}

test "zlib and gzip round-trip" {
    const gpa = std.testing.allocator;
    const payload = "Rosebed" ** 400;

    for ([_]Container{ .zlib, .gzip, .raw }) |container| {
        const packed_bytes = try compressAlloc(gpa, container, payload);
        defer gpa.free(packed_bytes);

        const unpacked = try decompressAlloc(gpa, container, packed_bytes, payload.len * 2);
        defer gpa.free(unpacked);

        try std.testing.expectEqualStrings(payload, unpacked);
    }
}

test "a zlib stream starts with the expected header bytes" {
    const gpa = std.testing.allocator;
    const packed_bytes = try compressAlloc(gpa, .zlib, "hello");
    defer gpa.free(packed_bytes);

    try std.testing.expect(packed_bytes.len > 2);
    try std.testing.expectEqual(@as(u8, 0x78), packed_bytes[0]);
}
