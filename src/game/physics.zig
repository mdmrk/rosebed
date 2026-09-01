const std = @import("std");

const math = @import("math");
const world = @import("world");

const max_colliding_boxes = 64;

fn offsetBox(bounds: world.block.Bounds, x: i32, y: i32, z: i32) math.Aabb {
    const fx: f64 = @floatFromInt(x);
    const fy: f64 = @floatFromInt(y);
    const fz: f64 = @floatFromInt(z);
    return math.Aabb.init(
        fx + bounds.min[0],
        fy + bounds.min[1],
        fz + bounds.min[2],
        fx + bounds.max[0],
        fy + bounds.max[1],
        fz + bounds.max[2],
    );
}

fn blockBoxes(world_map: *const world.World, id: world.Block, x: i32, y: i32, z: i32, out: *[2]math.Aabb) usize {
    if (id == .cactus) {
        out[0] = offsetBox(world.block.cactus_collision_bounds, x, y, z);
        return 1;
    }

    if (id == .soul_sand) {
        out[0] = offsetBox(world.block.soul_sand_collision_bounds, x, y, z);
        return 1;
    }

    if (id == .fence) {
        out[0] = offsetBox(world.block.fence_collision_bounds, x, y, z);
        return 1;
    }

    if (id == .farmland) {
        out[0] = offsetBox(.{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 1 } }, x, y, z);
        return 1;
    }

    const bounds = switch (id.shape()) {
        .door => world.block.doorBounds(world_map.getBlockMetadata(x, y, z)),
        .trapdoor => world.block.trapdoorBounds(world_map.getBlockMetadata(x, y, z)),
        .cake => world.block.cakeCollisionBounds(world_map.getBlockMetadata(x, y, z)),
        .ladder => world.block.ladderBounds(world_map.getBlockMetadata(x, y, z)),
        .bed => world.block.Bounds{ .min = .{ 0, 0, 0 }, .max = .{ 1, world.block.bed_height, 1 } },
        .stairs => {
            for (world.block.stairsBoxes(world_map.getBlockMetadata(x, y, z)), out) |bounds, *box| {
                box.* = offsetBox(bounds, x, y, z);
            }
            return 2;
        },
        .piston => world.block.pistonBaseBounds(world_map.getBlockMetadata(x, y, z)),
        .piston_moving => {
            const state = world_map.pistons.get(.{ .x = x, .y = y, .z = z }) orelse return 0;
            if (state.stored == .air or state.stored == .piston_moving) return 0;
            if (!state.stored.hasCollision()) return 0;

            const shift = state.displacement(0);
            const bounds = state.stored.selectionBounds(state.stored_metadata);
            out[0] = offsetBox(.{
                .min = .{ bounds.min[0] + shift[0], bounds.min[1] + shift[1], bounds.min[2] + shift[2] },
                .max = .{ bounds.max[0] + shift[0], bounds.max[1] + shift[1], bounds.max[2] + shift[2] },
            }, x, y, z);
            return 1;
        },
        .piston_head => {
            const metadata = world_map.getBlockMetadata(x, y, z);
            out[0] = offsetBox(world.block.pistonHeadPlateBounds(metadata), x, y, z);
            out[1] = offsetBox(world.block.pistonHeadShaftBounds(metadata), x, y, z);
            return 2;
        },
        .partial => |height| world.block.Bounds{ .min = .{ 0, 0, 0 }, .max = .{ 1, height, 1 } },
        else => world.block.Bounds{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 1 } },
    };
    out[0] = offsetBox(bounds, x, y, z);
    return 1;
}

fn collidingBoxes(world_map: *const world.World, query: math.Aabb, out: *[max_colliding_boxes]math.Aabb) usize {
    const min_x = math.util.floorDouble(query.min_x);
    const max_x = math.util.floorDouble(query.max_x);
    const min_y = std.math.clamp(math.util.floorDouble(query.min_y) - 1, 0, world.Chunk.height - 1);
    const max_y = std.math.clamp(math.util.floorDouble(query.max_y), 0, world.Chunk.height - 1);
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
                if (!id.hasCollision()) continue;
                var boxes: [2]math.Aabb = undefined;
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

fn shaveTowardLedge(world_map: *const world.World, aabb: math.Aabb, axis_dx: f64, axis_dz: f64, amount_in: f64) f64 {
    var box_buf: [max_colliding_boxes]math.Aabb = undefined;
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

pub fn clampToLedge(world_map: *const world.World, aabb: math.Aabb, dx: f64, dz: f64) [2]f64 {
    return .{
        shaveTowardLedge(world_map, aabb, 1.0, 0.0, dx),
        shaveTowardLedge(world_map, aabb, 0.0, 1.0, dz),
    };
}

pub const MoveResult = struct {
    aabb: math.Aabb,
    dx: f64,
    dy: f64,
    dz: f64,
};

pub fn moveEntity(world_map: *const world.World, aabb: math.Aabb, dx: f64, dy: f64, dz: f64) MoveResult {
    return moveEntityAmong(world_map, aabb, dx, dy, dz, &.{});
}

pub fn moveEntityAmong(
    world_map: *const world.World,
    aabb: math.Aabb,
    dx: f64,
    dy: f64,
    dz: f64,
    obstacles: []const math.Aabb,
) MoveResult {
    var box_buf: [max_colliding_boxes]math.Aabb = undefined;
    const broad = aabb.addCoord(dx, dy, dz);
    const count = collidingBoxes(world_map, broad, &box_buf);
    const boxes = box_buf[0..count];

    var result = aabb;

    var moved_y = dy;
    for (boxes) |box| moved_y = box.calculateYOffset(result, moved_y);
    for (obstacles) |box| {
        if (box.intersects(broad)) moved_y = box.calculateYOffset(result, moved_y);
    }
    result = result.offset(0, moved_y, 0);

    var moved_x = dx;
    for (boxes) |box| moved_x = box.calculateXOffset(result, moved_x);
    for (obstacles) |box| {
        if (box.intersects(broad)) moved_x = box.calculateXOffset(result, moved_x);
    }
    result = result.offset(moved_x, 0, 0);

    var moved_z = dz;
    for (boxes) |box| moved_z = box.calculateZOffset(result, moved_z);
    for (obstacles) |box| {
        if (box.intersects(broad)) moved_z = box.calculateZOffset(result, moved_z);
    }
    result = result.offset(0, 0, moved_z);

    return .{ .aabb = result, .dx = moved_x, .dy = moved_y, .dz = moved_z };
}

pub const StepResult = struct {
    aabb: math.Aabb,
    dx: f64,
    dy: f64,
    dz: f64,
    y_size: f64,
};

const step_lock: f64 = 0.05;

pub fn moveEntityStepping(
    world_map: *const world.World,
    aabb: math.Aabb,
    dx: f64,
    dy: f64,
    dz: f64,
    step_height: f64,
    on_ground: bool,
    sneaking: bool,
    y_size: f64,
    obstacles: []const math.Aabb,
) StepResult {
    const plain = moveEntityAmong(world_map, aabb, dx, dy, dz, obstacles);
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

    const raised = moveEntityAmong(world_map, aabb, dx, step_height, dz, obstacles);
    const settled = moveEntityAmong(world_map, raised.aabb, 0, -step_height, 0, obstacles);

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

pub fn groundFriction(world_map: *const world.World, box: math.Aabb, x: f64, z: f64, air_friction: f32) f32 {
    const below = world_map.getBlock(
        math.util.floorDouble(x),
        math.util.floorDouble(box.min_y) - 1,
        math.util.floorDouble(z),
    );
    const slipperiness = if (below == .air) world.block.default_slipperiness else below.slipperiness();
    return slipperiness * air_friction;
}

pub fn walkAcceleration(friction: f32) f32 {
    return 0.1 * (0.16277136 / (friction * friction * friction));
}

pub fn fluidSurface(world_map: *const world.World, x: i32, y: i32, z: i32) f64 {
    const air = world.fluid.percentAir(world_map.getBlockMetadata(x, y, z));
    return @as(f64, @floatFromInt(y + 1)) - @as(f64, air);
}

pub fn handleWaterMovement(world_map: *const world.World, box: math.Aabb) ?math.Vec3 {
    const query = box.contract(0.001, 0.001, 0.001);
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

pub const collided_inset: f64 = 0.001;

pub const TouchedCells = struct {
    min: [3]i32,
    max: [3]i32,
    cursor: [3]i32,
    exhausted: bool,

    pub fn next(self: *TouchedCells) ?[3]i32 {
        if (self.exhausted) return null;
        const cell = self.cursor;
        self.cursor[2] += 1;
        if (self.cursor[2] > self.max[2]) {
            self.cursor[2] = self.min[2];
            self.cursor[1] += 1;
            if (self.cursor[1] > self.max[1]) {
                self.cursor[1] = self.min[1];
                self.cursor[0] += 1;
                if (self.cursor[0] > self.max[0]) self.exhausted = true;
            }
        }
        return cell;
    }
};

pub fn touchedCells(box: math.Aabb) TouchedCells {
    const min: [3]i32 = .{
        math.util.floorDouble(box.min_x + collided_inset),
        math.util.floorDouble(box.min_y + collided_inset),
        math.util.floorDouble(box.min_z + collided_inset),
    };
    const max: [3]i32 = .{
        math.util.floorDouble(box.max_x - collided_inset),
        math.util.floorDouble(box.max_y - collided_inset),
        math.util.floorDouble(box.max_z - collided_inset),
    };
    return .{
        .min = min,
        .max = max,
        .cursor = min,
        .exhausted = min[0] > max[0] or min[1] > max[1] or min[2] > max[2],
    };
}

pub fn countTouchedBlocks(world_map: *const world.World, box: math.Aabb, id: world.Block) u32 {
    var cells = touchedCells(box);
    if (!world_map.chunksExist(cells.min[0], cells.min[1], cells.min[2], cells.max[0], cells.max[1], cells.max[2])) return 0;

    var count: u32 = 0;
    while (cells.next()) |cell| {
        if (world_map.getBlock(cell[0], cell[1], cell[2]) == id) count += 1;
    }
    return count;
}

pub fn touchesBlock(world_map: *const world.World, box: math.Aabb, id: world.Block) bool {
    return countTouchedBlocks(world_map, box, id) > 0;
}

pub fn isBoxInMaterial(world_map: *const world.World, box: math.Aabb, material: world.Material) bool {
    const min_x = math.util.floorDouble(box.min_x);
    const max_x = math.util.floorDouble(box.max_x + 1.0);
    const min_y = math.util.floorDouble(box.min_y);
    const max_y = math.util.floorDouble(box.max_y + 1.0);
    const min_z = math.util.floorDouble(box.min_z);
    const max_z = math.util.floorDouble(box.max_z + 1.0);

    var x = min_x;
    while (x < max_x) : (x += 1) {
        var y = min_y;
        while (y < max_y) : (y += 1) {
            var z = min_z;
            while (z < max_z) : (z += 1) {
                if (world_map.getBlock(x, y, z).material() != material) continue;
                const meta = world_map.getBlockMetadata(x, y, z);
                const top: f64 = @floatFromInt(y + 1);
                const surface = if (meta < 8) top - @as(f64, @floatFromInt(meta)) / 8.0 else top;
                if (surface >= box.min_y) return true;
            }
        }
    }
    return false;
}

pub const auto_jump_reach = 0.35;

pub fn stepIsJumpable(world_map: *const world.World, box: math.Aabb, direction: [3]f32) bool {
    const ahead = box.offset(
        @as(f64, direction[0]) * auto_jump_reach,
        0,
        @as(f64, direction[2]) * auto_jump_reach,
    );
    if (!isBoxObstructed(world_map, ahead)) return false;
    return !isBoxObstructed(world_map, ahead.offset(0, 1.0, 0));
}

pub fn isBoxObstructed(world_map: *const world.World, box: math.Aabb) bool {
    var box_buf: [max_colliding_boxes]math.Aabb = undefined;
    const count = collidingBoxes(world_map, box, &box_buf);
    for (box_buf[0..count]) |candidate| {
        if (candidate.intersects(box)) return true;
    }
    return false;
}

pub fn isAnyLiquid(world_map: *const world.World, box: math.Aabb) bool {
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

pub fn isInLava(world_map: *const world.World, box: math.Aabb) bool {
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

pub fn isOffsetPositionInLiquid(world_map: *const world.World, box: math.Aabb, dx: f64, dy: f64, dz: f64) bool {
    var box_buf: [max_colliding_boxes]math.Aabb = undefined;
    const offset = box.offset(dx, dy, dz);
    const count = collidingBoxes(world_map, offset, &box_buf);
    for (box_buf[0..count]) |candidate| {
        if (candidate.intersects(offset)) return false;
    }
    return !isAnyLiquid(world_map, offset);
}

pub fn isInsideWater(world_map: *const world.World, eye_x: f64, eye_y: f64, eye_z: f64) bool {
    return isInsideMaterial(world_map, .water, eye_x, eye_y, eye_z);
}

pub fn isInsideMaterial(world_map: *const world.World, material: world.Material, eye_x: f64, eye_y: f64, eye_z: f64) bool {
    const x = math.util.floorDouble(eye_x);
    const y = math.util.floorDouble(eye_y);
    const z = math.util.floorDouble(eye_z);
    if (world_map.getBlock(x, y, z).material() != material) return false;

    const air = world.fluid.percentAir(world_map.getBlockMetadata(x, y, z)) - 1.0 / 9.0;
    const surface: f32 = @as(f32, @floatFromInt(y + 1)) - air;
    return eye_y < @as(f64, surface);
}

fn testWorldWithFloor(floor_top_y: u32) !world.World {
    var w = world.World.init(std.testing.allocator);
    const chunk = try w.createChunk(0, 0);
    for (0..world.Chunk.width) |x| {
        for (0..world.Chunk.width) |z| {
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
    const aabb = math.Aabb.init(0, 1.1, 0, 0.6, 2.9, 0.6);
    const result = moveEntity(&w, aabb, 0, -0.5, 0);
    try std.testing.expectApproxEqAbs(@as(f64, -0.1), result.dy, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.aabb.min_y, 1.0e-9);
}

test "walking into a wall clamps the horizontal offset at the surface" {
    var w = try testWorldWithFloor(0);
    defer w.deinit();
    w.setBlock(2, 0, 0, .stone);
    const aabb = math.Aabb.init(1.2, 0, -0.3, 1.8, 1.8, 0.3);
    const result = moveEntity(&w, aabb, 0.5, 0, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), result.dx, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), result.aabb.max_x, 1.0e-9);
}

test "open air applies the full requested movement" {
    var w = try testWorldWithFloor(0);
    defer w.deinit();
    const aabb = math.Aabb.init(0, 50, 0, 0.6, 51.8, 0.6);
    const result = moveEntity(&w, aabb, 1.0, -1.0, 1.0);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.dx, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -1.0), result.dy, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.dz, 1.0e-9);
}

test "a single slab is half a block tall to walk onto, a double slab a whole one" {
    var w = try testWorldWithFloor(1);
    defer w.deinit();
    w.setBlock(2, 1, 0, .slab);

    const aabb = math.Aabb.init(1.2, 1.5, -0.3, 1.8, 2.4, 0.3);
    const onto_slab = moveEntityStepping(&w, aabb, 0.4, -0.08, 0, 0.5, true, false, 0, &.{});
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), onto_slab.dx, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), onto_slab.aabb.min_y, 1.0e-9);

    w.setBlock(2, 1, 0, .slab_double);
    const onto_double = moveEntityStepping(&w, aabb, 0.4, -0.08, 0, 0.5, true, false, 0, &.{});
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), onto_double.dx, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), onto_double.aabb.min_y, 1.0e-9);
}

test "a stair's tread is walked onto while its tall half blocks the way" {
    var w = try testWorldWithFloor(1);
    defer w.deinit();
    w.setBlock(2, 1, 0, .stairs_cobblestone);
    w.setBlockMetadata(2, 1, 0, 0);

    const aabb = math.Aabb.init(1.2, 1.5, -0.3, 1.8, 2.4, 0.3);
    const onto_tread = moveEntityStepping(&w, aabb, 0.4, -0.08, 0, 0.5, true, false, 0, &.{});
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

    const aabb = math.Aabb.init(1.2, 1.5, -0.3, 1.8, 2.4, 0.3);
    const stepped = moveEntityStepping(&w, aabb, 0.4, -0.08, 0, 0.5, true, false, 0, &.{});

    try std.testing.expectApproxEqAbs(@as(f64, 0.4), stepped.dx, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), stepped.aabb.min_y, 1.0e-9);
}

test "the same rise stops an entity that cannot step" {
    var w = try testWorldWithFloor(1);
    defer w.deinit();
    w.setBlock(2, 1, 0, .stone);

    const aabb = math.Aabb.init(1.2, 1.5, -0.3, 1.8, 2.4, 0.3);
    const blocked = moveEntityStepping(&w, aabb, 0.4, -0.08, 0, 0, true, false, 0, &.{});

    try std.testing.expectApproxEqAbs(@as(f64, 0.2), blocked.dx, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.42), blocked.aabb.min_y, 1.0e-9);
}

test "a step that lands mid-block locks out stepping until the offset decays" {
    var w = try testWorldWithFloor(1);
    defer w.deinit();
    w.setBlock(2, 1, 0, .stone);

    const aabb = math.Aabb.init(1.2, 1.5, -0.3, 1.8, 2.4, 0.3);
    const stepped = moveEntityStepping(&w, aabb, 0.4, -0.08, 0, 0.5, true, false, 0, &.{});
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), stepped.y_size, 1.0e-9);

    const locked = moveEntityStepping(&w, aabb, 0.4, -0.08, 0, 0.5, true, false, 0.2, &.{});
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), locked.dx, 1.0e-9);
}

fn waterWorld() !world.World {
    var w = try testWorldWithFloor(1);
    errdefer w.deinit();
    for (0..world.Chunk.width) |x| {
        for (0..world.Chunk.width) |z| {
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
    const aabb = math.Aabb.init(7.7, 4.0, 7.7, 8.3, 5.8, 8.3);
    const result = moveEntity(&w, aabb, 0, -2.0, 0);
    try std.testing.expectApproxEqAbs(@as(f64, -2.0), result.dy, 1.0e-9);
}

test "a box inside still water reports contact but no push" {
    var w = try waterWorld();
    defer w.deinit();
    const push = handleWaterMovement(&w, math.Aabb.init(7.7, 2.0, 7.7, 8.3, 3.8, 8.3).expand(0, -0.4, 0)).?;
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), push.length(), 1.0e-9);
}

test "a box in open air is not in water at all" {
    var w = try waterWorld();
    defer w.deinit();
    try std.testing.expect(handleWaterMovement(&w, math.Aabb.init(7.7, 20.0, 7.7, 8.3, 21.8, 8.3).expand(0, -0.4, 0)) == null);
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
    const box = math.Aabb.init(7.7, 2.0, 7.7, 8.3, 3.8, 8.3);
    try std.testing.expect(!isOffsetPositionInLiquid(&w, box, 0, 0, 0));
    try std.testing.expect(isOffsetPositionInLiquid(&w, box, 0, 4.0, 0));
}

test "a cactus is a sixteenth narrower and shorter than the cell it sits in" {
    var w = try testWorldWithFloor(1);
    defer w.deinit();
    w.setBlock(9, 1, 8, .cactus);

    const walking = math.Aabb.init(7.7, 1.0, 7.7, 8.3, 2.8, 8.3);
    const into = moveEntity(&w, walking, 1.0, 0, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 9.0 + 1.0 / 16.0), into.aabb.max_x, 1.0e-9);

    const falling = math.Aabb.init(8.7, 3.0, 7.7, 9.3, 4.8, 8.3);
    const landed = moveEntity(&w, falling, 0, -2.0, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0 - 1.0 / 16.0), landed.aabb.min_y, 1.0e-9);
}

test "soul sand is two sixteenths short, so an entity stands sunk into its cell" {
    var w = try testWorldWithFloor(1);
    defer w.deinit();
    w.setBlock(8, 1, 8, .soul_sand);

    const falling = math.Aabb.init(7.7, 4.0, 7.7, 8.3, 5.8, 8.3);
    const landed = moveEntity(&w, falling, 0, -3.0, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0 - 2.0 / 16.0), landed.aabb.min_y, 1.0e-9);
}

test "farmland is walked on as a whole cube even though it renders shaved" {
    var w = try testWorldWithFloor(1);
    defer w.deinit();
    w.setBlock(8, 1, 8, .farmland);

    const falling = math.Aabb.init(7.7, 5.0, 7.7, 8.3, 6.8, 8.3);
    const landed = moveEntity(&w, falling, 0, -4.0, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), landed.aabb.min_y, 1.0e-9);
}

test "a crop is walked straight through" {
    var w = try testWorldWithFloor(1);
    defer w.deinit();
    w.setBlock(8, 1, 8, .farmland);
    w.setBlock(8, 2, 8, .crops);

    const walking = math.Aabb.init(6.7, 2.0, 7.7, 7.3, 3.8, 8.3);
    const into = moveEntity(&w, walking, 2.0, 0, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 9.3), into.aabb.max_x, 1.0e-9);
}

test "a fence stands half a block taller than its own cell" {
    var w = try testWorldWithFloor(1);
    defer w.deinit();
    w.setBlock(8, 1, 8, .fence);

    const falling = math.Aabb.init(7.7, 5.0, 7.7, 8.3, 6.8, 8.3);
    const landed = moveEntity(&w, falling, 0, -4.0, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), landed.aabb.min_y, 1.0e-9);
}

test "a fence blocks a walker whose feet are already above the fence's cell" {
    var w = try testWorldWithFloor(1);
    defer w.deinit();
    w.setBlock(7, 1, 8, .stone);
    w.setBlock(8, 1, 8, .fence);

    const walking = math.Aabb.init(6.7, 2.0, 7.7, 7.3, 3.8, 8.3);
    const into = moveEntity(&w, walking, 1.0, 0, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), into.aabb.max_x, 1.0e-9);
}

test "a ladder is a two-sixteenth panel that only blocks the wall it hangs on" {
    var w = try testWorldWithFloor(1);
    defer w.deinit();
    w.setBlock(9, 1, 8, .stone);
    w.setBlock(8, 1, 8, .ladder);
    w.setBlockMetadata(8, 1, 8, 4);

    const walking = math.Aabb.init(7.2, 1.0, 7.7, 7.8, 2.8, 8.3);
    const into = moveEntity(&w, walking, 1.5, 0, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 9.0 - 2.0 / 16.0), into.aabb.max_x, 1.0e-9);
}

test "a box counts as touching the cell it barely overlaps, but not the one it only abuts" {
    var w = try testWorldWithFloor(1);
    defer w.deinit();
    w.setBlock(9, 1, 8, .cactus);

    const brushing = math.Aabb.init(8.2, 1.0, 7.7, 9.05, 2.8, 8.3);
    try std.testing.expect(touchesBlock(&w, brushing, .cactus));

    const flush = math.Aabb.init(8.2, 1.0, 7.7, 9.0, 2.8, 8.3);
    try std.testing.expect(!touchesBlock(&w, flush, .cactus));

    const standing_on_top = math.Aabb.init(8.7, 1.9375, 7.7, 9.3, 3.7375, 8.3);
    try std.testing.expect(touchesBlock(&w, standing_on_top, .cactus));

    try std.testing.expect(!touchesBlock(&w, brushing, .sand));
}

test "a closed door stops an entity walking into it" {
    var w = try testWorldWithFloor(1);
    defer w.deinit();
    try std.testing.expect(try world.block_update.placeDoor(&w, 8, 1, 8, .door_wood, 180));

    const closed = world.block.doorBounds(w.getBlockMetadata(8, 1, 8));
    const aabb = math.Aabb.init(8.2, 1.0, 6.7, 8.8, 2.8, 7.3);
    const blocked = moveEntity(&w, aabb, 0, 0, 2.0);
    try std.testing.expectApproxEqAbs(@as(f64, 8.0) + @as(f64, closed.min[2]), blocked.aabb.max_z, 1.0e-9);
}

test "an open door leaves the doorway clear" {
    var w = try testWorldWithFloor(1);
    defer w.deinit();
    try std.testing.expect(try world.block_update.placeDoor(&w, 8, 1, 8, .door_wood, 180));
    try world.block_update.toggleDoor(&w, 8, 1, 8);

    const aabb = math.Aabb.init(8.2, 1.0, 6.7, 8.8, 2.8, 7.3);
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

    const aabb = math.Aabb.init(8.2, 2.0, 7.9, 8.8, 3.8, 8.5);
    const landed = moveEntity(&w, aabb, 0, -1.0, 0);
    try std.testing.expectApproxEqAbs(1.0 + @as(f64, world.block.trapdoor_thickness), landed.aabb.min_y, 1.0e-9);
}

test "an open trapdoor drops an entity through and bars the way instead" {
    var w = try trapdoorWorld(world.block.trapdoor_open_bit);
    defer w.deinit();

    const above = math.Aabb.init(8.2, 2.0, 7.9, 8.8, 3.8, 8.5);
    const fell = moveEntity(&w, above, 0, -1.0, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), fell.aabb.min_y, 1.0e-9);

    const beside = math.Aabb.init(8.2, 1.0, 6.7, 8.8, 2.8, 7.3);
    const blocked = moveEntity(&w, beside, 0, 0, 2.0);
    const bounds = world.block.trapdoorBounds(world.block.trapdoor_open_bit);
    try std.testing.expectApproxEqAbs(8.0 + @as(f64, bounds.min[2]), blocked.aabb.max_z, 1.0e-9);
}

test "a one block rise is jumpable, open air and a taller wall are not" {
    var w = try testWorldWithFloor(0);
    defer w.deinit();
    const box = math.Aabb.init(1.2, 0, -0.3, 1.8, 1.8, 0.3);
    const east = [3]f32{ 1, 0, 0 };

    try std.testing.expect(!stepIsJumpable(&w, box, east));

    w.setBlock(2, 0, 0, .stone);
    try std.testing.expect(stepIsJumpable(&w, box, east));

    w.setBlock(2, 1, 0, .stone);
    try std.testing.expect(!stepIsJumpable(&w, box, east));
}

test "a rise behind the entity is not jumpable" {
    var w = try testWorldWithFloor(0);
    defer w.deinit();
    w.setBlock(2, 0, 0, .stone);
    const box = math.Aabb.init(1.2, 0, -0.3, 1.8, 1.8, 0.3);
    try std.testing.expect(!stepIsJumpable(&w, box, .{ -1, 0, 0 }));
}
