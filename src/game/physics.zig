const std = @import("std");

const math = @import("math");
const world = @import("world");

const max_colliding_boxes = 64;

fn offsetBox(bounds: world.block.Bounds, x: i32, y: i32, z: i32) math.AABB {
    const fx: f64 = @floatFromInt(x);
    const fy: f64 = @floatFromInt(y);
    const fz: f64 = @floatFromInt(z);
    return math.AABB.init(
        fx + bounds.min[0],
        fy + bounds.min[1],
        fz + bounds.min[2],
        fx + bounds.max[0],
        fy + bounds.max[1],
        fz + bounds.max[2],
    );
}

fn blockBoxes(world_map: *const world.World, id: world.Block, x: i32, y: i32, z: i32, out: *[2]math.AABB) usize {
    const bounds = switch (id.shape()) {
        .door => world.block.doorBounds(world_map.getBlockMetadata(x, y, z)),
        .trapdoor => world.block.trapdoorBounds(world_map.getBlockMetadata(x, y, z)),
        .cake => world.block.cakeCollisionBounds(world_map.getBlockMetadata(x, y, z)),
        .bed => world.block.Bounds{ .min = .{ 0, 0, 0 }, .max = .{ 1, world.block.bed_height, 1 } },
        .stairs => {
            for (world.block.stairsBoxes(world_map.getBlockMetadata(x, y, z)), out) |bounds, *box| {
                box.* = offsetBox(bounds, x, y, z);
            }
            return 2;
        },
        .partial => |height| world.block.Bounds{ .min = .{ 0, 0, 0 }, .max = .{ 1, height, 1 } },
        else => world.block.Bounds{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 1 } },
    };
    out[0] = offsetBox(bounds, x, y, z);
    return 1;
}

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
                const id = world_map.getBlock(x, y, z);
                if (!id.isSolid()) continue;
                var boxes: [2]math.AABB = undefined;
                const emitted = blockBoxes(world_map, id, x, y, z, &boxes);
                for (boxes[0..emitted]) |box| {
                    if (count == max_colliding_boxes) break;
                    out[count] = box;
                    count += 1;
                }
            }
        }
    }
    return count;
}

const ledge_step: f64 = 0.05;

fn shaveTowardLedge(world_map: *const world.World, aabb: math.AABB, axis_dx: f64, axis_dz: f64, amount_in: f64) f64 {
    var box_buf: [max_colliding_boxes]math.AABB = undefined;
    var amount = amount_in;
    while (amount != 0.0) {
        const probe = aabb.offset(axis_dx * amount, -1.0, axis_dz * amount);
        if (collidingBoxes(world_map, probe, &box_buf) != 0) break;
        if (amount < ledge_step and amount >= -ledge_step) {
            amount = 0.0;
        } else if (amount > 0.0) {
            amount -= ledge_step;
        } else {
            amount += ledge_step;
        }
    }
    return amount;
}

pub fn clampToLedge(world_map: *const world.World, aabb: math.AABB, dx: f64, dz: f64) [2]f64 {
    return .{
        shaveTowardLedge(world_map, aabb, 1.0, 0.0, dx),
        shaveTowardLedge(world_map, aabb, 0.0, 1.0, dz),
    };
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

pub const StepResult = struct {
    aabb: math.AABB,
    dx: f64,
    dy: f64,
    dz: f64,
    y_size: f64,
};

const step_lock: f64 = 0.05;

pub fn moveEntityStepping(
    world_map: *const world.World,
    aabb: math.AABB,
    dx: f64,
    dy: f64,
    dz: f64,
    step_height: f64,
    on_ground: bool,
    sneaking: bool,
    y_size: f64,
) StepResult {
    const plain = moveEntity(world_map, aabb, dx, dy, dz);
    const flat: StepResult = .{
        .aabb = plain.aabb,
        .dx = plain.dx,
        .dy = plain.dy,
        .dz = plain.dz,
        .y_size = y_size,
    };

    const landed = on_ground or (dy != plain.dy and dy < 0.0);
    const unlocked = sneaking or y_size < step_lock;
    const obstructed = dx != plain.dx or dz != plain.dz;
    if (step_height <= 0.0 or !landed or !unlocked or !obstructed) return flat;

    const raised = moveEntity(world_map, aabb, dx, step_height, dz);
    const settled = moveEntity(world_map, raised.aabb, 0, -step_height, 0);

    if (plain.dx * plain.dx + plain.dz * plain.dz >= raised.dx * raised.dx + raised.dz * raised.dz) return flat;

    var stepped_y_size = y_size;
    const overhang = settled.aabb.min_y - @trunc(settled.aabb.min_y);
    if (overhang > 0.0) stepped_y_size += overhang + 0.01;

    return .{
        .aabb = settled.aabb,
        .dx = raised.dx,
        .dy = settled.dy,
        .dz = raised.dz,
        .y_size = stepped_y_size,
    };
}

const flow_acceleration: f64 = 0.014;

pub fn fluidSurface(world_map: *const world.World, x: i32, y: i32, z: i32) f64 {
    const air = world.fluid.percentAir(world_map.getBlockMetadata(x, y, z));
    return @as(f64, @floatFromInt(y + 1)) - @as(f64, air);
}

pub fn handleWaterMovement(world_map: *const world.World, box: math.AABB) ?math.Vec3 {
    const query = box.expand(0, -0.4, 0).contract(0.001, 0.001, 0.001);
    const min_x = math.util.floorDouble(query.min_x);
    const max_x = math.util.floorDouble(query.max_x + 1.0);
    const min_y = math.util.floorDouble(query.min_y);
    const max_y = math.util.floorDouble(query.max_y + 1.0);
    const min_z = math.util.floorDouble(query.min_z);
    const max_z = math.util.floorDouble(query.max_z + 1.0);

    if (!world_map.chunksExist(min_x, min_y, min_z, max_x, max_y, max_z)) return null;

    var touching = false;
    var flow = math.Vec3.init(0, 0, 0);

    var x = min_x;
    while (x < max_x) : (x += 1) {
        var y = min_y;
        while (y < max_y) : (y += 1) {
            var z = min_z;
            while (z < max_z) : (z += 1) {
                if (world_map.getBlock(x, y, z).material() != .water) continue;
                if (@as(f64, @floatFromInt(max_y)) < fluidSurface(world_map, x, y, z)) continue;
                touching = true;
                flow = flow.add(world.fluid.flowVector(world_map, x, y, z));
            }
        }
    }

    if (!touching) return null;
    if (flow.length() <= 0.0) return math.Vec3.init(0, 0, 0);
    return flow.normalize().scale(flow_acceleration);
}

pub fn isBoxObstructed(world_map: *const world.World, box: math.AABB) bool {
    var box_buf: [max_colliding_boxes]math.AABB = undefined;
    const count = collidingBoxes(world_map, box, &box_buf);
    for (box_buf[0..count]) |candidate| {
        if (candidate.intersects(box)) return true;
    }
    return false;
}

pub fn isAnyLiquid(world_map: *const world.World, box: math.AABB) bool {
    var min_x = math.util.floorDouble(box.min_x);
    var min_y = math.util.floorDouble(box.min_y);
    var min_z = math.util.floorDouble(box.min_z);
    const max_x = math.util.floorDouble(box.max_x + 1.0);
    const max_y = math.util.floorDouble(box.max_y + 1.0);
    const max_z = math.util.floorDouble(box.max_z + 1.0);

    if (box.min_x < 0.0) min_x -= 1;
    if (box.min_y < 0.0) min_y -= 1;
    if (box.min_z < 0.0) min_z -= 1;

    var x = min_x;
    while (x < max_x) : (x += 1) {
        var y = min_y;
        while (y < max_y) : (y += 1) {
            var z = min_z;
            while (z < max_z) : (z += 1) {
                if (world_map.getBlock(x, y, z).isLiquid()) return true;
            }
        }
    }
    return false;
}

pub fn isInLava(world_map: *const world.World, box: math.AABB) bool {
    const query = box.expand(-0.1, -0.4, -0.1);
    const min_x = math.util.floorDouble(query.min_x);
    const min_y = math.util.floorDouble(query.min_y);
    const min_z = math.util.floorDouble(query.min_z);
    const max_x = math.util.floorDouble(query.max_x + 1.0);
    const max_y = math.util.floorDouble(query.max_y + 1.0);
    const max_z = math.util.floorDouble(query.max_z + 1.0);

    var x = min_x;
    while (x < max_x) : (x += 1) {
        var y = min_y;
        while (y < max_y) : (y += 1) {
            var z = min_z;
            while (z < max_z) : (z += 1) {
                if (world_map.getBlock(x, y, z).material() == .lava) return true;
            }
        }
    }
    return false;
}

pub fn isOffsetPositionInLiquid(world_map: *const world.World, box: math.AABB, dx: f64, dy: f64, dz: f64) bool {
    var box_buf: [max_colliding_boxes]math.AABB = undefined;
    const offset = box.offset(dx, dy, dz);
    const count = collidingBoxes(world_map, offset, &box_buf);
    for (box_buf[0..count]) |candidate| {
        if (candidate.intersects(offset)) return false;
    }
    return !isAnyLiquid(world_map, offset);
}

pub fn isInsideWater(world_map: *const world.World, eye_x: f64, eye_y: f64, eye_z: f64) bool {
    const x = math.util.floorDouble(eye_x);
    const y = math.util.floorDouble(eye_y);
    const z = math.util.floorDouble(eye_z);
    if (world_map.getBlock(x, y, z).material() != .water) return false;

    const air = world.fluid.percentAir(world_map.getBlockMetadata(x, y, z)) - 1.0 / 9.0;
    const surface: f32 = @as(f32, @floatFromInt(y + 1)) - air;
    return eye_y < @as(f64, surface);
}

fn testWorldWithFloor(floor_top_y: u32) !world.World {
    var w = world.World.init(std.testing.allocator);
    const chunk = try w.createChunk(0, 0);
    for (0..world.constants.chunk_width) |x| {
        for (0..world.constants.chunk_width) |z| {
            var y: u32 = 0;
            while (y < floor_top_y) : (y += 1) {
                chunk.setBlock(@intCast(x), @intCast(y), @intCast(z), .stone);
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
    w.setBlock(2, 0, 0, .stone);
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

test "a single slab is half a block tall to walk onto, a double slab a whole one" {
    var w = try testWorldWithFloor(1);
    defer w.deinit();
    w.setBlock(2, 1, 0, .slab);

    const aabb = math.AABB.init(1.2, 1.5, -0.3, 1.8, 2.4, 0.3);
    const onto_slab = moveEntityStepping(&w, aabb, 0.4, -0.08, 0, 0.5, true, false, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), onto_slab.dx, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), onto_slab.aabb.min_y, 1.0e-9);

    w.setBlock(2, 1, 0, .slab_double);
    const onto_double = moveEntityStepping(&w, aabb, 0.4, -0.08, 0, 0.5, true, false, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), onto_double.dx, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), onto_double.aabb.min_y, 1.0e-9);
}

test "a stair's tread is walked onto while its tall half blocks the way" {
    var w = try testWorldWithFloor(1);
    defer w.deinit();
    w.setBlock(2, 1, 0, .stairs_cobblestone);
    w.setBlockMetadata(2, 1, 0, 0);

    const aabb = math.AABB.init(1.2, 1.5, -0.3, 1.8, 2.4, 0.3);
    const onto_tread = moveEntityStepping(&w, aabb, 0.4, -0.08, 0, 0.5, true, false, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), onto_tread.dx, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), onto_tread.aabb.min_y, 1.0e-9);

    const into_back = moveEntity(&w, onto_tread.aabb, 0.4, 0, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), into_back.dx, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), into_back.aabb.max_x, 1.0e-9);
}

test "a rise of half a block is stepped over when the entity has step height" {
    var w = try testWorldWithFloor(1);
    defer w.deinit();
    w.setBlock(2, 1, 0, .stone);

    const aabb = math.AABB.init(1.2, 1.5, -0.3, 1.8, 2.4, 0.3);
    const stepped = moveEntityStepping(&w, aabb, 0.4, -0.08, 0, 0.5, true, false, 0);

    try std.testing.expectApproxEqAbs(@as(f64, 0.4), stepped.dx, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), stepped.aabb.min_y, 1.0e-9);
}

test "the same rise stops an entity that cannot step" {
    var w = try testWorldWithFloor(1);
    defer w.deinit();
    w.setBlock(2, 1, 0, .stone);

    const aabb = math.AABB.init(1.2, 1.5, -0.3, 1.8, 2.4, 0.3);
    const blocked = moveEntityStepping(&w, aabb, 0.4, -0.08, 0, 0, true, false, 0);

    try std.testing.expectApproxEqAbs(@as(f64, 0.2), blocked.dx, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.42), blocked.aabb.min_y, 1.0e-9);
}

test "a step that lands mid-block locks out stepping until the offset decays" {
    var w = try testWorldWithFloor(1);
    defer w.deinit();
    w.setBlock(2, 1, 0, .stone);

    const aabb = math.AABB.init(1.2, 1.5, -0.3, 1.8, 2.4, 0.3);
    const stepped = moveEntityStepping(&w, aabb, 0.4, -0.08, 0, 0.5, true, false, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), stepped.y_size, 1.0e-9);

    const locked = moveEntityStepping(&w, aabb, 0.4, -0.08, 0, 0.5, true, false, 0.2);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), locked.dx, 1.0e-9);
}

fn waterWorld() !world.World {
    var w = try testWorldWithFloor(1);
    errdefer w.deinit();
    for (0..world.constants.chunk_width) |x| {
        for (0..world.constants.chunk_width) |z| {
            var y: u32 = 1;
            while (y < 5) : (y += 1) {
                w.getChunk(0, 0).?.setBlock(@intCast(x), y, @intCast(z), .stationary_water);
            }
        }
    }
    return w;
}

test "water has no collision box, so an entity sinks straight through it" {
    var w = try waterWorld();
    defer w.deinit();
    const aabb = math.AABB.init(7.7, 4.0, 7.7, 8.3, 5.8, 8.3);
    const result = moveEntity(&w, aabb, 0, -2.0, 0);
    try std.testing.expectApproxEqAbs(@as(f64, -2.0), result.dy, 1.0e-9);
}

test "a box inside still water reports contact but no push" {
    var w = try waterWorld();
    defer w.deinit();
    const push = handleWaterMovement(&w, math.AABB.init(7.7, 2.0, 7.7, 8.3, 3.8, 8.3)).?;
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), push.length(), 1.0e-9);
}

test "a box in open air is not in water at all" {
    var w = try waterWorld();
    defer w.deinit();
    try std.testing.expect(handleWaterMovement(&w, math.AABB.init(7.7, 20.0, 7.7, 8.3, 21.8, 8.3)) == null);
}

test "a source block counts as submerged right up to the top of its block" {
    var w = try waterWorld();
    defer w.deinit();
    try std.testing.expect(isInsideWater(&w, 8.5, 3.5, 8.5));
    try std.testing.expect(isInsideWater(&w, 8.5, 4.95, 8.5));
    try std.testing.expect(!isInsideWater(&w, 8.5, 5.01, 8.5));
}

test "a shallow flowing block leaves an air gap the camera can see out of" {
    var w = try waterWorld();
    defer w.deinit();
    w.setBlock(8, 4, 8, .flowing_water);
    w.setBlockMetadata(8, 4, 8, 4);
    try std.testing.expect(!isInsideWater(&w, 8.5, 4.9, 8.5));
    try std.testing.expect(isInsideWater(&w, 8.5, 4.4, 8.5));
}

test "stepping out of water needs a free, dry space to move into" {
    var w = try waterWorld();
    defer w.deinit();
    const box = math.AABB.init(7.7, 2.0, 7.7, 8.3, 3.8, 8.3);
    try std.testing.expect(!isOffsetPositionInLiquid(&w, box, 0, 0, 0));
    try std.testing.expect(isOffsetPositionInLiquid(&w, box, 0, 4.0, 0));
}

test "a closed door stops an entity walking into it" {
    var w = try testWorldWithFloor(1);
    defer w.deinit();
    try std.testing.expect(try world.block_update.placeDoor(&w, 8, 1, 8, .door_wood, 180));

    const closed = world.block.doorBounds(w.getBlockMetadata(8, 1, 8));
    const aabb = math.AABB.init(8.2, 1.0, 6.7, 8.8, 2.8, 7.3);
    const blocked = moveEntity(&w, aabb, 0, 0, 2.0);
    try std.testing.expectApproxEqAbs(@as(f64, 8.0) + @as(f64, closed.min[2]), blocked.aabb.max_z, 1.0e-9);
}

test "an open door leaves the doorway clear" {
    var w = try testWorldWithFloor(1);
    defer w.deinit();
    try std.testing.expect(try world.block_update.placeDoor(&w, 8, 1, 8, .door_wood, 180));
    try world.block_update.toggleDoor(&w, 8, 1, 8);

    const aabb = math.AABB.init(8.2, 1.0, 6.7, 8.8, 2.8, 7.3);
    const through = moveEntity(&w, aabb, 0, 0, 2.0);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), through.dz, 1.0e-9);
}

fn trapdoorWorld(metadata: u4) !world.World {
    var w = try testWorldWithFloor(1);
    errdefer w.deinit();
    w.setBlock(8, 1, 9, .stone);
    try w.setBlockAndMetadataWithNotify(8, 1, 8, .trapdoor, metadata);
    return w;
}

test "a shut trapdoor is a floor an entity lands on" {
    var w = try trapdoorWorld(0);
    defer w.deinit();

    const aabb = math.AABB.init(8.2, 2.0, 7.9, 8.8, 3.8, 8.5);
    const landed = moveEntity(&w, aabb, 0, -1.0, 0);
    try std.testing.expectApproxEqAbs(1.0 + @as(f64, world.block.trapdoor_thickness), landed.aabb.min_y, 1.0e-9);
}

test "an open trapdoor drops an entity through and bars the way instead" {
    var w = try trapdoorWorld(world.block.trapdoor_open_bit);
    defer w.deinit();

    const above = math.AABB.init(8.2, 2.0, 7.9, 8.8, 3.8, 8.5);
    const fell = moveEntity(&w, above, 0, -1.0, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), fell.aabb.min_y, 1.0e-9);

    const beside = math.AABB.init(8.2, 1.0, 6.7, 8.8, 2.8, 7.3);
    const blocked = moveEntity(&w, beside, 0, 0, 2.0);
    const bounds = world.block.trapdoorBounds(world.block.trapdoor_open_bit);
    try std.testing.expectApproxEqAbs(8.0 + @as(f64, bounds.min[2]), blocked.aabb.max_z, 1.0e-9);
}
