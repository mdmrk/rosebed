const std = @import("std");

const math = @import("math");
const world = @import("world");
pub const Kind = world.item.MinecartKind;
const testing_world = world.testing;

const Entity = @import("../Entity.zig");

const Minecart = @This();

base: Entity,
kind: Kind = .empty,
yaw: f32 = 0,
pitch: f32 = 0,
prev_yaw: f32 = 0,
prev_pitch: f32 = 0,
damage: i32 = 0,
time_since_hit: i32 = 0,
rock_direction: i32 = 1,
flipped: bool = false,
rider: Entity.Id = Entity.no_id,
push: math.Vec3 = math.Vec3.init(0, 0, 0),
fuel: i32 = 0,
items: [chest_slots]?world.Stack = @splat(null),
dead: bool = false,

pub const width: f64 = 0.98;
pub const height: f64 = 0.7;
pub const y_offset: f64 = height / 2.0;
pub const mounted_offset: f64 = -0.3;
pub const chest_slots = 27;
pub const inventory_name = "Minecart";
pub const chest_rows = 3;

pub const damage_per_hit: i32 = 10;
pub const break_damage: i32 = 40;
pub const hit_ticks: i32 = 10;
pub const coal_fuel: i32 = 1200;
pub const speed_cap: f64 = 0.4;

const gravity: f64 = 0.04;
const slope_pull: f64 = 1.0 / 128.0;
const rider_drag: f64 = 0.997;
const rolling_drag: f64 = 0.96;
const air_drag: f64 = 0.95;
const ground_drag: f64 = 0.5;
const furnace_push: f64 = 0.04;
const furnace_drag: f64 = 0.8;
const furnace_idle_drag: f64 = 0.9;
const boost: f64 = 0.06;
const brake_speed: f64 = 0.03;
const nudge: f64 = 0.02;
const rider_scale: f64 = 0.75;
const slope_energy: f64 = 0.05;
const turn_threshold: f64 = 0.001;

pub const track = [10][2][3]i32{
    .{ .{ 0, 0, -1 }, .{ 0, 0, 1 } },
    .{ .{ -1, 0, 0 }, .{ 1, 0, 0 } },
    .{ .{ -1, -1, 0 }, .{ 1, 0, 0 } },
    .{ .{ -1, 0, 0 }, .{ 1, -1, 0 } },
    .{ .{ 0, 0, -1 }, .{ 0, -1, 1 } },
    .{ .{ 0, -1, -1 }, .{ 0, 0, 1 } },
    .{ .{ 0, 0, 1 }, .{ 1, 0, 0 } },
    .{ .{ 0, 0, 1 }, .{ -1, 0, 0 } },
    .{ .{ 0, 0, -1 }, .{ -1, 0, 0 } },
    .{ .{ 0, 0, -1 }, .{ 1, 0, 0 } },
};

pub fn spawn(position: math.Vec3, kind: Kind) Minecart {
    var base = Entity.init(position, width, height);
    base.triggers_walking = false;
    return .{ .base = base, .kind = kind };
}

fn centre(self: Minecart) math.Vec3 {
    return math.Vec3.init(self.base.position.x, self.base.position.y + y_offset, self.base.position.z);
}

pub fn railAt(world_map: *const world.World, x: f64, y: f64, z: f64) ?math.Vec3 {
    const cx = math.util.floorDouble(x);
    var cy = math.util.floorDouble(y);
    const cz = math.util.floorDouble(z);
    if (world.block.isRail(world_map.getBlock(.init(cx, cy - 1, cz)))) cy -= 1;

    const id = world_map.getBlock(.init(cx, cy, cz));
    if (!world.block.isRail(id)) return null;

    const shape = world.block.railShape(id, world_map.getBlockMetadata(.init(cx, cy, cz)));
    if (shape > 9) return null;

    const rails = track[shape];
    const fx: f64 = @floatFromInt(cx);
    const fy: f64 = @floatFromInt(cy);
    const fz: f64 = @floatFromInt(cz);

    const ax = fx + 0.5 + @as(f64, @floatFromInt(rails[0][0])) * 0.5;
    const ay = fy + 0.5 + @as(f64, @floatFromInt(rails[0][1])) * 0.5;
    const az = fz + 0.5 + @as(f64, @floatFromInt(rails[0][2])) * 0.5;
    const bx = fx + 0.5 + @as(f64, @floatFromInt(rails[1][0])) * 0.5;
    const by = fy + 0.5 + @as(f64, @floatFromInt(rails[1][1])) * 0.5;
    const bz = fz + 0.5 + @as(f64, @floatFromInt(rails[1][2])) * 0.5;

    const dx = bx - ax;
    const dy = (by - ay) * 2.0;
    const dz = bz - az;

    var along: f64 = 0;
    if (dx == 0.0) {
        along = z - fz;
    } else if (dz == 0.0) {
        along = x - fx;
    } else {
        along = ((x - ax) * dx + (z - az) * dz) * 2.0;
    }

    var out_y = ay + dy * along;
    if (dy < 0.0) out_y += 1.0;
    if (dy > 0.0) out_y += 0.5;

    return math.Vec3.init(ax + dx * along, out_y, az + dz * along);
}

pub fn railAhead(world_map: *const world.World, x: f64, y: f64, z: f64, offset: f64) ?math.Vec3 {
    const cx = math.util.floorDouble(x);
    var cy = math.util.floorDouble(y);
    const cz = math.util.floorDouble(z);
    if (world.block.isRail(world_map.getBlock(.init(cx, cy - 1, cz)))) cy -= 1;

    const id = world_map.getBlock(.init(cx, cy, cz));
    if (!world.block.isRail(id)) return null;

    const shape = world.block.railShape(id, world_map.getBlockMetadata(.init(cx, cy, cz)));
    if (shape > 9) return null;

    const rails = track[shape];
    var dx: f64 = @floatFromInt(rails[1][0] - rails[0][0]);
    var dz: f64 = @floatFromInt(rails[1][2] - rails[0][2]);
    const span = @sqrt(dx * dx + dz * dz);
    dx /= span;
    dz /= span;

    const ax = x + dx * offset;
    const az = z + dz * offset;
    var ay: f64 = @floatFromInt(cy);
    if (world.block.railIsSloped(shape)) ay += 1.0;

    if (rails[0][1] != 0 and math.util.floorDouble(ax) - cx == rails[0][0] and math.util.floorDouble(az) - cz == rails[0][2]) {
        ay += @floatFromInt(rails[0][1]);
    } else if (rails[1][1] != 0 and math.util.floorDouble(ax) - cx == rails[1][0] and math.util.floorDouble(az) - cz == rails[1][2]) {
        ay += @floatFromInt(rails[1][1]);
    }

    return railAt(world_map, ax, ay, az);
}

pub const Step = struct {
    smoking: bool = false,
};

pub fn tick(
    self: *Minecart,
    world_map: *const world.World,
    obstacles: []const math.Aabb,
    has_rider: bool,
) Step {
    if (self.time_since_hit > 0) self.time_since_hit -= 1;
    if (self.damage > 0) self.damage -= 1;

    self.base.beginTick();
    self.prev_yaw = self.yaw;
    self.prev_pitch = self.pitch;
    self.base.motion.y -= gravity;

    var step: Step = .{};
    const start = self.centre();
    const cx = math.util.floorDouble(start.x);
    var cy = math.util.floorDouble(start.y);
    const cz = math.util.floorDouble(start.z);
    if (world.block.isRail(world_map.getBlock(.init(cx, cy - 1, cz)))) cy -= 1;

    const id = world_map.getBlock(.init(cx, cy, cz));
    if (world.block.isRail(id)) {
        self.rideRail(world_map, obstacles, id, cx, cy, cz, has_rider, &step);
    } else {
        self.rollFree(world_map, obstacles);
    }

    self.pitch = 0;
    self.settleYaw();
    return step;
}

fn rideRail(
    self: *Minecart,
    world_map: *const world.World,
    obstacles: []const math.Aabb,
    id: world.Block,
    cx: i32,
    cy: i32,
    cz: i32,
    has_rider: bool,
    step: *Step,
) void {
    const before = railAt(world_map, self.centre().x, self.centre().y, self.centre().z);
    const metadata = world_map.getBlockMetadata(.init(cx, cy, cz));
    const shape = world.block.railShape(id, metadata);
    if (shape > 9) return;

    const boosting = id == .rail_powered and metadata & world.block.rail_flag_bit != 0;
    const braking = id == .rail_powered and !boosting;

    var floor_y: f64 = @floatFromInt(cy);
    if (world.block.railIsSloped(shape)) floor_y = @floatFromInt(cy + 1);
    var pos = self.centre();

    switch (shape) {
        2 => self.base.motion.x -= slope_pull,
        3 => self.base.motion.x += slope_pull,
        4 => self.base.motion.z += slope_pull,
        5 => self.base.motion.z -= slope_pull,
        else => {},
    }

    const rails = track[shape];
    var dx: f64 = @floatFromInt(rails[1][0] - rails[0][0]);
    var dz: f64 = @floatFromInt(rails[1][2] - rails[0][2]);
    const span = @sqrt(dx * dx + dz * dz);
    if (self.base.motion.x * dx + self.base.motion.z * dz < 0.0) {
        dx = -dx;
        dz = -dz;
    }

    var speed = @sqrt(self.base.motion.x * self.base.motion.x + self.base.motion.z * self.base.motion.z);
    self.base.motion.x = speed * dx / span;
    self.base.motion.z = speed * dz / span;

    if (braking) {
        const rolling = @sqrt(self.base.motion.x * self.base.motion.x + self.base.motion.z * self.base.motion.z);
        if (rolling < brake_speed) {
            self.base.motion = math.Vec3.init(0, 0, 0);
        } else {
            self.base.motion.x *= 0.5;
            self.base.motion.y = 0;
            self.base.motion.z *= 0.5;
        }
    }

    const fx: f64 = @floatFromInt(cx);
    const fz: f64 = @floatFromInt(cz);
    const ax = fx + 0.5 + @as(f64, @floatFromInt(rails[0][0])) * 0.5;
    const az = fz + 0.5 + @as(f64, @floatFromInt(rails[0][2])) * 0.5;
    const bx = fx + 0.5 + @as(f64, @floatFromInt(rails[1][0])) * 0.5;
    const bz = fz + 0.5 + @as(f64, @floatFromInt(rails[1][2])) * 0.5;
    const run_x = bx - ax;
    const run_z = bz - az;

    var along: f64 = 0;
    if (run_x == 0.0) {
        pos.x = fx + 0.5;
        along = pos.z - fz;
    } else if (run_z == 0.0) {
        pos.z = fz + 0.5;
        along = pos.x - fx;
    } else {
        along = ((pos.x - ax) * run_x + (pos.z - az) * run_z) * 2.0;
    }

    pos.x = ax + run_x * along;
    pos.z = az + run_z * along;
    self.base.position = math.Vec3.init(pos.x, floor_y, pos.z);

    var travel_x = self.base.motion.x;
    var travel_z = self.base.motion.z;
    if (has_rider) {
        travel_x *= rider_scale;
        travel_z *= rider_scale;
    }
    travel_x = std.math.clamp(travel_x, -speed_cap, speed_cap);
    travel_z = std.math.clamp(travel_z, -speed_cap, speed_cap);

    const carried = self.base.motion;
    self.base.motion = math.Vec3.init(travel_x, 0, travel_z);
    const moved = self.base.moveAmong(world_map, obstacles);
    self.base.motion = math.Vec3.init(
        if (moved.blocked_x) 0 else carried.x,
        carried.y,
        if (moved.blocked_z) 0 else carried.z,
    );

    const now = self.base.position;
    if (rails[0][1] != 0 and math.util.floorDouble(now.x) - cx == rails[0][0] and math.util.floorDouble(now.z) - cz == rails[0][2]) {
        self.base.position.y = now.y + @as(f64, @floatFromInt(rails[0][1]));
    } else if (rails[1][1] != 0 and math.util.floorDouble(now.x) - cx == rails[1][0] and math.util.floorDouble(now.z) - cz == rails[1][2]) {
        self.base.position.y = now.y + @as(f64, @floatFromInt(rails[1][1]));
    }

    if (has_rider) {
        self.base.motion.x *= rider_drag;
        self.base.motion.y = 0;
        self.base.motion.z *= rider_drag;
    } else {
        if (self.kind == .furnace) {
            const drive = @sqrt(self.push.x * self.push.x + self.push.z * self.push.z);
            if (drive > 0.01) {
                step.smoking = true;
                self.push.x /= drive;
                self.push.z /= drive;
                self.base.motion.x *= furnace_drag;
                self.base.motion.y = 0;
                self.base.motion.z *= furnace_drag;
                self.base.motion.x += self.push.x * furnace_push;
                self.base.motion.z += self.push.z * furnace_push;
            } else {
                self.base.motion.x *= furnace_idle_drag;
                self.base.motion.y = 0;
                self.base.motion.z *= furnace_idle_drag;
            }
        }
        self.base.motion.x *= rolling_drag;
        self.base.motion.y = 0;
        self.base.motion.z *= rolling_drag;
    }

    const here = self.centre();
    if (railAt(world_map, here.x, here.y, here.z)) |after| {
        if (before) |was| {
            const lift = (was.y - after.y) * slope_energy;
            speed = @sqrt(self.base.motion.x * self.base.motion.x + self.base.motion.z * self.base.motion.z);
            if (speed > 0.0) {
                self.base.motion.x = self.base.motion.x / speed * (speed + lift);
                self.base.motion.z = self.base.motion.z / speed * (speed + lift);
            }
            self.base.position.y = after.y - y_offset;
        }
    }

    const settled = self.centre();
    const moved_x = math.util.floorDouble(settled.x);
    const moved_z = math.util.floorDouble(settled.z);
    if (moved_x != cx or moved_z != cz) {
        speed = @sqrt(self.base.motion.x * self.base.motion.x + self.base.motion.z * self.base.motion.z);
        self.base.motion.x = speed * @as(f64, @floatFromInt(moved_x - cx));
        self.base.motion.z = speed * @as(f64, @floatFromInt(moved_z - cz));
    }

    if (self.kind == .furnace) {
        const drive = @sqrt(self.push.x * self.push.x + self.push.z * self.push.z);
        if (drive > 0.01 and
            self.base.motion.x * self.base.motion.x + self.base.motion.z * self.base.motion.z > 0.001)
        {
            self.push.x /= drive;
            self.push.z /= drive;
            if (self.push.x * self.base.motion.x + self.push.z * self.base.motion.z < 0.0) {
                self.push = math.Vec3.init(0, 0, 0);
            } else {
                self.push = math.Vec3.init(self.base.motion.x, 0, self.base.motion.z);
            }
        }
    }

    if (!boosting) return;

    const rolling = @sqrt(self.base.motion.x * self.base.motion.x + self.base.motion.z * self.base.motion.z);
    if (rolling > 0.01) {
        self.base.motion.x += self.base.motion.x / rolling * boost;
        self.base.motion.z += self.base.motion.z / rolling * boost;
    } else if (shape == 1) {
        if (world_map.getBlock(.init(cx - 1, cy, cz)).isNormalCube()) {
            self.base.motion.x = nudge;
        } else if (world_map.getBlock(.init(cx + 1, cy, cz)).isNormalCube()) {
            self.base.motion.x = -nudge;
        }
    } else if (shape == 0) {
        if (world_map.getBlock(.init(cx, cy, cz - 1)).isNormalCube()) {
            self.base.motion.z = nudge;
        } else if (world_map.getBlock(.init(cx, cy, cz + 1)).isNormalCube()) {
            self.base.motion.z = -nudge;
        }
    }
}

fn rollFree(self: *Minecart, world_map: *const world.World, obstacles: []const math.Aabb) void {
    self.base.motion.x = std.math.clamp(self.base.motion.x, -speed_cap, speed_cap);
    self.base.motion.z = std.math.clamp(self.base.motion.z, -speed_cap, speed_cap);

    if (self.base.on_ground) {
        self.base.motion.x *= ground_drag;
        self.base.motion.y *= ground_drag;
        self.base.motion.z *= ground_drag;
    }

    _ = self.base.moveAmong(world_map, obstacles);

    if (!self.base.on_ground) {
        self.base.motion.x *= air_drag;
        self.base.motion.y *= air_drag;
        self.base.motion.z *= air_drag;
    }
}

fn settleYaw(self: *Minecart) void {
    const back_x = self.base.prev_position.x - self.base.position.x;
    const back_z = self.base.prev_position.z - self.base.position.z;
    if (back_x * back_x + back_z * back_z > turn_threshold) {
        self.yaw = @floatCast(std.math.atan2(back_z, back_x) * 180.0 / std.math.pi);
        if (self.flipped) self.yaw += 180.0;
    }

    var delta: f64 = @as(f64, self.yaw) - @as(f64, self.prev_yaw);
    while (delta >= 180.0) delta -= 360.0;
    while (delta < -180.0) delta += 360.0;
    if (delta < -170.0 or delta >= 170.0) {
        self.yaw += 180.0;
        self.flipped = !self.flipped;
    }
}

pub const collision_reach: f64 = 0.2;
const shove: f64 = 0.1;
const shove_half: f64 = 0.5;
const shove_damp: f64 = 0.2;
const shove_carry: f64 = 0.7;
const pass_through_limit: f64 = 5.0;

fn addVelocity(self: *Minecart, dx: f64, dz: f64) void {
    self.base.motion.x += dx;
    self.base.motion.z += dz;
}

pub fn collideWith(self: *Minecart, other: *Minecart) void {
    var dx = other.base.position.x - self.base.position.x;
    var dz = other.base.position.z - self.base.position.z;
    const square = dx * dx + dz * dz;
    if (square < 1.0e-4) return;

    const distance = @sqrt(square);
    dx /= distance;
    dz /= distance;
    const scale = @min(1.0 / distance, 1.0);
    dx *= scale * shove * shove_half;
    dz *= scale * shove * shove_half;

    // EntityMinecart multiplies the z gap by the other cart's prevPosX where it means
    // motionX. Kept: the squared result trips the > 5 bail-out for any pair of carts a
    // little way from x = 0, so far from spawn they roll through each other in vanilla.
    const gap_x = other.base.position.x - self.base.position.x;
    const gap_z = other.base.position.z - self.base.position.z;
    const skew = gap_x * other.base.motion.z + gap_z * other.base.prev_position.x;
    if (skew * skew > pass_through_limit) return;

    var shared_x = other.base.motion.x + self.base.motion.x;
    var shared_z = other.base.motion.z + self.base.motion.z;

    if (other.kind == .furnace and self.kind != .furnace) {
        self.base.motion.x *= shove_damp;
        self.base.motion.z *= shove_damp;
        self.addVelocity(other.base.motion.x - dx, other.base.motion.z - dz);
        other.base.motion.x *= shove_carry;
        other.base.motion.z *= shove_carry;
        return;
    }

    if (other.kind != .furnace and self.kind == .furnace) {
        other.base.motion.x *= shove_damp;
        other.base.motion.z *= shove_damp;
        other.addVelocity(self.base.motion.x + dx, self.base.motion.z + dz);
        self.base.motion.x *= shove_carry;
        self.base.motion.z *= shove_carry;
        return;
    }

    shared_x /= 2.0;
    shared_z /= 2.0;
    self.base.motion.x *= shove_damp;
    self.base.motion.z *= shove_damp;
    self.addVelocity(shared_x - dx, shared_z - dz);
    other.base.motion.x *= shove_damp;
    other.base.motion.z *= shove_damp;
    other.addVelocity(shared_x + dx, shared_z + dz);
}

pub fn hurt(self: *Minecart, amount: i32) bool {
    if (self.dead) return true;
    self.rock_direction = -self.rock_direction;
    self.time_since_hit = hit_ticks;
    self.damage += amount * damage_per_hit;
    if (self.damage > break_damage) self.dead = true;
    return true;
}

pub fn riderPosition(self: Minecart) math.Vec3 {
    return math.Vec3.init(
        self.base.position.x,
        self.base.position.y + y_offset + mounted_offset,
        self.base.position.z,
    );
}

pub const scoop_speed_squared: f64 = 0.01;

pub fn wouldScoop(self: Minecart) bool {
    if (self.kind != .empty) return false;
    if (self.rider != Entity.no_id) return false;
    const speed = self.base.motion.x * self.base.motion.x + self.base.motion.z * self.base.motion.z;
    return speed > scoop_speed_squared;
}

pub fn shoveOff(self: *Minecart, other: *Entity) void {
    var dx = other.position.x - self.base.position.x;
    var dz = other.position.z - self.base.position.z;
    const square = dx * dx + dz * dz;
    if (square < 1.0e-4) return;

    const distance = @sqrt(square);
    dx /= distance;
    dz /= distance;
    const scale = @min(1.0 / distance, 1.0);
    dx *= scale * shove * shove_half;
    dz *= scale * shove * shove_half;

    self.base.motion.x -= dx;
    self.base.motion.z -= dz;
    other.motion.x += dx / bystander_share;
    other.motion.z += dz / bystander_share;
}

const bystander_share: f64 = 4.0;

pub fn slot(self: *Minecart, index: usize) *?world.Stack {
    return &self.items[index];
}

pub fn isEmpty(self: Minecart) bool {
    for (self.items) |maybe| {
        if (maybe != null) return false;
    }
    return true;
}

pub fn droppedItem(kind: Kind) world.Id {
    return switch (kind) {
        .empty => .{ .item = .minecart },
        .chest => .{ .block = .chest },
        .furnace => .{ .block = .furnace },
    };
}

pub fn toRecord(self: Minecart) world.entity_nbt.Minecart {
    return .{
        .base = .{
            .position = self.base.position,
            .motion = self.base.motion,
            .yaw = self.yaw,
            .pitch = self.pitch,
            .on_ground = self.base.on_ground,
        },
        .kind = @intFromEnum(self.kind),
        .fuel = self.fuel,
        .push = .{ self.push.x, self.push.z },
        .items = self.items,
    };
}

pub fn fromRecord(record: world.entity_nbt.Minecart) Minecart {
    var self = Minecart.spawn(record.base.position, @enumFromInt(@min(record.kind, 2)));
    self.base.motion = record.base.motion;
    self.base.on_ground = record.base.on_ground;
    self.yaw = record.base.yaw;
    self.pitch = record.base.pitch;
    self.prev_yaw = record.base.yaw;
    self.prev_pitch = record.base.pitch;
    self.fuel = record.fuel;
    self.push = math.Vec3.init(record.push[0], 0, record.push[1]);
    self.items = record.items;
    return self;
}

fn railWorld(shape_along_x: bool) !world.World {
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    errdefer w.deinit();

    var step: i32 = 4;
    while (step <= 12) : (step += 1) {
        if (shape_along_x) {
            try w.setBlockWithNotify(.init(step, 12, 8), .rail);
        } else {
            try w.setBlockWithNotify(.init(8, 12, step), .rail);
        }
    }
    return w;
}

test "a minecart is the size EntityMinecart sets itself to" {
    const cart = Minecart.spawn(math.Vec3.init(8.5, 12.5, 8.5), .empty);
    try std.testing.expectEqual(@as(f64, 0.98), cart.base.width);
    try std.testing.expectEqual(@as(f64, 0.7), cart.base.height);
    try std.testing.expectEqual(Kind.empty, cart.kind);
}

test "a minecart on a straight rail is pulled onto the centre line" {
    var w = try railWorld(true);
    defer w.deinit();

    var cart = Minecart.spawn(math.Vec3.init(8.2, 12.0, 8.4), .empty);
    _ = cart.tick(&w, &.{}, false);

    try std.testing.expectApproxEqAbs(@as(f64, 8.5), cart.base.position.z, 1.0e-9);
}

test "a minecart rolls along the rail it was pushed down and stays on it" {
    var w = try railWorld(true);
    defer w.deinit();

    var cart = Minecart.spawn(math.Vec3.init(6.5, 12.0, 8.5), .empty);
    cart.base.motion = math.Vec3.init(0.3, 0, 0);

    for (0..20) |_| _ = cart.tick(&w, &.{}, false);

    try std.testing.expect(cart.base.position.x > 7.5);
    try std.testing.expectApproxEqAbs(@as(f64, 8.5), cart.base.position.z, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 12.15), cart.base.position.y, 1.0e-9);
}

test "a minecart driven into a wall on the rails stops dead" {
    var w = try railWorld(true);
    defer w.deinit();
    try w.setBlockWithNotify(.init(9, 12, 8), .stone);

    var cart = Minecart.spawn(math.Vec3.init(6.5, 12.0, 8.5), .empty);
    cart.base.motion = math.Vec3.init(0.3, 0, 0);
    for (0..20) |_| _ = cart.tick(&w, &.{}, false);

    try std.testing.expect(cart.base.position.x < 9.0);
    try std.testing.expectEqual(@as(f64, 0), cart.base.motion.x);
}

test "the rail lookahead reads the next rail's height, sloped or not" {
    var w = try railWorld(true);
    defer w.deinit();

    const level = Minecart.railAhead(&w, 8.5, 12.5, 8.5, 0.3).?;
    const flat = Minecart.railAt(&w, 8.5, 12.5, 8.5).?;
    try std.testing.expectApproxEqAbs(flat.y, level.y, 1.0e-9);

    try w.setBlockMetadataWithNotify(.init(9, 12, 8), 3);
    const climbing = Minecart.railAhead(&w, 8.5, 12.5, 8.5, 0.6).?;
    try std.testing.expect(climbing.y > level.y);

    const behind = Minecart.railAhead(&w, 8.5, 12.5, 8.5, -0.6).?;
    try std.testing.expectApproxEqAbs(level.y, behind.y, 1.0e-9);
}

test "a minecart left alone on level track coasts to a halt" {
    var w = try railWorld(true);
    defer w.deinit();

    var cart = Minecart.spawn(math.Vec3.init(6.5, 12.0, 8.5), .empty);
    cart.base.motion = math.Vec3.init(0.3, 0, 0);
    for (0..400) |_| _ = cart.tick(&w, &.{}, false);

    try std.testing.expect(@abs(cart.base.motion.x) < 0.01);
}

test "a powered rail speeds a moving cart up and an unpowered one brakes it" {
    var boosted = try railWorld(true);
    defer boosted.deinit();
    try boosted.setBlockWithNotify(.init(8, 12, 8), .rail_powered);
    try boosted.setBlockMetadataWithNotify(.init(8, 12, 8), 1 | world.block.rail_flag_bit);

    var fast = Minecart.spawn(math.Vec3.init(8.5, 12.0, 8.5), .empty);
    fast.base.motion = math.Vec3.init(0.1, 0, 0);
    const before = fast.base.motion.x;
    _ = fast.tick(&boosted, &.{}, false);
    try std.testing.expect(fast.base.motion.x > before);

    var braked = try railWorld(true);
    defer braked.deinit();
    try braked.setBlockWithNotify(.init(8, 12, 8), .rail_powered);
    try braked.setBlockMetadataWithNotify(.init(8, 12, 8), 1);

    var slow = Minecart.spawn(math.Vec3.init(8.5, 12.0, 8.5), .empty);
    slow.base.motion = math.Vec3.init(0.1, 0, 0);
    _ = slow.tick(&braked, &.{}, false);
    try std.testing.expect(slow.base.motion.x < 0.1);
}

test "a minecart off the rails falls and drags along the ground" {
    const gpa = std.testing.allocator;
    var w = try testing_world.flatWorld(gpa, 12);
    defer w.deinit();

    var cart = Minecart.spawn(math.Vec3.init(8.5, 16.0, 8.5), .empty);
    _ = cart.tick(&w, &.{}, false);
    try std.testing.expect(cart.base.motion.y < 0);

    for (0..40) |_| _ = cart.tick(&w, &.{}, false);
    try std.testing.expectApproxEqAbs(@as(f64, 12.0), cart.base.position.y, 1.0e-6);
}

test "two carts meeting head on trade their momentum" {
    var rolling = Minecart.spawn(math.Vec3.init(8.0, 12.15, 8.5), .empty);
    rolling.base.motion = math.Vec3.init(0.3, 0, 0);
    var parked = Minecart.spawn(math.Vec3.init(8.8, 12.15, 8.5), .empty);

    parked.collideWith(&rolling);

    try std.testing.expect(parked.base.motion.x > 0.1);
    try std.testing.expect(rolling.base.motion.x < 0.3);
    try std.testing.expect(rolling.base.motion.x > 0.0);
}

test "a furnace cart shoves an ordinary one along instead of splitting the difference" {
    var pusher = Minecart.spawn(math.Vec3.init(8.0, 12.15, 8.5), .furnace);
    pusher.base.motion = math.Vec3.init(0.3, 0, 0);
    var pushed = Minecart.spawn(math.Vec3.init(8.8, 12.15, 8.5), .empty);

    pushed.collideWith(&pusher);

    try std.testing.expect(pushed.base.motion.x > 0.2);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3 * 0.7), pusher.base.motion.x, 1.0e-9);
}

test "carts touching but not overlapping in x are left alone" {
    var a = Minecart.spawn(math.Vec3.init(8.5, 12.15, 8.5), .empty);
    var b = Minecart.spawn(math.Vec3.init(8.5, 12.15, 8.5), .empty);
    b.base.motion = math.Vec3.init(0.3, 0, 0);

    a.collideWith(&b);
    try std.testing.expectEqual(@as(f64, 0.3), b.base.motion.x);
    try std.testing.expectEqual(@as(f64, 0), a.base.motion.x);
}

test "far from the origin EntityMinecart's skew test lets carts roll through each other" {
    var near_a = Minecart.spawn(math.Vec3.init(0.0, 12.15, 8.5), .empty);
    near_a.base.motion = math.Vec3.init(0.3, 0, 0);
    near_a.base.prev_position = near_a.base.position;
    var near_b = Minecart.spawn(math.Vec3.init(0.6, 12.15, 8.8), .empty);
    near_b.collideWith(&near_a);
    try std.testing.expect(near_b.base.motion.x != 0);

    var far_a = Minecart.spawn(math.Vec3.init(400.0, 12.15, 8.5), .empty);
    far_a.base.motion = math.Vec3.init(0.3, 0, 0);
    far_a.base.prev_position = far_a.base.position;
    var far_b = Minecart.spawn(math.Vec3.init(400.6, 12.15, 8.8), .empty);
    far_b.collideWith(&far_a);
    try std.testing.expectEqual(@as(f64, 0), far_b.base.motion.x);
    try std.testing.expectEqual(@as(f64, 0.3), far_a.base.motion.x);
}

test "a cart shoves a bystander at a quarter of what it takes itself" {
    var cart = Minecart.spawn(math.Vec3.init(8.0, 12.15, 8.5), .empty);
    var bystander = Entity.init(math.Vec3.init(8.8, 12.15, 8.5), 0.6, 1.8);

    cart.shoveOff(&bystander);

    try std.testing.expect(cart.base.motion.x < 0);
    try std.testing.expect(bystander.motion.x > 0);
    try std.testing.expectApproxEqAbs(-cart.base.motion.x / 4.0, bystander.motion.x, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0), bystander.motion.z, 1.0e-12);
}

test "a bystander standing exactly on the cart is left alone" {
    var cart = Minecart.spawn(math.Vec3.init(8.5, 12.15, 8.5), .empty);
    var bystander = Entity.init(math.Vec3.init(8.5, 12.15, 8.5), 0.6, 1.8);

    cart.shoveOff(&bystander);
    try std.testing.expectEqual(@as(f64, 0), cart.base.motion.x);
    try std.testing.expectEqual(@as(f64, 0), bystander.motion.x);
}

test "only a moving, empty, riderless cart scoops a passenger up" {
    var rolling = Minecart.spawn(math.Vec3.init(0, 0, 0), .empty);
    rolling.base.motion = math.Vec3.init(0.2, 0, 0);
    try std.testing.expect(rolling.wouldScoop());

    var crawling = Minecart.spawn(math.Vec3.init(0, 0, 0), .empty);
    crawling.base.motion = math.Vec3.init(0.05, 0, 0);
    try std.testing.expect(!crawling.wouldScoop());

    var occupied = Minecart.spawn(math.Vec3.init(0, 0, 0), .empty);
    occupied.base.motion = math.Vec3.init(0.2, 0, 0);
    occupied.rider = 7;
    try std.testing.expect(!occupied.wouldScoop());

    for ([_]Kind{ .chest, .furnace }) |kind| {
        var cargo = Minecart.spawn(math.Vec3.init(0, 0, 0), kind);
        cargo.base.motion = math.Vec3.init(0.2, 0, 0);
        try std.testing.expect(!cargo.wouldScoop());
    }
}

test "stepping off a cart sets you down on top of it, not in the seat" {
    const cart = Minecart.spawn(math.Vec3.init(8.5, 12.15, 8.5), .empty);
    const seat = cart.riderPosition();
    const off = Entity.dismountPosition(cart.base);

    try std.testing.expectApproxEqAbs(@as(f64, 12.15 + height), off.y, 1.0e-12);
    try std.testing.expect(off.y > seat.y);
    try std.testing.expectApproxEqAbs(cart.base.position.x, off.x, 1.0e-12);
    try std.testing.expectApproxEqAbs(cart.base.position.z, off.z, 1.0e-12);
}

test "a rider sits just above the cart floor" {
    const cart = Minecart.spawn(math.Vec3.init(8.5, 12.15, 8.5), .empty);
    const seat = cart.riderPosition();
    try std.testing.expectApproxEqAbs(@as(f64, 12.15 + 0.05), seat.y, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 8.5), seat.x, 1.0e-12);
}

test "a minecart breaks after enough damage and shrugs off a little" {
    var light = Minecart.spawn(math.Vec3.init(0, 0, 0), .empty);
    _ = light.hurt(1);
    try std.testing.expectEqual(@as(i32, 10), light.damage);
    try std.testing.expect(!light.dead);

    var doomed = Minecart.spawn(math.Vec3.init(0, 0, 0), .empty);
    _ = doomed.hurt(5);
    try std.testing.expect(doomed.dead);
}

test "each cart kind names the extra block it leaves behind" {
    try std.testing.expectEqual(world.Id{ .item = .minecart }, droppedItem(.empty));
    try std.testing.expectEqual(world.Id{ .block = .chest }, droppedItem(.chest));
    try std.testing.expectEqual(world.Id{ .block = .furnace }, droppedItem(.furnace));
}

test "a chest cart holds a chest's worth of slots" {
    var cart = Minecart.spawn(math.Vec3.init(0, 0, 0), .chest);
    try std.testing.expect(cart.isEmpty());
    cart.slot(26).* = .{ .id = .{ .block = .stone }, .count = 64 };
    try std.testing.expect(!cart.isEmpty());
    try std.testing.expectEqual(@as(usize, 27), cart.items.len);
}

test "a minecart's cargo and heading survive a record round trip" {
    var cart = Minecart.spawn(math.Vec3.init(-12.25, 63.5, 7.75), .chest);
    cart.base.motion = math.Vec3.init(0.1, -0.2, 0.3);
    cart.yaw = 42.5;
    cart.fuel = 600;
    cart.slot(3).* = .{ .id = .{ .item = .diamond }, .count = 5 };

    const restored = Minecart.fromRecord(cart.toRecord());
    try std.testing.expectEqual(cart.base.position, restored.base.position);
    try std.testing.expectEqual(cart.base.motion, restored.base.motion);
    try std.testing.expectEqual(cart.yaw, restored.yaw);
    try std.testing.expectEqual(Kind.chest, restored.kind);
    try std.testing.expectEqual(@as(i32, 600), restored.fuel);
    try std.testing.expectEqual(cart.items[3], restored.items[3]);
}
