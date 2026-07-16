const std = @import("std");
const math = @import("math");
const world = @import("world");

pub const Hit = struct {
    x: i32,
    y: i32,
    z: i32,
    face: world.Side,
    distance: f64,
};

const BoundsHit = struct {
    face: world.Side,
    distance: f64,
};

const max_steps: u32 = 200;

const low_faces = [3]world.Side{ .west, .down, .north };
const high_faces = [3]world.Side{ .east, .up, .south };

fn boundsHit(
    bounds: world.block.Bounds,
    cell: [3]i32,
    origin: [3]f64,
    direction: [3]f64,
    max_distance: f64,
) ?BoundsHit {
    var entry: f64 = 0;
    var exit = max_distance;
    var entry_face = world.Side.down;
    var exit_face = world.Side.down;
    var entered = false;

    for (0..3) |axis| {
        const base: f64 = @floatFromInt(cell[axis]);
        const low = base + bounds.min[axis];
        const high = base + bounds.max[axis];

        if (direction[axis] == 0.0) {
            if (origin[axis] < low or origin[axis] > high) return null;
            continue;
        }

        const to_low = (low - origin[axis]) / direction[axis];
        const to_high = (high - origin[axis]) / direction[axis];
        const near = @min(to_low, to_high);
        const far = @max(to_low, to_high);

        if (near > entry) {
            entry = near;
            entry_face = if (to_low < to_high) low_faces[axis] else high_faces[axis];
            entered = true;
        }
        if (far < exit) {
            exit = far;
            exit_face = if (to_low < to_high) high_faces[axis] else low_faces[axis];
        }
    }

    if (entry > exit) return null;
    return .{ .face = if (entered) entry_face else exit_face, .distance = entry };
}

pub fn cast(world_map: *const world.World, origin: math.Vec3, direction: [3]f32, max_distance: f64) ?Hit {
    const start = [3]f64{ origin.x, origin.y, origin.z };
    const along = [3]f64{ direction[0], direction[1], direction[2] };

    var cell = [3]i32{
        math.util.floorDouble(start[0]),
        math.util.floorDouble(start[1]),
        math.util.floorDouble(start[2]),
    };

    for (0..max_steps) |_| {
        const id = world_map.getBlock(cell[0], cell[1], cell[2]);
        if (id != world.Block.air and !id.isLiquid()) {
            const metadata = world_map.getBlockMetadata(cell[0], cell[1], cell[2]);
            if (boundsHit(id.selectionBounds(metadata), cell, start, along, max_distance)) |hit| {
                return .{ .x = cell[0], .y = cell[1], .z = cell[2], .face = hit.face, .distance = hit.distance };
            }
        }

        var crossed: f64 = std.math.inf(f64);
        var axis: usize = 3;
        for (0..3) |candidate| {
            if (along[candidate] == 0.0) continue;
            const boundary: f64 = @floatFromInt(cell[candidate] + @as(i32, if (along[candidate] > 0.0) 1 else 0));
            const distance = (boundary - start[candidate]) / along[candidate];
            if (distance < crossed) {
                crossed = distance;
                axis = candidate;
            }
        }

        if (axis == 3 or crossed > max_distance) return null;
        cell[axis] += if (along[axis] > 0.0) 1 else -1;
    }

    return null;
}

fn testWorldWithFloor() !world.World {
    var w = world.World.init(std.testing.allocator);
    const chunk = try w.createChunk(0, 0);
    for (0..world.constants.chunk_width) |x| {
        for (0..world.constants.chunk_width) |z| {
            chunk.setBlock(@intCast(x), 5, @intCast(z), world.Block.stone);
        }
    }
    return w;
}

test "looking straight down hits the floor's top face" {
    var w = try testWorldWithFloor();
    defer w.deinit();
    const hit = cast(&w, math.Vec3.init(8, 10, 8), .{ 0, -1, 0 }, 20.0).?;
    try std.testing.expectEqual(@as(i32, 8), hit.x);
    try std.testing.expectEqual(@as(i32, 5), hit.y);
    try std.testing.expectEqual(@as(i32, 8), hit.z);
    try std.testing.expectEqual(world.Side.up, hit.face);
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
    const chunk = try w.createChunk(0, 0);
    chunk.setBlock(10, 5, 8, world.Block.stone);
    const hit = cast(&w, math.Vec3.init(5, 5.5, 8), .{ 1, 0, 0 }, 20.0).?;
    try std.testing.expectEqual(@as(i32, 10), hit.x);
    try std.testing.expectEqual(world.Side.west, hit.face);
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
    const chunk = try w.createChunk(0, 0);
    chunk.setBlock(8, 5, 8, world.Block.tall_grass);

    const hit = cast(&w, math.Vec3.init(8.5, 10, 8.5), .{ 0, -1, 0 }, 20.0).?;
    try std.testing.expectEqual(@as(i32, 5), hit.y);
}

test "aiming past a wall torch targets the wall behind it" {
    var w = world.World.init(std.testing.allocator);
    defer w.deinit();
    const chunk = try w.createChunk(0, 0);
    chunk.setBlock(10, 5, 8, world.Block.stone);
    chunk.setBlock(9, 5, 8, world.Block.torch);
    chunk.setBlockMetadata(9, 5, 8, 2);

    const on_torch = cast(&w, math.Vec3.init(5, 5.5, 8.5), .{ 1, 0, 0 }, 20.0).?;
    try std.testing.expectEqual(@as(i32, 9), on_torch.x);
    try std.testing.expectEqual(world.Side.west, on_torch.face);

    const beside_torch = cast(&w, math.Vec3.init(5, 5.5, 8.9), .{ 1, 0, 0 }, 20.0).?;
    try std.testing.expectEqual(@as(i32, 10), beside_torch.x);
    try std.testing.expectEqual(world.Side.west, beside_torch.face);

    const above_torch = cast(&w, math.Vec3.init(5, 5.9, 8.5), .{ 1, 0, 0 }, 20.0).?;
    try std.testing.expectEqual(@as(i32, 10), above_torch.x);
}

test "a standing torch is only targetable down its own narrow column" {
    var w = world.World.init(std.testing.allocator);
    defer w.deinit();
    const chunk = try w.createChunk(0, 0);
    chunk.setBlock(8, 5, 8, world.Block.stone);
    chunk.setBlock(8, 6, 8, world.Block.torch);
    chunk.setBlockMetadata(8, 6, 8, 5);

    const centred = cast(&w, math.Vec3.init(8.5, 12, 8.5), .{ 0, -1, 0 }, 20.0).?;
    try std.testing.expectEqual(@as(i32, 6), centred.y);
    try std.testing.expectEqual(world.Side.up, centred.face);

    const off_centre = cast(&w, math.Vec3.init(8.9, 12, 8.5), .{ 0, -1, 0 }, 20.0).?;
    try std.testing.expectEqual(@as(i32, 5), off_centre.y);
    try std.testing.expectEqual(world.Side.up, off_centre.face);
}

test "a snow layer is only hit within its eighth of a block" {
    var w = world.World.init(std.testing.allocator);
    defer w.deinit();
    const chunk = try w.createChunk(0, 0);
    chunk.setBlock(10, 5, 8, world.Block.stone);
    chunk.setBlock(9, 5, 8, world.Block.snow_layer);

    const low = cast(&w, math.Vec3.init(5, 5.05, 8.5), .{ 1, 0, 0 }, 20.0).?;
    try std.testing.expectEqual(@as(i32, 9), low.x);

    const high = cast(&w, math.Vec3.init(5, 5.5, 8.5), .{ 1, 0, 0 }, 20.0).?;
    try std.testing.expectEqual(@as(i32, 10), high.x);
}

test "looking down onto a snow layer reports its own top, not the block's" {
    var w = world.World.init(std.testing.allocator);
    defer w.deinit();
    const chunk = try w.createChunk(0, 0);
    chunk.setBlock(8, 5, 8, world.Block.snow_layer);

    const hit = cast(&w, math.Vec3.init(8.5, 12, 8.5), .{ 0, -1, 0 }, 20.0).?;
    try std.testing.expectEqual(@as(i32, 5), hit.y);
    try std.testing.expectEqual(world.Side.up, hit.face);
}

test "standing inside a plant still targets it, by the face the ray leaves through" {
    var w = world.World.init(std.testing.allocator);
    defer w.deinit();
    const chunk = try w.createChunk(0, 0);
    chunk.setBlock(8, 5, 8, world.Block.tall_grass);

    const hit = cast(&w, math.Vec3.init(8.5, 5.4, 8.5), .{ 0, -1, 0 }, 20.0).?;
    try std.testing.expectEqual(@as(i32, 8), hit.x);
    try std.testing.expectEqual(@as(i32, 5), hit.y);
    try std.testing.expectEqual(world.Side.down, hit.face);
}

