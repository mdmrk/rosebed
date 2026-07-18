const std = @import("std");

const game = @import("game");
const math = @import("math");
const world = @import("world");

const Atlas = @import("atlas.zig");
const chunk_mesher = @import("chunk_mesher.zig");
const MeshBuilder = @import("mesh_builder.zig");
const mob_model = @import("mob_model.zig");

const white = [4]u8{ 255, 255, 255, 255 };

fn brightnessOf(world_map: *const world.World, base: game.Entity) f32 {
    const sample = base.lightSamplePosition();
    return world.light.brightnessAt(world_map, sample[0], sample[1], sample[2], 0);
}

pub const stack_copy_seed: i64 = 187;
pub const block_scale: f32 = 0.25;
pub const flat_scale: f32 = 0.5;

pub fn copiesFor(count: u8) u8 {
    if (count > 20) return 4;
    if (count > 5) return 3;
    if (count > 1) return 2;
    return 1;
}

pub fn bobHeight(age: u32, hover: f32, partial_ticks: f32) f32 {
    return math.util.sin((@as(f32, @floatFromInt(age)) + partial_ticks) / 10.0 + hover) * 0.1 + 0.1;
}

pub fn spinRadians(age: u32, hover: f32, partial_ticks: f32) f32 {
    return (@as(f32, @floatFromInt(age)) + partial_ticks) / 20.0 + hover;
}

fn placeSince(mesh: *MeshBuilder, first_vertex: usize, yaw: f32, origin: [3]f32) void {
    const cos = @cos(yaw);
    const sin = @sin(yaw);
    for (mesh.vertices.items[first_vertex..]) |*vertex| {
        const x = vertex.x * cos + vertex.z * sin;
        const z = -vertex.x * sin + vertex.z * cos;
        vertex.x = x + origin[0];
        vertex.y += origin[1];
        vertex.z = z + origin[2];
    }
}

fn itemOrigin(item: game.ItemEntity, partial_ticks: f32) [3]f32 {
    const pos = item.base.renderPosition(partial_ticks);
    return .{
        @floatCast(pos.x),
        @as(f32, @floatCast(pos.y + game.ItemEntity.height / 2.0)) + bobHeight(item.age, item.hover, partial_ticks),
        @floatCast(pos.z),
    };
}

fn appendCopies(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    item: game.ItemEntity,
    yaw: f32,
    spread: f32,
    partial_ticks: f32,
    build: *const fn (*MeshBuilder, std.mem.Allocator) anyerror!void,
) !void {
    const first_vertex = mesh.vertices.items.len;
    const origin = itemOrigin(item, partial_ticks);
    var rand = world.JavaRandom.init(stack_copy_seed);

    for (0..copiesFor(item.stack.count)) |copy| {
        const copy_start = mesh.vertices.items.len;
        try build(mesh, gpa);
        var offset = origin;
        if (copy > 0) {
            offset[0] += (rand.nextFloat() * 2.0 - 1.0) * spread;
            offset[1] += (rand.nextFloat() * 2.0 - 1.0) * spread;
            offset[2] += (rand.nextFloat() * 2.0 - 1.0) * spread;
        }
        placeSince(mesh, copy_start, yaw, offset);
    }

    mesh.scaleColors(first_vertex, brightnessOf(world_map, item.base));
}

pub fn appendItem(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    item: game.ItemEntity,
    partial_ticks: f32,
) !void {
    const id = switch (item.stack.id) {
        .block => |b| b,
        .item => return,
    };

    if (id.flatItemTile(item.stack.blockMeta())) |tile| {
        const Cross = struct {
            var shape_tile: u8 = 0;
            fn build(target: *MeshBuilder, gpa_inner: std.mem.Allocator) anyerror!void {
                try appendCrossSprite(target, gpa_inner, shape_tile, flat_scale);
            }
        };
        Cross.shape_tile = tile;
        return appendCopies(mesh, gpa, world_map, item, 0, 0.2, partial_ticks, Cross.build);
    }

    const Cube = struct {
        var faces: world.block.FaceTextures = undefined;
        var boxes: []const world.block.Bounds = undefined;
        var inset: f32 = 0.0;
        fn build(target: *MeshBuilder, gpa_inner: std.mem.Allocator) anyerror!void {
            for (boxes) |bounds| {
                try chunk_mesher.buildBoxCube(target, gpa_inner, .{ 0, 0, 0 }, block_scale, bounds, faces, inset);
            }
        }
    };
    Cube.boxes = id.itemRenderBoxes();
    Cube.faces = id.faceTextures();
    if (id == .log) {
        const side_tile = world.block.logSideTile(item.stack.blockMeta());
        Cube.faces.set(.north, side_tile);
        Cube.faces.set(.south, side_tile);
        Cube.faces.set(.west, side_tile);
        Cube.faces.set(.east, side_tile);
    } else if (id == .wool) {
        Cube.faces = world.block.FaceTextures.initFill(world.block.woolTile(item.stack.blockMeta()));
    } else if (id == .slab or id == .slab_double) {
        Cube.faces = world.block.slabTextures(item.stack.blockMeta());
    }
    Cube.inset = id.sideInset() * block_scale;
    try appendCopies(
        mesh,
        gpa,
        world_map,
        item,
        spinRadians(item.age, item.hover, partial_ticks),
        0.2,
        partial_ticks,
        Cube.build,
    );
}

fn appendCrossSprite(mesh: *MeshBuilder, gpa: std.mem.Allocator, tile: u8, scale: f32) !void {
    const uv = Atlas.tileUv(tile);
    const uvs = [4][2]f32{
        .{ uv.u0, uv.v1 }, .{ uv.u1, uv.v1 }, .{ uv.u1, uv.v0 }, .{ uv.u0, uv.v0 },
    };
    const half = scale / 2.0;
    try mesh.quad(gpa, .{
        .{ -half, -half, -half }, .{ half, -half, half }, .{ half, half, half }, .{ -half, half, -half },
    }, uvs, white);
    try mesh.quad(gpa, .{
        .{ half, -half, -half }, .{ -half, -half, half }, .{ -half, half, half }, .{ half, half, -half },
    }, uvs, white);
}

pub fn appendItemIcon(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    item: game.ItemEntity,
    view_yaw: f32,
    partial_ticks: f32,
) !void {
    const tile = switch (item.stack.id) {
        .item => |i| i.iconTile(item.stack.meta) orelse return,
        .block => return,
    };

    const Billboard = struct {
        var icon: u8 = 0;
        fn build(target: *MeshBuilder, gpa_inner: std.mem.Allocator) anyerror!void {
            const uv = Atlas.tileUv(icon);
            const uvs = [4][2]f32{
                .{ uv.u0, uv.v1 }, .{ uv.u1, uv.v1 }, .{ uv.u1, uv.v0 }, .{ uv.u0, uv.v0 },
            };
            const left = -flat_scale / 2.0;
            const right = flat_scale / 2.0;
            const bottom = -flat_scale / 4.0;
            const top = bottom + flat_scale;
            try target.quad(gpa_inner, .{
                .{ left, bottom, 0 }, .{ right, bottom, 0 }, .{ right, top, 0 }, .{ left, top, 0 },
            }, uvs, white);
        }
    };
    Billboard.icon = tile;

    const degrees = std.math.pi / 180.0;
    try appendCopies(mesh, gpa, world_map, item, (180.0 - view_yaw) * degrees, 0.3, partial_ticks, Billboard.build);
}

pub fn appendFallingBlock(mesh: *MeshBuilder, gpa: std.mem.Allocator, world_map: *const world.World, block: game.FallingBlock, partial_ticks: f32) !void {
    const first_vertex = mesh.vertices.items.len;
    const pos = block.base.renderPosition(partial_ticks);
    const size: f32 = @floatCast(game.FallingBlock.size);
    const half = size / 2.0;
    const cx: f32 = @floatCast(pos.x);
    const cy: f32 = @floatCast(pos.y);
    const cz: f32 = @floatCast(pos.z);
    try chunk_mesher.buildCube(
        mesh,
        gpa,
        .{ cx - half, cy, cz - half },
        .{ cx + half, cy + size, cz + half },
        block.block_id.faceTextures(),
        block.block_id.sideInset() * size,
    );

    mesh.scaleColors(first_vertex, brightnessOf(world_map, block.base));
}

pub const hurt_tint: f32 = 0.4;

const to_radians: f32 = std.math.pi / 180.0;

const untinted = [3]f32{ 1, 1, 1 };

pub const fleece_colors = [16][3]f32{
    .{ 1.0, 1.0, 1.0 },
    .{ 0.95, 0.7, 0.2 },
    .{ 0.9, 0.5, 0.85 },
    .{ 0.6, 0.7, 0.95 },
    .{ 0.9, 0.9, 0.2 },
    .{ 0.5, 0.8, 0.1 },
    .{ 0.95, 0.7, 0.8 },
    .{ 0.3, 0.3, 0.3 },
    .{ 0.6, 0.6, 0.6 },
    .{ 0.3, 0.6, 0.7 },
    .{ 0.7, 0.4, 0.9 },
    .{ 0.2, 0.4, 0.8 },
    .{ 0.5, 0.4, 0.3 },
    .{ 0.4, 0.5, 0.2 },
    .{ 0.8, 0.3, 0.3 },
    .{ 0.1, 0.1, 0.1 },
};

pub fn appendPig(mesh: *MeshBuilder, gpa: std.mem.Allocator, world_map: *const world.World, pig: game.Pig, partial_ticks: f32) !void {
    return appendAnimal(mesh, gpa, world_map, pig.animal, partial_ticks, mob_model.pig, .{});
}

pub fn appendPigSaddle(mesh: *MeshBuilder, gpa: std.mem.Allocator, world_map: *const world.World, pig: game.Pig, partial_ticks: f32) !void {
    return appendAnimal(mesh, gpa, world_map, pig.animal, partial_ticks, mob_model.pig_saddle, .{});
}

pub fn appendSheep(mesh: *MeshBuilder, gpa: std.mem.Allocator, world_map: *const world.World, sheep: game.Sheep, partial_ticks: f32) !void {
    return appendAnimal(mesh, gpa, world_map, sheep.animal, partial_ticks, mob_model.sheep, .{});
}

pub fn appendCow(mesh: *MeshBuilder, gpa: std.mem.Allocator, world_map: *const world.World, cow: game.Cow, partial_ticks: f32) !void {
    return appendAnimal(mesh, gpa, world_map, cow.animal, partial_ticks, mob_model.cow, .{});
}

pub fn appendChicken(mesh: *MeshBuilder, gpa: std.mem.Allocator, world_map: *const world.World, chicken: game.Chicken, partial_ticks: f32) !void {
    return appendAnimal(mesh, gpa, world_map, chicken.animal, partial_ticks, mob_model.chicken, .{
        .wing_flap = chicken.wingFlap(partial_ticks),
    });
}

pub fn appendSheepFur(mesh: *MeshBuilder, gpa: std.mem.Allocator, world_map: *const world.World, sheep: game.Sheep, partial_ticks: f32) !void {
    return appendAnimal(mesh, gpa, world_map, sheep.animal, partial_ticks, mob_model.sheep_fur, .{
        .tint = fleece_colors[sheep.fleece_color],
    });
}

pub const player_scale: f32 = 15.0 / 16.0;

const all_biped_parts_shown: [mob_model.biped.parts.len]bool = @splat(true);

pub fn appendPlayer(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    player: game.Player,
    holding_item: bool,
    partial_ticks: f32,
) !void {
    return appendBiped(mesh, gpa, world_map, player, holding_item, partial_ticks, mob_model.biped, &all_biped_parts_shown);
}

pub fn appendPlayerArmor(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    player: game.Player,
    holding_item: bool,
    partial_ticks: f32,
    layer: mob_model.ArmorLayer,
) !void {
    return appendBiped(mesh, gpa, world_map, player, holding_item, partial_ticks, layer.model, &layer.visible);
}

fn appendBiped(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    player: game.Player,
    holding_item: bool,
    partial_ticks: f32,
    model: mob_model.Model,
    shown: []const bool,
) !void {
    const first_vertex = mesh.vertices.items.len;
    const pos = player.base.renderPosition(partial_ticks);

    const parts = mob_model.bipedPosed(model, .{
        .limb_swing = player.limbSwingPhase(partial_ticks),
        .limb_swing_amount = player.limbSwingAmount(partial_ticks),
        .head_yaw = player.headYaw(partial_ticks),
        .head_pitch = player.headPitch(partial_ticks),
        .swing_progress = player.swingProgress(partial_ticks),
        .holding_item = holding_item,
        .sneaking = player.base.sneaking,
    });

    const pose: mob_model.Pose = .{
        .position = .{ @floatCast(pos.x), @floatCast(pos.y), @floatCast(pos.z) },
        .yaw = player.renderYaw(partial_ticks) * to_radians,
        .scale = player_scale,
    };

    for (parts, shown) |part, visible| {
        if (!visible) continue;
        try mob_model.appendPart(mesh, gpa, part, model.texture_width, model.texture_height, pose);
    }

    mesh.scaleColors(first_vertex, brightnessOf(world_map, player.base));
}

const Trim = struct {
    tint: [3]f32 = untinted,
    wing_flap: f32 = 0,
};

fn appendAnimal(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    animal: game.Animal,
    partial_ticks: f32,
    model: mob_model.Model,
    trim: Trim,
) !void {
    const first_vertex = mesh.vertices.items.len;
    const pos = animal.base.renderPosition(partial_ticks);

    const pose: mob_model.Pose = .{
        .position = .{ @floatCast(pos.x), @floatCast(pos.y), @floatCast(pos.z) },
        .yaw = animal.renderYaw(partial_ticks) * to_radians,
        .roll = animal.deathTilt(partial_ticks) * to_radians,
    };

    const stride = @cos(animal.limbSwingPhase(partial_ticks) * 0.6662) * 1.4 * animal.limbSwingAmount(partial_ticks);

    for (model.parts) |part| {
        var p = part;
        switch (part.role) {
            .head => {
                p.rotate_y = animal.headYaw(partial_ticks) * to_radians;
                p.rotate_x = animal.headPitch(partial_ticks) * to_radians;
            },
            .leg_ahead => p.rotate_x = stride,
            .leg_behind => p.rotate_x = -stride,
            .wing_right => p.rotate_z = trim.wing_flap,
            .wing_left => p.rotate_z = -trim.wing_flap,
            .still => {},
        }
        try mob_model.appendPart(mesh, gpa, p, model.texture_width, model.texture_height, pose);
    }

    const brightness = brightnessOf(world_map, animal.base);
    mesh.scaleColors(first_vertex, brightness);
    tintColors(mesh, first_vertex, trim.tint);
    if (animal.hurt_time > 0 or animal.death_time > 0) tintRed(mesh, first_vertex, brightness);
}

fn tintColors(mesh: *MeshBuilder, first_vertex: usize, tint: [3]f32) void {
    for (mesh.vertices.items[first_vertex..]) |*vertex| {
        for (0..3) |channel| {
            vertex.color[channel] = @intFromFloat(@as(f32, @floatFromInt(vertex.color[channel])) * tint[channel]);
        }
    }
}

fn tintRed(mesh: *MeshBuilder, first_vertex: usize, brightness: f32) void {
    const red: f32 = brightness * 255.0 * hurt_tint;
    for (mesh.vertices.items[first_vertex..]) |*vertex| {
        const kept = 1.0 - hurt_tint;
        vertex.color[0] = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(vertex.color[0])) * kept + red));
        vertex.color[1] = @intFromFloat(@as(f32, @floatFromInt(vertex.color[1])) * kept);
        vertex.color[2] = @intFromFloat(@as(f32, @floatFromInt(vertex.color[2])) * kept);
    }
}

pub const CameraBasis = struct {
    right_x: f32,
    up_y: f32,
    right_z: f32,
    tilt_x: f32,
    tilt_z: f32,

    pub fn fromLook(yaw_degrees: f32, pitch_degrees: f32) CameraBasis {
        const degrees = std.math.pi / 180.0;
        const cos_yaw = math.util.cos(yaw_degrees * degrees);
        const sin_yaw = math.util.sin(yaw_degrees * degrees);
        const sin_pitch = math.util.sin(pitch_degrees * degrees);
        return .{
            .right_x = cos_yaw,
            .up_y = math.util.cos(pitch_degrees * degrees),
            .right_z = sin_yaw,
            .tilt_x = -sin_yaw * sin_pitch,
            .tilt_z = cos_yaw * sin_pitch,
        };
    }
};

pub fn appendParticle(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    particle: game.Particle,
    basis: CameraBasis,
    partial_ticks: f32,
) !void {
    const pos = particle.base.renderPosition(partial_ticks);
    const cx: f32 = @floatCast(pos.x);
    const cy: f32 = @floatCast(pos.y);
    const cz: f32 = @floatCast(pos.z);
    const half = particle.halfSize(partial_ticks);

    const tile_size: f32 = 1.0 / 16.0;
    const quarter: f32 = 0.999 / 64.0;
    var left = @as(f32, @floatFromInt(particle.tile % 16)) * tile_size;
    var top = @as(f32, @floatFromInt(particle.tile / 16)) * tile_size;
    var right = left + 0.999 / 16.0;
    var bottom = top + 0.999 / 16.0;
    if (particle.kind == .digging) {
        left += particle.jitter_u / 4.0 * tile_size;
        top += particle.jitter_v / 4.0 * tile_size;
        right = left + quarter;
        bottom = top + quarter;
    }

    const positions = [4][3]f32{
        .{ cx - basis.right_x * half - basis.tilt_x * half, cy - basis.up_y * half, cz - basis.right_z * half - basis.tilt_z * half },
        .{ cx - basis.right_x * half + basis.tilt_x * half, cy + basis.up_y * half, cz - basis.right_z * half + basis.tilt_z * half },
        .{ cx + basis.right_x * half + basis.tilt_x * half, cy + basis.up_y * half, cz + basis.right_z * half + basis.tilt_z * half },
        .{ cx + basis.right_x * half - basis.tilt_x * half, cy - basis.up_y * half, cz + basis.right_z * half - basis.tilt_z * half },
    };
    const uvs = [4][2]f32{ .{ left, bottom }, .{ left, top }, .{ right, top }, .{ right, bottom } };

    const brightness = particle.brightness(brightnessOf(world_map, particle.base), partial_ticks);
    const shade: [4]u8 = .{
        @intFromFloat(particle.color[0] * @as(f32, @floatFromInt(particle.tint[0])) / 255.0 * brightness * 255.0),
        @intFromFloat(particle.color[1] * @as(f32, @floatFromInt(particle.tint[1])) / 255.0 * brightness * 255.0),
        @intFromFloat(particle.color[2] * @as(f32, @floatFromInt(particle.tint[2])) / 255.0 * brightness * 255.0),
        255,
    };
    try mesh.quad(gpa, positions, uvs, shade);
}

test "a particle renders as one camera-facing quad" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    var rand = world.JavaRandom.init(0);
    const particle = game.Particle.spawn(.{ .x = 8, .y = 40, .z = 8 }, .{ .x = 0, .y = 0, .z = 0 }, 1, &rand);
    try appendParticle(&mesh, gpa, &world_map, particle, CameraBasis.fromLook(0, 0), 0);

    try std.testing.expectEqual(@as(usize, 4), mesh.vertices.items.len);
}

test "a particle quad turns to follow the camera" {
    const gpa = std.testing.allocator;
    var facing: MeshBuilder = .{};
    defer facing.deinit(gpa);
    var turned: MeshBuilder = .{};
    defer turned.deinit(gpa);
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    var rand = world.JavaRandom.init(0);
    const particle = game.Particle.spawn(.{ .x = 8, .y = 40, .z = 8 }, .{ .x = 0, .y = 0, .z = 0 }, 1, &rand);
    try appendParticle(&facing, gpa, &world_map, particle, CameraBasis.fromLook(0, 0), 0);
    try appendParticle(&turned, gpa, &world_map, particle, CameraBasis.fromLook(90, 0), 0);

    try std.testing.expect(facing.vertices.items[0].x != turned.vertices.items[0].x);
    try std.testing.expect(facing.vertices.items[0].z != turned.vertices.items[0].z);
}

test "a particle samples only a quarter of its block's tile" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    var rand = world.JavaRandom.init(0);
    const particle = game.Particle.spawn(.{ .x = 8, .y = 40, .z = 8 }, .{ .x = 0, .y = 0, .z = 0 }, 1, &rand);
    try appendParticle(&mesh, gpa, &world_map, particle, CameraBasis.fromLook(0, 0), 0);

    var lowest_u: f32 = std.math.floatMax(f32);
    var highest_u: f32 = -std.math.floatMax(f32);
    for (mesh.vertices.items) |v| {
        lowest_u = @min(lowest_u, v.u);
        highest_u = @max(highest_u, v.u);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0.999 / 64.0), highest_u - lowest_u, 1.0e-6);
}

test "a lava ember samples a whole tile of the particle sheet" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    var rand = world.JavaRandom.init(0);
    const particle = game.Particle.spawnLava(.{ .x = 8, .y = 40, .z = 8 }, &rand);
    try appendParticle(&mesh, gpa, &world_map, particle, CameraBasis.fromLook(0, 0), 0);

    var lowest_u: f32 = std.math.floatMax(f32);
    var highest_u: f32 = -std.math.floatMax(f32);
    for (mesh.vertices.items) |v| {
        lowest_u = @min(lowest_u, v.u);
        highest_u = @max(highest_u, v.u);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0.999 / 16.0), highest_u - lowest_u, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 16.0), lowest_u, 1.0e-6);
}

test "a dropped block renders as a small cube, not a flat cross" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    var rand = world.JavaRandom.init(0);
    const item = game.ItemEntity.spawn(.{ .x = 0, .y = 0, .z = 0 }, .{ .id = .{ .block = .stone }, .count = 1 }, &rand);
    try appendItem(&mesh, gpa, &world_map, item, 0);

    try std.testing.expectEqual(@as(usize, 6 * 4), mesh.vertices.items.len);
}

test "a dropped pine log shows pine bark instead of oak's" {
    const gpa = std.testing.allocator;
    var oak: MeshBuilder = .{};
    defer oak.deinit(gpa);
    var pine: MeshBuilder = .{};
    defer pine.deinit(gpa);
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    var rand = world.JavaRandom.init(0);
    const oak_item = game.ItemEntity.spawn(.{ .x = 0, .y = 0, .z = 0 }, .{ .id = .{ .block = .log }, .count = 1 }, &rand);
    try appendItem(&oak, gpa, &world_map, oak_item, 0);
    const pine_item = game.ItemEntity.spawn(.{ .x = 0, .y = 0, .z = 0 }, .{ .id = .{ .block = .log }, .count = 1, .meta = 1 }, &rand);
    try appendItem(&pine, gpa, &world_map, pine_item, 0);

    var highest_oak_v: f32 = 0;
    for (oak.vertices.items) |v| highest_oak_v = @max(highest_oak_v, v.v);
    var highest_pine_v: f32 = 0;
    for (pine.vertices.items) |v| highest_pine_v = @max(highest_pine_v, v.v);

    try std.testing.expect(highest_oak_v < 7.0 / 16.0);
    try std.testing.expect(highest_pine_v > 7.0 / 16.0);
}

test "a dropped plant keeps the crossing-sprite shape the original gives it" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    var rand = world.JavaRandom.init(0);
    const rose = game.ItemEntity.spawn(.{ .x = 0, .y = 0, .z = 0 }, .{ .id = .{ .block = .rose }, .count = 1 }, &rand);
    try appendItem(&mesh, gpa, &world_map, rose, 0);

    try std.testing.expectEqual(@as(usize, 2 * 4), mesh.vertices.items.len);
}

test "a bigger stack piles up more copies" {
    try std.testing.expectEqual(@as(u8, 1), copiesFor(1));
    try std.testing.expectEqual(@as(u8, 2), copiesFor(2));
    try std.testing.expectEqual(@as(u8, 2), copiesFor(5));
    try std.testing.expectEqual(@as(u8, 3), copiesFor(6));
    try std.testing.expectEqual(@as(u8, 3), copiesFor(20));
    try std.testing.expectEqual(@as(u8, 4), copiesFor(21));
}

test "a stack of twenty one draws four cubes" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    var rand = world.JavaRandom.init(0);
    const pile = game.ItemEntity.spawn(.{ .x = 0, .y = 0, .z = 0 }, .{ .id = .{ .block = .stone }, .count = 21 }, &rand);
    try appendItem(&mesh, gpa, &world_map, pile, 0);

    try std.testing.expectEqual(@as(usize, 4 * 6 * 4), mesh.vertices.items.len);
}

test "a dropped item bobs and a dropped block also spins" {
    try std.testing.expect(bobHeight(0, 0, 0) != bobHeight(10, 0, 0));
    try std.testing.expect(spinRadians(0, 0, 0) != spinRadians(10, 0, 0));

    const gpa = std.testing.allocator;
    var early: MeshBuilder = .{};
    defer early.deinit(gpa);
    var later: MeshBuilder = .{};
    defer later.deinit(gpa);
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    var rand = world.JavaRandom.init(0);
    var item = game.ItemEntity.spawn(.{ .x = 0, .y = 0, .z = 0 }, .{ .id = .{ .block = .stone }, .count = 1 }, &rand);
    try appendItem(&early, gpa, &world_map, item, 0);
    item.age = 10;
    try appendItem(&later, gpa, &world_map, item, 0);

    try std.testing.expect(early.vertices.items[0].y != later.vertices.items[0].y);
    try std.testing.expect(early.vertices.items[0].x != later.vertices.items[0].x);
}

test "a true item stack has no world geometry yet" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    var rand = world.JavaRandom.init(0);
    const item = game.ItemEntity.spawn(.{ .x = 0, .y = 0, .z = 0 }, .{ .id = .{ .item = .coal }, .count = 1 }, &rand);
    try appendItem(&mesh, gpa, &world_map, item, 0);

    try std.testing.expectEqual(@as(usize, 0), mesh.vertices.items.len);
}

test "a falling block renders as a full cube" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    const block = game.FallingBlock.spawn(.{ .x = 0, .y = 0, .z = 0 }, .sand);
    try appendFallingBlock(&mesh, gpa, &world_map, block, 0);

    try std.testing.expectEqual(@as(usize, 6 * 4), mesh.vertices.items.len);
}

test "a pig renders all six body parts" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    const pig = game.Pig.spawn(.{ .x = 0, .y = 0, .z = 0 });
    try appendPig(&mesh, gpa, &world_map, pig, 0);

    try std.testing.expectEqual(@as(usize, 6 * 6 * 4), mesh.vertices.items.len);
}

fn meshBounds(mesh: MeshBuilder) [2][3]f32 {
    var min: [3]f32 = .{ 1.0e9, 1.0e9, 1.0e9 };
    var max: [3]f32 = .{ -1.0e9, -1.0e9, -1.0e9 };
    for (mesh.vertices.items) |v| {
        min = .{ @min(min[0], v.x), @min(min[1], v.y), @min(min[2], v.z) };
        max = .{ @max(max[0], v.x), @max(max[1], v.y), @max(max[2], v.z) };
    }
    return .{ min, max };
}

test "the pig model stands on its own feet instead of hanging below them" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    const pig = game.Pig.spawn(.{ .x = 0, .y = 64, .z = 0 });
    try appendPig(&mesh, gpa, &world_map, pig, 0);

    const bounds = meshBounds(mesh);
    try std.testing.expectApproxEqAbs(@as(f32, 64.0), bounds[0][1], 1.0e-5);
    try std.testing.expect(bounds[1][1] > 64.0);
    try std.testing.expect(bounds[1][1] < 64.0 + 1.2);
}

test "the pig's head is drawn on the side it walks toward" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);
    try appendPig(&mesh, gpa, &world_map, game.Pig.spawn(.{ .x = 0, .y = 0, .z = 0 }), 0);

    const per_part = 6 * 4;
    var head_z: f32 = 0;
    for (mesh.vertices.items[0..per_part]) |v| head_z += v.z;
    head_z /= @floatFromInt(per_part);

    var body_z: f32 = 0;
    for (mesh.vertices.items[per_part .. 2 * per_part]) |v| body_z += v.z;
    body_z /= @floatFromInt(per_part);

    try std.testing.expect(head_z > body_z);
    try std.testing.expect(head_z > 0.0);
}

test "a walking pig swings diagonal legs together and opposite legs apart" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    var pig = game.Pig.spawn(.{ .x = 0, .y = 0, .z = 0 });
    pig.animal.limb_swing = 1.0;
    pig.animal.limb_swing_amount = 1.0;
    pig.animal.prev_limb_swing_amount = 1.0;

    var walking: MeshBuilder = .{};
    defer walking.deinit(gpa);
    try appendPig(&walking, gpa, &world_map, pig, 1.0);

    const rear_left = legReach(walking, 2);
    const rear_right = legReach(walking, 3);
    const front_left = legReach(walking, 4);
    const front_right = legReach(walking, 5);

    try std.testing.expect(rear_left != rear_right);
    try std.testing.expectApproxEqAbs(rear_left, front_right, 1.0e-5);
    try std.testing.expectApproxEqAbs(rear_right, front_left, 1.0e-5);
}

fn legReach(mesh: MeshBuilder, part_index: usize) f32 {
    const per_part = 6 * 4;
    const pivot_z = -mob_model.pig.parts[part_index].pivot[2] / 16.0;

    var reach: f32 = -1.0e9;
    for (mesh.vertices.items[part_index * per_part ..][0..per_part]) |v| {
        reach = @max(reach, v.z);
    }
    return reach - pivot_z;
}

test "a standing pig holds all four legs still" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    var still: MeshBuilder = .{};
    defer still.deinit(gpa);
    const pig = game.Pig.spawn(.{ .x = 0, .y = 0, .z = 0 });
    try appendPig(&still, gpa, &world_map, pig, 0);

    const per_part = 6 * 4;
    for (0..4) |leg| {
        const vertices = still.vertices.items[(2 + leg) * per_part ..][0..per_part];
        for (vertices) |v| try std.testing.expect(v.y <= 0.5);
    }
}

test "turning the head moves the head without moving the body" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    var straight: MeshBuilder = .{};
    defer straight.deinit(gpa);
    var turned: MeshBuilder = .{};
    defer turned.deinit(gpa);

    const pig = game.Pig.spawn(.{ .x = 0, .y = 0, .z = 0 });
    try appendPig(&straight, gpa, &world_map, pig, 0);

    var looking = pig;
    looking.animal.yaw = 60;
    looking.animal.prev_yaw = 60;
    try appendPig(&turned, gpa, &world_map, looking, 0);

    const per_part = 6 * 4;
    var head_moved = false;
    for (straight.vertices.items[0..per_part], turned.vertices.items[0..per_part]) |a, b| {
        if (@abs(a.x - b.x) > 1.0e-4) head_moved = true;
    }
    try std.testing.expect(head_moved);

    for (straight.vertices.items[per_part .. 2 * per_part], turned.vertices.items[per_part .. 2 * per_part]) |a, b| {
        try std.testing.expectApproxEqAbs(a.x, b.x, 1.0e-5);
        try std.testing.expectApproxEqAbs(a.z, b.z, 1.0e-5);
    }
}

test "a hurt pig flashes red and a healthy one does not" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    const chunk = try world_map.createChunk(0, 0);
    for (0..world.Chunk.width) |x| {
        for (0..world.Chunk.width) |z| chunk.setSkyLight(@intCast(x), 1, @intCast(z), 15);
    }

    var healthy: MeshBuilder = .{};
    defer healthy.deinit(gpa);
    var hurt: MeshBuilder = .{};
    defer hurt.deinit(gpa);

    const pig = game.Pig.spawn(.{ .x = 8, .y = 1, .z = 8 });
    try appendPig(&healthy, gpa, &world_map, pig, 0);

    var wounded = pig;
    wounded.animal.hurt_time = 10;
    try appendPig(&hurt, gpa, &world_map, wounded, 0);

    const healthy_red: u32 = healthy.vertices.items[0].color[0];
    const hurt_red: u32 = hurt.vertices.items[0].color[0];
    try std.testing.expect(hurt.vertices.items[0].color[1] < healthy.vertices.items[0].color[1]);
    try std.testing.expect(hurt_red * 4 >= healthy_red * 3);
}

test "the saddle is drawn as a slightly larger skin over the same pose" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    var bare: MeshBuilder = .{};
    defer bare.deinit(gpa);
    var saddled: MeshBuilder = .{};
    defer saddled.deinit(gpa);

    var pig = game.Pig.spawn(.{ .x = 0, .y = 0, .z = 0 });
    pig.saddled = true;
    try appendPig(&bare, gpa, &world_map, pig, 0);
    try appendPigSaddle(&saddled, gpa, &world_map, pig, 0);

    try std.testing.expectEqual(bare.vertices.items.len, saddled.vertices.items.len);

    const bare_bounds = meshBounds(bare);
    const saddle_bounds = meshBounds(saddled);
    try std.testing.expect(saddle_bounds[1][1] > bare_bounds[1][1]);
    try std.testing.expectApproxEqAbs(0.5 / 16.0, saddle_bounds[1][1] - bare_bounds[1][1], 1.0e-5);

    for (bare.vertices.items, saddled.vertices.items) |a, b| {
        try std.testing.expectApproxEqAbs(a.u, b.u, 1.0e-6);
        try std.testing.expectApproxEqAbs(a.v, b.v, 1.0e-6);
    }
}

test "a dying pig rolls onto its side" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    var upright: MeshBuilder = .{};
    defer upright.deinit(gpa);
    var toppled: MeshBuilder = .{};
    defer toppled.deinit(gpa);

    const pig = game.Pig.spawn(.{ .x = 0, .y = 0, .z = 0 });
    try appendPig(&upright, gpa, &world_map, pig, 0);

    var dying = pig;
    dying.animal.death_time = game.Animal.death_ticks;
    try appendPig(&toppled, gpa, &world_map, dying, 1.0);

    const upright_bounds = meshBounds(upright);
    const toppled_bounds = meshBounds(toppled);
    try std.testing.expect(toppled_bounds[1][1] < upright_bounds[1][1]);
    try std.testing.expect(toppled_bounds[1][0] - toppled_bounds[0][0] > upright_bounds[1][0] - upright_bounds[0][0]);
}

fn testSheep(position: math.Vec3, color: u4) game.Sheep {
    var rand = world.JavaRandom.init(0);
    var sheep = game.Sheep.spawn(position, &rand);
    sheep.fleece_color = color;
    return sheep;
}

test "a sheep is drawn taller than a pig and stands on its own feet" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    var body: MeshBuilder = .{};
    defer body.deinit(gpa);
    var pig: MeshBuilder = .{};
    defer pig.deinit(gpa);

    try appendSheep(&body, gpa, &world_map, testSheep(.{ .x = 0, .y = 64, .z = 0 }, 0), 0);
    try appendPig(&pig, gpa, &world_map, game.Pig.spawn(.{ .x = 0, .y = 64, .z = 0 }), 0);

    try std.testing.expectEqual(@as(usize, 6 * 6 * 4), body.vertices.items.len);

    const sheep_bounds = meshBounds(body);
    const pig_bounds = meshBounds(pig);
    try std.testing.expectApproxEqAbs(@as(f32, 64.0), sheep_bounds[0][1], 1.0e-5);
    try std.testing.expect(sheep_bounds[1][1] > pig_bounds[1][1]);
    try std.testing.expect(sheep_bounds[1][1] < 64.0 + game.Sheep.height + 0.2);
}

test "the fleece is worn outside the body it covers" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    const sheep = testSheep(.{ .x = 0, .y = 0, .z = 0 }, 0);

    var body: MeshBuilder = .{};
    defer body.deinit(gpa);
    var fur: MeshBuilder = .{};
    defer fur.deinit(gpa);
    try appendSheep(&body, gpa, &world_map, sheep, 0);
    try appendSheepFur(&fur, gpa, &world_map, sheep, 0);

    const body_bounds = meshBounds(body);
    const fur_bounds = meshBounds(fur);

    // The fleece is grown around the flanks, stops short of the muzzle, and only reaches
    // halfway down the legs.
    try std.testing.expect(fur_bounds[1][0] > body_bounds[1][0]);
    try std.testing.expect(fur_bounds[0][0] < body_bounds[0][0]);
    try std.testing.expect(fur_bounds[1][2] < body_bounds[1][2]);
    try std.testing.expect(fur_bounds[0][1] > body_bounds[0][1]);
}

test "the fleece takes the sheep's colour and the body underneath stays white" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    const chunk = try world_map.createChunk(0, 0);
    for (0..world.Chunk.width) |x| {
        for (0..world.Chunk.width) |z| chunk.setSkyLight(@intCast(x), 1, @intCast(z), 15);
    }

    var white_fur: MeshBuilder = .{};
    defer white_fur.deinit(gpa);
    var black_fur: MeshBuilder = .{};
    defer black_fur.deinit(gpa);
    var black_body: MeshBuilder = .{};
    defer black_body.deinit(gpa);

    const position = math.Vec3{ .x = 8, .y = 1, .z = 8 };
    try appendSheepFur(&white_fur, gpa, &world_map, testSheep(position, 0), 0);
    try appendSheepFur(&black_fur, gpa, &world_map, testSheep(position, 15), 0);
    try appendSheep(&black_body, gpa, &world_map, testSheep(position, 15), 0);

    try std.testing.expectEqual(@as(u8, 255), white_fur.vertices.items[0].color[0]);
    try std.testing.expect(black_fur.vertices.items[0].color[0] < 40);
    try std.testing.expectEqual(@as(u8, 255), black_body.vertices.items[0].color[0]);
}

test "every wool colour has a fleece tint to draw it with" {
    try std.testing.expectEqual(@as(usize, 16), fleece_colors.len);
    for (fleece_colors) |color| {
        for (color) |channel| try std.testing.expect(channel > 0.0 and channel <= 1.0);
    }
    try std.testing.expectEqual([3]f32{ 1, 1, 1 }, fleece_colors[0]);
}

test "a hurt sheep flashes red through its fleece" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    const chunk = try world_map.createChunk(0, 0);
    for (0..world.Chunk.width) |x| {
        for (0..world.Chunk.width) |z| chunk.setSkyLight(@intCast(x), 1, @intCast(z), 15);
    }

    var calm: MeshBuilder = .{};
    defer calm.deinit(gpa);
    var hurt: MeshBuilder = .{};
    defer hurt.deinit(gpa);

    const sheep = testSheep(.{ .x = 8, .y = 1, .z = 8 }, 15);
    try appendSheepFur(&calm, gpa, &world_map, sheep, 0);

    var wounded = sheep;
    wounded.animal.hurt_time = 10;
    try appendSheepFur(&hurt, gpa, &world_map, wounded, 0);

    try std.testing.expect(hurt.vertices.items[0].color[0] > calm.vertices.items[0].color[0]);
}

fn partVertices(mesh: MeshBuilder, part_index: usize) []const MeshBuilder.Vertex {
    const per_part = 6 * 4;
    return mesh.vertices.items[part_index * per_part ..][0..per_part];
}

fn partBounds(mesh: MeshBuilder, part_index: usize) [2][3]f32 {
    var min: [3]f32 = .{ 1.0e9, 1.0e9, 1.0e9 };
    var max: [3]f32 = .{ -1.0e9, -1.0e9, -1.0e9 };
    for (partVertices(mesh, part_index)) |v| {
        min = .{ @min(min[0], v.x), @min(min[1], v.y), @min(min[2], v.z) };
        max = .{ @max(max[0], v.x), @max(max[1], v.y), @max(max[2], v.z) };
    }
    return .{ min, max };
}

const cow_head = 0;
const cow_horn_left = 1;
const cow_horn_right = 2;
const cow_body = 3;
const cow_udder = 4;

test "a cow renders its head, both horns, its body, its udder and four legs" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    try appendCow(&mesh, gpa, &world_map, game.Cow.spawn(.{ .x = 0, .y = 64, .z = 0 }), 0);

    try std.testing.expectEqual(@as(usize, 9 * 6 * 4), mesh.vertices.items.len);

    // The cow stands on its own feet, and — as in the original — its horns reach above the
    // collision box it walks around in.
    const bounds = meshBounds(mesh);
    try std.testing.expectApproxEqAbs(@as(f32, 64.0), bounds[0][1], 1.0e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 64.0 + 25.0 / 16.0), bounds[1][1], 1.0e-5);
    try std.testing.expect(bounds[1][1] > 64.0 + game.Cow.height);
}

test "a cow's horns sit above its head, one to each side" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    try appendCow(&mesh, gpa, &world_map, game.Cow.spawn(.{ .x = 0, .y = 0, .z = 0 }), 0);

    const head = partBounds(mesh, cow_head);
    const left = partBounds(mesh, cow_horn_left);
    const right = partBounds(mesh, cow_horn_right);

    try std.testing.expect(left[1][1] > head[1][1]);
    try std.testing.expect(right[1][1] > head[1][1]);
    try std.testing.expect(left[0][0] < head[0][0]);
    try std.testing.expect(right[1][0] > head[1][0]);
    try std.testing.expectApproxEqAbs(left[1][1], right[1][1], 1.0e-6);
}

test "a cow's horns turn with the head they grow from" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    var straight: MeshBuilder = .{};
    defer straight.deinit(gpa);
    var turned: MeshBuilder = .{};
    defer turned.deinit(gpa);

    const cow = game.Cow.spawn(.{ .x = 0, .y = 0, .z = 0 });
    try appendCow(&straight, gpa, &world_map, cow, 0);

    var looking = cow;
    looking.animal.yaw = 60;
    looking.animal.prev_yaw = 60;
    try appendCow(&turned, gpa, &world_map, looking, 0);

    for ([_]usize{ cow_horn_left, cow_horn_right }) |horn| {
        var moved = false;
        for (partVertices(straight, horn), partVertices(turned, horn)) |a, b| {
            if (@abs(a.x - b.x) > 1.0e-4) moved = true;
        }
        try std.testing.expect(moved);
    }

    for (partVertices(straight, cow_body), partVertices(turned, cow_body)) |a, b| {
        try std.testing.expectApproxEqAbs(a.x, b.x, 1.0e-5);
    }
}

test "a cow's udder hangs under its belly and stays there as it walks" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    var standing: MeshBuilder = .{};
    defer standing.deinit(gpa);
    var walking: MeshBuilder = .{};
    defer walking.deinit(gpa);

    var cow = game.Cow.spawn(.{ .x = 0, .y = 0, .z = 0 });
    try appendCow(&standing, gpa, &world_map, cow, 0);

    cow.animal.limb_swing = 1.0;
    cow.animal.limb_swing_amount = 1.0;
    cow.animal.prev_limb_swing_amount = 1.0;
    try appendCow(&walking, gpa, &world_map, cow, 1.0);

    const body = partBounds(standing, cow_body);
    const udder = partBounds(standing, cow_udder);
    try std.testing.expect(udder[1][1] <= body[0][1] + 1.0e-5);
    try std.testing.expect(udder[0][0] > body[0][0] and udder[1][0] < body[1][0]);

    for (partVertices(standing, cow_udder), partVertices(walking, cow_udder)) |a, b| {
        try std.testing.expectApproxEqAbs(a.y, b.y, 1.0e-6);
        try std.testing.expectApproxEqAbs(a.z, b.z, 1.0e-6);
    }
}

test "a walking cow swings diagonal legs together, on legs pushed out to the corners" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    var cow = game.Cow.spawn(.{ .x = 0, .y = 0, .z = 0 });
    cow.animal.limb_swing = 1.0;
    cow.animal.limb_swing_amount = 1.0;
    cow.animal.prev_limb_swing_amount = 1.0;

    var walking: MeshBuilder = .{};
    defer walking.deinit(gpa);
    try appendCow(&walking, gpa, &world_map, cow, 1.0);

    const first_leg = 5;
    var reach: [4]f32 = undefined;
    for (&reach, 0..) |*value, leg| {
        const part = first_leg + leg;
        value.* = partBounds(walking, part)[1][2] + mob_model.cow.parts[part].pivot[2] / 16.0;
    }

    try std.testing.expect(reach[0] != reach[1]);
    try std.testing.expectApproxEqAbs(reach[0], reach[3], 1.0e-5);
    try std.testing.expectApproxEqAbs(reach[1], reach[2], 1.0e-5);

    const body = partBounds(walking, cow_body);
    for ([_]usize{ 5, 6, 7, 8 }) |leg| {
        const bounds = partBounds(walking, leg);
        try std.testing.expect(bounds[0][0] >= body[0][0] and bounds[1][0] <= body[1][0]);
    }
}

test "a chicken renders its head, bill, chin, body, two legs and two wings" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    var rand = world.JavaRandom.init(0);
    try appendChicken(&mesh, gpa, &world_map, game.Chicken.spawn(.{ .x = 0, .y = 64, .z = 0 }, &rand), 0);

    try std.testing.expectEqual(@as(usize, 8 * 6 * 4), mesh.vertices.items.len);

    const bounds = meshBounds(mesh);
    try std.testing.expectApproxEqAbs(@as(f32, 64.0), bounds[0][1], 1.0e-5);
    try std.testing.expect(bounds[1][1] > 64.0 + game.Chicken.height);
}

test "a chicken's wings throw out to opposite sides as they beat" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    var rand = world.JavaRandom.init(0);
    var chicken = game.Chicken.spawn(.{ .x = 0, .y = 0, .z = 0 }, &rand);

    var folded: MeshBuilder = .{};
    defer folded.deinit(gpa);
    try appendChicken(&folded, gpa, &world_map, chicken, 0);

    // Mid-beat, off the ground: the wings are thrown as far out as they go.
    chicken.wing_rotation = std.math.pi / 2.0;
    chicken.prev_wing_rotation = chicken.wing_rotation;
    chicken.wing_reach = 1.0;
    chicken.prev_wing_reach = 1.0;
    try std.testing.expect(chicken.wingFlap(1.0) > 1.0);

    var beating: MeshBuilder = .{};
    defer beating.deinit(gpa);
    try appendChicken(&beating, gpa, &world_map, chicken, 1.0);

    const right_wing = 6;
    const left_wing = 7;
    const folded_right = partBounds(folded, right_wing);
    const beating_right = partBounds(beating, right_wing);
    const folded_left = partBounds(folded, left_wing);
    const beating_left = partBounds(beating, left_wing);

    try std.testing.expect(beating_right[0][1] != folded_right[0][1]);
    try std.testing.expect(beating_left[0][1] != folded_left[0][1]);

    // The two wings mirror one another about the body.
    try std.testing.expectApproxEqAbs(beating_right[0][1], beating_left[0][1], 1.0e-5);
    try std.testing.expectApproxEqAbs(-beating_right[1][0], beating_left[0][0], 1.0e-5);
}

test "an entity in the open is lit brighter than one sealed in the dark" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    const chunk = try world_map.createChunk(0, 0);
    for (0..world.Chunk.width) |x| {
        for (0..world.Chunk.width) |z| {
            chunk.setBlock(@intCast(x), 0, @intCast(z), .stone);
            if (x >= 8) chunk.setBlock(@intCast(x), 4, @intCast(z), .stone);
        }
    }
    try world.light.relightChunk(gpa, &world_map, 0, 0);

    var lit: MeshBuilder = .{};
    defer lit.deinit(gpa);
    var dark: MeshBuilder = .{};
    defer dark.deinit(gpa);

    try appendPig(&lit, gpa, &world_map, game.Pig.spawn(.{ .x = 2, .y = 1, .z = 8 }), 0);
    try appendPig(&dark, gpa, &world_map, game.Pig.spawn(.{ .x = 14, .y = 1, .z = 8 }), 0);

    try std.testing.expectEqual(@as(u8, 255), lit.vertices.items[0].color[0]);
    try std.testing.expect(dark.vertices.items[0].color[0] < 255);
}

test "an entity samples light two thirds of the way up its own box" {
    const pig = game.Pig.spawn(.{ .x = 3.7, .y = 64.0, .z = -2.2 });
    const sample = pig.animal.base.lightSamplePosition();
    try std.testing.expectEqual(@as(i32, 3), sample[0]);
    try std.testing.expectEqual(@as(i32, -3), sample[2]);
    try std.testing.expectEqual(@as(i32, 64), sample[1]);
    try std.testing.expect(pig.animal.base.height * 0.66 < 1.0);
}

test "a true item stack renders from the items atlas" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    var rand = world.JavaRandom.init(0);
    const coal = game.ItemEntity.spawn(.{ .x = 0, .y = 0, .z = 0 }, .{ .id = .{ .item = .coal }, .count = 1 }, &rand);
    try appendItemIcon(&mesh, gpa, &world_map, coal, 0, 0);

    try std.testing.expectEqual(@as(usize, 4), mesh.vertices.items.len);

    const expected = Atlas.tileUv(world.Item.iconTile(world.Item.coal, 0).?);
    try std.testing.expectApproxEqAbs(expected.u0, mesh.vertices.items[0].u, 1.0e-6);
}

test "the two item paths never both claim the same stack" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    var rand = world.JavaRandom.init(0);
    const stone = game.ItemEntity.spawn(.{ .x = 0, .y = 0, .z = 0 }, .{ .id = .{ .block = .stone }, .count = 1 }, &rand);
    try appendItemIcon(&mesh, gpa, &world_map, stone, 0, 0);
    try std.testing.expectEqual(@as(usize, 0), mesh.vertices.items.len);

    const coal = game.ItemEntity.spawn(.{ .x = 0, .y = 0, .z = 0 }, .{ .id = .{ .item = .coal }, .count = 1 }, &rand);
    try appendItem(&mesh, gpa, &world_map, coal, 0);
    try std.testing.expectEqual(@as(usize, 0), mesh.vertices.items.len);
}

test "a fresh flame is drawn at full white and dims to the light around it" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    var rand = world.JavaRandom.init(0);
    var particle = game.Particle.spawnFlame(.{ .x = 8, .y = 40, .z = 8 }, .{ .x = 0, .y = 0, .z = 0 }, &rand);

    var fresh: MeshBuilder = .{};
    defer fresh.deinit(gpa);
    try appendParticle(&fresh, gpa, &world_map, particle, CameraBasis.fromLook(0, 0), 0);
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, fresh.vertices.items[0].color);

    particle.age = particle.max_age;
    var spent: MeshBuilder = .{};
    defer spent.deinit(gpa);
    try appendParticle(&spent, gpa, &world_map, particle, CameraBasis.fromLook(0, 0), 0);
    try std.testing.expect(spent.vertices.items[0].color[0] < 255);
}

test "a flame samples a whole tile of the particle sheet, not a quarter" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    var rand = world.JavaRandom.init(0);
    const particle = game.Particle.spawnFlame(.{ .x = 8, .y = 40, .z = 8 }, .{ .x = 0, .y = 0, .z = 0 }, &rand);
    try appendParticle(&mesh, gpa, &world_map, particle, CameraBasis.fromLook(0, 0), 0);

    var lowest_u: f32 = std.math.floatMax(f32);
    var highest_u: f32 = -std.math.floatMax(f32);
    for (mesh.vertices.items) |v| {
        lowest_u = @min(lowest_u, v.u);
        highest_u = @max(highest_u, v.u);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0.999 / 16.0), highest_u - lowest_u, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), lowest_u, 1.0e-6);
}

const painting_atlas: f32 = 256.0;
const painting_back_u0: f32 = 12.0 / 16.0;
const painting_back_u1: f32 = 13.0 / 16.0;
const painting_back_v0: f32 = 0.0;
const painting_back_v1: f32 = 1.0 / 16.0;
const painting_edge_u: f32 = 385.0 / 512.0;
const painting_edge_v: f32 = 0.001953125;

fn paintingTileBrightness(
    world_map: *const world.World,
    painting: game.Painting,
    across: f32,
    up: f32,
) f32 {
    var x = math.util.floorDouble(painting.position.x);
    const y = math.util.floorDouble(painting.position.y + @as(f64, up / 16.0));
    var z = math.util.floorDouble(painting.position.z);
    switch (painting.direction) {
        0 => x = math.util.floorDouble(painting.position.x + @as(f64, across / 16.0)),
        1 => z = math.util.floorDouble(painting.position.z - @as(f64, across / 16.0)),
        2 => x = math.util.floorDouble(painting.position.x - @as(f64, across / 16.0)),
        3 => z = math.util.floorDouble(painting.position.z + @as(f64, across / 16.0)),
    }
    return world.light.brightnessAt(world_map, x, y, z, 0);
}

pub fn appendPainting(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    painting: game.Painting,
) !void {
    const size = painting.art.info();
    const wide: f32 = @floatFromInt(size.size_x);
    const tall: f32 = @floatFromInt(size.size_y);
    const left = -wide / 2.0;
    const bottom = -tall / 2.0;
    const back: f32 = -0.5;
    const front: f32 = 0.5;

    const yaw = painting.yaw() * to_radians;
    const sin = @sin(yaw);
    const cos = @cos(yaw);
    const origin_x: f32 = @floatCast(painting.position.x);
    const origin_y: f32 = @floatCast(painting.position.y);
    const origin_z: f32 = @floatCast(painting.position.z);

    const put = struct {
        fn at(x: f32, y: f32, z: f32, s: f32, c: f32, ox: f32, oy: f32, oz: f32) [3]f32 {
            const sx = x / 16.0;
            const sy = y / 16.0;
            const sz = z / 16.0;
            return .{ ox + sx * c + sz * s, oy + sy, oz - sx * s + sz * c };
        }
    }.at;

    for (0..size.size_x / 16) |column| {
        for (0..size.size_y / 16) |row| {
            const step: f32 = @floatFromInt(column);
            const lift: f32 = @floatFromInt(row);
            const right = left + (step + 1.0) * 16.0;
            const near = left + step * 16.0;
            const top = bottom + (lift + 1.0) * 16.0;
            const low = bottom + lift * 16.0;

            const shade = paintingTileBrightness(world_map, painting, (right + near) / 2.0, (top + low) / 2.0);
            const tile_first = mesh.vertices.items.len;
            const colour: [4]u8 = .{ 255, 255, 255, 255 };

            const u_near = @as(f32, @floatFromInt(size.offset_x + size.size_x)) / painting_atlas - step * 16.0 / painting_atlas;
            const u_far = @as(f32, @floatFromInt(size.offset_x + size.size_x)) / painting_atlas - (step + 1.0) * 16.0 / painting_atlas;
            const v_near = @as(f32, @floatFromInt(size.offset_y + size.size_y)) / painting_atlas - lift * 16.0 / painting_atlas;
            const v_far = @as(f32, @floatFromInt(size.offset_y + size.size_y)) / painting_atlas - (lift + 1.0) * 16.0 / painting_atlas;

            try mesh.quad(gpa, .{
                put(right, low, back, sin, cos, origin_x, origin_y, origin_z),
                put(near, low, back, sin, cos, origin_x, origin_y, origin_z),
                put(near, top, back, sin, cos, origin_x, origin_y, origin_z),
                put(right, top, back, sin, cos, origin_x, origin_y, origin_z),
            }, .{ .{ u_far, v_near }, .{ u_near, v_near }, .{ u_near, v_far }, .{ u_far, v_far } }, colour);

            try mesh.quad(gpa, .{
                put(right, top, front, sin, cos, origin_x, origin_y, origin_z),
                put(near, top, front, sin, cos, origin_x, origin_y, origin_z),
                put(near, low, front, sin, cos, origin_x, origin_y, origin_z),
                put(right, low, front, sin, cos, origin_x, origin_y, origin_z),
            }, .{
                .{ painting_back_u0, painting_back_v0 },
                .{ painting_back_u1, painting_back_v0 },
                .{ painting_back_u1, painting_back_v1 },
                .{ painting_back_u0, painting_back_v1 },
            }, colour);

            try mesh.quad(gpa, .{
                put(right, top, back, sin, cos, origin_x, origin_y, origin_z),
                put(near, top, back, sin, cos, origin_x, origin_y, origin_z),
                put(near, top, front, sin, cos, origin_x, origin_y, origin_z),
                put(right, top, front, sin, cos, origin_x, origin_y, origin_z),
            }, .{
                .{ painting_back_u0, painting_edge_v },
                .{ painting_back_u1, painting_edge_v },
                .{ painting_back_u1, painting_edge_v },
                .{ painting_back_u0, painting_edge_v },
            }, colour);

            try mesh.quad(gpa, .{
                put(right, low, front, sin, cos, origin_x, origin_y, origin_z),
                put(near, low, front, sin, cos, origin_x, origin_y, origin_z),
                put(near, low, back, sin, cos, origin_x, origin_y, origin_z),
                put(right, low, back, sin, cos, origin_x, origin_y, origin_z),
            }, .{
                .{ painting_back_u0, painting_edge_v },
                .{ painting_back_u1, painting_edge_v },
                .{ painting_back_u1, painting_edge_v },
                .{ painting_back_u0, painting_edge_v },
            }, colour);

            try mesh.quad(gpa, .{
                put(right, top, front, sin, cos, origin_x, origin_y, origin_z),
                put(right, low, front, sin, cos, origin_x, origin_y, origin_z),
                put(right, low, back, sin, cos, origin_x, origin_y, origin_z),
                put(right, top, back, sin, cos, origin_x, origin_y, origin_z),
            }, .{
                .{ painting_edge_u, 0.0 },
                .{ painting_edge_u, painting_back_v1 },
                .{ painting_edge_u, painting_back_v1 },
                .{ painting_edge_u, 0.0 },
            }, colour);

            try mesh.quad(gpa, .{
                put(near, top, back, sin, cos, origin_x, origin_y, origin_z),
                put(near, low, back, sin, cos, origin_x, origin_y, origin_z),
                put(near, low, front, sin, cos, origin_x, origin_y, origin_z),
                put(near, top, front, sin, cos, origin_x, origin_y, origin_z),
            }, .{
                .{ painting_edge_u, 0.0 },
                .{ painting_edge_u, painting_back_v1 },
                .{ painting_edge_u, painting_back_v1 },
                .{ painting_edge_u, 0.0 },
            }, colour);

            mesh.scaleColors(tile_first, shade);
        }
    }
}
