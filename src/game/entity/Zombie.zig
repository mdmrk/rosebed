const std = @import("std");

const assets = @import("assets");
const math = @import("math");
const world = @import("world");

const Mob = @import("../mob.zig");
const Animal = @import("Animal.zig");
const Monster = @import("Monster.zig");
pub const max_health: i32 = Monster.max_health;

const Zombie = @This();

animal: Animal,
monster: Monster = .{ .attack_strength = attack_strength },
ticks_existed: i32 = 0,
pending_drops: u8 = 0,

pub const width: f64 = 0.6;
pub const height: f64 = 1.8;
pub const move_speed: f32 = 0.5;
pub const attack_strength: i32 = 5;
pub const daylight_fire_ticks: i32 = 300;

pub const spec: Animal.Spec = .{
    .width = width,
    .height = height,
    .max_health = max_health,
    .move_speed = move_speed,
    .living_sound = assets.sounds.mob.zombie,
    .hurt_sound = assets.sounds.mob.zombiehurt,
    .death_sound = assets.sounds.mob.zombiedeath,
};

fn init(position: math.Vec3) Zombie {
    var self: Zombie = .{ .animal = Animal.spawn(position, spec) };
    self.animal.on_death = dropFewItems;
    self.animal.action_state = updateActionState;
    self.animal.path_weight = Monster.blockPathWeight;
    return self;
}

pub fn spawn(position: math.Vec3) Zombie {
    return init(position);
}

pub fn deinit(self: *Zombie, gpa: std.mem.Allocator) void {
    self.animal.deinit(gpa);
}

pub fn tick(
    self: *Zombie,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    players: Animal.Players,
    rand: *world.JavaRandom,
) !void {
    self.ticks_existed += 1;
    self.monster.beginTick(&self.animal);
    try self.animal.tick(gpa, world_map, players, rand);
}

pub fn burnInDaylight(animal: *Animal, world_map: *const world.World, rand: *world.JavaRandom) void {
    if (!world_map.isDaytime()) return;

    const brightness = Monster.brightnessOf(world_map, animal.*);
    if (brightness <= Monster.bright_light) return;

    const at = animal.base.position;
    if (!world_map.canBlockSeeTheSky(
        math.util.floorDouble(at.x),
        math.util.floorDouble(at.y),
        math.util.floorDouble(at.z),
    )) return;

    if (rand.nextFloat() * 30.0 >= (brightness - 0.4) * 2.0) return;
    animal.fire = daylight_fire_ticks;
}

fn updateActionState(
    animal: *Animal,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    players: Animal.Players,
    rand: *world.JavaRandom,
) anyerror!void {
    const self: *Zombie = @fieldParentPtr("animal", animal);
    burnInDaylight(animal, world_map, rand);
    try self.monster.updateActionState(animal, gpa, world_map, players, rand, true);
}

pub fn hurt(self: *Zombie, amount: i32, source: ?Animal.Attacker, rand: *world.JavaRandom) bool {
    if (!self.animal.hurt(amount, source, rand)) return false;
    if (source) |from| {
        if (from.player != Animal.Entity.no_id) self.monster.target = from.player;
    }
    return true;
}

pub fn canSpawnHere(self: Zombie, world_map: *const world.World, rand: *world.JavaRandom) bool {
    return Monster.canSpawnHere(self.animal, world_map, rand);
}

fn dropFewItems(animal: *Animal, rand: *world.JavaRandom) void {
    const self: *Zombie = @fieldParentPtr("animal", animal);
    self.pending_drops = @intCast(rand.nextIntBound(3));
}

pub const Drops = struct {
    count: u8,

    pub fn stack(_: Drops) world.Stack {
        return .{ .id = .{ .item = .feather }, .count = 1 };
    }
};

pub fn takeDrops(self: *Zombie) ?Drops {
    if (self.pending_drops == 0) return null;
    const drops: Drops = .{ .count = self.pending_drops };
    self.pending_drops = 0;
    return drops;
}

pub fn renderAge(self: Zombie, partial_ticks: f32) f32 {
    return @as(f32, @floatFromInt(self.ticks_existed)) + partial_ticks;
}

pub fn toRecord(self: Zombie) world.entity_nbt.Zombie {
    return .{ .living = self.animal.toRecord() };
}

pub fn fromRecord(record: world.entity_nbt.Zombie) Zombie {
    var self = init(math.Vec3.init(
        record.living.position[0],
        record.living.position[1],
        record.living.position[2],
    ));
    self.animal.restore(record.living);
    return self;
}

pub const wire_id: u8 = 54;

pub const mob_type: Mob.Type = .{
    .name = world.entity_nbt.zombie_id,
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
    const self = try gpa.create(Zombie);
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
    const self: *Zombie = @fieldParentPtr("animal", animal);
    try self.tick(gpa, world_map, players, rand);
}

fn mobTakeDrops(animal: *Animal) ?Mob.Drops {
    const self: *Zombie = @fieldParentPtr("animal", animal);
    const drops = self.takeDrops() orelse return null;
    return .{ .count = drops.count, .stack = drops.stack() };
}

fn mobHurt(animal: *Animal, amount: i32, source: ?Animal.Attacker, rand: *world.JavaRandom) bool {
    const self: *Zombie = @fieldParentPtr("animal", animal);
    return self.hurt(amount, source, rand);
}

fn mobStore(animal: *Animal, gpa: std.mem.Allocator) anyerror!world.nbt.Tag {
    const self: *Zombie = @fieldParentPtr("animal", animal);
    return world.entity_nbt.storeZombie(gpa, self.toRecord());
}

fn mobLoad(gpa: std.mem.Allocator, entity: world.nbt.Compound) anyerror!?*Animal {
    const record = world.entity_nbt.loadZombie(entity) orelse return null;
    const self = try gpa.create(Zombie);
    self.* = Zombie.fromRecord(record);
    return &self.animal;
}

fn mobDestroy(animal: *Animal, gpa: std.mem.Allocator) void {
    const self: *Zombie = @fieldParentPtr("animal", animal);
    self.deinit(gpa);
    gpa.destroy(self);
}

fn mobAfterTick(animal: *Animal, context: Mob.Tick) anyerror!void {
    const self: *Zombie = @fieldParentPtr("animal", animal);
    self.monster.deliverAttack(animal, context);
}

test "a zombie is the size, health and speed EntityZombie sets itself to" {
    const self = Zombie.spawn(math.Vec3.init(0, 0, 0));

    try std.testing.expectEqual(@as(f64, 0.6), self.animal.base.width);
    try std.testing.expectEqual(@as(f64, 1.8), self.animal.base.height);
    try std.testing.expectEqual(@as(i32, 20), self.animal.health);
    try std.testing.expectEqual(@as(f32, 0.5), self.animal.move_speed);
    try std.testing.expectEqual(@as(i32, 5), self.monster.attack_strength);
    try std.testing.expect(!self.animal.immune_to_fire);
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

test "a zombie needs no provocation to come after the player" {
    const gpa = std.testing.allocator;
    var w = try stoneFloor(gpa);
    defer w.deinit();

    var rand = world.JavaRandom.init(7);
    var self = Zombie.spawn(math.Vec3.init(8.5, 1, 8.5));
    defer self.deinit(gpa);
    self.animal.base.on_ground = true;

    const player = Animal.PlayerView{
        .id = 1,
        .position = math.Vec3.init(20.5, 1, 8.5),
        .eye_height = 1.62,
        .alive = true,
    };

    const started = self.animal.distanceSquaredTo(player.position);
    for (0..200) |_| try self.tick(gpa, &w, Animal.Players.one(&player), &rand);

    try std.testing.expectEqual(@as(?Animal.Entity.Id, 1), self.monster.target);
    try std.testing.expect(self.animal.distanceSquaredTo(player.position) < started);
}

test "a zombie under an open sky at noon catches fire" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();
    w.setTime(1000);
    w.skylight_subtracted = w.calculateSkylightSubtracted(1.0);
    try std.testing.expect(w.isDaytime());

    const chunk = w.getChunk(0, 0).?;
    for (0..world.Chunk.width) |x| {
        for (0..world.Chunk.width) |z| {
            var y: u32 = 1;
            while (y <= 4) : (y += 1) chunk.setSkyLight(@intCast(x), y, @intCast(z), 15);
        }
    }

    var rand = world.JavaRandom.init(1);
    var self = Zombie.spawn(math.Vec3.init(8.5, 1, 8.5));
    defer self.deinit(gpa);

    var lit = false;
    for (0..200) |_| {
        burnInDaylight(&self.animal, &w, &rand);
        if (self.animal.fire > 0) lit = true;
    }

    try std.testing.expect(lit);
}

test "a zombie under a roof never catches fire, however bright the day" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();
    w.setTime(1000);
    w.skylight_subtracted = w.calculateSkylightSubtracted(1.0);

    const chunk = w.getChunk(0, 0).?;
    for (0..world.Chunk.width) |x| {
        for (0..world.Chunk.width) |z| {
            chunk.setBlock(@intCast(x), 4, @intCast(z), .stone);
        }
    }
    try world.light.relightChunk(gpa, &w, 0, 0);
    for (0..world.Chunk.width) |x| {
        for (0..world.Chunk.width) |z| {
            var y: u32 = 1;
            while (y <= 3) : (y += 1) chunk.setBlockLight(@intCast(x), y, @intCast(z), 15);
        }
    }
    try std.testing.expect(!w.canBlockSeeTheSky(8, 1, 8));

    var rand = world.JavaRandom.init(1);
    var self = Zombie.spawn(math.Vec3.init(8.5, 1, 8.5));
    defer self.deinit(gpa);

    for (0..200) |_| {
        burnInDaylight(&self.animal, &w, &rand);
        try std.testing.expectEqual(@as(i32, 0), self.animal.fire);
    }
}

test "a zombie at night is left alone by the sun" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();
    w.setTime(18000);
    w.skylight_subtracted = w.calculateSkylightSubtracted(1.0);
    try std.testing.expect(!w.isDaytime());

    const chunk = w.getChunk(0, 0).?;
    for (0..world.Chunk.width) |x| {
        for (0..world.Chunk.width) |z| {
            var y: u32 = 1;
            while (y <= 4) : (y += 1) chunk.setSkyLight(@intCast(x), y, @intCast(z), 15);
        }
    }

    var rand = world.JavaRandom.init(1);
    var self = Zombie.spawn(math.Vec3.init(8.5, 1, 8.5));
    defer self.deinit(gpa);

    for (0..200) |_| {
        burnInDaylight(&self.animal, &w, &rand);
        try std.testing.expectEqual(@as(i32, 0), self.animal.fire);
    }
}

test "a dying zombie drops nought to two feathers" {
    var dropped_nothing = false;
    var dropped_something = false;

    for (0..20) |seed| {
        var rand = world.JavaRandom.init(@intCast(seed));
        var self = Zombie.spawn(math.Vec3.init(8, 1, 8));

        _ = self.animal.hurt(max_health, null, &rand);
        try std.testing.expect(!self.animal.isAlive());

        if (self.takeDrops()) |drops| {
            try std.testing.expect(drops.count >= 1 and drops.count <= 2);
            try std.testing.expectEqual(world.Item.feather, drops.stack().id.item);
            dropped_something = true;
        } else {
            dropped_nothing = true;
        }

        try std.testing.expect(self.takeDrops() == null);
    }

    try std.testing.expect(dropped_nothing);
    try std.testing.expect(dropped_something);
}

test "a struck zombie turns on the player who struck it" {
    var rand = world.JavaRandom.init(0);
    var self = Zombie.spawn(math.Vec3.init(8, 1, 8));

    try std.testing.expect(self.hurt(3, .{ .position = math.Vec3.init(6, 1, 8), .player = 11 }, &rand));
    try std.testing.expectEqual(@as(?Animal.Entity.Id, 11), self.monster.target);
}

test "a zombie keeps its wounds across a record round trip" {
    var self = Zombie.spawn(math.Vec3.init(12.5, 64.0, -3.25));
    self.animal.health = 14;
    self.animal.yaw = 42.0;
    self.animal.fire = 40;
    self.animal.base.on_ground = true;

    const restored = Zombie.fromRecord(self.toRecord());

    try std.testing.expectEqual(@as(i32, 14), restored.animal.health);
    try std.testing.expectApproxEqAbs(@as(f32, 42.0), restored.animal.yaw, 1.0e-6);
    try std.testing.expectEqual(@as(i32, 40), restored.animal.fire);
    try std.testing.expect(restored.animal.base.on_ground);
    try std.testing.expectApproxEqAbs(@as(f64, -3.25), restored.animal.base.position.z, 1.0e-9);
}
