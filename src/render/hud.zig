const std = @import("std");

const game = @import("game");
const gl = @import("gl");
const world = @import("world");

const gui = @import("gui.zig");
const MeshBuilder = @import("MeshBuilder.zig");

const hotbar_width: f32 = 182;
const hotbar_height: f32 = 22;
const highlight_width: f32 = 24;
const highlight_height: f32 = 22;
const slot_pitch: f32 = 20;
const crosshair_size: f32 = 16;

const heart_count: usize = 10;
const heart_size: f32 = 9;
const heart_pitch: f32 = 8;
const heart_row_offset: f32 = 32;
const heart_container_u: f32 = 16;
const heart_blink_u: f32 = 25;
const heart_full_u: f32 = 52;
const heart_half_u: f32 = 61;
const heart_flash_full_u: f32 = 70;
const heart_flash_half_u: f32 = 79;

const sleep_veil_color = [3]u8{ 16, 16, 32 };
const sleep_veil_alpha: f32 = 220.0;

const blink_period: i32 = 3;
const blink_hold_ticks: i32 = 10;
const low_health: i32 = 4;
const jitter_seed: i32 = 312871;

const armor_row_v: f32 = 9;
const armor_empty_u: f32 = 16;
const armor_half_u: f32 = 25;
const armor_full_u: f32 = 34;

const bubble_row_v: f32 = 18;
const bubble_full_u: f32 = 16;
const bubble_popping_u: f32 = 25;
const bubble_pitch: f32 = 8;

fn appendIcon(mesh: *MeshBuilder, ui: gui.Ui, u: f32, v: f32, x: f32, y: f32) !void {
    try gui.appendRect(mesh, ui.gpa, x, y, heart_size, heart_size, gui.pixelUv(u, v, heart_size, heart_size, gui.gui_texture_size, gui.gui_texture_size), ui.res);
}

pub fn blinking(hurt_resistance: i32) bool {
    if (hurt_resistance < blink_hold_ticks) return false;
    return @rem(@divTrunc(hurt_resistance, blink_period), 2) == 1;
}

pub const AirBubbles = struct {
    full: i32,
    popping: i32,
};

pub fn airBubbles(air: i32) AirBubbles {
    const full: i32 = @intFromFloat(@ceil(@as(f64, @floatFromInt(air - 2)) * 10.0 / 300.0));
    const total: i32 = @intFromFloat(@ceil(@as(f64, @floatFromInt(air)) * 10.0 / 300.0));
    return .{ .full = full, .popping = total - full };
}

pub fn draw(
    ui: gui.Ui,
    inventory: game.Inventory,
    player: game.Player,
    submerged: bool,
    update_counter: i32,
) !void {
    const health = player.health;
    const hotbar_x = @floor(ui.res.width / 2.0) - hotbar_width / 2.0;
    const hotbar_y = ui.res.height - hotbar_height;

    gl.Disable(gl.DEPTH_TEST);
    gl.Enable(gl.BLEND);
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

    var chrome: MeshBuilder = .{};
    defer chrome.deinit(ui.gpa);
    try gui.appendRect(&chrome, ui.gpa, hotbar_x, hotbar_y, hotbar_width, hotbar_height, gui.pixelUv(0, 0, hotbar_width, hotbar_height, gui.gui_texture_size, gui.gui_texture_size), ui.res);
    const highlight_x = hotbar_x - 1.0 + @as(f32, @floatFromInt(inventory.selected)) * slot_pitch;
    try gui.appendRect(&chrome, ui.gpa, highlight_x, hotbar_y - 1.0, highlight_width, highlight_height, gui.pixelUv(0, 22, highlight_width, highlight_height, gui.gui_texture_size, gui.gui_texture_size), ui.res);
    try gui.drawTexturedMesh(&chrome, ui.shader, ui.textures.gui);

    var crosshair: MeshBuilder = .{};
    defer crosshair.deinit(ui.gpa);
    const crosshair_x = @floor(ui.res.width / 2.0) - 7.0;
    const crosshair_y = @floor(ui.res.height / 2.0) - 7.0;
    try gui.appendRect(&crosshair, ui.gpa, crosshair_x, crosshair_y, crosshair_size, crosshair_size, gui.pixelUv(0, 0, crosshair_size, crosshair_size, gui.gui_texture_size, gui.gui_texture_size), ui.res);
    gl.BlendFunc(gl.ONE_MINUS_DST_COLOR, gl.ONE_MINUS_SRC_COLOR);
    try gui.drawTexturedMesh(&crosshair, ui.shader, ui.textures.icons);
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

    var hearts: MeshBuilder = .{};
    defer hearts.deinit(ui.gpa);
    const heart_row_y = ui.res.height - heart_row_offset;
    const armor = inventory.totalArmorValue();
    const flash = blinking(player.hurt_resistance);
    var jitter: world.JavaRandom = .init(update_counter *% jitter_seed);
    for (0..heart_count) |i| {
        const heart_x = hotbar_x + @as(f32, @floatFromInt(i)) * heart_pitch;
        const filled: i32 = @intCast(i * 2 + 1);

        if (armor > 0) {
            const armor_x = hotbar_x + hotbar_width - heart_size - @as(f32, @floatFromInt(i)) * heart_pitch;
            const armor_u: f32 = if (filled < armor) armor_full_u else if (filled == armor) armor_half_u else armor_empty_u;
            try appendIcon(&hearts, ui, armor_u, armor_row_v, armor_x, heart_row_y);
        }

        var heart_y = heart_row_y;
        if (health <= low_health) heart_y += @floatFromInt(jitter.nextIntBound(2));

        const container_u: f32 = if (flash) heart_blink_u else heart_container_u;
        try appendIcon(&hearts, ui, container_u, 0, heart_x, heart_y);

        if (flash) {
            if (filled < player.prev_health) {
                try appendIcon(&hearts, ui, heart_flash_full_u, 0, heart_x, heart_y);
            } else if (filled == player.prev_health) {
                try appendIcon(&hearts, ui, heart_flash_half_u, 0, heart_x, heart_y);
            }
        }

        if (filled < health) {
            try appendIcon(&hearts, ui, heart_full_u, 0, heart_x, heart_y);
        } else if (filled == health) {
            try appendIcon(&hearts, ui, heart_half_u, 0, heart_x, heart_y);
        }
    }

    if (submerged) {
        const bubbles = airBubbles(player.air);
        const bubble_y = heart_row_y - heart_size;
        for (0..@intCast(bubbles.full + bubbles.popping)) |i| {
            const bubble_x = hotbar_x + @as(f32, @floatFromInt(i)) * bubble_pitch;
            const bubble_u: f32 = if (i < @as(usize, @intCast(bubbles.full))) bubble_full_u else bubble_popping_u;
            try appendIcon(&hearts, ui, bubble_u, bubble_row_v, bubble_x, bubble_y);
        }
    }
    try gui.drawTexturedMesh(&hearts, ui.shader, ui.textures.icons);

    var block_icons: MeshBuilder = .{};
    defer block_icons.deinit(ui.gpa);
    var item_icons: MeshBuilder = .{};
    defer item_icons.deinit(ui.gpa);
    var bars: MeshBuilder = .{};
    defer bars.deinit(ui.gpa);
    var text: MeshBuilder = .{};
    defer text.deinit(ui.gpa);

    for (0..game.Inventory.hotbar_size) |i| {
        const stack = inventory.slots[i] orelse continue;
        const slot_x = hotbar_x + 3.0 + @as(f32, @floatFromInt(i)) * slot_pitch;
        const slot_y = hotbar_y + 3.0;
        try gui.appendStackIcon(&block_icons, &item_icons, &bars, &text, ui.gpa, ui.font, stack, slot_x, slot_y, ui.res);
    }

    try gui.drawTexturedMesh(&block_icons, ui.shader, ui.textures.terrain);
    try gui.drawTexturedMesh(&item_icons, ui.shader, ui.textures.items);
    try gui.drawColorMesh(&bars, ui.shader);
    try gui.drawTexturedMesh(&text, ui.shader, ui.font);

    const fade = player.sleepFade();
    if (fade > 0) {
        var veil: MeshBuilder = .{};
        defer veil.deinit(ui.gpa);
        const alpha: u8 = @intFromFloat(sleep_veil_alpha * fade);
        try gui.appendRectColor(&veil, ui.gpa, 0, 0, ui.res.width, ui.res.height, gui.opaque_texel, sleep_veil_color ++ [1]u8{alpha}, ui.res);
        try gui.drawTexturedMesh(&veil, ui.shader, ui.textures.gui);
    }

    gl.Disable(gl.BLEND);
    gl.Enable(gl.DEPTH_TEST);
}

test "a full lungful shows ten whole bubbles and none popping" {
    const full = airBubbles(game.Player.max_air);
    try std.testing.expectEqual(@as(i32, 10), full.full);
    try std.testing.expectEqual(@as(i32, 0), full.popping);
}

test "the leading bubble pops before the row gives one up" {
    const popping = airBubbles(271);
    try std.testing.expectEqual(@as(i32, 9), popping.full);
    try std.testing.expectEqual(@as(i32, 1), popping.popping);

    const settled = airBubbles(270);
    try std.testing.expectEqual(@as(i32, 9), settled.full);
    try std.testing.expectEqual(@as(i32, 0), settled.popping);
}

test "the last bubble is gone by the time the lungs are empty" {
    const last = airBubbles(1);
    try std.testing.expectEqual(@as(i32, 0), last.full);
    try std.testing.expectEqual(@as(i32, 1), last.popping);

    const empty = airBubbles(0);
    try std.testing.expectEqual(@as(i32, 0), empty.full);
    try std.testing.expectEqual(@as(i32, 0), empty.popping);

    const drowning = airBubbles(-19);
    try std.testing.expectEqual(@as(i32, 0), drowning.full);
    try std.testing.expectEqual(@as(i32, 0), drowning.popping);
}

test "the hearts blink on and off in three tick stripes after a hit" {
    try std.testing.expect(!blinking(20));
    try std.testing.expect(!blinking(19));
    try std.testing.expect(!blinking(18));
    try std.testing.expect(blinking(17));
    try std.testing.expect(blinking(15));
    try std.testing.expect(!blinking(14));
    try std.testing.expect(!blinking(12));
    try std.testing.expect(blinking(11));
    try std.testing.expect(blinking(10));
}

test "the blink stops once the resistance window is nearly spent" {
    try std.testing.expect(!blinking(9));
    try std.testing.expect(!blinking(6));
    try std.testing.expect(!blinking(3));
    try std.testing.expect(!blinking(0));
}
