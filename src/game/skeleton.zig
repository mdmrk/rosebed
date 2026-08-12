const std = @import("std");

const math = @import("math");
const world = @import("world");

const Animal = @import("animal.zig");
const Mob = @import("mob.zig");
const Monster = @import("monster.zig");
pub const max_health: i32 = Monster.max_health;
const Zombie = @import("zombie.zig");

const Skeleton = @This();

animal: Animal,
monster: Monster = .{},
ticks_existed: i32 = 0,
pending_shot: ?Shot = null,
pending_arrows: u8 = 0,
pending_bones: u8 = 0,

pub const width: f64 = 0.6;
pub const height: f64 = 1.8;
pub const bow_range: f32 = 10.0;
pub const draw_ticks: i32 = 30;
pub const arrow_lift: f64 = 1.4;
pub const arrow_drop: f64 = 0.1;
pub const arrow_hand_offset: f32 = 0.16;
pub const aim_drop: f64 = 0.2;
pub const aim_lob: f32 = 0.2;
pub const arrow_speed: f32 = 0.6;
pub const arrow_spread: f32 = 12.0;

pub const spec: Animal.Spec = .{
    .width = width,
    .height = height,
    .max_health = max_health,
};

pub const Shot = struct {
    owner: Animal.Entity.Id = Animal.Entity.no_id,
    from: math.Vec3,
    toward: math.Vec3,
};

fn init(position: math.Vec3) Skeleton {
    var self: Skeleton = .{ .animal = Animal.spawn(position, spec) };
    self.animal.on_death = dropFewItems;
    self.animal.action_state = updateActionState;
    self.animal.path_weight = Monster.blockPathWeight;
    self.monster.attack = attackEntity;
    return self;
}

pub fn spawn(position: math.Vec3) Skeleton {
    return init(position);
}

pub fn deinit(self: *Skeleton, gpa: std.mem.Allocator) void {
    self.animal.deinit(gpa);
}

pub fn tick(
    self: *Skeleton,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    players: Animal.Players,
    rand: *world.JavaRandom,
) !void {
    self.ticks_existed += 1;
    self.monster.beginTick(&self.animal);
    try self.animal.tick(gpa, world_map, players, rand);
}

fn attackEntity(
    monster: *Monster,
    animal: *Animal,
    _: *const world.World,
    view: Animal.PlayerView,
    distance: f32,
    _: *world.JavaRandom,
) void {
    const self: *Skeleton = @alignCast(@fieldParentPtr("monster", monster));
    if (distance >= bow_range) return;

    const dx = view.position.x - animal.base.position.x;
    const dz = view.position.z - animal.base.position.z;

    if (monster.attack_time == 0) {
        const yaw_radians = animal.yaw / 180.0 * std.math.pi;
        const from = math.Vec3.init(
            animal.base.position.x - @as(f64, math.util.cos(yaw_radians) * arrow_hand_offset),
            animal.base.position.y + animal.eyeHeight() - arrow_drop + arrow_lift,
            animal.base.position.z - @as(f64, math.util.sin(yaw_radians) * arrow_hand_offset),
        );

        const dy = view.position.y + view.eye_height - aim_drop - from.y;
        const lob: f64 = math.util.sqrtF(dx * dx + dz * dz) * aim_lob;

        self.pending_shot = .{ .owner = animal.base.id, .from = from, .toward = math.Vec3.init(dx, dy + lob, dz) };
        monster.attack_time = draw_ticks;
    }

    self.animal.yaw = @as(f32, @floatCast(std.math.atan2(dz, dx) * 180.0 / std.math.pi)) - 90.0;
    monster.has_attacked = true;
}

fn updateActionState(
    animal: *Animal,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    players: Animal.Players,
    rand: *world.JavaRandom,
) anyerror!void {
    const self: *Skeleton = @fieldParentPtr("animal", animal);
    Zombie.burnInDaylight(animal, world_map, rand);
    try self.monster.updateActionState(animal, gpa, world_map, players, rand, true);
}

pub fn takeShot(self: *Skeleton) ?Shot {
    const shot = self.pending_shot orelse return null;
    self.pending_shot = null;
    return shot;
}

pub fn hurt(self: *Skeleton, amount: i32, source: ?Animal.Attacker, rand: *world.JavaRandom) bool {
    if (!self.animal.hurt(amount, source, rand)) return false;
    if (source) |from| {
        if (from.player != Animal.Entity.no_id) self.monster.target = from.player;
    }
    return true;
}

pub fn canSpawnHere(self: Skeleton, world_map: *const world.World, rand: *world.JavaRandom) bool {
    return Monster.canSpawnHere(self.animal, world_map, rand);
}

fn dropFewItems(animal: *Animal, rand: *world.JavaRandom) void {
    const self: *Skeleton = @fieldParentPtr("animal", animal);
    self.pending_arrows = @intCast(rand.nextIntBound(3));
    self.pending_bones = @intCast(rand.nextIntBound(3));
}

pub const Drops = struct {
    count: u8,
    id: world.Item,

    pub fn stack(self: Drops) world.Stack {
        return .{ .id = .{ .item = self.id }, .count = 1 };
    }
};

pub fn takeDrops(self: *Skeleton) ?Drops {
    if (self.pending_arrows > 0) {
        const drops: Drops = .{ .count = self.pending_arrows, .id = .arrow };
        self.pending_arrows = 0;
        return drops;
    }
    if (self.pending_bones > 0) {
        const drops: Drops = .{ .count = self.pending_bones, .id = .bone };
        self.pending_bones = 0;
        return drops;
    }
    return null;
}

pub fn renderAge(self: Skeleton, partial_ticks: f32) f32 {
    return @as(f32, @floatFromInt(self.ticks_existed)) + partial_ticks;
}

pub fn toRecord(self: Skeleton) world.entity_nbt.Skeleton {
    return .{ .living = self.animal.toRecord() };
}

pub fn fromRecord(record: world.entity_nbt.Skeleton) Skeleton {
    var self = init(math.Vec3.init(
        record.living.position[0],
        record.living.position[1],
        record.living.position[2],
    ));
    self.animal.restore(record.living);
    return self;
}

pub const wire_id: u8 = 51;

pub const mob_type: Mob.Type = .{
    .name = world.entity_nbt.skeleton_id,
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
    const self = try gpa.create(Skeleton);
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
    const self: *Skeleton = @fieldParentPtr("animal", animal);
    try self.tick(gpa, world_map, players, rand);
}

fn mobTakeDrops(animal: *Animal) ?Mob.Drops {
    const self: *Skeleton = @fieldParentPtr("animal", animal);
    const drops = self.takeDrops() orelse return null;
    return .{ .count = drops.count, .stack = drops.stack() };
}

fn mobHurt(animal: *Animal, amount: i32, source: ?Animal.Attacker, rand: *world.JavaRandom) bool {
    const self: *Skeleton = @fieldParentPtr("animal", animal);
    return self.hurt(amount, source, rand);
}

fn mobStore(animal: *Animal, gpa: std.mem.Allocator) anyerror!world.nbt.Tag {
    const self: *Skeleton = @fieldParentPtr("animal", animal);
    return world.entity_nbt.storeSkeleton(gpa, self.toRecord());
}

fn mobLoad(gpa: std.mem.Allocator, entity: world.nbt.Compound) anyerror!?*Animal {
    const record = world.entity_nbt.loadSkeleton(entity) orelse return null;
    const self = try gpa.create(Skeleton);
    self.* = Skeleton.fromRecord(record);
    return &self.animal;
}

fn mobDestroy(animal: *Animal, gpa: std.mem.Allocator) void {
    const self: *Skeleton = @fieldParentPtr("animal", animal);
    self.deinit(gpa);
    gpa.destroy(self);
}

fn mobAfterTick(animal: *Animal, context: Mob.Tick) anyerror!void {
    const Entities = @import("entities.zig");
    const self: *Skeleton = @fieldParentPtr("animal", animal);

    const shot = self.takeShot() orelse return;
    const entities: *Entities = @ptrCast(@alignCast(context.entities));
    try entities.loose(context.gpa, shot, context.rand);
}

test "a skeleton is the size, health and speed EntitySkeleton inherits" {
    const self = Skeleton.spawn(math.Vec3.init(0, 0, 0));

    try std.testing.expectEqual(@as(f64, 0.6), self.animal.base.width);
    try std.testing.expectEqual(@as(f64, 1.8), self.animal.base.height);
    try std.testing.expectEqual(@as(i32, 20), self.animal.health);
    try std.testing.expectEqual(Animal.default_move_speed, self.animal.move_speed);
}

test "a skeleton looses an arrow at a player inside ten blocks, then draws for thirty ticks" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();
    var rand = world.JavaRandom.init(0);
    var self = Skeleton.spawn(math.Vec3.init(8.5, 1, 8.5));

    const player = Animal.PlayerView{
        .position = math.Vec3.init(14.5, 1, 8.5),
        .eye_height = 1.62,
        .alive = true,
    };

    self.monster.attack(&self.monster, &self.animal, &w, player, 12.0, &rand);
    try std.testing.expect(self.pending_shot == null);
    try std.testing.expect(!self.monster.has_attacked);

    self.monster.attack(&self.monster, &self.animal, &w, player, 6.0, &rand);
    try std.testing.expect(self.pending_shot != null);
    try std.testing.expectEqual(draw_ticks, self.monster.attack_time);
    try std.testing.expect(self.monster.has_attacked);

    _ = self.takeShot();
    self.monster.attack(&self.monster, &self.animal, &w, player, 6.0, &rand);
    try std.testing.expect(self.pending_shot == null);
    try std.testing.expect(self.monster.has_attacked);
}

test "a skeleton's arrow leaves above its head and leads the player it is aimed at" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();
    var rand = world.JavaRandom.init(0);
    var self = Skeleton.spawn(math.Vec3.init(8.5, 64, 8.5));

    const player = Animal.PlayerView{
        .position = math.Vec3.init(14.5, 64, 8.5),
        .eye_height = 1.62,
        .alive = true,
    };
    self.monster.attack(&self.monster, &self.animal, &w, player, 6.0, &rand);

    const shot = self.takeShot().?;
    try std.testing.expectApproxEqAbs(
        @as(f64, 64.0 + 1.53 - arrow_drop + arrow_lift),
        shot.from.y,
        1.0e-6,
    );

    try std.testing.expectApproxEqAbs(@as(f64, 6.0), shot.toward.x, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), shot.toward.z, 1.0e-6);

    // The lob is the flat range times a fifth, added on top of the drop to the player's eyes.
    const flat: f64 = 6.0;
    const to_eyes = 64.0 + 1.62 - aim_drop - shot.from.y;
    try std.testing.expectApproxEqAbs(to_eyes + flat * aim_lob, shot.toward.y, 1.0e-6);
}

test "a skeleton turns to face whatever it is shooting" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();
    var rand = world.JavaRandom.init(0);
    var self = Skeleton.spawn(math.Vec3.init(8.5, 1, 8.5));
    self.animal.faceYaw(0);

    const behind = Animal.PlayerView{
        .position = math.Vec3.init(8.5, 1, 2.5),
        .eye_height = 1.62,
        .alive = true,
    };
    self.monster.attack(&self.monster, &self.animal, &w, behind, 6.0, &rand);

    try std.testing.expectApproxEqAbs(@as(f32, 180.0), @abs(self.animal.yaw), 1.0e-4);
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

test "a skeleton that spots the player stands off and shoots rather than closing in" {
    const gpa = std.testing.allocator;
    var w = try stoneFloor(gpa);
    defer w.deinit();

    var rand = world.JavaRandom.init(7);
    var self = Skeleton.spawn(math.Vec3.init(8.5, 1, 8.5));
    defer self.deinit(gpa);
    self.animal.base.on_ground = true;

    const player = Animal.PlayerView{
        .id = 1,
        .position = math.Vec3.init(14.5, 1, 8.5),
        .eye_height = 1.62,
        .alive = true,
    };

    var shots: u32 = 0;
    for (0..120) |_| {
        try self.tick(gpa, &w, Animal.Players.one(&player), &rand);
        if (self.takeShot() != null) shots += 1;
    }

    try std.testing.expectEqual(@as(?Animal.Entity.Id, 1), self.monster.target);
    try std.testing.expect(shots >= 3 and shots <= 5);
}

test "a dying skeleton leaves both arrows and bones" {
    var seen_arrows = false;
    var seen_bones = false;
    var seen_empty = false;

    for (0..20) |seed| {
        var rand = world.JavaRandom.init(@intCast(seed));
        var self = Skeleton.spawn(math.Vec3.init(8, 1, 8));

        _ = self.animal.hurt(max_health, null, &rand);
        try std.testing.expect(!self.animal.isAlive());

        var arrows: u8 = 0;
        var bones: u8 = 0;
        while (self.takeDrops()) |drops| {
            try std.testing.expect(drops.count >= 1 and drops.count <= 2);
            switch (drops.id) {
                .arrow => arrows += drops.count,
                .bone => bones += drops.count,
                else => unreachable,
            }
        }

        if (arrows > 0) seen_arrows = true;
        if (bones > 0) seen_bones = true;
        if (arrows == 0 and bones == 0) seen_empty = true;
    }

    try std.testing.expect(seen_arrows);
    try std.testing.expect(seen_bones);
    try std.testing.expect(seen_empty);
}

test "a struck skeleton turns on the player who struck it" {
    var rand = world.JavaRandom.init(0);
    var self = Skeleton.spawn(math.Vec3.init(8, 1, 8));

    try std.testing.expect(self.hurt(3, .{ .position = math.Vec3.init(6, 1, 8), .player = 11 }, &rand));
    try std.testing.expectEqual(@as(?Animal.Entity.Id, 11), self.monster.target);
}

test "a skeleton keeps its wounds across a record round trip" {
    var self = Skeleton.spawn(math.Vec3.init(12.5, 64.0, -3.25));
    self.animal.health = 9;
    self.animal.yaw = 42.0;
    self.animal.base.on_ground = true;

    const restored = Skeleton.fromRecord(self.toRecord());

    try std.testing.expectEqual(@as(i32, 9), restored.animal.health);
    try std.testing.expectApproxEqAbs(@as(f32, 42.0), restored.animal.yaw, 1.0e-6);
    try std.testing.expect(restored.animal.base.on_ground);
    try std.testing.expectApproxEqAbs(@as(f64, -3.25), restored.animal.base.position.z, 1.0e-9);
}

test "a skeleton in the sun catches fire like a zombie" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();
    w.setTime(1000);
    w.skylight_subtracted = w.calculateSkylightSubtracted(1.0);

    const chunk = w.getChunk(0, 0).?;
    for (0..world.constants.chunk_width) |x| {
        for (0..world.constants.chunk_width) |z| {
            var y: u32 = 1;
            while (y <= 4) : (y += 1) chunk.setSkyLight(@intCast(x), y, @intCast(z), 15);
        }
    }

    var rand = world.JavaRandom.init(1);
    var self = Skeleton.spawn(math.Vec3.init(8.5, 1, 8.5));
    defer self.deinit(gpa);

    var lit = false;
    for (0..200) |_| {
        Zombie.burnInDaylight(&self.animal, &w, &rand);
        if (self.animal.fire > 0) lit = true;
    }

    try std.testing.expect(lit);
}
