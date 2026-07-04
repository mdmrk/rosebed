const std = @import("std");
const sdl3 = @import("sdl3");
const world = @import("world");

const GpuMesh = @import("gpu_mesh.zig");
const chunk_mesher = @import("chunk_mesher.zig");
const Colorizer = @import("colorizer.zig");

const ChunkRenderer = @This();

const CoordSet = std.AutoHashMapUnmanaged(world.World.ChunkCoord, void);
const MeshMap = std.AutoHashMapUnmanaged(world.World.ChunkCoord, ChunkMeshes);

const ChunkMeshes = struct {
    solid: GpuMesh,
    translucent: GpuMesh,

    fn deinit(self: ChunkMeshes) void {
        self.solid.deinit();
        self.translucent.deinit();
    }
};

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

pub fn markAllDirty(self: *ChunkRenderer, gpa: std.mem.Allocator) !void {
    var it = self.meshes.keyIterator();
    while (it.next()) |coord| try self.dirty.put(gpa, coord.*, {});
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

pub const rebuild_budget_ns = 8 * std.time.ns_per_ms;
const max_rebuilds_per_flush = 64;

pub fn radiusFor(render_distance: u5) i32 {
    const diameter = @min(@as(i32, 64) << (3 - render_distance), 400);
    return @divTrunc(diameter, 2 * world.constants.chunk_width);
}

pub fn flush(self: *ChunkRenderer, gpa: std.mem.Allocator, world_map: *const world.World, colorizer: Colorizer) !u32 {
    var rebuilt: u32 = 0;
    var done: [max_rebuilds_per_flush]world.World.ChunkCoord = undefined;
    var done_count: usize = 0;
    const started = sdl3.timer.getNanosecondsSinceInit();

    var it = self.dirty.keyIterator();
    while (it.next()) |coord| {
        if (done_count == max_rebuilds_per_flush) break;
        if (done_count > 0 and sdl3.timer.getNanosecondsSinceInit() -% started >= rebuild_budget_ns) break;
        done[done_count] = coord.*;
        done_count += 1;

        const chunk = world_map.getChunk(coord.x, coord.z) orelse continue;

        var mesh = try chunk_mesher.build(gpa, world_map, chunk, colorizer);
        defer mesh.deinit(gpa);

        const entry = try self.meshes.getOrPut(gpa, coord.*);
        if (entry.found_existing) entry.value_ptr.deinit();
        entry.value_ptr.* = .{
            .solid = GpuMesh.upload(&mesh.solid),
            .translucent = GpuMesh.upload(&mesh.translucent),
        };
        rebuilt += 1;
    }

    for (done[0..done_count]) |coord| _ = self.dirty.remove(coord);

    return rebuilt;
}

pub fn drawSolid(self: *const ChunkRenderer) void {
    var it = self.meshes.valueIterator();
    while (it.next()) |mesh| mesh.solid.draw();
}

pub fn drawTranslucent(self: *const ChunkRenderer, gpa: std.mem.Allocator, eye_x: f64, eye_z: f64) !void {
    const Ordered = struct {
        distance: f64,
        mesh: GpuMesh,

        fn farthestFirst(_: void, a: @This(), b: @This()) bool {
            return a.distance > b.distance;
        }
    };

    var ordered: std.ArrayList(Ordered) = .empty;
    defer ordered.deinit(gpa);

    const width: f64 = @floatFromInt(world.constants.chunk_width);
    var it = self.meshes.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.translucent.index_count == 0) continue;
        const center_x = (@as(f64, @floatFromInt(entry.key_ptr.x)) + 0.5) * width;
        const center_z = (@as(f64, @floatFromInt(entry.key_ptr.z)) + 0.5) * width;
        const dx = center_x - eye_x;
        const dz = center_z - eye_z;
        try ordered.append(gpa, .{ .distance = dx * dx + dz * dz, .mesh = entry.value_ptr.translucent });
    }

    std.mem.sort(Ordered, ordered.items, {}, Ordered.farthestFirst);
    for (ordered.items) |entry| entry.mesh.draw();
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

test "the view radius follows the original's render distance widths" {
    try std.testing.expectEqual(@as(i32, 12), radiusFor(0));
    try std.testing.expectEqual(@as(i32, 8), radiusFor(1));
    try std.testing.expectEqual(@as(i32, 4), radiusFor(2));
    try std.testing.expectEqual(@as(i32, 2), radiusFor(3));
}

test "a flush consumes at most its cap and leaves the rest dirty" {
    const gpa = std.testing.allocator;
    var renderer: ChunkRenderer = .{};
    defer renderer.deinit(gpa);

    var coord: i32 = 0;
    while (coord < max_rebuilds_per_flush + 5) : (coord += 1) {
        try renderer.markDirty(gpa, coord, 0);
    }
    try std.testing.expectEqual(@as(usize, max_rebuilds_per_flush + 5), renderer.dirty.count());

    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    _ = try renderer.flush(gpa, &world_map, Colorizer.untinted);
    try std.testing.expect(renderer.dirty.count() >= 5);
    try std.testing.expect(renderer.dirty.count() < max_rebuilds_per_flush + 5);
}
