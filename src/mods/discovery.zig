const std = @import("std");

const Manifest = @import("Manifest.zig");

pub const Mod = struct {
    folder: []const u8,
    manifest: Manifest,
};

const manifest_limit: std.Io.Limit = .limited(64 * 1024);

pub fn discover(arena: std.mem.Allocator, io: std.Io, mods_dir: std.Io.Dir) ![]Mod {
    var found: std.ArrayList(Mod) = .empty;
    var iterator = mods_dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        var dir = try mods_dir.openDir(io, entry.name, .{});
        defer dir.close(io);
        const text = dir.readFileAlloc(io, Manifest.file_name, arena, manifest_limit) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        try found.append(arena, .{
            .folder = try arena.dupe(u8, entry.name),
            .manifest = try Manifest.parse(arena, text),
        });
    }
    return found.items;
}

test "every folder with a manifest is a mod" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "quartz_blocks");
    try tmp.dir.writeFile(io, .{
        .sub_path = "quartz_blocks/" ++ Manifest.file_name,
        .data =
        \\{ "id": "quartz", "version": "1.0.0" }
        ,
    });
    try tmp.dir.createDirPath(io, "notes");
    try tmp.dir.writeFile(io, .{ .sub_path = "readme.txt", .data = "not a mod" });

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const mods = try discover(arena.allocator(), io, tmp.dir);
    try std.testing.expectEqual(1, mods.len);
    try std.testing.expectEqualStrings("quartz_blocks", mods[0].folder);
    try std.testing.expectEqualStrings("quartz", mods[0].manifest.id);
}

test "a broken manifest stops discovery instead of skipping the mod" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "quartz");
    try tmp.dir.writeFile(io, .{ .sub_path = "quartz/" ++ Manifest.file_name, .data = "{ \"id\": \"quartz\" }" });

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidManifest, discover(arena.allocator(), io, tmp.dir));
}
