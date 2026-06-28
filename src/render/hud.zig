const std = @import("std");
const gl = @import("gl");
const world = @import("world");
const game = @import("game");

const Atlas = @import("atlas.zig");
const MeshBuilder = @import("mesh_builder.zig");
const GpuMesh = @import("gpu_mesh.zig");
const Shader = @import("shader.zig");

const identity: [16]f32 = .{
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    0, 0, 0, 1,
};

pub const gui_scale: f32 = 2.0;

const hotbar_width: f32 = 182;
const hotbar_height: f32 = 22;
const highlight_width: f32 = 24;
const highlight_height: f32 = 22;
const slot_pitch: f32 = 20;
const icon_size: f32 = 16;
const crosshair_size: f32 = 16;

fn toNdc(x: f32, y: f32, scaled_width: f32, scaled_height: f32) [2]f32 {
    return .{
        (x / scaled_width) * 2.0 - 1.0,
        1.0 - (y / scaled_height) * 2.0,
    };
}

fn addRect(mesh: *MeshBuilder, gpa: std.mem.Allocator, x: f32, y: f32, w: f32, h: f32, scaled_width: f32, scaled_height: f32, color: [4]u8) !void {
    const tl = toNdc(x, y, scaled_width, scaled_height);
    const tr = toNdc(x + w, y, scaled_width, scaled_height);
    const br = toNdc(x + w, y + h, scaled_width, scaled_height);
    const bl = toNdc(x, y + h, scaled_width, scaled_height);
    try mesh.quad(gpa, .{
        .{ tl[0], tl[1], 0 }, .{ tr[0], tr[1], 0 }, .{ br[0], br[1], 0 }, .{ bl[0], bl[1], 0 },
    }, .{ .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 } }, color);
}

fn addIcon(mesh: *MeshBuilder, gpa: std.mem.Allocator, x: f32, y: f32, w: f32, h: f32, tile: u8, scaled_width: f32, scaled_height: f32) !void {
    const uv = Atlas.tileUv(tile);
    const tl = toNdc(x, y, scaled_width, scaled_height);
    const tr = toNdc(x + w, y, scaled_width, scaled_height);
    const br = toNdc(x + w, y + h, scaled_width, scaled_height);
    const bl = toNdc(x, y + h, scaled_width, scaled_height);
    try mesh.quad(gpa, .{
        .{ tl[0], tl[1], 0 }, .{ tr[0], tr[1], 0 }, .{ br[0], br[1], 0 }, .{ bl[0], bl[1], 0 },
    }, .{ .{ uv.u0, uv.v0 }, .{ uv.u1, uv.v0 }, .{ uv.u1, uv.v1 }, .{ uv.u0, uv.v1 } }, .{ 255, 255, 255, 255 });
}

pub fn draw(
    gpa: std.mem.Allocator,
    solid_shader: Shader,
    icon_shader: Shader,
    atlas: Atlas,
    inventory: game.Inventory,
    screen_width: f32,
    screen_height: f32,
) !void {
    const scaled_width = screen_width / gui_scale;
    const scaled_height = screen_height / gui_scale;

    const hotbar_x = scaled_width / 2.0 - hotbar_width / 2.0;
    const hotbar_y = scaled_height - hotbar_height;

    gl.Disable(gl.DEPTH_TEST);
    gl.Enable(gl.BLEND);

    var chrome: MeshBuilder = .{};
    defer chrome.deinit(gpa);
    try addRect(&chrome, gpa, hotbar_x, hotbar_y, hotbar_width, hotbar_height, scaled_width, scaled_height, .{ 20, 20, 20, 160 });
    const highlight_x = hotbar_x - 1.0 + @as(f32, @floatFromInt(inventory.selected)) * slot_pitch;
    try addRect(&chrome, gpa, highlight_x, hotbar_y - 1.0, highlight_width, highlight_height, scaled_width, scaled_height, .{ 255, 255, 255, 200 });

    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
    var chrome_gpu = GpuMesh.upload(&chrome);
    defer chrome_gpu.deinit();
    solid_shader.use();
    chrome_gpu.draw();

    var crosshair: MeshBuilder = .{};
    defer crosshair.deinit(gpa);
    const crosshair_x = scaled_width / 2.0 - 7.0;
    const crosshair_y = scaled_height / 2.0 - 7.0;
    try addRect(&crosshair, gpa, crosshair_x, crosshair_y + crosshair_size / 2.0 - 1.0, crosshair_size, 2.0, scaled_width, scaled_height, .{ 255, 255, 255, 255 });
    try addRect(&crosshair, gpa, crosshair_x + crosshair_size / 2.0 - 1.0, crosshair_y, 2.0, crosshair_size, scaled_width, scaled_height, .{ 255, 255, 255, 255 });

    gl.BlendFunc(gl.ONE_MINUS_DST_COLOR, gl.ONE_MINUS_SRC_COLOR);
    var crosshair_gpu = GpuMesh.upload(&crosshair);
    defer crosshair_gpu.deinit();
    crosshair_gpu.draw();
    gl.Disable(gl.BLEND);

    var icons: MeshBuilder = .{};
    defer icons.deinit(gpa);
    for (0..game.Inventory.hotbar_size) |i| {
        const stack = inventory.slots[i] orelse continue;
        if (stack.id > 255) continue;
        const tile = world.block.faceTextures(@intCast(stack.id))[world.block.up];
        const slot_x = hotbar_x + 2.0 + @as(f32, @floatFromInt(i)) * slot_pitch;
        const slot_y = hotbar_y + 3.0;
        try addIcon(&icons, gpa, slot_x, slot_y, icon_size, icon_size, tile, scaled_width, scaled_height);
    }

    if (icons.vertices.items.len > 0) {
        var icons_gpu = GpuMesh.upload(&icons);
        defer icons_gpu.deinit();
        icon_shader.use();
        gl.ActiveTexture(gl.TEXTURE0);
        atlas.bind();
        icon_shader.setInt("u_atlas", 0);
        icon_shader.setMat4("u_view_proj", identity);
        icons_gpu.draw();
    }

    gl.Enable(gl.DEPTH_TEST);
}
