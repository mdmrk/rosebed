const std = @import("std");

const sdl3 = @import("sdl3");
const world = @import("world");

const button = @import("../button.zig");
const gui = @import("../gui.zig");
const MeshBuilder = @import("../MeshBuilder.zig");
const scroll_list = @import("scroll_list.zig");
const list_top = scroll_list.list_top;
pub const entry_height = scroll_list.entry_height;
const entry_padding = scroll_list.entry_padding;
const entry_half_width = scroll_list.entry_half_width;

const title_color: [4]u8 = .{ 255, 255, 255, 255 };
const entry_name_color: [4]u8 = .{ 255, 255, 255, 255 };
const entry_detail_color: [4]u8 = .{ 128, 128, 128, 255 };
const selected_color: [4]u8 = .{ 128, 128, 128, 255 };

const list_bottom_margin: f32 = 64;
const edge_shadow_height: f32 = 4;

pub const Hit = union(enum) {
    entry: usize,
    select,
    rename,
    delete,
    create,
    cancel,
};

pub const double_click_ms: u64 = 250;

pub fn isDoubleClick(selected: ?usize, index: usize, now_ms: u64, last_click_ms: u64) bool {
    return selected == index and now_ms -% last_click_ms < double_click_ms;
}

const scrollbar_offset: f32 = 124;

const list = scroll_list.List(list_bottom_margin);

pub const listBottom = list.listBottom;
pub const maxScroll = list.maxScroll;
pub const clampScroll = list.clampScroll;
pub const scrollbarThumb = list.scrollbarThumb;
pub const scrollbarAt = list.scrollbarAt;
pub const dragScroll = list.dragScroll;
const entryY = list.entryY;
const appendScrollbar = list.appendScrollbar;

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

    const bar = buttons(res, has_selection);
    if (button.indexAt(bar, gx, gy)) |index| return bar[index].hit;

    if (list.rowAt(gx, gy, res, count, scroll)) |index| return .{ .entry = index };
    return null;
}

pub fn localOffsetSeconds(last_played: i64) i32 {
    const stamp: sdl3.time.Time = .{ .value = last_played * std.time.ns_per_ms };
    const local = sdl3.time.DateTime.fromTime(stamp, true) catch return 0;
    return local.utc_offset;
}

pub fn formatDetail(buffer: []u8, folder: []const u8, last_played: i64, utc_offset_seconds: i32, size_bytes: u64) []const u8 {
    const megabytes = @as(f32, @floatFromInt(size_bytes / 1024)) / 1024.0;
    if (last_played <= 0) {
        return std.fmt.bufPrint(buffer, "{s} ({d:.2} MB)", .{ folder, megabytes }) catch folder;
    }

    const local = @divFloor(last_played, std.time.ms_per_s) + utc_offset_seconds;
    if (local <= 0) {
        return std.fmt.bufPrint(buffer, "{s} ({d:.2} MB)", .{ folder, megabytes }) catch folder;
    }
    const seconds: u64 = @intCast(local);
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    const hours = day_seconds.getHoursIntoDay();
    const am_or_pm = if (hours >= 12) "PM" else "AM";
    const hours_12_format = if (hours % 12 == 0) 12 else hours % 12;

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

    gui.beginOverlay();

    const bottom = listBottom(ui.res);
    const cx = @floor(ui.res.width / 2.0);
    const slot_left = cx - 92 - 16;

    var back: MeshBuilder = .{};
    defer back.deinit(ui.gpa);

    try list.appendBackground(&back, ui.gpa, ui.res, scroll);
    try gui.drawTexturedMesh(&back, ui.shader, ui.textures.dirt);

    var highlights: MeshBuilder = .{};
    defer highlights.deinit(ui.gpa);
    var entry_text: MeshBuilder = .{};
    defer entry_text.deinit(ui.gpa);

    for (summaries, 0..) |summary, index| {
        const y = entryY(index, scroll);
        const slot_height = entry_height - 4;
        if (y + slot_height < list_top or y > bottom) continue;

        if (selected != null and selected.? == index) {
            try gui.appendRectColor(&highlights, ui.gpa, cx - entry_half_width, y - 2, entry_half_width * 2, slot_height + 4, gui.opaque_texel, selected_color, ui.res);
            try gui.appendRectColor(&highlights, ui.gpa, cx - entry_half_width + 1, y - 1, entry_half_width * 2 - 2, slot_height + 2, gui.opaque_texel, .{ 0, 0, 0, 255 }, ui.res);
        }

        const name = if (summary.name.len > 0) summary.name else summary.folder;
        try gui.appendTextColor(&entry_text, ui.gpa, ui.font, name, slot_left + 2, y + 1, entry_name_color, ui.res);

        var detail_buffer: [96]u8 = undefined;
        const detail = formatDetail(&detail_buffer, summary.folder, summary.last_played, localOffsetSeconds(summary.last_played), summary.size_bytes);
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

    try button.appendAll(&backgrounds, &text, ui.gpa, ui.font, buttons(ui.res, selected != null), gx, gy, ui.res);

    const title = "Select World";
    try gui.appendCenteredText(&text, ui.gpa, ui.font, title, 20, title_color, ui.res);

    try gui.drawTexturedMesh(&backgrounds, ui.shader, ui.textures.gui);
    try gui.drawTexturedMesh(&text, ui.shader, ui.font);

    gui.endOverlay();
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

test "the scrollbar column only takes the mouse while the list overflows" {
    const res = gui.scaledResolution(640, 480, 1000);
    const x = (@floor(res.width / 2.0) + scrollbar_offset + 2) * res.factor;
    const y = (list_top + 20) * res.factor;

    try std.testing.expect(scrollbarAt(x, y, res, 40));
    try std.testing.expect(!scrollbarAt(x, y, res, 1));
    try std.testing.expect(!scrollbarAt(x, (listBottom(res) + 4) * res.factor, res, 40));
    try std.testing.expect(!scrollbarAt((@floor(res.width / 2.0)) * res.factor, y, res, 40));
}

test "dragging the thumb the length of its travel scrolls the whole list" {
    const res = gui.scaledResolution(640, 480, 1000);
    const thumb = scrollbarThumb(res, 40, 0).?;
    const travel = listBottom(res) - list_top - thumb.height;

    try std.testing.expectEqual(maxScroll(res, 40), dragScroll(res, 40, 0, travel));
    try std.testing.expectEqual(@as(f32, 0), dragScroll(res, 40, 0, -10));
    try std.testing.expectEqual(@as(f32, 0), dragScroll(res, 1, 0, 10));

    const half = dragScroll(res, 40, 0, travel / 2.0);
    try std.testing.expectApproxEqAbs(maxScroll(res, 40) / 2.0, half, 0.5);
    try std.testing.expectApproxEqAbs(thumb.y + travel / 2.0, scrollbarThumb(res, 40, half).?.y, 0.5);
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

test "a second click counts as a double click only on the entry already selected" {
    try std.testing.expect(isDoubleClick(1, 1, 1200, 1000));
    try std.testing.expect(!isDoubleClick(0, 1, 1200, 1000));
    try std.testing.expect(!isDoubleClick(null, 0, 1200, 1000));
}

test "a double click has to land within a quarter second of the first" {
    try std.testing.expect(isDoubleClick(0, 0, 1249, 1000));
    try std.testing.expect(!isDoubleClick(0, 0, 1250, 1000));
}

test "scrolling is bounded by how much list overflows the visible area" {
    const res = gui.scaledResolution(640, 480, 1000);
    try std.testing.expect(maxScroll(res, 100) > 0);
    try std.testing.expectEqual(@as(f32, 0), clampScroll(res, 100, -20));
    try std.testing.expectEqual(maxScroll(res, 100), clampScroll(res, 100, 1.0e6));
}

test "a list too short to fill the view is pushed down to sit centred in it" {
    const res = gui.scaledResolution(640, 480, 1000);
    const visible = listBottom(res) - list_top - entry_padding;

    for ([_]usize{ 0, 1, 2 }) |count| {
        const leftover = visible - @as(f32, @floatFromInt(count)) * entry_height;
        const settled = clampScroll(res, count, 0);
        try std.testing.expectEqual(@trunc(-leftover / 2.0), settled);

        const first = entryY(0, settled);
        const last = entryY(count, settled);
        try std.testing.expectApproxEqAbs(first - list_top - entry_padding, listBottom(res) - last, 1.0);
    }
}

test "a list long enough to overflow scrolls from the top instead of centring" {
    const res = gui.scaledResolution(640, 480, 1000);
    try std.testing.expect(clampScroll(res, 100, 0) == 0);
    try std.testing.expectEqual(list_top + entry_padding, entryY(0, clampScroll(res, 100, 0)));
}

test "the detail line shows the folder, a date and a size" {
    var buffer: [96]u8 = undefined;
    const detail = formatDetail(&buffer, "My World", 1700000000 * std.time.ms_per_s, 0, 3 * 1024 * 1024);
    try std.testing.expect(std.mem.startsWith(u8, detail, "My World ("));
    try std.testing.expect(std.mem.indexOf(u8, detail, "11/14/23") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "3.00 MB") != null);
}

test "the clock reads as a twelve hour time, not the minute twice over" {
    var buffer: [96]u8 = undefined;

    const morning = formatDetail(&buffer, "W", 1700000000 * std.time.ms_per_s, 0, 0);
    try std.testing.expect(std.mem.indexOf(u8, morning, "10:13 PM") != null);

    var midnight_buffer: [96]u8 = undefined;
    const midnight = formatDetail(&midnight_buffer, "W", 1699920000 * std.time.ms_per_s, 0, 0);
    try std.testing.expect(std.mem.indexOf(u8, midnight, "12:00 AM") != null);

    var noon_buffer: [96]u8 = undefined;
    const noon = formatDetail(&noon_buffer, "W", 1699963200 * std.time.ms_per_s, 0, 0);
    try std.testing.expect(std.mem.indexOf(u8, noon, "12:00 PM") != null);
}

test "an offset east of UTC moves the clock forward" {
    var utc_buffer: [96]u8 = undefined;
    const utc = formatDetail(&utc_buffer, "W", 1700000000 * std.time.ms_per_s, 0, 0);
    try std.testing.expect(std.mem.indexOf(u8, utc, "11/14/23 10:13 PM") != null);

    var plus_two: [96]u8 = undefined;
    const east = formatDetail(&plus_two, "W", 1700000000 * std.time.ms_per_s, 2 * 60 * 60, 0);
    try std.testing.expect(std.mem.indexOf(u8, east, "11/15/23 12:13 AM") != null);

    var minus_eight: [96]u8 = undefined;
    const west = formatDetail(&minus_eight, "W", 1700000000 * std.time.ms_per_s, -8 * 60 * 60, 0);
    try std.testing.expect(std.mem.indexOf(u8, west, "11/14/23 2:13 PM") != null);
}

test "a world that has never been played shows only its size" {
    var buffer: [96]u8 = undefined;
    const detail = formatDetail(&buffer, "Fresh", 0, 0, 0);
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
