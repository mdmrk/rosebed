const std = @import("std");

const game = @import("game");
const world = @import("world");

const container = @import("container_screen.zig");
const gui = @import("gui.zig");
const MeshBuilder = @import("mesh_builder.zig");

const texture_size: f32 = 256;

const chest_label_x: f32 = 8;
const chest_label_y: f32 = 6;
const inventory_label_x: f32 = 8;

const player_rows_v: f32 = 126;
const player_rows_height: f32 = 96;

pub const max_rows = 6;
pub const max_slot_count = max_rows * 9 + container.player_slot_count;

pub fn slotCount(rows: u8) usize {
    return @as(usize, rows) * 9 + container.player_slot_count;
}

pub fn height(rows: u8) f32 {
    return 114 + @as(f32, @floatFromInt(rows)) * container.slot_pitch;
}

pub fn slots(rows: u8, out: *[max_slot_count]container.Slot) []container.Slot {
    const shift = (@as(f32, @floatFromInt(rows)) - 4) * container.slot_pitch;
    var n: usize = 0;

    for (0..rows) |row| {
        for (0..9) |col| {
            out[n] = .{
                .x = 8 + @as(f32, @floatFromInt(col)) * container.slot_pitch,
                .y = 18 + @as(f32, @floatFromInt(row)) * container.slot_pitch,
                .kind = .chest,
                .index = col + row * 9,
            };
            n += 1;
        }
    }

    for (0..3) |row| {
        for (0..9) |col| {
            out[n] = .{
                .x = 8 + @as(f32, @floatFromInt(col)) * container.slot_pitch,
                .y = 103 + @as(f32, @floatFromInt(row)) * container.slot_pitch + shift,
                .index = 9 + row * 9 + col,
            };
            n += 1;
        }
    }

    for (0..9) |col| {
        out[n] = .{
            .x = 8 + @as(f32, @floatFromInt(col)) * container.slot_pitch,
            .y = 161 + shift,
            .index = col,
        };
        n += 1;
    }

    return out[0..n];
}

fn drawBackdrop(ui: gui.Ui, rows: u8) !void {
    const org = container.origin(ui.res, height(rows));
    const upper = @as(f32, @floatFromInt(rows)) * container.slot_pitch + 17;

    try container.drawVeil(ui);

    var background: MeshBuilder = .{};
    defer background.deinit(ui.gpa);
    try gui.appendRect(
        &background,
        ui.gpa,
        org[0],
        org[1],
        container.width,
        upper,
        gui.pixelUv(0, 0, container.width, upper, texture_size, texture_size),
        ui.res,
    );
    try gui.appendRect(
        &background,
        ui.gpa,
        org[0],
        org[1] + upper,
        container.width,
        player_rows_height,
        gui.pixelUv(0, player_rows_v, container.width, player_rows_height, texture_size, texture_size),
        ui.res,
    );
    try gui.drawTexturedMesh(&background, ui.shader, ui.textures.container);
}

pub fn draw(
    ui: gui.Ui,
    inventory: game.Inventory,
    upper: *const world.chest.Chest,
    lower: ?*const world.chest.Chest,
    held: ?game.Inventory.ItemStack,
) !void {
    const rows: u8 = if (lower == null) world.chest.rows else world.chest.rows * 2;

    container.begin();
    try drawBackdrop(ui, rows);

    var buffer: [max_slot_count]container.Slot = undefined;
    const layout = slots(rows, &buffer);

    var stacks: [max_slot_count]?game.Inventory.ItemStack = undefined;
    for (layout, stacks[0..layout.len]) |slot, *stack| {
        stack.* = switch (slot.kind) {
            .inventory => inventory.slots[slot.index],
            .chest => if (slot.index < world.chest.slot_count)
                upper.items[slot.index]
            else
                lower.?.items[slot.index - world.chest.slot_count],
            .craft_input, .craft_result, .armor, .dispenser => unreachable,
            .furnace_input, .furnace_fuel, .furnace_output => unreachable,
        };
    }

    try container.drawContents(ui, layout, stacks[0..layout.len], &.{
        .{ .text = if (lower == null) "Chest" else "Large chest", .x = chest_label_x, .y = chest_label_y },
        .{ .text = "Inventory", .x = inventory_label_x, .y = height(rows) - 96 + 2 },
    }, held, height(rows));
    container.end();
}

test "a single chest is three rows tall and a double chest six" {
    try std.testing.expectEqual(@as(f32, 168), height(3));
    try std.testing.expectEqual(@as(f32, 222), height(6));
    try std.testing.expectEqual(@as(usize, 27 + 36), slotCount(3));
    try std.testing.expectEqual(@as(usize, 54 + 36), slotCount(6));
}

test "the chest rows sit where ContainerChest puts them" {
    var buffer: [max_slot_count]container.Slot = undefined;
    const layout = slots(3, &buffer);

    try std.testing.expectEqual(slotCount(3), layout.len);
    try std.testing.expectEqual(container.SlotKind.chest, layout[0].kind);
    try std.testing.expectEqual(@as(f32, 8), layout[0].x);
    try std.testing.expectEqual(@as(f32, 18), layout[0].y);
    try std.testing.expectEqual(@as(usize, 26), layout[26].index);
    try std.testing.expectEqual(@as(f32, 54), layout[26].y);
}

test "the player's own slots follow the chest's, one pixel below the furnace's" {
    var buffer: [max_slot_count]container.Slot = undefined;
    const layout = slots(3, &buffer);

    const first_player = layout[27];
    try std.testing.expectEqual(container.SlotKind.inventory, first_player.kind);
    try std.testing.expectEqual(@as(usize, 9), first_player.index);
    try std.testing.expectEqual(@as(f32, 85), first_player.y);

    const hotbar = layout[layout.len - 9];
    try std.testing.expectEqual(@as(usize, 0), hotbar.index);
    try std.testing.expectEqual(@as(f32, 143), hotbar.y);
}

test "a double chest pushes the player's slots down three more rows" {
    var buffer: [max_slot_count]container.Slot = undefined;
    const layout = slots(6, &buffer);

    try std.testing.expectEqual(slotCount(6), layout.len);
    try std.testing.expectEqual(@as(usize, 53), layout[53].index);
    try std.testing.expectEqual(@as(f32, 108), layout[53].y);
    try std.testing.expectEqual(@as(f32, 139), layout[54].y);
    try std.testing.expectEqual(@as(f32, 197), layout[layout.len - 9].y);
}

test "clicking the middle of a chest slot finds it" {
    const res = gui.scaledResolution(640, 480, 1000);
    var buffer: [max_slot_count]container.Slot = undefined;
    const layout = slots(3, &buffer);
    const org = container.origin(res, height(3));

    const click_x = (org[0] + layout[10].x + 8) * res.factor;
    const click_y = (org[1] + layout[10].y + 8) * res.factor;
    try std.testing.expectEqual(@as(?usize, 10), container.slotAt(layout, click_x, click_y, res, height(3)));
}
