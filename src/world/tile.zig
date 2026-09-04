const std = @import("std");

const block = @import("block.zig");
const Stack = block.Stack;
const BlockPos = @import("BlockPos.zig");
const nbt = @import("nbt.zig");

pub fn header(gpa: std.mem.Allocator, compound: *nbt.Compound, id_key: []const u8, pos: BlockPos) !void {
    try nbt.putDuped(gpa, compound, "id", .{ .string = try gpa.dupe(u8, id_key) });
    try nbt.putDuped(gpa, compound, "x", .{ .int = pos.x });
    try nbt.putDuped(gpa, compound, "y", .{ .int = pos.y });
    try nbt.putDuped(gpa, compound, "z", .{ .int = pos.z });
}

pub fn isKind(compound: nbt.Compound, id_key: []const u8) bool {
    return switch (compound.get("id") orelse return false) {
        .string => |value| std.mem.eql(u8, value, id_key),
        else => false,
    };
}

pub fn position(compound: nbt.Compound) ?BlockPos {
    return .{
        .x = nbt.intField(compound, "x") orelse return null,
        .y = nbt.intField(compound, "y") orelse return null,
        .z = nbt.intField(compound, "z") orelse return null,
    };
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

    try nbt.putDuped(gpa, &compound, "Slot", .{ .byte = @bitCast(index) });
    try nbt.putDuped(gpa, &compound, "id", .{ .short = storedId(stack) });
    try nbt.putDuped(gpa, &compound, "Count", .{ .byte = @bitCast(stack.count) });
    try nbt.putDuped(gpa, &compound, "Damage", .{ .short = @bitCast(stack.meta) });

    return .{ .compound = compound };
}

pub fn storeItems(gpa: std.mem.Allocator, compound: *nbt.Compound, slots: []const ?Stack) !void {
    var items: std.ArrayList(nbt.Tag) = .empty;
    errdefer {
        for (items.items) |*tag| nbt.deinit(gpa, tag);
        items.deinit(gpa);
    }
    for (slots, 0..) |maybe_stack, index| {
        const stack = maybe_stack orelse continue;
        try items.append(gpa, try storeStack(gpa, @intCast(index), stack));
    }

    try nbt.putDuped(gpa, compound, "Items", .{
        .list = .{ .element_type = .compound, .items = try items.toOwnedSlice(gpa) },
    });
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

pub fn loadItems(compound: nbt.Compound, slots: []?Stack) void {
    const tag = compound.get("Items") orelse return;
    const list = switch (tag) {
        .list => |list| list,
        else => return,
    };
    for (list.items) |entry| switch (entry) {
        .compound => |slot_compound| {
            const index = switch (slot_compound.get("Slot") orelse continue) {
                .byte => |value| @as(u8, @bitCast(value)),
                else => continue,
            };
            if (index >= slots.len) continue;
            slots[index] = loadStack(slot_compound);
        },
        else => {},
    };
}
