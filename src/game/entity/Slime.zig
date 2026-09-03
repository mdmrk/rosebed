const std = @import("std");

const assets = @import("assets");
const math = @import("math");
const world = @import("world");

const Mob = @import("../mob.zig");
const raycast = @import("../raycast.zig");
const Animal = @import("Animal.zig");

const Slime = @This();

animal: Animal,
size: u8,
squish: f32 = 0,
prev_squish: f32 = 0,
jump_delay: i32 = 0,
pending_drops: u8 = 0,
landed: bool = false,

pub const size_scale: f64 = 0.6;
pub const sight_range: f64 = 16.0;
pub const chunk_salt: i64 = 987234911;
pub const spawn_ceiling: f64 = 16.0;
pub const split_count: usize = 4;
pub const landing_squish: f32 = -0.5;
pub const jump_squish: f32 = 1.0;
pub const squish_decay: f32 = 0.6;
pub const particles_per_size: usize = 8;
pub const player_sight_height: f64 = 0.12;
pub const squish_pitch_bend: f32 = 0.8;
pub const squish_land_size: u8 = 2;
pub const squish_jump_size: u8 = 1;
pub const attack_volume: f32 = 1.0;

pub fn specFor(size: u8) Animal.Spec {
    const extent = size_scale * @as(f64, @floatFromInt(size));
    return .{
        .width = extent,
        .height = extent,
        .max_health = @as(i32, size) * @as(i32, size),
        .hurt_sound = assets.sounds.mob.slime,
        .death_sound = assets.sounds.mob.slime,
        .sound_volume = 0.6,
    };
}

fn init(position: math.Vec3, size: u8) Slime {
    var slime: Slime = .{
        .animal = Animal.spawn(position, specFor(size)),
        .size = size,
    };
    slime.animal.on_death = dropFewItems;
    slime.animal.action_state = updateActionState;
    return slime;
}

pub fn spawn(position: math.Vec3, rand: *world.JavaRandom) Slime {
    const rolled = @as(u8, 1) << @intCast(rand.nextIntBound(3));
    const delay = rand.nextIntBound(20) + 10;

    var slime = init(position, rolled);
    slime.jump_delay = delay;
    return slime;
}

pub fn deinit(self: *Slime, gpa: std.mem.Allocator) void {
    self.animal.deinit(gpa);
}

pub fn setSize(self: *Slime, size: u8) void {
    const spec = specFor(size);
    self.size = size;
    self.animal.base.width = spec.width;
    self.animal.base.height = spec.height;
    self.animal.max_health = spec.max_health;
    self.animal.health = spec.max_health;
}

pub fn tick(
    self: *Slime,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    players: Animal.Players,
    rand: *world.JavaRandom,
) !void {
    self.prev_squish = self.squish;
    const was_on_ground = self.animal.base.on_ground;

    try self.animal.tick(gpa, world_map, players, rand);

    self.landed = self.animal.base.on_ground and !was_on_ground;
    if (self.landed) self.squish = landing_squish;
    self.squish *= squish_decay;
}

fn playSquish(self: *const Slime, world_map: *const world.World, pitch: f32) void {
    world_map.playSoundEffect(
        self.animal.base.position.x,
        self.animal.base.position.y,
        self.animal.base.position.z,
        assets.sounds.mob.slime,
        self.animal.sound_volume,
        pitch,
    );
}

fn playAttack(self: *const Slime, world_map: *const world.World, rand: *world.JavaRandom) void {
    world_map.playSoundEffect(
        self.animal.base.position.x,
        self.animal.base.position.y,
        self.animal.base.position.z,
        assets.sounds.mob.slimeattack,
        attack_volume,
        (rand.nextFloat() - rand.nextFloat()) * 0.2 + 1.0,
    );
}

fn playerPosition(view: Animal.PlayerView) math.Vec3 {
    return .{
        .x = view.position.x,
        .y = view.position.y + view.eye_height,
        .z = view.position.z,
    };
}

fn closestPlayer(self: Slime, players: Animal.Players, range: f64) ?Animal.PlayerView {
    const view = players.closestTo(self.animal.base.position, -1.0) orelse return null;
    if (self.animal.distanceSquaredTo(playerPosition(view)) >= range * range) return null;
    return view;
}

fn updateActionState(
    animal: *Animal,
    _: std.mem.Allocator,
    world_map: *const world.World,
    players: Animal.Players,
    rand: *world.JavaRandom,
) anyerror!void {
    const self: *Slime = @fieldParentPtr("animal", animal);

    animal.despawnCheck(players, rand);

    const target = self.closestPlayer(players, sight_range);
    if (target) |view| animal.faceEntity(view.position, view.eye_height, 10.0, 20.0);

    var jumps = false;
    if (animal.base.on_ground) {
        jumps = self.jump_delay <= 0;
        self.jump_delay -= 1;
    }

    if (jumps) {
        self.jump_delay = rand.nextIntBound(20) + 10;
        if (target != null) self.jump_delay = @divTrunc(self.jump_delay, 3);

        animal.is_jumping = true;
        if (self.size > squish_jump_size) {
            self.playSquish(world_map, ((rand.nextFloat() - rand.nextFloat()) * 0.2 + 1.0) * squish_pitch_bend);
        }
        self.squish = jump_squish;
        animal.move_strafing = 1.0 - rand.nextFloat() * 2.0;
        animal.move_forward = @floatFromInt(self.size);
    } else {
        animal.is_jumping = false;
        if (animal.base.on_ground) {
            animal.move_strafing = 0;
            animal.move_forward = 0;
        }
    }
}

fn dropFewItems(animal: *Animal, rand: *world.JavaRandom) void {
    const self: *Slime = @fieldParentPtr("animal", animal);
    if (self.size != 1) return;
    self.pending_drops = @intCast(rand.nextIntBound(3));
}

pub const Drops = struct {
    count: u8,

    pub fn stack(_: Drops) world.Stack {
        return .{ .id = .{ .item = .slime_ball }, .count = 1 };
    }
};

pub fn takeDrops(self: *Slime) ?Drops {
    if (self.pending_drops == 0) return null;
    const drops: Drops = .{ .count = self.pending_drops };
    self.pending_drops = 0;
    return drops;
}

pub fn splitsApart(self: Slime) bool {
    return self.size > 1 and self.animal.health == 0;
}

pub fn splitOffset(self: Slime, index: usize) math.Vec3 {
    const spread = @as(f32, @floatFromInt(self.size)) / 4.0;
    const dx = (@as(f32, @floatFromInt(index % 2)) - 0.5) * spread;
    const dz = (@as(f32, @floatFromInt(index / 2)) - 0.5) * spread;
    return .{
        .x = self.animal.base.position.x + dx,
        .y = self.animal.base.position.y + 0.5,
        .z = self.animal.base.position.z + dz,
    };
}

fn canSeePlayer(self: Slime, world_map: *const world.World, view: Animal.PlayerView) bool {
    const eye = math.Vec3.init(
        self.animal.base.position.x,
        self.animal.base.position.y + self.animal.eyeHeight(),
        self.animal.base.position.z,
    );
    const sight = playerPosition(view);
    const to_player = math.Vec3.init(sight.x - eye.x, sight.y + player_sight_height - eye.y, sight.z - eye.z);
    const reach = @sqrt(to_player.lengthSquared());
    if (reach == 0.0) return true;

    const along = math.Vec3.init(to_player.x / reach, to_player.y / reach, to_player.z / reach);
    return raycast.castCollision(world_map, eye, along, reach) == null;
}

pub fn attackDamage(self: Slime, world_map: *const world.World, view: Animal.PlayerView) ?i32 {
    if (self.size <= 1) return null;
    if (!self.canSeePlayer(world_map, view)) return null;

    const reach = size_scale * @as(f64, @floatFromInt(self.size));
    if (self.animal.distanceSquaredTo(playerPosition(view)) >= reach * reach) return null;

    return self.size;
}

pub fn chunkSeed(chunk_x: i32, chunk_z: i32, world_seed: i64, salt: i64) i64 {
    const x_squared: i32 = chunk_x *% chunk_x *% 4987142;
    const x_linear: i32 = chunk_x *% 5947611;
    const z_squared: i32 = chunk_z *% chunk_z;
    const z_linear: i32 = chunk_z *% 389711;

    const mixed = world_seed +%
        @as(i64, x_squared) +%
        @as(i64, x_linear) +%
        @as(i64, z_squared) *% 4392871 +%
        @as(i64, z_linear);
    return mixed ^ salt;
}

pub fn canSpawnHere(
    self: Slime,
    world_map: *const world.World,
    world_seed: i64,
    rand: *world.JavaRandom,
) bool {
    if (self.size != 1 and !world_map.difficulty.atLeast(.easy)) return false;
    if (rand.nextIntBound(10) != 0) return false;

    const chunk_x = @divFloor(math.util.floorDouble(self.animal.base.position.x), world.Chunk.width);
    const chunk_z = @divFloor(math.util.floorDouble(self.animal.base.position.z), world.Chunk.width);
    var chunk_rand = world.JavaRandom.init(chunkSeed(chunk_x, chunk_z, world_seed, chunk_salt));
    if (chunk_rand.nextIntBound(10) != 0) return false;

    return self.animal.base.position.y < spawn_ceiling;
}

pub fn renderSquish(self: Slime, partial_ticks: f32) f32 {
    return self.prev_squish + (self.squish - self.prev_squish) * partial_ticks;
}

pub fn toRecord(self: Slime) world.entity_nbt.Slime {
    return .{ .living = self.animal.toRecord(), .size = @as(i32, self.size) - 1 };
}

pub fn fromRecord(record: world.entity_nbt.Slime) Slime {
    const size: u8 = @intCast(std.math.clamp(record.size + 1, 1, 255));
    var slime = init(record.living.position, size);
    slime.animal.restore(record.living);
    slime.setSize(size);
    return slime;
}

test "a slime is one of the three sizes EntitySlime rolls, and is square" {
    var seen = [_]bool{ false, false, false };

    for (0..40) |seed| {
        var rand = world.JavaRandom.init(@intCast(seed));
        const slime = Slime.spawn(math.Vec3.init(8, 1, 8), &rand);

        const extent = 0.6 * @as(f64, @floatFromInt(slime.size));
        try std.testing.expectEqual(extent, slime.animal.base.width);
        try std.testing.expectEqual(extent, slime.animal.base.height);
        try std.testing.expectEqual(@as(i32, slime.size) * @as(i32, slime.size), slime.animal.health);

        seen[std.math.log2_int(u8, slime.size)] = true;
    }

    for (seen) |size_seen| try std.testing.expect(size_seen);
}

test "resizing a slime resets its health to the square of its size" {
    var rand = world.JavaRandom.init(0);
    var slime = Slime.spawn(math.Vec3.init(8, 1, 8), &rand);

    slime.setSize(4);
    try std.testing.expectEqual(@as(i32, 16), slime.animal.health);
    try std.testing.expectApproxEqAbs(@as(f64, 2.4), slime.animal.base.width, 1.0e-9);

    slime.setSize(1);
    try std.testing.expectEqual(@as(i32, 1), slime.animal.health);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), slime.animal.base.height, 1.0e-9);
}

test "only the smallest slime leaves slimeballs behind" {
    var w = world.World.init(std.testing.allocator);
    defer w.deinit();
    var rand = world.JavaRandom.init(0);

    var big = Slime.spawn(math.Vec3.init(8, 1, 8), &rand);
    big.setSize(4);
    _ = big.animal.hurt(&w, big.animal.max_health, null, &rand);
    try std.testing.expect(big.takeDrops() == null);

    var dropped_nothing = false;
    var dropped_something = false;
    for (0..20) |seed| {
        var seeded = world.JavaRandom.init(@intCast(seed));
        var small = Slime.spawn(math.Vec3.init(8, 1, 8), &seeded);
        small.setSize(1);

        _ = small.animal.hurt(&w, small.animal.max_health, null, &seeded);
        if (small.takeDrops()) |drops| {
            try std.testing.expect(drops.count >= 1 and drops.count <= 2);
            try std.testing.expectEqual(world.Id{ .item = .slime_ball }, drops.stack().id);
            dropped_something = true;
        } else {
            dropped_nothing = true;
        }
    }

    try std.testing.expect(dropped_nothing);
    try std.testing.expect(dropped_something);
}

test "a slime killed outright splits, one killed by overkill does not" {
    var w = world.World.init(std.testing.allocator);
    defer w.deinit();
    var rand = world.JavaRandom.init(0);

    var halved = Slime.spawn(math.Vec3.init(8, 1, 8), &rand);
    halved.setSize(2);
    _ = halved.animal.hurt(&w, 4, null, &rand);
    try std.testing.expectEqual(@as(i32, 0), halved.animal.health);
    try std.testing.expect(halved.splitsApart());

    var overkilled = Slime.spawn(math.Vec3.init(8, 1, 8), &rand);
    overkilled.setSize(2);
    _ = overkilled.animal.hurt(&w, 9, null, &rand);
    try std.testing.expect(overkilled.animal.health < 0);
    try std.testing.expect(!overkilled.splitsApart());

    var smallest = Slime.spawn(math.Vec3.init(8, 1, 8), &rand);
    smallest.setSize(1);
    _ = smallest.animal.hurt(&w, 1, null, &rand);
    try std.testing.expect(!smallest.splitsApart());
}

test "the four children are placed around their parent, half a block up" {
    var rand = world.JavaRandom.init(0);
    var slime = Slime.spawn(math.Vec3.init(8, 1, 8), &rand);
    slime.setSize(4);

    var seen_x = [_]bool{ false, false };
    var seen_z = [_]bool{ false, false };
    for (0..split_count) |index| {
        const at = slime.splitOffset(index);
        try std.testing.expectApproxEqAbs(@as(f64, 1.5), at.y, 1.0e-9);
        try std.testing.expectApproxEqAbs(@as(f64, 0.5), @abs(at.x - 8.0), 1.0e-6);
        try std.testing.expectApproxEqAbs(@as(f64, 0.5), @abs(at.z - 8.0), 1.0e-6);
        seen_x[@intFromBool(at.x > 8.0)] = true;
        seen_z[@intFromBool(at.z > 8.0)] = true;
    }

    try std.testing.expect(seen_x[0] and seen_x[1]);
    try std.testing.expect(seen_z[0] and seen_z[1]);
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

test "a slime jumps on a countdown, and squashes when it lands" {
    const gpa = std.testing.allocator;
    var w = try stoneFloor(gpa);
    defer w.deinit();

    var rand = world.JavaRandom.init(4);
    var slime = Slime.spawn(math.Vec3.init(8.5, 1, 8.5), &rand);
    defer slime.deinit(gpa);
    slime.setSize(1);
    slime.animal.base.on_ground = true;

    var jumped = false;
    var squashed = false;
    for (0..200) |_| {
        try slime.tick(gpa, &w, .{}, &rand);
        if (slime.animal.base.motion.y > 0.0) jumped = true;
        if (slime.landed) squashed = true;
    }

    try std.testing.expect(jumped);
    try std.testing.expect(squashed);
    try std.testing.expect(slime.animal.isAlive());
}

test "a nearby player makes a slime jump sooner" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    const nearby = Animal.PlayerView{
        .position = math.Vec3.init(10.5, 1, 8.5),
        .eye_height = 1.62,
        .alive = true,
    };

    var alone_rand = world.JavaRandom.init(11);
    var alone = Slime.spawn(math.Vec3.init(8.5, 1, 8.5), &alone_rand);
    defer alone.deinit(gpa);
    alone.setSize(1);
    alone.animal.base.on_ground = true;

    var watched_rand = world.JavaRandom.init(11);
    var watched = Slime.spawn(math.Vec3.init(8.5, 1, 8.5), &watched_rand);
    defer watched.deinit(gpa);
    watched.setSize(1);
    watched.animal.base.on_ground = true;

    for (0..60) |_| {
        try alone.tick(gpa, &w, .{}, &alone_rand);
        try watched.tick(gpa, &w, Animal.Players.one(&nearby), &watched_rand);
    }

    try std.testing.expect(watched.jump_delay <= alone.jump_delay);
}

test "a slime turns to face the player it can see" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var rand = world.JavaRandom.init(2);
    var slime = Slime.spawn(math.Vec3.init(8.5, 1, 8.5), &rand);
    defer slime.deinit(gpa);
    slime.setSize(1);
    slime.animal.faceYaw(0);

    const nearby = Animal.PlayerView{
        .position = math.Vec3.init(14.5, 1, 8.5),
        .eye_height = 1.62,
        .alive = true,
    };
    for (0..40) |_| try slime.tick(gpa, &w, Animal.Players.one(&nearby), &rand);

    try std.testing.expect(@abs(slime.animal.yaw + 90.0) < 15.0);
}

test "only a slime bigger than the smallest can hurt the player, and only up close" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var rand = world.JavaRandom.init(0);
    const touching = Animal.PlayerView{
        .position = math.Vec3.init(8.5, 1, 8.5),
        .eye_height = 1.62,
        .alive = true,
    };

    var smallest = Slime.spawn(math.Vec3.init(8.5, 1, 8.5), &rand);
    smallest.setSize(1);
    try std.testing.expect(smallest.attackDamage(&w, touching) == null);

    var biggest = Slime.spawn(math.Vec3.init(8.5, 1, 8.5), &rand);
    biggest.setSize(4);
    try std.testing.expectEqual(@as(i32, 4), biggest.attackDamage(&w, touching).?);

    var far_off = Slime.spawn(math.Vec3.init(8.5, 1, 8.5), &rand);
    far_off.setSize(4);
    const distant = Animal.PlayerView{
        .position = math.Vec3.init(14.5, 1, 8.5),
        .eye_height = 1.62,
        .alive = true,
    };
    try std.testing.expect(far_off.attackDamage(&w, distant) == null);
}

test "a wall between the slime and the player stops the attack" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var rand = world.JavaRandom.init(0);
    var slime = Slime.spawn(math.Vec3.init(8.5, 1, 8.5), &rand);
    slime.setSize(4);

    const player = Animal.PlayerView{
        .position = math.Vec3.init(9.9, 1, 8.5),
        .eye_height = 1.62,
        .alive = true,
    };
    try std.testing.expect(slime.attackDamage(&w, player) != null);

    var y: u32 = 1;
    while (y <= 3) : (y += 1) w.setBlock(.init(9, @intCast(y), 8), .stone);
    try std.testing.expect(slime.attackDamage(&w, player) == null);
}

test "the slime chunk seed matches the vanilla chunk mix" {
    try std.testing.expectEqual(@as(i64, 987234911), chunkSeed(0, 0, 0, chunk_salt));

    const seeded = chunkSeed(3, -5, 12345, chunk_salt);
    const expected = (@as(i64, 12345) +%
        @as(i64, 3 * 3 * 4987142) +%
        @as(i64, 3 * 5947611) +%
        @as(i64, 25) *% 4392871 +%
        @as(i64, -5 * 389711)) ^ chunk_salt;
    try std.testing.expectEqual(expected, seeded);
}

test "slimes only spawn low down, and only in one chunk in ten" {
    var w = world.World.init(std.testing.allocator);
    defer w.deinit();
    var rand = world.JavaRandom.init(0);

    var high = Slime.spawn(math.Vec3.init(8.5, 40, 8.5), &rand);
    high.setSize(1);

    var allowed = false;
    for (0..400) |_| {
        if (high.canSpawnHere(&w, 1, &rand)) allowed = true;
    }
    try std.testing.expect(!allowed);

    var chunks_allowing: u32 = 0;
    for (0..200) |chunk| {
        const x: f64 = @floatFromInt(chunk * 16);
        var low = Slime.spawn(math.Vec3.init(x + 8.5, 8, 8.5), &rand);
        low.setSize(1);

        var attempts: u32 = 0;
        while (attempts < 200) : (attempts += 1) {
            if (low.canSpawnHere(&w, 1, &rand)) {
                chunks_allowing += 1;
                break;
            }
        }
    }

    try std.testing.expect(chunks_allowing > 5 and chunks_allowing < 45);
}

test "a slime keeps its size across a record round trip, and comes back healed" {
    var rand = world.JavaRandom.init(0);
    var slime = Slime.spawn(math.Vec3.init(12.5, 64.0, -3.25), &rand);
    slime.setSize(4);
    slime.animal.health = 9;
    slime.animal.yaw = 42.0;
    slime.animal.base.on_ground = true;

    const record = slime.toRecord();
    try std.testing.expectEqual(@as(i32, 3), record.size);
    try std.testing.expectEqual(@as(i16, 9), record.living.health);

    const restored = Slime.fromRecord(record);
    try std.testing.expectEqual(@as(u8, 4), restored.size);
    try std.testing.expectEqual(@as(i32, 16), restored.animal.health);
    try std.testing.expectApproxEqAbs(@as(f32, 42.0), restored.animal.yaw, 1.0e-6);
    try std.testing.expect(restored.animal.base.on_ground);
    try std.testing.expectApproxEqAbs(@as(f64, 12.5), restored.animal.base.position.x, 1.0e-9);
}

pub const wire_id: u8 = 55;
pub const watched_size: u5 = 16;

pub const mob_type: Mob.Type = .{
    .name = world.entity_nbt.slime_id,
    .wire_id = wire_id,
    .spawn = mobSpawn,
    .tick = mobTick,
    .takeDrops = mobTakeDrops,
    .store = mobStore,
    .load = mobLoad,
    .destroy = mobDestroy,
    .afterTick = mobAfterTick,
    .onDeath = mobOnDeath,
    .watch = mobWatch,
    .adopt = mobAdopt,
};

fn mobWatch(animal: *const Animal, out: *Mob.Watched) void {
    const self: *const Slime = @fieldParentPtr("animal", animal);
    out.add(watched_size, .{ .byte = @intCast(self.size) });
}

fn mobAdopt(animal: *Animal, metadata: Mob.Metadata) void {
    const self: *Slime = @fieldParentPtr("animal", animal);
    const size = metadata.byteAt(watched_size) orelse return;
    if (size <= 0) return;
    self.setSize(@intCast(size));
}

fn mobSpawn(gpa: std.mem.Allocator, position: math.Vec3, rand: *world.JavaRandom) anyerror!*Animal {
    const self = try gpa.create(Slime);
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
    const self: *Slime = @fieldParentPtr("animal", animal);
    try self.tick(gpa, world_map, players, rand);
}

fn mobTakeDrops(animal: *Animal) ?Mob.Drops {
    const self: *Slime = @fieldParentPtr("animal", animal);
    const drops = self.takeDrops() orelse return null;
    return .{ .count = drops.count, .stack = drops.stack() };
}

fn mobStore(animal: *Animal, gpa: std.mem.Allocator) anyerror!world.nbt.Tag {
    const self: *Slime = @fieldParentPtr("animal", animal);
    return world.entity_nbt.storeSlime(gpa, self.toRecord());
}

fn mobLoad(gpa: std.mem.Allocator, entity: world.nbt.Compound) anyerror!?*Animal {
    const record = world.entity_nbt.loadSlime(entity) orelse return null;
    const self = try gpa.create(Slime);
    self.* = Slime.fromRecord(record);
    return &self.animal;
}

fn mobDestroy(animal: *Animal, gpa: std.mem.Allocator) void {
    const self: *Slime = @fieldParentPtr("animal", animal);
    self.deinit(gpa);
    gpa.destroy(self);
}

fn mobAfterTick(animal: *Animal, tick_context: Mob.Tick) anyerror!void {
    const Entities = @import("../Entities.zig");
    const self: *Slime = @fieldParentPtr("animal", animal);
    const entities: *Entities = @ptrCast(@alignCast(tick_context.entities));

    if (self.landed) {
        try entities.spawnSlimeLandingParticles(tick_context.gpa, self.*, tick_context.rand);
        if (self.size > squish_land_size) {
            const rand = tick_context.rand;
            self.playSquish(
                tick_context.world_map,
                ((rand.nextFloat() - rand.nextFloat()) * 0.2 + 1.0) / squish_pitch_bend,
            );
        }
    }

    if (!self.animal.isAlive()) return;

    for (tick_context.roster) |player| {
        if (player.health <= 0) continue;

        const reach = player.base.boundingBox().expand(collide_reach, 0, collide_reach);
        if (!self.animal.base.boundingBox().intersects(reach)) continue;

        const view = tick_context.players.byId(player.base.id) orelse continue;
        if (self.attackDamage(tick_context.world_map, view)) |damage| {
            const absorbed = player.absorbsHit(damage);
            player.hurtFrom(tick_context.world_map, damage, self.animal.base.position);
            if (!absorbed) self.playAttack(tick_context.world_map, tick_context.rand);
        }
    }
}

fn mobOnDeath(animal: *Animal, tick_context: Mob.Tick) anyerror!void {
    const Entities = @import("../Entities.zig");
    const self: *Slime = @fieldParentPtr("animal", animal);
    if (!self.splitsApart()) return;

    const entities: *Entities = @ptrCast(@alignCast(tick_context.entities));
    for (0..split_count) |index| {
        const child = try entities.spawnMob(tick_context.gpa, Mob.slime, self.splitOffset(index), tick_context.rand);
        const born: *Slime = @fieldParentPtr("animal", child);
        born.setSize(self.size / 2);
        born.animal.faceYaw(tick_context.rand.nextFloat() * 360.0);
    }
}

pub const collide_reach: f64 = 1.0;

test "adopting a watched size resizes the slime, not just its label" {
    var rand: world.JavaRandom = .init(5);
    var big = spawn(math.Vec3.init(0, 0, 0), &rand);
    big.setSize(4);

    var watched: Mob.Watched = .{};
    Mob.watch(Mob.slime, &big.animal, &watched);

    var small = spawn(math.Vec3.init(0, 0, 0), &rand);
    small.setSize(1);
    Mob.adopt(Mob.slime, &small.animal, watched.view());

    try std.testing.expectEqual(@as(u8, 4), small.size);
    try std.testing.expectEqual(big.animal.base.width, small.animal.base.width);
}
