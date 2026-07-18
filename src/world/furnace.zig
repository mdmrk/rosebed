const std = @import("std");

const block = @import("block.zig");
const Block = block.Block;
const Stack = block.Stack;
const item = @import("item.zig");
const nbt = @import("nbt.zig");

pub const id_key = "Furnace";
pub const cook_ticks: i16 = 200;
pub const stack_limit: u8 = 64;
pub const slot_count = 3;

pub fn smeltingResult(id: block.Id) ?Stack {
    return switch (id) {
        .block => |b| switch (b) {
            .ore_iron => .{ .id = .{ .item = .ingot_iron }, .count = 1 },
            .ore_gold => .{ .id = .{ .item = .ingot_gold }, .count = 1 },
            .ore_diamond => .{ .id = .{ .item = .diamond }, .count = 1 },
            .sand => .{ .id = .{ .block = .glass }, .count = 1 },
            .cobblestone => .{ .id = .{ .block = .stone }, .count = 1 },
            .cactus => .{ .id = .{ .item = .dye }, .count = 1, .meta = item.dye_meta_cactus },
            .log => .{ .id = .{ .item = .coal }, .count = 1, .meta = item.coal_meta_charcoal },
            else => null,
        },
        .item => |i| switch (i) {
            .pork_raw => .{ .id = .{ .item = .pork_cooked }, .count = 1 },
            .clay_ball => .{ .id = .{ .item = .brick }, .count = 1 },
            else => null,
        },
    };
}

pub fn burnTime(maybe_stack: ?Stack) i16 {
    const stack = maybe_stack orelse return 0;
    return switch (stack.id) {
        .block => |id| if (id.material() == .wood) 300 else if (id == .sapling) 100 else 0,
        .item => |id| switch (id) {
            .stick => 100,
            .coal => 1600,
            else => 0,
        },
    };
}

fn sameItem(a: Stack, b: Stack) bool {
    return a.id.eql(b.id) and a.meta == b.meta;
}

pub const Furnace = struct {
    input: ?Stack = null,
    fuel: ?Stack = null,
    output: ?Stack = null,
    burn_time: i16 = 0,
    item_burn_time: i16 = 0,
    cook_time: i16 = 0,

    pub fn isBurning(self: Furnace) bool {
        return self.burn_time > 0;
    }

    pub fn canSmelt(self: Furnace) bool {
        const input = self.input orelse return false;
        const result = smeltingResult(input.id) orelse return false;
        const output = self.output orelse return true;
        if (!sameItem(output, result)) return false;
        if (output.count < stack_limit and output.count < output.id.maxStackSize()) return true;
        return output.count < result.id.maxStackSize();
    }

    pub fn smelt(self: *Furnace) void {
        if (!self.canSmelt()) return;

        const result = smeltingResult(self.input.?.id).?;
        if (self.output) |*output| {
            output.count += result.count;
        } else {
            self.output = result;
        }

        self.input.?.count -|= 1;
        if (self.input.?.count == 0) self.input = null;
    }

    pub fn tick(self: *Furnace) bool {
        const was_burning = self.isBurning();
        if (self.burn_time > 0) self.burn_time -= 1;

        if (self.burn_time == 0 and self.canSmelt()) {
            self.item_burn_time = burnTime(self.fuel);
            self.burn_time = self.item_burn_time;
            if (self.burn_time > 0) {
                if (self.fuel) |*fuel| {
                    fuel.count -|= 1;
                    if (fuel.count == 0) self.fuel = null;
                }
            }
        }

        if (self.isBurning() and self.canSmelt()) {
            self.cook_time += 1;
            if (self.cook_time == cook_ticks) {
                self.cook_time = 0;
                self.smelt();
            }
        } else {
            self.cook_time = 0;
        }

        return was_burning != self.isBurning();
    }

    pub fn cookProgressScaled(self: Furnace, span: i32) i32 {
        return @divTrunc(@as(i32, self.cook_time) * span, cook_ticks);
    }

    pub fn burnTimeRemainingScaled(self: *Furnace, span: i32) i32 {
        if (self.item_burn_time == 0) self.item_burn_time = cook_ticks;
        return @divTrunc(@as(i32, self.burn_time) * span, self.item_burn_time);
    }

    pub fn slot(self: *Furnace, index: usize) *?Stack {
        return switch (index) {
            0 => &self.input,
            1 => &self.fuel,
            else => &self.output,
        };
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

pub fn store(gpa: std.mem.Allocator, x: i32, y: i32, z: i32, state: Furnace) !nbt.Tag {
    var compound: nbt.Compound = .{};
    errdefer {
        var owned: nbt.Tag = .{ .compound = compound };
        nbt.deinit(gpa, &owned);
    }

    try put(gpa, &compound, "id", .{ .string = try gpa.dupe(u8, id_key) });
    try put(gpa, &compound, "x", .{ .int = x });
    try put(gpa, &compound, "y", .{ .int = y });
    try put(gpa, &compound, "z", .{ .int = z });
    try put(gpa, &compound, "BurnTime", .{ .short = state.burn_time });
    try put(gpa, &compound, "CookTime", .{ .short = state.cook_time });

    var items: std.ArrayList(nbt.Tag) = .empty;
    errdefer {
        for (items.items) |*tag| nbt.deinit(gpa, tag);
        items.deinit(gpa);
    }
    for ([_]?Stack{ state.input, state.fuel, state.output }, 0..) |maybe_stack, index| {
        const stack = maybe_stack orelse continue;
        try items.append(gpa, try storeStack(gpa, @intCast(index), stack));
    }

    try put(gpa, &compound, "Items", .{
        .list = .{ .element_type = .compound, .items = try items.toOwnedSlice(gpa) },
    });

    return .{ .compound = compound };
}

fn intField(compound: nbt.Compound, key: []const u8) ?i32 {
    return switch (compound.get(key) orelse return null) {
        .int => |value| value,
        else => null,
    };
}

fn shortField(compound: nbt.Compound, key: []const u8) i16 {
    return switch (compound.get(key) orelse return 0) {
        .short => |value| value,
        else => 0,
    };
}

fn loadStack(compound: nbt.Compound) ?Stack {
    const raw: u16 = @bitCast(shortField(compound, "id"));
    const count = switch (compound.get("Count") orelse return null) {
        .byte => |value| @as(u8, @bitCast(value)),
        else => return null,
    };
    if (count == 0) return null;

    const id: block.Id = if (raw < 256)
        .{ .block = @enumFromInt(@as(u8, @intCast(raw))) }
    else
        .{ .item = @enumFromInt(raw) };
    return .{ .id = id, .count = count, .meta = @bitCast(shortField(compound, "Damage")) };
}

pub const Placed = struct {
    x: i32,
    y: i32,
    z: i32,
    state: Furnace,
};

pub fn isFurnace(compound: nbt.Compound) bool {
    return switch (compound.get("id") orelse return false) {
        .string => |value| std.mem.eql(u8, value, id_key),
        else => false,
    };
}

pub fn load(compound: nbt.Compound) ?Placed {
    if (!isFurnace(compound)) return null;

    var state: Furnace = .{
        .burn_time = shortField(compound, "BurnTime"),
        .cook_time = shortField(compound, "CookTime"),
    };

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

    state.item_burn_time = burnTime(state.fuel);

    return .{
        .x = intField(compound, "x") orelse return null,
        .y = intField(compound, "y") orelse return null,
        .z = intField(compound, "z") orelse return null,
        .state = state,
    };
}

test "the smelting list is the one FurnaceRecipes fills in" {
    try std.testing.expectEqual(block.Id{ .item = .ingot_iron }, smeltingResult(.{ .block = .ore_iron }).?.id);
    try std.testing.expectEqual(block.Id{ .item = .ingot_gold }, smeltingResult(.{ .block = .ore_gold }).?.id);
    try std.testing.expectEqual(block.Id{ .item = .diamond }, smeltingResult(.{ .block = .ore_diamond }).?.id);
    try std.testing.expectEqual(block.Id{ .block = .glass }, smeltingResult(.{ .block = .sand }).?.id);
    try std.testing.expectEqual(block.Id{ .block = .stone }, smeltingResult(.{ .block = .cobblestone }).?.id);
    try std.testing.expectEqual(block.Id{ .item = .pork_cooked }, smeltingResult(.{ .item = .pork_raw }).?.id);
    try std.testing.expectEqual(block.Id{ .item = .brick }, smeltingResult(.{ .item = .clay_ball }).?.id);

    const green = smeltingResult(.{ .block = .cactus }).?;
    try std.testing.expectEqual(item.dye_meta_cactus, green.meta);
    const charcoal = smeltingResult(.{ .block = .log }).?;
    try std.testing.expectEqual(item.coal_meta_charcoal, charcoal.meta);

    try std.testing.expectEqual(@as(?Stack, null), smeltingResult(.{ .block = .dirt }));
    try std.testing.expectEqual(@as(?Stack, null), smeltingResult(.{ .item = .stick }));
}

test "fuels burn for getItemBurnTime's spans" {
    try std.testing.expectEqual(@as(i16, 300), burnTime(.{ .id = .{ .block = .planks }, .count = 1 }));
    try std.testing.expectEqual(@as(i16, 300), burnTime(.{ .id = .{ .block = .log }, .count = 1 }));
    try std.testing.expectEqual(@as(i16, 100), burnTime(.{ .id = .{ .block = .sapling }, .count = 1 }));
    try std.testing.expectEqual(@as(i16, 100), burnTime(.{ .id = .{ .item = .stick }, .count = 1 }));
    try std.testing.expectEqual(@as(i16, 1600), burnTime(.{ .id = .{ .item = .coal }, .count = 1 }));
    try std.testing.expectEqual(@as(i16, 0), burnTime(.{ .id = .{ .block = .stone }, .count = 1 }));
    try std.testing.expectEqual(@as(i16, 0), burnTime(null));
}

test "a lit furnace consumes one fuel and smelts after two hundred ticks" {
    var state: Furnace = .{
        .input = .{ .id = .{ .block = .ore_iron }, .count = 2 },
        .fuel = .{ .id = .{ .item = .coal }, .count = 1 },
    };

    try std.testing.expect(state.tick());
    try std.testing.expect(state.isBurning());
    try std.testing.expectEqual(@as(?Stack, null), state.fuel);
    try std.testing.expectEqual(@as(i16, 1600), state.item_burn_time);

    for (0..199) |_| try std.testing.expect(!state.tick());
    try std.testing.expectEqual(@as(u8, 1), state.output.?.count);
    try std.testing.expectEqual(block.Id{ .item = .ingot_iron }, state.output.?.id);
    try std.testing.expectEqual(@as(u8, 1), state.input.?.count);
    try std.testing.expectEqual(@as(i16, 0), state.cook_time);
}

test "the fire goes out when its fuel runs down, and cooking restarts" {
    var state: Furnace = .{
        .input = .{ .id = .{ .block = .ore_iron }, .count = 1 },
        .fuel = .{ .id = .{ .item = .stick }, .count = 1 },
    };

    _ = state.tick();
    try std.testing.expectEqual(@as(i16, 100), state.burn_time);
    for (0..99) |_| _ = state.tick();

    try std.testing.expect(state.tick());
    try std.testing.expect(!state.isBurning());
    try std.testing.expectEqual(@as(i16, 0), state.cook_time);
    try std.testing.expectEqual(@as(?Stack, null), state.output);
}

test "an unsmeltable input never lights the fire" {
    var state: Furnace = .{
        .input = .{ .id = .{ .block = .dirt }, .count = 1 },
        .fuel = .{ .id = .{ .item = .coal }, .count = 1 },
    };

    try std.testing.expect(!state.tick());
    try std.testing.expect(!state.isBurning());
    try std.testing.expectEqual(@as(u8, 1), state.fuel.?.count);
}

test "smelting stops once the output slot is full or holds something else" {
    var full: Furnace = .{
        .input = .{ .id = .{ .block = .sand }, .count = 8 },
        .output = .{ .id = .{ .block = .glass }, .count = 64 },
    };
    try std.testing.expect(!full.canSmelt());

    var mismatched: Furnace = .{
        .input = .{ .id = .{ .block = .sand }, .count = 8 },
        .output = .{ .id = .{ .block = .stone }, .count = 1 },
    };
    try std.testing.expect(!mismatched.canSmelt());

    var stacking: Furnace = .{
        .input = .{ .id = .{ .block = .sand }, .count = 8 },
        .output = .{ .id = .{ .block = .glass }, .count = 63 },
    };
    try std.testing.expect(stacking.canSmelt());
    stacking.smelt();
    try std.testing.expectEqual(@as(u8, 64), stacking.output.?.count);
    try std.testing.expectEqual(@as(u8, 7), stacking.input.?.count);
}

test "charcoal does not stack onto the coal it looks like" {
    var state: Furnace = .{
        .input = .{ .id = .{ .block = .log }, .count = 1 },
        .output = .{ .id = .{ .item = .coal }, .count = 1 },
    };
    try std.testing.expect(!state.canSmelt());
}

test "the progress bars scale the way GuiFurnace reads them" {
    var state: Furnace = .{ .cook_time = 100, .burn_time = 800, .item_burn_time = 1600 };
    try std.testing.expectEqual(@as(i32, 12), state.cookProgressScaled(24));
    try std.testing.expectEqual(@as(i32, 6), state.burnTimeRemainingScaled(12));

    var unlit: Furnace = .{};
    try std.testing.expectEqual(@as(i32, 0), unlit.cookProgressScaled(24));
    try std.testing.expectEqual(@as(i32, 0), unlit.burnTimeRemainingScaled(12));
}

test "a furnace survives a round trip through its tile entity compound" {
    const gpa = std.testing.allocator;
    const original: Furnace = .{
        .input = .{ .id = .{ .block = .ore_gold }, .count = 12 },
        .fuel = .{ .id = .{ .item = .coal }, .count = 3 },
        .output = .{ .id = .{ .item = .dye }, .count = 5, .meta = item.dye_meta_cactus },
        .burn_time = 640,
        .item_burn_time = 1600,
        .cook_time = 37,
    };

    var tag = try store(gpa, 10, 64, -3, original);
    defer nbt.deinit(gpa, &tag);

    const loaded = load(tag.compound).?;
    try std.testing.expectEqual(@as(i32, 10), loaded.x);
    try std.testing.expectEqual(@as(i32, 64), loaded.y);
    try std.testing.expectEqual(@as(i32, -3), loaded.z);
    try std.testing.expectEqual(original, loaded.state);
}

test "an empty furnace round-trips with no item entries" {
    const gpa = std.testing.allocator;
    var tag = try store(gpa, 0, 0, 0, .{});
    defer nbt.deinit(gpa, &tag);

    try std.testing.expectEqual(@as(usize, 0), tag.compound.get("Items").?.list.items.len);
    try std.testing.expectEqual(Furnace{}, load(tag.compound).?.state);
}

test "a tile entity of another kind is not read as a furnace" {
    const gpa = std.testing.allocator;
    var tag = try store(gpa, 1, 2, 3, .{});
    defer nbt.deinit(gpa, &tag);

    const stored = tag.compound.getPtr("id").?;
    gpa.free(stored.string);
    stored.string = try gpa.dupe(u8, "Chest");

    try std.testing.expect(!isFurnace(tag.compound));
    try std.testing.expect(load(tag.compound) == null);
}
