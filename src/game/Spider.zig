const std = @import("std");

const assets = @import("assets");
const math = @import("math");
const world = @import("world");

const Animal = @import("Animal.zig");
const Mob = @import("mob.zig");
const Monster = @import("Monster.zig");
pub const max_health: i32 = Monster.max_health;

const Spider = @This();

animal: Animal,
monster: Monster = .{ .needs_line_of_sight = false },
pending_drops: u8 = 0,

pub const width: f64 = 1.4;
pub const height: f64 = 0.9;
pub const move_speed: f32 = 0.8;
pub const death_max_rotation: f32 = 180.0;
pub const calm_odds: i32 = 100;
pub const pounce_near: f32 = 2.0;
pub const pounce_far: f32 = 6.0;
pub const pounce_odds: i32 = 10;
pub const pounce_lift: f64 = 0.4;

pub const spec: Animal.Spec = .{
    .width = width,
    .height = height,
    .max_health = max_health,
    .move_speed = move_speed,
    .living_sound = assets.sounds.mob.spider,
    .hurt_sound = assets.sounds.mob.spider,
    .death_sound = assets.sounds.mob.spiderdeath,
};

fn init(position: math.Vec3) Spider {
    var self: Spider = .{ .animal = Animal.spawn(position, spec) };
    self.animal.on_death = dropFewItems;
    self.animal.action_state = updateActionState;
    self.animal.path_weight = Monster.blockPathWeight;
    self.animal.climbs_walls = true;
    self.animal.death_max_rotation = death_max_rotation;
    self.monster.attack = attackEntity;
    return self;
}

pub fn spawn(position: math.Vec3) Spider {
    return init(position);
}

pub fn deinit(self: *Spider, gpa: std.mem.Allocator) void {
    self.animal.deinit(gpa);
}

pub fn tick(
    self: *Spider,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    players: Animal.Players,
    rand: *world.JavaRandom,
) !void {
    self.monster.beginTick(&self.animal);
    try self.animal.tick(gpa, world_map, players, rand);
}

fn attackEntity(
    monster: *Monster,
    animal: *Animal,
    world_map: *const world.World,
    view: Animal.PlayerView,
    distance: f32,
    rand: *world.JavaRandom,
) void {
    if (Monster.brightnessOf(world_map, animal.*) > Monster.bright_light and
        rand.nextIntBound(calm_odds) == 0)
    {
        monster.target = null;
        return;
    }

    if (distance > pounce_near and distance < pounce_far and rand.nextIntBound(pounce_odds) == 0) {
        if (!animal.base.on_ground) return;

        const dx = view.position.x - animal.base.position.x;
        const dz = view.position.z - animal.base.position.z;
        const flat: f64 = math.util.sqrtF(dx * dx + dz * dz);

        animal.base.motion.x = dx / flat * 0.5 * 0.8 + animal.base.motion.x * 0.2;
        animal.base.motion.z = dz / flat * 0.5 * 0.8 + animal.base.motion.z * 0.2;
        animal.base.motion.y = pounce_lift;
        return;
    }

    Monster.strike(monster, animal, world_map, view, distance, rand);
}

fn updateActionState(
    animal: *Animal,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    players: Animal.Players,
    rand: *world.JavaRandom,
) anyerror!void {
    const self: *Spider = @fieldParentPtr("animal", animal);
    const hunts = Monster.brightnessOf(world_map, animal.*) < Monster.bright_light;
    try self.monster.updateActionState(animal, gpa, world_map, players, rand, hunts);
}

pub fn hurt(self: *Spider, amount: i32, source: ?Animal.Attacker, rand: *world.JavaRandom) bool {
    if (!self.animal.hurt(amount, source, rand)) return false;
    if (source) |from| {
        if (from.player != Animal.Entity.no_id) self.monster.target = from.player;
    }
    return true;
}

pub fn canSpawnHere(self: Spider, world_map: *const world.World, rand: *world.JavaRandom) bool {
    return Monster.canSpawnHere(self.animal, world_map, rand);
}

fn dropFewItems(animal: *Animal, rand: *world.JavaRandom) void {
    const self: *Spider = @fieldParentPtr("animal", animal);
    self.pending_drops = @intCast(rand.nextIntBound(3));
}

pub const Drops = struct {
    count: u8,

    pub fn stack(_: Drops) world.Stack {
        return .{ .id = .{ .item = .string }, .count = 1 };
    }
};

pub fn takeDrops(self: *Spider) ?Drops {
    if (self.pending_drops == 0) return null;
    const drops: Drops = .{ .count = self.pending_drops };
    self.pending_drops = 0;
    return drops;
}

pub fn eyeGlow(self: Spider, world_map: *const world.World) f32 {
    return (1.0 - Monster.brightnessOf(world_map, self.animal)) * 0.5;
}

pub fn toRecord(self: Spider) world.entity_nbt.Spider {
    return .{ .living = self.animal.toRecord() };
}

pub fn fromRecord(record: world.entity_nbt.Spider) Spider {
    var self = init(math.Vec3.init(
        record.living.position[0],
        record.living.position[1],
        record.living.position[2],
    ));
    self.animal.restore(record.living);
    return self;
}

pub const wire_id: u8 = 52;

pub const mob_type: Mob.Type = .{
    .name = world.entity_nbt.spider_id,
    .wire_id = wire_id,
    .monster = true,
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
    const self = try gpa.create(Spider);
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
    const self: *Spider = @fieldParentPtr("animal", animal);
    try self.tick(gpa, world_map, players, rand);
}

fn mobTakeDrops(animal: *Animal) ?Mob.Drops {
    const self: *Spider = @fieldParentPtr("animal", animal);
    const drops = self.takeDrops() orelse return null;
    return .{ .count = drops.count, .stack = drops.stack() };
}

fn mobHurt(animal: *Animal, amount: i32, source: ?Animal.Attacker, rand: *world.JavaRandom) bool {
    const self: *Spider = @fieldParentPtr("animal", animal);
    return self.hurt(amount, source, rand);
}

fn mobStore(animal: *Animal, gpa: std.mem.Allocator) anyerror!world.nbt.Tag {
    const self: *Spider = @fieldParentPtr("animal", animal);
    return world.entity_nbt.storeSpider(gpa, self.toRecord());
}

fn mobLoad(gpa: std.mem.Allocator, entity: world.nbt.Compound) anyerror!?*Animal {
    const record = world.entity_nbt.loadSpider(entity) orelse return null;
    const self = try gpa.create(Spider);
    self.* = Spider.fromRecord(record);
    return &self.animal;
}

fn mobDestroy(animal: *Animal, gpa: std.mem.Allocator) void {
    const self: *Spider = @fieldParentPtr("animal", animal);
    self.deinit(gpa);
    gpa.destroy(self);
}

fn mobAfterTick(animal: *Animal, context: Mob.Tick) anyerror!void {
    const self: *Spider = @fieldParentPtr("animal", animal);
    self.monster.deliverAttack(animal, context);
}

const wall_push: f64 = 0.5;

fn darkWorld(gpa: std.mem.Allocator) !world.World {
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

fn lightUp(w: *world.World) void {
    var chunk_x: i32 = -2;
    while (chunk_x <= 2) : (chunk_x += 1) {
        var chunk_z: i32 = -2;
        while (chunk_z <= 2) : (chunk_z += 1) {
            const chunk = w.getChunk(chunk_x, chunk_z).?;
            for (0..world.constants.chunk_width) |x| {
                for (0..world.constants.chunk_width) |z| {
                    var y: u32 = 1;
                    while (y <= 4) : (y += 1) chunk.setSkyLight(@intCast(x), y, @intCast(z), 15);
                }
            }
        }
    }
}

test "a spider is the wide, low shape EntitySpider sets itself to" {
    const self = Spider.spawn(math.Vec3.init(0, 0, 0));

    try std.testing.expectEqual(@as(f64, 1.4), self.animal.base.width);
    try std.testing.expectEqual(@as(f64, 0.9), self.animal.base.height);
    try std.testing.expectEqual(@as(i32, 20), self.animal.health);
    try std.testing.expectEqual(move_speed, self.animal.move_speed);
    try std.testing.expect(self.animal.climbs_walls);
}

test "a spider hunts in the dark and leaves the player alone in the light" {
    const gpa = std.testing.allocator;
    var w = try darkWorld(gpa);
    defer w.deinit();

    var rand = world.JavaRandom.init(4);
    var self = Spider.spawn(math.Vec3.init(8.5, 1, 8.5));
    defer self.deinit(gpa);
    self.animal.base.on_ground = true;

    const player = Animal.PlayerView{
        .id = 1,
        .position = math.Vec3.init(14.5, 1, 8.5),
        .eye_height = 1.62,
        .alive = true,
    };

    for (0..20) |_| try self.tick(gpa, &w, Animal.Players.one(&player), &rand);
    try std.testing.expectEqual(@as(?Animal.Entity.Id, 1), self.monster.target);

    var daylit = Spider.spawn(math.Vec3.init(8.5, 1, 8.5));
    defer daylit.deinit(gpa);
    daylit.animal.base.on_ground = true;
    lightUp(&w);

    for (0..40) |_| try daylit.tick(gpa, &w, Animal.Players.one(&player), &rand);
    try std.testing.expect(daylit.monster.target == null);
}

test "a spider sees the player through a wall, unlike every other monster" {
    const gpa = std.testing.allocator;
    var w = try darkWorld(gpa);
    defer w.deinit();

    const self = Spider.spawn(math.Vec3.init(8.5, 1, 8.5));
    const zombie: Monster = .{};

    const player = Animal.PlayerView{
        .id = 1,
        .position = math.Vec3.init(11.5, 1, 8.5),
        .eye_height = 1.62,
        .alive = true,
    };
    const players = Animal.Players.one(&player);

    var y: u32 = 1;
    while (y <= 4) : (y += 1) w.setBlock(10, @intCast(y), 8, .stone);

    try std.testing.expectEqual(
        @as(Animal.Entity.Id, 1),
        self.monster.findPlayerToAttack(self.animal, &w, players, true).?,
    );
    try std.testing.expect(zombie.findPlayerToAttack(self.animal, &w, players, true) == null);
}

test "a spider in the light sometimes gives up on the player it was chasing" {
    const gpa = std.testing.allocator;
    var w = try darkWorld(gpa);
    defer w.deinit();
    lightUp(&w);

    const player = Animal.PlayerView{
        .id = 1,
        .position = math.Vec3.init(9.5, 1, 8.5),
        .eye_height = 1.62,
        .alive = true,
    };

    var gave_up = false;
    for (0..400) |seed| {
        var rand = world.JavaRandom.init(@intCast(seed));
        var self = Spider.spawn(math.Vec3.init(8.5, 1, 8.5));
        defer self.deinit(gpa);
        self.monster.target = 1;

        self.monster.attack(&self.monster, &self.animal, &w, player, 1.0, &rand);
        if (self.monster.target == null) gave_up = true;
    }

    try std.testing.expect(gave_up);
}

test "a spider out of reach pounces rather than biting" {
    const gpa = std.testing.allocator;
    var w = try darkWorld(gpa);
    defer w.deinit();

    var self = Spider.spawn(math.Vec3.init(8.5, 1, 8.5));
    defer self.deinit(gpa);
    self.animal.base.on_ground = true;

    const player = Animal.PlayerView{
        .position = math.Vec3.init(12.5, 1, 8.5),
        .eye_height = 1.62,
        .alive = true,
    };

    var leapt = false;
    for (0..200) |seed| {
        var rand = world.JavaRandom.init(@intCast(seed));
        self.animal.base.motion = math.Vec3.init(0, 0, 0);
        self.monster.attack(&self.monster, &self.animal, &w, player, 4.0, &rand);
        if (self.animal.base.motion.y > 0.0) {
            leapt = true;
            try std.testing.expect(self.animal.base.motion.x > 0.0);
            try std.testing.expectApproxEqAbs(pounce_lift, self.animal.base.motion.y, 1.0e-9);
        }
    }

    try std.testing.expect(leapt);
    try std.testing.expect(!self.monster.pending_attack);
}

test "a spider standing on the player bites instead of pouncing" {
    const gpa = std.testing.allocator;
    var w = try darkWorld(gpa);
    defer w.deinit();

    var rand = world.JavaRandom.init(0);
    var self = Spider.spawn(math.Vec3.init(8.5, 1, 8.5));
    defer self.deinit(gpa);

    const player = Animal.PlayerView{
        .position = math.Vec3.init(9.0, 1, 8.5),
        .eye_height = 1.62,
        .alive = true,
    };

    self.monster.attack(&self.monster, &self.animal, &w, player, 1.0, &rand);

    try std.testing.expect(self.monster.pending_attack);
    try std.testing.expectEqual(Monster.attack_cooldown, self.monster.attack_time);
}

test "a spider walks up a wall it has run into" {
    const gpa = std.testing.allocator;
    var w = try darkWorld(gpa);
    defer w.deinit();

    var wall_y: u32 = 1;
    while (wall_y <= 4) : (wall_y += 1) {
        var wall_z: i32 = 6;
        while (wall_z <= 11) : (wall_z += 1) {
            w.setBlock(10, @intCast(wall_y), wall_z, .stone);
        }
    }

    var rand = world.JavaRandom.init(0);
    var self = Spider.spawn(math.Vec3.init(8.5, 1, 8.5));
    defer self.deinit(gpa);
    self.animal.base.on_ground = true;

    const started = self.animal.base.position.y;
    var climbed = false;
    for (0..40) |_| {
        self.animal.base.motion.x = wall_push;
        try self.tick(gpa, &w, .{}, &rand);
        if (self.animal.base.blocked_horizontally) {
            try std.testing.expect(self.animal.isOnLadder());
            climbed = true;
        }
    }

    try std.testing.expect(climbed);
    try std.testing.expect(self.animal.base.position.y > started);
}

test "a mob that does not climb is unaffected by running into a wall" {
    const gpa = std.testing.allocator;
    var w = try darkWorld(gpa);
    defer w.deinit();

    var animal = Animal.spawn(math.Vec3.init(8.5, 1, 8.5), .{ .width = 0.6, .height = 1.8 });
    defer animal.deinit(gpa);
    animal.base.blocked_horizontally = true;

    try std.testing.expect(!animal.isOnLadder());
}

test "a dying spider drops nought to two string" {
    var dropped_nothing = false;
    var dropped_something = false;

    for (0..20) |seed| {
        var rand = world.JavaRandom.init(@intCast(seed));
        var self = Spider.spawn(math.Vec3.init(8, 1, 8));

        _ = self.animal.hurt(max_health, null, &rand);
        try std.testing.expect(!self.animal.isAlive());

        if (self.takeDrops()) |drops| {
            try std.testing.expect(drops.count >= 1 and drops.count <= 2);
            try std.testing.expectEqual(world.Item.string, drops.stack().id.item);
            dropped_something = true;
        } else {
            dropped_nothing = true;
        }

        try std.testing.expect(self.takeDrops() == null);
    }

    try std.testing.expect(dropped_nothing);
    try std.testing.expect(dropped_something);
}

test "a spider rolls all the way over when it dies, not onto its side" {
    var self = Spider.spawn(math.Vec3.init(8, 1, 8));
    self.animal.death_time = Animal.death_ticks;

    try std.testing.expectApproxEqAbs(death_max_rotation, self.animal.deathTilt(1.0), 1.0e-6);

    const upright = Animal.spawn(math.Vec3.init(8, 1, 8), .{ .width = 0.6, .height = 1.8 });
    try std.testing.expectEqual(Animal.default_death_max_rotation, upright.death_max_rotation);
}

test "a struck spider turns on the player who struck it" {
    var rand = world.JavaRandom.init(0);
    var self = Spider.spawn(math.Vec3.init(8, 1, 8));

    try std.testing.expect(self.hurt(3, .{ .position = math.Vec3.init(6, 1, 8), .player = 11 }, &rand));
    try std.testing.expectEqual(@as(?Animal.Entity.Id, 11), self.monster.target);
}

test "the spider's eyes glow brightest in the dark" {
    const gpa = std.testing.allocator;
    var w = try darkWorld(gpa);
    defer w.deinit();

    const self = Spider.spawn(math.Vec3.init(8.5, 1, 8.5));
    const in_the_dark = self.eyeGlow(&w);

    lightUp(&w);
    const in_the_light = self.eyeGlow(&w);

    try std.testing.expect(in_the_dark > in_the_light);
    try std.testing.expect(in_the_dark <= 0.5 and in_the_light >= 0.0);
}

test "a spider keeps its wounds across a record round trip" {
    var self = Spider.spawn(math.Vec3.init(12.5, 64.0, -3.25));
    self.animal.health = 13;
    self.animal.yaw = 42.0;
    self.animal.base.on_ground = true;

    const restored = Spider.fromRecord(self.toRecord());

    try std.testing.expectEqual(@as(i32, 13), restored.animal.health);
    try std.testing.expectApproxEqAbs(@as(f32, 42.0), restored.animal.yaw, 1.0e-6);
    try std.testing.expect(restored.animal.climbs_walls);
    try std.testing.expectEqual(death_max_rotation, restored.animal.death_max_rotation);
    try std.testing.expectApproxEqAbs(@as(f64, -3.25), restored.animal.base.position.z, 1.0e-9);
}
