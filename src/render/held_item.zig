const std = @import("std");
const game = @import("game");
const math = @import("math");
const world = @import("world");

const MeshBuilder = @import("mesh_builder.zig");
const chunk_mesher = @import("chunk_mesher.zig");
const mob_model = @import("mob_model.zig");

const degrees = std.math.pi / 180.0;

pub const equip_speed: f32 = 0.4;
pub const swap_threshold: f32 = 0.1;

pub const Equip = struct {
    progress: f32 = 1.0,
    prev_progress: f32 = 1.0,
    shown: ?game.Inventory.ItemStack = null,

    pub fn tick(self: *Equip, selected: ?game.Inventory.ItemStack) void {
        self.prev_progress = self.progress;

        const unchanged = sameStack(self.shown, selected);
        const target: f32 = if (unchanged) 1.0 else 0.0;
        self.progress += std.math.clamp(target - self.progress, -equip_speed, equip_speed);
        if (self.progress < swap_threshold) self.shown = selected;
    }

    pub fn interpolated(self: Equip, partial_ticks: f32) f32 {
        return self.prev_progress + (self.progress - self.prev_progress) * partial_ticks;
    }
};

fn sameStack(a: ?game.Inventory.ItemStack, b: ?game.Inventory.ItemStack) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.id.eql(b.?.id) and a.?.meta == b.?.meta;
}

pub fn handMatrix(swing: f32, equipped: f32) math.Mat4 {
    const scale: f32 = 0.8;
    const bob = math.util.sin(@sqrt(swing) * std.math.pi);
    const dip = math.util.sin(swing * std.math.pi);

    var transform = math.Mat4.translation(
        -bob * 0.4,
        math.util.sin(@sqrt(swing) * std.math.pi * 2.0) * 0.2,
        -dip * 0.2,
    );
    transform = transform.mul(math.Mat4.translation(
        0.7 * scale,
        -0.65 * scale - (1.0 - equipped) * 0.6,
        -0.9 * scale,
    ));
    transform = transform.mul(math.Mat4.rotationY(45.0 * degrees));

    const twist = math.util.sin(swing * swing * std.math.pi);
    transform = transform.mul(math.Mat4.rotationY(-twist * 20.0 * degrees));
    transform = transform.mul(math.Mat4.rotationZ(-bob * 20.0 * degrees));
    transform = transform.mul(math.Mat4.rotationX(-bob * 80.0 * degrees));

    return transform.mul(math.Mat4.scale(0.4, 0.4, 0.4));
}

pub fn appendBlock(mesh: *MeshBuilder, gpa: std.mem.Allocator, id: world.Block, brightness: f32) !void {
    const first_vertex = mesh.vertices.items.len;
    for (id.itemRenderBoxes()) |bounds| {
        try chunk_mesher.buildBoxCube(
            mesh,
            gpa,
            .{ 0, 0, 0 },
            1.0,
            bounds,
            id.faceTextures(),
            id.sideInset(),
        );
    }
    mesh.scaleColors(first_vertex, brightness);
}

pub const sprite_thickness: f32 = 1.0 / 16.0;
pub const sprite_slices: u32 = 16;
const atlas_size: f32 = 256.0;
const texel_bias: f32 = 0.001953125;

pub fn spriteMatrix() math.Mat4 {
    return math.Mat4.translation(0, -0.3, 0)
        .mul(math.Mat4.scale(1.5, 1.5, 1.5))
        .mul(math.Mat4.rotationY(50.0 * degrees))
        .mul(math.Mat4.rotationZ(335.0 * degrees))
        .mul(math.Mat4.translation(-15.0 / 16.0, -1.0 / 16.0, 0));
}

pub fn appendSprite(mesh: *MeshBuilder, gpa: std.mem.Allocator, tile: u8, brightness: f32) !void {
    const first_vertex = mesh.vertices.items.len;
    const white: [4]u8 = .{ 255, 255, 255, 255 };
    const back = -sprite_thickness;

    const column: f32 = @floatFromInt(@as(u32, tile % 16) * 16);
    const row: f32 = @floatFromInt(@as(u32, tile / 16) * 16);
    const left = column / atlas_size;
    const right = (column + 15.99) / atlas_size;
    const top = row / atlas_size;
    const bottom = (row + 15.99) / atlas_size;

    try mesh.quad(gpa, .{
        .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 1, 1, 0 }, .{ 0, 1, 0 },
    }, .{ .{ right, bottom }, .{ left, bottom }, .{ left, top }, .{ right, top } }, white);

    try mesh.quad(gpa, .{
        .{ 0, 1, back }, .{ 1, 1, back }, .{ 1, 0, back }, .{ 0, 0, back },
    }, .{ .{ right, top }, .{ left, top }, .{ left, bottom }, .{ right, bottom } }, white);

    for (0..sprite_slices) |slice| {
        const along: f32 = @as(f32, @floatFromInt(slice)) / 16.0;
        const u = right + (left - right) * along - texel_bias;
        const v = bottom + (top - bottom) * along - texel_bias;
        const near = along;
        const far = along + 1.0 / 16.0;

        try mesh.quad(gpa, .{
            .{ near, 0, back }, .{ near, 0, 0 }, .{ near, 1, 0 }, .{ near, 1, back },
        }, .{ .{ u, bottom }, .{ u, bottom }, .{ u, top }, .{ u, top } }, white);

        try mesh.quad(gpa, .{
            .{ far, 1, back }, .{ far, 1, 0 }, .{ far, 0, 0 }, .{ far, 0, back },
        }, .{ .{ u, top }, .{ u, top }, .{ u, bottom }, .{ u, bottom } }, white);

        try mesh.quad(gpa, .{
            .{ 0, far, 0 }, .{ 1, far, 0 }, .{ 1, far, back }, .{ 0, far, back },
        }, .{ .{ right, v }, .{ left, v }, .{ left, v }, .{ right, v } }, white);

        try mesh.quad(gpa, .{
            .{ 1, near, 0 }, .{ 0, near, 0 }, .{ 0, near, back }, .{ 1, near, back },
        }, .{ .{ left, v }, .{ right, v }, .{ right, v }, .{ left, v } }, white);
    }

    mesh.scaleColors(first_vertex, brightness);
}

pub const arm_box: mob_model.Box = .{
    .origin = .{ -3, -2, -2 },
    .size = .{ 4, 12, 4 },
    .tex_u = 40,
    .tex_v = 16,
};
pub const arm_pivot: [3]f32 = .{ -5, 2, 0 };
pub const arm_scale: f32 = 1.0 / 16.0;

pub fn armMatrix(swing: f32, equipped: f32) math.Mat4 {
    const scale: f32 = 0.8;
    const bob = math.util.sin(@sqrt(swing) * std.math.pi);
    const dip = math.util.sin(swing * std.math.pi);

    var transform = math.Mat4.translation(
        -bob * 0.3,
        math.util.sin(@sqrt(swing) * std.math.pi * 2.0) * 0.4,
        -dip * 0.4,
    );
    transform = transform.mul(math.Mat4.translation(
        0.8 * scale,
        -(12.0 / 16.0) * scale - (1.0 - equipped) * 0.6,
        -0.9 * scale,
    ));
    transform = transform.mul(math.Mat4.rotationY(45.0 * degrees));
    transform = transform.mul(math.Mat4.rotationY(bob * 70.0 * degrees));
    transform = transform.mul(math.Mat4.rotationZ(-math.util.sin(swing * swing * std.math.pi) * 20.0 * degrees));

    transform = transform.mul(math.Mat4.translation(-1, 3.6, 3.5));
    transform = transform.mul(math.Mat4.rotationZ(120.0 * degrees));
    transform = transform.mul(math.Mat4.rotationX(200.0 * degrees));
    transform = transform.mul(math.Mat4.rotationY(-135.0 * degrees));
    return transform.mul(math.Mat4.translation(5.6, 0, 0));
}

pub fn appendArm(mesh: *MeshBuilder, gpa: std.mem.Allocator, brightness: f32) !void {
    const first_vertex = mesh.vertices.items.len;
    try mob_model.appendBox(mesh, gpa, arm_box, arm_pivot, arm_scale, mob_model.biped.texture_width, mob_model.biped.texture_height);
    mesh.scaleColors(first_vertex, brightness);
}

pub const Held = union(enum) {
    cube: world.Block,
    sprite: struct { tile: u8, atlas: enum { terrain, items } },
};

pub fn heldShape(stack: ?game.Inventory.ItemStack) ?Held {
    const held = stack orelse return null;
    const id = switch (held.id) {
        .block => |b| b,
        .item => |i| {
            const tile = i.iconTile(held.meta) orelse return null;
            return .{ .sprite = .{ .tile = tile, .atlas = .items } };
        },
    };
    if (id == .air) return null;
    if (id.flatItemTile(held.blockMeta())) |tile| {
        return .{ .sprite = .{ .tile = tile, .atlas = .terrain } };
    }
    return .{ .cube = id };
}

test "the equip animation dips to zero when the held stack changes, then climbs back" {
    var equip: Equip = .{ .shown = .{ .id = .{ .block = .stone }, .count = 1 } };

    equip.tick(.{ .id = .{ .block = .dirt }, .count = 1 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), equip.progress, 1.0e-5);

    equip.tick(.{ .id = .{ .block = .dirt }, .count = 1 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), equip.progress, 1.0e-5);

    equip.tick(.{ .id = .{ .block = .dirt }, .count = 1 });
    try std.testing.expectEqual(world.Id{ .block = .dirt }, equip.shown.?.id);

    equip.tick(.{ .id = .{ .block = .dirt }, .count = 1 });
    try std.testing.expect(equip.progress > 0.0);
}

test "an unchanged stack holds the item fully raised" {
    var equip: Equip = .{ .shown = .{ .id = .{ .block = .stone }, .count = 1 } };
    for (0..5) |_| equip.tick(.{ .id = .{ .block = .stone }, .count = 1 });
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), equip.progress, 1.0e-5);
}

test "at rest the hand sits down and to the right of the camera" {
    const resting: [16]f32 = handMatrix(0.0, 1.0).m;

    try std.testing.expectApproxEqAbs(@as(f32, 0.56), resting[12], 1.0e-5);
    try std.testing.expectApproxEqAbs(@as(f32, -0.52), resting[13], 1.0e-5);
    try std.testing.expectApproxEqAbs(@as(f32, -0.72), resting[14], 1.0e-5);
}

test "lowering the item during a swap drops it below the resting position" {
    const resting: [16]f32 = handMatrix(0.0, 1.0).m;
    const swapping: [16]f32 = handMatrix(0.0, 0.0).m;
    try std.testing.expect(swapping[13] < resting[13]);
    try std.testing.expectApproxEqAbs(@as(f32, -0.6), swapping[13] - resting[13], 1.0e-5);
}

test "the extruded sprite is two faces plus four strips of sixteen slices" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);

    try appendSprite(&mesh, gpa, 7, 1.0);

    const quads = 2 + 4 * sprite_slices;
    try std.testing.expectEqual(@as(usize, quads * 4), mesh.vertices.items.len);
}

test "the sprite has depth and stays inside a unit square" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);

    try appendSprite(&mesh, gpa, 7, 1.0);

    var nearest: f32 = std.math.floatMax(f32);
    var furthest: f32 = -std.math.floatMax(f32);
    for (mesh.vertices.items) |v| {
        nearest = @min(nearest, v.z);
        furthest = @max(furthest, v.z);
        try std.testing.expect(v.x >= 0.0 and v.x <= 1.0);
        try std.testing.expect(v.y >= 0.0 and v.y <= 1.0);
    }
    try std.testing.expectApproxEqAbs(-sprite_thickness, nearest, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), furthest, 1.0e-6);
}

test "the sprite samples only its own tile" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);

    const tile: u8 = 3 * 16 + 5;
    try appendSprite(&mesh, gpa, tile, 1.0);

    const column: f32 = @floatFromInt(@as(u32, tile % 16) * 16);
    const row: f32 = @floatFromInt(@as(u32, tile / 16) * 16);
    for (mesh.vertices.items) |v| {
        try std.testing.expect(v.u >= column / 256.0 - texel_bias - 1.0e-6);
        try std.testing.expect(v.u <= (column + 16.0) / 256.0 + 1.0e-6);
        try std.testing.expect(v.v >= row / 256.0 - texel_bias - 1.0e-6);
        try std.testing.expect(v.v <= (row + 16.0) / 256.0 + 1.0e-6);
    }
}

test "each held stack picks the shape and atlas the original gives it" {
    const stone = heldShape(.{ .id = .{ .block = .stone }, .count = 1 }).?;
    try std.testing.expectEqual(world.Block.stone, stone.cube);

    const rose = heldShape(.{ .id = .{ .block = .rose }, .count = 1 }).?;
    try std.testing.expectEqual(world.Block.rose.crossTile(0), rose.sprite.tile);
    try std.testing.expectEqual(.terrain, rose.sprite.atlas);

    const coal = heldShape(.{ .id = .{ .item = .coal }, .count = 1 }).?;
    try std.testing.expectEqual(world.Item.iconTile(world.Item.coal, 0).?, coal.sprite.tile);
    try std.testing.expectEqual(.items, coal.sprite.atlas);

    try std.testing.expect(heldShape(null) == null);
}

test "the arm is one box of ModelBiped's right arm dimensions" {
    const gpa = std.testing.allocator;
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);

    try appendArm(&mesh, gpa, 1.0);
    try std.testing.expectEqual(@as(usize, 6 * 4), mesh.vertices.items.len);

    var lowest: [3]f32 = .{ std.math.floatMax(f32), std.math.floatMax(f32), std.math.floatMax(f32) };
    var highest: [3]f32 = .{ -std.math.floatMax(f32), -std.math.floatMax(f32), -std.math.floatMax(f32) };
    for (mesh.vertices.items) |v| {
        const p = [3]f32{ v.x, v.y, v.z };
        for (0..3) |axis| {
            lowest[axis] = @min(lowest[axis], p[axis]);
            highest[axis] = @max(highest[axis], p[axis]);
        }
    }
    for (0..3) |axis| {
        const span = (highest[axis] - lowest[axis]) * 16.0;
        try std.testing.expectApproxEqAbs(arm_box.size[axis], span, 1.0e-4);
    }
    try std.testing.expectApproxEqAbs((arm_box.origin[0] + arm_pivot[0]) / 16.0, lowest[0], 1.0e-6);
}

test "the empty hand and the held item start from different offsets" {
    const arm: [16]f32 = armMatrix(0.0, 1.0).m;
    const item: [16]f32 = handMatrix(0.0, 1.0).m;
    try std.testing.expect(arm[12] != item[12]);
    try std.testing.expect(arm[13] != item[13]);
}

test "an empty slot falls through to the arm" {
    try std.testing.expect(heldShape(null) == null);
    try std.testing.expect(heldShape(.{ .id = .{ .block = .air }, .count = 0 }) == null);
}
