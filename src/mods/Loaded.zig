const std = @import("std");

const world = @import("world");

const discovery = @import("discovery.zig");
const load_order = @import("load_order.zig");
const registry = @import("registry.zig");
const Vm = @import("Vm.zig");

const Loaded = @This();

arena: *std.heap.ArenaAllocator,
vm: Vm,
mods: []const discovery.Mod,

pub const folder_name = "mods";
pub const entry_point = "common.lua";

const source_limit: std.Io.Limit = .limited(4 * 1024 * 1024);

pub fn load(gpa: std.mem.Allocator, io: std.Io, mods_dir: std.Io.Dir, report: *std.Io.Writer) !Loaded {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    const found = discovery.discover(allocator, io, mods_dir) catch |err| {
        report.print("could not read the mods folder: {t}\n", .{err}) catch {};
        return err;
    };
    const mods = load_order.sort(allocator, found) catch |err| {
        report.print("could not order the mods: {t}\n", .{err}) catch {};
        return err;
    };

    const registrar = try allocator.create(registry.Registrar);
    registrar.* = .{ .arena = allocator };
    var vm: Vm = try .init(gpa);
    errdefer vm.deinit();
    registry.install(vm.lua, registrar);

    errdefer world.Block.resetRegistry();
    errdefer world.Item.resetRegistry();
    for (mods) |mod| {
        var dir = try mods_dir.openDir(io, mod.folder, .{});
        defer dir.close(io);
        const source = dir.readFileAlloc(io, entry_point, allocator, source_limit) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => {
                report.print("{s}/{s}: {t}\n", .{ mod.folder, entry_point, err }) catch {};
                return err;
            },
        };
        registrar.mod_id = mod.manifest.id;
        const chunk_name = try std.fmt.allocPrintSentinel(allocator, "@{s}/{s}", .{ mod.folder, entry_point }, 0);
        vm.exec(chunk_name, source) catch |err| {
            report.print("{s}\n", .{vm.errorMessage()}) catch {};
            return err;
        };
    }
    registrar.open = false;

    return .{ .arena = arena, .vm = vm, .mods = mods };
}

pub fn deinit(self: *Loaded, gpa: std.mem.Allocator) void {
    self.vm.deinit();
    self.arena.deinit();
    gpa.destroy(self.arena);
}

fn writeMod(io: std.Io, dir: std.Io.Dir, folder: []const u8, manifest: []const u8, common: ?[]const u8) !void {
    try dir.createDirPath(io, folder);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    try dir.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&path_buffer, "{s}/mod.json", .{folder}), .data = manifest });
    if (common) |source| {
        try dir.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&path_buffer, "{s}/" ++ entry_point, .{folder}), .data = source });
    }
}

test "mods load in dependency and id order whatever their folders are called" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    defer world.Block.resetRegistry();

    try writeMod(io, tmp.dir, "aaa",
        \\{ "id": "wiring", "version": "1.0.0", "depends": ["copper"] }
    , "rosebed.register_block { key = 'wire' }");
    try writeMod(io, tmp.dir, "bbb",
        \\{ "id": "stone", "version": "1.0.0" }
    , "rosebed.register_block { key = 'slate' }");
    try writeMod(io, tmp.dir, "zzz",
        \\{ "id": "copper", "version": "1.0.0" }
    , "rosebed.register_block { key = 'ore' }");
    try writeMod(io, tmp.dir, "docs",
        \\{ "id": "docs", "version": "1.0.0" }
    , null);

    var report: std.Io.Writer.Allocating = .init(gpa);
    defer report.deinit();
    var loaded = try load(gpa, io, tmp.dir, &report.writer);
    defer loaded.deinit(gpa);

    try std.testing.expectEqual(4, loaded.mods.len);
    try std.testing.expectEqual(@as(world.Block, @enumFromInt(97)), world.Block.fromKey("copper:ore").?);
    try std.testing.expectEqual(@as(world.Block, @enumFromInt(98)), world.Block.fromKey("stone:slate").?);
    try std.testing.expectEqual(@as(world.Block, @enumFromInt(99)), world.Block.fromKey("wiring:wire").?);
    try std.testing.expectEqualStrings("", report.written());
}

test "registration closes once loading has finished" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    defer world.Block.resetRegistry();

    var report: std.Io.Writer.Allocating = .init(gpa);
    defer report.deinit();
    var loaded = try load(gpa, io, tmp.dir, &report.writer);
    defer loaded.deinit(gpa);

    try std.testing.expectError(error.ScriptFailed, loaded.vm.exec("=late", "rosebed.register_block { key = 'late' }"));
}

test "a failing mod is reported by file and line and leaves the registry untouched" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try writeMod(io, tmp.dir, "copper",
        \\{ "id": "copper", "version": "1.0.0" }
    , "rosebed.register_block { key = 'ore' }\nrosebed.override_block('stone', { hardness = 9 })");
    try writeMod(io, tmp.dir, "wiring",
        \\{ "id": "wiring", "version": "1.0.0", "depends": ["copper"] }
    , "local x = 1\nerror('boom')");

    var report: std.Io.Writer.Allocating = .init(gpa);
    defer report.deinit();
    try std.testing.expectError(error.ScriptFailed, load(gpa, io, tmp.dir, &report.writer));
    try std.testing.expectEqualStrings("wiring/common.lua:2: boom\n", report.written());
    try std.testing.expect(world.Block.fromKey("copper:ore") == null);
    try std.testing.expectEqual(@as(f32, 1.5), world.Block.stone.def().hardness);
}

test "a mod that depends on a missing one is reported" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try writeMod(io, tmp.dir, "wiring",
        \\{ "id": "wiring", "version": "1.0.0", "depends": ["copper"] }
    , null);

    var report: std.Io.Writer.Allocating = .init(gpa);
    defer report.deinit();
    try std.testing.expectError(error.MissingDependency, load(gpa, io, tmp.dir, &report.writer));
    try std.testing.expectEqualStrings("could not order the mods: MissingDependency\n", report.written());
}
