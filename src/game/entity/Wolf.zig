const std = @import("std");

const assets = @import("assets");
const math = @import("math");
const world = @import("world");

const Mob = @import("../mob.zig");
const Player = @import("../Player.zig");
const raycast = @import("../raycast.zig");
const Animal = @import("Animal.zig");

const Wolf = @This();

animal: Animal,
tamed: bool = false,
angry: bool = false,
sitting: bool = false,
movement_ceased: bool = false,
target: ?Target = null,
prey_view: ?Animal.PlayerView = null,
hunting: bool = false,
pending_bite: i32 = 0,
alerts_pack: bool = false,
owner_id: Animal.Entity.Id = Animal.Entity.no_id,
owner: Player.Name = .{},
interested: bool = false,
interest: f32 = 0,
prev_interest: f32 = 0,
shaking: bool = false,
shake_running: bool = false,
shake_time: f32 = 0,
prev_shake_time: f32 = 0,

pub const Target = union(enum) {
    player: Animal.Entity.Id,
    prey: *Animal,
};

pub const width: f64 = 0.8;
pub const height: f64 = 0.8;
pub const max_health: i32 = 8;
pub const tamed_health: i32 = 20;
pub const move_speed: f32 = 1.1;
pub const eye_fraction: f64 = 0.8;
pub const max_spawned_in_chunk: u32 = 8;

pub const whine_health: i32 = 10;

fn livingSound(animal: *Animal, rand: *world.JavaRandom) ?assets.Sound {
    const self: *Wolf = @fieldParentPtr("animal", animal);
    if (self.angry) return assets.sounds.mob.wolf.growl;
    if (rand.nextIntBound(3) != 0) return assets.sounds.mob.wolf.bark;
    if (self.tamed and animal.health < whine_health) return assets.sounds.mob.wolf.whine;
    return assets.sounds.mob.wolf.panting;
}

pub const spec: Animal.Spec = .{
    .width = width,
    .height = height,
    .max_health = max_health,
    .move_speed = move_speed,
    .eye_fraction = eye_fraction,
    .living_sound_of = livingSound,
    .hurt_sound = assets.sounds.mob.wolf.hurt,
    .death_sound = assets.sounds.mob.wolf.death,
    .sound_volume = 0.4,
    .talk_interval = Animal.passive_talk_interval,
};

pub const sight_range: f64 = 16.0;
pub const follow_distance: f32 = 5.0;
pub const teleport_distance: f32 = 12.0;
pub const pack_reach: f64 = 16.0;
pub const pack_lift: f64 = 4.0;
pub const sitting_look_pitch: f32 = 20.0;
pub const tame_odds: i32 = 3;
pub const bite_damage: i32 = 2;
pub const tamed_bite_damage: i32 = 4;
pub const bite_reach: f32 = 1.5;
pub const lunge_near: f32 = 2.0;
pub const lunge_far: f32 = 6.0;
pub const lunge_odds: i32 = 10;
pub const lunge_lift: f64 = 0.4;
pub const hunt_odds: i32 = 100;
pub const pork_heal: i32 = 3;
pub const treat_particles: usize = 7;
pub const shake_particles: f32 = 7.0;
pub const shake_step: f32 = 0.05;
pub const shake_span: f32 = 2.0;
pub const shake_splash_start: f32 = 0.4;
pub const interest_ease: f32 = 0.4;
pub const interest_look_ticks: i32 = 10;

pub fn isFavouriteMeat(item: world.Item) bool {
    return item == .pork_raw or item == .pork_cooked;
}

fn init(position: math.Vec3) Wolf {
    var wolf: Wolf = .{ .animal = Animal.spawn(position, spec) };
    wolf.animal.action_state = updateActionState;
    return wolf;
}

pub fn spawn(position: math.Vec3) Wolf {
    return init(position);
}

pub fn deinit(self: *Wolf, gpa: std.mem.Allocator) void {
    self.animal.deinit(gpa);
}

pub fn tick(
    self: *Wolf,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    players: Animal.Players,
    rand: *world.JavaRandom,
) !void {
    try self.animal.tick(gpa, world_map, players, rand);

    self.interested = self.looksWithInterest(players);

    if (self.shaking and !self.shake_running and self.animal.path == null and self.animal.base.on_ground) {
        self.shake_running = true;
        self.shake_time = 0;
        self.prev_shake_time = 0;
    }

    self.prev_interest = self.interest;
    const wanted: f32 = if (self.interested) 1.0 else 0.0;
    self.interest += (wanted - self.interest) * interest_ease;
    if (self.interested) self.animal.look_ticks_left = interest_look_ticks;

    if (self.isWet()) {
        self.shaking = true;
        self.shake_running = false;
        self.shake_time = 0;
        self.prev_shake_time = 0;
    } else if (self.shake_running) {
        self.prev_shake_time = self.shake_time;
        self.shake_time += shake_step;
        if (self.prev_shake_time >= shake_span) {
            self.shaking = false;
            self.shake_running = false;
            self.prev_shake_time = 0;
            self.shake_time = 0;
        }
    }
}

fn isWet(self: Wolf) bool {
    return self.animal.base.in_water;
}

fn looksWithInterest(self: Wolf, players: Animal.Players) bool {
    const watching = self.animal.watched_player orelse return false;
    if (self.animal.path != null or self.angry) return false;
    const view = players.byId(watching) orelse return false;
    const held = view.held orelse return false;
    if (!self.tamed) return held == .bone;
    return isFavouriteMeat(held);
}

fn isMovementCeased(self: Wolf) bool {
    return self.sitting or self.shake_running;
}

fn targetView(self: Wolf, players: Animal.Players) ?Animal.PlayerView {
    return switch (self.target orelse return null) {
        .player => |id| players.byId(id),
        .prey => self.prey_view,
    };
}

fn findPlayerToAttack(self: Wolf, players: Animal.Players) ?Target {
    if (!self.angry) return null;
    const view = players.closestTo(self.animal.base.position, sight_range) orelse return null;
    return .{ .player = view.id };
}

fn ownerView(self: *Wolf, players: Animal.Players) ?Animal.PlayerView {
    if (self.owner_id != Animal.Entity.no_id) {
        if (players.byId(self.owner_id)) |view| return view;
        self.owner_id = Animal.Entity.no_id;
    }

    const view = players.byName(self.owner.text()) orelse return null;
    self.owner_id = view.id;
    return view;
}

fn canSee(self: Wolf, world_map: *const world.World, view: Animal.PlayerView) bool {
    const eye = math.Vec3.init(
        self.animal.base.position.x,
        self.animal.base.position.y + self.animal.eyeHeight(),
        self.animal.base.position.z,
    );
    const to_target = [3]f64{
        view.position.x - eye.x,
        view.position.y + view.eye_height - eye.y,
        view.position.z - eye.z,
    };
    const reach = @sqrt(to_target[0] * to_target[0] + to_target[1] * to_target[1] + to_target[2] * to_target[2]);
    if (reach == 0.0) return true;

    const along = [3]f64{ to_target[0] / reach, to_target[1] / reach, to_target[2] / reach };
    return raycast.castCollision(world_map, eye, along, reach) == null;
}

fn attackEntity(self: *Wolf, view: Animal.PlayerView, distance: f32, rand: *world.JavaRandom) void {
    const base = &self.animal.base;

    if (distance > lunge_near and distance < lunge_far and rand.nextIntBound(lunge_odds) == 0) {
        if (!base.on_ground) return;
        const dx = view.position.x - base.position.x;
        const dz = view.position.z - base.position.z;
        const flat: f64 = @sqrt(dx * dx + dz * dz);
        base.motion.x = dx / flat * 0.5 * 0.8 + base.motion.x * 0.2;
        base.motion.z = dz / flat * 0.5 * 0.8 + base.motion.z * 0.2;
        base.motion.y = lunge_lift;
        return;
    }

    if (distance >= bite_reach) return;

    const box = base.boundingBox();
    if (view.position.y + view.height <= box.min_y or view.position.y >= box.max_y) return;

    self.pending_bite = if (self.tamed) tamed_bite_damage else bite_damage;
}

fn pathToTarget(
    self: *Wolf,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    players: Animal.Players,
) !void {
    const view = self.targetView(players) orelse return;
    try self.animal.pathTowards(gpa, world_map, view.position, Animal.chase_path_range);
}

fn approachOwner(
    self: *Wolf,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    owner: Animal.PlayerView,
    distance: f32,
) !void {
    const found = try world.pathfinder.toPosition(
        gpa,
        world_map,
        self.animal.pathMob(),
        owner.position.x,
        owner.position.y,
        owner.position.z,
        Animal.chase_path_range,
    );

    if (found != null or distance <= teleport_distance) {
        self.animal.setPath(gpa, found);
        return;
    }

    const corner_x = math.util.floorDouble(owner.position.x) - 2;
    const corner_z = math.util.floorDouble(owner.position.z) - 2;
    const floor_y = math.util.floorDouble(owner.position.y);

    for (0..5) |ox| {
        for (0..5) |oz| {
            if (ox >= 1 and oz >= 1 and ox <= 3 and oz <= 3) continue;

            const x = corner_x + @as(i32, @intCast(ox));
            const z = corner_z + @as(i32, @intCast(oz));
            if (!world_map.getBlock(x, floor_y - 1, z).isOpaqueCube()) continue;
            if (world_map.getBlock(x, floor_y, z).isOpaqueCube()) continue;
            if (world_map.getBlock(x, floor_y + 1, z).isOpaqueCube()) continue;

            const landing = math.Vec3.init(
                @as(f64, @floatFromInt(x)) + 0.5,
                @floatFromInt(floor_y),
                @as(f64, @floatFromInt(z)) + 0.5,
            );
            self.animal.base.position = landing;
            self.animal.base.prev_position = landing;
            return;
        }
    }
}

fn creatureActionState(
    self: *Wolf,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    players: Animal.Players,
    rand: *world.JavaRandom,
) !void {
    const animal = &self.animal;
    self.movement_ceased = self.isMovementCeased();

    if (self.target == null) {
        self.target = self.findPlayerToAttack(players);
        if (self.target != null) try self.pathToTarget(gpa, world_map, players);
    } else if (self.targetView(players)) |view| {
        if (!view.alive) {
            self.target = null;
        } else {
            const distance: f32 = @floatCast(@sqrt(animal.distanceSquaredTo(view.position)));
            if (self.canSee(world_map, view)) self.attackEntity(view, distance, rand);
        }
    }

    if (self.movement_ceased or self.target == null or (animal.path != null and rand.nextIntBound(20) != 0)) {
        if (!self.movement_ceased and
            ((animal.path == null and rand.nextIntBound(80) == 0) or rand.nextIntBound(80) == 0))
        {
            try animal.findWanderPath(gpa, world_map, rand);
        }
    } else {
        try self.pathToTarget(gpa, world_map, players);
    }

    animal.pitch = 0;
    animal.look_pitch_speed = if (self.sitting) sitting_look_pitch else Animal.default_look_pitch_speed;

    if (animal.path != null and rand.nextIntBound(100) != 0) {
        const chase: ?Animal.Chase = if (self.targetView(players)) |view| .{
            .position = view.position,
            .eye_height = view.eye_height,
            .ceased = self.movement_ceased,
        } else null;
        animal.followPath(gpa, rand, chase);
    } else {
        animal.idleActionState(players, rand);
        animal.clearPath(gpa);
    }
}

fn updateActionState(
    animal: *Animal,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    players: Animal.Players,
    rand: *world.JavaRandom,
) anyerror!void {
    const self: *Wolf = @fieldParentPtr("animal", animal);
    try self.creatureActionState(gpa, world_map, players, rand);

    if (!self.movement_ceased and animal.path == null and self.tamed) {
        if (self.ownerView(players)) |owner| {
            const distance: f32 = @floatCast(@sqrt(animal.distanceSquaredTo(owner.position)));
            if (distance > follow_distance) try self.approachOwner(gpa, world_map, owner, distance);
        } else if (!animal.base.in_water) {
            self.sitting = true;
        }
    } else if (self.target == null and animal.path == null and !self.tamed and rand.nextIntBound(hunt_odds) == 0) {
        self.hunting = true;
    }

    if (animal.base.in_water) self.sitting = false;
}

pub fn hurt(self: *Wolf, world_map: *const world.World, amount: i32, source: ?Animal.Attacker, rand: *world.JavaRandom) bool {
    self.sitting = false;
    if (!self.animal.hurt(world_map, amount, source, rand)) return false;
    if (source == null) return true;

    const attacker = source.?.player;
    if (!self.tamed and !self.angry) {
        self.angry = true;
        self.target = .{ .player = attacker };
        self.alerts_pack = true;
    } else if (!self.tamed) {
        self.target = .{ .player = attacker };
    }
    return true;
}

pub const Use = enum { tamed, refused, fed, sat, stood };

pub fn interact(self: *Wolf, gpa: std.mem.Allocator, held: ?world.Item, rand: *world.JavaRandom) ?Use {
    return self.interactWith(gpa, .{ .position = self.animal.base.position, .eye_height = 0, .alive = true }, held, rand);
}

pub fn interactWith(
    self: *Wolf,
    gpa: std.mem.Allocator,
    player: Animal.PlayerView,
    held: ?world.Item,
    rand: *world.JavaRandom,
) ?Use {
    if (!self.tamed) {
        const item = held orelse return null;
        if (item != .bone or self.angry) return null;

        if (rand.nextIntBound(tame_odds) != 0) return .refused;

        self.tamed = true;
        self.owner_id = player.id;
        self.owner.set(player.name);
        self.sitting = true;
        self.animal.max_health = tamed_health;
        self.animal.health = tamed_health;
        self.animal.can_despawn = false;
        self.animal.clearPath(gpa);
        return .tamed;
    }

    if (held) |item| {
        if (isFavouriteMeat(item) and self.animal.health < tamed_health) {
            self.animal.health = @min(self.animal.health + pork_heal, tamed_health);
            return .fed;
        }
    }

    self.sitting = !self.sitting;
    self.animal.is_jumping = false;
    self.animal.clearPath(gpa);
    return if (self.sitting) .sat else .stood;
}

pub fn tailRotation(self: Wolf) f32 {
    if (self.angry) return std.math.pi * 0.49;
    if (!self.tamed) return std.math.pi * 0.2;

    const missing: f32 = @floatFromInt(tamed_health - std.math.clamp(self.animal.health, 0, tamed_health));
    return (0.55 - missing * 0.02) * std.math.pi;
}

pub fn shakeAngle(self: Wolf, partial_ticks: f32, offset: f32) f32 {
    const eased = std.math.clamp(
        (self.prev_shake_time + (self.shake_time - self.prev_shake_time) * partial_ticks + offset) / 1.8,
        0.0,
        1.0,
    );
    return math.util.sin(eased * std.math.pi) * math.util.sin(eased * std.math.pi * 11.0) * 0.15 * std.math.pi;
}

pub fn interestedAngle(self: Wolf, partial_ticks: f32) f32 {
    return (self.prev_interest + (self.interest - self.prev_interest) * partial_ticks) * 0.15 * std.math.pi;
}

pub fn shadingWhileShaking(self: Wolf, partial_ticks: f32) f32 {
    const shaken = self.prev_shake_time + (self.shake_time - self.prev_shake_time) * partial_ticks;
    return 12.0 / 16.0 + shaken / 2.0 * 0.25;
}

pub fn toRecord(self: Wolf) world.entity_nbt.Wolf {
    return .{
        .living = self.animal.toRecord(),
        .angry = self.angry,
        .sitting = self.sitting,
        .owner = world.entity_nbt.Owner.from(self.owner.text()),
    };
}

pub fn fromRecord(record: world.entity_nbt.Wolf) Wolf {
    var wolf = init(math.Vec3.init(
        record.living.position[0],
        record.living.position[1],
        record.living.position[2],
    ));
    wolf.animal.restore(record.living);
    wolf.angry = record.angry;
    wolf.sitting = record.sitting;
    if (record.owner.len > 0) {
        wolf.owner.set(record.owner.text());
        wolf.tamed = true;
        wolf.animal.max_health = tamed_health;
        wolf.animal.can_despawn = false;
    }
    return wolf;
}

fn packBox(self: Wolf) math.Aabb {
    const at = self.animal.base.position;
    return math.Aabb.init(at.x, at.y, at.z, at.x + 1.0, at.y + 1.0, at.z + 1.0)
        .expand(pack_reach, pack_lift, pack_reach);
}

pub const wire_id: u8 = 95;
pub const watched_flags: u5 = 16;
pub const watched_owner: u5 = 17;
pub const watched_health: u5 = 18;

const sitting_bit: i8 = 1;
const angry_bit: i8 = 2;
const tamed_bit: i8 = 4;

pub const mob_type: Mob.Type = .{
    .name = world.entity_nbt.wolf_id,
    .wire_id = wire_id,
    .spawn = mobSpawn,
    .tick = mobTick,
    .takeDrops = mobTakeDrops,
    .store = mobStore,
    .load = mobLoad,
    .destroy = mobDestroy,
    .hurt = mobHurt,
    .afterTick = mobAfterTick,
    .watch = mobWatch,
    .adopt = mobAdopt,
};

fn mobWatch(animal: *const Animal, out: *Mob.Watched) void {
    const self: *const Wolf = @fieldParentPtr("animal", animal);

    var flags: i8 = 0;
    if (self.sitting) flags |= sitting_bit;
    if (self.angry) flags |= angry_bit;
    if (self.tamed) flags |= tamed_bit;

    out.add(watched_flags, .{ .byte = flags });
    out.add(watched_owner, .{ .text = self.owner.text() });
    out.add(watched_health, .{ .int = animal.health });
}

fn mobAdopt(animal: *Animal, metadata: Mob.Metadata) void {
    const self: *Wolf = @fieldParentPtr("animal", animal);

    if (metadata.byteAt(watched_flags)) |flags| {
        self.sitting = flags & sitting_bit != 0;
        self.angry = flags & angry_bit != 0;
        self.tamed = flags & tamed_bit != 0;
    }
    if (metadata.textAt(watched_owner)) |owner| self.owner.set(owner);
    if (metadata.intAt(watched_health)) |health| animal.health = health;
}

fn mobSpawn(gpa: std.mem.Allocator, position: math.Vec3, _: *world.JavaRandom) anyerror!*Animal {
    const self = try gpa.create(Wolf);
    self.* = spawn(position);
    return &self.animal;
}

fn mobTick(
    animal: *Animal,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    players: Animal.Players,
    rand: *world.JavaRandom,
) anyerror!void {
    const self: *Wolf = @fieldParentPtr("animal", animal);
    try self.tick(gpa, world_map, players, rand);
}

fn mobTakeDrops(_: *Animal) ?Mob.Drops {
    return null;
}

fn mobHurt(animal: *Animal, world_map: *const world.World, amount: i32, source: ?Animal.Attacker, rand: *world.JavaRandom) bool {
    const self: *Wolf = @fieldParentPtr("animal", animal);
    return self.hurt(world_map, amount, source, rand);
}

fn mobStore(animal: *Animal, gpa: std.mem.Allocator) anyerror!world.nbt.Tag {
    const self: *Wolf = @fieldParentPtr("animal", animal);
    return world.entity_nbt.storeWolf(gpa, self.toRecord());
}

fn mobLoad(gpa: std.mem.Allocator, entity: world.nbt.Compound) anyerror!?*Animal {
    const record = world.entity_nbt.loadWolf(entity) orelse return null;
    const self = try gpa.create(Wolf);
    self.* = Wolf.fromRecord(record);
    return &self.animal;
}

fn mobDestroy(animal: *Animal, gpa: std.mem.Allocator) void {
    const self: *Wolf = @fieldParentPtr("animal", animal);
    self.deinit(gpa);
    gpa.destroy(self);
}

fn mobAfterTick(animal: *Animal, context: Mob.Tick) anyerror!void {
    const Entities = @import("../Entities.zig");
    const self: *Wolf = @fieldParentPtr("animal", animal);
    const entities: *Entities = @ptrCast(@alignCast(context.entities));

    if (self.alerts_pack) {
        self.alerts_pack = false;
        self.rousePack(entities);
    }

    if (self.hunting) {
        self.hunting = false;
        self.choosePrey(entities, context.rand);
    }

    self.refreshPrey(entities);

    if (self.pending_bite != 0) {
        const damage = self.pending_bite;
        self.pending_bite = 0;
        self.bite(entities, context, damage);
    }

    if (self.shake_running and self.shake_time > shake_splash_start) {
        try self.splash(entities, context.gpa, context.rand);
    }
}

fn rousePack(self: *Wolf, entities: anytype) void {
    const box = self.packBox();
    var pack = entities.of(Wolf, Mob.wolf);
    while (pack.next()) |other| {
        if (other == self) continue;
        if (!box.intersects(other.animal.base.boundingBox())) continue;
        if (other.tamed or other.target != null) continue;
        other.target = self.target;
        other.angry = true;
    }
}

fn choosePrey(self: *Wolf, entities: anytype, rand: *world.JavaRandom) void {
    const Sheep = @import("Sheep.zig");
    const box = self.packBox();

    var found: i32 = 0;
    var counting = entities.of(Sheep, Mob.sheep);
    while (counting.next()) |sheep| {
        if (box.intersects(sheep.animal.base.boundingBox())) found += 1;
    }
    if (found == 0) return;

    var chosen = rand.nextIntBound(found);
    var walking = entities.of(Sheep, Mob.sheep);
    while (walking.next()) |sheep| {
        if (!box.intersects(sheep.animal.base.boundingBox())) continue;
        if (chosen == 0) {
            self.target = .{ .prey = &sheep.animal };
            return;
        }
        chosen -= 1;
    }
}

fn refreshPrey(self: *Wolf, entities: anytype) void {
    self.prey_view = null;

    const hunted = switch (self.target orelse return) {
        .player => return,
        .prey => |animal| animal,
    };

    for (entities.mobs.items) |entry| {
        if (entry.animal != hunted) continue;
        self.prey_view = .{
            .position = hunted.base.position,
            .eye_height = hunted.eyeHeight(),
            .height = hunted.base.height,
            .alive = hunted.isAlive(),
        };
        return;
    }

    self.target = null;
}

fn bite(self: *Wolf, entities: anytype, context: Mob.Tick, damage: i32) void {
    switch (self.target orelse return) {
        .player => |id| {
            const player = context.playerById(id) orelse return;
            if (player.health <= 0) return;
            player.hurtFrom(context.world_map, damage, self.animal.base.position);
        },
        .prey => |hunted| {
            for (entities.mobs.items) |entry| {
                if (entry.animal != hunted) continue;
                _ = Mob.get(entry.type_id).hurt(hunted, context.world_map, damage, .{ .position = self.animal.base.position }, context.rand);
                return;
            }
        },
    }
}

fn splash(self: *Wolf, entities: anytype, gpa: std.mem.Allocator, rand: *world.JavaRandom) !void {
    const floor = self.animal.base.boundingBox().min_y;
    const bursts: i32 = @intFromFloat(math.util.sin((self.shake_time - shake_splash_start) * std.math.pi) * shake_particles);

    var spawned: i32 = 0;
    while (spawned < bursts) : (spawned += 1) {
        const dx = (rand.nextFloat() * 2.0 - 1.0) * @as(f32, @floatCast(self.animal.base.width)) * 0.5;
        const dz = (rand.nextFloat() * 2.0 - 1.0) * @as(f32, @floatCast(self.animal.base.width)) * 0.5;
        try entities.spawnWolfSplash(gpa, math.Vec3.init(
            self.animal.base.position.x + dx,
            floor + 0.8,
            self.animal.base.position.z + dz,
        ), self.animal.base.motion, rand);
    }
}

pub fn alertOwned(entities: anytype, attacker: Animal.Attacker, victim: *Animal, skip_sitting: bool) void {
    const at = attacker.position;
    const box = math.Aabb.init(at.x, at.y, at.z, at.x + 1.0, at.y + 1.0, at.z + 1.0)
        .expand(pack_reach, pack_lift, pack_reach);

    var pack = entities.of(Wolf, Mob.wolf);
    while (pack.next()) |wolf| {
        if (&wolf.animal == victim) continue;
        if (!box.intersects(wolf.animal.base.boundingBox())) continue;
        if (!wolf.tamed or wolf.target != null) continue;
        if (wolf.owner_id != Animal.Entity.no_id and wolf.owner_id != attacker.player) continue;
        if (skip_sitting and wolf.sitting) continue;
        wolf.sitting = false;
        wolf.target = .{ .prey = victim };
    }
}

test "a wolf is the size and speed EntityWolf sets itself to" {
    const wolf = Wolf.spawn(math.Vec3.init(0, 0, 0));

    try std.testing.expectEqual(@as(f64, 0.8), wolf.animal.base.width);
    try std.testing.expectEqual(@as(f64, 0.8), wolf.animal.base.height);
    try std.testing.expectEqual(max_health, wolf.animal.health);
    try std.testing.expectEqual(@as(f32, 1.1), wolf.animal.move_speed);
    try std.testing.expectApproxEqAbs(@as(f64, 0.64), wolf.animal.eyeHeight(), 1.0e-9);
}

test "a wolf leaves nothing behind when it dies" {
    var w = world.World.init(std.testing.allocator);
    defer w.deinit();
    var rand = world.JavaRandom.init(0);
    var wolf = Wolf.spawn(math.Vec3.init(8, 1, 8));

    _ = wolf.hurt(&w, max_health, null, &rand);

    try std.testing.expect(!wolf.animal.isAlive() or wolf.animal.health <= 0);
    try std.testing.expect(mobTakeDrops(&wolf.animal) == null);
}

test "a bone tames a wolf about one time in three, and always costs the bone" {
    const gpa = std.testing.allocator;
    var tamed: u32 = 0;
    var refused: u32 = 0;

    for (0..300) |seed| {
        var rand = world.JavaRandom.init(@intCast(seed));
        var wolf = Wolf.spawn(math.Vec3.init(8, 1, 8));
        defer wolf.deinit(gpa);

        switch (wolf.interact(gpa, .bone, &rand).?) {
            .tamed => tamed += 1,
            .refused => refused += 1,
            else => unreachable,
        }
    }

    try std.testing.expectEqual(@as(u32, 300), tamed + refused);
    try std.testing.expect(tamed > 60 and tamed < 140);
}

test "taming sits the wolf down, heals it to twenty and stops it despawning" {
    const gpa = std.testing.allocator;

    var seed: u64 = 0;
    while (seed < 100) : (seed += 1) {
        var rand = world.JavaRandom.init(@intCast(seed));
        var wolf = Wolf.spawn(math.Vec3.init(8, 1, 8));
        defer wolf.deinit(gpa);

        if (wolf.interact(gpa, .bone, &rand) != .tamed) continue;

        try std.testing.expect(wolf.tamed);
        try std.testing.expect(wolf.sitting);
        try std.testing.expectEqual(tamed_health, wolf.animal.health);
        try std.testing.expectEqual(tamed_health, wolf.animal.max_health);
        try std.testing.expect(!wolf.animal.can_despawn);
        return;
    }

    try std.testing.expect(false);
}

test "an angry wolf refuses the bone" {
    const gpa = std.testing.allocator;
    var rand = world.JavaRandom.init(0);
    var wolf = Wolf.spawn(math.Vec3.init(8, 1, 8));
    defer wolf.deinit(gpa);
    wolf.angry = true;

    try std.testing.expect(wolf.interact(gpa, .bone, &rand) == null);
    try std.testing.expect(!wolf.tamed);
}

test "a tamed wolf sits and stands on a bare hand, and eats pork when hurt" {
    const gpa = std.testing.allocator;
    var rand = world.JavaRandom.init(0);
    var wolf = Wolf.spawn(math.Vec3.init(8, 1, 8));
    defer wolf.deinit(gpa);
    wolf.tamed = true;
    wolf.animal.max_health = tamed_health;
    wolf.animal.health = tamed_health;

    try std.testing.expectEqual(Use.sat, wolf.interact(gpa, null, &rand).?);
    try std.testing.expectEqual(Use.stood, wolf.interact(gpa, null, &rand).?);

    try std.testing.expectEqual(Use.sat, wolf.interact(gpa, .pork_raw, &rand).?);

    wolf.animal.health = 10;
    try std.testing.expectEqual(Use.fed, wolf.interact(gpa, .pork_raw, &rand).?);
    try std.testing.expectEqual(@as(i32, 13), wolf.animal.health);

    wolf.animal.health = 19;
    try std.testing.expectEqual(Use.fed, wolf.interact(gpa, .pork_cooked, &rand).?);
    try std.testing.expectEqual(tamed_health, wolf.animal.health);
}

test "hitting an untamed wolf angers it at the player and rouses the pack" {
    var w = world.World.init(std.testing.allocator);
    defer w.deinit();
    var rand = world.JavaRandom.init(0);
    var wolf = Wolf.spawn(math.Vec3.init(8, 1, 8));
    wolf.sitting = true;

    try std.testing.expect(wolf.hurt(&w, 1, .{ .position = math.Vec3.init(6, 1, 8), .player = 7 }, &rand));

    try std.testing.expect(wolf.angry);
    try std.testing.expect(!wolf.sitting);
    try std.testing.expect(wolf.alerts_pack);
    try std.testing.expectEqual(@as(Animal.Entity.Id, 7), wolf.target.?.player);
}

test "a tamed wolf never turns on the hand that feeds it" {
    var w = world.World.init(std.testing.allocator);
    defer w.deinit();
    var rand = world.JavaRandom.init(0);
    var wolf = Wolf.spawn(math.Vec3.init(8, 1, 8));
    wolf.tamed = true;
    wolf.animal.max_health = tamed_health;
    wolf.animal.health = tamed_health;

    try std.testing.expect(wolf.hurt(&w, 2, .{ .position = math.Vec3.init(6, 1, 8) }, &rand));

    try std.testing.expect(!wolf.angry);
    try std.testing.expect(wolf.target == null);
}

test "damage with no attacker leaves the wolf calm" {
    var w = world.World.init(std.testing.allocator);
    defer w.deinit();
    var rand = world.JavaRandom.init(0);
    var wolf = Wolf.spawn(math.Vec3.init(8, 1, 8));

    try std.testing.expect(wolf.hurt(&w, 1, null, &rand));

    try std.testing.expect(!wolf.angry);
    try std.testing.expect(wolf.target == null);
}

test "the tail rises with anger, and with a tamed wolf's health" {
    var wolf = Wolf.spawn(math.Vec3.init(0, 0, 0));
    try std.testing.expectApproxEqAbs(std.math.pi * 0.2, wolf.tailRotation(), 1.0e-6);

    wolf.angry = true;
    try std.testing.expectApproxEqAbs(std.math.pi * 0.49, wolf.tailRotation(), 1.0e-6);

    wolf.angry = false;
    wolf.tamed = true;
    wolf.animal.max_health = tamed_health;
    wolf.animal.health = tamed_health;
    const healthy = wolf.tailRotation();
    wolf.animal.health = 4;
    const hurt_tail = wolf.tailRotation();

    try std.testing.expectApproxEqAbs(0.55 * std.math.pi, healthy, 1.0e-6);
    try std.testing.expect(hurt_tail < healthy);
}

fn stoneFloor(gpa: std.mem.Allocator) !world.World {
    var w = world.World.init(gpa);
    errdefer w.deinit();

    var chunk_x: i32 = -2;
    while (chunk_x <= 2) : (chunk_x += 1) {
        var chunk_z: i32 = -2;
        while (chunk_z <= 2) : (chunk_z += 1) {
            const chunk = try w.createChunk(chunk_x, chunk_z);
            for (0..world.Chunk.width) |x| {
                for (0..world.Chunk.width) |z| {
                    chunk.setBlock(@intCast(x), 0, @intCast(z), .stone);
                    chunk.setSkyLight(@intCast(x), 1, @intCast(z), 15);
                }
            }
        }
    }
    return w;
}

test "a sitting wolf stays put however long it is left alone" {
    const gpa = std.testing.allocator;
    var w = try stoneFloor(gpa);
    defer w.deinit();

    var rand = world.JavaRandom.init(5);
    var wolf = Wolf.spawn(math.Vec3.init(8.5, 1, 8.5));
    defer wolf.deinit(gpa);
    wolf.tamed = true;
    wolf.sitting = true;
    wolf.animal.base.on_ground = true;

    const owner = Animal.PlayerView{
        .position = math.Vec3.init(8.5, 1, 8.5),
        .eye_height = 1.62,
        .alive = true,
    };
    for (0..300) |_| try wolf.tick(gpa, &w, Animal.Players.one(&owner), &rand);

    try std.testing.expectApproxEqAbs(@as(f64, 8.5), wolf.animal.base.position.x, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 8.5), wolf.animal.base.position.z, 1.0e-6);
    try std.testing.expect(wolf.sitting);
}

test "a tamed wolf left standing walks back towards its owner" {
    const gpa = std.testing.allocator;
    var w = try stoneFloor(gpa);
    defer w.deinit();

    var rand = world.JavaRandom.init(9);
    var wolf = Wolf.spawn(math.Vec3.init(8.5, 1, 8.5));
    defer wolf.deinit(gpa);
    wolf.tamed = true;
    wolf.owner.set("Steve");
    wolf.animal.base.on_ground = true;

    const owner = Animal.PlayerView{
        .position = math.Vec3.init(20.5, 1, 8.5),
        .eye_height = 1.62,
        .alive = true,
        .name = "Steve",
    };

    const started = wolf.animal.distanceSquaredTo(owner.position);
    for (0..300) |_| try wolf.tick(gpa, &w, Animal.Players.one(&owner), &rand);

    try std.testing.expect(wolf.animal.distanceSquaredTo(owner.position) < started);
}

fn floodChunk(w: *world.World, block: world.Block) void {
    const chunk = w.getChunk(0, 0).?;
    for (0..world.Chunk.width) |x| {
        for (0..world.Chunk.width) |z| {
            var y: u32 = 1;
            while (y <= 2) : (y += 1) chunk.setBlock(@intCast(x), y, @intCast(z), block);
        }
    }
}

test "a wolf dropped in water shakes itself dry once it is back on land" {
    const gpa = std.testing.allocator;
    var w = try stoneFloor(gpa);
    defer w.deinit();
    floodChunk(&w, .stationary_water);

    var rand = world.JavaRandom.init(3);
    var wolf = Wolf.spawn(math.Vec3.init(8.5, 1, 8.5));
    defer wolf.deinit(gpa);
    wolf.animal.base.on_ground = true;

    try wolf.tick(gpa, &w, .{}, &rand);
    try std.testing.expect(wolf.animal.base.in_water);
    try std.testing.expect(wolf.shaking);
    try std.testing.expect(!wolf.shake_running);

    floodChunk(&w, .air);

    var shook = false;
    for (0..400) |_| {
        try wolf.tick(gpa, &w, .{}, &rand);
        if (wolf.shake_running) shook = true;
        if (!wolf.shaking) break;
    }

    try std.testing.expect(shook);
    try std.testing.expect(!wolf.shaking);
}

test "a shaking wolf holds still until it has finished" {
    const gpa = std.testing.allocator;
    var w = try stoneFloor(gpa);
    defer w.deinit();

    var rand = world.JavaRandom.init(3);
    var wolf = Wolf.spawn(math.Vec3.init(8.5, 1, 8.5));
    defer wolf.deinit(gpa);
    wolf.animal.base.on_ground = true;
    wolf.shake_running = true;

    try wolf.tick(gpa, &w, .{}, &rand);

    try std.testing.expect(wolf.movement_ceased);
    try std.testing.expect(wolf.animal.path == null);
}

test "the shake angle swings away from rest and comes back to it" {
    var wolf = Wolf.spawn(math.Vec3.init(0, 0, 0));

    try std.testing.expectApproxEqAbs(@as(f32, 0), wolf.shakeAngle(0, 0), 1.0e-6);

    wolf.shake_time = 0.9;
    wolf.prev_shake_time = 0.9;
    try std.testing.expect(@abs(wolf.shakeAngle(1.0, 0)) > 0.0);

    wolf.shake_time = 1.8;
    wolf.prev_shake_time = 1.8;
    try std.testing.expectApproxEqAbs(@as(f32, 0), wolf.shakeAngle(1.0, 0), 1.0e-5);
}

test "a shaking wolf is drawn darker at rest and brighter mid-shake" {
    var wolf = Wolf.spawn(math.Vec3.init(0, 0, 0));
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), wolf.shadingWhileShaking(0), 1.0e-6);

    wolf.shake_time = 2.0;
    wolf.prev_shake_time = 2.0;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), wolf.shadingWhileShaking(1.0), 1.0e-6);
}

test "a wolf keeps its collar, its mood and its seat across a record round trip" {
    var wolf = Wolf.spawn(math.Vec3.init(12.5, 64.0, -3.25));
    wolf.tamed = true;
    wolf.owner.set("Steve");
    wolf.sitting = true;
    wolf.animal.max_health = tamed_health;
    wolf.animal.health = 13;
    wolf.animal.yaw = 42.0;

    const restored = Wolf.fromRecord(wolf.toRecord());

    try std.testing.expect(restored.tamed);
    try std.testing.expectEqualStrings("Steve", restored.owner.text());
    try std.testing.expect(restored.sitting);
    try std.testing.expect(!restored.angry);
    try std.testing.expect(!restored.animal.can_despawn);
    try std.testing.expectEqual(tamed_health, restored.animal.max_health);
    try std.testing.expectEqual(@as(i32, 13), restored.animal.health);
    try std.testing.expectApproxEqAbs(@as(f32, 42.0), restored.animal.yaw, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f64, -3.25), restored.animal.base.position.z, 1.0e-9);
}

test "an angry wolf comes back angry, and still able to despawn" {
    var wolf = Wolf.spawn(math.Vec3.init(0, 64, 0));
    wolf.angry = true;

    const restored = Wolf.fromRecord(wolf.toRecord());

    try std.testing.expect(restored.angry);
    try std.testing.expect(!restored.tamed);
    try std.testing.expect(restored.animal.can_despawn);
    try std.testing.expectEqual(max_health, restored.animal.max_health);
}

test "a wolf only takes an interest in what it is old enough to want" {
    var wolf = Wolf.spawn(math.Vec3.init(8, 1, 8));
    wolf.animal.watched_player = 1;

    const holding = struct {
        var held: [1]Animal.PlayerView = undefined;

        fn players(item: ?world.Item) Animal.Players {
            held[0] = .{
                .id = 1,
                .position = math.Vec3.init(9, 1, 8),
                .eye_height = 1.62,
                .alive = true,
                .held = item,
            };
            return .of(&held);
        }
    };

    try std.testing.expect(wolf.looksWithInterest(holding.players(.bone)));
    try std.testing.expect(!wolf.looksWithInterest(holding.players(.pork_raw)));
    try std.testing.expect(!wolf.looksWithInterest(holding.players(null)));

    wolf.tamed = true;
    try std.testing.expect(!wolf.looksWithInterest(holding.players(.bone)));
    try std.testing.expect(wolf.looksWithInterest(holding.players(.pork_raw)));
    try std.testing.expect(wolf.looksWithInterest(holding.players(.pork_cooked)));
    try std.testing.expect(!wolf.looksWithInterest(holding.players(.bread)));

    wolf.angry = true;
    try std.testing.expect(!wolf.looksWithInterest(holding.players(.pork_raw)));
}

test "the interested head tilt eases in while the treat is out and back once it is gone" {
    var wolf = Wolf.spawn(math.Vec3.init(8.5, 1, 8.5));

    wolf.interested = true;
    for (0..20) |_| {
        wolf.prev_interest = wolf.interest;
        wolf.interest += (1.0 - wolf.interest) * interest_ease;
    }
    const tilted = wolf.interestedAngle(1.0);
    try std.testing.expect(tilted > 0.0);
    try std.testing.expectApproxEqAbs(0.15 * std.math.pi, tilted, 1.0e-4);

    wolf.interested = false;
    for (0..20) |_| {
        wolf.prev_interest = wolf.interest;
        wolf.interest += (0.0 - wolf.interest) * interest_ease;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0), wolf.interestedAngle(1.0), 1.0e-4);
}

test "an angry wolf runs down the player it can see, and stops at a wall" {
    const gpa = std.testing.allocator;
    var w = try stoneFloor(gpa);
    defer w.deinit();

    var rand = world.JavaRandom.init(7);
    var wolf = Wolf.spawn(math.Vec3.init(8.5, 1, 8.5));
    defer wolf.deinit(gpa);
    wolf.animal.base.on_ground = true;
    wolf.angry = true;

    const player = Animal.PlayerView{
        .position = math.Vec3.init(18.5, 1, 8.5),
        .eye_height = 1.62,
        .alive = true,
    };

    const started = wolf.animal.distanceSquaredTo(player.position);
    for (0..200) |_| try wolf.tick(gpa, &w, Animal.Players.one(&player), &rand);

    try std.testing.expect(wolf.target != null);
    try std.testing.expect(wolf.animal.distanceSquaredTo(player.position) < started);
}

test "a wolf standing on the player bites for two, or four once it is tamed" {
    const gpa = std.testing.allocator;
    var w = try stoneFloor(gpa);
    defer w.deinit();

    var rand = world.JavaRandom.init(0);
    var wolf = Wolf.spawn(math.Vec3.init(8.5, 1, 8.5));
    defer wolf.deinit(gpa);

    const player = Animal.PlayerView{
        .position = math.Vec3.init(9.0, 1, 8.5),
        .eye_height = 1.62,
        .alive = true,
    };

    wolf.attackEntity(player, 0.5, &rand);
    try std.testing.expectEqual(bite_damage, wolf.pending_bite);

    wolf.pending_bite = 0;
    wolf.tamed = true;
    wolf.attackEntity(player, 0.5, &rand);
    try std.testing.expectEqual(tamed_bite_damage, wolf.pending_bite);

    wolf.pending_bite = 0;
    wolf.attackEntity(player, 1.6, &rand);
    try std.testing.expectEqual(@as(i32, 0), wolf.pending_bite);
}

test "a wolf out of reach lunges rather than biting" {
    const gpa = std.testing.allocator;
    var w = try stoneFloor(gpa);
    defer w.deinit();

    var wolf = Wolf.spawn(math.Vec3.init(8.5, 1, 8.5));
    defer wolf.deinit(gpa);
    wolf.animal.base.on_ground = true;

    const player = Animal.PlayerView{
        .position = math.Vec3.init(12.5, 1, 8.5),
        .eye_height = 1.62,
        .alive = true,
    };

    var leapt = false;
    for (0..200) |seed| {
        var rand = world.JavaRandom.init(@intCast(seed));
        wolf.animal.base.motion = math.Vec3.init(0, 0, 0);
        wolf.attackEntity(player, 4.0, &rand);
        if (wolf.animal.base.motion.y > 0.0) {
            leapt = true;
            try std.testing.expect(wolf.animal.base.motion.x > 0.0);
        }
    }

    try std.testing.expect(leapt);
    try std.testing.expectEqual(@as(i32, 0), wolf.pending_bite);
}

test "a wall between the wolf and the player hides the player from it" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var wolf = Wolf.spawn(math.Vec3.init(8.5, 1, 8.5));
    const player = Animal.PlayerView{
        .position = math.Vec3.init(11.5, 1, 8.5),
        .eye_height = 1.62,
        .alive = true,
    };

    try std.testing.expect(wolf.canSee(&w, player));

    var y: u32 = 1;
    while (y <= 3) : (y += 1) w.setBlock(10, @intCast(y), 8, .stone);
    try std.testing.expect(!wolf.canSee(&w, player));
}

test "a struck wolf turns on the player who struck it, not the nearest one" {
    var w = world.World.init(std.testing.allocator);
    defer w.deinit();
    var rand = world.JavaRandom.init(0);
    var wolf = Wolf.spawn(math.Vec3.init(8, 1, 8));

    try std.testing.expect(wolf.hurt(&w, 1, .{ .position = math.Vec3.init(30, 1, 8), .player = 42 }, &rand));

    try std.testing.expect(wolf.angry);
    try std.testing.expectEqual(@as(Animal.Entity.Id, 42), wolf.target.?.player);
}

test "an angry wolf with no memory of an attacker picks the closest player it can see" {
    var wolf = Wolf.spawn(math.Vec3.init(0, 1, 0));
    wolf.angry = true;

    const views = [_]Animal.PlayerView{
        .{ .id = 1, .position = math.Vec3.init(12, 1, 0), .eye_height = 1.62, .alive = true },
        .{ .id = 2, .position = math.Vec3.init(3, 1, 0), .eye_height = 1.62, .alive = true },
    };

    try std.testing.expectEqual(@as(Animal.Entity.Id, 2), wolf.findPlayerToAttack(.of(&views)).?.player);

    const distant = [_]Animal.PlayerView{
        .{ .id = 1, .position = math.Vec3.init(40, 1, 0), .eye_height = 1.62, .alive = true },
    };
    try std.testing.expect(wolf.findPlayerToAttack(.of(&distant)) == null);
}

test "a tamed wolf follows the owner that tamed it, not whoever is nearest" {
    const gpa = std.testing.allocator;
    var wolf = Wolf.spawn(math.Vec3.init(0, 1, 0));
    defer wolf.deinit(gpa);
    wolf.tamed = true;
    wolf.owner.set("Steve");

    const views = [_]Animal.PlayerView{
        .{ .id = 3, .position = math.Vec3.init(2, 1, 0), .eye_height = 1.62, .alive = true, .name = "Alex" },
        .{ .id = 7, .position = math.Vec3.init(30, 1, 0), .eye_height = 1.62, .alive = true, .name = "Steve" },
    };

    try std.testing.expectEqual(@as(f64, 30), wolf.ownerView(.of(&views)).?.position.x);

    const owner_gone = [_]Animal.PlayerView{views[0]};
    try std.testing.expect(wolf.ownerView(.of(&owner_gone)) == null);
}

test "a wolf tamed at runtime remembers who tamed it" {
    const gpa = std.testing.allocator;

    var seed: u64 = 0;
    while (seed < 100) : (seed += 1) {
        var rand = world.JavaRandom.init(@intCast(seed));
        var wolf = Wolf.spawn(math.Vec3.init(8, 1, 8));
        defer wolf.deinit(gpa);

        if (wolf.interactWith(gpa, .{ .id = 11, .position = math.Vec3.init(8, 1, 8), .eye_height = 1.62, .alive = true, .name = "Notch" }, .bone, &rand) != .tamed) continue;

        try std.testing.expectEqual(@as(Animal.Entity.Id, 11), wolf.owner_id);
        try std.testing.expectEqualStrings("Notch", wolf.owner.text());
        return;
    }
    try std.testing.expect(false);
}

test "a tamed wolf reloaded from a save finds its owner by name, not by nearness" {
    var wolf = Wolf.spawn(math.Vec3.init(0, 1, 0));
    wolf.tamed = true;
    wolf.owner.set("Steve");

    const both = [_]Animal.PlayerView{
        .{ .id = 3, .position = math.Vec3.init(1, 1, 0), .eye_height = 1.62, .alive = true, .name = "Alex" },
        .{ .id = 7, .position = math.Vec3.init(40, 1, 0), .eye_height = 1.62, .alive = true, .name = "Steve" },
    };

    try std.testing.expectEqual(@as(Animal.Entity.Id, 7), wolf.ownerView(.of(&both)).?.id);
    try std.testing.expectEqual(@as(Animal.Entity.Id, 7), wolf.owner_id);

    const only_stranger = [_]Animal.PlayerView{both[0]};
    try std.testing.expect(wolf.ownerView(.of(&only_stranger)) == null);
}

test "a wolf whose owner logs back in with a new id rebinds to them" {
    var wolf = Wolf.spawn(math.Vec3.init(0, 1, 0));
    wolf.tamed = true;
    wolf.owner.set("Steve");
    wolf.owner_id = 7;

    const rejoined = [_]Animal.PlayerView{
        .{ .id = 42, .position = math.Vec3.init(3, 1, 0), .eye_height = 1.62, .alive = true, .name = "Steve" },
    };

    try std.testing.expectEqual(@as(Animal.Entity.Id, 42), wolf.ownerView(.of(&rejoined)).?.id);
    try std.testing.expectEqual(@as(Animal.Entity.Id, 42), wolf.owner_id);
}

test "a wolf's flags, owner and health ride along as three watched values" {
    var tame = spawn(math.Vec3.init(0, 0, 0));
    tame.tamed = true;
    tame.sitting = true;
    tame.owner.set("Steve");
    tame.animal.health = 14;

    var watched: Mob.Watched = .{};
    Mob.watch(Mob.wolf, &tame.animal, &watched);

    var stray = spawn(math.Vec3.init(0, 0, 0));
    Mob.adopt(Mob.wolf, &stray.animal, watched.view());

    try std.testing.expect(stray.tamed);
    try std.testing.expect(stray.sitting);
    try std.testing.expect(!stray.angry);
    try std.testing.expectEqualStrings("Steve", stray.owner.text());
    try std.testing.expectEqual(@as(i32, 14), stray.animal.health);
}
