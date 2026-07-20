const std = @import("std");

const math = @import("math");
const world = @import("world");

const Animal = @import("animal.zig");
const Chicken = @import("chicken.zig");
const Cow = @import("cow.zig");
const Entity = @import("entity.zig");
const FallingBlock = @import("falling_block.zig");
const Inventory = @import("inventory.zig");
const ItemEntity = @import("item_entity.zig");
const Painting = @import("painting.zig");
const Particle = @import("particle.zig");
const PickupFx = @import("pickup_fx.zig");
const Pig = @import("pig.zig");
const Player = @import("player.zig");
const Sheep = @import("sheep.zig");

const Entities = @This();

items: std.ArrayList(ItemEntity) = .empty,
falling_blocks: std.ArrayList(FallingBlock) = .empty,
pigs: std.ArrayList(Pig) = .empty,
sheep: std.ArrayList(Sheep) = .empty,
cows: std.ArrayList(Cow) = .empty,
chickens: std.ArrayList(Chicken) = .empty,
particles: std.ArrayList(Particle) = .empty,
pickups: std.ArrayList(PickupFx) = .empty,
paintings: std.ArrayList(Painting) = .empty,

fn herds(self: *Entities) struct {
    *std.ArrayList(Pig),
    *std.ArrayList(Sheep),
    *std.ArrayList(Cow),
    *std.ArrayList(Chicken),
} {
    return .{ &self.pigs, &self.sheep, &self.cows, &self.chickens };
}

pub const Target = union(enum) {
    pig: usize,
    sheep: usize,
    cow: usize,
    chicken: usize,
    painting: usize,
};

pub const entity_reach: f64 = 3.0;
const collision_border: f64 = 0.1;

fn boxRayDistance(box: math.AABB, origin: [3]f64, along: [3]f64, reach: f64) ?f64 {
    var entry: f64 = 0;
    var exit = reach;

    const low = [3]f64{ box.min_x, box.min_y, box.min_z };
    const high = [3]f64{ box.max_x, box.max_y, box.max_z };

    for (0..3) |axis| {
        if (along[axis] == 0.0) {
            if (origin[axis] < low[axis] or origin[axis] > high[axis]) return null;
            continue;
        }
        const to_low = (low[axis] - origin[axis]) / along[axis];
        const to_high = (high[axis] - origin[axis]) / along[axis];
        entry = @max(entry, @min(to_low, to_high));
        exit = @min(exit, @max(to_low, to_high));
    }

    if (entry > exit) return null;
    return entry;
}

fn boxHolds(box: math.AABB, point: [3]f64) bool {
    return point[0] >= box.min_x and point[0] <= box.max_x and
        point[1] >= box.min_y and point[1] <= box.max_y and
        point[2] >= box.min_z and point[2] <= box.max_z;
}

pub fn pick(self: *Entities, origin: math.Vec3, look: [3]f32, reach: f64) ?Target {
    const start = [3]f64{ origin.x, origin.y, origin.z };
    const along = [3]f64{ look[0], look[1], look[2] };

    var found: ?Target = null;
    var nearest: f64 = 0;

    for (self.paintings.items, 0..) |painting, index| {
        const target: Target = .{ .painting = index };
        if (boxHolds(painting.box, start)) {
            found = target;
            nearest = 0;
        } else if (boxRayDistance(painting.box, start, along, reach)) |distance| {
            if (distance < nearest or nearest == 0) {
                found = target;
                nearest = distance;
            }
        }
    }

    inline for (self.herds(), 0..) |herd, kind| {
        for (herd.items, 0..) |*animal, index| {
            if (!animal.animal.isAlive()) continue;

            const box = animal.animal.base.boundingBox().expand(collision_border, collision_border, collision_border);
            const target: Target = switch (kind) {
                0 => .{ .pig = index },
                1 => .{ .sheep = index },
                2 => .{ .cow = index },
                else => .{ .chicken = index },
            };

            // getMouseOver keeps a nearest of zero as its unset marker, so a later entity still
            // wins against one the eye stands inside. Kept as vanilla has it.
            if (boxHolds(box, start)) {
                found = target;
                nearest = 0;
            } else if (boxRayDistance(box, start, along, reach)) |distance| {
                if (distance < nearest or nearest == 0) {
                    found = target;
                    nearest = distance;
                }
            }
        }
    }

    return found;
}

pub fn hurtTarget(self: *Entities, target: Target, amount: i32, source: math.Vec3, rand: *world.JavaRandom) void {
    switch (target) {
        .pig => |index| _ = self.pigs.items[index].animal.hurt(amount, source, rand),
        .sheep => |index| _ = self.sheep.items[index].hurt(amount, source, rand),
        .cow => |index| _ = self.cows.items[index].animal.hurt(amount, source, rand),
        .chicken => |index| _ = self.chickens.items[index].animal.hurt(amount, source, rand),
        .painting => {},
    }
}

pub fn deinit(self: *Entities, gpa: std.mem.Allocator) void {
    self.items.deinit(gpa);
    self.falling_blocks.deinit(gpa);
    self.particles.deinit(gpa);
    self.pickups.deinit(gpa);
    self.paintings.deinit(gpa);
    inline for (self.herds()) |herd| {
        for (herd.items) |*animal| animal.deinit(gpa);
        herd.deinit(gpa);
    }
}

pub fn animalCount(self: *const Entities) usize {
    return self.pigs.items.len + self.sheep.items.len + self.cows.items.len + self.chickens.items.len;
}

pub fn count(self: *const Entities) usize {
    return self.items.items.len + self.falling_blocks.items.len + self.paintings.items.len + self.animalCount();
}

pub fn dropStackAt(
    self: *Entities,
    gpa: std.mem.Allocator,
    position: math.Vec3,
    stack: Inventory.ItemStack,
    rand: *world.JavaRandom,
) !void {
    try self.items.append(gpa, ItemEntity.spawn(position, stack, rand));
}

pub fn tickPaintings(
    self: *Entities,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    rand: *world.JavaRandom,
) !void {
    var index = self.paintings.items.len;
    while (index > 0) {
        index -= 1;
        if (!self.paintings.items[index].dueForRecheck()) continue;
        if (self.paintings.items[index].fits(world_map, self.paintings.items, index)) continue;

        const fallen = self.paintings.orderedRemove(index);
        try self.dropStackAt(gpa, fallen.position, .{ .id = .{ .item = .painting }, .count = 1 }, rand);
    }
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

const scatter_speed: f64 = 0.5;
const scatter_lift: f64 = 0.2;

pub fn scatterFromPlayer(
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

    const speed = @as(f64, rand.nextFloat()) * scatter_speed;
    const angle = @as(f64, rand.nextFloat()) * std.math.pi * 2.0;
    item.base.motion = .{
        .x = -@sin(angle) * speed,
        .y = scatter_lift,
        .z = @cos(angle) * speed,
    };

    try self.items.append(gpa, item);
}

pub fn spawnPainting(self: *Entities, gpa: std.mem.Allocator, painting: Painting) !void {
    try self.paintings.append(gpa, painting);
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

pub const torch_flame_height: f64 = 0.7;
pub const torch_wall_lift: f64 = 0.22;
pub const torch_wall_reach: f64 = 0.27;

pub fn torchFlamePosition(x: i32, y: i32, z: i32, metadata: u4) math.Vec3 {
    const cx = @as(f64, @floatFromInt(x)) + 0.5;
    const cy = @as(f64, @floatFromInt(y)) + torch_flame_height;
    const cz = @as(f64, @floatFromInt(z)) + 0.5;
    return switch (metadata) {
        1 => math.Vec3.init(cx - torch_wall_reach, cy + torch_wall_lift, cz),
        2 => math.Vec3.init(cx + torch_wall_reach, cy + torch_wall_lift, cz),
        3 => math.Vec3.init(cx, cy + torch_wall_lift, cz - torch_wall_reach),
        4 => math.Vec3.init(cx, cy + torch_wall_lift, cz + torch_wall_reach),
        else => math.Vec3.init(cx, cy, cz),
    };
}

pub fn spawnTorchParticles(
    self: *Entities,
    gpa: std.mem.Allocator,
    x: i32,
    y: i32,
    z: i32,
    metadata: u4,
    rand: *world.JavaRandom,
) !void {
    const position = torchFlamePosition(x, y, z, metadata);
    const still = math.Vec3.init(0, 0, 0);
    try self.particles.append(gpa, Particle.spawnSmoke(position, still, rand));
    try self.particles.append(gpa, Particle.spawnFlame(position, still, rand));
}

pub const furnace_mouth_reach: f64 = 0.52;
pub const furnace_mouth_height: f64 = 6.0 / 16.0;

pub fn furnaceMouthPosition(x: i32, y: i32, z: i32, metadata: u4, rand: *world.JavaRandom) math.Vec3 {
    const cx = @as(f64, @floatFromInt(x)) + 0.5;
    const cy = @as(f64, @floatFromInt(y)) + @as(f64, rand.nextFloat()) * furnace_mouth_height;
    const cz = @as(f64, @floatFromInt(z)) + 0.5;
    const along = @as(f64, rand.nextFloat()) * 0.6 - 0.3;

    return switch (world.block.furnaceFacing(metadata)) {
        .west => math.Vec3.init(cx - furnace_mouth_reach, cy, cz + along),
        .east => math.Vec3.init(cx + furnace_mouth_reach, cy, cz + along),
        .north => math.Vec3.init(cx + along, cy, cz - furnace_mouth_reach),
        else => math.Vec3.init(cx + along, cy, cz + furnace_mouth_reach),
    };
}

pub fn spawnFurnaceParticles(
    self: *Entities,
    gpa: std.mem.Allocator,
    x: i32,
    y: i32,
    z: i32,
    metadata: u4,
    rand: *world.JavaRandom,
) !void {
    const position = furnaceMouthPosition(x, y, z, metadata, rand);
    const still = math.Vec3.init(0, 0, 0);
    try self.particles.append(gpa, Particle.spawnSmoke(position, still, rand));
    try self.particles.append(gpa, Particle.spawnFlame(position, still, rand));
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

pub fn spawnSheep(self: *Entities, gpa: std.mem.Allocator, position: math.Vec3, rand: *world.JavaRandom) !void {
    try self.sheep.append(gpa, Sheep.spawn(position, rand));
}

pub fn spawnCow(self: *Entities, gpa: std.mem.Allocator, position: math.Vec3) !void {
    try self.cows.append(gpa, Cow.spawn(position));
}

pub fn spawnChicken(self: *Entities, gpa: std.mem.Allocator, position: math.Vec3, rand: *world.JavaRandom) !void {
    try self.chickens.append(gpa, Chicken.spawn(position, rand));
}

const pickup_reach: f64 = 1.0;

pub fn tickItems(
    self: *Entities,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    player: *Player,
) !void {
    const reach = player.base.boundingBox().expand(pickup_reach, 0, pickup_reach);
    var i: usize = 0;
    while (i < self.items.items.len) {
        const item = &self.items.items[i];
        item.tick(world_map);

        var picked_up = false;
        if (player.health > 0 and item.canPickUp() and item.base.boundingBox().intersects(reach)) {
            const leftover = player.inventory.addStack(item.stack);
            if (leftover < item.stack.count) {
                item.stack.count = leftover;
                try self.pickups.append(gpa, PickupFx.spawn(item.*));
                picked_up = leftover == 0;
            }
        }

        if (picked_up or item.isExpired()) {
            _ = self.items.swapRemove(i);
        } else {
            i += 1;
        }
    }
}

pub fn tickPickups(self: *Entities) void {
    var i: usize = 0;
    while (i < self.pickups.items.len) {
        const fx = &self.pickups.items[i];
        fx.tick();
        if (fx.isExpired()) {
            _ = self.pickups.swapRemove(i);
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
        if (chunkOf(pig.animal.base.position.x) != chunk_x or chunkOf(pig.animal.base.position.z) != chunk_z) continue;
        try out.append(gpa, try world.entity_nbt.storePig(gpa, pig.toRecord()));
    }
    for (self.sheep.items) |sheep| {
        if (chunkOf(sheep.animal.base.position.x) != chunk_x or chunkOf(sheep.animal.base.position.z) != chunk_z) continue;
        try out.append(gpa, try world.entity_nbt.storeSheep(gpa, sheep.toRecord()));
    }
    for (self.cows.items) |cow| {
        if (chunkOf(cow.animal.base.position.x) != chunk_x or chunkOf(cow.animal.base.position.z) != chunk_z) continue;
        try out.append(gpa, try world.entity_nbt.storeCow(gpa, cow.toRecord()));
    }
    for (self.chickens.items) |chicken| {
        if (chunkOf(chicken.animal.base.position.x) != chunk_x or chunkOf(chicken.animal.base.position.z) != chunk_z) continue;
        try out.append(gpa, try world.entity_nbt.storeChicken(gpa, chicken.toRecord()));
    }
}

fn restoreChunkEntity(context: *anyopaque, gpa: std.mem.Allocator, entity: world.nbt.Compound) anyerror!void {
    const self: *Entities = @ptrCast(@alignCast(context));
    if (world.entity_nbt.loadPig(entity)) |record| {
        try self.pigs.append(gpa, Pig.fromRecord(record));
    } else if (world.entity_nbt.loadSheep(entity)) |record| {
        try self.sheep.append(gpa, Sheep.fromRecord(record));
    } else if (world.entity_nbt.loadCow(entity)) |record| {
        try self.cows.append(gpa, Cow.fromRecord(record));
    } else if (world.entity_nbt.loadChicken(entity)) |record| {
        try self.chickens.append(gpa, Chicken.fromRecord(record));
    }
}

pub fn entityIo(self: *Entities) world.World.EntityIo {
    return .{
        .context = self,
        .collect = collectChunkEntities,
        .restore = restoreChunkEntity,
    };
}

const mob_push_reach: f64 = 0.2;
const mob_push_strength: f64 = 0.05;

fn pushApart(pusher: *Animal, pushed: *Animal) void {
    var dx = pushed.base.position.x - pusher.base.position.x;
    var dz = pushed.base.position.z - pusher.base.position.z;

    var spread = math.util.absMax(dx, dz);
    if (spread < 0.01) return;

    spread = @sqrt(spread);
    dx /= spread;
    dz /= spread;

    const falloff = @min(1.0 / spread, 1.0);
    dx *= falloff * mob_push_strength;
    dz *= falloff * mob_push_strength;

    pusher.base.motion.x -= dx;
    pusher.base.motion.z -= dz;
    pushed.base.motion.x += dx;
    pushed.base.motion.z += dz;
}

fn pushNeighbours(self: *Entities, animal: *Animal) void {
    const reach = animal.base.boundingBox().expand(mob_push_reach, 0, mob_push_reach);
    inline for (self.herds()) |herd| {
        for (herd.items) |*other| {
            if (&other.animal == animal) continue;
            if (!other.animal.base.boundingBox().intersects(reach)) continue;
            pushApart(&other.animal, animal);
        }
    }
}

fn tickHerd(
    self: *Entities,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    view: Animal.PlayerView,
    rand: *world.JavaRandom,
    herd: anytype,
) !void {
    var i: usize = 0;
    while (i < herd.items.len) {
        const mob = &herd.items[i];
        try mob.tick(gpa, world_map, view, rand);
        self.pushNeighbours(&mob.animal);

        // A chicken can owe both the egg it just laid and the feathers it died leaving.
        while (mob.takeDrops()) |drops| {
            const position = mob.animal.base.position;
            for (0..drops.count) |_| {
                try self.items.append(gpa, ItemEntity.spawn(position, drops.stack(), rand));
            }
        }

        if (mob.animal.dead) {
            var removed = herd.swapRemove(i);
            removed.deinit(gpa);
            continue;
        }
        i += 1;
    }
}

pub fn tickAnimals(
    self: *Entities,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    player: *const Player,
    rand: *world.JavaRandom,
) !void {
    const view: Animal.PlayerView = .{
        .position = player.base.position,
        .eye_height = Player.eye_height,
        .alive = player.health > 0,
    };

    inline for (self.herds()) |herd| {
        try self.tickHerd(gpa, world_map, view, rand, herd);
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
        entities.pigs.items[0].animal.health = 6;
        entities.pigs.items[0].animal.yaw = 42.0;
        entities.pigs.items[0].animal.base.on_ground = true;
        entities.pigs.items[0].saddled = true;

        var rand = world.JavaRandom.init(0);
        try entities.spawnSheep(gpa, math.Vec3.init(9.5, 1, 9.5), &rand);
        entities.sheep.items[0].fleece_color = 15;
        entities.sheep.items[0].sheared = true;

        try entities.spawnCow(gpa, math.Vec3.init(10.5, 1, 10.5));
        entities.cows.items[0].animal.health = 5;

        try entities.spawnChicken(gpa, math.Vec3.init(11.5, 1, 11.5), &rand);
        entities.chickens.items[0].animal.health = 3;

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
    try std.testing.expectApproxEqAbs(@as(f64, 8.5), pig.animal.base.position.x, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), pig.animal.base.position.y, 1.0e-9);
    try std.testing.expectEqual(@as(i32, 6), pig.animal.health);
    try std.testing.expectApproxEqAbs(@as(f32, 42.0), pig.animal.yaw, 1.0e-6);
    try std.testing.expect(pig.saddled);
    try std.testing.expect(pig.animal.base.on_ground);

    try std.testing.expectEqual(@as(usize, 1), restored.sheep.items.len);
    const sheep = restored.sheep.items[0];
    try std.testing.expectApproxEqAbs(@as(f64, 9.5), sheep.animal.base.position.x, 1.0e-9);
    try std.testing.expectEqual(@as(u4, 15), sheep.fleece_color);
    try std.testing.expect(sheep.sheared);

    try std.testing.expectEqual(@as(usize, 1), restored.cows.items.len);
    const cow = restored.cows.items[0];
    try std.testing.expectApproxEqAbs(@as(f64, 10.5), cow.animal.base.position.x, 1.0e-9);
    try std.testing.expectEqual(@as(i32, 5), cow.animal.health);

    try std.testing.expectEqual(@as(usize, 1), restored.chickens.items.len);
    const chicken = restored.chickens.items[0];
    try std.testing.expectApproxEqAbs(@as(f64, 11.5), chicken.animal.base.position.x, 1.0e-9);
    try std.testing.expectEqual(@as(i32, 3), chicken.animal.health);
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

    try entities.tickItems(gpa, &w, &player);

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

    try entities.tickItems(gpa, &w, &player);

    try std.testing.expectEqual(@as(usize, 1), entities.items.items.len);
    try std.testing.expectEqual(@as(u8, 4), entities.items.items[0].stack.count);
}

test "picking a stack up leaves a swallow effect behind, a full inventory does not" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var player = Player.spawn(math.Vec3.init(8, 1, 8));
    try entities.dropStack(gpa, 8, 1, 8, .{ .id = .{ .block = .stone }, .count = 3 }, &w.rand);
    entities.items.items[0].pickup_delay = 0;
    entities.items.items[0].base.position = player.base.position;

    try entities.tickItems(gpa, &w, &player);

    const swallowed = entities.pickups.items[0].item;
    try std.testing.expectEqual(@as(usize, 1), entities.pickups.items.len);
    try std.testing.expectEqual(@as(u8, 0), swallowed.stack.count);
    try std.testing.expectEqual(swallowed.base.position, swallowed.base.prev_position);
    try std.testing.expectApproxEqAbs(player.base.position.x, swallowed.base.position.x, 0.1);

    for (&player.inventory.slots) |*slot| {
        slot.* = .{ .id = .{ .item = .coal }, .count = Inventory.max_stack_size };
    }
    try entities.dropStack(gpa, 8, 1, 8, .{ .id = .{ .block = .stone }, .count = 3 }, &w.rand);
    entities.items.items[0].pickup_delay = 0;
    entities.items.items[0].base.position = player.base.position;

    try entities.tickItems(gpa, &w, &player);

    try std.testing.expectEqual(@as(usize, 1), entities.pickups.items.len);
}

test "swallow effects are dropped once they have run their three ticks" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var player = Player.spawn(math.Vec3.init(8, 1, 8));
    try entities.dropStack(gpa, 8, 1, 8, .{ .id = .{ .block = .stone }, .count = 1 }, &w.rand);
    entities.items.items[0].pickup_delay = 0;
    entities.items.items[0].base.position = player.base.position;
    try entities.tickItems(gpa, &w, &player);

    for (0..PickupFx.duration - 1) |_| {
        entities.tickPickups();
        try std.testing.expectEqual(@as(usize, 1), entities.pickups.items.len);
    }
    entities.tickPickups();
    try std.testing.expectEqual(@as(usize, 0), entities.pickups.items.len);
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

    try entities.tickItems(gpa, &w, &player);

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
    try entities.spawnSheep(gpa, math.Vec3.init(0, 1, 0), &w.rand);
    try entities.spawnCow(gpa, math.Vec3.init(0, 1, 0));
    try entities.spawnChicken(gpa, math.Vec3.init(0, 1, 0), &w.rand);

    try std.testing.expectEqual(@as(usize, 4), entities.animalCount());
    try std.testing.expectEqual(@as(usize, 6), entities.count());
}

test "a chicken hands over both the egg it laid and the feathers it died leaving" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(3);
    try entities.spawnChicken(gpa, math.Vec3.init(8.5, 1, 8.5), &rand);
    entities.chickens.items[0].pending_eggs = 1;
    entities.chickens.items[0].pending_feathers = 2;

    const player = Player.spawn(math.Vec3.init(0, 1, 0));
    try entities.tickAnimals(gpa, &w, &player, &rand);

    try std.testing.expectEqual(@as(usize, 3), entities.items.items.len);

    var eggs: u32 = 0;
    var feathers: u32 = 0;
    for (entities.items.items) |item| {
        if (item.stack.id.eql(.{ .item = .egg })) eggs += 1;
        if (item.stack.id.eql(.{ .item = .feather })) feathers += 1;
    }
    try std.testing.expectEqual(@as(u32, 1), eggs);
    try std.testing.expectEqual(@as(u32, 2), feathers);
}

test "a cow killed by the world leaves its hide behind" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(1);
    try entities.spawnCow(gpa, math.Vec3.init(8.5, 1, 8.5));
    entities.cows.items[0].pending_drops = 2;

    const player = Player.spawn(math.Vec3.init(0, 1, 0));
    try entities.tickAnimals(gpa, &w, &player, &rand);

    try std.testing.expectEqual(@as(usize, 2), entities.items.items.len);
    for (entities.items.items) |item| {
        try std.testing.expectEqual(world.Id{ .item = .leather }, item.stack.id);
        try std.testing.expectEqual(@as(u8, 1), item.stack.count);
    }
}

test "the wool a punched sheep loses is left on the ground in its own colour" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(2);
    try entities.spawnSheep(gpa, math.Vec3.init(8.5, 1, 8.5), &rand);
    entities.sheep.items[0].fleece_color = 12;
    _ = entities.sheep.items[0].hurt(1, math.Vec3.init(6, 1, 8), &rand);

    const player = Player.spawn(math.Vec3.init(0, 1, 0));
    try entities.tickAnimals(gpa, &w, &player, &rand);

    try std.testing.expect(entities.items.items.len >= 1 and entities.items.items.len <= 3);
    for (entities.items.items) |item| {
        try std.testing.expectEqual(world.Id{ .block = .wool }, item.stack.id);
        try std.testing.expectEqual(@as(u16, 12), item.stack.meta);
        try std.testing.expectEqual(@as(u8, 1), item.stack.count);
    }
}

test "two herds share one shoving space" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(0);
    try entities.spawnPig(gpa, math.Vec3.init(8.5, 1, 8.5));
    try entities.spawnSheep(gpa, math.Vec3.init(8.6, 1, 8.5), &rand);

    const player = Player.spawn(math.Vec3.init(0, 1, 0));
    try entities.tickAnimals(gpa, &w, &player, &rand);

    try std.testing.expect(entities.pigs.items[0].animal.base.motion.x < 0.0);
    try std.testing.expect(entities.sheep.items[0].animal.base.motion.x > 0.0);
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

    try entities.tickItems(gpa, &w, &player);

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

    try entities.tickItems(gpa, &w, &player);

    try std.testing.expectEqual(@as(usize, 1), entities.items.items.len);
}

test "a torch emits one smoke and one flame from the same point" {
    const gpa = std.testing.allocator;
    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(3);
    try entities.spawnTorchParticles(gpa, 8, 40, 8, 5, &rand);

    try std.testing.expectEqual(@as(usize, 2), entities.particles.items.len);
    try std.testing.expectEqual(Particle.Kind.smoke, entities.particles.items[0].kind);
    try std.testing.expectEqual(Particle.Kind.flame, entities.particles.items[1].kind);
    try std.testing.expectEqual(
        entities.particles.items[0].base.position,
        entities.particles.items[1].base.position,
    );
}

test "a standing torch burns at its own centre, a wall torch out over its bracket" {
    const standing = torchFlamePosition(8, 40, 8, 5);
    try std.testing.expectApproxEqAbs(@as(f64, 8.5), standing.x, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 40.7), standing.y, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 8.5), standing.z, 1.0e-9);
    try std.testing.expectEqual(standing, torchFlamePosition(8, 40, 8, 0));

    const west = torchFlamePosition(8, 40, 8, 1);
    try std.testing.expectApproxEqAbs(@as(f64, 8.23), west.x, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 40.92), west.y, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 8.5), west.z, 1.0e-9);

    try std.testing.expectApproxEqAbs(@as(f64, 8.77), torchFlamePosition(8, 40, 8, 2).x, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 8.23), torchFlamePosition(8, 40, 8, 3).z, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 8.77), torchFlamePosition(8, 40, 8, 4).z, 1.0e-9);
}

test "a torch flame sits above the tip of the model it belongs to" {
    const bounds = world.Block.torch.selectionBounds(5);
    const flame = torchFlamePosition(0, 0, 0, 5);
    try std.testing.expect(flame.y > bounds.max[1]);
    try std.testing.expect(flame.x > bounds.min[0] and flame.x < bounds.max[0]);
}

test "the crosshair picks the animal it is aimed at, and nothing off to the side" {
    const gpa = std.testing.allocator;
    var entities: Entities = .{};
    defer entities.deinit(gpa);

    try entities.spawnCow(gpa, math.Vec3.init(0, 0, 2));
    try entities.spawnPig(gpa, math.Vec3.init(5, 0, 0));

    const eye = math.Vec3.init(0, 1, 0);
    try std.testing.expectEqual(Target{ .cow = 0 }, entities.pick(eye, .{ 0, 0, 1 }, entity_reach).?);
    try std.testing.expect(entities.pick(eye, .{ 0, 0, -1 }, entity_reach) == null);
    try std.testing.expect(entities.pick(eye, .{ 0, 1, 0 }, entity_reach) == null);
}

test "an animal beyond the three block reach is not picked" {
    const gpa = std.testing.allocator;
    var entities: Entities = .{};
    defer entities.deinit(gpa);
    try entities.spawnCow(gpa, math.Vec3.init(0, 0, 6));

    const eye = math.Vec3.init(0, 1, 0);
    try std.testing.expect(entities.pick(eye, .{ 0, 0, 1 }, entity_reach) == null);
    try std.testing.expectEqual(Target{ .cow = 0 }, entities.pick(eye, .{ 0, 0, 1 }, 8.0).?);
}

test "the nearer of two animals in a line is the one picked" {
    const gpa = std.testing.allocator;
    var entities: Entities = .{};
    defer entities.deinit(gpa);

    try entities.spawnCow(gpa, math.Vec3.init(0, 0, 3));
    try entities.spawnPig(gpa, math.Vec3.init(0, 0, 1.5));

    const eye = math.Vec3.init(0, 1, 0);
    try std.testing.expectEqual(Target{ .pig = 0 }, entities.pick(eye, .{ 0, 0, 1 }, entity_reach).?);
}

test "a dead animal is no longer picked" {
    const gpa = std.testing.allocator;
    var entities: Entities = .{};
    defer entities.deinit(gpa);
    try entities.spawnCow(gpa, math.Vec3.init(0, 0, 2));

    const eye = math.Vec3.init(0, 1, 0);
    try std.testing.expect(entities.pick(eye, .{ 0, 0, 1 }, entity_reach) != null);

    entities.cows.items[0].animal.health = 0;
    try std.testing.expect(entities.pick(eye, .{ 0, 0, 1 }, entity_reach) == null);
}

test "a hit takes health off the animal the crosshair found" {
    const gpa = std.testing.allocator;
    var entities: Entities = .{};
    defer entities.deinit(gpa);
    var rand = world.JavaRandom.init(0);

    try entities.spawnCow(gpa, math.Vec3.init(0, 0, 2));
    const before = entities.cows.items[0].animal.health;

    entities.hurtTarget(.{ .cow = 0 }, 4, math.Vec3.init(0, 1, 0), &rand);
    try std.testing.expectEqual(before - 4, entities.cows.items[0].animal.health);
}

test "hitting a sheep shears it, as only EntitySheep overrides being attacked" {
    const gpa = std.testing.allocator;
    var entities: Entities = .{};
    defer entities.deinit(gpa);
    var rand = world.JavaRandom.init(0);

    try entities.spawnSheep(gpa, math.Vec3.init(0, 0, 2), &rand);
    try std.testing.expect(!entities.sheep.items[0].sheared);

    entities.hurtTarget(.{ .sheep = 0 }, 1, math.Vec3.init(0, 1, 0), &rand);
    try std.testing.expect(entities.sheep.items[0].sheared);
}

test "a painting whose wall is gone falls as an item where it hung" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();
    try w.setBlockWithNotify(8, 4, 8, .stone);

    var entities: Entities = .{};
    defer entities.deinit(gpa);
    const hung = Painting.place(.{ 8, 4, 8 }, 0, .kebab);
    try entities.spawnPainting(gpa, hung);

    var rand = world.JavaRandom.init(7);
    for (0..Painting.recheck_ticks * 2) |_| {
        try entities.tickPaintings(gpa, &w, &rand);
    }
    try std.testing.expectEqual(@as(usize, 1), entities.paintings.items.len);
    try std.testing.expectEqual(@as(usize, 0), entities.items.items.len);

    try w.setBlockWithNotify(8, 4, 8, .air);
    for (0..Painting.recheck_ticks * 2) |_| {
        try entities.tickPaintings(gpa, &w, &rand);
    }
    try std.testing.expectEqual(@as(usize, 0), entities.paintings.items.len);
    try std.testing.expectEqual(@as(usize, 1), entities.items.items.len);

    const dropped = entities.items.items[0];
    try std.testing.expectEqual(world.Id{ .item = .painting }, dropped.stack.id);
    try std.testing.expectApproxEqAbs(hung.position.x, dropped.base.position.x, 1.0e-6);
    try std.testing.expectApproxEqAbs(hung.position.z, dropped.base.position.z, 1.0e-6);
}
