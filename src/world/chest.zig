const std = @import("std");

const block = @import("block.zig");
const Stack = block.Stack;
const BlockPos = @import("BlockPos.zig");
const nbt = @import("nbt.zig");
const tile = @import("tile.zig");

pub const id_key = "Chest";
pub const stack_limit: u8 = 64;
pub const slot_count = 27;
pub const rows = 3;

pub const Chest = struct {
    items: [slot_count]?Stack = @splat(null),

    pub fn slot(self: *Chest, index: usize) *?Stack {
        return &self.items[index];
    }

    pub fn isEmpty(self: Chest) bool {
        for (self.items) |maybe_stack| {
            if (maybe_stack != null) return false;
        }
        return true;
    }
};

pub fn store(gpa: std.mem.Allocator, pos: BlockPos, state: Chest) !nbt.Tag {
    var compound: nbt.Compound = .{};
    errdefer {
        var owned: nbt.Tag = .{ .compound = compound };
        nbt.deinit(gpa, &owned);
    }

    try tile.header(gpa, &compound, id_key, pos);

    try tile.storeItems(gpa, &compound, &state.items);

    return .{ .compound = compound };
}

pub const Placed = struct {
    pos: BlockPos,
    state: Chest,
};

pub fn isChest(compound: nbt.Compound) bool {
    return tile.isKind(compound, id_key);
}

pub fn load(compound: nbt.Compound) ?Placed {
    if (!isChest(compound)) return null;

    var state: Chest = .{};

    tile.loadItems(compound, &state.items);

    return .{
        .pos = tile.position(compound) orelse return null,
        .state = state,
    };
}

test "a chest holds the twenty-seven slots TileEntityChest reports" {
    var state: Chest = .{};
    try std.testing.expect(state.isEmpty());

    state.slot(26).* = .{ .id = .{ .block = .stone }, .count = 64 };
    try std.testing.expect(!state.isEmpty());
    try std.testing.expectEqual(@as(usize, 27), state.items.len);
}

test "a chest survives a round trip through its tile entity compound" {
    const gpa = std.testing.allocator;
    var original: Chest = .{};
    original.slot(0).* = .{ .id = .{ .block = .planks }, .count = 32 };
    original.slot(13).* = .{ .id = .{ .item = .pickaxe_iron }, .count = 1, .meta = 47 };
    original.slot(26).* = .{ .id = .{ .item = .diamond }, .count = 5 };

    var tag = try store(gpa, .init(-18, 40, 7), original);
    defer nbt.deinit(gpa, &tag);

    try std.testing.expectEqual(@as(usize, 3), tag.compound.get("Items").?.list.items.len);

    const loaded = load(tag.compound).?;
    try std.testing.expectEqual(BlockPos.init(-18, 40, 7), loaded.pos);
    try std.testing.expectEqual(original, loaded.state);
}

test "an empty chest round-trips with no item entries" {
    const gpa = std.testing.allocator;
    var tag = try store(gpa, .init(0, 0, 0), .{});
    defer nbt.deinit(gpa, &tag);

    try std.testing.expectEqual(@as(usize, 0), tag.compound.get("Items").?.list.items.len);
    try std.testing.expect(load(tag.compound).?.state.isEmpty());
}

test "a tile entity of another kind is not read as a chest" {
    const gpa = std.testing.allocator;
    var tag = try store(gpa, .init(1, 2, 3), .{});
    defer nbt.deinit(gpa, &tag);

    const stored = tag.compound.getPtr("id").?;
    gpa.free(stored.string);
    stored.string = try gpa.dupe(u8, "Furnace");

    try std.testing.expect(!isChest(tag.compound));
    try std.testing.expect(load(tag.compound) == null);
}
