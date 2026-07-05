const std = @import("std");
const gl = @import("gl");
const game = @import("game");

const Atlas = @import("atlas.zig");
const Font = @import("font.zig");
const MeshBuilder = @import("mesh_builder.zig");
const MobModel = @import("mob_model.zig");
const Shader = @import("shader.zig");
const gui = @import("gui.zig");

pub const width: f32 = 176;
pub const height: f32 = 166;
const slot_pitch: f32 = 18;
const texture_size: f32 = 256;

const label_color: [4]u8 = .{ 64, 64, 64, 255 };
const label_x: f32 = 86;
const label_y: f32 = 16;

const highlight_color: [4]u8 = .{ 255, 255, 255, 128 };
const tooltip_color: [4]u8 = .{ 255, 255, 255, 255 };
const tooltip_background: [4]u8 = .{ 0, 0, 0, 192 };
const tooltip_offset_x: f32 = 12;
const tooltip_offset_y: f32 = -12;
const tooltip_padding: f32 = 3;
const tooltip_line_height: f32 = 8;

const preview_anchor_x: f32 = 51;
const preview_anchor_y: f32 = 75;
const preview_pitch_anchor_y: f32 = 50;
const preview_tracking_divisor: f32 = 40;
const preview_pixels_per_meter: f32 = 30;
const preview_depth_scale: f32 = 0.5;

fn appendPlayerPreview(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    model: MobModel.Model,
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
        var p = part;
        var yaw = body_yaw;
        if (i == model.head_index) {
            yaw = head_yaw;
            p.rotate_x = pitch;
        }
        try MobModel.appendPart(mesh, gpa, p, model.texture_width, model.texture_height, .{ 0, 0, 0 }, yaw);
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

pub const SlotKind = enum { inventory, craft_input, craft_result };
pub const Slot = struct { x: f32, y: f32, kind: SlotKind = .inventory, index: usize };

const craft_grid_x: f32 = 88;
const craft_grid_y: f32 = 26;
const craft_result_x: f32 = 144;
const craft_result_y: f32 = 36;

pub fn slots() [41]Slot {
    var result: [41]Slot = undefined;
    var n: usize = 0;
    result[n] = .{ .x = craft_result_x, .y = craft_result_y, .kind = .craft_result, .index = 0 };
    n += 1;
    for (0..2) |row| {
        for (0..2) |col| {
            result[n] = .{
                .x = craft_grid_x + @as(f32, @floatFromInt(col)) * slot_pitch,
                .y = craft_grid_y + @as(f32, @floatFromInt(row)) * slot_pitch,
                .kind = .craft_input,
                .index = col + row * 2,
            };
            n += 1;
        }
    }
    for (0..3) |row| {
        for (0..9) |col| {
            result[n] = .{
                .x = 8 + @as(f32, @floatFromInt(col)) * slot_pitch,
                .y = 84 + @as(f32, @floatFromInt(row)) * slot_pitch,
                .index = 9 + row * 9 + col,
            };
            n += 1;
        }
    }
    for (0..9) |col| {
        result[n] = .{
            .x = 8 + @as(f32, @floatFromInt(col)) * slot_pitch,
            .y = 142,
            .index = col,
        };
        n += 1;
    }
    return result;
}

pub fn origin(res: gui.Scaled) [2]f32 {
    return .{ @floor((res.width - width) / 2.0), @floor((res.height - height) / 2.0) };
}

/// Returns the inventory slot under the given window-pixel mouse position, if any.
pub fn slotAt(mouse_x: f32, mouse_y: f32, res: gui.Scaled) ?Slot {
    const org = origin(res);
    const gx = mouse_x / res.factor - org[0];
    const gy = mouse_y / res.factor - org[1];
    for (slots()) |slot| {
        if (gx >= slot.x - 1 and gx < slot.x + gui.icon_size + 1 and
            gy >= slot.y - 1 and gy < slot.y + gui.icon_size + 1)
        {
            return slot;
        }
    }
    return null;
}

pub fn isOutside(mouse_x: f32, mouse_y: f32, res: gui.Scaled) bool {
    const org = origin(res);
    const gx = mouse_x / res.factor;
    const gy = mouse_y / res.factor;
    return gx < org[0] or gy < org[1] or gx >= org[0] + width or gy >= org[1] + height;
}

pub fn draw(
    ui: gui.Ui,
    player_model: MobModel.Model,
    inventory: game.Inventory,
    crafting_grid: [game.crafting.grid_size * game.crafting.grid_size]?game.Inventory.ItemStack,
    held: ?game.Inventory.ItemStack,
) !void {
    const org = origin(ui.res);

    gl.Disable(gl.DEPTH_TEST);
    gl.Enable(gl.BLEND);
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

    var veil: MeshBuilder = .{};
    defer veil.deinit(ui.gpa);
    try gui.appendVeil(&veil, ui.gpa, ui.res);
    try gui.drawTexturedMesh(&veil, ui.shader, ui.textures.gui);

    var background: MeshBuilder = .{};
    defer background.deinit(ui.gpa);
    try gui.appendRect(&background, ui.gpa, org[0], org[1], width, height, gui.pixelUv(0, 0, width, height, texture_size, texture_size), ui.res);
    try gui.drawTexturedMesh(&background, ui.shader, ui.textures.inventory);

    var preview: MeshBuilder = .{};
    defer preview.deinit(ui.gpa);
    const preview_anchor = .{ org[0] + preview_anchor_x, org[1] + preview_anchor_y };
    const preview_dx = preview_anchor[0] - ui.mouse_x / ui.res.factor;
    const preview_dy = (preview_anchor[1] - preview_pitch_anchor_y) - ui.mouse_y / ui.res.factor;
    try appendPlayerPreview(
        &preview,
        ui.gpa,
        player_model,
        preview_anchor[0],
        preview_anchor[1],
        preview_dx,
        preview_dy,
        ui.res,
    );
    gl.Clear(gl.DEPTH_BUFFER_BIT);
    gl.Enable(gl.DEPTH_TEST);
    try gui.drawTexturedMesh(&preview, ui.shader, ui.textures.char);
    gl.Disable(gl.DEPTH_TEST);

    var block_icons: MeshBuilder = .{};
    defer block_icons.deinit(ui.gpa);
    var item_icons: MeshBuilder = .{};
    defer item_icons.deinit(ui.gpa);
    var text: MeshBuilder = .{};
    defer text.deinit(ui.gpa);

    const craft_result = game.crafting.findMatch(crafting_grid);
    const hovered = slotAt(ui.mouse_x, ui.mouse_y, ui.res);
    for (slots()) |slot| {
        const stack = switch (slot.kind) {
            .inventory => inventory.slots[slot.index],
            .craft_input => crafting_grid[slot.index],
            .craft_result => craft_result,
        } orelse continue;
        try gui.appendStackIcon(&block_icons, &item_icons, &text, ui.gpa, ui.font, stack, org[0] + slot.x, org[1] + slot.y, ui.res);
    }

    try gui.drawTexturedMesh(&block_icons, ui.shader, ui.textures.terrain);
    try gui.drawTexturedMesh(&item_icons, ui.shader, ui.textures.items);
    try gui.drawTexturedMesh(&text, ui.shader, ui.font);

    var highlight: MeshBuilder = .{};
    defer highlight.deinit(ui.gpa);
    if (hovered) |slot| {
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
        const hx = ui.mouse_x / ui.res.factor - gui.icon_size / 2.0;
        const hy = ui.mouse_y / ui.res.factor - gui.icon_size / 2.0;
        try gui.appendStackIcon(&cursor_blocks, &cursor_items, &foreground, ui.gpa, ui.font, stack, hx, hy, ui.res);
        try gui.drawTexturedMesh(&cursor_blocks, ui.shader, ui.textures.terrain);
        try gui.drawTexturedMesh(&cursor_items, ui.shader, ui.textures.items);
    }

    try gui.appendTextNoShadow(&foreground, ui.gpa, ui.font, "Crafting", org[0] + label_x, org[1] + label_y, label_color, ui.res);
    try gui.drawTexturedMesh(&foreground, ui.shader, ui.font);

    const hovered_stack = if (held != null) null else if (hovered) |slot| switch (slot.kind) {
        .inventory => inventory.slots[slot.index],
        .craft_input => crafting_grid[slot.index],
        .craft_result => craft_result,
    } else null;
    if (hovered_stack) |stack| try drawTooltip(ui, stack.displayName());

    gl.Disable(gl.BLEND);
    gl.Enable(gl.DEPTH_TEST);
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
    const org = origin(res);
    const slot = slots()[slots().len - 9];
    const left = (org[0] + slot.x - 1) * res.factor;
    const top = (org[1] + slot.y - 1) * res.factor;

    try std.testing.expectEqual(@as(?usize, slot.index), (slotAt(left, top, res) orelse return error.NoSlot).index);
    try std.testing.expectEqual(@as(?Slot, null), slotAt(left - res.factor, top, res));
    try std.testing.expectEqual(@as(?Slot, null), slotAt(left, top - res.factor, res));
}

test "clicking the background between slots hits no slot but is not outside" {
    const res = gui.scaledResolution(640, 480, 1000);
    const org = origin(res);
    const x = (org[0] + preview_anchor_x) * res.factor;
    const y = (org[1] + preview_anchor_y) * res.factor;

    try std.testing.expectEqual(@as(?Slot, null), slotAt(x, y, res));
    try std.testing.expect(!isOutside(x, y, res));
}

test "isOutside reports the region beyond the background rect" {
    const res = gui.scaledResolution(640, 480, 1000);
    const org = origin(res);

    try std.testing.expect(isOutside((org[0] - 1) * res.factor, org[1] * res.factor, res));
    try std.testing.expect(isOutside(org[0] * res.factor, (org[1] + height) * res.factor, res));
    try std.testing.expect(!isOutside(org[0] * res.factor, org[1] * res.factor, res));
}
