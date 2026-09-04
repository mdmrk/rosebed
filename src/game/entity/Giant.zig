const std = @import("std");

const math = @import("math");
const world = @import("world");
const BlockPos = world.BlockPos;

const Mob = @import("../mob.zig");
const Animal = @import("Animal.zig");
const Monster = @import("Monster.zig");

const Giant = @This();

animal: Animal,
monster: Monster = .{ .attack_strength = attack_strength },
ticks_existed: i32 = 0,

pub const scale: f64 = 6.0;
pub const width: f64 = 0.6 * scale;
pub const height: f64 = 1.8 * scale;
pub const max_health: i32 = Monster.max_health * 10;
pub const move_speed: f32 = 0.5;
pub const attack_strength: i32 = 50;

pub const spec: Animal.Spec = .{
    .width = width,
    .height = height,
    .max_health = max_health,
    .move_speed = move_speed,
};

pub fn blockPathWeight(world_map: *const world.World, pos: BlockPos) f32 {
    return world.light.brightnessAt(world_map, pos, 0) - 0.5;
}

fn init(position: math.Vec3) Giant {
    var self: Giant = .{ .animal = Animal.spawn(position, spec) };
    self.animal.action_state = updateActionState;
    self.animal.path_weight = blockPathWeight;
    return self;
}

pub fn spawn(position: math.Vec3) Giant {
    return init(position);
}

pub fn deinit(self: *Giant, gpa: std.mem.Allocator) void {
    self.animal.deinit(gpa);
}

pub fn tick(
    self: *Giant,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    players: Animal.Players,
    rand: *world.JavaRandom,
) !void {
    self.ticks_existed += 1;
    self.monster.beginTick(&self.animal);
    try self.animal.tick(gpa, world_map, players, rand);
}

fn updateActionState(
    animal: *Animal,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    players: Animal.Players,
    rand: *world.JavaRandom,
) anyerror!void {
    const self: *Giant = @fieldParentPtr("animal", animal);
    try self.monster.updateActionState(animal, gpa, world_map, players, rand, true);
}

pub fn hurt(self: *Giant, world_map: *const world.World, amount: i32, source: ?Animal.Attacker, rand: *world.JavaRandom) bool {
    if (!self.animal.hurt(world_map, amount, source, rand)) return false;
    if (source) |from| {
        if (from.player != Animal.Entity.no_id) self.monster.target = from.player;
    }
    return true;
}

pub fn canSpawnHere(self: Giant, world_map: *const world.World, rand: *world.JavaRandom) bool {
    return Monster.canSpawnHere(self.animal, world_map, rand);
}

pub fn renderAge(self: Giant, partial_ticks: f32) f32 {
    return @as(f32, @floatFromInt(self.ticks_existed)) + partial_ticks;
}

pub fn toRecord(self: Giant) world.entity_nbt.Giant {
    return .{ .living = self.animal.toRecord() };
}

pub fn fromRecord(record: world.entity_nbt.Giant) Giant {
    var self = init(record.living.position);
    self.animal.restore(record.living);
    return self;
}

pub const wire_id: u8 = 53;

pub const mob_type: Mob.Type = .{
    .name = world.entity_nbt.giant_id,
    .wire_id = wire_id,
    .monster = true,
    .vanishes_on_peaceful = true,
    .spawn = mobSpawn,
    .tick = mobTick,
    .takeDrops = mobTakeDrops,
    .store = mobStore,
    .load = mobLoad,
    .destroy = mobDestroy,
    .canSpawnHere = mobCanSpawnHere,
    .hurt = mobHurt,
    .afterTick = mobAfterTick,
};

fn mobSpawn(gpa: std.mem.Allocator, position: math.Vec3, _: *world.JavaRandom) anyerror!*Animal {
    const self = try gpa.create(Giant);
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
    const self: *Giant = @fieldParentPtr("animal", animal);
    try self.tick(gpa, world_map, players, rand);
}

fn mobTakeDrops(_: *Animal) ?Mob.Drops {
    return null;
}

fn mobHurt(animal: *Animal, world_map: *const world.World, amount: i32, source: ?Animal.Attacker, rand: *world.JavaRandom) bool {
    const self: *Giant = @fieldParentPtr("animal", animal);
    return self.hurt(world_map, amount, source, rand);
}

fn mobStore(animal: *Animal, gpa: std.mem.Allocator) anyerror!world.nbt.Tag {
    const self: *Giant = @fieldParentPtr("animal", animal);
    return world.entity_nbt.storeGiant(gpa, self.toRecord());
}

fn mobLoad(gpa: std.mem.Allocator, entity: world.nbt.Compound) anyerror!?*Animal {
    const record = world.entity_nbt.loadGiant(entity) orelse return null;
    const self = try gpa.create(Giant);
    self.* = Giant.fromRecord(record);
    return &self.animal;
}

fn mobCanSpawnHere(animal: *const Animal, world_map: *const world.World, _: i64, rand: *world.JavaRandom) bool {
    const self: *const Giant = @fieldParentPtr("animal", animal);
    return self.canSpawnHere(world_map, rand);
}
fn mobDestroy(animal: *Animal, gpa: std.mem.Allocator) void {
    const self: *Giant = @fieldParentPtr("animal", animal);
    self.deinit(gpa);
    gpa.destroy(self);
}

fn mobAfterTick(animal: *Animal, context: Mob.Tick) anyerror!void {
    const self: *Giant = @fieldParentPtr("animal", animal);
    self.monster.deliverAttack(animal, context);
}

test "a giant is six zombies wide and tall, with ten zombies' health" {
    const self = Giant.spawn(math.Vec3.init(0, 0, 0));

    try std.testing.expectApproxEqAbs(@as(f64, 3.6), self.animal.base.width, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 10.8), self.animal.base.height, 1.0e-9);
    try std.testing.expectEqual(@as(i32, 200), self.animal.health);
    try std.testing.expectEqual(@as(f32, 0.5), self.animal.move_speed);
    try std.testing.expectEqual(@as(i32, 50), self.monster.attack_strength);
    try std.testing.expect(!self.animal.immune_to_fire);
}

test "a giant seeks the light EntityMob shuns" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    const chunk = w.getChunk(0, 0).?;
    for (0..world.Chunk.width) |z| chunk.setBlockLight(8, 1, @intCast(z), @intCast(z));

    const dark: BlockPos = .init(8, 1, 0);
    const bright: BlockPos = .init(8, 1, 15);

    try std.testing.expect(blockPathWeight(&w, bright) > blockPathWeight(&w, dark));
    try std.testing.expect(Monster.blockPathWeight(&w, bright) < Monster.blockPathWeight(&w, dark));
}

test "a giant carries its own path weight rather than EntityMob's" {
    const self = Giant.spawn(math.Vec3.init(0, 0, 0));
    try std.testing.expect(self.animal.path_weight == &blockPathWeight);
}

test "a giant leaves no body behind" {
    var w = world.World.init(std.testing.allocator);
    defer w.deinit();

    for (0..20) |seed| {
        var rand = world.JavaRandom.init(@intCast(seed));
        var self = Giant.spawn(math.Vec3.init(8, 1, 8));

        _ = self.animal.hurt(&w, max_health, null, &rand);
        try std.testing.expect(!self.animal.isAlive());
        try std.testing.expect(mobTakeDrops(&self.animal) == null);
    }
}

test "a struck giant turns on the player who struck it" {
    var w = world.World.init(std.testing.allocator);
    defer w.deinit();
    var rand = world.JavaRandom.init(0);
    var self = Giant.spawn(math.Vec3.init(8, 1, 8));

    try std.testing.expect(self.hurt(&w, 3, .{ .position = math.Vec3.init(6, 1, 8), .player = 11 }, &rand));
    try std.testing.expectEqual(@as(?Animal.Entity.Id, 11), self.monster.target);
}

test "a giant keeps its wounds across a record round trip" {
    var self = Giant.spawn(math.Vec3.init(12.5, 64.0, -3.25));
    self.animal.health = 137;
    self.animal.yaw = 42.0;
    self.animal.fire = 40;
    self.animal.base.on_ground = true;

    const restored = Giant.fromRecord(self.toRecord());

    try std.testing.expectEqual(@as(i32, 137), restored.animal.health);
    try std.testing.expectApproxEqAbs(@as(f32, 42.0), restored.animal.yaw, 1.0e-6);
    try std.testing.expectEqual(@as(i32, 40), restored.animal.fire);
    try std.testing.expect(restored.animal.base.on_ground);
    try std.testing.expectApproxEqAbs(@as(f64, -3.25), restored.animal.base.position.z, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 3.6), restored.animal.base.width, 1.0e-9);
}
