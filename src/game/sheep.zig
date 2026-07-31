const std = @import("std");

const math = @import("math");
const world = @import("world");

const Animal = @import("animal.zig");
const Mob = @import("mob.zig");

const Sheep = @This();

animal: Animal,
fleece_color: u4 = white,
sheared: bool = false,
pending_wool: u8 = 0,

pub const width: f64 = 0.9;
pub const height: f64 = 1.3;
pub const max_health: i32 = 10;

pub const spec: Animal.Spec = .{ .width = width, .height = height, .max_health = max_health };

const white: u4 = 0;
const pink: u4 = 6;
const gray: u4 = 7;
const light_gray: u4 = 8;
const brown: u4 = 12;
const black: u4 = 15;

const min_wool: u8 = 1;
const wool_spread: i32 = 3;

fn init(position: math.Vec3) Sheep {
    return .{ .animal = Animal.spawn(position, spec) };
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
    player: ?Animal.PlayerView,
    rand: *world.JavaRandom,
) !void {
    try self.animal.tick(gpa, world_map, player, rand);
}

pub fn randomFleeceColor(rand: *world.JavaRandom) u4 {
    const roll = rand.nextIntBound(100);
    if (roll < 5) return black;
    if (roll < 10) return gray;
    if (roll < 15) return light_gray;
    if (roll < 18) return brown;
    return if (rand.nextIntBound(500) == 0) pink else white;
}

pub fn hurt(self: *Sheep, amount: i32, source: ?math.Vec3, rand: *world.JavaRandom) bool {
    if (source != null and !self.sheared) {
        self.sheared = true;
        self.pending_wool = min_wool + @as(u8, @intCast(rand.nextIntBound(wool_spread)));
    }
    return self.animal.hurt(amount, source, rand);
}

pub const Drops = struct {
    count: u8,
    color: u4,

    pub fn stack(self: Drops) world.Stack {
        return .{ .id = .{ .block = .wool }, .count = 1, .meta = self.color };
    }
};

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

test "a hit from an attacker shears the sheep and drops one to three wool of its colour" {
    var rand = world.JavaRandom.init(3);
    var sheep = Sheep.spawn(math.Vec3.init(8, 1, 8), &rand);
    sheep.fleece_color = brown;

    try std.testing.expect(sheep.hurt(2, math.Vec3.init(6, 1, 8), &rand));
    try std.testing.expect(sheep.sheared);

    const drops = sheep.takeDrops().?;
    try std.testing.expect(drops.count >= 1 and drops.count <= 3);
    try std.testing.expectEqual(brown, drops.color);
    try std.testing.expect(sheep.takeDrops() == null);
}

test "a sheared sheep has no more wool to give" {
    var rand = world.JavaRandom.init(3);
    var sheep = Sheep.spawn(math.Vec3.init(8, 1, 8), &rand);

    _ = sheep.hurt(1, math.Vec3.init(6, 1, 8), &rand);
    _ = sheep.takeDrops();

    sheep.animal.hurt_resistance = 0;
    _ = sheep.hurt(1, math.Vec3.init(6, 1, 8), &rand);

    try std.testing.expect(sheep.takeDrops() == null);
}

test "damage with no attacker behind it leaves the fleece on" {
    var rand = world.JavaRandom.init(3);
    var sheep = Sheep.spawn(math.Vec3.init(8, 1, 8), &rand);

    try std.testing.expect(sheep.hurt(4, null, &rand));

    try std.testing.expect(!sheep.sheared);
    try std.testing.expect(sheep.takeDrops() == null);
}

test "a sheep still takes the damage of the hit that shears it" {
    var rand = world.JavaRandom.init(3);
    var sheep = Sheep.spawn(math.Vec3.init(8, 1, 8), &rand);

    _ = sheep.hurt(3, math.Vec3.init(6, 1, 8), &rand);

    try std.testing.expectEqual(max_health - 3, sheep.animal.health);
    try std.testing.expect(sheep.animal.base.motion.x > 0.0);
}

test "a sheep killed outright drops no wool of its own" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var rand = world.JavaRandom.init(0);
    var sheep = Sheep.spawn(math.Vec3.init(8.5, 90, 8.5), &rand);
    defer sheep.deinit(gpa);

    for (0..200) |_| {
        try sheep.animal.tick(gpa, &w, null, &rand);
        if (!sheep.animal.isAlive()) break;
    }

    try std.testing.expect(!sheep.animal.isAlive());
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

pub const mob_type: Mob.Type = .{
    .name = world.entity_nbt.sheep_id,
    .spawn = mobSpawn,
    .tick = mobTick,
    .takeDrops = mobTakeDrops,
    .store = mobStore,
    .load = mobLoad,
    .destroy = mobDestroy,
    .hurt = mobHurt,
};

fn mobHurt(animal: *Animal, amount: i32, source: ?math.Vec3, rand: *world.JavaRandom) bool {
    const self: *Sheep = @fieldParentPtr("animal", animal);
    return self.hurt(amount, source, rand);
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
    view: Animal.PlayerView,
    rand: *world.JavaRandom,
) anyerror!void {
    const self: *Sheep = @fieldParentPtr("animal", animal);
    try self.tick(gpa, world_map, view, rand);
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
