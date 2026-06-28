const std = @import("std");

const Font = @import("font.zig");
const MeshBuilder = @import("mesh_builder.zig");
const hud = @import("hud.zig");

const gui_texture_size: f32 = 256;
const tex_row: f32 = 46;

pub const height: f32 = 20;

const text_normal: [4]u8 = .{ 224, 224, 224, 255 };
const text_hover: [4]u8 = .{ 255, 255, 160, 255 };
const text_disabled: [4]u8 = .{ 160, 160, 160, 255 };

pub const Button = struct { x: f32, y: f32, w: f32, label: []const u8, enabled: bool };

pub fn contains(button: Button, gx: f32, gy: f32) bool {
    return gx >= button.x and gx < button.x + button.w and gy >= button.y and gy < button.y + height;
}

fn hoverState(button: Button, hovered: bool) f32 {
    if (!button.enabled) return 0;
    if (hovered) return 2;
    return 1;
}

pub fn append(
    bg: *MeshBuilder,
    text: *MeshBuilder,
    gpa: std.mem.Allocator,
    font: Font,
    button: Button,
    hovered: bool,
    scaled_width: f32,
    scaled_height: f32,
) !void {
    const row = tex_row + hoverState(button, hovered) * height;
    const half = button.w / 2.0;
    try hud.appendRect(bg, gpa, button.x, button.y, half, height, hud.pixelUv(0, row, half, height, gui_texture_size, gui_texture_size), scaled_width, scaled_height);
    try hud.appendRect(bg, gpa, button.x + half, button.y, half, height, hud.pixelUv(200 - half, row, half, height, gui_texture_size, gui_texture_size), scaled_width, scaled_height);

    const color = if (!button.enabled) text_disabled else if (hovered) text_hover else text_normal;
    const label_width: f32 = @floatFromInt(font.stringWidth(button.label));
    const text_x = button.x + button.w / 2.0 - label_width / 2.0;
    const text_y = button.y + (height - Font.glyph_size) / 2.0;
    try hud.appendTextColor(text, gpa, font, button.label, text_x, text_y, color, scaled_width, scaled_height);
}

test "contains hits inside the button rect and misses outside" {
    const b: Button = .{ .x = 60, .y = 68, .w = 200, .label = "x", .enabled = true };
    try std.testing.expect(contains(b, 160, 78));
    try std.testing.expect(!contains(b, 160, 90));
    try std.testing.expect(!contains(b, 40, 78));
}
