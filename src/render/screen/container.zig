const std = @import("std");

const game = @import("game");

const Atlas = @import("../Atlas.zig");
const gui = @import("../gui.zig");
const MeshBuilder = @import("../MeshBuilder.zig");

pub const width: f32 = 176;
pub const height: f32 = 166;
pub const slot_pitch: f32 = 18;
const texture_size: f32 = 256;

pub const label_color: [4]u8 = .{ 64, 64, 64, 255 };
const highlight_color: [4]u8 = .{ 255, 255, 255, 128 };
const tooltip_color: [4]u8 = .{ 255, 255, 255, 255 };
const tooltip_background: [4]u8 = .{ 0, 0, 0, 192 };
const tooltip_offset_x: f32 = 12;
const tooltip_offset_y: f32 = -12;
const tooltip_padding: f32 = 3;
const tooltip_line_height: f32 = 8;

pub const SlotKind = enum { inventory, craft_input, craft_result, armor, furnace_input, furnace_fuel, furnace_output, chest, dispenser, minecart };
pub const Slot = struct { x: f32, y: f32, kind: SlotKind = .inventory, index: usize };
pub const Label = struct { text: []const u8, x: f32, y: f32 };

pub const player_slot_count = 36;

pub fn appendPlayerSlots(out: []Slot) void {
    var n: usize = 0;
    for (0..3) |row| {
        for (0..9) |col| {
            out[n] = .{
                .x = 8 + @as(f32, @floatFromInt(col)) * slot_pitch,
                .y = 84 + @as(f32, @floatFromInt(row)) * slot_pitch,
                .index = 9 + row * 9 + col,
            };
            n += 1;
        }
    }
    for (0..9) |col| {
        out[n] = .{
            .x = 8 + @as(f32, @floatFromInt(col)) * slot_pitch,
            .y = 142,
            .index = col,
        };
        n += 1;
    }
}

pub const QuickRange = struct { start: usize, end: usize, reverse: bool };

pub fn quickRange(slots: []const Slot, from: usize) QuickRange {
    const player_start = slots.len - player_slot_count;
    const hotbar_start = slots.len - game.Inventory.hotbar_size;

    if (from < player_start) {
        const reverse = switch (slots[from].kind) {
            .craft_result, .furnace_output, .chest, .dispenser, .minecart => true,
            else => false,
        };
        return .{ .start = player_start, .end = slots.len, .reverse = reverse };
    }

    if (player_start > 0 and (slots[0].kind == .chest or slots[0].kind == .dispenser or slots[0].kind == .minecart)) {
        return .{ .start = 0, .end = player_start, .reverse = false };
    }

    if (from < hotbar_start) return .{ .start = hotbar_start, .end = slots.len, .reverse = false };
    return .{ .start = player_start, .end = hotbar_start, .reverse = false };
}

pub fn origin(res: gui.Scaled, box_height: f32) [2]f32 {
    return .{ @floor((res.width - width) / 2.0), @floor((res.height - box_height) / 2.0) };
}

pub fn slotAt(slots: []const Slot, mouse_x: f32, mouse_y: f32, res: gui.Scaled, box_height: f32) ?usize {
    const org = origin(res, box_height);
    const gx = mouse_x / res.factor - org[0];
    const gy = mouse_y / res.factor - org[1];
    for (slots, 0..) |slot, index| {
        if (gx >= slot.x - 1 and gx < slot.x + gui.icon_size + 1 and
            gy >= slot.y - 1 and gy < slot.y + gui.icon_size + 1)
        {
            return index;
        }
    }
    return null;
}

pub fn isOutside(mouse_x: f32, mouse_y: f32, res: gui.Scaled, box_height: f32) bool {
    const org = origin(res, box_height);
    const gx = mouse_x / res.factor;
    const gy = mouse_y / res.factor;
    return gx < org[0] or gy < org[1] or gx >= org[0] + width or gy >= org[1] + box_height;
}

pub fn begin() void {
    gui.beginOverlay();
}

pub fn end() void {
    gui.endOverlay();
}

pub fn drawVeil(ui: gui.Ui) !void {
    var veil: MeshBuilder = .{};
    defer veil.deinit(ui.gpa);
    try gui.appendVeil(&veil, ui.gpa, ui.res);
    try gui.drawTexturedMesh(&veil, ui.shader, ui.textures.gui);
}

pub fn drawBackdrop(ui: gui.Ui, texture: Atlas) !void {
    const org = origin(ui.res, height);

    try drawVeil(ui);

    var background: MeshBuilder = .{};
    defer background.deinit(ui.gpa);
    try gui.appendRect(&background, ui.gpa, org[0], org[1], width, height, gui.pixelUv(0, 0, width, height, texture_size, texture_size), ui.res);
    try gui.drawTexturedMesh(&background, ui.shader, texture);
}

pub fn drawContents(
    ui: gui.Ui,
    slots: []const Slot,
    stacks: []const ?game.Inventory.ItemStack,
    labels: []const Label,
    held: ?game.Inventory.ItemStack,
    box_height: f32,
) !void {
    const org = origin(ui.res, box_height);

    var block_icons: MeshBuilder = .{};
    defer block_icons.deinit(ui.gpa);
    var item_icons: MeshBuilder = .{};
    defer item_icons.deinit(ui.gpa);
    var bars: MeshBuilder = .{};
    defer bars.deinit(ui.gpa);
    var text: MeshBuilder = .{};
    defer text.deinit(ui.gpa);

    for (slots, stacks) |slot, maybe_stack| {
        const stack = maybe_stack orelse continue;
        try gui.appendStackIcon(&block_icons, &item_icons, &bars, &text, ui.gpa, ui.font, stack, org[0] + slot.x, org[1] + slot.y, ui.res);
    }

    try gui.drawTexturedMesh(&block_icons, ui.shader, ui.textures.terrain);
    try gui.drawTexturedMesh(&item_icons, ui.shader, ui.textures.items);
    try gui.drawColorMesh(&bars, ui.shader);
    try gui.drawTexturedMesh(&text, ui.shader, ui.font);

    const hovered = slotAt(slots, ui.mouse_x, ui.mouse_y, ui.res, box_height);

    var highlight: MeshBuilder = .{};
    defer highlight.deinit(ui.gpa);
    if (hovered) |index| {
        const slot = slots[index];
        try gui.appendRectColor(&highlight, ui.gpa, org[0] + slot.x, org[1] + slot.y, gui.icon_size, gui.icon_size, gui.opaque_texel, highlight_color, ui.res);
    }
    try gui.drawColorMesh(&highlight, ui.shader);

    var foreground: MeshBuilder = .{};
    defer foreground.deinit(ui.gpa);

    if (held) |stack| {
        var cursor_blocks: MeshBuilder = .{};
        defer cursor_blocks.deinit(ui.gpa);
        var cursor_items: MeshBuilder = .{};
        defer cursor_items.deinit(ui.gpa);
        var cursor_bars: MeshBuilder = .{};
        defer cursor_bars.deinit(ui.gpa);
        const hx = ui.mouse_x / ui.res.factor - gui.icon_size / 2.0;
        const hy = ui.mouse_y / ui.res.factor - gui.icon_size / 2.0;
        try gui.appendStackIcon(&cursor_blocks, &cursor_items, &cursor_bars, &foreground, ui.gpa, ui.font, stack, hx, hy, ui.res);
        try gui.drawTexturedMesh(&cursor_blocks, ui.shader, ui.textures.terrain);
        try gui.drawTexturedMesh(&cursor_items, ui.shader, ui.textures.items);
        try gui.drawColorMesh(&cursor_bars, ui.shader);
    }

    for (labels) |label| {
        try gui.appendTextNoShadow(&foreground, ui.gpa, ui.font, label.text, org[0] + label.x, org[1] + label.y, label_color, ui.res);
    }
    try gui.drawTexturedMesh(&foreground, ui.shader, ui.font);

    if (held != null) return;
    const hovered_index = hovered orelse return;
    const hovered_stack = stacks[hovered_index] orelse return;
    try drawTooltip(ui, hovered_stack.displayName());
}

fn drawTooltip(ui: gui.Ui, name: []const u8) !void {
    if (name.len == 0) return;
    const x = ui.mouse_x / ui.res.factor + tooltip_offset_x;
    const y = ui.mouse_y / ui.res.factor + tooltip_offset_y;
    const text_width: f32 = @floatFromInt(ui.font.stringWidth(name));

    var background: MeshBuilder = .{};
    defer background.deinit(ui.gpa);
    try gui.appendRectColor(
        &background,
        ui.gpa,
        x - tooltip_padding,
        y - tooltip_padding,
        text_width + tooltip_padding * 2,
        tooltip_line_height + tooltip_padding * 2,
        gui.opaque_texel,
        tooltip_background,
        ui.res,
    );
    try gui.drawColorMesh(&background, ui.shader);

    var text: MeshBuilder = .{};
    defer text.deinit(ui.gpa);
    try gui.appendTextColor(&text, ui.gpa, ui.font, name, x, y, tooltip_color, ui.res);
    try gui.drawTexturedMesh(&text, ui.shader, ui.font);
}

test "a slot's hover box extends one pixel past the icon on every side" {
    const res = gui.scaledResolution(640, 480, 1000);
    const org = origin(res, height);
    var slots: [player_slot_count]Slot = undefined;
    appendPlayerSlots(&slots);
    const slot = slots[slots.len - 9];
    const left = (org[0] + slot.x - 1) * res.factor;
    const top = (org[1] + slot.y - 1) * res.factor;

    try std.testing.expectEqual(@as(?usize, slot.index), slots[slotAt(&slots, left, top, res, height) orelse return error.NoSlot].index);
    try std.testing.expectEqual(@as(?usize, null), slotAt(&slots, left - res.factor, top, res, height));
    try std.testing.expectEqual(@as(?usize, null), slotAt(&slots, left, top - res.factor, res, height));
}

test "isOutside reports the region beyond the background rect" {
    const res = gui.scaledResolution(640, 480, 1000);
    const org = origin(res, height);

    try std.testing.expect(isOutside((org[0] - 1) * res.factor, org[1] * res.factor, res, height));
    try std.testing.expect(isOutside(org[0] * res.factor, (org[1] + height) * res.factor, res, height));
    try std.testing.expect(!isOutside(org[0] * res.factor, org[1] * res.factor, res, height));
}

test "clicking the background between slots hits no slot but is not outside" {
    const res = gui.scaledResolution(640, 480, 1000);
    const org = origin(res, height);
    var slots: [player_slot_count]Slot = undefined;
    appendPlayerSlots(&slots);
    const x = (org[0] + 4) * res.factor;
    const y = (org[1] + 4) * res.factor;

    try std.testing.expectEqual(@as(?usize, null), slotAt(&slots, x, y, res, height));
    try std.testing.expect(!isOutside(x, y, res, height));
}

test "a furnace shift-click walks ContainerFurnace's slot ranges" {
    const furnace_screen = @import("furnace.zig");
    const layout = furnace_screen.slots();

    const output = quickRange(&layout, 2);
    try std.testing.expectEqual(QuickRange{ .start = 3, .end = 39, .reverse = true }, output);
    try std.testing.expectEqual(QuickRange{ .start = 3, .end = 39, .reverse = false }, quickRange(&layout, 0));
    try std.testing.expectEqual(QuickRange{ .start = 30, .end = 39, .reverse = false }, quickRange(&layout, 3));
    try std.testing.expectEqual(QuickRange{ .start = 30, .end = 39, .reverse = false }, quickRange(&layout, 29));
    try std.testing.expectEqual(QuickRange{ .start = 3, .end = 30, .reverse = false }, quickRange(&layout, 30));
    try std.testing.expectEqual(QuickRange{ .start = 3, .end = 30, .reverse = false }, quickRange(&layout, 38));
}

test "a workbench shift-click walks ContainerWorkbench's slot ranges" {
    const crafting_screen = @import("crafting.zig");
    const layout = crafting_screen.slots();

    try std.testing.expectEqual(QuickRange{ .start = 10, .end = 46, .reverse = true }, quickRange(&layout, 0));
    try std.testing.expectEqual(QuickRange{ .start = 10, .end = 46, .reverse = false }, quickRange(&layout, 9));
    try std.testing.expectEqual(QuickRange{ .start = 37, .end = 46, .reverse = false }, quickRange(&layout, 10));
    try std.testing.expectEqual(QuickRange{ .start = 10, .end = 37, .reverse = false }, quickRange(&layout, 37));
}

test "an inventory shift-click walks ContainerPlayer's slot ranges" {
    const inventory_screen = @import("inventory.zig");
    const layout = inventory_screen.slots();

    try std.testing.expectEqual(QuickRange{ .start = 9, .end = 45, .reverse = true }, quickRange(&layout, 0));
    try std.testing.expectEqual(QuickRange{ .start = 9, .end = 45, .reverse = false }, quickRange(&layout, 1));
    try std.testing.expectEqual(QuickRange{ .start = 9, .end = 45, .reverse = false }, quickRange(&layout, 8));
    try std.testing.expectEqual(QuickRange{ .start = 36, .end = 45, .reverse = false }, quickRange(&layout, 9));
    try std.testing.expectEqual(QuickRange{ .start = 9, .end = 36, .reverse = false }, quickRange(&layout, 44));
}

test "a chest shift-click moves stacks both ways, unlike the other containers" {
    const chest_screen = @import("chest.zig");
    var buffer: [chest_screen.max_slot_count]Slot = undefined;

    const single = chest_screen.slots(3, &buffer, .chest);
    try std.testing.expectEqual(QuickRange{ .start = 27, .end = 63, .reverse = true }, quickRange(single, 0));
    try std.testing.expectEqual(QuickRange{ .start = 0, .end = 27, .reverse = false }, quickRange(single, 27));
    try std.testing.expectEqual(QuickRange{ .start = 0, .end = 27, .reverse = false }, quickRange(single, 62));

    var wide: [chest_screen.max_slot_count]Slot = undefined;
    const double = chest_screen.slots(6, &wide, .chest);
    try std.testing.expectEqual(QuickRange{ .start = 54, .end = 90, .reverse = true }, quickRange(double, 53));
    try std.testing.expectEqual(QuickRange{ .start = 0, .end = 54, .reverse = false }, quickRange(double, 54));
}
