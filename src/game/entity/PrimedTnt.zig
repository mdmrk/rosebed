const std = @import("std");

const math = @import("math");
const world = @import("world");
const BlockPos = world.BlockPos;

const Entity = @import("../Entity.zig");

const PrimedTnt = @This();

base: Entity,
fuse: i32 = world.tnt.fuse_ticks,

pub const size: f64 = 0.98;
pub const explosion_size: f32 = 4.0;
pub const explosion_is_flaming: bool = false;
pub const flash_period: i32 = 5;
pub const smoke_lift: f64 = 0.5;
pub const swell_ticks: f32 = 10.0;
pub const swell_scale: f32 = 0.3;
pub const flash_fade_ticks: f32 = 100.0;
pub const flash_alpha: f32 = 0.8;

const gravity: f64 = 0.04;
const drag: f64 = 0.98;
const ground_friction: f64 = 0.7;
const ground_bounce: f64 = -0.5;
const spawn_lift: f64 = 0.2;
const spawn_drift: f64 = 0.02;

pub const Outcome = enum { burning, exploded };

pub fn spawnInBlock(pos: BlockPos, fuse: i32, rand: *world.JavaRandom) PrimedTnt {
    return spawn(math.Vec3.init(
        @as(f64, @floatFromInt(pos.x)) + 0.5,
        @as(f64, @floatFromInt(pos.y)) + 0.5 - size / 2.0,
        @as(f64, @floatFromInt(pos.z)) + 0.5,
    ), fuse, rand);
}

pub fn spawn(position: math.Vec3, fuse: i32, rand: *world.JavaRandom) PrimedTnt {
    var base = Entity.init(position, size, size);
    base.triggers_walking = false;
    const angle = @as(f64, rand.nextFloat()) * std.math.pi * 2.0;
    base.motion = .{
        .x = -@sin(angle * std.math.pi / 180.0) * spawn_drift,
        .y = spawn_lift,
        .z = -@cos(angle * std.math.pi / 180.0) * spawn_drift,
    };
    return .{ .base = base, .fuse = fuse };
}

pub fn tick(self: *PrimedTnt, world_map: *const world.World) Outcome {
    self.base.beginTick();
    self.base.motion.y -= gravity;
    _ = self.base.move(world_map);
    self.base.motion.x *= drag;
    self.base.motion.y *= drag;
    self.base.motion.z *= drag;

    if (self.base.on_ground) {
        self.base.motion.x *= ground_friction;
        self.base.motion.z *= ground_friction;
        self.base.motion.y *= ground_bounce;
    }

    const spent = self.fuse <= 0;
    self.fuse -= 1;
    return if (spent) .exploded else .burning;
}

pub fn center(self: PrimedTnt, partial_ticks: f32) math.Vec3 {
    const pos = self.base.renderPosition(partial_ticks);
    return math.Vec3.init(pos.x, pos.y + size / 2.0, pos.z);
}

pub fn blastPosition(self: PrimedTnt) math.Vec3 {
    return math.Vec3.init(
        self.base.position.x,
        self.base.position.y + size / 2.0,
        self.base.position.z,
    );
}

pub fn smokePosition(self: PrimedTnt) math.Vec3 {
    return math.Vec3.init(
        self.base.position.x,
        self.base.position.y + size / 2.0 + smoke_lift,
        self.base.position.z,
    );
}

pub fn flashing(self: PrimedTnt) bool {
    return @divTrunc(self.fuse, flash_period) & 1 == 0;
}

fn fuseLeft(self: PrimedTnt, partial_ticks: f32) f32 {
    return @as(f32, @floatFromInt(self.fuse)) - partial_ticks + 1.0;
}

pub fn swellScale(self: PrimedTnt, partial_ticks: f32) f32 {
    const remaining = self.fuseLeft(partial_ticks);
    if (remaining >= swell_ticks) return 1.0;

    var swell = std.math.clamp(1.0 - remaining / swell_ticks, 0.0, 1.0);
    swell *= swell;
    swell *= swell;
    return 1.0 + swell * swell_scale;
}

pub fn flashWhitening(self: PrimedTnt, partial_ticks: f32) f32 {
    if (!self.flashing()) return 0.0;
    return std.math.clamp((1.0 - self.fuseLeft(partial_ticks) / flash_fade_ticks) * flash_alpha, 0.0, 1.0);
}

test "a primed stick of tnt hops upward off the block it was lit in" {
    var w = try world.testing.flatWorld(std.testing.allocator, 0);
    defer w.deinit();
    var rand = world.JavaRandom.init(0);

    const lit = PrimedTnt.spawnInBlock(.init(8, 5, 8), world.tnt.fuse_ticks, &rand);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), lit.base.motion.y, 1.0e-9);
    try std.testing.expect(@abs(lit.base.motion.x) <= 0.02);
    try std.testing.expect(@abs(lit.base.motion.z) <= 0.02);
    try std.testing.expectApproxEqAbs(@as(f64, 8.5), lit.base.position.x, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 5.01), lit.base.position.y, 1.0e-9);
}

test "the fuse burns for eighty ticks before the blast" {
    var w = try world.testing.flatWorld(std.testing.allocator, 0);
    defer w.deinit();
    var rand = world.JavaRandom.init(0);

    var lit = PrimedTnt.spawnInBlock(.init(8, 50, 8), world.tnt.fuse_ticks, &rand);
    for (0..world.tnt.fuse_ticks) |_| {
        try std.testing.expectEqual(Outcome.burning, lit.tick(&w));
    }
    try std.testing.expectEqual(Outcome.exploded, lit.tick(&w));
}

test "the flash alternates every five ticks of fuse" {
    var rand = world.JavaRandom.init(0);
    var lit = PrimedTnt.spawnInBlock(.init(0, 0, 0), 10, &rand);
    try std.testing.expect(lit.flashing());
    lit.fuse = 5;
    try std.testing.expect(!lit.flashing());
    lit.fuse = 4;
    try std.testing.expect(lit.flashing());
}
