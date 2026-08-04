const std = @import("std");

const math = @import("math");
const world = @import("world");
const testing_world = world.testing;

pub const Entity = @import("entity.zig");
const physics = @import("physics.zig");

const Animal = @This();

base: Entity,
max_health: i32,
takes_fall_damage: bool = true,
move_speed: f32 = default_move_speed,
eye_fraction: f64 = eye_height_fraction,
look_pitch_speed: f32 = default_look_pitch_speed,
can_despawn: bool = true,
yaw: f32 = 0,
prev_yaw: f32 = 0,
pitch: f32 = 0,
prev_pitch: f32 = 0,
render_yaw: f32 = 0,
prev_render_yaw: f32 = 0,
limb_swing: f32 = 0,
limb_swing_amount: f32 = 0,
prev_limb_swing_amount: f32 = 0,
health: i32,
hurt_time: i32 = 0,
hurt_resistance: i32 = 0,
last_damage: i32 = 0,
death_time: i32 = 0,
attacked_at_yaw: f32 = 0,
air: i32 = max_air,
fire: i32 = 0,
fall_distance: f32 = 0,
entity_age: i32 = 0,
move_strafing: f32 = 0,
move_forward: f32 = 0,
random_yaw_velocity: f32 = 0,
is_jumping: bool = false,
in_lava: bool = false,
drowned: bool = false,
dead: bool = false,
look_ticks_left: i32 = 0,
watched_player: ?Entity.Id = null,
path: ?world.pathfinder.Path = null,
on_death: *const fn (*Animal, *world.JavaRandom) void = leaveNothing,
action_state: *const fn (
    *Animal,
    std.mem.Allocator,
    *const world.World,
    Players,
    *world.JavaRandom,
) anyerror!void = updateActionState,

pub const Spec = struct {
    width: f64,
    height: f64,
    max_health: i32 = default_max_health,
    step_height: f64 = default_step_height,
    takes_fall_damage: bool = true,
    move_speed: f32 = default_move_speed,
    eye_fraction: f64 = eye_height_fraction,
};

pub const default_max_health: i32 = 10;
pub const default_step_height: f64 = 0.5;
pub const max_air: i32 = 300;
pub const eye_height_fraction: f64 = 0.85;
pub const hurt_resistance_ticks: i32 = 20;
pub const death_ticks: i32 = 20;
pub const default_move_speed: f32 = 0.7;
pub const default_look_pitch_speed: f32 = 40.0;
pub const chase_path_range: f32 = 16.0;

const wander_radius: f32 = 10.0;
const gravity: f64 = 0.08;
const vertical_drag: f64 = 0.98;
const air_friction: f64 = 0.91;
const ground_friction: f64 = 0.6 * 0.91;
const ground_acceleration: f32 = 0.1;
const air_acceleration: f32 = 0.02;
const liquid_acceleration: f32 = 0.02;
const water_drag: f64 = 0.8;
const lava_drag: f64 = 0.5;
const liquid_gravity: f64 = 0.02;
const liquid_climb_out: f64 = 0.3;
const liquid_paddle: f64 = 0.04;
const jump_velocity: f64 = 0.42;

const look_range: f64 = 8.0;
const despawn_distance_squared: f64 = 16384.0;
const forget_distance_squared: f64 = 1024.0;
const persistent_age: i32 = 600;

const drown_damage: i32 = 2;
const suffocation_damage: i32 = 1;
const burn_damage: i32 = 1;
const lava_damage: i32 = 4;
const void_damage: i32 = 4;
const lava_fire_ticks: i32 = 600;
const void_floor: f64 = -64.0;
const safe_fall_distance: f32 = 3.0;
const knockback_strength: f64 = 0.4;

pub const PlayerView = struct {
    id: Entity.Id = Entity.no_id,
    position: math.Vec3,
    eye_height: f64,
    alive: bool,
    height: f64 = 1.8,
    held: ?world.Item = null,
    name: []const u8 = "",
};

pub const Attacker = struct {
    position: math.Vec3,
    player: Entity.Id = Entity.no_id,
};

pub const Players = struct {
    views: []const PlayerView = &.{},

    pub fn of(views: []const PlayerView) Players {
        return .{ .views = views };
    }

    pub fn one(view: *const PlayerView) Players {
        return .{ .views = view[0..1] };
    }

    pub fn closestTo(self: Players, position: math.Vec3, range: f64) ?PlayerView {
        var nearest: ?PlayerView = null;
        var nearest_distance: f64 = -1.0;
        for (self.views) |view| {
            const dx = view.position.x - position.x;
            const dy = view.position.y - position.y;
            const dz = view.position.z - position.z;
            const distance = dx * dx + dy * dy + dz * dz;
            if ((range < 0.0 or distance < range * range) and
                (nearest_distance == -1.0 or distance < nearest_distance))
            {
                nearest_distance = distance;
                nearest = view;
            }
        }
        return nearest;
    }

    pub fn byId(self: Players, id: Entity.Id) ?PlayerView {
        for (self.views) |view| {
            if (view.id == id) return view;
        }
        return null;
    }

    pub fn byName(self: Players, name: []const u8) ?PlayerView {
        if (name.len == 0) return null;
        for (self.views) |view| {
            if (std.mem.eql(u8, view.name, name)) return view;
        }
        return null;
    }
};

fn leaveNothing(_: *Animal, _: *world.JavaRandom) void {}

pub fn spawn(position: math.Vec3, spec: Spec) Animal {
    var base = Entity.init(position, spec.width, spec.height);
    base.step_height = spec.step_height;
    return .{
        .base = base,
        .max_health = spec.max_health,
        .health = spec.max_health,
        .takes_fall_damage = spec.takes_fall_damage,
        .move_speed = spec.move_speed,
        .eye_fraction = spec.eye_fraction,
    };
}

pub fn deinit(self: *Animal, gpa: std.mem.Allocator) void {
    self.clearPath(gpa);
}

pub fn faceYaw(self: *Animal, yaw: f32) void {
    self.yaw = yaw;
    self.prev_yaw = yaw;
    self.render_yaw = yaw;
    self.prev_render_yaw = yaw;
}

pub fn isAlive(self: Animal) bool {
    return !self.dead and self.health > 0;
}

pub fn eyeHeight(self: Animal) f64 {
    return self.base.height * self.eye_fraction;
}

pub fn clearPath(self: *Animal, gpa: std.mem.Allocator) void {
    if (self.path) |*path| path.deinit(gpa);
    self.path = null;
}

pub fn setPath(self: *Animal, gpa: std.mem.Allocator, found: ?world.pathfinder.Path) void {
    self.clearPath(gpa);
    self.path = found;
}

pub fn pathTowards(
    self: *Animal,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    target: math.Vec3,
    range: f32,
) !void {
    const found = try world.pathfinder.toPosition(gpa, world_map, self.pathMob(), target.x, target.y, target.z, range);
    self.setPath(gpa, found);
}

pub fn pathMob(self: Animal) world.pathfinder.Mob {
    const box = self.base.boundingBox();
    return .{
        .min_x = box.min_x,
        .min_y = box.min_y,
        .min_z = box.min_z,
        .width = @floatCast(self.base.width),
        .height = @floatCast(self.base.height),
    };
}

fn wrapDegrees(value: f32) f32 {
    var wrapped = value;
    while (wrapped < -180.0) wrapped += 360.0;
    while (wrapped >= 180.0) wrapped -= 360.0;
    return wrapped;
}

fn eyePosition(self: Animal) math.Vec3 {
    return .{
        .x = self.base.position.x,
        .y = self.base.position.y + self.eyeHeight(),
        .z = self.base.position.z,
    };
}

pub fn distanceSquaredTo(self: Animal, position: math.Vec3) f64 {
    const dx = position.x - self.base.position.x;
    const dy = position.y - self.base.position.y;
    const dz = position.z - self.base.position.z;
    return dx * dx + dy * dy + dz * dz;
}

fn isInsideOpaqueBlock(self: Animal, world_map: *const world.World) bool {
    for (0..8) |corner| {
        const index: i32 = @intCast(corner);
        const dx = (@as(f64, @floatFromInt(@rem(index, 2))) - 0.5) * self.base.width * 0.9;
        const dy = (@as(f64, @floatFromInt(@rem(@divTrunc(index, 2), 2))) - 0.5) * 0.1;
        const dz = (@as(f64, @floatFromInt(@rem(@divTrunc(index, 4), 2))) - 0.5) * self.base.width * 0.9;
        const x = math.util.floorDouble(self.base.position.x + dx);
        const y = math.util.floorDouble(self.base.position.y + self.eyeHeight() + dy);
        const z = math.util.floorDouble(self.base.position.z + dz);
        if (world_map.getBlock(x, y, z).isOpaqueCube()) return true;
    }
    return false;
}

pub fn blockPathWeight(world_map: *const world.World, x: i32, y: i32, z: i32) f32 {
    if (world_map.getBlock(x, y - 1, z) == .grass) return 10.0;
    return world.light.brightnessAt(world_map, x, y, z, 0) - 0.5;
}

pub fn canSpawnHere(self: Animal, world_map: *const world.World) bool {
    const box = self.base.boundingBox();
    const x = math.util.floorDouble(self.base.position.x);
    const y = math.util.floorDouble(box.min_y);
    const z = math.util.floorDouble(self.base.position.z);

    if (world_map.getBlock(x, y - 1, z) != .grass) return false;
    if (@max(world_map.getSkyLight(x, y, z), world_map.getBlockLight(x, y, z)) <= 8) return false;
    if (blockPathWeight(world_map, x, y, z) < 0.0) return false;

    return !physics.isBoxObstructed(world_map, box) and !physics.isAnyLiquid(world_map, box);
}

pub fn hurt(self: *Animal, amount: i32, source: ?Attacker, rand: *world.JavaRandom) bool {
    self.entity_age = 0;
    if (self.health <= 0) return false;

    self.limb_swing_amount = 1.5;
    var reacts = true;

    if (self.hurt_resistance > @divTrunc(hurt_resistance_ticks, 2)) {
        if (amount <= self.last_damage) return false;
        self.health -= amount - self.last_damage;
        self.last_damage = amount;
        reacts = false;
    } else {
        self.last_damage = amount;
        self.hurt_resistance = hurt_resistance_ticks;
        self.health -= amount;
        self.hurt_time = 10;
    }

    self.attacked_at_yaw = 0;
    if (reacts) {
        if (source) |from| {
            var dx = from.position.x - self.base.position.x;
            var dz = from.position.z - self.base.position.z;
            while (dx * dx + dz * dz < 1.0e-4) {
                dx = (rand.nextDouble() - rand.nextDouble()) * 0.01;
                dz = (rand.nextDouble() - rand.nextDouble()) * 0.01;
            }
            self.attacked_at_yaw = @as(f32, @floatCast(std.math.atan2(dz, dx) * 180.0 / std.math.pi)) - self.yaw;
            self.knockBack(dx, dz);
        } else {
            self.attacked_at_yaw = @floatFromInt(@as(i32, @intFromFloat(rand.nextDouble() * 2.0)) * 180);
        }
    }

    if (self.health <= 0) self.on_death(self, rand);
    return true;
}

fn knockBack(self: *Animal, dx: f64, dz: f64) void {
    const distance = @sqrt(dx * dx + dz * dz);
    self.base.motion.x /= 2.0;
    self.base.motion.y /= 2.0;
    self.base.motion.z /= 2.0;
    self.base.motion.x -= dx / distance * knockback_strength;
    self.base.motion.y += knockback_strength;
    self.base.motion.z -= dz / distance * knockback_strength;
    if (self.base.motion.y > knockback_strength) self.base.motion.y = knockback_strength;
}

fn fall(self: *Animal, distance: f32, rand: *world.JavaRandom) void {
    if (!self.takes_fall_damage) return;
    const damage: i32 = @intFromFloat(@ceil(distance - safe_fall_distance));
    if (damage > 0) _ = self.hurt(damage, null, rand);
}

fn updateFallState(self: *Animal, dy: f64, rand: *world.JavaRandom) void {
    if (self.base.on_ground) {
        if (self.fall_distance > 0.0) {
            self.fall(self.fall_distance, rand);
            self.fall_distance = 0.0;
        }
    } else if (dy < 0.0) {
        self.fall_distance -= @floatCast(dy);
    }
}

fn moveFlying(self: *Animal, strafe: f32, forward: f32, acceleration: f32) void {
    var scale = @sqrt(strafe * strafe + forward * forward);
    if (scale < 0.01) return;
    if (scale < 1.0) scale = 1.0;
    scale = acceleration / scale;

    const sideways = strafe * scale;
    const ahead = forward * scale;
    const sin = math.util.sin(self.yaw * std.math.pi / 180.0);
    const cos = math.util.cos(self.yaw * std.math.pi / 180.0);

    self.base.motion.x += @as(f64, sideways * cos - ahead * sin);
    self.base.motion.z += @as(f64, ahead * cos + sideways * sin);
}

fn moveWithHeading(self: *Animal, world_map: *const world.World, strafe: f32, forward: f32, rand: *world.JavaRandom) void {
    const was_on_ground = self.base.on_ground;
    const before_y = self.base.position.y;

    if (self.base.in_water or self.in_lava) {
        const drag: f64 = if (self.base.in_water) water_drag else lava_drag;
        self.moveFlying(strafe, forward, liquid_acceleration);
        const moved = self.base.move(world_map);
        self.updateFallState(moved.dy, rand);

        self.base.motion.x *= drag;
        self.base.motion.y *= drag;
        self.base.motion.z *= drag;
        self.base.motion.y -= liquid_gravity;

        const climb = self.base.motion.y + 0.6 - self.base.position.y + before_y;
        if ((moved.blocked_x or moved.blocked_z) and
            self.base.isOffsetPositionInLiquid(world_map, self.base.motion.x, climb, self.base.motion.z))
        {
            self.base.motion.y = liquid_climb_out;
        }
    } else {
        self.moveFlying(strafe, forward, if (was_on_ground) ground_acceleration else air_acceleration);
        const moved = self.base.move(world_map);
        self.updateFallState(moved.dy, rand);

        self.base.motion.y -= gravity;
        self.base.motion.y *= vertical_drag;
        const friction: f64 = if (was_on_ground) ground_friction else air_friction;
        self.base.motion.x *= friction;
        self.base.motion.z *= friction;
    }

    self.prev_limb_swing_amount = self.limb_swing_amount;
    const dx = self.base.position.x - self.base.prev_position.x;
    const dz = self.base.position.z - self.base.prev_position.z;
    var swing: f32 = @floatCast(@sqrt(dx * dx + dz * dz) * 4.0);
    if (swing > 1.0) swing = 1.0;
    self.limb_swing_amount += (swing - self.limb_swing_amount) * 0.4;
    self.limb_swing += self.limb_swing_amount;
}

pub fn faceEntity(self: *Animal, target: math.Vec3, target_eye_height: f64, yaw_speed: f32, pitch_speed: f32) void {
    const dx = target.x - self.base.position.x;
    const dz = target.z - self.base.position.z;
    const dy = (self.base.position.y + self.eyeHeight()) - (target.y + target_eye_height);
    const flat = @sqrt(dx * dx + dz * dz);

    const target_yaw = @as(f32, @floatCast(std.math.atan2(dz, dx) * 180.0 / std.math.pi)) - 90.0;
    const target_pitch = @as(f32, @floatCast(-(std.math.atan2(dy, flat) * 180.0 / std.math.pi)));

    self.pitch = -turnTowards(self.pitch, target_pitch, pitch_speed);
    self.yaw = turnTowards(self.yaw, target_yaw, yaw_speed);
}

fn turnTowards(current: f32, target: f32, limit: f32) f32 {
    return current + std.math.clamp(wrapDegrees(target - current), -limit, limit);
}

pub fn despawnCheck(self: *Animal, players: Players, rand: *world.JavaRandom) void {
    if (!self.can_despawn) return;
    const view = players.closestTo(self.base.position, -1.0) orelse return;
    const distance_squared = self.distanceSquaredTo(view.position);

    if (distance_squared > despawn_distance_squared) self.dead = true;

    if (self.entity_age > persistent_age and rand.nextIntBound(800) == 0) {
        if (distance_squared < forget_distance_squared) {
            self.entity_age = 0;
        } else {
            self.dead = true;
        }
    }
}

pub fn idleActionState(self: *Animal, players: Players, rand: *world.JavaRandom) void {
    self.entity_age += 1;
    self.despawnCheck(players, rand);
    self.move_strafing = 0;
    self.move_forward = 0;

    if (rand.nextFloat() < 0.02) {
        const nearby = players.closestTo(self.base.position, look_range);
        if (nearby != null and nearby.?.alive) {
            self.watched_player = nearby.?.id;
            self.look_ticks_left = 10 + rand.nextIntBound(20);
        } else {
            self.random_yaw_velocity = (rand.nextFloat() - 0.5) * 20.0;
        }
    }

    const watched = if (self.watched_player) |id| players.byId(id) else null;
    if (watched) |view| {
        self.faceEntity(view.position, view.eye_height, 10.0, self.look_pitch_speed);
        self.look_ticks_left -= 1;
        if (self.look_ticks_left < 0 or !view.alive or
            self.distanceSquaredTo(view.position) > look_range * look_range)
        {
            self.watched_player = null;
        }
    } else {
        self.watched_player = null;
        if (rand.nextFloat() < 0.05) self.random_yaw_velocity = (rand.nextFloat() - 0.5) * 20.0;
        self.yaw += self.random_yaw_velocity;
        self.pitch = 0;
    }

    if (self.base.in_water or self.in_lava) self.is_jumping = rand.nextFloat() < 0.8;
}

pub fn findWanderPath(self: *Animal, gpa: std.mem.Allocator, world_map: *const world.World, rand: *world.JavaRandom) !void {
    var best_weight: f32 = -99999.0;
    var best: ?[3]i32 = null;

    for (0..10) |_| {
        const x = math.util.floorDouble(self.base.position.x + @as(f64, @floatFromInt(rand.nextIntBound(13))) - 6.0);
        const y = math.util.floorDouble(self.base.position.y + @as(f64, @floatFromInt(rand.nextIntBound(7))) - 3.0);
        const z = math.util.floorDouble(self.base.position.z + @as(f64, @floatFromInt(rand.nextIntBound(13))) - 6.0);
        const weight = blockPathWeight(world_map, x, y, z);
        if (weight > best_weight) {
            best_weight = weight;
            best = .{ x, y, z };
        }
    }

    const target = best orelse return;
    const found = try world.pathfinder.toBlock(gpa, world_map, self.pathMob(), target[0], target[1], target[2], wander_radius);
    self.setPath(gpa, found);
}

pub const Chase = struct {
    position: math.Vec3,
    eye_height: f64,
    ceased: bool,
};

pub fn followPath(self: *Animal, gpa: std.mem.Allocator, rand: *world.JavaRandom, chase: ?Chase) void {
    const feet_y: f64 = @floatFromInt(math.util.floorDouble(self.base.boundingBox().min_y + 0.5));
    const reach = self.base.width * 2.0;

    var node: ?[3]f64 = self.path.?.position(self.pathMob());
    while (node) |position| {
        const dx = position[0] - self.base.position.x;
        const dz = position[2] - self.base.position.z;
        if (dx * dx + dz * dz >= reach * reach) break;

        self.path.?.incrementIndex();
        if (self.path.?.isFinished()) {
            node = null;
            self.clearPath(gpa);
        } else {
            node = self.path.?.position(self.pathMob());
        }
    }

    self.is_jumping = false;
    if (node) |position| {
        const dx = position[0] - self.base.position.x;
        const dz = position[2] - self.base.position.z;
        const dy = position[1] - feet_y;

        const target_yaw = @as(f32, @floatCast(std.math.atan2(dz, dx) * 180.0 / std.math.pi)) - 90.0;
        self.move_forward = self.move_speed;
        self.yaw += std.math.clamp(wrapDegrees(target_yaw - self.yaw), -30.0, 30.0);

        if (chase) |target| {
            if (target.ceased) {
                const to_x = target.position.x - self.base.position.x;
                const to_z = target.position.z - self.base.position.z;
                const held_yaw = self.yaw;
                self.yaw = @as(f32, @floatCast(std.math.atan2(to_z, to_x) * 180.0 / std.math.pi)) - 90.0;
                const swing = (held_yaw - self.yaw + 90.0) * std.math.pi / 180.0;
                self.move_strafing = -math.util.sin(swing) * self.move_forward;
                self.move_forward = math.util.cos(swing) * self.move_forward;
            }
        }

        if (dy > 0.0) self.is_jumping = true;
    }

    if (chase) |target| self.faceEntity(target.position, target.eye_height, 30.0, 30.0);

    if ((self.base.blocked_horizontally) and self.path == null) self.is_jumping = true;
    if (rand.nextFloat() < 0.8 and (self.base.in_water or self.in_lava)) self.is_jumping = true;
}

fn updateActionState(
    self: *Animal,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    players: Players,
    rand: *world.JavaRandom,
) anyerror!void {
    const wants_new_path = if (self.path == null)
        (rand.nextIntBound(80) == 0 or rand.nextIntBound(80) == 0)
    else
        rand.nextIntBound(80) == 0;
    if (wants_new_path) try self.findWanderPath(gpa, world_map, rand);

    self.pitch = 0;

    if (self.path != null and rand.nextIntBound(100) != 0) {
        self.followPath(gpa, rand, null);
    } else {
        self.idleActionState(players, rand);
        self.clearPath(gpa);
    }
}

fn updateFireAndWater(self: *Animal, world_map: *const world.World, rand: *world.JavaRandom) void {
    self.base.updateWaterState(world_map);
    if (self.base.in_water) {
        self.fall_distance = 0;
        self.fire = 0;
    }

    if (self.fire > 0) {
        if (@rem(self.fire, 20) == 0) _ = self.hurt(burn_damage, null, rand);
        self.fire -= 1;
    }

    self.in_lava = physics.isInLava(world_map, self.base.boundingBox());
    if (self.in_lava) {
        _ = self.hurt(lava_damage, null, rand);
        self.fire = lava_fire_ticks;
    }

    if (self.base.position.y < void_floor) _ = self.hurt(void_damage, null, rand);
}

fn updateBreathing(self: *Animal, world_map: *const world.World, rand: *world.JavaRandom) void {
    const eye = self.eyePosition();
    if (self.isAlive() and physics.isInsideWater(world_map, eye.x, eye.y, eye.z)) {
        self.air -= 1;
        if (self.air == -20) {
            self.air = 0;
            self.drowned = true;
            _ = self.hurt(drown_damage, null, rand);
        }
        self.fire = 0;
        return;
    }
    self.air = max_air;
}

fn updateRenderYaw(self: *Animal) void {
    const dx = self.base.position.x - self.base.prev_position.x;
    const dz = self.base.position.z - self.base.prev_position.z;
    const travelled: f32 = @floatCast(@sqrt(dx * dx + dz * dz));

    var facing = self.render_yaw;
    if (travelled > 0.05) {
        facing = @as(f32, @floatCast(std.math.atan2(dz, dx) * 180.0 / std.math.pi)) - 90.0;
    }

    self.render_yaw += wrapDegrees(facing - self.render_yaw) * 0.3;

    var offset = wrapDegrees(self.yaw - self.render_yaw);
    offset = std.math.clamp(offset, -75.0, 75.0);
    self.render_yaw = self.yaw - offset;
    if (offset * offset > 2500.0) self.render_yaw += offset * 0.2;

    while (self.yaw - self.prev_yaw < -180.0) self.prev_yaw -= 360.0;
    while (self.yaw - self.prev_yaw >= 180.0) self.prev_yaw += 360.0;
    while (self.render_yaw - self.prev_render_yaw < -180.0) self.prev_render_yaw -= 360.0;
    while (self.render_yaw - self.prev_render_yaw >= 180.0) self.prev_render_yaw += 360.0;
    while (self.pitch - self.prev_pitch < -180.0) self.prev_pitch -= 360.0;
    while (self.pitch - self.prev_pitch >= 180.0) self.prev_pitch += 360.0;
}

pub fn tick(
    self: *Animal,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    players: Players,
    rand: *world.JavaRandom,
) !void {
    self.base.beginTick();
    self.drowned = false;
    self.updateFireAndWater(world_map, rand);

    if (self.isAlive() and self.isInsideOpaqueBlock(world_map)) {
        _ = self.hurt(suffocation_damage, null, rand);
    }
    self.updateBreathing(world_map, rand);

    if (self.hurt_time > 0) self.hurt_time -= 1;
    if (self.hurt_resistance > 0) self.hurt_resistance -= 1;

    if (self.health <= 0) {
        self.death_time += 1;
        if (self.death_time > death_ticks) self.dead = true;
    }

    self.prev_render_yaw = self.render_yaw;
    self.prev_yaw = self.yaw;
    self.prev_pitch = self.pitch;

    if (self.health <= 0) {
        self.is_jumping = false;
        self.move_strafing = 0;
        self.move_forward = 0;
        self.random_yaw_velocity = 0;
        self.clearPath(gpa);
    } else {
        try self.action_state(self, gpa, world_map, players, rand);
    }

    if (self.is_jumping) {
        if (self.base.in_water or self.in_lava) {
            self.base.motion.y += liquid_paddle;
        } else if (self.base.on_ground) {
            self.base.motion.y = jump_velocity;
        }
    }

    self.move_strafing *= 0.98;
    self.move_forward *= 0.98;
    self.random_yaw_velocity *= 0.9;
    self.moveWithHeading(world_map, self.move_strafing, self.move_forward, rand);

    self.updateRenderYaw();
}

pub fn toRecord(self: Animal) world.entity_nbt.Living {
    return .{
        .position = .{
            self.base.position.x,
            self.base.position.y + self.base.y_size,
            self.base.position.z,
        },
        .motion = .{ self.base.motion.x, self.base.motion.y, self.base.motion.z },
        .yaw = self.yaw,
        .pitch = self.pitch,
        .fall_distance = self.fall_distance,
        .fire = @intCast(self.fire),
        .air = @intCast(self.air),
        .on_ground = self.base.on_ground,
        .health = @intCast(self.health),
        .hurt_time = @intCast(self.hurt_time),
        .death_time = @intCast(self.death_time),
    };
}

pub fn restore(self: *Animal, record: world.entity_nbt.Living) void {
    self.base.motion = math.Vec3.init(record.motion[0], record.motion[1], record.motion[2]);
    self.base.on_ground = record.on_ground;
    self.yaw = record.yaw;
    self.prev_yaw = record.yaw;
    self.render_yaw = record.yaw;
    self.prev_render_yaw = record.yaw;
    self.pitch = record.pitch;
    self.prev_pitch = record.pitch;
    self.fall_distance = record.fall_distance;
    self.fire = record.fire;
    self.air = record.air;
    self.health = record.health;
    self.hurt_time = record.hurt_time;
    self.death_time = record.death_time;
}

pub fn renderYaw(self: Animal, partial_ticks: f32) f32 {
    return self.prev_render_yaw + (self.render_yaw - self.prev_render_yaw) * partial_ticks;
}

pub fn headYaw(self: Animal, partial_ticks: f32) f32 {
    const yaw = self.prev_yaw + (self.yaw - self.prev_yaw) * partial_ticks;
    return yaw - self.renderYaw(partial_ticks);
}

pub fn headPitch(self: Animal, partial_ticks: f32) f32 {
    return self.prev_pitch + (self.pitch - self.prev_pitch) * partial_ticks;
}

pub fn limbSwingAmount(self: Animal, partial_ticks: f32) f32 {
    const amount = self.prev_limb_swing_amount + (self.limb_swing_amount - self.prev_limb_swing_amount) * partial_ticks;
    return @min(amount, 1.0);
}

pub fn limbSwingPhase(self: Animal, partial_ticks: f32) f32 {
    return self.limb_swing - self.limb_swing_amount * (1.0 - partial_ticks);
}

pub fn deathTilt(self: Animal, partial_ticks: f32) f32 {
    if (self.death_time == 0) return 0;
    const progress = (@as(f32, @floatFromInt(self.death_time)) + partial_ticks - 1.0) / 20.0 * 1.6;
    return @min(@sqrt(progress), 1.0) * 90.0;
}

const test_spec: Spec = .{ .width = 0.9, .height = 0.9 };

fn testAnimal(position: math.Vec3) Animal {
    return Animal.spawn(position, test_spec);
}

fn grassWorld(gpa: std.mem.Allocator) !world.World {
    var w = world.World.init(gpa);
    errdefer w.deinit();

    var chunk_x: i32 = -1;
    while (chunk_x <= 1) : (chunk_x += 1) {
        var chunk_z: i32 = -1;
        while (chunk_z <= 1) : (chunk_z += 1) {
            const chunk = try w.createChunk(chunk_x, chunk_z);
            for (0..world.constants.chunk_width) |x| {
                for (0..world.constants.chunk_width) |z| {
                    chunk.setBlock(@intCast(x), 0, @intCast(z), .grass);
                    chunk.setSkyLight(@intCast(x), 1, @intCast(z), 15);
                }
            }
        }
    }
    return w;
}

test "gravity pulls a spawned animal down" {
    const gpa = std.testing.allocator;
    var w = try testing_world.flatWorld(gpa, 1);
    defer w.deinit();

    var rand = world.JavaRandom.init(0);
    var animal = testAnimal(math.Vec3.init(8, 5, 8));
    defer animal.deinit(gpa);

    try animal.tick(gpa, &w, .{}, &rand);
    try std.testing.expectApproxEqAbs(@as(f64, -0.0784), animal.base.motion.y, 1.0e-9);

    try animal.tick(gpa, &w, .{}, &rand);
    try std.testing.expect(animal.base.position.y < 5.0);
}

test "an animal on grass eventually picks a path and walks it" {
    const gpa = std.testing.allocator;
    var w = try grassWorld(gpa);
    defer w.deinit();

    var rand = world.JavaRandom.init(7);
    var animal = testAnimal(math.Vec3.init(8.5, 1, 8.5));
    defer animal.deinit(gpa);
    animal.base.on_ground = true;

    var walked = false;
    for (0..400) |_| {
        try animal.tick(gpa, &w, .{}, &rand);
        if (animal.path != null) walked = true;
    }

    try std.testing.expect(walked);
    try std.testing.expect(animal.base.position.x != 8.5 or animal.base.position.z != 8.5);
}

test "a wandering animal walks along the surface rather than sinking or floating" {
    const gpa = std.testing.allocator;
    var w = try grassWorld(gpa);
    defer w.deinit();

    var rand = world.JavaRandom.init(3);
    var animal = testAnimal(math.Vec3.init(8.5, 1, 8.5));
    defer animal.deinit(gpa);
    animal.base.on_ground = true;

    for (0..200) |_| {
        try animal.tick(gpa, &w, .{}, &rand);

        try std.testing.expectApproxEqAbs(@as(f64, 1.0), animal.base.position.y, 1.0e-6);
    }
}

test "damage inside the invulnerability window only counts what exceeds the last hit" {
    var rand = world.JavaRandom.init(0);
    var animal = testAnimal(math.Vec3.init(8, 1, 8));

    try std.testing.expect(animal.hurt(3, null, &rand));
    try std.testing.expectEqual(@as(i32, 7), animal.health);
    try std.testing.expectEqual(@as(i32, 10), animal.hurt_time);

    try std.testing.expect(!animal.hurt(2, null, &rand));
    try std.testing.expectEqual(@as(i32, 7), animal.health);

    try std.testing.expect(animal.hurt(5, null, &rand));
    try std.testing.expectEqual(@as(i32, 5), animal.health);
}

test "a hit from a known source knocks the animal away from it" {
    var rand = world.JavaRandom.init(0);
    var animal = testAnimal(math.Vec3.init(8, 1, 8));

    _ = animal.hurt(1, .{ .position = math.Vec3.init(6, 1, 8) }, &rand);

    try std.testing.expect(animal.base.motion.x > 0.0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), animal.base.motion.y, 1.0e-9);
}

test "the death hook runs once, on the hit that empties the health bar" {
    const Counter = struct {
        var deaths: u32 = 0;
        fn count(_: *Animal, _: *world.JavaRandom) void {
            deaths += 1;
        }
    };

    var rand = world.JavaRandom.init(0);
    var animal = testAnimal(math.Vec3.init(8, 1, 8));
    animal.on_death = Counter.count;
    Counter.deaths = 0;

    _ = animal.hurt(4, null, &rand);
    try std.testing.expectEqual(@as(u32, 0), Counter.deaths);

    animal.hurt_resistance = 0;
    _ = animal.hurt(default_max_health, null, &rand);
    try std.testing.expectEqual(@as(u32, 1), Counter.deaths);

    animal.hurt_resistance = 0;
    _ = animal.hurt(4, null, &rand);
    try std.testing.expectEqual(@as(u32, 1), Counter.deaths);
}

test "a killed animal lingers for twenty ticks before it is removed" {
    const gpa = std.testing.allocator;
    var w = try testing_world.flatWorld(gpa, 1);
    defer w.deinit();

    var rand = world.JavaRandom.init(0);
    var animal = testAnimal(math.Vec3.init(8, 1, 8));
    defer animal.deinit(gpa);

    _ = animal.hurt(animal.max_health, null, &rand);
    for (0..death_ticks) |_| {
        try animal.tick(gpa, &w, .{}, &rand);
        try std.testing.expect(!animal.dead);
    }

    try animal.tick(gpa, &w, .{}, &rand);
    try std.testing.expect(animal.dead);
}

test "a long fall hurts by the distance beyond three blocks" {
    const gpa = std.testing.allocator;
    var w = try testing_world.flatWorld(gpa, 1);
    defer w.deinit();

    var rand = world.JavaRandom.init(0);
    var animal = testAnimal(math.Vec3.init(8.5, 20, 8.5));
    defer animal.deinit(gpa);

    for (0..100) |_| {
        try animal.tick(gpa, &w, .{}, &rand);
        if (animal.base.on_ground) break;
    }

    try std.testing.expect(animal.base.on_ground);
    try std.testing.expect(animal.health < animal.max_health);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), animal.fall_distance, 1.0e-6);
}

test "an animal that takes no fall damage lands from any height unhurt" {
    const gpa = std.testing.allocator;
    var w = try testing_world.flatWorld(gpa, 1);
    defer w.deinit();

    var rand = world.JavaRandom.init(0);
    var animal = Animal.spawn(math.Vec3.init(8.5, 60, 8.5), .{
        .width = 0.3,
        .height = 0.4,
        .takes_fall_damage = false,
    });
    defer animal.deinit(gpa);

    for (0..300) |_| {
        try animal.tick(gpa, &w, .{}, &rand);
        if (animal.base.on_ground) break;
    }

    try std.testing.expect(animal.base.on_ground);
    try std.testing.expectEqual(animal.max_health, animal.health);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), animal.fall_distance, 1.0e-6);
}

test "a short drop is walked off without damage" {
    const gpa = std.testing.allocator;
    var w = try testing_world.flatWorld(gpa, 1);
    defer w.deinit();

    var rand = world.JavaRandom.init(0);
    var animal = testAnimal(math.Vec3.init(8.5, 3.5, 8.5));
    defer animal.deinit(gpa);

    for (0..60) |_| {
        try animal.tick(gpa, &w, .{}, &rand);
        if (animal.base.on_ground) break;
    }

    try std.testing.expect(animal.base.on_ground);
    try std.testing.expectEqual(animal.max_health, animal.health);
}

test "an animal held under water drowns once its air runs out" {
    const gpa = std.testing.allocator;
    var w = try testing_world.flatWorld(gpa, 6);
    defer w.deinit();

    w.setBlock(8, 1, 8, .stationary_water);

    var rand = world.JavaRandom.init(0);
    var animal = testAnimal(math.Vec3.init(8.5, 1, 8.5));
    defer animal.deinit(gpa);

    for (0..max_air) |_| try animal.tick(gpa, &w, .{}, &rand);
    try std.testing.expectEqual(animal.max_health, animal.health);
    try std.testing.expectEqual(@as(i32, 0), animal.air);

    for (0..19) |_| {
        try animal.tick(gpa, &w, .{}, &rand);
        try std.testing.expect(!animal.drowned);
    }

    try animal.tick(gpa, &w, .{}, &rand);
    try std.testing.expect(animal.drowned);
    try std.testing.expectEqual(animal.max_health - drown_damage, animal.health);

    try animal.tick(gpa, &w, .{}, &rand);
    try std.testing.expect(!animal.drowned);
}

test "an animal in open water swims up and never drowns" {
    const gpa = std.testing.allocator;
    var w = try testing_world.flatWorld(gpa, 1);
    defer w.deinit();

    const chunk = w.getChunk(0, 0).?;
    for (0..world.constants.chunk_width) |x| {
        for (0..world.constants.chunk_width) |z| {
            var y: u32 = 1;
            while (y < 6) : (y += 1) chunk.setBlock(@intCast(x), y, @intCast(z), .stationary_water);
        }
    }

    var rand = world.JavaRandom.init(0);
    var animal = testAnimal(math.Vec3.init(8.5, 1, 8.5));
    defer animal.deinit(gpa);

    for (0..max_air + 100) |_| try animal.tick(gpa, &w, .{}, &rand);

    try std.testing.expectEqual(animal.max_health, animal.health);
    try std.testing.expect(animal.base.position.y > 4.0);
}

test "an animal buried in stone suffocates" {
    const gpa = std.testing.allocator;
    var w = try testing_world.flatWorld(gpa, 6);
    defer w.deinit();

    var rand = world.JavaRandom.init(0);
    var animal = testAnimal(math.Vec3.init(8.5, 3, 8.5));
    defer animal.deinit(gpa);

    try animal.tick(gpa, &w, .{}, &rand);
    try std.testing.expectEqual(animal.max_health - suffocation_damage, animal.health);
}

test "an animal standing in lava catches fire and burns" {
    const gpa = std.testing.allocator;
    var w = try testing_world.flatWorld(gpa, 1);
    defer w.deinit();

    const chunk = w.getChunk(0, 0).?;
    for (0..world.constants.chunk_width) |x| {
        for (0..world.constants.chunk_width) |z| {
            chunk.setBlock(@intCast(x), 1, @intCast(z), .stationary_lava);
        }
    }

    var rand = world.JavaRandom.init(0);
    var animal = testAnimal(math.Vec3.init(8.5, 1, 8.5));
    defer animal.deinit(gpa);

    try animal.tick(gpa, &w, .{}, &rand);
    try std.testing.expectEqual(animal.max_health - lava_damage, animal.health);
    try std.testing.expect(animal.fire > 0);
}

test "an animal far from the player despawns" {
    const gpa = std.testing.allocator;
    var w = try testing_world.flatWorld(gpa, 1);
    defer w.deinit();

    var rand = world.JavaRandom.init(0);
    var animal = testAnimal(math.Vec3.init(8.5, 1, 8.5));
    defer animal.deinit(gpa);

    const far_away = PlayerView{ .position = math.Vec3.init(8.5, 1, 400), .eye_height = 1.62, .alive = true };
    for (0..200) |_| {
        try animal.tick(gpa, &w, Players.one(&far_away), &rand);
        if (animal.dead) break;
    }

    try std.testing.expect(animal.dead);
}

test "an animal near the player is kept alive however old it gets" {
    const gpa = std.testing.allocator;
    var w = try grassWorld(gpa);
    defer w.deinit();

    var rand = world.JavaRandom.init(5);
    var animal = testAnimal(math.Vec3.init(8.5, 1, 8.5));
    defer animal.deinit(gpa);
    animal.entity_age = 5000;

    const nearby = PlayerView{ .position = math.Vec3.init(10.5, 1, 8.5), .eye_height = 1.62, .alive = true };
    for (0..600) |_| try animal.tick(gpa, &w, Players.one(&nearby), &rand);

    try std.testing.expect(!animal.dead);
}

test "an idle animal turns to watch a player who walks up to it" {
    const gpa = std.testing.allocator;
    var w = try testing_world.flatWorld(gpa, 1);
    defer w.deinit();

    var rand = world.JavaRandom.init(2);
    var animal = testAnimal(math.Vec3.init(8.5, 1, 8.5));
    defer animal.deinit(gpa);
    animal.base.on_ground = true;

    const nearby = PlayerView{ .position = math.Vec3.init(11.5, 1, 8.5), .eye_height = 1.62, .alive = true };
    var watched = false;
    for (0..300) |_| {
        try animal.tick(gpa, &w, Players.one(&nearby), &rand);
        if (animal.watched_player != null) watched = true;
    }

    try std.testing.expect(watched);
}

test "grass is the preferred ground to wander onto" {
    const gpa = std.testing.allocator;
    var w = try testing_world.flatWorld(gpa, 1);
    defer w.deinit();

    w.getChunk(0, 0).?.setBlock(4, 0, 8, .grass);

    try std.testing.expectEqual(@as(f32, 10.0), blockPathWeight(&w, 4, 1, 8));
    try std.testing.expect(blockPathWeight(&w, 12, 1, 8) < 10.0);
}

test "an animal only spawns on lit grass" {
    const gpa = std.testing.allocator;
    var w = try grassWorld(gpa);
    defer w.deinit();

    const on_grass = testAnimal(math.Vec3.init(8.5, 1, 8.5));
    try std.testing.expect(on_grass.canSpawnHere(&w));

    w.getChunk(0, 0).?.setBlock(8, 0, 8, .stone);
    try std.testing.expect(!on_grass.canSpawnHere(&w));

    w.getChunk(0, 0).?.setBlock(8, 0, 8, .grass);
    w.getChunk(0, 0).?.setSkyLight(8, 1, 8, 4);
    try std.testing.expect(!on_grass.canSpawnHere(&w));
}

test "a taller animal needs the headroom its own height asks for" {
    const gpa = std.testing.allocator;
    var w = try grassWorld(gpa);
    defer w.deinit();

    w.setBlock(8, 2, 8, .stone);

    const short = Animal.spawn(math.Vec3.init(8.5, 1, 8.5), .{ .width = 0.9, .height = 0.9 });
    const tall = Animal.spawn(math.Vec3.init(8.5, 1, 8.5), .{ .width = 0.9, .height = 1.3 });

    try std.testing.expect(short.canSpawnHere(&w));
    try std.testing.expect(!tall.canSpawnHere(&w));
}

test "the limb swing amount saturates at one however hard the animal is hit" {
    var rand = world.JavaRandom.init(0);
    var animal = testAnimal(math.Vec3.init(8, 1, 8));

    _ = animal.hurt(1, null, &rand);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), animal.limb_swing_amount, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), animal.limbSwingAmount(1.0), 1.0e-6);
}

test "the death tilt rolls the corpse onto its side over the death animation" {
    var animal = testAnimal(math.Vec3.init(8, 1, 8));

    try std.testing.expectApproxEqAbs(@as(f32, 0.0), animal.deathTilt(0), 1.0e-6);

    animal.death_time = 1;
    try std.testing.expect(animal.deathTilt(1.0) > 0.0);

    animal.death_time = death_ticks;
    try std.testing.expectApproxEqAbs(@as(f32, 90.0), animal.deathTilt(1.0), 1.0e-6);
}

test "an animal walks the way it is facing" {
    var north = testAnimal(math.Vec3.init(8, 1, 8));
    north.yaw = 0;
    north.moveFlying(0, default_move_speed, ground_acceleration);
    try std.testing.expect(north.base.motion.z > 0.0);
    try std.testing.expectApproxEqAbs(@as(f64, 0), north.base.motion.x, 1.0e-6);

    var west = testAnimal(math.Vec3.init(8, 1, 8));
    west.yaw = 90;
    west.moveFlying(0, default_move_speed, ground_acceleration);
    try std.testing.expect(west.base.motion.x < 0.0);
    try std.testing.expectApproxEqAbs(@as(f64, 0), west.base.motion.z, 1.0e-6);
}

test "the body turns to follow the head rather than snapping to it" {
    var animal = testAnimal(math.Vec3.init(8, 1, 8));
    animal.yaw = 90;
    animal.updateRenderYaw();

    try std.testing.expect(animal.render_yaw > 0.0);
    try std.testing.expect(animal.render_yaw <= 90.0);
    try std.testing.expect(@abs(animal.headYaw(1.0)) <= 75.0);
}

test "the eyes sit at the same fraction of the body however tall it is" {
    const pig_sized = Animal.spawn(math.Vec3.init(0, 0, 0), .{ .width = 0.9, .height = 0.9 });
    const sheep_sized = Animal.spawn(math.Vec3.init(0, 0, 0), .{ .width = 0.9, .height = 1.3 });

    try std.testing.expectApproxEqAbs(@as(f64, 0.765), pig_sized.eyeHeight(), 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.105), sheep_sized.eyeHeight(), 1.0e-9);
}

fn viewAt(id: Entity.Id, x: f64, z: f64) PlayerView {
    return .{ .id = id, .position = math.Vec3.init(x, 1, z), .eye_height = 1.62, .alive = true };
}

test "the closest player is the nearest one inside the range, and none beyond it" {
    const views = [_]PlayerView{ viewAt(1, 20, 0), viewAt(2, 4, 0), viewAt(3, 9, 0) };
    const players = Players.of(&views);
    const origin = math.Vec3.init(0, 1, 0);

    try std.testing.expectEqual(@as(Entity.Id, 2), players.closestTo(origin, -1.0).?.id);
    try std.testing.expectEqual(@as(Entity.Id, 2), players.closestTo(origin, 10.0).?.id);
    try std.testing.expect(players.closestTo(origin, 3.0) == null);

    const far = math.Vec3.init(18, 1, 0);
    try std.testing.expectEqual(@as(Entity.Id, 1), players.closestTo(far, -1.0).?.id);
}

test "an empty world has no closest player and no player by id" {
    const players: Players = .{};
    try std.testing.expect(players.closestTo(math.Vec3.init(0, 0, 0), -1.0) == null);
    try std.testing.expect(players.byId(1) == null);
}

test "a player is found by the id it was given" {
    const views = [_]PlayerView{ viewAt(4, 0, 0), viewAt(9, 5, 0) };
    const players = Players.of(&views);

    try std.testing.expectEqual(@as(f64, 5), players.byId(9).?.position.x);
    try std.testing.expect(players.byId(5) == null);
}

test "an animal watches whichever player is nearer, and forgets one that walks away" {
    const gpa = std.testing.allocator;
    var w = try testing_world.flatWorld(gpa, 1);
    defer w.deinit();

    var rand = world.JavaRandom.init(2);
    var animal = testAnimal(math.Vec3.init(8.5, 1, 8.5));
    defer animal.deinit(gpa);
    animal.base.on_ground = true;

    var views = [_]PlayerView{ viewAt(1, 40.5, 8.5), viewAt(2, 11.5, 8.5) };
    const players = Players.of(&views);

    var watched: ?Entity.Id = null;
    for (0..300) |_| {
        try animal.tick(gpa, &w, players, &rand);
        if (animal.watched_player) |id| watched = id;
    }
    try std.testing.expectEqual(@as(Entity.Id, 2), watched.?);

    views[1] = viewAt(2, 400.5, 8.5);
    for (0..40) |_| try animal.tick(gpa, &w, players, &rand);
    try std.testing.expect(animal.watched_player == null);
}

test "an animal beside one player is kept alive however far the other has wandered" {
    const gpa = std.testing.allocator;
    var w = try testing_world.flatWorld(gpa, 1);
    defer w.deinit();

    var rand = world.JavaRandom.init(0);
    var animal = testAnimal(math.Vec3.init(8.5, 1, 8.5));
    defer animal.deinit(gpa);

    const views = [_]PlayerView{ viewAt(1, 8.5, 900), viewAt(2, 10.5, 8.5) };
    for (0..200) |_| {
        try animal.tick(gpa, &w, Players.of(&views), &rand);
        if (animal.dead) break;
    }

    try std.testing.expect(!animal.dead);
}

test "an animal every player has left behind despawns" {
    const gpa = std.testing.allocator;
    var w = try testing_world.flatWorld(gpa, 1);
    defer w.deinit();

    var rand = world.JavaRandom.init(0);
    var animal = testAnimal(math.Vec3.init(8.5, 1, 8.5));
    defer animal.deinit(gpa);

    const views = [_]PlayerView{ viewAt(1, 8.5, 900), viewAt(2, 900, 8.5) };
    for (0..200) |_| {
        try animal.tick(gpa, &w, Players.of(&views), &rand);
        if (animal.dead) break;
    }

    try std.testing.expect(animal.dead);
}
