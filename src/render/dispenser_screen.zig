const std = @import("std");

const game = @import("game");
const world = @import("world");

const container = @import("container_screen.zig");
const gui = @import("gui.zig");

const grid_x: f32 = 62;
const grid_y: f32 = 17;

const dispenser_label_x: f32 = 60;
const dispenser_label_y: f32 = 6;
const inventory_label_x: f32 = 8;
const inventory_label_y: f32 = container.height - 96 + 2;

pub const slot_count = world.dispenser.slot_count + container.player_slot_count;

pub fn slots() [slot_count]container.Slot {
    var result: [slot_count]container.Slot = undefined;
    for (0..world.dispenser.rows) |row| {
        for (0..world.dispenser.rows) |col| {
            result[col + row * world.dispenser.rows] = .{
                .x = grid_x + @as(f32, @floatFromInt(col)) * container.slot_pitch,
                .y = grid_y + @as(f32, @floatFromInt(row)) * container.slot_pitch,
                .kind = .dispenser,
                .index = col + row * world.dispenser.rows,
            };
        }
    }
    container.appendPlayerSlots(result[world.dispenser.slot_count..]);
    return result;
}

pub fn draw(
    ui: gui.Ui,
    inventory: game.Inventory,
    state: *const world.dispenser.Dispenser,
    held: ?game.Inventory.ItemStack,
) !void {
    container.begin();
    try container.drawBackdrop(ui, ui.textures.trap);

    const layout = slots();
    var stacks: [slot_count]?game.Inventory.ItemStack = undefined;
    for (layout, &stacks) |slot, *stack| {
        stack.* = switch (slot.kind) {
            .inventory => inventory.slots[slot.index],
            .dispenser => state.items[slot.index],
            .craft_input, .craft_result, .armor, .chest => unreachable,
            .furnace_input, .furnace_fuel, .furnace_output => unreachable,
        };
    }

    try container.drawContents(ui, &layout, &stacks, &.{
        .{ .text = "Dispenser", .x = dispenser_label_x, .y = dispenser_label_y },
        .{ .text = "Inventory", .x = inventory_label_x, .y = inventory_label_y },
    }, held, container.height);
    container.end();
}

test "the nine dispenser slots sit where ContainerDispenser puts them" {
    const layout = slots();

    try std.testing.expectEqual(@as(usize, 45), layout.len);
    try std.testing.expectEqual(container.SlotKind.dispenser, layout[0].kind);
    try std.testing.expectEqual(@as(f32, 62), layout[0].x);
    try std.testing.expectEqual(@as(f32, 17), layout[0].y);

    try std.testing.expectEqual(@as(f32, 98), layout[2].x);
    try std.testing.expectEqual(@as(f32, 17), layout[2].y);
    try std.testing.expectEqual(@as(usize, 8), layout[8].index);
    try std.testing.expectEqual(@as(f32, 98), layout[8].x);
    try std.testing.expectEqual(@as(f32, 53), layout[8].y);
}

test "the player's own slots follow the dispenser's nine" {
    const layout = slots();
    for (layout[9..]) |slot| try std.testing.expectEqual(container.SlotKind.inventory, slot.kind);
    try std.testing.expectEqual(@as(usize, 9), layout[9].index);
    try std.testing.expectEqual(@as(f32, 84), layout[9].y);
    try std.testing.expectEqual(@as(usize, 0), layout[layout.len - 9].index);
    try std.testing.expectEqual(@as(f32, 142), layout[layout.len - 9].y);
}

test "clicking the middle of a dispenser slot finds it" {
    const res = gui.scaledResolution(640, 480, 1000);
    const org = container.origin(res, container.height);
    const layout = slots();

    const click_x = (org[0] + layout[4].x + 8) * res.factor;
    const click_y = (org[1] + layout[4].y + 8) * res.factor;
    try std.testing.expectEqual(@as(?usize, 4), container.slotAt(&layout, click_x, click_y, res, container.height));
}
