const std = @import("std");
const world = @import("world");

pub const ItemStack = world.Stack;

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

fn matchingSlot(self: Inventory, id: world.Id, meta: u4) ?usize {
    for (self.slots, 0..) |slot, i| {
        if (slot) |s| {
            if (s.id.eql(id) and s.meta == meta and s.count < max_stack_size) return i;
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
    const leftover = inv.addStack(.{ .id = .{ .block = @enumFromInt(1) }, .count = 10 });
    try std.testing.expectEqual(@as(u8, 0), leftover);
    try std.testing.expectEqual(@as(u8, 10), inv.slots[0].?.count);
}

test "addStack tops up a matching slot before using a new one" {
    var inv: Inventory = .{};
    inv.slots[0] = .{ .id = .{ .block = @enumFromInt(1) }, .count = 60 };
    const leftover = inv.addStack(.{ .id = .{ .block = @enumFromInt(1) }, .count = 10 });
    try std.testing.expectEqual(@as(u8, 0), leftover);
    try std.testing.expectEqual(@as(u8, 64), inv.slots[0].?.count);
    try std.testing.expectEqual(@as(u8, 6), inv.slots[1].?.count);
}

test "addStack does not merge stacks with different metadata" {
    var inv: Inventory = .{};
    inv.slots[0] = .{ .id = .{ .block = @enumFromInt(17) }, .count = 10, .meta = 0 };
    _ = inv.addStack(.{ .id = .{ .block = @enumFromInt(17) }, .count = 5, .meta = 1 });
    try std.testing.expectEqual(@as(u8, 10), inv.slots[0].?.count);
    try std.testing.expectEqual(@as(u8, 5), inv.slots[1].?.count);
    try std.testing.expectEqual(@as(u4, 1), inv.slots[1].?.meta);
}

test "addStack splits a stack larger than the limit across slots" {
    var inv: Inventory = .{};
    const leftover = inv.addStack(.{ .id = .{ .block = @enumFromInt(1) }, .count = 100 });
    try std.testing.expectEqual(@as(u8, 0), leftover);
    try std.testing.expectEqual(@as(u8, 64), inv.slots[0].?.count);
    try std.testing.expectEqual(@as(u8, 36), inv.slots[1].?.count);
}

test "addStack returns the leftover once the inventory is full" {
    var inv: Inventory = .{};
    for (0..size) |i| inv.slots[i] = .{ .id = .{ .block = @enumFromInt(1) }, .count = max_stack_size };
    const leftover = inv.addStack(.{ .id = .{ .block = @enumFromInt(1) }, .count = 5 });
    try std.testing.expectEqual(@as(u8, 5), leftover);
}

pub fn saveEntry(slot: usize, stack: ItemStack) world.save.InventoryEntry {
    const id: i16 = switch (stack.id) {
        .block => |b| @intCast(@intFromEnum(b)),
        .item => |i| @bitCast(@as(u16, @intFromEnum(i))),
    };
    return .{ .slot = @intCast(slot), .id = id, .count = stack.count, .damage = stack.meta };
}

pub fn stackFromEntry(entry: world.save.InventoryEntry) ?ItemStack {
    if (entry.count == 0) return null;
    const raw: u16 = @bitCast(entry.id);
    const id: world.Id = if (raw < 256)
        .{ .block = @enumFromInt(@as(u8, @intCast(raw))) }
    else
        .{ .item = @enumFromInt(raw) };
    return .{ .id = id, .count = entry.count, .meta = @truncate(@as(u16, @bitCast(entry.damage))) };
}

pub fn appendSaveEntries(self: Inventory, gpa: std.mem.Allocator, entries: *std.ArrayList(world.save.InventoryEntry)) !void {
    for (self.slots, 0..) |slot, i| {
        if (slot) |stack| try entries.append(gpa, saveEntry(i, stack));
    }
}

pub fn loadSaveEntries(self: *Inventory, entries: []const world.save.InventoryEntry) void {
    self.slots = @splat(null);
    for (entries) |entry| {
        if (entry.slot >= self.slots.len) continue;
        self.slots[entry.slot] = stackFromEntry(entry);
    }
}

test "an inventory round-trips through the save format" {
    var inv: Inventory = .{};
    inv.slots[0] = .{ .id = .{ .block = .stone }, .count = 64 };
    inv.slots[4] = .{ .id = .{ .block = .log }, .count = 12, .meta = 2 };
    inv.slots[9] = .{ .id = .{ .item = .diamond }, .count = 3 };

    var entries: std.ArrayList(world.save.InventoryEntry) = .empty;
    defer entries.deinit(std.testing.allocator);
    try inv.appendSaveEntries(std.testing.allocator, &entries);
    try std.testing.expectEqual(@as(usize, 3), entries.items.len);

    var restored: Inventory = .{};
    restored.loadSaveEntries(entries.items);
    try std.testing.expectEqual(inv.slots[0], restored.slots[0]);
    try std.testing.expectEqual(inv.slots[4], restored.slots[4]);
    try std.testing.expectEqual(inv.slots[9], restored.slots[9]);
    try std.testing.expectEqual(@as(?ItemStack, null), restored.slots[1]);
}

test "block ids stay under 256 and item ids above it" {
    try std.testing.expectEqual(@as(i16, 1), saveEntry(0, .{ .id = .{ .block = .stone }, .count = 1 }).id);
    try std.testing.expectEqual(@as(i16, 264), saveEntry(0, .{ .id = .{ .item = .diamond }, .count = 1 }).id);
    try std.testing.expectEqual(world.Id{ .block = .stone }, stackFromEntry(.{ .slot = 0, .id = 1, .count = 1 }).?.id);
    try std.testing.expectEqual(world.Id{ .item = .diamond }, stackFromEntry(.{ .slot = 0, .id = 264, .count = 1 }).?.id);
}

test "an empty stack in a save slot loads as nothing" {
    try std.testing.expectEqual(@as(?ItemStack, null), stackFromEntry(.{ .slot = 3, .id = 1, .count = 0 }));
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
    inv.slots[3] = .{ .id = .{ .block = .cobblestone }, .count = 1 };
    inv.selectHotbar(3);
    try std.testing.expectEqual(world.Id{ .block = .cobblestone }, inv.selectedStack().?.id);
}
