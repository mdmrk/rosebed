const std = @import("std");

const math = @import("math");
const world = @import("world");

const Entity = @import("Entity.zig");

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
origin: math.Vec3 = .{ .x = 0, .y = 0, .z = 0 },

pub const Kind = enum { digging, smoke, splash, lava, flame, bubble, reddust, slime, heart, portal, explode, note, rain };

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
pub const flame_tile: u8 = 48;
pub const flame_drag: f64 = 0.96;
pub const flame_drift: f64 = 0.01;
pub const bubble_tile: u8 = 32;
pub const bubble_size: f64 = 0.02;
pub const bubble_lift: f64 = 0.002;
pub const bubble_drag: f64 = 0.85;
pub const reddust_drag: f64 = 0.96;
pub const reddust_launch: f64 = 0.1;
pub const slime_tile: u8 = 1 * 16 + 14;
pub const heart_tile: u8 = 5 * 16 + 0;
pub const heart_drag: f64 = 0.86;
pub const heart_scale: f32 = 2.0;
pub const heart_lift: f64 = 0.1;
pub const heart_age: i32 = 16;
pub const note_tile: u8 = 4 * 16 + 0;
pub const note_drag: f64 = 0.66;
pub const note_scale: f32 = 2.0;
pub const note_lift: f64 = 0.2;
pub const note_age: i32 = 6;
pub const rain_tile: u8 = 19;
pub const rain_tile_spread: i32 = 4;
pub const rain_gravity: f64 = 0.06;
pub const rain_drag: f64 = 0.98;
pub const rain_size: f64 = 0.01;
pub const rain_ground_friction: f64 = 0.7;
pub const explode_jitter: f64 = 0.05;
pub const explode_lift: f64 = 0.004;
pub const explode_drag: f64 = 0.9;
pub const portal_min_age: i32 = 40;
pub const portal_age_spread: i32 = 10;
pub const portal_tiles: i32 = 8;

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

pub const large_smoke_scale: f32 = 2.5;

pub fn spawnSmoke(position: math.Vec3, drift: math.Vec3, rand: *world.JavaRandom) Particle {
    return spawnSmokeScaled(position, drift, rand, 1.0);
}

pub fn spawnLargeSmoke(position: math.Vec3, drift: math.Vec3, rand: *world.JavaRandom) Particle {
    return spawnSmokeScaled(position, drift, rand, large_smoke_scale);
}

fn spawnSmokeScaled(position: math.Vec3, drift: math.Vec3, rand: *world.JavaRandom, scale: f32) Particle {
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
    particle.scale *= scale;

    const base_age: i32 = @intFromFloat(8.0 / (rand.nextDouble() * 0.8 + 0.2));
    particle.max_age = @intFromFloat(@as(f32, @floatFromInt(base_age)) * scale);

    particle.tile = 7;
    return particle;
}

test "a large puff is two and a half times the size of an ordinary one" {
    var small_rand = world.JavaRandom.init(4);
    var large_rand = world.JavaRandom.init(4);

    const small = spawnSmoke(math.Vec3.init(8, 40, 8), math.Vec3.init(0, 0, 0), &small_rand);
    const large = spawnLargeSmoke(math.Vec3.init(8, 40, 8), math.Vec3.init(0, 0, 0), &large_rand);

    try std.testing.expectEqual(Kind.smoke, large.kind);
    try std.testing.expectEqual(small.tile, large.tile);
    try std.testing.expectEqual(small.color, large.color);
    try std.testing.expectApproxEqAbs(small.scale * large_smoke_scale, large.scale, 1.0e-6);
    try std.testing.expect(large.max_age > small.max_age);
}

test "the large puff's lifetime is truncated twice, the way EntitySmokeFX does it" {
    for (0..64) |seed| {
        var a = world.JavaRandom.init(@intCast(seed));
        var b = world.JavaRandom.init(@intCast(seed));
        const small = spawnSmoke(math.Vec3.init(0, 0, 0), math.Vec3.init(0, 0, 0), &a);
        const large = spawnLargeSmoke(math.Vec3.init(0, 0, 0), math.Vec3.init(0, 0, 0), &b);

        const scaled_after: i32 = @intFromFloat(@as(f32, @floatFromInt(small.max_age)) * large_smoke_scale);
        try std.testing.expectEqual(scaled_after, large.max_age);
    }

    const raw: f32 = 3.9;
    const cut_first: i32 = @intFromFloat(@as(f32, @floatFromInt(@as(i32, @intFromFloat(raw)))) * large_smoke_scale);
    const scaled_first: i32 = @intFromFloat(raw * large_smoke_scale);
    try std.testing.expectEqual(@as(i32, 7), cut_first);
    try std.testing.expectEqual(@as(i32, 9), scaled_first);
}

test "both puffs draw the same number of values from the stream" {
    var a = world.JavaRandom.init(11);
    var b = world.JavaRandom.init(11);
    _ = spawnSmoke(math.Vec3.init(0, 0, 0), math.Vec3.init(0, 0, 0), &a);
    _ = spawnLargeSmoke(math.Vec3.init(0, 0, 0), math.Vec3.init(0, 0, 0), &b);
    try std.testing.expectEqual(a.seed, b.seed);
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

pub fn spawnFlame(position: math.Vec3, drift: math.Vec3, rand: *world.JavaRandom) Particle {
    var particle = spawnBase(position, drift, rand);
    particle.kind = .flame;
    particle.base.motion = math.Vec3.init(
        particle.base.motion.x * flame_drift + drift.x,
        particle.base.motion.y * flame_drift + drift.y,
        particle.base.motion.z * flame_drift + drift.z,
    );
    particle.color = .{ 1, 1, 1 };
    particle.max_age = @as(i32, @intFromFloat(8.0 / (rand.nextDouble() * 0.8 + 0.2))) + 4;
    particle.tile = flame_tile;
    return particle;
}

pub fn spawnBubble(position: math.Vec3, drift: math.Vec3, rand: *world.JavaRandom) Particle {
    var particle = spawnBase(position, drift, rand);
    particle.kind = .bubble;
    particle.tile = bubble_tile;
    particle.base.width = bubble_size;
    particle.base.height = bubble_size;
    particle.scale *= rand.nextFloat() * 0.6 + 0.2;
    particle.base.motion = math.Vec3.init(
        drift.x * 0.2 + (@as(f64, rand.nextFloat()) * 2.0 - 1.0) * 0.02,
        drift.y * 0.2 + (@as(f64, rand.nextFloat()) * 2.0 - 1.0) * 0.02,
        drift.z * 0.2 + (@as(f64, rand.nextFloat()) * 2.0 - 1.0) * 0.02,
    );
    particle.max_age = @intFromFloat(8.0 / (rand.nextDouble() * 0.8 + 0.2));
    return particle;
}

pub fn spawnReddust(position: math.Vec3, color: [3]f32, rand: *world.JavaRandom) Particle {
    var particle = spawnBase(position, math.Vec3.init(0, 0, 0), rand);
    particle.kind = .reddust;
    particle.base.motion.x *= reddust_launch;
    particle.base.motion.y *= reddust_launch;
    particle.base.motion.z *= reddust_launch;

    const red = if (color[0] == 0.0) 1.0 else color[0];
    const shade = rand.nextFloat() * 0.4 + 0.6;
    particle.color = .{
        (rand.nextFloat() * 0.2 + 0.8) * red * shade,
        (rand.nextFloat() * 0.2 + 0.8) * color[1] * shade,
        (rand.nextFloat() * 0.2 + 0.8) * color[2] * shade,
    };
    particle.scale *= 12.0 / 16.0;
    particle.max_age = @intFromFloat(8.0 / (rand.nextDouble() * 0.8 + 0.2));
    particle.tile = 7;
    return particle;
}

pub fn spawnHeart(position: math.Vec3, rand: *world.JavaRandom) Particle {
    var particle = spawnBase(position, math.Vec3.init(0, 0, 0), rand);
    particle.kind = .heart;
    particle.base.motion = math.Vec3.init(
        particle.base.motion.x * 0.01,
        particle.base.motion.y * 0.01 + heart_lift,
        particle.base.motion.z * 0.01,
    );
    particle.scale *= 12.0 / 16.0 * heart_scale;
    particle.max_age = heart_age;
    particle.tile = heart_tile;
    return particle;
}

pub fn spawnNote(position: math.Vec3, tone: f32, rand: *world.JavaRandom) Particle {
    var particle = spawnBase(position, math.Vec3.init(0, 0, 0), rand);
    particle.kind = .note;
    particle.base.motion = math.Vec3.init(
        particle.base.motion.x * 0.01,
        particle.base.motion.y * 0.01 + note_lift,
        particle.base.motion.z * 0.01,
    );
    particle.color = .{
        math.util.sin(tone * std.math.tau) * 0.65 + 0.35,
        math.util.sin((tone + 1.0 / 3.0) * std.math.tau) * 0.65 + 0.35,
        math.util.sin((tone + 2.0 / 3.0) * std.math.tau) * 0.65 + 0.35,
    };
    particle.scale *= 12.0 / 16.0 * note_scale;
    particle.max_age = note_age;
    particle.tile = note_tile;
    return particle;
}

pub fn spawnRain(position: math.Vec3, rand: *world.JavaRandom) Particle {
    var particle = spawnBase(position, math.Vec3.init(0, 0, 0), rand);
    particle.kind = .rain;
    particle.base.width = rain_size;
    particle.base.height = rain_size;
    particle.base.motion = math.Vec3.init(
        particle.base.motion.x * 0.3,
        @as(f64, rand.nextFloat()) * 0.2 + 0.1,
        particle.base.motion.z * 0.3,
    );
    particle.color = .{ 1, 1, 1 };
    particle.tile = rain_tile + @as(u8, @intCast(rand.nextIntBound(rain_tile_spread)));
    particle.max_age = @intFromFloat(8.0 / (rand.nextDouble() * 0.8 + 0.2));
    return particle;
}

pub fn spawnSlime(position: math.Vec3, rand: *world.JavaRandom) Particle {
    var particle = spawnBase(position, math.Vec3.init(0, 0, 0), rand);
    particle.kind = .slime;
    particle.scale /= 2.0;
    particle.tile = slime_tile;
    return particle;
}

// EntityExplodeFX jitters its drift with Math.random(), which is outside any seeded stream;
// this port has only the world random, so the shape matches and the exact numbers cannot.
pub fn spawnExplode(position: math.Vec3, drift: math.Vec3, rand: *world.JavaRandom) Particle {
    var particle = spawnBase(position, math.Vec3.init(0, 0, 0), rand);
    particle.kind = .explode;
    particle.base.motion = math.Vec3.init(
        drift.x + (rand.nextDouble() * 2.0 - 1.0) * explode_jitter,
        drift.y + (rand.nextDouble() * 2.0 - 1.0) * explode_jitter,
        drift.z + (rand.nextDouble() * 2.0 - 1.0) * explode_jitter,
    );

    const shade = rand.nextFloat() * 0.3 + 0.7;
    particle.color = .{ shade, shade, shade };
    particle.scale = rand.nextFloat() * rand.nextFloat() * 6.0 + 1.0;
    particle.max_age = @as(i32, @intFromFloat(16.0 / (@as(f64, rand.nextFloat()) * 0.8 + 0.2))) + 2;
    particle.tile = 7;
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

pub fn spawnPortal(position: math.Vec3, drift: math.Vec3, rand: *world.JavaRandom) Particle {
    var particle = spawnBase(position, drift, rand);
    particle.kind = .portal;
    particle.base.motion = drift;
    particle.origin = position;

    const shade = rand.nextFloat() * 0.6 + 0.4;
    particle.scale = rand.nextFloat() * 0.2 + 0.5;
    particle.color = .{ shade * 0.9, shade * 0.3, shade };
    particle.max_age = rand.nextIntBound(portal_age_spread) + portal_min_age;
    particle.tile = @intCast(rand.nextIntBound(portal_tiles));
    return particle;
}

pub fn tick(self: *Particle, world_map: *const world.World, rand: *world.JavaRandom) void {
    self.base.beginTick();
    self.age += 1;

    switch (self.kind) {
        .digging, .slime => {
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
        .flame => {
            self.base.position.x += self.base.motion.x;
            self.base.position.y += self.base.motion.y;
            self.base.position.z += self.base.motion.z;
            self.applyDrag(flame_drag);
        },
        .reddust => {
            if (self.age < self.max_age) {
                self.tile = @intCast(7 - @divTrunc(self.age * 8, self.max_age));
            }
            _ = self.base.move(world_map);
            if (self.base.position.y == self.base.prev_position.y) {
                self.base.motion.x *= 1.1;
                self.base.motion.z *= 1.1;
            }
            self.applyDrag(reddust_drag);
            self.applyGroundFriction();
        },
        .heart => {
            _ = self.base.move(world_map);
            if (self.base.position.y == self.base.prev_position.y) {
                self.base.motion.x *= 1.1;
                self.base.motion.z *= 1.1;
            }
            self.applyDrag(heart_drag);
            self.applyGroundFriction();
        },
        .rain => {
            self.base.motion.y -= rain_gravity;
            _ = self.base.move(world_map);
            self.applyDrag(rain_drag);
            if (self.base.on_ground) {
                if (rand.nextDouble() < 0.5) self.age = self.max_age;
                self.base.motion.x *= rain_ground_friction;
                self.base.motion.z *= rain_ground_friction;
            }
        },
        .note => {
            _ = self.base.move(world_map);
            if (self.base.position.y == self.base.prev_position.y) {
                self.base.motion.x *= 1.1;
                self.base.motion.z *= 1.1;
            }
            self.applyDrag(note_drag);
            self.applyGroundFriction();
        },
        .portal => {
            const lifetime: f32 = @floatFromInt(self.max_age);
            const elapsed: f32 = @floatFromInt(self.age - 1);
            const progress = elapsed / lifetime;
            const eased = 1.0 - (-progress + progress * progress * 2.0);
            self.base.position = math.Vec3.init(
                self.origin.x + self.base.motion.x * eased,
                self.origin.y + self.base.motion.y * eased + (1.0 - progress),
                self.origin.z + self.base.motion.z * eased,
            );
        },
        .explode => {
            if (self.age < self.max_age) {
                self.tile = @intCast(7 - @divTrunc(self.age * 8, self.max_age));
            }
            self.base.motion.y += explode_lift;
            _ = self.base.move(world_map);
            self.applyDrag(explode_drag);
            self.applyGroundFriction();
        },
        .bubble => {
            self.base.motion.y += bubble_lift;
            _ = self.base.move(world_map);
            self.applyDrag(bubble_drag);
            const block = world_map.getBlock(
                math.util.floorDouble(self.base.position.x),
                math.util.floorDouble(self.base.position.y),
                math.util.floorDouble(self.base.position.z),
            );
            if (block.material() != .water) self.expire();
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
        .digging, .splash, .bubble, .slime, .explode, .rain => 1.0,
        .smoke, .reddust, .heart, .note => std.math.clamp(self.lifeProgress(partial_ticks) * 32.0, 0.0, 1.0),
        .lava => blk: {
            const progress = self.lifeProgress(partial_ticks);
            break :blk @max(0.0, 1.0 - progress * progress);
        },
        .flame => blk: {
            const progress = self.lifeProgress(partial_ticks);
            break :blk 1.0 - progress * progress * 0.5;
        },
        .portal => blk: {
            const remaining = 1.0 - self.lifeProgress(partial_ticks);
            break :blk 1.0 - remaining * remaining;
        },
    };
    return 0.1 * self.scale * factor;
}

pub fn brightness(self: Particle, ambient: f32, partial_ticks: f32) f32 {
    return switch (self.kind) {
        .lava => 1.0,
        .flame => blk: {
            const progress = std.math.clamp(self.lifeProgress(partial_ticks), 0.0, 1.0);
            break :blk ambient * progress + (1.0 - progress);
        },
        .portal => blk: {
            var faded = @as(f32, @floatFromInt(self.age)) / @as(f32, @floatFromInt(self.max_age));
            faded *= faded;
            faded *= faded;
            break :blk ambient * (1.0 - faded) + faded;
        },
        else => ambient,
    };
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

test "an explosion puff is pale, outlives smoke and steps through the same tile strip" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    var rand = world.JavaRandom.init(9);
    var particle = spawnExplode(math.Vec3.init(8, 40, 8), math.Vec3.init(0, 0, 0), &rand);

    try std.testing.expectEqual(Kind.explode, particle.kind);
    try std.testing.expect(particle.color[0] >= 0.7 and particle.color[0] <= 1.0);
    try std.testing.expect(particle.scale >= 1.0 and particle.scale <= 7.0);
    try std.testing.expect(particle.max_age >= 18 and particle.max_age <= 82);
    try std.testing.expectEqual(@as(u8, 7), particle.tile);

    var last_tile: u8 = 7;
    while (!particle.isExpired()) {
        particle.tick(&world_map, &rand);
        try std.testing.expect(particle.tile <= last_tile);
        last_tile = particle.tile;
    }
    try std.testing.expectEqual(@as(u8, 0), last_tile);
}

test "an explosion puff drifts the way the blast threw it" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    var rand = world.JavaRandom.init(3);
    var particle = spawnExplode(math.Vec3.init(8, 40, 8), math.Vec3.init(0.5, 0, 0), &rand);

    try std.testing.expect(particle.base.motion.x > 0.5 - explode_jitter);
    try std.testing.expect(particle.base.motion.x < 0.5 + explode_jitter);

    const started = particle.base.position.x;
    for (0..5) |_| particle.tick(&world_map, &rand);
    try std.testing.expect(particle.base.position.x > started);
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
    world_map.getChunk(0, 0).?.setBlock(8, 4, 8, .stationary_water);
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

test "a bubble takes the bubble tile and barely any of the drift it was given" {
    var rand = world.JavaRandom.init(5);
    const bubble = spawnBubble(math.Vec3.init(8, 40, 8), math.Vec3.init(0.5, -0.5, 0.5), &rand);

    try std.testing.expectEqual(Kind.bubble, bubble.kind);
    try std.testing.expectEqual(bubble_tile, bubble.tile);
    try std.testing.expectEqual(bubble_size, bubble.base.width);
    try std.testing.expect(bubble.base.motion.x >= 0.08 and bubble.base.motion.x <= 0.12);
    try std.testing.expect(bubble.base.motion.y >= -0.12 and bubble.base.motion.y <= -0.08);
}

test "a bubble rises through water and pops as soon as it leaves it" {
    const gpa = std.testing.allocator;
    var world_map = try world.testing.flatWorld(gpa, 4);
    defer world_map.deinit();

    const chunk = world_map.getChunk(0, 0).?;
    for (5..9) |y| chunk.setBlock(8, @intCast(y), 8, .stationary_water);

    var rand = world.JavaRandom.init(5);
    var bubble = spawnBubble(math.Vec3.init(8.5, 5.5, 8.5), math.Vec3.init(0, 0, 0), &rand);
    bubble.base.motion = math.Vec3.init(0, 0, 0);

    const started = bubble.base.position.y;
    bubble.tick(&world_map, &rand);
    try std.testing.expect(bubble.base.position.y > started);
    try std.testing.expect(!bubble.isExpired());

    bubble.base.position = math.Vec3.init(8.5, 9.5, 8.5);
    bubble.tick(&world_map, &rand);
    try std.testing.expect(bubble.isExpired());
}

test "a lava ember pops upward, glows at full brightness and shrinks away" {
    var rand = world.JavaRandom.init(9);
    var particle = spawnLava(math.Vec3.init(8, 40, 8), &rand);

    try std.testing.expectEqual(Kind.lava, particle.kind);
    try std.testing.expectEqual(lava_tile, particle.tile);
    try std.testing.expectEqual(@as(f32, 1.0), particle.brightness(0.2, 0.0));
    try std.testing.expect(particle.base.motion.y >= 0.05 and particle.base.motion.y < 0.45);

    const fresh = particle.halfSize(0.0);
    particle.age = particle.max_age;
    try std.testing.expect(particle.halfSize(0.0) < fresh);
}

test "a flame starts white, takes the flame tile and outlives smoke by four ticks" {
    var rand = world.JavaRandom.init(4);
    for (0..200) |_| {
        const particle = spawnFlame(math.Vec3.init(8, 40, 8), math.Vec3.init(0, 0, 0), &rand);
        try std.testing.expectEqual(Kind.flame, particle.kind);
        try std.testing.expectEqual(flame_tile, particle.tile);
        try std.testing.expectEqual([3]f32{ 1, 1, 1 }, particle.color);
        try std.testing.expect(particle.max_age >= 12 and particle.max_age <= 44);
    }
}

test "a flame keeps almost none of its launch speed, unlike a digging shard" {
    var rand = world.JavaRandom.init(11);
    const flame = spawnFlame(math.Vec3.init(8, 40, 8), math.Vec3.init(0, 0, 0), &rand);
    rand = world.JavaRandom.init(11);
    const shard = spawn(math.Vec3.init(8, 40, 8), math.Vec3.init(0, 0, 0), 1, &rand);

    try std.testing.expectApproxEqAbs(shard.base.motion.x * flame_drift, flame.base.motion.x, 1.0e-12);
    try std.testing.expectApproxEqAbs(shard.base.motion.y * flame_drift, flame.base.motion.y, 1.0e-12);
}

test "a flame carries the drift it was given on top of its own jitter" {
    var rand = world.JavaRandom.init(11);
    const drifting = spawnFlame(math.Vec3.init(8, 40, 8), math.Vec3.init(0.5, 0, 0), &rand);
    try std.testing.expect(drifting.base.motion.x > 0.4);
}

test "a flame ignores gravity and drifts through blocks instead of landing" {
    const gpa = std.testing.allocator;
    var world_map = try world.testing.flatWorld(gpa, 12);
    defer world_map.deinit();

    var rand = world.JavaRandom.init(6);
    var particle = spawnFlame(math.Vec3.init(8.5, 12.5, 8.5), math.Vec3.init(0, -0.5, 0), &rand);
    const started = particle.base.position.y;

    for (0..4) |_| particle.tick(&world_map, &rand);

    try std.testing.expect(particle.base.position.y < started);
    try std.testing.expect(particle.base.position.y < 12.0);
    try std.testing.expect(!particle.base.on_ground);
}

test "a flame shrinks by half over its life and fades from full bright to ambient" {
    var rand = world.JavaRandom.init(8);
    var particle = spawnFlame(math.Vec3.init(8, 40, 8), math.Vec3.init(0, 0, 0), &rand);

    const fresh = particle.halfSize(0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), particle.brightness(0.2, 0.0), 1.0e-6);

    particle.age = particle.max_age;
    try std.testing.expectApproxEqAbs(fresh * 0.5, particle.halfSize(0.0), 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), particle.brightness(0.2, 0.0), 1.0e-6);
}

test "only lava ignores the light around it, smoke and shards take it as is" {
    var rand = world.JavaRandom.init(8);
    const smoke = spawnSmoke(math.Vec3.init(8, 40, 8), math.Vec3.init(0, 0, 0), &rand);
    const ember = spawnLava(math.Vec3.init(8, 40, 8), &rand);

    try std.testing.expectApproxEqAbs(@as(f32, 0.2), smoke.brightness(0.2, 0.0), 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), ember.brightness(0.2, 0.0), 1.0e-6);
}

test "reddust takes the colour it is handed, dimmed by a random shade" {
    var rand = world.JavaRandom.init(3);
    for (0..200) |_| {
        const particle = spawnReddust(math.Vec3.init(8, 40, 8), .{ 1.0, 0.0, 0.0 }, &rand);
        try std.testing.expectEqual(Kind.reddust, particle.kind);
        try std.testing.expectEqual(@as(u8, 7), particle.tile);
        try std.testing.expect(particle.color[0] >= 0.48 and particle.color[0] <= 1.0);
        try std.testing.expectEqual(@as(f32, 0.0), particle.color[1]);
        try std.testing.expectEqual(@as(f32, 0.0), particle.color[2]);
    }
}

test "reddust asked for black comes out red, as EntityReddustFX insists" {
    var rand = world.JavaRandom.init(5);
    const particle = spawnReddust(math.Vec3.init(8, 40, 8), .{ 0, 0, 0 }, &rand);

    try std.testing.expect(particle.color[0] > 0.4);
    try std.testing.expectEqual(@as(f32, 0.0), particle.color[1]);
    try std.testing.expectEqual(@as(f32, 0.0), particle.color[2]);
}

test "reddust keeps a tenth of its launch speed and never falls under gravity" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    var rand = world.JavaRandom.init(11);
    const dust = spawnReddust(math.Vec3.init(8, 40, 8), .{ 1, 0, 0 }, &rand);
    rand = world.JavaRandom.init(11);
    const shard = spawn(math.Vec3.init(8, 40, 8), math.Vec3.init(0, 0, 0), 1, &rand);

    try std.testing.expectApproxEqAbs(shard.base.motion.x * reddust_launch, dust.base.motion.x, 1.0e-12);

    var falling = dust;
    const started = falling.base.motion.y;
    falling.tick(&world_map, &rand);
    try std.testing.expect(falling.base.motion.y > started - gravity);
}

test "reddust steps down its tile strip and shrinks away like smoke" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    var rand = world.JavaRandom.init(2);
    var particle = spawnReddust(math.Vec3.init(8, 40, 8), .{ 1, 0, 0 }, &rand);

    var last_tile: u8 = 7;
    while (!particle.isExpired()) {
        particle.tick(&world_map, &rand);
        try std.testing.expect(particle.tile <= last_tile);
        last_tile = particle.tile;
    }
    try std.testing.expectEqual(@as(u8, 0), last_tile);
}

test "a portal particle drifts exactly where it was aimed, and outlives the others" {
    var rand = world.JavaRandom.init(4);
    const drift = math.Vec3.init(0.25, -0.1, 1.5);
    const particle = spawnPortal(math.Vec3.init(8.5, 64.0, 8.5), drift, &rand);

    try std.testing.expectEqual(Kind.portal, particle.kind);
    try std.testing.expectApproxEqAbs(drift.x, particle.base.motion.x, 1.0e-9);
    try std.testing.expectApproxEqAbs(drift.y, particle.base.motion.y, 1.0e-9);
    try std.testing.expectApproxEqAbs(drift.z, particle.base.motion.z, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 8.5), particle.origin.x, 1.0e-9);

    try std.testing.expect(particle.max_age >= portal_min_age);
    try std.testing.expect(particle.max_age < portal_min_age + portal_age_spread);
    try std.testing.expect(particle.tile < portal_tiles);
    try std.testing.expect(particle.scale >= 0.5 and particle.scale <= 0.7);
}

test "a portal particle is the purple EntityPortalFX mixes, blue over red over green" {
    var rand = world.JavaRandom.init(9);
    const particle = spawnPortal(math.Vec3.init(0, 0, 0), math.Vec3.init(0, 0, 0), &rand);

    try std.testing.expect(particle.color[2] > particle.color[0]);
    try std.testing.expect(particle.color[0] > particle.color[1]);
    try std.testing.expectApproxEqAbs(particle.color[2] * 0.9, particle.color[0], 1.0e-6);
    try std.testing.expectApproxEqAbs(particle.color[2] * 0.3, particle.color[1], 1.0e-6);
}

test "a portal particle rides its own curve home instead of falling" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var rand = world.JavaRandom.init(4);
    var particle = spawnPortal(math.Vec3.init(8.5, 64.0, 8.5), math.Vec3.init(0, 0, 2.0), &rand);

    particle.tick(&w, &rand);
    try std.testing.expectApproxEqAbs(@as(f64, 10.5), particle.base.position.z, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 65.0), particle.base.position.y, 1.0e-6);

    var peak = particle.base.position.z;
    while (!particle.isExpired()) {
        particle.tick(&w, &rand);
        peak = @max(peak, particle.base.position.z);
    }

    try std.testing.expect(peak > 10.5);
    try std.testing.expectApproxEqAbs(@as(f64, 8.5), particle.base.position.x, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 8.5), particle.base.position.z, 0.25);
    try std.testing.expectApproxEqAbs(@as(f64, 64.0), particle.base.position.y, 0.25);
}

test "a portal particle swells from nothing and burns to full brightness" {
    var rand = world.JavaRandom.init(4);
    var particle = spawnPortal(math.Vec3.init(0, 0, 0), math.Vec3.init(0, 0, 0), &rand);

    try std.testing.expectApproxEqAbs(@as(f32, 0.0), particle.halfSize(0.0), 1.0e-6);
    try std.testing.expect(particle.halfSize(0.0) < particle.halfSize(1.0));

    try std.testing.expectApproxEqAbs(@as(f32, 0.1), particle.brightness(0.1, 0.0), 1.0e-6);
    particle.age = particle.max_age;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), particle.brightness(0.1, 0.0), 1.0e-6);
}
