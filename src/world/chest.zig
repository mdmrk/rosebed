const std = @import("std");

const block = @import("block.zig");
const Stack = block.Stack;
const BlockPos = @import("BlockPos.zig");
const nbt = @import("nbt.zig");

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

fn put(gpa: std.mem.Allocator, compound: *nbt.Compound, key: []const u8, tag: nbt.Tag) !void {
    try nbt.putDuped(gpa, compound, key, tag);
}

fn storedId(stack: Stack) i16 {
    return switch (stack.id) {
        .block => |id| @intCast(@intFromEnum(id)),
        .item => |id| @bitCast(@as(u16, @intFromEnum(id))),
    };
}

fn storeStack(gpa: std.mem.Allocator, index: u8, stack: Stack) !nbt.Tag {
    var compound: nbt.Compound = .{};
    errdefer {
        var owned: nbt.Tag = .{ .compound = compound };
        nbt.deinit(gpa, &owned);
    }

    try put(gpa, &compound, "Slot", .{ .byte = @bitCast(index) });
    try put(gpa, &compound, "id", .{ .short = storedId(stack) });
    try put(gpa, &compound, "Count", .{ .byte = @bitCast(stack.count) });
    try put(gpa, &compound, "Damage", .{ .short = @bitCast(stack.meta) });

    return .{ .compound = compound };
}

pub fn store(gpa: std.mem.Allocator, pos: BlockPos, state: Chest) !nbt.Tag {
    var compound: nbt.Compound = .{};
    errdefer {
        var owned: nbt.Tag = .{ .compound = compound };
        nbt.deinit(gpa, &owned);
    }

    try put(gpa, &compound, "id", .{ .string = try gpa.dupe(u8, id_key) });
    try put(gpa, &compound, "x", .{ .int = pos.x });
    try put(gpa, &compound, "y", .{ .int = pos.y });
    try put(gpa, &compound, "z", .{ .int = pos.z });

    var items: std.ArrayList(nbt.Tag) = .empty;
    errdefer {
        for (items.items) |*tag| nbt.deinit(gpa, tag);
        items.deinit(gpa);
    }
    for (state.items, 0..) |maybe_stack, index| {
        const stack = maybe_stack orelse continue;
        try items.append(gpa, try storeStack(gpa, @intCast(index), stack));
    }

    try put(gpa, &compound, "Items", .{
        .list = .{ .element_type = .compound, .items = try items.toOwnedSlice(gpa) },
    });

    return .{ .compound = compound };
}

fn loadStack(compound: nbt.Compound) ?Stack {
    const raw: u16 = @bitCast(nbt.shortField(compound, "id"));
    const count = switch (compound.get("Count") orelse return null) {
        .byte => |value| @as(u8, @bitCast(value)),
        else => return null,
    };
    if (count == 0) return null;

    const id: block.Id = if (raw < 256)
        .{ .block = @enumFromInt(@as(u8, @intCast(raw))) }
    else
        .{ .item = @enumFromInt(raw) };
    return .{ .id = id, .count = count, .meta = @bitCast(nbt.shortField(compound, "Damage")) };
}

pub const Placed = struct {
    pos: BlockPos,
    state: Chest,
};

pub fn isChest(compound: nbt.Compound) bool {
    return switch (compound.get("id") orelse return false) {
        .string => |value| std.mem.eql(u8, value, id_key),
        else => false,
    };
}

pub fn load(compound: nbt.Compound) ?Placed {
    if (!isChest(compound)) return null;

    var state: Chest = .{};

    if (compound.get("Items")) |tag| switch (tag) {
        .list => |list| for (list.items) |entry| switch (entry) {
            .compound => |slot_compound| {
                const index = switch (slot_compound.get("Slot") orelse continue) {
                    .byte => |value| @as(u8, @bitCast(value)),
                    else => continue,
                };
                if (index >= slot_count) continue;
                state.slot(index).* = loadStack(slot_compound);
            },
            else => {},
        },
        else => {},
    };

    return .{
        .pos = .{
            .x = nbt.intField(compound, "x") orelse return null,
            .y = nbt.intField(compound, "y") orelse return null,
            .z = nbt.intField(compound, "z") orelse return null,
        },
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
