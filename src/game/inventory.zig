const std = @import("std");

pub const ItemStack = struct {
    id: u16,
    count: u8,
    meta: u4 = 0,
};

pub const max_stack_size: u8 = 64;
pub const hotbar_size: u4 = 9;
pub const size: usize = 36;

const Inventory = @This();

slots: [size]?ItemStack = @splat(null),
selected: u4 = 0,

pub fn selectedStack(self: Inventory) ?ItemStack {
    return self.slots[self.selected];
}

pub fn selectHotbar(self: *Inventory, index: u8) void {
    if (index < hotbar_size) self.selected = @intCast(index);
}

pub fn cycleHotbar(self: *Inventory, delta: i32) void {
    const step: i32 = if (delta > 0) 1 else if (delta < 0) -1 else 0;
    const wrapped = @mod(@as(i32, self.selected) - step, @as(i32, hotbar_size));
    self.selected = @intCast(wrapped);
}

fn firstEmptySlot(self: Inventory) ?usize {
    for (self.slots, 0..) |slot, i| {
        if (slot == null) return i;
    }
    return null;
}

fn matchingSlot(self: Inventory, id: u16, meta: u4) ?usize {
    for (self.slots, 0..) |slot, i| {
        if (slot) |s| {
            if (s.id == id and s.meta == meta and s.count < max_stack_size) return i;
        }
    }
    return null;
}

pub fn addStack(self: *Inventory, stack: ItemStack) u8 {
    var remaining = stack.count;

    while (remaining > 0) {
        const slot_index = self.matchingSlot(stack.id, stack.meta) orelse self.firstEmptySlot() orelse break;
        const slot = &self.slots[slot_index];
        const existing: u8 = if (slot.*) |s| s.count else 0;
        const room = max_stack_size - existing;
        const added = @min(room, remaining);
        slot.* = .{ .id = stack.id, .count = existing + added, .meta = stack.meta };
        remaining -= added;
    }

    return remaining;
}

test "addStack fills a single slot below the stack limit" {
    var inv: Inventory = .{};
    const leftover = inv.addStack(.{ .id = 1, .count = 10 });
    try std.testing.expectEqual(@as(u8, 0), leftover);
    try std.testing.expectEqual(@as(u8, 10), inv.slots[0].?.count);
}

test "addStack tops up a matching slot before using a new one" {
    var inv: Inventory = .{};
    inv.slots[0] = .{ .id = 1, .count = 60 };
    const leftover = inv.addStack(.{ .id = 1, .count = 10 });
    try std.testing.expectEqual(@as(u8, 0), leftover);
    try std.testing.expectEqual(@as(u8, 64), inv.slots[0].?.count);
    try std.testing.expectEqual(@as(u8, 6), inv.slots[1].?.count);
}

test "addStack does not merge stacks with different metadata" {
    var inv: Inventory = .{};
    inv.slots[0] = .{ .id = 17, .count = 10, .meta = 0 };
    _ = inv.addStack(.{ .id = 17, .count = 5, .meta = 1 });
    try std.testing.expectEqual(@as(u8, 10), inv.slots[0].?.count);
    try std.testing.expectEqual(@as(u8, 5), inv.slots[1].?.count);
    try std.testing.expectEqual(@as(u4, 1), inv.slots[1].?.meta);
}

test "addStack splits a stack larger than the limit across slots" {
    var inv: Inventory = .{};
    const leftover = inv.addStack(.{ .id = 1, .count = 100 });
    try std.testing.expectEqual(@as(u8, 0), leftover);
    try std.testing.expectEqual(@as(u8, 64), inv.slots[0].?.count);
    try std.testing.expectEqual(@as(u8, 36), inv.slots[1].?.count);
}

test "addStack returns the leftover once the inventory is full" {
    var inv: Inventory = .{};
    for (0..size) |i| inv.slots[i] = .{ .id = 1, .count = max_stack_size };
    const leftover = inv.addStack(.{ .id = 1, .count = 5 });
    try std.testing.expectEqual(@as(u8, 5), leftover);
}

test "selectHotbar ignores indices outside the hotbar" {
    var inv: Inventory = .{};
    inv.selectHotbar(5);
    try std.testing.expectEqual(@as(u4, 5), inv.selected);
    inv.selectHotbar(20);
    try std.testing.expectEqual(@as(u4, 5), inv.selected);
}

test "cycleHotbar wraps around both ends" {
    var inv: Inventory = .{};
    inv.selected = 0;
    inv.cycleHotbar(1);
    try std.testing.expectEqual(@as(u4, 8), inv.selected);
    inv.selected = 8;
    inv.cycleHotbar(-1);
    try std.testing.expectEqual(@as(u4, 0), inv.selected);
}

test "selectedStack reflects the currently selected hotbar slot" {
    var inv: Inventory = .{};
    inv.slots[3] = .{ .id = 4, .count = 1 };
    inv.selectHotbar(3);
    try std.testing.expectEqual(@as(u8, 4), inv.selectedStack().?.id);
}
