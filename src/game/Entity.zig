const std = @import("std");

const math = @import("math");
const world = @import("world");
const BlockPos = world.BlockPos;

const physics = @import("physics.zig");

const Entity = @This();

pub const Id = u32;
pub const no_id: Id = 0;

id: Id = no_id,
position: math.Vec3,
prev_position: math.Vec3,
motion: math.Vec3 = math.Vec3.init(0, 0, 0),
on_ground: bool = false,
blocked_horizontally: bool = false,
in_water: bool = false,
in_web: bool = false,
sneaking: bool = false,
triggers_walking: bool = true,
distance_walked: f32 = 0,
prev_distance_walked: f32 = 0,
next_step_distance: i32 = 1,
stepped_on: ?[3]i32 = null,
width: f64,
height: f64,
step_height: f64 = 0,
y_size: f64 = 0,
remote: ?Remote = null,

pub const Remote = struct {
    server_x: i32 = 0,
    server_y: i32 = 0,
    server_z: i32 = 0,
    position: math.Vec3 = math.Vec3.init(0, 0, 0),
    yaw: f64 = 0,
    pitch: f64 = 0,
    increments: i32 = 0,

    pub const scale: f64 = 32.0;
    pub const increments_per_update: i32 = 3;
    pub const boat_extra_increments: i32 = 4;
    pub const minecart_extra_increments: i32 = 2;
    pub const teleport_lift: f64 = 1.0 / 64.0;

    pub fn decode(value: i32) f64 {
        return @as(f64, @floatFromInt(value)) / scale;
    }

    pub fn at(x: i32, y: i32, z: i32) Remote {
        return .{
            .server_x = x,
            .server_y = y,
            .server_z = z,
            .position = .{ .x = decode(x), .y = decode(y), .z = decode(z) },
        };
    }

    pub fn teleportTo(self: *Remote, x: i32, y: i32, z: i32, yaw: f32, pitch: f32, lift: bool) void {
        self.server_x = x;
        self.server_y = y;
        self.server_z = z;
        self.aimAt(decode(x), decode(y) + if (lift) teleport_lift else 0, decode(z), yaw, pitch);
    }

    pub fn shiftBy(self: *Remote, dx: i8, dy: i8, dz: i8, yaw: f32, pitch: f32) void {
        self.server_x += dx;
        self.server_y += dy;
        self.server_z += dz;
        self.aimAt(decode(self.server_x), decode(self.server_y), decode(self.server_z), yaw, pitch);
    }

    fn aimAt(self: *Remote, x: f64, y: f64, z: f64, yaw: f32, pitch: f32) void {
        self.position = .{ .x = x, .y = y, .z = z };
        self.yaw = yaw;
        self.pitch = pitch;
        self.increments = increments_per_update;
    }
};

pub fn stepRemote(body: anytype) void {
    const target = if (body.base.remote) |*it| it else return;
    if (target.increments <= 0) return;

    const steps: f64 = @floatFromInt(target.increments);
    const x = body.base.position.x + (target.position.x - body.base.position.x) / steps;
    const y = body.base.position.y + (target.position.y - body.base.position.y) / steps;
    const z = body.base.position.z + (target.position.z - body.base.position.z) / steps;

    if (@hasField(@TypeOf(body.*), "yaw")) {
        var turn = target.yaw - @as(f64, body.yaw);
        while (turn < -180.0) turn += 360.0;
        while (turn >= 180.0) turn -= 360.0;

        body.yaw = @floatCast(@as(f64, body.yaw) + turn / steps);
        body.pitch = @floatCast(@as(f64, body.pitch) + (target.pitch - @as(f64, body.pitch)) / steps);
    }
    target.increments -= 1;
    body.base.position = .{ .x = x, .y = y, .z = z };
}

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

pub fn boundingBox(self: Entity) math.Aabb {
    const half = self.width / 2.0;
    return math.Aabb.init(
        self.position.x - half,
        self.position.y,
        self.position.z - half,
        self.position.x + half,
        self.position.y + self.height,
        self.position.z + half,
    );
}

pub fn dismountPosition(mount: Entity) math.Vec3 {
    return math.Vec3.init(mount.position.x, mount.position.y + mount.height, mount.position.z);
}

pub fn lightSamplePosition(self: Entity) [3]i32 {
    return .{
        math.util.floorDouble(self.position.x),
        math.util.floorDouble(self.position.y + self.height * 0.66),
        math.util.floorDouble(self.position.z),
    };
}

pub fn beginTick(self: *Entity) void {
    self.prev_position = self.position;
}

pub fn updateWaterState(self: *Entity, world_map: *const world.World) void {
    const push = physics.handleWaterMovement(world_map, self.boundingBox().expand(0, -0.4, 0)) orelse {
        self.in_water = false;
        return;
    };
    self.motion = self.motion.add(push);
    self.in_water = true;
}

pub fn isOnLadder(self: Entity, world_map: *const world.World) bool {
    const x = math.util.floorDouble(self.position.x);
    const y = math.util.floorDouble(self.boundingBox().min_y);
    const z = math.util.floorDouble(self.position.z);
    return world_map.getBlock(.init(x, y, z)) == .ladder;
}

pub fn isOffsetPositionInLiquid(self: Entity, world_map: *const world.World, dx: f64, dy: f64, dz: f64) bool {
    return physics.isOffsetPositionInLiquid(world_map, self.boundingBox(), dx, dy, dz);
}

pub fn move(self: *Entity, world_map: *const world.World) Moved {
    return self.moveAmong(world_map, &.{});
}

pub fn moveAmong(self: *Entity, world_map: *const world.World, obstacles: []const math.Aabb) Moved {
    const before_x = self.position.x;
    const before_z = self.position.z;
    var dx = self.motion.x;
    var dy = self.motion.y;
    var dz = self.motion.z;
    if (self.in_web) {
        self.in_web = false;
        dx *= world.block.web_drag;
        dy *= world.block.web_vertical_drag;
        dz *= world.block.web_drag;
        self.motion = math.Vec3.init(0, 0, 0);
    }

    const sneak_stepping = self.sneaking and self.on_ground;
    if (sneak_stepping) {
        const clamped = physics.clampToLedge(world_map, self.boundingBox(), dx, dz);
        dx = clamped[0];
        dz = clamped[1];
    }

    self.y_size *= 0.4;
    const result = physics.moveEntityStepping(
        world_map,
        self.boundingBox(),
        dx,
        dy,
        dz,
        self.step_height,
        self.on_ground,
        sneak_stepping,
        self.y_size,
        obstacles,
    );
    self.y_size = result.y_size;

    self.position = .{
        .x = (result.aabb.min_x + result.aabb.max_x) / 2.0,
        .y = result.aabb.min_y,
        .z = (result.aabb.min_z + result.aabb.max_z) / 2.0,
    };

    const moved: Moved = .{
        .dx = result.dx,
        .dy = result.dy,
        .dz = result.dz,
        .blocked_x = dx != result.dx,
        .blocked_y = dy != result.dy,
        .blocked_z = dz != result.dz,
    };

    self.on_ground = moved.blocked_y and dy < 0.0;
    self.blocked_horizontally = moved.blocked_x or moved.blocked_z;
    if (moved.blocked_x) self.motion.x = 0;
    if (moved.blocked_y) self.motion.y = 0;
    if (moved.blocked_z) self.motion.z = 0;

    if (self.triggers_walking and !sneak_stepping) {
        self.trackWalking(world_map, self.position.x - before_x, self.position.z - before_z);
    }

    if (physics.touchesBlock(world_map, self.boundingBox(), .web)) self.in_web = true;

    var soul_sand = physics.countTouchedBlocks(world_map, self.boundingBox(), .soul_sand);
    while (soul_sand > 0) : (soul_sand -= 1) {
        self.motion.x *= world.block.soul_sand_drag;
        self.motion.z *= world.block.soul_sand_drag;
    }

    return moved;
}

fn trackWalking(self: *Entity, world_map: *const world.World, dx: f64, dz: f64) void {
    self.distance_walked += @floatCast(@sqrt(dx * dx + dz * dz) * 0.6);

    const x = math.util.floorDouble(self.position.x);
    const y = math.util.floorDouble(self.position.y - 0.2);
    const z = math.util.floorDouble(self.position.z);
    const under = if (world_map.getBlock(.init(x, y - 1, z)) == .fence) world.Block.fence else world_map.getBlock(.init(x, y, z));
    if (self.distance_walked <= @as(f32, @floatFromInt(self.next_step_distance)) or under == .air) return;

    self.next_step_distance += 1;
    self.stepped_on = .{ x, y, z };

    const covered = world_map.getBlock(.init(x, y + 1, z)) == .snow_layer;
    if (!covered and under.material().isLiquid()) return;

    const step_sound = if (covered) world.Block.snow_layer.stepSound() else under.stepSound();
    world_map.playSoundEffect(
        self.position,
        step_sound.walk(),
        step_sound.volume() * 0.15,
        step_sound.pitch(),
    );
}

pub fn renderPosition(self: Entity, partial_ticks: f32) math.Vec3 {
    return self.prev_position.lerp(self.position, partial_ticks);
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

test "walking on soul sand damps horizontal motion once per cell touched" {
    var w = try world.testing.flatWorld(std.testing.allocator, 1);
    defer w.deinit();
    w.setBlock(.init(8, 1, 8), .soul_sand);

    var entity = Entity.init(math.Vec3.init(8.5, 2.0 - 2.0 / 16.0, 8.5), 0.6, 1.8);
    entity.motion = math.Vec3.init(0.2, 0, 0);
    _ = entity.move(&w);
    try std.testing.expectApproxEqAbs(@as(f64, 0.08), entity.motion.x, 1.0e-9);

    w.setBlock(.init(9, 1, 8), .soul_sand);
    var straddling = Entity.init(math.Vec3.init(9.0, 2.0 - 2.0 / 16.0, 8.5), 0.6, 1.8);
    straddling.motion = math.Vec3.init(0, 0, 0.2);
    _ = straddling.move(&w);
    try std.testing.expectApproxEqAbs(@as(f64, 0.032), straddling.motion.z, 1.0e-9);
}

test "an entity clear of soul sand keeps its motion" {
    var w = try world.testing.flatWorld(std.testing.allocator, 1);
    defer w.deinit();
    w.setBlock(.init(8, 1, 8), .soul_sand);

    var entity = Entity.init(math.Vec3.init(11.5, 1.0, 11.5), 0.6, 1.8);
    entity.motion = math.Vec3.init(0.2, 0, 0);
    _ = entity.move(&w);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), entity.motion.x, 1.0e-9);
}

test "a cobweb caught last tick throttles the next move and drops all momentum" {
    var w = try world.testing.flatWorld(std.testing.allocator, 1);
    defer w.deinit();
    w.setBlock(.init(8, 1, 8), .web);

    var entity = Entity.init(math.Vec3.init(8.5, 1.0, 8.5), 0.6, 1.8);
    entity.motion = math.Vec3.init(0.4, 0, 0);
    _ = entity.move(&w);
    try std.testing.expect(entity.in_web);
    try std.testing.expectApproxEqAbs(@as(f64, 8.9), entity.position.x, 1.0e-9);

    entity.motion = math.Vec3.init(0.4, -0.4, 0);
    const caught = entity.move(&w);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), caught.dx, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), entity.motion.x, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), entity.motion.z, 1.0e-9);
    try std.testing.expect(entity.in_web);

    entity.position = math.Vec3.init(12.5, 1.0, 12.5);
    entity.motion = math.Vec3.init(0.4, 0, 0);
    const freed = entity.move(&w);
    try std.testing.expect(!entity.in_web);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), freed.dx, 1.0e-9);
}

test "a cobweb has no collision box to stand on" {
    var w = try world.testing.flatWorld(std.testing.allocator, 1);
    defer w.deinit();
    w.setBlock(.init(8, 1, 8), .web);

    var entity = Entity.init(math.Vec3.init(8.5, 4.0, 8.5), 0.6, 1.8);
    entity.motion.y = -3.5;
    _ = entity.move(&w);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), entity.position.y, 1.0e-9);
    try std.testing.expect(entity.on_ground);
}

test "a ladder is only underfoot when it shares the cell the feet stand in" {
    var w = try world.testing.flatWorld(std.testing.allocator, 1);
    defer w.deinit();
    w.setBlock(.init(8, 1, 8), .ladder);
    w.setBlockMetadata(.init(8, 1, 8), 4);

    var entity = Entity.init(math.Vec3.init(8.5, 1.0, 8.5), 0.6, 1.8);
    try std.testing.expect(entity.isOnLadder(&w));

    entity.position.y = 2.0;
    try std.testing.expect(!entity.isOnLadder(&w));

    entity.position = math.Vec3.init(9.5, 1.0, 8.5);
    try std.testing.expect(!entity.isOnLadder(&w));
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

test "an entity that has walked far enough records the block under its feet" {
    var w = try world.testing.flatWorld(std.testing.allocator, 1);
    defer w.deinit();
    w.setBlock(.init(8, 0, 8), .farmland);

    var entity = Entity.init(math.Vec3.init(8.5, 1.0, 8.5), 0.6, 1.8);
    try std.testing.expectEqual(@as(?[3]i32, null), entity.stepped_on);

    for (0..10) |_| {
        entity.position = math.Vec3.init(8.5, 1.0, 8.5);
        entity.motion = math.Vec3.init(0.2, 0, 0);
        _ = entity.move(&w);
    }

    try std.testing.expectEqual(@as(?[3]i32, .{ 8, 0, 8 }), entity.stepped_on);
}

test "an entity that cannot trigger walking never records a step" {
    var w = try world.testing.flatWorld(std.testing.allocator, 1);
    defer w.deinit();

    var entity = Entity.init(math.Vec3.init(8.5, 1.0, 8.5), 0.6, 1.8);
    entity.triggers_walking = false;

    for (0..10) |_| {
        entity.position = math.Vec3.init(8.5, 1.0, 8.5);
        entity.motion = math.Vec3.init(0.2, 0, 0);
        _ = entity.move(&w);
    }

    try std.testing.expectEqual(@as(f32, 0), entity.distance_walked);
    try std.testing.expectEqual(@as(?[3]i32, null), entity.stepped_on);
}

test "a sneaking entity on the ground takes no step" {
    var w = try world.testing.flatWorld(std.testing.allocator, 1);
    defer w.deinit();

    var entity = Entity.init(math.Vec3.init(8.5, 1.0, 8.5), 0.6, 1.8);

    for (0..10) |_| {
        entity.position = math.Vec3.init(8.5, 1.0, 8.5);
        entity.on_ground = true;
        entity.sneaking = true;
        entity.motion = math.Vec3.init(0.2, 0, 0);
        _ = entity.move(&w);
    }

    try std.testing.expectEqual(@as(f32, 0), entity.distance_walked);
    try std.testing.expectEqual(@as(?[3]i32, null), entity.stepped_on);
}
