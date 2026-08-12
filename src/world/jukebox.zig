const std = @import("std");

const Item = @import("item.zig").Item;
const nbt = @import("nbt.zig");
const testing_world = @import("testing.zig");
const World = @import("world_map.zig");

pub const id_key = "RecordPlayer";

pub const Jukebox = struct {
    record: ?Item = null,
};

pub fn insertRecord(world_map: *World, x: i32, y: i32, z: i32, record: Item) !void {
    (try world_map.addJukebox(x, y, z)).record = record;
    try world_map.setBlockMetadataWithNotify(x, y, z, 1);
}

pub fn takeRecord(world_map: *World, x: i32, y: i32, z: i32) !?Item {
    const state = world_map.jukeboxAt(x, y, z) orelse return null;
    const record = state.record orelse return null;
    state.record = null;
    try world_map.setBlockMetadataWithNotify(x, y, z, 0);
    return record;
}

fn put(gpa: std.mem.Allocator, compound: *nbt.Compound, key: []const u8, tag: nbt.Tag) !void {
    try nbt.putDuped(gpa, compound, key, tag);
}

pub fn store(gpa: std.mem.Allocator, x: i32, y: i32, z: i32, state: Jukebox) !nbt.Tag {
    var compound: nbt.Compound = .{};
    errdefer {
        var owned: nbt.Tag = .{ .compound = compound };
        nbt.deinit(gpa, &owned);
    }

    try put(gpa, &compound, "id", .{ .string = try gpa.dupe(u8, id_key) });
    try put(gpa, &compound, "x", .{ .int = x });
    try put(gpa, &compound, "y", .{ .int = y });
    try put(gpa, &compound, "z", .{ .int = z });

    if (state.record) |record| {
        try put(gpa, &compound, "Record", .{ .int = @intFromEnum(record) });
    }

    return .{ .compound = compound };
}

pub const Placed = struct {
    x: i32,
    y: i32,
    z: i32,
    state: Jukebox,
};

pub fn isJukebox(compound: nbt.Compound) bool {
    return switch (compound.get("id") orelse return false) {
        .string => |value| std.mem.eql(u8, value, id_key),
        else => false,
    };
}

fn intField(compound: nbt.Compound, key: []const u8) ?i32 {
    return switch (compound.get(key) orelse return null) {
        .int => |value| value,
        else => null,
    };
}

pub fn load(compound: nbt.Compound) ?Placed {
    if (!isJukebox(compound)) return null;

    const raw = intField(compound, "Record") orelse 0;
    const record: ?Item = if (raw > 0 and raw <= std.math.maxInt(u16))
        @enumFromInt(@as(u16, @intCast(raw)))
    else
        null;

    return .{
        .x = intField(compound, "x") orelse return null,
        .y = intField(compound, "y") orelse return null,
        .z = intField(compound, "z") orelse return null,
        .state = .{ .record = record },
    };
}

test "inserting a record fills the jukebox and lights its metadata" {
    var w = try testing_world.flatWorld(std.testing.allocator, 4);
    defer w.deinit();
    try w.setBlockWithNotify(8, 4, 8, .jukebox);

    try std.testing.expect(w.jukeboxAt(8, 4, 8) == null);

    try insertRecord(&w, 8, 4, 8, .record_13);
    try std.testing.expectEqual(@as(u4, 1), w.getBlockMetadata(8, 4, 8));
    try std.testing.expectEqual(Item.record_13, w.jukeboxAt(8, 4, 8).?.record.?);
}

test "taking a record hands it back once and clears the metadata" {
    var w = try testing_world.flatWorld(std.testing.allocator, 4);
    defer w.deinit();
    try w.setBlockWithNotify(8, 4, 8, .jukebox);
    try insertRecord(&w, 8, 4, 8, .record_cat);

    try std.testing.expectEqual(Item.record_cat, (try takeRecord(&w, 8, 4, 8)).?);
    try std.testing.expectEqual(@as(u4, 0), w.getBlockMetadata(8, 4, 8));
    try std.testing.expect(try takeRecord(&w, 8, 4, 8) == null);
}

test "a jukebox that lost its block spills its record and its state" {
    var w = try testing_world.flatWorld(std.testing.allocator, 4);
    defer w.deinit();
    try w.setBlockWithNotify(8, 4, 8, .jukebox);
    try insertRecord(&w, 8, 4, 8, .record_13);

    try w.spillOrphanJukeboxes();
    try std.testing.expectEqual(@as(usize, 0), w.dropped.items.len);

    try w.setBlockWithNotify(8, 4, 8, .air);
    try w.spillOrphanJukeboxes();
    try std.testing.expectEqual(@as(usize, 1), w.dropped.items.len);
    try std.testing.expectEqual(Item.record_13, w.dropped.items[0].stack.id.item);
    try std.testing.expect(w.jukeboxAt(8, 4, 8) == null);
}

test "an empty jukebox writes no Record tag and reads back empty" {
    const gpa = std.testing.allocator;
    var tag = try store(gpa, 3, 70, -9, .{});
    defer nbt.deinit(gpa, &tag);

    try std.testing.expect(tag.compound.get("Record") == null);

    const loaded = load(tag.compound).?;
    try std.testing.expectEqual(@as(i32, 3), loaded.x);
    try std.testing.expectEqual(@as(i32, 70), loaded.y);
    try std.testing.expectEqual(@as(i32, -9), loaded.z);
    try std.testing.expect(loaded.state.record == null);
}

test "a loaded record survives a trip through NBT" {
    const gpa = std.testing.allocator;
    var tag = try store(gpa, 0, 64, 0, .{ .record = .record_cat });
    defer nbt.deinit(gpa, &tag);

    try std.testing.expectEqual(@as(i32, 2257), tag.compound.get("Record").?.int);
    try std.testing.expectEqual(Item.record_cat, load(tag.compound).?.state.record.?);
}

test "a tile entity of another kind is not read as a jukebox" {
    const gpa = std.testing.allocator;
    var tag = try store(gpa, 1, 2, 3, .{});
    defer nbt.deinit(gpa, &tag);

    const stored = tag.compound.getPtr("id").?;
    gpa.free(stored.string);
    stored.string = try gpa.dupe(u8, "Chest");

    try std.testing.expect(!isJukebox(tag.compound));
    try std.testing.expect(load(tag.compound) == null);
}
