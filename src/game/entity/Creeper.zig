const std = @import("std");

const assets = @import("assets");
const math = @import("math");
const world = @import("world");

const explosion = @import("../explosion.zig");
const Mob = @import("../mob.zig");
const Animal = @import("Animal.zig");
const Monster = @import("Monster.zig");
pub const max_health: i32 = Monster.max_health;

const Creeper = @This();

animal: Animal,
monster: Monster = .{},
fuse: i32 = 0,
prev_fuse: i32 = 0,
state: i8 = idle_state,
powered: bool = false,
pending_blast: ?f32 = null,
pending_drops: u8 = 0,
pending_record: ?world.Item = null,

pub const width: f64 = 0.6;
pub const height: f64 = 1.8;
pub const idle_state: i8 = -1;
pub const lit_state: i8 = 1;
pub const fuse_ticks: i32 = 30;
pub const flash_ticks: f32 = 28.0;
pub const ignite_range: f32 = 3.0;
pub const hold_range: f32 = 7.0;
pub const blast_size: f32 = 3.0;
pub const powered_blast_size: f32 = 6.0;
pub const blast_is_flaming: bool = false;
pub const fuse_volume: f32 = 1.0;
pub const fuse_pitch: f32 = 0.5;

pub const spec: Animal.Spec = .{
    .width = width,
    .height = height,
    .max_health = max_health,
    .hurt_sound = assets.sounds.mob.creeper,
    .death_sound = assets.sounds.mob.creeperdeath,
};

fn init(position: math.Vec3) Creeper {
    var self: Creeper = .{ .animal = Animal.spawn(position, spec) };
    self.animal.on_death = dropFewItems;
    self.animal.action_state = updateActionState;
    self.animal.path_weight = Monster.blockPathWeight;
    self.monster.attack = attackEntity;
    self.monster.attack_blocked = attackBlockedEntity;
    return self;
}

pub fn spawn(position: math.Vec3) Creeper {
    return init(position);
}

pub fn deinit(self: *Creeper, gpa: std.mem.Allocator) void {
    self.animal.deinit(gpa);
}

pub fn tick(
    self: *Creeper,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    players: Animal.Players,
    rand: *world.JavaRandom,
) !void {
    self.prev_fuse = self.fuse;
    self.monster.beginTick(&self.animal);
    try self.animal.tick(gpa, world_map, players, rand);

    if (self.monster.target == null and self.fuse > 0) self.douse();
}

fn douse(self: *Creeper) void {
    self.state = idle_state;
    self.fuse -= 1;
    if (self.fuse < 0) self.fuse = 0;
}

fn attackEntity(
    monster: *Monster,
    _: *Animal,
    world_map: *const world.World,
    _: Animal.PlayerView,
    distance: f32,
    _: *world.JavaRandom,
) void {
    const self: *Creeper = @alignCast(@fieldParentPtr("monster", monster));

    const reach = if (self.state > 0) hold_range else ignite_range;
    if (distance >= reach) {
        self.douse();
        return;
    }

    if (self.fuse == 0) {
        world_map.playSoundEffect(
            self.animal.base.position.x,
            self.animal.base.position.y,
            self.animal.base.position.z,
            assets.sounds.random.fuse,
            fuse_volume,
            fuse_pitch,
        );
    }

    self.state = lit_state;
    self.fuse += 1;
    if (self.fuse >= fuse_ticks) {
        self.pending_blast = if (self.powered) powered_blast_size else blast_size;
        self.animal.dead = true;
    }
    monster.has_attacked = true;
}

fn attackBlockedEntity(
    monster: *Monster,
    _: *Animal,
    _: *const world.World,
    _: Animal.PlayerView,
    _: f32,
    _: *world.JavaRandom,
) void {
    const self: *Creeper = @alignCast(@fieldParentPtr("monster", monster));
    if (self.fuse > 0) self.douse();
}

fn updateActionState(
    animal: *Animal,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    players: Animal.Players,
    rand: *world.JavaRandom,
) anyerror!void {
    const self: *Creeper = @fieldParentPtr("animal", animal);
    try self.monster.updateActionState(animal, gpa, world_map, players, rand, true);
}

pub fn hurt(self: *Creeper, world_map: *const world.World, amount: i32, source: ?Animal.Attacker, rand: *world.JavaRandom) bool {
    if (!self.animal.hurt(world_map, amount, source, rand)) return false;
    if (source) |from| {
        if (from.player != Animal.Entity.no_id) self.monster.target = from.player;
    }
    return true;
}

pub fn canSpawnHere(self: Creeper, world_map: *const world.World, rand: *world.JavaRandom) bool {
    return Monster.canSpawnHere(self.animal, world_map, rand);
}

pub fn flashTime(self: Creeper, partial_ticks: f32) f32 {
    const prev: f32 = @floatFromInt(self.prev_fuse);
    const now: f32 = @floatFromInt(self.fuse);
    return (prev + (now - prev) * partial_ticks) / flash_ticks;
}

pub fn swellScale(self: Creeper, partial_ticks: f32) [3]f32 {
    const flash = self.flashTime(partial_ticks);
    const wobble = 1.0 + math.util.sin(flash * 100.0) * flash * 0.01;

    var swell = std.math.clamp(flash, 0.0, 1.0);
    swell *= swell;
    swell *= swell;

    const wide = (1.0 + swell * 0.4) * wobble;
    const tall = (1.0 + swell * 0.1) / wobble;
    return .{ wide, tall, wide };
}

pub fn flashWhitening(self: Creeper, partial_ticks: f32) f32 {
    const flash = self.flashTime(partial_ticks);
    if (@rem(@as(i32, @intFromFloat(flash * 10.0)), 2) == 0) return 0.0;
    return std.math.clamp(flash * 0.2, 0.0, 1.0);
}

fn dropFewItems(animal: *Animal, rand: *world.JavaRandom) void {
    const self: *Creeper = @fieldParentPtr("animal", animal);
    self.pending_drops = @intCast(rand.nextIntBound(3));

    const killer = animal.killer orelse return;
    if (killer.mob_type != Mob.skeleton) return;
    self.pending_record = if (rand.nextIntBound(2) == 0) .record_13 else .record_cat;
}

pub const Drops = struct {
    count: u8,
    record: ?world.Item = null,

    pub fn stack(self: Drops) world.Stack {
        if (self.record) |record| return .{ .id = .{ .item = record }, .count = 1 };
        return .{ .id = .{ .item = .gunpowder }, .count = 1 };
    }
};

pub fn takeDrops(self: *Creeper) ?Drops {
    if (self.pending_drops > 0) {
        const drops: Drops = .{ .count = self.pending_drops };
        self.pending_drops = 0;
        return drops;
    }

    const record = self.pending_record orelse return null;
    self.pending_record = null;
    return .{ .count = 1, .record = record };
}

pub fn toRecord(self: Creeper) world.entity_nbt.Creeper {
    return .{ .living = self.animal.toRecord(), .powered = self.powered };
}

pub fn fromRecord(record: world.entity_nbt.Creeper) Creeper {
    var self = init(record.living.position);
    self.animal.restore(record.living);
    self.powered = record.powered;
    return self;
}

pub const wire_id: u8 = 50;
pub const watched_state: u5 = 16;
pub const watched_powered: u5 = 17;

pub const mob_type: Mob.Type = .{
    .name = world.entity_nbt.creeper_id,
    .wire_id = wire_id,
    .monster = true,
    .vanishes_on_peaceful = true,
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
    const self: *const Creeper = @fieldParentPtr("animal", animal);
    out.add(watched_state, .{ .byte = self.state });
    out.add(watched_powered, .{ .byte = @intFromBool(self.powered) });
}

fn mobAdopt(animal: *Animal, metadata: Mob.Metadata) void {
    const self: *Creeper = @fieldParentPtr("animal", animal);
    if (metadata.byteAt(watched_state)) |state| self.state = state;
    if (metadata.byteAt(watched_powered)) |powered| self.powered = powered == 1;
}

fn mobSpawn(gpa: std.mem.Allocator, position: math.Vec3, _: *world.JavaRandom) anyerror!*Animal {
    const self = try gpa.create(Creeper);
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
    const self: *Creeper = @fieldParentPtr("animal", animal);
    try self.tick(gpa, world_map, players, rand);
}

fn mobTakeDrops(animal: *Animal) ?Mob.Drops {
    const self: *Creeper = @fieldParentPtr("animal", animal);
    const drops = self.takeDrops() orelse return null;
    return .{ .count = drops.count, .stack = drops.stack() };
}

fn mobHurt(animal: *Animal, world_map: *const world.World, amount: i32, source: ?Animal.Attacker, rand: *world.JavaRandom) bool {
    const self: *Creeper = @fieldParentPtr("animal", animal);
    return self.hurt(world_map, amount, source, rand);
}

fn mobStore(animal: *Animal, gpa: std.mem.Allocator) anyerror!world.nbt.Tag {
    const self: *Creeper = @fieldParentPtr("animal", animal);
    return world.entity_nbt.storeCreeper(gpa, self.toRecord());
}

fn mobLoad(gpa: std.mem.Allocator, entity: world.nbt.Compound) anyerror!?*Animal {
    const record = world.entity_nbt.loadCreeper(entity) orelse return null;
    const self = try gpa.create(Creeper);
    self.* = Creeper.fromRecord(record);
    return &self.animal;
}

fn mobDestroy(animal: *Animal, gpa: std.mem.Allocator) void {
    const self: *Creeper = @fieldParentPtr("animal", animal);
    self.deinit(gpa);
    gpa.destroy(self);
}

fn mobAfterTick(animal: *Animal, context: Mob.Tick) anyerror!void {
    const Entities = @import("../Entities.zig");
    const self: *Creeper = @fieldParentPtr("animal", animal);

    self.monster.deliverAttack(animal, context);

    const size = self.pending_blast orelse return;
    self.pending_blast = null;

    const entities: *Entities = @ptrCast(@alignCast(context.entities));
    try explosion.detonate(
        context.gpa,
        entities,
        context.world_map,
        context.roster,
        animal.base.position,
        size,
        blast_is_flaming,
        context.rand,
    );
}

test "a creeper is the size, health and speed EntityCreeper inherits" {
    const self = Creeper.spawn(math.Vec3.init(0, 0, 0));

    try std.testing.expectEqual(@as(f64, 0.6), self.animal.base.width);
    try std.testing.expectEqual(@as(f64, 1.8), self.animal.base.height);
    try std.testing.expectEqual(@as(i32, 20), self.animal.health);
    try std.testing.expectEqual(Animal.default_move_speed, self.animal.move_speed);
    try std.testing.expectEqual(idle_state, self.state);
    try std.testing.expect(!self.powered);
}

test "a creeper lights its fuse inside three blocks and holds it out to seven" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();
    var rand = world.JavaRandom.init(0);
    var self = Creeper.spawn(math.Vec3.init(8.5, 1, 8.5));

    const player = Animal.PlayerView{
        .position = math.Vec3.init(12.5, 1, 8.5),
        .eye_height = 1.62,
        .alive = true,
    };

    self.monster.attack(&self.monster, &self.animal, &w, player, 5.0, &rand);
    try std.testing.expectEqual(@as(i32, 0), self.fuse);
    try std.testing.expectEqual(idle_state, self.state);
    try std.testing.expect(!self.monster.has_attacked);

    self.monster.attack(&self.monster, &self.animal, &w, player, 2.0, &rand);
    try std.testing.expectEqual(@as(i32, 1), self.fuse);
    try std.testing.expectEqual(lit_state, self.state);
    try std.testing.expect(self.monster.has_attacked);

    self.monster.attack(&self.monster, &self.animal, &w, player, 6.0, &rand);
    try std.testing.expectEqual(@as(i32, 2), self.fuse);

    self.monster.attack(&self.monster, &self.animal, &w, player, 8.0, &rand);
    try std.testing.expectEqual(@as(i32, 1), self.fuse);
    try std.testing.expectEqual(idle_state, self.state);
}

test "a creeper held beside the player for thirty ticks blows itself up" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();
    var rand = world.JavaRandom.init(0);
    var self = Creeper.spawn(math.Vec3.init(8.5, 1, 8.5));

    const player = Animal.PlayerView{
        .position = math.Vec3.init(9.5, 1, 8.5),
        .eye_height = 1.62,
        .alive = true,
    };

    for (0..fuse_ticks - 1) |_| {
        self.monster.attack(&self.monster, &self.animal, &w, player, 1.0, &rand);
        try std.testing.expect(self.pending_blast == null);
        try std.testing.expect(!self.animal.dead);
    }

    self.monster.attack(&self.monster, &self.animal, &w, player, 1.0, &rand);
    try std.testing.expectEqual(blast_size, self.pending_blast.?);
    try std.testing.expect(self.animal.dead);
}

test "a charged creeper leaves twice the crater" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();
    var rand = world.JavaRandom.init(0);
    var self = Creeper.spawn(math.Vec3.init(8.5, 1, 8.5));
    self.powered = true;
    self.fuse = fuse_ticks - 1;

    const player = Animal.PlayerView{
        .position = math.Vec3.init(9.5, 1, 8.5),
        .eye_height = 1.62,
        .alive = true,
    };
    self.monster.attack(&self.monster, &self.animal, &w, player, 1.0, &rand);

    try std.testing.expectEqual(powered_blast_size, self.pending_blast.?);
}

test "a creeper that loses sight of the player lets its fuse burn back down" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();
    var rand = world.JavaRandom.init(0);
    var self = Creeper.spawn(math.Vec3.init(8.5, 1, 8.5));
    self.fuse = 10;
    self.state = lit_state;

    const player = Animal.PlayerView{
        .position = math.Vec3.init(9.5, 1, 8.5),
        .eye_height = 1.62,
        .alive = true,
    };

    self.monster.attack_blocked(&self.monster, &self.animal, &w, player, 1.0, &rand);
    try std.testing.expectEqual(@as(i32, 9), self.fuse);
    try std.testing.expectEqual(idle_state, self.state);

    self.fuse = 0;
    self.monster.attack_blocked(&self.monster, &self.animal, &w, player, 1.0, &rand);
    try std.testing.expectEqual(@as(i32, 0), self.fuse);
}

test "a creeper with nobody to chase lets its fuse burn back down" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var rand = world.JavaRandom.init(5);
    var self = Creeper.spawn(math.Vec3.init(8.5, 1, 8.5));
    defer self.deinit(gpa);
    self.fuse = 6;
    self.state = lit_state;

    try self.tick(gpa, &w, .{}, &rand);

    try std.testing.expectEqual(@as(i32, 5), self.fuse);
    try std.testing.expectEqual(idle_state, self.state);
    try std.testing.expectEqual(@as(i32, 6), self.prev_fuse);
}

test "a fusing creeper stands its ground instead of walking on" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var rand = world.JavaRandom.init(5);
    var self = Creeper.spawn(math.Vec3.init(8.5, 1, 8.5));
    defer self.deinit(gpa);
    self.animal.base.on_ground = true;

    const player = Animal.PlayerView{
        .id = 1,
        .position = math.Vec3.init(9.5, 1, 8.5),
        .eye_height = 1.62,
        .alive = true,
    };

    // The first tick only acquires the target; the fuse starts on the tick after.
    for (0..5) |_| try self.tick(gpa, &w, Animal.Players.one(&player), &rand);

    try std.testing.expect(self.monster.has_attacked);
    try std.testing.expect(self.fuse > 0);
    try std.testing.expect(self.animal.path == null);
    try std.testing.expectApproxEqAbs(@as(f64, 8.5), self.animal.base.position.x, 0.5);
}

test "a creeper a skeleton killed leaves one of the two records behind its gunpowder" {
    var w = world.World.init(std.testing.allocator);
    defer w.deinit();
    var saw_13 = false;
    var saw_cat = false;

    for (0..20) |seed| {
        var rand = world.JavaRandom.init(@intCast(seed));
        var self = Creeper.spawn(math.Vec3.init(8, 1, 8));

        _ = self.hurt(&w, max_health, .{
            .position = math.Vec3.init(6, 1, 8),
            .mob = 11,
            .mob_type = Mob.skeleton,
        }, &rand);

        var record: ?world.Item = null;
        while (self.takeDrops()) |drops| {
            if (drops.record) |dropped| {
                try std.testing.expectEqual(@as(u8, 1), drops.count);
                try std.testing.expectEqual(dropped, drops.stack().id.item);
                record = dropped;
            } else {
                try std.testing.expectEqual(world.Item.gunpowder, drops.stack().id.item);
            }
        }

        switch (record orelse return error.TestUnexpectedResult) {
            .record_13 => saw_13 = true,
            .record_cat => saw_cat = true,
            else => return error.TestUnexpectedResult,
        }
    }

    try std.testing.expect(saw_13 and saw_cat);
}

test "only a skeleton's kill leaves a record, and a stale attacker cannot conjure one" {
    var w = world.World.init(std.testing.allocator);
    defer w.deinit();
    var rand = world.JavaRandom.init(0);

    var by_player = Creeper.spawn(math.Vec3.init(8, 1, 8));
    _ = by_player.hurt(&w, max_health, .{ .position = math.Vec3.init(6, 1, 8), .player = 3 }, &rand);
    try std.testing.expect(by_player.pending_record == null);

    var drowned = Creeper.spawn(math.Vec3.init(8, 1, 8));
    _ = drowned.hurt(&w, 1, .{
        .position = math.Vec3.init(6, 1, 8),
        .mob = 11,
        .mob_type = Mob.skeleton,
    }, &rand);
    try std.testing.expect(drowned.animal.isAlive());

    drowned.animal.hurt_resistance = 0;
    _ = drowned.animal.hurt(&w, max_health, null, &rand);
    try std.testing.expect(!drowned.animal.isAlive());
    try std.testing.expect(drowned.pending_record == null);
}

test "a dying creeper drops nought to two gunpowder, but one that detonates leaves nothing" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();
    var dropped_nothing = false;
    var dropped_something = false;

    for (0..20) |seed| {
        var rand = world.JavaRandom.init(@intCast(seed));
        var self = Creeper.spawn(math.Vec3.init(8, 1, 8));

        _ = self.animal.hurt(&w, max_health, null, &rand);
        try std.testing.expect(!self.animal.isAlive());

        if (self.takeDrops()) |drops| {
            try std.testing.expect(drops.count >= 1 and drops.count <= 2);
            try std.testing.expectEqual(world.Item.gunpowder, drops.stack().id.item);
            dropped_something = true;
        } else {
            dropped_nothing = true;
        }
    }

    try std.testing.expect(dropped_nothing);
    try std.testing.expect(dropped_something);

    var blast_rand = world.JavaRandom.init(0);
    var blown = Creeper.spawn(math.Vec3.init(8, 1, 8));
    blown.fuse = fuse_ticks - 1;
    const player = Animal.PlayerView{
        .position = math.Vec3.init(8.5, 1, 8),
        .eye_height = 1.62,
        .alive = true,
    };
    blown.monster.attack(&blown.monster, &blown.animal, &w, player, 1.0, &blast_rand);

    try std.testing.expect(blown.animal.dead);
    try std.testing.expect(blown.takeDrops() == null);
}

test "a struck creeper turns on the player who struck it" {
    var w = world.World.init(std.testing.allocator);
    defer w.deinit();
    var rand = world.JavaRandom.init(0);
    var self = Creeper.spawn(math.Vec3.init(8, 1, 8));

    try std.testing.expect(self.hurt(&w, 3, .{ .position = math.Vec3.init(6, 1, 8), .player = 11 }, &rand));
    try std.testing.expectEqual(@as(?Animal.Entity.Id, 11), self.monster.target);
}

test "the swell grows with the fuse and pinches the creeper taller" {
    var self = Creeper.spawn(math.Vec3.init(0, 0, 0));

    const calm = self.swellScale(1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), calm[0], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), calm[1], 1.0e-6);

    self.fuse = fuse_ticks;
    self.prev_fuse = fuse_ticks;
    const swollen = self.swellScale(1.0);
    try std.testing.expect(swollen[0] > calm[0]);
    try std.testing.expect(swollen[2] > calm[2]);
    try std.testing.expect(swollen[0] > swollen[1]);
}

test "the flash blinks on and off as the fuse runs" {
    var self = Creeper.spawn(math.Vec3.init(0, 0, 0));
    try std.testing.expectApproxEqAbs(@as(f32, 0), self.flashWhitening(1.0), 1.0e-6);

    var lit_frames: u32 = 0;
    var dark_frames: u32 = 0;
    var tick_count: i32 = 0;
    while (tick_count <= fuse_ticks) : (tick_count += 1) {
        self.prev_fuse = tick_count;
        self.fuse = tick_count;
        if (self.flashWhitening(1.0) > 0.0) lit_frames += 1 else dark_frames += 1;
    }

    try std.testing.expect(lit_frames > 0);
    try std.testing.expect(dark_frames > 0);
}

test "a creeper keeps its charge across a record round trip" {
    var self = Creeper.spawn(math.Vec3.init(12.5, 64.0, -3.25));
    self.powered = true;
    self.animal.health = 11;
    self.animal.yaw = 42.0;

    const restored = Creeper.fromRecord(self.toRecord());

    try std.testing.expect(restored.powered);
    try std.testing.expectEqual(@as(i32, 11), restored.animal.health);
    try std.testing.expectApproxEqAbs(@as(f32, 42.0), restored.animal.yaw, 1.0e-6);

    var plain = Creeper.spawn(math.Vec3.init(0, 64, 0));
    plain.animal.health = 20;
    try std.testing.expect(!Creeper.fromRecord(plain.toRecord()).powered);
}

test "a creeper's fuse and charge ride along as watched values" {
    var lit = spawn(math.Vec3.init(0, 0, 0));
    lit.state = lit_state;
    lit.powered = true;

    var watched: Mob.Watched = .{};
    Mob.watch(Mob.creeper, &lit.animal, &watched);

    var calm = spawn(math.Vec3.init(0, 0, 0));
    Mob.adopt(Mob.creeper, &calm.animal, watched.view());

    try std.testing.expectEqual(lit_state, calm.state);
    try std.testing.expect(calm.powered);
}
