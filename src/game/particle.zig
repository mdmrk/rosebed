const std = @import("std");
const math = @import("math");
const world = @import("world");
const Entity = @import("entity.zig");

const Particle = @This();

base: Entity,
age: i32 = 0,
max_age: i32,
scale: f32,
jitter_u: f32,
jitter_v: f32,
tile: u8,
color: [3]f32,

pub const size: f64 = 0.2;
pub const gravity: f64 = 0.04;
pub const drag: f64 = 0.98;
pub const ground_friction: f64 = 0.7;
pub const digging_shade: f32 = 0.6;

pub fn spawn(
    position: math.Vec3,
    drift: math.Vec3,
    tile: u8,
    rand: *world.JavaRandom,
) Particle {
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
        .scale = (spread * 0.5 + 0.5) * 2.0 / 2.0,
        .jitter_u = jitter_u,
        .jitter_v = jitter_v,
        .tile = tile,
        .color = .{ digging_shade, digging_shade, digging_shade },
    };
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

pub fn tick(self: *Particle, world_map: *const world.World) void {
    self.base.beginTick();
    self.age += 1;

    self.base.motion.y -= gravity;
    _ = self.base.move(world_map);
    self.base.motion.x *= drag;
    self.base.motion.y *= drag;
    self.base.motion.z *= drag;
    if (self.base.on_ground) {
        self.base.motion.x *= ground_friction;
        self.base.motion.z *= ground_friction;
    }
}

pub fn isExpired(self: Particle) bool {
    return self.age > self.max_age;
}

pub fn halfSize(self: Particle) f32 {
    return 0.1 * self.scale;
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

    for (0..@intCast(particle.max_age + 1)) |_| particle.tick(&world_map);
    try std.testing.expect(particle.isExpired());
}

test "gravity pulls a particle down over time" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    var rand = world.JavaRandom.init(3);
    var particle = spawn(math.Vec3.init(8, 40, 8), math.Vec3.init(0, 0, 0), 1, &rand);
    const started = particle.base.position.y;
    for (0..20) |_| particle.tick(&world_map);
    try std.testing.expect(particle.base.position.y < started);
}
