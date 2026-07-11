const std = @import("std");
const math = @import("math");
const world = @import("world");
const Entity = @import("entity.zig");

const Particle = @This();

base: Entity,
kind: Kind = .digging,
age: i32 = 0,
max_age: i32,
scale: f32,
jitter_u: f32,
jitter_v: f32,
tile: u8,
color: [3]f32,
tint: [3]u8 = .{ 255, 255, 255 },

pub const Kind = enum { digging, smoke, splash, lava };

pub const size: f64 = 0.2;
pub const gravity: f64 = 0.04;
pub const drag: f64 = 0.98;
pub const ground_friction: f64 = 0.7;
pub const digging_shade: f32 = 0.6;
pub const smoke_lift: f64 = 0.004;
pub const smoke_drag: f64 = 0.96;
pub const lava_gravity: f64 = 0.03;
pub const lava_drag: f64 = 0.999;
pub const lava_tile: u8 = 49;
pub const splash_gravity: f64 = 0.04;

fn spawnBase(position: math.Vec3, drift: math.Vec3, rand: *world.JavaRandom) Particle {
    var base = Entity.init(position, size, size);

    var motion = math.Vec3.init(
        drift.x + (@as(f64, rand.nextFloat()) * 2.0 - 1.0) * 0.4,
        drift.y + (@as(f64, rand.nextFloat()) * 2.0 - 1.0) * 0.4,
        drift.z + (@as(f64, rand.nextFloat()) * 2.0 - 1.0) * 0.4,
    );
    const speed = (rand.nextDouble() + rand.nextDouble() + 1.0) * 0.15;
    const length = @sqrt(motion.x * motion.x + motion.y * motion.y + motion.z * motion.z);
    if (length > 0.0) {
        motion.x = motion.x / length * speed * 0.4;
        motion.y = motion.y / length * speed * 0.4 + 0.1;
        motion.z = motion.z / length * speed * 0.4;
    }
    base.motion = motion;

    const jitter_u = rand.nextFloat() * 3.0;
    const jitter_v = rand.nextFloat() * 3.0;
    const spread = rand.nextFloat();

    return .{
        .base = base,
        .max_age = @intFromFloat(4.0 / (rand.nextFloat() * 0.9 + 0.1)),
        .scale = (spread * 0.5 + 0.5) * 2.0,
        .jitter_u = jitter_u,
        .jitter_v = jitter_v,
        .tile = 0,
        .color = .{ 1, 1, 1 },
    };
}

pub fn spawn(
    position: math.Vec3,
    drift: math.Vec3,
    tile: u8,
    rand: *world.JavaRandom,
) Particle {
    var particle = spawnBase(position, drift, rand);
    particle.scale /= 2.0;
    particle.tile = tile;
    particle.color = .{ digging_shade, digging_shade, digging_shade };
    return particle;
}

pub fn spawnSmoke(position: math.Vec3, drift: math.Vec3, rand: *world.JavaRandom) Particle {
    var particle = spawnBase(position, math.Vec3.init(0, 0, 0), rand);
    particle.kind = .smoke;
    particle.base.motion = math.Vec3.init(
        particle.base.motion.x * 0.1 + drift.x,
        particle.base.motion.y * 0.1 + drift.y,
        particle.base.motion.z * 0.1 + drift.z,
    );
    const shade = rand.nextFloat() * 0.3;
    particle.color = .{ shade, shade, shade };
    particle.scale *= 12.0 / 16.0;
    particle.max_age = @intFromFloat(8.0 / (rand.nextDouble() * 0.8 + 0.2));
    particle.tile = 7;
    return particle;
}

pub fn spawnSplash(position: math.Vec3, drift: math.Vec3, rand: *world.JavaRandom) Particle {
    var particle = spawnBase(position, math.Vec3.init(0, 0, 0), rand);
    particle.kind = .splash;
    particle.base.motion.x *= 0.3;
    particle.base.motion.y = @as(f64, rand.nextFloat()) * 0.2 + 0.1;
    particle.base.motion.z *= 0.3;
    particle.tile = @intCast(20 + rand.nextIntBound(4));
    particle.base.width = 0.01;
    particle.base.height = 0.01;
    particle.max_age = @intFromFloat(8.0 / (rand.nextDouble() * 0.8 + 0.2));
    if (drift.y == 0.0 and (drift.x != 0.0 or drift.z != 0.0)) {
        particle.base.motion = math.Vec3.init(drift.x, 0.1, drift.z);
    }
    return particle;
}

pub fn spawnLava(position: math.Vec3, rand: *world.JavaRandom) Particle {
    var particle = spawnBase(position, math.Vec3.init(0, 0, 0), rand);
    particle.kind = .lava;
    particle.base.motion.x *= 0.8;
    particle.base.motion.y = @as(f64, rand.nextFloat()) * 0.4 + 0.05;
    particle.base.motion.z *= 0.8;
    particle.scale *= rand.nextFloat() * 2.0 + 0.2;
    particle.max_age = @intFromFloat(16.0 / (rand.nextDouble() * 0.8 + 0.2));
    particle.tile = lava_tile;
    return particle;
}

pub fn slowedBy(self: Particle, factor: f32) Particle {
    var slowed = self;
    slowed.base.motion.x *= factor;
    slowed.base.motion.y = (slowed.base.motion.y - 0.1) * factor + 0.1;
    slowed.base.motion.z *= factor;
    return slowed;
}

pub fn scaledBy(self: Particle, factor: f32) Particle {
    var smaller = self;
    smaller.base.width = size * factor;
    smaller.base.height = size * factor;
    smaller.scale *= factor;
    return smaller;
}

pub fn tick(self: *Particle, world_map: *const world.World, rand: *world.JavaRandom) void {
    self.base.beginTick();
    self.age += 1;

    switch (self.kind) {
        .digging => {
            self.base.motion.y -= gravity;
            _ = self.base.move(world_map);
            self.applyDrag(drag);
            self.applyGroundFriction();
        },
        .smoke => {
            if (self.age < self.max_age) {
                self.tile = @intCast(7 - @divTrunc(self.age * 8, self.max_age));
            }
            self.base.motion.y += smoke_lift;
            _ = self.base.move(world_map);
            if (self.base.position.y == self.base.prev_position.y) {
                self.base.motion.x *= 1.1;
                self.base.motion.z *= 1.1;
            }
            self.applyDrag(smoke_drag);
            self.applyGroundFriction();
        },
        .splash => {
            self.base.motion.y -= splash_gravity;
            _ = self.base.move(world_map);
            self.applyDrag(drag);
            if (self.base.on_ground) {
                if (rand.nextDouble() < 0.5) self.expire();
                self.base.motion.x *= ground_friction;
                self.base.motion.z *= ground_friction;
            }
            const block = world_map.getBlock(
                math.util.floorDouble(self.base.position.x),
                math.util.floorDouble(self.base.position.y),
                math.util.floorDouble(self.base.position.z),
            );
            if (block.material().isLiquid() or block.isSolid()) self.expire();
        },
        .lava => {
            self.base.motion.y -= lava_gravity;
            _ = self.base.move(world_map);
            self.applyDrag(lava_drag);
            self.applyGroundFriction();
        },
    }
}

fn applyDrag(self: *Particle, factor: f64) void {
    self.base.motion.x *= factor;
    self.base.motion.y *= factor;
    self.base.motion.z *= factor;
}

fn applyGroundFriction(self: *Particle) void {
    if (self.base.on_ground) {
        self.base.motion.x *= ground_friction;
        self.base.motion.z *= ground_friction;
    }
}

pub fn expire(self: *Particle) void {
    self.age = self.max_age + 1;
}

pub fn isExpired(self: Particle) bool {
    return self.age > self.max_age;
}

pub fn lifeProgress(self: Particle, partial_ticks: f32) f32 {
    return (@as(f32, @floatFromInt(self.age)) + partial_ticks) / @as(f32, @floatFromInt(self.max_age));
}

pub fn halfSize(self: Particle, partial_ticks: f32) f32 {
    const factor: f32 = switch (self.kind) {
        .digging, .splash => 1.0,
        .smoke => std.math.clamp(self.lifeProgress(partial_ticks) * 32.0, 0.0, 1.0),
        .lava => blk: {
            const progress = self.lifeProgress(partial_ticks);
            break :blk @max(0.0, 1.0 - progress * progress);
        },
    };
    return 0.1 * self.scale * factor;
}

pub fn fullBright(self: Particle) bool {
    return self.kind == .lava;
}

test "a particle is launched outward and settles within its lifetime" {
    var rand = world.JavaRandom.init(1);
    const particle = spawn(math.Vec3.init(8, 40, 8), math.Vec3.init(0.25, 0.25, 0.25), 1, &rand);

    try std.testing.expect(particle.max_age >= 4 and particle.max_age <= 40);
    try std.testing.expect(particle.scale >= 0.5 and particle.scale <= 1.0);
    try std.testing.expect(particle.base.motion.y > 0.0);
    try std.testing.expect(particle.jitter_u >= 0.0 and particle.jitter_u < 3.0);
}

test "a particle expires once it outlives its maximum age" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    var rand = world.JavaRandom.init(7);
    var particle = spawn(math.Vec3.init(8, 40, 8), math.Vec3.init(0, 0, 0), 1, &rand);
    try std.testing.expect(!particle.isExpired());

    for (0..@intCast(particle.max_age + 1)) |_| particle.tick(&world_map, &rand);
    try std.testing.expect(particle.isExpired());
}

test "gravity pulls a particle down over time" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    var rand = world.JavaRandom.init(3);
    var particle = spawn(math.Vec3.init(8, 40, 8), math.Vec3.init(0, 0, 0), 1, &rand);
    const started = particle.base.position.y;
    for (0..20) |_| particle.tick(&world_map, &rand);
    try std.testing.expect(particle.base.position.y < started);
}

test "smoke drifts upward, darkens and steps through its tile strip" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    var rand = world.JavaRandom.init(2);
    var particle = spawnSmoke(math.Vec3.init(8, 40, 8), math.Vec3.init(0, 0, 0), &rand);

    try std.testing.expectEqual(Kind.smoke, particle.kind);
    try std.testing.expect(particle.color[0] <= 0.3);
    try std.testing.expectEqual(@as(u8, 7), particle.tile);

    const started = particle.base.position.y;
    var last_tile: u8 = 7;
    while (!particle.isExpired()) {
        particle.tick(&world_map, &rand);
        try std.testing.expect(particle.tile <= last_tile);
        last_tile = particle.tile;
    }
    try std.testing.expectEqual(@as(u8, 0), last_tile);
    try std.testing.expect(particle.base.position.y > started);
}

test "a splash droplet picks a rain tile and dies when it lands in water" {
    const gpa = std.testing.allocator;
    var world_map = try world.testing.flatWorld(gpa, 1);
    defer world_map.deinit();

    var rand = world.JavaRandom.init(5);
    var particle = spawnSplash(math.Vec3.init(8, 40, 8), math.Vec3.init(0, 0, 0), &rand);

    try std.testing.expectEqual(Kind.splash, particle.kind);
    try std.testing.expect(particle.tile >= 20 and particle.tile <= 23);
    try std.testing.expect(particle.base.motion.y >= 0.1 and particle.base.motion.y < 0.3);

    particle.base.position = math.Vec3.init(8.5, 4.5, 8.5);
    world_map.getChunk(0, 0).?.setBlock(8, 4, 8, world.Block.stationary_water);
    particle.tick(&world_map, &rand);
    try std.testing.expect(particle.isExpired());
}

test "a splash droplet launched sideways keeps that drift and hops up" {
    var rand = world.JavaRandom.init(5);
    const particle = spawnSplash(math.Vec3.init(8, 40, 8), math.Vec3.init(0.25, 0, -0.25), &rand);

    try std.testing.expectApproxEqAbs(@as(f64, 0.25), particle.base.motion.x, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), particle.base.motion.y, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -0.25), particle.base.motion.z, 1.0e-9);
}

test "a lava ember pops upward, glows at full brightness and shrinks away" {
    var rand = world.JavaRandom.init(9);
    var particle = spawnLava(math.Vec3.init(8, 40, 8), &rand);

    try std.testing.expectEqual(Kind.lava, particle.kind);
    try std.testing.expectEqual(lava_tile, particle.tile);
    try std.testing.expect(particle.fullBright());
    try std.testing.expect(particle.base.motion.y >= 0.05 and particle.base.motion.y < 0.45);

    const fresh = particle.halfSize(0.0);
    particle.age = particle.max_age;
    try std.testing.expect(particle.halfSize(0.0) < fresh);
}
