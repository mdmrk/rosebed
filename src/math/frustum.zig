const std = @import("std");
const Mat4 = @import("mat4.zig");

const Frustum = @This();

pub const Plane = [4]f32;

planes: [6]Plane,

fn normalized(plane: Plane) Plane {
    const length = @sqrt(plane[0] * plane[0] + plane[1] * plane[1] + plane[2] * plane[2]);
    if (length == 0) return plane;
    return .{ plane[0] / length, plane[1] / length, plane[2] / length, plane[3] / length };
}

pub fn fromViewProjection(view_projection: Mat4) Frustum {
    const m: [16]f32 = view_projection.m;
    const row = struct {
        fn at(matrix: [16]f32, index: usize) Plane {
            return .{ matrix[index], matrix[4 + index], matrix[8 + index], matrix[12 + index] };
        }
    }.at;

    const w = row(m, 3);
    var planes: [6]Plane = undefined;
    for (0..3) |axis| {
        const a = row(m, axis);
        for (0..4) |i| {
            planes[axis * 2][i] = w[i] + a[i];
            planes[axis * 2 + 1][i] = w[i] - a[i];
        }
    }
    for (&planes) |*plane| plane.* = normalized(plane.*);
    return .{ .planes = planes };
}

pub fn containsBox(self: Frustum, min: [3]f32, max: [3]f32) bool {
    for (self.planes) |plane| {
        const nearest = [3]f32{
            if (plane[0] >= 0) max[0] else min[0],
            if (plane[1] >= 0) max[1] else min[1],
            if (plane[2] >= 0) max[2] else min[2],
        };
        if (plane[0] * nearest[0] + plane[1] * nearest[1] + plane[2] * nearest[2] + plane[3] < 0) {
            return false;
        }
    }
    return true;
}

fn lookingDownNegativeZ() Mat4 {
    return Mat4.perspective(70.0 * std.math.pi / 180.0, 16.0 / 9.0, 0.05, 1000.0);
}

test "a box straight ahead is inside and one behind the camera is not" {
    const frustum = fromViewProjection(lookingDownNegativeZ());

    try std.testing.expect(frustum.containsBox(.{ -1, -1, -20 }, .{ 1, 1, -18 }));
    try std.testing.expect(!frustum.containsBox(.{ -1, -1, 18 }, .{ 1, 1, 20 }));
}

test "a box far off to the side falls outside the cone" {
    const frustum = fromViewProjection(lookingDownNegativeZ());

    try std.testing.expect(!frustum.containsBox(.{ 500, -1, -20 }, .{ 520, 1, -18 }));
    try std.testing.expect(!frustum.containsBox(.{ -1, 500, -20 }, .{ 1, 520, -18 }));
}

test "a box beyond the far plane is culled" {
    const frustum = fromViewProjection(lookingDownNegativeZ());

    try std.testing.expect(frustum.containsBox(.{ -1, -1, -900 }, .{ 1, 1, -800 }));
    try std.testing.expect(!frustum.containsBox(.{ -1, -1, -2000 }, .{ 1, 1, -1500 }));
}

test "a box the camera sits inside is never culled" {
    const frustum = fromViewProjection(lookingDownNegativeZ());
    try std.testing.expect(frustum.containsBox(.{ -50, -50, -50 }, .{ 50, 50, 50 }));
}

test "turning the camera around swaps which side is visible" {
    const projection = lookingDownNegativeZ();
    const behind = fromViewProjection(projection.mul(Mat4.rotationY(std.math.pi)));

    try std.testing.expect(behind.containsBox(.{ -1, -1, 18 }, .{ 1, 1, 20 }));
    try std.testing.expect(!behind.containsBox(.{ -1, -1, -20 }, .{ 1, 1, -18 }));
}

test "a box just clipping the edge of the view still counts as visible" {
    const frustum = fromViewProjection(lookingDownNegativeZ());
    try std.testing.expect(frustum.containsBox(.{ -1000, -1, -20 }, .{ 0, 1, -18 }));
}
