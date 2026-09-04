const std = @import("std");

const block = @import("block.zig");
const Stack = block.Stack;
const BlockPos = @import("BlockPos.zig");
const Item = @import("item.zig").Item;
const JavaRandom = @import("JavaRandom.zig");
const nbt = @import("nbt.zig");
const tile = @import("tile.zig");

pub const id_key = "Trap";
pub const stack_limit: u8 = 64;
pub const slot_count = 9;
pub const rows = 3;

pub const Dispenser = struct {
    items: [slot_count]?Stack = @splat(null),

    pub fn slot(self: *Dispenser, index: usize) *?Stack {
        return &self.items[index];
    }

    pub fn isEmpty(self: Dispenser) bool {
        for (self.items) |maybe_stack| {
            if (maybe_stack != null) return false;
        }
        return true;
    }

    pub fn takeRandomStack(self: *Dispenser, rand: *JavaRandom) ?Stack {
        var chosen: ?usize = null;
        var seen: i32 = 1;

        for (self.items, 0..) |maybe_stack, index| {
            if (maybe_stack == null) continue;
            const roll = rand.nextIntBound(seen);
            seen += 1;
            if (roll == 0) chosen = index;
        }

        const index = chosen orelse return null;
        const held = &self.items[index];
        var one = held.*.?;
        one.count = 1;
        if (held.*.?.count <= 1) held.* = null else held.*.?.count -= 1;
        return one;
    }
};

pub fn store(gpa: std.mem.Allocator, pos: BlockPos, state: Dispenser) !nbt.Tag {
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
    state: Dispenser,
};

pub fn isDispenser(compound: nbt.Compound) bool {
    return tile.isKind(compound, id_key);
}

pub fn load(compound: nbt.Compound) ?Placed {
    if (!isDispenser(compound)) return null;

    var state: Dispenser = .{};

    tile.loadItems(compound, &state.items);

    return .{
        .pos = tile.position(compound) orelse return null,
        .state = state,
    };
}

test "a dispenser holds the nine slots TileEntityDispenser reports" {
    var state: Dispenser = .{};
    try std.testing.expect(state.isEmpty());

    state.slot(8).* = .{ .id = .{ .block = .stone }, .count = 64 };
    try std.testing.expect(!state.isEmpty());
    try std.testing.expectEqual(@as(usize, 9), state.items.len);
}

test "an empty dispenser has nothing to hand out" {
    var rand = JavaRandom.init(0);
    var state: Dispenser = .{};
    try std.testing.expect(state.takeRandomStack(&rand) == null);
}

test "taking a stack peels one item off and empties the slot on the last one" {
    var rand = JavaRandom.init(0);
    var state: Dispenser = .{};
    state.slot(4).* = .{ .id = .{ .item = .arrow }, .count = 2, .meta = 7 };

    const first = state.takeRandomStack(&rand).?;
    try std.testing.expectEqual(Item.arrow, first.id.item);
    try std.testing.expectEqual(@as(u8, 1), first.count);
    try std.testing.expectEqual(@as(u16, 7), first.meta);
    try std.testing.expectEqual(@as(u8, 1), state.items[4].?.count);

    const second = state.takeRandomStack(&rand).?;
    try std.testing.expectEqual(@as(u8, 1), second.count);
    try std.testing.expect(state.items[4] == null);
    try std.testing.expect(state.isEmpty());
}

test "every filled slot is reachable and empty ones are never picked" {
    var state: Dispenser = .{};
    state.slot(0).* = .{ .id = .{ .block = .stone }, .count = 64 };
    state.slot(5).* = .{ .id = .{ .block = .dirt }, .count = 64 };
    state.slot(8).* = .{ .id = .{ .block = .sand }, .count = 64 };

    var seen = [_]bool{false} ** 3;
    for (0..64) |seed| {
        var rand = JavaRandom.init(@intCast(seed));
        var copy = state;
        const taken = copy.takeRandomStack(&rand).?;
        switch (taken.id.block) {
            .stone => seen[0] = true,
            .dirt => seen[1] = true,
            .sand => seen[2] = true,
            else => return error.TestUnexpectedResult,
        }
    }

    try std.testing.expect(seen[0] and seen[1] and seen[2]);
}

test "a dispenser survives a round trip through its tile entity compound" {
    const gpa = std.testing.allocator;
    var original: Dispenser = .{};
    original.slot(0).* = .{ .id = .{ .item = .arrow }, .count = 32 };
    original.slot(4).* = .{ .id = .{ .block = .cobblestone }, .count = 12 };
    original.slot(8).* = .{ .id = .{ .item = .pickaxe_iron }, .count = 1, .meta = 47 };

    var tag = try store(gpa, .init(-18, 40, 7), original);
    defer nbt.deinit(gpa, &tag);

    try std.testing.expectEqual(@as(usize, 3), tag.compound.get("Items").?.list.items.len);

    const loaded = load(tag.compound).?;
    try std.testing.expectEqual(BlockPos.init(-18, 40, 7), loaded.pos);
    try std.testing.expectEqual(original, loaded.state);
}

test "a tile entity of another kind is not read as a dispenser" {
    const gpa = std.testing.allocator;
    var tag = try store(gpa, .init(1, 2, 3), .{});
    defer nbt.deinit(gpa, &tag);

    const stored = tag.compound.getPtr("id").?;
    gpa.free(stored.string);
    stored.string = try gpa.dupe(u8, "Chest");

    try std.testing.expect(!isDispenser(tag.compound));
    try std.testing.expect(load(tag.compound) == null);
}
