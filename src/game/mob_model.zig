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

pub const Model = struct {
    parts: []const Part,
    head_index: usize,
    texture_width: f32,
    texture_height: f32,
};

pub const Limb = enum { body, right_leg, left_leg, right_arm, left_arm, head };

pub const BipedOverride = struct {
    pitch: f32 = 0,
    roll: f32 = 0,
    spin: f32 = 0,
    lift: f32 = 0,
    limbs: [@typeInfo(Limb).@"enum".fields.len]?[3]f32 = @splat(null),
};
