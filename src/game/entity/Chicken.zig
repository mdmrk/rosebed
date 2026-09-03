const std = @import("std");

const assets = @import("assets");
const math = @import("math");
const world = @import("world");

const Mob = @import("../mob.zig");
const Animal = @import("Animal.zig");

const Chicken = @This();

animal: Animal,
wing_rotation: f32 = 0,
prev_wing_rotation: f32 = 0,
wing_reach: f32 = 0,
prev_wing_reach: f32 = 0,
wing_speed: f32 = 1.0,

egg_timer: ?i32 = null,
pending_eggs: u8 = 0,
pending_feathers: u8 = 0,

pub const width: f64 = 0.3;
pub const height: f64 = 0.4;
pub const max_health: i32 = 4;

pub const spec: Animal.Spec = .{
    .width = width,
    .height = height,
    .max_health = max_health,
    .takes_fall_damage = false,
    .living_sound = assets.sounds.mob.chicken,
    .hurt_sound = assets.sounds.mob.chickenhurt,
    .death_sound = assets.sounds.mob.chickenhurt,
    .talk_interval = Animal.passive_talk_interval,
};

const egg_interval: i32 = 6000;
const wing_beat: f32 = 2.0;
const wing_slowdown: f32 = 0.9;
const reach_step: f32 = 0.3;
const flutter_drag: f64 = 0.6;

fn init(position: math.Vec3) Chicken {
    var chicken: Chicken = .{ .animal = Animal.spawn(position, spec) };
    chicken.animal.on_death = dropFewItems;
    return chicken;
}

pub fn spawn(position: math.Vec3, rand: *world.JavaRandom) Chicken {
    var chicken = init(position);
    chicken.egg_timer = nextEggTimer(rand);
    return chicken;
}

pub fn deinit(self: *Chicken, gpa: std.mem.Allocator) void {
    self.animal.deinit(gpa);
}

fn nextEggTimer(rand: *world.JavaRandom) i32 {
    return rand.nextIntBound(egg_interval) + egg_interval;
}

fn dropFewItems(animal: *Animal, rand: *world.JavaRandom) void {
    const self: *Chicken = @fieldParentPtr("animal", animal);
    self.pending_feathers = @intCast(rand.nextIntBound(3));
}

pub fn tick(
    self: *Chicken,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    players: Animal.Players,
    rand: *world.JavaRandom,
) !void {
    try self.animal.tick(gpa, world_map, players, rand);

    const on_ground = self.animal.base.on_ground;

    self.prev_wing_rotation = self.wing_rotation;
    self.prev_wing_reach = self.wing_reach;
    self.wing_reach += (if (on_ground) -reach_step else 4.0 * reach_step);
    self.wing_reach = std.math.clamp(self.wing_reach, 0.0, 1.0);

    if (!on_ground and self.wing_speed < 1.0) self.wing_speed = 1.0;
    self.wing_speed *= wing_slowdown;

    if (!on_ground and self.animal.base.motion.y < 0.0) self.animal.base.motion.y *= flutter_drag;
    self.wing_rotation += self.wing_speed * wing_beat;

    if (self.animal.base.remote != null) return;

    const timer = (self.egg_timer orelse nextEggTimer(rand)) - 1;
    if (timer <= 0) {
        self.animal.playSound(world_map, assets.sounds.mob.chickenplop, rand);
        self.pending_eggs += 1;
        self.egg_timer = nextEggTimer(rand);
    } else {
        self.egg_timer = timer;
    }
}

pub const Drops = struct {
    count: u8,
    id: world.Item,

    pub fn stack(self: Drops) world.Stack {
        return .{ .id = .{ .item = self.id }, .count = 1 };
    }
};

pub fn takeDrops(self: *Chicken) ?Drops {
    if (self.pending_eggs > 0) {
        const drops: Drops = .{ .count = self.pending_eggs, .id = .egg };
        self.pending_eggs = 0;
        return drops;
    }
    if (self.pending_feathers > 0) {
        const drops: Drops = .{ .count = self.pending_feathers, .id = .feather };
        self.pending_feathers = 0;
        return drops;
    }
    return null;
}

pub fn wingFlap(self: Chicken, partial_ticks: f32) f32 {
    const rotation = self.prev_wing_rotation + (self.wing_rotation - self.prev_wing_rotation) * partial_ticks;
    const reach = self.prev_wing_reach + (self.wing_reach - self.prev_wing_reach) * partial_ticks;
    return (math.util.sin(rotation) + 1.0) * reach;
}

pub fn toRecord(self: Chicken) world.entity_nbt.Chicken {
    return .{ .living = self.animal.toRecord() };
}

pub fn fromRecord(record: world.entity_nbt.Chicken) Chicken {
    var chicken = init(record.living.position);
    chicken.animal.restore(record.living);
    return chicken;
}

test "a chicken is the size EntityChicken sets itself to, and as frail" {
    var rand = world.JavaRandom.init(0);
    const chicken = Chicken.spawn(math.Vec3.init(0, 0, 0), &rand);

    try std.testing.expectEqual(@as(f64, 0.3), chicken.animal.base.width);
    try std.testing.expectEqual(@as(f64, 0.4), chicken.animal.base.height);
    try std.testing.expectEqual(@as(i32, 4), chicken.animal.health);
}

test "a dying chicken drops nought to two feathers" {
    var w = world.World.init(std.testing.allocator);
    defer w.deinit();
    var dropped_nothing = false;
    var dropped_something = false;

    for (0..20) |seed| {
        var rand = world.JavaRandom.init(@intCast(seed));
        var chicken = Chicken.spawn(math.Vec3.init(8, 1, 8), &rand);

        _ = chicken.animal.hurt(&w, max_health, null, &rand);
        try std.testing.expect(!chicken.animal.isAlive());

        if (chicken.takeDrops()) |drops| {
            try std.testing.expect(drops.count >= 1 and drops.count <= 2);
            try std.testing.expectEqual(world.Item.feather, drops.id);
            dropped_something = true;
        } else {
            dropped_nothing = true;
        }

        try std.testing.expect(chicken.takeDrops() == null);
    }

    try std.testing.expect(dropped_nothing);
    try std.testing.expect(dropped_something);
}

fn grassField(gpa: std.mem.Allocator, radius: i32) !world.World {
    var w = world.World.init(gpa);
    errdefer w.deinit();

    var chunk_x: i32 = -radius;
    while (chunk_x <= radius) : (chunk_x += 1) {
        var chunk_z: i32 = -radius;
        while (chunk_z <= radius) : (chunk_z += 1) {
            const chunk = try w.createChunk(chunk_x, chunk_z);
            for (0..world.Chunk.width) |x| {
                for (0..world.Chunk.width) |z| {
                    chunk.setBlock(@intCast(x), 0, @intCast(z), .grass);
                    chunk.setSkyLight(@intCast(x), 1, @intCast(z), 15);
                }
            }
        }
    }
    return w;
}

test "a chicken lays one egg when its clutch runs out, then begins another" {
    const gpa = std.testing.allocator;
    var w = try grassField(gpa, 4);
    defer w.deinit();

    var rand = world.JavaRandom.init(4);
    var chicken = Chicken.spawn(math.Vec3.init(8.5, 1, 8.5), &rand);
    defer chicken.deinit(gpa);
    chicken.egg_timer = 1;

    try chicken.tick(gpa, &w, .{}, &rand);

    const drops = chicken.takeDrops().?;
    try std.testing.expectEqual(world.Item.egg, drops.id);
    try std.testing.expectEqual(@as(u8, 1), drops.count);
    try std.testing.expectEqual(world.Id{ .item = .egg }, drops.stack().id);
    try std.testing.expect(chicken.takeDrops() == null);

    try std.testing.expect(chicken.egg_timer.? >= egg_interval);
    try std.testing.expect(chicken.egg_timer.? <= egg_interval * 2);

    try chicken.tick(gpa, &w, .{}, &rand);
    try std.testing.expect(chicken.takeDrops() == null);
}

test "a clutch is always six to twelve thousand ticks long" {
    for (0..64) |seed| {
        var rand = world.JavaRandom.init(@intCast(seed));
        const chicken = Chicken.spawn(math.Vec3.init(0, 0, 0), &rand);

        try std.testing.expect(chicken.egg_timer.? >= egg_interval);
        try std.testing.expect(chicken.egg_timer.? <= egg_interval * 2);
    }
}

test "a chicken has nothing to lay before its timer runs out" {
    const gpa = std.testing.allocator;
    var w = try grassField(gpa, 4);
    defer w.deinit();

    var rand = world.JavaRandom.init(1);
    var chicken = Chicken.spawn(math.Vec3.init(8.5, 1, 8.5), &rand);
    defer chicken.deinit(gpa);

    for (0..egg_interval - 1) |_| {
        try chicken.tick(gpa, &w, .{}, &rand);
        try std.testing.expect(chicken.animal.isAlive());
        try std.testing.expect(chicken.takeDrops() == null);
    }
}

test "a chicken flutters down instead of falling, and lands unhurt" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var rand = world.JavaRandom.init(0);
    var chicken = Chicken.spawn(math.Vec3.init(8.5, 40, 8.5), &rand);
    defer chicken.deinit(gpa);

    var fastest: f64 = 0;
    for (0..600) |_| {
        try chicken.tick(gpa, &w, .{}, &rand);
        fastest = @min(fastest, chicken.animal.base.motion.y);
        if (chicken.animal.base.on_ground) break;
    }

    try std.testing.expect(chicken.animal.base.on_ground);
    try std.testing.expectEqual(max_health, chicken.animal.health);

    // Terminal velocity for anything that falls plainly is near -3.92.
    try std.testing.expect(fastest > -0.5);
}

test "the wings beat while the chicken is in the air and settle once it lands" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var rand = world.JavaRandom.init(0);
    var chicken = Chicken.spawn(math.Vec3.init(8.5, 20, 8.5), &rand);
    defer chicken.deinit(gpa);

    for (0..40) |_| try chicken.tick(gpa, &w, .{}, &rand);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), chicken.wing_reach, 1.0e-6);
    try std.testing.expect(chicken.wingFlap(1.0) >= 0.0);

    for (0..600) |_| {
        try chicken.tick(gpa, &w, .{}, &rand);
        if (chicken.animal.base.on_ground and chicken.wing_reach == 0.0) break;
    }

    try std.testing.expect(chicken.animal.base.on_ground);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), chicken.wing_reach, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), chicken.wingFlap(1.0), 1.0e-6);
}

test "a chicken keeps its wounds across a record round trip and starts a fresh clutch" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var rand = world.JavaRandom.init(0);
    var chicken = Chicken.spawn(math.Vec3.init(12.5, 64.0, -3.25), &rand);
    chicken.animal.health = 2;
    chicken.animal.yaw = 42.0;
    chicken.egg_timer = 3;

    var restored = Chicken.fromRecord(chicken.toRecord());
    defer restored.deinit(gpa);

    try std.testing.expectEqual(@as(i32, 2), restored.animal.health);
    try std.testing.expectApproxEqAbs(@as(f32, 42.0), restored.animal.yaw, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 12.5), restored.animal.base.position.x, 1.0e-9);

    // The clutch it was part way through is not in the save, so its first tick starts another.
    try std.testing.expect(restored.egg_timer == null);
    try restored.tick(gpa, &w, .{}, &rand);
    try std.testing.expect(restored.egg_timer.? >= egg_interval - 1);
    try std.testing.expect(restored.takeDrops() == null);
}

pub const wire_id: u8 = 93;

pub const mob_type: Mob.Type = .{
    .name = world.entity_nbt.chicken_id,
    .wire_id = wire_id,
    .spawn = mobSpawn,
    .tick = mobTick,
    .takeDrops = mobTakeDrops,
    .store = mobStore,
    .load = mobLoad,
    .destroy = mobDestroy,
};

fn mobSpawn(gpa: std.mem.Allocator, position: math.Vec3, rand: *world.JavaRandom) anyerror!*Animal {
    const self = try gpa.create(Chicken);
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
    const self: *Chicken = @fieldParentPtr("animal", animal);
    try self.tick(gpa, world_map, players, rand);
}

fn mobTakeDrops(animal: *Animal) ?Mob.Drops {
    const self: *Chicken = @fieldParentPtr("animal", animal);
    const drops = self.takeDrops() orelse return null;
    return .{ .count = drops.count, .stack = drops.stack() };
}

fn mobStore(animal: *Animal, gpa: std.mem.Allocator) anyerror!world.nbt.Tag {
    const self: *Chicken = @fieldParentPtr("animal", animal);
    return world.entity_nbt.storeChicken(gpa, self.toRecord());
}

fn mobLoad(gpa: std.mem.Allocator, entity: world.nbt.Compound) anyerror!?*Animal {
    const record = world.entity_nbt.loadChicken(entity) orelse return null;
    const self = try gpa.create(Chicken);
    self.* = Chicken.fromRecord(record);
    return &self.animal;
}

fn mobDestroy(animal: *Animal, gpa: std.mem.Allocator) void {
    const self: *Chicken = @fieldParentPtr("animal", animal);
    self.deinit(gpa);
    gpa.destroy(self);
}
