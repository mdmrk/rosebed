const std = @import("std");

const gl = @import("gl");
const sdl3 = @import("sdl3");

pub const dir_name = "screenshots";
pub const saved_prefix = "Saved screenshot as ";
pub const failed_prefix = "Failed to save: ";

pub const max_name_len = 40;

pub fn fileName(buf: *[max_name_len]u8, at: sdl3.time.DateTime, index: u32) []const u8 {
    var suffix_buf: [12]u8 = undefined;
    const suffix = if (index == 1) "" else std.fmt.bufPrint(&suffix_buf, "_{d}", .{index}) catch unreachable;
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}_{d:0>2}.{d:0>2}.{d:0>2}{s}.png", .{
        at.year,
        @as(u8, @intCast(@intFromEnum(at.month))),
        at.day,
        at.hour,
        at.minute,
        at.second,
        suffix,
    }) catch unreachable;
}

pub fn save(
    gpa: std.mem.Allocator,
    io: std.Io,
    base: std.Io.Dir,
    width: usize,
    height: usize,
    name_buf: *[max_name_len]u8,
) ![]const u8 {
    var dir = try base.createDirPathOpen(io, dir_name, .{});
    defer dir.close(io);

    const pixels = try gpa.alloc(u8, width * height * 3);
    defer gpa.free(pixels);

    gl.PixelStorei(gl.PACK_ALIGNMENT, 1);
    gl.ReadPixels(0, 0, @intCast(width), @intCast(height), gl.RGB, gl.UNSIGNED_BYTE, pixels.ptr);

    const surface = try sdl3.surface.Surface.initFrom(width, height, .array_rgb_24, pixels);
    defer surface.deinit();
    try surface.flip(.{ .vertical = true });

    const stream = try sdl3.io_stream.Stream.initFromDynamicMem();
    defer stream.deinit() catch {};
    try surface.savePngIo(stream, false);

    const encoded_len = try stream.getSize();
    const memory = (try stream.getProperties()).dynamic_memory orelse return error.SdlError;
    const encoded = @as([*]const u8, @ptrCast(memory.ptr orelse return error.SdlError))[0..encoded_len];

    const at = try sdl3.time.DateTime.fromTime(try sdl3.time.Time.getCurrent(), true);
    var index: u32 = 1;
    while (true) : (index += 1) {
        const name = fileName(name_buf, at, index);
        if (dir.statFile(io, name, .{})) |_| continue else |_| {}

        const file = try dir.createFile(io, name, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, encoded);
        return name;
    }
}

test "the first screenshot of a second is unnumbered and later ones count up" {
    const at: sdl3.time.DateTime = .{
        .year = 2010,
        .month = .june,
        .day = 30,
        .hour = 9,
        .minute = 5,
        .second = 3,
        .nanosecond = 0,
        .day_of_week = .wednesday,
        .utc_offset = 0,
    };

    var buf: [max_name_len]u8 = undefined;
    try std.testing.expectEqualStrings("2010-06-30_09.05.03.png", fileName(&buf, at, 1));
    try std.testing.expectEqualStrings("2010-06-30_09.05.03_2.png", fileName(&buf, at, 2));
}
