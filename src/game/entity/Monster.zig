const std = @import("std");

const math = @import("math");
const world = @import("world");

const Mob = @import("../mob.zig");
const physics = @import("../physics.zig");
const raycast = @import("../raycast.zig");
const Animal = @import("Animal.zig");

const Monster = @This();

attack_strength: i32 = 2,
attack_time: i32 = 0,
target: ?Animal.Entity.Id = null,
pending_attack: bool = false,
has_attacked: bool = false,
needs_line_of_sight: bool = true,
attack: *const fn (*Monster, *Animal, *const world.World, Animal.PlayerView, f32, *world.JavaRandom) void = strike,
attack_blocked: *const fn (*Monster, *Animal, *const world.World, Animal.PlayerView, f32, *world.JavaRandom) void = ignoreBlocked,

pub const max_health: i32 = 20;
pub const attack_cooldown: i32 = 20;
pub const attack_reach: f32 = 2.0;
pub const sight_range: f64 = 16.0;
pub const bright_light: f32 = 0.5;
pub const sky_spawn_roll: i32 = 32;
pub const block_spawn_roll: i32 = 8;

pub fn blockPathWeight(world_map: *const world.World, x: i32, y: i32, z: i32) f32 {
    return 0.5 - world.light.brightnessAt(world_map, x, y, z, 0);
}

pub fn brightnessOf(world_map: *const world.World, animal: Animal) f32 {
    const sample = animal.base.lightSamplePosition();
    return world.light.brightnessAt(world_map, sample[0], sample[1], sample[2], 0);
}

pub fn canSee(animal: Animal, world_map: *const world.World, view: Animal.PlayerView) bool {
    const eye = math.Vec3.init(
        animal.base.position.x,
        animal.base.position.y + animal.eyeHeight(),
        animal.base.position.z,
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

pub fn canSpawnHere(animal: Animal, world_map: *const world.World, rand: *world.JavaRandom) bool {
    const x = math.util.floorDouble(animal.base.position.x);
    const y = math.util.floorDouble(animal.base.boundingBox().min_y);
    const z = math.util.floorDouble(animal.base.position.z);

    if (@as(i32, world_map.getSkyLight(x, y, z)) > rand.nextIntBound(sky_spawn_roll)) return false;
    if (@as(i32, world.light.levelAt(world_map, x, y, z)) > rand.nextIntBound(block_spawn_roll)) return false;
    if (blockPathWeight(world_map, x, y, z) < 0.0) return false;

    const box = animal.base.boundingBox();
    return !physics.isBoxObstructed(world_map, box) and !physics.isAnyLiquid(world_map, box);
}

fn targetView(self: Monster, players: Animal.Players) ?Animal.PlayerView {
    return players.byId(self.target orelse return null);
}

pub fn findPlayerToAttack(
    self: Monster,
    animal: Animal,
    world_map: *const world.World,
    players: Animal.Players,
    hostile: bool,
) ?Animal.Entity.Id {
    if (!hostile) return null;
    const view = players.closestTo(animal.base.position, sight_range) orelse return null;
    if (self.needs_line_of_sight and !canSee(animal, world_map, view)) return null;
    return view.id;
}

pub fn strike(
    self: *Monster,
    animal: *Animal,
    _: *const world.World,
    view: Animal.PlayerView,
    distance: f32,
    _: *world.JavaRandom,
) void {
    if (self.attack_time > 0 or distance >= attack_reach) return;

    const box = animal.base.boundingBox();
    if (view.position.y + view.height <= box.min_y or view.position.y >= box.max_y) return;

    self.attack_time = attack_cooldown;
    self.pending_attack = true;
}

fn ignoreBlocked(_: *Monster, _: *Animal, _: *const world.World, _: Animal.PlayerView, _: f32, _: *world.JavaRandom) void {}

pub fn beginTick(self: *Monster, _: *Animal) void {
    if (self.attack_time > 0) self.attack_time -= 1;
}

fn pathToTarget(
    self: *Monster,
    animal: *Animal,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    players: Animal.Players,
) !void {
    const view = self.targetView(players) orelse return;
    try animal.pathTowards(gpa, world_map, view.position, Animal.chase_path_range);
}

pub fn updateActionState(
    self: *Monster,
    animal: *Animal,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    players: Animal.Players,
    rand: *world.JavaRandom,
    hostile: bool,
) !void {
    if (brightnessOf(world_map, animal.*) > bright_light) animal.entity_age += 2;

    self.has_attacked = false;

    if (self.target == null) {
        self.target = self.findPlayerToAttack(animal.*, world_map, players, hostile);
        if (self.target != null) try self.pathToTarget(animal, gpa, world_map, players);
    } else if (self.targetView(players)) |view| {
        if (!view.alive) {
            self.target = null;
        } else {
            const distance: f32 = @floatCast(@sqrt(animal.distanceSquaredTo(view.position)));
            if (canSee(animal.*, world_map, view)) {
                self.attack(self, animal, world_map, view, distance, rand);
            } else {
                self.attack_blocked(self, animal, world_map, view, distance, rand);
            }
        }
    }

    if (self.has_attacked or self.target == null or (animal.path != null and rand.nextIntBound(20) != 0)) {
        if (!self.has_attacked and
            ((animal.path == null and rand.nextIntBound(80) == 0) or rand.nextIntBound(80) == 0))
        {
            try animal.findWanderPath(gpa, world_map, rand);
        }
    } else {
        try self.pathToTarget(animal, gpa, world_map, players);
    }

    animal.pitch = 0;

    if (animal.path != null and rand.nextIntBound(100) != 0) {
        const chase: ?Animal.Chase = if (self.targetView(players)) |view| .{
            .position = view.position,
            .eye_height = view.eye_height,
            .ceased = self.has_attacked,
        } else null;
        animal.followPath(gpa, rand, chase);
    } else {
        animal.idleActionState(players, rand);
        animal.clearPath(gpa);
    }
}

pub fn deliverAttack(self: *Monster, animal: *Animal, context: Mob.Tick) void {
    if (!self.pending_attack) return;
    self.pending_attack = false;

    const player = context.playerById(self.target orelse return) orelse return;
    if (player.health <= 0) return;
    player.hurtFrom(context.world_map, self.attack_strength, animal.base.position);
}

test "a monster reaches only a player standing beside it, and then waits out its cooldown" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var rand = world.JavaRandom.init(0);
    var animal = Animal.spawn(math.Vec3.init(8.5, 1, 8.5), .{ .width = 0.6, .height = 1.8 });
    var self: Monster = .{ .attack_strength = 5 };

    const beside = Animal.PlayerView{
        .position = math.Vec3.init(9.5, 1, 8.5),
        .eye_height = 1.62,
        .alive = true,
    };

    self.attack(&self, &animal, &w, beside, 1.0, &rand);
    try std.testing.expect(self.pending_attack);
    try std.testing.expectEqual(attack_cooldown, self.attack_time);

    self.pending_attack = false;
    self.attack(&self, &animal, &w, beside, 1.0, &rand);
    try std.testing.expect(!self.pending_attack);

    self.attack_time = 0;
    self.attack(&self, &animal, &w, beside, attack_reach, &rand);
    try std.testing.expect(!self.pending_attack);

    const overhead = Animal.PlayerView{
        .position = math.Vec3.init(8.5, 4, 8.5),
        .eye_height = 1.62,
        .alive = true,
    };
    self.attack(&self, &animal, &w, overhead, 1.0, &rand);
    try std.testing.expect(!self.pending_attack);

    animal.base.position.y = 1;
}

test "a monster that is not hostile looks for nobody to attack" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    const animal = Animal.spawn(math.Vec3.init(8.5, 1, 8.5), .{ .width = 0.6, .height = 1.8 });
    const self: Monster = .{};

    const player = Animal.PlayerView{
        .id = 3,
        .position = math.Vec3.init(12.5, 1, 8.5),
        .eye_height = 1.62,
        .alive = true,
    };
    const players = Animal.Players.one(&player);

    try std.testing.expect(self.findPlayerToAttack(animal, &w, players, false) == null);
    try std.testing.expectEqual(@as(Animal.Entity.Id, 3), self.findPlayerToAttack(animal, &w, players, true).?);
}

test "a monster loses sight of a player it cannot reach through a wall" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    const animal = Animal.spawn(math.Vec3.init(8.5, 1, 8.5), .{ .width = 0.6, .height = 1.8 });
    const self: Monster = .{};

    const player = Animal.PlayerView{
        .id = 3,
        .position = math.Vec3.init(11.5, 1, 8.5),
        .eye_height = 1.62,
        .alive = true,
    };

    try std.testing.expect(canSee(animal, &w, player));

    var y: u32 = 1;
    while (y <= 4) : (y += 1) w.setBlock(10, @intCast(y), 8, .stone);
    try std.testing.expect(!canSee(animal, &w, player));
    try std.testing.expect(self.findPlayerToAttack(animal, &w, Animal.Players.one(&player), true) == null);

    var blind = self;
    blind.needs_line_of_sight = false;
    try std.testing.expectEqual(
        @as(Animal.Entity.Id, 3),
        blind.findPlayerToAttack(animal, &w, Animal.Players.one(&player), true).?,
    );
}

test "a monster prefers the dark to wander into" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    w.getChunk(0, 0).?.setSkyLight(4, 1, 8, 15);

    try std.testing.expect(blockPathWeight(&w, 8, 1, 8) > blockPathWeight(&w, 4, 1, 8));
    try std.testing.expect(blockPathWeight(&w, 4, 1, 8) < 0.0);
}

test "a monster only spawns in the dark, in a clear dry space" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var rand = world.JavaRandom.init(4);
    const animal = Animal.spawn(math.Vec3.init(8.5, 1, 8.5), .{ .width = 0.6, .height = 1.8 });

    var dark_spawns: u32 = 0;
    for (0..100) |_| {
        if (canSpawnHere(animal, &w, &rand)) dark_spawns += 1;
    }
    try std.testing.expect(dark_spawns > 0);

    w.getChunk(0, 0).?.setSkyLight(8, 1, 8, 15);
    for (0..100) |_| try std.testing.expect(!canSpawnHere(animal, &w, &rand));

    w.getChunk(0, 0).?.setSkyLight(8, 1, 8, 0);
    w.setBlock(8, 2, 8, .stone);
    for (0..100) |_| try std.testing.expect(!canSpawnHere(animal, &w, &rand));
}
