const std = @import("std");

const world = @import("world");

const button = @import("../button.zig");
const gui = @import("../gui.zig");
const MeshBuilder = @import("../MeshBuilder.zig");
const sign_render = @import("../sign_render.zig");

pub const title = "Edit sign message:";
pub const title_y: f32 = 40;
pub const title_color: [4]u8 = .{ 255, 255, 255, 255 };

pub const preview_scale: f32 = 93.75;
pub const preview_lift: f32 = -1.0625;
pub const preview_origin: [3]f32 = .{ -0.5, -0.75, -0.5 };
pub const blink_ticks: i32 = 6;

pub const Hit = enum { done };

pub const State = struct {
    pos: world.BlockPos = .{ .x = 0, .y = 0, .z = 0 },
    line: usize = 0,
    counter: i32 = 0,

    pub fn tick(self: *State) void {
        self.counter +%= 1;
    }

    pub fn previousLine(self: *State) void {
        self.line = (self.line + world.sign.line_count - 1) % world.sign.line_count;
    }

    pub fn nextLine(self: *State) void {
        self.line = (self.line + 1) % world.sign.line_count;
    }

    pub fn showsCursor(self: State) bool {
        return @rem(@divTrunc(self.counter, blink_ticks), 2) == 0;
    }
};

fn doneButton(res: gui.Scaled) button.Button {
    return .{
        .x = @floor(res.width / 2.0) - 100,
        .y = @floor(res.height / 4.0) + 120,
        .w = 200,
        .label = "Done",
        .enabled = true,
    };
}

pub fn hitAt(mouse_x: f32, mouse_y: f32, res: gui.Scaled) ?Hit {
    const gx = mouse_x / res.factor;
    const gy = mouse_y / res.factor;
    if (button.contains(doneButton(res), gx, gy)) return .done;
    return null;
}

fn projectSince(mesh: *MeshBuilder, first_vertex: usize, angle: f32, res: gui.Scaled) void {
    const cos = @cos(angle);
    const sin = @sin(angle);
    const centre = @floor(res.ortho_width / 2.0);

    for (mesh.vertices.items[first_vertex..]) |*vertex| {
        const lifted_y = vertex.y + preview_lift;
        const turned_x = vertex.x * cos + vertex.z * sin;
        const turned_z = -vertex.x * sin + vertex.z * cos;

        const screen_x = centre - turned_x * preview_scale;
        const screen_y = -lifted_y * preview_scale;
        const ndc = gui.toNdc(screen_x, screen_y, res);
        vertex.x = ndc[0];
        vertex.y = ndc[1];
        vertex.z = turned_z * 0.001;
    }
}

pub fn draw(
    ui: gui.Ui,
    state: State,
    id: world.Block,
    metadata: u4,
    sign: world.sign.Sign,
) !void {
    const gx = ui.mouse_x / ui.res.factor;
    const gy = ui.mouse_y / ui.res.factor;

    gui.beginOverlay();

    try gui.drawBackdrop(ui, .veil);

    var backgrounds: MeshBuilder = .{};
    defer backgrounds.deinit(ui.gpa);
    var text: MeshBuilder = .{};
    defer text.deinit(ui.gpa);

    const done = doneButton(ui.res);
    try button.append(&backgrounds, &text, ui.gpa, ui.font, done, button.contains(done, gx, gy), ui.res);

    try gui.appendCenteredText(&text, ui.gpa, ui.font, title, title_y, title_color, ui.res);

    const turn = sign_render.blockAngle(id, metadata) * std.math.pi / 180.0 + std.math.pi;

    var board: MeshBuilder = .{};
    defer board.deinit(ui.gpa);
    try sign_render.appendBoardAt(
        &board,
        ui.gpa,
        1.0,
        id,
        metadata,
        preview_origin[0],
        preview_origin[1],
        preview_origin[2],
    );
    projectSince(&board, 0, turn, ui.res);

    var board_text: MeshBuilder = .{};
    defer board_text.deinit(ui.gpa);
    try sign_render.appendTextAt(
        &board_text,
        ui.gpa,
        ui.font,
        id,
        metadata,
        preview_origin[0],
        preview_origin[1],
        preview_origin[2],
        sign,
        if (state.showsCursor()) state.line else null,
    );
    projectSince(&board_text, 0, turn, ui.res);

    try gui.drawTexturedMesh(&board, ui.shader, ui.textures.sign);
    try gui.drawTexturedMesh(&board_text, ui.shader, ui.font);
    try gui.drawTexturedMesh(&backgrounds, ui.shader, ui.textures.gui);
    try gui.drawTexturedMesh(&text, ui.shader, ui.font);

    gui.endOverlay();
}

test "the edit cursor walks the four lines and wraps at both ends" {
    var state: State = .{};
    try std.testing.expectEqual(@as(usize, 0), state.line);

    state.nextLine();
    try std.testing.expectEqual(@as(usize, 1), state.line);

    state.previousLine();
    state.previousLine();
    try std.testing.expectEqual(@as(usize, 3), state.line);

    state.nextLine();
    try std.testing.expectEqual(@as(usize, 0), state.line);
}

test "the cursor blinks on and off in six tick stripes" {
    var state: State = .{};
    try std.testing.expect(state.showsCursor());

    for (0..blink_ticks) |_| state.tick();
    try std.testing.expect(!state.showsCursor());

    for (0..blink_ticks) |_| state.tick();
    try std.testing.expect(state.showsCursor());
}
