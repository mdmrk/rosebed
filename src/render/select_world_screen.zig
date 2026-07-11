const std = @import("std");
const gl = @import("gl");
const world = @import("world");

const Atlas = @import("atlas.zig");
const MeshBuilder = @import("mesh_builder.zig");
const button = @import("button.zig");
const gui = @import("gui.zig");

const dirt_tile_scale: f32 = 32;
const dirt_tint: [4]u8 = .{ 64, 64, 64, 255 };
const list_dirt_tint: [4]u8 = .{ 32, 32, 32, 255 };
const title_color: [4]u8 = .{ 255, 255, 255, 255 };
const entry_name_color: [4]u8 = .{ 255, 255, 255, 255 };
const entry_detail_color: [4]u8 = .{ 128, 128, 128, 255 };
const selected_color: [4]u8 = .{ 128, 128, 128, 255 };
const scrollbar_track: [4]u8 = .{ 0, 0, 0, 255 };
const scrollbar_thumb: [4]u8 = .{ 128, 128, 128, 255 };
const scrollbar_highlight: [4]u8 = .{ 192, 192, 192, 255 };

pub const list_top: f32 = 32;
pub const entry_height: f32 = 36;
const list_bottom_margin: f32 = 64;
const entry_padding: f32 = 4;
const entry_half_width: f32 = 110;
const edge_shadow_height: f32 = 4;
const scrollbar_offset: f32 = 124;
const scrollbar_width: f32 = 6;

pub const Hit = union(enum) {
    entry: usize,
    select,
    rename,
    delete,
    create,
    cancel,
};

pub fn listBottom(res: gui.Scaled) f32 {
    return res.height - list_bottom_margin;
}

pub fn maxScroll(res: gui.Scaled, count: usize) f32 {
    const content = @as(f32, @floatFromInt(count)) * entry_height;
    const visible = listBottom(res) - list_top;
    return @max(0, content - visible);
}

fn buttons(res: gui.Scaled, has_selection: bool) [5]struct { button: button.Button, hit: Hit } {
    const cx = @floor(res.width / 2.0);
    const bottom = res.height;
    return .{
        .{ .button = .{ .x = cx - 154, .y = bottom - 52, .w = 150, .label = "Play Selected World", .enabled = has_selection }, .hit = .select },
        .{ .button = .{ .x = cx - 154, .y = bottom - 28, .w = 70, .label = "Rename", .enabled = has_selection }, .hit = .rename },
        .{ .button = .{ .x = cx - 74, .y = bottom - 28, .w = 70, .label = "Delete", .enabled = has_selection }, .hit = .delete },
        .{ .button = .{ .x = cx + 4, .y = bottom - 52, .w = 150, .label = "Create New World", .enabled = true }, .hit = .create },
        .{ .button = .{ .x = cx + 4, .y = bottom - 28, .w = 150, .label = "Cancel", .enabled = true }, .hit = .cancel },
    };
}

pub fn hitAt(mouse_x: f32, mouse_y: f32, res: gui.Scaled, count: usize, scroll: f32, has_selection: bool) ?Hit {
    const gx = mouse_x / res.factor;
    const gy = mouse_y / res.factor;

    for (buttons(res, has_selection)) |entry| {
        if (entry.button.enabled and button.contains(entry.button, gx, gy)) return entry.hit;
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

fn entryY(res: gui.Scaled, index: usize, scroll: f32) f32 {
    _ = res;
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

fn appendScrollbar(mesh: *MeshBuilder, gpa: std.mem.Allocator, res: gui.Scaled, count: usize, scroll: f32) !void {
    const thumb = scrollbarThumb(res, count, scroll) orelse return;
    const x = @floor(res.width / 2.0) + scrollbar_offset;
    const bottom = listBottom(res);

    try gui.appendRectColor(mesh, gpa, x, list_top, scrollbar_width, bottom - list_top, gui.opaque_texel, scrollbar_track, res);
    try gui.appendRectColor(mesh, gpa, x, thumb.y, scrollbar_width, thumb.height, gui.opaque_texel, scrollbar_thumb, res);
    try gui.appendRectColor(mesh, gpa, x, thumb.y, scrollbar_width - 1, thumb.height - 1, gui.opaque_texel, scrollbar_highlight, res);
}

pub fn formatDetail(buffer: []u8, folder: []const u8, last_played: i64, size_bytes: u64) []const u8 {
    const megabytes = @as(f32, @floatFromInt(size_bytes / 1024)) / 1024.0;
    if (last_played <= 0) {
        return std.fmt.bufPrint(buffer, "{s} ({d:.2} MB)", .{ folder, megabytes }) catch folder;
    }

    const seconds: u64 = @intCast(last_played);
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    const hours = day_seconds.getMinutesIntoHour();
    const am_or_pm = if (hours > 12) "PM" else "AM";
    const hours_12_format = if (hours > 12) hours - 12 else hours;

    return std.fmt.bufPrint(buffer, "{s} ({d}/{d}/{d:0>2} {d}:{d:0>2} {s}, {d:.2} MB)", .{
        folder,
        month_day.month.numeric(),
        month_day.day_index + 1,
        year_day.year % 100,
        hours_12_format,
        day_seconds.getMinutesIntoHour(),
        am_or_pm,
        megabytes,
    }) catch folder;
}

pub fn draw(
    ui: gui.Ui,
    summaries: []const world.save.Summary,
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
    const slot_left = cx - 92 - 16;

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
    var entry_text: MeshBuilder = .{};
    defer entry_text.deinit(ui.gpa);

    for (summaries, 0..) |summary, index| {
        const y = entryY(ui.res, index, scroll);
        const slot_height = entry_height - 4;
        if (y + slot_height < list_top or y > bottom) continue;

        if (selected != null and selected.? == index) {
            try gui.appendRectColor(&highlights, ui.gpa, cx - entry_half_width, y - 2, entry_half_width * 2, slot_height + 4, gui.opaque_texel, selected_color, ui.res);
            try gui.appendRectColor(&highlights, ui.gpa, cx - entry_half_width + 1, y - 1, entry_half_width * 2 - 2, slot_height + 2, gui.opaque_texel, .{ 0, 0, 0, 255 }, ui.res);
        }

        const name = if (summary.name.len > 0) summary.name else summary.folder;
        try gui.appendTextColor(&entry_text, ui.gpa, ui.font, name, slot_left + 2, y + 1, entry_name_color, ui.res);

        var detail_buffer: [96]u8 = undefined;
        const detail = formatDetail(&detail_buffer, summary.folder, summary.last_played, summary.size_bytes);
        try gui.appendTextColor(&entry_text, ui.gpa, ui.font, detail, slot_left + 2, y + 12, entry_detail_color, ui.res);
    }

    try gui.drawTexturedMesh(&highlights, ui.shader, ui.textures.gui);
    try gui.drawTexturedMesh(&entry_text, ui.shader, ui.font);

    var backgrounds: MeshBuilder = .{};
    defer backgrounds.deinit(ui.gpa);
    var text: MeshBuilder = .{};
    defer text.deinit(ui.gpa);

    try gui.drawEdgeBands(ui, list_top, bottom);
    try gui.appendEdgeShadows(&backgrounds, ui.gpa, ui.res, list_top, bottom, edge_shadow_height);

    try appendScrollbar(&backgrounds, ui.gpa, ui.res, summaries.len, scroll);

    for (buttons(ui.res, selected != null)) |entry| {
        const hovered = entry.button.enabled and button.contains(entry.button, gx, gy);
        try button.append(&backgrounds, &text, ui.gpa, ui.font, entry.button, hovered, ui.res);
    }

    const title = "Select World";
    const title_width: f32 = @floatFromInt(ui.font.stringWidth(title));
    try gui.appendTextColor(&text, ui.gpa, ui.font, title, @floor(ui.res.width / 2.0) - @floor(title_width / 2.0), 20, title_color, ui.res);

    try gui.drawTexturedMesh(&backgrounds, ui.shader, ui.textures.gui);
    try gui.drawTexturedMesh(&text, ui.shader, ui.font);

    gl.Disable(gl.BLEND);
    gl.Enable(gl.DEPTH_TEST);
}

fn rowClickY(res: gui.Scaled, index: usize) f32 {
    return (list_top + entry_padding + @as(f32, @floatFromInt(index)) * entry_height + 2) * res.factor;
}

test "clicking a list row returns its index, offset by the scroll position" {
    const res = gui.scaledResolution(640, 480, 1000);
    const cx = @floor(res.width / 2.0) * res.factor;
    try std.testing.expectEqual(@as(?Hit, .{ .entry = 0 }), hitAt(cx, rowClickY(res, 0), res, 3, 0, false));
    try std.testing.expectEqual(@as(?Hit, .{ .entry = 1 }), hitAt(cx, rowClickY(res, 1), res, 3, 0, false));
    try std.testing.expectEqual(@as(?Hit, .{ .entry = 1 }), hitAt(cx, rowClickY(res, 0), res, 3, entry_height, false));
}

test "clicking past the last row selects nothing" {
    const res = gui.scaledResolution(640, 480, 1000);
    const cx = @floor(res.width / 2.0) * res.factor;
    try std.testing.expectEqual(@as(?Hit, null), hitAt(cx, rowClickY(res, 2), res, 1, 0, false));
}

test "clicking beside the list, outside a row's width, selects nothing" {
    const res = gui.scaledResolution(640, 480, 1000);
    const outside = (@floor(res.width / 2.0) - entry_half_width - 4) * res.factor;
    try std.testing.expectEqual(@as(?Hit, null), hitAt(outside, rowClickY(res, 0), res, 3, 0, false));
}

test "the scrollbar thumb only appears once the list overflows" {
    const res = gui.scaledResolution(640, 480, 1000);
    try std.testing.expectEqual(@as(?@TypeOf(scrollbarThumb(res, 0, 0).?), null), scrollbarThumb(res, 1, 0));

    const thumb = scrollbarThumb(res, 40, 0).?;
    try std.testing.expect(thumb.height >= 32);
    try std.testing.expectEqual(list_top, thumb.y);

    const scrolled = scrollbarThumb(res, 40, maxScroll(res, 40)).?;
    try std.testing.expect(scrolled.y > thumb.y);
}

test "the action buttons only respond once a world is selected" {
    const res = gui.scaledResolution(640, 480, 1000);
    const select_y = (res.height - 52 + 10) * res.factor;
    const cx = @floor(res.width / 2.0);

    try std.testing.expectEqual(@as(?Hit, null), hitAt((cx - 100) * res.factor, select_y, res, 2, 0, false));
    try std.testing.expectEqual(@as(?Hit, .select), hitAt((cx - 100) * res.factor, select_y, res, 2, 0, true));
    try std.testing.expectEqual(@as(?Hit, .create), hitAt((cx + 80) * res.factor, select_y, res, 2, 0, false));
}

test "cancel sits below create" {
    const res = gui.scaledResolution(640, 480, 1000);
    const cx = @floor(res.width / 2.0);
    try std.testing.expectEqual(@as(?Hit, .cancel), hitAt((cx + 80) * res.factor, (res.height - 28 + 10) * res.factor, res, 0, 0, false));
}

test "scrolling is bounded by how much list overflows the visible area" {
    const res = gui.scaledResolution(640, 480, 1000);
    try std.testing.expectEqual(@as(f32, 0), maxScroll(res, 0));
    try std.testing.expectEqual(@as(f32, 0), maxScroll(res, 1));
    try std.testing.expect(maxScroll(res, 100) > 0);
}

test "the detail line shows the folder, a date and a size" {
    var buffer: [96]u8 = undefined;
    const detail = formatDetail(&buffer, "My World", 1700000000, 3 * 1024 * 1024);
    try std.testing.expect(std.mem.startsWith(u8, detail, "My World ("));
    try std.testing.expect(std.mem.indexOf(u8, detail, "11/14/23") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "3.00 MB") != null);
}

test "a world that has never been played shows only its size" {
    var buffer: [96]u8 = undefined;
    const detail = formatDetail(&buffer, "Fresh", 0, 0);
    try std.testing.expectEqualStrings("Fresh (0.00 MB)", detail);
}

test "the buttons and title use the strings from the vanilla language file" {
    const res = gui.scaledResolution(640, 480, 1000);
    const entries = buttons(res, true);
    try std.testing.expectEqualStrings("Play Selected World", entries[0].button.label);
    try std.testing.expectEqualStrings("Rename", entries[1].button.label);
    try std.testing.expectEqualStrings("Delete", entries[2].button.label);
    try std.testing.expectEqualStrings("Create New World", entries[3].button.label);
    try std.testing.expectEqualStrings("Cancel", entries[4].button.label);
}
