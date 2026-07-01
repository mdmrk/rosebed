const std = @import("std");

const version_id = "b1.7.3";
const manifest_url = "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";
const dest_dir = "src/assets";

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

const Node = struct {
    children: std.StringHashMap(*Node),
    embed_path: ?[]const u8 = null,

    fn init(alloc: std.mem.Allocator) !*Node {
        const n = try alloc.create(Node);
        n.* = .{ .children = std.StringHashMap(*Node).init(alloc) };
        return n;
    }
};

fn insert(alloc: std.mem.Allocator, root: *Node, path: []const u8) !void {
    var node = root;
    var it = std.mem.splitScalar(u8, path, '/');
    var seg = it.next();
    while (seg) |name| {
        const next = it.next();
        if (next == null) {
            const leaf = try Node.init(alloc);
            leaf.embed_path = path;
            try node.children.put(name, leaf);
        } else {
            const gop = try node.children.getOrPut(name);
            if (!gop.found_existing) {
                gop.value_ptr.* = try Node.init(alloc);
            }
            node = gop.value_ptr.*;
        }
        seg = next;
    }
}

fn identFor(alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (std.mem.eql(u8, name, "null")) return "@\"null\"";

    const buf = try alloc.alloc(u8, name.len);
    for (name, 0..) |c, i| {
        buf[i] = if (std.ascii.isAlphanumeric(c) or c == '_') c else '_';
    }
    return buf;
}

fn emit(writer: anytype, alloc: std.mem.Allocator, node: *Node, depth: usize) !void {
    var it = node.children.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const child = entry.value_ptr.*;
        try writer.splatByteAll(' ', depth * 4);
        const ident = try identFor(alloc, name);
        if (child.embed_path) |p| {
            try writer.print("pub const {s} = @embedFile(\"{s}\");\n", .{ ident, p });
        } else {
            try writer.print("pub const {s} = struct {{\n", .{ident});
            try emit(writer, alloc, child, depth + 1);
            try writer.splatByteAll(' ', depth * 4);
            try writer.writeAll("};\n");
        }
    }
}

fn writeManifest(io: std.Io, assets_dir: std.Io.Dir, gpa: std.mem.Allocator, names: *std.ArrayList([]const u8)) !void {
    const root = try Node.init(gpa);
    for (names.items) |p| try insert(gpa, root, p);

    var out_buf: std.Io.Writer.Allocating = .init(gpa);
    defer out_buf.deinit();

    try emit(&out_buf.writer, gpa, root, 0);

    var out_file = try assets_dir.createFile(io, "root.zig", .{ .truncate = true });
    defer out_file.close(io);
    try out_file.writeStreamingAll(io, out_buf.written());
}

pub fn main() !void {
    const gpa = std.heap.page_allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const manifest_body = try fetchAlloc(gpa, &client, manifest_url);
    defer gpa.free(manifest_body);

    const version_url = try findVersionUrl(gpa, manifest_body);
    defer gpa.free(version_url);

    const version_body = try fetchAlloc(gpa, &client, version_url);
    defer gpa.free(version_body);

    const download = try findClientDownload(gpa, version_body);
    defer gpa.free(download.url);
    defer gpa.free(download.sha1);

    const jar_bytes = try fetchAlloc(gpa, &client, download.url);
    defer gpa.free(jar_bytes);

    var actual_hex: [40]u8 = undefined;
    sha1Hex(jar_bytes, &actual_hex);
    if (!std.mem.eql(u8, &actual_hex, download.sha1)) {
        return error.ChecksumMismatch;
    }

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

    try cwd.deleteTree(io, dest_dir);
    try cwd.createDirPath(io, dest_dir);
    var assets_dir = try cwd.openDir(io, dest_dir, .{});
    defer assets_dir.close(io);

    var jar_file = try tmp_dir.openFile(io, jar_name, .{});
    defer jar_file.close(io);
    var read_buffer: [4096]u8 = undefined;
    var jar_reader = jar_file.reader(io, &read_buffer);

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    var iter = try std.zip.Iterator.init(&jar_reader);
    var filename_buf: [std.fs.max_path_bytes]u8 = undefined;
    while (try iter.next()) |entry| {
        const name = filename_buf[0..entry.filename_len];
        try jar_reader.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
        try jar_reader.interface.readSliceAll(name);
        if (std.mem.endsWith(u8, name, ".class")) continue;

        try names.append(gpa, try gpa.dupe(u8, name));
        try entry.extract(&jar_reader, .{}, &filename_buf, assets_dir);
    }
    try tmp_dir.deleteFile(io, jar_name);

    try writeManifest(io, assets_dir, gpa, &names);
}
