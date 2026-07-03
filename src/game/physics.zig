const std = @import("std");
const math = @import("math");
const world = @import("world");

const max_colliding_boxes = 64;

fn collidingBoxes(world_map: *const world.World, query: math.AABB, out: *[max_colliding_boxes]math.AABB) usize {
    const min_x = math.util.floorDouble(query.min_x);
    const max_x = math.util.floorDouble(query.max_x);
    const min_y = std.math.clamp(math.util.floorDouble(query.min_y), 0, world.constants.chunk_height - 1);
    const max_y = std.math.clamp(math.util.floorDouble(query.max_y), 0, world.constants.chunk_height - 1);
    const min_z = math.util.floorDouble(query.min_z);
    const max_z = math.util.floorDouble(query.max_z);

    var count: usize = 0;
    var x = min_x;
    while (x <= max_x) : (x += 1) {
        var y = min_y;
        while (y <= max_y) : (y += 1) {
            var z = min_z;
            while (z <= max_z) : (z += 1) {
                const id = world_map.getBlockId(x, y, z);
                if (world.block.isOpaque(id) and count < max_colliding_boxes) {
                    const fx: f64 = @floatFromInt(x);
                    const fy: f64 = @floatFromInt(y);
                    const fz: f64 = @floatFromInt(z);
                    out[count] = math.AABB.init(fx, fy, fz, fx + 1, fy + 1, fz + 1);
                    count += 1;
                }
            }
        }
    }
    return count;
}

pub const MoveResult = struct {
    aabb: math.AABB,
    dx: f64,
    dy: f64,
    dz: f64,
};

pub fn moveEntity(world_map: *const world.World, aabb: math.AABB, dx: f64, dy: f64, dz: f64) MoveResult {
    var box_buf: [max_colliding_boxes]math.AABB = undefined;
    const broad = aabb.addCoord(dx, dy, dz);
    const count = collidingBoxes(world_map, broad, &box_buf);
    const boxes = box_buf[0..count];

    var result = aabb;

    var moved_y = dy;
    for (boxes) |box| moved_y = box.calculateYOffset(result, moved_y);
    result = result.offset(0, moved_y, 0);

    var moved_x = dx;
    for (boxes) |box| moved_x = box.calculateXOffset(result, moved_x);
    result = result.offset(moved_x, 0, 0);

    var moved_z = dz;
    for (boxes) |box| moved_z = box.calculateZOffset(result, moved_z);
    result = result.offset(0, 0, moved_z);

    return .{ .aabb = result, .dx = moved_x, .dy = moved_y, .dz = moved_z };
}

fn testWorldWithFloor(floor_top_y: u32) !world.World {
    var w = world.World.init(std.testing.allocator);
    const chunk = try w.createChunk(0, 0);
    for (0..world.constants.chunk_width) |x| {
        for (0..world.constants.chunk_width) |z| {
            var y: u32 = 0;
            while (y < floor_top_y) : (y += 1) {
                chunk.setBlockId(@intCast(x), @intCast(y), @intCast(z), world.block.stone);
            }
        }
    }
    return w;
}

test "falling onto a floor stops the vertical offset at the surface" {
    var w = try testWorldWithFloor(1);
    defer w.deinit();
    const aabb = math.AABB.init(0, 1.1, 0, 0.6, 2.9, 0.6);
    const result = moveEntity(&w, aabb, 0, -0.5, 0);
    try std.testing.expectApproxEqAbs(@as(f64, -0.1), result.dy, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.aabb.min_y, 1.0e-9);
}

test "walking into a wall clamps the horizontal offset at the surface" {
    var w = try testWorldWithFloor(0);
    defer w.deinit();
    w.setBlockId(2, 0, 0, world.block.stone);
    const aabb = math.AABB.init(1.2, 0, -0.3, 1.8, 1.8, 0.3);
    const result = moveEntity(&w, aabb, 0.5, 0, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), result.dx, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), result.aabb.max_x, 1.0e-9);
}

test "open air applies the full requested movement" {
    var w = try testWorldWithFloor(0);
    defer w.deinit();
    const aabb = math.AABB.init(0, 50, 0, 0.6, 51.8, 0.6);
    const result = moveEntity(&w, aabb, 1.0, -1.0, 1.0);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.dx, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -1.0), result.dy, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.dz, 1.0e-9);
}
