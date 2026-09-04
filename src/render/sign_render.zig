const std = @import("std");

const math = @import("math");
const world = @import("world");
const BlockPos = world.BlockPos;

const Font = @import("Font.zig");
const item_lighting = @import("item_lighting.zig");
const MeshBuilder = @import("MeshBuilder.zig");
const mesh_testing = @import("mesh_testing.zig");
const mob_model = @import("mob_model.zig");

pub const texture_width: f32 = 64;
pub const texture_height: f32 = 32;
pub const model_scale: f32 = 2.0 / 3.0;
pub const board_height: f32 = 12.0 / 16.0 * model_scale;
pub const text_scale: f32 = 1.0 / 60.0 * model_scale;
pub const text_lift: f32 = 0.5 * model_scale;
pub const text_stand_off: f32 = 0.07 * model_scale;
pub const line_spacing: f32 = 10;
pub const wall_drop: f32 = -5.0 / 16.0;
pub const wall_back: f32 = -7.0 / 16.0;
pub const text_color: [4]u8 = .{ 0, 0, 0, 255 };

const board: mob_model.Box = .{ .origin = .{ -12, -14, -1 }, .size = .{ 24, 12, 2 }, .tex_u = 0, .tex_v = 0 };
const stick: mob_model.Box = .{ .origin = .{ -1, -2, -1 }, .size = .{ 2, 14, 2 }, .tex_u = 0, .tex_v = 14 };

pub const Pose = struct {
    origin: [3]f32,
    turn: f32,
    offset: [3]f32,

    fn place(self: Pose, point: [3]f32) [3]f32 {
        const x = point[0] + self.offset[0];
        const y = point[1] + self.offset[1];
        const z = point[2] + self.offset[2];
        const cos = @cos(self.turn);
        const sin = @sin(self.turn);
        return .{
            self.origin[0] + x * cos + z * sin,
            self.origin[1] + y,
            self.origin[2] - x * sin + z * cos,
        };
    }
};

pub fn blockAngle(id: world.Block, metadata: u4) f32 {
    if (id == .sign_post) return @as(f32, @floatFromInt(@as(u32, metadata) * 360)) / 16.0;
    return switch (metadata) {
        2 => 180.0,
        4 => 90.0,
        5 => -90.0,
        else => 0.0,
    };
}

pub fn poseAt(id: world.Block, metadata: u4, x: f32, y: f32, z: f32) Pose {
    const origin: [3]f32 = .{ x + 0.5, y + board_height, z + 0.5 };
    const turn = -blockAngle(id, metadata) * std.math.pi / 180.0;
    if (id == .sign_post) return .{ .origin = origin, .turn = turn, .offset = .{ 0, 0, 0 } };
    return .{ .origin = origin, .turn = turn, .offset = .{ 0, wall_drop, wall_back } };
}

pub fn poseFor(id: world.Block, metadata: u4, pos: BlockPos) Pose {
    return poseAt(id, metadata, @floatFromInt(pos.x), @floatFromInt(pos.y), @floatFromInt(pos.z));
}

fn placeSince(mesh: *MeshBuilder, first_vertex: usize, pose: Pose) void {
    for (mesh.vertices.items[first_vertex..]) |*vertex| {
        const placed = pose.place(.{ vertex.x, vertex.y, vertex.z });
        vertex.x = placed[0];
        vertex.y = placed[1];
        vertex.z = placed[2];
    }
}

fn orientOf(pose: Pose) [3][3]f32 {
    const cos = @cos(pose.turn);
    const sin = @sin(pose.turn);
    return .{
        .{ cos, 0, -sin },
        .{ 0, -1, 0 },
        .{ -sin, 0, -cos },
    };
}

fn flipModelSince(mesh: *MeshBuilder, first_vertex: usize) void {
    for (mesh.vertices.items[first_vertex..]) |*vertex| {
        vertex.x *= model_scale;
        vertex.y *= -model_scale;
        vertex.z *= -model_scale;
    }
}

pub fn appendBoardAt(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    brightness: f32,
    id: world.Block,
    metadata: u4,
    x: f32,
    y: f32,
    z: f32,
) !void {
    const first_vertex = mesh.vertices.items.len;
    const pose = poseAt(id, metadata, x, y, z);
    const lit: item_lighting.Lit = .{
        .orient = orientOf(pose),
        .material = item_lighting.material(brightness, .{ 1, 1, 1 }),
    };

    try mob_model.appendBox(mesh, gpa, board, .{ 0, 0, 0 }, 1.0 / 16.0, texture_width, texture_height, lit);
    if (id == .sign_post) {
        try mob_model.appendBox(mesh, gpa, stick, .{ 0, 0, 0 }, 1.0 / 16.0, texture_width, texture_height, lit);
    }

    flipModelSince(mesh, first_vertex);
    placeSince(mesh, first_vertex, pose);
}

pub fn appendBoard(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    id: world.Block,
    metadata: u4,
    pos: BlockPos,
) !void {
    try appendBoardAt(
        mesh,
        gpa,
        world.light.brightnessAt(world_map, pos, 0),
        id,
        metadata,
        @floatFromInt(pos.x),
        @floatFromInt(pos.y),
        @floatFromInt(pos.z),
    );
}

pub fn lineOffsetY(index: usize) f32 {
    return @as(f32, @floatFromInt(index)) * line_spacing -
        @as(f32, @floatFromInt(world.sign.line_count)) * line_spacing / 2.0;
}

pub fn appendText(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    font: Font,
    id: world.Block,
    metadata: u4,
    pos: BlockPos,
    state: world.sign.Sign,
    highlighted_line: ?usize,
) !void {
    try appendTextAt(
        mesh,
        gpa,
        font,
        id,
        metadata,
        @floatFromInt(pos.x),
        @floatFromInt(pos.y),
        @floatFromInt(pos.z),
        state,
        highlighted_line,
    );
}

pub fn appendTextAt(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    font: Font,
    id: world.Block,
    metadata: u4,
    x: f32,
    y: f32,
    z: f32,
    state: world.sign.Sign,
    highlighted_line: ?usize,
) !void {
    const pose = poseAt(id, metadata, x, y, z);

    for (0..world.sign.line_count) |index| {
        var buffer: [world.sign.max_line_length + 4]u8 = undefined;
        const text = if (highlighted_line == index)
            std.fmt.bufPrint(&buffer, "> {s} <", .{state.line(index)}) catch state.line(index)
        else
            state.line(index);
        if (text.len == 0) continue;

        const width: f32 = @floatFromInt(font.stringWidth(text));
        var cursor = -width / 2.0;
        const top = lineOffsetY(index);

        for (text) |c| {
            const uv = Font.glyphUv(c);
            const g = Font.glyph_draw_size;
            const corners = [4][2]f32{
                .{ cursor, top },
                .{ cursor + g, top },
                .{ cursor + g, top + g },
                .{ cursor, top + g },
            };

            var positions: [4][3]f32 = undefined;
            for (corners, 0..) |corner, i| {
                positions[i] = pose.place(.{
                    corner[0] * text_scale,
                    corner[1] * -text_scale + text_lift,
                    text_stand_off,
                });
            }

            try mesh.quad(gpa, positions, .{
                .{ uv.u0, uv.v0 },
                .{ uv.u1, uv.v0 },
                .{ uv.u1, uv.v1 },
                .{ uv.u0, uv.v1 },
            }, text_color);

            cursor += @floatFromInt(font.char_width[c]);
        }
    }
}

test "the board's faces are shaded by the way they point once the sign is placed" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);

    try appendBoardAt(&mesh, gpa, 1.0, .sign_post, 0, 0, 0, 0);

    const shading = mesh_testing.horizontalFaceShading(mesh);

    try std.testing.expectEqual(@as(u8, 255), shading.top.?);
    try std.testing.expectEqual(@as(u8, @intFromFloat(255.0 * item_lighting.ambient)), shading.bottom.?);
}

test "a sign post turns with its metadata, a wall sign with the face it hangs on" {
    const post = poseFor(.sign_post, 4, .init(8, 64, 8));
    try std.testing.expectApproxEqAbs(@as(f32, -std.math.pi / 2.0), post.turn, 1.0e-6);
    try std.testing.expectEqual([3]f32{ 0, 0, 0 }, post.offset);

    const facing_south = poseFor(.wall_sign, 3, .init(8, 64, 8));
    try std.testing.expectApproxEqAbs(@as(f32, 0), facing_south.turn, 1.0e-6);

    const facing_north = poseFor(.wall_sign, 2, .init(8, 64, 8));
    try std.testing.expectApproxEqAbs(@as(f32, -std.math.pi), facing_north.turn, 1.0e-6);

    const facing_west = poseFor(.wall_sign, 5, .init(8, 64, 8));
    try std.testing.expectApproxEqAbs(@as(f32, std.math.pi / 2.0), facing_west.turn, 1.0e-6);
}

test "a wall sign is pulled back against the block it hangs on, a post is not" {
    const post = poseFor(.sign_post, 0, .init(0, 0, 0));
    try std.testing.expectEqual(@as(f32, 0), post.offset[2]);

    const wall = poseFor(.wall_sign, 3, .init(0, 0, 0));
    try std.testing.expectEqual(wall_back, wall.offset[2]);
    try std.testing.expectEqual(wall_drop, wall.offset[1]);
}

test "the four lines stack around the middle of the board" {
    try std.testing.expectEqual(@as(f32, -20), lineOffsetY(0));
    try std.testing.expectEqual(@as(f32, -10), lineOffsetY(1));
    try std.testing.expectEqual(@as(f32, 0), lineOffsetY(2));
    try std.testing.expectEqual(@as(f32, 10), lineOffsetY(3));
}

test "a post carries its stick, a wall sign does not" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    _ = try world_map.createChunk(0, 0);

    var post: MeshBuilder = .{};
    defer post.deinit(gpa);
    try appendBoard(&post, gpa, &world_map, .sign_post, 0, .init(8, 5, 8));

    var wall: MeshBuilder = .{};
    defer wall.deinit(gpa);
    try appendBoard(&wall, gpa, &world_map, .wall_sign, 3, .init(8, 5, 8));

    try std.testing.expectEqual(@as(usize, 48), post.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 24), wall.vertices.items.len);
}
