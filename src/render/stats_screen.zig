const std = @import("std");

const game = @import("game");
const stats = game.stats;
const gl = @import("gl");
const world = @import("world");

const Atlas = @import("atlas.zig");
const button = @import("button.zig");
const Font = @import("font.zig");
const gui = @import("gui.zig");
const MeshBuilder = @import("mesh_builder.zig");

const dirt_tile_scale: f32 = 32;
const list_dirt_tint: [4]u8 = .{ 32, 32, 32, 255 };
const title_color: [4]u8 = .{ 255, 255, 255, 255 };
const row_color: [4]u8 = .{ 255, 255, 255, 255 };
const alternate_row_color: [4]u8 = .{ 144, 144, 144, 255 };
const scrollbar_track: [4]u8 = .{ 0, 0, 0, 255 };
const scrollbar_thumb: [4]u8 = .{ 128, 128, 128, 255 };
const scrollbar_highlight: [4]u8 = .{ 192, 192, 192, 255 };
const tooltip_background: [4]u8 = .{ 0, 0, 0, 192 };

pub const list_top: f32 = 32;
const list_bottom_margin: f32 = 64;
const general_row_height: f32 = 10;
const table_row_height: f32 = 20;
const table_header_height: f32 = 20;
const list_half_width: f32 = 110;
const content_offset: f32 = 92 + 16;
const general_value_x: f32 = 2 + 213;
const icon_column_x: f32 = 40;
const edge_shadow_height: f32 = 4;
const scrollbar_offset: f32 = 124;
const scrollbar_width: f32 = 6;

const slot_texture_size: f32 = 128;
const sprite_size: f32 = 18;

const column_value_x = [3]f32{ 115, 165, 215 };
const column_arrow_x = [3]f32{ 79, 129, 179 };

pub const Tab = enum { general, blocks, items };

pub const Sort = struct { column: usize, ascending: bool };

pub const State = struct {
    tab: Tab = .general,
    scroll: std.EnumArray(Tab, f32) = .initFill(0),
    sort: std.EnumArray(Tab, ?Sort) = .initFill(null),
    pressed: ?usize = null,
    blocks: []world.Id = &.{},
    items: []world.Id = &.{},

    pub fn init(gpa: std.mem.Allocator, source: *const stats.Stats) !State {
        const blocks = try stats.blockRows(gpa, source);
        errdefer gpa.free(blocks);
        const items = try stats.itemRows(gpa, source);
        return .{ .blocks = blocks, .items = items };
    }

    pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
        gpa.free(self.blocks);
        gpa.free(self.items);
        self.* = .{};
    }

    pub fn scrollOf(self: State) f32 {
        return self.scroll.get(self.tab);
    }

    pub fn rows(self: State) []world.Id {
        return switch (self.tab) {
            .general => self.blocks[0..0],
            .blocks => self.blocks,
            .items => self.items,
        };
    }

    pub fn count(self: State) usize {
        return switch (self.tab) {
            .general => std.enums.values(stats.General).len,
            .blocks => self.blocks.len,
            .items => self.items.len,
        };
    }
};

pub fn columnKind(tab: Tab, column: usize) stats.Kind {
    return switch (tab) {
        .general => unreachable,
        .blocks => switch (column) {
            0 => .crafted,
            1 => .used,
            else => .mined,
        },
        .items => switch (column) {
            0 => .depleted,
            1 => .crafted,
            else => .used,
        },
    };
}

fn columnLabel(tab: Tab, column: usize) []const u8 {
    return switch (columnKind(tab, column)) {
        .crafted => "Times Crafted",
        .used => "Times Used",
        .mined => "Times Mined",
        .depleted => "Times Depleted",
    };
}

fn columnSpriteX(kind: stats.Kind) f32 {
    return switch (kind) {
        .crafted => 18,
        .used => 36,
        .mined => 54,
        .depleted => 72,
    };
}

pub fn listBottom(res: gui.Scaled) f32 {
    return res.height - list_bottom_margin;
}

fn rowHeight(tab: Tab) f32 {
    return if (tab == .general) general_row_height else table_row_height;
}

fn headerHeight(tab: Tab) f32 {
    return if (tab == .general) 0 else table_header_height;
}

fn contentLeft(res: gui.Scaled) f32 {
    return @floor(res.width / 2.0) - content_offset;
}

pub fn scrollLimit(res: gui.Scaled, state: State) f32 {
    const content = @as(f32, @floatFromInt(state.count())) * rowHeight(state.tab) + headerHeight(state.tab);
    const slack = content - (listBottom(res) - list_top - 4);
    if (slack < 0) return @trunc(slack / 2.0);
    return slack;
}

pub fn scrollStep(tab: Tab) f32 {
    return @trunc(rowHeight(tab) * 2.0 / 3.0);
}

pub fn clampScroll(res: gui.Scaled, state: State, scroll: f32) f32 {
    return @min(@max(scroll, 0), scrollLimit(res, state));
}

pub fn scrollbarThumb(res: gui.Scaled, state: State) ?struct { y: f32, height: f32 } {
    const overflow = scrollLimit(res, state);
    if (overflow <= 0) return null;

    const visible = listBottom(res) - list_top;
    const content = @as(f32, @floatFromInt(state.count())) * rowHeight(state.tab) + headerHeight(state.tab);
    var height = visible * visible / content;
    height = std.math.clamp(height, 32, visible - 8);
    const y = state.scrollOf() * (visible - height) / overflow + list_top;
    return .{ .y = @max(y, list_top), .height = height };
}

pub fn scrollbarAt(mouse_x: f32, mouse_y: f32, res: gui.Scaled, state: State) bool {
    if (scrollbarThumb(res, state) == null) return false;
    const gx = mouse_x / res.factor;
    const gy = mouse_y / res.factor;
    const x = @floor(res.width / 2.0) + scrollbar_offset;
    return gx >= x and gx <= x + scrollbar_width and gy >= list_top and gy <= listBottom(res);
}

pub fn dragScroll(res: gui.Scaled, state: State, dy: f32) f32 {
    const thumb = scrollbarThumb(res, state) orelse return state.scrollOf();
    const travel = listBottom(res) - list_top - thumb.height;
    return clampScroll(res, state, state.scrollOf() + dy * scrollLimit(res, state) / travel);
}

pub fn applySort(state: *State, source: *const stats.Stats, column: usize) void {
    const current = state.sort.get(state.tab);
    const next: ?Sort = if (current) |sort|
        if (sort.column != column)
            .{ .column = column, .ascending = false }
        else if (!sort.ascending)
            .{ .column = column, .ascending = true }
        else
            null
    else
        .{ .column = column, .ascending = false };

    state.sort.set(state.tab, next);
    stats.sortRows(
        state.rows(),
        source,
        if (next) |value| columnKind(state.tab, value.column) else null,
        if (next) |value| value.ascending else false,
    );
}

pub const Hit = union(enum) {
    done,
    tab: Tab,
    header: usize,
};

const Entry = struct { button: button.Button, hit: Hit };

fn buttons(res: gui.Scaled, state: State) [4]Entry {
    const cx = @floor(res.width / 2.0);
    const bottom = res.height;
    return .{
        .{ .button = .{ .x = cx + 4, .y = bottom - 28, .w = 150, .label = "Done", .enabled = true }, .hit = .done },
        .{ .button = .{ .x = cx - 154, .y = bottom - 52, .w = 100, .label = "General", .enabled = true }, .hit = .{ .tab = .general } },
        .{ .button = .{ .x = cx - 46, .y = bottom - 52, .w = 100, .label = "Blocks", .enabled = state.blocks.len > 0 }, .hit = .{ .tab = .blocks } },
        .{ .button = .{ .x = cx + 62, .y = bottom - 52, .w = 100, .label = "Items", .enabled = state.items.len > 0 }, .hit = .{ .tab = .items } },
    };
}

fn rowAt(res: gui.Scaled, state: State, gx: f32, gy: f32) ?usize {
    const cx = @floor(res.width / 2.0);
    if (gx < cx - list_half_width or gx > cx + list_half_width) return null;
    const offset = gy - list_top - headerHeight(state.tab) + state.scrollOf() - 4;
    if (offset < 0) return null;
    const index: usize = @intFromFloat(offset / rowHeight(state.tab));
    if (index >= state.count()) return null;
    return index;
}

pub fn hitAt(mouse_x: f32, mouse_y: f32, res: gui.Scaled, state: State) ?Hit {
    const gx = mouse_x / res.factor;
    const gy = mouse_y / res.factor;

    for (buttons(res, state)) |entry| {
        if (entry.button.enabled and button.contains(entry.button, gx, gy)) return entry.hit;
    }

    if (state.tab == .general) return null;
    if (gy < list_top or gy > listBottom(res)) return null;

    const cx = @floor(res.width / 2.0);
    if (gx < cx - list_half_width or gx > cx + list_half_width) return null;
    if (gy - list_top - headerHeight(state.tab) + state.scrollOf() - 4 >= 0) return null;

    const local = gx - (cx - list_half_width);
    for (column_arrow_x, 0..) |start, column| {
        if (local >= start and local < start + 36) return .{ .header = column };
    }
    return null;
}

fn appendSprite(mesh: *MeshBuilder, gpa: std.mem.Allocator, x: f32, y: f32, tex_x: f32, tex_y: f32, res: gui.Scaled) !void {
    try gui.appendRect(
        mesh,
        gpa,
        x,
        y,
        sprite_size,
        sprite_size,
        gui.pixelUv(tex_x, tex_y, sprite_size, sprite_size, slot_texture_size, slot_texture_size),
        res,
    );
}

fn appendValue(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    font: Font,
    value: ?i32,
    unit: stats.Unit,
    right: f32,
    y: f32,
    color: [4]u8,
    res: gui.Scaled,
) !void {
    var buffer: [32]u8 = undefined;
    const text = if (value) |number| stats.formatValue(&buffer, unit, number) else "-";
    const width: f32 = @floatFromInt(font.stringWidth(text));
    try gui.appendTextNoShadow(mesh, gpa, font, text, right - width, y, color, res);
}

fn drawTooltip(ui: gui.Ui, text: []const u8) !void {
    if (text.len == 0) return;
    const x = ui.mouse_x / ui.res.factor + 12;
    const y = ui.mouse_y / ui.res.factor - 12;
    const width: f32 = @floatFromInt(ui.font.stringWidth(text));

    var background: MeshBuilder = .{};
    defer background.deinit(ui.gpa);
    try gui.appendRectColor(&background, ui.gpa, x - 3, y - 3, width + 6, 14, gui.opaque_texel, tooltip_background, ui.res);
    try gui.drawColorMesh(&background, ui.shader);

    var label: MeshBuilder = .{};
    defer label.deinit(ui.gpa);
    try gui.appendTextColor(&label, ui.gpa, ui.font, text, x, y, title_color, ui.res);
    try gui.drawTexturedMesh(&label, ui.shader, ui.font);
}

fn tooltipText(ui: gui.Ui, state: State) ?[]const u8 {
    if (state.tab == .general) return null;
    const gx = ui.mouse_x / ui.res.factor;
    const gy = ui.mouse_y / ui.res.factor;
    if (gy < list_top or gy > listBottom(ui.res)) return null;

    const left = contentLeft(ui.res);
    if (rowAt(ui.res, state, gx, gy)) |index| {
        if (gx < left + icon_column_x or gx > left + icon_column_x + 20) return null;
        return stats.displayName(state.rows()[index]);
    }

    for (column_value_x, 0..) |right, column| {
        if (gx >= left + right - sprite_size and gx <= left + right) return columnLabel(state.tab, column);
    }
    return null;
}

pub fn draw(ui: gui.Ui, state: State, source: *const stats.Stats) !void {
    const gx = ui.mouse_x / ui.res.factor;
    const gy = ui.mouse_y / ui.res.factor;

    gl.Disable(gl.DEPTH_TEST);
    gl.Enable(gl.BLEND);
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

    const bottom = listBottom(ui.res);
    const left = contentLeft(ui.res);
    const origin_y = list_top + 4 - state.scrollOf();

    var band: MeshBuilder = .{};
    defer band.deinit(ui.gpa);
    const band_uv: Atlas.Uv = .{
        .u0 = 0,
        .v0 = (list_top + state.scrollOf()) / dirt_tile_scale,
        .u1 = ui.res.width / dirt_tile_scale,
        .v1 = (bottom + state.scrollOf()) / dirt_tile_scale,
    };
    try gui.appendRectColor(&band, ui.gpa, 0, list_top, ui.res.width, bottom - list_top, band_uv, list_dirt_tint, ui.res);
    try gui.drawTexturedMesh(&band, ui.shader, ui.textures.dirt);

    var sprites: MeshBuilder = .{};
    defer sprites.deinit(ui.gpa);
    var block_icons: MeshBuilder = .{};
    defer block_icons.deinit(ui.gpa);
    var item_icons: MeshBuilder = .{};
    defer item_icons.deinit(ui.gpa);
    var bars: MeshBuilder = .{};
    defer bars.deinit(ui.gpa);
    var row_text: MeshBuilder = .{};
    defer row_text.deinit(ui.gpa);

    if (state.tab != .general) {
        for (column_value_x, 0..) |right, column| {
            const held = state.pressed != null and state.pressed.? == column;
            const x = left + right - sprite_size;
            try appendSprite(&sprites, ui.gpa, x, origin_y + 1, 0, if (held) 0 else sprite_size, ui.res);
            const nudge: f32 = if (held) 1 else 0;
            try appendSprite(
                &sprites,
                ui.gpa,
                x + nudge,
                origin_y + 1 + nudge,
                columnSpriteX(columnKind(state.tab, column)),
                sprite_size,
                ui.res,
            );
        }

        if (state.sort.get(state.tab)) |sort| {
            try appendSprite(
                &sprites,
                ui.gpa,
                left + column_arrow_x[sort.column],
                origin_y + 1,
                if (sort.ascending) 36 else sprite_size,
                0,
                ui.res,
            );
        }
    }

    if (state.tab == .general) {
        for (std.enums.values(stats.General), 0..) |general, index| {
            const y = origin_y + @as(f32, @floatFromInt(index)) * general_row_height;
            if (y > bottom or y + general_row_height - 4 < list_top) continue;
            const color = if (index % 2 == 0) row_color else alternate_row_color;
            try gui.appendTextNoShadow(&row_text, ui.gpa, ui.font, general.label(), left + 2, y + 1, color, ui.res);
            try appendValue(
                &row_text,
                ui.gpa,
                ui.font,
                source.get(.{ .general = general }),
                general.unit(),
                left + general_value_x,
                y + 1,
                color,
                ui.res,
            );
        }
    } else {
        for (state.rows(), 0..) |id, index| {
            const y = origin_y + table_header_height + @as(f32, @floatFromInt(index)) * table_row_height;
            if (y > bottom or y + table_row_height - 4 < list_top) continue;
            const color = if (index % 2 == 0) row_color else alternate_row_color;

            try appendSprite(&sprites, ui.gpa, left + icon_column_x + 1, y + 1, 0, 0, ui.res);
            try gui.appendStackIcon(
                &block_icons,
                &item_icons,
                &bars,
                &row_text,
                ui.gpa,
                ui.font,
                .{ .id = id, .count = 1 },
                left + icon_column_x + 2,
                y + 2,
                ui.res,
            );

            for (column_value_x, 0..) |right, column| {
                try appendValue(
                    &row_text,
                    ui.gpa,
                    ui.font,
                    source.value(stats.key(columnKind(state.tab, column), id)),
                    .count,
                    left + right,
                    y + 5,
                    color,
                    ui.res,
                );
            }
        }
    }

    try gui.drawTexturedMesh(&sprites, ui.shader, ui.textures.slot);
    try gui.drawTexturedMesh(&block_icons, ui.shader, ui.textures.terrain);
    try gui.drawTexturedMesh(&item_icons, ui.shader, ui.textures.items);
    try gui.drawColorMesh(&bars, ui.shader);
    try gui.drawTexturedMesh(&row_text, ui.shader, ui.font);

    try gui.drawEdgeBands(ui, list_top, bottom);

    var overlays: MeshBuilder = .{};
    defer overlays.deinit(ui.gpa);
    try gui.appendEdgeShadows(&overlays, ui.gpa, ui.res, list_top, bottom, edge_shadow_height);
    try appendScrollbar(&overlays, ui.gpa, ui.res, state);

    var overlay_text: MeshBuilder = .{};
    defer overlay_text.deinit(ui.gpa);
    for (buttons(ui.res, state)) |entry| {
        const hovered = entry.button.enabled and button.contains(entry.button, gx, gy);
        try button.append(&overlays, &overlay_text, ui.gpa, ui.font, entry.button, hovered, ui.res);
    }

    const title = "Statistics";
    const title_width: f32 = @floatFromInt(ui.font.stringWidth(title));
    try gui.appendTextColor(&overlay_text, ui.gpa, ui.font, title, @floor(ui.res.width / 2.0) - @floor(title_width / 2.0), 20, title_color, ui.res);

    try gui.drawTexturedMesh(&overlays, ui.shader, ui.textures.gui);
    try gui.drawTexturedMesh(&overlay_text, ui.shader, ui.font);

    if (tooltipText(ui, state)) |text| try drawTooltip(ui, text);

    gl.Disable(gl.BLEND);
    gl.Enable(gl.DEPTH_TEST);
}

fn appendScrollbar(mesh: *MeshBuilder, gpa: std.mem.Allocator, res: gui.Scaled, state: State) !void {
    const thumb = scrollbarThumb(res, state) orelse return;
    const x = @floor(res.width / 2.0) + scrollbar_offset;
    const visible = listBottom(res) - list_top;

    try gui.appendRectColor(mesh, gpa, x, list_top, scrollbar_width, visible, gui.opaque_texel, scrollbar_track, res);
    try gui.appendRectColor(mesh, gpa, x, thumb.y, scrollbar_width, thumb.height, gui.opaque_texel, scrollbar_thumb, res);
    try gui.appendRectColor(mesh, gpa, x, thumb.y, scrollbar_width - 1, thumb.height - 1, gui.opaque_texel, scrollbar_highlight, res);
}

test "the tab buttons stay disabled until their list has rows" {
    const res = gui.scaledResolution(640, 480, 1000);
    const cx = @floor(res.width / 2.0);
    const y = (res.height - 52 + 10) * res.factor;

    const empty: State = .{};
    try std.testing.expectEqual(@as(?Hit, .{ .tab = .general }), hitAt((cx - 100) * res.factor, y, res, empty));
    try std.testing.expectEqual(@as(?Hit, null), hitAt((cx + 4) * res.factor, y, res, empty));
    try std.testing.expectEqual(@as(?Hit, null), hitAt((cx + 112) * res.factor, y, res, empty));

    var blocks = [_]world.Id{.{ .block = .stone }};
    var items = [_]world.Id{.{ .item = .stick }};
    const filled: State = .{ .blocks = &blocks, .items = &items };
    try std.testing.expectEqual(@as(?Hit, .{ .tab = .blocks }), hitAt((cx + 4) * res.factor, y, res, filled));
    try std.testing.expectEqual(@as(?Hit, .{ .tab = .items }), hitAt((cx + 112) * res.factor, y, res, filled));
}

test "done sits to the right of the tab row" {
    const res = gui.scaledResolution(640, 480, 1000);
    const cx = @floor(res.width / 2.0);
    const state: State = .{};
    try std.testing.expectEqual(@as(?Hit, .done), hitAt((cx + 80) * res.factor, (res.height - 28 + 10) * res.factor, res, state));
}

test "dragging the thumb the length of its travel scrolls the whole list" {
    const res = gui.scaledResolution(640, 480, 1000);
    var many: [64]world.Id = @splat(.{ .block = .stone });
    const filled: State = .{ .tab = .blocks, .blocks = &many };

    const x = (@floor(res.width / 2.0) + scrollbar_offset + 2) * res.factor;
    try std.testing.expect(scrollbarAt(x, (list_top + 20) * res.factor, res, filled));
    try std.testing.expect(!scrollbarAt((@floor(res.width / 2.0)) * res.factor, (list_top + 20) * res.factor, res, filled));

    const thumb = scrollbarThumb(res, filled).?;
    const travel = listBottom(res) - list_top - thumb.height;
    try std.testing.expectEqual(scrollLimit(res, filled), dragScroll(res, filled, travel));
    try std.testing.expectEqual(@as(f32, 0), dragScroll(res, filled, -10));
}

test "a list too short for a scrollbar cannot be dragged" {
    const res = gui.scaledResolution(640, 480, 1000);
    var one = [_]world.Id{.{ .block = .stone }};
    const short: State = .{ .tab = .blocks, .blocks = &one };

    try std.testing.expect(scrollbarThumb(res, short) == null);
    try std.testing.expect(!scrollbarAt((@floor(res.width / 2.0) + scrollbar_offset + 2) * res.factor, (list_top + 20) * res.factor, res, short));
    try std.testing.expectEqual(short.scrollOf(), dragScroll(res, short, 40));
}

test "the column headers only respond on the table tabs" {
    const res = gui.scaledResolution(640, 480, 1000);
    const cx = @floor(res.width / 2.0);
    const header_y = (list_top + 8) * res.factor;

    var blocks = [_]world.Id{.{ .block = .stone }};
    const table: State = .{ .tab = .blocks, .blocks = &blocks };
    try std.testing.expectEqual(@as(?Hit, .{ .header = 0 }), hitAt((cx - list_half_width + 90) * res.factor, header_y, res, table));
    try std.testing.expectEqual(@as(?Hit, .{ .header = 1 }), hitAt((cx - list_half_width + 140) * res.factor, header_y, res, table));
    try std.testing.expectEqual(@as(?Hit, .{ .header = 2 }), hitAt((cx - list_half_width + 190) * res.factor, header_y, res, table));
    try std.testing.expectEqual(@as(?Hit, null), hitAt((cx - list_half_width + 10) * res.factor, header_y, res, table));

    const general: State = .{ .tab = .general };
    try std.testing.expectEqual(@as(?Hit, null), hitAt((cx - list_half_width + 90) * res.factor, header_y, res, general));
}

test "clicking a header cycles descending, ascending and back to unsorted" {
    const gpa = std.testing.allocator;
    var source: game.stats.Stats = .{};
    defer source.deinit(gpa);
    try source.mine(gpa, .stone);

    var blocks = [_]world.Id{.{ .block = .stone }};
    var state: State = .{ .tab = .blocks, .blocks = &blocks };

    applySort(&state, &source, 2);
    try std.testing.expectEqual(@as(?Sort, .{ .column = 2, .ascending = false }), state.sort.get(.blocks));
    applySort(&state, &source, 2);
    try std.testing.expectEqual(@as(?Sort, .{ .column = 2, .ascending = true }), state.sort.get(.blocks));
    applySort(&state, &source, 2);
    try std.testing.expectEqual(@as(?Sort, null), state.sort.get(.blocks));
    applySort(&state, &source, 0);
    try std.testing.expectEqual(@as(?Sort, .{ .column = 0, .ascending = false }), state.sort.get(.blocks));
    applySort(&state, &source, 1);
    try std.testing.expectEqual(@as(?Sort, .{ .column = 1, .ascending = false }), state.sort.get(.blocks));
}

test "the columns map onto the stats each tab shows" {
    try std.testing.expectEqual(game.stats.Kind.crafted, columnKind(.blocks, 0));
    try std.testing.expectEqual(game.stats.Kind.used, columnKind(.blocks, 1));
    try std.testing.expectEqual(game.stats.Kind.mined, columnKind(.blocks, 2));
    try std.testing.expectEqual(game.stats.Kind.depleted, columnKind(.items, 0));
    try std.testing.expectEqual(game.stats.Kind.crafted, columnKind(.items, 1));
    try std.testing.expectEqual(game.stats.Kind.used, columnKind(.items, 2));
}

test "a list shorter than the view sits at half its slack, as bindAmountScrolled leaves it" {
    const res = gui.scaledResolution(640, 480, 1000);
    var one = [_]world.Id{.{ .block = .stone }};
    const short: State = .{ .tab = .blocks, .blocks = &one };
    try std.testing.expect(scrollLimit(res, short) < 0);
    try std.testing.expectEqual(scrollLimit(res, short), clampScroll(res, short, 0));

    var many: [64]world.Id = @splat(.{ .block = .stone });
    const filled: State = .{ .tab = .blocks, .blocks = &many };
    try std.testing.expect(scrollLimit(res, filled) > 0);
    try std.testing.expectEqual(@as(f32, 0), clampScroll(res, filled, -10));
    try std.testing.expectEqual(scrollLimit(res, filled), clampScroll(res, filled, 100000));
}
