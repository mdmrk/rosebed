const std = @import("std");

const assets = @import("assets");
const math = @import("math");
const world = @import("world");

const Mob = @import("../mob.zig");
const Animal = @import("Animal.zig");

const Sheep = @This();

animal: Animal,
fleece_color: u4 = white,
sheared: bool = false,
pending_wool: u8 = 0,

pub const width: f64 = 0.9;
pub const height: f64 = 1.3;
pub const max_health: i32 = 10;

pub const spec: Animal.Spec = .{
    .width = width,
    .height = height,
    .max_health = max_health,
    .living_sound = assets.sounds.mob.sheep,
    .hurt_sound = assets.sounds.mob.sheep,
    .death_sound = assets.sounds.mob.sheep,
    .talk_interval = Animal.passive_talk_interval,
};

const white: u4 = 0;
const pink: u4 = 6;
const gray: u4 = 7;
const light_gray: u4 = 8;
const brown: u4 = 12;
const black: u4 = 15;

const sheared_min_wool: u8 = 2;
const wool_spread: i32 = 3;

pub fn init(position: math.Vec3) Sheep {
    var sheep: Sheep = .{ .animal = Animal.spawn(position, spec) };
    sheep.animal.on_death = dropFewItems;
    return sheep;
}

pub fn spawn(position: math.Vec3, rand: *world.JavaRandom) Sheep {
    var sheep = init(position);
    sheep.fleece_color = randomFleeceColor(rand);
    return sheep;
}

pub fn deinit(self: *Sheep, gpa: std.mem.Allocator) void {
    self.animal.deinit(gpa);
}

pub fn tick(
    self: *Sheep,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    players: Animal.Players,
    rand: *world.JavaRandom,
) !void {
    try self.animal.tick(gpa, world_map, players, rand);
}

pub fn randomFleeceColor(rand: *world.JavaRandom) u4 {
    const roll = rand.nextIntBound(100);
    if (roll < 5) return black;
    if (roll < 10) return gray;
    if (roll < 15) return light_gray;
    if (roll < 18) return brown;
    return if (rand.nextIntBound(500) == 0) pink else white;
}

fn dropFewItems(animal: *Animal, _: *world.JavaRandom) void {
    const self: *Sheep = @fieldParentPtr("animal", animal);
    if (!self.sheared) self.pending_wool = 1;
}

pub const Drops = struct {
    count: u8,
    color: u4,

    pub fn stack(self: Drops) world.Stack {
        return .{ .id = .{ .block = .wool }, .count = 1, .meta = self.color };
    }
};

pub fn shear(self: *Sheep, rand: *world.JavaRandom) ?Drops {
    if (self.sheared) return null;
    self.sheared = true;
    return .{
        .count = sheared_min_wool + @as(u8, @intCast(rand.nextIntBound(wool_spread))),
        .color = self.fleece_color,
    };
}

pub fn takeDrops(self: *Sheep) ?Drops {
    if (self.pending_wool == 0) return null;
    const drops: Drops = .{ .count = self.pending_wool, .color = self.fleece_color };
    self.pending_wool = 0;
    return drops;
}

pub fn toRecord(self: Sheep) world.entity_nbt.Sheep {
    return .{ .living = self.animal.toRecord(), .sheared = self.sheared, .color = self.fleece_color };
}

pub fn fromRecord(record: world.entity_nbt.Sheep) Sheep {
    var sheep = init(math.Vec3.init(
        record.living.position[0],
        record.living.position[1],
        record.living.position[2],
    ));
    sheep.animal.restore(record.living);
    sheep.sheared = record.sheared;
    sheep.fleece_color = record.color;
    return sheep;
}

test "a sheep is the size EntitySheep sets itself to" {
    var rand = world.JavaRandom.init(0);
    const sheep = Sheep.spawn(math.Vec3.init(0, 0, 0), &rand);

    try std.testing.expectEqual(@as(f64, 0.9), sheep.animal.base.width);
    try std.testing.expectEqual(@as(f64, 1.3), sheep.animal.base.height);
    try std.testing.expectEqual(max_health, sheep.animal.health);
}

test "hitting a sheep neither shears it nor knocks any wool loose" {
    var w = world.World.init(std.testing.allocator);
    defer w.deinit();
    var rand = world.JavaRandom.init(3);
    var sheep = Sheep.spawn(math.Vec3.init(8, 1, 8), &rand);

    try std.testing.expect(sheep.animal.hurt(&w, 2, .{ .position = math.Vec3.init(6, 1, 8) }, &rand));

    try std.testing.expect(!sheep.sheared);
    try std.testing.expect(sheep.takeDrops() == null);
}

test "shearing a sheep yields two to four wool of its colour, and only once" {
    var rand = world.JavaRandom.init(7);
    var sheep = Sheep.spawn(math.Vec3.init(8, 1, 8), &rand);
    sheep.fleece_color = pink;

    const drops = sheep.shear(&rand).?;
    try std.testing.expect(drops.count >= 2 and drops.count <= 4);
    try std.testing.expectEqual(pink, drops.color);
    try std.testing.expectEqual(world.Id{ .block = .wool }, drops.stack().id);
    try std.testing.expectEqual(@as(u16, pink), drops.stack().meta);
    try std.testing.expect(sheep.sheared);

    try std.testing.expect(sheep.shear(&rand) == null);
}

test "a sheep shorn before it died leaves nothing behind" {
    var w = world.World.init(std.testing.allocator);
    defer w.deinit();
    var rand = world.JavaRandom.init(7);
    var sheep = Sheep.spawn(math.Vec3.init(8, 1, 8), &rand);

    _ = sheep.shear(&rand).?;
    try std.testing.expect(sheep.takeDrops() == null);

    _ = sheep.animal.hurt(&w, max_health, null, &rand);
    try std.testing.expect(!sheep.animal.isAlive());
    try std.testing.expect(sheep.takeDrops() == null);
}

test "a sheep takes the damage and the knockback of a hit" {
    var w = world.World.init(std.testing.allocator);
    defer w.deinit();
    var rand = world.JavaRandom.init(3);
    var sheep = Sheep.spawn(math.Vec3.init(8, 1, 8), &rand);

    _ = sheep.animal.hurt(&w, 3, .{ .position = math.Vec3.init(6, 1, 8) }, &rand);

    try std.testing.expectEqual(max_health - 3, sheep.animal.health);
    try std.testing.expect(sheep.animal.base.motion.x > 0.0);
}

test "a sheep that dies with its fleece on drops a single wool of its colour" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var rand = world.JavaRandom.init(0);
    var sheep = Sheep.spawn(math.Vec3.init(8.5, 90, 8.5), &rand);
    defer sheep.deinit(gpa);
    sheep.fleece_color = black;

    for (0..200) |_| {
        try sheep.animal.tick(gpa, &w, .{}, &rand);
        if (!sheep.animal.isAlive()) break;
    }

    try std.testing.expect(!sheep.animal.isAlive());
    const drops = sheep.takeDrops().?;
    try std.testing.expectEqual(@as(u8, 1), drops.count);
    try std.testing.expectEqual(black, drops.color);
    try std.testing.expect(sheep.takeDrops() == null);
}

test "fleece colours come out at the rates EntitySheep rolls them" {
    var rand = world.JavaRandom.init(11);
    var counts = [_]u32{0} ** 16;
    const rolls = 20000;
    for (0..rolls) |_| counts[randomFleeceColor(&rand)] += 1;

    try std.testing.expect(counts[white] > rolls * 80 / 100);
    for ([_]u4{ black, gray, light_gray }) |color| {
        try std.testing.expect(counts[color] > rolls * 3 / 100 and counts[color] < rolls * 7 / 100);
    }
    try std.testing.expect(counts[brown] > rolls * 1 / 100 and counts[brown] < rolls * 5 / 100);
    try std.testing.expect(counts[pink] > 0 and counts[pink] < rolls / 100);

    var total: u32 = 0;
    for (counts) |count| total += count;
    try std.testing.expectEqual(@as(u32, rolls), total);
    try std.testing.expectEqual(@as(u32, 0), counts[1] + counts[2] + counts[3] + counts[4] + counts[5]);
}

test "a sheep keeps its colour and its shearing across a record round trip" {
    var rand = world.JavaRandom.init(0);
    var sheep = Sheep.spawn(math.Vec3.init(12.5, 64.0, -3.25), &rand);
    sheep.fleece_color = black;
    sheep.sheared = true;
    sheep.animal.health = 4;
    sheep.animal.yaw = 42.0;

    const restored = Sheep.fromRecord(sheep.toRecord());

    try std.testing.expectEqual(black, restored.fleece_color);
    try std.testing.expect(restored.sheared);
    try std.testing.expectEqual(@as(i32, 4), restored.animal.health);
    try std.testing.expectApproxEqAbs(@as(f32, 42.0), restored.animal.yaw, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f64, -3.25), restored.animal.base.position.z, 1.0e-9);
}

pub const wire_id: u8 = 91;
pub const watched_fleece: u5 = 16;
const sheared_bit: i8 = 16;

pub const mob_type: Mob.Type = .{
    .name = world.entity_nbt.sheep_id,
    .wire_id = wire_id,
    .spawn = mobSpawn,
    .tick = mobTick,
    .takeDrops = mobTakeDrops,
    .store = mobStore,
    .load = mobLoad,
    .destroy = mobDestroy,
    .watch = mobWatch,
    .adopt = mobAdopt,
};

fn mobWatch(animal: *const Animal, out: *Mob.Watched) void {
    const self: *const Sheep = @fieldParentPtr("animal", animal);
    const fleece: i8 = @intCast(self.fleece_color);
    out.add(watched_fleece, .{ .byte = if (self.sheared) fleece | sheared_bit else fleece });
}

fn mobAdopt(animal: *Animal, metadata: Mob.Metadata) void {
    const self: *Sheep = @fieldParentPtr("animal", animal);
    const fleece = metadata.byteAt(watched_fleece) orelse return;
    self.fleece_color = @intCast(fleece & 15);
    self.sheared = fleece & sheared_bit != 0;
}

fn mobSpawn(gpa: std.mem.Allocator, position: math.Vec3, rand: *world.JavaRandom) anyerror!*Animal {
    const self = try gpa.create(Sheep);
    self.* = spawn(position, rand);
    return &self.animal;
}

fn mobTick(
    animal: *Animal,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    players: Animal.Players,
    rand: *world.JavaRandom,
) anyerror!void {
    const self: *Sheep = @fieldParentPtr("animal", animal);
    try self.tick(gpa, world_map, players, rand);
}

fn mobTakeDrops(animal: *Animal) ?Mob.Drops {
    const self: *Sheep = @fieldParentPtr("animal", animal);
    const drops = self.takeDrops() orelse return null;
    return .{ .count = drops.count, .stack = drops.stack() };
}

fn mobStore(animal: *Animal, gpa: std.mem.Allocator) anyerror!world.nbt.Tag {
    const self: *Sheep = @fieldParentPtr("animal", animal);
    return world.entity_nbt.storeSheep(gpa, self.toRecord());
}

fn mobLoad(gpa: std.mem.Allocator, entity: world.nbt.Compound) anyerror!?*Animal {
    const record = world.entity_nbt.loadSheep(entity) orelse return null;
    const self = try gpa.create(Sheep);
    self.* = Sheep.fromRecord(record);
    return &self.animal;
}

fn mobDestroy(animal: *Animal, gpa: std.mem.Allocator) void {
    const self: *Sheep = @fieldParentPtr("animal", animal);
    self.deinit(gpa);
    gpa.destroy(self);
}

test "a sheep's fleece colour and shearing share one watched byte" {
    var rand: world.JavaRandom = .init(3);
    var shorn = spawn(math.Vec3.init(0, 0, 0), &rand);
    shorn.fleece_color = brown;
    shorn.sheared = true;

    var watched: Mob.Watched = .{};
    Mob.watch(Mob.sheep, &shorn.animal, &watched);
    try std.testing.expectEqual(@as(i8, brown) | sheared_bit, watched.view().byteAt(watched_fleece).?);

    var woolly = spawn(math.Vec3.init(0, 0, 0), &rand);
    Mob.adopt(Mob.sheep, &woolly.animal, watched.view());

    try std.testing.expectEqual(brown, woolly.fleece_color);
    try std.testing.expect(woolly.sheared);
}
