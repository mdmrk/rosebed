const std = @import("std");

const math = @import("math");
const world = @import("world");

const achievements = @import("achievements.zig");
const Entity = @import("Entity.zig");
const game_physics = @import("physics.zig");
const Inventory = @import("Inventory.zig");
const raycast = @import("raycast.zig");

const Player = @This();

base: Entity,
riding: Entity.Id = Entity.no_id,
ride_input: math.Vec3 = math.Vec3.init(0, 0, 0),
yaw: f32 = 0,
pitch: f32 = 0,
prev_yaw: f32 = 0,
prev_pitch: f32 = 0,
render_yaw: f32 = 0,
prev_render_yaw: f32 = 0,
limb_swing: f32 = 0,
limb_swing_amount: f32 = 0,
prev_limb_swing_amount: f32 = 0,
health: i32 = 20,
name: Name = .{},
prev_health: i32 = 20,
spawn_point: ?[3]i32 = null,
sleeping: bool = false,
sleep_timer: i32 = 0,
bed: ?[3]i32 = null,
bed_offset: [2]f32 = .{ 0, 0 },
wake_pending: bool = false,
hurt_time: i32 = 0,
max_hurt_time: i32 = 0,
attacked_at_yaw: f32 = 0,
death_time: i32 = 0,
hurt_rand: world.JavaRandom = .init(0),
air: i32 = max_air,
in_portal: bool = false,
time_in_portal: f32 = 0,
prev_time_in_portal: f32 = 0,
time_until_portal: i32 = portal_cooldown,
inventory: Inventory = .{},
distance_walked: f32 = 0,
prev_distance_walked: f32 = 0,
next_step_distance: i32 = 0,
camera_yaw: f32 = 0,
swing_progress: f32 = 0,
prev_swing_progress: f32 = 0,
swing_ticks: i32 = 0,
is_swinging: bool = false,
prev_camera_yaw: f32 = 0,
camera_pitch: f32 = 0,
prev_camera_pitch: f32 = 0,
jumped: bool = false,
drowned: bool = false,
fire: i32 = 0,
in_lava: bool = false,
hurt_resistance: i32 = 0,
last_damage: i32 = 0,
damage_taken: i32 = 0,
damage_remainder: i32 = 0,
fall_distance: f32 = 0,
distance_fallen: f32 = 0,
earned: std.EnumSet(achievements.Id) = .initEmpty(),
minecart_start: ?[3]i32 = null,
y_size: f64 = 0,
prev_y_size: f64 = 0,

pub fn earn(self: *Player, id: achievements.Id) void {
    self.earned.insert(id);
}

pub fn takeEarned(self: *Player) std.EnumSet(achievements.Id) {
    const claimed = self.earned;
    self.earned = .initEmpty();
    return claimed;
}

pub const max_name = 16;

pub const Name = struct {
    bytes: [max_name]u8 = undefined,
    len: usize = 0,

    pub fn set(self: *Name, value: []const u8) void {
        self.len = @min(value.len, self.bytes.len);
        @memcpy(self.bytes[0..self.len], value[0..self.len]);
    }

    pub fn text(self: *const Name) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn eql(self: *const Name, other: []const u8) bool {
        return std.mem.eql(u8, self.text(), other);
    }
};

pub const width: f64 = 0.6;
pub const height: f64 = 1.8;
pub const eye_height: f64 = 1.62;

pub const turn_scale = 0.15;

const gravity: f64 = 0.08;
const vertical_drag: f64 = 0.98;
const air_friction: f64 = 0.91;
const ground_friction: f64 = 0.6 * 0.91;
const ground_speed: f64 = 0.1;
const air_speed: f64 = 0.02;
const jump_velocity: f64 = 0.42;

const liquid_speed: f64 = 0.02;
const water_drag: f64 = 0.8;
const lava_drag: f64 = 0.5;
const liquid_gravity: f64 = 0.02;
const liquid_jump: f64 = 0.04;
const liquid_climb_out: f64 = 0.3;

pub const max_air: i32 = 300;
pub const portal_cooldown: i32 = 20;
pub const portal_reentry_cooldown: i32 = 10;
const portal_fade_in: f32 = 0.0125;
const portal_fade_out: f32 = 0.05;
const drown_damage: i32 = 2;
const cactus_damage: i32 = 1;
const burn_damage: i32 = 1;
const lava_damage: i32 = 4;
const lava_fire_ticks: i32 = 600;
const hurt_resistance_ticks: i32 = 20;
const hurt_animation_ticks: i32 = 10;
const knockback_strength: f64 = 0.4;

pub const safe_fall_distance: f32 = 3.0;
const recorded_fall_distance: f32 = 2.0;

const sneak_input_scale: f32 = 0.3;
const sneak_camera_dip: f64 = 0.2;

pub const step_height: f64 = 0.5;

pub const sleep_size: f64 = 0.2;
pub const sleep_eye_height: f64 = 0.2;
pub const bed_pillow_height: f64 = 15.0 / 16.0;
pub const bed_camera_height: f64 = 0.54;
pub const sleep_fade_ticks: i32 = 100;
pub const sleep_wake_ticks: i32 = 110;
const bed_body_reach: f32 = 1.8;
const bed_reach_x: f64 = 3.0;
const bed_reach_y: f64 = 2.0;
const wake_stand_lift: f64 = 0.1;

pub fn spawn(position: math.Vec3) Player {
    var player: Player = .{ .base = Entity.init(position, width, height) };
    player.base.step_height = step_height;
    return player;
}

pub const ride_push_speed: f64 = air_speed;

pub fn tickRidden(self: *Player, strafe: f32, forward: f32) void {
    self.base.beginTick();
    self.jumped = false;
    self.drowned = false;
    self.prev_distance_walked = self.distance_walked;
    self.prev_camera_yaw = self.camera_yaw;
    self.prev_camera_pitch = self.camera_pitch;
    self.prev_yaw = self.yaw;
    self.prev_pitch = self.pitch;
    self.prev_render_yaw = self.render_yaw;
    self.prev_y_size = self.y_size;

    self.base.motion = math.Vec3.init(0, 0, 0);
    self.fall_distance = 0;
    self.base.on_ground = true;

    const dir = self.moveDirection(strafe, forward);
    self.ride_input = math.Vec3.init(
        @as(f64, dir[0]) * ride_push_speed,
        0,
        @as(f64, dir[2]) * ride_push_speed,
    );

    if (self.hurt_time > 0) self.hurt_time -= 1;
    if (self.hurt_resistance > 0) self.hurt_resistance -= 1;
    if (self.health <= 0) self.death_time += 1;
}

pub fn tick(self: *Player, world_map: *const world.World, strafe_in: f32, forward_in: f32, jump: bool, sneak: bool) void {
    self.base.beginTick();
    self.jumped = false;
    self.drowned = false;
    self.prev_distance_walked = self.distance_walked;
    self.prev_camera_yaw = self.camera_yaw;
    self.prev_camera_pitch = self.camera_pitch;
    self.prev_yaw = self.yaw;
    self.prev_pitch = self.pitch;
    self.prev_render_yaw = self.render_yaw;

    self.base.sneaking = sneak;
    self.prev_y_size = self.y_size;
    self.y_size *= 0.4;
    if (sneak and self.y_size < sneak_camera_dip) self.y_size = sneak_camera_dip;

    var strafe = strafe_in;
    var forward = forward_in;
    if (sneak) {
        strafe *= sneak_input_scale;
        forward *= sneak_input_scale;
    }

    self.base.updateWaterState(world_map);
    if (self.base.in_water) {
        self.fall_distance = 0;
        self.fire = 0;
    }
    self.updateFire(world_map);
    self.updateAir(world_map);
    if (self.hurt_time > 0) self.hurt_time -= 1;
    if (self.hurt_resistance > 0) self.hurt_resistance -= 1;
    if (self.health <= 0) self.death_time += 1;

    if (self.base.in_water or self.in_lava) {
        if (jump) self.base.motion.y += liquid_jump;
    } else if (self.base.on_ground and jump) {
        self.base.motion.y = jump_velocity;
        self.jumped = true;
    }

    const speed: f64 = if (self.base.in_water or self.in_lava)
        liquid_speed
    else if (self.base.on_ground)
        ground_speed
    else
        air_speed;
    const dir = self.moveDirection(strafe, forward);
    self.base.motion.x += @as(f64, dir[0]) * speed;
    self.base.motion.z += @as(f64, dir[2]) * speed;

    const before_x = self.base.position.x;
    const before_y = self.base.position.y;
    const before_z = self.base.position.z;
    const moved = self.base.move(world_map);
    self.updateFallState(moved.dy);
    self.hurtOnCactus(world_map);

    const moved_x = self.base.position.x - before_x;
    const moved_z = self.base.position.z - before_z;
    self.distance_walked += @floatCast(@sqrt(moved_x * moved_x + moved_z * moved_z) * 0.6);
    self.playStepSound(world_map);

    if (self.base.in_water or self.in_lava) {
        const drag: f64 = if (self.base.in_water) water_drag else lava_drag;
        self.base.motion.x *= drag;
        self.base.motion.y *= drag;
        self.base.motion.z *= drag;
        self.base.motion.y -= liquid_gravity;

        const blocked_horizontally = moved.blocked_x or moved.blocked_z;
        const step_up = self.base.motion.y + 0.6 - self.base.position.y + before_y;
        if (blocked_horizontally and self.base.isOffsetPositionInLiquid(world_map, self.base.motion.x, step_up, self.base.motion.z)) {
            self.base.motion.y = liquid_climb_out;
        }
    } else {
        self.base.motion.y -= gravity;
        self.base.motion.y *= vertical_drag;
        const friction: f64 = if (self.base.on_ground) ground_friction else air_friction;
        self.base.motion.x *= friction;
        self.base.motion.z *= friction;
    }

    var swing: f32 = @floatCast(@sqrt(self.base.motion.x * self.base.motion.x + self.base.motion.z * self.base.motion.z));
    var dip: f32 = @floatCast(std.math.atan(-self.base.motion.y * 0.2) * 15.0);
    if (swing > 0.1) swing = 0.1;
    if (!self.base.on_ground) swing = 0.0;
    if (self.base.on_ground) dip = 0.0;
    self.camera_yaw += (swing - self.camera_yaw) * 0.4;
    self.camera_pitch += (dip - self.camera_pitch) * 0.8;

    self.updateLimbSwing();
    self.updateRenderYaw();
}

pub fn tickEnvironment(self: *Player, world_map: *const world.World, dy: f64) void {
    self.drowned = false;
    self.base.in_water = game_physics.isBoxInMaterial(world_map, self.base.boundingBox().expand(0, -0.4, 0), .water);
    self.updateFire(world_map);
    self.updateAir(world_map);
    self.updateFallState(dy);
    self.hurtOnCactus(world_map);
    if (self.hurt_time > 0) self.hurt_time -= 1;
    if (self.hurt_resistance > 0) self.hurt_resistance -= 1;
}

pub fn tickRemote(self: *Player) void {
    self.base.beginTick();
    self.prev_yaw = self.yaw;
    self.prev_pitch = self.pitch;
    self.prev_render_yaw = self.render_yaw;

    Entity.stepRemote(self);

    self.updateRenderYaw();
    self.updateLimbSwing();
    self.tickSwing();
}

fn wrapDegrees(value: f32) f32 {
    var wrapped = value;
    while (wrapped < -180.0) wrapped += 360.0;
    while (wrapped >= 180.0) wrapped -= 360.0;
    return wrapped;
}

fn updateLimbSwing(self: *Player) void {
    self.prev_limb_swing_amount = self.limb_swing_amount;
    const dx = self.base.position.x - self.base.prev_position.x;
    const dz = self.base.position.z - self.base.prev_position.z;
    var swing: f32 = @floatCast(@sqrt(dx * dx + dz * dz) * 4.0);
    if (swing > 1.0) swing = 1.0;
    self.limb_swing_amount += (swing - self.limb_swing_amount) * 0.4;
    self.limb_swing += self.limb_swing_amount;
}

fn updateRenderYaw(self: *Player) void {
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

pub fn renderYaw(self: Player, partial_ticks: f32) f32 {
    return self.prev_render_yaw + (self.render_yaw - self.prev_render_yaw) * partial_ticks;
}

pub fn headYaw(self: Player, partial_ticks: f32) f32 {
    const yaw = self.prev_yaw + (self.yaw - self.prev_yaw) * partial_ticks;
    return yaw - self.renderYaw(partial_ticks);
}

pub fn headPitch(self: Player, partial_ticks: f32) f32 {
    return self.prev_pitch + (self.pitch - self.prev_pitch) * partial_ticks;
}

pub fn limbSwingAmount(self: Player, partial_ticks: f32) f32 {
    const amount = self.prev_limb_swing_amount + (self.limb_swing_amount - self.prev_limb_swing_amount) * partial_ticks;
    return @min(amount, 1.0);
}

pub fn limbSwingPhase(self: Player, partial_ticks: f32) f32 {
    return self.limb_swing - self.limb_swing_amount * (1.0 - partial_ticks);
}

pub fn isSubmerged(self: Player, world_map: *const world.World) bool {
    const eye = self.eyePosition();
    return game_physics.isInsideWater(world_map, eye.x, eye.y, eye.z);
}

pub fn isEyeInLava(self: Player, world_map: *const world.World) bool {
    const eye = self.eyePosition();
    return game_physics.isInsideMaterial(world_map, .lava, eye.x, eye.y, eye.z);
}

fn updateFire(self: *Player, world_map: *const world.World) void {
    if (self.fire > 0) {
        if (@rem(self.fire, 20) == 0) self.hurt(burn_damage);
        self.fire -= 1;
    }

    self.in_lava = game_physics.isInLava(world_map, self.base.boundingBox());
    if (self.in_lava) {
        self.hurt(lava_damage);
        self.fire = lava_fire_ticks;
    }
}

fn hurtOnCactus(self: *Player, world_map: *const world.World) void {
    if (game_physics.touchesBlock(world_map, self.base.boundingBox(), .cactus)) self.hurt(cactus_damage);
}

fn updateAir(self: *Player, world_map: *const world.World) void {
    if (self.health > 0 and self.isSubmerged(world_map)) {
        self.air -= 1;
        if (self.air == -20) {
            self.air = 0;
            self.drowned = true;
            self.hurt(drown_damage);
        }
        self.fire = 0;
        return;
    }
    self.air = max_air;
}

fn fall(self: *Player, distance: f32) void {
    if (distance >= recorded_fall_distance) self.distance_fallen += distance;

    const damage: i32 = @intFromFloat(@ceil(distance - safe_fall_distance));
    if (damage <= 0) return;
    self.hurt(damage);
}

fn updateFallState(self: *Player, dy: f64) void {
    if (self.base.on_ground) {
        if (self.fall_distance > 0.0) {
            self.fall(self.fall_distance);
            self.fall_distance = 0.0;
        }
    } else if (dy < 0.0) {
        self.fall_distance -= @floatCast(dy);
    }
}

pub fn absorbsHit(self: Player, amount: i32) bool {
    if (self.health <= 0 or amount == 0) return true;
    return self.hurt_resistance > @divTrunc(hurt_resistance_ticks, 2) and amount <= self.last_damage;
}

pub fn hurt(self: *Player, amount: i32) void {
    self.damageFrom(amount, null);
}

pub fn tp(self: *Player, pos: math.Vec3) void {
    self.base.position = pos;
}

pub fn hurtFrom(self: *Player, amount: i32, source: math.Vec3) void {
    self.damageFrom(amount, source);
}

fn damageFrom(self: *Player, amount: i32, source: ?math.Vec3) void {
    if (self.health <= 0 or amount == 0) return;
    if (self.sleeping) self.wake_pending = true;
    self.damage_taken += amount;

    if (self.hurt_resistance > @divTrunc(hurt_resistance_ticks, 2)) {
        if (amount <= self.last_damage) return;
        self.applyDamage(amount - self.last_damage);
        self.last_damage = amount;
        self.attacked_at_yaw = 0;
        return;
    }

    self.last_damage = amount;
    self.prev_health = self.health;
    self.hurt_resistance = hurt_resistance_ticks;
    self.applyDamage(amount);
    self.hurt_time = hurt_animation_ticks;
    self.max_hurt_time = hurt_animation_ticks;

    const from = source orelse {
        self.attacked_at_yaw = @floatFromInt(@as(i32, @intFromFloat(self.hurt_rand.nextDouble() * 2.0)) * 180);
        return;
    };

    var dx = from.x - self.base.position.x;
    var dz = from.z - self.base.position.z;
    while (dx * dx + dz * dz < 1.0e-4) {
        dx = (self.hurt_rand.nextDouble() - self.hurt_rand.nextDouble()) * 0.01;
        dz = (self.hurt_rand.nextDouble() - self.hurt_rand.nextDouble()) * 0.01;
    }
    self.attacked_at_yaw = @as(f32, @floatCast(std.math.atan2(dz, dx) * 180.0 / std.math.pi)) - self.yaw;
    self.knockBack(dx, dz);
}

fn knockBack(self: *Player, dx: f64, dz: f64) void {
    const distance = @sqrt(dx * dx + dz * dz);
    self.base.motion.x /= 2.0;
    self.base.motion.y /= 2.0;
    self.base.motion.z /= 2.0;
    self.base.motion.x -= dx / distance * knockback_strength;
    self.base.motion.y += knockback_strength;
    self.base.motion.z -= dz / distance * knockback_strength;
    if (self.base.motion.y > knockback_strength) self.base.motion.y = knockback_strength;
}

fn applyDamage(self: *Player, amount: i32) void {
    const scaled = amount * (25 - self.inventory.totalArmorValue()) + self.damage_remainder;
    self.inventory.damageArmor(@intCast(amount));
    self.damage_remainder = @rem(scaled, 25);
    self.health = @max(0, self.health - @divTrunc(scaled, 25));
}

pub fn kill(self: *Player) void {
    self.damage_taken += self.health;
    self.health = 0;
}

pub fn setInPortal(self: *Player) void {
    if (self.time_until_portal > 0) {
        self.time_until_portal = portal_reentry_cooldown;
    } else {
        self.in_portal = true;
    }
}

pub const PortalStep = enum { none, travel };

pub fn tickPortal(self: *Player) PortalStep {
    self.prev_time_in_portal = self.time_in_portal;

    var step: PortalStep = .none;
    if (self.in_portal) {
        self.time_in_portal += portal_fade_in;
        if (self.time_in_portal >= 1.0) {
            self.time_in_portal = 1.0;
            self.time_until_portal = portal_reentry_cooldown;
            step = .travel;
        }
        self.in_portal = false;
    } else {
        if (self.time_in_portal > 0.0) self.time_in_portal -= portal_fade_out;
        if (self.time_in_portal < 0.0) self.time_in_portal = 0.0;
    }

    if (self.time_until_portal > 0) self.time_until_portal -= 1;
    return step;
}

pub fn portalOverlay(self: Player, partial: f32) f32 {
    return self.prev_time_in_portal + (self.time_in_portal - self.prev_time_in_portal) * partial;
}

pub fn heal(self: *Player, amount: i32) void {
    if (self.health <= 0) return;
    self.health = @min(20, self.health + amount);
    self.hurt_resistance = @divTrunc(hurt_resistance_ticks, 2);
}

pub fn isDead(self: Player) bool {
    return self.health <= 0;
}

pub fn respawn(self: *Player, position: math.Vec3) void {
    const id = self.base.id;
    self.base = Entity.init(position, width, height);
    self.base.id = id;
    self.base.step_height = step_height;
    self.health = 20;
    self.prev_health = 20;
    self.air = max_air;
    self.fire = 0;
    self.fall_distance = 0;
    self.hurt_resistance = 0;
    self.hurt_time = 0;
    self.max_hurt_time = 0;
    self.attacked_at_yaw = 0;
    self.death_time = 0;
    self.last_damage = 0;
    self.damage_remainder = 0;
    self.sleeping = false;
    self.sleep_timer = 0;
    self.bed = null;
    self.bed_offset = .{ 0, 0 };
    self.wake_pending = false;
}

pub const SleepStatus = enum { ok, not_possible_here, not_possible_now, too_far_away, other_problem };

pub fn sleepInBedAt(
    self: *Player,
    world_map: *const world.World,
    dimension: world.Dimension,
    x: i32,
    y: i32,
    z: i32,
) SleepStatus {
    if (self.sleeping or self.isDead()) return .other_problem;
    if (dimension == .nether) return .not_possible_here;
    if (world_map.isDaytime()) return .not_possible_now;
    if (@abs(self.base.position.x - @as(f64, @floatFromInt(x))) > bed_reach_x) return .too_far_away;
    if (@abs(self.base.position.y + eye_height - @as(f64, @floatFromInt(y))) > bed_reach_y) return .too_far_away;
    if (@abs(self.base.position.z - @as(f64, @floatFromInt(z))) > bed_reach_x) return .too_far_away;

    self.layInBed(world_map, x, y, z);
    return .ok;
}

pub fn layInBed(self: *Player, world_map: *const world.World, x: i32, y: i32, z: i32) void {
    self.base.width = sleep_size;
    self.base.height = sleep_size;

    var toward_x: f64 = 0.5;
    var toward_z: f64 = 0.5;
    self.bed_offset = .{ 0, 0 };
    if (world_map.getChunk(x >> 4, z >> 4) != null) {
        switch (world.block.bedFacing(world_map.getBlockMetadata(x, y, z))) {
            0 => {
                toward_z = 0.9;
                self.bed_offset[1] = -bed_body_reach;
            },
            1 => {
                toward_x = 0.1;
                self.bed_offset[0] = bed_body_reach;
            },
            2 => {
                toward_z = 0.1;
                self.bed_offset[1] = bed_body_reach;
            },
            3 => {
                toward_x = 0.9;
                self.bed_offset[0] = -bed_body_reach;
            },
        }
    }

    self.tp(.{
        .x = @as(f64, @floatFromInt(x)) + toward_x,
        .y = @as(f64, @floatFromInt(y)) + bed_pillow_height - sleep_eye_height,
        .z = @as(f64, @floatFromInt(z)) + toward_z,
    });

    self.sleeping = true;
    self.sleep_timer = 0;
    self.bed = .{ x, y, z };
    self.base.motion = math.Vec3.init(0, 0, 0);
}

pub fn wakeUp(self: *Player, world_map: *world.World, immediately: bool, set_spawn: bool) !void {
    self.base.width = width;
    self.base.height = height;
    self.y_size = 0;

    if (self.bed) |spot| {
        if (world_map.getBlock(spot[0], spot[1], spot[2]) == .bed) {
            try world.block_update.setBedOccupied(world_map, spot[0], spot[1], spot[2], false);
            const stand = world.block_update.bedRespawnSpot(world_map, spot[0], spot[1], spot[2], 0) orelse
                [3]i32{ spot[0], spot[1] + 1, spot[2] };
            self.tp(.{
                .x = @as(f64, @floatFromInt(stand[0])) + 0.5,
                .y = @as(f64, @floatFromInt(stand[1])) + wake_stand_lift,
                .z = @as(f64, @floatFromInt(stand[2])) + 0.5,
            });
        }
    }

    self.sleeping = false;
    self.sleep_timer = if (immediately) 0 else sleep_fade_ticks;
    if (set_spawn) self.spawn_point = self.bed;
}

pub fn anchorY(self: Player) f64 {
    return self.base.position.y + if (self.sleeping) sleep_eye_height else eye_height;
}

pub fn isFullyAsleep(self: Player) bool {
    return self.sleeping and self.sleep_timer >= sleep_fade_ticks;
}

pub fn isMovementBlocked(self: Player) bool {
    return self.isDead() or self.sleeping;
}

pub fn isInBed(self: Player, world_map: *const world.World) bool {
    const spot = self.bed orelse return false;
    return world_map.getBlock(spot[0], spot[1], spot[2]) == .bed;
}

pub fn bedOrientationDegrees(self: Player, world_map: *const world.World) f32 {
    const spot = self.bed orelse return 0;
    return switch (world.block.bedFacing(world_map.getBlockMetadata(spot[0], spot[1], spot[2]))) {
        0 => 90,
        1 => 0,
        2 => 270,
        3 => 180,
    };
}

pub fn tickSleep(self: *Player) void {
    if (self.sleeping) {
        self.sleep_timer += 1;
        if (self.sleep_timer > sleep_fade_ticks) self.sleep_timer = sleep_fade_ticks;
        return;
    }
    if (self.sleep_timer > 0) {
        self.sleep_timer += 1;
        if (self.sleep_timer >= sleep_wake_ticks) self.sleep_timer = 0;
    }
}

pub fn tickSleepWake(self: *Player, world_map: *world.World) !bool {
    if (!self.sleeping) return false;

    if (self.wake_pending) {
        self.wake_pending = false;
        try self.wakeUp(world_map, true, false);
    } else if (!self.isInBed(world_map)) {
        try self.wakeUp(world_map, true, false);
    } else if (world_map.isDaytime()) {
        try self.wakeUp(world_map, false, true);
    } else return false;

    return true;
}

pub fn sleepFade(self: Player) f32 {
    if (self.sleep_timer <= 0) return 0;
    const elapsed: f32 = @floatFromInt(self.sleep_timer);
    const fade = elapsed / @as(f32, sleep_fade_ticks);
    if (fade <= 1.0) return fade;
    return 1.0 - (elapsed - @as(f32, sleep_fade_ticks)) / 10.0;
}

pub fn digSpeedFactor(self: Player, world_map: *const world.World) f32 {
    var factor: f32 = 1.0;
    if (self.isSubmerged(world_map)) factor /= 5.0;
    if (!self.base.on_ground) factor /= 5.0;
    return factor;
}

pub fn turnFactor(sensitivity: f32) f32 {
    const s = sensitivity * 0.6 + 0.2;
    return s * s * s * 8.0;
}

pub fn turn(self: *Player, dx: f32, dy: f32, sensitivity: f32, invert: bool) void {
    const factor = turnFactor(sensitivity);
    const pitch_delta = if (invert) -dy else dy;
    self.yaw += dx * factor * turn_scale;
    self.pitch += pitch_delta * factor * turn_scale;
    self.pitch = std.math.clamp(self.pitch, -90.0, 90.0);
}

pub fn lookVector(self: Player) [3]f32 {
    const yaw_rad = self.yaw * std.math.pi / 180.0;
    const pitch_rad = self.pitch * std.math.pi / 180.0;
    return .{
        -@sin(yaw_rad) * @cos(pitch_rad),
        -@sin(pitch_rad),
        @cos(yaw_rad) * @cos(pitch_rad),
    };
}

pub fn moveDirection(self: Player, strafe: f32, forward: f32) [3]f32 {
    const yaw_rad = self.yaw * std.math.pi / 180.0;
    const s = @sin(yaw_rad);
    const c = @cos(yaw_rad);
    var dir = [3]f32{ strafe * c - forward * s, 0, forward * c + strafe * s };
    const len = @sqrt(dir[0] * dir[0] + dir[2] * dir[2]);
    if (len > 1.0) {
        dir[0] /= len;
        dir[2] /= len;
    }
    return dir;
}

pub fn eyePosition(self: Player) math.Vec3 {
    return .{
        .x = self.base.position.x,
        .y = self.base.position.y + eye_height - self.y_size,
        .z = self.base.position.z,
    };
}

fn playStepSound(self: *Player, world_map: *const world.World) void {
    const x = math.util.floorDouble(self.base.position.x);
    const y = math.util.floorDouble(self.base.position.y - 0.2);
    const z = math.util.floorDouble(self.base.position.z);
    const stepped_on = world_map.getBlock(x, y, z);
    if (self.distance_walked <= @as(f32, @floatFromInt(self.next_step_distance)) or stepped_on == .air) return;

    self.next_step_distance += 1;
    const covered = world_map.getBlock(x, y + 1, z) == .snow_layer;
    if (!covered and stepped_on.material().isLiquid()) return;

    const step_sound = if (covered) world.Block.snow_layer.stepSound() else stepped_on.stepSound();
    world_map.playSoundEffect(
        self.base.position.x,
        self.base.position.y,
        self.base.position.z,
        step_sound.walk(),
        step_sound.volume() * 0.15,
        step_sound.pitch(),
    );
}

pub const swing_duration: i32 = 8;

pub fn swingItem(self: *Player) void {
    self.swing_ticks = -1;
    self.is_swinging = true;
}

pub fn tickSwing(self: *Player) void {
    self.prev_swing_progress = self.swing_progress;
    if (self.is_swinging) {
        self.swing_ticks += 1;
        if (self.swing_ticks >= swing_duration) {
            self.swing_ticks = 0;
            self.is_swinging = false;
        }
    } else {
        self.swing_ticks = 0;
    }
    self.swing_progress = @as(f32, @floatFromInt(self.swing_ticks)) / @as(f32, swing_duration);
}

pub fn swingProgress(self: Player, partial_ticks: f32) f32 {
    var delta = self.swing_progress - self.prev_swing_progress;
    if (delta < 0.0) delta += 1.0;
    return self.prev_swing_progress + delta * partial_ticks;
}

pub fn viewRotation(self: Player) math.Mat4 {
    const degrees = std.math.pi / 180.0;
    return math.Mat4.rotationX(self.pitch * degrees)
        .mul(math.Mat4.rotationY((self.yaw + 180.0) * degrees));
}

pub fn viewMatrix(self: Player, partial_ticks: f32) math.Mat4 {
    const render_position = self.base.renderPosition(partial_ticks);
    const dip = self.prev_y_size + (self.y_size - self.prev_y_size) * @as(f64, partial_ticks);
    const eye_x: f32 = @floatCast(render_position.x);
    const eye_y: f32 = @floatCast(render_position.y + eye_height - dip);
    const eye_z: f32 = @floatCast(render_position.z);
    return self.viewRotation()
        .mul(math.Mat4.translation(-eye_x, -eye_y, -eye_z));
}

pub fn sleepFacingDegrees(self: Player, world_map: *const world.World) f32 {
    const x = math.util.floorDouble(self.base.position.x);
    const y = math.util.floorDouble(self.anchorY());
    const z = math.util.floorDouble(self.base.position.z);
    if (world_map.getBlock(x, y, z) != .bed) return 0;
    return @floatFromInt(@as(i32, world.block.bedFacing(world_map.getBlockMetadata(x, y, z))) * 90);
}

pub fn cameraRotation(self: Player, world_map: *const world.World) math.Mat4 {
    if (!self.sleeping) return self.viewRotation();
    return math.Mat4.rotationY(self.sleepFacingDegrees(world_map) * std.math.pi / 180.0);
}

pub fn sleepViewMatrix(self: Player, world_map: *const world.World, partial_ticks: f32) math.Mat4 {
    const render_position = self.base.renderPosition(partial_ticks);
    const eye_x: f32 = @floatCast(render_position.x);
    const eye_y: f32 = @floatCast(render_position.y + sleep_eye_height + bed_camera_height);
    const eye_z: f32 = @floatCast(render_position.z);
    return self.cameraRotation(world_map)
        .mul(math.Mat4.translation(-eye_x, -eye_y, -eye_z));
}

const opaque_probe_eye: f64 = 0.12;

pub fn isInsideOpaqueBlock(self: Player, world_map: *const world.World) bool {
    for (0..8) |corner| {
        const index: i32 = @intCast(corner);
        const dx = (@as(f64, @floatFromInt(@rem(index, 2))) - 0.5) * width * 0.9;
        const dy = (@as(f64, @floatFromInt(@rem(@divTrunc(index, 2), 2))) - 0.5) * 0.1;
        const dz = (@as(f64, @floatFromInt(@rem(@divTrunc(index, 4), 2))) - 0.5) * width * 0.9;
        const x = math.util.floorDouble(self.base.position.x + dx);
        const y = math.util.floorDouble(self.base.position.y + eye_height + opaque_probe_eye + dy);
        const z = math.util.floorDouble(self.base.position.z + dz);
        if (world_map.getBlock(x, y, z).isOpaqueCube()) return true;
    }
    return false;
}

pub const third_person_distance: f64 = 4.0;
const camera_probe_offset: f32 = 0.1;

pub fn thirdPersonDistance(self: Player, world_map: *const world.World, partial_ticks: f32) f64 {
    const degrees = std.math.pi / 180.0;
    const eye = self.base.renderPosition(partial_ticks);
    const eye_y = eye.y + eye_height;

    const back_x = @as(f64, -math.util.sin(self.yaw * degrees) * math.util.cos(self.pitch * degrees)) * third_person_distance;
    const back_z = @as(f64, math.util.cos(self.yaw * degrees) * math.util.cos(self.pitch * degrees)) * third_person_distance;
    const back_y = @as(f64, -math.util.sin(self.pitch * degrees)) * third_person_distance;

    var distance = third_person_distance;
    for (0..8) |corner| {
        const index: i32 = @intCast(corner);
        const dx: f64 = @as(f64, @floatFromInt((index & 1) * 2 - 1)) * camera_probe_offset;
        const dy: f64 = @as(f64, @floatFromInt((index >> 1 & 1) * 2 - 1)) * camera_probe_offset;
        const dz: f64 = @as(f64, @floatFromInt((index >> 2 & 1) * 2 - 1)) * camera_probe_offset;

        const from = math.Vec3.init(eye.x + dx, eye_y + dy, eye.z + dz);
        const to = math.Vec3.init(eye.x - back_x + dx + dz, eye_y - back_y + dy, eye.z - back_z + dz);
        const span = math.Vec3.init(to.x - from.x, to.y - from.y, to.z - from.z);
        const length = @sqrt(span.x * span.x + span.y * span.y + span.z * span.z);
        if (length == 0.0) continue;

        const direction = [3]f32{
            @floatCast(span.x / length),
            @floatCast(span.y / length),
            @floatCast(span.z / length),
        };
        const hit = raycast.cast(world_map, from, direction, length) orelse continue;

        const hit_x = from.x + span.x * (hit.distance / length);
        const hit_y = from.y + span.y * (hit.distance / length);
        const hit_z = from.z + span.z * (hit.distance / length);
        const to_eye_x = hit_x - eye.x;
        const to_eye_y = hit_y - eye_y;
        const to_eye_z = hit_z - eye.z;
        const reached = @sqrt(to_eye_x * to_eye_x + to_eye_y * to_eye_y + to_eye_z * to_eye_z);
        if (reached < distance) distance = reached;
    }
    return distance;
}

pub fn hurtMatrix(self: Player, partial_ticks: f32) math.Mat4 {
    const degrees = std.math.pi / 180.0;
    var transform = math.Mat4.identity;

    if (self.health <= 0) {
        const dying = @as(f32, @floatFromInt(self.death_time)) + partial_ticks;
        transform = transform.mul(math.Mat4.rotationZ((40.0 - 8000.0 / (dying + 200.0)) * degrees));
    }

    const elapsed = @as(f32, @floatFromInt(self.hurt_time)) - partial_ticks;
    if (elapsed < 0.0 or self.max_hurt_time == 0) return transform;

    const phase = elapsed / @as(f32, @floatFromInt(self.max_hurt_time));
    const tilt = math.util.sin(phase * phase * phase * phase * std.math.pi);
    const yaw = self.attacked_at_yaw;
    return transform
        .mul(math.Mat4.rotationY(-yaw * degrees))
        .mul(math.Mat4.rotationZ(-tilt * 14.0 * degrees))
        .mul(math.Mat4.rotationY(yaw * degrees));
}

const portal_spin_per_tick: f32 = 20.0;
const portal_spin_period: u64 = 18;

pub fn portalMatrix(self: Player, partial_ticks: f32, ticks: u64) math.Mat4 {
    const overlay = self.portalOverlay(partial_ticks);
    if (overlay <= 0.0) return math.Mat4.identity;

    var squeeze = 5.0 / (overlay * overlay + 5.0) - overlay * 0.04;
    squeeze *= squeeze;

    const degrees = std.math.pi / 180.0;
    const turned: f32 = @floatFromInt(ticks % portal_spin_period);
    const spin = (turned + partial_ticks) * portal_spin_per_tick * degrees;

    return math.Mat4.rotationAxis(0, 1, 1, spin)
        .mul(math.Mat4.scale(1.0 / squeeze, 1.0, 1.0))
        .mul(math.Mat4.rotationAxis(0, 1, 1, -spin));
}

pub fn bobMatrix(self: Player, partial_ticks: f32) math.Mat4 {
    const step = self.distance_walked - self.prev_distance_walked;
    const walk = -(self.distance_walked + step * partial_ticks);
    const swing = self.prev_camera_yaw + (self.camera_yaw - self.prev_camera_yaw) * partial_ticks;
    const dip = self.prev_camera_pitch + (self.camera_pitch - self.prev_camera_pitch) * partial_ticks;

    const phase = walk * std.math.pi;
    const sway = math.util.sin(phase) * swing;
    const lift = @abs(math.util.cos(phase) * swing);
    const tilt = @abs(math.util.cos(phase - 0.2) * swing) * 5.0;

    const degrees = std.math.pi / 180.0;
    return math.Mat4.translation(sway * 0.5, -lift, 0)
        .mul(math.Mat4.rotationZ(sway * 3.0 * degrees))
        .mul(math.Mat4.rotationX(tilt * degrees))
        .mul(math.Mat4.rotationX(dip * degrees));
}

test "eyePosition sits eye_height above the feet position" {
    const player = Player.spawn(math.Vec3.init(2, 5, 3));
    const eye = player.eyePosition();
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), eye.x, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0 + eye_height), eye.y, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), eye.z, 1.0e-9);
}

test "turn at default sensitivity applies the 0.15 deg/pixel scale" {
    var player = Player.spawn(math.Vec3.init(0, 0, 0));
    player.turn(10, 4, 0.5, false);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), player.yaw, 1.0e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), player.pitch, 1.0e-4);
}

test "inverting the mouse flips the pitch delta" {
    var player = Player.spawn(math.Vec3.init(0, 0, 0));
    player.turn(0, 4, 0.5, true);
    try std.testing.expectApproxEqAbs(@as(f32, -0.6), player.pitch, 1.0e-4);
}

test "pitch clamps to +/-90 degrees" {
    var player = Player.spawn(math.Vec3.init(0, 0, 0));
    player.turn(0, 10000, 0.5, false);
    try std.testing.expectApproxEqAbs(@as(f32, 90.0), player.pitch, 1.0e-4);
    player.turn(0, -20000, 0.5, false);
    try std.testing.expectApproxEqAbs(@as(f32, -90.0), player.pitch, 1.0e-4);
}

test "lookVector faces +Z at yaw 0, pitch 0" {
    const player = Player.spawn(math.Vec3.init(0, 0, 0));
    const look = player.lookVector();
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), look[0], 1.0e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), look[1], 1.0e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), look[2], 1.0e-5);
}

test "positive pitch looks down, negative pitch looks up" {
    var player = Player.spawn(math.Vec3.init(0, 0, 0));
    player.pitch = 90;
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), player.lookVector()[1], 1.0e-4);
    player.pitch = -90;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), player.lookVector()[1], 1.0e-4);
}

const test_eye_y: f32 = 90.0 + @as(f32, @floatCast(eye_height));

fn project(player: Player, point: [3]f32) [4]f32 {
    const vp = math.Mat4.perspective(70.0 * std.math.pi / 180.0, 16.0 / 9.0, 0.05, 1000.0).mul(player.viewMatrix(0));
    const cells: [16]f32 = vp.m;
    var out: [4]f32 = .{ 0, 0, 0, 0 };
    const v = [4]f32{ point[0], point[1], point[2], 1 };
    for (0..4) |col| {
        for (0..4) |row| out[row] += cells[col * 4 + row] * v[col];
    }
    return out;
}

fn isOnScreen(clip: [4]f32) bool {
    if (!(clip[3] > 0)) return false;
    return @abs(clip[0]) <= clip[3] and @abs(clip[1]) <= clip[3] and @abs(clip[2]) <= clip[3];
}

test "the ground stays visible when looking straight down" {
    var player = Player.spawn(math.Vec3.init(8, 90, 8));
    player.pitch = 90;
    for ([_]f32{ 0, 45, 137, -200 }) |yaw| {
        player.yaw = yaw;
        try std.testing.expect(isOnScreen(project(player, .{ 8, 85, 8 })));
    }
}

test "the sky side stays visible when looking straight up" {
    var player = Player.spawn(math.Vec3.init(8, 90, 8));
    player.pitch = -90;
    try std.testing.expect(isOnScreen(project(player, .{ 8, 95, 8 })));
}

test "a block ahead projects to the screen center at yaw 0" {
    const player = Player.spawn(math.Vec3.init(8, 90, 8));
    const clip = project(player, .{ 8, test_eye_y, 12 });
    try std.testing.expect(clip[3] > 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0), clip[0] / clip[3], 1.0e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), clip[1] / clip[3], 1.0e-5);
}

test "what is behind the camera is not on screen" {
    const player = Player.spawn(math.Vec3.init(8, 90, 8));
    try std.testing.expect(!isOnScreen(project(player, .{ 8, test_eye_y, 4 })));
}

test "turning right moves what is ahead to the left of the screen" {
    var player = Player.spawn(math.Vec3.init(8, 90, 8));
    player.turn(100, 0, 0.5, false);
    const clip = project(player, .{ 8, test_eye_y, 12 });
    try std.testing.expect(clip[3] > 0);
    try std.testing.expect(clip[0] / clip[3] < 0);
}

test "looking down moves what is ahead to the top of the screen" {
    var player = Player.spawn(math.Vec3.init(8, 90, 8));
    player.turn(0, 100, 0.5, false);
    const clip = project(player, .{ 8, test_eye_y, 12 });
    try std.testing.expect(clip[3] > 0);
    try std.testing.expect(clip[1] / clip[3] > 0);
}

test "moveDirection at yaw 0 matches forward/strafe axes" {
    const player = Player.spawn(math.Vec3.init(0, 0, 0));
    const forward = player.moveDirection(0, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), forward[0], 1.0e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), forward[2], 1.0e-5);

    const strafe = player.moveDirection(1, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), strafe[0], 1.0e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), strafe[2], 1.0e-5);
}

test "resting on the ground stays grounded" {
    var w = try world.testing.flatWorld(std.testing.allocator, 1);
    defer w.deinit();
    var player = Player.spawn(math.Vec3.init(8, 1, 8));
    player.base.on_ground = true;
    player.base.motion = math.Vec3.init(0, -0.0784, 0);
    player.tick(&w, 0, 0, false, false);
    try std.testing.expect(player.base.on_ground);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), player.base.position.y, 1.0e-9);
}

test "a cactus pricks the player perched on it" {
    var w = try world.testing.flatWorld(std.testing.allocator, 1);
    defer w.deinit();
    w.setBlock(8, 1, 8, .cactus);

    var pricked = Player.spawn(math.Vec3.init(8, 2.0 - 1.0 / 16.0, 8));
    pricked.base.on_ground = true;
    pricked.tick(&w, 0, 0, false, false);
    try std.testing.expectEqual(@as(i32, 19), pricked.health);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0 - 1.0 / 16.0), pricked.base.position.y, 1.0e-9);

    var spared = Player.spawn(math.Vec3.init(4, 1, 4));
    spared.base.on_ground = true;
    spared.tick(&w, 0, 0, false, false);
    try std.testing.expectEqual(@as(i32, 20), spared.health);
}

test "gravity accelerates a falling player" {
    var w = try world.testing.flatWorld(std.testing.allocator, 0);
    defer w.deinit();
    var player = Player.spawn(math.Vec3.init(8, 50, 8));
    player.tick(&w, 0, 0, false, false);
    try std.testing.expectApproxEqAbs(@as(f64, -0.0784), player.base.motion.y, 1.0e-9);
}

test "jumping from the ground sets the jump velocity" {
    var w = try world.testing.flatWorld(std.testing.allocator, 1);
    defer w.deinit();
    var player = Player.spawn(math.Vec3.init(8, 1, 8));
    player.base.on_ground = true;
    player.tick(&w, 0, 0, true, false);
    try std.testing.expectApproxEqAbs(@as(f64, (0.42 - 0.08) * 0.98), player.base.motion.y, 1.0e-9);
}

test "forward input on the ground moves the player each tick" {
    var w = try world.testing.flatWorld(std.testing.allocator, 1);
    defer w.deinit();
    var player = Player.spawn(math.Vec3.init(8, 1, 8));
    player.base.on_ground = true;
    player.tick(&w, 0, 1, false, false);
    try std.testing.expectApproxEqAbs(@as(f64, 8.1), player.base.position.z, 1.0e-9);
}

test "bobbing is the identity while standing still" {
    const player = Player.spawn(math.Vec3.init(0, 0, 0));
    const bob: [16]f32 = player.bobMatrix(0.5).m;
    const want: [16]f32 = math.Mat4.identity.m;
    for (bob, want) |got, expected| {
        try std.testing.expectApproxEqAbs(expected, got, 1.0e-6);
    }
}

test "bobbing sways to both sides and never lifts the camera" {
    var player = Player.spawn(math.Vec3.init(0, 0, 0));
    player.camera_yaw = 0.1;
    player.prev_camera_yaw = 0.1;

    var swayed_left = false;
    var swayed_right = false;
    var walked: f32 = 0;
    while (walked < 4.0) : (walked += 0.05) {
        player.prev_distance_walked = walked;
        player.distance_walked = walked;
        const bob: [16]f32 = player.bobMatrix(0).m;
        if (bob[12] < -1.0e-4) swayed_left = true;
        if (bob[12] > 1.0e-4) swayed_right = true;
        try std.testing.expect(bob[13] <= 1.0e-6);
    }

    try std.testing.expect(swayed_left);
    try std.testing.expect(swayed_right);
}

test "a long walk does not overflow MathHelper's sine table index" {
    var player = Player.spawn(math.Vec3.init(0, 0, 0));
    player.camera_yaw = 0.1;
    player.prev_camera_yaw = 0.1;
    player.distance_walked = 1.0e9;
    player.prev_distance_walked = 1.0e9;
    _ = player.bobMatrix(0.5);
}

fn floodedWorld(surface_y: u32) !world.World {
    var w = try world.testing.flatWorld(std.testing.allocator, 1);
    errdefer w.deinit();
    const chunk = w.getChunk(0, 0).?;
    for (0..world.Chunk.width) |x| {
        for (0..world.Chunk.width) |z| {
            var y: u32 = 1;
            while (y < surface_y) : (y += 1) {
                chunk.setBlock(@intCast(x), y, @intCast(z), .stationary_water);
            }
        }
    }
    return w;
}

test "a player in water sinks far more slowly than one falling through air" {
    var w = try floodedWorld(20);
    defer w.deinit();

    var swimmer = Player.spawn(math.Vec3.init(8, 10, 8));
    swimmer.tick(&w, 0, 0, false, false);
    try std.testing.expect(swimmer.base.in_water);
    try std.testing.expectApproxEqAbs(@as(f64, -liquid_gravity), swimmer.base.motion.y, 1.0e-9);

    var faller = Player.spawn(math.Vec3.init(8, 40, 8));
    faller.tick(&w, 0, 0, false, false);
    try std.testing.expect(!faller.base.in_water);
    try std.testing.expect(faller.base.motion.y < swimmer.base.motion.y);
}

test "holding jump underwater swims upward instead of doing nothing" {
    var w = try floodedWorld(20);
    defer w.deinit();

    var player = Player.spawn(math.Vec3.init(8, 10, 8));
    for (0..10) |_| player.tick(&w, 0, 0, true, false);
    try std.testing.expect(player.base.motion.y > 0.0);
    try std.testing.expect(player.base.position.y > 10.0);
}

fn lavaWorld(surface_y: u32) !world.World {
    var w = try world.testing.flatWorld(std.testing.allocator, 1);
    errdefer w.deinit();
    const chunk = w.getChunk(0, 0).?;
    for (0..world.Chunk.width) |x| {
        for (0..world.Chunk.width) |z| {
            var y: u32 = 1;
            while (y < surface_y) : (y += 1) {
                chunk.setBlock(@intCast(x), y, @intCast(z), .stationary_lava);
            }
        }
    }
    return w;
}

test "lava scalds on contact and leaves the player alight for half a minute" {
    var w = try lavaWorld(20);
    defer w.deinit();

    var player = Player.spawn(math.Vec3.init(8, 10, 8));
    player.tick(&w, 0, 0, false, false);
    try std.testing.expect(player.in_lava);
    try std.testing.expectEqual(@as(i32, 16), player.health);
    try std.testing.expectEqual(@as(i32, lava_fire_ticks), player.fire);
}

test "burning outside lava costs half a heart a second until the flames die" {
    var w = try world.testing.flatWorld(std.testing.allocator, 1);
    defer w.deinit();

    var player = Player.spawn(math.Vec3.init(8, 1, 8));
    player.base.on_ground = true;
    player.fire = 40;

    for (0..40) |_| player.tick(&w, 0, 0, false, false);
    try std.testing.expectEqual(@as(i32, 0), player.fire);
    try std.testing.expectEqual(@as(i32, 18), player.health);
}

test "water snuffs the flames out" {
    var w = try floodedWorld(20);
    defer w.deinit();

    var player = Player.spawn(math.Vec3.init(8, 10, 8));
    player.fire = lava_fire_ticks;
    player.tick(&w, 0, 0, false, false);
    try std.testing.expectEqual(@as(i32, 0), player.fire);
}

test "wading through lava is slower than swimming the same input" {
    var flooded = try floodedWorld(20);
    defer flooded.deinit();
    var swimmer = Player.spawn(math.Vec3.init(8, 10, 8));
    swimmer.tick(&flooded, 0, 1, false, false);

    var molten = try lavaWorld(20);
    defer molten.deinit();
    var waders = Player.spawn(math.Vec3.init(8, 10, 8));
    waders.tick(&molten, 0, 1, false, false);

    try std.testing.expect(waders.base.motion.z < swimmer.base.motion.z);
    try std.testing.expectApproxEqAbs(swimmer.base.motion.z * lava_drag / water_drag, waders.base.motion.z, 1.0e-9);
}

test "swimming forward is slower than walking the same input on land" {
    var dry = try world.testing.flatWorld(std.testing.allocator, 1);
    defer dry.deinit();
    var walker = Player.spawn(math.Vec3.init(8, 1, 8));
    walker.base.on_ground = true;
    walker.tick(&dry, 0, 1, false, false);

    var flooded = try floodedWorld(20);
    defer flooded.deinit();
    var swimmer = Player.spawn(math.Vec3.init(8, 10, 8));
    swimmer.tick(&flooded, 0, 1, false, false);

    try std.testing.expect(swimmer.base.position.z - 8.0 < walker.base.position.z - 8.0);
}

test "air holds for 300 ticks underwater and then drowning starts" {
    var w = try floodedWorld(20);
    defer w.deinit();

    var player = Player.spawn(math.Vec3.init(8, 10, 8));
    player.base.motion = math.Vec3.init(0, 0, 0);

    for (0..max_air) |_| {
        player.updateAir(&w);
        player.base.position.y = 10;
    }
    try std.testing.expectEqual(@as(i32, 20), player.health);
    try std.testing.expectEqual(@as(i32, 0), player.air);

    for (0..20) |_| player.updateAir(&w);
    try std.testing.expectEqual(@as(i32, 18), player.health);
    try std.testing.expectEqual(@as(i32, 0), player.air);
}

test "the drowning flag is raised only on the tick the lungs give out" {
    var w = try floodedWorld(20);
    defer w.deinit();

    var player = Player.spawn(math.Vec3.init(8, 10, 8));
    for (0..max_air + 19) |_| {
        player.drowned = false;
        player.updateAir(&w);
        try std.testing.expect(!player.drowned);
    }

    player.updateAir(&w);
    try std.testing.expect(player.drowned);

    player.tick(&w, 0, 0, false, false);
    try std.testing.expect(!player.drowned);
}

test "a fall costs half a heart for every block past the third" {
    var player = Player.spawn(math.Vec3.init(8, 20, 8));
    player.updateFallState(-2.0);
    player.updateFallState(-3.5);
    player.base.on_ground = true;
    player.updateFallState(0);

    try std.testing.expectEqual(@as(i32, 17), player.health);
    try std.testing.expectEqual(@as(i32, 3), player.damage_taken);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), player.fall_distance, 1.0e-6);
}

test "a three block drop is walked away from unhurt" {
    var player = Player.spawn(math.Vec3.init(8, 20, 8));
    player.updateFallState(-3.0);
    player.base.on_ground = true;
    player.updateFallState(0);

    try std.testing.expectEqual(@as(i32, 20), player.health);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), player.fall_distance, 1.0e-6);
}

test "a fall of two blocks or more is counted as distance fallen" {
    var player = Player.spawn(math.Vec3.init(8, 20, 8));
    player.updateFallState(-1.5);
    player.base.on_ground = true;
    player.updateFallState(0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), player.distance_fallen, 1.0e-6);

    player.base.on_ground = false;
    player.updateFallState(-2.5);
    player.base.on_ground = true;
    player.updateFallState(0);
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), player.distance_fallen, 1.0e-6);
}

test "killing outright empties the health bar, armour or no armour" {
    var player = Player.spawn(math.Vec3.init(8, 20, 8));
    player.inventory.armor[0] = .{ .id = .{ .item = .helmet_diamond }, .count = 1 };
    player.health = 7;
    player.kill();

    try std.testing.expect(player.isDead());
    try std.testing.expectEqual(@as(i32, 0), player.health);
    try std.testing.expectEqual(@as(i32, 7), player.damage_taken);
    try std.testing.expect(player.inventory.armor[0] != null);
}

test "respawning restores health and air and forgets the fall" {
    var player = Player.spawn(math.Vec3.init(8, 20, 8));
    player.health = 0;
    player.air = 0;
    player.fall_distance = 12.0;
    player.damage_remainder = 17;
    player.base.motion = math.Vec3.init(0, -3, 0);
    player.inventory.slots[0] = .{ .id = .{ .block = .stone }, .count = 1 };

    player.respawn(math.Vec3.init(1.5, 64, 2.5));

    try std.testing.expect(!player.isDead());
    try std.testing.expectEqual(@as(i32, 20), player.health);
    try std.testing.expectEqual(max_air, player.air);
    try std.testing.expectEqual(@as(i32, 0), player.damage_remainder);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), player.fall_distance, 1.0e-6);
    try std.testing.expectEqual(@as(f64, 64.0), player.base.position.y);
    try std.testing.expectEqual(@as(f64, 64.0), player.base.prev_position.y);
    try std.testing.expectEqual(@as(f64, 0.0), player.base.motion.y);
    try std.testing.expectEqual(step_height, player.base.step_height);
    try std.testing.expect(player.inventory.slots[0] != null);
}

test "falling out of the sky hurts on landing" {
    var w = try world.testing.flatWorld(std.testing.allocator, 1);
    defer w.deinit();

    var player = Player.spawn(math.Vec3.init(8, 30, 8));
    for (0..200) |_| {
        player.tick(&w, 0, 0, false, false);
        if (player.base.on_ground) break;
    }

    try std.testing.expect(player.base.on_ground);
    try std.testing.expect(player.health < 20);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), player.fall_distance, 1.0e-6);
}

test "hitting water cancels the fall instead of hurting" {
    var w = try floodedWorld(8);
    defer w.deinit();

    var player = Player.spawn(math.Vec3.init(8, 40, 8));
    for (0..200) |_| {
        player.tick(&w, 0, 0, false, false);
        if (player.base.on_ground) break;
    }

    try std.testing.expect(player.base.on_ground);
    try std.testing.expectEqual(@as(i32, 20), player.health);
}

test "a full diamond suit soaks four fifths of a hit and wears down doing it" {
    var player = Player.spawn(math.Vec3.init(0, 64, 0));
    inline for (.{ .helmet, .chestplate, .leggings, .boots }, .{
        world.Item.helmet_diamond,
        world.Item.chestplate_diamond,
        world.Item.leggings_diamond,
        world.Item.boots_diamond,
    }) |slot, id| {
        player.inventory.armorSlot(slot).* = .{ .id = .{ .item = id }, .count = 1 };
    }
    try std.testing.expectEqual(@as(i32, 20), player.inventory.totalArmorValue());

    player.hurt(10);
    try std.testing.expectEqual(@as(i32, 18), player.health);
    try std.testing.expectEqual(@as(u16, 10), player.inventory.armorSlot(.helmet).*.?.meta);
}

test "the twenty-fifths armour rounds away carry into the next hit" {
    var player = Player.spawn(math.Vec3.init(0, 64, 0));
    player.inventory.armorSlot(.chestplate).* = .{ .id = .{ .item = .chestplate_iron }, .count = 1 };

    player.applyDamage(2);
    try std.testing.expectEqual(@as(i32, 19), player.health);
    try std.testing.expectEqual(@as(i32, 9), player.damage_remainder);

    player.applyDamage(2);
    try std.testing.expectEqual(@as(i32, 18), player.health);
    try std.testing.expectEqual(@as(i32, 20), player.damage_remainder);
}

test "a second hit inside the resistance window is shrugged off unless it is harder" {
    var player = Player.spawn(math.Vec3.init(0, 64, 0));

    player.hurt(4);
    try std.testing.expectEqual(@as(i32, 16), player.health);

    player.hurt(4);
    try std.testing.expectEqual(@as(i32, 16), player.health);

    player.hurt(6);
    try std.testing.expectEqual(@as(i32, 14), player.health);
}

test "sneaking walks at a third of normal speed" {
    var w = try world.testing.flatWorld(std.testing.allocator, 1);
    defer w.deinit();
    var player = Player.spawn(math.Vec3.init(8, 1, 8));
    player.base.on_ground = true;
    player.tick(&w, 0, 1, false, true);
    try std.testing.expectApproxEqAbs(@as(f64, 8.03), player.base.position.z, 1.0e-6);
}

test "a sneaking player will not walk off the edge of a block" {
    var w = try world.testing.flatWorld(std.testing.allocator, 0);
    defer w.deinit();
    w.getChunk(0, 0).?.setBlock(8, 0, 8, .stone);

    var sneaker = Player.spawn(math.Vec3.init(8.5, 1, 8.5));
    sneaker.base.on_ground = true;
    for (0..40) |_| sneaker.tick(&w, 0, 1, false, true);
    try std.testing.expect(sneaker.base.on_ground);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), sneaker.base.position.y, 1.0e-9);
    try std.testing.expect(sneaker.base.position.z < 9.3);

    var walker = Player.spawn(math.Vec3.init(8.5, 1, 8.5));
    walker.base.on_ground = true;
    for (0..40) |_| walker.tick(&w, 0, 1, false, false);
    try std.testing.expect(walker.base.position.y < 1.0);
}

test "sneaking dips the camera a fifth of a block and eases back up" {
    var w = try world.testing.flatWorld(std.testing.allocator, 1);
    defer w.deinit();
    var player = Player.spawn(math.Vec3.init(8, 1, 8));
    player.base.on_ground = true;

    player.tick(&w, 0, 0, false, true);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 + eye_height - 0.2), player.eyePosition().y, 1.0e-9);

    player.tick(&w, 0, 0, false, false);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 + eye_height - 0.08), player.eyePosition().y, 1.0e-9);
}

test "surfacing refills the air supply immediately" {
    var w = try floodedWorld(20);
    defer w.deinit();

    var player = Player.spawn(math.Vec3.init(8, 10, 8));
    for (0..50) |_| player.updateAir(&w);
    try std.testing.expect(player.air < max_air);

    player.base.position.y = 40;
    player.updateAir(&w);
    try std.testing.expectEqual(max_air, player.air);
}

test "the body turns to follow the direction of travel" {
    var w = try world.testing.flatWorld(std.testing.allocator, 1);
    defer w.deinit();
    var player = Player.spawn(math.Vec3.init(8, 1, 8));
    player.base.on_ground = true;

    for (0..20) |_| player.tick(&w, 0, 1, false, false);

    try std.testing.expect(player.base.position.z > 8.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), wrapDegrees(player.render_yaw), 1.0e-3);
}

test "the head never twists more than 75 degrees away from the body" {
    var w = try world.testing.flatWorld(std.testing.allocator, 1);
    defer w.deinit();
    var player = Player.spawn(math.Vec3.init(8, 1, 8));
    player.base.on_ground = true;

    player.yaw = 170;
    player.tick(&w, 0, 0, false, false);

    try std.testing.expect(@abs(wrapDegrees(player.yaw - player.render_yaw)) <= 75.0 + 1.0e-3);
}

test "walking builds up the limb swing, standing still lets it fall away" {
    var w = try world.testing.flatWorld(std.testing.allocator, 1);
    defer w.deinit();
    var player = Player.spawn(math.Vec3.init(8, 1, 8));
    player.base.on_ground = true;

    for (0..20) |_| player.tick(&w, 0, 1, false, false);
    const walking = player.limb_swing_amount;
    try std.testing.expect(walking > 0.3);

    for (0..20) |_| player.tick(&w, 0, 0, false, false);
    try std.testing.expect(player.limb_swing_amount < walking * 0.1);
}

test "the third person camera sits four blocks back in the open" {
    var w = try world.testing.flatWorld(std.testing.allocator, 1);
    defer w.deinit();
    var player = Player.spawn(math.Vec3.init(8, 10, 8));

    try std.testing.expectApproxEqAbs(third_person_distance, player.thirdPersonDistance(&w, 0), 1.0e-9);
}

test "the third person camera stops short of a wall behind the player" {
    var w = try world.testing.flatWorld(std.testing.allocator, 1);
    defer w.deinit();
    const chunk = w.getChunk(0, 0).?;
    for (0..6) |y| chunk.setBlock(8, @intCast(y), 5, .stone);

    var player = Player.spawn(math.Vec3.init(8.5, 1, 8.5));
    player.yaw = 0;

    const pulled = player.thirdPersonDistance(&w, 0);
    try std.testing.expect(pulled < third_person_distance);
    try std.testing.expect(pulled > 0.0);
}

test "standing in the open is not standing inside a block" {
    var w = try world.testing.flatWorld(std.testing.allocator, 1);
    defer w.deinit();
    const player = Player.spawn(math.Vec3.init(8.5, 1, 8.5));

    try std.testing.expect(!player.isInsideOpaqueBlock(&w));
}

test "a block at head height counts as being inside it" {
    var w = try world.testing.flatWorld(std.testing.allocator, 1);
    defer w.deinit();
    const chunk = w.getChunk(0, 0).?;
    chunk.setBlock(8, 2, 8, .stone);

    const player = Player.spawn(math.Vec3.init(8.5, 1, 8.5));
    try std.testing.expect(player.isInsideOpaqueBlock(&w));
}

test "a player walks up a slab without jumping" {
    var w = try world.testing.flatWorld(std.testing.allocator, 1);
    defer w.deinit();
    w.setBlock(10, 1, 8, .slab);

    var player = Player.spawn(math.Vec3.init(8.5, 1, 8.5));
    player.base.on_ground = true;
    player.yaw = -90;

    for (0..14) |_| {
        player.tick(&w, 0, 1, false, false);
        try std.testing.expect(!player.jumped);
    }

    try std.testing.expect(player.base.position.x > 10.0);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), player.base.position.y, 1.0e-9);
}

test "a player climbs a stair's tread and back in two steps, never jumping" {
    var w = try world.testing.flatWorld(std.testing.allocator, 1);
    defer w.deinit();
    try w.setBlockAndMetadataWithNotify(10, 1, 8, .stairs_cobblestone, 0);

    var player = Player.spawn(math.Vec3.init(8.5, 1, 8.5));
    player.base.on_ground = true;
    player.yaw = -90;

    var reached_tread = false;
    for (0..16) |_| {
        player.tick(&w, 0, 1, false, false);
        try std.testing.expect(!player.jumped);
        if (player.base.position.y == 1.5) reached_tread = true;
    }

    try std.testing.expect(reached_tread);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), player.base.position.y, 1.0e-9);
    try std.testing.expect(player.base.position.x > 10.0);
}

test "without step height the same slab stops the player where they stand" {
    var w = try world.testing.flatWorld(std.testing.allocator, 1);
    defer w.deinit();
    w.setBlock(10, 1, 8, .slab);

    var player = Player.spawn(math.Vec3.init(8.5, 1, 8.5));
    player.base.step_height = 0;
    player.base.on_ground = true;
    player.yaw = -90;

    for (0..14) |_| player.tick(&w, 0, 1, false, false);

    try std.testing.expectApproxEqAbs(@as(f64, 1.0), player.base.position.y, 1.0e-9);
    try std.testing.expect(player.base.position.x < 10.0);
}

test "a player spawns with the half-block step height EntityLiving grants" {
    const player = Player.spawn(math.Vec3.init(0, 0, 0));
    try std.testing.expectEqual(step_height, player.base.step_height);
    try std.testing.expectEqual(@as(f64, 0.5), player.base.step_height);
}

test "healing tops out at full health and never revives the dead" {
    var player = Player.spawn(math.Vec3.init(0, 64, 0));

    player.health = 14;
    player.heal(3);
    try std.testing.expectEqual(@as(i32, 17), player.health);

    player.heal(9);
    try std.testing.expectEqual(@as(i32, 20), player.health);

    player.health = 0;
    player.heal(3);
    try std.testing.expectEqual(@as(i32, 0), player.health);
}

test "taking a hit starts a ten tick hurt animation and remembers the health before it" {
    var player = Player.spawn(math.Vec3.init(0, 64, 0));
    player.hurt(4);

    try std.testing.expectEqual(@as(i32, 20), player.prev_health);
    try std.testing.expectEqual(@as(i32, 16), player.health);
    try std.testing.expectEqual(@as(i32, 10), player.hurt_time);
    try std.testing.expectEqual(@as(i32, 10), player.max_hurt_time);
    try std.testing.expect(player.attacked_at_yaw == 0.0 or player.attacked_at_yaw == 180.0);
}

test "a hit shrugged off inside the resistance window does not restart the animation" {
    var player = Player.spawn(math.Vec3.init(0, 64, 0));
    player.hurt(4);
    player.hurt_time = 3;
    player.hurt(6);

    try std.testing.expectEqual(@as(i32, 20), player.prev_health);
    try std.testing.expectEqual(@as(i32, 14), player.health);
    try std.testing.expectEqual(@as(i32, 3), player.hurt_time);
}

test "healing halves the resistance window so the hearts stop flashing" {
    var player = Player.spawn(math.Vec3.init(0, 64, 0));
    player.hurt(4);
    try std.testing.expectEqual(@as(i32, hurt_resistance_ticks), player.hurt_resistance);

    player.heal(2);
    try std.testing.expectEqual(@as(i32, hurt_resistance_ticks / 2), player.hurt_resistance);
}

test "the hurt camera rolls out and back over the animation" {
    var player = Player.spawn(math.Vec3.init(0, 64, 0));
    player.hurt(4);
    player.attacked_at_yaw = 0;

    try std.testing.expectApproxEqAbs(@as(f32, 0.0), player.hurtMatrix(0.0).m[1], 1.0e-3);

    var peak: f32 = 0;
    var remaining: i32 = 10;
    while (remaining >= 0) : (remaining -= 1) {
        player.hurt_time = remaining;
        peak = @min(peak, player.hurtMatrix(0.0).m[1]);
    }
    try std.testing.expect(peak < -0.2);

    player.hurt_time = 0;
    try std.testing.expectEqual(math.Mat4.identity.m, player.hurtMatrix(0.0).m);
}

test "the attacked yaw flips which way the camera rolls" {
    var player = Player.spawn(math.Vec3.init(0, 64, 0));
    player.hurt(4);
    player.hurt_time = 5;

    player.attacked_at_yaw = 0;
    const left = player.hurtMatrix(0.5);
    player.attacked_at_yaw = 180;
    const right = player.hurtMatrix(0.5);

    try std.testing.expectApproxEqAbs(left.m[1], -right.m[1], 1.0e-5);
}

test "a dead player's camera keeps tilting toward forty degrees" {
    var player = Player.spawn(math.Vec3.init(0, 64, 0));
    player.health = 0;

    player.death_time = 1;
    const early = player.hurtMatrix(0.0);
    player.death_time = 200;
    const late = player.hurtMatrix(0.0);

    try std.testing.expect(early.m[1] > 0.0);
    try std.testing.expect(late.m[1] > early.m[1]);
}

test "a respawning player keeps the id the world knows it by" {
    var player = Player.spawn(math.Vec3.init(0, 64, 0));
    player.base.id = 12;

    player.kill();
    player.respawn(math.Vec3.init(8, 70, 8));

    try std.testing.expectEqual(@as(u32, 12), player.base.id);
    try std.testing.expectEqual(@as(i32, 20), player.health);
    try std.testing.expectApproxEqAbs(@as(f64, 8), player.base.position.x, 1.0e-9);
}

test "a player's name is kept, clipped to what the protocol allows" {
    var player = Player.spawn(math.Vec3.init(0, 0, 0));
    try std.testing.expectEqualStrings("", player.name.text());

    player.name.set("Notch");
    try std.testing.expectEqualStrings("Notch", player.name.text());
    try std.testing.expect(player.name.eql("Notch"));
    try std.testing.expect(!player.name.eql("notch"));

    player.name.set("a" ** (max_name + 4));
    try std.testing.expectEqual(@as(usize, max_name), player.name.text().len);
}

test "a respawning player keeps its name along with its id" {
    var player = Player.spawn(math.Vec3.init(0, 64, 0));
    player.base.id = 3;
    player.name.set("Steve");

    player.kill();
    player.respawn(math.Vec3.init(1, 2, 3));

    try std.testing.expectEqualStrings("Steve", player.name.text());
    try std.testing.expectEqual(@as(u32, 3), player.base.id);
}

test "a portal fades in over eighty ticks, then sends the player through" {
    var player = Player.spawn(math.Vec3.init(0, 64, 0));
    player.time_until_portal = 0;

    var ticks: u32 = 0;
    while (ticks < 200) : (ticks += 1) {
        player.setInPortal();
        if (player.tickPortal() == .travel) break;
    }

    try std.testing.expectEqual(@as(u32, 80), ticks);
    try std.testing.expectEqual(@as(f32, 1.0), player.time_in_portal);
    try std.testing.expectEqual(portal_reentry_cooldown - 1, player.time_until_portal);
}

test "stepping out of a portal fades the overlay back out, four times as fast" {
    var player = Player.spawn(math.Vec3.init(0, 64, 0));
    player.time_in_portal = 1.0;
    player.time_until_portal = 0;

    _ = player.tickPortal();
    try std.testing.expectApproxEqAbs(@as(f32, 0.95), player.time_in_portal, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), player.prev_time_in_portal, 1.0e-6);

    for (0..40) |_| _ = player.tickPortal();
    try std.testing.expectEqual(@as(f32, 0.0), player.time_in_portal);
}

test "the cooldown after a trip stops the player bouncing straight back" {
    var player = Player.spawn(math.Vec3.init(0, 64, 0));

    try std.testing.expectEqual(portal_cooldown, player.time_until_portal);
    player.setInPortal();
    try std.testing.expect(!player.in_portal);
    try std.testing.expectEqual(portal_reentry_cooldown, player.time_until_portal);

    for (0..portal_reentry_cooldown) |_| _ = player.tickPortal();
    player.setInPortal();
    try std.testing.expect(player.in_portal);
}

test "the portal overlay is interpolated between ticks" {
    var player = Player.spawn(math.Vec3.init(0, 64, 0));
    player.prev_time_in_portal = 0.2;
    player.time_in_portal = 0.4;

    try std.testing.expectApproxEqAbs(@as(f32, 0.3), player.portalOverlay(0.5), 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), player.portalOverlay(0.0), 1.0e-6);
}

test "a player outside a portal has no warp on the camera at all" {
    var player = Player.spawn(math.Vec3.init(0, 64, 0));
    try std.testing.expectEqual(math.Mat4.identity.m, player.portalMatrix(0.5, 7).m);
}

test "the portal warp stretches the view sideways as the trip fills up" {
    var player = Player.spawn(math.Vec3.init(0, 64, 0));

    player.prev_time_in_portal = 0.5;
    player.time_in_portal = 0.5;
    const halfway = player.portalMatrix(0.0, 0);

    player.prev_time_in_portal = 1.0;
    player.time_in_portal = 1.0;
    const full = player.portalMatrix(0.0, 0);

    try std.testing.expect(halfway.m[0] > 1.0);
    try std.testing.expect(full.m[0] > halfway.m[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), full.m[5], 1.0e-6);
}

test "the warp spins with the clock and repeats every eighteen ticks" {
    var player = Player.spawn(math.Vec3.init(0, 64, 0));
    player.prev_time_in_portal = 1.0;
    player.time_in_portal = 1.0;

    const first = player.portalMatrix(0.0, 3);
    const wrapped = player.portalMatrix(0.0, 3 + portal_spin_period);
    const turned = player.portalMatrix(0.0, 4);

    inline for (0..16) |i| {
        try std.testing.expectApproxEqAbs(first.m[i], wrapped.m[i], 1.0e-5);
    }
    try std.testing.expect(@abs(first.m[1] - turned.m[1]) > 1.0e-4);
}

fn bedWorld(gpa: std.mem.Allocator, facing: u2) !world.World {
    var w = try world.testing.flatWorld(gpa, 2);
    errdefer w.deinit();

    const step = world.block.bedStep(facing);
    w.setBlock(8, 2, 8, .bed);
    w.setBlockMetadata(8, 2, 8, @as(u4, facing) | world.block.bed_pillow_bit);
    w.setBlock(8 + step[0], 2, 8 + step[1], .bed);
    w.setBlockMetadata(8 + step[0], 2, 8 + step[1], facing);
    w.time = 14000;
    w.skylight_subtracted = 11;
    return w;
}

test "a bed at night takes the player and puts them on the pillow" {
    var w = try bedWorld(std.testing.allocator, 0);
    defer w.deinit();

    var player = Player.spawn(math.Vec3.init(8.5, 2, 8.5));
    try std.testing.expectEqual(SleepStatus.ok, player.sleepInBedAt(&w, .overworld, 8, 2, 8));
    try std.testing.expect(player.sleeping);
    try std.testing.expectEqual(@as(?[3]i32, .{ 8, 2, 8 }), player.bed);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0 + 15.0 / 16.0 - 0.2), player.base.position.y, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 8.9), player.base.position.z, 1.0e-6);
    try std.testing.expectEqual(sleep_size, player.base.height);
}

test "daylight, distance and the nether each refuse the bed for their own reason" {
    var w = try bedWorld(std.testing.allocator, 0);
    defer w.deinit();

    var player = Player.spawn(math.Vec3.init(8.5, 2, 8.5));
    try std.testing.expectEqual(SleepStatus.not_possible_here, player.sleepInBedAt(&w, .nether, 8, 2, 8));

    var far = Player.spawn(math.Vec3.init(20.5, 2, 8.5));
    try std.testing.expectEqual(SleepStatus.too_far_away, far.sleepInBedAt(&w, .overworld, 8, 2, 8));

    w.skylight_subtracted = 0;
    try std.testing.expectEqual(SleepStatus.not_possible_now, player.sleepInBedAt(&w, .overworld, 8, 2, 8));

    w.skylight_subtracted = 11;
    try std.testing.expectEqual(SleepStatus.ok, player.sleepInBedAt(&w, .overworld, 8, 2, 8));
    try std.testing.expectEqual(SleepStatus.other_problem, player.sleepInBedAt(&w, .overworld, 8, 2, 8));
}

test "the sleep timer fills over a hundred ticks and drains over ten more" {
    var player = Player.spawn(math.Vec3.init(8.5, 2, 8.5));
    player.sleeping = true;

    for (0..sleep_fade_ticks) |_| player.tickSleep();
    try std.testing.expect(player.isFullyAsleep());
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), player.sleepFade(), 1.0e-6);

    player.tickSleep();
    try std.testing.expectEqual(sleep_fade_ticks, player.sleep_timer);

    player.sleeping = false;
    for (0..sleep_wake_ticks - sleep_fade_ticks - 1) |_| player.tickSleep();
    try std.testing.expect(player.sleep_timer > 0);
    try std.testing.expect(player.sleepFade() < 1.0);

    player.tickSleep();
    try std.testing.expectEqual(@as(i32, 0), player.sleep_timer);
    try std.testing.expectEqual(@as(f32, 0), player.sleepFade());
}

test "waking clears the occupied bit, restores the box and claims the bed as spawn" {
    var w = try bedWorld(std.testing.allocator, 0);
    defer w.deinit();

    var player = Player.spawn(math.Vec3.init(8.5, 2, 8.5));
    try std.testing.expectEqual(SleepStatus.ok, player.sleepInBedAt(&w, .overworld, 8, 2, 8));
    try world.block_update.setBedOccupied(&w, 8, 2, 8, true);

    try player.wakeUp(&w, false, true);
    try std.testing.expect(!player.sleeping);
    try std.testing.expect(!world.block.bedIsOccupied(w.getBlockMetadata(8, 2, 8)));
    try std.testing.expectEqual(height, player.base.height);
    try std.testing.expectEqual(@as(?[3]i32, .{ 8, 2, 8 }), player.spawn_point);
    try std.testing.expectEqual(sleep_fade_ticks, player.sleep_timer);
}

test "the bed's facing decides which way the body lies and where the camera looks" {
    var w = try bedWorld(std.testing.allocator, 2);
    defer w.deinit();

    var player = Player.spawn(math.Vec3.init(8.5, 2, 8.5));
    try std.testing.expectEqual(SleepStatus.ok, player.sleepInBedAt(&w, .overworld, 8, 2, 8));
    try std.testing.expectApproxEqAbs(@as(f32, 1.8), player.bed_offset[1], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 270.0), player.bedOrientationDegrees(&w), 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 8.1), player.base.position.z, 1.0e-6);
}

test "the sleeping camera looks down the bed and ignores where the mouse points" {
    var w = try bedWorld(std.testing.allocator, 2);
    defer w.deinit();

    var player = Player.spawn(math.Vec3.init(8.5, 2, 8.5));
    try std.testing.expectEqual(SleepStatus.ok, player.sleepInBedAt(&w, .overworld, 8, 2, 8));
    player.base.prev_position = player.base.position;

    const settled = player.cameraRotation(&w);
    player.yaw = 137.0;
    player.pitch = -42.0;
    const turned = player.cameraRotation(&w);

    inline for (0..16) |cell| {
        try std.testing.expectApproxEqAbs(settled.m[cell], turned.m[cell], 1.0e-6);
    }

    try std.testing.expectApproxEqAbs(@as(f32, 180.0), player.sleepFacingDegrees(&w), 1.0e-6);
}

test "an awake player's camera still follows the mouse" {
    var w = try bedWorld(std.testing.allocator, 0);
    defer w.deinit();

    var player = Player.spawn(math.Vec3.init(8.5, 2, 8.5));
    const settled = player.cameraRotation(&w);
    player.yaw = 137.0;
    const turned = player.cameraRotation(&w);

    var moved = false;
    inline for (0..16) |cell| {
        if (@abs(settled.m[cell] - turned.m[cell]) > 1.0e-4) moved = true;
    }
    try std.testing.expect(moved);
}
