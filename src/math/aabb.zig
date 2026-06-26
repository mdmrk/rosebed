const std = @import("std");

const AABB = @This();

min_x: f64,
min_y: f64,
min_z: f64,
max_x: f64,
max_y: f64,
max_z: f64,

pub fn init(min_x: f64, min_y: f64, min_z: f64, max_x: f64, max_y: f64, max_z: f64) AABB {
    return .{ .min_x = min_x, .min_y = min_y, .min_z = min_z, .max_x = max_x, .max_y = max_y, .max_z = max_z };
}

pub fn expand(b: AABB, x: f64, y: f64, z: f64) AABB {
    return .{
        .min_x = b.min_x - x,
        .min_y = b.min_y - y,
        .min_z = b.min_z - z,
        .max_x = b.max_x + x,
        .max_y = b.max_y + y,
        .max_z = b.max_z + z,
    };
}

pub fn contract(b: AABB, x: f64, y: f64, z: f64) AABB {
    return b.expand(-x, -y, -z);
}

pub fn offset(b: AABB, x: f64, y: f64, z: f64) AABB {
    return .{
        .min_x = b.min_x + x,
        .min_y = b.min_y + y,
        .min_z = b.min_z + z,
        .max_x = b.max_x + x,
        .max_y = b.max_y + y,
        .max_z = b.max_z + z,
    };
}

pub fn addCoord(b: AABB, x: f64, y: f64, z: f64) AABB {
    var r = b;
    if (x < 0.0) r.min_x += x;
    if (x > 0.0) r.max_x += x;
    if (y < 0.0) r.min_y += y;
    if (y > 0.0) r.max_y += y;
    if (z < 0.0) r.min_z += z;
    if (z > 0.0) r.max_z += z;
    return r;
}

pub fn intersects(a: AABB, b: AABB) bool {
    if (b.max_x <= a.min_x or b.min_x >= a.max_x) return false;
    if (b.max_y <= a.min_y or b.min_y >= a.max_y) return false;
    if (b.max_z <= a.min_z or b.min_z >= a.max_z) return false;
    return true;
}

pub fn calculateXOffset(this: AABB, other: AABB, dx: f64) f64 {
    if (other.max_y <= this.min_y or other.min_y >= this.max_y) return dx;
    if (other.max_z <= this.min_z or other.min_z >= this.max_z) return dx;

    var d = dx;
    if (d > 0.0 and other.max_x <= this.min_x) {
        const clamp = this.min_x - other.max_x;
        if (clamp < d) d = clamp;
    }
    if (d < 0.0 and other.min_x >= this.max_x) {
        const clamp = this.max_x - other.min_x;
        if (clamp > d) d = clamp;
    }
    return d;
}

pub fn calculateYOffset(this: AABB, other: AABB, dy: f64) f64 {
    if (other.max_x <= this.min_x or other.min_x >= this.max_x) return dy;
    if (other.max_z <= this.min_z or other.min_z >= this.max_z) return dy;

    var d = dy;
    if (d > 0.0 and other.max_y <= this.min_y) {
        const clamp = this.min_y - other.max_y;
        if (clamp < d) d = clamp;
    }
    if (d < 0.0 and other.min_y >= this.max_y) {
        const clamp = this.max_y - other.min_y;
        if (clamp > d) d = clamp;
    }
    return d;
}

pub fn calculateZOffset(this: AABB, other: AABB, dz: f64) f64 {
    if (other.max_x <= this.min_x or other.min_x >= this.max_x) return dz;
    if (other.max_y <= this.min_y or other.min_y >= this.max_y) return dz;

    var d = dz;
    if (d > 0.0 and other.max_z <= this.min_z) {
        const clamp = this.min_z - other.max_z;
        if (clamp < d) d = clamp;
    }
    if (d < 0.0 and other.min_z >= this.max_z) {
        const clamp = this.max_z - other.min_z;
        if (clamp > d) d = clamp;
    }
    return d;
}

test "intersects detects overlap and rejects touching boxes" {
    const a = AABB.init(0, 0, 0, 1, 1, 1);
    const overlapping = AABB.init(0.5, 0.5, 0.5, 1.5, 1.5, 1.5);
    const touching = AABB.init(1, 0, 0, 2, 1, 1);
    try std.testing.expect(a.intersects(overlapping));
    try std.testing.expect(!a.intersects(touching));
}

test "calculateXOffset clamps motion at the point of contact" {
    const floor = AABB.init(0, 0, 0, 1, 1, 1);
    const mover = AABB.init(2, 0, 0, 3, 1, 1);
    try std.testing.expectApproxEqAbs(@as(f64, -1.0), floor.calculateXOffset(mover, -5.0), 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), floor.calculateXOffset(mover, 5.0), 1.0e-9);
}

test "expand/contract are inverses" {
    const a = AABB.init(0, 0, 0, 1, 1, 1);
    const grown = a.expand(1, 1, 1);
    try std.testing.expectApproxEqAbs(@as(f64, -1.0), grown.min_x, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), grown.max_x, 1.0e-9);
    const back = grown.contract(1, 1, 1);
    try std.testing.expectApproxEqAbs(a.min_x, back.min_x, 1.0e-9);
    try std.testing.expectApproxEqAbs(a.max_x, back.max_x, 1.0e-9);
}
