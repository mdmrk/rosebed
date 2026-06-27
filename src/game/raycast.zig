const std = @import("std");
const math = @import("math");
const world = @import("world");

pub const Hit = struct {
    x: i32,
    y: i32,
    z: i32,
    face: u3,
};

const step: f64 = 0.05;

pub fn cast(world_map: *const world.World, origin: math.Vec3, direction: [3]f32, max_distance: f64) ?Hit {
    var traveled: f64 = 0;
    var prev_bx = math.util.floorDouble(origin.x);
    var prev_by = math.util.floorDouble(origin.y);
    var prev_bz = math.util.floorDouble(origin.z);

    while (traveled < max_distance) : (traveled += step) {
        const x = origin.x + @as(f64, direction[0]) * traveled;
        const y = origin.y + @as(f64, direction[1]) * traveled;
        const z = origin.z + @as(f64, direction[2]) * traveled;
        const bx = math.util.floorDouble(x);
        const by = math.util.floorDouble(y);
        const bz = math.util.floorDouble(z);

        defer {
            prev_bx = bx;
            prev_by = by;
            prev_bz = bz;
        }

        const id = world_map.getBlockId(bx, by, bz);
        if (id == world.block.air) continue;

        var face: u3 = world.block.down;
        if (bx != prev_bx) {
            face = if (bx > prev_bx) world.block.west else world.block.east;
        } else if (by != prev_by) {
            face = if (by > prev_by) world.block.down else world.block.up;
        } else if (bz != prev_bz) {
            face = if (bz > prev_bz) world.block.north else world.block.south;
        }

        return .{ .x = bx, .y = by, .z = bz, .face = face };
    }

    return null;
}

fn testWorldWithFloor() !world.World {
    var w = world.World.init(std.testing.allocator);
    var chunk = world.Chunk.init(0, 0);
    for (0..world.constants.chunk_width) |x| {
        for (0..world.constants.chunk_width) |z| {
            chunk.setBlockId(@intCast(x), 5, @intCast(z), world.block.stone);
        }
    }
    try w.chunks.put(std.testing.allocator, .{ .x = 0, .z = 0 }, chunk);
    return w;
}

test "looking straight down hits the floor's top face" {
    var w = try testWorldWithFloor();
    defer w.deinit();
    const hit = cast(&w, math.Vec3.init(8, 10, 8), .{ 0, -1, 0 }, 20.0).?;
    try std.testing.expectEqual(@as(i32, 8), hit.x);
    try std.testing.expectEqual(@as(i32, 5), hit.y);
    try std.testing.expectEqual(@as(i32, 8), hit.z);
    try std.testing.expectEqual(world.block.up, hit.face);
}

test "looking away from anything solid finds nothing within range" {
    var w = try testWorldWithFloor();
    defer w.deinit();
    const hit = cast(&w, math.Vec3.init(8, 10, 8), .{ 0, 1, 0 }, 20.0);
    try std.testing.expect(hit == null);
}

test "approaching a wall from the side hits its facing side face" {
    var w = world.World.init(std.testing.allocator);
    defer w.deinit();
    var chunk = world.Chunk.init(0, 0);
    chunk.setBlockId(10, 5, 8, world.block.stone);
    try w.chunks.put(std.testing.allocator, .{ .x = 0, .z = 0 }, chunk);
    const hit = cast(&w, math.Vec3.init(5, 5.5, 8), .{ 1, 0, 0 }, 20.0).?;
    try std.testing.expectEqual(@as(i32, 10), hit.x);
    try std.testing.expectEqual(world.block.west, hit.face);
}

test "a target beyond max_distance is not hit" {
    var w = try testWorldWithFloor();
    defer w.deinit();
    const hit = cast(&w, math.Vec3.init(8, 10, 8), .{ 0, -1, 0 }, 2.0);
    try std.testing.expect(hit == null);
}

test "a cross-shaped plant is still targetable despite having no collision" {
    var w = world.World.init(std.testing.allocator);
    defer w.deinit();
    var chunk = world.Chunk.init(0, 0);
    chunk.setBlockId(8, 5, 8, world.block.tall_grass);
    try w.chunks.put(std.testing.allocator, .{ .x = 0, .z = 0 }, chunk);

    const hit = cast(&w, math.Vec3.init(8.5, 10, 8.5), .{ 0, -1, 0 }, 20.0).?;
    try std.testing.expectEqual(@as(i32, 5), hit.y);
}
