const std = @import("std");
const world = @import("world");

const GpuMesh = @import("gpu_mesh.zig");
const chunk_mesher = @import("chunk_mesher.zig");

const ChunkRenderer = @This();

const CoordSet = std.AutoHashMapUnmanaged(world.World.ChunkCoord, void);
const MeshMap = std.AutoHashMapUnmanaged(world.World.ChunkCoord, GpuMesh);

meshes: MeshMap = .{},
dirty: CoordSet = .{},

pub fn deinit(self: *ChunkRenderer, gpa: std.mem.Allocator) void {
    var it = self.meshes.valueIterator();
    while (it.next()) |mesh| mesh.deinit();
    self.meshes.deinit(gpa);
    self.dirty.deinit(gpa);
}

pub fn loadedCount(self: *const ChunkRenderer) usize {
    return self.meshes.count();
}

pub fn hasMesh(self: *const ChunkRenderer, chunk_x: i32, chunk_z: i32) bool {
    return self.meshes.contains(.{ .x = chunk_x, .z = chunk_z });
}

pub fn markDirty(self: *ChunkRenderer, gpa: std.mem.Allocator, chunk_x: i32, chunk_z: i32) !void {
    try self.dirty.put(gpa, .{ .x = chunk_x, .z = chunk_z }, {});
}

pub fn markBlockDirty(self: *ChunkRenderer, gpa: std.mem.Allocator, x: i32, z: i32) !void {
    const width = world.constants.chunk_width;
    const chunk_x = @divFloor(x, width);
    const chunk_z = @divFloor(z, width);
    const local_x = @mod(x, width);
    const local_z = @mod(z, width);

    try self.markDirty(gpa, chunk_x, chunk_z);
    if (local_x == 0) try self.markDirty(gpa, chunk_x - 1, chunk_z);
    if (local_x == width - 1) try self.markDirty(gpa, chunk_x + 1, chunk_z);
    if (local_z == 0) try self.markDirty(gpa, chunk_x, chunk_z - 1);
    if (local_z == width - 1) try self.markDirty(gpa, chunk_x, chunk_z + 1);
}

pub fn flush(self: *ChunkRenderer, gpa: std.mem.Allocator, world_map: *const world.World) !u32 {
    var rebuilt: u32 = 0;

    var it = self.dirty.keyIterator();
    while (it.next()) |coord| {
        const chunk = world_map.getChunk(coord.x, coord.z) orelse continue;

        var mesh = try chunk_mesher.build(gpa, world_map, chunk);
        defer mesh.deinit(gpa);

        const entry = try self.meshes.getOrPut(gpa, coord.*);
        if (entry.found_existing) entry.value_ptr.deinit();
        entry.value_ptr.* = GpuMesh.upload(&mesh);
        rebuilt += 1;
    }
    self.dirty.clearRetainingCapacity();

    return rebuilt;
}

pub fn draw(self: *const ChunkRenderer) void {
    var it = self.meshes.valueIterator();
    while (it.next()) |mesh| mesh.draw();
}

test "a block on a chunk seam dirties both sides" {
    const gpa = std.testing.allocator;
    var renderer: ChunkRenderer = .{};
    defer renderer.deinit(gpa);

    try renderer.markBlockDirty(gpa, 15, 4);
    try std.testing.expect(renderer.dirty.contains(.{ .x = 0, .z = 0 }));
    try std.testing.expect(renderer.dirty.contains(.{ .x = 1, .z = 0 }));
    try std.testing.expectEqual(@as(usize, 2), renderer.dirty.count());
}

test "a block in the interior only dirties its own chunk" {
    const gpa = std.testing.allocator;
    var renderer: ChunkRenderer = .{};
    defer renderer.deinit(gpa);

    try renderer.markBlockDirty(gpa, 8, 8);
    try std.testing.expectEqual(@as(usize, 1), renderer.dirty.count());
    try std.testing.expect(renderer.dirty.contains(.{ .x = 0, .z = 0 }));
}

test "negative world coordinates resolve to the chunk that owns them" {
    const gpa = std.testing.allocator;
    var renderer: ChunkRenderer = .{};
    defer renderer.deinit(gpa);

    try renderer.markBlockDirty(gpa, -1, -1);
    try std.testing.expect(renderer.dirty.contains(.{ .x = -1, .z = -1 }));
    try std.testing.expect(renderer.dirty.contains(.{ .x = 0, .z = -1 }));
    try std.testing.expect(renderer.dirty.contains(.{ .x = -1, .z = 0 }));
}

test "repeated edits to the same chunk collapse into one rebuild" {
    const gpa = std.testing.allocator;
    var renderer: ChunkRenderer = .{};
    defer renderer.deinit(gpa);

    try renderer.markBlockDirty(gpa, 4, 4);
    try renderer.markBlockDirty(gpa, 5, 5);
    try renderer.markDirty(gpa, 0, 0);
    try std.testing.expectEqual(@as(usize, 1), renderer.dirty.count());
}
