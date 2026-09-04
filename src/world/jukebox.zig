const std = @import("std");

const BlockPos = @import("BlockPos.zig");
const Item = @import("item.zig").Item;
const nbt = @import("nbt.zig");
const testing_world = @import("testing.zig");
const World = @import("World.zig");

pub const id_key = "RecordPlayer";

pub const Jukebox = struct {
    record: ?Item = null,
};

pub fn insertRecord(world_map: *World, pos: BlockPos, record: Item) !void {
    (try world_map.addJukebox(pos)).record = record;
    try world_map.setBlockMetadataWithNotify(pos, 1);
    world_map.playAuxSfx(.record_play, pos, @intFromEnum(record));
}

pub fn takeRecord(world_map: *World, pos: BlockPos) !?Item {
    const state = world_map.jukeboxAt(pos) orelse return null;
    const record = state.record orelse return null;
    state.record = null;
    try world_map.setBlockMetadataWithNotify(pos, 0);
    world_map.playAuxSfx(.record_play, pos, 0);
    return record;
}

fn put(gpa: std.mem.Allocator, compound: *nbt.Compound, key: []const u8, tag: nbt.Tag) !void {
    try nbt.putDuped(gpa, compound, key, tag);
}

pub fn store(gpa: std.mem.Allocator, pos: BlockPos, state: Jukebox) !nbt.Tag {
    var compound: nbt.Compound = .{};
    errdefer {
        var owned: nbt.Tag = .{ .compound = compound };
        nbt.deinit(gpa, &owned);
    }

    try put(gpa, &compound, "id", .{ .string = try gpa.dupe(u8, id_key) });
    try put(gpa, &compound, "x", .{ .int = pos.x });
    try put(gpa, &compound, "y", .{ .int = pos.y });
    try put(gpa, &compound, "z", .{ .int = pos.z });

    if (state.record) |record| {
        try put(gpa, &compound, "Record", .{ .int = @intFromEnum(record) });
    }

    return .{ .compound = compound };
}

pub const Placed = struct {
    pos: BlockPos,
    state: Jukebox,
};

pub fn isJukebox(compound: nbt.Compound) bool {
    return switch (compound.get("id") orelse return false) {
        .string => |value| std.mem.eql(u8, value, id_key),
        else => false,
    };
}

pub fn load(compound: nbt.Compound) ?Placed {
    if (!isJukebox(compound)) return null;

    const raw = nbt.intField(compound, "Record") orelse 0;
    const record: ?Item = if (raw > 0 and raw <= std.math.maxInt(u16))
        @enumFromInt(@as(u16, @intCast(raw)))
    else
        null;

    return .{
        .pos = .{
            .x = nbt.intField(compound, "x") orelse return null,
            .y = nbt.intField(compound, "y") orelse return null,
            .z = nbt.intField(compound, "z") orelse return null,
        },
        .state = .{ .record = record },
    };
}

test "inserting a record fills the jukebox and lights its metadata" {
    var w = try testing_world.flatWorld(std.testing.allocator, 4);
    defer w.deinit();
    try w.setBlockWithNotify(.init(8, 4, 8), .jukebox);

    try std.testing.expect(w.jukeboxAt(.init(8, 4, 8)) == null);

    try insertRecord(&w, .init(8, 4, 8), .record_13);
    try std.testing.expectEqual(@as(u4, 1), w.getBlockMetadata(.init(8, 4, 8)));
    try std.testing.expectEqual(Item.record_13, w.jukeboxAt(.init(8, 4, 8)).?.record.?);
}

test "taking a record hands it back once and clears the metadata" {
    var w = try testing_world.flatWorld(std.testing.allocator, 4);
    defer w.deinit();
    try w.setBlockWithNotify(.init(8, 4, 8), .jukebox);
    try insertRecord(&w, .init(8, 4, 8), .record_cat);

    try std.testing.expectEqual(Item.record_cat, (try takeRecord(&w, .init(8, 4, 8))).?);
    try std.testing.expectEqual(@as(u4, 0), w.getBlockMetadata(.init(8, 4, 8)));
    try std.testing.expect(try takeRecord(&w, .init(8, 4, 8)) == null);
}

test "a jukebox that lost its block spills its record and its state" {
    var w = try testing_world.flatWorld(std.testing.allocator, 4);
    defer w.deinit();
    try w.setBlockWithNotify(.init(8, 4, 8), .jukebox);
    try insertRecord(&w, .init(8, 4, 8), .record_13);

    try w.spillOrphanJukeboxes();
    try std.testing.expectEqual(@as(usize, 0), w.dropped.items.len);

    try w.setBlockWithNotify(.init(8, 4, 8), .air);
    try w.spillOrphanJukeboxes();
    try std.testing.expectEqual(@as(usize, 1), w.dropped.items.len);
    try std.testing.expectEqual(Item.record_13, w.dropped.items[0].stack.id.item);
    try std.testing.expect(w.jukeboxAt(.init(8, 4, 8)) == null);
}

test "an empty jukebox writes no Record tag and reads back empty" {
    const gpa = std.testing.allocator;
    var tag = try store(gpa, .init(3, 70, -9), .{});
    defer nbt.deinit(gpa, &tag);

    try std.testing.expect(tag.compound.get("Record") == null);

    const loaded = load(tag.compound).?;
    try std.testing.expectEqual(BlockPos.init(3, 70, -9), loaded.pos);
    try std.testing.expect(loaded.state.record == null);
}

test "a loaded record survives a trip through NBT" {
    const gpa = std.testing.allocator;
    var tag = try store(gpa, .init(0, 64, 0), .{ .record = .record_cat });
    defer nbt.deinit(gpa, &tag);

    try std.testing.expectEqual(@as(i32, 2257), tag.compound.get("Record").?.int);
    try std.testing.expectEqual(Item.record_cat, load(tag.compound).?.state.record.?);
}

test "a tile entity of another kind is not read as a jukebox" {
    const gpa = std.testing.allocator;
    var tag = try store(gpa, .init(1, 2, 3), .{});
    defer nbt.deinit(gpa, &tag);

    const stored = tag.compound.getPtr("id").?;
    gpa.free(stored.string);
    stored.string = try gpa.dupe(u8, "Chest");

    try std.testing.expect(!isJukebox(tag.compound));
    try std.testing.expect(load(tag.compound) == null);
}

const AuxSfxLog = struct {
    last: ?World.AuxSfx = null,
    data: i32 = 0,
    count: usize = 0,

    fn record(context: *anyopaque, effect: World.AuxSfx, _: BlockPos, data: i32) void {
        const self: *AuxSfxLog = @ptrCast(@alignCast(context));
        self.last = effect;
        self.data = data;
        self.count += 1;
    }

    fn sink(self: *AuxSfxLog) World.AuxSfxSink {
        return .{ .context = self, .play = record };
    }
};

test "a jukebox names the record it starts, and names nothing when it stops" {
    var w = try testing_world.flatWorld(std.testing.allocator, 5);
    defer w.deinit();

    var heard: AuxSfxLog = .{};
    w.aux_sfx_sink = heard.sink();
    w.setBlock(.init(8, 4, 8), .jukebox);

    try insertRecord(&w, .init(8, 4, 8), .record_cat);
    try std.testing.expectEqual(World.AuxSfx.record_play, heard.last.?);
    try std.testing.expectEqual(@as(i32, @intFromEnum(Item.record_cat)), heard.data);

    try std.testing.expectEqual(Item.record_cat, (try takeRecord(&w, .init(8, 4, 8))).?);
    try std.testing.expectEqual(World.AuxSfx.record_play, heard.last.?);
    try std.testing.expectEqual(@as(i32, 0), heard.data);
    try std.testing.expectEqual(@as(usize, 2), heard.count);
}
