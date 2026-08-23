const std = @import("std");

const game = @import("game");
const world = @import("world");

const container = @import("container_screen.zig");
const gui = @import("gui.zig");
const MeshBuilder = @import("MeshBuilder.zig");

const texture_size: f32 = 256;

const input_x: f32 = 56;
const input_y: f32 = 17;
const fuel_x: f32 = 56;
const fuel_y: f32 = 53;
const output_x: f32 = 116;
const output_y: f32 = 35;

const furnace_label_x: f32 = 60;
const furnace_label_y: f32 = 6;
const inventory_label_x: f32 = 8;
const inventory_label_y: f32 = container.height - 96 + 2;

const flame_x: f32 = 56;
const flame_y: f32 = 36;
const flame_width: f32 = 14;
const flame_span: i32 = 12;
const arrow_x: f32 = 79;
const arrow_y: f32 = 34;
const arrow_height: f32 = 16;
const arrow_span: i32 = 24;
const overlay_u: f32 = 176;
const arrow_v: f32 = 14;

pub const slot_count = world.furnace.slot_count + container.player_slot_count;

pub fn slots() [slot_count]container.Slot {
    var result: [slot_count]container.Slot = undefined;
    result[0] = .{ .x = input_x, .y = input_y, .kind = .furnace_input, .index = 0 };
    result[1] = .{ .x = fuel_x, .y = fuel_y, .kind = .furnace_fuel, .index = 1 };
    result[2] = .{ .x = output_x, .y = output_y, .kind = .furnace_output, .index = 2 };
    container.appendPlayerSlots(result[world.furnace.slot_count..]);
    return result;
}

fn appendProgress(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    res: gui.Scaled,
    org: [2]f32,
    state: world.furnace.Furnace,
) !void {
    var reading = state;

    if (reading.isBurning()) {
        const lit: f32 = @floatFromInt(reading.burnTimeRemainingScaled(flame_span));
        try gui.appendRect(
            mesh,
            gpa,
            org[0] + flame_x,
            org[1] + flame_y + 12 - lit,
            flame_width,
            lit + 2,
            gui.pixelUv(overlay_u, 12 - lit, flame_width, lit + 2, texture_size, texture_size),
            res,
        );
    }

    const cooked: f32 = @floatFromInt(reading.cookProgressScaled(arrow_span));
    if (cooked <= 0) return;
    try gui.appendRect(
        mesh,
        gpa,
        org[0] + arrow_x,
        org[1] + arrow_y,
        cooked + 1,
        arrow_height,
        gui.pixelUv(overlay_u, arrow_v, cooked + 1, arrow_height, texture_size, texture_size),
        res,
    );
}

pub fn draw(
    ui: gui.Ui,
    inventory: game.Inventory,
    state: world.furnace.Furnace,
    held: ?game.Inventory.ItemStack,
) !void {
    container.begin();
    try container.drawBackdrop(ui, ui.textures.furnace);

    var overlay: MeshBuilder = .{};
    defer overlay.deinit(ui.gpa);
    try appendProgress(&overlay, ui.gpa, ui.res, container.origin(ui.res, container.height), state);
    try gui.drawTexturedMesh(&overlay, ui.shader, ui.textures.furnace);

    const layout = slots();
    var stacks: [slot_count]?game.Inventory.ItemStack = undefined;
    for (layout, &stacks) |slot, *stack| {
        stack.* = switch (slot.kind) {
            .inventory => inventory.slots[slot.index],
            .furnace_input => state.input,
            .furnace_fuel => state.fuel,
            .furnace_output => state.output,
            .craft_input, .craft_result, .armor, .chest, .dispenser, .minecart => unreachable,
        };
    }

    try container.drawContents(ui, &layout, &stacks, &.{
        .{ .text = "Furnace", .x = furnace_label_x, .y = furnace_label_y },
        .{ .text = "Inventory", .x = inventory_label_x, .y = inventory_label_y },
    }, held, container.height);
    container.end();
}

test "the three furnace slots sit where ContainerFurnace puts them" {
    const layout = slots();
    try std.testing.expectEqual(container.SlotKind.furnace_input, layout[0].kind);
    try std.testing.expectEqual(@as(f32, 56), layout[0].x);
    try std.testing.expectEqual(@as(f32, 17), layout[0].y);
    try std.testing.expectEqual(container.SlotKind.furnace_fuel, layout[1].kind);
    try std.testing.expectEqual(@as(f32, 53), layout[1].y);
    try std.testing.expectEqual(container.SlotKind.furnace_output, layout[2].kind);
    try std.testing.expectEqual(@as(f32, 116), layout[2].x);
    try std.testing.expectEqual(@as(f32, 35), layout[2].y);
}

test "the player's own slots follow the furnace's three" {
    const layout = slots();
    try std.testing.expectEqual(@as(usize, 39), layout.len);
    for (layout[3..]) |slot| try std.testing.expectEqual(container.SlotKind.inventory, slot.kind);
    try std.testing.expectEqual(@as(usize, 9), layout[3].index);
    try std.testing.expectEqual(@as(usize, 0), layout[layout.len - 9].index);
}

test "clicking the middle of a furnace slot finds it" {
    const res = gui.scaledResolution(640, 480, 1000);
    const org = container.origin(res, container.height);
    const layout = slots();

    const fuel_click_x = (org[0] + fuel_x + 8) * res.factor;
    const fuel_click_y = (org[1] + fuel_y + 8) * res.factor;
    try std.testing.expectEqual(@as(?usize, 1), container.slotAt(&layout, fuel_click_x, fuel_click_y, res, container.height));
}
