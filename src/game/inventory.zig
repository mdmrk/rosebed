const std = @import("std");

const world = @import("world");
pub const ItemStack = world.Stack;

pub const max_stack_size: u8 = 64;
pub const hotbar_size: u4 = 9;
pub const size: usize = 36;
pub const armor_size: usize = 4;

const Inventory = @This();

slots: [size]?ItemStack = @splat(null),
armor: [armor_size]?ItemStack = @splat(null),
selected: u4 = 0,

pub fn selectedStack(self: Inventory) ?ItemStack {
    return self.slots[self.selected];
}

pub fn armorSlot(self: *Inventory, slot: world.item.ArmorSlot) *?ItemStack {
    return &self.armor[@intFromEnum(slot)];
}

pub fn fitsArmorSlot(stack: ItemStack, slot: world.item.ArmorSlot) bool {
    return switch (stack.id) {
        .block => |id| id == .pumpkin and slot == .helmet,
        .item => |id| if (id.armor()) |a| a.slot == slot else false,
    };
}

pub fn totalArmorValue(self: Inventory) i32 {
    var protection: i32 = 0;
    var remaining: i32 = 0;
    var capacity: i32 = 0;

    for (self.armor) |maybe_stack| {
        const stack = maybe_stack orelse continue;
        const piece = switch (stack.id) {
            .item => |id| id.armor() orelse continue,
            .block => continue,
        };
        const max: i32 = piece.maxDamage();
        remaining += max - @as(i32, stack.meta);
        capacity += max;
        protection += piece.damageReduction();
    }

    if (capacity == 0) return 0;
    return @divTrunc((protection - 1) * remaining, capacity) + 1;
}

pub fn damageArmor(self: *Inventory, amount: u16) void {
    for (&self.armor) |*slot| {
        if (slot.*) |*stack| {
            if (stack.id != .item or stack.id.item.armor() == null) continue;
            stack.damage(amount);
            if (stack.count == 0) slot.* = null;
        }
    }
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

fn matchingSlot(self: Inventory, id: world.Id, meta: u16, limit: u8) ?usize {
    for (self.slots, 0..) |slot, i| {
        if (slot) |s| {
            if (s.id.eql(id) and s.meta == meta and s.count < limit) return i;
        }
    }
    return null;
}

pub fn addStack(self: *Inventory, stack: ItemStack) u8 {
    var remaining = stack.count;
    const limit = stack.id.maxStackSize();

    while (remaining > 0) {
        const slot_index = self.matchingSlot(stack.id, stack.meta, limit) orelse self.firstEmptySlot() orelse break;
        const slot = &self.slots[slot_index];
        const existing: u8 = if (slot.*) |s| s.count else 0;
        const room = limit - existing;
        const added = @min(room, remaining);
        slot.* = .{ .id = stack.id, .count = existing + added, .meta = stack.meta };
        remaining -= added;
    }

    return remaining;
}

test "consuming an item takes one from the first slot holding it" {
    var inv: Inventory = .{};
    inv.slots[2] = .{ .id = .{ .item = .arrow }, .count = 3 };
    inv.slots[5] = .{ .id = .{ .item = .arrow }, .count = 1 };

    try std.testing.expect(inv.consumeItem(.{ .item = .arrow }));
    try std.testing.expectEqual(@as(u8, 2), inv.slots[2].?.count);
    try std.testing.expectEqual(@as(u8, 1), inv.slots[5].?.count);
}

test "the slot holding the last of an item is emptied, not left at zero" {
    var inv: Inventory = .{};
    inv.slots[0] = .{ .id = .{ .item = .arrow }, .count = 1 };

    try std.testing.expect(inv.consumeItem(.{ .item = .arrow }));
    try std.testing.expect(inv.slots[0] == null);
    try std.testing.expect(!inv.consumeItem(.{ .item = .arrow }));
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
    try std.testing.expectEqual(@as(u16, 1), inv.slots[1].?.meta);
}

test "tools never stack, so each one opens a slot of its own" {
    var inv: Inventory = .{};
    const pickaxe: ItemStack = .{ .id = .{ .item = .pickaxe_iron }, .count = 1 };
    try std.testing.expectEqual(@as(u8, 0), inv.addStack(pickaxe));
    try std.testing.expectEqual(@as(u8, 0), inv.addStack(pickaxe));
    try std.testing.expectEqual(@as(u8, 1), inv.slots[0].?.count);
    try std.testing.expectEqual(@as(u8, 1), inv.slots[1].?.count);
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

const armor_save_base: u8 = 100;

fn armorSaveSlot(index: usize) u8 {
    return armor_save_base + @as(u8, @intCast(armor_size - 1 - index));
}

pub fn consumeItem(self: *Inventory, id: world.Id) bool {
    for (&self.slots) |*slot| {
        const stack = slot.* orelse continue;
        if (!std.meta.eql(stack.id, id)) continue;

        if (stack.count <= 1) {
            slot.* = null;
        } else {
            slot.*.?.count = stack.count - 1;
        }
        return true;
    }
    return false;
}

pub fn saveEntry(slot: u8, stack: ItemStack) world.save.InventoryEntry {
    return .{ .slot = slot, .id = stack.id.numeric(), .count = stack.count, .damage = @bitCast(stack.meta) };
}

pub fn stackFromEntry(entry: world.save.InventoryEntry) ?ItemStack {
    if (entry.count == 0) return null;
    return .{ .id = world.Id.fromNumeric(entry.id), .count = entry.count, .meta = @bitCast(entry.damage) };
}

pub fn appendSaveEntries(self: Inventory, gpa: std.mem.Allocator, entries: *std.ArrayList(world.save.InventoryEntry)) !void {
    for (self.slots, 0..) |slot, i| {
        if (slot) |stack| try entries.append(gpa, saveEntry(@intCast(i), stack));
    }
    for (self.armor, 0..) |slot, i| {
        if (slot) |stack| try entries.append(gpa, saveEntry(armorSaveSlot(i), stack));
    }
}

pub fn loadSaveEntries(self: *Inventory, entries: []const world.save.InventoryEntry) void {
    self.slots = @splat(null);
    self.armor = @splat(null);
    for (entries) |entry| {
        if (entry.slot >= armor_save_base) {
            const index = entry.slot - armor_save_base;
            if (index >= armor_size) continue;
            self.armor[armor_size - 1 - index] = stackFromEntry(entry);
            continue;
        }
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

test "worn armour round-trips through the original's 100-and-up slot numbering" {
    var inv: Inventory = .{};
    inv.armor[@intFromEnum(world.item.ArmorSlot.helmet)] = .{ .id = .{ .item = .helmet_iron }, .count = 1, .meta = 40 };
    inv.armor[@intFromEnum(world.item.ArmorSlot.boots)] = .{ .id = .{ .item = .boots_diamond }, .count = 1 };

    var entries: std.ArrayList(world.save.InventoryEntry) = .empty;
    defer entries.deinit(std.testing.allocator);
    try inv.appendSaveEntries(std.testing.allocator, &entries);

    try std.testing.expectEqual(@as(u8, 103), entries.items[0].slot);
    try std.testing.expectEqual(@as(u8, 100), entries.items[1].slot);
    try std.testing.expectEqual(@as(i16, 40), entries.items[0].damage);

    var restored: Inventory = .{};
    restored.loadSaveEntries(entries.items);
    try std.testing.expectEqual(inv.armor, restored.armor);
}

test "the armour value scales the worn protection by the durability left" {
    var inv: Inventory = .{};
    try std.testing.expectEqual(@as(i32, 0), inv.totalArmorValue());

    inv.armor[@intFromEnum(world.item.ArmorSlot.chestplate)] = .{ .id = .{ .item = .chestplate_iron }, .count = 1 };
    try std.testing.expectEqual(@as(i32, 8), inv.totalArmorValue());

    inv.armor[@intFromEnum(world.item.ArmorSlot.chestplate)].?.meta = 96;
    try std.testing.expectEqual(@as(i32, 4), inv.totalArmorValue());
}

test "damaging armour wears every worn piece and drops one that runs out" {
    var inv: Inventory = .{};
    inv.armor[@intFromEnum(world.item.ArmorSlot.helmet)] = .{ .id = .{ .item = .helmet_leather }, .count = 1, .meta = 33 };
    inv.armor[@intFromEnum(world.item.ArmorSlot.boots)] = .{ .id = .{ .item = .boots_leather }, .count = 1 };

    inv.damageArmor(1);
    try std.testing.expectEqual(@as(?ItemStack, null), inv.armor[@intFromEnum(world.item.ArmorSlot.helmet)]);
    try std.testing.expectEqual(@as(u16, 1), inv.armor[@intFromEnum(world.item.ArmorSlot.boots)].?.meta);
}

test "an armour slot only takes its own piece, plus a pumpkin on the head" {
    try std.testing.expect(fitsArmorSlot(.{ .id = .{ .item = .boots_gold }, .count = 1 }, .boots));
    try std.testing.expect(!fitsArmorSlot(.{ .id = .{ .item = .boots_gold }, .count = 1 }, .helmet));
    try std.testing.expect(fitsArmorSlot(.{ .id = .{ .block = .pumpkin }, .count = 1 }, .helmet));
    try std.testing.expect(!fitsArmorSlot(.{ .id = .{ .block = .pumpkin }, .count = 1 }, .chestplate));
    try std.testing.expect(!fitsArmorSlot(.{ .id = .{ .item = .pickaxe_iron }, .count = 1 }, .helmet));
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
