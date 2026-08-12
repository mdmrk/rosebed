const std = @import("std");

const Pool = @This();

pub const Source = union(enum) {
    embedded: u32,
    file: [:0]const u8,
};

entries: std.ArrayList(Source) = .empty,
groups: std.StringArrayHashMapUnmanaged(std.ArrayList(u32)) = .empty,
strip_digits: bool = true,

pub fn deinit(self: *Pool, gpa: std.mem.Allocator) void {
    for (self.entries.items) |source| switch (source) {
        .file => |path| gpa.free(path),
        .embedded => {},
    };
    self.entries.deinit(gpa);
    for (self.groups.keys()) |key| gpa.free(key);
    for (self.groups.values()) |*list| list.deinit(gpa);
    self.groups.deinit(gpa);
}

pub fn keyOf(gpa: std.mem.Allocator, path: []const u8, strip_digits: bool) ![]u8 {
    var end = std.mem.indexOfScalar(u8, path, '.') orelse path.len;
    if (strip_digits) {
        while (end > 0 and std.ascii.isDigit(path[end - 1])) end -= 1;
    }
    const key = try gpa.dupe(u8, path[0..end]);
    std.mem.replaceScalar(u8, key, '/', '.');
    return key;
}

pub fn add(self: *Pool, gpa: std.mem.Allocator, path: []const u8, source: Source) !void {
    const key = try keyOf(gpa, path, self.strip_digits);
    errdefer gpa.free(key);

    const index: u32 = @intCast(self.entries.items.len);
    try self.entries.append(gpa, source);
    errdefer _ = self.entries.pop();

    const found = try self.groups.getOrPut(gpa, key);
    if (found.found_existing) gpa.free(key) else found.value_ptr.* = .empty;
    try found.value_ptr.append(gpa, index);
}

pub fn pick(self: *const Pool, name: []const u8, rand: std.Random) ?Source {
    const group = self.groups.get(name) orelse return null;
    return self.entries.items[group.items[rand.uintLessThan(usize, group.items.len)]];
}

pub fn pickAny(self: *const Pool, rand: std.Random) ?Source {
    if (self.entries.items.len == 0) return null;
    return self.entries.items[rand.uintLessThan(usize, self.entries.items.len)];
}

test "a pool key drops the extension, the variant digits and the directories" {
    const gpa = std.testing.allocator;

    const step = try keyOf(gpa, "step/grass1.ogg", true);
    defer gpa.free(step);
    try std.testing.expectEqualStrings("step.grass", step);

    const cave = try keyOf(gpa, "ambient/cave/cave13.ogg", true);
    defer gpa.free(cave);
    try std.testing.expectEqualStrings("ambient.cave.cave", cave);

    const record = try keyOf(gpa, "13.ogg", false);
    defer gpa.free(record);
    try std.testing.expectEqualStrings("13", record);
}

test "every variant of a name lands in one group" {
    const gpa = std.testing.allocator;

    var pool: Pool = .{};
    defer pool.deinit(gpa);

    try pool.add(gpa, "step/grass1.ogg", .{ .embedded = 0 });
    try pool.add(gpa, "step/grass2.ogg", .{ .embedded = 1 });
    try pool.add(gpa, "step/wood1.ogg", .{ .embedded = 2 });

    var prng: std.Random.DefaultPrng = .init(0);
    const rand = prng.random();

    try std.testing.expectEqual(@as(?Source, .{ .embedded = 2 }), pool.pick("step.wood", rand));
    try std.testing.expectEqual(@as(?Source, null), pool.pick("step.stone", rand));

    for (0..16) |_| {
        const picked = pool.pick("step.grass", rand).?;
        try std.testing.expect(picked.embedded == 0 or picked.embedded == 1);
    }
}

test "a streaming pool keeps the digits that name a record" {
    const gpa = std.testing.allocator;

    var pool: Pool = .{ .strip_digits = false };
    defer pool.deinit(gpa);

    try pool.add(gpa, "13.ogg", .{ .embedded = 0 });
    try pool.add(gpa, "cat.ogg", .{ .embedded = 1 });

    var prng: std.Random.DefaultPrng = .init(0);
    const rand = prng.random();

    try std.testing.expectEqual(@as(?Source, .{ .embedded = 0 }), pool.pick("13", rand));
    try std.testing.expectEqual(@as(?Source, .{ .embedded = 1 }), pool.pick("cat", rand));
}
