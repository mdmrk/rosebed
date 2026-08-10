const std = @import("std");

const math = @import("math");
const world = @import("world");

const Animal = @import("animal.zig");
const Mob = @import("mob.zig");
const physics = @import("physics.zig");
const raycast = @import("raycast.zig");

const PigZombie = @This();

animal: Animal,
ticks_existed: i32 = 0,
anger_level: i32 = 0,
attack_time: i32 = 0,
target: ?Animal.Entity.Id = null,
pending_attack: bool = false,
rouses_horde: ?Animal.Entity.Id = null,
pending_drops: u8 = 0,

pub const width: f64 = 0.6;
pub const height: f64 = 1.8;
pub const max_health: i32 = 20;
pub const idle_move_speed: f32 = 0.5;
pub const chase_move_speed: f32 = 0.95;
pub const attack_strength: i32 = 5;
pub const attack_cooldown: i32 = 20;
pub const attack_reach: f32 = 2.0;
pub const sight_range: f64 = 16.0;
pub const anger_base: i32 = 400;
pub const anger_spread: i32 = 400;
pub const horde_reach: f64 = 32.0;
pub const bright_light: f32 = 0.5;
pub const daylight_fire_ticks: i32 = 300;

pub const spec: Animal.Spec = .{
    .width = width,
    .height = height,
    .max_health = max_health,
    .move_speed = idle_move_speed,
    .immune_to_fire = true,
};

fn init(position: math.Vec3) PigZombie {
    var self: PigZombie = .{ .animal = Animal.spawn(position, spec) };
    self.animal.on_death = dropFewItems;
    self.animal.action_state = updateActionState;
    self.animal.path_weight = blockPathWeight;
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
    self.animal.move_speed = if (self.target != null) chase_move_speed else idle_move_speed;
    if (self.attack_time > 0) self.attack_time -= 1;
    try self.animal.tick(gpa, world_map, players, rand);
}

fn blockPathWeight(world_map: *const world.World, x: i32, y: i32, z: i32) f32 {
    return 0.5 - world.light.brightnessAt(world_map, x, y, z, 0);
}

fn brightnessOf(world_map: *const world.World, animal: Animal) f32 {
    const sample = animal.base.lightSamplePosition();
    return world.light.brightnessAt(world_map, sample[0], sample[1], sample[2], 0);
}

fn burnInDaylight(self: *PigZombie, world_map: *const world.World, rand: *world.JavaRandom) void {
    if (!world_map.isDaytime()) return;

    const brightness = brightnessOf(world_map, self.animal);
    if (brightness <= bright_light) return;

    const at = self.animal.base.position;
    if (!world_map.canBlockSeeTheSky(
        math.util.floorDouble(at.x),
        math.util.floorDouble(at.y),
        math.util.floorDouble(at.z),
    )) return;

    if (rand.nextFloat() * 30.0 >= (brightness - 0.4) * 2.0) return;
    self.animal.fire = daylight_fire_ticks;
}

fn canSee(self: PigZombie, world_map: *const world.World, view: Animal.PlayerView) bool {
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

fn targetView(self: PigZombie, players: Animal.Players) ?Animal.PlayerView {
    return players.byId(self.target orelse return null);
}

fn findPlayerToAttack(
    self: PigZombie,
    world_map: *const world.World,
    players: Animal.Players,
) ?Animal.Entity.Id {
    if (self.anger_level == 0) return null;
    const view = players.closestTo(self.animal.base.position, sight_range) orelse return null;
    if (!self.canSee(world_map, view)) return null;
    return view.id;
}

fn attackEntity(self: *PigZombie, view: Animal.PlayerView, distance: f32) void {
    if (self.attack_time > 0 or distance >= attack_reach) return;

    const box = self.animal.base.boundingBox();
    if (view.position.y + view.height <= box.min_y or view.position.y >= box.max_y) return;

    self.attack_time = attack_cooldown;
    self.pending_attack = true;
}

fn pathToTarget(
    self: *PigZombie,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    players: Animal.Players,
) !void {
    const view = self.targetView(players) orelse return;
    try self.animal.pathTowards(gpa, world_map, view.position, Animal.chase_path_range);
}

fn updateActionState(
    animal: *Animal,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    players: Animal.Players,
    rand: *world.JavaRandom,
) anyerror!void {
    const self: *PigZombie = @fieldParentPtr("animal", animal);

    self.burnInDaylight(world_map, rand);
    if (brightnessOf(world_map, animal.*) > bright_light) animal.entity_age += 2;

    if (self.target == null) {
        self.target = self.findPlayerToAttack(world_map, players);
        if (self.target != null) try self.pathToTarget(gpa, world_map, players);
    } else if (self.targetView(players)) |view| {
        if (!view.alive) {
            self.target = null;
        } else {
            const distance: f32 = @floatCast(@sqrt(animal.distanceSquaredTo(view.position)));
            if (self.canSee(world_map, view)) self.attackEntity(view, distance);
        }
    }

    if (self.target == null or (animal.path != null and rand.nextIntBound(20) != 0)) {
        if ((animal.path == null and rand.nextIntBound(80) == 0) or rand.nextIntBound(80) == 0) {
            try animal.findWanderPath(gpa, world_map, rand);
        }
    } else {
        try self.pathToTarget(gpa, world_map, players);
    }

    animal.pitch = 0;

    if (animal.path != null and rand.nextIntBound(100) != 0) {
        const chase: ?Animal.Chase = if (self.targetView(players)) |view| .{
            .position = view.position,
            .eye_height = view.eye_height,
            .ceased = false,
        } else null;
        animal.followPath(gpa, rand, chase);
    } else {
        animal.idleActionState(players, rand);
        animal.clearPath(gpa);
    }
}

pub fn becomeAngryAt(self: *PigZombie, player: Animal.Entity.Id, rand: *world.JavaRandom) void {
    self.target = player;
    self.anger_level = anger_base + rand.nextIntBound(anger_spread);
}

pub fn hurt(self: *PigZombie, amount: i32, source: ?Animal.Attacker, rand: *world.JavaRandom) bool {
    if (source) |from| {
        if (from.player != Animal.Entity.no_id) {
            self.rouses_horde = from.player;
            self.becomeAngryAt(from.player, rand);
        }
    }

    if (!self.animal.hurt(amount, source, rand)) return false;

    if (source) |from| {
        if (from.player != Animal.Entity.no_id) self.target = from.player;
    }
    return true;
}

pub fn canSpawnHere(self: PigZombie, world_map: *const world.World) bool {
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
    var self = init(math.Vec3.init(
        record.living.position[0],
        record.living.position[1],
        record.living.position[2],
    ));
    self.animal.restore(record.living);
    self.anger_level = record.anger;
    return self;
}

pub const wire_id: u8 = 57;

pub const mob_type: Mob.Type = .{
    .name = world.entity_nbt.pig_zombie_id,
    .wire_id = wire_id,
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

fn mobHurt(animal: *Animal, amount: i32, source: ?Animal.Attacker, rand: *world.JavaRandom) bool {
    const self: *PigZombie = @fieldParentPtr("animal", animal);
    return self.hurt(amount, source, rand);
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
    const Entities = @import("entities.zig");
    const self: *PigZombie = @fieldParentPtr("animal", animal);
    const entities: *Entities = @ptrCast(@alignCast(context.entities));

    if (self.rouses_horde) |attacker| {
        self.rouses_horde = null;
        self.rouseHorde(entities, attacker, context.rand);
    }

    if (!self.pending_attack) return;
    self.pending_attack = false;

    const player = context.playerById(self.target orelse return) orelse return;
    if (player.health <= 0) return;
    player.hurtFrom(attack_strength, animal.base.position);
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

    try std.testing.expect(self.findPlayerToAttack(&w, players) == null);

    self.becomeAngryAt(player.id, &rand);
    try std.testing.expectEqual(@as(Animal.Entity.Id, 3), self.findPlayerToAttack(&w, players).?);
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
            for (0..world.constants.chunk_width) |x| {
                for (0..world.constants.chunk_width) |z| {
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

test "a pig zombie in reach swings for five, then waits out its cooldown" {
    var self = PigZombie.spawn(math.Vec3.init(8.5, 1, 8.5));

    const player = Animal.PlayerView{
        .position = math.Vec3.init(9.5, 1, 8.5),
        .eye_height = 1.62,
        .alive = true,
    };

    self.attackEntity(player, 1.0);
    try std.testing.expect(self.pending_attack);
    try std.testing.expectEqual(attack_cooldown, self.attack_time);

    self.pending_attack = false;
    self.attackEntity(player, 1.0);
    try std.testing.expect(!self.pending_attack);

    self.attack_time = 0;
    self.attackEntity(player, attack_reach);
    try std.testing.expect(!self.pending_attack);
}

test "a pig zombie never reaches a player standing above or below it" {
    var self = PigZombie.spawn(math.Vec3.init(8.5, 1, 8.5));

    const overhead = Animal.PlayerView{
        .position = math.Vec3.init(8.5, 4, 8.5),
        .eye_height = 1.62,
        .alive = true,
    };
    self.attackEntity(overhead, 1.0);
    try std.testing.expect(!self.pending_attack);

    const underfoot = Animal.PlayerView{
        .position = math.Vec3.init(8.5, -1.0, 8.5),
        .eye_height = 1.62,
        .alive = true,
    };
    self.attackEntity(underfoot, 1.0);
    try std.testing.expect(!self.pending_attack);
}

test "a hit from a player angers the pig zombie at whoever struck it" {
    var rand = world.JavaRandom.init(0);
    var self = PigZombie.spawn(math.Vec3.init(8, 1, 8));

    try std.testing.expect(self.hurt(3, .{ .position = math.Vec3.init(6, 1, 8), .player = 11 }, &rand));

    try std.testing.expect(self.anger_level > 0);
    try std.testing.expectEqual(@as(Animal.Entity.Id, 11), self.target.?);
    try std.testing.expectEqual(@as(?Animal.Entity.Id, 11), self.rouses_horde);
}

test "damage from no player leaves the pig zombie calm" {
    var rand = world.JavaRandom.init(0);
    var self = PigZombie.spawn(math.Vec3.init(8, 1, 8));

    try std.testing.expect(self.hurt(1, null, &rand));
    try std.testing.expect(self.hurt(4, .{ .position = math.Vec3.init(6, 1, 8) }, &rand));

    try std.testing.expectEqual(@as(i32, 0), self.anger_level);
    try std.testing.expect(self.target == null);
}

test "a dying pig zombie drops nought to two cooked porkchops" {
    var dropped_nothing = false;
    var dropped_something = false;

    for (0..20) |seed| {
        var rand = world.JavaRandom.init(@intCast(seed));
        var self = PigZombie.spawn(math.Vec3.init(8, 1, 8));

        _ = self.animal.hurt(max_health, null, &rand);
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

test "a pig zombie wanders towards the dark, not the light" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    w.getChunk(0, 0).?.setSkyLight(4, 1, 8, 15);

    try std.testing.expect(blockPathWeight(&w, 8, 1, 8) > blockPathWeight(&w, 4, 1, 8));
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

test "a pig zombie only spawns where it fits and stays dry" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    const clear = PigZombie.spawn(math.Vec3.init(8.5, 1, 8.5));
    try std.testing.expect(clear.canSpawnHere(&w));

    w.setBlock(8, 2, 8, .stone);
    try std.testing.expect(!clear.canSpawnHere(&w));

    w.setBlock(8, 2, 8, .stationary_water);
    try std.testing.expect(!clear.canSpawnHere(&w));
}
