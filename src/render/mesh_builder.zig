const std = @import("std");

const MeshBuilder = @This();

pub const Vertex = struct {
    x: f32,
    y: f32,
    z: f32,
    u: f32,
    v: f32,
    color: [4]u8,
};

vertices: std.ArrayList(Vertex) = .empty,
indices: std.ArrayList(u32) = .empty,

pub fn deinit(self: *MeshBuilder, gpa: std.mem.Allocator) void {
    self.vertices.deinit(gpa);
    self.indices.deinit(gpa);
}

pub fn quad(
    self: *MeshBuilder,
    gpa: std.mem.Allocator,
    positions: [4][3]f32,
    uvs: [4][2]f32,
    color: [4]u8,
) !void {
    const base: u32 = @intCast(self.vertices.items.len);
    for (positions, uvs) |p, uv| {
        try self.vertices.append(gpa, .{
            .x = p[0],
            .y = p[1],
            .z = p[2],
            .u = uv[0],
            .v = uv[1],
            .color = color,
        });
    }
    try self.indices.appendSlice(gpa, &.{
        base, base + 1, base + 2,
        base, base + 2, base + 3,
    });
}

test "quad appends 4 vertices and 2 triangles" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);

    try mesh.quad(
        gpa,
        .{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 1, 1, 0 }, .{ 0, 1, 0 } },
        .{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } },
        .{ 255, 255, 255, 255 },
    );

    try std.testing.expectEqual(@as(usize, 4), mesh.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 6), mesh.indices.items.len);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 0, 2, 3 }, mesh.indices.items);
    try std.testing.expectEqual(@as(f32, 1.0), mesh.vertices.items[2].x);
}

test "a second quad's indices offset from the first quad's vertex count" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);

    const face = .{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 1, 1, 0 }, .{ 0, 1, 0 } };
    const uv = .{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };
    try mesh.quad(gpa, face, uv, .{ 255, 255, 255, 255 });
    try mesh.quad(gpa, face, uv, .{ 255, 255, 255, 255 });

    try std.testing.expectEqual(@as(usize, 8), mesh.vertices.items.len);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7 }, mesh.indices.items);
}
