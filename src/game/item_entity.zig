const std = @import("std");
const math = @import("math");
const world = @import("world");
const physics = @import("physics.zig");
const Inventory = @import("inventory.zig");

const ItemEntity = @This();

position: math.Vec3,
prev_position: math.Vec3,
motion: math.Vec3,
on_ground: bool = false,
stack: Inventory.ItemStack,
age: u32 = 0,
pickup_delay: u16 = 10,

pub const width: f64 = 0.25;
pub const height: f64 = 0.25;

const gravity: f64 = 0.04;
const vertical_drag: f64 = 0.98;
const ground_friction: f64 = 0.6 * 0.98;
const air_friction: f64 = 0.98;
const despawn_age: u32 = 6000;

pub fn spawn(position: math.Vec3, stack: Inventory.ItemStack, rand: *world.JavaRandom) ItemEntity {
    return .{
        .position = position,
        .prev_position = position,
        .motion = .{
            .x = @as(f64, rand.nextFloat()) * 0.2 - 0.1,
            .y = 0.2,
            .z = @as(f64, rand.nextFloat()) * 0.2 - 0.1,
        },
        .stack = stack,
    };
}

pub fn boundingBox(self: ItemEntity) math.AABB {
    const half = width / 2.0;
    return math.AABB.init(
        self.position.x - half,
        self.position.y,
        self.position.z - half,
        self.position.x + half,
        self.position.y + height,
        self.position.z + half,
    );
}

pub fn tick(self: *ItemEntity, world_map: *const world.World) void {
    self.prev_position = self.position;
    if (self.pickup_delay > 0) self.pickup_delay -= 1;

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

    const friction: f64 = if (self.on_ground) ground_friction else air_friction;
    self.motion.x *= friction;
    self.motion.z *= friction;
    self.motion.y *= vertical_drag;
    if (self.on_ground) self.motion.y *= -0.5;

    self.age += 1;
}

pub fn isExpired(self: ItemEntity) bool {
    return self.age >= despawn_age;
}

pub fn canPickUp(self: ItemEntity) bool {
    return self.pickup_delay == 0;
}

pub fn renderPosition(self: ItemEntity, partial_ticks: f32) math.Vec3 {
    const t: f64 = partial_ticks;
    return .{
        .x = self.prev_position.x + (self.position.x - self.prev_position.x) * t,
        .y = self.prev_position.y + (self.position.y - self.prev_position.y) * t,
        .z = self.prev_position.z + (self.position.z - self.prev_position.z) * t,
    };
}

fn testWorldWithFloor() !world.World {
    var w = world.World.init(std.testing.allocator);
    var chunk = world.Chunk.init(0, 0);
    for (0..world.constants.chunk_width) |x| {
        for (0..world.constants.chunk_width) |z| {
            chunk.setBlockId(@intCast(x), 0, @intCast(z), world.block.stone);
        }
    }
    try w.chunks.put(std.testing.allocator, .{ .x = 0, .z = 0 }, chunk);
    return w;
}

test "spawn seeds an upward hop and a small random horizontal drift" {
    var rand = world.JavaRandom.init(0);
    const item = ItemEntity.spawn(math.Vec3.init(8, 5, 8), .{ .id = 1, .count = 1 }, &rand);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), item.motion.y, 1.0e-9);
    try std.testing.expect(item.motion.x >= -0.1 and item.motion.x <= 0.1);
    try std.testing.expect(item.motion.z >= -0.1 and item.motion.z <= 0.1);
}

test "gravity accelerates a falling item" {
    var w = world.World.init(std.testing.allocator);
    defer w.deinit();
    try w.chunks.put(std.testing.allocator, .{ .x = 0, .z = 0 }, world.Chunk.init(0, 0));
    var rand = world.JavaRandom.init(0);
    var item = ItemEntity.spawn(math.Vec3.init(8, 50, 8), .{ .id = 1, .count = 1 }, &rand);
    item.motion = math.Vec3.init(0, 0, 0);
    item.tick(&w);
    try std.testing.expectApproxEqAbs(@as(f64, -0.04 * 0.98), item.motion.y, 1.0e-9);
}

test "landing zeroes motionY, so the -0.5 bounce factor has nothing to act on" {
    var w = try testWorldWithFloor();
    defer w.deinit();
    var rand = world.JavaRandom.init(0);
    var item = ItemEntity.spawn(math.Vec3.init(8, 1, 8), .{ .id = 1, .count = 1 }, &rand);
    item.motion = math.Vec3.init(0, -0.0784, 0);
    item.tick(&w);
    try std.testing.expect(item.on_ground);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), item.motion.y, 1.0e-9);
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
    var rand = world.JavaRandom.init(0);
    var w = world.World.init(std.testing.allocator);
    defer w.deinit();
    try w.chunks.put(std.testing.allocator, .{ .x = 0, .z = 0 }, world.Chunk.init(0, 0));
    var item = ItemEntity.spawn(math.Vec3.init(8, 50, 8), .{ .id = 1, .count = 1 }, &rand);
    try std.testing.expect(!item.canPickUp());
    for (0..10) |_| item.tick(&w);
    try std.testing.expect(item.canPickUp());
}
