const std = @import("std");

const Font = @import("font.zig");
const gui = @import("gui.zig");
const MeshBuilder = @import("mesh_builder.zig");

const gui_texture_size: f32 = 256;
const tex_row: f32 = 46;

pub const height: f32 = 20;

pub const text_normal: [4]u8 = .{ 224, 224, 224, 255 };
pub const text_hover: [4]u8 = .{ 255, 255, 160, 255 };
pub const text_disabled: [4]u8 = .{ 160, 160, 160, 255 };

pub const Button = struct { x: f32, y: f32, w: f32, label: []const u8, enabled: bool };

pub fn contains(button: Button, gx: f32, gy: f32) bool {
    return gx >= button.x and gx < button.x + button.w and gy >= button.y and gy < button.y + height;
}

fn hoverState(button: Button, hovered: bool) f32 {
    if (!button.enabled) return 0;
    if (hovered) return 2;
    return 1;
}

pub fn appendBackground(
    bg: *MeshBuilder,
    gpa: std.mem.Allocator,
    x: f32,
    y: f32,
    w: f32,
    state: f32,
    res: gui.Scaled,
) !void {
    const row = tex_row + state * height;
    const half = w / 2.0;
    try gui.appendRect(bg, gpa, x, y, half, height, gui.pixelUv(0, row, half, height, gui_texture_size, gui_texture_size), res);
    try gui.appendRect(bg, gpa, x + half, y, half, height, gui.pixelUv(200 - half, row, half, height, gui_texture_size, gui_texture_size), res);
}

pub fn appendLabel(
    text: *MeshBuilder,
    gpa: std.mem.Allocator,
    font: Font,
    x: f32,
    y: f32,
    w: f32,
    label: []const u8,
    color: [4]u8,
    res: gui.Scaled,
) !void {
    const label_width: f32 = @floatFromInt(font.stringWidth(label));
    const text_x = x + @floor(w / 2.0) - @floor(label_width / 2.0);
    const text_y = y + (height - Font.glyph_size) / 2.0;
    try gui.appendTextColor(text, gpa, font, label, text_x, text_y, color, res);
}

pub fn append(
    bg: *MeshBuilder,
    text: *MeshBuilder,
    gpa: std.mem.Allocator,
    font: Font,
    button: Button,
    hovered: bool,
    res: gui.Scaled,
) !void {
    try appendBackground(bg, gpa, button.x, button.y, button.w, hoverState(button, hovered), res);
    const color = if (!button.enabled) text_disabled else if (hovered) text_hover else text_normal;
    try appendLabel(text, gpa, font, button.x, button.y, button.w, button.label, color, res);
}

test "contains hits inside the button rect and misses outside" {
    const b: Button = .{ .x = 60, .y = 68, .w = 200, .label = "x", .enabled = true };
    try std.testing.expect(contains(b, 160, 78));
    try std.testing.expect(!contains(b, 160, 90));
    try std.testing.expect(!contains(b, 40, 78));
}
