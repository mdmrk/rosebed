const std = @import("std");

const version = "3.4.0";
const archive_url = "https://github.com/libsdl-org/SDL/releases/download/release-" ++ version ++ "/SDL3-" ++ version ++ ".dmg";
const archive_sha256 = "adf14bde6258b9f4a8775bec093f26797f1679aeb60ecb832cb34f9df5c85812";
const tmp_dir_name = ".zig-cache/tmp";
const archive_name = "fetched-sdl-ios.dmg";
const mount_name = ".zig-cache/tmp/sdl-ios-mount";
const framework_prefix = "SDL3.xcframework/ios-arm64/SDL3.framework";
const bundle_files = [_][]const u8{ "SDL3", "Info.plist", "default.metallib", "LICENSE.txt" };
const link_name = "lib/libsdl3.dylib";

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

fn run(io: std.Io, argv: []const []const u8) !void {
    var child = try std.process.spawn(io, .{ .argv = argv, .stdout = .ignore });
    switch (try child.wait(io)) {
        .exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

pub fn main(init: std.process.Init) !void {
    if (@import("builtin").os.tag != .macos) return error.MacOsRequired;

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
    try tmp_dir.writeFile(io, .{ .sub_path = archive_name, .data = archive_bytes });

    try cwd.deleteTree(io, mount_name);
    try cwd.createDirPath(io, mount_name);

    try run(io, &.{
        "hdiutil",     "attach",      tmp_dir_name ++ "/" ++ archive_name,
        "-readonly",   "-nobrowse",   "-noverify",
        "-noautoopen", "-mountpoint", mount_name,
    });

    try cwd.deleteTree(io, dest_root);
    {
        defer run(io, &.{ "hdiutil", "detach", mount_name, "-quiet" }) catch {};

        var framework = try cwd.openDir(io, mount_name ++ "/" ++ framework_prefix, .{});
        defer framework.close(io);

        var dest = try cwd.createDirPathOpen(io, dest_root, .{});
        defer dest.close(io);

        for (bundle_files) |name| {
            const to = try std.fmt.allocPrint(gpa, "SDL3.framework/{s}", .{name});
            defer gpa.free(to);
            try framework.copyFile(name, dest, to, io, .{ .make_path = true });
        }
        try framework.copyFile("SDL3", dest, link_name, io, .{ .make_path = true });

        var headers = try framework.openDir(io, "Headers", .{ .iterate = true });
        defer headers.close(io);

        var it = headers.iterate();
        var count: usize = 0;
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            const to = try std.fmt.allocPrint(gpa, "include/SDL3/{s}", .{entry.name});
            defer gpa.free(to);
            try headers.copyFile(entry.name, dest, to, io, .{ .make_path = true });
            count += 1;
        }
        std.log.info("sdl {s} ios-arm64, {d} headers", .{ version, count });
    }

    try cwd.deleteTree(io, mount_name);
    try tmp_dir.deleteFile(io, archive_name);
}
