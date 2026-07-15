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
    for (self.pigs.items) |*pig| pig.deinit(gpa);
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

const throw_speed: f64 = 0.3;
const throw_lift: f64 = 0.1;
const throw_pickup_delay: u16 = 40;
const player_hand_drop: f64 = 0.3 - 0.12;

pub fn throwFromPlayer(
    self: *Entities,
    gpa: std.mem.Allocator,
    player: *const Player,
    stack: Inventory.ItemStack,
    rand: *world.JavaRandom,
) !void {
    const position = math.Vec3.init(
        player.base.position.x,
        player.base.position.y + Player.eye_height - player_hand_drop,
        player.base.position.z,
    );
    var item = ItemEntity.spawn(position, stack, rand);
    item.pickup_delay = throw_pickup_delay;

    const look = player.lookVector();
    const angle = @as(f64, rand.nextFloat()) * std.math.pi * 2.0;
    const jitter = 0.02 * @as(f64, rand.nextFloat());
    item.base.motion = .{
        .x = @as(f64, look[0]) * throw_speed + @cos(angle) * jitter,
        .y = @as(f64, look[1]) * throw_speed + throw_lift + @as(f64, rand.nextFloat() - rand.nextFloat()) * 0.1,
        .z = @as(f64, look[2]) * throw_speed + @sin(angle) * jitter,
    };

    try self.items.append(gpa, item);
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

const pickup_reach: f64 = 1.0;

pub fn tickItems(self: *Entities, world_map: *const world.World, player: *Player) void {
    const reach = player.base.boundingBox().expand(pickup_reach, 0, pickup_reach);
    var i: usize = 0;
    while (i < self.items.items.len) {
        const item = &self.items.items[i];
        item.tick(world_map);

        var picked_up = false;
        if (player.health > 0 and item.canPickUp() and item.base.boundingBox().intersects(reach)) {
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

fn chunkOf(coordinate: f64) i32 {
    return @divFloor(math.util.floorDouble(coordinate), world.constants.chunk_width);
}

fn collectChunkEntities(
    context: *anyopaque,
    gpa: std.mem.Allocator,
    chunk_x: i32,
    chunk_z: i32,
    out: *std.ArrayList(world.nbt.Tag),
) anyerror!void {
    const self: *Entities = @ptrCast(@alignCast(context));
    for (self.pigs.items) |pig| {
        if (chunkOf(pig.base.position.x) != chunk_x or chunkOf(pig.base.position.z) != chunk_z) continue;
        try out.append(gpa, try world.entity_nbt.storePig(gpa, pig.toRecord()));
    }
}

fn restoreChunkEntity(context: *anyopaque, gpa: std.mem.Allocator, entity: world.nbt.Compound) anyerror!void {
    const self: *Entities = @ptrCast(@alignCast(context));
    const record = world.entity_nbt.loadPig(entity) orelse return;
    try self.pigs.append(gpa, Pig.fromRecord(record));
}

pub fn entityIo(self: *Entities) world.World.EntityIo {
    return .{
        .context = self,
        .collect = collectChunkEntities,
        .restore = restoreChunkEntity,
    };
}

const pig_push_reach: f64 = 0.2;
const pig_push_strength: f64 = 0.05;

fn pushApart(pusher: *Pig, pushed: *Pig) void {
    var dx = pushed.base.position.x - pusher.base.position.x;
    var dz = pushed.base.position.z - pusher.base.position.z;

    var spread = math.util.absMax(dx, dz);
    if (spread < 0.01) return;

    spread = @sqrt(spread);
    dx /= spread;
    dz /= spread;

    const falloff = @min(1.0 / spread, 1.0);
    dx *= falloff * pig_push_strength;
    dz *= falloff * pig_push_strength;

    pusher.base.motion.x -= dx;
    pusher.base.motion.z -= dz;
    pushed.base.motion.x += dx;
    pushed.base.motion.z += dz;
}

fn pushNeighbours(self: *Entities, index: usize) void {
    const reach = self.pigs.items[index].base.boundingBox().expand(pig_push_reach, 0, pig_push_reach);
    for (self.pigs.items, 0..) |*other, i| {
        if (i == index) continue;
        if (!other.base.boundingBox().intersects(reach)) continue;
        pushApart(other, &self.pigs.items[index]);
    }
}

pub fn tickPigs(
    self: *Entities,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    player: *const Player,
    rand: *world.JavaRandom,
) !void {
    const view: Pig.PlayerView = .{
        .position = player.base.position,
        .eye_height = Player.eye_height,
        .alive = player.health > 0,
    };

    var i: usize = 0;
    while (i < self.pigs.items.len) {
        try self.pigs.items[i].tick(gpa, world_map, view, rand);
        self.pushNeighbours(i);

        if (self.pigs.items[i].takeDrops()) |drops| {
            const position = self.pigs.items[i].base.position;
            for (0..drops.count) |_| {
                try self.items.append(gpa, ItemEntity.spawn(
                    position,
                    .{ .id = .{ .item = drops.id }, .count = 1 },
                    rand,
                ));
            }
        }

        if (self.pigs.items[i].dead) {
            var removed = self.pigs.swapRemove(i);
            removed.deinit(gpa);
            continue;
        }
        i += 1;
    }
}

test "a pig is written into the chunk it stands in and comes back on reload" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var handle = try world.save.open(io, tmp.dir, "Piggy");
    defer handle.close(gpa, io);

    var generator = try world.TerrainGenerator.init(gpa, 7);
    defer generator.deinit(gpa);

    {
        var w = try world.testing.flatWorld(gpa, 1);
        defer w.deinit();
        w.persistence = .{ .handle = &handle, .io = io };

        var entities: Entities = .{};
        defer entities.deinit(gpa);
        w.entity_io = entities.entityIo();

        try entities.spawnPig(gpa, math.Vec3.init(8.5, 1, 8.5));
        entities.pigs.items[0].health = 6;
        entities.pigs.items[0].yaw = 42.0;
        entities.pigs.items[0].saddled = true;
        entities.pigs.items[0].base.on_ground = true;

        try w.saveLoadedChunks();
    }

    var reloaded = world.World.init(gpa);
    defer reloaded.deinit();
    reloaded.persistence = .{ .handle = &handle, .io = io };

    var restored: Entities = .{};
    defer restored.deinit(gpa);
    reloaded.entity_io = restored.entityIo();

    _ = try reloaded.getOrGenerateChunk(generator, 0, 0);

    try std.testing.expectEqual(@as(usize, 1), restored.pigs.items.len);
    const pig = restored.pigs.items[0];
    try std.testing.expectApproxEqAbs(@as(f64, 8.5), pig.base.position.x, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), pig.base.position.y, 1.0e-9);
    try std.testing.expectEqual(@as(i32, 6), pig.health);
    try std.testing.expectApproxEqAbs(@as(f32, 42.0), pig.yaw, 1.0e-6);
    try std.testing.expect(pig.saddled);
    try std.testing.expect(pig.base.on_ground);
}

test "a pig is only written into the chunk it is standing in" {
    const gpa = std.testing.allocator;

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    try entities.spawnPig(gpa, math.Vec3.init(8.5, 1, 8.5));
    try entities.spawnPig(gpa, math.Vec3.init(-24.0, 1, 40.0));

    const io = entities.entityIo();

    var here: std.ArrayList(world.nbt.Tag) = .empty;
    defer {
        for (here.items) |*tag| world.nbt.deinit(gpa, tag);
        here.deinit(gpa);
    }
    try io.collect(io.context, gpa, 0, 0, &here);
    try std.testing.expectEqual(@as(usize, 1), here.items.len);

    var neighbour: std.ArrayList(world.nbt.Tag) = .empty;
    defer {
        for (neighbour.items) |*tag| world.nbt.deinit(gpa, tag);
        neighbour.deinit(gpa);
    }
    try io.collect(io.context, gpa, -2, 2, &neighbour);
    try std.testing.expectEqual(@as(usize, 1), neighbour.items.len);

    var empty: std.ArrayList(world.nbt.Tag) = .empty;
    defer empty.deinit(gpa);
    try io.collect(io.context, gpa, 5, 5, &empty);
    try std.testing.expectEqual(@as(usize, 0), empty.items.len);
}

test "a thrown item flies out in front of the player with a pickup delay" {
    const gpa = std.testing.allocator;
    var entities: Entities = .{};
    defer entities.deinit(gpa);
    var rand = world.JavaRandom.init(0);

    const player = Player.spawn(math.Vec3.init(8, 1, 8));
    try entities.throwFromPlayer(gpa, &player, .{ .id = .{ .block = .stone }, .count = 1 }, &rand);

    const item = entities.items.items[0];
    try std.testing.expectEqual(@as(u16, 40), item.pickup_delay);
    try std.testing.expect(!item.canPickUp());
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 + Player.eye_height - 0.18), item.base.position.y, 1.0e-9);
    try std.testing.expect(item.base.motion.z > 0.25);
    try std.testing.expect(@abs(item.base.motion.x) < 0.05);
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

test "an item within a block of the player is drawn in, one further out is not" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var player = Player.spawn(math.Vec3.init(8, 1, 8));
    for ([_]f64{ 9.4, 9.5 }) |x| {
        try entities.dropStack(gpa, 8, 1, 8, .{ .id = .{ .block = .stone }, .count = 1 }, &w.rand);
        var item = &entities.items.items[entities.items.items.len - 1];
        item.pickup_delay = 0;
        item.base.position = math.Vec3.init(x, 1, 8);
        item.base.motion = math.Vec3.init(0, 0, 0);
    }

    entities.tickItems(&w, &player);

    try std.testing.expectEqual(@as(usize, 1), entities.items.items.len);
    try std.testing.expectApproxEqAbs(@as(f64, 9.5), entities.items.items[0].base.position.x, 1.0e-9);
}

test "a dead player leaves items on the ground" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var player = Player.spawn(math.Vec3.init(8, 1, 8));
    player.health = 0;
    try entities.dropStack(gpa, 8, 1, 8, .{ .id = .{ .block = .stone }, .count = 1 }, &w.rand);
    entities.items.items[0].pickup_delay = 0;
    entities.items.items[0].base.position = player.base.position;

    entities.tickItems(&w, &player);

    try std.testing.expectEqual(@as(usize, 1), entities.items.items.len);
}
