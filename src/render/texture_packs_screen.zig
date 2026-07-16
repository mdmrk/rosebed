const std = @import("std");
const gl = @import("gl");

const Atlas = @import("atlas.zig");
const MeshBuilder = @import("mesh_builder.zig");
const button = @import("button.zig");
const gui = @import("gui.zig");
const texture_pack = @import("texture_pack.zig");

const dirt_tile_scale: f32 = 32;
const dirt_tint: [4]u8 = .{ 64, 64, 64, 255 };
const list_dirt_tint: [4]u8 = .{ 32, 32, 32, 255 };
const title_color: [4]u8 = .{ 255, 255, 255, 255 };
const folder_info_color: [4]u8 = .{ 128, 128, 128, 255 };
const name_color: [4]u8 = .{ 255, 255, 255, 255 };
const description_color: [4]u8 = .{ 128, 128, 128, 255 };
const selected_color: [4]u8 = .{ 128, 128, 128, 255 };
const scrollbar_track: [4]u8 = .{ 0, 0, 0, 255 };
const scrollbar_thumb: [4]u8 = .{ 128, 128, 128, 255 };
const scrollbar_highlight: [4]u8 = .{ 192, 192, 192, 255 };

pub const list_top: f32 = 32;
pub const entry_height: f32 = 36;
const list_bottom_margin: f32 = 51;
const entry_half_width: f32 = 110;
const entry_padding: f32 = 4;
const row_height: f32 = entry_height - 4;
const thumbnail_size: f32 = 32;
const text_left_gap: f32 = thumbnail_size + 2;
const edge_shadow_height: f32 = 4;
const scrollbar_offset: f32 = 124;
const scrollbar_width: f32 = 6;

const title = "Select Texture Pack";
const folder_info = "(Place texture pack files here)";

pub const Hit = union(enum) {
    entry: usize,
    open_folder,
    done,
};

pub fn listBottom(res: gui.Scaled) f32 {
    return res.height - list_bottom_margin;
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

fn buttons(res: gui.Scaled) [2]struct { button: button.Button, hit: Hit } {
    const cx = @floor(res.width / 2.0);
    const y = res.height - 48;
    return .{
        .{ .button = .{ .x = cx - 154, .y = y, .w = 150, .label = "Open texture pack folder", .enabled = true }, .hit = .open_folder },
        .{ .button = .{ .x = cx + 4, .y = y, .w = 150, .label = "Done", .enabled = true }, .hit = .done },
    };
}

pub fn hitAt(mouse_x: f32, mouse_y: f32, res: gui.Scaled, count: usize, scroll: f32) ?Hit {
    const gx = mouse_x / res.factor;
    const gy = mouse_y / res.factor;

    for (buttons(res)) |entry| {
        if (button.contains(entry.button, gx, gy)) return entry.hit;
    }

    const cx = @floor(res.width / 2.0);
    if (gy >= list_top and gy < listBottom(res) and gx >= cx - entry_half_width and gx <= cx + entry_half_width) {
        const offset = gy - list_top + scroll - entry_padding;
        if (offset < 0) return null;
        const index: usize = @intFromFloat(offset / entry_height);
        if (index < count) return .{ .entry = index };
    }
    return null;
}

fn entryY(index: usize, scroll: f32) f32 {
    return list_top + entry_padding - scroll + @as(f32, @floatFromInt(index)) * entry_height;
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

fn appendScrollbar(mesh: *MeshBuilder, gpa: std.mem.Allocator, res: gui.Scaled, count: usize, scroll: f32) !void {
    const thumb = scrollbarThumb(res, count, scroll) orelse return;
    const x = @floor(res.width / 2.0) + scrollbar_offset;
    const bottom = listBottom(res);

    try gui.appendRectColor(mesh, gpa, x, list_top, scrollbar_width, bottom - list_top, gui.opaque_texel, scrollbar_track, res);
    try gui.appendRectColor(mesh, gpa, x, thumb.y, scrollbar_width, thumb.height, gui.opaque_texel, scrollbar_thumb, res);
    try gui.appendRectColor(mesh, gpa, x, thumb.y, scrollbar_width - 1, thumb.height - 1, gui.opaque_texel, scrollbar_highlight, res);
}

const whole_texture: Atlas.Uv = .{ .u0 = 0, .v0 = 0, .u1 = 1, .v1 = 1 };

pub fn draw(
    ui: gui.Ui,
    packs: []const texture_pack.Pack,
    thumbnails: []const Atlas,
    selected: ?usize,
    scroll: f32,
) !void {
    const gx = ui.mouse_x / ui.res.factor;
    const gy = ui.mouse_y / ui.res.factor;

    gl.Disable(gl.DEPTH_TEST);
    gl.Enable(gl.BLEND);
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

    const bottom = listBottom(ui.res);
    const cx = @floor(ui.res.width / 2.0);
    const slot_left = cx - entry_half_width + 2;

    var back: MeshBuilder = .{};
    defer back.deinit(ui.gpa);

    const dirt_uv: Atlas.Uv = .{ .u0 = 0, .v0 = 0, .u1 = ui.res.width / dirt_tile_scale, .v1 = ui.res.height / dirt_tile_scale };
    try gui.appendRectColor(&back, ui.gpa, 0, 0, ui.res.width, ui.res.height, dirt_uv, dirt_tint, ui.res);

    const list_uv: Atlas.Uv = .{
        .u0 = 0,
        .v0 = (list_top + scroll) / dirt_tile_scale,
        .u1 = ui.res.width / dirt_tile_scale,
        .v1 = (bottom + scroll) / dirt_tile_scale,
    };
    try gui.appendRectColor(&back, ui.gpa, 0, list_top, ui.res.width, bottom - list_top, list_uv, list_dirt_tint, ui.res);
    try gui.drawTexturedMesh(&back, ui.shader, ui.textures.dirt);

    var highlights: MeshBuilder = .{};
    defer highlights.deinit(ui.gpa);

    for (packs, 0..) |_, index| {
        const y = entryY(index, scroll);
        if (y + row_height < list_top or y > bottom) continue;
        if (selected == null or selected.? != index) continue;

        try gui.appendRectColor(&highlights, ui.gpa, cx - entry_half_width, y - 2, entry_half_width * 2, entry_height, gui.opaque_texel, selected_color, ui.res);
        try gui.appendRectColor(&highlights, ui.gpa, cx - entry_half_width + 1, y - 1, entry_half_width * 2 - 2, entry_height - 2, gui.opaque_texel, .{ 0, 0, 0, 255 }, ui.res);
    }
    try gui.drawTexturedMesh(&highlights, ui.shader, ui.textures.gui);

    for (packs, thumbnails, 0..) |_, thumbnail, index| {
        const y = entryY(index, scroll);
        if (y + row_height < list_top or y > bottom) continue;

        var icon: MeshBuilder = .{};
        defer icon.deinit(ui.gpa);
        try gui.appendRect(&icon, ui.gpa, slot_left, y, thumbnail_size, thumbnail_size, whole_texture, ui.res);
        try gui.drawTexturedMesh(&icon, ui.shader, thumbnail);
    }

    var entry_text: MeshBuilder = .{};
    defer entry_text.deinit(ui.gpa);

    for (packs, 0..) |pack, index| {
        const y = entryY(index, scroll);
        if (y + row_height < list_top or y > bottom) continue;

        const text_x = slot_left + text_left_gap;
        try gui.appendTextColor(&entry_text, ui.gpa, ui.font, pack.name, text_x, y + 1, name_color, ui.res);
        try gui.appendTextColor(&entry_text, ui.gpa, ui.font, pack.lines[0], text_x, y + 12, description_color, ui.res);
        try gui.appendTextColor(&entry_text, ui.gpa, ui.font, pack.lines[1], text_x, y + 22, description_color, ui.res);
    }
    try gui.drawTexturedMesh(&entry_text, ui.shader, ui.font);

    var backgrounds: MeshBuilder = .{};
    defer backgrounds.deinit(ui.gpa);
    var text: MeshBuilder = .{};
    defer text.deinit(ui.gpa);

    try gui.drawEdgeBands(ui, list_top, bottom);
    try gui.appendEdgeShadows(&backgrounds, ui.gpa, ui.res, list_top, bottom, edge_shadow_height);
    try appendScrollbar(&backgrounds, ui.gpa, ui.res, packs.len, scroll);

    for (buttons(ui.res)) |entry| {
        const hovered = button.contains(entry.button, gx, gy);
        try button.append(&backgrounds, &text, ui.gpa, ui.font, entry.button, hovered, ui.res);
    }

    const title_width: f32 = @floatFromInt(ui.font.stringWidth(title));
    try gui.appendTextColor(&text, ui.gpa, ui.font, title, cx - @floor(title_width / 2.0), 16, title_color, ui.res);

    const info_width: f32 = @floatFromInt(ui.font.stringWidth(folder_info));
    try gui.appendTextColor(&text, ui.gpa, ui.font, folder_info, cx - 77 - @floor(info_width / 2.0), ui.res.height - 26, folder_info_color, ui.res);

    try gui.drawTexturedMesh(&backgrounds, ui.shader, ui.textures.gui);
    try gui.drawTexturedMesh(&text, ui.shader, ui.font);

    gl.Disable(gl.BLEND);
    gl.Enable(gl.DEPTH_TEST);
}

fn rowClickY(res: gui.Scaled, index: usize) f32 {
    return (list_top + entry_padding + @as(f32, @floatFromInt(index)) * entry_height + 2) * res.factor;
}

test "clicking a row returns its index, offset by the scroll position" {
    const res = gui.scaledResolution(640, 480, 1000);
    const cx = @floor(res.width / 2.0) * res.factor;
    try std.testing.expectEqual(@as(?Hit, .{ .entry = 0 }), hitAt(cx, rowClickY(res, 0), res, 3, 0));
    try std.testing.expectEqual(@as(?Hit, .{ .entry = 1 }), hitAt(cx, rowClickY(res, 1), res, 3, 0));
    try std.testing.expectEqual(@as(?Hit, .{ .entry = 1 }), hitAt(cx, rowClickY(res, 0), res, 3, entry_height));
}

test "clicking past the last pack selects nothing" {
    const res = gui.scaledResolution(640, 480, 1000);
    const cx = @floor(res.width / 2.0) * res.factor;
    try std.testing.expectEqual(@as(?Hit, null), hitAt(cx, rowClickY(res, 2), res, 1, 0));
}

test "clicking to the side of the list misses every row" {
    const res = gui.scaledResolution(640, 480, 1000);
    const outside = (@floor(res.width / 2.0) + entry_half_width + 8) * res.factor;
    try std.testing.expectEqual(@as(?Hit, null), hitAt(outside, rowClickY(res, 0), res, 3, 0));
}

test "the two buttons sit side by side under the list" {
    const res = gui.scaledResolution(640, 480, 1000);
    const pair = buttons(res);
    try std.testing.expectEqual(pair[0].button.y, pair[1].button.y);
    try std.testing.expect(pair[0].button.x + pair[0].button.w < pair[1].button.x);
    try std.testing.expect(pair[0].button.y >= listBottom(res));

    const centre_of = struct {
        fn at(b: button.Button, res_inner: gui.Scaled) [2]f32 {
            return .{ (b.x + b.w / 2) * res_inner.factor, (b.y + 10) * res_inner.factor };
        }
    };
    const open = centre_of.at(pair[0].button, res);
    const done = centre_of.at(pair[1].button, res);
    try std.testing.expectEqual(@as(?Hit, .open_folder), hitAt(open[0], open[1], res, 3, 0));
    try std.testing.expectEqual(@as(?Hit, .done), hitAt(done[0], done[1], res, 3, 0));
}

test "a list that fits needs no scrollbar, and one that overflows gets one" {
    const res = gui.scaledResolution(640, 480, 1000);
    try std.testing.expectEqual(@as(f32, 0), maxScroll(res, 2));
    try std.testing.expect(scrollbarThumb(res, 2, 0) == null);

    const many = 40;
    try std.testing.expect(maxScroll(res, many) > 0);
    try std.testing.expect(scrollbarThumb(res, many, 0) != null);
}

test "dragging the thumb the length of its travel scrolls the whole list" {
    const res = gui.scaledResolution(640, 480, 1000);
    const x = (@floor(res.width / 2.0) + scrollbar_offset + 2) * res.factor;
    try std.testing.expect(scrollbarAt(x, (list_top + 20) * res.factor, res, 40));
    try std.testing.expect(!scrollbarAt(x, (list_top + 20) * res.factor, res, 2));

    const thumb = scrollbarThumb(res, 40, 0).?;
    const travel = listBottom(res) - list_top - thumb.height;
    try std.testing.expectEqual(maxScroll(res, 40), dragScroll(res, 40, 0, travel));
    try std.testing.expectEqual(@as(f32, 0), dragScroll(res, 40, 0, -10));
}

test "a row scrolled above the list is not clickable through the header" {
    const res = gui.scaledResolution(640, 480, 1000);
    const cx = @floor(res.width / 2.0) * res.factor;
    try std.testing.expectEqual(@as(?Hit, null), hitAt(cx, (list_top - 4) * res.factor, res, 3, 0));
}

test "rows start four pixels below the top of the list, as GuiSlot does" {
    try std.testing.expectEqual(list_top + entry_padding, entryY(0, 0));
    try std.testing.expectEqual(list_top + entry_padding + entry_height, entryY(1, 0));
    try std.testing.expectEqual(list_top, entryY(0, entry_padding));
}

test "the row content is the slot height less its four pixel gap" {
    try std.testing.expectEqual(@as(f32, 32), row_height);
}

test "the list content sits where the original puts it, at half the width less 108" {
    const res = gui.scaledResolution(640, 480, 1000);
    const cx = @floor(res.width / 2.0);
    try std.testing.expectEqual(cx - 92 - 16, cx - entry_half_width + 2);
    try std.testing.expectEqual(cx - 110, cx - entry_half_width);
    try std.testing.expectEqual(cx + 124, cx + scrollbar_offset);
}

test "the last row can be scrolled to sit just above the bottom of the list" {
    const res = gui.scaledResolution(640, 480, 1000);
    const count = 40;
    const limit = maxScroll(res, count);
    const last = entryY(count - 1, limit);
    try std.testing.expectEqual(listBottom(res) - row_height, last);
}

test "a list too short to fill the view is pushed down to sit centred in it" {
    const res = gui.scaledResolution(640, 480, 1000);
    const visible = listBottom(res) - list_top - entry_padding;

    for ([_]usize{ 1, 2, 3 }) |count| {
        const leftover = visible - @as(f32, @floatFromInt(count)) * entry_height;
        const settled = clampScroll(res, count, 0);
        try std.testing.expectEqual(@trunc(-leftover / 2.0), settled);

        const above = entryY(0, settled) - list_top - entry_padding;
        const below = listBottom(res) - entryY(count, settled);
        try std.testing.expectApproxEqAbs(above, below, 1.0);
    }
}

test "the one Default pack alone sits in the middle of the list, not at its top" {
    const res = gui.scaledResolution(640, 480, 1000);
    const settled = clampScroll(res, 1, 0);
    try std.testing.expect(settled < 0);
    try std.testing.expect(entryY(0, settled) > list_top + entry_padding);
}

test "a list long enough to overflow scrolls from the top instead of centring" {
    const res = gui.scaledResolution(640, 480, 1000);
    try std.testing.expectEqual(@as(f32, 0), clampScroll(res, 100, 0));
    try std.testing.expectEqual(list_top + entry_padding, entryY(0, clampScroll(res, 100, 0)));
    try std.testing.expect(maxScroll(res, 100) > 0);
}

test "scrolling a centred list stays put, since it has nowhere to go" {
    const res = gui.scaledResolution(640, 480, 1000);
    const settled = clampScroll(res, 2, 0);
    try std.testing.expectEqual(settled, clampScroll(res, 2, settled - entry_height));
    try std.testing.expectEqual(settled, clampScroll(res, 2, settled + entry_height));
}

test "clicking a centred row still finds it at the place it was drawn" {
    const res = gui.scaledResolution(640, 480, 1000);
    const cx = @floor(res.width / 2.0) * res.factor;
    const settled = clampScroll(res, 2, 0);

    for ([_]usize{ 0, 1 }) |index| {
        const drawn_y = (entryY(index, settled) + 2) * res.factor;
        try std.testing.expectEqual(@as(?Hit, .{ .entry = index }), hitAt(cx, drawn_y, res, 2, settled));
    }
}
