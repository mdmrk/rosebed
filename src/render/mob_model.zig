const std = @import("std");

const MeshBuilder = @import("mesh_builder.zig");

pub const Box = struct {
    origin: [3]f32,
    size: [3]f32,
    tex_u: f32,
    tex_v: f32,
};

pub const Part = struct {
    box: Box,
    pivot: [3]f32,
    rotate_x: f32 = 0,
};

pub const Model = struct {
    parts: []const Part,
    head_index: usize,
    texture_width: f32,
    texture_height: f32,
};

const pig_parts = [6]Part{
    .{ .box = .{ .origin = .{ -4, -4, -8 }, .size = .{ 8, 8, 8 }, .tex_u = 0, .tex_v = 0 }, .pivot = .{ 0, 12, -6 } },
    .{ .box = .{ .origin = .{ -5, -10, -7 }, .size = .{ 10, 16, 8 }, .tex_u = 28, .tex_v = 8 }, .pivot = .{ 0, 11, 2 }, .rotate_x = std.math.pi * 0.5 },
    .{ .box = .{ .origin = .{ -2, 0, -2 }, .size = .{ 4, 6, 4 }, .tex_u = 0, .tex_v = 16 }, .pivot = .{ -3, 18, 7 } },
    .{ .box = .{ .origin = .{ -2, 0, -2 }, .size = .{ 4, 6, 4 }, .tex_u = 0, .tex_v = 16 }, .pivot = .{ 3, 18, 7 } },
    .{ .box = .{ .origin = .{ -2, 0, -2 }, .size = .{ 4, 6, 4 }, .tex_u = 0, .tex_v = 16 }, .pivot = .{ -3, 18, -5 } },
    .{ .box = .{ .origin = .{ -2, 0, -2 }, .size = .{ 4, 6, 4 }, .tex_u = 0, .tex_v = 16 }, .pivot = .{ 3, 18, -5 } },
};

pub const pig: Model = .{
    .parts = &pig_parts,
    .head_index = 0,
    .texture_width = 64,
    .texture_height = 32,
};

const biped_parts = [6]Part{
    .{ .box = .{ .origin = .{ -4, 0, -2 }, .size = .{ 8, 12, 4 }, .tex_u = 16, .tex_v = 16 }, .pivot = .{ 0, -24, 0 } },
    .{ .box = .{ .origin = .{ -2, 0, -2 }, .size = .{ 4, 12, 4 }, .tex_u = 0, .tex_v = 16 }, .pivot = .{ -2, -12, 0 } },
    .{ .box = .{ .origin = .{ -2, 0, -2 }, .size = .{ 4, 12, 4 }, .tex_u = 0, .tex_v = 16 }, .pivot = .{ 2, -12, 0 } },
    .{ .box = .{ .origin = .{ -3, -2, -2 }, .size = .{ 4, 12, 4 }, .tex_u = 40, .tex_v = 16 }, .pivot = .{ -5, -22, 0 } },
    .{ .box = .{ .origin = .{ -1, -2, -2 }, .size = .{ 4, 12, 4 }, .tex_u = 40, .tex_v = 16 }, .pivot = .{ 5, -22, 0 } },
    .{ .box = .{ .origin = .{ -4, -8, -4 }, .size = .{ 8, 8, 8 }, .tex_u = 0, .tex_v = 0 }, .pivot = .{ 0, -24, 0 } },
};

pub const biped: Model = .{
    .parts = &biped_parts,
    .head_index = 5,
    .texture_width = 64,
    .texture_height = 32,
};

const pixel_scale: f32 = 1.0 / 16.0;

fn rotateX(p: [3]f32, angle: f32) [3]f32 {
    if (angle == 0) return p;
    const c = @cos(angle);
    const s = @sin(angle);
    return .{ p[0], p[1] * c - p[2] * s, p[1] * s + p[2] * c };
}

fn rotateYaw(x: f32, z: f32, yaw: f32) [2]f32 {
    const c = @cos(yaw);
    const s = @sin(yaw);
    return .{ x * c + z * s, x * s - z * c };
}

const FaceSpec = struct {
    corners: [4][3]f32,
    rect: [4]f32,
};

fn faceSpecs(box: Box) [6]FaceSpec {
    const w = box.size[0];
    const h = box.size[1];
    const d = box.size[2];
    const x1 = box.origin[0];
    const y1 = box.origin[1];
    const z1 = box.origin[2];
    const x2 = x1 + w;
    const y2 = y1 + h;
    const z2 = z1 + d;
    const tu = box.tex_u;
    const tv = box.tex_v;

    return .{
        .{ .corners = .{ .{ x2, y1, z2 }, .{ x2, y1, z1 }, .{ x2, y2, z1 }, .{ x2, y2, z2 } }, .rect = .{ tu + d + w, tv + d, tu + 2 * d + w, tv + d + h } },
        .{ .corners = .{ .{ x1, y1, z1 }, .{ x1, y1, z2 }, .{ x1, y2, z2 }, .{ x1, y2, z1 } }, .rect = .{ tu, tv + d, tu + d, tv + d + h } },
        .{ .corners = .{ .{ x2, y1, z2 }, .{ x1, y1, z2 }, .{ x1, y1, z1 }, .{ x2, y1, z1 } }, .rect = .{ tu + d, tv, tu + d + w, tv + d } },
        .{ .corners = .{ .{ x2, y2, z1 }, .{ x1, y2, z1 }, .{ x1, y2, z2 }, .{ x2, y2, z2 } }, .rect = .{ tu + d + w, tv, tu + 2 * w + d, tv + d } },
        .{ .corners = .{ .{ x2, y1, z1 }, .{ x1, y1, z1 }, .{ x1, y2, z1 }, .{ x2, y2, z1 } }, .rect = .{ tu + d, tv + d, tu + d + w, tv + d + h } },
        .{ .corners = .{ .{ x1, y1, z2 }, .{ x2, y1, z2 }, .{ x2, y2, z2 }, .{ x1, y2, z2 } }, .rect = .{ tu + 2 * d + w, tv + d, tu + 2 * d + 2 * w, tv + d + h } },
    };
}

pub fn appendBox(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    box: Box,
    pivot: [3]f32,
    scale: f32,
    tex_width: f32,
    tex_height: f32,
) !void {
    for (faceSpecs(box)) |face| {
        var positions: [4][3]f32 = undefined;
        for (face.corners, 0..) |c, i| {
            positions[i] = .{
                (c[0] + pivot[0]) * scale,
                (c[1] + pivot[1]) * scale,
                (c[2] + pivot[2]) * scale,
            };
        }
        const uvs = [4][2]f32{
            .{ face.rect[2] / tex_width, face.rect[1] / tex_height },
            .{ face.rect[0] / tex_width, face.rect[1] / tex_height },
            .{ face.rect[0] / tex_width, face.rect[3] / tex_height },
            .{ face.rect[2] / tex_width, face.rect[3] / tex_height },
        };
        try mesh.quad(gpa, positions, uvs, .{ 255, 255, 255, 255 });
    }
}

pub fn appendPart(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    part: Part,
    tex_width: f32,
    tex_height: f32,
    entity_pos: [3]f32,
    entity_yaw: f32,
) !void {
    for (faceSpecs(part.box)) |face| {
        var positions: [4][3]f32 = undefined;
        for (face.corners, 0..) |c, i| {
            var p = rotateX(c, part.rotate_x);
            p = .{ p[0] + part.pivot[0], p[1] + part.pivot[1], p[2] + part.pivot[2] };
            const world_scale = .{ p[0] * pixel_scale, -p[1] * pixel_scale, p[2] * pixel_scale };
            const xz = rotateYaw(world_scale[0], world_scale[2], entity_yaw);
            positions[i] = .{ xz[0] + entity_pos[0], world_scale[1] + entity_pos[1], xz[1] + entity_pos[2] };
        }
        const uvs = [4][2]f32{
            .{ face.rect[2] / tex_width, face.rect[1] / tex_height },
            .{ face.rect[0] / tex_width, face.rect[1] / tex_height },
            .{ face.rect[0] / tex_width, face.rect[3] / tex_height },
            .{ face.rect[2] / tex_width, face.rect[3] / tex_height },
        };
        try mesh.quad(gpa, positions, uvs, .{ 255, 255, 255, 255 });
    }
}

test "appendPart emits 6 quads and flips the box into world space at yaw 0" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);

    const part = Part{
        .box = .{ .origin = .{ 0, 0, 0 }, .size = .{ 16, 16, 16 }, .tex_u = 0, .tex_v = 0 },
        .pivot = .{ 0, 0, 0 },
    };
    try appendPart(&mesh, gpa, part, 64, 32, .{ 0, 0, 0 }, 0);

    try std.testing.expectEqual(@as(usize, 24), mesh.vertices.items.len);

    var min: [3]f32 = .{ 1000, 1000, 1000 };
    var max: [3]f32 = .{ -1000, -1000, -1000 };
    for (mesh.vertices.items) |v| {
        min = .{ @min(min[0], v.x), @min(min[1], v.y), @min(min[2], v.z) };
        max = .{ @max(max[0], v.x), @max(max[1], v.y), @max(max[2], v.z) };
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), min[0], 1.0e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), max[0], 1.0e-5);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), min[1], 1.0e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), max[1], 1.0e-5);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), min[2], 1.0e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), max[2], 1.0e-5);
}
