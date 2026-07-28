const std = @import("std");

const math = @import("math");
const world = @import("world");

const Animal = @import("animal.zig");
const raycast = @import("raycast.zig");

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

pub fn specFor(size: u8) Animal.Spec {
    const extent = size_scale * @as(f64, @floatFromInt(size));
    return .{
        .width = extent,
        .height = extent,
        .max_health = @as(i32, size) * @as(i32, size),
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
    player: ?Animal.PlayerView,
    rand: *world.JavaRandom,
) !void {
    self.prev_squish = self.squish;
    const was_on_ground = self.animal.base.on_ground;

    try self.animal.tick(gpa, world_map, player, rand);

    self.landed = self.animal.base.on_ground and !was_on_ground;
    if (self.landed) self.squish = landing_squish;
    self.squish *= squish_decay;
}

fn playerPosition(view: Animal.PlayerView) math.Vec3 {
    return .{
        .x = view.position.x,
        .y = view.position.y + view.eye_height,
        .z = view.position.z,
    };
}

fn distanceSquaredTo(self: Slime, target: math.Vec3) f64 {
    const dx = target.x - self.animal.base.position.x;
    const dy = target.y - self.animal.base.position.y;
    const dz = target.z - self.animal.base.position.z;
    return dx * dx + dy * dy + dz * dz;
}

fn closestPlayer(self: Slime, player: ?Animal.PlayerView, range: f64) ?Animal.PlayerView {
    const view = player orelse return null;
    if (self.distanceSquaredTo(playerPosition(view)) >= range * range) return null;
    return view;
}

fn updateActionState(
    animal: *Animal,
    _: std.mem.Allocator,
    _: *const world.World,
    player: ?Animal.PlayerView,
    rand: *world.JavaRandom,
) anyerror!void {
    const self: *Slime = @fieldParentPtr("animal", animal);

    animal.despawnCheck(player, rand);

    const target = self.closestPlayer(player, sight_range);
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
    const to_player = [3]f64{ sight.x - eye.x, sight.y + player_sight_height - eye.y, sight.z - eye.z };
    const reach = @sqrt(to_player[0] * to_player[0] + to_player[1] * to_player[1] + to_player[2] * to_player[2]);
    if (reach == 0.0) return true;

    const along = [3]f64{ to_player[0] / reach, to_player[1] / reach, to_player[2] / reach };
    return raycast.castCollision(world_map, eye, along, reach) == null;
}

pub fn attackDamage(self: Slime, world_map: *const world.World, view: Animal.PlayerView) ?i32 {
    if (self.size <= 1) return null;
    if (!self.canSeePlayer(world_map, view)) return null;

    const reach = size_scale * @as(f64, @floatFromInt(self.size));
    if (self.distanceSquaredTo(playerPosition(view)) >= reach * reach) return null;

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

pub fn canSpawnHere(self: Slime, world_seed: i64, rand: *world.JavaRandom) bool {
    if (rand.nextIntBound(10) != 0) return false;

    const chunk_x = @divFloor(math.util.floorDouble(self.animal.base.position.x), world.constants.chunk_width);
    const chunk_z = @divFloor(math.util.floorDouble(self.animal.base.position.z), world.constants.chunk_width);
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
    var slime = init(math.Vec3.init(
        record.living.position[0],
        record.living.position[1],
        record.living.position[2],
    ), size);
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
    var rand = world.JavaRandom.init(0);

    var big = Slime.spawn(math.Vec3.init(8, 1, 8), &rand);
    big.setSize(4);
    _ = big.animal.hurt(big.animal.max_health, null, &rand);
    try std.testing.expect(big.takeDrops() == null);

    var dropped_nothing = false;
    var dropped_something = false;
    for (0..20) |seed| {
        var seeded = world.JavaRandom.init(@intCast(seed));
        var small = Slime.spawn(math.Vec3.init(8, 1, 8), &seeded);
        small.setSize(1);

        _ = small.animal.hurt(small.animal.max_health, null, &seeded);
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
    var rand = world.JavaRandom.init(0);

    var halved = Slime.spawn(math.Vec3.init(8, 1, 8), &rand);
    halved.setSize(2);
    _ = halved.animal.hurt(4, null, &rand);
    try std.testing.expectEqual(@as(i32, 0), halved.animal.health);
    try std.testing.expect(halved.splitsApart());

    var overkilled = Slime.spawn(math.Vec3.init(8, 1, 8), &rand);
    overkilled.setSize(2);
    _ = overkilled.animal.hurt(9, null, &rand);
    try std.testing.expect(overkilled.animal.health < 0);
    try std.testing.expect(!overkilled.splitsApart());

    var smallest = Slime.spawn(math.Vec3.init(8, 1, 8), &rand);
    smallest.setSize(1);
    _ = smallest.animal.hurt(1, null, &rand);
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
            for (0..world.constants.chunk_width) |x| {
                for (0..world.constants.chunk_width) |z| {
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
        try slime.tick(gpa, &w, null, &rand);
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
        try alone.tick(gpa, &w, null, &alone_rand);
        try watched.tick(gpa, &w, nearby, &watched_rand);
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
    for (0..40) |_| try slime.tick(gpa, &w, nearby, &rand);

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
    while (y <= 3) : (y += 1) w.setBlock(9, @intCast(y), 8, .stone);
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
    var rand = world.JavaRandom.init(0);

    var high = Slime.spawn(math.Vec3.init(8.5, 40, 8.5), &rand);
    high.setSize(1);

    var allowed = false;
    for (0..400) |_| {
        if (high.canSpawnHere(1, &rand)) allowed = true;
    }
    try std.testing.expect(!allowed);

    var chunks_allowing: u32 = 0;
    for (0..200) |chunk| {
        const x: f64 = @floatFromInt(chunk * 16);
        var low = Slime.spawn(math.Vec3.init(x + 8.5, 8, 8.5), &rand);
        low.setSize(1);

        var attempts: u32 = 0;
        while (attempts < 200) : (attempts += 1) {
            if (low.canSpawnHere(1, &rand)) {
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
