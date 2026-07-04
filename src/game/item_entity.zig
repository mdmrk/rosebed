const std = @import("std");
const math = @import("math");
const world = @import("world");
const Entity = @import("entity.zig");
const Inventory = @import("inventory.zig");

const ItemEntity = @This();

base: Entity,
stack: Inventory.ItemStack,
age: u32 = 0,
pickup_delay: u16 = 10,
hover: f32 = 0,

pub const width: f64 = 0.25;
pub const height: f64 = 0.25;

const gravity: f64 = 0.04;
const vertical_drag: f64 = 0.98;
const ground_friction: f64 = 0.6 * 0.98;
const air_friction: f64 = 0.98;
const despawn_age: u32 = 6000;

pub fn spawn(position: math.Vec3, stack: Inventory.ItemStack, rand: *world.JavaRandom) ItemEntity {
    var base = Entity.init(position, width, height);
    base.motion = .{
        .x = @as(f64, rand.nextFloat()) * 0.2 - 0.1,
        .y = 0.2,
        .z = @as(f64, rand.nextFloat()) * 0.2 - 0.1,
    };
    return .{
        .base = base,
        .stack = stack,
        .hover = @floatCast(rand.nextDouble() * std.math.pi * 2.0),
    };
}

pub fn tick(self: *ItemEntity, world_map: *const world.World) void {
    self.base.beginTick();
    if (self.pickup_delay > 0) self.pickup_delay -= 1;

    self.base.motion.y -= gravity;
    _ = self.base.move(world_map);

    const friction: f64 = if (self.base.on_ground) ground_friction else air_friction;
    self.base.motion.x *= friction;
    self.base.motion.z *= friction;
    self.base.motion.y *= vertical_drag;
    if (self.base.on_ground) self.base.motion.y *= -0.5;

    self.age += 1;
}

pub fn isExpired(self: ItemEntity) bool {
    return self.age >= despawn_age;
}

pub fn canPickUp(self: ItemEntity) bool {
    return self.pickup_delay == 0;
}

test "spawn seeds an upward hop and a small random horizontal drift" {
    var rand = world.JavaRandom.init(0);
    const item = ItemEntity.spawn(math.Vec3.init(8, 5, 8), .{ .id = 1, .count = 1 }, &rand);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), item.base.motion.y, 1.0e-9);
    try std.testing.expect(item.base.motion.x >= -0.1 and item.base.motion.x <= 0.1);
    try std.testing.expect(item.base.motion.z >= -0.1 and item.base.motion.z <= 0.1);
}

test "gravity accelerates a falling item" {
    var w = try world.testing.flatWorld(std.testing.allocator, 0);
    defer w.deinit();
    var rand = world.JavaRandom.init(0);
    var item = ItemEntity.spawn(math.Vec3.init(8, 50, 8), .{ .id = 1, .count = 1 }, &rand);
    item.base.motion = math.Vec3.init(0, 0, 0);
    item.tick(&w);
    try std.testing.expectApproxEqAbs(@as(f64, -0.04 * 0.98), item.base.motion.y, 1.0e-9);
}

test "landing zeroes motionY, so the -0.5 bounce factor has nothing to act on" {
    var w = try world.testing.flatWorld(std.testing.allocator, 1);
    defer w.deinit();
    var rand = world.JavaRandom.init(0);
    var item = ItemEntity.spawn(math.Vec3.init(8, 1, 8), .{ .id = 1, .count = 1 }, &rand);
    item.base.motion = math.Vec3.init(0, -0.0784, 0);
    item.tick(&w);
    try std.testing.expect(item.base.on_ground);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), item.base.motion.y, 1.0e-9);
}

test "isExpired only becomes true at 6000 ticks (5 minutes)" {
    var rand = world.JavaRandom.init(0);
    var item = ItemEntity.spawn(math.Vec3.init(0, 0, 0), .{ .id = 1, .count = 1 }, &rand);
    item.age = 5999;
    try std.testing.expect(!item.isExpired());
    item.age = 6000;
    try std.testing.expect(item.isExpired());
}

test "canPickUp is false until the pickup delay elapses" {
    var w = try world.testing.flatWorld(std.testing.allocator, 0);
    defer w.deinit();
    var rand = world.JavaRandom.init(0);
    var item = ItemEntity.spawn(math.Vec3.init(8, 50, 8), .{ .id = 1, .count = 1 }, &rand);
    try std.testing.expect(!item.canPickUp());
    for (0..10) |_| item.tick(&w);
    try std.testing.expect(item.canPickUp());
}
