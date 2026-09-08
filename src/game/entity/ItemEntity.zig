const std = @import("std");

const assets = @import("assets");
const math = @import("math");
const world = @import("world");

const Entity = @import("../Entity.zig");
const Inventory = @import("../Inventory.zig");
const physics = @import("../physics.zig");

const ItemEntity = @This();

base: Entity,
stack: Inventory.ItemStack,
age: u32 = 0,
health: i32 = max_health,
fire: i32 = 0,
pickup_delay: u16 = 10,
hover: f32 = 0,

pub const width: f64 = 0.25;
pub const height: f64 = 0.25;

const gravity: f64 = 0.04;
const vertical_drag: f64 = 0.98;
const air_friction: f32 = 0.98;
const despawn_age: u32 = 6000;
pub const max_health: i32 = 5;
const cactus_damage: i32 = 1;
const burn_damage: i32 = 1;
const lava_damage: i32 = 4;
const lava_fire_ticks: i32 = 600;
const fire_resistance: i32 = 1;
const extinguish_volume: f32 = 0.7;
const extinguish_pitch_base: f32 = 1.6;
const lava_lift: f64 = 0.2;
const lava_scatter: f64 = 0.2;
const lava_fizz_volume: f32 = 0.4;
const lava_fizz_pitch_base: f32 = 2.0;

pub fn spawn(position: math.Vec3, stack: Inventory.ItemStack, rand: *world.JavaRandom) ItemEntity {
    var base = Entity.init(position, width, height);
    base.triggers_walking = false;
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

pub fn tick(self: *ItemEntity, world_map: *const world.World, rand: *world.JavaRandom) void {
    self.base.beginTick();
    self.updateFire(world_map);
    if (self.pickup_delay > 0) self.pickup_delay -= 1;

    self.base.motion.y -= gravity;
    if (world_map.getBlock(.init(
        math.util.floorDouble(self.base.position.x),
        math.util.floorDouble(self.base.position.y + height / 2.0),
        math.util.floorDouble(self.base.position.z),
    )).material() == .lava) {
        self.base.motion.y = lava_lift;
        self.base.motion.x = (@as(f64, rand.nextFloat()) - @as(f64, rand.nextFloat())) * lava_scatter;
        self.base.motion.z = (@as(f64, rand.nextFloat()) - @as(f64, rand.nextFloat())) * lava_scatter;
        world_map.playSoundEffect(
            self.base.position,
            assets.sounds.random.fizz,
            lava_fizz_volume,
            lava_fizz_pitch_base + rand.nextFloat() * 0.4,
        );
    }
    _ = self.base.move(world_map);
    if (physics.touchesBlock(world_map, self.base.boundingBox(), .cactus)) self.health -= cactus_damage;
    self.hurtInFire(world_map, rand);

    const friction: f32 = if (self.base.on_ground)
        physics.groundFriction(world_map, self.base.boundingBox(), self.base.position.x, self.base.position.z, air_friction)
    else
        air_friction;
    self.base.motion.x *= @as(f64, friction);
    self.base.motion.z *= @as(f64, friction);
    self.base.motion.y *= vertical_drag;
    if (self.base.on_ground) self.base.motion.y *= -0.5;

    self.age += 1;
}

fn updateFire(self: *ItemEntity, world_map: *const world.World) void {
    if (self.fire > 0) {
        if (@rem(self.fire, 20) == 0) self.health -= burn_damage;
        self.fire -= 1;
    }

    if (physics.isInLava(world_map, self.base.boundingBox())) {
        self.health -= lava_damage;
        self.fire = lava_fire_ticks;
    }
}

fn isWet(self: *const ItemEntity, world_map: *const world.World) bool {
    if (self.base.in_water) return true;
    return world_map.canBlockBeRainedOn(.init(
        math.util.floorDouble(self.base.position.x),
        math.util.floorDouble(self.base.position.y),
        math.util.floorDouble(self.base.position.z),
    ));
}

fn hurtInFire(self: *ItemEntity, world_map: *const world.World, rand: *world.JavaRandom) void {
    const burning = physics.isBoundingBoxBurning(world_map, self.base.boundingBox());
    if (burning) self.health -= burn_damage;

    if (Entity.stepFireContact(&self.fire, fire_resistance, burning, self.isWet(world_map)) == .sizzled) {
        world_map.playSoundEffect(
            self.base.position,
            assets.sounds.random.fizz,
            extinguish_volume,
            extinguish_pitch_base + (rand.nextFloat() - rand.nextFloat()) * 0.4,
        );
    }
}

pub fn isExpired(self: ItemEntity) bool {
    return self.age >= despawn_age;
}

pub fn isDestroyed(self: ItemEntity) bool {
    return self.health <= 0;
}

pub fn canPickUp(self: ItemEntity) bool {
    return self.pickup_delay == 0;
}

pub const pickup_volume: f32 = 0.2;

pub fn pickupPitch(rand: *world.JavaRandom) f32 {
    return ((rand.nextFloat() - rand.nextFloat()) * 0.7 + 1.0) * 2.0;
}

test "spawn seeds an upward hop and a small random horizontal drift" {
    var rand = world.JavaRandom.init(0);
    const item = ItemEntity.spawn(math.Vec3.init(8, 5, 8), .{ .id = .{ .block = @enumFromInt(1) }, .count = 1 }, &rand);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), item.base.motion.y, 1.0e-9);
    try std.testing.expect(item.base.motion.x >= -0.1 and item.base.motion.x <= 0.1);
    try std.testing.expect(item.base.motion.z >= -0.1 and item.base.motion.z <= 0.1);
}

test "gravity accelerates a falling item" {
    var w = try world.testing.flatWorld(std.testing.allocator, 0);
    defer w.deinit();
    var rand = world.JavaRandom.init(0);
    var item = ItemEntity.spawn(math.Vec3.init(8, 50, 8), .{ .id = .{ .block = @enumFromInt(1) }, .count = 1 }, &rand);
    item.base.motion = math.Vec3.init(0, 0, 0);
    item.tick(&w, &rand);
    try std.testing.expectApproxEqAbs(@as(f64, -0.04 * 0.98), item.base.motion.y, 1.0e-9);
}

test "landing zeroes motionY, so the -0.5 bounce factor has nothing to act on" {
    var w = try world.testing.flatWorld(std.testing.allocator, 1);
    defer w.deinit();
    var rand = world.JavaRandom.init(0);
    var item = ItemEntity.spawn(math.Vec3.init(8, 1, 8), .{ .id = .{ .block = @enumFromInt(1) }, .count = 1 }, &rand);
    item.base.motion = math.Vec3.init(0, -0.0784, 0);
    item.tick(&w, &rand);
    try std.testing.expect(item.base.on_ground);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), item.base.motion.y, 1.0e-9);
}

test "isExpired only becomes true at 6000 ticks (5 minutes)" {
    var rand = world.JavaRandom.init(0);
    var item = ItemEntity.spawn(math.Vec3.init(0, 0, 0), .{ .id = .{ .block = @enumFromInt(1) }, .count = 1 }, &rand);
    item.age = 5999;
    try std.testing.expect(!item.isExpired());
    item.age = 6000;
    try std.testing.expect(item.isExpired());
}

test "canPickUp is false until the pickup delay elapses" {
    var w = try world.testing.flatWorld(std.testing.allocator, 0);
    defer w.deinit();
    var rand = world.JavaRandom.init(0);
    var item = ItemEntity.spawn(math.Vec3.init(8, 50, 8), .{ .id = .{ .block = @enumFromInt(1) }, .count = 1 }, &rand);
    try std.testing.expect(!item.canPickUp());
    for (0..10) |_| item.tick(&w, &rand);
    try std.testing.expect(item.canPickUp());
}

test "an item lying on a cactus is whittled away and destroyed" {
    var w = try world.testing.flatWorld(std.testing.allocator, 1);
    defer w.deinit();
    w.setBlock(.init(8, 1, 8), .cactus);

    var rand = world.JavaRandom.init(0);
    var item = ItemEntity.spawn(math.Vec3.init(8.5, 2.0 - 1.0 / 16.0, 8.5), .{ .id = .{ .block = .stone }, .count = 1 }, &rand);
    item.base.motion = math.Vec3.init(0, 0, 0);

    for (0..max_health) |_| {
        try std.testing.expect(!item.isDestroyed());
        item.tick(&w, &rand);
    }
    try std.testing.expect(item.isDestroyed());
}

test "an item dropped in lava is scalded and burns up on the spot" {
    var w = try world.testing.flatWorld(std.testing.allocator, 1);
    defer w.deinit();

    const chunk = w.getChunk(0, 0).?;
    for (0..world.Chunk.width) |x| {
        for (0..world.Chunk.width) |z| {
            chunk.setBlock(@intCast(x), 1, @intCast(z), .stationary_lava);
        }
    }

    var rand = world.JavaRandom.init(0);
    var item = ItemEntity.spawn(math.Vec3.init(8.5, 1.5, 8.5), .{ .id = .{ .block = .stone }, .count = 1 }, &rand);
    item.base.motion = math.Vec3.init(0, 0, 0);

    item.tick(&w, &rand);
    try std.testing.expectEqual(lava_fire_ticks + 1, item.fire);
    try std.testing.expect(item.isDestroyed());
}

test "an item lying in a fire block is whittled away a point a tick" {
    var w = try world.testing.flatWorld(std.testing.allocator, 1);
    defer w.deinit();
    w.setBlock(.init(8, 1, 8), .fire);

    var rand = world.JavaRandom.init(0);
    var item = ItemEntity.spawn(math.Vec3.init(8.5, 1, 8.5), .{ .id = .{ .block = .stone }, .count = 1 }, &rand);
    item.base.motion = math.Vec3.init(0, 0, 0);

    for (0..max_health) |_| {
        try std.testing.expect(!item.isDestroyed());
        item.tick(&w, &rand);
    }
    try std.testing.expect(item.isDestroyed());
}

test "an item well clear of any flame takes no damage and settles below zero fire" {
    var w = try world.testing.flatWorld(std.testing.allocator, 1);
    defer w.deinit();

    var rand = world.JavaRandom.init(0);
    var item = ItemEntity.spawn(math.Vec3.init(8.5, 1, 8.5), .{ .id = .{ .block = .stone }, .count = 1 }, &rand);
    item.base.motion = math.Vec3.init(0, 0, 0);

    item.tick(&w, &rand);
    try std.testing.expectEqual(max_health, item.health);
    try std.testing.expectEqual(-fire_resistance, item.fire);
}

test "the fire an item is carrying survives a save and reload" {
    var rand = world.JavaRandom.init(0);
    var item = ItemEntity.spawn(math.Vec3.init(8.5, 1, 8.5), .{ .id = .{ .block = .stone }, .count = 1 }, &rand);
    item.fire = lava_fire_ticks;

    try std.testing.expectEqual(lava_fire_ticks, fromRecord(item.toRecord()).fire);
}

pub fn toRecord(self: ItemEntity) world.entity_nbt.Item {
    return .{
        .base = .{
            .position = .{
                .x = self.base.position.x,
                .y = self.base.position.y + self.base.y_size,
                .z = self.base.position.z,
            },
            .motion = self.base.motion,
            .fire = @intCast(self.fire),
            .on_ground = self.base.on_ground,
        },
        .stack = self.stack,
        .health = @intCast(self.health),
        .age = @intCast(self.age),
    };
}

pub fn fromRecord(record: world.entity_nbt.Item) ItemEntity {
    var item = ItemEntity{
        .base = Entity.init(record.base.position, width, height),
        .stack = record.stack,
        .health = record.health,
        .age = @intCast(@max(0, record.age)),
        .fire = record.base.fire,
    };
    item.base.triggers_walking = false;
    item.base.motion = record.base.motion;
    item.base.on_ground = record.base.on_ground;
    return item;
}
