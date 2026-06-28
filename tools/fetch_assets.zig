const std = @import("std");

const version_id = "b1.7.3";
const manifest_url = "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";
const wanted_files = [_][]const u8{ "terrain.png", "mob/", "gui/", "font/" };

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

fn findVersionUrl(gpa: std.mem.Allocator, manifest_json: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, manifest_json, .{});
    defer parsed.deinit();

    const versions = parsed.value.object.get("versions").?.array;
    for (versions.items) |v| {
        const id = v.object.get("id").?.string;
        if (std.mem.eql(u8, id, version_id)) {
            return gpa.dupe(u8, v.object.get("url").?.string);
        }
    }
    return error.VersionNotFound;
}

const ClientDownload = struct { url: []u8, sha1: []u8 };

fn findClientDownload(gpa: std.mem.Allocator, version_json: []const u8) !ClientDownload {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, version_json, .{});
    defer parsed.deinit();

    const client_obj = parsed.value.object.get("downloads").?.object.get("client").?.object;
    return .{
        .url = try gpa.dupe(u8, client_obj.get("url").?.string),
        .sha1 = try gpa.dupe(u8, client_obj.get("sha1").?.string),
    };
}

fn sha1Hex(bytes: []const u8, out: *[40]u8) void {
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(bytes);
    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    hasher.final(&digest);
    _ = std.fmt.bufPrint(out, "{x}", .{digest}) catch unreachable;
}

fn matchesWanted(name: []const u8) bool {
    for (wanted_files) |prefix| {
        if (std.mem.eql(u8, prefix, name)) return true;
        if (std.mem.endsWith(u8, prefix, "/") and std.mem.startsWith(u8, name, prefix)) return true;
    }
    return false;
}

pub fn main() !void {
    const gpa = std.heap.page_allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    std.debug.print("Looking up Minecraft {s} in Mojang's official version manifest...\n", .{version_id});
    const manifest_body = try fetchAlloc(gpa, &client, manifest_url);
    defer gpa.free(manifest_body);

    const version_url = try findVersionUrl(gpa, manifest_body);
    defer gpa.free(version_url);

    const version_body = try fetchAlloc(gpa, &client, version_url);
    defer gpa.free(version_body);

    const download = try findClientDownload(gpa, version_body);
    defer gpa.free(download.url);
    defer gpa.free(download.sha1);

    std.debug.print("Downloading the official {s} client jar from Mojang...\n", .{version_id});
    const jar_bytes = try fetchAlloc(gpa, &client, download.url);
    defer gpa.free(jar_bytes);

    var actual_hex: [40]u8 = undefined;
    sha1Hex(jar_bytes, &actual_hex);
    if (!std.mem.eql(u8, &actual_hex, download.sha1)) {
        std.debug.print("error: checksum mismatch (expected {s}, got {s})\n", .{ download.sha1, actual_hex });
        return error.ChecksumMismatch;
    }
    std.debug.print("Checksum verified ({s}).\n", .{actual_hex});

    const cwd = std.Io.Dir.cwd();
    var tmp_dir = try cwd.createDirPathOpen(io, ".zig-cache/tmp", .{});
    defer tmp_dir.close(io);

    const jar_name = "fetched-client.jar";
    {
        var jar_file = try tmp_dir.createFile(io, jar_name, .{});
        defer jar_file.close(io);
        var write_buffer: [4096]u8 = undefined;
        var writer = jar_file.writer(io, &write_buffer);
        try writer.interface.writeAll(jar_bytes);
        try writer.interface.flush();
    }

    std.debug.print("Extracting assets to assets/...\n", .{});
    try cwd.deleteTree(io, "assets");
    try cwd.createDirPath(io, "assets");
    var assets_dir = try cwd.openDir(io, "assets", .{});
    defer assets_dir.close(io);

    var jar_file = try tmp_dir.openFile(io, jar_name, .{});
    defer jar_file.close(io);
    var read_buffer: [4096]u8 = undefined;
    var jar_reader = jar_file.reader(io, &read_buffer);

    var iter = try std.zip.Iterator.init(&jar_reader);
    var filename_buf: [std.fs.max_path_bytes]u8 = undefined;
    while (try iter.next()) |entry| {
        const name = filename_buf[0..entry.filename_len];
        try jar_reader.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
        try jar_reader.interface.readSliceAll(name);
        if (!matchesWanted(name)) continue;
        if (std.mem.endsWith(u8, name, "/")) continue;

        try entry.extract(&jar_reader, .{}, &filename_buf, assets_dir);
        std.debug.print("  {s}\n", .{name});
    }
    try tmp_dir.deleteFile(io, jar_name);

    std.debug.print("Done. Assets are in assets/\n", .{});
}
