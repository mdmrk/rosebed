const std = @import("std");

const game = @import("game");
const achievements = game.achievements;
const gl = @import("gl");
const world = @import("world");

const Atlas = @import("atlas.zig");
const button = @import("button.zig");
const gui = @import("gui.zig");
const MeshBuilder = @import("mesh_builder.zig");
const text_wrap = @import("text_wrap.zig");

pub const window_width: f32 = 256;
pub const window_height: f32 = 202;
pub const map_width: f32 = 224;
pub const map_height: f32 = 155;
pub const map_inset_x: f32 = 16;
pub const map_inset_y: f32 = 17;
pub const cell: f32 = 24;
pub const plate: f32 = 26;
pub const icon_inset: f32 = 3;
pub const texture_size: f32 = 256;
pub const terrain_tile: f32 = 16;

const start_span: f64 = 141;
const glide: f64 = 0.85;
const settle_squared: f64 = 4.0;

const title_color: [4]u8 = .{ 64, 64, 64, 255 };
const tooltip_background: [4]u8 = .{ 0, 0, 0, 192 };
const description_color: [4]u8 = .{ 160, 160, 160, 255 };
const requires_color: [4]u8 = .{ 112, 80, 80, 255 };
const taken_color: [4]u8 = .{ 144, 144, 255, 255 };
const name_open: [4]u8 = .{ 255, 255, 255, 255 };
const name_open_special: [4]u8 = .{ 255, 255, 128, 255 };
const name_locked: [4]u8 = .{ 128, 128, 128, 255 };
const name_locked_special: [4]u8 = .{ 128, 128, 64, 255 };
const link_unlocked: [4]u8 = .{ 112, 112, 112, 255 };
const link_locked: [4]u8 = .{ 0, 0, 0, 255 };
const link_open: [3]u8 = .{ 0, 255, 0 };
const locked_icon_shade: f32 = 0.1;

pub const title = "Achievements";
pub const done_label = "Done";
const tooltip_min_width: u32 = 120;

pub const Hit = enum { done };

pub fn panLeft() f64 {
    return @as(f64, @floatFromInt(achievements.bounds.min_column)) * cell - 112;
}

pub fn panTop() f64 {
    return @as(f64, @floatFromInt(achievements.bounds.min_row)) * cell - 112;
}

pub fn panRight() f64 {
    return @as(f64, @floatFromInt(achievements.bounds.max_column)) * cell - 77;
}

pub fn panBottom() f64 {
    return @as(f64, @floatFromInt(achievements.bounds.max_row)) * cell - 77;
}

fn clampPan(x: f64, y: f64) [2]f64 {
    var out = [2]f64{ x, y };
    if (out[0] < panLeft()) out[0] = panLeft();
    if (out[1] < panTop()) out[1] = panTop();
    if (out[0] >= panRight()) out[0] = panRight() - 1;
    if (out[1] >= panBottom()) out[1] = panBottom() - 1;
    return out;
}

pub const State = struct {
    pan: [2]f64 = startPan(),
    prev: [2]f64 = startPan(),
    target: [2]f64 = startPan(),
    grabbed: bool = false,
    last_mouse: [2]f32 = .{ 0, 0 },

    pub fn startPan() [2]f64 {
        const home = achievements.Id.open_inventory.def();
        return .{
            @as(f64, @floatFromInt(home.column)) * cell - @divTrunc(start_span, 2.0) - 12,
            @as(f64, @floatFromInt(home.row)) * cell - @divTrunc(start_span, 2.0),
        };
    }

    pub fn tick(self: *State) void {
        self.prev = self.pan;
        const dx = self.target[0] - self.pan[0];
        const dy = self.target[1] - self.pan[1];
        if (dx * dx + dy * dy < settle_squared) {
            self.pan[0] += dx;
            self.pan[1] += dy;
        } else {
            self.pan[0] += dx * glide;
            self.pan[1] += dy * glide;
        }
    }

    pub fn drag(self: *State, mouse_x: f32, mouse_y: f32, res: gui.Scaled, pressed: bool) void {
        if (!pressed) {
            self.grabbed = false;
            return;
        }

        const gx = mouse_x / res.factor;
        const gy = mouse_y / res.factor;
        if (insideMap(gx, gy, res)) {
            if (!self.grabbed) {
                self.grabbed = true;
            } else {
                self.target[0] -= @as(f64, gx - self.last_mouse[0]);
                self.target[1] -= @as(f64, gy - self.last_mouse[1]);
                self.pan = self.target;
                self.prev = self.target;
            }
            self.last_mouse = .{ gx, gy };
        }

        self.target = clampPan(self.target[0], self.target[1]);
    }

    pub fn view(self: State, partial: f32) [2]f64 {
        const at: f64 = partial;
        const x = self.prev[0] + (self.pan[0] - self.prev[0]) * at;
        const y = self.prev[1] + (self.pan[1] - self.prev[1]) * at;
        return clampPan(@floor(x), @floor(y));
    }
};

pub fn windowLeft(res: gui.Scaled) f32 {
    return @floor((res.width - window_width) / 2.0);
}

pub fn windowTop(res: gui.Scaled) f32 {
    return @floor((res.height - window_height) / 2.0);
}

fn mapLeft(res: gui.Scaled) f32 {
    return windowLeft(res) + map_inset_x;
}

fn mapTop(res: gui.Scaled) f32 {
    return windowTop(res) + map_inset_y;
}

fn insideMap(gx: f32, gy: f32, res: gui.Scaled) bool {
    const left = windowLeft(res) + 8;
    const top = windowTop(res) + 17;
    return gx >= left and gx < left + map_width and gy >= top and gy < top + map_height;
}

fn doneButton(res: gui.Scaled) button.Button {
    return .{
        .x = @floor(res.width / 2.0) + 24,
        .y = @floor(res.height / 2.0) + 74,
        .w = 80,
        .label = done_label,
        .enabled = true,
    };
}

pub fn hitAt(mouse_x: f32, mouse_y: f32, res: gui.Scaled) ?Hit {
    const gx = mouse_x / res.factor;
    const gy = mouse_y / res.factor;
    if (button.contains(doneButton(res), gx, gy)) return .done;
    return null;
}

pub fn backgroundTile(column: i32, row: i32) world.Block {
    var rand: world.JavaRandom = .init(1234 + column);
    _ = rand.nextInt();
    const depth = rand.nextIntBound(1 + row) + @divTrunc(row, 2);

    if (depth > 37 or row == 35) return .bedrock;
    if (depth == 22) return if (rand.nextIntBound(2) == 0) .ore_diamond else .ore_redstone;
    if (depth == 10) return .ore_iron;
    if (depth == 8) return .ore_coal;
    if (depth > 4) return .stone;
    if (depth > 0) return .dirt;
    return .sand;
}

pub fn backgroundShade(row: i32) f32 {
    return 0.6 - @as(f32, @floatFromInt(row)) / 25.0 * 0.3;
}

fn tileUv(block: world.Block) Atlas.Uv {
    return Atlas.tileUv(block.faceTextures().get(.north));
}

pub fn achievementAt(mouse_x: f32, mouse_y: f32, res: gui.Scaled, pan: [2]f64) ?achievements.Id {
    const gx = mouse_x / res.factor;
    const gy = mouse_y / res.factor;
    const left = mapLeft(res);
    const top = mapTop(res);
    if (gx < left or gy < top or gx >= left + map_width or gy >= top + map_height) return null;

    for (std.enums.values(achievements.Id)) |id| {
        const entry = id.def();
        const x = @as(f64, @floatFromInt(entry.column)) * cell - pan[0];
        const y = @as(f64, @floatFromInt(entry.row)) * cell - pan[1];
        if (x < -cell or y < -cell or x > map_width or y > map_height) continue;

        const plate_x = left + @as(f32, @floatCast(x));
        const plate_y = top + @as(f32, @floatCast(y));
        if (gx >= plate_x and gx <= plate_x + 22 and gy >= plate_y and gy <= plate_y + 22) return id;
    }
    return null;
}

fn plateUv(special: bool) Atlas.Uv {
    return gui.pixelUv(if (special) plate else 0, 202, plate, plate, texture_size, texture_size);
}

fn windowUv() Atlas.Uv {
    return gui.pixelUv(0, 0, window_width, window_height, texture_size, texture_size);
}

fn plateShade(unlocked: bool, reachable: bool, blink: bool) u8 {
    if (unlocked) return 255;
    if (!reachable) return 76;
    return if (blink) 204 else 153;
}

pub fn blinkOn(now_ms: f64) bool {
    const phase = @mod(now_ms, 600.0) / 600.0 * std.math.pi * 2.0;
    return @sin(phase) > 0.6;
}

fn linkColor(unlocked: bool, reachable: bool, now_ms: f64) [4]u8 {
    if (unlocked) return link_unlocked;
    if (!reachable) return link_locked;
    const alpha: u8 = if (blinkOn(now_ms)) 255 else 130;
    return .{ link_open[0], link_open[1], link_open[2], alpha };
}

fn nameColor(reachable: bool, special: bool) [4]u8 {
    if (reachable) return if (special) name_open_special else name_open;
    return if (special) name_locked_special else name_locked;
}

fn appendLine(mesh: *MeshBuilder, gpa: std.mem.Allocator, from: [2]f32, to: [2]f32, color: [4]u8, res: gui.Scaled) !void {
    const x = @min(from[0], to[0]);
    const y = @min(from[1], to[1]);
    const w = @max(@abs(to[0] - from[0]), 1);
    const h = @max(@abs(to[1] - from[1]), 1);
    try gui.appendRectColor(mesh, gpa, x, y, w, h, gui.opaque_texel, color, res);
}

pub fn draw(
    ui: gui.Ui,
    state: State,
    source: *const game.stats.Stats,
    partial: f32,
    now_ms: f64,
    inventory_key: []const u8,
) !void {
    const gx = ui.mouse_x / ui.res.factor;
    const gy = ui.mouse_y / ui.res.factor;
    const pan = state.view(partial);

    gl.Disable(gl.DEPTH_TEST);
    gl.Enable(gl.BLEND);
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

    try gui.drawBackdrop(ui, .veil);

    const left = mapLeft(ui.res);
    const top = mapTop(ui.res);
    const base_column: i32 = @intCast(@divFloor(@as(i64, @intFromFloat(pan[0])) + 288, 16));
    const base_row: i32 = @intCast(@divFloor(@as(i64, @intFromFloat(pan[1])) + 288, 16));
    const skip_x: f32 = @floatFromInt(@mod(@as(i64, @intFromFloat(pan[0])) + 288, 16));
    const skip_y: f32 = @floatFromInt(@mod(@as(i64, @intFromFloat(pan[1])) + 288, 16));

    var terrain: MeshBuilder = .{};
    defer terrain.deinit(ui.gpa);

    var down: i32 = 0;
    while (@as(f32, @floatFromInt(down)) * terrain_tile - skip_y < map_height) : (down += 1) {
        const row = base_row + down;
        const shade: u8 = @intFromFloat(std.math.clamp(backgroundShade(row), 0.0, 1.0) * 255.0);
        var across: i32 = 0;
        while (@as(f32, @floatFromInt(across)) * terrain_tile - skip_x < map_width) : (across += 1) {
            const block = backgroundTile(base_column + across, row);
            try gui.appendRectColor(
                &terrain,
                ui.gpa,
                left + @as(f32, @floatFromInt(across)) * terrain_tile - skip_x,
                top + @as(f32, @floatFromInt(down)) * terrain_tile - skip_y,
                terrain_tile,
                terrain_tile,
                tileUv(block),
                .{ shade, shade, shade, 255 },
                ui.res,
            );
        }
    }
    try gui.drawTexturedMesh(&terrain, ui.shader, ui.textures.terrain);

    var links: MeshBuilder = .{};
    defer links.deinit(ui.gpa);
    for (std.enums.values(achievements.Id)) |id| {
        const entry = id.def();
        const parent = entry.parent orelse continue;
        const parent_entry = parent.def();

        const x: f32 = @floatCast(@as(f64, @floatFromInt(entry.column)) * cell - pan[0] + 11);
        const y: f32 = @floatCast(@as(f64, @floatFromInt(entry.row)) * cell - pan[1] + 11);
        const px: f32 = @floatCast(@as(f64, @floatFromInt(parent_entry.column)) * cell - pan[0] + 11);
        const py: f32 = @floatCast(@as(f64, @floatFromInt(parent_entry.row)) * cell - pan[1] + 11);

        const color = linkColor(source.hasAchievement(id), source.canUnlock(id), now_ms);
        try appendLine(&links, ui.gpa, .{ left + x, top + y }, .{ left + px, top + y }, color, ui.res);
        try appendLine(&links, ui.gpa, .{ left + px, top + y }, .{ left + px, top + py }, color, ui.res);
    }
    try gui.drawColorMesh(&links, ui.shader);

    var plates: MeshBuilder = .{};
    defer plates.deinit(ui.gpa);
    var blocks: MeshBuilder = .{};
    defer blocks.deinit(ui.gpa);
    var items: MeshBuilder = .{};
    defer items.deinit(ui.gpa);
    var bars: MeshBuilder = .{};
    defer bars.deinit(ui.gpa);
    var counts: MeshBuilder = .{};
    defer counts.deinit(ui.gpa);

    const blink = blinkOn(now_ms);
    for (std.enums.values(achievements.Id)) |id| {
        const entry = id.def();
        const x = @as(f64, @floatFromInt(entry.column)) * cell - pan[0];
        const y = @as(f64, @floatFromInt(entry.row)) * cell - pan[1];
        if (x < -cell or y < -cell or x > map_width or y > map_height) continue;

        const plate_x = left + @as(f32, @floatCast(x));
        const plate_y = top + @as(f32, @floatCast(y));
        const shade = plateShade(source.hasAchievement(id), source.canUnlock(id), blink);
        try gui.appendRectColor(
            &plates,
            ui.gpa,
            plate_x - 2,
            plate_y - 2,
            plate,
            plate,
            plateUv(entry.special),
            .{ shade, shade, shade, 255 },
            ui.res,
        );

        const blocks_at = blocks.vertices.items.len;
        const items_at = items.vertices.items.len;
        try gui.appendStackIcon(
            &blocks,
            &items,
            &bars,
            &counts,
            ui.gpa,
            ui.font,
            .{ .id = entry.icon, .count = 1 },
            plate_x + icon_inset,
            plate_y + icon_inset,
            ui.res,
        );
        if (!source.canUnlock(id)) {
            blocks.scaleColors(blocks_at, locked_icon_shade);
            items.scaleColors(items_at, locked_icon_shade);
        }
    }
    try gui.drawTexturedMesh(&plates, ui.shader, ui.textures.achievement);
    try gui.drawTexturedMesh(&blocks, ui.shader, ui.textures.terrain);
    try gui.drawTexturedMesh(&items, ui.shader, ui.textures.items);

    var frame: MeshBuilder = .{};
    defer frame.deinit(ui.gpa);
    try gui.appendRect(&frame, ui.gpa, windowLeft(ui.res), windowTop(ui.res), window_width, window_height, windowUv(), ui.res);
    try gui.drawTexturedMesh(&frame, ui.shader, ui.textures.achievement);

    var chrome: MeshBuilder = .{};
    defer chrome.deinit(ui.gpa);
    var text: MeshBuilder = .{};
    defer text.deinit(ui.gpa);
    try button.append(&chrome, &text, ui.gpa, ui.font, doneButton(ui.res), button.contains(doneButton(ui.res), gx, gy), ui.res);
    try gui.appendTextNoShadow(&text, ui.gpa, ui.font, title, windowLeft(ui.res) + 15, windowTop(ui.res) + 5, title_color, ui.res);
    try gui.drawTexturedMesh(&chrome, ui.shader, ui.textures.gui);
    try gui.drawTexturedMesh(&text, ui.shader, ui.font);

    if (achievementAt(ui.mouse_x, ui.mouse_y, ui.res, pan)) |hovered| {
        try drawTooltip(ui, hovered, source, gx, gy, inventory_key);
    }

    gl.Disable(gl.BLEND);
    gl.Enable(gl.DEPTH_TEST);
}

fn drawTooltip(
    ui: gui.Ui,
    id: achievements.Id,
    source: *const game.stats.Stats,
    gx: f32,
    gy: f32,
    inventory_key: []const u8,
) !void {
    const entry = id.def();
    const x = gx + 12;
    const y = gy - 4;
    const width = @max(ui.font.stringWidth(entry.title), tooltip_min_width);
    const reachable = source.canUnlock(id);
    const unlocked = source.hasAchievement(id);

    var described: [text_wrap.buffer_bytes]u8 = undefined;
    var requires: [text_wrap.buffer_bytes]u8 = undefined;
    const body = if (reachable)
        achievements.describe(&described, id, inventory_key)
    else
        achievements.requiresText(&requires, entry.parent.?);

    const wrapped = text_wrap.wrap(ui.font, body, width);
    var body_height = wrapped.height();
    if (reachable and unlocked) body_height += 12;

    var panel: MeshBuilder = .{};
    defer panel.deinit(ui.gpa);
    var text: MeshBuilder = .{};
    defer text.deinit(ui.gpa);

    const box_width: f32 = @floatFromInt(width + 6);
    try gui.appendRectColor(&panel, ui.gpa, x - 3, y - 3, box_width, body_height + 18, gui.opaque_texel, tooltip_background, ui.res);

    const body_color = if (reachable) description_color else requires_color;
    for (0..wrapped.count) |index| {
        const line_y = y + 12 + @as(f32, @floatFromInt(index)) * text_wrap.line_height;
        try gui.appendTextNoShadow(&text, ui.gpa, ui.font, wrapped.line(index), x, line_y, body_color, ui.res);
    }
    if (reachable and unlocked) {
        try gui.appendTextColor(&text, ui.gpa, ui.font, achievements.taken_banner, x, y + body_height + 4, taken_color, ui.res);
    }
    try gui.appendTextColor(&text, ui.gpa, ui.font, entry.title, x, y, nameColor(reachable, entry.special), ui.res);

    try gui.drawColorMesh(&panel, ui.shader);
    try gui.drawTexturedMesh(&text, ui.shader, ui.font);
}

test "the map opens centred on Taking Inventory" {
    const state: State = .{};
    try std.testing.expectEqual(@as(f64, -82), state.pan[0]);
    try std.testing.expectEqual(@as(f64, -70), state.pan[1]);
}

test "the pan is fenced in by the outermost achievements" {
    try std.testing.expectEqual(@as(f64, -136), panLeft());
    try std.testing.expectEqual(@as(f64, -232), panTop());
    try std.testing.expectEqual(@as(f64, 115), panRight());
    try std.testing.expectEqual(@as(f64, 67), panBottom());

    const far = clampPan(9999, 9999);
    try std.testing.expectEqual(panRight() - 1, far[0]);
    try std.testing.expectEqual(panBottom() - 1, far[1]);

    const near = clampPan(-9999, -9999);
    try std.testing.expectEqual(panLeft(), near[0]);
    try std.testing.expectEqual(panTop(), near[1]);
}

test "the map eases toward its target and then snaps the last stretch" {
    var state: State = .{};
    state.target = .{ state.pan[0] + 100, state.pan[1] };
    const start = state.pan[0];

    state.tick();
    try std.testing.expectApproxEqAbs(start + 85, state.pan[0], 1.0e-9);

    for (0..40) |_| state.tick();
    try std.testing.expectApproxEqAbs(state.target[0], state.pan[0], 1.0e-9);
}

test "the first press of a drag only takes hold, it does not move the map" {
    const res = gui.scaledResolution(640, 480, 1);
    var state: State = .{};
    const inside_x = windowLeft(res) + 40;
    const inside_y = windowTop(res) + 40;
    const before = state.target;

    state.drag(inside_x, inside_y, res, true);
    try std.testing.expectEqual(before, state.target);

    state.drag(inside_x - 10, inside_y - 5, res, true);
    try std.testing.expectEqual(before[0] + 10, state.target[0]);
    try std.testing.expectEqual(before[1] + 5, state.target[1]);
}

test "releasing the mouse lets go, so the next press does not jump the map" {
    const res = gui.scaledResolution(640, 480, 1);
    var state: State = .{};
    const inside_x = windowLeft(res) + 40;
    const inside_y = windowTop(res) + 40;

    state.drag(inside_x, inside_y, res, true);
    state.drag(0, 0, res, false);
    const before = state.target;

    state.drag(inside_x + 60, inside_y + 60, res, true);
    try std.testing.expectEqual(before, state.target);
}

test "dragging outside the map window does nothing" {
    const res = gui.scaledResolution(640, 480, 1);
    var state: State = .{};
    const before = state.target;

    state.drag(0, 0, res, true);
    state.drag(4, 4, res, true);
    try std.testing.expectEqual(before, state.target);
}

test "Taking Inventory is the achievement under the cursor at the map's home view" {
    const res = gui.scaledResolution(640, 480, 1);
    const state: State = .{};
    const pan = state.view(1.0);

    const left = mapLeft(res) + @as(f32, @floatCast(-pan[0]));
    const top = mapTop(res) + @as(f32, @floatCast(-pan[1]));

    try std.testing.expectEqual(@as(?achievements.Id, .open_inventory), achievementAt(left + 11, top + 11, res, pan));
    try std.testing.expectEqual(@as(?achievements.Id, null), achievementAt(left + 11, top - 40, res, pan));
}

test "the done button sits below the window" {
    const res = gui.scaledResolution(640, 480, 1);
    const done = doneButton(res);

    try std.testing.expectEqual(@as(?Hit, .done), hitAt(done.x + 40, done.y + 10, res));
    try std.testing.expectEqual(@as(?Hit, null), hitAt(done.x - 40, done.y + 10, res));
}

test "the cave behind the tree is stone near the top and bedrock at the bottom" {
    try std.testing.expectEqual(world.Block.bedrock, backgroundTile(0, 60));
    try std.testing.expectEqual(world.Block.bedrock, backgroundTile(7, 35));

    var seen_dirt = false;
    var seen_stone = false;
    for (0..64) |column| {
        const tile = backgroundTile(@intCast(column), 4);
        if (tile == .dirt) seen_dirt = true;
        if (tile == .stone) seen_stone = true;
    }
    try std.testing.expect(seen_dirt);
    try std.testing.expect(seen_stone);
}

test "the background darkens the deeper the row sits" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), backgroundShade(0), 1.0e-6);
    try std.testing.expect(backgroundShade(20) < backgroundShade(10));
}

test "a plate is brightest when taken, dimmest when its parent is still locked" {
    try std.testing.expectEqual(@as(u8, 255), plateShade(true, true, false));
    try std.testing.expectEqual(@as(u8, 76), plateShade(false, false, true));
    try std.testing.expect(plateShade(false, true, true) > plateShade(false, true, false));
}

fn argb(value: i32) [4]u8 {
    const bits: u32 = @bitCast(value);
    return .{
        @truncate(bits >> 16),
        @truncate(bits >> 8),
        @truncate(bits),
        @truncate(bits >> 24),
    };
}

test "the tooltip and link colours are the ints GuiAchievements draws with" {
    try std.testing.expectEqual(argb(-6250336), description_color);
    try std.testing.expectEqual(argb(-9416624), requires_color);
    try std.testing.expectEqual(argb(-7302913), taken_color);
    try std.testing.expectEqual(argb(-1), name_open);
    try std.testing.expectEqual(argb(-128), name_open_special);
    try std.testing.expectEqual(argb(-8355712), name_locked);
    try std.testing.expectEqual(argb(-8355776), name_locked_special);
    try std.testing.expectEqual(argb(-9408400), link_unlocked);
    try std.testing.expectEqual(argb(-16777216), link_locked);
    try std.testing.expectEqual(argb(-1073741824), tooltip_background);
    try std.testing.expectEqual(@as([3]u8, .{ 0, 255, 0 }), link_open);
}

test "a name is lettered by whether it is reachable and whether it is special" {
    try std.testing.expectEqual(name_open, nameColor(true, false));
    try std.testing.expectEqual(name_open_special, nameColor(true, true));
    try std.testing.expectEqual(name_locked, nameColor(false, false));
    try std.testing.expectEqual(name_locked_special, nameColor(false, true));
}

test "a link is grey once taken, green while it blinks, and black while out of reach" {
    try std.testing.expectEqual(link_unlocked, linkColor(true, true, 0));
    try std.testing.expectEqual(link_locked, linkColor(false, false, 0));

    const bright = linkColor(false, true, 150);
    const dim = linkColor(false, true, 450);
    try std.testing.expectEqual(@as(u8, 255), bright[3]);
    try std.testing.expectEqual(@as(u8, 130), dim[3]);
    try std.testing.expectEqual(@as(u8, 255), bright[1]);
}
