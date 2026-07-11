const std = @import("std");
const math = @import("math");
const world = @import("world");

const Entity = @import("entity.zig");
const FallingBlock = @import("falling_block.zig");
const Particle = @import("particle.zig");
const Inventory = @import("inventory.zig");
const ItemEntity = @import("item_entity.zig");
const Pig = @import("pig.zig");
const Player = @import("player.zig");

const Entities = @This();

items: std.ArrayList(ItemEntity) = .empty,
falling_blocks: std.ArrayList(FallingBlock) = .empty,
pigs: std.ArrayList(Pig) = .empty,
particles: std.ArrayList(Particle) = .empty,

pub fn deinit(self: *Entities, gpa: std.mem.Allocator) void {
    self.items.deinit(gpa);
    self.falling_blocks.deinit(gpa);
    self.particles.deinit(gpa);
    self.pigs.deinit(gpa);
}

pub fn count(self: *const Entities) usize {
    return self.items.items.len + self.falling_blocks.items.len + self.pigs.items.len;
}

pub fn dropStack(
    self: *Entities,
    gpa: std.mem.Allocator,
    x: i32,
    y: i32,
    z: i32,
    stack: Inventory.ItemStack,
    rand: *world.JavaRandom,
) !void {
    const position = math.Vec3.init(
        @as(f64, @floatFromInt(x)) + @as(f64, rand.nextFloat()) * 0.7 + 0.15,
        @as(f64, @floatFromInt(y)) + @as(f64, rand.nextFloat()) * 0.7 + 0.15,
        @as(f64, @floatFromInt(z)) + @as(f64, rand.nextFloat()) * 0.7 + 0.15,
    );
    try self.items.append(gpa, ItemEntity.spawn(position, stack, rand));
}

pub fn spawnFallingBlock(self: *Entities, gpa: std.mem.Allocator, x: i32, y: i32, z: i32, block_id: world.Block) !void {
    const position = math.Vec3.init(
        @as(f64, @floatFromInt(x)) + 0.5,
        @floatFromInt(y),
        @as(f64, @floatFromInt(z)) + 0.5,
    );
    try self.falling_blocks.append(gpa, FallingBlock.spawn(position, block_id));
}

pub const destroy_grid: i32 = 4;

pub fn spawnBlockDestroyParticles(
    self: *Entities,
    gpa: std.mem.Allocator,
    x: i32,
    y: i32,
    z: i32,
    tile: u8,
    tint: [3]u8,
    rand: *world.JavaRandom,
) !void {
    const step = 1.0 / @as(f64, destroy_grid);
    var ix: i32 = 0;
    while (ix < destroy_grid) : (ix += 1) {
        var iy: i32 = 0;
        while (iy < destroy_grid) : (iy += 1) {
            var iz: i32 = 0;
            while (iz < destroy_grid) : (iz += 1) {
                const px = @as(f64, @floatFromInt(x)) + (@as(f64, @floatFromInt(ix)) + 0.5) * step;
                const py = @as(f64, @floatFromInt(y)) + (@as(f64, @floatFromInt(iy)) + 0.5) * step;
                const pz = @as(f64, @floatFromInt(z)) + (@as(f64, @floatFromInt(iz)) + 0.5) * step;
                var shard = Particle.spawn(
                    math.Vec3.init(px, py, pz),
                    math.Vec3.init(
                        px - @as(f64, @floatFromInt(x)) - 0.5,
                        py - @as(f64, @floatFromInt(y)) - 0.5,
                        pz - @as(f64, @floatFromInt(z)) - 0.5,
                    ),
                    tile,
                    rand,
                );
                shard.tint = tint;
                try self.particles.append(gpa, shard);
            }
        }
    }
}

pub const hit_inset: f64 = 0.1;
pub const hit_slowdown: f32 = 0.2;
pub const hit_shrink: f32 = 0.6;

pub fn spawnBlockHitParticle(
    self: *Entities,
    gpa: std.mem.Allocator,
    x: i32,
    y: i32,
    z: i32,
    side: world.Side,
    tile: u8,
    tint: [3]u8,
    rand: *world.JavaRandom,
) !void {
    const span = 1.0 - hit_inset * 2.0;
    var px = @as(f64, @floatFromInt(x)) + rand.nextDouble() * span + hit_inset;
    var py = @as(f64, @floatFromInt(y)) + rand.nextDouble() * span + hit_inset;
    var pz = @as(f64, @floatFromInt(z)) + rand.nextDouble() * span + hit_inset;

    switch (side) {
        world.Side.down => py = @as(f64, @floatFromInt(y)) - hit_inset,
        world.Side.up => py = @as(f64, @floatFromInt(y)) + 1.0 + hit_inset,
        world.Side.north => pz = @as(f64, @floatFromInt(z)) - hit_inset,
        world.Side.south => pz = @as(f64, @floatFromInt(z)) + 1.0 + hit_inset,
        world.Side.west => px = @as(f64, @floatFromInt(x)) - hit_inset,
        world.Side.east => px = @as(f64, @floatFromInt(x)) + 1.0 + hit_inset,
    }

    var shard = Particle.spawn(math.Vec3.init(px, py, pz), math.Vec3.init(0, 0, 0), tile, rand);
    shard.tint = tint;
    try self.particles.append(gpa, shard.slowedBy(hit_slowdown).scaledBy(hit_shrink));
}

pub fn tickParticles(
    self: *Entities,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    rand: *world.JavaRandom,
) !void {
    var i: usize = 0;
    while (i < self.particles.items.len) {
        self.particles.items[i].tick(world_map, rand);
        const particle = self.particles.items[i];
        if (particle.isExpired()) {
            _ = self.particles.swapRemove(i);
            continue;
        }
        i += 1;
        if (particle.kind == .lava) {
            const progress = @as(f32, @floatFromInt(particle.age)) / @as(f32, @floatFromInt(particle.max_age));
            if (rand.nextFloat() > progress) {
                try self.particles.append(gpa, Particle.spawnSmoke(particle.base.position, particle.base.motion, rand));
            }
        }
    }
}

pub fn spawnWaterSplash(
    self: *Entities,
    gpa: std.mem.Allocator,
    base: Entity,
    rand: *world.JavaRandom,
) !void {
    const surface: f64 = @floatFromInt(math.util.floorDouble(base.boundingBox().min_y) + 1);
    var spawned: f64 = 0;
    while (spawned < 1.0 + base.width * 20.0) : (spawned += 1) {
        const dx = (@as(f64, rand.nextFloat()) * 2.0 - 1.0) * base.width;
        const dz = (@as(f64, rand.nextFloat()) * 2.0 - 1.0) * base.width;
        try self.particles.append(gpa, Particle.spawnSplash(
            math.Vec3.init(base.position.x + dx, surface, base.position.z + dz),
            base.motion,
            rand,
        ));
    }
}

pub fn spawnPig(self: *Entities, gpa: std.mem.Allocator, position: math.Vec3) !void {
    try self.pigs.append(gpa, Pig.spawn(position));
}

pub fn tickItems(self: *Entities, world_map: *const world.World, player: *Player) void {
    var i: usize = 0;
    while (i < self.items.items.len) {
        const item = &self.items.items[i];
        item.tick(world_map);

        var picked_up = false;
        if (item.canPickUp() and item.base.boundingBox().intersects(player.base.boundingBox())) {
            const leftover = player.inventory.addStack(item.stack);
            if (leftover == 0) {
                picked_up = true;
            } else {
                item.stack.count = leftover;
            }
        }

        if (picked_up or item.isExpired()) {
            _ = self.items.swapRemove(i);
        } else {
            i += 1;
        }
    }
}

pub fn tickPigs(self: *Entities, world_map: *const world.World, rand: *world.JavaRandom) void {
    for (self.pigs.items) |*pig| pig.tick(world_map, rand);
}

test "walking over a dropped stack picks it up" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var player = Player.spawn(math.Vec3.init(8, 1, 8));
    try entities.dropStack(gpa, 8, 1, 8, .{ .id = .{ .block = .stone }, .count = 3 }, &w.rand);
    entities.items.items[0].pickup_delay = 0;
    entities.items.items[0].base.position = player.base.position;

    entities.tickItems(&w, &player);

    try std.testing.expectEqual(@as(usize, 0), entities.items.items.len);
    try std.testing.expectEqual(@as(u8, 3), player.inventory.slots[0].?.count);
}

test "a stack that does not fit keeps whatever is left over on the ground" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var player = Player.spawn(math.Vec3.init(8, 1, 8));
    for (&player.inventory.slots) |*slot| {
        slot.* = .{ .id = .{ .block = .stone }, .count = Inventory.max_stack_size };
    }
    player.inventory.slots[0].?.count = Inventory.max_stack_size - 1;

    try entities.dropStack(gpa, 8, 1, 8, .{ .id = .{ .block = .stone }, .count = 5 }, &w.rand);
    entities.items.items[0].pickup_delay = 0;
    entities.items.items[0].base.position = player.base.position;

    entities.tickItems(&w, &player);

    try std.testing.expectEqual(@as(usize, 1), entities.items.items.len);
    try std.testing.expectEqual(@as(u8, 4), entities.items.items[0].stack.count);
}

test "an item out of reach of the player is left alone" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var player = Player.spawn(math.Vec3.init(0, 1, 0));
    try entities.dropStack(gpa, 8, 1, 8, .{ .id = .{ .block = .stone }, .count = 1 }, &w.rand);
    entities.items.items[0].pickup_delay = 0;

    entities.tickItems(&w, &player);

    try std.testing.expectEqual(@as(usize, 1), entities.items.items.len);
    try std.testing.expect(player.inventory.slots[0] == null);
}

test "count sums every kind of entity" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    try entities.dropStack(gpa, 0, 1, 0, .{ .id = .{ .block = .stone }, .count = 1 }, &w.rand);
    try entities.spawnFallingBlock(gpa, 0, 5, 0, .sand);
    try entities.spawnPig(gpa, math.Vec3.init(0, 1, 0));

    try std.testing.expectEqual(@as(usize, 3), entities.count());
}

test "a young lava ember sheds a smoke puff as it flies" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(1);
    try entities.particles.append(gpa, Particle.spawnLava(math.Vec3.init(8, 10, 8), &rand));
    try entities.tickParticles(gpa, &w, &rand);

    try std.testing.expectEqual(@as(usize, 2), entities.particles.items.len);
    try std.testing.expectEqual(Particle.Kind.lava, entities.particles.items[0].kind);
    try std.testing.expectEqual(Particle.Kind.smoke, entities.particles.items[1].kind);
}

test "wading into water throws a ring of splash droplets at the surface" {
    const gpa = std.testing.allocator;
    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(6);
    var base = Entity.init(math.Vec3.init(8, 4.4, 8), 0.6, 1.8);
    base.motion = math.Vec3.init(0, -0.3, 0);
    try entities.spawnWaterSplash(gpa, base, &rand);

    try std.testing.expectEqual(@as(usize, 13), entities.particles.items.len);
    for (entities.particles.items) |droplet| {
        try std.testing.expectEqual(Particle.Kind.splash, droplet.kind);
        try std.testing.expectApproxEqAbs(@as(f64, 5.0), droplet.base.position.y, 1.0e-9);
        try std.testing.expect(@abs(droplet.base.position.x - 8.0) <= 0.6);
    }
}

test "a hit particle lands on the face being mined" {
    const gpa = std.testing.allocator;
    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(4);
    try entities.spawnBlockHitParticle(gpa, 5, 9, 3, world.Side.up, 1, .{ 255, 255, 255 }, &rand);
    try entities.spawnBlockHitParticle(gpa, 5, 9, 3, world.Side.west, 1, .{ 255, 255, 255 }, &rand);

    const on_top = entities.particles.items[0];
    try std.testing.expectApproxEqAbs(@as(f64, 10.0 + hit_inset), on_top.base.position.y, 1.0e-9);
    try std.testing.expect(on_top.base.position.x > 5.0 and on_top.base.position.x < 6.0);

    const on_side = entities.particles.items[1];
    try std.testing.expectApproxEqAbs(@as(f64, 5.0 - hit_inset), on_side.base.position.x, 1.0e-9);
}

test "a hit particle is smaller and slower than a destroy shard" {
    const gpa = std.testing.allocator;
    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(4);
    try entities.spawnBlockHitParticle(gpa, 0, 0, 0, world.Side.up, 1, .{ 255, 255, 255 }, &rand);
    const hit = entities.particles.items[0];

    var same_rand = world.JavaRandom.init(4);
    _ = same_rand.nextDouble();
    _ = same_rand.nextDouble();
    _ = same_rand.nextDouble();
    const plain = Particle.spawn(math.Vec3.init(0, 0, 0), math.Vec3.init(0, 0, 0), 1, &same_rand);

    try std.testing.expect(hit.scale < plain.scale);
    try std.testing.expectApproxEqAbs(plain.scale * hit_shrink, hit.scale, 1.0e-6);
    try std.testing.expect(@abs(hit.base.motion.x) < @abs(plain.base.motion.x));
}
