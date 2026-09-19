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
