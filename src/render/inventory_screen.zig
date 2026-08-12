const std = @import("std");

const game = @import("game");
const grid_size = game.crafting.player_grid_size;
const armor_size = game.Inventory.armor_size;
const gl = @import("gl");
const world = @import("world");

const container = @import("container_screen.zig");
const gui = @import("gui.zig");
const MeshBuilder = @import("mesh_builder.zig");
const MobModel = @import("mob_model.zig");

const label_x: f32 = 86;
const label_y: f32 = 16;

const preview_anchor_x: f32 = 51;
const preview_anchor_y: f32 = 75;
const preview_pitch_anchor_y: f32 = 50;
const preview_tracking_divisor: f32 = 40;
const preview_pixels_per_meter: f32 = 30;
const preview_depth_scale: f32 = 0.5;

const craft_grid_x: f32 = 88;
const craft_grid_y: f32 = 26;
const craft_result_x: f32 = 144;
const craft_result_y: f32 = 36;
const armor_x: f32 = 8;
const armor_y: f32 = 8;

pub const slot_count = 1 + grid_size * grid_size + armor_size + container.player_slot_count;

pub fn slots() [slot_count]container.Slot {
    var result: [slot_count]container.Slot = undefined;
    var n: usize = 0;
    result[n] = .{ .x = craft_result_x, .y = craft_result_y, .kind = .craft_result, .index = 0 };
    n += 1;
    for (0..grid_size) |row| {
        for (0..grid_size) |col| {
            result[n] = .{
                .x = craft_grid_x + @as(f32, @floatFromInt(col)) * container.slot_pitch,
                .y = craft_grid_y + @as(f32, @floatFromInt(row)) * container.slot_pitch,
                .kind = .craft_input,
                .index = col + row * grid_size,
            };
            n += 1;
        }
    }
    for (0..armor_size) |piece| {
        result[n] = .{
            .x = armor_x,
            .y = armor_y + @as(f32, @floatFromInt(piece)) * container.slot_pitch,
            .kind = .armor,
            .index = piece,
        };
        n += 1;
    }
    container.appendPlayerSlots(result[n..]);
    return result;
}

fn appendPlayerPreview(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    model: MobModel.Model,
    visible: []const bool,
    anchor_x: f32,
    anchor_y: f32,
    dx: f32,
    dy: f32,
    res: gui.Scaled,
) !void {
    const body_yaw = std.math.atan(dx / preview_tracking_divisor) * (20.0 * std.math.pi / 180.0);
    const head_yaw = std.math.atan(dx / preview_tracking_divisor) * (40.0 * std.math.pi / 180.0);
    const pitch = -std.math.atan(dy / preview_tracking_divisor) * (20.0 * std.math.pi / 180.0);

    const start = mesh.vertices.items.len;
    for (model.parts, 0..) |part, i| {
        if (!visible[i]) continue;
        var p = part;
        var yaw = body_yaw;
        if (i == model.head_index) {
            yaw = head_yaw;
            p.rotate_x = pitch;
        }
        try MobModel.appendPart(mesh, gpa, p, model.texture_width, model.texture_height, .{ .position = .{ 0, 0, 0 }, .yaw = yaw });
    }

    for (mesh.vertices.items[start..]) |*v| {
        const screen_x = anchor_x + v.x * preview_pixels_per_meter;
        const screen_y = anchor_y - v.y * preview_pixels_per_meter;
        const ndc = gui.toNdc(screen_x, screen_y, res);
        v.x = ndc[0];
        v.y = ndc[1];
        v.z = -v.z * preview_depth_scale;
    }
}

fn wornArmor(stack: ?game.Inventory.ItemStack) ?world.item.Armor {
    const worn = stack orelse return null;
    return switch (worn.id) {
        .item => |id| id.armor(),
        .block => null,
    };
}

fn drawPreview(ui: gui.Ui, player_model: MobModel.Model, inventory: game.Inventory) !void {
    const org = container.origin(ui.res, container.height);

    const anchor = .{ org[0] + preview_anchor_x, org[1] + preview_anchor_y };
    const dx = anchor[0] - ui.mouse_x / ui.res.factor;
    const dy = (anchor[1] - preview_pitch_anchor_y) - ui.mouse_y / ui.res.factor;

    gl.Clear(gl.DEPTH_BUFFER_BIT);
    gl.Enable(gl.DEPTH_TEST);

    var preview: MeshBuilder = .{};
    defer preview.deinit(ui.gpa);
    const all_visible: [MobModel.biped.parts.len]bool = @splat(true);
    try appendPlayerPreview(&preview, ui.gpa, player_model, &all_visible, anchor[0], anchor[1], dx, dy, ui.res);
    try gui.drawTexturedMesh(&preview, ui.shader, ui.textures.char);

    for (inventory.armor) |stack| {
        const piece = wornArmor(stack) orelse continue;
        const layer = MobModel.bipedArmor(piece.slot);

        var worn: MeshBuilder = .{};
        defer worn.deinit(ui.gpa);
        try appendPlayerPreview(&worn, ui.gpa, layer.model, &layer.visible, anchor[0], anchor[1], dx, dy, ui.res);
        try gui.drawTexturedMesh(&worn, ui.shader, ui.textures.armor(piece.material, layer.second_texture));
    }

    gl.Disable(gl.DEPTH_TEST);
}

pub fn draw(
    ui: gui.Ui,
    player_model: MobModel.Model,
    inventory: game.Inventory,
    crafting_grid: [grid_size * grid_size]?game.Inventory.ItemStack,
    held: ?game.Inventory.ItemStack,
) !void {
    container.begin();
    try container.drawBackdrop(ui, ui.textures.inventory);
    try drawPreview(ui, player_model, inventory);

    const craft_result = game.crafting.findMatch(&crafting_grid, grid_size);
    const layout = slots();
    var stacks: [slot_count]?game.Inventory.ItemStack = undefined;
    for (layout, &stacks) |slot, *stack| {
        stack.* = switch (slot.kind) {
            .inventory => inventory.slots[slot.index],
            .craft_input => crafting_grid[slot.index],
            .craft_result => craft_result,
            .armor => inventory.armor[slot.index],
            .furnace_input, .furnace_fuel, .furnace_output, .chest, .dispenser => unreachable,
        };
    }

    try container.drawContents(ui, &layout, &stacks, &.{
        .{ .text = "Crafting", .x = label_x, .y = label_y },
    }, held, container.height);
    container.end();
}

test "the armour column sits where ContainerPlayer puts it, helmet at the top" {
    const layout = slots();
    var found: usize = 0;
    for (layout) |slot| {
        if (slot.kind != .armor) continue;
        try std.testing.expectEqual(@as(f32, 8), slot.x);
        try std.testing.expectEqual(@as(f32, 8) + @as(f32, @floatFromInt(slot.index)) * container.slot_pitch, slot.y);
        found += 1;
    }
    try std.testing.expectEqual(armor_size, found);
    try std.testing.expectEqual(@as(usize, @intFromEnum(world.item.ArmorSlot.helmet)), layout[5].index);
}
