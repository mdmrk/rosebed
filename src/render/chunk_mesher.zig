const std = @import("std");

const math = @import("math");
const world = @import("world");
const BlockPos = world.BlockPos;

const anaglyph = @import("anaglyph.zig");
const Atlas = @import("Atlas.zig");
const Colorizer = @import("Colorizer.zig");
const item_lighting = @import("item_lighting.zig");
const MeshBuilder = @import("MeshBuilder.zig");

const FaceDir = struct {
    side: world.Side,
    shade: f32,
    normal: [3]i32,
    corners: [4][3]f32,
    axis_u: u2,
    axis_v: u2,
    flip_v: bool = false,
};

pub const faces = [6]FaceDir{
    .{ .side = .down, .shade = 0.5, .normal = .{ 0, -1, 0 }, .axis_u = 0, .axis_v = 2, .flip_v = true, .corners = .{
        .{ 1, 0, 0 }, .{ 1, 0, 1 }, .{ 0, 0, 1 }, .{ 0, 0, 0 },
    } },
    .{ .side = .up, .shade = 1.0, .normal = .{ 0, 1, 0 }, .axis_u = 0, .axis_v = 2, .corners = .{
        .{ 1, 1, 1 }, .{ 1, 1, 0 }, .{ 0, 1, 0 }, .{ 0, 1, 1 },
    } },
    .{ .side = .north, .shade = 0.8, .normal = .{ 0, 0, -1 }, .axis_u = 0, .axis_v = 1, .corners = .{
        .{ 0, 0, 0 }, .{ 0, 1, 0 }, .{ 1, 1, 0 }, .{ 1, 0, 0 },
    } },
    .{ .side = .south, .shade = 0.8, .normal = .{ 0, 0, 1 }, .axis_u = 0, .axis_v = 1, .corners = .{
        .{ 1, 0, 1 }, .{ 1, 1, 1 }, .{ 0, 1, 1 }, .{ 0, 0, 1 },
    } },
    .{ .side = .west, .shade = 0.6, .normal = .{ -1, 0, 0 }, .axis_u = 2, .axis_v = 1, .corners = .{
        .{ 0, 0, 1 }, .{ 0, 1, 1 }, .{ 0, 1, 0 }, .{ 0, 0, 0 },
    } },
    .{ .side = .east, .shade = 0.6, .normal = .{ 1, 0, 0 }, .axis_u = 2, .axis_v = 1, .corners = .{
        .{ 1, 0, 0 }, .{ 1, 1, 0 }, .{ 1, 1, 1 }, .{ 1, 0, 1 },
    } },
};

fn shadeColor(shade: f32, tint: [3]u8) [4]u8 {
    var color: [4]u8 = .{ 0, 0, 0, 255 };
    for (0..3) |i| {
        const multiplier = @as(f32, @floatFromInt(tint[i])) / 255.0;
        color[i] = @intFromFloat(shade * multiplier * 255.0);
    }
    return color;
}

pub fn renderColor(id: world.Block, metadata: u4) [3]u8 {
    return switch (id) {
        .leaves => if (metadata & 1 == 1)
            Colorizer.pine
        else if (metadata & 2 == 2)
            Colorizer.birch
        else
            Colorizer.foliage_default,
        else => Colorizer.white,
    };
}

pub fn blockTint(colorizer: Colorizer, id: world.Block, metadata: u4, side: world.Side, temperature: f64, humidity: f64) [3]u8 {
    return switch (id) {
        .grass => if (side == .up)
            colorizer.grassColor(temperature, humidity)
        else
            Colorizer.white,
        .leaves => if (metadata & 1 == 1)
            Colorizer.pine
        else if (metadata & 2 == 2)
            Colorizer.birch
        else
            colorizer.foliageColor(temperature, humidity),
        .tall_grass => if (metadata == 0)
            Colorizer.white
        else
            colorizer.grassColor(temperature, humidity),
        .redstone_wire => world.block.wire_particle_tint,
        else => Colorizer.white,
    };
}

fn faceUvs(tile: u8, side: world.Side, height_scale: f32) [4][2]f32 {
    const uv = Atlas.tileUv(tile);
    const top_v = if (side == .up or side == .down)
        uv.v0
    else
        uv.v1 - (uv.v1 - uv.v0) * height_scale;
    return .{
        .{ uv.u1, uv.v1 },
        .{ uv.u1, top_v },
        .{ uv.u0, top_v },
        .{ uv.u0, uv.v1 },
    };
}

fn stepAlong(axis: u2, corner: [3]f32) [3]i32 {
    var step: [3]i32 = .{ 0, 0, 0 };
    step[axis] = if (corner[axis] == 1) 1 else -1;
    return step;
}

fn offsetBy(cell: [3]i32, step: [3]i32) [3]i32 {
    return .{ cell[0] + step[0], cell[1] + step[1], cell[2] + step[2] };
}

fn brightnessOf(world_map: *const world.ChunkView, cell: [3]i32, minimum: u4) f32 {
    return world.light.brightnessAt(world_map, .init(cell[0], cell[1], cell[2]), minimum);
}

fn blocksGrass(world_map: *const world.ChunkView, cell: [3]i32) bool {
    return world_map.getBlock(.init(cell[0], cell[1], cell[2])).isOpaque();
}

fn smoothBrightness(
    world_map: *const world.ChunkView,
    face: FaceDir,
    pos: BlockPos,
    minimum: u4,
) [4]f32 {
    const cell = offsetBy(.{ pos.x, pos.y, pos.z }, face.normal);
    const center = brightnessOf(world_map, cell, minimum);

    var result: [4]f32 = undefined;
    for (face.corners, 0..) |corner, i| {
        const step_u = stepAlong(face.axis_u, corner);
        const step_v = stepAlong(face.axis_v, corner);
        const cell_u = offsetBy(cell, step_u);
        const cell_v = offsetBy(cell, step_v);
        const edge_u = brightnessOf(world_map, cell_u, minimum);
        const edge_v = brightnessOf(world_map, cell_v, minimum);
        const diagonal = if (blocksGrass(world_map, cell_u) and blocksGrass(world_map, cell_v))
            edge_u
        else
            brightnessOf(world_map, offsetBy(cell_u, step_v), minimum);
        result[i] = (center + edge_u + edge_v + diagonal) / 4.0;
    }
    return result;
}

pub const Options = struct {
    smooth: bool = false,
    fancy: bool = false,
    anaglyph: bool = false,
    override_tile: ?u8 = null,
    all_faces: bool = false,
};

fn tileFor(options: Options, tile: u8) u8 {
    return options.override_tile orelse tile;
}

fn texturesFor(options: Options, textures: world.block.FaceTextures) world.block.FaceTextures {
    const tile = options.override_tile orelse return textures;
    return world.block.FaceTextures.initFill(tile);
}

fn showsFace(options: Options, world_map: *const world.ChunkView, id: world.Block, pos: BlockPos, side: world.Side) bool {
    if (options.all_faces) return true;
    if (id == .portal) return world.portal.facesNeighbour(world_map, .{ .x = pos.x, .y = pos.y, .z = pos.z }, side);
    return id.shouldRenderFace(world_map.getBlock(pos), side, options.fancy);
}

fn chestRing(world_map: *const world.ChunkView, pos: BlockPos) world.block.ChestRing {
    return .{
        .north = world_map.getBlock(pos.offset(0, 0, -1)),
        .south = world_map.getBlock(pos.offset(0, 0, 1)),
        .west = world_map.getBlock(pos.offset(-1, 0, 0)),
        .east = world_map.getBlock(pos.offset(1, 0, 0)),
        .north_west = world_map.getBlock(pos.offset(-1, 0, -1)),
        .north_east = world_map.getBlock(pos.offset(1, 0, -1)),
        .south_west = world_map.getBlock(pos.offset(-1, 0, 1)),
        .south_east = world_map.getBlock(pos.offset(1, 0, 1)),
    };
}

pub const Climate = struct {
    temperature: f64 = 0.5,
    humidity: f64 = 0.5,
};

pub fn climateAt(world_map: *const world.ChunkView, x: i32, z: i32) Climate {
    const width = world.Chunk.width;
    const chunk = world_map.getChunk(@divFloor(x, width), @divFloor(z, width)) orelse return .{};
    const lx: u32 = @intCast(@mod(x, width));
    const lz: u32 = @intCast(@mod(z, width));
    return .{
        .temperature = chunk.getTemperature(lx, lz),
        .humidity = chunk.getHumidity(lx, lz),
    };
}

pub const Mesh = struct {
    solid: MeshBuilder = .{},
    translucent: MeshBuilder = .{},

    pub fn deinit(self: *Mesh, gpa: std.mem.Allocator) void {
        self.solid.deinit(gpa);
        self.translucent.deinit(gpa);
    }
};

fn pulledInward(coordinate: f32, normal: i32, inset: f32) f32 {
    return coordinate - @as(f32, @floatFromInt(normal)) * inset;
}

pub fn buildCube(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    min: [3]f32,
    max: [3]f32,
    face_textures: world.block.FaceTextures,
    inset: f32,
) !void {
    for (faces) |face| {
        const uv = Atlas.tileUv(face_textures.get(face.side));
        var positions: [4][3]f32 = undefined;
        for (face.corners, 0..) |corner, i| {
            positions[i] = .{
                pulledInward(if (corner[0] == 0) min[0] else max[0], face.normal[0], inset),
                if (corner[1] == 0) min[1] else max[1],
                pulledInward(if (corner[2] == 0) min[2] else max[2], face.normal[2], inset),
            };
        }
        const v_far = if (face.flip_v) uv.v0 else uv.v1;
        const v_near = if (face.flip_v) uv.v1 else uv.v0;
        const uvs = [4][2]f32{
            .{ uv.u1, v_far },
            .{ uv.u1, v_near },
            .{ uv.u0, v_near },
            .{ uv.u0, v_far },
        };
        try mesh.quad(gpa, positions, uvs, shadeColor(face.shade, Colorizer.white));
    }
}

const cross_inset: f32 = 0.45;

fn buildCross(mesh: *MeshBuilder, gpa: std.mem.Allocator, tile: u8, tint: [3]u8, brightness: f32, bx: f32, by: f32, bz: f32) !void {
    const uv = Atlas.tileUv(tile);
    const color = shadeColor(brightness, tint);

    const x0 = bx + 0.5 - cross_inset;
    const x1 = bx + 0.5 + cross_inset;
    const z0 = bz + 0.5 - cross_inset;
    const z1 = bz + 0.5 + cross_inset;
    const y0 = by;
    const y1 = by + 1;

    const uvs = [4][2]f32{
        .{ uv.u0, uv.v0 },
        .{ uv.u0, uv.v1 },
        .{ uv.u1, uv.v1 },
        .{ uv.u1, uv.v0 },
    };

    try mesh.quad(gpa, .{
        .{ x0, y1, z0 }, .{ x0, y0, z0 }, .{ x1, y0, z1 }, .{ x1, y1, z1 },
    }, uvs, color);
    try mesh.quad(gpa, .{
        .{ x1, y1, z1 }, .{ x1, y0, z1 }, .{ x0, y0, z0 }, .{ x0, y1, z0 },
    }, uvs, color);
    try mesh.quad(gpa, .{
        .{ x0, y1, z1 }, .{ x0, y0, z1 }, .{ x1, y0, z0 }, .{ x1, y1, z0 },
    }, uvs, color);
    try mesh.quad(gpa, .{
        .{ x1, y1, z0 }, .{ x1, y0, z0 }, .{ x0, y0, z1 }, .{ x0, y1, z1 },
    }, uvs, color);
}

test "each cross plane repeats its texture on the reversed back face" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);

    try buildCross(&mesh, gpa, 12, Colorizer.white, 1.0, 0, 0, 0);
    try std.testing.expectEqual(@as(usize, 16), mesh.vertices.items.len);

    for ([_]usize{ 0, 8 }) |plane| {
        const front = mesh.vertices.items[plane..][0..4];
        const back = mesh.vertices.items[plane + 4 ..][0..4];
        for (0..4) |i| {
            const opposite = front[3 - i];
            try std.testing.expectApproxEqAbs(opposite.x, back[i].x, 1.0e-6);
            try std.testing.expectApproxEqAbs(opposite.y, back[i].y, 1.0e-6);
            try std.testing.expectApproxEqAbs(opposite.z, back[i].z, 1.0e-6);

            try std.testing.expectApproxEqAbs(front[i].u, back[i].u, 1.0e-6);
            try std.testing.expectApproxEqAbs(front[i].v, back[i].v, 1.0e-6);
        }
    }
}

const fire_height: f32 = 1.4;
const fire_lean: f32 = 0.2;
const fire_wall_inset: f32 = 0.2;
const fire_wall_lift: f32 = 1.0 / 16.0;
const fire_ceiling_drop: f32 = 0.2;

fn fireUvs(uv: Atlas.Uv) [4][2]f32 {
    return .{ .{ uv.u1, uv.v0 }, .{ uv.u1, uv.v1 }, .{ uv.u0, uv.v1 }, .{ uv.u0, uv.v0 } };
}

fn fireUvsFlipped(uv: Atlas.Uv) [4][2]f32 {
    return .{ .{ uv.u0, uv.v0 }, .{ uv.u0, uv.v1 }, .{ uv.u1, uv.v1 }, .{ uv.u1, uv.v0 } };
}

fn swappedU(uv: Atlas.Uv) Atlas.Uv {
    return .{ .u0 = uv.u1, .v0 = uv.v0, .u1 = uv.u0, .v1 = uv.v1 };
}

fn fireQuadBothSides(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    positions: [4][3]f32,
    uvs: [4][2]f32,
    color: [4]u8,
) !void {
    try mesh.quad(gpa, positions, uvs, color);
    try mesh.quad(
        gpa,
        .{ positions[3], positions[2], positions[1], positions[0] },
        .{ uvs[3], uvs[2], uvs[1], uvs[0] },
        color,
    );
}

fn buildFireStanding(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    near: Atlas.Uv,
    far: Atlas.Uv,
    color: [4]u8,
    bx: f32,
    by: f32,
    bz: f32,
) !void {
    const top = by + fire_height;

    var foot_high = bx + 0.5 + fire_lean;
    var foot_low = bx + 0.5 - fire_lean;
    var tip_low = bx + 0.5 - 0.3;
    var tip_high = bx + 0.5 + 0.3;
    var foot_far = bz + 0.5 + fire_lean;
    var foot_near = bz + 0.5 - fire_lean;
    var tip_near = bz + 0.5 - 0.3;
    var tip_far = bz + 0.5 + 0.3;

    try mesh.quad(gpa, .{
        .{ tip_low, top, bz + 1 }, .{ foot_high, by, bz + 1 },
        .{ foot_high, by, bz },    .{ tip_low, top, bz },
    }, fireUvs(near), color);
    try mesh.quad(gpa, .{
        .{ tip_high, top, bz },    .{ foot_low, by, bz },
        .{ foot_low, by, bz + 1 }, .{ tip_high, top, bz + 1 },
    }, fireUvs(near), color);
    try mesh.quad(gpa, .{
        .{ bx + 1, top, tip_far }, .{ bx + 1, by, foot_near },
        .{ bx, by, foot_near },    .{ bx, top, tip_far },
    }, fireUvs(far), color);
    try mesh.quad(gpa, .{
        .{ bx, top, tip_near },    .{ bx, by, foot_far },
        .{ bx + 1, by, foot_far }, .{ bx + 1, top, tip_near },
    }, fireUvs(far), color);

    foot_high = bx;
    foot_low = bx + 1;
    tip_low = bx + 0.1;
    tip_high = bx + 0.9;
    foot_far = bz;
    foot_near = bz + 1;
    tip_near = bz + 0.1;
    tip_far = bz + 0.9;

    try mesh.quad(gpa, .{
        .{ tip_low, top, bz },      .{ foot_high, by, bz },
        .{ foot_high, by, bz + 1 }, .{ tip_low, top, bz + 1 },
    }, fireUvsFlipped(far), color);
    try mesh.quad(gpa, .{
        .{ tip_high, top, bz + 1 }, .{ foot_low, by, bz + 1 },
        .{ foot_low, by, bz },      .{ tip_high, top, bz },
    }, fireUvsFlipped(far), color);
    try mesh.quad(gpa, .{
        .{ bx, top, tip_far },      .{ bx, by, foot_near },
        .{ bx + 1, by, foot_near }, .{ bx + 1, top, tip_far },
    }, fireUvsFlipped(near), color);
    try mesh.quad(gpa, .{
        .{ bx + 1, top, tip_near }, .{ bx + 1, by, foot_far },
        .{ bx, by, foot_far },      .{ bx, top, tip_near },
    }, fireUvsFlipped(near), color);
}

fn buildFireOnNeighbours(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    world_map: *const world.ChunkView,
    near: Atlas.Uv,
    far: Atlas.Uv,
    color: [4]u8,
    pos: BlockPos,
    bx: f32,
    by: f32,
    bz: f32,
) !void {
    const row = if ((pos.x +% pos.y +% pos.z) & 1 == 1) far else near;
    const uv = if ((@divTrunc(pos.x, 2) +% @divTrunc(pos.y, 2) +% @divTrunc(pos.z, 2)) & 1 == 1) swappedU(row) else row;

    const foot = by + fire_wall_lift;
    const top = by + fire_height + fire_wall_lift;

    if (world_map.getBlock(pos.offset(-1, 0, 0)).isFlammable()) {
        try fireQuadBothSides(mesh, gpa, .{
            .{ bx + fire_wall_inset, top, bz + 1 }, .{ bx, foot, bz + 1 },
            .{ bx, foot, bz },                      .{ bx + fire_wall_inset, top, bz },
        }, fireUvs(uv), color);
    }
    if (world_map.getBlock(pos.offset(1, 0, 0)).isFlammable()) {
        try fireQuadBothSides(mesh, gpa, .{
            .{ bx + 1 - fire_wall_inset, top, bz }, .{ bx + 1, foot, bz },
            .{ bx + 1, foot, bz + 1 },              .{ bx + 1 - fire_wall_inset, top, bz + 1 },
        }, fireUvsFlipped(uv), color);
    }
    if (world_map.getBlock(pos.offset(0, 0, -1)).isFlammable()) {
        try fireQuadBothSides(mesh, gpa, .{
            .{ bx, top, bz + fire_wall_inset }, .{ bx, foot, bz },
            .{ bx + 1, foot, bz },              .{ bx + 1, top, bz + fire_wall_inset },
        }, fireUvs(uv), color);
    }
    if (world_map.getBlock(pos.offset(0, 0, 1)).isFlammable()) {
        try fireQuadBothSides(mesh, gpa, .{
            .{ bx + 1, top, bz + 1 - fire_wall_inset }, .{ bx + 1, foot, bz + 1 },
            .{ bx, foot, bz + 1 },                      .{ bx, top, bz + 1 - fire_wall_inset },
        }, fireUvsFlipped(uv), color);
    }
    if (!world_map.getBlock(pos.offset(0, 1, 0)).isFlammable()) return;

    const ceiling = by + 1;
    const tip = ceiling - fire_ceiling_drop;
    if ((pos.x +% (pos.y + 1) +% pos.z) & 1 == 0) {
        try mesh.quad(gpa, .{
            .{ bx, tip, bz },             .{ bx + 1, ceiling, bz },
            .{ bx + 1, ceiling, bz + 1 }, .{ bx, tip, bz + 1 },
        }, fireUvs(near), color);
        try mesh.quad(gpa, .{
            .{ bx + 1, tip, bz + 1 }, .{ bx, ceiling, bz + 1 },
            .{ bx, ceiling, bz },     .{ bx + 1, tip, bz },
        }, fireUvs(far), color);
    } else {
        try mesh.quad(gpa, .{
            .{ bx, tip, bz + 1 },     .{ bx, ceiling, bz },
            .{ bx + 1, ceiling, bz }, .{ bx + 1, tip, bz + 1 },
        }, fireUvs(near), color);
        try mesh.quad(gpa, .{
            .{ bx + 1, tip, bz },     .{ bx + 1, ceiling, bz + 1 },
            .{ bx, ceiling, bz + 1 }, .{ bx, tip, bz },
        }, fireUvs(far), color);
    }
}

fn buildFire(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    world_map: *const world.ChunkView,
    tile: u8,
    brightness: f32,
    pos: BlockPos,
    origin: [3]f32,
) !void {
    const color = shadeColor(brightness, Colorizer.white);
    const near = Atlas.tileUv(tile);
    const far = Atlas.tileUv(tile +% Atlas.tiles_per_row);

    const below = world_map.getBlock(pos.offset(0, -1, 0));
    if (!below.isNormalCube() and !below.isFlammable()) {
        try buildFireOnNeighbours(mesh, gpa, world_map, near, far, color, pos, origin[0], origin[1], origin[2]);
        return;
    }
    try buildFireStanding(mesh, gpa, near, far, color, origin[0], origin[1], origin[2]);
}

const torch_lean: f32 = 0.4;
const torch_half: f32 = 1.0 / 16.0;
const torch_tip: f32 = 0.625;

fn buildTorch(mesh: *MeshBuilder, gpa: std.mem.Allocator, tile: u8, metadata: u4, bx: f32, by: f32, bz: f32, color: [4]u8) !void {
    const shift: f32 = 0.5 - torch_lean;
    const lift: f32 = 0.2;

    var origin = [3]f32{ bx, by, bz };
    var lean = [2]f32{ 0, 0 };
    switch (metadata) {
        1 => {
            origin[0] -= shift;
            origin[1] += lift;
            lean[0] = -torch_lean;
        },
        2 => {
            origin[0] += shift;
            origin[1] += lift;
            lean[0] = torch_lean;
        },
        3 => {
            origin[2] -= shift;
            origin[1] += lift;
            lean[1] = -torch_lean;
        },
        4 => {
            origin[2] += shift;
            origin[1] += lift;
            lean[1] = torch_lean;
        },
        else => {},
    }

    const uv = Atlas.tileUv(tile);
    const texel: f32 = 1.0 / 256.0;

    const center_x = origin[0] + 0.5;
    const center_z = origin[2] + 0.5;
    const bottom = origin[1];
    const top = origin[1] + 1.0;

    const tip_x = center_x + lean[0] * (1.0 - torch_tip);
    const tip_y = origin[1] + torch_tip;
    const tip_z = center_z + lean[1] * (1.0 - torch_tip);
    const tip_u0 = uv.u0 + 7.0 * texel;
    const tip_u1 = uv.u0 + 9.0 * texel;
    const tip_v0 = uv.v0 + 6.0 * texel;
    const tip_v1 = uv.v0 + 8.0 * texel;

    try mesh.quad(gpa, .{
        .{ tip_x - torch_half, tip_y, tip_z - torch_half },
        .{ tip_x - torch_half, tip_y, tip_z + torch_half },
        .{ tip_x + torch_half, tip_y, tip_z + torch_half },
        .{ tip_x + torch_half, tip_y, tip_z - torch_half },
    }, .{
        .{ tip_u0, tip_v0 },
        .{ tip_u0, tip_v1 },
        .{ tip_u1, tip_v1 },
        .{ tip_u1, tip_v0 },
    }, color);

    const near_x = center_x - 0.5;
    const far_x = center_x + 0.5;
    const near_z = center_z - 0.5;
    const far_z = center_z + 0.5;
    const uvs = [4][2]f32{
        .{ uv.u0, uv.v0 },
        .{ uv.u0, uv.v1 },
        .{ uv.u1, uv.v1 },
        .{ uv.u1, uv.v0 },
    };

    try mesh.quad(gpa, .{
        .{ center_x - torch_half, top, near_z },
        .{ center_x - torch_half + lean[0], bottom, near_z + lean[1] },
        .{ center_x - torch_half + lean[0], bottom, far_z + lean[1] },
        .{ center_x - torch_half, top, far_z },
    }, uvs, color);

    try mesh.quad(gpa, .{
        .{ center_x + torch_half, top, far_z },
        .{ center_x + torch_half + lean[0], bottom, far_z + lean[1] },
        .{ center_x + torch_half + lean[0], bottom, near_z + lean[1] },
        .{ center_x + torch_half, top, near_z },
    }, uvs, color);

    try mesh.quad(gpa, .{
        .{ near_x, top, center_z + torch_half },
        .{ near_x + lean[0], bottom, center_z + torch_half + lean[1] },
        .{ far_x + lean[0], bottom, center_z + torch_half + lean[1] },
        .{ far_x, top, center_z + torch_half },
    }, uvs, color);

    try mesh.quad(gpa, .{
        .{ far_x, top, center_z - torch_half },
        .{ far_x + lean[0], bottom, center_z - torch_half + lean[1] },
        .{ near_x + lean[0], bottom, center_z - torch_half + lean[1] },
        .{ near_x, top, center_z - torch_half },
    }, uvs, color);
}

const wire_lift: f32 = 1.0 / 64.0;
const wire_climb_top: f32 = 7.0 / 320.0;
const rail_lift: f32 = 1.0 / 16.0;
const wire_gap: f32 = 5.0 / 16.0;
const wire_crop: f32 = 5.0 / 256.0;

fn wireColor(metadata: u4, brightness: f32) [4]u8 {
    const level = @as(f32, @floatFromInt(metadata)) / 15.0;
    const red = if (metadata == 0) 0.3 else level * 0.6 + 0.4;
    const green = @max(0.0, level * level * 0.7 - 0.5);
    const blue = @max(0.0, level * level * 0.6 - 0.7);
    return .{
        @intFromFloat(brightness * red * 255.0),
        @intFromFloat(brightness * green * 255.0),
        @intFromFloat(brightness * blue * 255.0),
        255,
    };
}

fn buildRail(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    world_map: *const world.ChunkView,
    id: world.Block,
    metadata: u4,
    pos: BlockPos,
    origin: [3]f32,
    options: Options,
) !void {
    const brightness = world.light.brightnessAt(world_map, pos, 0);
    const color = shadeColor(brightness, Colorizer.white);
    const uv = Atlas.tileUv(tileFor(options, world.block.railTile(id, metadata)));
    const shape = world.block.railShape(id, metadata);

    const west = origin[0];
    const east = origin[0] + 1.0;
    const north = origin[2];
    const south = origin[2] + 1.0;
    const flat = origin[1] + rail_lift;

    var px = [4]f32{ east, east, west, west };
    var pz = [4]f32{ north, south, south, north };
    var py = [4]f32{ flat, flat, flat, flat };

    switch (shape) {
        1, 2, 3, 7 => {
            px = .{ east, west, west, east };
            pz = .{ south, south, north, north };
        },
        8 => {
            px = .{ west, west, east, east };
            pz = .{ south, north, north, south };
        },
        9 => {
            px = .{ west, east, east, west };
            pz = .{ north, north, south, south };
        },
        else => {},
    }

    switch (shape) {
        2, 4 => {
            py[0] += 1.0;
            py[3] += 1.0;
        },
        3, 5 => {
            py[1] += 1.0;
            py[2] += 1.0;
        },
        else => {},
    }

    const positions = [4][3]f32{
        .{ px[0], py[0], pz[0] },
        .{ px[1], py[1], pz[1] },
        .{ px[2], py[2], pz[2] },
        .{ px[3], py[3], pz[3] },
    };
    const uvs = [4][2]f32{
        .{ uv.u1, uv.v0 },
        .{ uv.u1, uv.v1 },
        .{ uv.u0, uv.v1 },
        .{ uv.u0, uv.v0 },
    };

    try mesh.quad(gpa, positions, uvs, color);

    var back_positions = positions;
    var back_uvs = uvs;
    std.mem.reverse([3]f32, &back_positions);
    std.mem.reverse([2]f32, &back_uvs);
    try mesh.quad(gpa, back_positions, back_uvs, color);
}

fn buildWire(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    world_map: *const world.ChunkView,
    metadata: u4,
    pos: BlockPos,
    origin: [3]f32,
    options: Options,
) !void {
    const brightness = world.light.brightnessAt(world_map, pos, 0);
    const color = wireColor(metadata, brightness);
    const links = world.redstone.wireConnections(world_map, pos);

    const along_x = (links.west or links.east) and !links.north and !links.south;
    const along_z = (links.north or links.south) and !links.west and !links.east;
    const straight = along_x or along_z;

    const uv = Atlas.tileUv(tileFor(options, if (straight) world.block.wire_line_tile else world.block.wire_cross_tile));
    var x0 = origin[0];
    var x1 = origin[0] + 1.0;
    var z0 = origin[2];
    var z1 = origin[2] + 1.0;
    var tex_u0 = uv.u0;
    var tex_u1 = uv.u1;
    var tex_v0 = uv.v0;
    var tex_v1 = uv.v1;

    if (!straight and (links.west or links.east or links.north or links.south)) {
        if (!links.west) {
            x0 += wire_gap;
            tex_u0 += wire_crop;
        }
        if (!links.east) {
            x1 -= wire_gap;
            tex_u1 -= wire_crop;
        }
        if (!links.north) {
            z0 += wire_gap;
            tex_v0 += wire_crop;
        }
        if (!links.south) {
            z1 -= wire_gap;
            tex_v1 -= wire_crop;
        }
    }

    const flat = origin[1] + wire_lift;
    const positions = [4][3]f32{
        .{ x1, flat, z1 }, .{ x1, flat, z0 }, .{ x0, flat, z0 }, .{ x0, flat, z1 },
    };
    const uvs: [4][2]f32 = if (along_z)
        .{ .{ tex_u1, tex_v1 }, .{ tex_u0, tex_v1 }, .{ tex_u0, tex_v0 }, .{ tex_u1, tex_v0 } }
    else
        .{ .{ tex_u1, tex_v1 }, .{ tex_u1, tex_v0 }, .{ tex_u0, tex_v0 }, .{ tex_u0, tex_v1 } };
    try mesh.quad(gpa, positions, uvs, color);

    if (world_map.getBlock(pos.offset(0, 1, 0)).isNormalCube()) return;

    const line = Atlas.tileUv(tileFor(options, world.block.wire_line_tile));
    const top = origin[1] + 1.0 + wire_climb_top;
    const bottom = origin[1];
    const west = origin[0] + wire_lift;
    const east = origin[0] + 1.0 - wire_lift;
    const north = origin[2] + wire_lift;
    const south = origin[2] + 1.0 - wire_lift;
    const near_x = origin[0];
    const far_x = origin[0] + 1.0;
    const near_z = origin[2];
    const far_z = origin[2] + 1.0;

    if (world_map.getBlock(pos.offset(-1, 0, 0)).isNormalCube() and world_map.getBlock(pos.offset(-1, 1, 0)) == .redstone_wire) {
        try mesh.quad(gpa, .{
            .{ west, top, far_z }, .{ west, bottom, far_z }, .{ west, bottom, near_z }, .{ west, top, near_z },
        }, .{
            .{ line.u1, line.v0 }, .{ line.u0, line.v0 }, .{ line.u0, line.v1 }, .{ line.u1, line.v1 },
        }, color);
    }

    if (world_map.getBlock(pos.offset(1, 0, 0)).isNormalCube() and world_map.getBlock(pos.offset(1, 1, 0)) == .redstone_wire) {
        try mesh.quad(gpa, .{
            .{ east, bottom, far_z }, .{ east, top, far_z }, .{ east, top, near_z }, .{ east, bottom, near_z },
        }, .{
            .{ line.u0, line.v1 }, .{ line.u1, line.v1 }, .{ line.u1, line.v0 }, .{ line.u0, line.v0 },
        }, color);
    }

    if (world_map.getBlock(pos.offset(0, 0, -1)).isNormalCube() and world_map.getBlock(pos.offset(0, 1, -1)) == .redstone_wire) {
        try mesh.quad(gpa, .{
            .{ far_x, bottom, north }, .{ far_x, top, north }, .{ near_x, top, north }, .{ near_x, bottom, north },
        }, .{
            .{ line.u0, line.v1 }, .{ line.u1, line.v1 }, .{ line.u1, line.v0 }, .{ line.u0, line.v0 },
        }, color);
    }

    if (world_map.getBlock(pos.offset(0, 0, 1)).isNormalCube() and world_map.getBlock(pos.offset(0, 1, 1)) == .redstone_wire) {
        try mesh.quad(gpa, .{
            .{ far_x, top, south }, .{ far_x, bottom, south }, .{ near_x, bottom, south }, .{ near_x, top, south },
        }, .{
            .{ line.u1, line.v0 }, .{ line.u0, line.v0 }, .{ line.u0, line.v1 }, .{ line.u1, line.v1 },
        }, color);
    }
}

const lever_stick_half: f32 = 1.0 / 16.0;
const lever_stick_length: f32 = 10.0 / 16.0;
const lever_tilt: f32 = std.math.pi * 2.0 / 9.0;

fn rotateAroundX(point: [3]f32, angle: f32) [3]f32 {
    const c = @cos(angle);
    const s = @sin(angle);
    return .{ point[0], point[1] * c + point[2] * s, point[2] * c - point[1] * s };
}

fn rotateAroundY(point: [3]f32, angle: f32) [3]f32 {
    const c = @cos(angle);
    const s = @sin(angle);
    return .{ point[0] * c + point[2] * s, point[1], point[2] * c - point[0] * s };
}

fn leverStickCorners(metadata: u4, origin: [3]f32) [8][3]f32 {
    const facing = metadata & world.block.facing_mask;
    const powered = world.block.isPowered(metadata);
    const half = lever_stick_half;
    const length = lever_stick_length;

    var corners = [8][3]f32{
        .{ -half, 0, -half },      .{ half, 0, -half },      .{ half, 0, half },      .{ -half, 0, half },
        .{ -half, length, -half }, .{ half, length, -half }, .{ half, length, half }, .{ -half, length, half },
    };

    for (&corners) |*corner| {
        if (powered) {
            corner[2] -= 1.0 / 16.0;
            corner.* = rotateAroundX(corner.*, lever_tilt);
        } else {
            corner[2] += 1.0 / 16.0;
            corner.* = rotateAroundX(corner.*, -lever_tilt);
        }

        if (facing == 6) corner.* = rotateAroundY(corner.*, std.math.pi * 0.5);

        if (facing < 5) {
            corner[1] -= 0.375;
            corner.* = rotateAroundX(corner.*, std.math.pi * 0.5);
            switch (facing) {
                3 => corner.* = rotateAroundY(corner.*, std.math.pi),
                2 => corner.* = rotateAroundY(corner.*, std.math.pi * 0.5),
                1 => corner.* = rotateAroundY(corner.*, std.math.pi * -0.5),
                else => {},
            }
            corner[0] += origin[0] + 0.5;
            corner[1] += origin[1] + 0.5;
            corner[2] += origin[2] + 0.5;
        } else {
            corner[0] += origin[0] + 0.5;
            corner[1] += origin[1] + 2.0 / 16.0;
            corner[2] += origin[2] + 0.5;
        }
    }

    return corners;
}

const lever_stick_faces = [6][4]usize{
    .{ 0, 1, 2, 3 },
    .{ 7, 6, 5, 4 },
    .{ 1, 0, 4, 5 },
    .{ 2, 1, 5, 6 },
    .{ 3, 2, 6, 7 },
    .{ 0, 3, 7, 4 },
};

const crops_drop: f32 = 1.0 / 16.0;
const crops_offset: f32 = 0.25;

fn buildCrops(mesh: *MeshBuilder, gpa: std.mem.Allocator, tile: u8, brightness: f32, bx: f32, by: f32, bz: f32) !void {
    const uv = Atlas.tileUv(tile);
    const color = shadeColor(brightness, Colorizer.white);

    const bottom = by - crops_drop;
    const top = bottom + 1.0;

    const uvs = [4][2]f32{
        .{ uv.u0, uv.v0 },
        .{ uv.u0, uv.v1 },
        .{ uv.u1, uv.v1 },
        .{ uv.u1, uv.v0 },
    };

    for ([_]f32{ bx + 0.5 - crops_offset, bx + 0.5 + crops_offset }, 0..) |plane_x, index| {
        const near = if (index == 0) bz else bz + 1.0;
        const far = if (index == 0) bz + 1.0 else bz;
        try mesh.quad(gpa, .{
            .{ plane_x, top, near },
            .{ plane_x, bottom, near },
            .{ plane_x, bottom, far },
            .{ plane_x, top, far },
        }, uvs, color);
        try mesh.quad(gpa, .{
            .{ plane_x, top, far },
            .{ plane_x, bottom, far },
            .{ plane_x, bottom, near },
            .{ plane_x, top, near },
        }, uvs, color);
    }

    for ([_]f32{ bz + 0.5 - crops_offset, bz + 0.5 + crops_offset }, 0..) |plane_z, index| {
        const near = if (index == 0) bx else bx + 1.0;
        const far = if (index == 0) bx + 1.0 else bx;
        try mesh.quad(gpa, .{
            .{ near, top, plane_z },
            .{ near, bottom, plane_z },
            .{ far, bottom, plane_z },
            .{ far, top, plane_z },
        }, uvs, color);
        try mesh.quad(gpa, .{
            .{ far, top, plane_z },
            .{ far, bottom, plane_z },
            .{ near, bottom, plane_z },
            .{ near, top, plane_z },
        }, uvs, color);
    }
}

fn buildFence(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    world_map: *const world.ChunkView,
    id: world.Block,
    pos: BlockPos,
    origin: [3]f32,
    options: Options,
) !void {
    const textures = id.faceTextures();
    try buildBoundedBox(mesh, gpa, world_map, id, world.block.fence_post_bounds, textures, pos, origin, options);

    const west = world_map.getBlock(pos.offset(-1, 0, 0)) == id;
    const east = world_map.getBlock(pos.offset(1, 0, 0)) == id;
    const north = world_map.getBlock(pos.offset(0, 0, -1)) == id;
    const south = world_map.getBlock(pos.offset(0, 0, 1)) == id;

    const along_z = north or south;
    const along_x = west or east or !along_z;

    for ([_]bool{ true, false }) |upper| {
        if (along_x) {
            const bounds = world.block.fenceRailBounds(upper, true, west, east);
            try buildBoundedBox(mesh, gpa, world_map, id, bounds, textures, pos, origin, options);
        }
        if (along_z) {
            const bounds = world.block.fenceRailBounds(upper, false, north, south);
            try buildBoundedBox(mesh, gpa, world_map, id, bounds, textures, pos, origin, options);
        }
    }
}

const ladder_offset: f32 = 0.05;

fn buildLadder(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    tile: u8,
    metadata: u4,
    brightness: f32,
    bx: f32,
    by: f32,
    bz: f32,
) !void {
    const uv = Atlas.tileUv(tile);
    const color = shadeColor(brightness, Colorizer.white);

    const west = bx;
    const east = bx + 1.0;
    const bottom = by;
    const top = by + 1.0;
    const north = bz;
    const south = bz + 1.0;

    const positions: [4][3]f32 = switch (metadata) {
        2 => .{
            .{ east, top, south - ladder_offset },
            .{ east, bottom, south - ladder_offset },
            .{ west, bottom, south - ladder_offset },
            .{ west, top, south - ladder_offset },
        },
        3 => .{
            .{ east, bottom, north + ladder_offset },
            .{ east, top, north + ladder_offset },
            .{ west, top, north + ladder_offset },
            .{ west, bottom, north + ladder_offset },
        },
        4 => .{
            .{ east - ladder_offset, bottom, south },
            .{ east - ladder_offset, top, south },
            .{ east - ladder_offset, top, north },
            .{ east - ladder_offset, bottom, north },
        },
        else => .{
            .{ west + ladder_offset, top, south },
            .{ west + ladder_offset, bottom, south },
            .{ west + ladder_offset, bottom, north },
            .{ west + ladder_offset, top, north },
        },
    };

    const uvs: [4][2]f32 = switch (metadata) {
        3, 4 => .{
            .{ uv.u1, uv.v1 },
            .{ uv.u1, uv.v0 },
            .{ uv.u0, uv.v0 },
            .{ uv.u0, uv.v1 },
        },
        else => .{
            .{ uv.u0, uv.v0 },
            .{ uv.u0, uv.v1 },
            .{ uv.u1, uv.v1 },
            .{ uv.u1, uv.v0 },
        },
    };

    try mesh.quad(gpa, positions, uvs, color);
}

fn buildLever(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    world_map: *const world.ChunkView,
    metadata: u4,
    pos: BlockPos,
    origin: [3]f32,
    options: Options,
) !void {
    try buildBoundedBox(
        mesh,
        gpa,
        world_map,
        .lever,
        world.block.leverBaseBounds(metadata),
        world.block.FaceTextures.initFill(world.block.cobblestone_tile),
        pos,
        origin,
        options,
    );

    const corners = leverStickCorners(metadata, origin);
    const color = shadeColor(world.light.brightnessAt(world_map, pos, 0), Colorizer.white);
    const uv = Atlas.tileUv(tileFor(options, world.block.lever_tile));
    const texel: f32 = 1.0 / 256.0;

    for (lever_stick_faces, 0..) |face, index| {
        const u_low = uv.u0 + 7.0 * texel;
        const u_high = uv.u0 + 9.0 * texel;
        const v_low = uv.v0 + 6.0 * texel;
        const v_high = if (index >= 2) uv.v0 + 16.0 * texel else uv.v0 + 8.0 * texel;

        try mesh.quad(gpa, .{
            corners[face[0]], corners[face[1]], corners[face[2]], corners[face[3]],
        }, .{
            .{ u_low, v_high }, .{ u_high, v_high }, .{ u_high, v_low }, .{ u_low, v_low },
        }, color);
    }
}

fn repeaterTopCorners(origin: [3]f32, facing: u2) [4][3]f32 {
    const height = origin[1] + world.block.repeater_height;
    const cycle = [4][2]f32{ .{ 0, 0 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 } };
    const start = (4 - @as(usize, facing)) % 4;

    var corners: [4][3]f32 = undefined;
    for (&corners, 0..) |*corner, index| {
        const cell = cycle[(start + index) % 4];
        corner.* = .{ origin[0] + cell[0], height, origin[2] + cell[1] };
    }
    return corners;
}

fn buildRepeater(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    world_map: *const world.ChunkView,
    id: world.Block,
    metadata: u4,
    pos: BlockPos,
    origin: [3]f32,
    options: Options,
) !void {
    const bounds: world.block.Bounds = .{ .min = .{ 0, 0, 0 }, .max = .{ 1, world.block.repeater_height, 1 } };
    const textures = texturesFor(options, world.block.repeaterTextures(id));
    const emitted = world.light.emission(id);

    for (faces) |face| {
        if (face.side == .up or face.side == .down) continue;
        const quad = boxFaceQuad(bounds, origin, face, textures.get(face.side), .{});
        const brightness = world.light.brightnessAt(world_map, pos.offset(face.normal[0], 0, face.normal[2]), emitted);
        try mesh.quad(gpa, quad.positions, quad.uvs, shadeColor(face.shade * brightness, Colorizer.white));
    }

    const facing = world.block.repeaterFacing(metadata);
    const top_uv = Atlas.tileUv(textures.get(.up));
    const top_brightness = world.light.brightnessAt(world_map, pos.offset(0, 1, 0), emitted);
    try mesh.quad(gpa, repeaterTopCorners(origin, facing), .{
        .{ top_uv.u0, top_uv.v0 },
        .{ top_uv.u0, top_uv.v1 },
        .{ top_uv.u1, top_uv.v1 },
        .{ top_uv.u1, top_uv.v0 },
    }, shadeColor(top_brightness, Colorizer.white));

    const offset = world.block.repeater_torch_offsets[world.block.repeaterDelay(metadata)];
    const lock: f32 = 0.3125;
    var moving: [2]f32 = .{ 0, 0 };
    var fixed: [2]f32 = .{ 0, 0 };
    switch (facing) {
        0 => {
            fixed[1] = -lock;
            moving[1] = offset;
        },
        1 => {
            fixed[0] = lock;
            moving[0] = -offset;
        },
        2 => {
            fixed[1] = lock;
            moving[1] = -offset;
        },
        3 => {
            fixed[0] = -lock;
            moving[0] = offset;
        },
    }

    const torch_tile = textures.get(.down);
    const torch_brightness = (world.light.brightnessAt(world_map, pos, emitted) + 1.0) * 0.5;
    const torch_color = shadeColor(torch_brightness, Colorizer.white);
    const torch_drop: f32 = -0.1875;

    try buildTorch(mesh, gpa, torch_tile, 5, origin[0] + moving[0], origin[1] + torch_drop, origin[2] + moving[1], torch_color);
    try buildTorch(mesh, gpa, torch_tile, 5, origin[0] + fixed[0], origin[1] + torch_drop, origin[2] + fixed[1], torch_color);
}

fn boxCorner(origin: [3]f32, bounds: world.block.Bounds, corner: [3]f32) [3]f32 {
    var out: [3]f32 = undefined;
    for (0..3) |axis| {
        out[axis] = origin[axis] + (if (corner[axis] == 0) bounds.min[axis] else bounds.max[axis]);
    }
    return out;
}

pub fn croppedUv(edge: f32, opposite: f32, bounds: world.block.Bounds, axis: u2, corner: f32) f32 {
    const inset = if (corner == 0) bounds.min[axis] else 1.0 - bounds.max[axis];
    return edge + inset * (opposite - edge);
}

fn reachesFace(bounds: world.block.Bounds, side: world.Side) bool {
    return switch (side) {
        .down => bounds.min[1] == 0.0,
        .up => bounds.max[1] == 1.0,
        .north => bounds.min[2] == 0.0,
        .south => bounds.max[2] == 1.0,
        .west => bounds.min[0] == 0.0,
        .east => bounds.max[0] == 1.0,
    };
}

const BoxQuad = struct { positions: [4][3]f32, uvs: [4][2]f32 };

fn tileFraction(bounds: world.block.Bounds, axis: u2, corner: f32, far: bool) f32 {
    if (bounds.min[axis] < 0.0 or bounds.max[axis] > 1.0) return if (far) 1.0 else 0.0;
    const inset = if (corner == 0) bounds.min[axis] else 1.0 - bounds.max[axis];
    return if (far) 1.0 - inset else inset;
}

fn turnedTileUv(u: f32, v: f32, turn: world.block.TileTurn) [2]f32 {
    const across = if (turn.mirrored) 1.0 - u else u;
    return switch (turn.turns) {
        0 => .{ across, v },
        1 => .{ v, 1.0 - across },
        2 => .{ 1.0 - across, 1.0 - v },
        3 => .{ 1.0 - v, across },
    };
}

fn boxFaceQuad(bounds: world.block.Bounds, origin: [3]f32, face: FaceDir, tile: u8, turn: world.block.TileTurn) BoxQuad {
    const uv = Atlas.tileUv(tile);

    var quad: BoxQuad = undefined;
    for (face.corners, 0..) |corner, i| {
        quad.positions[i] = boxCorner(origin, bounds, corner);

        const across = tileFraction(bounds, face.axis_u, corner[face.axis_u], i < 2);
        const down = tileFraction(bounds, face.axis_v, corner[face.axis_v], (i == 0 or i == 3) != face.flip_v);
        const turned = turnedTileUv(across, down, turn);

        quad.uvs[i] = .{
            uv.u0 + turned[0] * (uv.u1 - uv.u0),
            uv.v0 + turned[1] * (uv.v1 - uv.v0),
        };
    }
    return quad;
}

pub fn buildBoxCube(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    center: [3]f32,
    size: f32,
    bounds: world.block.Bounds,
    face_textures: world.block.FaceTextures,
    inset: f32,
    lit: item_lighting.Lit,
) !void {
    for (faces) |face| {
        const quad = boxFaceQuad(bounds, .{ 0, 0, 0 }, face, face_textures.get(face.side), .{});
        var positions = quad.positions;
        for (&positions) |*position| {
            for (0..3) |axis| position[axis] = center[axis] + (position[axis] - 0.5) * size;
            position[0] = pulledInward(position[0], face.normal[0], inset);
            position[2] = pulledInward(position[2], face.normal[2], inset);
        }
        const normal: [3]f32 = .{
            @floatFromInt(face.normal[0]),
            @floatFromInt(face.normal[1]),
            @floatFromInt(face.normal[2]),
        };
        try mesh.quad(gpa, positions, quad.uvs, item_lighting.faceColor(lit, normal));
    }
}

const bed_seam_side = [4]world.Side{ .south, .west, .north, .east };
const bed_opposite_direction = [4]u2{ 2, 3, 0, 1 };
const bed_flipped_side = [4]world.Side{ .east, .south, .west, .north };

const bed_top_uvs = [4][4][2]f32{
    .{ .{ 1, 1 }, .{ 0, 1 }, .{ 0, 0 }, .{ 1, 0 } },
    .{ .{ 0, 1 }, .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 } },
    .{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } },
    .{ .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 }, .{ 0, 0 } },
};

const bed_bottom_uvs = [4][2]f32{ .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 }, .{ 0, 0 } };

fn tileUvs(tile: u8, fractions: [4][2]f32) [4][2]f32 {
    const uv = Atlas.tileUv(tile);
    var uvs: [4][2]f32 = undefined;
    for (fractions, 0..) |fraction, i| {
        uvs[i] = .{
            uv.u0 + fraction[0] * (uv.u1 - uv.u0),
            uv.v0 + fraction[1] * (uv.v1 - uv.v0),
        };
    }
    return uvs;
}

fn buildBed(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    world_map: *const world.ChunkView,
    id: world.Block,
    metadata: u4,
    pos: BlockPos,
    origin: [3]f32,
    options: Options,
) !void {
    const bounds = world.block.Bounds{ .min = .{ 0, 0, 0 }, .max = .{ 1, world.block.bed_height, 1 } };
    const textures = texturesFor(options, world.block.bedTextures(metadata));
    const facing = world.block.bedFacing(metadata);
    const seam = if (world.block.bedIsPillow(metadata))
        bed_seam_side[bed_opposite_direction[facing]]
    else
        bed_seam_side[facing];

    const emitted = world.light.emission(id);
    const own_brightness = world.light.brightnessAt(world_map, pos, emitted);

    for (faces) |face| {
        const tile = textures.get(face.side);

        if (face.side == .down) {
            var legs = bounds;
            legs.min[1] = world.block.bed_leg_height;
            const quad = boxFaceQuad(legs, origin, face, tile, .{});
            try mesh.quad(gpa, quad.positions, tileUvs(tile, bed_bottom_uvs), shadeColor(face.shade * own_brightness, Colorizer.white));
            continue;
        }

        if (face.side == .up) {
            const quad = boxFaceQuad(bounds, origin, face, tile, .{});
            const brightness = world.light.brightnessAt(world_map, pos.offset(0, 1, 0), emitted);
            try mesh.quad(gpa, quad.positions, tileUvs(tile, bed_top_uvs[facing]), shadeColor(face.shade * brightness, Colorizer.white));
            continue;
        }

        if (face.side == seam) continue;

        const nx = pos.x + face.normal[0];
        const ny = pos.y + face.normal[1];
        const nz = pos.z + face.normal[2];
        if (!showsFace(options, world_map, id, .init(nx, ny, nz), face.side)) continue;

        const turn = world.block.TileTurn{ .mirrored = face.side == bed_flipped_side[facing] };
        const quad = boxFaceQuad(bounds, origin, face, tile, turn);

        if (options.smooth) {
            const corner_brightness = smoothBrightness(world_map, face, pos, emitted);
            var colors: [4][4]u8 = undefined;
            for (corner_brightness, 0..) |brightness, i| {
                colors[i] = shadeColor(face.shade * brightness, Colorizer.white);
            }
            try mesh.quadShaded(gpa, quad.positions, quad.uvs, colors);
            continue;
        }

        const brightness = world.light.brightnessAt(world_map, .init(nx, ny, nz), emitted);
        try mesh.quad(gpa, quad.positions, quad.uvs, shadeColor(face.shade * brightness, Colorizer.white));
    }
}

fn buildDoor(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    world_map: *const world.ChunkView,
    id: world.Block,
    metadata: u4,
    pos: BlockPos,
    origin: [3]f32,
    options: Options,
) !void {
    const bounds = world.block.doorBounds(metadata);
    const emitted = world.light.emission(id);
    const own_brightness = world.light.brightnessAt(world_map, pos, emitted);

    for (faces) |face| {
        const door_face = world.block.doorFaceTile(id, face.side, metadata);
        const quad = boxFaceQuad(bounds, origin, face, tileFor(options, door_face.tile), .{ .mirrored = door_face.mirrored });

        const brightness = if (reachesFace(bounds, face.side))
            world.light.brightnessAt(world_map, pos.offset(face.normal[0], face.normal[1], face.normal[2]), emitted)
        else
            own_brightness;

        try mesh.quad(gpa, quad.positions, quad.uvs, shadeColor(face.shade * brightness, Colorizer.white));
    }
}

pub const piston_shaft_length: f32 = 1.0;
pub const piston_shaft_band: f32 = 4.0 / 16.0;

pub fn pistonShaftBox(metadata: u4, length: f32) world.block.Bounds {
    const low = 0.5 - world.block.piston_shaft_half;
    const high = 0.5 + world.block.piston_shaft_half;
    const plate = world.block.piston_head_depth;

    return switch (world.block.pistonFacing(metadata)) {
        .down => .{ .min = .{ low, plate, low }, .max = .{ high, plate + length, high } },
        .up => .{ .min = .{ low, 1.0 - plate - length, low }, .max = .{ high, 1.0 - plate, high } },
        .north => .{ .min = .{ low, low, plate }, .max = .{ high, high, plate + length } },
        .south => .{ .min = .{ low, low, 1.0 - plate - length }, .max = .{ high, high, 1.0 - plate } },
        .west => .{ .min = .{ plate, low, low }, .max = .{ plate + length, high, high } },
        .east => .{ .min = .{ 1.0 - plate - length, low, low }, .max = .{ 1.0 - plate, high, high } },
    };
}

fn pistonShaftAxis(metadata: u4) u2 {
    const step = world.block.pistonFacing(metadata).step();
    return if (step[0] != 0) 0 else if (step[1] != 0) 1 else 2;
}

fn pistonShaftCrossAxes(axis: u2) [2]u2 {
    return switch (axis) {
        0 => .{ 1, 2 },
        1 => .{ 0, 2 },
        else => .{ 0, 1 },
    };
}

const ShaftQuad = struct { from: [2]f32, to: [2]f32, shade: f32 };

fn pistonShaftQuads(axis: u2) [4]ShaftQuad {
    const low = 0.5 - world.block.piston_shaft_half;
    const high = 0.5 + world.block.piston_shaft_half;

    return switch (axis) {
        1 => .{
            .{ .from = .{ low, high }, .to = .{ high, high }, .shade = 0.8 },
            .{ .from = .{ high, low }, .to = .{ low, low }, .shade = 0.8 },
            .{ .from = .{ low, low }, .to = .{ low, high }, .shade = 0.6 },
            .{ .from = .{ high, high }, .to = .{ high, low }, .shade = 0.6 },
        },
        2 => .{
            .{ .from = .{ low, high }, .to = .{ low, low }, .shade = 0.6 },
            .{ .from = .{ high, low }, .to = .{ high, high }, .shade = 0.6 },
            .{ .from = .{ low, low }, .to = .{ high, low }, .shade = 0.5 },
            .{ .from = .{ high, high }, .to = .{ low, high }, .shade = 1.0 },
        },
        else => .{
            .{ .from = .{ low, high }, .to = .{ low, low }, .shade = 0.5 },
            .{ .from = .{ high, low }, .to = .{ high, high }, .shade = 1.0 },
            .{ .from = .{ low, low }, .to = .{ high, low }, .shade = 0.6 },
            .{ .from = .{ high, high }, .to = .{ low, high }, .shade = 0.6 },
        },
    };
}

fn shaftCorner(origin: [3]f32, axis: u2, along: f32, cross: [2]u2, at: [2]f32) [3]f32 {
    var out: [3]f32 = undefined;
    out[axis] = origin[axis] + along;
    out[cross[0]] = origin[cross[0]] + at[0];
    out[cross[1]] = origin[cross[1]] + at[1];
    return out;
}

pub fn buildPistonShaft(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    metadata: u4,
    length: f32,
    origin: [3]f32,
    tile: u8,
    brightness: ?f32,
) !void {
    if (length <= 0.0) return;

    const axis = pistonShaftAxis(metadata);
    const cross = pistonShaftCrossAxes(axis);
    const bounds = pistonShaftBox(metadata, length);
    const low = bounds.min[axis];
    const high = bounds.max[axis];

    const uv = Atlas.tileUv(tile);
    const u_high = uv.u0 + (uv.u1 - uv.u0) * length;
    const v_high = uv.v0 + (uv.v1 - uv.v0) * piston_shaft_band;

    for (pistonShaftQuads(axis)) |quad| {
        const positions = [4][3]f32{
            shaftCorner(origin, axis, high, cross, quad.from),
            shaftCorner(origin, axis, low, cross, quad.from),
            shaftCorner(origin, axis, low, cross, quad.to),
            shaftCorner(origin, axis, high, cross, quad.to),
        };
        const uvs = [4][2]f32{
            .{ u_high, uv.v0 },
            .{ uv.u0, uv.v0 },
            .{ uv.u0, v_high },
            .{ u_high, v_high },
        };
        const color = if (brightness) |lit|
            shadeColor(quad.shade * lit, Colorizer.white)
        else
            [4]u8{ 255, 255, 255, 255 };
        try mesh.quad(gpa, positions, uvs, color);
    }
}

pub fn buildPistonHead(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    world_map: *const world.ChunkView,
    id: world.Block,
    metadata: u4,
    pos: BlockPos,
    origin: [3]f32,
    shaft_length: f32,
    options: Options,
) !void {
    const facing = world.block.pistonFacing(metadata);
    const textures = world.block.pistonHeadTextures(metadata);
    try buildBoundedBoxTurned(mesh, gpa, world_map, id, world.block.pistonHeadPlateBounds(metadata), textures, facing, pos, origin, options);

    const emitted = world.light.emission(id);
    const brightness = world.light.brightnessAt(world_map, pos, emitted);
    try buildPistonShaft(mesh, gpa, metadata, shaft_length, origin, tileFor(options, world.block.piston_side_tile), brightness);
}

fn buildBoundedBox(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    world_map: *const world.ChunkView,
    id: world.Block,
    bounds: world.block.Bounds,
    textures: world.block.FaceTextures,
    pos: BlockPos,
    origin: [3]f32,
    options: Options,
) !void {
    return buildBoundedBoxTurned(mesh, gpa, world_map, id, bounds, textures, null, pos, origin, options);
}

fn buildBoundedBoxTurned(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    world_map: *const world.ChunkView,
    id: world.Block,
    bounds: world.block.Bounds,
    textures: world.block.FaceTextures,
    facing: ?world.Side,
    pos: BlockPos,
    origin: [3]f32,
    options: Options,
) !void {
    const emitted = world.light.emission(id);
    const own_brightness = world.light.brightnessAt(world_map, pos, emitted);

    for (faces) |face| {
        const nx = pos.x + face.normal[0];
        const ny = pos.y + face.normal[1];
        const nz = pos.z + face.normal[2];
        const reaches = reachesFace(bounds, face.side);
        if (reaches and !showsFace(options, world_map, id, .init(nx, ny, nz), face.side)) continue;

        const turn = if (facing) |along| world.block.pistonSideTurn(along, face.side) else world.block.TileTurn{};
        const quad = boxFaceQuad(bounds, origin, face, texturesFor(options, textures).get(face.side), turn);

        if (options.smooth and reaches) {
            const corner_brightness = smoothBrightness(world_map, face, pos, emitted);
            var colors: [4][4]u8 = undefined;
            for (corner_brightness, 0..) |brightness, i| {
                colors[i] = shadeColor(face.shade * brightness, Colorizer.white);
            }
            try mesh.quadShaded(gpa, quad.positions, quad.uvs, colors);
            continue;
        }

        const brightness = if (reaches)
            world.light.brightnessAt(world_map, .init(nx, ny, nz), emitted)
        else
            own_brightness;
        try mesh.quad(gpa, quad.positions, quad.uvs, shadeColor(face.shade * brightness, Colorizer.white));
    }
}

fn fluidBrightness(world_map: *const world.ChunkView, pos: BlockPos, minimum: u4) f32 {
    return @max(
        world.light.brightnessAt(world_map, pos, minimum),
        world.light.brightnessAt(world_map, pos.offset(0, 1, 0), minimum),
    );
}

fn fluidCornerHeight(world_map: *const world.ChunkView, pos: BlockPos, material: world.Material) f32 {
    var count: u32 = 0;
    var submerged: f32 = 0;

    for (0..4) |corner| {
        const nx = pos.x - @as(i32, @intCast(corner & 1));
        const nz = pos.z - @as(i32, @intCast((corner >> 1) & 1));
        if (world_map.getBlock(.init(nx, pos.y + 1, nz)).material() == material) return 1.0;

        const neighbor = world_map.getBlock(.init(nx, pos.y, nz)).material();
        if (neighbor != material) {
            if (!neighbor.isSolid()) {
                submerged += 1.0;
                count += 1;
            }
            continue;
        }

        const metadata = world_map.getBlockMetadata(.init(nx, pos.y, nz));
        if (metadata >= 8 or metadata == 0) {
            submerged += world.fluid.percentAir(metadata) * 10.0;
            count += 10;
        }
        submerged += world.fluid.percentAir(metadata);
        count += 1;
    }

    return 1.0 - submerged / @as(f32, @floatFromInt(count));
}

const fluid_sides = [4]struct {
    side: world.Side,
    normal: [2]i32,
    left: u2,
    right: u2,
    left_offset: [2]f32,
    right_offset: [2]f32,
}{
    .{ .side = .north, .normal = .{ 0, -1 }, .left = 0, .right = 3, .left_offset = .{ 0, 0 }, .right_offset = .{ 1, 0 } },
    .{ .side = .south, .normal = .{ 0, 1 }, .left = 2, .right = 1, .left_offset = .{ 1, 1 }, .right_offset = .{ 0, 1 } },
    .{ .side = .west, .normal = .{ -1, 0 }, .left = 1, .right = 0, .left_offset = .{ 0, 1 }, .right_offset = .{ 0, 0 } },
    .{ .side = .east, .normal = .{ 1, 0 }, .left = 3, .right = 2, .left_offset = .{ 1, 0 }, .right_offset = .{ 1, 1 } },
};

fn buildFluid(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    world_map: *const world.ChunkView,
    id: world.Block,
    pos: BlockPos,
    origin: [3]f32,
    options: Options,
) !void {
    const material = id.material();
    const emitted = world.light.emission(id);
    const textures = id.faceTextures();

    const heights = [4]f32{
        fluidCornerHeight(world_map, pos, material),
        fluidCornerHeight(world_map, pos.offset(0, 0, 1), material),
        fluidCornerHeight(world_map, pos.offset(1, 0, 1), material),
        fluidCornerHeight(world_map, pos.offset(1, 0, 0), material),
    };

    if (id.shouldRenderFace(world_map.getBlock(pos.offset(0, 1, 0)), .up, options.fancy)) {
        const angle = world.fluid.flowAngle(world_map, pos);
        const tile = if (angle == null) textures.get(.up) else textures.get(.north);
        const uv = Atlas.tileUv(tile);
        const half: f32 = 8.0 / 256.0;
        const center_offset: f32 = if (angle == null) half else 2.0 * half;
        const center_u = uv.u0 + center_offset;
        const center_v = uv.v0 + center_offset;
        const rotation = angle orelse 0.0;
        const du = math.util.sin(rotation) * half;
        const dv = math.util.cos(rotation) * half;

        const brightness = fluidBrightness(world_map, pos, emitted);
        const color = shadeColor(1.0 * brightness, Colorizer.white);
        try mesh.quad(gpa, .{
            .{ origin[0], origin[1] + heights[0], origin[2] },
            .{ origin[0], origin[1] + heights[1], origin[2] + 1 },
            .{ origin[0] + 1, origin[1] + heights[2], origin[2] + 1 },
            .{ origin[0] + 1, origin[1] + heights[3], origin[2] },
        }, .{
            .{ center_u - dv - du, center_v - dv + du },
            .{ center_u - dv + du, center_v + dv + du },
            .{ center_u + dv + du, center_v + dv - du },
            .{ center_u + dv - du, center_v - dv - du },
        }, color);
    }

    if (id.shouldRenderFace(world_map.getBlock(pos.offset(0, -1, 0)), .down, options.fancy)) {
        const uv = Atlas.tileUv(textures.get(.down));
        const brightness = fluidBrightness(world_map, pos.offset(0, -1, 0), emitted);
        const color = shadeColor(0.5 * brightness, Colorizer.white);
        try mesh.quad(gpa, .{
            .{ origin[0] + 1, origin[1], origin[2] },
            .{ origin[0] + 1, origin[1], origin[2] + 1 },
            .{ origin[0], origin[1], origin[2] + 1 },
            .{ origin[0], origin[1], origin[2] },
        }, .{
            .{ uv.u1, uv.v0 },
            .{ uv.u1, uv.v1 },
            .{ uv.u0, uv.v1 },
            .{ uv.u0, uv.v0 },
        }, color);
    }

    for (fluid_sides) |face| {
        const nx = pos.x + face.normal[0];
        const nz = pos.z + face.normal[1];
        if (!id.shouldRenderFace(world_map.getBlock(.init(nx, pos.y, nz)), face.side, options.fancy)) continue;

        const left_height = heights[face.left];
        const right_height = heights[face.right];
        const tile = textures.get(face.side);
        const tile_u: f32 = @floatFromInt((@as(u32, tile) & 15) * 16);
        const tile_v: f32 = @floatFromInt(@as(u32, tile) & 240);
        const u_left = tile_u / 256.0;
        const u_right = (tile_u + 16.0 - 0.01) / 256.0;
        const v_left = (tile_v + (1.0 - left_height) * 16.0) / 256.0;
        const v_right = (tile_v + (1.0 - right_height) * 16.0) / 256.0;
        const v_bottom = (tile_v + 16.0 - 0.01) / 256.0;

        const shade: f32 = if (face.normal[1] != 0) 0.8 else 0.6;
        const brightness = fluidBrightness(world_map, .init(nx, pos.y, nz), emitted);
        const color = shadeColor(shade * brightness, Colorizer.white);

        const left_x = origin[0] + face.left_offset[0];
        const left_z = origin[2] + face.left_offset[1];
        const right_x = origin[0] + face.right_offset[0];
        const right_z = origin[2] + face.right_offset[1];

        try mesh.quad(gpa, .{
            .{ left_x, origin[1] + left_height, left_z },
            .{ right_x, origin[1] + right_height, right_z },
            .{ right_x, origin[1], right_z },
            .{ left_x, origin[1], left_z },
        }, .{
            .{ u_left, v_left },
            .{ u_right, v_right },
            .{ u_right, v_bottom },
            .{ u_left, v_bottom },
        }, color);
    }
}

pub fn buildBlockAt(
    target: *MeshBuilder,
    gpa: std.mem.Allocator,
    world_map: *const world.ChunkView,
    id: world.Block,
    metadata: u4,
    pos: BlockPos,
    origin: [3]f32,
    colorizer: Colorizer,
    climate: Climate,
    options: Options,
) !void {
    if (id == .air) return;
    if (id.isSign()) return;

    const bx = origin[0];
    const by = origin[1];
    const bz = origin[2];

    const emitted = world.light.emission(id);
    const own_brightness = world.light.brightnessAt(world_map, pos, emitted);

    if (id.isCross()) {
        const tint = anaglyph.tint(options.anaglyph, blockTint(colorizer, id, metadata, world.Side.up, climate.temperature, climate.humidity));
        try buildCross(target, gpa, tileFor(options, id.crossTile(metadata)), tint, own_brightness, bx, by, bz);
        return;
    }

    if (id.shape() == .fire) {
        try buildFire(target, gpa, world_map, tileFor(options, id.faceTextures().get(.down)), own_brightness, pos, origin);
        return;
    }

    if (id.shape() == .torch) {
        try buildTorch(target, gpa, tileFor(options, id.faceTextures().get(.down)), metadata, bx, by, bz, shadeColor(1.0, Colorizer.white));
        return;
    }

    if (id.shape() == .portal) {
        const bounds = world.portal.bounds(world_map, .{ .x = pos.x, .y = pos.y, .z = pos.z });
        try buildBoundedBox(target, gpa, world_map, id, bounds, id.faceTextures(), pos, origin, options);
        return;
    }

    if (id.shape() == .wire) {
        try buildWire(target, gpa, world_map, metadata, pos, origin, options);
        return;
    }

    if (id.shape() == .rail) {
        try buildRail(target, gpa, world_map, id, metadata, pos, origin, options);
        return;
    }

    if (id.shape() == .crops) {
        try buildCrops(target, gpa, tileFor(options, world.block.cropsTile(metadata)), own_brightness, bx, by, bz);
        return;
    }

    if (id.shape() == .fence) {
        try buildFence(target, gpa, world_map, id, pos, origin, options);
        return;
    }

    if (id.shape() == .ladder) {
        try buildLadder(target, gpa, tileFor(options, id.faceTextures().get(.down)), metadata, own_brightness, bx, by, bz);
        return;
    }

    if (id.shape() == .lever) {
        try buildLever(target, gpa, world_map, metadata, pos, origin, options);
        return;
    }

    if (id.shape() == .button) {
        const bounds = world.block.buttonBounds(metadata);
        try buildBoundedBox(target, gpa, world_map, id, bounds, id.faceTextures(), pos, origin, options);
        return;
    }

    if (id.shape() == .plate) {
        const bounds = world.block.plateBounds(metadata);
        try buildBoundedBox(target, gpa, world_map, id, bounds, id.faceTextures(), pos, origin, options);
        return;
    }

    if (id.shape() == .piston) {
        try buildBoundedBoxTurned(
            target,
            gpa,
            world_map,
            id,
            world.block.pistonBaseBounds(metadata),
            world.block.pistonBaseTextures(id, metadata),
            world.block.pistonFacing(metadata),
            pos,
            origin,
            options,
        );
        return;
    }

    if (id.shape() == .piston_head) {
        try buildPistonHead(target, gpa, world_map, id, metadata, pos, origin, piston_shaft_length, options);
        return;
    }

    if (id.shape() == .piston_moving) return;

    if (id.isRepeater()) {
        try buildRepeater(target, gpa, world_map, id, metadata, pos, origin, options);
        return;
    }

    if (id.isDoor()) {
        try buildDoor(target, gpa, world_map, id, metadata, pos, origin, options);
        return;
    }

    if (id.isTrapdoor()) {
        const bounds = world.block.trapdoorBounds(metadata);
        try buildBoundedBox(target, gpa, world_map, id, bounds, id.faceTextures(), pos, origin, options);
        return;
    }

    if (id.isStairs()) {
        for (world.block.stairsBoxes(metadata)) |bounds| {
            try buildBoundedBox(target, gpa, world_map, id, bounds, id.faceTextures(), pos, origin, options);
        }
        return;
    }

    if (id.shape() == .bed) {
        try buildBed(target, gpa, world_map, id, metadata, pos, origin, options);
        return;
    }

    if (id.isCake()) {
        const bounds = world.block.cakeBounds(metadata);
        const textures = world.block.cakeTextures(metadata);
        try buildBoundedBox(target, gpa, world_map, id, bounds, textures, pos, origin, options);
        return;
    }

    if (id.isLiquid()) {
        try buildFluid(target, gpa, world_map, id, pos, origin, options);
        return;
    }

    var textures = id.faceTextures();
    if (id == .log) {
        const side_tile = world.block.logSideTile(metadata);
        textures.set(.north, side_tile);
        textures.set(.south, side_tile);
        textures.set(.west, side_tile);
        textures.set(.east, side_tile);
    } else if (id == .leaves) {
        textures = world.block.FaceTextures.initFill(world.block.leafTile(metadata, options.fancy));
    } else if (id == .wool) {
        textures = world.block.FaceTextures.initFill(world.block.woolTile(metadata));
    } else if (id == .slab or id == .slab_double) {
        textures = world.block.slabTextures(metadata);
    } else if (id == .furnace or id == .burning_furnace) {
        textures = world.block.furnaceTextures(id, metadata);
    } else if (id == .dispenser) {
        textures = world.block.dispenserTextures(metadata);
    } else if (id == .pumpkin or id == .jack_o_lantern) {
        textures = world.block.pumpkinTextures(id, metadata);
    } else if (id == .chest) {
        textures = world.block.chestTextures(chestRing(world_map, pos));
    } else if (id == .locked_chest) {
        textures = world.block.lockedChestTextures(chestRing(world_map, pos));
    } else if (id == .farmland) {
        textures = world.block.farmlandTextures(metadata);
    } else if (id == .grass) {
        const above = world_map.getBlock(pos.offset(0, 1, 0));
        const side_tile = world.block.grassSideTile(above);
        textures.set(.north, side_tile);
        textures.set(.south, side_tile);
        textures.set(.west, side_tile);
        textures.set(.east, side_tile);
    }
    textures = texturesFor(options, textures);

    const height_scale = id.heightScale();
    const inset = id.sideInset();

    for (faces) |face| {
        const nx = pos.x + face.normal[0];
        const ny = pos.y + face.normal[1];
        const nz = pos.z + face.normal[2];
        if (!showsFace(options, world_map, id, .init(nx, ny, nz), face.side)) continue;

        const tile = textures.get(face.side);
        var positions: [4][3]f32 = undefined;
        for (face.corners, 0..) |corner, i| {
            positions[i] = .{
                pulledInward(bx + corner[0], face.normal[0], inset),
                by + corner[1] * height_scale,
                pulledInward(bz + corner[2], face.normal[2], inset),
            };
        }
        const uvs = faceUvs(tile, face.side, height_scale);

        const tint = anaglyph.tint(options.anaglyph, blockTint(colorizer, id, metadata, face.side, climate.temperature, climate.humidity));
        const overlaid = options.fancy and id == .grass and tile == world.block.grass_side_tile;
        const overlay_uvs = faceUvs(world.block.grass_side_overlay_tile, face.side, height_scale);
        const overlay_tint = anaglyph.tint(options.anaglyph, colorizer.grassColor(climate.temperature, climate.humidity));

        if (options.smooth) {
            const corner_brightness = smoothBrightness(world_map, face, pos, emitted);
            var colors: [4][4]u8 = undefined;
            for (corner_brightness, 0..) |brightness, i| {
                colors[i] = shadeColor(face.shade * brightness, tint);
            }
            try target.quadShaded(gpa, positions, uvs, colors);

            if (overlaid) {
                var overlay_colors: [4][4]u8 = undefined;
                for (corner_brightness, 0..) |brightness, i| {
                    overlay_colors[i] = shadeColor(face.shade * brightness, overlay_tint);
                }
                try target.quadShaded(gpa, positions, overlay_uvs, overlay_colors);
            }
            continue;
        }

        const partial_top = face.side == world.Side.up and height_scale != 1.0 and !id.isLiquid();
        const brightness = if (partial_top)
            own_brightness
        else
            world.light.brightnessAt(world_map, .init(nx, ny, nz), emitted);

        try target.quad(gpa, positions, uvs, shadeColor(face.shade * brightness, tint));

        if (overlaid) {
            try target.quad(gpa, positions, overlay_uvs, shadeColor(face.shade * brightness, overlay_tint));
        }
    }
}

pub fn build(gpa: std.mem.Allocator, world_map: *const world.World, chunk: *const world.Chunk, colorizer: Colorizer, options: Options) !Mesh {
    var mesh: Mesh = .{};
    errdefer mesh.deinit(gpa);

    const view = world.ChunkView.around(world_map, chunk.x, chunk.z);

    const base_x = chunk.x * world.Chunk.width;
    const base_z = chunk.z * world.Chunk.width;

    for (0..world.Chunk.width) |lx| {
        for (0..world.Chunk.width) |lz| {
            const climate: Climate = .{
                .temperature = chunk.getTemperature(@intCast(lx), @intCast(lz)),
                .humidity = chunk.getHumidity(@intCast(lx), @intCast(lz)),
            };
            for (0..world.Chunk.height) |ly| {
                const id = chunk.getBlock(@intCast(lx), @intCast(ly), @intCast(lz));
                if (id == .air) continue;

                const bx: f32 = @floatFromInt(lx);
                const by: f32 = @floatFromInt(ly);
                const bz: f32 = @floatFromInt(lz);

                const metadata = chunk.getBlockMetadata(@intCast(lx), @intCast(ly), @intCast(lz));
                const target = if (id.isTranslucent()) &mesh.translucent else &mesh.solid;

                try buildBlockAt(
                    target,
                    gpa,
                    &view,
                    id,
                    metadata,
                    .init(base_x + @as(i32, @intCast(lx)), @intCast(ly), base_z + @as(i32, @intCast(lz))),
                    .{ bx, by, bz },
                    colorizer,
                    climate,
                    options,
                );
            }
        }
    }

    return mesh;
}

test "a chunk far from the origin keeps full precision block geometry" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    const far = @divFloor(@as(i32, 59999999), world.Chunk.width);
    const chunk = try world_map.createChunk(far, far);
    chunk.setBlock(1, 1, 1, .stone);

    try world.light.relightChunk(gpa, &world_map, far, far);
    var mesh = try build(gpa, &world_map, world_map.getChunk(far, far).?, Colorizer.untinted, .{});
    defer mesh.deinit(gpa);

    var low: f32 = std.math.floatMax(f32);
    var high: f32 = -std.math.floatMax(f32);
    for (mesh.solid.vertices.items) |vertex| {
        low = @min(low, vertex.x);
        high = @max(high, vertex.x);
    }

    try std.testing.expectEqual(@as(usize, 6 * 4), mesh.solid.vertices.items.len);
    try std.testing.expectEqual(@as(f32, 1.0), low);
    try std.testing.expectEqual(@as(f32, 2.0), high);
}

test "a block enclosed far from the origin still culls every face" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    const far = @divFloor(@as(i32, 59999999), world.Chunk.width);
    const chunk = try world_map.createChunk(far, far);
    for (1..4) |x| {
        for (1..4) |y| {
            for (1..4) |z| chunk.setBlock(@intCast(x), @intCast(y), @intCast(z), .stone);
        }
    }

    try world.light.relightChunk(gpa, &world_map, far, far);
    var mesh = try build(gpa, &world_map, world_map.getChunk(far, far).?, Colorizer.untinted, .{});
    defer mesh.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 6 * 9 * 4), mesh.solid.vertices.items.len);
}

test "a cross-shaped plant emits both faces of both diagonals so culling keeps it visible" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlock(0, 0, 0, .tall_grass);

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?, Colorizer.untinted, .{});
    defer mesh.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 4 * 4), mesh.solid.vertices.items.len);
}

test "a solid neighbor does not cull a cross-shaped plant" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlock(0, 0, 0, .stone);
    chunk.setBlock(1, 0, 0, .tall_grass);

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?, Colorizer.untinted, .{});
    defer mesh.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 6 * 4 + 4 * 4), mesh.solid.vertices.items.len);
}

test "a snow layer renders as a thin partial-height cube" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlock(0, 1, 0, .stone);
    chunk.setBlock(0, 2, 0, .snow_layer);

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?, Colorizer.untinted, .{});
    defer mesh.deinit(gpa);

    var max_y: f32 = 0;
    for (mesh.solid.vertices.items) |v| {
        if (v.y > 2.0 and v.y < 3.0) max_y = @max(max_y, v.y);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 2.125), max_y, 1.0e-5);
}

test "a nether chunk meshes into lit geometry rather than a black wall" {
    const gpa = std.testing.allocator;
    var generator = try world.NetherGenerator.init(gpa, 12345);
    defer generator.deinit(gpa);

    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.getOrGenerateChunk(&generator, 0, 0);
    chunk.setBlock(8, 40, 8, .air);
    chunk.setBlock(8, 41, 8, .glowstone);

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    var mesh = try build(gpa, &world_map, chunk, Colorizer.untinted, .{});
    defer mesh.deinit(gpa);

    try std.testing.expect(mesh.solid.vertices.items.len > 0);

    var brightest: u8 = 0;
    for (mesh.solid.vertices.items) |v| brightest = @max(brightest, v.color[0]);
    try std.testing.expect(brightest > 200);
}

test "a cactus pulls its four sides in by a sixteenth and keeps its top and bottom full" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlock(8, 0, 8, .cactus);

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?, Colorizer.untinted, .{});
    defer mesh.deinit(gpa);

    const near: f32 = 8.0 + 1.0 / 16.0;
    const far: f32 = 9.0 - 1.0 / 16.0;

    for (mesh.solid.vertices.items[0..8]) |v| {
        try std.testing.expect(v.x == 8.0 or v.x == 9.0);
        try std.testing.expect(v.z == 8.0 or v.z == 9.0);
    }
    for (mesh.solid.vertices.items[2 * 4 ..][0..4]) |v| {
        try std.testing.expectApproxEqAbs(near, v.z, 1.0e-6);
        try std.testing.expect(v.x == 8.0 or v.x == 9.0);
        try std.testing.expect(v.y == 0.0 or v.y == 1.0);
    }
    for (mesh.solid.vertices.items[3 * 4 ..][0..4]) |v| try std.testing.expectApproxEqAbs(far, v.z, 1.0e-6);
    for (mesh.solid.vertices.items[4 * 4 ..][0..4]) |v| try std.testing.expectApproxEqAbs(near, v.x, 1.0e-6);
    for (mesh.solid.vertices.items[5 * 4 ..][0..4]) |v| try std.testing.expectApproxEqAbs(far, v.x, 1.0e-6);
}

test "a cactus leaves the top face of the sand under it visible" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlock(8, 0, 8, .sand);
    chunk.setBlock(8, 1, 8, .cactus);

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?, Colorizer.untinted, .{});
    defer mesh.deinit(gpa);

    try std.testing.expectEqual(@as(usize, (6 + 5) * 4), mesh.solid.vertices.items.len);
}

test "a lone block emits all 6 faces" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlock(0, 0, 0, .stone);

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?, Colorizer.untinted, .{});
    defer mesh.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 6 * 4), mesh.solid.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 6 * 6), mesh.solid.indices.items.len);
}

test "each cube face carries its own directional shade" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlock(8, 0, 8, .stone);

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?, Colorizer.untinted, .{});
    defer mesh.deinit(gpa);

    const expected = [6]u8{ 6, 255, 204, 204, 153, 153 };
    for (expected, 0..) |level, face| {
        for (mesh.solid.vertices.items[face * 4 ..][0..4]) |v| {
            try std.testing.expectEqual([4]u8{ level, level, level, 255 }, v.color);
        }
    }
}

test "a cross-shaped plant is not directionally shaded" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlock(0, 0, 0, .rose);

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?, Colorizer.untinted, .{});
    defer mesh.deinit(gpa);

    for (mesh.solid.vertices.items) |v| {
        try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, v.color);
    }
}

test "adjacent blocks cull their shared face" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlock(0, 0, 0, .stone);
    chunk.setBlock(1, 0, 0, .stone);

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?, Colorizer.untinted, .{});
    defer mesh.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 10 * 4), mesh.solid.vertices.items.len);
}

test "an all-air chunk produces an empty mesh" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    _ = try world_map.createChunk(0, 0);

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?, Colorizer.untinted, .{});
    defer mesh.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), mesh.solid.vertices.items.len);
}

test "a block at a chunk boundary culls its face against a loaded neighbor chunk" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const a = try world_map.createChunk(0, 0);
    a.setBlock(15, 0, 0, .stone);
    const b = try world_map.createChunk(1, 0);
    b.setBlock(0, 0, 0, .stone);

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?, Colorizer.untinted, .{});
    defer mesh.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 5 * 4), mesh.solid.vertices.items.len);
}

test "only the grass block's top face takes the biome tint" {
    const gpa = std.testing.allocator;
    const table = try gpa.alloc([3]u8, 256 * 256);
    defer gpa.free(table);
    @memset(table, .{ 100, 200, 50 });
    const colorizer: Colorizer = .{ .grass = table, .foliage = table };

    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlock(8, 0, 8, .grass);

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?, colorizer, .{});
    defer mesh.deinit(gpa);

    try std.testing.expectEqual([4]u8{ 100, 200, 50, 255 }, mesh.solid.vertices.items[1 * 4].color);
    try std.testing.expectEqual([4]u8{ 204, 204, 204, 255 }, mesh.solid.vertices.items[2 * 4].color);
}

test "birch leaves take the fixed foliage color instead of the biome lookup" {
    const gpa = std.testing.allocator;
    const table = try gpa.alloc([3]u8, 256 * 256);
    defer gpa.free(table);
    @memset(table, .{ 100, 200, 50 });
    const colorizer: Colorizer = .{ .grass = table, .foliage = table };

    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlock(8, 0, 8, .leaves);
    chunk.setBlockMetadata(8, 0, 8, 2);
    chunk.setBlock(11, 0, 11, .leaves);

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?, colorizer, .{});
    defer mesh.deinit(gpa);

    const birch_top = mesh.solid.vertices.items[1 * 4].color;
    const oak_top = mesh.solid.vertices.items[(6 + 1) * 4].color;
    try std.testing.expectEqual([4]u8{ Colorizer.birch[0], Colorizer.birch[1], Colorizer.birch[2], 255 }, birch_top);
    try std.testing.expectEqual([4]u8{ 100, 200, 50, 255 }, oak_top);
}

test "water builds into the translucent pass, not the solid one" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlock(8, 0, 8, .stationary_water);

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?, Colorizer.untinted, .{});
    defer mesh.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), mesh.solid.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 6 * 4), mesh.translucent.vertices.items.len);
}

test "touching water faces are culled but the surface between water and air is not" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlock(8, 0, 8, .stationary_water);
    chunk.setBlock(8, 1, 8, .stationary_water);

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?, Colorizer.untinted, .{});
    defer mesh.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 10 * 4), mesh.translucent.vertices.items.len);
}

test "a solid block keeps the face it shares with water" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlock(8, 0, 8, .stone);
    chunk.setBlock(8, 1, 8, .stationary_water);

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?, Colorizer.untinted, .{});
    defer mesh.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 6 * 4), mesh.solid.vertices.items.len);
}

test "fancy leaves keep the face two leaf blocks share, fast leaves cull it" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlock(8, 0, 8, .leaves);
    chunk.setBlock(9, 0, 8, .leaves);
    try world.light.relightChunk(gpa, &world_map, 0, 0);

    var fast = try build(gpa, &world_map, world_map.getChunk(0, 0).?, Colorizer.untinted, .{});
    defer fast.deinit(gpa);
    var fancy = try build(gpa, &world_map, world_map.getChunk(0, 0).?, Colorizer.untinted, .{ .fancy = true });
    defer fancy.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 10 * 4), fast.solid.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 12 * 4), fancy.solid.vertices.items.len);
}

test "leaves never cull a neighbouring block's face" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlock(8, 0, 8, .stone);
    chunk.setBlock(9, 0, 8, .leaves);
    try world.light.relightChunk(gpa, &world_map, 0, 0);

    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?, Colorizer.untinted, .{ .fancy = true });
    defer mesh.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 11 * 4), mesh.solid.vertices.items.len);
}

test "an unobstructed face lights all four corners the same" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlock(8, 0, 8, .stone);

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    const view = world.ChunkView.around(&world_map, 0, 0);
    const corners = smoothBrightness(&view, faces[@intFromEnum(world.Side.up)], .init(8, 0, 8), 0);
    for (corners) |corner| try std.testing.expectApproxEqAbs(@as(f32, 1.0), corner, 1.0e-6);
}

test "a block beside the face darkens the two corners nearest it" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlock(8, 0, 8, .stone);
    chunk.setBlock(9, 1, 8, .stone);

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    const view = world.ChunkView.around(&world_map, 0, 0);
    const corners = smoothBrightness(&view, faces[@intFromEnum(world.Side.up)], .init(8, 0, 8), 0);

    try std.testing.expectApproxEqAbs(@as(f32, 1.0), corners[3], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), corners[2], 1.0e-6);
    try std.testing.expect(corners[1] < 1.0);
    try std.testing.expect(corners[0] < 1.0);
    try std.testing.expectApproxEqAbs(corners[1], corners[0], 1.0e-6);
}

test "a diagonal block darkens only the corner it touches" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlock(8, 0, 8, .stone);
    chunk.setBlock(9, 1, 9, .stone);

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    const view = world.ChunkView.around(&world_map, 0, 0);
    const corners = smoothBrightness(&view, faces[@intFromEnum(world.Side.up)], .init(8, 0, 8), 0);

    const dark = world.light.brightnessAt(&world_map, .init(9, 1, 9), 0);
    try std.testing.expectApproxEqAbs((3.0 + dark) / 4.0, corners[0], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), corners[3], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), corners[2], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), corners[1], 1.0e-6);
}

test "two solid edges hide whatever is diagonally behind them" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlock(8, 0, 8, .stone);
    chunk.setBlock(9, 1, 8, .stone);
    chunk.setBlock(8, 1, 9, .stone);

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    const view = world.ChunkView.around(&world_map, 0, 0);
    const corners = smoothBrightness(&view, faces[@intFromEnum(world.Side.up)], .init(8, 0, 8), 0);

    const dark = world.light.brightnessAt(&world_map, .init(9, 1, 8), 0);
    try std.testing.expect(world.light.brightnessAt(&world_map, .init(9, 1, 9), 0) > dark);
    try std.testing.expectApproxEqAbs((1.0 + 3.0 * dark) / 4.0, corners[0], 1.0e-6);
}

test "a seam face needs its neighbour lit before it shades correctly" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    const near = try world_map.createChunk(0, 0);
    const far = try world_map.createChunk(1, 0);
    for (0..world.Chunk.width) |x| {
        for (0..world.Chunk.width) |z| {
            near.setBlock(@intCast(x), 0, @intCast(z), .stone);
            far.setBlock(@intCast(x), 0, @intCast(z), .stone);
        }
    }

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    const view = world.ChunkView.around(&world_map, 0, 0);
    const unlit_neighbour = smoothBrightness(&view, faces[@intFromEnum(world.Side.up)], .init(15, 0, 8), 0);
    try std.testing.expect(unlit_neighbour[1] < 1.0);
    try std.testing.expect(unlit_neighbour[0] < 1.0);

    try world.light.relightChunk(gpa, &world_map, 1, 0);
    const lit_neighbour = smoothBrightness(&view, faces[@intFromEnum(world.Side.up)], .init(15, 0, 8), 0);
    const interior = smoothBrightness(&view, faces[@intFromEnum(world.Side.up)], .init(8, 0, 8), 0);
    for (lit_neighbour, interior) |seam, inside| {
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), seam, 1.0e-6);
        try std.testing.expectApproxEqAbs(inside, seam, 1.0e-6);
    }
}

test "smooth lighting varies a face's vertex colors, flat lighting does not" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlock(8, 0, 8, .stone);
    chunk.setBlock(9, 1, 8, .stone);
    try world.light.relightChunk(gpa, &world_map, 0, 0);

    var flat = try build(gpa, &world_map, world_map.getChunk(0, 0).?, Colorizer.untinted, .{});
    defer flat.deinit(gpa);
    var smooth = try build(gpa, &world_map, world_map.getChunk(0, 0).?, Colorizer.untinted, .{ .smooth = true });
    defer smooth.deinit(gpa);

    try std.testing.expectEqual(flat.solid.vertices.items.len, smooth.solid.vertices.items.len);
    try std.testing.expect(!uniformQuads(smooth.solid));
    try std.testing.expect(uniformQuads(flat.solid));
}

fn uniformQuads(mesh: MeshBuilder) bool {
    var i: usize = 0;
    while (i < mesh.vertices.items.len) : (i += 4) {
        const first = mesh.vertices.items[i].color;
        for (mesh.vertices.items[i .. i + 4]) |vertex| {
            if (!std.mem.eql(u8, &first, &vertex.color)) return false;
        }
    }
    return true;
}

test "a water surface surrounded by sources sits one ninth below the block top" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    for (7..10) |x| {
        for (7..10) |z| chunk.setBlock(@intCast(x), 0, @intCast(z), .stationary_water);
    }

    const view = world.ChunkView.around(&world_map, 0, 0);
    const height = fluidCornerHeight(&view, .init(8, 0, 8), world.Material.water);
    try std.testing.expectApproxEqAbs(@as(f32, 8.0 / 9.0), height, 1.0e-6);
}

test "water under more water fills its block completely" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlock(8, 0, 8, .stationary_water);
    chunk.setBlock(8, 1, 8, .stationary_water);

    const view = world.ChunkView.around(&world_map, 0, 0);
    try std.testing.expectEqual(@as(f32, 1.0), fluidCornerHeight(&view, .init(8, 0, 8), world.Material.water));
}

test "a shallower flowing block pulls the surface corner it shares down" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    for (7..10) |x| {
        for (7..10) |z| chunk.setBlock(@intCast(x), 0, @intCast(z), .stationary_water);
    }
    chunk.setBlockMetadata(9, 0, 9, 6);

    const view = world.ChunkView.around(&world_map, 0, 0);
    const shared = fluidCornerHeight(&view, .init(9, 0, 9), world.Material.water);
    const away = fluidCornerHeight(&view, .init(8, 0, 8), world.Material.water);
    try std.testing.expect(shared < away);
}

test "a flowing surface slopes across the block, a level one does not" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlock(7, 1, 8, .stone);
    for (8..12) |x| {
        chunk.setBlock(@intCast(x), 0, 8, .stone);
        chunk.setBlock(@intCast(x), 1, 8, .stationary_water);
        chunk.setBlockMetadata(@intCast(x), 1, 8, @intCast(x - 8));
    }

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?, Colorizer.untinted, .{});
    defer mesh.deinit(gpa);

    var lowest: f32 = 100;
    var highest: f32 = -100;
    for (mesh.translucent.vertices.items) |vertex| {
        if (vertex.y <= 1.0) continue;
        lowest = @min(lowest, vertex.y);
        highest = @max(highest, vertex.y);
    }
    try std.testing.expect(highest - lowest > 0.05);
    try std.testing.expect(highest < 2.0);
}

fn torchMesh(gpa: std.mem.Allocator, world_map: *world.World, metadata: u4) !Mesh {
    const chunk = world_map.getChunk(0, 0).?;
    chunk.setBlock(8, 1, 8, .torch);
    chunk.setBlockMetadata(8, 1, 8, metadata);
    try world.light.relightChunk(gpa, world_map, 0, 0);
    return build(gpa, world_map, world_map.getChunk(0, 0).?, Colorizer.untinted, .{});
}

fn fireMesh(gpa: std.mem.Allocator, world_map: *world.World, ground: world.Block) !Mesh {
    const chunk = world_map.getChunk(0, 0).?;
    chunk.setBlock(8, 1, 8, ground);
    chunk.setBlock(8, 2, 8, .fire);
    try world.light.relightChunk(gpa, world_map, 0, 0);
    return build(gpa, world_map, world_map.getChunk(0, 0).?, Colorizer.untinted, .{});
}

fn spanOf(mesh: Mesh, axis: u2) [2]f32 {
    var lowest: f32 = std.math.floatMax(f32);
    var highest: f32 = -std.math.floatMax(f32);
    for (mesh.solid.vertices.items) |v| {
        const value = switch (axis) {
            0 => v.x,
            1 => v.y,
            else => v.z,
        };
        lowest = @min(lowest, value);
        highest = @max(highest, value);
    }
    return .{ lowest, highest };
}

test "a torch is a tip quad plus four sides, and burns at full brightness" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    _ = try world_map.createChunk(0, 0);

    var mesh = try torchMesh(gpa, &world_map, 5);
    defer mesh.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 5 * 4), mesh.solid.vertices.items.len);
    for (mesh.solid.vertices.items) |v| {
        try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, v.color);
    }
}

test "a standing torch is centred in its block and reaches its tip at ten sixteenths" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    _ = try world_map.createChunk(0, 0);

    var mesh = try torchMesh(gpa, &world_map, 5);
    defer mesh.deinit(gpa);

    const across = spanOf(mesh, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 8.0), across[0], 1.0e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 9.0), across[1], 1.0e-5);
    try std.testing.expectEqual(across, spanOf(mesh, 2));

    const upright = spanOf(mesh, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), upright[0], 1.0e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), upright[1], 1.0e-5);

    for (mesh.solid.vertices.items[0..4]) |v| {
        try std.testing.expectApproxEqAbs(@as(f32, 1.0) + torch_tip, v.y, 1.0e-5);
    }
}

test "a wall torch shifts toward its wall and leans its foot further into it" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    _ = try world_map.createChunk(0, 0);

    var west = try torchMesh(gpa, &world_map, 1);
    defer west.deinit(gpa);
    const along_west = spanOf(west, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 7.5), along_west[0], 1.0e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 8.9), along_west[1], 1.0e-5);

    var east = try torchMesh(gpa, &world_map, 2);
    defer east.deinit(gpa);
    const along_east = spanOf(east, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 8.1), along_east[0], 1.0e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 9.5), along_east[1], 1.0e-5);

    var north = try torchMesh(gpa, &world_map, 3);
    defer north.deinit(gpa);
    try std.testing.expectEqual(along_west, spanOf(north, 2));

    var south = try torchMesh(gpa, &world_map, 4);
    defer south.deinit(gpa);
    try std.testing.expectEqual(along_east, spanOf(south, 2));
}

test "a wall torch is lifted so its foot meets the wall above the floor" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    _ = try world_map.createChunk(0, 0);

    var mesh = try torchMesh(gpa, &world_map, 1);
    defer mesh.deinit(gpa);

    const upright = spanOf(mesh, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 1.2), upright[0], 1.0e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 2.2), upright[1], 1.0e-5);
}

test "a torch samples only its own tile, with the tip taking the flame end of it" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    _ = try world_map.createChunk(0, 0);

    var mesh = try torchMesh(gpa, &world_map, 5);
    defer mesh.deinit(gpa);

    const uv = Atlas.tileUv(world.Block.torch.faceTextures().get(.down));
    for (mesh.solid.vertices.items) |v| {
        try std.testing.expect(v.u >= uv.u0 - 1.0e-6 and v.u <= uv.u1 + 1.0e-6);
        try std.testing.expect(v.v >= uv.v0 - 1.0e-6 and v.v <= uv.v1 + 1.0e-6);
    }
    for (mesh.solid.vertices.items[0..4]) |v| {
        try std.testing.expect(v.u >= uv.u0 + 7.0 / 256.0 - 1.0e-6);
        try std.testing.expect(v.u <= uv.u0 + 9.0 / 256.0 + 1.0e-6);
    }
}

test "fancy graphics lays a biome-tinted overlay over each grass side" {
    const gpa = std.testing.allocator;
    const table = try gpa.alloc([3]u8, 256 * 256);
    defer gpa.free(table);
    @memset(table, .{ 100, 200, 50 });
    const colorizer: Colorizer = .{ .grass = table, .foliage = table };

    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlock(8, 0, 8, .grass);

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    var plain = try build(gpa, &world_map, world_map.getChunk(0, 0).?, colorizer, .{});
    defer plain.deinit(gpa);
    var fancy = try build(gpa, &world_map, world_map.getChunk(0, 0).?, colorizer, .{ .fancy = true });
    defer fancy.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 6 * 4), plain.solid.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 10 * 4), fancy.solid.vertices.items.len);

    const overlay = Atlas.tileUv(world.block.grass_side_overlay_tile);
    const first_overlay = fancy.solid.vertices.items[3 * 4];
    try std.testing.expectApproxEqAbs(overlay.u1, first_overlay.u, 1.0e-6);
    try std.testing.expectEqual(shadeColor(0.8, .{ 100, 200, 50 }), first_overlay.color);
    try std.testing.expectEqual(shadeColor(0.8, Colorizer.white), fancy.solid.vertices.items[2 * 4].color);
}

test "snow on top swaps the grass sides for the snow side, overlay and all" {
    const gpa = std.testing.allocator;
    const table = try gpa.alloc([3]u8, 256 * 256);
    defer gpa.free(table);
    @memset(table, .{ 100, 200, 50 });
    const colorizer: Colorizer = .{ .grass = table, .foliage = table };

    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlock(8, 0, 8, .grass);
    chunk.setBlock(8, 1, 8, .snow_layer);

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?, colorizer, .{ .fancy = true });
    defer mesh.deinit(gpa);

    const snow_side = Atlas.tileUv(world.block.grassSideTile(.snow_layer));
    var sides: usize = 0;
    for (mesh.solid.vertices.items) |vertex| {
        if (vertex.v >= snow_side.v0 - 1.0e-6 and vertex.v <= snow_side.v1 + 1.0e-6 and
            vertex.u >= snow_side.u0 - 1.0e-6 and vertex.u <= snow_side.u1 + 1.0e-6)
        {
            sides += 1;
        }
    }
    try std.testing.expect(sides >= 4 * 4);

    const overlay = Atlas.tileUv(world.block.grass_side_overlay_tile);
    for (mesh.solid.vertices.items) |vertex| {
        const on_overlay = vertex.u >= overlay.u0 - 1.0e-6 and vertex.u <= overlay.u1 + 1.0e-6 and
            vertex.v >= overlay.v0 - 1.0e-6 and vertex.v <= overlay.v1 + 1.0e-6;
        try std.testing.expect(!on_overlay);
    }
}

test "a snow layer's sides show only the bottom slice of its texture" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlock(0, 1, 0, .stone);
    chunk.setBlock(0, 2, 0, .snow_layer);

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?, Colorizer.untinted, .{});
    defer mesh.deinit(gpa);

    const uv = Atlas.tileUv(world.Block.snow_layer.faceTextures().get(.north));
    const slice = uv.v1 - (uv.v1 - uv.v0) * world.Block.snow_layer.heightScale();

    var sides: usize = 0;
    var quad: usize = 0;
    while (quad * 4 < mesh.solid.vertices.items.len) : (quad += 1) {
        const corners = mesh.solid.vertices.items[quad * 4 ..][0..4];

        var spans_snow = false;
        for (corners) |corner| spans_snow = spans_snow or corner.y == 2.125;
        if (!spans_snow) continue;

        var upright = false;
        for (corners) |corner| upright = upright or corner.y == 2.0;
        if (!upright) continue;

        sides += 1;
        for (corners) |corner| {
            const want = if (corner.y == 2.0) uv.v1 else slice;
            try std.testing.expectApproxEqAbs(want, corner.v, 1.0e-6);
        }
    }
    try std.testing.expectEqual(@as(usize, 4), sides);
}

fn doorMesh(gpa: std.mem.Allocator, world_map: *world.World, metadata: u4) !Mesh {
    const chunk = world_map.getChunk(0, 0).?;
    chunk.setBlock(8, 1, 8, .door_wood);
    chunk.setBlockMetadata(8, 1, 8, metadata);
    try world.light.relightChunk(gpa, world_map, 0, 0);
    return build(gpa, world_map, world_map.getChunk(0, 0).?, Colorizer.untinted, .{});
}

test "a door keeps all six faces, thin across the way it hangs" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    _ = try world_map.createChunk(0, 0);

    var mesh = try doorMesh(gpa, &world_map, 1);
    defer mesh.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 6 * 4), mesh.solid.vertices.items.len);

    const across = spanOf(mesh, 2);
    try std.testing.expectApproxEqAbs(@as(f32, 8.0), across[0], 1.0e-5);
    try std.testing.expectApproxEqAbs(8.0 + world.block.door_thickness, across[1], 1.0e-5);

    const along = spanOf(mesh, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 8.0), along[0], 1.0e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 9.0), along[1], 1.0e-5);

    const upright = spanOf(mesh, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), upright[0], 1.0e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), upright[1], 1.0e-5);
}

test "opening a door swings its mesh onto the other axis" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    _ = try world_map.createChunk(0, 0);

    var mesh = try doorMesh(gpa, &world_map, 1 | world.block.door_open_bit);
    defer mesh.deinit(gpa);

    const across = spanOf(mesh, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 9.0) - world.block.door_thickness, across[0], 1.0e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 9.0), across[1], 1.0e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), spanOf(mesh, 2)[1] - spanOf(mesh, 2)[0], 1.0e-5);
}

test "a door's narrow sides sample only the slice of the tile they cover" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    _ = try world_map.createChunk(0, 0);

    var mesh = try doorMesh(gpa, &world_map, 1);
    defer mesh.deinit(gpa);

    const uv = Atlas.tileUv(world.Block.door_wood.faceTextures().get(.north));
    const slice = (uv.u1 - uv.u0) * world.block.door_thickness;

    const west = mesh.solid.vertices.items[4 * 4 ..][0..4];
    var lowest: f32 = std.math.floatMax(f32);
    var highest: f32 = -std.math.floatMax(f32);
    for (west) |vertex| {
        try std.testing.expect(vertex.u >= uv.u0 - 1.0e-6 and vertex.u <= uv.u1 + 1.0e-6);
        lowest = @min(lowest, vertex.u);
        highest = @max(highest, vertex.u);
    }
    try std.testing.expectApproxEqAbs(slice, highest - lowest, 1.0e-6);
}

fn uvAtLowestX(quad: []const MeshBuilder.Vertex) f32 {
    var lowest = quad[0];
    for (quad) |vertex| {
        if (vertex.x < lowest.x) lowest = vertex;
    }
    return lowest.u;
}

test "a door's two faces keep the same side of the tile facing the same way" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    _ = try world_map.createChunk(0, 0);

    var mesh = try doorMesh(gpa, &world_map, 1);
    defer mesh.deinit(gpa);

    const uv = Atlas.tileUv(world.Block.door_wood.faceTextures().get(.north));
    const north = uvAtLowestX(mesh.solid.vertices.items[2 * 4 ..][0..4]);
    const south = uvAtLowestX(mesh.solid.vertices.items[3 * 4 ..][0..4]);

    try std.testing.expectApproxEqAbs(uv.u1, north, 1.0e-6);
    try std.testing.expectApproxEqAbs(uv.u1, south, 1.0e-6);
}

fn trapdoorMesh(gpa: std.mem.Allocator, world_map: *world.World, metadata: u4, options: Options) !Mesh {
    const chunk = world_map.getChunk(0, 0).?;
    chunk.setBlock(8, 1, 8, .trapdoor);
    chunk.setBlockMetadata(8, 1, 8, metadata);
    try world.light.relightChunk(gpa, world_map, 0, 0);
    return build(gpa, world_map, world_map.getChunk(0, 0).?, Colorizer.untinted, options);
}

test "a shut trapdoor is a slab across the floor of its block" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    _ = try world_map.createChunk(0, 0);

    var mesh = try trapdoorMesh(gpa, &world_map, 0, .{});
    defer mesh.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 6 * 4), mesh.solid.vertices.items.len);

    const upright = spanOf(mesh, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), upright[0], 1.0e-5);
    try std.testing.expectApproxEqAbs(1.0 + world.block.trapdoor_thickness, upright[1], 1.0e-5);

    for ([_]u2{ 0, 2 }) |axis| {
        const across = spanOf(mesh, axis);
        try std.testing.expectApproxEqAbs(@as(f32, 8.0), across[0], 1.0e-5);
        try std.testing.expectApproxEqAbs(@as(f32, 9.0), across[1], 1.0e-5);
    }
}

test "an open trapdoor stands upright against its wall" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    _ = try world_map.createChunk(0, 0);

    var mesh = try trapdoorMesh(gpa, &world_map, world.block.trapdoor_open_bit, .{});
    defer mesh.deinit(gpa);

    const upright = spanOf(mesh, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), upright[0], 1.0e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), upright[1], 1.0e-5);

    const across = spanOf(mesh, 2);
    try std.testing.expectApproxEqAbs(9.0 - world.block.trapdoor_thickness, across[0], 1.0e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 9.0), across[1], 1.0e-5);
}

test "a trapdoor keeps the faces that stop short of the block, and culls the rest" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlock(8, 0, 8, .stone);
    chunk.setBlock(8, 2, 8, .stone);

    var mesh = try trapdoorMesh(gpa, &world_map, 0, .{});
    defer mesh.deinit(gpa);

    try std.testing.expectEqual(@as(usize, (6 + 6 + 5) * 4), mesh.solid.vertices.items.len);

    var lowest: f32 = std.math.floatMax(f32);
    for (mesh.solid.vertices.items) |vertex| {
        if (vertex.y > 1.0 and vertex.y < 2.0) lowest = @min(lowest, vertex.y);
    }
    try std.testing.expectApproxEqAbs(1.0 + world.block.trapdoor_thickness, lowest, 1.0e-5);
}

test "a trapdoor's sides show only the slice of the tile they cover" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    _ = try world_map.createChunk(0, 0);

    var mesh = try trapdoorMesh(gpa, &world_map, 0, .{});
    defer mesh.deinit(gpa);

    const uv = Atlas.tileUv(world.Block.trapdoor.faceTextures().get(.north));
    const slice = (uv.v1 - uv.v0) * world.block.trapdoor_thickness;

    const north = mesh.solid.vertices.items[2 * 4 ..][0..4];
    var lowest: f32 = std.math.floatMax(f32);
    var highest: f32 = -std.math.floatMax(f32);
    for (north) |vertex| {
        lowest = @min(lowest, vertex.v);
        highest = @max(highest, vertex.v);
    }
    try std.testing.expectApproxEqAbs(uv.v1, highest, 1.0e-6);
    try std.testing.expectApproxEqAbs(slice, highest - lowest, 1.0e-6);
}

test "a slab stands half a block tall and keeps its top face when buried" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlock(8, 1, 8, .slab);
    try world.light.relightChunk(gpa, &world_map, 0, 0);

    var open = try build(gpa, &world_map, chunk, Colorizer.untinted, .{});
    defer open.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 6 * 4), open.solid.vertices.items.len);

    var highest: f32 = -std.math.floatMax(f32);
    for (open.solid.vertices.items) |vertex| highest = @max(highest, vertex.y);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), highest, 1.0e-5);

    chunk.setBlock(8, 2, 8, .stone);
    try world.light.relightChunk(gpa, &world_map, 0, 0);
    var buried = try build(gpa, &world_map, chunk, Colorizer.untinted, .{});
    defer buried.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), topFaces(buried, 1.5));
    try std.testing.expectEqual(@as(usize, 1), topFaces(open, 1.5));
}

fn topFaces(mesh: Mesh, height: f32) usize {
    var count: usize = 0;
    var quad: usize = 0;
    while (quad * 4 < mesh.solid.vertices.items.len) : (quad += 1) {
        const corners = mesh.solid.vertices.items[quad * 4 ..][0..4];
        var flat = true;
        for (corners) |corner| flat = flat and corner.y == height;
        if (flat) count += 1;
    }
    return count;
}

test "slabs of one id hide the sides they share, unlike a slab beside a double slab" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlock(8, 1, 8, .slab);
    chunk.setBlock(9, 1, 8, .slab);
    try world.light.relightChunk(gpa, &world_map, 0, 0);

    var paired = try build(gpa, &world_map, chunk, Colorizer.untinted, .{});
    defer paired.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 10 * 4), paired.solid.vertices.items.len);

    chunk.setBlock(9, 1, 8, .slab_double);
    try world.light.relightChunk(gpa, &world_map, 0, 0);
    var mixed = try build(gpa, &world_map, chunk, Colorizer.untinted, .{});
    defer mixed.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 11 * 4), mixed.solid.vertices.items.len);
}

test "a slab's sides show the bottom half of the tile, as the double slab's seam requires" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlock(8, 1, 8, .slab);
    try world.light.relightChunk(gpa, &world_map, 0, 0);

    var mesh = try build(gpa, &world_map, chunk, Colorizer.untinted, .{});
    defer mesh.deinit(gpa);

    const uv = Atlas.tileUv(world.block.slabTextures(world.block.slab_stone).get(.north));
    const middle = uv.v1 - (uv.v1 - uv.v0) * 0.5;

    var sides: usize = 0;
    var quad: usize = 0;
    while (quad * 4 < mesh.solid.vertices.items.len) : (quad += 1) {
        const corners = mesh.solid.vertices.items[quad * 4 ..][0..4];
        var upright = false;
        for (corners) |corner| upright = upright or corner.y == 1.5;
        var grounded = false;
        for (corners) |corner| grounded = grounded or corner.y == 1.0;
        if (!upright or !grounded) continue;

        sides += 1;
        for (corners) |corner| {
            const want = if (corner.y == 1.0) uv.v1 else middle;
            try std.testing.expectApproxEqAbs(want, corner.v, 1.0e-6);
        }
    }
    try std.testing.expectEqual(@as(usize, 4), sides);
}

test "a slab in hand is the bottom half of its block, not a whole cube" {
    const boxes = world.Block.slab.itemRenderBoxes();
    try std.testing.expectEqual(@as(usize, 1), boxes.len);
    try std.testing.expectEqual([3]f32{ 0, 0, 0 }, boxes[0].min);
    try std.testing.expectEqual([3]f32{ 1, 0.5, 1 }, boxes[0].max);

    const whole: world.block.Bounds = .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 1 } };
    try std.testing.expectEqualSlices(world.block.Bounds, &.{whole}, world.Block.slab_double.itemRenderBoxes());

    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);
    try buildBoxCube(&mesh, gpa, .{ 0, 0, 0 }, 1.0, boxes[0], world.Block.slab.faceTextures(), 0.0, .{});

    var lowest: f32 = std.math.floatMax(f32);
    var highest: f32 = -std.math.floatMax(f32);
    for (mesh.vertices.items) |vertex| {
        lowest = @min(lowest, vertex.y);
        highest = @max(highest, vertex.y);
    }
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), lowest, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), highest, 1.0e-6);
}

test "a slab's metadata reaches the mesh as the texture it was cut from" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlock(8, 1, 8, .slab);
    chunk.setBlockMetadata(8, 1, 8, world.block.slab_wood);
    try world.light.relightChunk(gpa, &world_map, 0, 0);

    var mesh = try build(gpa, &world_map, chunk, Colorizer.untinted, .{});
    defer mesh.deinit(gpa);

    const uv = Atlas.tileUv(world.block.slabTextures(world.block.slab_wood).get(.up));
    var matched = false;
    for (mesh.solid.vertices.items) |vertex| {
        if (vertex.y == 1.5 and @abs(vertex.u - uv.u0) < 1.0e-6) matched = true;
    }
    try std.testing.expect(matched);
}

fn stairsMesh(gpa: std.mem.Allocator, world_map: *world.World, metadata: u4, options: Options) !Mesh {
    const chunk = world_map.getChunk(0, 0).?;
    chunk.setBlock(8, 1, 8, .stairs_cobblestone);
    chunk.setBlockMetadata(8, 1, 8, metadata);
    try world.light.relightChunk(gpa, world_map, 0, 0);
    return build(gpa, world_map, world_map.getChunk(0, 0).?, Colorizer.untinted, options);
}

test "a stair's inner faces are lit like the air around it, not black" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    for (0..16) |x| {
        for (0..16) |z| chunk.setBlock(@intCast(x), 0, @intCast(z), .stone);
    }

    var mesh = try stairsMesh(gpa, &world_map, 3, .{});
    defer mesh.deinit(gpa);

    var inner_riser: ?[4]u8 = null;
    var outer_wall: ?[4]u8 = null;

    var quad: usize = 0;
    while (quad * 4 < mesh.solid.vertices.items.len) : (quad += 1) {
        const corners = mesh.solid.vertices.items[quad * 4 ..][0..4];

        var above_floor = false;
        for (corners) |corner| above_floor = above_floor or corner.y > 1.0;
        if (!above_floor) continue;

        for (corners) |corner| {
            try std.testing.expect(corner.color[0] > 0);
        }

        var flat_z: ?f32 = corners[0].z;
        for (corners) |corner| {
            if (corner.z != corners[0].z) flat_z = null;
        }
        const plane = flat_z orelse continue;
        if (plane == 8.5) inner_riser = corners[0].color;
        if (plane == 8.0) outer_wall = corners[0].color;
    }

    try std.testing.expect(inner_riser != null);
    try std.testing.expect(outer_wall != null);
    try std.testing.expectEqual(outer_wall.?, inner_riser.?);
}

test "a stair in the open draws both of its halves" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    _ = try world_map.createChunk(0, 0);

    var mesh = try stairsMesh(gpa, &world_map, 3, .{});
    defer mesh.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 12 * 4), mesh.solid.vertices.items.len);

    var tread: f32 = std.math.floatMax(f32);
    var highest: f32 = -std.math.floatMax(f32);
    for (mesh.solid.vertices.items) |vertex| {
        if (vertex.y > 1.0) tread = @min(tread, vertex.y);
        highest = @max(highest, vertex.y);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), tread, 1.0e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), highest, 1.0e-5);
}

test "a stair turns its tall half to the side its metadata names" {
    const gpa = std.testing.allocator;

    for ([_]struct { meta: u4, axis: usize, near: bool }{
        .{ .meta = 0, .axis = 0, .near = false },
        .{ .meta = 1, .axis = 0, .near = true },
        .{ .meta = 2, .axis = 2, .near = false },
        .{ .meta = 3, .axis = 2, .near = true },
    }) |turn| {
        var world_map = world.World.init(gpa);
        defer world_map.deinit();
        _ = try world_map.createChunk(0, 0);

        var mesh = try stairsMesh(gpa, &world_map, turn.meta, .{});
        defer mesh.deinit(gpa);

        var lowest: f32 = std.math.floatMax(f32);
        var highest: f32 = -std.math.floatMax(f32);
        for (mesh.solid.vertices.items) |vertex| {
            if (vertex.y != 2.0) continue;
            const along = if (turn.axis == 0) vertex.x else vertex.z;
            lowest = @min(lowest, along);
            highest = @max(highest, along);
        }
        const base: f32 = if (turn.near) 8.0 else 8.5;
        try std.testing.expectApproxEqAbs(base, lowest, 1.0e-5);
        try std.testing.expectApproxEqAbs(base + 0.5, highest, 1.0e-5);
    }
}

test "a stair buried on every side still draws the faces that stop short of the block" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    for ([_][3]u8{ .{ 8, 0, 8 }, .{ 8, 2, 8 }, .{ 7, 1, 8 }, .{ 9, 1, 8 }, .{ 8, 1, 7 }, .{ 8, 1, 9 } }) |cell| {
        chunk.setBlock(cell[0], cell[1], cell[2], .stone);
    }

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    var walled = try build(gpa, &world_map, chunk, Colorizer.untinted, .{});
    defer walled.deinit(gpa);

    var mesh = try stairsMesh(gpa, &world_map, 3, .{});
    defer mesh.deinit(gpa);

    const stair_vertices = mesh.solid.vertices.items.len - walled.solid.vertices.items.len;
    try std.testing.expectEqual(@as(usize, 3 * 4), stair_vertices);

    var interior: usize = 0;
    for (mesh.solid.vertices.items) |vertex| {
        if (vertex.z == 8.5 or vertex.y == 1.5) interior += 1;
    }
    try std.testing.expectEqual(stair_vertices, interior);
}

test "smooth lighting reaches a trapdoor, unlike a door" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlock(9, 2, 8, .stone);

    var mesh = try trapdoorMesh(gpa, &world_map, 0, .{ .smooth = true });
    defer mesh.deinit(gpa);

    try std.testing.expect(!uniformQuads(mesh.solid));
}

test "a box with full bounds sits where the whole cube does, lit as an item rather than as terrain" {
    const gpa = std.testing.allocator;

    for ([_]world.Block{ .workbench, .cactus }) |id| {
        var cube: MeshBuilder = .{};
        defer cube.deinit(gpa);
        var box: MeshBuilder = .{};
        defer box.deinit(gpa);

        const textures = id.faceTextures();
        const inset = id.sideInset();
        try buildCube(&cube, gpa, .{ -0.5, -0.5, -0.5 }, .{ 0.5, 0.5, 0.5 }, textures, inset);
        try buildBoxCube(&box, gpa, .{ 0, 0, 0 }, 1.0, id.itemRenderBoxes()[0], textures, inset, .{});

        try std.testing.expectEqual(cube.vertices.items.len, box.vertices.items.len);
        for (cube.vertices.items, box.vertices.items) |a, b| {
            try std.testing.expectApproxEqAbs(a.x, b.x, 1.0e-6);
            try std.testing.expectApproxEqAbs(a.y, b.y, 1.0e-6);
            try std.testing.expectApproxEqAbs(a.z, b.z, 1.0e-6);
            try std.testing.expectApproxEqAbs(a.u, b.u, 1.0e-6);
            try std.testing.expectApproxEqAbs(a.v, b.v, 1.0e-6);
        }

        for (faces, 0..) |face, index| {
            const normal: [3]f32 = .{
                @floatFromInt(face.normal[0]),
                @floatFromInt(face.normal[1]),
                @floatFromInt(face.normal[2]),
            };
            const want = item_lighting.faceColor(.{}, normal);
            try std.testing.expectEqual(want, box.vertices.items[index * 4].color);
        }
    }
}

test "a trapdoor in hand is a plate through the middle of its block" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);

    const id = world.Block.trapdoor;
    try buildBoxCube(&mesh, gpa, .{ 0, 0, 0 }, 1.0, id.itemRenderBoxes()[0], id.faceTextures(), 0.0, .{});

    var lowest: f32 = std.math.floatMax(f32);
    var highest: f32 = -std.math.floatMax(f32);
    var widest: f32 = 0;
    for (mesh.vertices.items) |vertex| {
        lowest = @min(lowest, vertex.y);
        highest = @max(highest, vertex.y);
        widest = @max(widest, @abs(vertex.x));
    }
    try std.testing.expectApproxEqAbs(-world.block.trapdoor_thickness / 2.0, lowest, 1.0e-6);
    try std.testing.expectApproxEqAbs(world.block.trapdoor_thickness / 2.0, highest, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), widest, 1.0e-6);

    const uv = Atlas.tileUv(id.faceTextures().get(.north));
    const north = mesh.vertices.items[2 * 4 ..][0..4];
    var v_low: f32 = std.math.floatMax(f32);
    var v_high: f32 = -std.math.floatMax(f32);
    for (north) |vertex| {
        v_low = @min(v_low, vertex.v);
        v_high = @max(v_high, vertex.v);
    }
    try std.testing.expectApproxEqAbs((uv.v1 - uv.v0) * world.block.trapdoor_thickness, v_high - v_low, 1.0e-6);
}

fn meshExtent(mesh: MeshBuilder, axis: usize) [2]f32 {
    var low: f32 = std.math.floatMax(f32);
    var high: f32 = -std.math.floatMax(f32);
    for (mesh.vertices.items) |vertex| {
        const value = switch (axis) {
            0 => vertex.x,
            1 => vertex.y,
            else => vertex.z,
        };
        low = @min(low, value);
        high = @max(high, value);
    }
    return .{ low, high };
}

fn pistonHeadMesh(gpa: std.mem.Allocator, world_map: *world.World, metadata: u4, mesh: *MeshBuilder) !void {
    const view = world.ChunkView.around(world_map, 0, 0);
    try buildPistonHead(mesh, gpa, &view, .piston_head, metadata, .init(0, 0, 0), .{ 0, 0, 0 }, piston_shaft_length, .{});
}

test "the piston head is a plate with a shaft reaching back into the base" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    _ = try world_map.createChunk(0, 0);

    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);
    try pistonHeadMesh(gpa, &world_map, world.block.pistonFacingValue(.up), &mesh);

    const height = meshExtent(mesh, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), height[1], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 12.0 / 16.0 - 1.0), height[0], 1.0e-6);

    const across = meshExtent(mesh, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), across[0], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), across[1], 1.0e-6);
}

test "the head shaft is four pixels square whichever way it points" {
    for (std.enums.values(world.Side)) |facing| {
        const metadata = world.block.pistonFacingValue(facing);
        const shaft = pistonShaftBox(metadata, piston_shaft_length);

        const along = facing.step();
        for (0..3) |axis| {
            const span = shaft.max[axis] - shaft.min[axis];
            if (along[axis] != 0) {
                try std.testing.expectApproxEqAbs(piston_shaft_length, span, 1.0e-6);
            } else {
                try std.testing.expectApproxEqAbs(@as(f32, 4.0 / 16.0), span, 1.0e-6);
                try std.testing.expectApproxEqAbs(@as(f32, 0.5), (shaft.min[axis] + shaft.max[axis]) / 2.0, 1.0e-6);
            }
        }
    }
}

fn cornerAt(mesh: MeshBuilder, quad: usize, at: [3]f32) !MeshBuilder.Vertex {
    for (mesh.vertices.items[quad * 4 ..][0..4]) |corner| {
        if (@abs(corner.x - at[0]) < 1.0e-5 and @abs(corner.y - at[1]) < 1.0e-5 and @abs(corner.z - at[2]) < 1.0e-5) {
            return corner;
        }
    }
    return error.NoSuchCorner;
}

test "a bottom face runs its tile along +z, the way renderBottomFace lays it down" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);
    try buildCube(&mesh, gpa, .{ 0, 0, 0 }, .{ 1, 1, 1 }, world.block.FaceTextures.initFill(1), 0.0);

    const uv = Atlas.tileUv(1);
    try std.testing.expectApproxEqAbs(uv.v0, (try cornerAt(mesh, 0, .{ 0, 0, 0 })).v, 1.0e-6);
    try std.testing.expectApproxEqAbs(uv.v1, (try cornerAt(mesh, 0, .{ 0, 0, 1 })).v, 1.0e-6);
}

test "an extended east-facing piston lands its side tile exactly where RenderBlocks does" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    _ = try world_map.createChunk(0, 0);

    const metadata = world.block.pistonFacingValue(.east) | world.block.piston_flag;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);
    const view = world.ChunkView.around(&world_map, 0, 0);
    try buildBoundedBoxTurned(&mesh, gpa, &view, .piston, world.block.pistonBaseBounds(metadata), world.block.pistonBaseTextures(.piston, metadata), .east, .init(0, 0, 0), .{ 0, 0, 0 }, .{});

    const uv = Atlas.tileUv(world.block.piston_side_tile);
    const expected = [4]struct { at: [3]f32, pixel: [2]f32 }{
        .{ .at = .{ 0, 1, 0 }, .pixel = .{ 0, 16 } },
        .{ .at = .{ 0.75, 1, 0 }, .pixel = .{ 0, 4 } },
        .{ .at = .{ 0.75, 0, 0 }, .pixel = .{ 16, 4 } },
        .{ .at = .{ 0, 0, 0 }, .pixel = .{ 16, 16 } },
    };

    for (expected) |want| {
        const corner = try cornerAt(mesh, 2, want.at);
        try std.testing.expectApproxEqAbs(uv.u0 + (uv.u1 - uv.u0) * want.pixel[0] / 16.0, corner.u, 1.0e-5);
        try std.testing.expectApproxEqAbs(uv.v0 + (uv.v1 - uv.v0) * want.pixel[1] / 16.0, corner.v, 1.0e-5);
    }
}

test "a sideways shaft keeps the flat 0.6 the original gives both its z faces" {
    const gpa = std.testing.allocator;

    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);
    try buildPistonShaft(&mesh, gpa, world.block.pistonFacingValue(.east), piston_shaft_length, .{ 0, 0, 0 }, world.block.piston_side_tile, 1.0);

    var flat: usize = 0;
    var quad: usize = 0;
    while (quad * 4 < mesh.vertices.items.len) : (quad += 1) {
        const corners = mesh.vertices.items[quad * 4 ..][0..4];
        const constant_z = for (corners) |corner| {
            if (@abs(corner.z - corners[0].z) > 1.0e-5) break false;
        } else true;
        if (!constant_z) continue;

        try std.testing.expectEqual(shadeColor(0.6, Colorizer.white), corners[0].color);
        flat += 1;
    }

    try std.testing.expectEqual(@as(usize, 2), flat);
}

test "the shaft is a bare rod of four quads, capped by neither end" {
    const gpa = std.testing.allocator;

    for (std.enums.values(world.Side)) |facing| {
        var mesh: MeshBuilder = .{};
        defer mesh.deinit(gpa);
        try buildPistonShaft(&mesh, gpa, world.block.pistonFacingValue(facing), piston_shaft_length, .{ 0, 0, 0 }, world.block.piston_side_tile, 1.0);

        try std.testing.expectEqual(@as(usize, 4 * 4), mesh.vertices.items.len);
    }
}

test "the shaft wears the wooden band off the top of the side tile, stretched down its length" {
    const gpa = std.testing.allocator;
    const uv = Atlas.tileUv(world.block.piston_side_tile);
    const band = (uv.v1 - uv.v0) * piston_shaft_band;

    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);
    try buildPistonShaft(&mesh, gpa, world.block.pistonFacingValue(.up), piston_shaft_length, .{ 0, 0, 0 }, world.block.piston_side_tile, 1.0);

    for (mesh.vertices.items) |vertex| {
        try std.testing.expect(vertex.u >= uv.u0 - 1.0e-6 and vertex.u <= uv.u1 + 1.0e-6);
        try std.testing.expect(vertex.v >= uv.v0 - 1.0e-6 and vertex.v <= uv.v0 + band + 1.0e-6);

        const along = if (vertex.y < (12.0 / 16.0 - 1.0 + 12.0 / 16.0) / 2.0) uv.u0 else uv.u1;
        try std.testing.expectApproxEqAbs(along, vertex.u, 1.0e-6);
    }
}

test "half a shaft takes half the tile, so the rod keeps its pixel scale as it slides" {
    const gpa = std.testing.allocator;
    const uv = Atlas.tileUv(world.block.piston_side_tile);

    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);
    try buildPistonShaft(&mesh, gpa, world.block.pistonFacingValue(.up), 0.5, .{ 0, 0, 0 }, world.block.piston_side_tile, 1.0);

    var u_high: f32 = -std.math.floatMax(f32);
    for (mesh.vertices.items) |vertex| u_high = @max(u_high, vertex.u);
    try std.testing.expectApproxEqAbs(uv.u0 + (uv.u1 - uv.u0) * 0.5, u_high, 1.0e-6);
}

test "a shaft ground away to nothing draws nothing" {
    const gpa = std.testing.allocator;

    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);
    try buildPistonShaft(&mesh, gpa, world.block.pistonFacingValue(.up), 0.0, .{ 0, 0, 0 }, world.block.piston_side_tile, 1.0);

    try std.testing.expectEqual(@as(usize, 0), mesh.vertices.items.len);
}

test "a retracted piston fills its block, an extended one comes up short" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    _ = try world_map.createChunk(0, 0);

    var retracted: MeshBuilder = .{};
    defer retracted.deinit(gpa);
    const view = world.ChunkView.around(&world_map, 0, 0);
    try buildBoundedBox(&retracted, gpa, &view, .piston, world.block.pistonBaseBounds(world.block.pistonFacingValue(.up)), world.block.pistonBaseTextures(.piston, world.block.pistonFacingValue(.up)), .init(0, 0, 0), .{ 0, 0, 0 }, .{});

    var extended: MeshBuilder = .{};
    defer extended.deinit(gpa);
    const meta = world.block.pistonFacingValue(.up) | world.block.piston_flag;
    try buildBoundedBox(&extended, gpa, &view, .piston, world.block.pistonBaseBounds(meta), world.block.pistonBaseTextures(.piston, meta), .init(0, 0, 0), .{ 0, 0, 0 }, .{});

    try std.testing.expectApproxEqAbs(@as(f32, 1.0), meshExtent(retracted, 1)[1], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 12.0 / 16.0), meshExtent(extended, 1)[1], 1.0e-6);
}

fn buildPistonBase(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    world_map: *world.World,
    metadata: u4,
    facing: world.Side,
) !void {
    const view = world.ChunkView.around(world_map, 0, 0);
    try buildBoundedBoxTurned(
        mesh,
        gpa,
        &view,
        .piston,
        world.block.pistonBaseBounds(metadata),
        world.block.pistonBaseTextures(.piston, metadata),
        facing,
        .init(0, 0, 0),
        .{ 0, 0, 0 },
        .{},
    );
}

test "an extended piston loses the collar off its sides, the head having taken it" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    _ = try world_map.createChunk(0, 0);

    const uv = Atlas.tileUv(world.block.piston_side_tile);
    const collar = (uv.v1 - uv.v0) * world.block.piston_head_depth;

    for (std.enums.values(world.Side)) |facing| {
        const metadata = world.block.pistonFacingValue(facing) | world.block.piston_flag;

        var mesh: MeshBuilder = .{};
        defer mesh.deinit(gpa);
        try buildPistonBase(&mesh, gpa, &world_map, metadata, facing);

        const along = facing.step();
        const axis: usize = if (along[0] != 0) 0 else if (along[1] != 0) 1 else 2;

        var sides: usize = 0;
        var quad: usize = 0;
        while (quad * 4 < mesh.vertices.items.len) : (quad += 1) {
            if (faces[quad].normal[axis] != 0) continue;

            var v_low: f32 = std.math.floatMax(f32);
            var v_high: f32 = -std.math.floatMax(f32);
            for (mesh.vertices.items[quad * 4 ..][0..4]) |corner| {
                v_low = @min(v_low, corner.v);
                v_high = @max(v_high, corner.v);
            }

            try std.testing.expectApproxEqAbs(uv.v0 + collar, v_low, 1.0e-5);
            try std.testing.expectApproxEqAbs(uv.v1, v_high, 1.0e-5);
            sides += 1;
        }

        try std.testing.expectEqual(@as(usize, 4), sides);
    }
}

test "the collar on a piston's sides always points the way the piston faces" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    _ = try world_map.createChunk(0, 0);

    const uv = Atlas.tileUv(world.block.piston_side_tile);

    for (std.enums.values(world.Side)) |facing| {
        const metadata = world.block.pistonFacingValue(facing);

        var mesh: MeshBuilder = .{};
        defer mesh.deinit(gpa);
        try buildPistonBase(&mesh, gpa, &world_map, metadata, facing);

        const along = facing.step();
        const axis: usize = if (along[0] != 0) 0 else if (along[1] != 0) 1 else 2;
        const toward_high = along[axis] > 0;

        var checked: usize = 0;
        var quad: usize = 0;
        while (quad * 4 < mesh.vertices.items.len) : (quad += 1) {
            const corners = mesh.vertices.items[quad * 4 ..][0..4];

            // Only the four faces that carry the side tile wear the collar.
            if (@abs(corners[0].u - uv.u0) > 1.0e-5 and @abs(corners[0].u - uv.u1) > 1.0e-5) continue;
            var on_side_tile = true;
            for (corners) |corner| {
                if (corner.v < uv.v0 - 1.0e-5 or corner.v > uv.v1 + 1.0e-5) on_side_tile = false;
                if (corner.u < uv.u0 - 1.0e-5 or corner.u > uv.u1 + 1.0e-5) on_side_tile = false;
            }
            if (!on_side_tile) continue;

            var collar_low: f32 = std.math.floatMax(f32);
            var collar_high: f32 = -std.math.floatMax(f32);
            var seen_collar = false;
            for (corners) |corner| {
                if (@abs(corner.v - uv.v0) > 1.0e-5) continue;
                seen_collar = true;
                const value = switch (axis) {
                    0 => corner.x,
                    1 => corner.y,
                    else => corner.z,
                };
                collar_low = @min(collar_low, value);
                collar_high = @max(collar_high, value);
            }
            if (!seen_collar) continue;

            // The collar edge runs flat across the end of the block the head sits at.
            try std.testing.expectApproxEqAbs(collar_low, collar_high, 1.0e-5);
            try std.testing.expectApproxEqAbs(if (toward_high) @as(f32, 1.0) else @as(f32, 0.0), collar_low, 1.0e-5);
            checked += 1;
        }

        try std.testing.expectEqual(@as(usize, 4), checked);
    }
}

fn wireMesh(gpa: std.mem.Allocator, world_map: *world.World, metadata: u4) !Mesh {
    try world.light.relightChunk(gpa, world_map, 0, 0);
    const chunk = world_map.getChunk(0, 0).?;
    chunk.setBlockMetadata(8, 1, 8, metadata);
    return build(gpa, world_map, chunk, Colorizer.untinted, .{});
}

fn wireWorldMap(gpa: std.mem.Allocator) !world.World {
    var world_map = world.World.init(gpa);
    errdefer world_map.deinit();

    const chunk = try world_map.createChunk(0, 0);
    for (0..world.Chunk.width) |x| {
        for (0..world.Chunk.width) |z| {
            chunk.setBlock(@intCast(x), 0, @intCast(z), .stone);
        }
    }
    chunk.setBlock(8, 1, 8, .redstone_wire);
    return world_map;
}

fn dustVertices(mesh: Mesh, gpa: std.mem.Allocator) ![]MeshBuilder.Vertex {
    var found: std.ArrayList(MeshBuilder.Vertex) = .empty;
    errdefer found.deinit(gpa);
    for (mesh.solid.vertices.items) |v| {
        if (v.y == 1.0 + wire_lift) try found.append(gpa, v);
    }
    return found.toOwnedSlice(gpa);
}

test "a lone scrap of dust is a single flat quad lifted off the floor" {
    const gpa = std.testing.allocator;
    var world_map = try wireWorldMap(gpa);
    defer world_map.deinit();

    var mesh = try wireMesh(gpa, &world_map, 0);
    defer mesh.deinit(gpa);

    const dust = try dustVertices(mesh, gpa);
    defer gpa.free(dust);

    try std.testing.expectEqual(@as(usize, 4), dust.len);
}

test "unpowered dust is dim and full strength dust is bright red" {
    const gpa = std.testing.allocator;
    var world_map = try wireWorldMap(gpa);
    defer world_map.deinit();

    var dark_mesh = try wireMesh(gpa, &world_map, 0);
    defer dark_mesh.deinit(gpa);
    const dark = try dustVertices(dark_mesh, gpa);
    defer gpa.free(dark);

    var lit_mesh = try wireMesh(gpa, &world_map, 15);
    defer lit_mesh.deinit(gpa);
    const lit = try dustVertices(lit_mesh, gpa);
    defer gpa.free(lit);

    try std.testing.expect(lit[0].color[0] > dark[0].color[0]);
    try std.testing.expectEqual(@as(u8, 0), dark[0].color[1]);
    try std.testing.expectEqual(@as(u8, 0), dark[0].color[2]);
}

fn dustReachesTileEdge(mesh: Mesh, gpa: std.mem.Allocator, edge: f32) !bool {
    const dust = try dustVertices(mesh, gpa);
    defer gpa.free(dust);
    for (dust) |v| {
        if (v.u == edge) return true;
    }
    return false;
}

test "dust running east to west uses the line tile, not the crossing" {
    const gpa = std.testing.allocator;
    var world_map = try wireWorldMap(gpa);
    defer world_map.deinit();

    const line_edge = Atlas.tileUv(world.block.wire_line_tile).u1;

    var alone = try wireMesh(gpa, &world_map, 0);
    defer alone.deinit(gpa);
    try std.testing.expect(!try dustReachesTileEdge(alone, gpa, line_edge));

    const chunk = world_map.getChunk(0, 0).?;
    chunk.setBlock(7, 1, 8, .redstone_wire);
    chunk.setBlock(9, 1, 8, .redstone_wire);

    var run = try wireMesh(gpa, &world_map, 0);
    defer run.deinit(gpa);
    try std.testing.expect(try dustReachesTileEdge(run, gpa, line_edge));
}

test "redstone dust breaks into dark red shards, not grey stone ones" {
    const tint = blockTint(Colorizer.untinted, .redstone_wire, 0, world.Side.up, 0.5, 0.5);
    try std.testing.expectEqual(world.block.wire_particle_tint, tint);
    try std.testing.expectEqual(Colorizer.white, blockTint(Colorizer.untinted, .stone, 0, world.Side.up, 0.5, 0.5));
}

fn stickExtents(metadata: u4) [2][3]f32 {
    const corners = leverStickCorners(metadata, .{ 0, 0, 0 });
    var lowest: [3]f32 = .{ std.math.floatMax(f32), std.math.floatMax(f32), std.math.floatMax(f32) };
    var highest: [3]f32 = .{ -std.math.floatMax(f32), -std.math.floatMax(f32), -std.math.floatMax(f32) };
    for (corners) |corner| {
        for (0..3) |axis| {
            lowest[axis] = @min(lowest[axis], corner[axis]);
            highest[axis] = @max(highest[axis], corner[axis]);
        }
    }
    return .{ lowest, highest };
}

fn expectExtents(metadata: u4, lowest: [3]f32, highest: [3]f32) !void {
    const got = stickExtents(metadata);
    for (0..3) |axis| {
        try std.testing.expectApproxEqAbs(lowest[axis], got[0][axis], 1.0e-3);
        try std.testing.expectApproxEqAbs(highest[axis], got[1][axis], 1.0e-3);
    }
}

test "a lever handle stands where RenderBlocks swings it, per wall and floor facing" {
    try expectExtents(1, .{ 0.045, 0.500, 0.438 }, .{ 0.604, 0.997, 0.562 });
    try expectExtents(2, .{ 0.396, 0.500, 0.438 }, .{ 0.955, 0.997, 0.562 });
    try expectExtents(3, .{ 0.438, 0.500, 0.045 }, .{ 0.562, 0.997, 0.604 });
    try expectExtents(4, .{ 0.438, 0.500, 0.396 }, .{ 0.562, 0.997, 0.955 });
    try expectExtents(5, .{ 0.438, 0.045, 0.500 }, .{ 0.562, 0.604, 0.997 });
    try expectExtents(6, .{ 0.500, 0.045, 0.438 }, .{ 0.997, 0.604, 0.562 });
}

test "a lit portal meshes as one seamless sheet, not a stack of boxes" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    _ = chunk;

    var across: i32 = -1;
    while (across <= 2) : (across += 1) {
        var up: i32 = -1;
        while (up <= 3) : (up += 1) {
            const on_frame = across == -1 or across == 2 or up == -1 or up == 3;
            const corner = (across == -1 or across == 2) and (up == -1 or up == 3);
            if (!on_frame or corner) continue;
            world_map.setBlock(.init(8 + across, 64 + up, 8), .obsidian);
        }
    }
    try std.testing.expect(try world.portal.tryCreate(&world_map, .{ .x = 8, .y = 64, .z = 8 }));
    try world.light.relightChunk(gpa, &world_map, 0, 0);

    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?, Colorizer.untinted, .{});
    defer mesh.deinit(gpa);

    var portal_quads: usize = 0;
    for (mesh.translucent.vertices.items) |vertex| {
        if (vertex.z > 8.0 and vertex.z < 9.0) portal_quads += 1;
    }

    const portal_blocks = 6;
    const faces_per_block = 2;
    try std.testing.expectEqual(@as(usize, portal_blocks * faces_per_block * 4), portal_quads);
}

fn bedMesh(gpa: std.mem.Allocator, facing: u2, pillow: bool) !MeshBuilder {
    var world_map = try world.testing.flatWorld(gpa, 64);
    defer world_map.deinit();

    const metadata: u4 = @as(u4, facing) | (if (pillow) world.block.bed_pillow_bit else 0);
    const step = world.block.bedStep(facing);
    world_map.setBlock(.init(8, 64, 8), .bed);
    world_map.setBlockMetadata(.init(8, 64, 8), metadata);
    world_map.setBlock(.init(8 + step[0], 64, 8 + step[1]), .bed);
    world_map.setBlockMetadata(.init(8 + step[0], 64, 8 + step[1]), @as(u4, facing) | world.block.bed_pillow_bit);
    try world.light.relightChunk(gpa, &world_map, 0, 0);

    var mesh: MeshBuilder = .{};
    errdefer mesh.deinit(gpa);
    const view = world.ChunkView.around(&world_map, 0, 0);
    try buildBed(&mesh, gpa, &view, .bed, metadata, .init(8, 64, 8), .{ 8, 64, 8 }, .{});
    return mesh;
}

test "the bed skips the face it shares with its other half" {
    const gpa = std.testing.allocator;

    for ([4]u2{ 0, 1, 2, 3 }) |facing| {
        var head = try bedMesh(gpa, facing, false);
        defer head.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 5 * 4), head.vertices.items.len);

        var foot = try bedMesh(gpa, facing, true);
        defer foot.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 5 * 4), foot.vertices.items.len);
    }
}

test "the bed's sides run the full block height and only its underside sits on the legs" {
    const gpa = std.testing.allocator;
    var mesh = try bedMesh(gpa, 0, false);
    defer mesh.deinit(gpa);

    var lowest: f32 = 1.0;
    var highest: f32 = 0.0;
    var underside: usize = 0;
    for (mesh.vertices.items) |vertex| {
        const height = vertex.y - 64.0;
        lowest = @min(lowest, height);
        highest = @max(highest, height);
        if (@abs(height - world.block.bed_leg_height) < 1.0e-5) underside += 1;
    }

    try std.testing.expectApproxEqAbs(@as(f32, 0.0), lowest, 1.0e-5);
    try std.testing.expectApproxEqAbs(world.block.bed_height, highest, 1.0e-5);
    try std.testing.expectEqual(@as(usize, 4), underside);
}

test "the bed's top texture turns a quarter for every step of its facing" {
    const gpa = std.testing.allocator;

    var seen: [4][4][2]f32 = undefined;
    for ([4]u2{ 0, 1, 2, 3 }, 0..) |facing, index| {
        var mesh = try bedMesh(gpa, facing, false);
        defer mesh.deinit(gpa);

        var found = false;
        for (mesh.vertices.items, 0..) |vertex, at| {
            if (@abs(vertex.y - 64.0 - world.block.bed_height) > 1.0e-5) continue;
            for (0..4) |corner| {
                seen[index][corner] = .{ mesh.vertices.items[at + corner].u, mesh.vertices.items[at + corner].v };
            }
            found = true;
            break;
        }
        try std.testing.expect(found);
    }

    for (0..4) |first| {
        for (first + 1..4) |second| {
            try std.testing.expect(!std.mem.eql(u8, std.mem.asBytes(&seen[first]), std.mem.asBytes(&seen[second])));
        }
    }
}

test "fire standing on solid ground is eight leaning quads, not a crossed sprite" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    _ = try world_map.createChunk(0, 0);

    var mesh = try fireMesh(gpa, &world_map, .stone);
    defer mesh.deinit(gpa);

    const ground_quads = 6;
    const fire_quads = 8;
    try std.testing.expectEqual(@as(usize, (fire_quads + ground_quads) * 4), mesh.solid.vertices.items.len);
}

test "fire reaches the original's one and two fifths blocks above its floor" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    _ = try world_map.createChunk(0, 0);

    var mesh = try fireMesh(gpa, &world_map, .stone);
    defer mesh.deinit(gpa);

    const upright = spanOf(mesh, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0) + fire_height, upright[1], 1.0e-5);
}

test "fire alternates between its tile and the row beneath it" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    _ = try world_map.createChunk(0, 0);

    var mesh = try fireMesh(gpa, &world_map, .stone);
    defer mesh.deinit(gpa);

    const near = Atlas.tileUv(world.Block.fire.faceTextures().get(.down));
    const far = Atlas.tileUv(world.Block.fire.faceTextures().get(.down) + Atlas.tiles_per_row);

    var near_rows: usize = 0;
    var far_rows: usize = 0;
    for (mesh.solid.vertices.items) |v| {
        if (v.y < 2.0) continue;
        if (@abs(v.v - near.v0) < 1.0e-5) near_rows += 1;
        if (@abs(v.v - far.v0) < 1.0e-5) far_rows += 1;
    }
    try std.testing.expect(near_rows > 0);
    try std.testing.expect(far_rows > 0);
}

test "fire with nothing to stand on clings to the flammable blocks beside it" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);

    chunk.setBlock(8, 2, 8, .fire);
    chunk.setBlock(7, 2, 8, .planks);
    try world.light.relightChunk(gpa, &world_map, 0, 0);
    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?, Colorizer.untinted, .{});
    defer mesh.deinit(gpa);

    const planks_quads = 6;
    const wall_quads = 2;
    try std.testing.expectEqual(@as(usize, (planks_quads + wall_quads) * 4), mesh.solid.vertices.items.len);
}

test "fire floating with no flammable neighbour draws nothing at all" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);

    chunk.setBlock(8, 2, 8, .fire);
    try world.light.relightChunk(gpa, &world_map, 0, 0);
    var mesh = try build(gpa, &world_map, world_map.getChunk(0, 0).?, Colorizer.untinted, .{});
    defer mesh.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), mesh.solid.vertices.items.len);
}
