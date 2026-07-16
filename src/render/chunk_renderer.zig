const std = @import("std");
const math = @import("math");
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

fn seamOffset(local: i32) i32 {
    if (local == 0) return -1;
    if (local == world.constants.chunk_width - 1) return 1;
    return 0;
}

pub fn markBlockDirty(self: *ChunkRenderer, gpa: std.mem.Allocator, x: i32, z: i32) !void {
    const width = world.constants.chunk_width;
    const chunk_x = @divFloor(x, width);
    const chunk_z = @divFloor(z, width);
    const offset_x = seamOffset(@mod(x, width));
    const offset_z = seamOffset(@mod(z, width));

    try self.markDirty(gpa, chunk_x, chunk_z);
    if (offset_x != 0) try self.markDirty(gpa, chunk_x + offset_x, chunk_z);
    if (offset_z != 0) try self.markDirty(gpa, chunk_x, chunk_z + offset_z);
    if (offset_x != 0 and offset_z != 0) try self.markDirty(gpa, chunk_x + offset_x, chunk_z + offset_z);
}

const distant_rebuilds_per_batch = 2;
const max_rebuilds_per_flush = 64;
const immediate_rebuild_distance = 16.0;

pub fn radiusFor(render_distance: u5) i32 {
    const diameter = @min(@as(i32, 64) << (3 - render_distance), 400);
    return @divTrunc(diameter, 2 * world.constants.chunk_width);
}

const Pending = struct {
    coord: world.World.ChunkCoord,
    distance: f64,

    fn nearestFirst(_: void, a: Pending, b: Pending) bool {
        return a.distance < b.distance;
    }
};

pub fn flush(
    self: *ChunkRenderer,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    colorizer: Colorizer,
    options: chunk_mesher.Options,
    eye_x: f64,
    eye_z: f64,
    deadline_ns: u64,
) !u32 {
    if (self.dirty.count() == 0) return 0;

    var pending: std.ArrayList(Pending) = .empty;
    defer pending.deinit(gpa);
    try pending.ensureTotalCapacity(gpa, self.dirty.count());

    const width: f64 = @floatFromInt(world.constants.chunk_width);
    var it = self.dirty.keyIterator();
    while (it.next()) |coord| {
        const center_x = (@as(f64, @floatFromInt(coord.x)) + 0.5) * width;
        const center_z = (@as(f64, @floatFromInt(coord.z)) + 0.5) * width;
        const dx = center_x - eye_x;
        const dz = center_z - eye_z;
        pending.appendAssumeCapacity(.{ .coord = coord.*, .distance = dx * dx + dz * dz });
    }
    std.mem.sort(Pending, pending.items, {}, Pending.nearestFirst);

    var rebuilt: u32 = 0;
    var attempts: usize = 0;
    var distant: usize = 0;

    for (pending.items) |entry| {
        if (entry.distance > immediate_rebuild_distance * immediate_rebuild_distance) {
            if (attempts == max_rebuilds_per_flush) break;
            if (distant >= distant_rebuilds_per_batch and
                (deadline_ns == 0 or sdl3.timer.getNanosecondsSinceInit() >= deadline_ns)) break;
            distant += 1;
        }
        attempts += 1;
        _ = self.dirty.remove(entry.coord);

        const chunk = world_map.getChunk(entry.coord.x, entry.coord.z) orelse continue;

        var mesh = try chunk_mesher.build(gpa, world_map, chunk, colorizer, options);
        defer mesh.deinit(gpa);

        const slot = try self.meshes.getOrPut(gpa, entry.coord);
        if (slot.found_existing) slot.value_ptr.deinit();
        slot.value_ptr.* = .{
            .solid = GpuMesh.upload(&mesh.solid),
            .translucent = GpuMesh.upload(&mesh.translucent),
        };
        rebuilt += 1;
    }

    return rebuilt;
}

fn chunkBounds(coord: world.World.ChunkCoord) struct { min: [3]f32, max: [3]f32 } {
    const width: f32 = @floatFromInt(world.constants.chunk_width);
    const height: f32 = @floatFromInt(world.constants.chunk_height);
    const min_x = @as(f32, @floatFromInt(coord.x)) * width;
    const min_z = @as(f32, @floatFromInt(coord.z)) * width;
    return .{
        .min = .{ min_x, 0, min_z },
        .max = .{ min_x + width, height, min_z + width },
    };
}

pub fn drawSolid(self: *const ChunkRenderer, frustum: math.Frustum) u32 {
    var drawn: u32 = 0;
    var it = self.meshes.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.solid.index_count == 0) continue;
        const bounds = chunkBounds(entry.key_ptr.*);
        if (!frustum.containsBox(bounds.min, bounds.max)) continue;
        entry.value_ptr.solid.draw();
        drawn += 1;
    }
    return drawn;
}

pub fn drawTranslucent(self: *const ChunkRenderer, gpa: std.mem.Allocator, frustum: math.Frustum, eye_x: f64, eye_z: f64) !void {
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
        const bounds = chunkBounds(entry.key_ptr.*);
        if (!frustum.containsBox(bounds.min, bounds.max)) continue;
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

test "a block on a chunk corner dirties the diagonal chunk too" {
    const gpa = std.testing.allocator;
    var renderer: ChunkRenderer = .{};
    defer renderer.deinit(gpa);

    try renderer.markBlockDirty(gpa, 0, 0);
    try std.testing.expectEqual(@as(usize, 4), renderer.dirty.count());
    try std.testing.expect(renderer.dirty.contains(.{ .x = 0, .z = 0 }));
    try std.testing.expect(renderer.dirty.contains(.{ .x = -1, .z = 0 }));
    try std.testing.expect(renderer.dirty.contains(.{ .x = 0, .z = -1 }));
    try std.testing.expect(renderer.dirty.contains(.{ .x = -1, .z = -1 }));
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

    const deadline = sdl3.timer.getNanosecondsSinceInit() + std.time.ns_per_s;
    _ = try renderer.flush(gpa, &world_map, Colorizer.untinted, .{}, 100_000, 100_000, deadline);
    try std.testing.expect(renderer.dirty.count() >= 5);
    try std.testing.expect(renderer.dirty.count() < max_rebuilds_per_flush + 5);
}

test "a flush without a deadline rebuilds a single batch of distant chunks" {
    const gpa = std.testing.allocator;
    var renderer: ChunkRenderer = .{};
    defer renderer.deinit(gpa);

    var coord: i32 = 0;
    while (coord < 10) : (coord += 1) {
        try renderer.markDirty(gpa, coord, 0);
    }

    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    _ = try renderer.flush(gpa, &world_map, Colorizer.untinted, .{}, 100_000, 100_000, 0);
    try std.testing.expectEqual(@as(usize, 10 - distant_rebuilds_per_batch), renderer.dirty.count());
}

test "a flush past its deadline still rebuilds a batch of distant chunks" {
    const gpa = std.testing.allocator;
    var renderer: ChunkRenderer = .{};
    defer renderer.deinit(gpa);

    var coord: i32 = 0;
    while (coord < 10) : (coord += 1) {
        try renderer.markDirty(gpa, coord, 0);
    }

    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    _ = try renderer.flush(gpa, &world_map, Colorizer.untinted, .{}, 100_000, 100_000, 1);
    try std.testing.expectEqual(@as(usize, 10 - distant_rebuilds_per_batch), renderer.dirty.count());
}

test "a flush drains the nearest chunks first and never starves the one underfoot" {
    const gpa = std.testing.allocator;
    var renderer: ChunkRenderer = .{};
    defer renderer.deinit(gpa);

    var coord: i32 = 0;
    while (coord < max_rebuilds_per_flush * 4) : (coord += 1) {
        try renderer.markDirty(gpa, coord + 1, 0);
    }
    try renderer.markDirty(gpa, 0, 0);

    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    _ = try renderer.flush(gpa, &world_map, Colorizer.untinted, .{}, 8, 8, 0);

    try std.testing.expect(!renderer.dirty.contains(.{ .x = 0, .z = 0 }));
    try std.testing.expect(renderer.dirty.contains(.{ .x = max_rebuilds_per_flush * 4, .z = 0 }));
}

test "a chunk within the immediate radius is rebuilt even past the attempt cap" {
    const gpa = std.testing.allocator;
    var renderer: ChunkRenderer = .{};
    defer renderer.deinit(gpa);

    var coord: i32 = 0;
    while (coord < max_rebuilds_per_flush * 2) : (coord += 1) {
        try renderer.markDirty(gpa, -coord - 8, 0);
    }
    try renderer.markDirty(gpa, 0, 0);
    try renderer.markDirty(gpa, 0, 1);

    var world_map = world.World.init(gpa);
    defer world_map.deinit();

    _ = try renderer.flush(gpa, &world_map, Colorizer.untinted, .{}, 8, 20, 0);

    try std.testing.expect(!renderer.dirty.contains(.{ .x = 0, .z = 0 }));
    try std.testing.expect(!renderer.dirty.contains(.{ .x = 0, .z = 1 }));
}
