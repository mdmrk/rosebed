const std = @import("std");
const math = @import("math");
const world = @import("world");
const physics = @import("physics.zig");

const Pig = @This();

position: math.Vec3,
prev_position: math.Vec3,
motion: math.Vec3 = math.Vec3.init(0, 0, 0),
yaw: f32 = 0,
on_ground: bool = false,
walk_distance: f32 = 0,
wander_ticks_left: u16 = 0,
is_moving: bool = false,

pub const width: f64 = 0.9;
pub const height: f64 = 0.9;

const gravity: f64 = 0.08;
const vertical_drag: f64 = 0.98;
const air_friction: f64 = 0.91;
const ground_friction: f64 = 0.6 * 0.91;
const walk_speed: f64 = 0.1;

pub fn spawn(position: math.Vec3) Pig {
    return .{ .position = position, .prev_position = position };
}

pub fn boundingBox(self: Pig) math.AABB {
    const half = width / 2.0;
    return math.AABB.init(
        self.position.x - half,
        self.position.y,
        self.position.z - half,
        self.position.x + half,
        self.position.y + height,
        self.position.z + half,
    );
}

fn rerollWander(self: *Pig, rand: *world.JavaRandom) void {
    self.is_moving = rand.nextIntBound(4) != 0;
    if (self.is_moving) self.yaw = @floatFromInt(rand.nextIntBound(360));
    self.wander_ticks_left = @intCast(20 + rand.nextIntBound(40));
}

pub fn tick(self: *Pig, world_map: *const world.World, rand: *world.JavaRandom) void {
    self.prev_position = self.position;

    if (self.wander_ticks_left == 0) {
        self.rerollWander(rand);
    } else {
        self.wander_ticks_left -= 1;
    }

    if (self.is_moving) {
        const yaw_rad = self.yaw * std.math.pi / 180.0;
        self.motion.x += @as(f64, -@sin(yaw_rad)) * walk_speed;
        self.motion.z += @as(f64, @cos(yaw_rad)) * walk_speed;
    }

    const result = physics.moveEntity(world_map, self.boundingBox(), self.motion.x, self.motion.y, self.motion.z);
    self.position = .{
        .x = (result.aabb.min_x + result.aabb.max_x) / 2.0,
        .y = result.aabb.min_y,
        .z = (result.aabb.min_z + result.aabb.max_z) / 2.0,
    };

    self.on_ground = self.motion.y != result.dy and self.motion.y < 0.0;
    const blocked_horizontally = self.motion.x != result.dx or self.motion.z != result.dz;
    if (self.motion.x != result.dx) self.motion.x = 0;
    if (self.motion.y != result.dy) self.motion.y = 0;
    if (self.motion.z != result.dz) self.motion.z = 0;

    self.motion.y -= gravity;
    self.motion.y *= vertical_drag;
    const friction: f64 = if (self.on_ground) ground_friction else air_friction;
    self.motion.x *= friction;
    self.motion.z *= friction;

    if (blocked_horizontally) self.wander_ticks_left = 0;

    if (self.is_moving and self.on_ground) {
        const dx = result.dx;
        const dz = result.dz;
        self.walk_distance += @floatCast(@sqrt(dx * dx + dz * dz));
    }
}

pub fn renderPosition(self: Pig, partial_ticks: f32) math.Vec3 {
    const t: f64 = partial_ticks;
    return .{
        .x = self.prev_position.x + (self.position.x - self.prev_position.x) * t,
        .y = self.prev_position.y + (self.position.y - self.prev_position.y) * t,
        .z = self.prev_position.z + (self.position.z - self.prev_position.z) * t,
    };
}

fn testWorldWithFloor() !world.World {
    var w = world.World.init(std.testing.allocator);
    var chunk = world.Chunk.init(0, 0);
    for (0..world.constants.chunk_width) |x| {
        for (0..world.constants.chunk_width) |z| {
            chunk.setBlockId(@intCast(x), 0, @intCast(z), world.block.stone);
        }
    }
    try w.chunks.put(std.testing.allocator, .{ .x = 0, .z = 0 }, chunk);
    return w;
}

test "gravity pulls a spawned pig down" {
    var w = try testWorldWithFloor();
    defer w.deinit();
    var rand = world.JavaRandom.init(0);
    var pig = Pig.spawn(math.Vec3.init(8, 5, 8));
    pig.tick(&w, &rand);
    try std.testing.expect(pig.position.y <= 5.0);
}

test "a freshly spawned pig picks a wander state within one tick" {
    var w = try testWorldWithFloor();
    defer w.deinit();
    var rand = world.JavaRandom.init(0);
    var pig = Pig.spawn(math.Vec3.init(8, 1, 8));
    try std.testing.expectEqual(@as(u16, 0), pig.wander_ticks_left);
    pig.tick(&w, &rand);
    try std.testing.expect(pig.wander_ticks_left > 0);
}

test "walk distance only accumulates while moving on the ground" {
    var w = try testWorldWithFloor();
    defer w.deinit();
    var rand = world.JavaRandom.init(0);
    var pig = Pig.spawn(math.Vec3.init(8, 1, 8));
    pig.is_moving = false;
    pig.wander_ticks_left = 100;
    pig.on_ground = true;
    pig.tick(&w, &rand);
    try std.testing.expectEqual(@as(f32, 0), pig.walk_distance);
}

test "hitting a wall cuts the current wander leg short" {
    var w = world.World.init(std.testing.allocator);
    defer w.deinit();
    var chunk = world.Chunk.init(0, 0);
    for (0..world.constants.chunk_width) |x| {
        chunk.setBlockId(@intCast(x), 0, 0, world.block.stone);
    }
    chunk.setBlockId(9, 1, 0, world.block.stone);
    try w.chunks.put(std.testing.allocator, .{ .x = 0, .z = 0 }, chunk);

    var rand = world.JavaRandom.init(0);
    var pig = Pig.spawn(math.Vec3.init(8, 1, 0));
    pig.is_moving = true;
    pig.yaw = 270;
    pig.wander_ticks_left = 50;
    pig.on_ground = true;
    var saw_reset = false;
    for (0..20) |_| {
        pig.tick(&w, &rand);
        if (pig.wander_ticks_left == 0) saw_reset = true;
    }
    try std.testing.expect(saw_reset);
}
