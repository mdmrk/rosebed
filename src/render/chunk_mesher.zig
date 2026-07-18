const std = @import("std");

const math = @import("math");
const world = @import("world");

const Atlas = @import("atlas.zig");
const Colorizer = @import("colorizer.zig");
const MeshBuilder = @import("mesh_builder.zig");

const FaceDir = struct {
    side: world.Side,
    shade: f32,
    normal: [3]i32,
    corners: [4][3]f32,
    axis_u: u2,
    axis_v: u2,
};

const faces = [6]FaceDir{
    .{ .side = .down, .shade = 0.5, .normal = .{ 0, -1, 0 }, .axis_u = 0, .axis_v = 2, .corners = .{
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

fn brightnessOf(world_map: *const world.World, cell: [3]i32, minimum: u4) f32 {
    return world.light.brightnessAt(world_map, cell[0], cell[1], cell[2], minimum);
}

fn blocksGrass(world_map: *const world.World, cell: [3]i32) bool {
    return world_map.getBlock(cell[0], cell[1], cell[2]).isOpaque();
}

fn smoothBrightness(
    world_map: *const world.World,
    face: FaceDir,
    x: i32,
    y: i32,
    z: i32,
    minimum: u4,
) [4]f32 {
    const cell = offsetBy(.{ x, y, z }, face.normal);
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

fn neighborId(world_map: *const world.World, chunk: *const world.Chunk, x: i32, y: i32, z: i32) world.Block {
    const world_x = chunk.x * world.constants.chunk_width + x;
    const world_z = chunk.z * world.constants.chunk_width + z;
    return world_map.getBlock(world_x, y, world_z);
}

pub const Options = struct {
    smooth: bool = false,
    fancy: bool = false,
};

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

pub fn buildCube(mesh: *MeshBuilder, gpa: std.mem.Allocator, min: [3]f32, max: [3]f32, face_textures: world.block.FaceTextures, inset: f32) !void {
    try buildCubeColored(mesh, gpa, min, max, face_textures, inset, null);
}

pub fn buildCubeColored(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    min: [3]f32,
    max: [3]f32,
    face_textures: world.block.FaceTextures,
    inset: f32,
    color: ?[4]u8,
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
        const uvs = [4][2]f32{
            .{ uv.u1, uv.v1 },
            .{ uv.u1, uv.v0 },
            .{ uv.u0, uv.v0 },
            .{ uv.u0, uv.v1 },
        };
        try mesh.quad(gpa, positions, uvs, color orelse shadeColor(face.shade, Colorizer.white));
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

    const facing = [4][2]f32{
        .{ uv.u0, uv.v0 },
        .{ uv.u0, uv.v1 },
        .{ uv.u1, uv.v1 },
        .{ uv.u1, uv.v0 },
    };
    const mirrored = [4][2]f32{
        .{ uv.u1, uv.v0 },
        .{ uv.u1, uv.v1 },
        .{ uv.u0, uv.v1 },
        .{ uv.u0, uv.v0 },
    };

    try mesh.quad(gpa, .{
        .{ x0, y1, z0 }, .{ x0, y0, z0 }, .{ x1, y0, z1 }, .{ x1, y1, z1 },
    }, facing, color);
    try mesh.quad(gpa, .{
        .{ x1, y1, z1 }, .{ x1, y0, z1 }, .{ x0, y0, z0 }, .{ x0, y1, z0 },
    }, mirrored, color);
    try mesh.quad(gpa, .{
        .{ x0, y1, z1 }, .{ x0, y0, z1 }, .{ x1, y0, z0 }, .{ x1, y1, z0 },
    }, facing, color);
    try mesh.quad(gpa, .{
        .{ x1, y1, z0 }, .{ x1, y0, z0 }, .{ x0, y0, z1 }, .{ x0, y1, z1 },
    }, mirrored, color);
}

const torch_lean: f32 = 0.4;
const torch_half: f32 = 1.0 / 16.0;
const torch_tip: f32 = 0.625;

fn buildTorch(mesh: *MeshBuilder, gpa: std.mem.Allocator, tile: u8, metadata: u4, bx: f32, by: f32, bz: f32) !void {
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
    const color = shadeColor(1.0, Colorizer.white);

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

fn boxFaceQuad(bounds: world.block.Bounds, origin: [3]f32, face: FaceDir, tile: u8, mirrored: bool) BoxQuad {
    const uv = Atlas.tileUv(tile);
    const u_far = if (mirrored) uv.u0 else uv.u1;
    const u_near = if (mirrored) uv.u1 else uv.u0;

    var quad: BoxQuad = undefined;
    for (face.corners, 0..) |corner, i| {
        quad.positions[i] = boxCorner(origin, bounds, corner);
        const u_edge = if (i < 2) u_far else u_near;
        const v_edge = if (i == 0 or i == 3) uv.v1 else uv.v0;
        quad.uvs[i] = .{
            croppedUv(u_edge, if (i < 2) u_near else u_far, bounds, face.axis_u, corner[face.axis_u]),
            croppedUv(v_edge, if (i == 0 or i == 3) uv.v0 else uv.v1, bounds, face.axis_v, corner[face.axis_v]),
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
) !void {
    for (faces) |face| {
        const quad = boxFaceQuad(bounds, .{ 0, 0, 0 }, face, face_textures.get(face.side), false);
        var positions = quad.positions;
        for (&positions) |*position| {
            for (0..3) |axis| position[axis] = center[axis] + (position[axis] - 0.5) * size;
            position[0] = pulledInward(position[0], face.normal[0], inset);
            position[2] = pulledInward(position[2], face.normal[2], inset);
        }
        try mesh.quad(gpa, positions, quad.uvs, shadeColor(face.shade, Colorizer.white));
    }
}

fn buildDoor(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    id: world.Block,
    metadata: u4,
    x: i32,
    y: i32,
    z: i32,
    origin: [3]f32,
) !void {
    const bounds = world.block.doorBounds(metadata);
    const emitted = world.light.emission(id);
    const own_brightness = world.light.brightnessAt(world_map, x, y, z, emitted);

    for (faces) |face| {
        const door_face = world.block.doorFaceTile(id, face.side, metadata);
        const quad = boxFaceQuad(bounds, origin, face, door_face.tile, door_face.mirrored);

        const brightness = if (reachesFace(bounds, face.side))
            world.light.brightnessAt(world_map, x + face.normal[0], y + face.normal[1], z + face.normal[2], emitted)
        else
            own_brightness;

        try mesh.quad(gpa, quad.positions, quad.uvs, shadeColor(face.shade * brightness, Colorizer.white));
    }
}

fn buildBoundedBox(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    id: world.Block,
    bounds: world.block.Bounds,
    textures: world.block.FaceTextures,
    x: i32,
    y: i32,
    z: i32,
    origin: [3]f32,
    options: Options,
) !void {
    const emitted = world.light.emission(id);
    const own_brightness = world.light.brightnessAt(world_map, x, y, z, emitted);

    for (faces) |face| {
        const nx = x + face.normal[0];
        const ny = y + face.normal[1];
        const nz = z + face.normal[2];
        const reaches = reachesFace(bounds, face.side);
        if (reaches and !id.shouldRenderFace(world_map.getBlock(nx, ny, nz), face.side, options.fancy)) continue;

        const quad = boxFaceQuad(bounds, origin, face, textures.get(face.side), false);

        if (options.smooth and reaches) {
            const corner_brightness = smoothBrightness(world_map, face, x, y, z, emitted);
            var colors: [4][4]u8 = undefined;
            for (corner_brightness, 0..) |brightness, i| {
                colors[i] = shadeColor(face.shade * brightness, Colorizer.white);
            }
            try mesh.quadShaded(gpa, quad.positions, quad.uvs, colors);
            continue;
        }

        const brightness = if (reaches)
            world.light.brightnessAt(world_map, nx, ny, nz, emitted)
        else
            own_brightness;
        try mesh.quad(gpa, quad.positions, quad.uvs, shadeColor(face.shade * brightness, Colorizer.white));
    }
}

fn fluidBrightness(world_map: *const world.World, x: i32, y: i32, z: i32, minimum: u4) f32 {
    return @max(
        world.light.brightnessAt(world_map, x, y, z, minimum),
        world.light.brightnessAt(world_map, x, y + 1, z, minimum),
    );
}

fn fluidCornerHeight(world_map: *const world.World, x: i32, y: i32, z: i32, material: world.Material) f32 {
    var count: u32 = 0;
    var submerged: f32 = 0;

    for (0..4) |corner| {
        const nx = x - @as(i32, @intCast(corner & 1));
        const nz = z - @as(i32, @intCast((corner >> 1) & 1));
        if (world_map.getBlock(nx, y + 1, nz).material() == material) return 1.0;

        const neighbor = world_map.getBlock(nx, y, nz).material();
        if (neighbor != material) {
            if (!neighbor.isSolid()) {
                submerged += 1.0;
                count += 1;
            }
            continue;
        }

        const metadata = world_map.getBlockMetadata(nx, y, nz);
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
    world_map: *const world.World,
    id: world.Block,
    x: i32,
    y: i32,
    z: i32,
    origin: [3]f32,
    options: Options,
) !void {
    const material = id.material();
    const emitted = world.light.emission(id);
    const textures = id.faceTextures();

    const heights = [4]f32{
        fluidCornerHeight(world_map, x, y, z, material),
        fluidCornerHeight(world_map, x, y, z + 1, material),
        fluidCornerHeight(world_map, x + 1, y, z + 1, material),
        fluidCornerHeight(world_map, x + 1, y, z, material),
    };

    if (id.shouldRenderFace(world_map.getBlock(x, y + 1, z), .up, options.fancy)) {
        const angle = world.fluid.flowAngle(world_map, x, y, z);
        const tile = if (angle == null) textures.get(.up) else textures.get(.north);
        const uv = Atlas.tileUv(tile);
        const half: f32 = 8.0 / 256.0;
        const center_offset: f32 = if (angle == null) half else 2.0 * half;
        const center_u = uv.u0 + center_offset;
        const center_v = uv.v0 + center_offset;
        const rotation = angle orelse 0.0;
        const du = math.util.sin(rotation) * half;
        const dv = math.util.cos(rotation) * half;

        const brightness = fluidBrightness(world_map, x, y, z, emitted);
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

    if (id.shouldRenderFace(world_map.getBlock(x, y - 1, z), .down, options.fancy)) {
        const uv = Atlas.tileUv(textures.get(.down));
        const brightness = fluidBrightness(world_map, x, y - 1, z, emitted);
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
        const nx = x + face.normal[0];
        const nz = z + face.normal[1];
        if (!id.shouldRenderFace(world_map.getBlock(nx, y, nz), face.side, options.fancy)) continue;

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
        const brightness = fluidBrightness(world_map, nx, y, nz, emitted);
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

pub fn build(gpa: std.mem.Allocator, world_map: *const world.World, chunk: *const world.Chunk, colorizer: Colorizer, options: Options) !Mesh {
    var mesh: Mesh = .{};
    errdefer mesh.deinit(gpa);

    const origin_x: f32 = @floatFromInt(chunk.x * world.constants.chunk_width);
    const origin_z: f32 = @floatFromInt(chunk.z * world.constants.chunk_width);

    for (0..world.constants.chunk_width) |lx| {
        for (0..world.constants.chunk_width) |lz| {
            const column_temperature = chunk.getTemperature(@intCast(lx), @intCast(lz));
            const column_humidity = chunk.getHumidity(@intCast(lx), @intCast(lz));
            for (0..world.constants.chunk_height) |ly| {
                const id = chunk.getBlock(@intCast(lx), @intCast(ly), @intCast(lz));
                if (id == .air) continue;

                const bx = origin_x + @as(f32, @floatFromInt(lx));
                const by: f32 = @floatFromInt(ly);
                const bz = origin_z + @as(f32, @floatFromInt(lz));

                const metadata = chunk.getBlockMetadata(@intCast(lx), @intCast(ly), @intCast(lz));

                const world_x: i32 = @intFromFloat(bx);
                const world_y: i32 = @intCast(ly);
                const world_z: i32 = @intFromFloat(bz);
                const emitted = world.light.emission(id);
                const own_brightness = world.light.brightnessAt(world_map, world_x, world_y, world_z, emitted);

                const target = if (id.isTranslucent()) &mesh.translucent else &mesh.solid;

                if (id.isCross()) {
                    const tint = blockTint(colorizer, id, metadata, world.Side.up, column_temperature, column_humidity);
                    try buildCross(target, gpa, id.crossTile(metadata), tint, own_brightness, bx, by, bz);
                    continue;
                }

                if (id.shape() == .torch) {
                    try buildTorch(target, gpa, id.faceTextures().get(.down), metadata, bx, by, bz);
                    continue;
                }

                if (id.isDoor()) {
                    try buildDoor(target, gpa, world_map, id, metadata, world_x, world_y, world_z, .{ bx, by, bz });
                    continue;
                }

                if (id.isTrapdoor()) {
                    const bounds = world.block.trapdoorBounds(metadata);
                    try buildBoundedBox(target, gpa, world_map, id, bounds, id.faceTextures(), world_x, world_y, world_z, .{ bx, by, bz }, options);
                    continue;
                }

                if (id.isStairs()) {
                    for (world.block.stairsBoxes(metadata)) |bounds| {
                        try buildBoundedBox(target, gpa, world_map, id, bounds, id.faceTextures(), world_x, world_y, world_z, .{ bx, by, bz }, options);
                    }
                    continue;
                }

                if (id.isCake()) {
                    const bounds = world.block.cakeBounds(metadata);
                    const textures = world.block.cakeTextures(metadata);
                    try buildBoundedBox(target, gpa, world_map, id, bounds, textures, world_x, world_y, world_z, .{ bx, by, bz }, options);
                    continue;
                }

                if (id.isLiquid()) {
                    try buildFluid(target, gpa, world_map, id, world_x, world_y, world_z, .{ bx, by, bz }, options);
                    continue;
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
                } else if (id == .grass) {
                    const above = neighborId(world_map, chunk, @intCast(lx), @as(i32, @intCast(ly)) + 1, @intCast(lz));
                    const side_tile = world.block.grassSideTile(above);
                    textures.set(.north, side_tile);
                    textures.set(.south, side_tile);
                    textures.set(.west, side_tile);
                    textures.set(.east, side_tile);
                }

                const height_scale = id.heightScale();
                const inset = id.sideInset();

                for (faces) |face| {
                    const nx: i32 = @as(i32, @intCast(lx)) + face.normal[0];
                    const ny: i32 = @as(i32, @intCast(ly)) + face.normal[1];
                    const nz: i32 = @as(i32, @intCast(lz)) + face.normal[2];
                    if (!id.shouldRenderFace(neighborId(world_map, chunk, nx, ny, nz), face.side, options.fancy)) continue;

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

                    const tint = blockTint(colorizer, id, metadata, face.side, column_temperature, column_humidity);
                    const overlaid = options.fancy and id == .grass and tile == world.block.grass_side_tile;
                    const overlay_uvs = faceUvs(world.block.grass_side_overlay_tile, face.side, height_scale);
                    const overlay_tint = colorizer.grassColor(column_temperature, column_humidity);

                    if (options.smooth) {
                        const corner_brightness = smoothBrightness(world_map, face, world_x, world_y, world_z, emitted);
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
                        world.light.brightnessAt(world_map, world_x + face.normal[0], world_y + face.normal[1], world_z + face.normal[2], emitted);

                    try target.quad(gpa, positions, uvs, shadeColor(face.shade * brightness, tint));

                    if (overlaid) {
                        try target.quad(gpa, positions, overlay_uvs, shadeColor(face.shade * brightness, overlay_tint));
                    }
                }
            }
        }
    }

    return mesh;
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
    const corners = smoothBrightness(&world_map, faces[@intFromEnum(world.Side.up)], 8, 0, 8, 0);
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
    const corners = smoothBrightness(&world_map, faces[@intFromEnum(world.Side.up)], 8, 0, 8, 0);

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
    const corners = smoothBrightness(&world_map, faces[@intFromEnum(world.Side.up)], 8, 0, 8, 0);

    const dark = world.light.brightnessAt(&world_map, 9, 1, 9, 0);
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
    const corners = smoothBrightness(&world_map, faces[@intFromEnum(world.Side.up)], 8, 0, 8, 0);

    const dark = world.light.brightnessAt(&world_map, 9, 1, 8, 0);
    try std.testing.expect(world.light.brightnessAt(&world_map, 9, 1, 9, 0) > dark);
    try std.testing.expectApproxEqAbs((1.0 + 3.0 * dark) / 4.0, corners[0], 1.0e-6);
}

test "a seam face needs its neighbour lit before it shades correctly" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    const near = try world_map.createChunk(0, 0);
    const far = try world_map.createChunk(1, 0);
    for (0..world.constants.chunk_width) |x| {
        for (0..world.constants.chunk_width) |z| {
            near.setBlock(@intCast(x), 0, @intCast(z), .stone);
            far.setBlock(@intCast(x), 0, @intCast(z), .stone);
        }
    }

    try world.light.relightChunk(gpa, &world_map, 0, 0);
    const unlit_neighbour = smoothBrightness(&world_map, faces[@intFromEnum(world.Side.up)], 15, 0, 8, 0);
    try std.testing.expect(unlit_neighbour[1] < 1.0);
    try std.testing.expect(unlit_neighbour[0] < 1.0);

    try world.light.relightChunk(gpa, &world_map, 1, 0);
    const lit_neighbour = smoothBrightness(&world_map, faces[@intFromEnum(world.Side.up)], 15, 0, 8, 0);
    const interior = smoothBrightness(&world_map, faces[@intFromEnum(world.Side.up)], 8, 0, 8, 0);
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

    const height = fluidCornerHeight(&world_map, 8, 0, 8, world.Material.water);
    try std.testing.expectApproxEqAbs(@as(f32, 8.0 / 9.0), height, 1.0e-6);
}

test "water under more water fills its block completely" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlock(8, 0, 8, .stationary_water);
    chunk.setBlock(8, 1, 8, .stationary_water);

    try std.testing.expectEqual(@as(f32, 1.0), fluidCornerHeight(&world_map, 8, 0, 8, world.Material.water));
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

    const shared = fluidCornerHeight(&world_map, 9, 0, 9, world.Material.water);
    const away = fluidCornerHeight(&world_map, 8, 0, 8, world.Material.water);
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
    try buildBoxCube(&mesh, gpa, .{ 0, 0, 0 }, 1.0, boxes[0], world.Block.slab.faceTextures(), 0.0);

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

fn expectSameMesh(want: MeshBuilder, got: MeshBuilder) !void {
    try std.testing.expectEqual(want.vertices.items.len, got.vertices.items.len);
    for (want.vertices.items, got.vertices.items) |a, b| {
        try std.testing.expectApproxEqAbs(a.x, b.x, 1.0e-6);
        try std.testing.expectApproxEqAbs(a.y, b.y, 1.0e-6);
        try std.testing.expectApproxEqAbs(a.z, b.z, 1.0e-6);
        try std.testing.expectApproxEqAbs(a.u, b.u, 1.0e-6);
        try std.testing.expectApproxEqAbs(a.v, b.v, 1.0e-6);
        try std.testing.expectEqual(a.color, b.color);
    }
}

test "a box with full bounds is the cube the item renderers drew before" {
    const gpa = std.testing.allocator;

    for ([_]world.Block{ .workbench, .cactus }) |id| {
        var cube: MeshBuilder = .{};
        defer cube.deinit(gpa);
        var box: MeshBuilder = .{};
        defer box.deinit(gpa);

        const textures = id.faceTextures();
        const inset = id.sideInset();
        try buildCube(&cube, gpa, .{ -0.5, -0.5, -0.5 }, .{ 0.5, 0.5, 0.5 }, textures, inset);
        try buildBoxCube(&box, gpa, .{ 0, 0, 0 }, 1.0, id.itemRenderBoxes()[0], textures, inset);

        try expectSameMesh(cube, box);
    }
}

test "a trapdoor in hand is a plate through the middle of its block" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);

    const id = world.Block.trapdoor;
    try buildBoxCube(&mesh, gpa, .{ 0, 0, 0 }, 1.0, id.itemRenderBoxes()[0], id.faceTextures(), 0.0);

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
