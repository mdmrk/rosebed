const std = @import("std");
const game = @import("game");
const math = @import("math");
const world = @import("world");

const MeshBuilder = @import("mesh_builder.zig");
const chunk_mesher = @import("chunk_mesher.zig");

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
    return a.?.id == b.?.id and a.?.meta == b.?.meta;
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

pub fn appendBlock(mesh: *MeshBuilder, gpa: std.mem.Allocator, id: u8, brightness: f32) !void {
    const first_vertex = mesh.vertices.items.len;
    try chunk_mesher.buildCube(
        mesh,
        gpa,
        .{ -0.5, -0.5, -0.5 },
        .{ 0.5, 0.5, 0.5 },
        world.block.faceTextures(id),
    );
    mesh.scaleColors(first_vertex, brightness);
}

pub fn renderable(stack: ?game.Inventory.ItemStack) ?u8 {
    const held = stack orelse return null;
    if (held.id > 255 or held.id == world.block.air) return null;
    if (world.block.isCross(@intCast(held.id))) return null;
    return @intCast(held.id);
}

test "the equip animation dips to zero when the held stack changes, then climbs back" {
    var equip: Equip = .{ .shown = .{ .id = world.block.stone, .count = 1 } };

    equip.tick(.{ .id = world.block.dirt, .count = 1 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), equip.progress, 1.0e-5);

    equip.tick(.{ .id = world.block.dirt, .count = 1 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), equip.progress, 1.0e-5);

    equip.tick(.{ .id = world.block.dirt, .count = 1 });
    try std.testing.expectEqual(world.block.dirt, equip.shown.?.id);

    equip.tick(.{ .id = world.block.dirt, .count = 1 });
    try std.testing.expect(equip.progress > 0.0);
}

test "an unchanged stack holds the item fully raised" {
    var equip: Equip = .{ .shown = .{ .id = world.block.stone, .count = 1 } };
    for (0..5) |_| equip.tick(.{ .id = world.block.stone, .count = 1 });
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

test "only full-cube blocks are held for now" {
    try std.testing.expectEqual(world.block.stone, renderable(.{ .id = world.block.stone, .count = 1 }).?);
    try std.testing.expect(renderable(null) == null);
    try std.testing.expect(renderable(.{ .id = world.item.coal, .count = 1 }) == null);
    try std.testing.expect(renderable(.{ .id = world.block.rose, .count = 1 }) == null);
}
