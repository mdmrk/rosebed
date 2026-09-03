const std = @import("std");

const assets = @import("assets");
const math = @import("math");
const world = @import("world");
const testing_world = world.testing;

const Entity = @import("../Entity.zig");
const physics = @import("../physics.zig");
const Player = @import("../Player.zig");

pub const line_segments: usize = 16;
pub const line_lift: f64 = 0.25;

const rod_tip_offset = math.Vec3.init(-0.5, 0.03, 0.8);
const third_person_side: f64 = 0.35;
const third_person_reach: f64 = 0.85;
const third_person_drop: f64 = 0.45;
const swing_yaw_scale: f32 = 0.5;
const swing_pitch_scale: f32 = 0.7;

fn rotateAroundX(v: math.Vec3, angle: f32) math.Vec3 {
    const c: f64 = math.util.cos(angle);
    const s: f64 = math.util.sin(angle);
    return math.Vec3.init(v.x, v.y * c + v.z * s, v.z * c - v.y * s);
}

fn rotateAroundY(v: math.Vec3, angle: f32) math.Vec3 {
    const c: f64 = math.util.cos(angle);
    const s: f64 = math.util.sin(angle);
    return math.Vec3.init(v.x * c + v.z * s, v.y, v.z * c - v.x * s);
}

pub const Angler = struct {
    eye: math.Vec3,
    yaw: f32,
    pitch: f32,
    body_yaw: f32,
    swing: f32,
    third_person: bool,
};

pub fn rodTip(angler: Angler) math.Vec3 {
    const degrees = std.math.pi / 180.0;

    if (angler.third_person) {
        const body = angler.body_yaw * degrees;
        const sin_body: f64 = math.util.sin(body);
        const cos_body: f64 = math.util.cos(body);
        return math.Vec3.init(
            angler.eye.x - cos_body * third_person_side - sin_body * third_person_reach,
            angler.eye.y - third_person_drop,
            angler.eye.z - sin_body * third_person_side + cos_body * third_person_reach,
        );
    }

    const swing_bend: f32 = math.util.sin(math.util.sqrtF(angler.swing) * std.math.pi);
    var offset = rotateAroundX(rod_tip_offset, -angler.pitch * degrees);
    offset = rotateAroundY(offset, -angler.yaw * degrees);
    offset = rotateAroundY(offset, swing_bend * swing_yaw_scale);
    offset = rotateAroundX(offset, -swing_bend * swing_pitch_scale);

    return math.Vec3.init(
        angler.eye.x + offset.x,
        angler.eye.y + offset.y,
        angler.eye.z + offset.z,
    );
}

pub fn linePoint(self: FishHook, tip: math.Vec3, step: usize, partial_ticks: f32) math.Vec3 {
    const at = self.base.renderPosition(partial_ticks);
    const from = math.Vec3.init(at.x, at.y + line_lift, at.z);
    const run = math.Vec3.init(tip.x - from.x, tip.y - from.y, tip.z - from.z);

    const t: f64 = @as(f64, @floatFromInt(step)) / @as(f64, @floatFromInt(line_segments));
    return math.Vec3.init(
        at.x + run.x * t,
        at.y + run.y * (t * t + t) * 0.5 + line_lift,
        at.z + run.z * t,
    );
}

const FishHook = @This();

base: Entity,
yaw: f32 = 0,
pitch: f32 = 0,
prev_yaw: f32 = 0,
prev_pitch: f32 = 0,
angler: Entity.Id = Entity.no_id,
tile: [3]i32 = .{ -1, -1, -1 },
in_tile: world.Block = .air,
in_ground: bool = false,
shake: i32 = 0,
ticks_in_ground: i32 = 0,
ticks_in_air: i32 = 0,
ticks_catchable: i32 = 0,
dead: bool = false,

pub const size: f64 = 0.25;
pub const cast_speed: f32 = 0.4;
pub const cast_spread: f32 = 1.0;
pub const launch_scale: f32 = 1.5;
pub const owner_grace_ticks: i32 = 5;
pub const stuck_lifetime: i32 = 1200;
pub const reel_range_squared: f64 = 1024.0;
pub const buoyancy_slices: usize = 5;
pub const bite_chance: i32 = 500;
pub const bite_chance_rain: i32 = 300;

const hand_offset: f32 = 0.16;
const hand_drop: f64 = 0.1;
const eye_height: f64 = 1.62;
const drag: f64 = 0.92;
const ground_drag: f64 = 0.5;
const water_drag: f64 = 0.9;
const water_sink: f64 = 0.8;
const buoyancy: f64 = 0.04;
const bite_dip: f64 = 0.2;
const bite_splash_volume: f32 = 0.25;
const turn_smoothing: f32 = 0.2;
const reel_pull: f64 = 0.1;
const reel_lift: f64 = 0.08;

pub fn castBy(player: Player, rand: *world.JavaRandom) FishHook {
    const yaw_radians = player.yaw / 180.0 * std.math.pi;
    const pitch_radians = player.pitch / 180.0 * std.math.pi;

    const position = math.Vec3.init(
        player.base.position.x - @as(f64, math.util.cos(yaw_radians) * hand_offset),
        player.base.position.y + eye_height - player.y_size - hand_drop,
        player.base.position.z - @as(f64, math.util.sin(yaw_radians) * hand_offset),
    );

    var hook: FishHook = .{
        .base = Entity.init(position, size, size),
        .angler = player.base.id,
        .yaw = player.yaw,
        .pitch = player.pitch,
        .prev_yaw = player.yaw,
        .prev_pitch = player.pitch,
    };

    const heading = math.Vec3.init(
        -math.util.sin(yaw_radians) * math.util.cos(pitch_radians) * cast_speed,
        -math.util.sin(pitch_radians) * cast_speed,
        math.util.cos(yaw_radians) * math.util.cos(pitch_radians) * cast_speed,
    );
    hook.setHeading(heading, launch_scale, cast_spread, rand);
    return hook;
}

fn setHeading(self: *FishHook, direction: math.Vec3, speed: f32, spread: f32, rand: *world.JavaRandom) void {
    const length = math.util.sqrtF(
        direction.x * direction.x + direction.y * direction.y + direction.z * direction.z,
    );

    var x = direction.x / length;
    var y = direction.y / length;
    var z = direction.z / length;

    x += rand.nextGaussian() * 0.0075 * spread;
    y += rand.nextGaussian() * 0.0075 * spread;
    z += rand.nextGaussian() * 0.0075 * spread;

    x *= speed;
    y *= speed;
    z *= speed;

    self.base.motion = math.Vec3.init(x, y, z);
    const flat = math.util.sqrtF(x * x + z * z);
    self.yaw = @floatCast(std.math.atan2(x, z) * 180.0 / std.math.pi);
    self.pitch = @floatCast(std.math.atan2(y, flat) * 180.0 / std.math.pi);
    self.prev_yaw = self.yaw;
    self.prev_pitch = self.pitch;
}

pub fn submergedFraction(self: FishHook, world_map: *const world.World) f64 {
    const box = self.base.boundingBox();
    const span = box.max_y - box.min_y;
    var submerged: f64 = 0;

    for (0..buoyancy_slices) |slice| {
        const from: f64 = @floatFromInt(slice);
        const to: f64 = @floatFromInt(slice + 1);
        const slices: f64 = @floatFromInt(buoyancy_slices);
        const low = box.min_y + span * from / slices;
        const high = box.min_y + span * to / slices;
        const layer = math.Aabb.init(box.min_x, low, box.min_z, box.max_x, high, box.max_z);
        if (physics.isBoxInMaterial(world_map, layer, .water)) submerged += 1.0 / slices;
    }

    return submerged;
}

pub const Step = struct {
    bit: bool = false,
};

pub fn tick(self: *FishHook, world_map: *const world.World, rand: *world.JavaRandom) Step {
    self.base.beginTick();
    self.prev_yaw = self.yaw;
    self.prev_pitch = self.pitch;

    var step: Step = .{};
    if (self.shake > 0) self.shake -= 1;

    if (self.in_ground) {
        if (world_map.getBlock(.init(self.tile[0], self.tile[1], self.tile[2])) == self.in_tile) {
            self.ticks_in_ground += 1;
            if (self.ticks_in_ground == stuck_lifetime) self.dead = true;
            return step;
        }

        self.in_ground = false;
        self.base.motion.x *= @as(f64, rand.nextFloat()) * 0.2;
        self.base.motion.y *= @as(f64, rand.nextFloat()) * 0.2;
        self.base.motion.z *= @as(f64, rand.nextFloat()) * 0.2;
        self.ticks_in_ground = 0;
        self.ticks_in_air = 0;
    } else {
        self.ticks_in_air += 1;
    }

    const moved = self.base.move(world_map);
    if (moved.blocked_y and self.base.motion.y <= 0) self.settleInto(world_map);
    if (self.in_ground) return step;

    const flat = math.util.sqrtF(self.base.motion.x * self.base.motion.x + self.base.motion.z * self.base.motion.z);
    self.yaw = @floatCast(std.math.atan2(self.base.motion.x, self.base.motion.z) * 180.0 / std.math.pi);
    self.pitch = @floatCast(std.math.atan2(self.base.motion.y, flat) * 180.0 / std.math.pi);
    self.pitch = self.prev_pitch + (self.pitch - self.prev_pitch) * turn_smoothing;
    self.yaw = self.prev_yaw + (self.yaw - self.prev_yaw) * turn_smoothing;

    var slip: f64 = drag;
    if (self.base.on_ground or self.base.blocked_horizontally) slip = ground_drag;

    const submerged = self.submergedFraction(world_map);
    if (submerged > 0.0) {
        if (self.ticks_catchable > 0) {
            self.ticks_catchable -= 1;
        } else {
            if (rand.nextIntBound(bite_chance) == 0) {
                self.ticks_catchable = rand.nextIntBound(30) + 10;
                self.base.motion.y -= bite_dip;
                world_map.playSoundEffect(
                    self.base.position,
                    assets.sounds.random.splash,
                    bite_splash_volume,
                    1.0 + (rand.nextFloat() - rand.nextFloat()) * 0.4,
                );
                step.bit = true;
            }
        }
    }

    if (self.ticks_catchable > 0) {
        const tug = @as(f64, rand.nextFloat()) * @as(f64, rand.nextFloat()) * @as(f64, rand.nextFloat());
        self.base.motion.y -= tug * bite_dip;
    }

    self.base.motion.y += buoyancy * (submerged * 2.0 - 1.0);
    if (submerged > 0.0) {
        slip *= water_drag;
        self.base.motion.y *= water_sink;
    }

    self.base.motion.x *= slip;
    self.base.motion.y *= slip;
    self.base.motion.z *= slip;
    return step;
}

fn settleInto(self: *FishHook, world_map: *const world.World) void {
    const x = math.util.floorDouble(self.base.position.x);
    const y = math.util.floorDouble(self.base.position.y);
    const z = math.util.floorDouble(self.base.position.z);
    const under = world_map.getBlock(.init(x, y - 1, z));
    if (under == .air or under.isLiquid()) return;

    self.tile = .{ x, y - 1, z };
    self.in_tile = under;
    self.in_ground = true;
    self.base.motion = math.Vec3.init(0, 0, 0);
}

pub const Catch = enum(u8) { nothing = 0, fish = 1, stuck = 2 };

pub fn reelIn(self: *FishHook) Catch {
    self.dead = true;
    if (self.ticks_catchable > 0) return .fish;
    if (self.in_ground) return .stuck;
    return .nothing;
}

pub fn pullToward(self: FishHook, angler: math.Vec3) math.Vec3 {
    const dx = angler.x - self.base.position.x;
    const dy = angler.y - self.base.position.y;
    const dz = angler.z - self.base.position.z;
    const distance = math.util.sqrtF(dx * dx + dy * dy + dz * dz);
    return math.Vec3.init(
        dx * reel_pull,
        dy * reel_pull + math.util.sqrtF(distance) * reel_lift,
        dz * reel_pull,
    );
}

pub fn outOfRange(self: FishHook, angler: math.Vec3) bool {
    const dx = angler.x - self.base.position.x;
    const dy = angler.y - self.base.position.y;
    const dz = angler.z - self.base.position.z;
    return dx * dx + dy * dy + dz * dz > reel_range_squared;
}

test "a cast bobber leaves the rod with the speed EntityFish gives it" {
    var rand = world.JavaRandom.init(7);
    var player = Player.spawn(math.Vec3.init(8.5, 12, 8.5));
    player.yaw = 0;
    player.pitch = 0;

    const hook = FishHook.castBy(player, &rand);
    try std.testing.expectEqual(@as(f64, size), hook.base.width);
    try std.testing.expect(hook.base.motion.z > 0.5);
    try std.testing.expect(@abs(hook.base.motion.x) < 0.1);
    try std.testing.expectEqual(player.base.id, hook.angler);
}

test "a bobber floats where it lands in water" {
    const gpa = std.testing.allocator;
    var w = try testing_world.flatWorld(gpa, 4);
    defer w.deinit();
    for (0..world.Chunk.width) |x| {
        for (0..world.Chunk.width) |z| {
            w.getChunk(0, 0).?.setBlock(@intCast(x), 4, @intCast(z), .stationary_water);
        }
    }

    var rand = world.JavaRandom.init(1);
    var hook: FishHook = .{ .base = Entity.init(math.Vec3.init(8.5, 8.0, 8.5), size, size) };

    for (0..200) |_| _ = hook.tick(&w, &rand);

    try std.testing.expect(hook.base.position.y > 4.0);
    try std.testing.expect(hook.base.position.y < 6.0);
    try std.testing.expect(!hook.in_ground);
}

test "a bobber that hits the ground sticks and eventually gives up" {
    const gpa = std.testing.allocator;
    var w = try testing_world.flatWorld(gpa, 12);
    defer w.deinit();

    var rand = world.JavaRandom.init(1);
    var hook: FishHook = .{ .base = Entity.init(math.Vec3.init(8.5, 14.0, 8.5), size, size) };

    for (0..40) |_| _ = hook.tick(&w, &rand);
    try std.testing.expect(hook.in_ground);
    try std.testing.expectEqual(world.Block.stone, hook.in_tile);

    hook.ticks_in_ground = stuck_lifetime - 1;
    _ = hook.tick(&w, &rand);
    try std.testing.expect(hook.dead);
}

test "reeling in reports what was on the line" {
    var empty: FishHook = .{ .base = Entity.init(math.Vec3.init(0, 0, 0), size, size) };
    try std.testing.expectEqual(Catch.nothing, empty.reelIn());
    try std.testing.expect(empty.dead);

    var biting: FishHook = .{ .base = Entity.init(math.Vec3.init(0, 0, 0), size, size) };
    biting.ticks_catchable = 5;
    try std.testing.expectEqual(Catch.fish, biting.reelIn());

    var snagged: FishHook = .{ .base = Entity.init(math.Vec3.init(0, 0, 0), size, size) };
    snagged.in_ground = true;
    try std.testing.expectEqual(Catch.stuck, snagged.reelIn());
}

test "a caught fish is thrown back toward the angler" {
    var hook: FishHook = .{ .base = Entity.init(math.Vec3.init(8.5, 12.0, 12.5), size, size) };
    const toss = hook.pullToward(math.Vec3.init(8.5, 13.0, 8.5));

    try std.testing.expectApproxEqAbs(@as(f64, 0), toss.x, 1.0e-12);
    try std.testing.expect(toss.z < 0);
    try std.testing.expect(toss.y > 0);
}

test "the line runs from the bobber to the rod tip and sags between" {
    var hook: FishHook = .{ .base = Entity.init(math.Vec3.init(8.5, 12.0, 16.5), size, size) };
    hook.base.prev_position = hook.base.position;

    const angler: Angler = .{
        .eye = math.Vec3.init(8.5, 13.0, 8.5),
        .yaw = 0,
        .pitch = 0,
        .body_yaw = 0,
        .swing = 0,
        .third_person = false,
    };
    const tip = rodTip(angler);

    const start = hook.linePoint(tip, 0, 1.0);
    try std.testing.expectApproxEqAbs(hook.base.position.x, start.x, 1.0e-9);
    try std.testing.expectApproxEqAbs(hook.base.position.y + line_lift, start.y, 1.0e-9);
    try std.testing.expectApproxEqAbs(hook.base.position.z, start.z, 1.0e-9);

    const end = hook.linePoint(tip, line_segments, 1.0);
    try std.testing.expectApproxEqAbs(tip.x, end.x, 1.0e-9);
    try std.testing.expectApproxEqAbs(tip.y, end.y, 1.0e-9);
    try std.testing.expectApproxEqAbs(tip.z, end.z, 1.0e-9);

    const middle = hook.linePoint(tip, line_segments / 2, 1.0);
    const straight = (start.y + end.y) / 2.0;
    try std.testing.expect(middle.y < straight);
}

test "the rod tip sits off the angler's hand and swings with the cast" {
    const facing: Angler = .{
        .eye = math.Vec3.init(8.5, 13.0, 8.5),
        .yaw = 0,
        .pitch = 0,
        .body_yaw = 0,
        .swing = 0,
        .third_person = false,
    };

    const still = rodTip(facing);
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), still.x, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 9.3), still.z, 1.0e-6);

    var mid_swing = facing;
    mid_swing.swing = 0.25;
    const swung = rodTip(mid_swing);
    try std.testing.expect(@abs(swung.x - still.x) > 1.0e-3 or @abs(swung.y - still.y) > 1.0e-3);

    var behind = facing;
    behind.third_person = true;
    const over_shoulder = rodTip(behind);
    try std.testing.expectApproxEqAbs(@as(f64, 13.0 - 0.45), over_shoulder.y, 1.0e-9);
}

test "a bobber cast too far away is out of range" {
    var hook: FishHook = .{ .base = Entity.init(math.Vec3.init(0, 0, 0), size, size) };
    try std.testing.expect(!hook.outOfRange(math.Vec3.init(10, 0, 10)));
    try std.testing.expect(hook.outOfRange(math.Vec3.init(40, 0, 0)));
}
