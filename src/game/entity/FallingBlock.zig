const std = @import("std");

const math = @import("math");
const world = @import("world");

const Entity = @import("../Entity.zig");

const FallingBlock = @This();

base: Entity,
block_id: world.Block,
fall_time: u32 = 0,

pub const size: f64 = 0.98;

const gravity: f64 = 0.04;
const drag: f64 = 0.98;
const give_up_after_ticks: u32 = 100;

pub const Outcome = enum { falling, landed, gave_up };

pub fn spawn(position: math.Vec3, block_id: world.Block) FallingBlock {
    var base = Entity.init(position, size, size);
    base.triggers_walking = false;
    return .{ .base = base, .block_id = block_id };
}

pub fn tick(self: *FallingBlock, world_map: *const world.World) Outcome {
    self.base.beginTick();
    self.fall_time += 1;
    self.base.motion.y -= gravity;

    _ = self.base.move(world_map);

    self.base.motion.x *= drag;
    self.base.motion.y *= drag;
    self.base.motion.z *= drag;

    if (self.base.on_ground) {
        self.base.motion.x *= 0.7;
        self.base.motion.z *= 0.7;
        self.base.motion.y *= -0.5;
        return .landed;
    }
    if (self.fall_time > give_up_after_ticks) return .gave_up;
    return .falling;
}

test "gravity accelerates a falling block" {
    var w = try world.testing.flatWorld(std.testing.allocator, 0);
    defer w.deinit();
    var block = FallingBlock.spawn(math.Vec3.init(8, 50, 8), .sand);
    _ = block.tick(&w);
    try std.testing.expectApproxEqAbs(@as(f64, -0.04 * 0.98), block.base.motion.y, 1.0e-9);
}

test "landing on solid ground reports landed" {
    var w = try world.testing.flatWorld(std.testing.allocator, 1);
    defer w.deinit();
    var block = FallingBlock.spawn(math.Vec3.init(8, 1, 8), .sand);
    block.base.motion = math.Vec3.init(0, -0.0784, 0);
    try std.testing.expectEqual(Outcome.landed, block.tick(&w));
}

test "still falling after one tick in open air" {
    var w = try world.testing.flatWorld(std.testing.allocator, 0);
    defer w.deinit();
    var block = FallingBlock.spawn(math.Vec3.init(8, 50, 8), .sand);
    try std.testing.expectEqual(Outcome.falling, block.tick(&w));
}

test "gives up after falling for more than 100 ticks without landing" {
    var w = try world.testing.flatWorld(std.testing.allocator, 0);
    defer w.deinit();
    var block = FallingBlock.spawn(math.Vec3.init(8, 1000, 8), .sand);
    var outcome: Outcome = .falling;
    for (0..101) |_| outcome = block.tick(&w);
    try std.testing.expectEqual(Outcome.gave_up, outcome);
}
