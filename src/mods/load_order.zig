const std = @import("std");

const Mod = @import("discovery.zig").Mod;

pub const Error = error{ OutOfMemory, DuplicateId, MissingDependency, DependencyCycle };

pub fn sort(arena: std.mem.Allocator, mods: []const Mod) Error![]Mod {
    for (mods, 0..) |mod, index| {
        for (mods[index + 1 ..]) |other| {
            if (std.mem.eql(u8, mod.manifest.id, other.manifest.id)) return error.DuplicateId;
        }
        for (mod.manifest.depends) |dependency| {
            _ = find(mods, dependency) orelse return error.MissingDependency;
        }
    }

    const placed = try arena.alloc(bool, mods.len);
    @memset(placed, false);
    const sorted = try arena.alloc(Mod, mods.len);
    for (sorted) |*slot| {
        var next: ?usize = null;
        for (mods, 0..) |mod, index| {
            if (placed[index] or !ready(mods, placed, mod)) continue;
            if (next) |best| {
                if (!std.mem.lessThan(u8, mod.manifest.id, mods[best].manifest.id)) continue;
            }
            next = index;
        }
        const chosen = next orelse return error.DependencyCycle;
        placed[chosen] = true;
        slot.* = mods[chosen];
    }
    return sorted;
}

fn find(mods: []const Mod, id: []const u8) ?usize {
    for (mods, 0..) |mod, index| {
        if (std.mem.eql(u8, mod.manifest.id, id)) return index;
    }
    return null;
}

fn ready(mods: []const Mod, placed: []const bool, mod: Mod) bool {
    for (mod.manifest.depends) |dependency| {
        if (!placed[find(mods, dependency).?]) return false;
    }
    return true;
}

fn testMod(id: []const u8, depends: []const []const u8) Mod {
    return .{ .folder = id, .manifest = .{ .id = id, .version = "1.0.0", .depends = depends } };
}

fn expectOrder(expected: []const []const u8, sorted: []const Mod) !void {
    try std.testing.expectEqual(expected.len, sorted.len);
    for (expected, sorted) |id, mod| try std.testing.expectEqualStrings(id, mod.manifest.id);
}

test "dependencies load first and independent mods load by id" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const mods = [_]Mod{
        testMod("zeta", &.{}),
        testMod("quartz", &.{"stone_age"}),
        testMod("stone_age", &.{"alpha"}),
        testMod("alpha", &.{}),
    };
    try expectOrder(&.{ "alpha", "stone_age", "quartz", "zeta" }, try sort(arena.allocator(), &mods));
}

test "the order folders are found in does not change the load order" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var mods = [_]Mod{
        testMod("wiring", &.{ "copper", "tools" }),
        testMod("copper", &.{}),
        testMod("tools", &.{"copper"}),
        testMod("biomes", &.{}),
        testMod("mobs", &.{"biomes"}),
        testMod("quartz", &.{}),
    };
    const expected = [_][]const u8{ "biomes", "copper", "mobs", "quartz", "tools", "wiring" };
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    for (0..32) |_| {
        prng.random().shuffle(Mod, &mods);
        try expectOrder(&expected, try sort(arena.allocator(), &mods));
    }
}

test "a missing dependency is reported" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const mods = [_]Mod{testMod("quartz", &.{"stone_age"})};
    try std.testing.expectError(error.MissingDependency, sort(arena.allocator(), &mods));
}

test "two mods cannot share an id" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const mods = [_]Mod{ testMod("quartz", &.{}), testMod("quartz", &.{}) };
    try std.testing.expectError(error.DuplicateId, sort(arena.allocator(), &mods));
}

test "a dependency cycle is reported" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const cycle = [_]Mod{ testMod("a", &.{"b"}), testMod("b", &.{"a"}) };
    try std.testing.expectError(error.DependencyCycle, sort(arena.allocator(), &cycle));
    const itself = [_]Mod{testMod("a", &.{"a"})};
    try std.testing.expectError(error.DependencyCycle, sort(arena.allocator(), &itself));
}
