const std = @import("std");
const gl = @import("gl");
const game = @import("game");

const Atlas = @import("atlas.zig");
const Font = @import("font.zig");
const MeshBuilder = @import("mesh_builder.zig");
const MobModel = @import("mob_model.zig");
const Shader = @import("shader.zig");
const hud = @import("hud.zig");

pub const width: f32 = 176;
pub const height: f32 = 166;
const slot_pitch: f32 = 18;
const texture_size: f32 = 256;

const preview_anchor_x: f32 = 51;
const preview_anchor_y: f32 = 75;
const preview_pitch_anchor_y: f32 = 50;
const preview_tracking_divisor: f32 = 40;
const preview_pixels_per_meter: f32 = 30;

fn appendPlayerPreview(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    parts: []const MobModel.Part,
    head_index: usize,
    tex_width: f32,
    tex_height: f32,
    anchor_x: f32,
    anchor_y: f32,
    dx: f32,
    dy: f32,
    scaled_width: f32,
    scaled_height: f32,
) !void {
    const body_yaw = std.math.atan(dx / preview_tracking_divisor) * (20.0 * std.math.pi / 180.0);
    const head_yaw = std.math.atan(dx / preview_tracking_divisor) * (40.0 * std.math.pi / 180.0);
    const pitch = -std.math.atan(dy / preview_tracking_divisor) * (20.0 * std.math.pi / 180.0);

    const start = mesh.vertices.items.len;
    for (parts, 0..) |part, i| {
        var p = part;
        var yaw = body_yaw;
        if (i == head_index) {
            yaw = head_yaw;
            p.rotate_x = pitch;
        }
        try MobModel.appendPart(mesh, gpa, p, tex_width, tex_height, .{ 0, 0, 0 }, yaw);
    }

    for (mesh.vertices.items[start..]) |*v| {
        const screen_x = anchor_x + v.x * preview_pixels_per_meter;
        const screen_y = anchor_y - v.y * preview_pixels_per_meter;
        const ndc = hud.toNdc(screen_x, screen_y, scaled_width, scaled_height);
        v.x = ndc[0];
        v.y = ndc[1];
        v.z = 0;
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

pub fn origin(screen_width: f32, screen_height: f32) [2]f32 {
    const scaled_width = screen_width / hud.gui_scale;
    const scaled_height = screen_height / hud.gui_scale;
    return .{ scaled_width / 2.0 - width / 2.0, scaled_height / 2.0 - height / 2.0 };
}

/// Returns the inventory slot under the given window-pixel mouse position, if any.
pub fn slotAt(mouse_x: f32, mouse_y: f32, screen_width: f32, screen_height: f32) ?Slot {
    const org = origin(screen_width, screen_height);
    const gx = mouse_x / hud.gui_scale - org[0];
    const gy = mouse_y / hud.gui_scale - org[1];
    for (slots()) |slot| {
        if (gx >= slot.x and gx < slot.x + hud.icon_size and gy >= slot.y and gy < slot.y + hud.icon_size) {
            return slot;
        }
    }
    return null;
}

pub fn draw(
    gpa: std.mem.Allocator,
    icon_shader: Shader,
    background_texture: Atlas,
    atlas: Atlas,
    items_texture: Atlas,
    font: Font,
    player_texture: Atlas,
    player_parts: []const MobModel.Part,
    player_head_index: usize,
    player_tex_width: f32,
    player_tex_height: f32,
    inventory: game.Inventory,
    crafting_grid: [game.crafting.grid_size * game.crafting.grid_size]?game.Inventory.ItemStack,
    held: ?game.Inventory.ItemStack,
    mouse_x: f32,
    mouse_y: f32,
    screen_width: f32,
    screen_height: f32,
) !void {
    const scaled_width = screen_width / hud.gui_scale;
    const scaled_height = screen_height / hud.gui_scale;
    const org = origin(screen_width, screen_height);

    gl.Disable(gl.DEPTH_TEST);
    gl.Enable(gl.BLEND);
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

    var background: MeshBuilder = .{};
    defer background.deinit(gpa);
    try hud.appendRect(&background, gpa, org[0], org[1], width, height, hud.pixelUv(0, 0, width, height, texture_size, texture_size), scaled_width, scaled_height);
    try hud.drawTexturedMesh(&background, icon_shader, background_texture);

    var preview: MeshBuilder = .{};
    defer preview.deinit(gpa);
    const preview_anchor = .{ org[0] + preview_anchor_x, org[1] + preview_anchor_y };
    const preview_dx = preview_anchor[0] - mouse_x / hud.gui_scale;
    const preview_dy = (preview_anchor[1] - preview_pitch_anchor_y) - mouse_y / hud.gui_scale;
    try appendPlayerPreview(
        &preview,
        gpa,
        player_parts,
        player_head_index,
        player_tex_width,
        player_tex_height,
        preview_anchor[0],
        preview_anchor[1],
        preview_dx,
        preview_dy,
        scaled_width,
        scaled_height,
    );
    try hud.drawTexturedMesh(&preview, icon_shader, player_texture);

    var block_icons: MeshBuilder = .{};
    defer block_icons.deinit(gpa);
    var item_icons: MeshBuilder = .{};
    defer item_icons.deinit(gpa);
    var text: MeshBuilder = .{};
    defer text.deinit(gpa);

    const craft_result = game.crafting.findMatch(crafting_grid);
    for (slots()) |slot| {
        const stack = switch (slot.kind) {
            .inventory => inventory.slots[slot.index],
            .craft_input => crafting_grid[slot.index],
            .craft_result => craft_result,
        } orelse continue;
        try hud.appendStackIcon(&block_icons, &item_icons, &text, gpa, font, stack, org[0] + slot.x, org[1] + slot.y, scaled_width, scaled_height);
    }

    if (held) |stack| {
        const hx = mouse_x / hud.gui_scale - hud.icon_size / 2.0;
        const hy = mouse_y / hud.gui_scale - hud.icon_size / 2.0;
        try hud.appendStackIcon(&block_icons, &item_icons, &text, gpa, font, stack, hx, hy, scaled_width, scaled_height);
    }

    try hud.drawTexturedMesh(&block_icons, icon_shader, atlas);
    try hud.drawTexturedMesh(&item_icons, icon_shader, items_texture);
    try hud.drawTexturedMesh(&text, icon_shader, font);

    gl.Disable(gl.BLEND);
    gl.Enable(gl.DEPTH_TEST);
}
