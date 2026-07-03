const std = @import("std");
const math = @import("math");
const world = @import("world");
const physics = @import("physics.zig");

const FallingBlock = @This();

position: math.Vec3,
prev_position: math.Vec3,
motion: math.Vec3 = math.Vec3.init(0, 0, 0),
on_ground: bool = false,
block_id: u8,
fall_time: u32 = 0,

pub const size: f64 = 0.98;

const gravity: f64 = 0.04;
const drag: f64 = 0.98;
const give_up_after_ticks: u32 = 100;

pub const Outcome = enum { falling, landed, gave_up };

pub fn spawn(position: math.Vec3, block_id: u8) FallingBlock {
    return .{ .position = position, .prev_position = position, .block_id = block_id };
}

pub fn boundingBox(self: FallingBlock) math.AABB {
    const half = size / 2.0;
    return math.AABB.init(
        self.position.x - half,
        self.position.y,
        self.position.z - half,
        self.position.x + half,
        self.position.y + size,
        self.position.z + half,
    );
}

pub fn tick(self: *FallingBlock, world_map: *const world.World) Outcome {
    self.prev_position = self.position;
    self.fall_time += 1;
    self.motion.y -= gravity;

    const result = physics.moveEntity(world_map, self.boundingBox(), self.motion.x, self.motion.y, self.motion.z);
    self.position = .{
        .x = (result.aabb.min_x + result.aabb.max_x) / 2.0,
        .y = result.aabb.min_y,
        .z = (result.aabb.min_z + result.aabb.max_z) / 2.0,
    };

    self.on_ground = self.motion.y != result.dy and self.motion.y < 0.0;
    if (self.motion.x != result.dx) self.motion.x = 0;
    if (self.motion.y != result.dy) self.motion.y = 0;
    if (self.motion.z != result.dz) self.motion.z = 0;

    self.motion.x *= drag;
    self.motion.y *= drag;
    self.motion.z *= drag;

    if (self.on_ground) {
        self.motion.x *= 0.7;
        self.motion.z *= 0.7;
        self.motion.y *= -0.5;
        return .landed;
    }
    if (self.fall_time > give_up_after_ticks) return .gave_up;
    return .falling;
}

pub fn renderPosition(self: FallingBlock, partial_ticks: f32) math.Vec3 {
    const t: f64 = partial_ticks;
    return .{
        .x = self.prev_position.x + (self.position.x - self.prev_position.x) * t,
        .y = self.prev_position.y + (self.position.y - self.prev_position.y) * t,
        .z = self.prev_position.z + (self.position.z - self.prev_position.z) * t,
    };
}

fn testWorldWithFloor() !world.World {
    var w = world.World.init(std.testing.allocator);
    const chunk = try w.createChunk(0, 0);
    for (0..world.constants.chunk_width) |x| {
        for (0..world.constants.chunk_width) |z| {
            chunk.setBlockId(@intCast(x), 0, @intCast(z), world.block.stone);
        }
    }
    return w;
}

test "gravity accelerates a falling block" {
    var w = world.World.init(std.testing.allocator);
    defer w.deinit();
    _ = try w.createChunk(0, 0);
    var block = FallingBlock.spawn(math.Vec3.init(8, 50, 8), world.block.sand);
    _ = block.tick(&w);
    try std.testing.expectApproxEqAbs(@as(f64, -0.04 * 0.98), block.motion.y, 1.0e-9);
}

test "landing on solid ground reports landed" {
    var w = try testWorldWithFloor();
    defer w.deinit();
    var block = FallingBlock.spawn(math.Vec3.init(8, 1, 8), world.block.sand);
    block.motion = math.Vec3.init(0, -0.0784, 0);
    try std.testing.expectEqual(Outcome.landed, block.tick(&w));
}

test "still falling after one tick in open air" {
    var w = world.World.init(std.testing.allocator);
    defer w.deinit();
    _ = try w.createChunk(0, 0);
    var block = FallingBlock.spawn(math.Vec3.init(8, 50, 8), world.block.sand);
    try std.testing.expectEqual(Outcome.falling, block.tick(&w));
}

test "gives up after falling for more than 100 ticks without landing" {
    var w = world.World.init(std.testing.allocator);
    defer w.deinit();
    _ = try w.createChunk(0, 0);
    var block = FallingBlock.spawn(math.Vec3.init(8, 1000, 8), world.block.sand);
    var outcome: Outcome = .falling;
    for (0..101) |_| outcome = block.tick(&w);
    try std.testing.expectEqual(Outcome.gave_up, outcome);
}
