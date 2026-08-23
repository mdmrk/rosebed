const std = @import("std");

const assets = @import("assets");
const math = @import("math");
const world = @import("world");

const Animal = @import("animal.zig");
const Mob = @import("mob.zig");

const Cow = @This();

animal: Animal,
pending_drops: u8 = 0,

pub const width: f64 = 0.9;
pub const height: f64 = 1.3;
pub const max_health: i32 = 10;

pub const spec: Animal.Spec = .{
    .width = width,
    .height = height,
    .max_health = max_health,
    .living_sound = assets.sounds.mob.cow,
    .hurt_sound = assets.sounds.mob.cowhurt,
    .death_sound = assets.sounds.mob.cowhurt,
    .sound_volume = 0.4,
    .talk_interval = Animal.passive_talk_interval,
};

pub fn interact(held: ?world.Item) ?world.Item {
    const item = held orelse return null;
    return if (item == .bucket) .bucket_milk else null;
}

pub fn spawn(position: math.Vec3) Cow {
    var cow: Cow = .{ .animal = Animal.spawn(position, spec) };
    cow.animal.on_death = dropFewItems;
    return cow;
}

pub fn deinit(self: *Cow, gpa: std.mem.Allocator) void {
    self.animal.deinit(gpa);
}

pub fn tick(
    self: *Cow,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    players: Animal.Players,
    rand: *world.JavaRandom,
) !void {
    try self.animal.tick(gpa, world_map, players, rand);
}

fn dropFewItems(animal: *Animal, rand: *world.JavaRandom) void {
    const self: *Cow = @fieldParentPtr("animal", animal);
    self.pending_drops = @intCast(rand.nextIntBound(3));
}

pub const Drops = struct {
    count: u8,

    pub fn stack(_: Drops) world.Stack {
        return .{ .id = .{ .item = .leather }, .count = 1 };
    }
};

pub fn takeDrops(self: *Cow) ?Drops {
    if (self.pending_drops == 0) return null;
    const drops: Drops = .{ .count = self.pending_drops };
    self.pending_drops = 0;
    return drops;
}

pub fn toRecord(self: Cow) world.entity_nbt.Cow {
    return .{ .living = self.animal.toRecord() };
}

pub fn fromRecord(record: world.entity_nbt.Cow) Cow {
    var cow = Cow.spawn(math.Vec3.init(
        record.living.position[0],
        record.living.position[1],
        record.living.position[2],
    ));
    cow.animal.restore(record.living);
    return cow;
}

test "a cow is the size EntityCow sets itself to" {
    const cow = Cow.spawn(math.Vec3.init(0, 0, 0));
    try std.testing.expectEqual(@as(f64, 0.9), cow.animal.base.width);
    try std.testing.expectEqual(@as(f64, 1.3), cow.animal.base.height);
    try std.testing.expectEqual(max_health, cow.animal.health);
}

test "a dying cow drops nought to two hides" {
    var dropped_nothing = false;
    var dropped_something = false;

    for (0..20) |seed| {
        var rand = world.JavaRandom.init(@intCast(seed));
        var cow = Cow.spawn(math.Vec3.init(8, 1, 8));

        _ = cow.animal.hurt(max_health, null, &rand);
        try std.testing.expect(!cow.animal.isAlive());

        if (cow.takeDrops()) |drops| {
            try std.testing.expect(drops.count >= 1 and drops.count <= 2);
            try std.testing.expectEqual(world.Id{ .item = .leather }, drops.stack().id);
            dropped_something = true;
        } else {
            dropped_nothing = true;
        }

        try std.testing.expect(cow.takeDrops() == null);
    }

    try std.testing.expect(dropped_nothing);
    try std.testing.expect(dropped_something);
}

test "a cow that burned to death still leaves plain leather" {
    var rand = world.JavaRandom.init(0);
    var cow = Cow.spawn(math.Vec3.init(8, 1, 8));
    cow.animal.fire = 5;

    _ = cow.animal.hurt(max_health, null, &rand);
    cow.pending_drops = 1;

    try std.testing.expectEqual(world.Id{ .item = .leather }, cow.takeDrops().?.stack().id);
}

test "a cow keeps its wounds across a record round trip" {
    var cow = Cow.spawn(math.Vec3.init(12.5, 64.0, -3.25));
    cow.animal.health = 3;
    cow.animal.yaw = 42.0;
    cow.animal.base.on_ground = true;

    const restored = Cow.fromRecord(cow.toRecord());

    try std.testing.expectEqual(@as(i32, 3), restored.animal.health);
    try std.testing.expectApproxEqAbs(@as(f32, 42.0), restored.animal.yaw, 1.0e-6);
    try std.testing.expect(restored.animal.base.on_ground);
    try std.testing.expectApproxEqAbs(@as(f64, 12.5), restored.animal.base.position.x, 1.0e-9);
}

test "a cow fills an empty bucket with milk, and ignores anything else" {
    try std.testing.expectEqual(world.Item.bucket_milk, Cow.interact(.bucket).?);
    try std.testing.expect(Cow.interact(.bucket_water) == null);
    try std.testing.expect(Cow.interact(.bucket_milk) == null);
    try std.testing.expect(Cow.interact(.sword_iron) == null);
    try std.testing.expect(Cow.interact(null) == null);
}

pub const wire_id: u8 = 92;

pub const mob_type: Mob.Type = .{
    .name = world.entity_nbt.cow_id,
    .wire_id = wire_id,
    .spawn = mobSpawn,
    .tick = mobTick,
    .takeDrops = mobTakeDrops,
    .store = mobStore,
    .load = mobLoad,
    .destroy = mobDestroy,
};

fn mobSpawn(gpa: std.mem.Allocator, position: math.Vec3, _: *world.JavaRandom) anyerror!*Animal {
    const self = try gpa.create(Cow);
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
    const self: *Cow = @fieldParentPtr("animal", animal);
    try self.tick(gpa, world_map, players, rand);
}

fn mobTakeDrops(animal: *Animal) ?Mob.Drops {
    const self: *Cow = @fieldParentPtr("animal", animal);
    const drops = self.takeDrops() orelse return null;
    return .{ .count = drops.count, .stack = drops.stack() };
}

fn mobStore(animal: *Animal, gpa: std.mem.Allocator) anyerror!world.nbt.Tag {
    const self: *Cow = @fieldParentPtr("animal", animal);
    return world.entity_nbt.storeCow(gpa, self.toRecord());
}

fn mobLoad(gpa: std.mem.Allocator, entity: world.nbt.Compound) anyerror!?*Animal {
    const record = world.entity_nbt.loadCow(entity) orelse return null;
    const self = try gpa.create(Cow);
    self.* = Cow.fromRecord(record);
    return &self.animal;
}

fn mobDestroy(animal: *Animal, gpa: std.mem.Allocator) void {
    const self: *Cow = @fieldParentPtr("animal", animal);
    self.deinit(gpa);
    gpa.destroy(self);
}
