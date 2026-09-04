const std = @import("std");

const Atlas = @import("../Atlas.zig");
const gui = @import("../gui.zig");
const MeshBuilder = @import("../MeshBuilder.zig");

pub const list_top: f32 = 32;
pub const entry_height: f32 = 36;
pub const entry_padding: f32 = 4;
pub const entry_half_width: f32 = 110;
pub const dirt_tile_scale: f32 = 32;
pub const dirt_tint: [4]u8 = .{ 64, 64, 64, 255 };
pub const list_dirt_tint: [4]u8 = .{ 32, 32, 32, 255 };

const scrollbar_offset: f32 = 124;
const scrollbar_width: f32 = 6;
const scrollbar_track: [4]u8 = .{ 0, 0, 0, 255 };
const scrollbar_thumb: [4]u8 = .{ 128, 128, 128, 255 };
const scrollbar_highlight: [4]u8 = .{ 192, 192, 192, 255 };

pub fn List(comptime bottom_margin: f32) type {
    return struct {
        pub fn listBottom(res: gui.Scaled) f32 {
            return res.height - bottom_margin;
        }

        pub fn maxScroll(res: gui.Scaled, count: usize) f32 {
            const content = @as(f32, @floatFromInt(count)) * entry_height;
            const visible = listBottom(res) - list_top - entry_padding;
            const overflow = content - visible;
            return if (overflow < 0) @trunc(overflow / 2.0) else overflow;
        }

        pub fn clampScroll(res: gui.Scaled, count: usize, scroll: f32) f32 {
            return @min(@max(scroll, 0), maxScroll(res, count));
        }

        pub fn entryY(index: usize, scroll: f32) f32 {
            return list_top + entry_padding - scroll + @as(f32, @floatFromInt(index)) * entry_height;
        }

        pub fn rowAt(gx: f32, gy: f32, res: gui.Scaled, count: usize, scroll: f32) ?usize {
            const cx = @floor(res.width / 2.0);
            if (gy < list_top or gy >= listBottom(res)) return null;
            if (gx < cx - entry_half_width or gx > cx + entry_half_width) return null;

            const offset = gy - list_top + scroll - entry_padding;
            if (offset < 0) return null;
            const index: usize = @intFromFloat(offset / entry_height);
            return if (index < count) index else null;
        }

        pub fn scrollbarThumb(res: gui.Scaled, count: usize, scroll: f32) ?struct { y: f32, height: f32 } {
            const bottom = listBottom(res);
            const visible = bottom - list_top;
            const content = @as(f32, @floatFromInt(count)) * entry_height;
            const overflow = content - (visible - entry_padding);
            if (overflow <= 0) return null;

            var height = visible * visible / content;
            height = std.math.clamp(height, 32, visible - 8);
            const y = list_top + scroll * (visible - height) / overflow;
            return .{ .y = @max(y, list_top), .height = height };
        }

        pub fn scrollbarAt(mouse_x: f32, mouse_y: f32, res: gui.Scaled, count: usize) bool {
            if (scrollbarThumb(res, count, 0) == null) return false;
            const gx = mouse_x / res.factor;
            const gy = mouse_y / res.factor;
            const x = @floor(res.width / 2.0) + scrollbar_offset;
            return gx >= x and gx <= x + scrollbar_width and gy >= list_top and gy <= listBottom(res);
        }

        pub fn dragScroll(res: gui.Scaled, count: usize, scroll: f32, dy: f32) f32 {
            const thumb = scrollbarThumb(res, count, scroll) orelse return scroll;
            const travel = listBottom(res) - list_top - thumb.height;
            return clampScroll(res, count, scroll + dy * maxScroll(res, count) / travel);
        }

        pub fn appendScrollbar(mesh: *MeshBuilder, gpa: std.mem.Allocator, res: gui.Scaled, count: usize, scroll: f32) !void {
            const thumb = scrollbarThumb(res, count, scroll) orelse return;
            const x = @floor(res.width / 2.0) + scrollbar_offset;
            const bottom = listBottom(res);

            try gui.appendRectColor(mesh, gpa, x, list_top, scrollbar_width, bottom - list_top, gui.opaque_texel, scrollbar_track, res);
            try gui.appendRectColor(mesh, gpa, x, thumb.y, scrollbar_width, thumb.height, gui.opaque_texel, scrollbar_thumb, res);
            try gui.appendRectColor(mesh, gpa, x, thumb.y, scrollbar_width - 1, thumb.height - 1, gui.opaque_texel, scrollbar_highlight, res);
        }

        pub fn appendBackground(mesh: *MeshBuilder, gpa: std.mem.Allocator, res: gui.Scaled, scroll: f32) !void {
            const dirt_uv: Atlas.Uv = .{ .u0 = 0, .v0 = 0, .u1 = res.width / dirt_tile_scale, .v1 = res.height / dirt_tile_scale };
            try gui.appendRectColor(mesh, gpa, 0, 0, res.width, res.height, dirt_uv, dirt_tint, res);

            const bottom = listBottom(res);
            const list_uv: Atlas.Uv = .{
                .u0 = 0,
                .v0 = (list_top + scroll) / dirt_tile_scale,
                .u1 = res.width / dirt_tile_scale,
                .v1 = (bottom + scroll) / dirt_tile_scale,
            };
            try gui.appendRectColor(mesh, gpa, 0, list_top, res.width, bottom - list_top, list_uv, list_dirt_tint, res);
        }
    };
}
