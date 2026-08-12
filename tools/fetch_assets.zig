const std = @import("std");

const version_id = "b1.7.3";
const manifest_url = "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";
const resource_url = "https://resources.download.minecraft.net/";
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

fn findAssetIndexUrl(gpa: std.mem.Allocator, version_json: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, version_json, .{});
    defer parsed.deinit();

    const index_obj = parsed.value.object.get("assetIndex").?.object;
    return gpa.dupe(u8, index_obj.get("url").?.string);
}

const Resource = struct {
    path: []const u8,
    hash: []const u8,
    size: u64,
    pool: Pool,

    const Pool = enum { embedded, streamed };

    fn lessThan(_: void, a: Resource, b: Resource) bool {
        return std.mem.order(u8, a.path, b.path) == .lt;
    }
};

fn poolFor(path: []const u8) ?Resource.Pool {
    const slash = std.mem.indexOfScalar(u8, path, '/') orelse return null;
    const prefix = path[0..slash];
    if (std.mem.eql(u8, prefix, "sound") or std.mem.eql(u8, prefix, "newsound")) return .embedded;
    if (std.mem.eql(u8, prefix, "music") or std.mem.eql(u8, prefix, "newmusic")) return .streamed;
    if (std.mem.eql(u8, prefix, "streaming")) return .streamed;
    return null;
}

fn findResources(gpa: std.mem.Allocator, index_json: []const u8) ![]Resource {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, index_json, .{});
    defer parsed.deinit();

    var list: std.ArrayList(Resource) = .empty;
    errdefer list.deinit(gpa);

    var it = parsed.value.object.get("objects").?.object.iterator();
    while (it.next()) |entry| {
        const path = entry.key_ptr.*;
        if (!std.mem.endsWith(u8, path, ".ogg")) continue;
        const pool = poolFor(path) orelse continue;
        try list.append(gpa, .{
            .path = try gpa.dupe(u8, path),
            .hash = try gpa.dupe(u8, entry.value_ptr.object.get("hash").?.string),
            .size = @intCast(entry.value_ptr.object.get("size").?.integer),
            .pool = pool,
        });
    }

    std.mem.sort(Resource, list.items, {}, Resource.lessThan);
    return list.toOwnedSlice(gpa);
}

fn upToDate(io: std.Io, dir: std.Io.Dir, resource: Resource) bool {
    const stat = dir.statFile(io, resource.path, .{}) catch return false;
    return stat.size == resource.size;
}

fn fetchResource(
    gpa: std.mem.Allocator,
    client: *std.http.Client,
    io: std.Io,
    dir: std.Io.Dir,
    resource: Resource,
) !void {
    if (upToDate(io, dir, resource)) return;

    const url = try std.fmt.allocPrint(gpa, "{s}{s}/{s}", .{ resource_url, resource.hash[0..2], resource.hash });
    defer gpa.free(url);

    const bytes = try fetchAlloc(gpa, client, url);
    defer gpa.free(bytes);

    var actual_hex: [40]u8 = undefined;
    sha1Hex(bytes, &actual_hex);
    if (!std.mem.eql(u8, &actual_hex, resource.hash)) return error.ChecksumMismatch;

    if (std.fs.path.dirname(resource.path)) |parent| try dir.createDirPath(io, parent);
    try dir.writeFile(io, .{ .sub_path = resource.path, .data = bytes });
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
            try writer.print("pub const {s}: Asset = .{{ .path = \"{s}\", .bytes = @embedFile(\"{s}\") }};\n", .{ ident, p, p });
        } else {
            try writer.print("pub const {s} = struct {{\n", .{ident});
            try emit(writer, alloc, child, depth + 1);
            try writer.splatByteAll(' ', depth * 4);
            try writer.writeAll("};\n");
        }
    }
}

fn writeManifest(
    io: std.Io,
    assets_dir: std.Io.Dir,
    gpa: std.mem.Allocator,
    names: *std.ArrayList([]const u8),
    sounds: []const Resource,
) !void {
    const root = try Node.init(gpa);
    for (names.items) |p| try insert(gpa, root, p);

    var out_buf: std.Io.Writer.Allocating = .init(gpa);
    defer out_buf.deinit();

    try out_buf.writer.writeAll(
        \\pub const Asset = struct { path: []const u8, bytes: []const u8 };
        \\
    );

    try emit(&out_buf.writer, gpa, root, 0);

    try out_buf.writer.writeAll(
        \\pub const sounds = [_]Asset{
        \\
    );
    for (sounds) |sound| {
        try out_buf.writer.print(
            "    .{{ .path = \"{s}\", .bytes = @embedFile(\"{s}\") }},\n",
            .{ sound.path, sound.path },
        );
    }
    try out_buf.writer.writeAll("};\n");

    var out_file = try assets_dir.createFile(io, "root.zig", .{ .truncate = true });
    defer out_file.close(io);
    try out_file.writeStreamingAll(io, out_buf.written());
}

pub fn main(init: std.process.Init) !void {
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

    const index_url = try findAssetIndexUrl(gpa, version_body);
    defer gpa.free(index_url);

    const index_body = try fetchAlloc(gpa, &client, index_url);
    defer gpa.free(index_body);

    const resources = try findResources(gpa, index_body);
    defer gpa.free(resources);

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next();
    const resource_root = args.next() orelse return error.MissingResourceDir;

    try cwd.createDirPath(io, resource_root);
    var resource_dir = try cwd.openDir(io, resource_root, .{});
    defer resource_dir.close(io);

    var embedded: std.ArrayList(Resource) = .empty;
    defer embedded.deinit(gpa);

    for (resources, 1..) |resource, done| {
        const dir = switch (resource.pool) {
            .embedded => assets_dir,
            .streamed => resource_dir,
        };
        try fetchResource(gpa, &client, io, dir, resource);
        if (resource.pool == .embedded) try embedded.append(gpa, resource);
        std.log.info("resource {d}/{d} {s}", .{ done, resources.len, resource.path });
    }

    try writeManifest(io, assets_dir, gpa, &names, embedded.items);
}
