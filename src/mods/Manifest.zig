const std = @import("std");

const Manifest = @This();

id: []const u8,
version: []const u8,
depends: []const []const u8 = &.{},

pub const file_name = "mod.json";

pub const ParseError = error{ OutOfMemory, InvalidManifest, InvalidId };

pub fn parse(arena: std.mem.Allocator, text: []const u8) ParseError!Manifest {
    const manifest = std.json.parseFromSliceLeaky(Manifest, arena, text, .{ .allocate = .alloc_always }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidManifest,
    };
    if (!validId(manifest.id)) return error.InvalidId;
    for (manifest.depends) |dependency| {
        if (!validId(dependency)) return error.InvalidId;
    }
    return manifest;
}

pub fn validId(id: []const u8) bool {
    if (id.len == 0) return false;
    for (id) |char| switch (char) {
        'a'...'z', '0'...'9', '_' => {},
        else => return false,
    };
    return true;
}

test "a manifest names its mod, version and dependencies" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try parse(arena.allocator(),
        \\{ "id": "quartz", "version": "1.0.0", "depends": ["stone_age"] }
    );
    try std.testing.expectEqualStrings("quartz", manifest.id);
    try std.testing.expectEqualStrings("1.0.0", manifest.version);
    try std.testing.expectEqual(1, manifest.depends.len);
    try std.testing.expectEqualStrings("stone_age", manifest.depends[0]);
}

test "dependencies are optional" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try parse(arena.allocator(),
        \\{ "id": "quartz", "version": "1.0.0" }
    );
    try std.testing.expectEqual(0, manifest.depends.len);
}

test "a malformed or misspelled manifest is rejected" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidManifest, parse(arena.allocator(), "{ \"id\": \"quartz\" }"));
    try std.testing.expectError(error.InvalidManifest, parse(arena.allocator(),
        \\{ "id": "quartz", "version": "1.0.0", "dependencies": [] }
    ));
    try std.testing.expectError(error.InvalidManifest, parse(arena.allocator(), "not json"));
}

test "ids are lowercase so they can prefix registry keys" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidId, parse(arena.allocator(),
        \\{ "id": "Quartz", "version": "1.0.0" }
    ));
    try std.testing.expectError(error.InvalidId, parse(arena.allocator(),
        \\{ "id": "quartz", "version": "1.0.0", "depends": ["stone:age"] }
    ));
    try std.testing.expectError(error.InvalidId, parse(arena.allocator(),
        \\{ "id": "", "version": "1.0.0" }
    ));
}
