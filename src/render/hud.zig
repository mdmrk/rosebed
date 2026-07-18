const game = @import("game");
const gl = @import("gl");

const gui = @import("gui.zig");
const MeshBuilder = @import("mesh_builder.zig");

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
const heart_full_u: f32 = 52;
const heart_half_u: f32 = 61;

const armor_row_v: f32 = 9;
const armor_empty_u: f32 = 16;
const armor_half_u: f32 = 25;
const armor_full_u: f32 = 34;

fn appendIcon(mesh: *MeshBuilder, ui: gui.Ui, u: f32, v: f32, x: f32, y: f32) !void {
    try gui.appendRect(mesh, ui.gpa, x, y, heart_size, heart_size, gui.pixelUv(u, v, heart_size, heart_size, gui.gui_texture_size, gui.gui_texture_size), ui.res);
}

pub fn draw(
    ui: gui.Ui,
    inventory: game.Inventory,
    health: i32,
) !void {
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
    const heart_y = ui.res.height - heart_row_offset;
    const armor = inventory.totalArmorValue();
    for (0..heart_count) |i| {
        const heart_x = hotbar_x + @as(f32, @floatFromInt(i)) * heart_pitch;
        try appendIcon(&hearts, ui, heart_container_u, 0, heart_x, heart_y);
        const filled: i32 = @intCast(i * 2 + 1);

        if (armor > 0) {
            const armor_x = hotbar_x + hotbar_width - heart_size - @as(f32, @floatFromInt(i)) * heart_pitch;
            const armor_u: f32 = if (filled < armor) armor_full_u else if (filled == armor) armor_half_u else armor_empty_u;
            try appendIcon(&hearts, ui, armor_u, armor_row_v, armor_x, heart_y);
        }

        const u: f32 = if (filled < health) heart_full_u else if (filled == health) heart_half_u else continue;
        try appendIcon(&hearts, ui, u, 0, heart_x, heart_y);
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

    gl.Disable(gl.BLEND);
    gl.Enable(gl.DEPTH_TEST);
}
