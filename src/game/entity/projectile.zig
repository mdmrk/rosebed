const std = @import("std");

const math = @import("math");
const world = @import("world");

pub const spread_scale: f32 = 0.0075;
pub const drag: f32 = 0.99;
pub const water_drag: f32 = 0.8;
pub const gravity: f32 = 0.03;
pub const rotation_smoothing: f32 = 0.2;
pub const trail_back: f32 = 0.25;
pub const void_floor: f64 = -64.0;

const float_pi: f64 = @as(f32, std.math.pi);

pub const BubbleTrail = struct {
    position: math.Vec3,
    drift: math.Vec3,
};

pub fn flatSpeed(x: f64, z: f64) f64 {
    return math.util.sqrtF(x * x + z * z);
}

pub fn headingYaw(x: f64, z: f64) f32 {
    return @floatCast(std.math.atan2(x, z) * 180.0 / float_pi);
}

pub fn headingPitch(y: f64, flat: f64) f32 {
    return @floatCast(std.math.atan2(y, flat) * 180.0 / float_pi);
}

pub fn setHeading(self: anytype, direction: math.Vec3, speed: f32, spread: f32, rand: *world.JavaRandom) void {
    const length: f64 = math.util.sqrtF(
        direction.x * direction.x + direction.y * direction.y + direction.z * direction.z,
    );

    var x = direction.x / length;
    var y = direction.y / length;
    var z = direction.z / length;

    x += rand.nextGaussian() * spread_scale * spread;
    y += rand.nextGaussian() * spread_scale * spread;
    z += rand.nextGaussian() * spread_scale * spread;

    x *= speed;
    y *= speed;
    z *= speed;

    self.base.motion = math.Vec3.init(x, y, z);
    self.yaw = headingYaw(x, z);
    self.pitch = headingPitch(y, flatSpeed(x, z));
    self.prev_yaw = self.yaw;
    self.prev_pitch = self.pitch;
}

pub fn smoothRotation(self: anytype) void {
    while (self.pitch - self.prev_pitch < -180.0) self.prev_pitch -= 360.0;
    while (self.pitch - self.prev_pitch >= 180.0) self.prev_pitch += 360.0;
    while (self.yaw - self.prev_yaw < -180.0) self.prev_yaw -= 360.0;
    while (self.yaw - self.prev_yaw >= 180.0) self.prev_yaw += 360.0;
    self.pitch = self.prev_pitch + (self.pitch - self.prev_pitch) * rotation_smoothing;
    self.yaw = self.prev_yaw + (self.yaw - self.prev_yaw) * rotation_smoothing;
}

pub fn bubbleTrail(self: anytype) ?BubbleTrail {
    if (!self.base.in_water) return null;
    return .{
        .position = math.Vec3.init(
            self.base.position.x - self.base.motion.x * trail_back,
            self.base.position.y - self.base.motion.y * trail_back,
            self.base.position.z - self.base.motion.z * trail_back,
        ),
        .drift = self.base.motion,
    };
}

pub fn fly(self: anytype) ?BubbleTrail {
    self.base.position.x += self.base.motion.x;
    self.base.position.y += self.base.motion.y;
    self.base.position.z += self.base.motion.z;

    self.yaw = headingYaw(self.base.motion.x, self.base.motion.z);
    self.pitch = headingPitch(self.base.motion.y, flatSpeed(self.base.motion.x, self.base.motion.z));
    smoothRotation(self);

    const trail = bubbleTrail(self);

    const factor: f64 = if (self.base.in_water) water_drag else drag;
    self.base.motion.x *= factor;
    self.base.motion.y *= factor;
    self.base.motion.z *= factor;
    self.base.motion.y -= gravity;

    return trail;
}
