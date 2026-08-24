const std = @import("std");

const game = @import("game");
const grid_size = game.crafting.workbench_grid_size;
const world = @import("world");

const gui = @import("../gui.zig");
const container = @import("container.zig");

const grid_x: f32 = 30;
const grid_y: f32 = 17;
const result_x: f32 = 124;
const result_y: f32 = 35;

const crafting_label_x: f32 = 28;
const crafting_label_y: f32 = 6;
const inventory_label_x: f32 = 8;
const inventory_label_y: f32 = container.height - 96 + 2;

pub const slot_count = 1 + grid_size * grid_size + container.player_slot_count;

pub fn slots() [slot_count]container.Slot {
    var result: [slot_count]container.Slot = undefined;
    var n: usize = 0;
    result[n] = .{ .x = result_x, .y = result_y, .kind = .craft_result, .index = 0 };
    n += 1;
    for (0..grid_size) |row| {
        for (0..grid_size) |col| {
            result[n] = .{
                .x = grid_x + @as(f32, @floatFromInt(col)) * container.slot_pitch,
                .y = grid_y + @as(f32, @floatFromInt(row)) * container.slot_pitch,
                .kind = .craft_input,
                .index = col + row * grid_size,
            };
            n += 1;
        }
    }
    container.appendPlayerSlots(result[n..]);
    return result;
}

pub fn draw(
    ui: gui.Ui,
    inventory: game.Inventory,
    grid: [grid_size * grid_size]?game.Inventory.ItemStack,
    held: ?game.Inventory.ItemStack,
) !void {
    container.begin();
    try container.drawBackdrop(ui, ui.textures.crafting);

    const craft_result = game.crafting.findMatch(&grid, grid_size);
    const layout = slots();
    var stacks: [slot_count]?game.Inventory.ItemStack = undefined;
    for (layout, &stacks) |slot, *stack| {
        stack.* = switch (slot.kind) {
            .inventory => inventory.slots[slot.index],
            .craft_input => grid[slot.index],
            .craft_result => craft_result,
            .armor, .furnace_input, .furnace_fuel, .furnace_output, .chest, .dispenser, .minecart => unreachable,
        };
    }

    try container.drawContents(ui, &layout, &stacks, &.{
        .{ .text = "Crafting", .x = crafting_label_x, .y = crafting_label_y },
        .{ .text = "Inventory", .x = inventory_label_x, .y = inventory_label_y },
    }, held, container.height);
    container.end();
}

test "the workbench screen's slots line up with the protocol window, slot for slot" {
    var grid: [game.Window.workbench_grid]?world.Stack = @splat(null);
    var player: game.Inventory = .{};

    var window: game.Window = .{};
    window.addGrid(&grid, game.Window.workbench_side);
    window.addPlayer(&player);

    const screen = slots();
    try std.testing.expectEqual(screen.len, window.count);
    for (screen, 0..) |slot, index| {
        switch (slot.kind) {
            .craft_result => try std.testing.expectEqual(game.Window.Kind.craft_result, window.slots[index].kind),
            .craft_input => try std.testing.expectEqual(&grid[slot.index], window.slots[index].stack.?),
            .inventory => try std.testing.expectEqual(&player.slots[slot.index], window.slots[index].stack.?),
            else => unreachable,
        }
    }
}
