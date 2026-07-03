const std = @import("std");
const math = @import("math");
const world = @import("world");
const physics = @import("physics.zig");

const Entity = @This();

position: math.Vec3,
prev_position: math.Vec3,
motion: math.Vec3 = math.Vec3.init(0, 0, 0),
on_ground: bool = false,
width: f64,
height: f64,

pub const Moved = struct {
    dx: f64,
    dy: f64,
    dz: f64,
    blocked_x: bool,
    blocked_y: bool,
    blocked_z: bool,
};

pub fn init(position: math.Vec3, width: f64, height: f64) Entity {
    return .{
        .position = position,
        .prev_position = position,
        .width = width,
        .height = height,
    };
}

pub fn boundingBox(self: Entity) math.AABB {
    const half = self.width / 2.0;
    return math.AABB.init(
        self.position.x - half,
        self.position.y,
        self.position.z - half,
        self.position.x + half,
        self.position.y + self.height,
        self.position.z + half,
    );
}

pub fn beginTick(self: *Entity) void {
    self.prev_position = self.position;
}

pub fn move(self: *Entity, world_map: *const world.World) Moved {
    const result = physics.moveEntity(world_map, self.boundingBox(), self.motion.x, self.motion.y, self.motion.z);

    self.position = .{
        .x = (result.aabb.min_x + result.aabb.max_x) / 2.0,
        .y = result.aabb.min_y,
        .z = (result.aabb.min_z + result.aabb.max_z) / 2.0,
    };

    const moved: Moved = .{
        .dx = result.dx,
        .dy = result.dy,
        .dz = result.dz,
        .blocked_x = self.motion.x != result.dx,
        .blocked_y = self.motion.y != result.dy,
        .blocked_z = self.motion.z != result.dz,
    };

    self.on_ground = moved.blocked_y and self.motion.y < 0.0;
    if (moved.blocked_x) self.motion.x = 0;
    if (moved.blocked_y) self.motion.y = 0;
    if (moved.blocked_z) self.motion.z = 0;

    return moved;
}

pub fn renderPosition(self: Entity, partial_ticks: f32) math.Vec3 {
    const t: f64 = partial_ticks;
    return .{
        .x = self.prev_position.x + (self.position.x - self.prev_position.x) * t,
        .y = self.prev_position.y + (self.position.y - self.prev_position.y) * t,
        .z = self.prev_position.z + (self.position.z - self.prev_position.z) * t,
    };
}

test "boundingBox is centered on x/z and rests on the feet position" {
    const entity = Entity.init(math.Vec3.init(2, 5, 3), 0.6, 1.8);
    const box = entity.boundingBox();
    try std.testing.expectApproxEqAbs(@as(f64, 1.7), box.min_x, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2.3), box.max_x, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), box.min_y, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 6.8), box.max_y, 1.0e-9);
}

test "renderPosition interpolates between the previous and current tick" {
    var entity = Entity.init(math.Vec3.init(0, 0, 0), 1, 1);
    entity.position = math.Vec3.init(10, 0, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), entity.renderPosition(0.0).x, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), entity.renderPosition(0.5).x, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), entity.renderPosition(1.0).x, 1.0e-9);
}

test "landing on a floor grounds the entity and zeroes its vertical motion" {
    var w = try world.testing.flatWorld(std.testing.allocator, 1);
    defer w.deinit();

    var entity = Entity.init(math.Vec3.init(8, 1.05, 8), 0.6, 1.8);
    entity.motion.y = -0.5;
    const moved = entity.move(&w);

    try std.testing.expect(entity.on_ground);
    try std.testing.expect(moved.blocked_y);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), entity.motion.y, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), entity.position.y, 1.0e-9);
}

test "unobstructed movement keeps the entity off the ground" {
    var w = try world.testing.flatWorld(std.testing.allocator, 0);
    defer w.deinit();

    var entity = Entity.init(math.Vec3.init(8, 50, 8), 0.6, 1.8);
    entity.motion = math.Vec3.init(0.1, -0.2, 0.3);
    const moved = entity.move(&w);

    try std.testing.expect(!entity.on_ground);
    try std.testing.expectApproxEqAbs(@as(f64, -0.2), moved.dy, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 49.8), entity.position.y, 1.0e-9);
}
