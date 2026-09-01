const std = @import("std");

const version = "3.4.0";
const archive_url = "https://github.com/libsdl-org/SDL/releases/download/release-" ++ version ++ "/SDL3-devel-" ++ version ++ "-android.zip";
const archive_sha256 = "ed8e9278b4a944fc0ad93ece64cfc6d46693eaa4d47a5f87d891a3c24c783c21";
const aar_name = "SDL3-" ++ version ++ ".aar";
const tmp_dir_name = ".zig-cache/tmp";
const staging_name = ".zig-cache/tmp/sdl-android";
const header_prefix = "prefab/modules/SDL3-Headers/include";
const lib_prefix = "prefab/modules/SDL3-shared/libs/android.";
const lib_name = "libSDL3.so";
const link_name = "libsdl3.so";
const abis = [_][]const u8{ "arm64-v8a", "armeabi-v7a", "x86_64", "x86" };

fn fetchAlloc(gpa: std.mem.Allocator, client: *std.http.Client, url: []const u8) ![]u8 {
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body.writer,
    });
    if (result.status != .ok) return error.HttpRequestFailed;
    var list = body.toArrayList();
    return list.toOwnedSlice(gpa);
}

fn sha256Hex(bytes: []const u8, out: *[64]u8) void {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(bytes);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    _ = std.fmt.bufPrint(out, "{x}", .{digest}) catch unreachable;
}

fn wanted(name: []const u8) bool {
    if (std.mem.eql(u8, name, "classes.jar")) return true;
    if (std.mem.startsWith(u8, name, header_prefix)) return true;
    return std.mem.startsWith(u8, name, lib_prefix) and std.mem.endsWith(u8, name, lib_name);
}

fn extractInto(io: std.Io, file: std.Io.File, dest: std.Io.Dir, filter: ?*const fn ([]const u8) bool) !void {
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    var iter = try std.zip.Iterator.init(&reader);
    var filename_buf: [std.fs.max_path_bytes]u8 = undefined;
    while (try iter.next()) |entry| {
        const name = filename_buf[0..entry.filename_len];
        try reader.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
        try reader.interface.readSliceAll(name);
        if (filter) |accept| if (!accept(name)) continue;
        try entry.extract(&reader, .{}, &filename_buf, dest);
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.page_allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next();
    const dest_root = args.next() orelse return error.MissingDestination;

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const archive_bytes = try fetchAlloc(gpa, &client, archive_url);
    defer gpa.free(archive_bytes);

    var actual_hex: [64]u8 = undefined;
    sha256Hex(archive_bytes, &actual_hex);
    if (!std.mem.eql(u8, &actual_hex, archive_sha256)) return error.ChecksumMismatch;

    const cwd = std.Io.Dir.cwd();
    var tmp_dir = try cwd.createDirPathOpen(io, tmp_dir_name, .{});
    defer tmp_dir.close(io);

    const archive_name = "fetched-sdl-android.zip";
    try tmp_dir.writeFile(io, .{ .sub_path = archive_name, .data = archive_bytes });

    try cwd.deleteTree(io, staging_name);
    var staging = try cwd.createDirPathOpen(io, staging_name, .{});
    defer staging.close(io);

    {
        var archive = try tmp_dir.openFile(io, archive_name, .{});
        defer archive.close(io);
        try extractInto(io, archive, staging, null);
    }
    try tmp_dir.deleteFile(io, archive_name);

    {
        var aar = try staging.openFile(io, aar_name, .{});
        defer aar.close(io);
        try extractInto(io, aar, staging, wanted);
    }

    try cwd.deleteTree(io, dest_root);
    try cwd.createDirPath(io, dest_root);
    var dest = try cwd.openDir(io, dest_root, .{});
    defer dest.close(io);

    try staging.rename(header_prefix, dest, "include", io);
    try staging.rename("classes.jar", dest, "classes.jar", io);

    for (abis) |abi| {
        const from = try std.fmt.allocPrint(gpa, "{s}{s}/{s}", .{ lib_prefix, abi, lib_name });
        defer gpa.free(from);
        const into = try std.fmt.allocPrint(gpa, "lib/{s}", .{abi});
        defer gpa.free(into);
        const to = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ into, lib_name });
        defer gpa.free(to);
        const link = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ into, link_name });
        defer gpa.free(link);

        try dest.createDirPath(io, into);
        try staging.rename(from, dest, to, io);
        try dest.copyFile(to, dest, link, io, .{});
        std.log.info("sdl {s}", .{abi});
    }

    try cwd.deleteTree(io, staging_name);
}
