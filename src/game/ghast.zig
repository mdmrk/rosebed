const std = @import("std");

const assets = @import("assets");
const math = @import("math");
const world = @import("world");

const Animal = @import("animal.zig");
const Mob = @import("mob.zig");
const physics = @import("physics.zig");
const raycast = @import("raycast.zig");

const Ghast = @This();

animal: Animal,
ticks_existed: i32 = 0,
course_change_cooldown: i32 = 0,
waypoint: math.Vec3 = math.Vec3.init(0, 0, 0),
targeted_player: ?Animal.Entity.Id = null,
aggro_cooldown: i32 = 0,
attack_counter: i32 = 0,
prev_attack_counter: i32 = 0,
pending_shot: ?Shot = null,
pending_drops: u8 = 0,

pub const width: f64 = 4.0;
pub const height: f64 = 4.0;
pub const max_spawned_in_chunk: u32 = 1;
pub const spawn_roll: i32 = 20;

pub const waypoint_reach: f64 = 16.0;
pub const waypoint_min: f64 = 1.0;
pub const waypoint_max: f64 = 60.0;
pub const course_speed: f64 = 0.1;
pub const sight_range: f64 = 100.0;
pub const attack_range: f64 = 64.0;
pub const aggro_ticks: i32 = 20;
pub const charge_at: i32 = 10;
pub const fire_at: i32 = 20;
pub const reload_at: i32 = -40;
pub const muzzle_reach: f64 = 4.0;
pub const muzzle_lift: f64 = 0.5;
pub const player_eye_height: f64 = 0.12;

pub const spec: Animal.Spec = .{
    .width = width,
    .height = height,
    .movement = .flying,
    .immune_to_fire = true,
    .takes_fall_damage = false,
    .living_sound = assets.sounds.mob.ghast.moan,
    .hurt_sound = assets.sounds.mob.ghast.scream,
    .death_sound = assets.sounds.mob.ghast.death,
    .sound_volume = 10.0,
};

pub const Shot = struct {
    from: math.Vec3,
    toward: math.Vec3,
};

fn init(position: math.Vec3) Ghast {
    var ghast: Ghast = .{ .animal = Animal.spawn(position, spec) };
    ghast.animal.on_death = dropFewItems;
    ghast.animal.action_state = updateActionState;
    return ghast;
}

pub fn spawn(position: math.Vec3) Ghast {
    return init(position);
}

pub fn deinit(self: *Ghast, gpa: std.mem.Allocator) void {
    self.animal.deinit(gpa);
}

pub fn isAttacking(self: Ghast) bool {
    return self.attack_counter > charge_at;
}

pub fn renderAge(self: Ghast, partial_ticks: f32) f32 {
    return @as(f32, @floatFromInt(self.ticks_existed)) + partial_ticks;
}

pub fn renderAttackCounter(self: Ghast, partial_ticks: f32) f32 {
    const prev: f32 = @floatFromInt(self.prev_attack_counter);
    const now: f32 = @floatFromInt(self.attack_counter);
    return prev + (now - prev) * partial_ticks;
}

pub fn takeShot(self: *Ghast) ?Shot {
    const shot = self.pending_shot orelse return null;
    self.pending_shot = null;
    return shot;
}

pub fn tick(
    self: *Ghast,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    players: Animal.Players,
    rand: *world.JavaRandom,
) !void {
    self.ticks_existed += 1;
    try self.animal.tick(gpa, world_map, players, rand);
}

fn updateActionState(
    animal: *Animal,
    _: std.mem.Allocator,
    world_map: *const world.World,
    players: Animal.Players,
    rand: *world.JavaRandom,
) anyerror!void {
    const self: *Ghast = @fieldParentPtr("animal", animal);
    const position = animal.base.position;

    animal.despawnCheck(players, rand);
    self.prev_attack_counter = self.attack_counter;

    const to_waypoint = [3]f64{
        self.waypoint.x - position.x,
        self.waypoint.y - position.y,
        self.waypoint.z - position.z,
    };
    const range: f64 = @as(f32, @floatCast(@sqrt(
        to_waypoint[0] * to_waypoint[0] + to_waypoint[1] * to_waypoint[1] + to_waypoint[2] * to_waypoint[2],
    )));

    if (range < waypoint_min or range > waypoint_max) {
        self.waypoint = math.Vec3.init(
            position.x + @as(f64, (rand.nextFloat() * 2.0 - 1.0) * waypoint_reach),
            position.y + @as(f64, (rand.nextFloat() * 2.0 - 1.0) * waypoint_reach),
            position.z + @as(f64, (rand.nextFloat() * 2.0 - 1.0) * waypoint_reach),
        );
    }

    const course_was_due = self.course_change_cooldown <= 0;
    self.course_change_cooldown -= 1;
    if (course_was_due) {
        self.course_change_cooldown += rand.nextIntBound(5) + 2;
        if (self.isCourseTraversable(world_map, range)) {
            animal.base.motion.x += to_waypoint[0] / range * course_speed;
            animal.base.motion.y += to_waypoint[1] / range * course_speed;
            animal.base.motion.z += to_waypoint[2] / range * course_speed;
        } else {
            self.waypoint = position;
        }
    }

    var target = if (self.targeted_player) |id| players.byId(id) else null;
    if (target != null and !target.?.alive) {
        self.targeted_player = null;
        target = null;
    }

    var reacquire = target == null;
    if (!reacquire) {
        reacquire = self.aggro_cooldown <= 0;
        self.aggro_cooldown -= 1;
    }
    if (reacquire) {
        target = players.closestTo(position, sight_range);
        self.targeted_player = if (target) |view| view.id else null;
        if (target != null) self.aggro_cooldown = aggro_ticks;
    }

    const in_range = if (target) |view|
        animal.distanceSquaredTo(view.position) < attack_range * attack_range
    else
        false;

    if (!in_range) {
        self.face(headingYaw(animal.base.motion.x, animal.base.motion.z));
        if (self.attack_counter > 0) self.attack_counter -= 1;
        return;
    }

    const view = target.?;
    const aim = math.Vec3.init(
        view.position.x - position.x,
        view.position.y + view.height / 2.0 - (position.y + height / 2.0),
        view.position.z - position.z,
    );
    self.face(headingYaw(aim.x, aim.z));

    if (!self.canSee(world_map, view)) {
        if (self.attack_counter > 0) self.attack_counter -= 1;
        return;
    }

    if (self.attack_counter == charge_at) {
        animal.playSound(world_map, assets.sounds.mob.ghast.charge, rand);
    }

    self.attack_counter += 1;
    if (self.attack_counter != fire_at) return;

    animal.playSound(world_map, assets.sounds.mob.ghast.fireball, rand);

    const look = lookVector(animal.yaw, animal.pitch);
    self.pending_shot = .{
        .from = math.Vec3.init(
            position.x + look.x * muzzle_reach,
            position.y + height / 2.0 + muzzle_lift,
            position.z + look.z * muzzle_reach,
        ),
        .toward = aim,
    };
    self.attack_counter = reload_at;
}

fn face(self: *Ghast, yaw: f32) void {
    self.animal.yaw = yaw;
    self.animal.render_yaw = yaw;
}

fn headingYaw(x: f64, z: f64) f32 {
    const float_pi: f64 = @as(f32, std.math.pi);
    return @floatCast(-std.math.atan2(x, z) * 180.0 / float_pi);
}

fn lookVector(yaw: f32, pitch: f32) math.Vec3 {
    const degrees: f32 = std.math.pi / 180.0;
    const cos_yaw = math.util.cos(-yaw * degrees - std.math.pi);
    const sin_yaw = math.util.sin(-yaw * degrees - std.math.pi);
    const cos_pitch = -math.util.cos(-pitch * degrees);
    const sin_pitch = math.util.sin(-pitch * degrees);
    return math.Vec3.init(sin_yaw * cos_pitch, sin_pitch, cos_yaw * cos_pitch);
}

fn isCourseTraversable(self: Ghast, world_map: *const world.World, range: f64) bool {
    const position = self.animal.base.position;
    const step_x = (self.waypoint.x - position.x) / range;
    const step_y = (self.waypoint.y - position.y) / range;
    const step_z = (self.waypoint.z - position.z) / range;

    var box = self.animal.base.boundingBox();
    var step: i32 = 1;
    while (@as(f64, @floatFromInt(step)) < range) : (step += 1) {
        box = box.offset(step_x, step_y, step_z);
        if (physics.isBoxObstructed(world_map, box)) return false;
    }
    return true;
}

fn canSee(self: Ghast, world_map: *const world.World, view: Animal.PlayerView) bool {
    const eye = math.Vec3.init(
        self.animal.base.position.x,
        self.animal.base.position.y + self.animal.eyeHeight(),
        self.animal.base.position.z,
    );
    const sight = [3]f64{
        view.position.x - eye.x,
        view.position.y + player_eye_height - eye.y,
        view.position.z - eye.z,
    };
    const reach = @sqrt(sight[0] * sight[0] + sight[1] * sight[1] + sight[2] * sight[2]);
    if (reach == 0.0) return true;

    const along = [3]f64{ sight[0] / reach, sight[1] / reach, sight[2] / reach };
    return raycast.castBlocks(world_map, eye, along, reach) == null;
}

pub fn canSpawnHere(self: Ghast, world_map: *const world.World, rand: *world.JavaRandom) bool {
    if (rand.nextIntBound(spawn_roll) != 0) return false;

    const box = self.animal.base.boundingBox();
    return !physics.isBoxObstructed(world_map, box) and !physics.isAnyLiquid(world_map, box);
}

fn dropFewItems(animal: *Animal, rand: *world.JavaRandom) void {
    const self: *Ghast = @fieldParentPtr("animal", animal);
    self.pending_drops = @intCast(rand.nextIntBound(3));
}

pub const Drops = struct {
    count: u8,

    pub fn stack(_: Drops) world.Stack {
        return .{ .id = .{ .item = .gunpowder }, .count = 1 };
    }
};

pub fn takeDrops(self: *Ghast) ?Drops {
    if (self.pending_drops == 0) return null;
    const drops: Drops = .{ .count = self.pending_drops };
    self.pending_drops = 0;
    return drops;
}

pub fn attackScale(self: Ghast, partial_ticks: f32) [3]f32 {
    const counter = @as(f32, @floatFromInt(self.prev_attack_counter)) +
        @as(f32, @floatFromInt(self.attack_counter - self.prev_attack_counter)) * partial_ticks;

    var charge = @max(counter / 20.0, 0.0);
    charge = 1.0 / (charge * charge * charge * charge * charge * 2.0 + 1.0);

    const tall = (8.0 + charge) / 2.0;
    const wide = (8.0 + 1.0 / charge) / 2.0;
    return .{ wide, tall, wide };
}

pub fn toRecord(self: Ghast) world.entity_nbt.Ghast {
    return .{ .living = self.animal.toRecord() };
}

pub fn fromRecord(record: world.entity_nbt.Ghast) Ghast {
    var ghast = init(math.Vec3.init(
        record.living.position[0],
        record.living.position[1],
        record.living.position[2],
    ));
    ghast.animal.restore(record.living);
    return ghast;
}

pub const wire_id: u8 = 56;
pub const watched_attacking: u5 = 16;

pub const mob_type: Mob.Type = .{
    .name = world.entity_nbt.ghast_id,
    .wire_id = wire_id,
    .spawn = mobSpawn,
    .tick = mobTick,
    .takeDrops = mobTakeDrops,
    .store = mobStore,
    .load = mobLoad,
    .destroy = mobDestroy,
    .afterTick = mobAfterTick,
    .watch = mobWatch,
    .adopt = mobAdopt,
};

fn mobAfterTick(animal: *Animal, tick_context: Mob.Tick) anyerror!void {
    const Entities = @import("entities.zig");
    const self: *Ghast = @fieldParentPtr("animal", animal);
    const shot = self.takeShot() orelse return;

    const entities: *Entities = @ptrCast(@alignCast(tick_context.entities));
    try entities.shootFireball(tick_context.gpa, animal.base.id, shot, tick_context.rand);
}

fn mobWatch(animal: *const Animal, out: *Mob.Watched) void {
    const self: *const Ghast = @fieldParentPtr("animal", animal);
    out.add(watched_attacking, .{ .byte = @intFromBool(self.isAttacking()) });
}

fn mobAdopt(animal: *Animal, metadata: Mob.Metadata) void {
    const self: *Ghast = @fieldParentPtr("animal", animal);
    const attacking = metadata.byteAt(watched_attacking) orelse return;
    self.attack_counter = if (attacking != 0) charge_at + 1 else 0;
    self.prev_attack_counter = self.attack_counter;
}

fn mobSpawn(gpa: std.mem.Allocator, position: math.Vec3, _: *world.JavaRandom) anyerror!*Animal {
    const self = try gpa.create(Ghast);
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
    const self: *Ghast = @fieldParentPtr("animal", animal);
    try self.tick(gpa, world_map, players, rand);
}

fn mobTakeDrops(animal: *Animal) ?Mob.Drops {
    const self: *Ghast = @fieldParentPtr("animal", animal);
    const drops = self.takeDrops() orelse return null;
    return .{ .count = drops.count, .stack = drops.stack() };
}

fn mobStore(animal: *Animal, gpa: std.mem.Allocator) anyerror!world.nbt.Tag {
    const self: *Ghast = @fieldParentPtr("animal", animal);
    return world.entity_nbt.storeGhast(gpa, self.toRecord());
}

fn mobLoad(gpa: std.mem.Allocator, entity: world.nbt.Compound) anyerror!?*Animal {
    const record = world.entity_nbt.loadGhast(entity) orelse return null;
    const self = try gpa.create(Ghast);
    self.* = Ghast.fromRecord(record);
    return &self.animal;
}

fn mobDestroy(animal: *Animal, gpa: std.mem.Allocator) void {
    const self: *Ghast = @fieldParentPtr("animal", animal);
    self.deinit(gpa);
    gpa.destroy(self);
}
