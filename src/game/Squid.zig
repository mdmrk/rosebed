const std = @import("std");
const float_pi: f32 = std.math.pi;

const math = @import("math");
const world = @import("world");

const Animal = @import("Animal.zig");
const Mob = @import("mob.zig");
const physics = @import("physics.zig");

const Squid = @This();

animal: Animal,
tilt: f32 = 0,
prev_tilt: f32 = 0,
spin: f32 = 0,
prev_spin: f32 = 0,
wave: f32 = 0,
prev_wave: f32 = 0,
tentacle_angle: f32 = 0,
prev_tentacle_angle: f32 = 0,
motion_speed: f32 = 0,
wave_speed: f32 = 0,
flap: f32 = 0,
drift: [3]f32 = .{ 0, 0, 0 },
pending_ink: u8 = 0,

pub const width: f64 = 0.95;
pub const height: f64 = 0.95;

pub const water_reach: f64 = -0.6;

const stroke_span: f32 = 0.75;
const stroke_decay: f32 = 0.8;
const glide_decay: f32 = 0.9;
const flap_decay: f32 = 0.99;
const tentacle_reach: f32 = float_pi * 0.25;
const turn_rate: f32 = 0.1;
const beached_pitch: f32 = -90.0;
const beached_turn: f64 = 0.02;
const beached_gravity: f64 = 0.08;
const beached_drag: f64 = 0.98;
const drift_reach: f32 = 0.2;
const drift_lift: f32 = 0.2;
const drift_sink: f32 = -0.1;
const course_roll: i32 = 50;
const wave_reroll: i32 = 10;

pub const spec: Animal.Spec = .{
    .width = width,
    .height = height,
    .movement = .drifting,
    .breathes_underwater = true,
    .hurt_sound = null,
    .death_sound = null,
    .sound_volume = 0.4,
    .talk_interval = Animal.passive_talk_interval,
};

fn init(position: math.Vec3) Squid {
    var squid: Squid = .{ .animal = Animal.spawn(position, spec) };
    squid.animal.on_death = dropFewItems;
    squid.animal.action_state = updateActionState;
    squid.animal.after_move = swim;
    return squid;
}

pub fn spawn(position: math.Vec3, rand: *world.JavaRandom) Squid {
    var squid = init(position);
    squid.wave_speed = nextWaveSpeed(rand);
    return squid;
}

pub fn deinit(self: *Squid, gpa: std.mem.Allocator) void {
    self.animal.deinit(gpa);
}

fn nextWaveSpeed(rand: *world.JavaRandom) f32 {
    return 1.0 / (rand.nextFloat() + 1.0) * 0.2;
}

pub fn tick(
    self: *Squid,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    players: Animal.Players,
    rand: *world.JavaRandom,
) !void {
    try self.animal.tick(gpa, world_map, players, rand);
}

pub fn isInWater(self: *Squid, world_map: *const world.World) bool {
    const box = self.animal.base.boundingBox().expand(0, water_reach, 0);
    const push = physics.handleWaterMovement(world_map, box) orelse return false;
    self.animal.base.motion = self.animal.base.motion.add(push);
    return true;
}

fn updateActionState(
    animal: *Animal,
    _: std.mem.Allocator,
    world_map: *const world.World,
    players: Animal.Players,
    rand: *world.JavaRandom,
) anyerror!void {
    const self: *Squid = @fieldParentPtr("animal", animal);

    const adrift = self.drift[0] == 0.0 and self.drift[1] == 0.0 and self.drift[2] == 0.0;
    if (rand.nextIntBound(course_roll) == 0 or !animal.base.in_water or adrift) {
        const heading = rand.nextFloat() * float_pi * 2.0;
        self.drift = .{
            math.util.cos(heading) * drift_reach,
            drift_sink + rand.nextFloat() * drift_lift,
            math.util.sin(heading) * drift_reach,
        };
    }

    animal.despawnCheck(players, rand);

    // Vanilla tests the water once more before it moves, and that test is what pushes
    // a squid along a current: the swim step below overwrites the motion it reads.
    _ = self.isInWater(world_map);
}

fn swim(animal: *Animal, world_map: *const world.World, rand: *world.JavaRandom) void {
    const self: *Squid = @fieldParentPtr("animal", animal);

    self.prev_tilt = self.tilt;
    self.prev_spin = self.spin;
    self.prev_wave = self.wave;
    self.prev_tentacle_angle = self.tentacle_angle;

    self.wave += self.wave_speed;
    if (self.wave > float_pi * 2.0) {
        self.wave -= float_pi * 2.0;
        if (rand.nextIntBound(wave_reroll) == 0) self.wave_speed = nextWaveSpeed(rand);
    }

    if (!self.isInWater(world_map)) {
        self.tentacle_angle = @abs(math.util.sin(self.wave)) * tentacle_reach;
        animal.base.motion.x = 0;
        animal.base.motion.y -= beached_gravity;
        animal.base.motion.y *= beached_drag;
        animal.base.motion.z = 0;
        self.tilt = @floatCast(@as(f64, self.tilt) + @as(f64, beached_pitch - self.tilt) * beached_turn);
        return;
    }

    if (self.wave < float_pi) {
        const stroke = self.wave / float_pi;
        self.tentacle_angle = math.util.sin(stroke * stroke * float_pi) * tentacle_reach;
        if (stroke > stroke_span) {
            self.motion_speed = 1.0;
            self.flap = 1.0;
        } else {
            self.flap *= stroke_decay;
        }
    } else {
        self.tentacle_angle = 0;
        self.motion_speed *= glide_decay;
        self.flap *= flap_decay;
    }

    animal.base.motion = math.Vec3.init(
        self.drift[0] * self.motion_speed,
        self.drift[1] * self.motion_speed,
        self.drift[2] * self.motion_speed,
    );

    const flat = math.util.sqrtF(
        animal.base.motion.x * animal.base.motion.x + animal.base.motion.z * animal.base.motion.z,
    );
    animal.render_yaw += (headingDegrees(animal.base.motion.x, animal.base.motion.z) - animal.render_yaw) * turn_rate;
    animal.yaw = animal.render_yaw;
    self.spin += float_pi * self.flap * 1.5;
    self.tilt += (headingDegrees(flat, animal.base.motion.y) - self.tilt) * turn_rate;
}

fn headingDegrees(x: f64, z: f64) f32 {
    return -@as(f32, @floatCast(std.math.atan2(x, z))) * 180.0 / float_pi;
}

pub fn canSpawnHere(self: Squid, world_map: *const world.World) bool {
    return !physics.isBoxObstructed(world_map, self.animal.base.boundingBox());
}

fn dropFewItems(animal: *Animal, rand: *world.JavaRandom) void {
    const self: *Squid = @fieldParentPtr("animal", animal);
    self.pending_ink = @intCast(rand.nextIntBound(3) + 1);
}

pub const Drops = struct {
    count: u8,

    pub fn stack(_: Drops) world.Stack {
        return .{ .id = .{ .item = .dye }, .count = 1, .meta = world.item.dye_meta_ink };
    }
};

pub fn takeDrops(self: *Squid) ?Drops {
    if (self.pending_ink == 0) return null;
    const drops: Drops = .{ .count = self.pending_ink };
    self.pending_ink = 0;
    return drops;
}

pub fn renderTilt(self: Squid, partial_ticks: f32) f32 {
    return self.prev_tilt + (self.tilt - self.prev_tilt) * partial_ticks;
}

pub fn renderSpin(self: Squid, partial_ticks: f32) f32 {
    return self.prev_spin + (self.spin - self.prev_spin) * partial_ticks;
}

pub fn renderTentacleAngle(self: Squid, partial_ticks: f32) f32 {
    return self.prev_tentacle_angle + (self.tentacle_angle - self.prev_tentacle_angle) * partial_ticks;
}

pub fn toRecord(self: Squid) world.entity_nbt.Squid {
    return .{ .living = self.animal.toRecord() };
}

pub fn fromRecord(record: world.entity_nbt.Squid) Squid {
    var squid = init(math.Vec3.init(
        record.living.position[0],
        record.living.position[1],
        record.living.position[2],
    ));
    squid.animal.restore(record.living);
    return squid;
}

pub const wire_id: u8 = 94;

pub const mob_type: Mob.Type = .{
    .name = world.entity_nbt.squid_id,
    .wire_id = wire_id,
    .spawn = mobSpawn,
    .tick = mobTick,
    .takeDrops = mobTakeDrops,
    .store = mobStore,
    .load = mobLoad,
    .destroy = mobDestroy,
};

fn mobSpawn(gpa: std.mem.Allocator, position: math.Vec3, rand: *world.JavaRandom) anyerror!*Animal {
    const self = try gpa.create(Squid);
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
    const self: *Squid = @fieldParentPtr("animal", animal);
    try self.tick(gpa, world_map, players, rand);
}

fn mobTakeDrops(animal: *Animal) ?Mob.Drops {
    const self: *Squid = @fieldParentPtr("animal", animal);
    const drops = self.takeDrops() orelse return null;
    return .{ .count = drops.count, .stack = drops.stack() };
}

fn mobStore(animal: *Animal, gpa: std.mem.Allocator) anyerror!world.nbt.Tag {
    const self: *Squid = @fieldParentPtr("animal", animal);
    return world.entity_nbt.storeSquid(gpa, self.toRecord());
}

fn mobLoad(gpa: std.mem.Allocator, entity: world.nbt.Compound) anyerror!?*Animal {
    const record = world.entity_nbt.loadSquid(entity) orelse return null;
    const self = try gpa.create(Squid);
    self.* = Squid.fromRecord(record);
    return &self.animal;
}

fn mobDestroy(animal: *Animal, gpa: std.mem.Allocator) void {
    const self: *Squid = @fieldParentPtr("animal", animal);
    self.deinit(gpa);
    gpa.destroy(self);
}

fn seaWorld(gpa: std.mem.Allocator, surface: u32) !world.World {
    var w = world.World.init(gpa);
    errdefer w.deinit();

    var chunk_x: i32 = -1;
    while (chunk_x <= 1) : (chunk_x += 1) {
        var chunk_z: i32 = -1;
        while (chunk_z <= 1) : (chunk_z += 1) {
            const chunk = try w.createChunk(chunk_x, chunk_z);
            for (0..world.Chunk.width) |x| {
                for (0..world.Chunk.width) |z| {
                    chunk.setBlock(@intCast(x), 0, @intCast(z), .stone);
                    var y: u32 = 1;
                    while (y <= surface) : (y += 1) {
                        chunk.setBlock(@intCast(x), y, @intCast(z), .stationary_water);
                    }
                }
            }
        }
    }
    return w;
}

test "a squid is the size EntitySquid sets itself to and drifts instead of walking" {
    var rand = world.JavaRandom.init(0);
    const squid = Squid.spawn(math.Vec3.init(0, 0, 0), &rand);

    try std.testing.expectEqual(@as(f64, 0.95), squid.animal.base.width);
    try std.testing.expectEqual(@as(f64, 0.95), squid.animal.base.height);
    try std.testing.expectEqual(Animal.Movement.drifting, squid.animal.movement);
    try std.testing.expect(squid.animal.breathes_underwater);
}

test "a squid never runs out of air however long it stays under" {
    const gpa = std.testing.allocator;
    var w = try seaWorld(gpa, 20);
    defer w.deinit();

    var rand = world.JavaRandom.init(3);
    var squid = Squid.spawn(math.Vec3.init(8.5, 10, 8.5), &rand);
    defer squid.deinit(gpa);

    for (0..400) |_| try squid.tick(gpa, &w, .{}, &rand);

    try std.testing.expectEqual(Animal.max_air, squid.animal.air);
    try std.testing.expectEqual(squid.animal.max_health, squid.animal.health);
}

test "the wave phase drives the tentacles and only a stroke pushes the squid along" {
    const gpa = std.testing.allocator;
    var w = try seaWorld(gpa, 20);
    defer w.deinit();

    var rand = world.JavaRandom.init(5);
    var squid = Squid.spawn(math.Vec3.init(8.5, 10, 8.5), &rand);
    defer squid.deinit(gpa);

    var widest: f32 = 0;
    var fastest: f64 = 0;
    for (0..200) |_| {
        try squid.tick(gpa, &w, .{}, &rand);
        widest = @max(widest, squid.tentacle_angle);
        fastest = @max(fastest, @abs(squid.animal.base.motion.x) + @abs(squid.animal.base.motion.z));
        try std.testing.expect(squid.wave >= 0.0 and squid.wave <= float_pi * 2.0);
        try std.testing.expect(squid.tentacle_angle <= tentacle_reach + 1.0e-6);
    }

    try std.testing.expect(widest > 0.0);
    try std.testing.expect(fastest > 0.0);
}

test "a squid out of water stops swimming, sinks and rolls onto its side" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var rand = world.JavaRandom.init(7);
    var squid = Squid.spawn(math.Vec3.init(8.5, 20, 8.5), &rand);
    defer squid.deinit(gpa);

    for (0..40) |_| {
        try squid.tick(gpa, &w, .{}, &rand);
        try std.testing.expectEqual(@as(f64, 0), squid.animal.base.motion.x);
        try std.testing.expectEqual(@as(f64, 0), squid.animal.base.motion.z);
    }

    try std.testing.expect(squid.animal.base.position.y < 20.0);
    try std.testing.expect(squid.tilt < 0.0 and squid.tilt > beached_pitch);
}

test "a dying squid drops one to three ink sacs" {
    for (0..20) |seed| {
        var rand = world.JavaRandom.init(@intCast(seed));
        var squid = Squid.spawn(math.Vec3.init(8, 1, 8), &rand);

        _ = squid.animal.hurt(squid.animal.max_health, null, &rand);
        try std.testing.expect(!squid.animal.isAlive());

        const drops = squid.takeDrops().?;
        try std.testing.expect(drops.count >= 1 and drops.count <= 3);
        try std.testing.expectEqual(world.Id{ .item = .dye }, drops.stack().id);
        try std.testing.expectEqual(world.item.dye_meta_ink, drops.stack().meta);
        try std.testing.expect(squid.takeDrops() == null);
    }
}

test "a squid keeps its wounds and its bearing across a record round trip" {
    const gpa = std.testing.allocator;

    var rand = world.JavaRandom.init(0);
    var squid = Squid.spawn(math.Vec3.init(12.5, 64.0, -3.25), &rand);
    squid.animal.health = 4;
    squid.animal.yaw = 42.0;

    var tag = try world.entity_nbt.storeSquid(gpa, squid.toRecord());
    defer world.nbt.deinit(gpa, &tag);

    const restored = Squid.fromRecord(world.entity_nbt.loadSquid(tag.compound).?);
    try std.testing.expectEqual(@as(i32, 4), restored.animal.health);
    try std.testing.expectEqual(@as(f32, 42.0), restored.animal.yaw);
    try std.testing.expectEqual(@as(f64, 12.5), restored.animal.base.position.x);
    try std.testing.expectEqual(@as(f64, -3.25), restored.animal.base.position.z);
    try std.testing.expectEqual(Animal.Movement.drifting, restored.animal.movement);
}
