const std = @import("std");
const builtin = @import("builtin");

const Atlas = @import("../Atlas.zig");
const button = @import("../button.zig");
const Font = @import("../Font.zig");
const gui = @import("../gui.zig");
const MeshBuilder = @import("../MeshBuilder.zig");
const texture_pack = @import("../texture_pack.zig");
const scroll_list = @import("scroll_list.zig");
const Column = scroll_list.Column;
const list_top = scroll_list.list_top;
pub const entry_height = scroll_list.entry_height;
const entry_padding = scroll_list.entry_padding;
const entry_half_width = scroll_list.entry_half_width;

const wasm = builtin.cpu.arch.isWasm();
const android = builtin.abi == .android or builtin.abi == .androideabi or builtin.os.tag == .ios;

const title_color: [4]u8 = .{ 255, 255, 255, 255 };
const name_color: [4]u8 = .{ 255, 255, 255, 255 };
const description_color: [4]u8 = .{ 128, 128, 128, 255 };
const selected_color: [4]u8 = .{ 128, 128, 128, 255 };

const list_bottom_margin: f32 = 51;
const row_height: f32 = entry_height - 4;
const thumbnail_size: f32 = 32;
const text_left_gap: f32 = thumbnail_size + 2;
const edge_shadow_height: f32 = 4;
const column_gap: f32 = 8;
const side_margin: f32 = 4;
const text_inset: f32 = 2;

const title = "Select Texture Pack";
const mods_title = "Mods";
const no_mods = "No mods loaded";
const needs_prefix = "needs ";
const clipped_tail = "..";

pub const Side = enum { packs, mods };

pub const Mod = struct {
    id: []const u8,
    version: []const u8,
    depends: []const []const u8,
};

pub const Hit = union(enum) {
    entry: usize,
    open_folder,
    open_mods_folder,
    refresh,
    done,
};

const list = scroll_list.List(list_bottom_margin);

pub const listBottom = list.listBottom;
pub const maxScroll = list.maxScroll;
pub const clampScroll = list.clampScroll;
pub const scrollbarThumb = list.scrollbarThumb;
pub const dragScroll = list.dragScroll;
const entryY = list.entryY;

pub fn columns(res: gui.Scaled) [2]Column {
    const room = @floor((res.width - side_margin * 2 - column_gap) / 2.0) - scroll_list.scrollbar_room;
    const width = @min(entry_half_width * 2, room);
    const span = (width + scroll_list.scrollbar_room) * 2 + column_gap;
    const left = @floor((res.width - span) / 2.0);
    return .{
        .{ .left = left, .width = width },
        .{ .left = left + width + scroll_list.scrollbar_room + column_gap, .width = width },
    };
}

fn columnOf(res: gui.Scaled, side: Side) Column {
    return columns(res)[@intFromEnum(side)];
}

pub fn sideAt(mouse_x: f32, res: gui.Scaled) Side {
    const mods = columnOf(res, .mods);
    return if (mouse_x / res.factor >= mods.left - column_gap / 2.0) .mods else .packs;
}

pub fn scrollbarAt(side: Side, mouse_x: f32, mouse_y: f32, res: gui.Scaled, count: usize) bool {
    return list.scrollbarIn(columnOf(res, side), mouse_x, mouse_y, res, count);
}

fn buttons(res: gui.Scaled) [4]struct { button: button.Button, hit: Hit } {
    const cx = @floor(res.width / 2.0);
    const y = res.height - 48;
    return .{
        .{ .button = .{ .x = cx - 154, .y = y, .w = 74, .label = "Pack folder", .enabled = !wasm and !android }, .hit = .open_folder },
        .{ .button = .{ .x = cx - 76, .y = y, .w = 74, .label = "Mods folder", .enabled = !wasm and !android }, .hit = .open_mods_folder },
        .{ .button = .{ .x = cx + 2, .y = y, .w = 74, .label = "Refresh", .enabled = true }, .hit = .refresh },
        .{ .button = .{ .x = cx + 80, .y = y, .w = 74, .label = "Done", .enabled = true }, .hit = .done },
    };
}

pub fn hitAt(mouse_x: f32, mouse_y: f32, res: gui.Scaled, count: usize, scroll: f32) ?Hit {
    const gx = mouse_x / res.factor;
    const gy = mouse_y / res.factor;

    const bar = buttons(res);
    if (button.indexAt(bar, gx, gy)) |index| return bar[index].hit;

    if (list.rowIn(columnOf(res, .packs), gx, gy, res, count, scroll)) |index| return .{ .entry = index };
    return null;
}

const whole_texture: Atlas.Uv = .{ .u0 = 0, .v0 = 0, .u1 = 1, .v1 = 1 };

fn clipped(font: Font, text: []const u8, max_width: f32) []const u8 {
    if (@as(f32, @floatFromInt(font.stringWidth(text))) <= max_width) return text;
    const room = max_width - @as(f32, @floatFromInt(font.stringWidth(clipped_tail)));
    var width: f32 = 0;
    for (text, 0..) |c, index| {
        width += @floatFromInt(font.char_width[c]);
        if (width > room) return text[0..index];
    }
    return text;
}

fn appendClipped(mesh: *MeshBuilder, ui: gui.Ui, text: []const u8, x: f32, y: f32, max_width: f32, color: [4]u8) !void {
    const shown = clipped(ui.font, text, max_width);
    try gui.appendTextColor(mesh, ui.gpa, ui.font, shown, x, y, color, ui.res);
    if (shown.len == text.len) return;
    const tail_x = x + @as(f32, @floatFromInt(ui.font.stringWidth(shown)));
    try gui.appendTextColor(mesh, ui.gpa, ui.font, clipped_tail, tail_x, y, color, ui.res);
}

fn centeredX(ui: gui.Ui, text: []const u8, column: Column) f32 {
    const width: f32 = @floatFromInt(ui.font.stringWidth(text));
    return column.left + @floor(column.width / 2.0) - @floor(width / 2.0);
}

fn appendTitle(mesh: *MeshBuilder, ui: gui.Ui, text: []const u8, column: Column) !void {
    try gui.appendTextColor(mesh, ui.gpa, ui.font, text, centeredX(ui, text, column), 16, title_color, ui.res);
}

fn needsLine(buffer: []u8, depends: []const []const u8) []const u8 {
    if (depends.len == 0) return "";
    var writer: std.Io.Writer = .fixed(buffer);
    writer.writeAll(needs_prefix) catch return writer.buffered();
    for (depends, 0..) |dependency, index| {
        if (index > 0) writer.writeAll(", ") catch break;
        writer.writeAll(dependency) catch break;
    }
    return writer.buffered();
}

pub fn draw(
    ui: gui.Ui,
    packs: []const texture_pack.Pack,
    thumbnails: []const Atlas,
    selected: ?usize,
    scroll: f32,
    mods: []const Mod,
    mod_scroll: f32,
) !void {
    const gx = ui.mouse_x / ui.res.factor;
    const gy = ui.mouse_y / ui.res.factor;

    gui.beginOverlay();

    const bottom = listBottom(ui.res);
    const pack_column = columnOf(ui.res, .packs);
    const mod_column = columnOf(ui.res, .mods);
    const slot_left = pack_column.left + text_inset;

    var back: MeshBuilder = .{};
    defer back.deinit(ui.gpa);

    try list.appendBackground(&back, ui.gpa, ui.res, 0);
    try gui.drawTexturedMesh(&back, ui.shader, ui.textures.dirt);

    var highlights: MeshBuilder = .{};
    defer highlights.deinit(ui.gpa);

    for (packs, 0..) |_, index| {
        const y = entryY(index, scroll);
        if (y + row_height < list_top or y > bottom) continue;
        if (selected == null or selected.? != index) continue;

        try gui.appendRectColor(&highlights, ui.gpa, pack_column.left, y - 2, pack_column.width, entry_height, gui.opaque_texel, selected_color, ui.res);
        try gui.appendRectColor(&highlights, ui.gpa, pack_column.left + 1, y - 1, pack_column.width - 2, entry_height - 2, gui.opaque_texel, .{ 0, 0, 0, 255 }, ui.res);
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

    const text_x = slot_left + text_left_gap;
    const text_width = pack_column.left + pack_column.width - text_inset - text_x;
    for (packs, 0..) |pack, index| {
        const y = entryY(index, scroll);
        if (y + row_height < list_top or y > bottom) continue;

        try appendClipped(&entry_text, ui, pack.name, text_x, y + 1, text_width, name_color);
        try appendClipped(&entry_text, ui, pack.lines[0], text_x, y + 12, text_width, description_color);
        try appendClipped(&entry_text, ui, pack.lines[1], text_x, y + 22, text_width, description_color);
    }

    const mod_x = mod_column.left + text_inset;
    const mod_width = mod_column.width - text_inset * 2;
    for (mods, 0..) |mod, index| {
        const y = entryY(index, mod_scroll);
        if (y + row_height < list_top or y > bottom) continue;

        var needs_buffer: [256]u8 = undefined;
        try appendClipped(&entry_text, ui, mod.id, mod_x, y + 1, mod_width, name_color);
        try appendClipped(&entry_text, ui, mod.version, mod_x, y + 12, mod_width, description_color);
        try appendClipped(&entry_text, ui, needsLine(&needs_buffer, mod.depends), mod_x, y + 22, mod_width, description_color);
    }
    if (mods.len == 0) {
        const x = centeredX(ui, no_mods, mod_column);
        try gui.appendTextColor(&entry_text, ui.gpa, ui.font, no_mods, x, @floor((list_top + bottom) / 2.0) - 4, description_color, ui.res);
    }
    try gui.drawTexturedMesh(&entry_text, ui.shader, ui.font);

    var backgrounds: MeshBuilder = .{};
    defer backgrounds.deinit(ui.gpa);
    var text: MeshBuilder = .{};
    defer text.deinit(ui.gpa);

    try gui.drawEdgeBands(ui, list_top, bottom);
    try gui.appendEdgeShadows(&backgrounds, ui.gpa, ui.res, list_top, bottom, edge_shadow_height);
    try list.appendScrollbarIn(pack_column, &backgrounds, ui.gpa, ui.res, packs.len, scroll);
    try list.appendScrollbarIn(mod_column, &backgrounds, ui.gpa, ui.res, mods.len, mod_scroll);

    for (buttons(ui.res)) |entry| {
        const hovered = button.contains(entry.button, gx, gy);
        try button.append(&backgrounds, &text, ui.gpa, ui.font, entry.button, hovered, ui.res);
    }

    try appendTitle(&text, ui, title, pack_column);
    try appendTitle(&text, ui, mods_title, mod_column);

    try gui.drawTexturedMesh(&backgrounds, ui.shader, ui.textures.gui);
    try gui.drawTexturedMesh(&text, ui.shader, ui.font);

    gui.endOverlay();
}

fn packColumnX(res: gui.Scaled) f32 {
    const column = columnOf(res, .packs);
    return (column.left + @floor(column.width / 2.0)) * res.factor;
}

fn rowClickY(res: gui.Scaled, index: usize) f32 {
    return (list_top + entry_padding + @as(f32, @floatFromInt(index)) * entry_height + 2) * res.factor;
}

test "clicking a row returns its index, offset by the scroll position" {
    const res = gui.scaledResolution(640, 480, 1000);
    const cx = packColumnX(res);
    try std.testing.expectEqual(@as(?Hit, .{ .entry = 0 }), hitAt(cx, rowClickY(res, 0), res, 3, 0));
    try std.testing.expectEqual(@as(?Hit, .{ .entry = 1 }), hitAt(cx, rowClickY(res, 1), res, 3, 0));
    try std.testing.expectEqual(@as(?Hit, .{ .entry = 1 }), hitAt(cx, rowClickY(res, 0), res, 3, entry_height));
}

test "clicking past the last pack selects nothing" {
    const res = gui.scaledResolution(640, 480, 1000);
    const cx = packColumnX(res);
    try std.testing.expectEqual(@as(?Hit, null), hitAt(cx, rowClickY(res, 2), res, 1, 0));
}

test "clicking to the side of the list misses every row" {
    const res = gui.scaledResolution(640, 480, 1000);
    const column = columnOf(res, .packs);
    const outside = (column.left + column.width + 8) * res.factor;
    try std.testing.expectEqual(@as(?Hit, null), hitAt(outside, rowClickY(res, 0), res, 3, 0));
}

test "the buttons sit side by side under the lists" {
    const res = gui.scaledResolution(640, 480, 1000);
    const row = buttons(res);
    for (row[0 .. row.len - 1], row[1..]) |left, right| {
        try std.testing.expectEqual(left.button.y, right.button.y);
        try std.testing.expect(left.button.x + left.button.w < right.button.x);
    }
    try std.testing.expect(row[0].button.y >= listBottom(res));
    try std.testing.expect(row[0].button.x >= 0);
    try std.testing.expect(row[row.len - 1].button.x + row[row.len - 1].button.w <= res.width);

    for (row) |entry| {
        if (!entry.button.enabled) continue;
        const x = (entry.button.x + entry.button.w / 2) * res.factor;
        const y = (entry.button.y + 10) * res.factor;
        try std.testing.expectEqual(@as(?Hit, entry.hit), hitAt(x, y, res, 3, 0));
    }
}

test "a list that fits needs no scrollbar, and one that overflows gets one" {
    const res = gui.scaledResolution(640, 480, 1000);
    try std.testing.expect(maxScroll(res, 2) <= 0);
    try std.testing.expect(scrollbarThumb(res, 2, 0) == null);

    const many = 40;
    try std.testing.expect(maxScroll(res, many) > 0);
    try std.testing.expect(scrollbarThumb(res, many, 0) != null);
}

test "dragging the thumb the length of its travel scrolls the whole list" {
    const res = gui.scaledResolution(640, 480, 1000);
    const x = (columnOf(res, .packs).scrollbarX() + 2) * res.factor;
    try std.testing.expect(scrollbarAt(.packs, x, (list_top + 20) * res.factor, res, 40));
    try std.testing.expect(!scrollbarAt(.packs, x, (list_top + 20) * res.factor, res, 2));
    try std.testing.expect(!scrollbarAt(.mods, x, (list_top + 20) * res.factor, res, 40));

    const thumb = scrollbarThumb(res, 40, 0).?;
    const travel = listBottom(res) - list_top - thumb.height;
    try std.testing.expectEqual(maxScroll(res, 40), dragScroll(res, 40, 0, travel));
    try std.testing.expectEqual(@as(f32, 0), dragScroll(res, 40, 0, -10));
}

test "a row scrolled above the list is not clickable through the header" {
    const res = gui.scaledResolution(640, 480, 1000);
    const cx = packColumnX(res);
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

test "on a wide screen both columns keep the original list width" {
    const res = gui.scaledResolution(1280, 720, 2);
    const pair = columns(res);
    try std.testing.expectEqual(entry_half_width * 2, pair[0].width);
    try std.testing.expectEqual(pair[0].width, pair[1].width);
    try std.testing.expect(pair[0].scrollbarX() + scroll_list.scrollbar_room < pair[1].left + column_gap);
}

test "on the narrowest screen both columns and their scrollbars stay on it" {
    const res = gui.scaledResolution(320, 240, 1000);
    const pair = columns(res);
    try std.testing.expect(pair[0].width < entry_half_width * 2);
    try std.testing.expect(pair[0].left >= side_margin);
    try std.testing.expect(pair[1].left >= pair[0].left + pair[0].width + scroll_list.scrollbar_room);
    try std.testing.expect(pair[1].left + pair[1].width + scroll_list.scrollbar_room <= res.width - side_margin);
}

test "the mouse wheel scrolls whichever column the pointer is over" {
    const res = gui.scaledResolution(640, 480, 1000);
    const pair = columns(res);
    try std.testing.expectEqual(Side.packs, sideAt((pair[0].left + 10) * res.factor, res));
    try std.testing.expectEqual(Side.mods, sideAt((pair[1].left + 10) * res.factor, res));
}

test "a mod row is not a texture pack to select" {
    const res = gui.scaledResolution(640, 480, 1000);
    const column = columnOf(res, .mods);
    const x = (column.left + @floor(column.width / 2.0)) * res.factor;
    try std.testing.expectEqual(@as(?Hit, null), hitAt(x, rowClickY(res, 0), res, 3, 0));
}

test "a mod's dependencies read as one needs line, and none reads as nothing" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("", needsLine(&buffer, &.{}));
    try std.testing.expectEqualStrings("needs meadow", needsLine(&buffer, &.{"meadow"}));
    try std.testing.expectEqualStrings("needs meadow, quartz", needsLine(&buffer, &.{ "meadow", "quartz" }));
}

test "text wider than its column is cut to fit with a trailing mark" {
    const font: Font = .{ .texture = 0, .char_width = @splat(6) };
    try std.testing.expectEqualStrings("meadow", clipped(font, "meadow", 36));
    const shown = clipped(font, "honeycomb", 36);
    try std.testing.expectEqualStrings("hone", shown);
    try std.testing.expect(font.stringWidth(shown) + font.stringWidth(clipped_tail) <= 36);
}

test "the last row can be scrolled to sit just above the bottom of the list" {
    const res = gui.scaledResolution(640, 480, 1000);
    const count = 40;
    const limit = maxScroll(res, count);
    const last = entryY(count - 1, limit);
    try std.testing.expectEqual(listBottom(res) - entry_height, last);
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
    const cx = packColumnX(res);
    const settled = clampScroll(res, 2, 0);

    for ([_]usize{ 0, 1 }) |index| {
        const drawn_y = (entryY(index, settled) + 2) * res.factor;
        try std.testing.expectEqual(@as(?Hit, .{ .entry = index }), hitAt(cx, drawn_y, res, 2, settled));
    }
}
