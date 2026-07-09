const std = @import("std");
const game = @import("game");
const math = @import("math");
const world = @import("world");

const Atlas = @import("atlas.zig");
const MeshBuilder = @import("mesh_builder.zig");
const chunk_mesher = @import("chunk_mesher.zig");
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

    if (id.isCross()) {
        const tile = id.crossTile(item.stack.meta);
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
        var inset: f32 = 0.0;
        fn build(target: *MeshBuilder, gpa_inner: std.mem.Allocator) anyerror!void {
            const half = block_scale / 2.0;
            try chunk_mesher.buildCube(target, gpa_inner, .{ -half, -half, -half }, .{ half, half, half }, faces, inset);
        }
    };
    Cube.faces = id.faceTextures();
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
        .item => |i| i.iconTile() orelse return,
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

pub fn appendPig(mesh: *MeshBuilder, gpa: std.mem.Allocator, world_map: *const world.World, pig: game.Pig, partial_ticks: f32) !void {
    const first_vertex = mesh.vertices.items.len;
    const pos = pig.base.renderPosition(partial_ticks);
    const entity_pos = [3]f32{ @floatCast(pos.x), @floatCast(pos.y), @floatCast(pos.z) };
    const yaw_rad = pig.yaw * std.math.pi / 180.0;
    const swing = @cos(pig.walk_distance * 0.6662) * 1.4;

    for (mob_model.pig.parts, 0..) |part, i| {
        var p = part;
        if (i >= 2) p.rotate_x = if (i == 2 or i == 5) swing else -swing;
        try mob_model.appendPart(mesh, gpa, p, mob_model.pig.texture_width, mob_model.pig.texture_height, entity_pos, yaw_rad);
    }

    mesh.scaleColors(first_vertex, brightnessOf(world_map, pig.base));
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
    const half = particle.halfSize();

    const tile_size: f32 = 1.0 / 16.0;
    const quarter: f32 = 0.999 / 64.0;
    const left = (@as(f32, @floatFromInt(particle.tile % 16)) + particle.jitter_u / 4.0) * tile_size;
    const top = (@as(f32, @floatFromInt(particle.tile / 16)) + particle.jitter_v / 4.0) * tile_size;
    const right = left + quarter;
    const bottom = top + quarter;

    const positions = [4][3]f32{
        .{ cx - basis.right_x * half - basis.tilt_x * half, cy - basis.up_y * half, cz - basis.right_z * half - basis.tilt_z * half },
        .{ cx - basis.right_x * half + basis.tilt_x * half, cy + basis.up_y * half, cz - basis.right_z * half + basis.tilt_z * half },
        .{ cx + basis.right_x * half + basis.tilt_x * half, cy + basis.up_y * half, cz + basis.right_z * half + basis.tilt_z * half },
        .{ cx + basis.right_x * half - basis.tilt_x * half, cy - basis.up_y * half, cz + basis.right_z * half - basis.tilt_z * half },
    };
    const uvs = [4][2]f32{ .{ left, bottom }, .{ left, top }, .{ right, top }, .{ right, bottom } };

    const brightness = brightnessOf(world_map, particle.base);
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

    const block = game.FallingBlock.spawn(.{ .x = 0, .y = 0, .z = 0 }, world.Block.sand);
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

test "an entity in the open is lit brighter than one sealed in the dark" {
    const gpa = std.testing.allocator;
    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    const chunk = try world_map.createChunk(0, 0);
    for (0..world.Chunk.width) |x| {
        for (0..world.Chunk.width) |z| {
            chunk.setBlock(@intCast(x), 0, @intCast(z), world.Block.stone);
            if (x >= 8) chunk.setBlock(@intCast(x), 4, @intCast(z), world.Block.stone);
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
    const sample = pig.base.lightSamplePosition();
    try std.testing.expectEqual(@as(i32, 3), sample[0]);
    try std.testing.expectEqual(@as(i32, -3), sample[2]);
    try std.testing.expectEqual(@as(i32, 64), sample[1]);
    try std.testing.expect(pig.base.height * 0.66 < 1.0);
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

    const expected = Atlas.tileUv(world.Item.iconTile(world.Item.coal).?);
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
