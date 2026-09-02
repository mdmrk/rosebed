const std = @import("std");

const assets = @import("assets");
const math = @import("math");
const world = @import("world");

const achievements = @import("achievements.zig");
const Entity = @import("Entity.zig");
const Animal = @import("entity/Animal.zig");
const Arrow = @import("entity/Arrow.zig");
const Boat = @import("entity/Boat.zig");
const Chicken = @import("entity/Chicken.zig");
const Cow = @import("entity/Cow.zig");
const Creeper = @import("entity/Creeper.zig");
const FallingBlock = @import("entity/FallingBlock.zig");
const Fireball = @import("entity/Fireball.zig");
const FishHook = @import("entity/FishHook.zig");
const Ghast = @import("entity/Ghast.zig");
const ItemEntity = @import("entity/ItemEntity.zig");
const Lightning = @import("entity/Lightning.zig");
const Minecart = @import("entity/Minecart.zig");
const Painting = @import("entity/Painting.zig");
const Particle = @import("entity/Particle.zig");
const PickupFx = @import("entity/PickupFx.zig");
const Pig = @import("entity/Pig.zig");
const PigZombie = @import("entity/PigZombie.zig");
const PrimedTnt = @import("entity/PrimedTnt.zig");
const Sheep = @import("entity/Sheep.zig");
const Skeleton = @import("entity/Skeleton.zig");
const Slime = @import("entity/Slime.zig");
const Spider = @import("entity/Spider.zig");
const Thrown = @import("entity/Thrown.zig");
const Wolf = @import("entity/Wolf.zig");
const Zombie = @import("entity/Zombie.zig");
const explosion = @import("explosion.zig");
const Inventory = @import("Inventory.zig");
const mob = @import("mob.zig");
pub const lightning_pig_zombie = mob.pig_zombie;
const physics = @import("physics.zig");
const Player = @import("Player.zig");

const Entities = @This();

items: std.ArrayList(ItemEntity) = .empty,
arrows: std.ArrayList(Arrow) = .empty,
fireballs: std.ArrayList(Fireball) = .empty,
thrown: std.ArrayList(Thrown) = .empty,
falling_blocks: std.ArrayList(FallingBlock) = .empty,
primed: std.ArrayList(PrimedTnt) = .empty,
mobs: std.ArrayList(Mob) = .empty,
particles: std.ArrayList(Particle) = .empty,
pickups: std.ArrayList(PickupFx) = .empty,
paintings: std.ArrayList(Painting) = .empty,
boats: std.ArrayList(Boat) = .empty,
minecarts: std.ArrayList(Minecart) = .empty,
hooks: std.ArrayList(FishHook) = .empty,
bolts: std.ArrayList(Lightning) = .empty,
struck: std.ArrayList(Struck) = .empty,
collected: std.ArrayList(Collected) = .empty,
blasts: std.ArrayList(Blast) = .empty,
blast_blocks: std.ArrayList([3]i8) = .empty,
next_entity_id: Entity.Id = 1,

pub const Collected = struct {
    item: Entity.Id,
    by: Entity.Id,
};

pub const Struck = struct {
    id: Entity.Id,
    at: math.Vec3,
};

pub const Blast = struct {
    at: math.Vec3,
    size: f32,
    first: usize,
    count: usize,
};

pub fn recordBlast(
    self: *Entities,
    gpa: std.mem.Allocator,
    at: math.Vec3,
    size: f32,
    broken: []const world.World.BlockPos,
) !void {
    const origin: [3]i32 = .{
        @intFromFloat(at.x),
        @intFromFloat(at.y),
        @intFromFloat(at.z),
    };
    const start = self.blast_blocks.items.len;

    for (broken) |pos| {
        const dx = pos.x - origin[0];
        const dy = pos.y - origin[1];
        const dz = pos.z - origin[2];
        if (dx < -128 or dx > 127 or dy < -128 or dy > 127 or dz < -128 or dz > 127) continue;
        try self.blast_blocks.append(gpa, .{
            @intCast(dx),
            @intCast(dy),
            @intCast(dz),
        });
    }

    try self.blasts.append(gpa, .{
        .at = at,
        .size = size,
        .first = start,
        .count = self.blast_blocks.items.len - start,
    });
}

pub fn clearBlasts(self: *Entities) void {
    self.blasts.clearRetainingCapacity();
    self.blast_blocks.clearRetainingCapacity();
}

pub const Mob = struct {
    type_id: mob.Id,
    animal: *Animal,
};

pub const Target = union(enum) {
    mob: Entity.Id,
    painting: Entity.Id,
    boat: Entity.Id,
    minecart: Entity.Id,
};

pub fn Iterator(comptime T: type) type {
    return struct {
        mobs: []const Mob,
        type_id: mob.Id,
        index: usize = 0,

        pub fn next(self: *@This()) ?*T {
            while (self.index < self.mobs.len) {
                const entry = self.mobs[self.index];
                self.index += 1;
                if (entry.type_id != self.type_id) continue;
                return @fieldParentPtr("animal", entry.animal);
            }
            return null;
        }
    };
}

pub fn of(self: *const Entities, comptime T: type, type_id: mob.Id) Iterator(T) {
    return .{ .mobs = self.mobs.items, .type_id = type_id };
}

pub fn takeId(self: *Entities) Entity.Id {
    const id = self.next_entity_id;
    self.next_entity_id += 1;
    return id;
}

pub fn stampIds(self: *Entities) void {
    inline for (.{ "items", "arrows", "fireballs", "thrown", "falling_blocks", "primed", "boats", "minecarts", "hooks" }) |name| {
        for (@field(self, name).items) |*entity| {
            if (entity.base.id == Entity.no_id) entity.base.id = self.takeId();
        }
    }
    for (self.paintings.items) |*hung| {
        if (hung.id == Entity.no_id) hung.id = self.takeId();
    }
}

pub fn mobById(self: *const Entities, id: Entity.Id) ?Mob {
    for (self.mobs.items) |entry| {
        if (entry.animal.base.id == id) return entry;
    }
    return null;
}

pub fn mobAt(self: *const Entities, target: Target) ?Mob {
    return switch (target) {
        .mob => |id| self.mobById(id),
        .painting, .boat, .minecart => null,
    };
}

pub fn boatById(self: *Entities, id: Entity.Id) ?*Boat {
    for (self.boats.items) |*boat| {
        if (boat.base.id == id and !boat.dead) return boat;
    }
    return null;
}

pub fn hookOf(self: *Entities, angler: Entity.Id) ?*FishHook {
    for (self.hooks.items) |*hook| {
        if (hook.angler == angler and !hook.dead) return hook;
    }
    return null;
}

pub fn castHook(self: *Entities, gpa: std.mem.Allocator, player: *const Player, rand: *world.JavaRandom) !void {
    var hook = FishHook.castBy(player.*, rand);
    hook.base.id = self.takeId();
    try self.hooks.append(gpa, hook);
}

pub fn tickHooks(
    self: *Entities,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    roster: []const *Player,
    rand: *world.JavaRandom,
) !void {
    var index: usize = 0;
    while (index < self.hooks.items.len) {
        const hook = &self.hooks.items[index];
        const angler = playerById(roster, hook.angler);

        if (hook.base.remote == null and
            (angler == null or angler.?.health <= 0 or hook.outOfRange(angler.?.base.position)))
        {
            _ = self.hooks.swapRemove(index);
            continue;
        }

        const step = hook.tick(world_map, rand);
        if (step.bit) {
            for (0..bite_splashes) |_| {
                try self.particles.append(gpa, Particle.spawnSplash(hook.base.position, hook.base.motion, rand));
            }
        }

        if (hook.dead) {
            _ = self.hooks.swapRemove(index);
            continue;
        }
        index += 1;
    }
}

const bite_splashes: usize = 6;

pub fn reelHook(
    self: *Entities,
    gpa: std.mem.Allocator,
    angler: *const Player,
    rand: *world.JavaRandom,
) !?FishHook.Catch {
    const hook = self.hookOf(angler.base.id) orelse return null;
    const at = hook.base.position;
    const toss = hook.pullToward(angler.base.position);
    const caught = hook.reelIn();

    if (caught == .fish) {
        var fish = ItemEntity.spawn(at, .{ .id = .{ .item = .fish_raw }, .count = 1 }, rand);
        fish.base.motion = toss;
        fish.pickup_delay = 0;
        try self.items.append(gpa, fish);
    }

    var index: usize = 0;
    while (index < self.hooks.items.len) : (index += 1) {
        if (self.hooks.items[index].dead) {
            _ = self.hooks.swapRemove(index);
            break;
        }
    }
    return caught;
}

pub fn minecartById(self: *Entities, id: Entity.Id) ?*Minecart {
    for (self.minecarts.items) |*cart| {
        if (cart.base.id == id and !cart.dead) return cart;
    }
    return null;
}

pub fn spawnMinecart(
    self: *Entities,
    gpa: std.mem.Allocator,
    position: math.Vec3,
    kind: Minecart.Kind,
) !Entity.Id {
    var cart = Minecart.spawn(.{ .x = position.x, .y = position.y - Minecart.y_offset, .z = position.z }, kind);
    cart.base.id = self.takeId();
    try self.minecarts.append(gpa, cart);
    return cart.base.id;
}

pub fn spawnBoat(self: *Entities, gpa: std.mem.Allocator, position: math.Vec3) !Entity.Id {
    var boat = Boat.spawn(position);
    boat.base.id = self.takeId();
    try self.boats.append(gpa, boat);
    return boat.base.id;
}

pub fn removePainting(self: *Entities, id: Entity.Id) ?Painting {
    for (self.paintings.items, 0..) |painting, index| {
        if (painting.id == id) return self.paintings.orderedRemove(index);
    }
    return null;
}

pub fn first(self: *const Entities, comptime T: type, type_id: mob.Id) ?*T {
    var iterator = self.of(T, type_id);
    return iterator.next();
}

pub fn countOf(self: *const Entities, type_id: mob.Id) usize {
    var total: usize = 0;
    for (self.mobs.items) |entry| {
        if (entry.type_id == type_id) total += 1;
    }
    return total;
}

pub fn spawnMob(
    self: *Entities,
    gpa: std.mem.Allocator,
    type_id: mob.Id,
    position: math.Vec3,
    rand: *world.JavaRandom,
) !*Animal {
    const animal = try mob.get(type_id).spawn(gpa, position, rand);
    errdefer mob.get(type_id).destroy(animal, gpa);
    animal.base.id = self.takeId();
    try self.mobs.append(gpa, .{ .type_id = type_id, .animal = animal });
    return animal;
}

pub fn adoptMob(self: *Entities, gpa: std.mem.Allocator, type_id: mob.Id, animal: *Animal) !void {
    return self.adoptMobAs(gpa, type_id, animal, self.takeId());
}

pub fn adoptMobAs(
    self: *Entities,
    gpa: std.mem.Allocator,
    type_id: mob.Id,
    animal: *Animal,
    id: Entity.Id,
) !void {
    animal.base.id = id;
    try self.mobs.append(gpa, .{ .type_id = type_id, .animal = animal });
}

pub fn removeMob(self: *Entities, gpa: std.mem.Allocator, id: Entity.Id) bool {
    for (self.mobs.items, 0..) |entry, index| {
        if (entry.animal.base.id != id) continue;
        _ = self.mobs.orderedRemove(index);
        mob.get(entry.type_id).destroy(entry.animal, gpa);
        return true;
    }
    return false;
}

pub fn removeById(self: *Entities, gpa: std.mem.Allocator, id: Entity.Id) bool {
    if (self.removeMob(gpa, id)) return true;

    inline for (.{ "items", "arrows", "fireballs", "thrown", "falling_blocks", "primed", "boats", "minecarts", "hooks" }) |name| {
        const list = &@field(self, name);
        for (list.items, 0..) |entity, index| {
            if (entity.base.id != id) continue;
            _ = list.orderedRemove(index);
            return true;
        }
    }
    for (self.paintings.items, 0..) |hung, index| {
        if (hung.id != id) continue;
        _ = self.paintings.orderedRemove(index);
        return true;
    }
    return false;
}

pub fn adopt(self: *Entities, gpa: std.mem.Allocator, type_id: mob.Id, value: anytype) !void {
    return self.adoptAs(gpa, type_id, value, self.takeId());
}

pub fn adoptAs(
    self: *Entities,
    gpa: std.mem.Allocator,
    type_id: mob.Id,
    value: anytype,
    id: Entity.Id,
) !void {
    const held = try gpa.create(@TypeOf(value));
    errdefer gpa.destroy(held);
    held.* = value;
    try self.adoptMobAs(gpa, type_id, &held.animal, id);
}

pub const entity_reach: f64 = 3.0;
const collision_border: f64 = 0.1;

fn boxRayDistance(box: math.Aabb, from: math.Vec3, direction: math.Vec3, reach: f64) ?f64 {
    var entry: f64 = 0;
    var exit = reach;

    const origin = [3]f64{ from.x, from.y, from.z };
    const along = [3]f64{ direction.x, direction.y, direction.z };

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

fn boxHolds(box: math.Aabb, point: math.Vec3) bool {
    return point.x >= box.min_x and point.x <= box.max_x and
        point.y >= box.min_y and point.y <= box.max_y and
        point.z >= box.min_z and point.z <= box.max_z;
}

pub fn pick(self: *Entities, origin: math.Vec3, look: [3]f32, reach: f64) ?Target {
    const start = origin;
    const along = math.Vec3.init(look[0], look[1], look[2]);

    var found: ?Target = null;
    var nearest: f64 = 0;

    for (self.paintings.items) |painting| {
        const target: Target = .{ .painting = painting.id };
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

    for (self.minecarts.items) |cart| {
        if (cart.dead) continue;

        const box = cart.base.boundingBox().expand(collision_border, collision_border, collision_border);
        const target: Target = .{ .minecart = cart.base.id };
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

    for (self.boats.items) |boat| {
        if (boat.dead) continue;

        const box = boat.base.boundingBox().expand(collision_border, collision_border, collision_border);
        const target: Target = .{ .boat = boat.base.id };
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

    for (self.mobs.items) |entry| {
        if (!entry.animal.isAlive()) continue;

        const box = entry.animal.base.boundingBox().expand(collision_border, collision_border, collision_border);
        const target: Target = .{ .mob = entry.animal.base.id };

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

    return found;
}

pub fn hurtTarget(self: *Entities, world_map: *const world.World, target: Target, amount: i32, source: ?Animal.Attacker, rand: *world.JavaRandom) bool {
    return switch (target) {
        .mob => |id| {
            const entry = self.mobById(id) orelse return false;
            const hit = mob.get(entry.type_id).hurt(entry.animal, world_map, amount, source, rand);
            if (hit and entry.animal.isAlive()) {
                if (source) |from| Wolf.alertOwned(self, from, entry.animal, true);
            }
            return hit;
        },
        .painting => false,
        .boat => |id| (self.boatById(id) orelse return false).hurt(amount),
        .minecart => |id| (self.minecartById(id) orelse return false).hurt(amount),
    };
}

pub fn playerById(roster: []const *Player, id: Entity.Id) ?*Player {
    for (roster) |player| {
        if (player.base.id == id) return player;
    }
    return null;
}

pub fn viewOf(player: *const Player) Animal.PlayerView {
    const held: ?world.Item = if (player.inventory.selectedStack()) |stack| switch (stack.id) {
        .item => |id| id,
        .block => null,
    } else null;

    return .{
        .id = player.base.id,
        .position = player.base.position,
        .eye_height = Player.eye_height,
        .alive = player.health > 0,
        .height = Player.height,
        .held = held,
        .name = player.name.text(),
    };
}

pub fn deinit(self: *Entities, gpa: std.mem.Allocator) void {
    self.items.deinit(gpa);
    self.arrows.deinit(gpa);
    self.fireballs.deinit(gpa);
    self.thrown.deinit(gpa);
    self.falling_blocks.deinit(gpa);
    self.primed.deinit(gpa);
    self.particles.deinit(gpa);
    self.pickups.deinit(gpa);
    self.paintings.deinit(gpa);
    self.boats.deinit(gpa);
    self.minecarts.deinit(gpa);
    self.hooks.deinit(gpa);
    self.bolts.deinit(gpa);
    self.struck.deinit(gpa);
    self.collected.deinit(gpa);
    self.blasts.deinit(gpa);
    self.blast_blocks.deinit(gpa);
    for (self.mobs.items) |entry| mob.get(entry.type_id).destroy(entry.animal, gpa);
    self.mobs.deinit(gpa);
}

pub fn animalCount(self: *const Entities) usize {
    return self.countOf(mob.pig) + self.countOf(mob.sheep) + self.countOf(mob.cow) +
        self.countOf(mob.chicken) + self.countOf(mob.wolf);
}

pub fn count(self: *const Entities) usize {
    return self.items.items.len + self.arrows.items.len + self.fireballs.items.len +
        self.thrown.items.len + self.falling_blocks.items.len + self.paintings.items.len +
        self.boats.items.len + self.minecarts.items.len + self.mobs.items.len;
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

const shear_drop_lift: f64 = 1.0;

pub fn dropShearedWool(
    self: *Entities,
    gpa: std.mem.Allocator,
    sheep: *const Sheep,
    drops: Sheep.Drops,
    rand: *world.JavaRandom,
) !void {
    const position = sheep.animal.base.position.add(math.Vec3.init(0, shear_drop_lift, 0));
    for (0..drops.count) |_| {
        var wool = ItemEntity.spawn(position, drops.stack(), rand);
        wool.base.motion.y += @as(f32, rand.nextFloat() * 0.05);
        wool.base.motion.x += @as(f32, (rand.nextFloat() - rand.nextFloat()) * 0.1);
        wool.base.motion.z += @as(f32, (rand.nextFloat() - rand.nextFloat()) * 0.1);
        try self.items.append(gpa, wool);
    }
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

const dispense_reach: f64 = 0.6;
const dispense_drop: f64 = 0.3;
const dispense_lift: f64 = 0.2;
const dispense_spread: f64 = 0.0075 * 6.0;
const dispense_shot_speed: f32 = 1.1;
const dispense_shot_spread: f32 = 6.0;
const dispense_shot_lift: f64 = 0.1;
const dispense_puffs = 10;
const dispense_puff_sink: f64 = -0.03;

pub fn thrownKind(item: ?world.Item) ?Thrown.Kind {
    return switch (item orelse return null) {
        .egg => .egg,
        .snowball => .snowball,
        else => null,
    };
}

pub fn dispense(
    self: *Entities,
    gpa: std.mem.Allocator,
    shot: world.World.Dispensed,
    rand: *world.JavaRandom,
) !void {
    const dx: f64 = @floatFromInt(shot.step[0]);
    const dz: f64 = @floatFromInt(shot.step[1]);
    const muzzle = math.Vec3.init(
        @as(f64, @floatFromInt(shot.pos.x)) + dx * dispense_reach + 0.5,
        @as(f64, @floatFromInt(shot.pos.y)) + 0.5,
        @as(f64, @floatFromInt(shot.pos.z)) + dz * dispense_reach + 0.5,
    );

    const shot_item: ?world.Item = switch (shot.stack.id) {
        .item => |id| switch (id) {
            .arrow, .egg, .snowball => id,
            else => null,
        },
        .block => null,
    };
    const heading = math.Vec3.init(dx, dispense_shot_lift, dz);

    if (shot_item == .arrow) {
        var arrow = Arrow.loosedBy(
            Entity.no_id,
            muzzle,
            heading,
            dispense_shot_speed,
            dispense_shot_spread,
            rand,
        );
        arrow.from_player = true;
        try self.arrows.append(gpa, arrow);
    } else if (thrownKind(shot_item)) |kind| {
        try self.thrown.append(gpa, Thrown.dispensedFrom(
            kind,
            muzzle,
            heading,
            dispense_shot_speed,
            dispense_shot_spread,
            rand,
        ));
    } else {
        const launched = math.Vec3.init(muzzle.x, muzzle.y - dispense_drop, muzzle.z);
        var item = ItemEntity.spawn(launched, .{
            .id = shot.stack.id,
            .count = shot.stack.count,
            .meta = shot.stack.meta,
        }, rand);

        item.pickup_delay = 0;
        const speed = rand.nextDouble() * 0.1 + 0.2;
        item.base.motion = .{
            .x = dx * speed + rand.nextGaussian() * dispense_spread,
            .y = dispense_lift + rand.nextGaussian() * dispense_spread,
            .z = dz * speed + rand.nextGaussian() * dispense_spread,
        };
        try self.items.append(gpa, item);
    }

    try self.puffDispenserSmoke(gpa, muzzle, dx, dz, rand);
}

fn puffDispenserSmoke(
    self: *Entities,
    gpa: std.mem.Allocator,
    muzzle: math.Vec3,
    dx: f64,
    dz: f64,
    rand: *world.JavaRandom,
) !void {
    for (0..dispense_puffs) |_| {
        const speed = rand.nextDouble() * 0.2 + 0.01;
        const at = math.Vec3.init(
            muzzle.x + dx * 0.01 + (rand.nextDouble() - 0.5) * dz * 0.5,
            muzzle.y + (rand.nextDouble() - 0.5) * 0.5,
            muzzle.z + dz * 0.01 + (rand.nextDouble() - 0.5) * dx * 0.5,
        );
        const drift = math.Vec3.init(
            dx * speed + rand.nextGaussian() * 0.01,
            dispense_puff_sink + rand.nextGaussian() * 0.01,
            dz * speed + rand.nextGaussian() * 0.01,
        );
        try self.particles.append(gpa, Particle.spawnSmoke(at, drift, rand));
    }
}

pub fn ejectRecord(
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
        @as(f64, @floatFromInt(y)) + @as(f64, rand.nextFloat()) * 0.7 + 0.66,
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
    var hung = painting;
    hung.id = self.takeId();
    try self.paintings.append(gpa, hung);
}

pub fn primeTnt(
    self: *Entities,
    gpa: std.mem.Allocator,
    lit: world.World.PrimedTnt,
    rand: *world.JavaRandom,
) !void {
    try self.primed.append(gpa, PrimedTnt.spawnInBlock(lit.pos.x, lit.pos.y, lit.pos.z, lit.fuse, rand));
}

pub fn tickPrimed(
    self: *Entities,
    gpa: std.mem.Allocator,
    world_map: *world.World,
    roster: []const *Player,
    rand: *world.JavaRandom,
) !void {
    var index: usize = 0;
    while (index < self.primed.items.len) {
        const lit = &self.primed.items[index];
        const outcome = lit.tick(world_map);

        if (outcome == .burning) {
            try self.particles.append(gpa, Particle.spawnSmoke(
                lit.smokePosition(),
                math.Vec3.init(0, 0, 0),
                rand,
            ));
            index += 1;
            continue;
        }

        const at = lit.blastPosition();
        const owned_here = lit.base.remote == null;
        _ = self.primed.swapRemove(index);
        if (!owned_here) continue;

        try explosion.detonate(
            gpa,
            self,
            world_map,
            roster,
            at,
            PrimedTnt.explosion_size,
            PrimedTnt.explosion_is_flaming,
            rand,
        );
    }
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
const full_cube: world.block.Bounds = .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 1 } };
pub const hit_slowdown: f32 = 0.2;
pub const hit_shrink: f32 = 0.6;

pub fn spawnBlockHitParticle(
    self: *Entities,
    gpa: std.mem.Allocator,
    x: i32,
    y: i32,
    z: i32,
    side: world.Side,
    bounds: world.block.Bounds,
    tile: u8,
    tint: [3]u8,
    rand: *world.JavaRandom,
) !void {
    const low = [3]f64{ bounds.min[0], bounds.min[1], bounds.min[2] };
    const high = [3]f64{ bounds.max[0], bounds.max[1], bounds.max[2] };

    var spread: [3]f64 = undefined;
    for (0..3) |axis| {
        spread[axis] = rand.nextDouble() * (high[axis] - low[axis] - hit_inset * 2.0) + hit_inset + low[axis];
    }

    var px = @as(f64, @floatFromInt(x)) + spread[0];
    var py = @as(f64, @floatFromInt(y)) + spread[1];
    var pz = @as(f64, @floatFromInt(z)) + spread[2];

    switch (side) {
        world.Side.down => py = @as(f64, @floatFromInt(y)) + low[1] - hit_inset,
        world.Side.up => py = @as(f64, @floatFromInt(y)) + high[1] + hit_inset,
        world.Side.north => pz = @as(f64, @floatFromInt(z)) + low[2] - hit_inset,
        world.Side.south => pz = @as(f64, @floatFromInt(z)) + high[2] + hit_inset,
        world.Side.west => px = @as(f64, @floatFromInt(x)) + low[0] - hit_inset,
        world.Side.east => px = @as(f64, @floatFromInt(x)) + high[0] + hit_inset,
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

pub const torch_burnout_particles = 5;
const torch_burnout_spread: f64 = 0.6;
const torch_burnout_inset: f64 = 0.2;

pub fn spawnTorchBurnoutSmoke(
    self: *Entities,
    gpa: std.mem.Allocator,
    x: i32,
    y: i32,
    z: i32,
    rand: *world.JavaRandom,
) !void {
    for (0..torch_burnout_particles) |_| {
        const px = @as(f64, @floatFromInt(x)) + rand.nextDouble() * torch_burnout_spread + torch_burnout_inset;
        const py = @as(f64, @floatFromInt(y)) + rand.nextDouble() * torch_burnout_spread + torch_burnout_inset;
        const pz = @as(f64, @floatFromInt(z)) + rand.nextDouble() * torch_burnout_spread + torch_burnout_inset;
        try self.particles.append(gpa, Particle.spawnSmoke(
            math.Vec3.init(px, py, pz),
            math.Vec3.init(0, 0, 0),
            rand,
        ));
    }
}

pub const fire_standing_particles = 3;
pub const fire_edge_particles = 2;
const fire_edge_inset: f64 = 0.1;

pub fn spawnFireParticles(
    self: *Entities,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    x: i32,
    y: i32,
    z: i32,
    rand: *world.JavaRandom,
) !void {
    const fx: f64 = @floatFromInt(x);
    const fy: f64 = @floatFromInt(y);
    const fz: f64 = @floatFromInt(z);
    const still = math.Vec3.init(0, 0, 0);

    const below = world_map.getBlock(x, y - 1, z);
    if (!below.isNormalCube() and !below.isFlammable()) {
        if (world_map.getBlock(x - 1, y, z).isFlammable()) {
            for (0..fire_edge_particles) |_| {
                try self.particles.append(gpa, Particle.spawnLargeSmoke(math.Vec3.init(
                    fx + @as(f64, rand.nextFloat()) * fire_edge_inset,
                    fy + @as(f64, rand.nextFloat()),
                    fz + @as(f64, rand.nextFloat()),
                ), still, rand));
            }
        }
        if (world_map.getBlock(x + 1, y, z).isFlammable()) {
            for (0..fire_edge_particles) |_| {
                try self.particles.append(gpa, Particle.spawnLargeSmoke(math.Vec3.init(
                    fx + 1.0 - @as(f64, rand.nextFloat()) * fire_edge_inset,
                    fy + @as(f64, rand.nextFloat()),
                    fz + @as(f64, rand.nextFloat()),
                ), still, rand));
            }
        }
        if (world_map.getBlock(x, y, z - 1).isFlammable()) {
            for (0..fire_edge_particles) |_| {
                try self.particles.append(gpa, Particle.spawnLargeSmoke(math.Vec3.init(
                    fx + @as(f64, rand.nextFloat()),
                    fy + @as(f64, rand.nextFloat()),
                    fz + @as(f64, rand.nextFloat()) * fire_edge_inset,
                ), still, rand));
            }
        }
        if (world_map.getBlock(x, y, z + 1).isFlammable()) {
            for (0..fire_edge_particles) |_| {
                try self.particles.append(gpa, Particle.spawnLargeSmoke(math.Vec3.init(
                    fx + @as(f64, rand.nextFloat()),
                    fy + @as(f64, rand.nextFloat()),
                    fz + 1.0 - @as(f64, rand.nextFloat()) * fire_edge_inset,
                ), still, rand));
            }
        }
        if (world_map.getBlock(x, y + 1, z).isFlammable()) {
            for (0..fire_edge_particles) |_| {
                try self.particles.append(gpa, Particle.spawnLargeSmoke(math.Vec3.init(
                    fx + @as(f64, rand.nextFloat()),
                    fy + 1.0 - @as(f64, rand.nextFloat()) * fire_edge_inset,
                    fz + @as(f64, rand.nextFloat()),
                ), still, rand));
            }
        }
        return;
    }

    for (0..fire_standing_particles) |_| {
        try self.particles.append(gpa, Particle.spawnLargeSmoke(math.Vec3.init(
            fx + @as(f64, rand.nextFloat()),
            fy + @as(f64, rand.nextFloat()) * 0.5 + 0.5,
            fz + @as(f64, rand.nextFloat()),
        ), still, rand));
    }
}

pub const portal_particles_per_tick = 4;
const portal_drift_spread: f64 = 0.5;
const portal_mouth_inset: f64 = 0.25;
const portal_ejection_speed: f64 = 2.0;

pub fn spawnPortalParticles(
    self: *Entities,
    gpa: std.mem.Allocator,
    x: i32,
    y: i32,
    z: i32,
    spans_x: bool,
    rand: *world.JavaRandom,
) !void {
    for (0..portal_particles_per_tick) |_| {
        var px = @as(f64, @floatFromInt(x)) + @as(f64, rand.nextFloat());
        const py = @as(f64, @floatFromInt(y)) + @as(f64, rand.nextFloat());
        var pz = @as(f64, @floatFromInt(z)) + @as(f64, rand.nextFloat());

        const side: f64 = @floatFromInt(rand.nextIntBound(2) * 2 - 1);
        var dx = (@as(f64, rand.nextFloat()) - 0.5) * portal_drift_spread;
        const dy = (@as(f64, rand.nextFloat()) - 0.5) * portal_drift_spread;
        var dz = (@as(f64, rand.nextFloat()) - 0.5) * portal_drift_spread;

        if (spans_x) {
            pz = @as(f64, @floatFromInt(z)) + 0.5 + portal_mouth_inset * side;
            dz = @as(f64, rand.nextFloat()) * portal_ejection_speed * side;
        } else {
            px = @as(f64, @floatFromInt(x)) + 0.5 + portal_mouth_inset * side;
            dx = @as(f64, rand.nextFloat()) * portal_ejection_speed * side;
        }

        try self.particles.append(gpa, Particle.spawnPortal(
            math.Vec3.init(px, py, pz),
            math.Vec3.init(dx, dy, dz),
            rand,
        ));
    }
}

pub const reddust_jitter: f64 = 0.2;
pub const redstone_torch_height: f64 = 0.7;
pub const repeater_dust_height: f64 = 0.4;
pub const repeater_lock_reach: f64 = 0.3125;
pub const ore_dust_samples: usize = 6;
pub const ore_dust_lift: f64 = 1.0 / 16.0;

fn jittered(value: f64, rand: *world.JavaRandom) f64 {
    return value + (@as(f64, rand.nextFloat()) - 0.5) * reddust_jitter;
}

pub fn spawnWireParticles(
    self: *Entities,
    gpa: std.mem.Allocator,
    x: i32,
    y: i32,
    z: i32,
    metadata: u4,
    rand: *world.JavaRandom,
) !void {
    if (metadata == 0) return;

    const position = math.Vec3.init(
        jittered(@as(f64, @floatFromInt(x)) + 0.5, rand),
        @as(f64, @floatFromInt(y)) + 1.0 / 16.0,
        jittered(@as(f64, @floatFromInt(z)) + 0.5, rand),
    );

    const level = @as(f32, @floatFromInt(metadata)) / 15.0;
    const color: [3]f32 = .{
        level * 0.6 + 0.4,
        @max(0.0, level * level * 0.7 - 0.5),
        @max(0.0, level * level * 0.6 - 0.7),
    };
    try self.particles.append(gpa, Particle.spawnReddust(position, color, rand));
}

pub fn spawnRedstoneTorchParticles(
    self: *Entities,
    gpa: std.mem.Allocator,
    x: i32,
    y: i32,
    z: i32,
    metadata: u4,
    rand: *world.JavaRandom,
) !void {
    const centre_x = jittered(@as(f64, @floatFromInt(x)) + 0.5, rand);
    const centre_y = jittered(@as(f64, @floatFromInt(y)) + redstone_torch_height, rand);
    const centre_z = jittered(@as(f64, @floatFromInt(z)) + 0.5, rand);

    const position = switch (metadata) {
        1 => math.Vec3.init(centre_x - torch_wall_reach, centre_y + torch_wall_lift, centre_z),
        2 => math.Vec3.init(centre_x + torch_wall_reach, centre_y + torch_wall_lift, centre_z),
        3 => math.Vec3.init(centre_x, centre_y + torch_wall_lift, centre_z - torch_wall_reach),
        4 => math.Vec3.init(centre_x, centre_y + torch_wall_lift, centre_z + torch_wall_reach),
        else => math.Vec3.init(centre_x, centre_y, centre_z),
    };
    try self.particles.append(gpa, Particle.spawnReddust(position, .{ 0, 0, 0 }, rand));
}

pub fn spawnRepeaterParticles(
    self: *Entities,
    gpa: std.mem.Allocator,
    x: i32,
    y: i32,
    z: i32,
    metadata: u4,
    rand: *world.JavaRandom,
) !void {
    const centre_x = jittered(@as(f64, @floatFromInt(x)) + 0.5, rand);
    const centre_y = jittered(@as(f64, @floatFromInt(y)) + repeater_dust_height, rand);
    const centre_z = jittered(@as(f64, @floatFromInt(z)) + 0.5, rand);

    var along: f64 = 0;
    var across: f64 = 0;
    if (rand.nextIntBound(2) == 0) {
        switch (world.block.repeaterFacing(metadata)) {
            0 => across = -repeater_lock_reach,
            1 => along = repeater_lock_reach,
            2 => across = repeater_lock_reach,
            3 => along = -repeater_lock_reach,
        }
    } else {
        const offset: f64 = world.block.repeater_torch_offsets[world.block.repeaterDelay(metadata)];
        switch (world.block.repeaterFacing(metadata)) {
            0 => across = offset,
            1 => along = -offset,
            2 => across = -offset,
            3 => along = offset,
        }
    }

    const position = math.Vec3.init(centre_x + along, centre_y, centre_z + across);
    try self.particles.append(gpa, Particle.spawnReddust(position, .{ 0, 0, 0 }, rand));
}

pub fn spawnRedstoneOreParticles(
    self: *Entities,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    x: i32,
    y: i32,
    z: i32,
    rand: *world.JavaRandom,
) !void {
    for (0..ore_dust_samples) |sample| {
        var px = @as(f64, @floatFromInt(x)) + @as(f64, rand.nextFloat());
        var py = @as(f64, @floatFromInt(y)) + @as(f64, rand.nextFloat());
        var pz = @as(f64, @floatFromInt(z)) + @as(f64, rand.nextFloat());

        switch (sample) {
            0 => if (!world_map.getBlock(x, y + 1, z).isOpaqueCube()) {
                py = @as(f64, @floatFromInt(y + 1)) + ore_dust_lift;
            },
            1 => if (!world_map.getBlock(x, y - 1, z).isOpaqueCube()) {
                py = @as(f64, @floatFromInt(y)) - ore_dust_lift;
            },
            2 => if (!world_map.getBlock(x, y, z + 1).isOpaqueCube()) {
                pz = @as(f64, @floatFromInt(z + 1)) + ore_dust_lift;
            },
            3 => if (!world_map.getBlock(x, y, z - 1).isOpaqueCube()) {
                pz = @as(f64, @floatFromInt(z)) - ore_dust_lift;
            },
            4 => if (!world_map.getBlock(x + 1, y, z).isOpaqueCube()) {
                px = @as(f64, @floatFromInt(x + 1)) + ore_dust_lift;
            },
            else => if (!world_map.getBlock(x - 1, y, z).isOpaqueCube()) {
                px = @as(f64, @floatFromInt(x)) - ore_dust_lift;
            },
        }

        const inside = px >= @as(f64, @floatFromInt(x)) and px <= @as(f64, @floatFromInt(x + 1)) and
            py >= 0.0 and py <= @as(f64, @floatFromInt(y + 1)) and
            pz >= @as(f64, @floatFromInt(z)) and pz <= @as(f64, @floatFromInt(z + 1));
        if (inside) continue;

        try self.particles.append(gpa, Particle.spawnReddust(math.Vec3.init(px, py, pz), .{ 0, 0, 0 }, rand));
    }
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
    world_map: *const world.World,
    base: Entity,
    rand: *world.JavaRandom,
) !void {
    const impact: f32 = @floatCast(@sqrt(base.motion.x * base.motion.x * 0.2 +
        base.motion.y * base.motion.y +
        base.motion.z * base.motion.z * 0.2));
    world_map.playSoundEffect(
        base.position.x,
        base.position.y,
        base.position.z,
        assets.sounds.random.splash,
        @min(impact * 0.2, 1.0),
        1.0 + (rand.nextFloat() - rand.nextFloat()) * 0.4,
    );

    const surface: f64 = @floatFromInt(math.util.floorDouble(base.boundingBox().min_y) + 1);

    var bubbled: f64 = 0;
    while (bubbled < 1.0 + base.width * 20.0) : (bubbled += 1) {
        const dx = (@as(f64, rand.nextFloat()) * 2.0 - 1.0) * base.width;
        const dz = (@as(f64, rand.nextFloat()) * 2.0 - 1.0) * base.width;
        const sinking = math.Vec3.init(
            base.motion.x,
            base.motion.y - @as(f64, rand.nextFloat()) * 0.2,
            base.motion.z,
        );
        try self.particles.append(gpa, Particle.spawnBubble(
            math.Vec3.init(base.position.x + dx, surface, base.position.z + dz),
            sinking,
            rand,
        ));
    }

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

const drowning_bubbles: usize = 8;

pub fn spawnDrowningBubbles(
    self: *Entities,
    gpa: std.mem.Allocator,
    position: math.Vec3,
    motion: math.Vec3,
    rand: *world.JavaRandom,
) !void {
    for (0..drowning_bubbles) |_| {
        const dx: f64 = @floatCast(rand.nextFloat() - rand.nextFloat());
        const dy: f64 = @floatCast(rand.nextFloat() - rand.nextFloat());
        const dz: f64 = @floatCast(rand.nextFloat() - rand.nextFloat());
        try self.particles.append(gpa, Particle.spawnBubble(
            math.Vec3.init(position.x + dx, position.y + dy, position.z + dz),
            motion,
            rand,
        ));
    }
}

pub fn loose(
    self: *Entities,
    gpa: std.mem.Allocator,
    shot: Skeleton.Shot,
    rand: *world.JavaRandom,
) !void {
    try self.arrows.append(gpa, Arrow.loosedBy(
        shot.owner,
        shot.from,
        shot.toward,
        Skeleton.arrow_speed,
        Skeleton.arrow_spread,
        rand,
    ));
}

pub fn shootArrow(
    self: *Entities,
    gpa: std.mem.Allocator,
    player: *const Player,
    rand: *world.JavaRandom,
) !void {
    try self.arrows.append(gpa, Arrow.shotBy(player.*, rand));
}

const ArrowStrike = union(enum) {
    mob: Target,
    player: Entity.Id,
};

fn arrowStrike(self: *Entities, arrow: Arrow, roster: []const *Player, limit: f64) ?ArrowStrike {
    const start = arrow.base.position;
    const along = arrow.base.motion;
    const swept = arrow.base.boundingBox()
        .addCoord(along.x, along.y, along.z)
        .expand(1.0, 1.0, 1.0);

    var found: ?ArrowStrike = null;
    var nearest: f64 = 0;

    const consider = struct {
        fn hit(
            box: math.Aabb,
            candidate: ArrowStrike,
            origin: math.Vec3,
            direction: math.Vec3,
            reach: f64,
            best: *?ArrowStrike,
            best_distance: *f64,
        ) void {
            const grown = box.expand(Arrow.hit_border, Arrow.hit_border, Arrow.hit_border);
            const distance = boxRayDistance(grown, origin, direction, reach) orelse return;
            if (best.* == null or distance < best_distance.*) {
                best.* = candidate;
                best_distance.* = distance;
            }
        }
    }.hit;

    const shielded = arrow.ticks_in_air < Arrow.owner_grace_ticks;

    for (self.mobs.items) |entry| {
        if (shielded and !arrow.from_player and entry.animal.base.id == arrow.owner) continue;
        const box = entry.animal.base.boundingBox();
        if (box.intersects(swept)) {
            consider(box, .{ .mob = .{ .mob = entry.animal.base.id } }, start, along, limit, &found, &nearest);
        }
    }

    for (roster) |player| {
        if (shielded and arrow.from_player and player.base.id == arrow.owner) continue;
        const box = player.base.boundingBox();
        if (box.intersects(swept)) {
            consider(box, .{ .player = player.base.id }, start, along, limit, &found, &nearest);
        }
    }

    return found;
}

fn arrowShooter(self: *const Entities, arrow: Arrow, roster: []const *Player) ?Animal.Attacker {
    if (arrow.from_player) {
        const shooter = playerById(roster, arrow.owner) orelse return null;
        return .{ .position = shooter.base.position, .player = shooter.base.id };
    }

    const entry = self.mobById(arrow.owner) orelse return null;
    return .{
        .position = entry.animal.base.position,
        .mob = entry.animal.base.id,
        .mob_type = entry.type_id,
    };
}

const cactus_damage: i32 = 1;

// EntityMinecart.getCollisionBox returns the other entity's box, so a cart is stopped by
// every entity it runs into - mobs, players, even dropped items - while its own
// getBoundingBox is null and it blocks nothing in return.
const cart_obstacle_reach: f64 = 0.25;

fn gatherObstacles(
    self: *const Entities,
    gpa: std.mem.Allocator,
    out: *std.ArrayList(math.Aabb),
    roster: []const *Player,
    query: math.Aabb,
    skip: Entity.Id,
) !void {
    out.clearRetainingCapacity();

    inline for (.{ "items", "arrows", "fireballs", "thrown", "falling_blocks", "primed", "boats", "minecarts", "hooks" }) |name| {
        for (@field(self, name).items) |entry| {
            if (entry.base.id == skip) continue;
            const box = entry.base.boundingBox();
            if (box.intersects(query)) try out.append(gpa, box);
        }
    }

    for (self.mobs.items) |entry| {
        const box = entry.animal.base.boundingBox();
        if (box.intersects(query)) try out.append(gpa, box);
    }

    for (self.paintings.items) |painting| {
        if (painting.box.intersects(query)) try out.append(gpa, painting.box);
    }

    for (roster) |player| {
        const box = player.base.boundingBox();
        if (box.intersects(query)) try out.append(gpa, box);
    }
}

pub fn tickMinecarts(
    self: *Entities,
    gpa: std.mem.Allocator,
    world_map: *world.World,
    roster: []const *Player,
    rand: *world.JavaRandom,
) !void {
    var obstacles: std.ArrayList(math.Aabb) = .empty;
    defer obstacles.deinit(gpa);

    var index: usize = 0;
    while (index < self.minecarts.items.len) {
        self.jostleBystanders(index, roster);

        const reach = Minecart.speed_cap + cart_obstacle_reach;
        const rolling = self.minecarts.items[index].base;
        const swept = rolling
            .boundingBox()
            .addCoord(rolling.motion.x, rolling.motion.y, rolling.motion.z)
            .expand(reach, cart_obstacle_reach, reach);
        try self.gatherObstacles(gpa, &obstacles, roster, swept, rolling.id);

        const cart = &self.minecarts.items[index];
        const step = cart.tick(world_map, obstacles.items, cart.rider != Entity.no_id);
        if (cart.base.remote == null and physics.touchesBlock(world_map, cart.base.boundingBox(), .cactus)) {
            _ = cart.hurt(cactus_damage);
        }

        if (step.smoking and rand.nextIntBound(4) == 0) {
            cart.fuel -= 1;
            if (cart.fuel < 0) cart.push = math.Vec3.init(0, 0, 0);
            const smoke = math.Vec3.init(
                cart.base.position.x,
                cart.base.position.y + Minecart.y_offset + 0.8,
                cart.base.position.z,
            );
            try self.particles.append(gpa, Particle.spawnLargeSmoke(smoke, math.Vec3.init(0, 0, 0), rand));
        }

        try world.redstone.onMinecartOverRail(world_map, cart.base.boundingBox());
        self.shoveMinecarts(index);

        if (cart.dead) {
            const wreck = cart.*;
            self.releaseRider(wreck.rider, wreck.base);
            _ = self.minecarts.orderedRemove(index);
            try self.breakUpMinecart(gpa, wreck, rand);
            continue;
        }
        index += 1;
    }
}

// Vanilla runs this from each living entity's own tick, which reaches the cart through
// EntityMinecart.applyEntityCollision. Driving it from the cart's tick instead touches the
// same pairs once per tick and keeps the cart's override in one place. It has to run before
// the cart moves: a cart is blocked by whatever it runs into, so by the time it is touching
// a mob its speed is already zero and the scoop-up test would never pass.
fn jostleBystanders(self: *Entities, index: usize, roster: []const *Player) void {
    const reach = Minecart.collision_reach;
    const box = self.minecarts.items[index].base.boundingBox().expand(reach, 0, reach);

    for (self.mobs.items) |entry| {
        if (!entry.animal.isAlive()) continue;
        if (entry.animal.base.id == self.minecarts.items[index].rider) continue;
        if (!entry.animal.base.boundingBox().intersects(box)) continue;

        const cart = &self.minecarts.items[index];
        if (entry.animal.riding == Entity.no_id and cart.wouldScoop()) {
            entry.animal.riding = cart.base.id;
            cart.rider = entry.animal.base.id;
        }
        cart.shoveOff(&entry.animal.base);
    }

    for (roster) |player| {
        if (player.health <= 0) continue;
        if (player.base.id == self.minecarts.items[index].rider) continue;
        if (!player.base.boundingBox().intersects(box)) continue;
        self.minecarts.items[index].shoveOff(&player.base);
    }
}

fn shoveMinecarts(self: *Entities, index: usize) void {
    const reach = Minecart.collision_reach;
    const box = self.minecarts.items[index].base.boundingBox().expand(reach, 0, reach);

    for (0..self.minecarts.items.len) |other| {
        if (other == index) continue;
        if (self.minecarts.items[other].dead) continue;
        if (!self.minecarts.items[other].base.boundingBox().intersects(box)) continue;
        self.minecarts.items[other].collideWith(&self.minecarts.items[index]);
    }
}

pub fn boardMinecart(self: *Entities, cart: *Minecart, passenger: Entity.Id) bool {
    if (cart.rider != Entity.no_id and cart.rider != passenger) {
        const seated = self.mobById(cart.rider) orelse return false;
        seated.animal.riding = Entity.no_id;
    }
    for (self.minecarts.items) |*other| {
        if (other.rider == passenger) other.rider = Entity.no_id;
    }
    cart.rider = passenger;
    return true;
}

pub fn releaseRider(self: *Entities, id: Entity.Id, mount: Entity) void {
    if (id == Entity.no_id) return;
    for (self.mobs.items) |entry| {
        if (entry.animal.base.id != id) continue;
        entry.animal.riding = Entity.no_id;
        entry.animal.base.position = Entity.dismountPosition(mount);
        entry.animal.base.prev_position = entry.animal.base.position;
    }
}

fn breakUpMinecart(self: *Entities, gpa: std.mem.Allocator, cart: Minecart, rand: *world.JavaRandom) !void {
    const x = math.util.floorDouble(cart.base.position.x);
    const y = math.util.floorDouble(cart.base.position.y);
    const z = math.util.floorDouble(cart.base.position.z);

    try self.dropStack(gpa, x, y, z, .{ .id = .{ .item = .minecart }, .count = 1 }, rand);

    for (cart.items) |maybe| {
        const stack = maybe orelse continue;
        try self.dropStack(gpa, x, y, z, .{ .id = stack.id, .count = stack.count, .meta = stack.meta }, rand);
    }

    if (cart.kind == .empty) return;
    const extra = Minecart.droppedItem(cart.kind);
    try self.dropStack(gpa, x, y, z, .{ .id = extra, .count = 1 }, rand);
}

pub const BoatRider = struct {
    id: Entity.Id,
    motion: math.Vec3,
};

fn shoveBoats(self: *Entities, index: usize) void {
    const reach = Boat.collision_reach;
    const box = self.boats.items[index].base.boundingBox().expand(reach, 0, reach);

    for (0..self.boats.items.len) |other| {
        if (other == index) continue;
        if (self.boats.items[other].dead) continue;
        if (!self.boats.items[other].base.boundingBox().intersects(box)) continue;
        self.boats.items[other].collideWith(&self.boats.items[index]);
    }
}

fn breakUpBoat(self: *Entities, gpa: std.mem.Allocator, boat: Boat, rand: *world.JavaRandom) !void {
    const x = math.util.floorDouble(boat.base.position.x);
    const y = math.util.floorDouble(boat.base.position.y);
    const z = math.util.floorDouble(boat.base.position.z);

    for (0..Boat.plank_drops) |_| {
        try self.dropStack(gpa, x, y, z, .{ .id = .{ .block = .planks }, .count = 1 }, rand);
    }
    for (0..Boat.stick_drops) |_| {
        try self.dropStack(gpa, x, y, z, .{ .id = .{ .item = .stick }, .count = 1 }, rand);
    }
}

pub fn tickBoats(
    self: *Entities,
    gpa: std.mem.Allocator,
    world_map: *world.World,
    rider: ?BoatRider,
    rand: *world.JavaRandom,
) !void {
    var index: usize = 0;
    while (index < self.boats.items.len) {
        const boat = &self.boats.items[index];
        const push: ?math.Vec3 = if (rider) |on_board|
            (if (on_board.id == boat.base.id) on_board.motion else null)
        else
            null;

        const step = boat.tick(world_map, push);
        if (boat.base.remote == null and physics.touchesBlock(world_map, boat.base.boundingBox(), .cactus)) {
            _ = boat.hurt(cactus_damage);
        }

        for (0..Boat.wakeCount(step.speed)) |_| {
            const wake = boat.wakeAt(rand);
            try self.particles.append(gpa, Particle.spawnSplash(wake.position, wake.motion, rand));
        }

        self.shoveBoats(index);

        for (0..4) |corner| {
            const cell = boat.crushedSnow(corner);
            if (world_map.getBlock(cell[0], cell[1], cell[2]) != .snow_layer) continue;
            try world_map.setBlockWithNotify(cell[0], cell[1], cell[2], .air);
        }

        if (boat.dead) {
            const wreck = boat.*;
            _ = self.boats.orderedRemove(index);
            if (step.broke_up or wreck.damage > Boat.break_damage) {
                try self.breakUpBoat(gpa, wreck, rand);
            }
            continue;
        }
        index += 1;
    }
}

fn playArrowImpact(world_map: *const world.World, arrow: Arrow, rand: *world.JavaRandom) void {
    world_map.playSoundEffect(
        arrow.base.position.x,
        arrow.base.position.y,
        arrow.base.position.z,
        assets.sounds.random.drr,
        Arrow.impact_volume,
        Arrow.impactPitch(rand),
    );
}

pub fn tickArrows(
    self: *Entities,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    roster: []const *Player,
    rand: *world.JavaRandom,
) !void {
    var i: usize = 0;
    while (i < self.arrows.items.len) {
        const arrow = &self.arrows.items[i];
        const owned_here = arrow.base.remote == null;

        if (!arrow.settle(world_map, rand)) {
            const block_hit = arrow.blockImpact(world_map);
            const limit: f64 = if (block_hit) |hit| hit.distance else 1.0;

            if (if (owned_here) self.arrowStrike(arrow.*, roster, limit) else null) |strike| {
                const source = self.arrowShooter(arrow.*, roster);
                const landed = switch (strike) {
                    .mob => |target| self.hurtTarget(world_map, target, Arrow.damage, source, rand),
                    .player => |id| blk: {
                        const struck = playerById(roster, id) orelse break :blk false;
                        const absorbed = struck.absorbsHit(Arrow.damage);
                        struck.hurtByHostile(world_map, Arrow.damage, null);
                        break :blk !absorbed;
                    },
                };
                if (landed) {
                    playArrowImpact(world_map, arrow.*, rand);
                    arrow.dead = true;
                } else arrow.deflect();
            } else if (block_hit) |hit| {
                arrow.stickInto(world_map, hit);
                playArrowImpact(world_map, arrow.*, rand);
            }

            if (arrow.fly()) |trail| {
                for (0..Arrow.bubbles_per_trail) |_| {
                    try self.particles.append(gpa, Particle.spawnBubble(trail.position, trail.drift, rand));
                }
            }
        }

        for (roster) |player| {
            const reach = player.base.boundingBox().expand(pickup_reach, 0, pickup_reach);
            if (!arrow.canBePickedUp() or player.health <= 0) continue;
            if (!arrow.base.boundingBox().intersects(reach)) continue;

            const stack: Inventory.ItemStack = .{ .id = .{ .item = .arrow }, .count = 1 };
            if (player.inventory.addStack(stack) == 0) {
                const collected: ItemEntity = .{
                    .base = Entity.init(arrow.base.position, ItemEntity.width, ItemEntity.height),
                    .stack = stack,
                };
                world_map.playSoundEffect(
                    arrow.base.position.x,
                    arrow.base.position.y,
                    arrow.base.position.z,
                    assets.sounds.random.pop,
                    ItemEntity.pickup_volume,
                    ItemEntity.pickupPitch(rand),
                );
                try self.pickups.append(gpa, PickupFx.spawn(collected));
                arrow.dead = true;
            }
            break;
        }

        if (arrow.dead) {
            _ = self.arrows.swapRemove(i);
        } else {
            i += 1;
        }
    }
}

pub fn shootFireball(
    self: *Entities,
    gpa: std.mem.Allocator,
    shooter: Entity.Id,
    shot: Ghast.Shot,
    rand: *world.JavaRandom,
) !void {
    try self.fireballs.append(gpa, Fireball.shotBy(shot.from, shooter, shot.toward, rand));
}

fn fireballStrike(self: *Entities, ball: Fireball, roster: []const *Player, limit: f64) ?ArrowStrike {
    const start = ball.base.position;
    const along = ball.base.motion;
    const swept = ball.base.boundingBox()
        .addCoord(along.x, along.y, along.z)
        .expand(1.0, 1.0, 1.0);

    var found: ?ArrowStrike = null;
    var nearest: f64 = 0;
    const spent = ball.ticks_in_air >= Fireball.owner_grace_ticks;

    for (self.mobs.items) |entry| {
        if (entry.animal.base.id == ball.shooter and !spent) continue;
        const box = entry.animal.base.boundingBox();
        if (!box.intersects(swept)) continue;

        const grown = box.expand(Fireball.hit_border, Fireball.hit_border, Fireball.hit_border);
        const distance = boxRayDistance(grown, start, along, limit) orelse continue;
        if (found == null or distance < nearest) {
            found = .{ .mob = .{ .mob = entry.animal.base.id } };
            nearest = distance;
        }
    }

    for (roster) |player| {
        if (player.base.id == ball.shooter and !spent) continue;
        const box = player.base.boundingBox();
        if (!box.intersects(swept)) continue;

        const grown = box.expand(Fireball.hit_border, Fireball.hit_border, Fireball.hit_border);
        const distance = boxRayDistance(grown, start, along, limit) orelse continue;
        if (found == null or distance < nearest) {
            found = .{ .player = player.base.id };
            nearest = distance;
        }
    }

    return found;
}

pub fn tickFireballs(
    self: *Entities,
    gpa: std.mem.Allocator,
    world_map: *world.World,
    roster: []const *Player,
    rand: *world.JavaRandom,
) !void {
    var index: usize = 0;
    while (index < self.fireballs.items.len) {
        var ball = self.fireballs.items[index];
        ball.settle(world_map);

        const owned_here = ball.base.remote == null;
        const block_hit = if (owned_here) ball.blockImpact(world_map) else null;
        const limit: f64 = if (block_hit) |hit| hit.distance else 1.0;
        const strike = if (owned_here) self.fireballStrike(ball, roster, limit) else null;

        if (strike != null or block_hit != null) {
            // The direct hit lands for nothing; every point of damage comes from the blast.
            if (strike) |target| {
                if (target == .mob) {
                    _ = self.hurtTarget(world_map, target.mob, 0, .{ .position = ball.base.position }, rand);
                }
            }
            try explosion.detonate(
                gpa,
                self,
                world_map,
                roster,
                ball.base.position,
                Fireball.explosion_size,
                Fireball.explosion_is_flaming,
                rand,
            );
            ball.dead = true;
        }

        if (ball.fly()) |trail| {
            for (0..Fireball.bubbles_per_trail) |_| {
                try self.particles.append(gpa, Particle.spawnBubble(trail.position, trail.drift, rand));
            }
        }
        try self.particles.append(gpa, Particle.spawnSmoke(
            ball.smokeTrailPosition(),
            math.Vec3.init(0, 0, 0),
            rand,
        ));

        self.fireballs.items[index] = ball;

        if (ball.dead) {
            _ = self.fireballs.swapRemove(index);
        } else {
            index += 1;
        }
    }
}

pub fn throwItem(
    self: *Entities,
    gpa: std.mem.Allocator,
    kind: Thrown.Kind,
    player: *const Player,
    rand: *world.JavaRandom,
) !void {
    try self.thrown.append(gpa, Thrown.thrownBy(kind, player.*, rand));
}

fn thrownStrike(self: *Entities, projectile: Thrown, roster: []const *Player, limit: f64) ?ArrowStrike {
    const start = projectile.base.position;
    const along = projectile.base.motion;
    const swept = projectile.base.boundingBox()
        .addCoord(along.x, along.y, along.z)
        .expand(1.0, 1.0, 1.0);

    var found: ?ArrowStrike = null;
    var nearest: f64 = 0;
    const spent = projectile.ticks_in_air >= Thrown.owner_grace_ticks;

    for (self.mobs.items) |entry| {
        if (entry.animal.base.id == projectile.owner and !spent) continue;
        const box = entry.animal.base.boundingBox();
        if (!box.intersects(swept)) continue;

        const grown = box.expand(Thrown.hit_border, Thrown.hit_border, Thrown.hit_border);
        const distance = boxRayDistance(grown, start, along, limit) orelse continue;
        if (found == null or distance < nearest) {
            found = .{ .mob = .{ .mob = entry.animal.base.id } };
            nearest = distance;
        }
    }

    for (roster) |player| {
        if (player.base.id == projectile.owner and !spent) continue;
        const box = player.base.boundingBox();
        if (!box.intersects(swept)) continue;

        const grown = box.expand(Thrown.hit_border, Thrown.hit_border, Thrown.hit_border);
        const distance = boxRayDistance(grown, start, along, limit) orelse continue;
        if (found == null or distance < nearest) {
            found = .{ .player = player.base.id };
            nearest = distance;
        }
    }

    return found;
}

pub fn tickThrown(
    self: *Entities,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    roster: []const *Player,
    rand: *world.JavaRandom,
) !void {
    var index: usize = 0;
    while (index < self.thrown.items.len) {
        const projectile = &self.thrown.items[index];
        const owned_here = projectile.base.remote == null;
        projectile.settle(world_map);

        const block_hit = projectile.blockImpact(world_map);
        const limit: f64 = if (block_hit) |hit| hit.distance else 1.0;
        const strike = if (owned_here) self.thrownStrike(projectile.*, roster, limit) else null;

        if (strike != null or block_hit != null) {
            if (strike) |target| {
                if (target == .mob) {
                    _ = self.hurtTarget(world_map, target.mob, 0, self.throwerOf(projectile.*, roster), rand);
                }
            }
            const broken = projectile.base.position;
            if (owned_here and projectile.kind == .egg) {
                for (0..Thrown.hatched(rand)) |_| {
                    try self.spawnChicken(gpa, broken, rand);
                }
            }
            for (0..Thrown.poof_particles) |_| {
                try self.particles.append(gpa, Particle.spawnItemPoof(broken, .snowball, rand));
            }
            projectile.dead = true;
        }

        if (projectile.fly()) |trail| {
            for (0..Thrown.bubbles_per_trail) |_| {
                try self.particles.append(gpa, Particle.spawnBubble(trail.position, trail.drift, rand));
            }
        }

        if (projectile.dead) {
            _ = self.thrown.swapRemove(index);
        } else {
            index += 1;
        }
    }
}

fn throwerOf(self: *const Entities, projectile: Thrown, roster: []const *Player) ?Animal.Attacker {
    if (projectile.from_player) {
        const thrower = playerById(roster, projectile.owner) orelse return null;
        return .{ .position = thrower.base.position, .player = thrower.base.id };
    }

    const entry = self.mobById(projectile.owner) orelse return null;
    return .{
        .position = entry.animal.base.position,
        .mob = entry.animal.base.id,
        .mob_type = entry.type_id,
    };
}

pub fn spawnPig(self: *Entities, gpa: std.mem.Allocator, position: math.Vec3) !void {
    var unused = world.JavaRandom.init(0);
    _ = try self.spawnMob(gpa, mob.pig, position, &unused);
}

pub fn spawnSheep(self: *Entities, gpa: std.mem.Allocator, position: math.Vec3, rand: *world.JavaRandom) !void {
    _ = try self.spawnMob(gpa, mob.sheep, position, rand);
}

pub fn spawnCow(self: *Entities, gpa: std.mem.Allocator, position: math.Vec3) !void {
    var unused = world.JavaRandom.init(0);
    _ = try self.spawnMob(gpa, mob.cow, position, &unused);
}

pub fn spawnChicken(self: *Entities, gpa: std.mem.Allocator, position: math.Vec3, rand: *world.JavaRandom) !void {
    _ = try self.spawnMob(gpa, mob.chicken, position, rand);
}

pub fn spawnSlime(self: *Entities, gpa: std.mem.Allocator, position: math.Vec3, rand: *world.JavaRandom) !void {
    _ = try self.spawnMob(gpa, mob.slime, position, rand);
}

pub fn spawnGhast(self: *Entities, gpa: std.mem.Allocator, position: math.Vec3) !void {
    var unused = world.JavaRandom.init(0);
    _ = try self.spawnMob(gpa, mob.ghast, position, &unused);
}

pub fn spawnSquid(self: *Entities, gpa: std.mem.Allocator, position: math.Vec3, rand: *world.JavaRandom) !void {
    _ = try self.spawnMob(gpa, mob.squid, position, rand);
}

pub fn spawnSpider(self: *Entities, gpa: std.mem.Allocator, position: math.Vec3) !void {
    var unused = world.JavaRandom.init(0);
    _ = try self.spawnMob(gpa, mob.spider, position, &unused);
}

pub fn spawnSkeleton(self: *Entities, gpa: std.mem.Allocator, position: math.Vec3) !void {
    var unused = world.JavaRandom.init(0);
    _ = try self.spawnMob(gpa, mob.skeleton, position, &unused);
}

pub fn spawnCreeper(self: *Entities, gpa: std.mem.Allocator, position: math.Vec3) !void {
    var unused = world.JavaRandom.init(0);
    _ = try self.spawnMob(gpa, mob.creeper, position, &unused);
}

pub fn spawnZombie(self: *Entities, gpa: std.mem.Allocator, position: math.Vec3) !void {
    var unused = world.JavaRandom.init(0);
    _ = try self.spawnMob(gpa, mob.zombie, position, &unused);
}

pub fn spawnPigZombie(self: *Entities, gpa: std.mem.Allocator, position: math.Vec3) !void {
    var unused = world.JavaRandom.init(0);
    _ = try self.spawnMob(gpa, mob.pig_zombie, position, &unused);
}

pub fn spawnWolf(self: *Entities, gpa: std.mem.Allocator, position: math.Vec3, rand: *world.JavaRandom) !void {
    _ = try self.spawnMob(gpa, mob.wolf, position, rand);
}

pub fn spawnWolfSplash(
    self: *Entities,
    gpa: std.mem.Allocator,
    position: math.Vec3,
    motion: math.Vec3,
    rand: *world.JavaRandom,
) !void {
    try self.particles.append(gpa, Particle.spawnSplash(position, motion, rand));
}

pub fn spawnTreatReaction(
    self: *Entities,
    gpa: std.mem.Allocator,
    animal: Animal,
    pleased: bool,
    rand: *world.JavaRandom,
) !void {
    for (0..Wolf.treat_particles) |_| {
        const drift = math.Vec3.init(
            rand.nextGaussian() * 0.02,
            rand.nextGaussian() * 0.02,
            rand.nextGaussian() * 0.02,
        );
        const at = math.Vec3.init(
            animal.base.position.x + @as(f64, rand.nextFloat()) * animal.base.width * 2.0 - animal.base.width,
            animal.base.position.y + 0.5 + @as(f64, rand.nextFloat()) * animal.base.height,
            animal.base.position.z + @as(f64, rand.nextFloat()) * animal.base.width * 2.0 - animal.base.width,
        );
        try self.particles.append(gpa, if (pleased)
            Particle.spawnHeart(at, rand)
        else
            Particle.spawnSmoke(at, drift, rand));
    }
}

const pickup_reach: f64 = 1.0;

pub fn tickItems(
    self: *Entities,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    roster: []const *Player,
    rand: *world.JavaRandom,
) !void {
    for (roster) |player| try self.tickItemsFor(gpa, world_map, player, rand);
}

fn tickItemsFor(
    self: *Entities,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    player: *Player,
    rand: *world.JavaRandom,
) !void {
    const reach = player.base.boundingBox().expand(pickup_reach, 0, pickup_reach);
    var i: usize = 0;
    while (i < self.items.items.len) {
        const item = &self.items.items[i];
        item.tick(world_map);

        var picked_up = false;
        if (item.base.remote == null and player.health > 0 and item.canPickUp() and item.base.boundingBox().intersects(reach)) {
            const collected = item.stack.id;
            const leftover = player.inventory.addStack(item.stack);
            if (leftover < item.stack.count) {
                if (collected.eql(.{ .block = .log })) player.earn(.mine_wood);
                if (collected.eql(.{ .item = .leather })) player.earn(.kill_cow);
                world_map.playSoundEffect(
                    item.base.position.x,
                    item.base.position.y,
                    item.base.position.z,
                    assets.sounds.random.pop,
                    ItemEntity.pickup_volume,
                    ItemEntity.pickupPitch(rand),
                );
                item.stack.count = leftover;
                try self.pickups.append(gpa, PickupFx.spawn(item.*));
                picked_up = leftover == 0;
                if (picked_up) {
                    try self.collected.append(gpa, .{ .item = item.base.id, .by = player.base.id });
                }
            }
        }

        if (picked_up or (item.base.remote == null and (item.isExpired() or item.isDestroyed()))) {
            _ = self.items.swapRemove(i);
        } else {
            i += 1;
        }
    }
}

pub fn strikeLightning(
    self: *Entities,
    gpa: std.mem.Allocator,
    world_map: *world.World,
    at: math.Vec3,
    rand: *world.JavaRandom,
) !void {
    var bolt = Lightning.strike(at, rand);
    bolt.base.id = self.takeId();
    try bolt.scorch(world_map, rand);
    try self.struck.append(gpa, .{ .id = bolt.base.id, .at = at });
    try self.bolts.append(gpa, bolt);
}

pub fn showLightning(
    self: *Entities,
    gpa: std.mem.Allocator,
    id: Entity.Id,
    at: math.Vec3,
    rand: *world.JavaRandom,
) !void {
    var bolt = Lightning.strike(at, rand);
    bolt.base.id = id;
    bolt.base.remote = .at(0, 0, 0);
    try self.bolts.append(gpa, bolt);
}

pub fn clearStruck(self: *Entities) void {
    self.struck.clearRetainingCapacity();
}

pub fn tickLightning(
    self: *Entities,
    gpa: std.mem.Allocator,
    world_map: *world.World,
    roster: []const *Player,
    rand: *world.JavaRandom,
) !void {
    var index: usize = 0;
    while (index < self.bolts.items.len) {
        const bolt = &self.bolts.items[index];
        const step = bolt.tick(rand);

        if (step.struck) {
            world_map.playSoundEffect(
                bolt.base.position.x,
                bolt.base.position.y,
                bolt.base.position.z,
                assets.sounds.ambient.weather.thunder,
                Lightning.thunder_volume,
                0.8 + rand.nextFloat() * 0.2,
            );
            world_map.playSoundEffect(
                bolt.base.position.x,
                bolt.base.position.y,
                bolt.base.position.z,
                assets.sounds.random.explode,
                Lightning.crack_volume,
                0.5 + rand.nextFloat() * 0.2,
            );
        }
        const owned_here = bolt.base.remote == null;
        if (step.reflash and owned_here) try bolt.scorch(world_map, rand);

        if (bolt.isVisible()) {
            world_map.weather.flash = world.Weather.flash_ticks;
            if (owned_here) try self.shockEntities(gpa, world_map, bolt.*, roster, rand);
        }

        if (bolt.dead) {
            _ = self.bolts.swapRemove(index);
            continue;
        }
        index += 1;
    }
}

fn shockEntities(
    self: *Entities,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    bolt: Lightning,
    roster: []const *Player,
    rand: *world.JavaRandom,
) !void {
    const box = bolt.boundingBox();

    for (roster) |player| {
        if (!player.base.boundingBox().intersects(box)) continue;
        player.hurt(world_map, Lightning.fire_damage);
        if (player.fire == 0) player.fire = Lightning.burn_ticks;
    }

    var index: usize = 0;
    while (index < self.mobs.items.len) : (index += 1) {
        const entry = self.mobs.items[index];
        if (!entry.animal.base.boundingBox().intersects(box)) continue;

        if (entry.type_id == mob.pig) {
            const at = entry.animal.base.position;
            const facing = entry.animal.yaw;
            _ = self.removeMob(gpa, entry.animal.base.id);
            const zombie = try self.spawnMob(gpa, lightning_pig_zombie, at, rand);
            zombie.yaw = facing;
            zombie.prev_yaw = facing;
            continue;
        }

        _ = mob.get(entry.type_id).hurt(entry.animal, world_map, Lightning.fire_damage, null, rand);
        if (entry.animal.fire == 0) entry.animal.fire = Lightning.burn_ticks;
        if (entry.type_id == mob.creeper) {
            const charged: *Creeper = @fieldParentPtr("animal", entry.animal);
            charged.powered = true;
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
    return @divFloor(math.util.floorDouble(coordinate), world.Chunk.width);
}

fn collectChunkEntities(
    context: *anyopaque,
    gpa: std.mem.Allocator,
    chunk_x: i32,
    chunk_z: i32,
    out: *std.ArrayList(world.nbt.Tag),
) anyerror!void {
    const self: *Entities = @ptrCast(@alignCast(context));
    for (self.mobs.items) |entry| {
        const position = entry.animal.base.position;
        if (chunkOf(position.x) != chunk_x or chunkOf(position.z) != chunk_z) continue;
        try out.append(gpa, try mob.get(entry.type_id).store(entry.animal, gpa));
    }
    for (self.items.items) |item| {
        if (chunkOf(item.base.position.x) != chunk_x or chunkOf(item.base.position.z) != chunk_z) continue;
        try out.append(gpa, try world.entity_nbt.storeItem(gpa, item.toRecord()));
    }
    for (self.arrows.items) |arrow| {
        if (arrow.dead) continue;
        if (chunkOf(arrow.base.position.x) != chunk_x or chunkOf(arrow.base.position.z) != chunk_z) continue;
        try out.append(gpa, try world.entity_nbt.storeArrow(gpa, arrow.toRecord()));
    }
    for (self.paintings.items) |painting| {
        if (chunkOf(painting.position.x) != chunk_x or chunkOf(painting.position.z) != chunk_z) continue;
        try out.append(gpa, try world.entity_nbt.storePainting(gpa, painting.toRecord()));
    }
    for (self.boats.items) |boat| {
        if (boat.dead) continue;
        if (chunkOf(boat.base.position.x) != chunk_x or chunkOf(boat.base.position.z) != chunk_z) continue;
        try out.append(gpa, try world.entity_nbt.storeBoat(gpa, boat.toRecord()));
    }
    for (self.minecarts.items) |cart| {
        if (cart.dead) continue;
        if (chunkOf(cart.base.position.x) != chunk_x or chunkOf(cart.base.position.z) != chunk_z) continue;
        try out.append(gpa, try world.entity_nbt.storeMinecart(gpa, cart.toRecord()));
    }
}

fn restoreChunkEntity(context: *anyopaque, gpa: std.mem.Allocator, entity: world.nbt.Compound) anyerror!void {
    const self: *Entities = @ptrCast(@alignCast(context));
    var type_id: mob.Id = 0;
    while (type_id < mob.registered()) : (type_id += 1) {
        const animal = try mob.get(type_id).load(gpa, entity) orelse continue;
        errdefer mob.get(type_id).destroy(animal, gpa);
        try self.adoptMob(gpa, type_id, animal);
        return;
    }
    if (world.entity_nbt.loadItem(entity)) |record| {
        try self.items.append(gpa, ItemEntity.fromRecord(record));
    } else if (world.entity_nbt.loadArrow(entity)) |record| {
        try self.arrows.append(gpa, Arrow.fromRecord(record));
    } else if (world.entity_nbt.loadPainting(entity)) |record| {
        if (Painting.fromRecord(record)) |painting| try self.spawnPainting(gpa, painting);
    } else if (world.entity_nbt.loadBoat(entity)) |record| {
        var boat = Boat.fromRecord(record);
        boat.base.id = self.takeId();
        try self.boats.append(gpa, boat);
    } else if (world.entity_nbt.loadMinecart(entity)) |record| {
        var cart = Minecart.fromRecord(record);
        cart.base.id = self.takeId();
        try self.minecarts.append(gpa, cart);
    }
}

pub fn anyInBox(self: *Entities, box: math.Aabb, living_only: bool) bool {
    for (self.mobs.items) |entry| {
        if (entry.animal.base.boundingBox().intersects(box)) return true;
    }
    if (living_only) return false;

    for (self.items.items) |*dropped| {
        if (dropped.base.boundingBox().intersects(box)) return true;
    }
    for (self.arrows.items) |*arrow| {
        if (arrow.base.boundingBox().intersects(box)) return true;
    }
    for (self.fireballs.items) |*ball| {
        if (ball.base.boundingBox().intersects(box)) return true;
    }
    for (self.thrown.items) |*egg| {
        if (egg.base.boundingBox().intersects(box)) return true;
    }
    for (self.boats.items) |*boat| {
        if (boat.base.boundingBox().intersects(box)) return true;
    }
    for (self.minecarts.items) |*cart| {
        if (cart.base.boundingBox().intersects(box)) return true;
    }
    return false;
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
    for (self.mobs.items) |entry| {
        if (entry.animal == animal) continue;
        if (entry.animal.riding == animal.base.id or animal.riding == entry.animal.base.id) continue;
        if (!entry.animal.base.boundingBox().intersects(reach)) continue;
        pushApart(entry.animal, animal);
    }
}

pub fn tickMobs(
    self: *Entities,
    gpa: std.mem.Allocator,
    world_map: *world.World,
    roster: []const *Player,
    players: Animal.Players,
    rand: *world.JavaRandom,
) !void {
    var index: usize = 0;
    while (index < self.mobs.items.len) {
        const entry = self.mobs.items[index];
        const kind = mob.get(entry.type_id);
        const context: mob.Tick = .{
            .entities = self,
            .gpa = gpa,
            .world_map = world_map,
            .roster = roster,
            .players = players,
            .rand = rand,
        };

        try kind.tick(entry.animal, gpa, world_map, players, rand);
        if (physics.touchesBlock(world_map, entry.animal.base.boundingBox(), .cactus)) {
            _ = kind.hurt(entry.animal, world_map, cactus_damage, null, rand);
        }
        self.pushNeighbours(entry.animal);
        try kind.afterTick(entry.animal, context);

        if (entry.animal.drowned) {
            try self.spawnDrowningBubbles(gpa, entry.animal.base.position, entry.animal.base.motion, rand);
        }

        // A chicken can owe both the egg it just laid and the feathers it died leaving.
        while (kind.takeDrops(entry.animal)) |drops| {
            const position = entry.animal.base.position;
            for (0..drops.count) |_| {
                try self.items.append(gpa, ItemEntity.spawn(position, drops.stack, rand));
            }
        }

        if (kind.vanishes_on_peaceful and world_map.difficulty == .peaceful) {
            _ = self.mobs.orderedRemove(index);
            kind.destroy(entry.animal, gpa);
            continue;
        }

        if (entry.animal.dead) {
            if (kind.monster and entry.animal.health <= 0) {
                if (entry.animal.killer) |slayer| {
                    if (context.playerById(slayer.player)) |slain_by| slain_by.earn(.kill_enemy);
                }
            }
            try kind.onDeath(entry.animal, context);
            _ = self.mobs.orderedRemove(index);
            kind.destroy(entry.animal, gpa);
            continue;
        }
        index += 1;
    }
}

pub fn spawnSlimeLandingParticles(
    self: *Entities,
    gpa: std.mem.Allocator,
    slime: Slime,
    rand: *world.JavaRandom,
) !void {
    const size: f32 = @floatFromInt(slime.size);
    const floor = slime.animal.base.boundingBox().min_y;

    for (0..@as(usize, slime.size) * Slime.particles_per_size) |_| {
        const angle = rand.nextFloat() * std.math.pi * 2.0;
        const spread = rand.nextFloat() * 0.5 + 0.5;
        const dx = math.util.sin(angle) * size * 0.5 * spread;
        const dz = math.util.cos(angle) * size * 0.5 * spread;

        try self.particles.append(gpa, Particle.spawnSlime(math.Vec3.init(
            slime.animal.base.position.x + dx,
            floor,
            slime.animal.base.position.z + dz,
        ), rand));
    }
}

fn shoveBox(shove: world.World.PistonShove) ?math.Aabb {
    const stored = shove.state.stored;
    if (stored == .air or stored == .piston_moving) return null;
    if (!stored.hasCollision()) return null;

    const bounds = stored.selectionBounds(shove.state.stored_metadata);
    const along = shove.state.offsetAt(shove.progress);
    const delta = shove.state.facing.step();
    const shift = [3]f64{
        @as(f64, along) * @as(f64, @floatFromInt(delta[0])),
        @as(f64, along) * @as(f64, @floatFromInt(delta[1])),
        @as(f64, along) * @as(f64, @floatFromInt(delta[2])),
    };

    return math.Aabb.init(
        @as(f64, @floatFromInt(shove.pos.x)) + bounds.min[0] + shift[0],
        @as(f64, @floatFromInt(shove.pos.y)) + bounds.min[1] + shift[1],
        @as(f64, @floatFromInt(shove.pos.z)) + bounds.min[2] + shift[2],
        @as(f64, @floatFromInt(shove.pos.x)) + bounds.max[0] + shift[0],
        @as(f64, @floatFromInt(shove.pos.y)) + bounds.max[1] + shift[1],
        @as(f64, @floatFromInt(shove.pos.z)) + bounds.max[2] + shift[2],
    );
}

pub fn applyPistonShoves(self: *Entities, world_map: *world.World, roster: []const *Player) !void {
    for (world_map.piston_shoves.items) |shove| {
        const box = shoveBox(shove) orelse continue;
        const push = shove.state.shoveAlong(shove.amount);

        for (roster) |player| {
            if (!player.base.boundingBox().intersects(box)) continue;
            player.base.motion = player.base.motion.add(push);
            _ = player.base.move(world_map);
            player.base.motion = player.base.motion.sub(push);
        }

        for (self.mobs.items) |entry| {
            if (!entry.animal.base.boundingBox().intersects(box)) continue;
            shoveEntity(&entry.animal.base, world_map, push);
        }
        for (self.items.items) |*dropped| {
            if (!dropped.base.boundingBox().intersects(box)) continue;
            shoveEntity(&dropped.base, world_map, push);
        }
    }
}

fn shoveEntity(base: *Entity, world_map: *const world.World, push: math.Vec3) void {
    const kept = base.motion;
    base.motion = push;
    _ = base.move(world_map);
    base.motion = kept;
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
        entities.first(Pig, mob.pig).?.animal.health = 6;
        entities.first(Pig, mob.pig).?.animal.yaw = 42.0;
        entities.first(Pig, mob.pig).?.animal.base.on_ground = true;
        entities.first(Pig, mob.pig).?.saddled = true;

        var rand = world.JavaRandom.init(0);
        try entities.spawnSheep(gpa, math.Vec3.init(9.5, 1, 9.5), &rand);
        entities.first(Sheep, mob.sheep).?.fleece_color = 15;
        entities.first(Sheep, mob.sheep).?.sheared = true;

        try entities.spawnCow(gpa, math.Vec3.init(10.5, 1, 10.5));
        entities.first(Cow, mob.cow).?.animal.health = 5;

        try entities.spawnChicken(gpa, math.Vec3.init(11.5, 1, 11.5), &rand);
        entities.first(Chicken, mob.chicken).?.animal.health = 3;

        try w.saveLoadedChunks();
    }

    var reloaded = world.World.init(gpa);
    defer reloaded.deinit();
    reloaded.persistence = .{ .handle = &handle, .io = io };

    var restored: Entities = .{};
    defer restored.deinit(gpa);
    reloaded.entity_io = restored.entityIo();

    _ = try reloaded.getOrGenerateChunk(generator, 0, 0);

    try std.testing.expectEqual(@as(usize, 1), restored.countOf(mob.pig));
    const pig = restored.first(Pig, mob.pig).?;
    try std.testing.expectApproxEqAbs(@as(f64, 8.5), pig.animal.base.position.x, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), pig.animal.base.position.y, 1.0e-9);
    try std.testing.expectEqual(@as(i32, 6), pig.animal.health);
    try std.testing.expectApproxEqAbs(@as(f32, 42.0), pig.animal.yaw, 1.0e-6);
    try std.testing.expect(pig.saddled);
    try std.testing.expect(pig.animal.base.on_ground);

    try std.testing.expectEqual(@as(usize, 1), restored.countOf(mob.sheep));
    const sheep = restored.first(Sheep, mob.sheep).?;
    try std.testing.expectApproxEqAbs(@as(f64, 9.5), sheep.animal.base.position.x, 1.0e-9);
    try std.testing.expectEqual(@as(u4, 15), sheep.fleece_color);
    try std.testing.expect(sheep.sheared);

    try std.testing.expectEqual(@as(usize, 1), restored.countOf(mob.cow));
    const cow = restored.first(Cow, mob.cow).?;
    try std.testing.expectApproxEqAbs(@as(f64, 10.5), cow.animal.base.position.x, 1.0e-9);
    try std.testing.expectEqual(@as(i32, 5), cow.animal.health);

    try std.testing.expectEqual(@as(usize, 1), restored.countOf(mob.chicken));
    const chicken = restored.first(Chicken, mob.chicken).?;
    try std.testing.expectApproxEqAbs(@as(f64, 11.5), chicken.animal.base.position.x, 1.0e-9);
    try std.testing.expectEqual(@as(i32, 3), chicken.animal.health);
}

test "a slime comes back from its chunk the size it went in" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var handle = try world.save.open(io, tmp.dir, "Slimy");
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

        var rand = world.JavaRandom.init(0);
        try entities.spawnSlime(gpa, math.Vec3.init(8.5, 1, 8.5), &rand);
        entities.first(Slime, mob.slime).?.setSize(4);
        entities.first(Slime, mob.slime).?.animal.health = 9;
        entities.first(Slime, mob.slime).?.animal.yaw = 42.0;
        entities.first(Slime, mob.slime).?.animal.base.on_ground = true;

        try w.saveLoadedChunks();
    }

    var reloaded = world.World.init(gpa);
    defer reloaded.deinit();
    reloaded.persistence = .{ .handle = &handle, .io = io };

    var restored: Entities = .{};
    defer restored.deinit(gpa);
    reloaded.entity_io = restored.entityIo();

    _ = try reloaded.getOrGenerateChunk(generator, 0, 0);

    try std.testing.expectEqual(@as(usize, 1), restored.countOf(mob.slime));
    const slime = restored.first(Slime, mob.slime).?;
    try std.testing.expectEqual(@as(u8, 4), slime.size);
    try std.testing.expectEqual(@as(i32, 16), slime.animal.health);
    try std.testing.expectApproxEqAbs(@as(f64, 8.5), slime.animal.base.position.x, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f32, 42.0), slime.animal.yaw, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 2.4), slime.animal.base.width, 1.0e-9);
    try std.testing.expect(slime.animal.base.on_ground);
}

test "dropped items, arrows and paintings come back with their chunk" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var handle = try world.save.open(io, tmp.dir, "Litter");
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

        var rand = world.JavaRandom.init(0);
        try entities.dropStackAt(gpa, math.Vec3.init(4.5, 1, 4.5), .{ .id = .{ .item = .diamond }, .count = 7 }, &rand);

        var arrow = Arrow{ .base = Entity.init(math.Vec3.init(6.5, 1, 6.5), Arrow.size, Arrow.size) };
        arrow.in_ground = true;
        arrow.from_player = true;
        arrow.tile = .{ 6, 0, 6 };
        arrow.in_tile = .stone;
        try entities.arrows.append(gpa, arrow);

        try entities.spawnPainting(gpa, Painting.place(.{ 9, 2, 9 }, 2, .pigscene));

        try w.saveLoadedChunks();
    }

    var reloaded = world.World.init(gpa);
    defer reloaded.deinit();
    reloaded.persistence = .{ .handle = &handle, .io = io };

    var restored: Entities = .{};
    defer restored.deinit(gpa);
    reloaded.entity_io = restored.entityIo();

    _ = try reloaded.getOrGenerateChunk(generator, 0, 0);

    try std.testing.expectEqual(@as(usize, 1), restored.items.items.len);
    const item = restored.items.items[0];
    try std.testing.expectEqual(world.Id{ .item = .diamond }, item.stack.id);
    try std.testing.expectEqual(@as(u8, 7), item.stack.count);
    try std.testing.expectApproxEqAbs(@as(f64, 4.5), item.base.position.x, 1.0e-9);

    try std.testing.expectEqual(@as(usize, 1), restored.arrows.items.len);
    const restored_arrow = restored.arrows.items[0];
    try std.testing.expect(restored_arrow.in_ground);
    try std.testing.expect(restored_arrow.from_player);
    try std.testing.expectEqual(world.Block.stone, restored_arrow.in_tile);
    try std.testing.expectEqual([3]i32{ 6, 0, 6 }, restored_arrow.tile);

    try std.testing.expectEqual(@as(usize, 1), restored.paintings.items.len);
    const painting = restored.paintings.items[0];
    try std.testing.expectEqual(Painting.Art.pigscene, painting.art);
    try std.testing.expectEqual([3]i32{ 9, 2, 9 }, painting.tile);
    try std.testing.expectEqual(@as(u2, 2), painting.direction);
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

    var player = Player.spawn(math.Vec3.init(8, 1, 8));
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

    try entities.tickItems(gpa, &w, &[_]*Player{&player}, &w.rand);

    try std.testing.expectEqual(@as(usize, 0), entities.items.items.len);
    try std.testing.expectEqual(@as(u8, 3), player.inventory.slots[0].?.count);
}

test "picking up wood or leather earns the achievement that hangs off it" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    const cases = [_]struct { stack: world.Stack, earns: achievements.Id }{
        .{ .stack = .{ .id = .{ .block = .log }, .count = 1 }, .earns = .mine_wood },
        .{ .stack = .{ .id = .{ .item = .leather }, .count = 1 }, .earns = .kill_cow },
    };

    for (cases) |case| {
        var entities: Entities = .{};
        defer entities.deinit(gpa);

        var player = Player.spawn(math.Vec3.init(8, 1, 8));
        try entities.dropStack(gpa, 8, 1, 8, case.stack, &w.rand);
        entities.items.items[0].pickup_delay = 0;
        entities.items.items[0].base.position = player.base.position;

        try entities.tickItems(gpa, &w, &[_]*Player{&player}, &w.rand);
        try std.testing.expect(player.earned.contains(case.earns));
    }
}

test "picking up anything else earns nothing" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var player = Player.spawn(math.Vec3.init(8, 1, 8));
    try entities.dropStack(gpa, 8, 1, 8, .{ .id = .{ .block = .planks }, .count = 1 }, &w.rand);
    entities.items.items[0].pickup_delay = 0;
    entities.items.items[0].base.position = player.base.position;

    try entities.tickItems(gpa, &w, &[_]*Player{&player}, &w.rand);
    try std.testing.expectEqual(@as(usize, 0), player.earned.count());
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

    try entities.tickItems(gpa, &w, &[_]*Player{&player}, &w.rand);

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

    try entities.tickItems(gpa, &w, &[_]*Player{&player}, &w.rand);

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

    try entities.tickItems(gpa, &w, &[_]*Player{&player}, &w.rand);

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
    try entities.tickItems(gpa, &w, &[_]*Player{&player}, &w.rand);

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

    try entities.tickItems(gpa, &w, &[_]*Player{&player}, &w.rand);

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
    entities.first(Chicken, mob.chicken).?.pending_eggs = 1;
    entities.first(Chicken, mob.chicken).?.pending_feathers = 2;

    var player = Player.spawn(math.Vec3.init(0, 1, 0));
    try soloTick(&entities, gpa, &w, &player, &rand);

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
    entities.first(Cow, mob.cow).?.pending_drops = 2;

    var player = Player.spawn(math.Vec3.init(0, 1, 0));
    try soloTick(&entities, gpa, &w, &player, &rand);

    try std.testing.expectEqual(@as(usize, 2), entities.items.items.len);
    for (entities.items.items) |item| {
        try std.testing.expectEqual(world.Id{ .item = .leather }, item.stack.id);
        try std.testing.expectEqual(@as(u8, 1), item.stack.count);
    }
}

fn killedSlime(gpa: std.mem.Allocator, entities: *Entities, w: *world.World, size: u8, rand: *world.JavaRandom) !void {
    try entities.spawnSlime(gpa, math.Vec3.init(8.5, 1, 8.5), rand);
    entities.first(Slime, mob.slime).?.setSize(size);
    _ = entities.first(Slime, mob.slime).?.animal.hurt(w, entities.first(Slime, mob.slime).?.animal.max_health, null, rand);

    var player = Player.spawn(math.Vec3.init(0, 1, 0));
    for (0..Animal.death_ticks + 1) |_| {
        try soloTick(entities, gpa, w, &player, rand);
    }
}

test "a slain slime splits into four of the next size down" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(1);
    try killedSlime(gpa, &entities, &w, 4, &rand);

    try std.testing.expectEqual(Slime.split_count, entities.countOf(mob.slime));
    var children = entities.of(Slime, mob.slime);
    while (children.next()) |child| {
        try std.testing.expectEqual(@as(u8, 2), child.size);
        try std.testing.expectEqual(@as(i32, 4), child.animal.health);
        try std.testing.expect(child.animal.isAlive());
    }
}

test "the smallest slime leaves slimeballs rather than more slimes" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(1);
    try entities.spawnSlime(gpa, math.Vec3.init(8.5, 1, 8.5), &rand);
    entities.first(Slime, mob.slime).?.setSize(1);
    entities.first(Slime, mob.slime).?.pending_drops = 2;

    var player = Player.spawn(math.Vec3.init(0, 1, 0));
    for (0..Animal.death_ticks + 1) |_| {
        try soloTick(&entities, gpa, &w, &player, &rand);
    }

    try std.testing.expectEqual(@as(usize, 2), entities.items.items.len);
    for (entities.items.items) |item| {
        try std.testing.expectEqual(world.Id{ .item = .slime_ball }, item.stack.id);
    }
}

test "a landing slime throws out eight shards for every size step" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(3);
    try entities.spawnSlime(gpa, math.Vec3.init(8.5, 4, 8.5), &rand);
    entities.first(Slime, mob.slime).?.setSize(2);

    var player = Player.spawn(math.Vec3.init(0, 1, 0));
    for (0..40) |_| {
        try soloTick(&entities, gpa, &w, &player, &rand);
        if (entities.particles.items.len > 0) break;
    }

    try std.testing.expectEqual(@as(usize, 2 * Slime.particles_per_size), entities.particles.items.len);
    for (entities.particles.items) |particle| {
        try std.testing.expectEqual(Particle.Kind.slime, particle.kind);
    }
}

test "a big slime hurts and shoves the player it lands on" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(1);
    try entities.spawnSlime(gpa, math.Vec3.init(9.0, 1, 8.5), &rand);
    entities.first(Slime, mob.slime).?.setSize(4);

    var player = Player.spawn(math.Vec3.init(8.5, 1, 8.5));
    const before = player.health;
    try soloTick(&entities, gpa, &w, &player, &rand);

    try std.testing.expect(player.health < before);
    try std.testing.expect(player.base.motion.x < 0.0);
}

test "the smallest slime is harmless to walk into" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(1);
    try entities.spawnSlime(gpa, math.Vec3.init(8.6, 1, 8.5), &rand);
    entities.first(Slime, mob.slime).?.setSize(1);

    var player = Player.spawn(math.Vec3.init(8.5, 1, 8.5));
    for (0..20) |_| try soloTick(&entities, gpa, &w, &player, &rand);

    try std.testing.expectEqual(@as(i32, 20), player.health);
}

test "the wool a slain sheep loses is left on the ground in its own colour" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(2);
    try entities.spawnSheep(gpa, math.Vec3.init(8.5, 1, 8.5), &rand);
    entities.first(Sheep, mob.sheep).?.fleece_color = 12;
    _ = entities.first(Sheep, mob.sheep).?.animal.hurt(&w, Sheep.max_health, .{ .position = math.Vec3.init(6, 1, 8) }, &rand);

    var player = Player.spawn(math.Vec3.init(0, 1, 0));
    try soloTick(&entities, gpa, &w, &player, &rand);

    try std.testing.expect(entities.items.items.len >= 1 and entities.items.items.len <= 3);
    for (entities.items.items) |item| {
        try std.testing.expectEqual(world.Id{ .block = .wool }, item.stack.id);
        try std.testing.expectEqual(@as(u16, 12), item.stack.meta);
        try std.testing.expectEqual(@as(u8, 1), item.stack.count);
    }
}

test "sheared wool falls from over the sheep's back, one stack at a time" {
    const gpa = std.testing.allocator;

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(2);
    try entities.spawnSheep(gpa, math.Vec3.init(8.5, 64.0, 8.5), &rand);
    const sheep = entities.first(Sheep, mob.sheep).?;
    sheep.fleece_color = 12;

    const drops = sheep.shear(&rand).?;
    try entities.dropShearedWool(gpa, sheep, drops, &rand);

    try std.testing.expectEqual(@as(usize, drops.count), entities.items.items.len);
    for (entities.items.items) |wool| {
        try std.testing.expectEqual(world.Id{ .block = .wool }, wool.stack.id);
        try std.testing.expectEqual(@as(u16, 12), wool.stack.meta);
        try std.testing.expectEqual(@as(u8, 1), wool.stack.count);
        try std.testing.expectApproxEqAbs(@as(f64, 65.0), wool.base.position.y, 1.0e-9);
        try std.testing.expect(wool.base.motion.y > 0.2);
    }
}

test "a pig that runs out of air breathes out a burst of bubbles" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 6);
    defer w.deinit();
    w.setBlock(8, 1, 8, .stationary_water);

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(1);
    try entities.spawnPig(gpa, math.Vec3.init(8.5, 1, 8.5));
    entities.first(Pig, mob.pig).?.animal.air = -19;

    var player = Player.spawn(math.Vec3.init(0, 1, 0));
    try soloTick(&entities, gpa, &w, &player, &rand);

    try std.testing.expectEqual(drowning_bubbles, entities.particles.items.len);
    for (entities.particles.items) |bubble| {
        try std.testing.expectEqual(Particle.Kind.bubble, bubble.kind);
    }
}

fn archer(position: math.Vec3, yaw: f32, pitch: f32) Player {
    var player = Player.spawn(position);
    player.yaw = yaw;
    player.pitch = pitch;
    return player;
}

test "an arrow shot at a pig sticks in it, hurts it and is gone" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(1);
    try entities.spawnPig(gpa, math.Vec3.init(8.5, 1, 12.5));
    const before = entities.first(Pig, mob.pig).?.animal.health;

    var player = archer(math.Vec3.init(8.5, 1, 8.5), 0, 15);
    try entities.shootArrow(gpa, &player, &rand);
    try std.testing.expectEqual(@as(usize, 1), entities.arrows.items.len);

    for (0..4) |_| try entities.tickArrows(gpa, &w, &[_]*Player{&player}, &rand);

    try std.testing.expectEqual(@as(usize, 0), entities.arrows.items.len);
    try std.testing.expectEqual(before - Arrow.damage, entities.first(Pig, mob.pig).?.animal.health);
}

test "an arrow is heard landing, both in a wall and in a mob" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();
    var y: i32 = 1;
    while (y <= 4) : (y += 1) try w.setBlockWithNotify(12, y, 8, .stone);

    var heard: SoundLog = .{};
    w.sound_sink = heard.sink();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(1);
    var player = archer(math.Vec3.init(8.5, 1, 8.5), -90, 0);
    try entities.shootArrow(gpa, &player, &rand);
    for (0..4) |_| try entities.tickArrows(gpa, &w, &[_]*Player{&player}, &rand);

    try std.testing.expect(entities.arrows.items[0].in_ground);
    try std.testing.expect(heard.indexOf(assets.sounds.random.drr.key) != null);

    heard.count = 0;
    try entities.spawnPig(gpa, math.Vec3.init(8.5, 1, 12.5));
    const before = entities.first(Pig, mob.pig).?.animal.health;
    var shooter = archer(math.Vec3.init(8.5, 1, 8.5), 0, 15);
    try entities.shootArrow(gpa, &shooter, &rand);
    for (0..4) |_| try entities.tickArrows(gpa, &w, &[_]*Player{&shooter}, &rand);

    try std.testing.expectEqual(before - Arrow.damage, entities.first(Pig, mob.pig).?.animal.health);
    try std.testing.expect(heard.indexOf(assets.sounds.random.drr.key) != null);
}

test "an egg thrown at a wall breaks against it in a puff of shell" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();
    var y: i32 = 1;
    while (y <= 4) : (y += 1) try w.setBlockWithNotify(12, y, 8, .stone);

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(1);
    var player = archer(math.Vec3.init(8.5, 1, 8.5), -90, 0);
    try entities.throwItem(gpa, .egg, &player, &rand);
    try std.testing.expectEqual(@as(usize, 1), entities.thrown.items.len);

    for (0..4) |_| try entities.tickThrown(gpa, &w, &[_]*Player{&player}, &rand);

    try std.testing.expectEqual(@as(usize, 0), entities.thrown.items.len);
    var poofs: usize = 0;
    for (entities.particles.items) |particle| {
        if (particle.kind == .slime) poofs += 1;
    }
    try std.testing.expectEqual(Thrown.poof_particles, poofs);
}

test "a snowball bursts against a wall and hatches nothing" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();
    var y: i32 = 1;
    while (y <= 4) : (y += 1) try w.setBlockWithNotify(12, y, 8, .stone);

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(5);
    var player = archer(math.Vec3.init(8.5, 1, 8.5), -90, 0);

    const throws = 200;
    for (0..throws) |_| {
        try entities.throwItem(gpa, .snowball, &player, &rand);
        try std.testing.expectEqual(Thrown.Kind.snowball, entities.thrown.items[0].kind);
        for (0..4) |_| try entities.tickThrown(gpa, &w, &[_]*Player{&player}, &rand);
    }

    try std.testing.expectEqual(@as(usize, 0), entities.thrown.items.len);
    try std.testing.expectEqual(@as(usize, 0), entities.countOf(mob.chicken));
}

test "a snowball thrown at a pig bursts on it and leaves it unhurt" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(1);
    try entities.spawnPig(gpa, math.Vec3.init(8.5, 1, 12.5));
    const before = entities.first(Pig, mob.pig).?.animal.health;

    var player = archer(math.Vec3.init(8.5, 1, 8.5), 0, 15);
    try entities.throwItem(gpa, .snowball, &player, &rand);

    for (0..4) |_| try entities.tickThrown(gpa, &w, &[_]*Player{&player}, &rand);

    try std.testing.expectEqual(@as(usize, 0), entities.thrown.items.len);
    try std.testing.expectEqual(before, entities.first(Pig, mob.pig).?.animal.health);
}

test "an egg thrown at a pig bursts on it and leaves it unhurt" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(1);
    try entities.spawnPig(gpa, math.Vec3.init(8.5, 1, 12.5));
    const before = entities.first(Pig, mob.pig).?.animal.health;

    var player = archer(math.Vec3.init(8.5, 1, 8.5), 0, 15);
    try entities.throwItem(gpa, .egg, &player, &rand);

    for (0..4) |_| try entities.tickThrown(gpa, &w, &[_]*Player{&player}, &rand);

    try std.testing.expectEqual(@as(usize, 0), entities.thrown.items.len);
    try std.testing.expectEqual(before, entities.first(Pig, mob.pig).?.animal.health);
}

test "eggs broken against a wall hatch a chicken now and then" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();
    var y: i32 = 1;
    while (y <= 4) : (y += 1) try w.setBlockWithNotify(12, y, 8, .stone);

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(5);
    var player = archer(math.Vec3.init(8.5, 1, 8.5), -90, 0);

    const throws = 200;
    for (0..throws) |_| {
        try entities.throwItem(gpa, .egg, &player, &rand);
        for (0..4) |_| try entities.tickThrown(gpa, &w, &[_]*Player{&player}, &rand);
    }

    const hatched = entities.countOf(mob.chicken);
    try std.testing.expect(hatched > 0);
    try std.testing.expect(hatched < throws);
}

test "a dispenser throws an egg instead of dropping it" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(2);
    try entities.dispense(gpa, .{
        .pos = .{ .x = 8, .y = 2, .z = 8 },
        .step = .{ 1, 0 },
        .stack = .{ .id = .{ .item = .egg }, .count = 1 },
    }, &rand);

    try std.testing.expectEqual(@as(usize, 1), entities.thrown.items.len);
    try std.testing.expectEqual(@as(usize, 0), entities.items.items.len);
    try std.testing.expect(entities.thrown.items[0].base.motion.x > 1.0);
}

test "a dispenser throws a snowball instead of dropping it" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(2);
    try entities.dispense(gpa, .{
        .pos = .{ .x = 8, .y = 2, .z = 8 },
        .step = .{ 1, 0 },
        .stack = .{ .id = .{ .item = .snowball }, .count = 1 },
    }, &rand);

    try std.testing.expectEqual(@as(usize, 1), entities.thrown.items.len);
    try std.testing.expectEqual(@as(usize, 0), entities.items.items.len);
    try std.testing.expectEqual(Thrown.Kind.snowball, entities.thrown.items[0].kind);
    try std.testing.expect(entities.thrown.items[0].base.motion.x > 1.0);
}

test "a rolling empty cart scoops up a pig it runs into, and a chest cart does not" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 12);
    defer w.deinit();
    var step: i32 = 4;
    while (step <= 12) : (step += 1) try w.setBlockWithNotify(step, 12, 8, .rail);

    var rand = world.JavaRandom.init(3);

    var entities: Entities = .{};
    defer entities.deinit(gpa);
    try entities.spawnPig(gpa, math.Vec3.init(8.5, 12.15, 8.5));
    const cart_id = try entities.spawnMinecart(gpa, math.Vec3.init(7.5, 12.5, 8.5), .empty);
    entities.minecartById(cart_id).?.base.motion = math.Vec3.init(0.3, 0, 0);

    for (0..6) |_| try entities.tickMinecarts(gpa, &w, &.{}, &rand);

    const pig = entities.first(Pig, mob.pig).?;
    try std.testing.expectEqual(cart_id, pig.animal.riding);
    try std.testing.expectEqual(pig.animal.base.id, entities.minecartById(cart_id).?.rider);
}

fn railedWorld(gpa: std.mem.Allocator) !world.World {
    var w = try world.testing.flatWorld(gpa, 12);
    errdefer w.deinit();
    var step: i32 = 4;
    while (step <= 14) : (step += 1) try w.setBlockWithNotify(step, 12, 8, .rail);
    return w;
}

test "a cart is stopped by whatever is standing on the track, not driven through it" {
    const gpa = std.testing.allocator;
    var w = try railedWorld(gpa);
    defer w.deinit();
    var rand = world.JavaRandom.init(3);

    var clear: Entities = .{};
    defer clear.deinit(gpa);
    const rolling = try clear.spawnMinecart(gpa, math.Vec3.init(7.5, 12.5, 8.5), .chest);
    clear.minecartById(rolling).?.base.motion = math.Vec3.init(0.3, 0, 0);
    for (0..8) |_| try clear.tickMinecarts(gpa, &w, &.{}, &rand);
    try std.testing.expect(clear.minecartById(rolling).?.base.position.x > 9.5);

    var blocked: Entities = .{};
    defer blocked.deinit(gpa);
    var dropped = ItemEntity.spawn(math.Vec3.init(9.5, 12.15, 8.5), .{ .id = .{ .block = .stone }, .count = 1 }, &rand);
    dropped.base.motion = math.Vec3.init(0, 0, 0);
    try blocked.items.append(gpa, dropped);
    const halted = try blocked.spawnMinecart(gpa, math.Vec3.init(7.5, 12.5, 8.5), .chest);
    blocked.minecartById(halted).?.base.motion = math.Vec3.init(0.3, 0, 0);
    for (0..8) |_| try blocked.tickMinecarts(gpa, &w, &.{}, &rand);
    try std.testing.expect(blocked.minecartById(halted).?.base.position.x < 9.0);
}

test "boarding a cart bumps a mob out of the seat but leaves another player's seat alone" {
    const gpa = std.testing.allocator;
    var entities: Entities = .{};
    defer entities.deinit(gpa);

    try entities.spawnPig(gpa, math.Vec3.init(8.5, 12.15, 8.5));
    const cart_id = try entities.spawnMinecart(gpa, math.Vec3.init(8.5, 12.5, 8.5), .empty);
    const pig = entities.first(Pig, mob.pig).?;

    const cart = entities.minecartById(cart_id).?;
    cart.rider = pig.animal.base.id;
    pig.animal.riding = cart_id;

    const rider: Entity.Id = 4096;
    try std.testing.expect(entities.boardMinecart(cart, rider));
    try std.testing.expectEqual(rider, cart.rider);
    try std.testing.expectEqual(Entity.no_id, pig.animal.riding);

    try std.testing.expect(!entities.boardMinecart(cart, 4097));
    try std.testing.expectEqual(rider, cart.rider);
    try std.testing.expect(entities.boardMinecart(cart, rider));
}

test "boarding one cart empties the seat you left behind" {
    const gpa = std.testing.allocator;
    var entities: Entities = .{};
    defer entities.deinit(gpa);

    const first_cart = try entities.spawnMinecart(gpa, math.Vec3.init(8.5, 12.5, 8.5), .empty);
    const second_cart = try entities.spawnMinecart(gpa, math.Vec3.init(10.5, 12.5, 8.5), .empty);

    const rider: Entity.Id = 4096;
    try std.testing.expect(entities.boardMinecart(entities.minecartById(first_cart).?, rider));
    try std.testing.expect(entities.boardMinecart(entities.minecartById(second_cart).?, rider));

    try std.testing.expectEqual(Entity.no_id, entities.minecartById(first_cart).?.rider);
    try std.testing.expectEqual(rider, entities.minecartById(second_cart).?.rider);
}

test "a wrecked cart sets its passenger down on top of where it stood" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 12);
    defer w.deinit();
    var step: i32 = 4;
    while (step <= 12) : (step += 1) try w.setBlockWithNotify(step, 12, 8, .rail);

    var rand = world.JavaRandom.init(3);
    var entities: Entities = .{};
    defer entities.deinit(gpa);

    try entities.spawnPig(gpa, math.Vec3.init(8.5, 12.15, 8.5));
    const cart_id = try entities.spawnMinecart(gpa, math.Vec3.init(7.5, 12.5, 8.5), .empty);
    entities.minecartById(cart_id).?.base.motion = math.Vec3.init(0.3, 0, 0);
    for (0..6) |_| try entities.tickMinecarts(gpa, &w, &.{}, &rand);

    const pig = entities.first(Pig, mob.pig).?;
    try std.testing.expectEqual(cart_id, pig.animal.riding);

    const wreck = entities.minecartById(cart_id).?;
    const stood_at = wreck.base;
    _ = wreck.hurt(5);
    try entities.tickMinecarts(gpa, &w, &.{}, &rand);

    try std.testing.expect(entities.minecartById(cart_id) == null);
    try std.testing.expectEqual(Entity.no_id, pig.animal.riding);
    try std.testing.expect(pig.animal.base.position.y >= stood_at.position.y + Minecart.height - 1.0e-9);
}

test "a chest cart bumps a pig aside instead of carrying it" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 12);
    defer w.deinit();
    var step: i32 = 4;
    while (step <= 12) : (step += 1) try w.setBlockWithNotify(step, 12, 8, .rail);

    var rand = world.JavaRandom.init(3);

    var entities: Entities = .{};
    defer entities.deinit(gpa);
    try entities.spawnPig(gpa, math.Vec3.init(8.5, 12.15, 8.5));
    const cart_id = try entities.spawnMinecart(gpa, math.Vec3.init(7.5, 12.5, 8.5), .chest);
    entities.minecartById(cart_id).?.base.motion = math.Vec3.init(0.3, 0, 0);

    var nudged = false;
    for (0..6) |_| {
        try entities.tickMinecarts(gpa, &w, &.{}, &rand);
        if (entities.first(Pig, mob.pig).?.animal.base.motion.x != 0) nudged = true;
    }

    const pig = entities.first(Pig, mob.pig).?;
    try std.testing.expectEqual(Entity.no_id, pig.animal.riding);
    try std.testing.expect(nudged);
}

test "a dispenser lobs an ordinary stack out of its face" {
    const gpa = std.testing.allocator;
    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(4);
    try entities.dispense(gpa, .{
        .pos = .{ .x = 8, .y = 12, .z = 8 },
        .step = .{ 0, 1 },
        .stack = .{ .id = .{ .block = .cobblestone }, .count = 1 },
    }, &rand);

    try std.testing.expectEqual(@as(usize, 1), entities.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), entities.arrows.items.len);

    const thrown = entities.items.items[0];
    try std.testing.expectApproxEqAbs(@as(f64, 8.5), thrown.base.position.x, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 12.2), thrown.base.position.y, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 9.1), thrown.base.position.z, 1.0e-9);
    try std.testing.expect(thrown.base.motion.z > 0.1);
    try std.testing.expect(@abs(thrown.base.motion.x) < 0.1);
    try std.testing.expect(thrown.canPickUp());
}

test "a dispenser loaded with arrows shoots them instead of dropping them" {
    const gpa = std.testing.allocator;
    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(4);
    try entities.dispense(gpa, .{
        .pos = .{ .x = 8, .y = 12, .z = 8 },
        .step = .{ -1, 0 },
        .stack = .{ .id = .{ .item = .arrow }, .count = 1 },
    }, &rand);

    try std.testing.expectEqual(@as(usize, 1), entities.arrows.items.len);
    try std.testing.expectEqual(@as(usize, 0), entities.items.items.len);

    const shot = entities.arrows.items[0];
    try std.testing.expectApproxEqAbs(@as(f64, 7.9), shot.base.position.x, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 12.5), shot.base.position.y, 1.0e-9);
    try std.testing.expect(shot.base.motion.x < -1.0);
    try std.testing.expect(shot.from_player);
    try std.testing.expectEqual(Entity.no_id, shot.owner);
}

test "a firing dispenser puffs smoke out of the face it fired from" {
    const gpa = std.testing.allocator;
    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(4);
    try entities.dispense(gpa, .{
        .pos = .{ .x = 8, .y = 12, .z = 8 },
        .step = .{ 0, 1 },
        .stack = .{ .id = .{ .block = .cobblestone }, .count = 1 },
    }, &rand);

    try std.testing.expectEqual(@as(usize, dispense_puffs), entities.particles.items.len);

    for (entities.particles.items) |puff| {
        try std.testing.expectEqual(Particle.Kind.smoke, puff.kind);
        try std.testing.expectApproxEqAbs(@as(f64, 9.11), puff.base.position.z, 1.0e-9);
        try std.testing.expectApproxEqAbs(@as(f64, 8.5), puff.base.position.x, 0.25);
        try std.testing.expectApproxEqAbs(@as(f64, 12.5), puff.base.position.y, 0.25);
    }
}

test "an arrow a skeleton loosed credits the skeleton, not the nearest player" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(1);
    try entities.spawnSkeleton(gpa, math.Vec3.init(8.5, 1, 8.5));
    try entities.spawnCreeper(gpa, math.Vec3.init(8.5, 1, 12.5));

    const bowman = entities.first(Skeleton, mob.skeleton).?.animal.base.id;
    const quarry = entities.first(Creeper, mob.creeper).?;
    quarry.animal.health = 1;

    try entities.loose(gpa, .{
        .owner = bowman,
        .from = math.Vec3.init(8.5, 2, 8.5),
        .toward = math.Vec3.init(0, 0, 1),
    }, &rand);

    var player = archer(math.Vec3.init(0.5, 1, 0.5), 0, 0);
    for (0..8) |_| try entities.tickArrows(gpa, &w, &[_]*Player{&player}, &rand);

    try std.testing.expect(!quarry.animal.isAlive());
    const killer = quarry.animal.killer.?;
    try std.testing.expectEqual(bowman, killer.mob);
    try std.testing.expectEqual(@as(?mob.Id, mob.skeleton), killer.mob_type);
    try std.testing.expectEqual(Animal.Entity.no_id, killer.player);
    try std.testing.expect(quarry.pending_record != null);
}

test "an arrow ignores the archer who just fired it" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(1);
    var player = archer(math.Vec3.init(8.5, 1, 8.5), 0, 0);
    try entities.shootArrow(gpa, &player, &rand);

    const chest = math.Vec3.init(player.base.position.x, player.base.position.y + 1.0, player.base.position.z);
    entities.arrows.items[0].base.position = chest;
    entities.arrows.items[0].base.motion = math.Vec3.init(0.01, 0, 0);
    for (0..Arrow.owner_grace_ticks - 1) |_| {
        try entities.tickArrows(gpa, &w, &[_]*Player{&player}, &rand);
        entities.arrows.items[0].base.position = chest;
    }
    try std.testing.expectEqual(@as(i32, 20), player.health);

    try entities.tickArrows(gpa, &w, &[_]*Player{&player}, &rand);
    try std.testing.expectEqual(@as(i32, 20 - Arrow.damage), player.health);
}

test "an arrow resting in a block is collected back into the quiver" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(1);
    var player = archer(math.Vec3.init(8.5, 1, 8.5), 0, 0);

    var arrow: Arrow = .{
        .base = Entity.init(math.Vec3.init(8.5, 1.5, 8.5), Arrow.size, Arrow.size),
        .from_player = true,
        .in_ground = true,
        .shake = 2,
        .tile = .{ 8, 0, 8 },
    };
    arrow.in_tile = w.getBlock(8, 0, 8);
    try entities.arrows.append(gpa, arrow);

    try entities.tickArrows(gpa, &w, &[_]*Player{&player}, &rand);
    try std.testing.expectEqual(@as(usize, 1), entities.arrows.items.len);
    try std.testing.expect(player.inventory.slots[0] == null);

    try entities.tickArrows(gpa, &w, &[_]*Player{&player}, &rand);
    try std.testing.expectEqual(@as(usize, 0), entities.arrows.items.len);
    try std.testing.expectEqual(world.Id{ .item = .arrow }, player.inventory.slots[0].?.id);
    try std.testing.expectEqual(@as(u8, 1), player.inventory.slots[0].?.count);
    try std.testing.expectEqual(@as(usize, 1), entities.pickups.items.len);
}

test "an arrow still in flight is not collectable" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(1);
    var player = archer(math.Vec3.init(8.5, 1, 8.5), 0, 0);
    try entities.shootArrow(gpa, &player, &rand);
    entities.arrows.items[0].base.position = math.Vec3.init(8.5, 1.5, 8.5);

    try entities.tickArrows(gpa, &w, &[_]*Player{&player}, &rand);
    try std.testing.expect(player.inventory.slots[0] == null);
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

    var player = Player.spawn(math.Vec3.init(0, 1, 0));
    try soloTick(&entities, gpa, &w, &player, &rand);

    try std.testing.expect(entities.first(Pig, mob.pig).?.animal.base.motion.x < 0.0);
    try std.testing.expect(entities.first(Sheep, mob.sheep).?.animal.base.motion.x > 0.0);
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

test "wading into water throws a ring of bubbles and splash droplets at the surface" {
    const gpa = std.testing.allocator;
    var w = world.World.init(gpa);
    defer w.deinit();
    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(6);
    var base = Entity.init(math.Vec3.init(8, 4.4, 8), 0.6, 1.8);
    base.motion = math.Vec3.init(0, -0.3, 0);
    try entities.spawnWaterSplash(gpa, &w, base, &rand);

    try std.testing.expectEqual(@as(usize, 26), entities.particles.items.len);
    for (entities.particles.items, 0..) |droplet, i| {
        const expected: Particle.Kind = if (i < 13) .bubble else .splash;
        try std.testing.expectEqual(expected, droplet.kind);
        try std.testing.expectApproxEqAbs(@as(f64, 5.0), droplet.base.position.y, 1.0e-9);
        try std.testing.expect(@abs(droplet.base.position.x - 8.0) <= 0.6);
    }
}

const SplashSound = struct {
    key: []const u8 = "",
    volume: f32 = 0,
    pitch: f32 = 0,
    count: usize = 0,

    fn record(context: *anyopaque, sound: assets.Sound, _: f64, _: f64, _: f64, volume: f32, pitch: f32) void {
        const self: *SplashSound = @ptrCast(@alignCast(context));
        self.key = sound.key;
        self.volume = volume;
        self.pitch = pitch;
        self.count += 1;
    }

    fn ignoreRecord(_: *anyopaque, _: ?[]const u8, _: i32, _: i32, _: i32) void {}

    fn sink(self: *SplashSound) world.World.SoundSink {
        return .{ .context = self, .playSound = record, .playRecord = ignoreRecord };
    }
};

test "hitting the water is heard, and the loudest a fall can splash is full volume" {
    const gpa = std.testing.allocator;
    var w = world.World.init(gpa);
    defer w.deinit();

    var heard: SplashSound = .{};
    w.sound_sink = heard.sink();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(6);
    var base = Entity.init(math.Vec3.init(8, 4.4, 8), 0.6, 1.8);
    base.motion = math.Vec3.init(0, -0.3, 0);
    try entities.spawnWaterSplash(gpa, &w, base, &rand);

    try std.testing.expectEqual(@as(usize, 1), heard.count);
    try std.testing.expectEqualStrings(assets.sounds.random.splash.key, heard.key);
    try std.testing.expectApproxEqAbs(@as(f32, 0.06), heard.volume, 1.0e-5);
    try std.testing.expect(heard.pitch >= 0.6 and heard.pitch <= 1.4);

    base.motion = math.Vec3.init(0, -30.0, 0);
    try entities.spawnWaterSplash(gpa, &w, base, &rand);
    try std.testing.expectEqual(@as(f32, 1.0), heard.volume);
}

test "drowning coughs up eight bubbles around the entity" {
    const gpa = std.testing.allocator;
    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(6);
    try entities.spawnDrowningBubbles(
        gpa,
        math.Vec3.init(8, 40, 8),
        math.Vec3.init(0, 0, 0),
        &rand,
    );

    try std.testing.expectEqual(drowning_bubbles, entities.particles.items.len);
    for (entities.particles.items) |bubble| {
        try std.testing.expectEqual(Particle.Kind.bubble, bubble.kind);
        try std.testing.expect(@abs(bubble.base.position.x - 8.0) <= 1.0);
        try std.testing.expect(@abs(bubble.base.position.y - 40.0) <= 1.0);
        try std.testing.expect(@abs(bubble.base.position.z - 8.0) <= 1.0);
    }
}

test "a hit particle lands on the face being mined" {
    const gpa = std.testing.allocator;
    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(4);
    try entities.spawnBlockHitParticle(gpa, 5, 9, 3, world.Side.up, full_cube, 1, .{ 255, 255, 255 }, &rand);
    try entities.spawnBlockHitParticle(gpa, 5, 9, 3, world.Side.west, full_cube, 1, .{ 255, 255, 255 }, &rand);

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
    try entities.spawnBlockHitParticle(gpa, 0, 0, 0, world.Side.up, full_cube, 1, .{ 255, 255, 255 }, &rand);
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

    try entities.tickItems(gpa, &w, &[_]*Player{&player}, &w.rand);

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

    try entities.tickItems(gpa, &w, &[_]*Player{&player}, &w.rand);

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

    const cow = entities.first(Cow, mob.cow).?.animal.base.id;
    const eye = math.Vec3.init(0, 1, 0);
    try std.testing.expectEqual(Target{ .mob = cow }, entities.pick(eye, .{ 0, 0, 1 }, entity_reach).?);
    try std.testing.expect(entities.pick(eye, .{ 0, 0, -1 }, entity_reach) == null);
    try std.testing.expect(entities.pick(eye, .{ 0, 1, 0 }, entity_reach) == null);
}

test "an animal beyond the three block reach is not picked" {
    const gpa = std.testing.allocator;
    var entities: Entities = .{};
    defer entities.deinit(gpa);
    try entities.spawnCow(gpa, math.Vec3.init(0, 0, 6));

    const cow = entities.first(Cow, mob.cow).?.animal.base.id;
    const eye = math.Vec3.init(0, 1, 0);
    try std.testing.expect(entities.pick(eye, .{ 0, 0, 1 }, entity_reach) == null);
    try std.testing.expectEqual(Target{ .mob = cow }, entities.pick(eye, .{ 0, 0, 1 }, 8.0).?);
}

test "the nearer of two animals in a line is the one picked" {
    const gpa = std.testing.allocator;
    var entities: Entities = .{};
    defer entities.deinit(gpa);

    try entities.spawnCow(gpa, math.Vec3.init(0, 0, 3));
    try entities.spawnPig(gpa, math.Vec3.init(0, 0, 1.5));

    const eye = math.Vec3.init(0, 1, 0);
    const picked = entities.pick(eye, .{ 0, 0, 1 }, entity_reach).?;
    try std.testing.expectEqual(mob.pig, entities.mobAt(picked).?.type_id);
}

test "a dead animal is no longer picked" {
    const gpa = std.testing.allocator;
    var entities: Entities = .{};
    defer entities.deinit(gpa);
    try entities.spawnCow(gpa, math.Vec3.init(0, 0, 2));

    const eye = math.Vec3.init(0, 1, 0);
    try std.testing.expect(entities.pick(eye, .{ 0, 0, 1 }, entity_reach) != null);

    entities.first(Cow, mob.cow).?.animal.health = 0;
    try std.testing.expect(entities.pick(eye, .{ 0, 0, 1 }, entity_reach) == null);
}

test "a hit takes health off the animal the crosshair found" {
    var w = world.World.init(std.testing.allocator);
    defer w.deinit();
    const gpa = std.testing.allocator;
    var entities: Entities = .{};
    defer entities.deinit(gpa);
    var rand = world.JavaRandom.init(0);

    try entities.spawnCow(gpa, math.Vec3.init(0, 0, 2));
    const before = entities.first(Cow, mob.cow).?.animal.health;

    const cow = entities.first(Cow, mob.cow).?.animal.base.id;
    _ = entities.hurtTarget(&w, .{ .mob = cow }, 4, .{ .position = math.Vec3.init(0, 1, 0) }, &rand);
    try std.testing.expectEqual(before - 4, entities.first(Cow, mob.cow).?.animal.health);
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

test "hit particles off a pressure plate stay down at plate height, not mid block" {
    const gpa = std.testing.allocator;
    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(4);
    const plate = world.Block.pressure_plate_stone;
    const bounds = plate.selectionBounds(0);

    for (0..64) |_| {
        try entities.spawnBlockHitParticle(gpa, 5, 9, 3, world.Side.up, bounds, 1, .{ 255, 255, 255 }, &rand);
    }

    for (entities.particles.items) |particle| {
        try std.testing.expectApproxEqAbs(
            @as(f64, 9.0) + bounds.max[1] + hit_inset,
            particle.base.position.y,
            1.0e-9,
        );
        try std.testing.expect(particle.base.position.x >= 5.0 + bounds.min[0]);
        try std.testing.expect(particle.base.position.x <= 5.0 + bounds.max[0]);
    }
}

test "hit particles off a full cube still span the whole block face" {
    const gpa = std.testing.allocator;
    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(4);
    for (0..64) |_| {
        try entities.spawnBlockHitParticle(gpa, 0, 0, 0, world.Side.west, full_cube, 1, .{ 255, 255, 255 }, &rand);
    }

    var lowest: f64 = std.math.floatMax(f64);
    var highest: f64 = -std.math.floatMax(f64);
    for (entities.particles.items) |particle| {
        try std.testing.expectApproxEqAbs(-hit_inset, particle.base.position.x, 1.0e-9);
        lowest = @min(lowest, particle.base.position.y);
        highest = @max(highest, particle.base.position.y);
    }
    try std.testing.expect(lowest >= hit_inset);
    try std.testing.expect(highest <= 1.0 - hit_inset);
}

test "a mob type registered at runtime ticks and is stored alongside the vanilla ones" {
    const gpa = std.testing.allocator;
    defer mob.reset();

    const rosebug = mob.register(.{
        .name = "Rosebug",
        .spawn = mob.get(mob.pig).spawn,
        .tick = mob.get(mob.pig).tick,
        .takeDrops = mob.get(mob.pig).takeDrops,
        .store = mob.get(mob.pig).store,
        .load = mob.get(mob.pig).load,
        .destroy = mob.get(mob.pig).destroy,
    });

    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(7);
    try entities.spawnPig(gpa, math.Vec3.init(8.5, 1, 8.5));
    _ = try entities.spawnMob(gpa, rosebug, math.Vec3.init(10.5, 1, 10.5), &rand);

    try std.testing.expectEqual(@as(usize, 1), entities.countOf(mob.pig));
    try std.testing.expectEqual(@as(usize, 1), entities.countOf(rosebug));
    try std.testing.expectEqual(@as(usize, 2), entities.count());

    var player = Player.spawn(math.Vec3.init(0, 1, 0));
    const before = entities.mobs.items[1].animal.base.position;
    for (0..20) |_| try soloTick(&entities, gpa, &w, &player, &rand);

    try std.testing.expectEqual(@as(usize, 2), entities.mobs.items.len);
    try std.testing.expectEqual(rosebug, entities.mobs.items[1].type_id);
    try std.testing.expect(entities.mobs.items[1].animal.isAlive());
    try std.testing.expectApproxEqAbs(before.y, entities.mobs.items[1].animal.base.position.y, 1.0e-9);
}

test "a registered type outnumbering the vanilla ones still ticks in insertion order" {
    const gpa = std.testing.allocator;
    var entities: Entities = .{};
    defer entities.deinit(gpa);

    try entities.spawnCow(gpa, math.Vec3.init(0, 1, 0));
    try entities.spawnPig(gpa, math.Vec3.init(2, 1, 0));
    try entities.spawnCow(gpa, math.Vec3.init(4, 1, 0));

    try std.testing.expectEqual(mob.cow, entities.mobs.items[0].type_id);
    try std.testing.expectEqual(mob.pig, entities.mobs.items[1].type_id);
    try std.testing.expectEqual(mob.cow, entities.mobs.items[2].type_id);
}

fn soloTick(
    entities: *Entities,
    gpa: std.mem.Allocator,
    world_map: *world.World,
    player: *Player,
    rand: *world.JavaRandom,
) !void {
    const roster = [_]*Player{player};
    const views = [_]Animal.PlayerView{viewOf(player)};
    try entities.tickMobs(gpa, world_map, &roster, .of(&views), rand);
}

test "killing a monster earns Monster Hunter, killing an animal does not" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    const cases = [_]struct { type_id: mob.Id, earns: bool }{
        .{ .type_id = mob.zombie, .earns = true },
        .{ .type_id = mob.cow, .earns = false },
    };

    for (cases) |case| {
        var entities: Entities = .{};
        defer entities.deinit(gpa);

        var rand = world.JavaRandom.init(3);
        var player = Player.spawn(math.Vec3.init(8.5, 1, 8.5));
        player.base.id = 7;

        const animal = try entities.spawnMob(gpa, case.type_id, math.Vec3.init(10.5, 1, 8.5), &rand);
        _ = animal.hurt(&w, animal.max_health, .{ .position = player.base.position, .player = player.base.id }, &rand);
        animal.dead = true;

        try soloTick(&entities, gpa, &w, &player, &rand);
        try std.testing.expectEqual(case.earns, player.earned.contains(.kill_enemy));
    }
}

test "a mob standing on a cactus is pricked by it" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();
    w.setBlock(8, 1, 8, .cactus);

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(3);
    var player = Player.spawn(math.Vec3.init(0.5, 1, 0.5));
    const pig = try entities.spawnMob(gpa, mob.pig, math.Vec3.init(8.5, 2.0 - 1.0 / 16.0, 8.5), &rand);
    const unhurt = pig.health;

    try soloTick(&entities, gpa, &w, &player, &rand);
    try std.testing.expectEqual(unhurt - cactus_damage, pig.health);
}

test "a monster that dies with nobody to blame earns nothing" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(3);
    var player = Player.spawn(math.Vec3.init(8.5, 1, 8.5));
    player.base.id = 7;

    const animal = try entities.spawnMob(gpa, mob.zombie, math.Vec3.init(10.5, 1, 8.5), &rand);
    _ = animal.hurt(&w, animal.max_health, null, &rand);
    animal.dead = true;

    try soloTick(&entities, gpa, &w, &player, &rand);
    try std.testing.expect(!player.earned.contains(.kill_enemy));
}

test "an untamed wolf that rolls a hunt takes a nearby sheep as its target" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(1);
    try entities.spawnWolf(gpa, math.Vec3.init(8.5, 1, 8.5), &rand);
    try entities.spawnSheep(gpa, math.Vec3.init(12.5, 1, 8.5), &rand);

    const wolf = entities.first(Wolf, mob.wolf).?;
    wolf.hunting = true;

    var player = Player.spawn(math.Vec3.init(0, 1, 0));
    try soloTick(&entities, gpa, &w, &player, &rand);

    try std.testing.expect(wolf.target != null);
    try std.testing.expectEqual(&entities.first(Sheep, mob.sheep).?.animal, wolf.target.?.prey);
    try std.testing.expect(wolf.prey_view != null);
}

test "a sheep out of range is never hunted" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(1);
    try entities.spawnWolf(gpa, math.Vec3.init(8.5, 1, 8.5), &rand);
    try entities.spawnSheep(gpa, math.Vec3.init(80.5, 1, 8.5), &rand);

    const wolf = entities.first(Wolf, mob.wolf).?;
    wolf.hunting = true;

    var player = Player.spawn(math.Vec3.init(0, 1, 0));
    try soloTick(&entities, gpa, &w, &player, &rand);

    try std.testing.expect(wolf.target == null);
}

test "a wolf's bite lands on the sheep it is hunting" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(1);
    try entities.spawnWolf(gpa, math.Vec3.init(8.5, 1, 8.5), &rand);
    try entities.spawnSheep(gpa, math.Vec3.init(9.0, 1, 8.5), &rand);

    const wolf = entities.first(Wolf, mob.wolf).?;
    const sheep = entities.first(Sheep, mob.sheep).?;
    wolf.target = .{ .prey = &sheep.animal };
    wolf.pending_bite = Wolf.bite_damage;

    var player = Player.spawn(math.Vec3.init(0, 1, 0));
    try soloTick(&entities, gpa, &w, &player, &rand);

    try std.testing.expectEqual(Sheep.max_health - Wolf.bite_damage, sheep.animal.health);
    try std.testing.expectEqual(@as(i32, 0), wolf.pending_bite);
}

test "a wolf whose prey is gone forgets it rather than chasing a ghost" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(1);
    try entities.spawnWolf(gpa, math.Vec3.init(8.5, 1, 8.5), &rand);
    try entities.spawnSheep(gpa, math.Vec3.init(10.5, 1, 8.5), &rand);

    const wolf = entities.first(Wolf, mob.wolf).?;
    const sheep = entities.first(Sheep, mob.sheep).?;
    wolf.target = .{ .prey = &sheep.animal };

    var player = Player.spawn(math.Vec3.init(0, 1, 0));
    try soloTick(&entities, gpa, &w, &player, &rand);
    try std.testing.expect(wolf.target != null);

    sheep.animal.health = 0;
    sheep.animal.dead = true;
    try soloTick(&entities, gpa, &w, &player, &rand);
    try std.testing.expectEqual(@as(usize, 0), entities.countOf(mob.sheep));

    try soloTick(&entities, gpa, &w, &player, &rand);
    try std.testing.expect(wolf.target == null);
    try std.testing.expect(wolf.prey_view == null);
}

test "hitting one wolf of a pack turns the whole pack on the player" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(1);
    try entities.spawnWolf(gpa, math.Vec3.init(8.5, 1, 8.5), &rand);
    try entities.spawnWolf(gpa, math.Vec3.init(12.5, 1, 8.5), &rand);
    try entities.spawnWolf(gpa, math.Vec3.init(60.5, 1, 8.5), &rand);

    const struck = entities.mobs.items[0].animal;
    try std.testing.expect(entities.hurtTarget(&w, .{ .mob = struck.base.id }, 1, .{ .position = math.Vec3.init(6, 1, 8.5) }, &rand));

    var player = Player.spawn(math.Vec3.init(0, 1, 0));
    try soloTick(&entities, gpa, &w, &player, &rand);

    var pack = entities.of(Wolf, mob.wolf);
    var angered: u32 = 0;
    while (pack.next()) |wolf| {
        if (wolf.angry) angered += 1;
        if (&wolf.animal == struck) try std.testing.expect(wolf.target.? == .player);
    }

    try std.testing.expectEqual(@as(u32, 2), angered);
}

test "a tamed wolf sets on whatever its owner strikes, unless it is sitting" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(1);
    try entities.spawnPig(gpa, math.Vec3.init(9.5, 1, 8.5));
    try entities.spawnWolf(gpa, math.Vec3.init(6.5, 1, 8.5), &rand);
    try entities.spawnWolf(gpa, math.Vec3.init(7.5, 1, 8.5), &rand);

    var pack = entities.of(Wolf, mob.wolf);
    const standing = pack.next().?;
    const seated = pack.next().?;
    for ([_]*Wolf{ standing, seated }) |wolf| {
        wolf.tamed = true;
        wolf.animal.max_health = Wolf.tamed_health;
        wolf.animal.health = Wolf.tamed_health;
    }
    seated.sitting = true;

    const struck = entities.mobs.items[0].animal;
    try std.testing.expect(entities.hurtTarget(&w, .{ .mob = struck.base.id }, 1, .{ .position = math.Vec3.init(8.5, 1, 8.5) }, &rand));

    try std.testing.expectEqual(struck, standing.target.?.prey);
    try std.testing.expect(!standing.sitting);
    try std.testing.expect(seated.target == null);
    try std.testing.expect(seated.sitting);
}

test "an angry wolf standing on the player bites into the health bar" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(2);
    var player = Player.spawn(math.Vec3.init(8.5, 1, 8.5));
    try entities.spawnWolf(gpa, math.Vec3.init(8.9, 1, 8.5), &rand);

    const wolf = entities.first(Wolf, mob.wolf).?;
    wolf.angry = true;
    wolf.animal.base.on_ground = true;

    const full = player.health;
    for (0..60) |_| {
        try soloTick(&entities, gpa, &w, &player, &rand);
        if (player.health < full) break;
    }

    try std.testing.expect(player.health < full);
    try std.testing.expect(wolf.target.? == .player);
}

test "a tamed wolf is never counted out of the world by distance" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(1);
    try entities.spawnWolf(gpa, math.Vec3.init(8.5, 1, 8.5), &rand);

    const wolf = entities.first(Wolf, mob.wolf).?;
    wolf.tamed = true;
    wolf.animal.can_despawn = false;

    var player = Player.spawn(math.Vec3.init(8.5, 1, 900));
    for (0..200) |_| try soloTick(&entities, gpa, &w, &player, &rand);

    try std.testing.expectEqual(@as(usize, 1), entities.countOf(mob.wolf));
}

test "a wolf shaking itself dry throws water off its coat" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(1);
    try entities.spawnWolf(gpa, math.Vec3.init(8.5, 1, 8.5), &rand);

    const wolf = entities.first(Wolf, mob.wolf).?;
    wolf.shake_running = true;
    wolf.shake_time = 1.0;

    var player = Player.spawn(math.Vec3.init(0, 1, 0));
    try soloTick(&entities, gpa, &w, &player, &rand);

    try std.testing.expect(entities.particles.items.len > 0);
    for (entities.particles.items) |particle| {
        try std.testing.expectEqual(Particle.Kind.splash, particle.kind);
    }
}

test "every entity in the world is handed its own id" {
    const gpa = std.testing.allocator;
    var entities: Entities = .{};
    defer entities.deinit(gpa);
    var rand = world.JavaRandom.init(0);

    try entities.spawnCow(gpa, math.Vec3.init(0, 1, 0));
    try entities.spawnPig(gpa, math.Vec3.init(2, 1, 0));
    try entities.spawnSheep(gpa, math.Vec3.init(4, 1, 0), &rand);

    var seen: std.AutoHashMapUnmanaged(Entity.Id, void) = .{};
    defer seen.deinit(gpa);

    for (entities.mobs.items) |entry| {
        try std.testing.expect(entry.animal.base.id != Entity.no_id);
        try std.testing.expect(!seen.contains(entry.animal.base.id));
        try seen.put(gpa, entry.animal.base.id, {});
    }
    try std.testing.expectEqual(@as(usize, 3), seen.count());
}

test "a target still names the same animal after an earlier one is removed" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);
    var rand = world.JavaRandom.init(0);

    try entities.spawnCow(gpa, math.Vec3.init(4.5, 1, 4.5));
    try entities.spawnCow(gpa, math.Vec3.init(6.5, 1, 6.5));
    try entities.spawnCow(gpa, math.Vec3.init(8.5, 1, 8.5));

    const doomed = entities.mobs.items[0].animal;
    const watched = entities.mobs.items[2].animal;
    const target: Target = .{ .mob = watched.base.id };
    const middle = entities.mobs.items[1].animal;
    const middle_health = middle.health;

    var player = Player.spawn(math.Vec3.init(0, 1, 0));
    doomed.health = 0;
    doomed.dead = true;
    try soloTick(&entities, gpa, &w, &player, &rand);

    try std.testing.expectEqual(@as(usize, 2), entities.mobs.items.len);
    try std.testing.expectEqual(watched, entities.mobAt(target).?.animal);

    const before = watched.health;
    try std.testing.expect(entities.hurtTarget(&w, target, 3, .{ .position = math.Vec3.init(0, 1, 0) }, &rand));
    try std.testing.expectEqual(before - 3, watched.health);
    try std.testing.expectEqual(middle_health, middle.health);
}

test "a target naming an animal that has gone hits nothing at all" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);
    var rand = world.JavaRandom.init(0);

    try entities.spawnCow(gpa, math.Vec3.init(8.5, 1, 8.5));
    const doomed = entities.mobs.items[0].animal;
    const stale: Target = .{ .mob = doomed.base.id };

    var player = Player.spawn(math.Vec3.init(0, 1, 0));
    doomed.health = 0;
    doomed.dead = true;
    try soloTick(&entities, gpa, &w, &player, &rand);

    try std.testing.expectEqual(@as(usize, 0), entities.mobs.items.len);
    try std.testing.expect(entities.mobAt(stale) == null);
    try std.testing.expect(!entities.hurtTarget(&w, stale, 3, .{ .position = math.Vec3.init(0, 1, 0) }, &rand));
}

test "an id is never handed out twice, even after the holder is gone" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);
    var rand = world.JavaRandom.init(0);

    try entities.spawnCow(gpa, math.Vec3.init(8.5, 1, 8.5));
    const retired = entities.mobs.items[0].animal.base.id;

    var player = Player.spawn(math.Vec3.init(0, 1, 0));
    entities.mobs.items[0].animal.health = 0;
    entities.mobs.items[0].animal.dead = true;
    try soloTick(&entities, gpa, &w, &player, &rand);

    try entities.spawnCow(gpa, math.Vec3.init(8.5, 1, 8.5));
    try std.testing.expect(entities.mobs.items[0].animal.base.id != retired);
}

test "a painting is taken down by its id rather than its place in the list" {
    const gpa = std.testing.allocator;
    var entities: Entities = .{};
    defer entities.deinit(gpa);

    try entities.spawnPainting(gpa, .{
        .tile = .{ 8, 4, 8 },
        .direction = 0,
        .art = .kebab,
        .position = math.Vec3.init(8, 4, 8),
        .box = math.Aabb.init(8, 4, 8, 9, 5, 9),
    });
    try entities.spawnPainting(gpa, .{
        .tile = .{ 12, 4, 8 },
        .direction = 0,
        .art = .alban,
        .position = math.Vec3.init(12, 4, 8),
        .box = math.Aabb.init(12, 4, 8, 13, 5, 9),
    });

    const second = entities.paintings.items[1].id;
    try std.testing.expect(entities.paintings.items[0].id != second);

    try std.testing.expectEqual(Painting.Art.alban, entities.removePainting(second).?.art);
    try std.testing.expectEqual(@as(usize, 1), entities.paintings.items.len);
    try std.testing.expectEqual(Painting.Art.kebab, entities.paintings.items[0].art);
    try std.testing.expect(entities.removePainting(second) == null);
}

test "animals loaded back from a save are given fresh ids" {
    const gpa = std.testing.allocator;
    var entities: Entities = .{};
    defer entities.deinit(gpa);

    try entities.spawnCow(gpa, math.Vec3.init(8.5, 1, 8.5));
    const saved = entities.mobs.items[0].animal.base.id;

    var stored = try world.entity_nbt.storeCow(gpa, entities.first(Cow, mob.cow).?.toRecord());
    defer world.nbt.deinit(gpa, &stored);
    try restoreChunkEntity(&entities, gpa, stored.compound);

    try std.testing.expectEqual(@as(usize, 2), entities.mobs.items.len);
    const restored = entities.mobs.items[1].animal.base.id;
    try std.testing.expect(restored != Entity.no_id);
    try std.testing.expect(restored != saved);
}

fn heldCount(player: *const Player, id: world.Id) u32 {
    var total: u32 = 0;
    for (player.inventory.slots) |slot| {
        const stack = slot orelse continue;
        if (stack.id.eql(id)) total += stack.count;
    }
    return total;
}

fn twoPlayerTick(
    entities: *Entities,
    gpa: std.mem.Allocator,
    world_map: *world.World,
    one: *Player,
    two: *Player,
    rand: *world.JavaRandom,
) !void {
    const roster = [_]*Player{ one, two };
    const views = [_]Animal.PlayerView{ viewOf(one), viewOf(two) };
    try entities.tickMobs(gpa, world_map, &roster, .of(&views), rand);
}

test "a slime attacks whichever player is standing on it" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);
    var rand = world.JavaRandom.init(3);

    var far = Player.spawn(math.Vec3.init(60.5, 1, 8.5));
    var near = Player.spawn(math.Vec3.init(8.5, 1, 8.5));
    far.base.id = 1;
    near.base.id = 2;

    try entities.spawnSlime(gpa, math.Vec3.init(8.5, 1, 8.5), &rand);
    entities.first(Slime, mob.slime).?.setSize(4);

    const far_health = far.health;
    const near_health = near.health;
    for (0..40) |_| {
        try twoPlayerTick(&entities, gpa, &w, &far, &near, &rand);
        if (near.health < near_health) break;
    }

    try std.testing.expect(near.health < near_health);
    try std.testing.expectEqual(far_health, far.health);
}

test "a dropped item is picked up by whichever player reaches it" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);
    var rand = world.JavaRandom.init(0);

    var distant = Player.spawn(math.Vec3.init(60.5, 1, 8.5));
    var close_by = Player.spawn(math.Vec3.init(8.5, 1, 8.5));
    distant.base.id = 1;
    close_by.base.id = 2;

    try entities.dropStack(gpa, 8, 1, 8, .{ .id = .{ .item = .bone }, .count = 1 }, &rand);
    for (entities.items.items) |*dropped| dropped.pickup_delay = 0;

    const roster = [_]*Player{ &distant, &close_by };
    for (0..40) |_| {
        try entities.tickItems(gpa, &w, &roster, &rand);
        if (entities.items.items.len == 0) break;
    }

    try std.testing.expectEqual(@as(usize, 0), entities.items.items.len);
    try std.testing.expect(heldCount(&close_by, .{ .item = .bone }) > 0);
    try std.testing.expectEqual(@as(u32, 0), heldCount(&distant, .{ .item = .bone }));
}

test "a wolf roused by one player's blow leaves the other player alone" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);
    var rand = world.JavaRandom.init(1);

    var attacker = Player.spawn(math.Vec3.init(6.5, 1, 8.5));
    var bystander = Player.spawn(math.Vec3.init(9.0, 1, 8.5));
    attacker.base.id = 1;
    bystander.base.id = 2;

    try entities.spawnWolf(gpa, math.Vec3.init(8.5, 1, 8.5), &rand);
    try entities.spawnWolf(gpa, math.Vec3.init(10.5, 1, 8.5), &rand);

    const struck = entities.mobs.items[0].animal;
    try std.testing.expect(entities.hurtTarget(
        &w,
        .{ .mob = struck.base.id },
        1,
        .{ .position = attacker.base.position, .player = attacker.base.id },
        &rand,
    ));

    try twoPlayerTick(&entities, gpa, &w, &attacker, &bystander, &rand);

    var pack = entities.of(Wolf, mob.wolf);
    while (pack.next()) |wolf| {
        try std.testing.expect(wolf.angry);
        try std.testing.expectEqual(attacker.base.id, wolf.target.?.player);
    }
}

test "a portal breathes four particles a tick out of the face it presents" {
    const gpa = std.testing.allocator;
    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(5);
    try entities.spawnPortalParticles(gpa, 8, 64, 8, false, &rand);

    try std.testing.expectEqual(@as(usize, portal_particles_per_tick), entities.particles.items.len);
    for (entities.particles.items) |particle| {
        try std.testing.expectEqual(Particle.Kind.portal, particle.kind);
        const from_middle = @abs(particle.origin.x - 8.5);
        try std.testing.expectApproxEqAbs(portal_mouth_inset, from_middle, 1.0e-9);
        try std.testing.expect(particle.origin.y >= 64.0 and particle.origin.y < 65.0);
        try std.testing.expect(particle.origin.z >= 8.0 and particle.origin.z < 9.0);
        try std.testing.expect(@abs(particle.base.motion.x) > @abs(particle.base.motion.y));
    }
}

test "a portal that runs along x throws its particles across z instead" {
    const gpa = std.testing.allocator;
    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(5);
    try entities.spawnPortalParticles(gpa, 8, 64, 8, true, &rand);

    for (entities.particles.items) |particle| {
        try std.testing.expectApproxEqAbs(portal_mouth_inset, @abs(particle.origin.z - 8.5), 1.0e-9);
        try std.testing.expect(particle.origin.x >= 8.0 and particle.origin.x < 9.0);
        try std.testing.expect(@abs(particle.base.motion.z) > @abs(particle.base.motion.y));
    }
}

test "hitting one pig zombie turns the whole horde within thirty-two blocks on the player" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(3);
    try entities.spawnPigZombie(gpa, math.Vec3.init(8.5, 1, 8.5));
    try entities.spawnPigZombie(gpa, math.Vec3.init(28.5, 1, 8.5));
    try entities.spawnPigZombie(gpa, math.Vec3.init(200.5, 1, 8.5));

    var player = Player.spawn(math.Vec3.init(6.5, 1, 8.5));
    player.base.id = entities.takeId();

    const struck = entities.mobs.items[0].animal.base.id;
    try std.testing.expect(entities.hurtTarget(
        &w,
        .{ .mob = struck },
        1,
        .{ .position = player.base.position, .player = player.base.id },
        &rand,
    ));
    try soloTick(&entities, gpa, &w, &player, &rand);

    var horde = entities.of(PigZombie, mob.pig_zombie);
    var roused: usize = 0;
    while (horde.next()) |pig_zombie| {
        if (pig_zombie.anger_level == 0) continue;
        try std.testing.expectEqual(player.base.id, pig_zombie.monster.target.?);
        roused += 1;
    }

    try std.testing.expectEqual(@as(usize, 2), roused);
}

test "a pig zombie in reach takes five hearts off the player it is angry at" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(3);
    try entities.spawnPigZombie(gpa, math.Vec3.init(8.5, 1, 8.5));

    var player = Player.spawn(math.Vec3.init(9.0, 1, 8.5));
    player.base.id = entities.takeId();

    const pig_zombie = entities.first(PigZombie, mob.pig_zombie).?;
    pig_zombie.becomeAngryAt(player.base.id, &rand);

    const full = player.health;
    for (0..40) |_| {
        try soloTick(&entities, gpa, &w, &player, &rand);
        if (player.health < full) break;
    }

    try std.testing.expectEqual(full - PigZombie.attack_strength, player.health);
}

test "an angry pig zombie comes back angry from its chunk" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var handle = try world.save.open(io, tmp.dir, "Grudge");
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

        try entities.spawnPigZombie(gpa, math.Vec3.init(8.5, 1, 8.5));
        const pig_zombie = entities.first(PigZombie, mob.pig_zombie).?;
        pig_zombie.anger_level = 617;
        pig_zombie.animal.health = 14;

        try w.saveLoadedChunks();
    }

    var reloaded = world.World.init(gpa);
    defer reloaded.deinit();
    reloaded.persistence = .{ .handle = &handle, .io = io };

    var restored: Entities = .{};
    defer restored.deinit(gpa);
    reloaded.entity_io = restored.entityIo();

    _ = try reloaded.getOrGenerateChunk(generator, 0, 0);

    try std.testing.expectEqual(@as(usize, 1), restored.countOf(mob.pig_zombie));
    const pig_zombie = restored.first(PigZombie, mob.pig_zombie).?;
    try std.testing.expectEqual(@as(i32, 617), pig_zombie.anger_level);
    try std.testing.expectEqual(@as(i32, 14), pig_zombie.animal.health);
}

test "a zombie in reach takes five hearts off the player without being provoked" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(3);
    try entities.spawnZombie(gpa, math.Vec3.init(8.5, 1, 8.5));

    var player = Player.spawn(math.Vec3.init(9.0, 1, 8.5));
    player.base.id = entities.takeId();

    const full = player.health;
    for (0..40) |_| {
        try soloTick(&entities, gpa, &w, &player, &rand);
        if (player.health < full) break;
    }

    try std.testing.expectEqual(full - Zombie.attack_strength, player.health);
    try std.testing.expectEqual(player.base.id, entities.first(Zombie, mob.zombie).?.monster.target.?);
}

test "a zombie comes back from its chunk with its wounds" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var handle = try world.save.open(io, tmp.dir, "Shamble");
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

        try entities.spawnZombie(gpa, math.Vec3.init(8.5, 1, 8.5));
        entities.first(Zombie, mob.zombie).?.animal.health = 12;

        try w.saveLoadedChunks();
    }

    var reloaded = world.World.init(gpa);
    defer reloaded.deinit();
    reloaded.persistence = .{ .handle = &handle, .io = io };

    var restored: Entities = .{};
    defer restored.deinit(gpa);
    reloaded.entity_io = restored.entityIo();

    _ = try reloaded.getOrGenerateChunk(generator, 0, 0);

    try std.testing.expectEqual(@as(usize, 1), restored.countOf(mob.zombie));
    try std.testing.expectEqual(@as(usize, 0), restored.countOf(mob.pig_zombie));
    try std.testing.expectEqual(@as(i32, 12), restored.first(Zombie, mob.zombie).?.animal.health);
}

test "a creeper that reaches the player blows a hole in the world and leaves no gunpowder" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 8);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(3);
    try entities.spawnCreeper(gpa, math.Vec3.init(8.5, 8, 8.5));

    var player = Player.spawn(math.Vec3.init(9.0, 8, 8.5));
    player.base.id = entities.takeId();

    const full = player.health;

    for (0..Creeper.fuse_ticks + 4) |_| {
        try soloTick(&entities, gpa, &w, &player, &rand);
        if (entities.countOf(mob.creeper) == 0) break;
    }

    try std.testing.expectEqual(@as(usize, 0), entities.countOf(mob.creeper));
    try std.testing.expect(player.health < full);
    try std.testing.expectEqual(.air, w.getBlock(8, 7, 8));

    for (entities.items.items) |item| {
        try std.testing.expect(item.stack.id != .item or item.stack.id.item != .gunpowder);
    }
}

test "a creeper killed before its fuse runs out leaves its gunpowder behind" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(1);
    try entities.spawnCreeper(gpa, math.Vec3.init(8.5, 1, 8.5));
    const id = entities.mobs.items[0].animal.base.id;

    _ = entities.hurtTarget(&w, .{ .mob = id }, Creeper.max_health, .{ .position = math.Vec3.init(6, 1, 8) }, &rand);
    entities.first(Creeper, mob.creeper).?.pending_drops = 2;

    var player = Player.spawn(math.Vec3.init(0, 1, 0));
    for (0..Animal.death_ticks + 2) |_| try soloTick(&entities, gpa, &w, &player, &rand);

    try std.testing.expectEqual(@as(usize, 0), entities.countOf(mob.creeper));

    var gunpowder: u32 = 0;
    for (entities.items.items) |item| {
        if (item.stack.id == .item and item.stack.id.item == .gunpowder) gunpowder += 1;
    }
    try std.testing.expectEqual(@as(u32, 2), gunpowder);
    try std.testing.expectEqual(.stone, w.getBlock(8, 0, 8));
}

const SoundLog = struct {
    keys: [8][]const u8 = undefined,
    count: usize = 0,

    fn record(context: *anyopaque, sound: assets.Sound, _: f64, _: f64, _: f64, _: f32, _: f32) void {
        const self: *SoundLog = @ptrCast(@alignCast(context));
        if (self.count == self.keys.len) return;
        self.keys[self.count] = sound.key;
        self.count += 1;
    }

    fn ignoreRecord(_: *anyopaque, _: ?[]const u8, _: i32, _: i32, _: i32) void {}

    fn sink(self: *SoundLog) world.World.SoundSink {
        return .{ .context = self, .playSound = record, .playRecord = ignoreRecord };
    }

    fn indexOf(self: SoundLog, key: []const u8) ?usize {
        for (self.keys[0..self.count], 0..) |heard, index| {
            if (std.mem.eql(u8, heard, key)) return index;
        }
        return null;
    }
};

test "a ghast draws breath halfway through its wind-up and barks as the fireball leaves" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var heard: SoundLog = .{};
    w.sound_sink = heard.sink();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(3);
    try entities.spawnGhast(gpa, math.Vec3.init(8.5, 1, 8.5));

    var player = Player.spawn(math.Vec3.init(24.5, 1, 8.5));
    player.base.id = entities.takeId();

    for (0..64) |_| {
        try soloTick(&entities, gpa, &w, &player, &rand);
        if (entities.fireballs.items.len > 0) break;
    }

    try std.testing.expectEqual(@as(usize, 1), entities.fireballs.items.len);

    const charge = heard.indexOf(assets.sounds.mob.ghast.charge.key);
    const shot = heard.indexOf(assets.sounds.mob.ghast.fireball.key);
    try std.testing.expect(charge != null and shot != null);
    try std.testing.expect(charge.? < shot.?);
    try std.testing.expectEqual(@as(i32, Ghast.reload_at), entities.first(Ghast, mob.ghast).?.attack_counter);
}

test "a skeleton that sees the player looses a real arrow into the world" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(3);
    try entities.spawnSkeleton(gpa, math.Vec3.init(8.5, 1, 8.5));

    var player = Player.spawn(math.Vec3.init(14.5, 1, 8.5));
    player.base.id = entities.takeId();

    for (0..8) |_| {
        try soloTick(&entities, gpa, &w, &player, &rand);
        if (entities.arrows.items.len > 0) break;
    }

    try std.testing.expectEqual(@as(usize, 1), entities.arrows.items.len);

    const arrow = entities.arrows.items[0];
    try std.testing.expect(!arrow.from_player);
    try std.testing.expect(arrow.base.motion.x > 0.0);
    try std.testing.expect(arrow.base.position.y > 1.0 + Skeleton.arrow_lift);
    try std.testing.expectEqual(
        @as(?Animal.Entity.Id, player.base.id),
        entities.first(Skeleton, mob.skeleton).?.monster.target,
    );
}

test "a skeleton comes back from its chunk, and leaves arrows and bones when killed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var handle = try world.save.open(io, tmp.dir, "Bones");
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

        try entities.spawnSkeleton(gpa, math.Vec3.init(8.5, 1, 8.5));
        entities.first(Skeleton, mob.skeleton).?.animal.health = 7;

        try w.saveLoadedChunks();
    }

    var reloaded = world.World.init(gpa);
    defer reloaded.deinit();
    reloaded.persistence = .{ .handle = &handle, .io = io };

    var restored: Entities = .{};
    defer restored.deinit(gpa);
    reloaded.entity_io = restored.entityIo();

    _ = try reloaded.getOrGenerateChunk(generator, 0, 0);

    try std.testing.expectEqual(@as(usize, 1), restored.countOf(mob.skeleton));
    const skeleton = restored.first(Skeleton, mob.skeleton).?;
    try std.testing.expectEqual(@as(i32, 7), skeleton.animal.health);

    var rand = world.JavaRandom.init(2);
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    skeleton.pending_arrows = 2;
    skeleton.pending_bones = 1;
    skeleton.animal.dead = true;

    var player = Player.spawn(math.Vec3.init(0, 1, 0));
    try soloTick(&restored, gpa, &w, &player, &rand);

    var arrows: u32 = 0;
    var bones: u32 = 0;
    for (restored.items.items) |item| {
        if (item.stack.id != .item) continue;
        switch (item.stack.id.item) {
            .arrow => arrows += 1,
            .bone => bones += 1,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(u32, 2), arrows);
    try std.testing.expectEqual(@as(u32, 1), bones);
}

test "a spider bites the player it caught in the dark" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(3);
    try entities.spawnSpider(gpa, math.Vec3.init(8.5, 1, 8.5));

    var player = Player.spawn(math.Vec3.init(9.2, 1, 8.5));
    player.base.id = entities.takeId();

    const full = player.health;
    for (0..60) |_| {
        try soloTick(&entities, gpa, &w, &player, &rand);
        if (player.health < full) break;
    }

    try std.testing.expect(player.health < full);
    try std.testing.expectEqual(player.base.id, entities.first(Spider, mob.spider).?.monster.target.?);
}

test "a spider comes back from its chunk still able to climb" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var handle = try world.save.open(io, tmp.dir, "Webs");
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

        try entities.spawnSpider(gpa, math.Vec3.init(8.5, 1, 8.5));
        entities.first(Spider, mob.spider).?.animal.health = 6;

        try w.saveLoadedChunks();
    }

    var reloaded = world.World.init(gpa);
    defer reloaded.deinit();
    reloaded.persistence = .{ .handle = &handle, .io = io };

    var restored: Entities = .{};
    defer restored.deinit(gpa);
    reloaded.entity_io = restored.entityIo();

    _ = try reloaded.getOrGenerateChunk(generator, 0, 0);

    try std.testing.expectEqual(@as(usize, 1), restored.countOf(mob.spider));
    const spider = restored.first(Spider, mob.spider).?;
    try std.testing.expectEqual(@as(i32, 6), spider.animal.health);
    try std.testing.expect(spider.animal.climbs_walls);
    try std.testing.expectApproxEqAbs(@as(f64, 1.4), spider.animal.base.width, 1.0e-9);
}

test "fire standing on the ground smokes from its upper half" {
    const gpa = std.testing.allocator;
    var world_map = try world.testing.flatWorld(gpa, 64);
    defer world_map.deinit();
    world_map.setBlock(8, 64, 8, .fire);

    var entities: Entities = .{};
    defer entities.deinit(gpa);
    var rand = world.JavaRandom.init(7);

    try entities.spawnFireParticles(gpa, &world_map, 8, 64, 8, &rand);

    try std.testing.expectEqual(@as(usize, fire_standing_particles), entities.particles.items.len);
    for (entities.particles.items) |particle| {
        try std.testing.expect(particle.base.position.y >= 64.5);
        try std.testing.expect(particle.base.position.y <= 65.0);
    }
}

test "fire clinging to a wall smokes along that wall only" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlock(8, 65, 8, .fire);
    chunk.setBlock(7, 65, 8, .planks);

    var entities: Entities = .{};
    defer entities.deinit(gpa);
    var rand = world.JavaRandom.init(7);

    try entities.spawnFireParticles(gpa, &world_map, 8, 65, 8, &rand);

    try std.testing.expectEqual(@as(usize, fire_edge_particles), entities.particles.items.len);
    for (entities.particles.items) |particle| {
        try std.testing.expect(particle.base.position.x <= 8.1);
    }
}

test "fire with nothing to burn beside it makes no smoke" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlock(8, 65, 8, .fire);

    var entities: Entities = .{};
    defer entities.deinit(gpa);
    var rand = world.JavaRandom.init(7);

    try entities.spawnFireParticles(gpa, &world_map, 8, 65, 8, &rand);

    try std.testing.expectEqual(@as(usize, 0), entities.particles.items.len);
}

test "a mob and the one riding it are the one pair that never shoves itself apart" {
    const gpa = std.testing.allocator;

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    try entities.spawnSpider(gpa, math.Vec3.init(8.5, 1, 8.5));
    try entities.spawnSkeleton(gpa, math.Vec3.init(8.8, 1, 8.5));

    const spider = entities.mobs.items[0].animal;
    const skeleton = entities.mobs.items[1].animal;

    entities.pushNeighbours(spider);
    try std.testing.expect(spider.base.motion.x != 0);
    try std.testing.expect(skeleton.base.motion.x != 0);

    spider.base.motion = math.Vec3.init(0, 0, 0);
    skeleton.base.motion = math.Vec3.init(0, 0, 0);
    skeleton.riding = spider.base.id;

    entities.pushNeighbours(spider);
    try std.testing.expectEqual(math.Vec3.init(0, 0, 0), spider.base.motion);
    try std.testing.expectEqual(math.Vec3.init(0, 0, 0), skeleton.base.motion);
}
