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
