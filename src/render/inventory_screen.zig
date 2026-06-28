const std = @import("std");
const gl = @import("gl");
const game = @import("game");

const Atlas = @import("atlas.zig");
const Font = @import("font.zig");
const MeshBuilder = @import("mesh_builder.zig");
const Shader = @import("shader.zig");
const hud = @import("hud.zig");

pub const width: f32 = 176;
pub const height: f32 = 166;
const slot_pitch: f32 = 18;
const texture_size: f32 = 256;

pub const Slot = struct { x: f32, y: f32, index: usize };

pub fn slots() [36]Slot {
    var result: [36]Slot = undefined;
    var n: usize = 0;
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

/// Returns the inventory slot index under the given window-pixel mouse position, if any.
pub fn slotAt(mouse_x: f32, mouse_y: f32, screen_width: f32, screen_height: f32) ?usize {
    const org = origin(screen_width, screen_height);
    const gx = mouse_x / hud.gui_scale - org[0];
    const gy = mouse_y / hud.gui_scale - org[1];
    for (slots()) |slot| {
        if (gx >= slot.x and gx < slot.x + hud.icon_size and gy >= slot.y and gy < slot.y + hud.icon_size) {
            return slot.index;
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
    inventory: game.Inventory,
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

    var block_icons: MeshBuilder = .{};
    defer block_icons.deinit(gpa);
    var item_icons: MeshBuilder = .{};
    defer item_icons.deinit(gpa);
    var text: MeshBuilder = .{};
    defer text.deinit(gpa);

    for (slots()) |slot| {
        const stack = inventory.slots[slot.index] orelse continue;
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
