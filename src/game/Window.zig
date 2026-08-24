const std = @import("std");

const world = @import("world");

const crafting = @import("crafting.zig");
const Inventory = @import("Inventory.zig");
pub const player_slot_count: usize = Inventory.size;

const Window = @This();

pub const Kind = enum { plain, armor, craft_input, craft_result, output, chest };

pub const Slot = struct {
    stack: ?*?world.Stack = null,
    kind: Kind = .plain,
    armor: ?world.item.ArmorSlot = null,
};

pub const max_slots: usize = 90;
pub const outside_slot: i16 = -999;
pub const crafting_grid: usize = 4;
pub const crafting_side: u8 = 2;
pub const workbench_grid: usize = 9;
pub const workbench_side: u8 = 3;
slots: [max_slots]Slot = @splat(.{}),
count: usize = 0,
grid: []?world.Stack = &.{},
grid_side: u8 = 0,
store_count: usize = 0,
minted_map: ?u16 = null,

pub fn add(self: *Window, slot: Slot) void {
    if (self.count >= max_slots) return;
    self.slots[self.count] = slot;
    self.count += 1;
}

pub fn addPlayer(self: *Window, inventory: *Inventory) void {
    var index: usize = Inventory.hotbar_size;
    while (index < Inventory.size) : (index += 1) {
        self.add(.{ .stack = &inventory.slots[index] });
    }
    index = 0;
    while (index < Inventory.hotbar_size) : (index += 1) {
        self.add(.{ .stack = &inventory.slots[index] });
    }
}

pub fn playerStart(self: *const Window) usize {
    return self.count - player_slot_count;
}

pub fn hotbarStart(self: *const Window) usize {
    return self.count - Inventory.hotbar_size;
}

pub fn stackAt(self: *const Window, index: usize) ?world.Stack {
    if (index >= self.count) return null;
    const slot = self.slots[index];
    if (slot.kind == .craft_result) {
        if (self.grid.len == 0) return null;
        return crafting.findMatch(self.grid, self.grid_side);
    }
    const held = slot.stack orelse return null;
    return held.*;
}

pub fn addStore(self: *Window, slots: []?world.Stack, kind: Kind) void {
    for (slots) |*slot| self.add(.{ .stack = slot, .kind = kind });
    self.store_count = self.count;
}

pub fn addGrid(self: *Window, grid: []?world.Stack, side: u8) void {
    self.grid = grid;
    self.grid_side = side;
    self.add(.{ .kind = .craft_result });
    for (grid) |*slot| self.add(.{ .stack = slot, .kind = .craft_input });
}

fn accepts(slot: Slot, stack: world.Stack) bool {
    const piece = slot.armor orelse return true;
    return Inventory.fitsArmorSlot(stack, piece);
}

fn limitOf(slot: Slot, stack: world.Stack) u8 {
    if (slot.armor != null) return 1;
    return stack.id.maxStackSize();
}

pub const Click = enum { left, right };

pub const Outcome = struct {
    thrown: ?world.Stack = null,
    crafted: ?world.Stack = null,
    smelted: ?world.Stack = null,
};

pub fn throwCarried(button: Click, carried: *?world.Stack) ?world.Stack {
    const held = carried.* orelse return null;
    const drop_count = if (button == .left) held.count else 1;
    const kept = held.count - drop_count;
    carried.* = if (kept == 0) null else .{ .id = held.id, .count = kept, .meta = held.meta };
    return .{ .id = held.id, .count = drop_count, .meta = held.meta };
}

pub fn click(
    self: *Window,
    index: i16,
    button: Click,
    shift: bool,
    carried: *?world.Stack,
) Outcome {
    if (index == outside_slot) return .{ .thrown = throwCarried(button, carried) };

    if (index < 0 or index >= self.count) return .{};
    const at: usize = @intCast(index);

    if (shift) return self.quickMove(at);

    switch (self.slots[at].kind) {
        .craft_result => return .{ .crafted = self.takeResult(carried) },
        .output => return .{ .smelted = self.takeOutput(at, button, carried) },
        else => self.plainClick(at, button, carried),
    }
    return .{};
}

fn takeOutput(self: *Window, at: usize, button: Click, carried: *?world.Stack) ?world.Stack {
    const storage = self.slots[at].stack orelse return null;
    return takeInto(storage, button, carried);
}

pub fn takeInto(storage: *?world.Stack, button: Click, carried: *?world.Stack) ?world.Stack {
    const ready = storage.* orelse return null;
    const taken = if (button == .left) ready.count else (ready.count + 1) / 2;

    if (carried.*) |*held| {
        if (!held.id.eql(ready.id) or held.meta != ready.meta) return null;
        if (@as(u16, held.count) + taken > ready.id.maxStackSize()) return null;
        held.count += taken;
    } else {
        carried.* = .{ .id = ready.id, .count = taken, .meta = ready.meta };
    }

    storage.*.?.count -= taken;
    if (storage.*.?.count == 0) storage.* = null;
    return .{ .id = ready.id, .count = taken, .meta = ready.meta };
}

fn plainClick(self: *Window, at: usize, button: Click, carried: *?world.Stack) void {
    clickSlot(self.slots[at], button, carried);
}

pub fn clickSlot(slot: Slot, button: Click, carried: *?world.Stack) void {
    const storage = slot.stack orelse return;

    if (storage.*) |*existing| {
        if (carried.*) |*held| {
            if (existing.id.eql(held.id) and existing.meta == held.meta) {
                const room = limitOf(slot, existing.*) -| existing.count;
                const amount = @min(if (button == .left) held.count else 1, room);
                existing.count += amount;
                held.count -= amount;
                if (held.count == 0) carried.* = null;
                return;
            }
            if (!accepts(slot, held.*)) return;
            const swapped = existing.*;
            storage.* = held.*;
            carried.* = swapped;
            return;
        }
        const amount = if (button == .left) existing.count else (existing.count + 1) / 2;
        carried.* = .{ .id = existing.id, .count = amount, .meta = existing.meta };
        existing.count -= amount;
        if (existing.count == 0) storage.* = null;
        return;
    }

    const held = &(carried.* orelse return);
    if (!accepts(slot, held.*)) return;
    const amount = @min(if (button == .left) held.count else 1, limitOf(slot, held.*));
    storage.* = .{ .id = held.id, .count = amount, .meta = held.meta };
    held.count -= amount;
    carried.* = if (held.count == 0) null else held.*;
}

fn stampMinted(self: *Window, result: *world.Stack) void {
    const meta = self.minted_map orelse return;
    if (!result.id.eql(.{ .item = .map })) return;
    result.meta = meta;
}

fn takeResult(self: *Window, carried: *?world.Stack) ?world.Stack {
    var result = crafting.findMatch(self.grid, self.grid_side) orelse return null;
    self.stampMinted(&result);
    if (carried.*) |*held| {
        if (!held.id.eql(result.id) or held.meta != result.meta) return null;
        if (@as(u16, held.count) + result.count > result.id.maxStackSize()) return null;
        held.count += result.count;
    } else {
        carried.* = result;
    }
    crafting.consume(self.grid);
    return result;
}

const Range = struct { start: usize, end: usize, reverse: bool };

fn quickRange(self: *const Window, from: usize) Range {
    const player_start = self.playerStart();
    const hotbar_start = self.hotbarStart();

    if (from < player_start) {
        const reverse = switch (self.slots[from].kind) {
            .craft_result, .output, .chest => true,
            else => false,
        };
        return .{ .start = player_start, .end = self.count, .reverse = reverse };
    }

    if (self.store_count > 0) return .{ .start = 0, .end = self.store_count, .reverse = false };

    if (from < hotbar_start) return .{ .start = hotbar_start, .end = self.count, .reverse = false };
    return .{ .start = player_start, .end = hotbar_start, .reverse = false };
}

fn quickMove(self: *Window, from: usize) Outcome {
    const range = self.quickRange(from);

    var targets: [max_slots]*?world.Stack = undefined;
    var count: usize = 0;
    for (0..range.end - range.start) |step| {
        const index = if (range.reverse) range.end - 1 - step else range.start + step;
        targets[count] = self.slots[index].stack orelse continue;
        count += 1;
    }

    if (self.slots[from].kind == .craft_result) {
        var result = crafting.findMatch(self.grid, self.grid_side) orelse return .{};
        self.stampMinted(&result);
        var moving = result;
        Inventory.mergeStack(targets[0..count], &moving);
        if (moving.count == result.count) return .{};
        crafting.consume(self.grid);
        return .{ .crafted = .{
            .id = result.id,
            .count = result.count - moving.count,
            .meta = result.meta,
        } };
    }

    const source = self.slots[from].stack orelse return .{};
    var moving = source.* orelse return .{};
    const before = moving.count;
    Inventory.mergeStack(targets[0..count], &moving);
    source.* = if (moving.count == 0) null else moving;

    if (self.slots[from].kind != .output or moving.count == before) return .{};
    return .{ .smelted = .{ .id = moving.id, .count = before - moving.count, .meta = moving.meta } };
}

test "the player window lays its slots out the way vanilla numbers them" {
    var inventory: Inventory = .{};
    var grid: [crafting_grid]?world.Stack = @splat(null);

    inventory.slots[0] = .{ .id = .{ .block = .stone }, .count = 5 };
    inventory.slots[9] = .{ .id = .{ .block = .dirt }, .count = 7 };
    inventory.armor[0] = .{ .id = .{ .item = .helmet_iron }, .count = 1 };

    var window: Window = .{ .grid = &grid, .grid_side = crafting_side };
    window.add(.{ .kind = .craft_result });
    for (0..crafting_grid) |slot| window.add(.{ .stack = &grid[slot], .kind = .craft_input });
    for (0..Inventory.armor_size) |piece| {
        window.add(.{ .stack = &inventory.armor[piece], .kind = .armor, .armor = @enumFromInt(piece) });
    }
    window.addPlayer(&inventory);

    try std.testing.expectEqual(@as(usize, 45), window.count);
    try std.testing.expectEqual(@as(usize, 9), window.playerStart());
    try std.testing.expect(window.stackAt(5).?.id.eql(.{ .item = .helmet_iron }));
    try std.testing.expect(window.stackAt(9).?.id.eql(.{ .block = .dirt }));
    try std.testing.expect(window.stackAt(36).?.id.eql(.{ .block = .stone }));
}

test "picking a stack up and putting it back down goes through the carried slot" {
    var inventory: Inventory = .{};
    var grid: [crafting_grid]?world.Stack = @splat(null);
    inventory.slots[0] = .{ .id = .{ .block = .stone }, .count = 5 };

    var window: Window = .{ .grid = &grid, .grid_side = crafting_side };
    window.add(.{ .kind = .craft_result });
    for (0..crafting_grid) |slot| window.add(.{ .stack = &grid[slot], .kind = .craft_input });
    for (0..Inventory.armor_size) |piece| {
        window.add(.{ .stack = &inventory.armor[piece], .kind = .armor, .armor = @enumFromInt(piece) });
    }
    window.addPlayer(&inventory);

    var carried: ?world.Stack = null;
    _ = window.click(36, .left, false, &carried);
    try std.testing.expectEqual(@as(u8, 5), carried.?.count);
    try std.testing.expect(inventory.slots[0] == null);

    _ = window.click(9, .left, false, &carried);
    try std.testing.expect(carried == null);
    try std.testing.expectEqual(@as(u8, 5), inventory.slots[9].?.count);
}

test "a helmet only goes in the helmet slot" {
    var inventory: Inventory = .{};
    var grid: [crafting_grid]?world.Stack = @splat(null);

    var window: Window = .{ .grid = &grid, .grid_side = crafting_side };
    window.add(.{ .kind = .craft_result });
    for (0..crafting_grid) |slot| window.add(.{ .stack = &grid[slot], .kind = .craft_input });
    for (0..Inventory.armor_size) |piece| {
        window.add(.{ .stack = &inventory.armor[piece], .kind = .armor, .armor = @enumFromInt(piece) });
    }
    window.addPlayer(&inventory);

    var carried: ?world.Stack = .{ .id = .{ .item = .helmet_iron }, .count = 1 };
    _ = window.click(6, .left, false, &carried);
    try std.testing.expect(carried != null);

    _ = window.click(5, .left, false, &carried);
    try std.testing.expect(carried == null);
    try std.testing.expect(inventory.armor[0].?.id.eql(.{ .item = .helmet_iron }));
}

test "throwing a stack out of the window hands it back to be dropped" {
    var inventory: Inventory = .{};
    var grid: [crafting_grid]?world.Stack = @splat(null);

    var window: Window = .{ .grid = &grid, .grid_side = crafting_side };
    window.addPlayer(&inventory);

    var carried: ?world.Stack = .{ .id = .{ .block = .sand }, .count = 3 };
    const thrown = window.click(outside_slot, .right, false, &carried).thrown.?;

    try std.testing.expectEqual(@as(u8, 1), thrown.count);
    try std.testing.expectEqual(@as(u8, 2), carried.?.count);
}
