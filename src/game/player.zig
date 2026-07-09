const std = @import("std");
const math = @import("math");
const world = @import("world");
const Entity = @import("entity.zig");
const Inventory = @import("inventory.zig");
const game_physics = @import("physics.zig");

const Player = @This();

base: Entity,
yaw: f32 = 0,
pitch: f32 = 0,
health: i32 = 20,
air: i32 = max_air,
inventory: Inventory = .{},
distance_walked: f32 = 0,
prev_distance_walked: f32 = 0,
camera_yaw: f32 = 0,
swing_progress: f32 = 0,
prev_swing_progress: f32 = 0,
swing_ticks: i32 = 0,
is_swinging: bool = false,
prev_camera_yaw: f32 = 0,
camera_pitch: f32 = 0,
prev_camera_pitch: f32 = 0,
jumped: bool = false,
damage_taken: i32 = 0,

pub const width: f64 = 0.6;
pub const height: f64 = 1.8;
pub const eye_height: f64 = 1.62;

const turn_scale = 0.15;

const gravity: f64 = 0.08;
const vertical_drag: f64 = 0.98;
const air_friction: f64 = 0.91;
const ground_friction: f64 = 0.6 * 0.91;
const ground_speed: f64 = 0.1;
const air_speed: f64 = 0.02;
const jump_velocity: f64 = 0.42;

const water_speed: f64 = 0.02;
const water_drag: f64 = 0.8;
const water_gravity: f64 = 0.02;
const water_jump: f64 = 0.04;
const water_climb_out: f64 = 0.3;

pub const max_air: i32 = 300;
const drown_damage: i32 = 2;

pub fn spawn(position: math.Vec3) Player {
    return .{ .base = Entity.init(position, width, height) };
}

pub fn tick(self: *Player, world_map: *const world.World, strafe: f32, forward: f32, jump: bool) void {
    self.base.beginTick();
    self.jumped = false;
    self.prev_distance_walked = self.distance_walked;
    self.prev_camera_yaw = self.camera_yaw;
    self.prev_camera_pitch = self.camera_pitch;

    self.base.updateWaterState(world_map);
    self.updateAir(world_map);

    if (self.base.in_water) {
        if (jump) self.base.motion.y += water_jump;
    } else if (self.base.on_ground and jump) {
        self.base.motion.y = jump_velocity;
        self.jumped = true;
    }

    const speed: f64 = if (self.base.in_water)
        water_speed
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

    const moved_x = self.base.position.x - before_x;
    const moved_z = self.base.position.z - before_z;
    self.distance_walked += @floatCast(@sqrt(moved_x * moved_x + moved_z * moved_z) * 0.6);

    if (self.base.in_water) {
        self.base.motion.x *= water_drag;
        self.base.motion.y *= water_drag;
        self.base.motion.z *= water_drag;
        self.base.motion.y -= water_gravity;

        const blocked_horizontally = moved.blocked_x or moved.blocked_z;
        const step_up = self.base.motion.y + 0.6 - self.base.position.y + before_y;
        if (blocked_horizontally and self.base.isOffsetPositionInLiquid(world_map, self.base.motion.x, step_up, self.base.motion.z)) {
            self.base.motion.y = water_climb_out;
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
}

pub fn isSubmerged(self: Player, world_map: *const world.World) bool {
    const eye = self.eyePosition();
    return game_physics.isInsideWater(world_map, eye.x, eye.y, eye.z);
}

fn updateAir(self: *Player, world_map: *const world.World) void {
    if (self.health > 0 and self.isSubmerged(world_map)) {
        self.air -= 1;
        if (self.air == -20) {
            self.air = 0;
            self.health = @max(0, self.health - drown_damage);
            self.damage_taken += drown_damage;
        }
        return;
    }
    self.air = max_air;
}

fn turnFactor(sensitivity: f32) f32 {
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
    if (len > 1.0e-4) {
        dir[0] /= len;
        dir[2] /= len;
    }
    return dir;
}

pub fn eyePosition(self: Player) math.Vec3 {
    return .{
        .x = self.base.position.x,
        .y = self.base.position.y + eye_height,
        .z = self.base.position.z,
    };
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
    const eye_x: f32 = @floatCast(render_position.x);
    const eye_y: f32 = @floatCast(render_position.y + eye_height);
    const eye_z: f32 = @floatCast(render_position.z);
    return self.viewRotation()
        .mul(math.Mat4.translation(-eye_x, -eye_y, -eye_z));
}

pub fn bobMatrix(self: Player, partial_ticks: f32) math.Mat4 {
    const step = self.distance_walked - self.prev_distance_walked;
    const walk = -(self.distance_walked + step * partial_ticks);
    const swing = self.prev_camera_yaw + (self.camera_yaw - self.prev_camera_yaw) * partial_ticks;
    const dip = self.prev_camera_pitch + (self.camera_pitch - self.prev_camera_pitch) * partial_ticks;

    const phase = walk * std.math.pi;
    const sway = math.util.sin(phase) * swing;
    const lift = math.util.abs(math.util.cos(phase) * swing);
    const tilt = math.util.abs(math.util.cos(phase - 0.2) * swing) * 5.0;

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
    player.tick(&w, 0, 0, false);
    try std.testing.expect(player.base.on_ground);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), player.base.position.y, 1.0e-9);
}

test "gravity accelerates a falling player" {
    var w = try world.testing.flatWorld(std.testing.allocator, 0);
    defer w.deinit();
    var player = Player.spawn(math.Vec3.init(8, 50, 8));
    player.tick(&w, 0, 0, false);
    try std.testing.expectApproxEqAbs(@as(f64, -0.0784), player.base.motion.y, 1.0e-9);
}

test "jumping from the ground sets the jump velocity" {
    var w = try world.testing.flatWorld(std.testing.allocator, 1);
    defer w.deinit();
    var player = Player.spawn(math.Vec3.init(8, 1, 8));
    player.base.on_ground = true;
    player.tick(&w, 0, 0, true);
    try std.testing.expectApproxEqAbs(@as(f64, (0.42 - 0.08) * 0.98), player.base.motion.y, 1.0e-9);
}

test "forward input on the ground moves the player each tick" {
    var w = try world.testing.flatWorld(std.testing.allocator, 1);
    defer w.deinit();
    var player = Player.spawn(math.Vec3.init(8, 1, 8));
    player.base.on_ground = true;
    player.tick(&w, 0, 1, false);
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
    for (0..world.constants.chunk_width) |x| {
        for (0..world.constants.chunk_width) |z| {
            var y: u32 = 1;
            while (y < surface_y) : (y += 1) {
                chunk.setBlock(@intCast(x), y, @intCast(z), world.Block.stationary_water);
            }
        }
    }
    return w;
}

test "a player in water sinks far more slowly than one falling through air" {
    var w = try floodedWorld(20);
    defer w.deinit();

    var swimmer = Player.spawn(math.Vec3.init(8, 10, 8));
    swimmer.tick(&w, 0, 0, false);
    try std.testing.expect(swimmer.base.in_water);
    try std.testing.expectApproxEqAbs(@as(f64, -water_gravity), swimmer.base.motion.y, 1.0e-9);

    var faller = Player.spawn(math.Vec3.init(8, 40, 8));
    faller.tick(&w, 0, 0, false);
    try std.testing.expect(!faller.base.in_water);
    try std.testing.expect(faller.base.motion.y < swimmer.base.motion.y);
}

test "holding jump underwater swims upward instead of doing nothing" {
    var w = try floodedWorld(20);
    defer w.deinit();

    var player = Player.spawn(math.Vec3.init(8, 10, 8));
    for (0..10) |_| player.tick(&w, 0, 0, true);
    try std.testing.expect(player.base.motion.y > 0.0);
    try std.testing.expect(player.base.position.y > 10.0);
}

test "swimming forward is slower than walking the same input on land" {
    var dry = try world.testing.flatWorld(std.testing.allocator, 1);
    defer dry.deinit();
    var walker = Player.spawn(math.Vec3.init(8, 1, 8));
    walker.base.on_ground = true;
    walker.tick(&dry, 0, 1, false);

    var flooded = try floodedWorld(20);
    defer flooded.deinit();
    var swimmer = Player.spawn(math.Vec3.init(8, 10, 8));
    swimmer.tick(&flooded, 0, 1, false);

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
