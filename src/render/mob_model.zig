const std = @import("std");

const math = @import("math");
const world = @import("world");

const MeshBuilder = @import("mesh_builder.zig");

pub const Box = struct {
    origin: [3]f32,
    size: [3]f32,
    tex_u: f32,
    tex_v: f32,
    inflate: f32 = 0,
    mirror: bool = false,
};

pub const Role = enum { still, head, leg_ahead, leg_behind, wing_right, wing_left };

pub const Part = struct {
    box: Box,
    pivot: [3]f32,
    rotate_x: f32 = 0,
    rotate_y: f32 = 0,
    rotate_z: f32 = 0,
    role: Role = .still,
};

pub const Pose = struct {
    position: [3]f32,
    yaw: f32,
    roll: f32 = 0,
    scale: [3]f32 = .{ 1, 1, 1 },
};

pub const Model = struct {
    parts: []const Part,
    head_index: usize,
    texture_width: f32,
    texture_height: f32,
};

const pig_parts = [6]Part{
    .{ .box = .{ .origin = .{ -4, -4, -8 }, .size = .{ 8, 8, 8 }, .tex_u = 0, .tex_v = 0 }, .pivot = .{ 0, -12, -6 }, .role = .head },
    .{ .box = .{ .origin = .{ -5, -10, -7 }, .size = .{ 10, 16, 8 }, .tex_u = 28, .tex_v = 8 }, .pivot = .{ 0, -13, 2 }, .rotate_x = std.math.pi * 0.5 },
    .{ .box = .{ .origin = .{ -2, 0, -2 }, .size = .{ 4, 6, 4 }, .tex_u = 0, .tex_v = 16 }, .pivot = .{ -3, -6, 7 }, .role = .leg_ahead },
    .{ .box = .{ .origin = .{ -2, 0, -2 }, .size = .{ 4, 6, 4 }, .tex_u = 0, .tex_v = 16 }, .pivot = .{ 3, -6, 7 }, .role = .leg_behind },
    .{ .box = .{ .origin = .{ -2, 0, -2 }, .size = .{ 4, 6, 4 }, .tex_u = 0, .tex_v = 16 }, .pivot = .{ -3, -6, -5 }, .role = .leg_behind },
    .{ .box = .{ .origin = .{ -2, 0, -2 }, .size = .{ 4, 6, 4 }, .tex_u = 0, .tex_v = 16 }, .pivot = .{ 3, -6, -5 }, .role = .leg_ahead },
};

pub const pig: Model = .{
    .parts = &pig_parts,
    .head_index = 0,
    .texture_width = 64,
    .texture_height = 32,
};

const saddle_inflate: f32 = 0.5;

const pig_saddle_parts = blk: {
    var parts = pig_parts;
    for (&parts) |*part| part.box.inflate = saddle_inflate;
    break :blk parts;
};

pub const pig_saddle: Model = .{
    .parts = &pig_saddle_parts,
    .head_index = 0,
    .texture_width = 64,
    .texture_height = 32,
};

const sheep_parts = [6]Part{
    .{ .box = .{ .origin = .{ -3, -4, -6 }, .size = .{ 6, 6, 8 }, .tex_u = 0, .tex_v = 0 }, .pivot = .{ 0, -18, -8 }, .role = .head },
    .{ .box = .{ .origin = .{ -4, -10, -7 }, .size = .{ 8, 16, 6 }, .tex_u = 28, .tex_v = 8 }, .pivot = .{ 0, -19, 2 }, .rotate_x = std.math.pi * 0.5 },
    .{ .box = .{ .origin = .{ -2, 0, -2 }, .size = .{ 4, 12, 4 }, .tex_u = 0, .tex_v = 16 }, .pivot = .{ -3, -12, 7 }, .role = .leg_ahead },
    .{ .box = .{ .origin = .{ -2, 0, -2 }, .size = .{ 4, 12, 4 }, .tex_u = 0, .tex_v = 16 }, .pivot = .{ 3, -12, 7 }, .role = .leg_behind },
    .{ .box = .{ .origin = .{ -2, 0, -2 }, .size = .{ 4, 12, 4 }, .tex_u = 0, .tex_v = 16 }, .pivot = .{ -3, -12, -5 }, .role = .leg_behind },
    .{ .box = .{ .origin = .{ -2, 0, -2 }, .size = .{ 4, 12, 4 }, .tex_u = 0, .tex_v = 16 }, .pivot = .{ 3, -12, -5 }, .role = .leg_ahead },
};

pub const sheep: Model = .{
    .parts = &sheep_parts,
    .head_index = 0,
    .texture_width = 64,
    .texture_height = 32,
};

const sheep_fur_parts = [6]Part{
    .{ .box = .{ .origin = .{ -3, -4, -4 }, .size = .{ 6, 6, 6 }, .tex_u = 0, .tex_v = 0, .inflate = 0.6 }, .pivot = .{ 0, -18, -8 }, .role = .head },
    .{ .box = .{ .origin = .{ -4, -10, -7 }, .size = .{ 8, 16, 6 }, .tex_u = 28, .tex_v = 8, .inflate = 1.75 }, .pivot = .{ 0, -19, 2 }, .rotate_x = std.math.pi * 0.5 },
    .{ .box = .{ .origin = .{ -2, 0, -2 }, .size = .{ 4, 6, 4 }, .tex_u = 0, .tex_v = 16, .inflate = 0.5 }, .pivot = .{ -3, -12, 7 }, .role = .leg_ahead },
    .{ .box = .{ .origin = .{ -2, 0, -2 }, .size = .{ 4, 6, 4 }, .tex_u = 0, .tex_v = 16, .inflate = 0.5 }, .pivot = .{ 3, -12, 7 }, .role = .leg_behind },
    .{ .box = .{ .origin = .{ -2, 0, -2 }, .size = .{ 4, 6, 4 }, .tex_u = 0, .tex_v = 16, .inflate = 0.5 }, .pivot = .{ -3, -12, -5 }, .role = .leg_behind },
    .{ .box = .{ .origin = .{ -2, 0, -2 }, .size = .{ 4, 6, 4 }, .tex_u = 0, .tex_v = 16, .inflate = 0.5 }, .pivot = .{ 3, -12, -5 }, .role = .leg_ahead },
};

pub const sheep_fur: Model = .{
    .parts = &sheep_fur_parts,
    .head_index = 0,
    .texture_width = 64,
    .texture_height = 32,
};

const cow_parts = [9]Part{
    .{ .box = .{ .origin = .{ -4, -4, -6 }, .size = .{ 8, 8, 6 }, .tex_u = 0, .tex_v = 0 }, .pivot = .{ 0, -20, -8 }, .role = .head },
    .{ .box = .{ .origin = .{ -5, -5, -4 }, .size = .{ 1, 3, 1 }, .tex_u = 22, .tex_v = 0 }, .pivot = .{ 0, -20, -8 }, .role = .head },
    .{ .box = .{ .origin = .{ 4, -5, -4 }, .size = .{ 1, 3, 1 }, .tex_u = 22, .tex_v = 0 }, .pivot = .{ 0, -20, -8 }, .role = .head },
    .{ .box = .{ .origin = .{ -6, -10, -7 }, .size = .{ 12, 18, 10 }, .tex_u = 18, .tex_v = 4 }, .pivot = .{ 0, -19, 2 }, .rotate_x = std.math.pi * 0.5 },
    .{ .box = .{ .origin = .{ -2, 2, -8 }, .size = .{ 4, 6, 1 }, .tex_u = 52, .tex_v = 0 }, .pivot = .{ 0, -19, 2 }, .rotate_x = std.math.pi * 0.5 },
    .{ .box = .{ .origin = .{ -2, 0, -2 }, .size = .{ 4, 12, 4 }, .tex_u = 0, .tex_v = 16 }, .pivot = .{ -4, -12, 7 }, .role = .leg_ahead },
    .{ .box = .{ .origin = .{ -2, 0, -2 }, .size = .{ 4, 12, 4 }, .tex_u = 0, .tex_v = 16 }, .pivot = .{ 4, -12, 7 }, .role = .leg_behind },
    .{ .box = .{ .origin = .{ -2, 0, -2 }, .size = .{ 4, 12, 4 }, .tex_u = 0, .tex_v = 16 }, .pivot = .{ -4, -12, -6 }, .role = .leg_behind },
    .{ .box = .{ .origin = .{ -2, 0, -2 }, .size = .{ 4, 12, 4 }, .tex_u = 0, .tex_v = 16 }, .pivot = .{ 4, -12, -6 }, .role = .leg_ahead },
};

pub const cow: Model = .{
    .parts = &cow_parts,
    .head_index = 0,
    .texture_width = 64,
    .texture_height = 32,
};

const chicken_parts = [8]Part{
    .{ .box = .{ .origin = .{ -2, -6, -2 }, .size = .{ 4, 6, 3 }, .tex_u = 0, .tex_v = 0 }, .pivot = .{ 0, -9, -4 }, .role = .head },
    .{ .box = .{ .origin = .{ -2, -4, -4 }, .size = .{ 4, 2, 2 }, .tex_u = 14, .tex_v = 0 }, .pivot = .{ 0, -9, -4 }, .role = .head },
    .{ .box = .{ .origin = .{ -1, -2, -3 }, .size = .{ 2, 2, 2 }, .tex_u = 14, .tex_v = 4 }, .pivot = .{ 0, -9, -4 }, .role = .head },
    .{ .box = .{ .origin = .{ -3, -4, -3 }, .size = .{ 6, 8, 6 }, .tex_u = 0, .tex_v = 9 }, .pivot = .{ 0, -8, 0 }, .rotate_x = std.math.pi * 0.5 },
    .{ .box = .{ .origin = .{ -1, 0, -3 }, .size = .{ 3, 5, 3 }, .tex_u = 26, .tex_v = 0 }, .pivot = .{ -2, -5, 1 }, .role = .leg_ahead },
    .{ .box = .{ .origin = .{ -1, 0, -3 }, .size = .{ 3, 5, 3 }, .tex_u = 26, .tex_v = 0 }, .pivot = .{ 1, -5, 1 }, .role = .leg_behind },
    .{ .box = .{ .origin = .{ 0, 0, -3 }, .size = .{ 1, 4, 6 }, .tex_u = 24, .tex_v = 13 }, .pivot = .{ -4, -11, 0 }, .role = .wing_right },
    .{ .box = .{ .origin = .{ -1, 0, -3 }, .size = .{ 1, 4, 6 }, .tex_u = 24, .tex_v = 13 }, .pivot = .{ 4, -11, 0 }, .role = .wing_left },
};

pub const chicken: Model = .{
    .parts = &chicken_parts,
    .head_index = 0,
    .texture_width = 64,
    .texture_height = 32,
};

const creeper_parts = [6]Part{
    .{ .box = .{ .origin = .{ -4, -8, -4 }, .size = .{ 8, 8, 8 }, .tex_u = 0, .tex_v = 0 }, .pivot = .{ 0, -20, 0 }, .role = .head },
    .{ .box = .{ .origin = .{ -4, 0, -2 }, .size = .{ 8, 12, 4 }, .tex_u = 16, .tex_v = 16 }, .pivot = .{ 0, -20, 0 } },
    .{ .box = .{ .origin = .{ -2, 0, -2 }, .size = .{ 4, 6, 4 }, .tex_u = 0, .tex_v = 16 }, .pivot = .{ -2, -8, 4 }, .role = .leg_ahead },
    .{ .box = .{ .origin = .{ -2, 0, -2 }, .size = .{ 4, 6, 4 }, .tex_u = 0, .tex_v = 16 }, .pivot = .{ 2, -8, 4 }, .role = .leg_behind },
    .{ .box = .{ .origin = .{ -2, 0, -2 }, .size = .{ 4, 6, 4 }, .tex_u = 0, .tex_v = 16 }, .pivot = .{ -2, -8, -4 }, .role = .leg_behind },
    .{ .box = .{ .origin = .{ -2, 0, -2 }, .size = .{ 4, 6, 4 }, .tex_u = 0, .tex_v = 16 }, .pivot = .{ 2, -8, -4 }, .role = .leg_ahead },
};

pub const creeper: Model = .{
    .parts = &creeper_parts,
    .head_index = 0,
    .texture_width = 64,
    .texture_height = 32,
};

const wolf_head_index: usize = 0;
const wolf_body_index: usize = 1;
const wolf_leg_back_right: usize = 2;
const wolf_leg_back_left: usize = 3;
const wolf_leg_front_right: usize = 4;
const wolf_leg_front_left: usize = 5;
const wolf_ear_right: usize = 6;
const wolf_ear_left: usize = 7;
const wolf_snout_index: usize = 8;
const wolf_tail_index: usize = 9;
const wolf_mane_index: usize = 10;

const wolf_parts = [11]Part{
    .{ .box = .{ .origin = .{ -3, -3, -2 }, .size = .{ 6, 6, 4 }, .tex_u = 0, .tex_v = 0 }, .pivot = .{ -1, -10.5, -7 } },
    .{ .box = .{ .origin = .{ -4, -2, -3 }, .size = .{ 6, 9, 6 }, .tex_u = 18, .tex_v = 14 }, .pivot = .{ 0, -10, 2 } },
    .{ .box = .{ .origin = .{ -1, 0, -1 }, .size = .{ 2, 8, 2 }, .tex_u = 0, .tex_v = 18 }, .pivot = .{ -2.5, -8, 7 } },
    .{ .box = .{ .origin = .{ -1, 0, -1 }, .size = .{ 2, 8, 2 }, .tex_u = 0, .tex_v = 18 }, .pivot = .{ 0.5, -8, 7 } },
    .{ .box = .{ .origin = .{ -1, 0, -1 }, .size = .{ 2, 8, 2 }, .tex_u = 0, .tex_v = 18 }, .pivot = .{ -2.5, -8, -4 } },
    .{ .box = .{ .origin = .{ -1, 0, -1 }, .size = .{ 2, 8, 2 }, .tex_u = 0, .tex_v = 18 }, .pivot = .{ 0.5, -8, -4 } },
    .{ .box = .{ .origin = .{ -3, -5, 0 }, .size = .{ 2, 2, 1 }, .tex_u = 16, .tex_v = 14 }, .pivot = .{ -1, -10.5, -7 } },
    .{ .box = .{ .origin = .{ 1, -5, 0 }, .size = .{ 2, 2, 1 }, .tex_u = 16, .tex_v = 14 }, .pivot = .{ -1, -10.5, -7 } },
    .{ .box = .{ .origin = .{ -2, 0, -5 }, .size = .{ 3, 3, 4 }, .tex_u = 0, .tex_v = 10 }, .pivot = .{ -0.5, -10.5, -7 } },
    .{ .box = .{ .origin = .{ -1, 0, -1 }, .size = .{ 2, 8, 2 }, .tex_u = 9, .tex_v = 18 }, .pivot = .{ -1, -12, 8 } },
    .{ .box = .{ .origin = .{ -4, -3, -3 }, .size = .{ 8, 6, 7 }, .tex_u = 21, .tex_v = 0 }, .pivot = .{ -1, -10, -3 } },
};

pub const wolf: Model = .{
    .parts = &wolf_parts,
    .head_index = wolf_head_index,
    .texture_width = 64,
    .texture_height = 32,
};

pub const WolfPose = struct {
    limb_swing: f32,
    limb_swing_amount: f32,
    head_yaw: f32,
    head_pitch: f32,
    tail_rotation: f32,
    interested_angle: f32,
    sitting: bool,
    angry: bool,
    head_shake: f32,
    mane_shake: f32,
    body_shake: f32,
    tail_shake: f32,
};

pub fn wolfPosed(pose: WolfPose) [wolf_parts.len]Part {
    const degrees = std.math.pi / 180.0;
    const pi = std.math.pi;

    var parts = wolf_parts;
    const stride = math.util.cos(pose.limb_swing * 0.6662) * 1.4 * pose.limb_swing_amount;

    parts[wolf_tail_index].rotate_y = if (pose.angry) 0 else stride;

    if (pose.sitting) {
        parts[wolf_mane_index].pivot = .{ -1, -8, -3 };
        parts[wolf_mane_index].rotate_x = pi * 0.4;
        parts[wolf_mane_index].rotate_y = 0;
        parts[wolf_body_index].pivot = .{ 0, -6, 0 };
        parts[wolf_body_index].rotate_x = pi * 0.25;
        parts[wolf_tail_index].pivot = .{ -1, -3, 6 };
        parts[wolf_leg_back_right].pivot = .{ -2.5, -2, 2 };
        parts[wolf_leg_back_right].rotate_x = pi * 3.0 / 2.0;
        parts[wolf_leg_back_left].pivot = .{ 0.5, -2, 2 };
        parts[wolf_leg_back_left].rotate_x = pi * 3.0 / 2.0;
        parts[wolf_leg_front_right].rotate_x = pi * 1.85;
        parts[wolf_leg_front_right].pivot = .{ -2.49, -7, -4 };
        parts[wolf_leg_front_left].rotate_x = pi * 1.85;
        parts[wolf_leg_front_left].pivot = .{ 0.51, -7, -4 };
    } else {
        parts[wolf_body_index].rotate_x = pi * 0.5;
        parts[wolf_mane_index].rotate_x = parts[wolf_body_index].rotate_x;
        parts[wolf_leg_back_right].rotate_x = stride;
        parts[wolf_leg_back_left].rotate_x = -stride;
        parts[wolf_leg_front_right].rotate_x = -stride;
        parts[wolf_leg_front_left].rotate_x = stride;
    }

    const tilt = pose.interested_angle + pose.head_shake;
    parts[wolf_head_index].rotate_z = tilt;
    parts[wolf_ear_right].rotate_z = tilt;
    parts[wolf_ear_left].rotate_z = tilt;
    parts[wolf_snout_index].rotate_z = tilt;
    parts[wolf_mane_index].rotate_z = pose.mane_shake;
    parts[wolf_body_index].rotate_z = pose.body_shake;
    parts[wolf_tail_index].rotate_z = pose.tail_shake;

    parts[wolf_head_index].rotate_x = pose.head_pitch * degrees;
    parts[wolf_head_index].rotate_y = pose.head_yaw * degrees;
    parts[wolf_ear_right].rotate_x = parts[wolf_head_index].rotate_x;
    parts[wolf_ear_right].rotate_y = parts[wolf_head_index].rotate_y;
    parts[wolf_ear_left].rotate_x = parts[wolf_head_index].rotate_x;
    parts[wolf_ear_left].rotate_y = parts[wolf_head_index].rotate_y;
    parts[wolf_snout_index].rotate_x = parts[wolf_head_index].rotate_x;
    parts[wolf_snout_index].rotate_y = parts[wolf_head_index].rotate_y;
    parts[wolf_tail_index].rotate_x = pose.tail_rotation;

    return parts;
}

const slime_body_parts = [4]Part{
    .{ .box = .{ .origin = .{ -3, 17, -3 }, .size = .{ 6, 6, 6 }, .tex_u = 0, .tex_v = 16 }, .pivot = .{ 0, -24, 0 } },
    .{ .box = .{ .origin = .{ -3.25, 18, -3.5 }, .size = .{ 2, 2, 2 }, .tex_u = 32, .tex_v = 0 }, .pivot = .{ 0, -24, 0 } },
    .{ .box = .{ .origin = .{ 1.25, 18, -3.5 }, .size = .{ 2, 2, 2 }, .tex_u = 32, .tex_v = 4 }, .pivot = .{ 0, -24, 0 } },
    .{ .box = .{ .origin = .{ 0, 21, -3.5 }, .size = .{ 1, 1, 1 }, .tex_u = 32, .tex_v = 8 }, .pivot = .{ 0, -24, 0 } },
};

pub const slime_body: Model = .{
    .parts = &slime_body_parts,
    .head_index = 0,
    .texture_width = 64,
    .texture_height = 32,
};

const slime_shell_parts = [1]Part{
    .{ .box = .{ .origin = .{ -4, 16, -4 }, .size = .{ 8, 8, 8 }, .tex_u = 0, .tex_v = 0 }, .pivot = .{ 0, -24, 0 } },
};

pub const slime_shell: Model = .{
    .parts = &slime_shell_parts,
    .head_index = 0,
    .texture_width = 64,
    .texture_height = 32,
};

const biped_parts = [6]Part{
    .{ .box = .{ .origin = .{ -4, 0, -2 }, .size = .{ 8, 12, 4 }, .tex_u = 16, .tex_v = 16 }, .pivot = .{ 0, -24, 0 } },
    .{ .box = .{ .origin = .{ -2, 0, -2 }, .size = .{ 4, 12, 4 }, .tex_u = 0, .tex_v = 16 }, .pivot = .{ -2, -12, 0 } },
    .{ .box = .{ .origin = .{ -2, 0, -2 }, .size = .{ 4, 12, 4 }, .tex_u = 0, .tex_v = 16 }, .pivot = .{ 2, -12, 0 } },
    .{ .box = .{ .origin = .{ -3, -2, -2 }, .size = .{ 4, 12, 4 }, .tex_u = 40, .tex_v = 16 }, .pivot = .{ -5, -22, 0 } },
    .{ .box = .{ .origin = .{ -1, -2, -2 }, .size = .{ 4, 12, 4 }, .tex_u = 40, .tex_v = 16 }, .pivot = .{ 5, -22, 0 } },
    .{ .box = .{ .origin = .{ -4, -8, -4 }, .size = .{ 8, 8, 8 }, .tex_u = 0, .tex_v = 0 }, .pivot = .{ 0, -24, 0 } },
};

pub const biped: Model = .{
    .parts = &biped_parts,
    .head_index = 5,
    .texture_width = 64,
    .texture_height = 32,
};

pub const BipedPose = struct {
    limb_swing: f32,
    limb_swing_amount: f32,
    head_yaw: f32,
    head_pitch: f32,
    swing_progress: f32 = 0,
    holding_item: bool = false,
    sneaking: bool = false,
};

const body_index: usize = 0;
const right_leg_index: usize = 1;
const left_leg_index: usize = 2;
const right_arm_index: usize = 3;
const left_arm_index: usize = 4;

pub fn bipedPosed(model: Model, pose: BipedPose) [biped_parts.len]Part {
    const degrees = std.math.pi / 180.0;
    const pi = std.math.pi;

    var parts: [biped_parts.len]Part = model.parts[0..biped_parts.len].*;
    const body = &parts[body_index];
    const right_leg = &parts[right_leg_index];
    const left_leg = &parts[left_leg_index];
    const right_arm = &parts[right_arm_index];
    const left_arm = &parts[left_arm_index];
    const head = &parts[model.head_index];

    head.rotate_y = pose.head_yaw * degrees;
    head.rotate_x = pose.head_pitch * degrees;
    right_arm.rotate_x = math.util.cos(pose.limb_swing * 0.6662 + pi) * 2.0 * pose.limb_swing_amount * 0.5;
    left_arm.rotate_x = math.util.cos(pose.limb_swing * 0.6662) * 2.0 * pose.limb_swing_amount * 0.5;
    right_arm.rotate_z = 0;
    left_arm.rotate_z = 0;
    right_leg.rotate_x = math.util.cos(pose.limb_swing * 0.6662) * 1.4 * pose.limb_swing_amount;
    left_leg.rotate_x = math.util.cos(pose.limb_swing * 0.6662 + pi) * 1.4 * pose.limb_swing_amount;
    right_leg.rotate_y = 0;
    left_leg.rotate_y = 0;

    if (pose.holding_item) right_arm.rotate_x = right_arm.rotate_x * 0.5 - pi * 0.1;

    right_arm.rotate_y = 0;
    left_arm.rotate_y = 0;

    const swing = pose.swing_progress;
    body.rotate_y = math.util.sin(@sqrt(swing) * pi * 2.0) * 0.2;
    right_arm.pivot[2] = math.util.sin(body.rotate_y) * 5.0;
    right_arm.pivot[0] = -math.util.cos(body.rotate_y) * 5.0;
    left_arm.pivot[2] = -math.util.sin(body.rotate_y) * 5.0;
    left_arm.pivot[0] = math.util.cos(body.rotate_y) * 5.0;
    right_arm.rotate_y += body.rotate_y;
    left_arm.rotate_y += body.rotate_y;
    left_arm.rotate_x += body.rotate_y;

    var eased = 1.0 - swing;
    eased *= eased;
    eased *= eased;
    eased = 1.0 - eased;
    const raise = math.util.sin(eased * pi);
    const reach = math.util.sin(swing * pi) * -(head.rotate_x - 0.7) * (12.0 / 16.0);
    right_arm.rotate_x -= raise * 1.2 + reach;
    right_arm.rotate_y += body.rotate_y * 2.0;
    right_arm.rotate_z = math.util.sin(swing * pi) * -0.4;

    if (pose.sneaking) {
        body.rotate_x = 0.5;
        right_arm.rotate_x += 0.4;
        left_arm.rotate_x += 0.4;
        right_leg.pivot[2] = 4.0;
        left_leg.pivot[2] = 4.0;
        right_leg.pivot[1] = 9.0 - 24.0;
        left_leg.pivot[1] = 9.0 - 24.0;
        head.pivot[1] = 1.0 - 24.0;
    } else {
        body.rotate_x = 0;
        right_leg.pivot[2] = 0;
        left_leg.pivot[2] = 0;
        right_leg.pivot[1] = -12.0;
        left_leg.pivot[1] = -12.0;
        head.pivot[1] = -24.0;
    }

    return parts;
}

const skeleton_parts = [6]Part{
    biped_parts[body_index],
    .{ .box = .{ .origin = .{ -1, 0, -1 }, .size = .{ 2, 12, 2 }, .tex_u = 0, .tex_v = 16 }, .pivot = .{ -2, -12, 0 } },
    .{ .box = .{ .origin = .{ -1, 0, -1 }, .size = .{ 2, 12, 2 }, .tex_u = 0, .tex_v = 16, .mirror = true }, .pivot = .{ 2, -12, 0 } },
    .{ .box = .{ .origin = .{ -1, -2, -1 }, .size = .{ 2, 12, 2 }, .tex_u = 40, .tex_v = 16 }, .pivot = .{ -5, -22, 0 } },
    .{ .box = .{ .origin = .{ -1, -2, -1 }, .size = .{ 2, 12, 2 }, .tex_u = 40, .tex_v = 16, .mirror = true }, .pivot = .{ 5, -22, 0 } },
    biped_parts[5],
};

pub const skeleton: Model = .{
    .parts = &skeleton_parts,
    .head_index = 5,
    .texture_width = 64,
    .texture_height = 32,
};

pub fn zombiePosed(model: Model, pose: BipedPose, age: f32) [biped_parts.len]Part {
    const pi = std.math.pi;

    var parts = bipedPosed(model, pose);
    const right_arm = &parts[right_arm_index];
    const left_arm = &parts[left_arm_index];

    const raise = math.util.sin(pose.swing_progress * pi);
    const eased = math.util.sin((1.0 - (1.0 - pose.swing_progress) * (1.0 - pose.swing_progress)) * pi);

    right_arm.rotate_z = 0;
    left_arm.rotate_z = 0;
    right_arm.rotate_y = -(0.1 - raise * 0.6);
    left_arm.rotate_y = 0.1 - raise * 0.6;
    right_arm.rotate_x = pi * -0.5;
    left_arm.rotate_x = pi * -0.5;
    right_arm.rotate_x -= raise * 1.2 - eased * 0.4;
    left_arm.rotate_x -= raise * 1.2 - eased * 0.4;
    right_arm.rotate_z += math.util.cos(age * 0.09) * 0.05 + 0.05;
    left_arm.rotate_z -= math.util.cos(age * 0.09) * 0.05 + 0.05;
    right_arm.rotate_x += math.util.sin(age * 0.067) * 0.05;
    left_arm.rotate_x -= math.util.sin(age * 0.067) * 0.05;

    return parts;
}

const armor_outer_inflate: f32 = 1.0;
const armor_inner_inflate: f32 = 0.5;

fn bipedInflated(comptime inflate: f32) [biped_parts.len]Part {
    var parts = biped_parts;
    for (&parts) |*part| part.box.inflate = inflate;
    return parts;
}

const biped_armor_outer_parts = bipedInflated(armor_outer_inflate);
const biped_armor_inner_parts = bipedInflated(armor_inner_inflate);

const biped_armor_outer: Model = .{
    .parts = &biped_armor_outer_parts,
    .head_index = biped.head_index,
    .texture_width = 64,
    .texture_height = 32,
};

const biped_armor_inner: Model = .{
    .parts = &biped_armor_inner_parts,
    .head_index = biped.head_index,
    .texture_width = 64,
    .texture_height = 32,
};

pub const ArmorLayer = struct {
    model: Model,
    visible: [biped_parts.len]bool,
    second_texture: bool,
};

pub fn bipedArmor(slot: world.item.ArmorSlot) ArmorLayer {
    return switch (slot) {
        .helmet => .{
            .model = biped_armor_outer,
            .visible = .{ false, false, false, false, false, true },
            .second_texture = false,
        },
        .chestplate => .{
            .model = biped_armor_outer,
            .visible = .{ true, false, false, true, true, false },
            .second_texture = false,
        },
        .leggings => .{
            .model = biped_armor_inner,
            .visible = .{ true, true, true, false, false, false },
            .second_texture = true,
        },
        .boots => .{
            .model = biped_armor_outer,
            .visible = .{ false, true, true, false, false, false },
            .second_texture = false,
        },
    };
}

const pixel_scale: f32 = 1.0 / 16.0;

fn rotateX(p: [3]f32, angle: f32) [3]f32 {
    if (angle == 0) return p;
    const c = @cos(angle);
    const s = @sin(angle);
    return .{ p[0], p[1] * c - p[2] * s, p[1] * s + p[2] * c };
}

fn rotateY(p: [3]f32, angle: f32) [3]f32 {
    if (angle == 0) return p;
    const c = @cos(angle);
    const s = @sin(angle);
    return .{ p[0] * c + p[2] * s, p[1], p[2] * c - p[0] * s };
}

fn rotateZAxis(p: [3]f32, angle: f32) [3]f32 {
    if (angle == 0) return p;
    const c = @cos(angle);
    const s = @sin(angle);
    return .{ p[0] * c - p[1] * s, p[0] * s + p[1] * c, p[2] };
}

fn rotateZ(x: f32, y: f32, angle: f32) [2]f32 {
    if (angle == 0) return .{ x, y };
    const c = @cos(angle);
    const s = @sin(angle);
    return .{ x * c - y * s, x * s + y * c };
}

fn rotateYaw(x: f32, z: f32, yaw: f32) [2]f32 {
    const c = @cos(yaw);
    const s = @sin(yaw);
    return .{ x * c + z * s, x * s - z * c };
}

const FaceSpec = struct {
    corners: [4][3]f32,
    rect: [4]f32,
};

fn faceSpecs(box: Box) [6]FaceSpec {
    const w = box.size[0];
    const h = box.size[1];
    const d = box.size[2];
    var x1 = box.origin[0] - box.inflate;
    const y1 = box.origin[1] - box.inflate;
    const z1 = box.origin[2] - box.inflate;
    var x2 = box.origin[0] + w + box.inflate;
    if (box.mirror) std.mem.swap(f32, &x1, &x2);
    const y2 = box.origin[1] + h + box.inflate;
    const z2 = box.origin[2] + d + box.inflate;
    const tu = box.tex_u;
    const tv = box.tex_v;

    return .{
        .{ .corners = .{ .{ x2, y1, z2 }, .{ x2, y1, z1 }, .{ x2, y2, z1 }, .{ x2, y2, z2 } }, .rect = .{ tu + d + w, tv + d, tu + 2 * d + w, tv + d + h } },
        .{ .corners = .{ .{ x1, y1, z1 }, .{ x1, y1, z2 }, .{ x1, y2, z2 }, .{ x1, y2, z1 } }, .rect = .{ tu, tv + d, tu + d, tv + d + h } },
        .{ .corners = .{ .{ x2, y1, z2 }, .{ x1, y1, z2 }, .{ x1, y1, z1 }, .{ x2, y1, z1 } }, .rect = .{ tu + d, tv, tu + d + w, tv + d } },
        .{ .corners = .{ .{ x2, y2, z1 }, .{ x1, y2, z1 }, .{ x1, y2, z2 }, .{ x2, y2, z2 } }, .rect = .{ tu + d + w, tv, tu + 2 * w + d, tv + d } },
        .{ .corners = .{ .{ x2, y1, z1 }, .{ x1, y1, z1 }, .{ x1, y2, z1 }, .{ x2, y2, z1 } }, .rect = .{ tu + d, tv + d, tu + d + w, tv + d + h } },
        .{ .corners = .{ .{ x1, y1, z2 }, .{ x2, y1, z2 }, .{ x2, y2, z2 }, .{ x1, y2, z2 } }, .rect = .{ tu + 2 * d + w, tv + d, tu + 2 * d + 2 * w, tv + d + h } },
    };
}

pub fn appendBox(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    box: Box,
    pivot: [3]f32,
    scale: f32,
    tex_width: f32,
    tex_height: f32,
) !void {
    for (faceSpecs(box)) |face| {
        var positions: [4][3]f32 = undefined;
        for (face.corners, 0..) |c, i| {
            positions[i] = .{
                (c[0] + pivot[0]) * scale,
                (c[1] + pivot[1]) * scale,
                (c[2] + pivot[2]) * scale,
            };
        }
        var uvs = [4][2]f32{
            .{ face.rect[2] / tex_width, face.rect[1] / tex_height },
            .{ face.rect[0] / tex_width, face.rect[1] / tex_height },
            .{ face.rect[0] / tex_width, face.rect[3] / tex_height },
            .{ face.rect[2] / tex_width, face.rect[3] / tex_height },
        };
        if (box.mirror) {
            std.mem.reverse([3]f32, &positions);
            std.mem.reverse([2]f32, &uvs);
        }
        try mesh.quad(gpa, positions, uvs, .{ 255, 255, 255, 255 });
    }
}

pub fn appendPart(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    part: Part,
    tex_width: f32,
    tex_height: f32,
    pose: Pose,
) !void {
    for (faceSpecs(part.box)) |face| {
        var positions: [4][3]f32 = undefined;
        for (face.corners, 0..) |c, i| {
            var p = rotateZAxis(rotateY(rotateX(c, part.rotate_x), part.rotate_y), part.rotate_z);
            p = .{ p[0] + part.pivot[0], p[1] + part.pivot[1], p[2] + part.pivot[2] };
            const world_scale = .{
                p[0] * pixel_scale * pose.scale[0],
                -p[1] * pixel_scale * pose.scale[1],
                p[2] * pixel_scale * pose.scale[2],
            };
            const rolled = rotateZ(world_scale[0], world_scale[1], pose.roll);
            const xz = rotateYaw(rolled[0], world_scale[2], pose.yaw);
            positions[i] = .{ xz[0] + pose.position[0], rolled[1] + pose.position[1], xz[1] + pose.position[2] };
        }
        var uvs = [4][2]f32{
            .{ face.rect[2] / tex_width, face.rect[1] / tex_height },
            .{ face.rect[0] / tex_width, face.rect[1] / tex_height },
            .{ face.rect[0] / tex_width, face.rect[3] / tex_height },
            .{ face.rect[2] / tex_width, face.rect[3] / tex_height },
        };
        if (part.box.mirror) {
            std.mem.reverse([3]f32, &positions);
            std.mem.reverse([2]f32, &uvs);
        }
        try mesh.quad(gpa, positions, uvs, .{ 255, 255, 255, 255 });
    }
}

test "appendPart emits 6 quads and flips the box into world space at yaw 0" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);

    const part = Part{
        .box = .{ .origin = .{ 0, 0, 0 }, .size = .{ 16, 16, 16 }, .tex_u = 0, .tex_v = 0 },
        .pivot = .{ 0, 0, 0 },
    };
    try appendPart(&mesh, gpa, part, 64, 32, .{ .position = .{ 0, 0, 0 }, .yaw = 0 });

    try std.testing.expectEqual(@as(usize, 24), mesh.vertices.items.len);

    var min: [3]f32 = .{ 1000, 1000, 1000 };
    var max: [3]f32 = .{ -1000, -1000, -1000 };
    for (mesh.vertices.items) |v| {
        min = .{ @min(min[0], v.x), @min(min[1], v.y), @min(min[2], v.z) };
        max = .{ @max(max[0], v.x), @max(max[1], v.y), @max(max[2], v.z) };
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), min[0], 1.0e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), max[0], 1.0e-5);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), min[1], 1.0e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), max[1], 1.0e-5);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), min[2], 1.0e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), max[2], 1.0e-5);
}

test "each armour piece shows the parts setArmorModel shows for its slot" {
    const body = 0;
    const right_leg = 1;
    const left_leg = 2;
    const right_arm = 3;
    const left_arm = 4;
    const head = biped.head_index;

    const helmet = bipedArmor(.helmet).visible;
    try std.testing.expect(helmet[head]);
    try std.testing.expect(!helmet[body]);

    const chestplate = bipedArmor(.chestplate).visible;
    try std.testing.expect(chestplate[body] and chestplate[right_arm] and chestplate[left_arm]);
    try std.testing.expect(!chestplate[head] and !chestplate[right_leg] and !chestplate[left_leg]);

    const leggings = bipedArmor(.leggings).visible;
    try std.testing.expect(leggings[body] and leggings[right_leg] and leggings[left_leg]);
    try std.testing.expect(!leggings[right_arm] and !leggings[left_arm]);

    const boots = bipedArmor(.boots).visible;
    try std.testing.expect(boots[right_leg] and boots[left_leg]);
    try std.testing.expect(!boots[body]);
}

test "only the leggings wear the thin layer, and only they read the second texture" {
    for ([_]world.item.ArmorSlot{ .helmet, .chestplate, .boots }) |slot| {
        const layer = bipedArmor(slot);
        try std.testing.expectEqual(armor_outer_inflate, layer.model.parts[0].box.inflate);
        try std.testing.expect(!layer.second_texture);
    }

    const leggings = bipedArmor(.leggings);
    try std.testing.expectEqual(armor_inner_inflate, leggings.model.parts[0].box.inflate);
    try std.testing.expect(leggings.second_texture);
}

test "an armour layer keeps the base biped's boxes, only grown" {
    const layer = bipedArmor(.chestplate);
    try std.testing.expectEqual(biped.parts.len, layer.model.parts.len);
    for (biped.parts, layer.model.parts) |base, worn| {
        try std.testing.expectEqual(base.box.origin, worn.box.origin);
        try std.testing.expectEqual(base.box.size, worn.box.size);
        try std.testing.expectEqual(base.box.tex_u, worn.box.tex_u);
        try std.testing.expectEqual(base.box.tex_v, worn.box.tex_v);
        try std.testing.expectEqual(base.pivot, worn.pivot);
        try std.testing.expect(worn.box.inflate > base.box.inflate);
    }
}

test "walking swings each arm against the leg on the same side" {
    const parts = bipedPosed(biped, .{
        .limb_swing = 3.0,
        .limb_swing_amount = 1.0,
        .head_yaw = 0,
        .head_pitch = 0,
    });

    try std.testing.expect(parts[right_arm_index].rotate_x * parts[right_leg_index].rotate_x < 0);
    try std.testing.expect(parts[left_arm_index].rotate_x * parts[left_leg_index].rotate_x < 0);
    try std.testing.expect(parts[right_leg_index].rotate_x * parts[left_leg_index].rotate_x < 0);
}

test "standing still leaves the limbs hanging straight" {
    const parts = bipedPosed(biped, .{
        .limb_swing = 3.0,
        .limb_swing_amount = 0,
        .head_yaw = 0,
        .head_pitch = 0,
    });

    for (parts) |part| {
        try std.testing.expectApproxEqAbs(@as(f32, 0), part.rotate_x, 1.0e-6);
        try std.testing.expectApproxEqAbs(@as(f32, 0), part.rotate_y, 1.0e-6);
        try std.testing.expectApproxEqAbs(@as(f32, 0), part.rotate_z, 1.0e-6);
    }
}

test "the head carries the look angles, the body does not" {
    const parts = bipedPosed(biped, .{
        .limb_swing = 0,
        .limb_swing_amount = 0,
        .head_yaw = 30,
        .head_pitch = -20,
    });

    const degrees = std.math.pi / 180.0;
    try std.testing.expectApproxEqAbs(@as(f32, 30 * degrees), parts[biped.head_index].rotate_y, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -20 * degrees), parts[biped.head_index].rotate_x, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), parts[body_index].rotate_y, 1.0e-6);
}

test "sneaking tips the body forward, drops the head and lifts the leg joints" {
    const upright = bipedPosed(biped, .{ .limb_swing = 0, .limb_swing_amount = 0, .head_yaw = 0, .head_pitch = 0 });
    const crouched = bipedPosed(biped, .{ .limb_swing = 0, .limb_swing_amount = 0, .head_yaw = 0, .head_pitch = 0, .sneaking = true });

    try std.testing.expectApproxEqAbs(@as(f32, 0.5), crouched[body_index].rotate_x, 1.0e-6);
    try std.testing.expect(crouched[biped.head_index].pivot[1] > upright[biped.head_index].pivot[1]);
    try std.testing.expect(crouched[right_leg_index].pivot[1] < upright[right_leg_index].pivot[1]);
    try std.testing.expectApproxEqAbs(@as(f32, 4), crouched[right_leg_index].pivot[2], 1.0e-6);
}

test "swinging lifts the right arm and leaves the left one alone" {
    const resting = bipedPosed(biped, .{ .limb_swing = 0, .limb_swing_amount = 0, .head_yaw = 0, .head_pitch = 0 });
    const swung = bipedPosed(biped, .{ .limb_swing = 0, .limb_swing_amount = 0, .head_yaw = 0, .head_pitch = 0, .swing_progress = 0.5 });

    try std.testing.expect(swung[right_arm_index].rotate_x < resting[right_arm_index].rotate_x);
    try std.testing.expect(swung[right_arm_index].rotate_z != 0);
    try std.testing.expectApproxEqAbs(resting[left_arm_index].rotate_x, swung[left_arm_index].rotate_x, 0.2);
}

test "holding an item lowers the right arm" {
    const empty = bipedPosed(biped, .{ .limb_swing = 0, .limb_swing_amount = 0, .head_yaw = 0, .head_pitch = 0 });
    const holding = bipedPosed(biped, .{ .limb_swing = 0, .limb_swing_amount = 0, .head_yaw = 0, .head_pitch = 0, .holding_item = true });

    try std.testing.expect(holding[right_arm_index].rotate_x < empty[right_arm_index].rotate_x);
    try std.testing.expectApproxEqAbs(empty[left_arm_index].rotate_x, holding[left_arm_index].rotate_x, 1.0e-6);
}

test "an armour layer poses exactly like the skin under it" {
    const pose: BipedPose = .{ .limb_swing = 2.0, .limb_swing_amount = 0.8, .head_yaw = 15, .head_pitch = 5 };
    const skin = bipedPosed(biped, pose);
    const worn = bipedPosed(bipedArmor(.chestplate).model, pose);

    for (skin, worn) |base, layer| {
        try std.testing.expectEqual(base.rotate_x, layer.rotate_x);
        try std.testing.expectEqual(base.rotate_y, layer.rotate_y);
        try std.testing.expectEqual(base.rotate_z, layer.rotate_z);
        try std.testing.expectEqual(base.pivot, layer.pivot);
    }
}
