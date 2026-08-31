const std = @import("std");

const assets = @import("assets");
const math = @import("math");
const world = @import("world");

const Mob = @import("../mob.zig");
const physics = @import("../physics.zig");
const Animal = @import("Animal.zig");
const Monster = @import("Monster.zig");
pub const max_health: i32 = Monster.max_health;
const Zombie = @import("Zombie.zig");
pub const width: f64 = Zombie.width;
pub const height: f64 = Zombie.height;
pub const idle_move_speed: f32 = Zombie.move_speed;

const PigZombie = @This();

animal: Animal,
monster: Monster = .{ .attack_strength = attack_strength },
ticks_existed: i32 = 0,
anger_level: i32 = 0,
rouses_horde: ?Animal.Entity.Id = null,
pending_drops: u8 = 0,

pub const chase_move_speed: f32 = 0.95;
pub const attack_strength: i32 = 5;
pub const anger_base: i32 = 400;
pub const anger_spread: i32 = 400;
pub const horde_reach: f64 = 32.0;

pub const spec: Animal.Spec = .{
    .width = width,
    .height = height,
    .max_health = max_health,
    .move_speed = idle_move_speed,
    .immune_to_fire = true,
    .living_sound = assets.sounds.mob.zombiepig.zpig,
    .hurt_sound = assets.sounds.mob.zombiepig.zpighurt,
    .death_sound = assets.sounds.mob.zombiepig.zpigdeath,
};

fn init(position: math.Vec3) PigZombie {
    var self: PigZombie = .{ .animal = Animal.spawn(position, spec) };
    self.animal.on_death = dropFewItems;
    self.animal.action_state = updateActionState;
    self.animal.path_weight = Monster.blockPathWeight;
    return self;
}

pub fn spawn(position: math.Vec3) PigZombie {
    return init(position);
}

pub fn deinit(self: *PigZombie, gpa: std.mem.Allocator) void {
    self.animal.deinit(gpa);
}

pub fn tick(
    self: *PigZombie,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    players: Animal.Players,
    rand: *world.JavaRandom,
) !void {
    self.ticks_existed += 1;
    self.monster.beginTick(&self.animal);
    self.animal.move_speed = if (self.monster.target != null) chase_move_speed else idle_move_speed;
    try self.animal.tick(gpa, world_map, players, rand);
}

fn updateActionState(
    animal: *Animal,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    players: Animal.Players,
    rand: *world.JavaRandom,
) anyerror!void {
    const self: *PigZombie = @fieldParentPtr("animal", animal);
    Zombie.burnInDaylight(animal, world_map, rand);
    try self.monster.updateActionState(animal, gpa, world_map, players, rand, self.anger_level != 0);
}

pub fn becomeAngryAt(self: *PigZombie, player: Animal.Entity.Id, rand: *world.JavaRandom) void {
    self.monster.target = player;
    self.anger_level = anger_base + rand.nextIntBound(anger_spread);
}

pub fn hurt(self: *PigZombie, world_map: *const world.World, amount: i32, source: ?Animal.Attacker, rand: *world.JavaRandom) bool {
    if (source) |from| {
        if (from.player != Animal.Entity.no_id) {
            self.rouses_horde = from.player;
            self.becomeAngryAt(from.player, rand);
        }
    }

    if (!self.animal.hurt(world_map, amount, source, rand)) return false;

    if (source) |from| {
        if (from.player != Animal.Entity.no_id) self.monster.target = from.player;
    }
    return true;
}

pub fn canSpawnHere(self: PigZombie, world_map: *const world.World) bool {
    if (!world_map.difficulty.atLeast(.easy)) return false;

    const box = self.animal.base.boundingBox();
    return !physics.isBoxObstructed(world_map, box) and !physics.isAnyLiquid(world_map, box);
}

fn dropFewItems(animal: *Animal, rand: *world.JavaRandom) void {
    const self: *PigZombie = @fieldParentPtr("animal", animal);
    self.pending_drops = @intCast(rand.nextIntBound(3));
}

pub const Drops = struct {
    count: u8,

    pub fn stack(_: Drops) world.Stack {
        return .{ .id = .{ .item = .pork_cooked }, .count = 1 };
    }
};

pub fn takeDrops(self: *PigZombie) ?Drops {
    if (self.pending_drops == 0) return null;
    const drops: Drops = .{ .count = self.pending_drops };
    self.pending_drops = 0;
    return drops;
}

pub fn renderAge(self: PigZombie, partial_ticks: f32) f32 {
    return @as(f32, @floatFromInt(self.ticks_existed)) + partial_ticks;
}

pub fn toRecord(self: PigZombie) world.entity_nbt.PigZombie {
    return .{ .living = self.animal.toRecord(), .anger = @intCast(self.anger_level) };
}

pub fn fromRecord(record: world.entity_nbt.PigZombie) PigZombie {
    var self = init(record.living.position);
    self.animal.restore(record.living);
    self.anger_level = record.anger;
    return self;
}

pub const wire_id: u8 = 57;

pub const mob_type: Mob.Type = .{
    .name = world.entity_nbt.pig_zombie_id,
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
};

fn mobSpawn(gpa: std.mem.Allocator, position: math.Vec3, _: *world.JavaRandom) anyerror!*Animal {
    const self = try gpa.create(PigZombie);
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
    const self: *PigZombie = @fieldParentPtr("animal", animal);
    try self.tick(gpa, world_map, players, rand);
}

fn mobTakeDrops(animal: *Animal) ?Mob.Drops {
    const self: *PigZombie = @fieldParentPtr("animal", animal);
    const drops = self.takeDrops() orelse return null;
    return .{ .count = drops.count, .stack = drops.stack() };
}

fn mobHurt(animal: *Animal, world_map: *const world.World, amount: i32, source: ?Animal.Attacker, rand: *world.JavaRandom) bool {
    const self: *PigZombie = @fieldParentPtr("animal", animal);
    return self.hurt(world_map, amount, source, rand);
}

fn mobStore(animal: *Animal, gpa: std.mem.Allocator) anyerror!world.nbt.Tag {
    const self: *PigZombie = @fieldParentPtr("animal", animal);
    return world.entity_nbt.storePigZombie(gpa, self.toRecord());
}

fn mobLoad(gpa: std.mem.Allocator, entity: world.nbt.Compound) anyerror!?*Animal {
    const record = world.entity_nbt.loadPigZombie(entity) orelse return null;
    const self = try gpa.create(PigZombie);
    self.* = PigZombie.fromRecord(record);
    return &self.animal;
}

fn mobDestroy(animal: *Animal, gpa: std.mem.Allocator) void {
    const self: *PigZombie = @fieldParentPtr("animal", animal);
    self.deinit(gpa);
    gpa.destroy(self);
}

fn mobAfterTick(animal: *Animal, context: Mob.Tick) anyerror!void {
    const Entities = @import("../Entities.zig");
    const self: *PigZombie = @fieldParentPtr("animal", animal);

    if (self.rouses_horde) |attacker| {
        self.rouses_horde = null;
        const entities: *Entities = @ptrCast(@alignCast(context.entities));
        self.rouseHorde(entities, attacker, context.rand);
    }

    self.monster.deliverAttack(animal, context);
}

fn rouseHorde(self: *PigZombie, entities: anytype, attacker: Animal.Entity.Id, rand: *world.JavaRandom) void {
    const box = self.animal.base.boundingBox().expand(horde_reach, horde_reach, horde_reach);
    var horde = entities.of(PigZombie, Mob.pig_zombie);
    while (horde.next()) |other| {
        if (other == self) continue;
        if (!box.intersects(other.animal.base.boundingBox())) continue;
        other.becomeAngryAt(attacker, rand);
    }
}

test "a pig zombie is the size, health and speed EntityPigZombie sets itself to" {
    const self = PigZombie.spawn(math.Vec3.init(0, 0, 0));

    try std.testing.expectEqual(@as(f64, 0.6), self.animal.base.width);
    try std.testing.expectEqual(@as(f64, 1.8), self.animal.base.height);
    try std.testing.expectEqual(max_health, self.animal.health);
    try std.testing.expectEqual(idle_move_speed, self.animal.move_speed);
    try std.testing.expectEqual(attack_strength, self.monster.attack_strength);
    try std.testing.expect(self.animal.immune_to_fire);
}

test "a calm pig zombie ignores the player, an angered one hunts them down" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var rand = world.JavaRandom.init(0);
    var self = PigZombie.spawn(math.Vec3.init(8.5, 1, 8.5));
    defer self.deinit(gpa);

    const player = Animal.PlayerView{
        .id = 3,
        .position = math.Vec3.init(12.5, 1, 8.5),
        .eye_height = 1.62,
        .alive = true,
    };
    const players = Animal.Players.one(&player);

    try std.testing.expect(self.monster.findPlayerToAttack(self.animal, &w, players, self.anger_level != 0) == null);

    self.becomeAngryAt(player.id, &rand);
    try std.testing.expectEqual(
        @as(Animal.Entity.Id, 3),
        self.monster.findPlayerToAttack(self.animal, &w, players, self.anger_level != 0).?,
    );
    try std.testing.expect(self.anger_level >= anger_base);
    try std.testing.expect(self.anger_level < anger_base + anger_spread);
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
                }
            }
        }
    }
    return w;
}

test "an angered pig zombie walks the player down and speeds up to do it" {
    const gpa = std.testing.allocator;
    var w = try stoneFloor(gpa);
    defer w.deinit();

    var rand = world.JavaRandom.init(7);
    var self = PigZombie.spawn(math.Vec3.init(8.5, 1, 8.5));
    defer self.deinit(gpa);
    self.animal.base.on_ground = true;

    const player = Animal.PlayerView{
        .id = 1,
        .position = math.Vec3.init(20.5, 1, 8.5),
        .eye_height = 1.62,
        .alive = true,
    };
    self.becomeAngryAt(player.id, &rand);

    const started = self.animal.distanceSquaredTo(player.position);
    for (0..200) |_| try self.tick(gpa, &w, Animal.Players.one(&player), &rand);

    try std.testing.expectEqual(chase_move_speed, self.animal.move_speed);
    try std.testing.expect(self.animal.distanceSquaredTo(player.position) < started);
}

test "a calm pig zombie keeps to the slower of its two paces" {
    const gpa = std.testing.allocator;
    var w = try stoneFloor(gpa);
    defer w.deinit();

    var rand = world.JavaRandom.init(7);
    var self = PigZombie.spawn(math.Vec3.init(8.5, 1, 8.5));
    defer self.deinit(gpa);
    self.animal.base.on_ground = true;

    const player = Animal.PlayerView{
        .id = 1,
        .position = math.Vec3.init(12.5, 1, 8.5),
        .eye_height = 1.62,
        .alive = true,
    };

    for (0..200) |_| {
        try self.tick(gpa, &w, Animal.Players.one(&player), &rand);
        try std.testing.expectEqual(idle_move_speed, self.animal.move_speed);
    }

    try std.testing.expect(self.monster.target == null);
}

test "a hit from a player angers the pig zombie at whoever struck it" {
    var w = world.World.init(std.testing.allocator);
    defer w.deinit();
    var rand = world.JavaRandom.init(0);
    var self = PigZombie.spawn(math.Vec3.init(8, 1, 8));

    try std.testing.expect(self.hurt(&w, 3, .{ .position = math.Vec3.init(6, 1, 8), .player = 11 }, &rand));

    try std.testing.expect(self.anger_level > 0);
    try std.testing.expectEqual(@as(Animal.Entity.Id, 11), self.monster.target.?);
    try std.testing.expectEqual(@as(?Animal.Entity.Id, 11), self.rouses_horde);
}

test "damage from no player leaves the pig zombie calm" {
    var w = world.World.init(std.testing.allocator);
    defer w.deinit();
    var rand = world.JavaRandom.init(0);
    var self = PigZombie.spawn(math.Vec3.init(8, 1, 8));

    try std.testing.expect(self.hurt(&w, 1, null, &rand));
    try std.testing.expect(self.hurt(&w, 4, .{ .position = math.Vec3.init(6, 1, 8) }, &rand));

    try std.testing.expectEqual(@as(i32, 0), self.anger_level);
    try std.testing.expect(self.monster.target == null);
}

test "a dying pig zombie drops nought to two cooked porkchops" {
    var w = world.World.init(std.testing.allocator);
    defer w.deinit();
    var dropped_nothing = false;
    var dropped_something = false;

    for (0..20) |seed| {
        var rand = world.JavaRandom.init(@intCast(seed));
        var self = PigZombie.spawn(math.Vec3.init(8, 1, 8));

        _ = self.animal.hurt(&w, max_health, null, &rand);
        try std.testing.expect(!self.animal.isAlive());

        if (self.takeDrops()) |drops| {
            try std.testing.expect(drops.count >= 1 and drops.count <= 2);
            try std.testing.expectEqual(world.Item.pork_cooked, drops.stack().id.item);
            dropped_something = true;
        } else {
            dropped_nothing = true;
        }

        try std.testing.expect(self.takeDrops() == null);
    }

    try std.testing.expect(dropped_nothing);
    try std.testing.expect(dropped_something);
}

test "a pig zombie keeps its grudge across a record round trip" {
    var self = PigZombie.spawn(math.Vec3.init(12.5, 64.0, -3.25));
    self.anger_level = 617;
    self.animal.health = 14;
    self.animal.yaw = 42.0;
    self.animal.base.on_ground = true;

    const restored = PigZombie.fromRecord(self.toRecord());

    try std.testing.expectEqual(@as(i32, 617), restored.anger_level);
    try std.testing.expectEqual(@as(i32, 14), restored.animal.health);
    try std.testing.expectApproxEqAbs(@as(f32, 42.0), restored.animal.yaw, 1.0e-6);
    try std.testing.expect(restored.animal.base.on_ground);
    try std.testing.expectApproxEqAbs(@as(f64, -3.25), restored.animal.base.position.z, 1.0e-9);
}

test "a pig zombie spawns wherever it fits and stays dry, however bright the nether is" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    const clear = PigZombie.spawn(math.Vec3.init(8.5, 1, 8.5));
    try std.testing.expect(clear.canSpawnHere(&w));

    const chunk = w.getChunk(0, 0).?;
    for (0..world.Chunk.width) |x| {
        for (0..world.Chunk.width) |z| {
            chunk.setBlockLight(@intCast(x), 1, @intCast(z), 15);
        }
    }
    try std.testing.expect(clear.canSpawnHere(&w));

    w.setBlock(8, 2, 8, .stone);
    try std.testing.expect(!clear.canSpawnHere(&w));

    w.setBlock(8, 2, 8, .stationary_water);
    try std.testing.expect(!clear.canSpawnHere(&w));
}
