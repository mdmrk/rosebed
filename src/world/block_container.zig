const std = @import("std");

const block = @import("block.zig");
const Stack = block.Stack;
const BlockPos = @import("BlockPos.zig");
const nbt = @import("nbt.zig");
const tile = @import("tile.zig");

pub const id_key = "RosebedContainer";
pub const max_rows: u8 = 6;
pub const max_slots: usize = @as(usize, max_rows) * 9;

pub const Store = struct {
    items: [max_slots]?Stack = @splat(null),

    pub fn slot(self: *Store, index: usize) *?Stack {
        return &self.items[index];
    }

    pub fn isEmpty(self: Store) bool {
        for (self.items) |maybe_stack| {
            if (maybe_stack != null) return false;
        }
        return true;
    }
};

pub fn store(gpa: std.mem.Allocator, pos: BlockPos, state: Store) !nbt.Tag {
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
    state: Store,
};

pub fn isContainer(compound: nbt.Compound) bool {
    return tile.isKind(compound, id_key);
}

pub fn load(compound: nbt.Compound) ?Placed {
    if (!isContainer(compound)) return null;

    var state: Store = .{};
    tile.loadItems(compound, &state.items);

    return .{
        .pos = tile.position(compound) orelse return null,
        .state = state,
    };
}

test "a mod container holds six rows of slots at the most" {
    var state: Store = .{};
    try std.testing.expect(state.isEmpty());

    state.slot(max_slots - 1).* = .{ .id = .{ .block = .stone }, .count = 64 };
    try std.testing.expect(!state.isEmpty());
    try std.testing.expectEqual(@as(usize, 54), state.items.len);
}

test "a mod container survives a round trip through its tile entity compound" {
    const gpa = std.testing.allocator;

    var original: Store = .{};
    original.slot(0).* = .{ .id = .{ .block = .planks }, .count = 32 };
    original.slot(53).* = .{ .id = .{ .item = .diamond }, .count = 5 };

    var tag = try store(gpa, .init(7, 65, -3), original);
    defer nbt.deinit(gpa, &tag);

    const placed = load(tag.compound).?;
    try std.testing.expectEqual(BlockPos.init(7, 65, -3), placed.pos);
    try std.testing.expectEqual(original, placed.state);
}
