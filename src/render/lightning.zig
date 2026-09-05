const std = @import("std");

const math = @import("math");
const world = @import("world");

const MeshBuilder = @import("MeshBuilder.zig");

pub const segments: usize = 8;
pub const segment_height: f64 = 16.0;
pub const passes: usize = 4;
pub const branches: usize = 3;
pub const shade: f32 = 0.5;
pub const alpha: f32 = 0.3;
pub const trunk_jitter: i32 = 11;
pub const branch_jitter: i32 = 31;
pub const pass_width: f64 = 0.2;
pub const base_width: f64 = 0.1;
pub const ring_corners: usize = 5;

fn boltColor() [4]u8 {
    return .{
        @intFromFloat(0.9 * shade * 255.0),
        @intFromFloat(0.9 * shade * 255.0),
        @intFromFloat(1.0 * shade * 255.0),
        @intFromFloat(alpha * 255.0),
    };
}

fn cornerOffset(corner: usize, width: f64) [2]f64 {
    var dx = -width;
    var dz = -width;
    if (corner == 1 or corner == 2) dx += width * 2.0;
    if (corner == 2 or corner == 3) dz += width * 2.0;
    return .{ dx, dz };
}

pub fn append(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    at: math.Vec3,
    seed: i64,
) !void {
    var drift: [segments]f64 = @splat(0);
    var sway: [segments]f64 = @splat(0);

    var walk: world.JavaRandom = .init(seed);
    var x: f64 = 0;
    var z: f64 = 0;
    var index: usize = segments;
    while (index > 0) {
        index -= 1;
        drift[index] = x;
        sway[index] = z;
        x += @floatFromInt(walk.nextIntBound(trunk_jitter) - 5);
        z += @floatFromInt(walk.nextIntBound(trunk_jitter) - 5);
    }

    const tint = boltColor();

    for (0..passes) |pass| {
        var rand: world.JavaRandom = .init(seed);

        for (0..branches) |branch| {
            const top: usize = if (branch > 0) segments - 1 - branch else segments - 1;
            const bottom: usize = if (branch > 0) top -| 2 else 0;

            var offset_x = drift[top] - x;
            var offset_z = sway[top] - z;

            var level: usize = top + 1;
            while (level > bottom) {
                level -= 1;
                const prev_x = offset_x;
                const prev_z = offset_z;
                const jitter: i32 = if (branch == 0) trunk_jitter else branch_jitter;
                const spread: f64 = if (branch == 0) 5 else 15;
                offset_x += @as(f64, @floatFromInt(rand.nextIntBound(jitter))) - spread;
                offset_z += @as(f64, @floatFromInt(rand.nextIntBound(jitter))) - spread;

                var lower = base_width + @as(f64, @floatFromInt(pass)) * pass_width;
                if (branch == 0) lower *= @as(f64, @floatFromInt(level)) * 0.1 + 1.0;

                var upper = base_width + @as(f64, @floatFromInt(pass)) * pass_width;
                if (branch == 0) upper *= (@as(f64, @floatFromInt(level)) - 1.0) * 0.1 + 1.0;

                try appendRing(mesh, gpa, at, .{
                    .level = level,
                    .lower = lower,
                    .upper = upper,
                    .offset_x = offset_x,
                    .offset_z = offset_z,
                    .prev_x = prev_x,
                    .prev_z = prev_z,
                }, tint);
            }
        }
    }
}

const Ring = struct {
    level: usize,
    lower: f64,
    upper: f64,
    offset_x: f64,
    offset_z: f64,
    prev_x: f64,
    prev_z: f64,
};

fn appendRing(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    at: math.Vec3,
    ring: Ring,
    tint: [4]u8,
) !void {
    const bottom = at.y + @as(f64, @floatFromInt(ring.level)) * segment_height;
    const top = at.y + @as(f64, @floatFromInt(ring.level + 1)) * segment_height;

    for (0..ring_corners - 1) |corner| {
        const near = cornerOffset(corner, ring.lower);
        const far = cornerOffset(corner + 1, ring.lower);
        const near_top = cornerOffset(corner, ring.upper);
        const far_top = cornerOffset(corner + 1, ring.upper);

        try mesh.quad(
            gpa,
            .{
                point(mesh, at, near[0] + ring.offset_x, bottom, near[1] + ring.offset_z),
                point(mesh, at, far[0] + ring.offset_x, bottom, far[1] + ring.offset_z),
                point(mesh, at, far_top[0] + ring.prev_x, top, far_top[1] + ring.prev_z),
                point(mesh, at, near_top[0] + ring.prev_x, top, near_top[1] + ring.prev_z),
            },
            .{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } },
            tint,
        );
    }
}

fn point(mesh: *const MeshBuilder, at: math.Vec3, dx: f64, y: f64, dz: f64) [3]f32 {
    return mesh.local(at.x + 0.5 + dx, y, at.z + 0.5 + dz);
}

test "a bolt is built from four passes of tapering segments" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);

    try append(&mesh, gpa, math.Vec3.init(8, 64, 8), 12345);

    try std.testing.expect(mesh.vertices.items.len > 0);
    try std.testing.expect(mesh.vertices.items.len % 4 == 0);
}

test "the same seed draws the same bolt twice" {
    const gpa = std.testing.allocator;

    var first: MeshBuilder = .{};
    defer first.deinit(gpa);
    var second: MeshBuilder = .{};
    defer second.deinit(gpa);

    try append(&first, gpa, math.Vec3.init(0, 0, 0), -99);
    try append(&second, gpa, math.Vec3.init(0, 0, 0), -99);

    try std.testing.expectEqual(first.vertices.items.len, second.vertices.items.len);
    for (first.vertices.items, second.vertices.items) |a, b| {
        try std.testing.expectEqual(a.x, b.x);
        try std.testing.expectEqual(a.y, b.y);
        try std.testing.expectEqual(a.z, b.z);
    }
}

test "a bolt climbs from the ground toward the cloud deck" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);

    try append(&mesh, gpa, math.Vec3.init(0, 60, 0), 7);

    var lowest: f32 = std.math.floatMax(f32);
    var highest: f32 = -std.math.floatMax(f32);
    for (mesh.vertices.items) |vertex| {
        lowest = @min(lowest, vertex.y);
        highest = @max(highest, vertex.y);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 60.0), lowest, 1.0e-3);
    try std.testing.expect(highest > 60.0 + @as(f32, segment_height));
}
