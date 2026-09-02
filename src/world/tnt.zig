const std = @import("std");

const assets = @import("assets");

const block = @import("block.zig");
const BlockPos = @import("BlockPos.zig");
const JavaRandom = @import("JavaRandom.zig");
const redstone = @import("redstone.zig");
const testing_world = @import("testing.zig");
const World = @import("World.zig");

pub const fuse_ticks: i32 = 80;
pub const lit_bit: u4 = 1;
pub const fuse_volume: f32 = 1.0;
pub const fuse_pitch: f32 = 1.0;

pub fn isLit(metadata: u4) bool {
    return metadata & lit_bit != 0;
}

pub fn markLit(world_map: *World, pos: BlockPos) void {
    if (world_map.getBlock(pos) != .tnt) return;
    world_map.setBlockMetadata(pos, world_map.getBlockMetadata(pos) | lit_bit);
}

pub fn prime(world_map: *World, pos: BlockPos, fuse: i32) std.mem.Allocator.Error!void {
    try world_map.primed.append(world_map.allocator, .{
        .pos = pos,
        .fuse = fuse,
    });
}

pub fn primeByPlayer(world_map: *World, pos: BlockPos) std.mem.Allocator.Error!void {
    try prime(world_map, pos, fuse_ticks);
    world_map.playSoundEffect(
        @as(f64, @floatFromInt(pos.x)) + 0.5,
        @as(f64, @floatFromInt(pos.y)) + 0.5,
        @as(f64, @floatFromInt(pos.z)) + 0.5,
        assets.sounds.random.fuse,
        fuse_volume,
        fuse_pitch,
    );
}

pub fn primeByExplosion(world_map: *World, pos: BlockPos, rand: *JavaRandom) std.mem.Allocator.Error!void {
    const shortened = rand.nextIntBound(@divTrunc(fuse_ticks, 4)) + @divTrunc(fuse_ticks, 8);
    try prime(world_map, pos, shortened);
}

pub fn onBlockAdded(world_map: *World, pos: BlockPos) std.mem.Allocator.Error!void {
    if (!redstone.isBlockIndirectlyGettingPowered(world_map, pos)) return;
    try primeByPlayer(world_map, pos);
    try world_map.setBlockWithNotify(pos, .air);
}

pub fn onNeighborChange(world_map: *World, pos: BlockPos, source: block.Block) std.mem.Allocator.Error!void {
    if (!redstone.canProvidePower(source)) return;
    return onBlockAdded(world_map, pos);
}

test "redstone power beside a stick of tnt lights it and takes the block away" {
    var w = try testing_world.flatWorld(std.testing.allocator, 1);
    defer w.deinit();

    try w.setBlockWithNotify(.init(8, 2, 8), .tnt);
    try w.setBlockWithNotify(.init(9, 2, 8), .torch_redstone_on);

    try std.testing.expectEqual(@as(usize, 1), w.primed.items.len);
    try std.testing.expectEqual(fuse_ticks, w.primed.items[0].fuse);
    try std.testing.expectEqual(.air, w.getBlock(.init(8, 2, 8)));
}

test "tnt placed beside a live torch lights itself as it lands" {
    var w = try testing_world.flatWorld(std.testing.allocator, 1);
    defer w.deinit();

    try w.setBlockWithNotify(.init(9, 1, 8), .torch_redstone_on);
    try w.setBlockWithNotify(.init(8, 1, 8), .tnt);

    try std.testing.expectEqual(@as(usize, 1), w.primed.items.len);
    try std.testing.expectEqual(.air, w.getBlock(.init(8, 1, 8)));
}

test "an unpowered neighbour leaves the tnt standing" {
    var w = try testing_world.flatWorld(std.testing.allocator, 1);
    defer w.deinit();

    try w.setBlockWithNotify(.init(8, 2, 8), .tnt);
    try w.setBlockWithNotify(.init(9, 2, 8), .stone);

    try std.testing.expectEqual(@as(usize, 0), w.primed.items.len);
    try std.testing.expectEqual(.tnt, w.getBlock(.init(8, 2, 8)));
}

test "a blast shortens the fuse of the tnt it reaches" {
    var w = try testing_world.flatWorld(std.testing.allocator, 1);
    defer w.deinit();
    var rand = JavaRandom.init(0);

    try primeByExplosion(&w, .init(4, 2, 4), &rand);

    const lit = w.primed.items[0];
    try std.testing.expect(lit.fuse >= @divTrunc(fuse_ticks, 8));
    try std.testing.expect(lit.fuse < @divTrunc(fuse_ticks, 4) + @divTrunc(fuse_ticks, 8));
}
