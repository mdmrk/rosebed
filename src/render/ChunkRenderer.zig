const std = @import("std");

const gl = @import("gl");
const query_target = gl.ANY_SAMPLES_PASSED;
const math = @import("math");
const sdl3 = @import("sdl3");
const world = @import("world");

const chunk_mesher = @import("chunk_mesher.zig");
const Colorizer = @import("Colorizer.zig");
const GpuMesh = @import("GpuMesh.zig");
const MeshBuilder = @import("MeshBuilder.zig");
const Shader = @import("Shader.zig");

const ChunkRenderer = @This();

const CoordSet = std.AutoHashMapUnmanaged(world.World.ChunkCoord, void);
const MeshMap = std.AutoHashMapUnmanaged(world.World.ChunkCoord, ChunkMeshes);

const ChunkMeshes = struct {
    solid: GpuMesh,
    translucent: GpuMesh,
    query: gl.uint = 0,
    visible: bool = true,
    waiting: bool = false,

    fn drawsNothing(self: ChunkMeshes) bool {
        return self.solid.index_count == 0 and self.translucent.index_count == 0;
    }

    fn deinit(self: ChunkMeshes) void {
        self.solid.deinit();
        self.translucent.deinit();
        if (self.query != 0) gl.DeleteQueries(1, @ptrCast(&self.query));
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
    if (local == world.Chunk.width - 1) return 1;
    return 0;
}

pub fn markBlockDirty(self: *ChunkRenderer, gpa: std.mem.Allocator, x: i32, z: i32) !void {
    const width = world.Chunk.width;
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
    return @divTrunc(diameter, 2 * world.Chunk.width);
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

    const width: f64 = @floatFromInt(world.Chunk.width);
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
        if (slot.found_existing) {
            slot.value_ptr.solid.deinit();
            slot.value_ptr.translucent.deinit();
        } else {
            slot.value_ptr.* = .{ .solid = undefined, .translucent = undefined };
        }
        slot.value_ptr.solid = GpuMesh.upload(&mesh.solid);
        slot.value_ptr.translucent = GpuMesh.upload(&mesh.translucent);
        rebuilt += 1;
    }

    return rebuilt;
}

fn chunkBounds(coord: world.World.ChunkCoord) struct { min: [3]f32, max: [3]f32 } {
    const width: f32 = @floatFromInt(world.Chunk.width);
    const height: f32 = @floatFromInt(world.Chunk.height);
    const min_x = @as(f32, @floatFromInt(coord.x)) * width;
    const min_z = @as(f32, @floatFromInt(coord.z)) * width;
    return .{
        .min = .{ min_x, 0, min_z },
        .max = .{ min_x + width, height, min_z + width },
    };
}

const first_query_batch = 16;
const query_box_margin = 6.0;
const query_stagger_distance = 128.0;
const indices_per_query_box = 36;
const query_box_faces = [6][4][3]u1{
    .{ .{ 1, 0, 0 }, .{ 1, 0, 1 }, .{ 0, 0, 1 }, .{ 0, 0, 0 } },
    .{ .{ 1, 1, 1 }, .{ 1, 1, 0 }, .{ 0, 1, 0 }, .{ 0, 1, 1 } },
    .{ .{ 0, 0, 0 }, .{ 0, 1, 0 }, .{ 1, 1, 0 }, .{ 1, 0, 0 } },
    .{ .{ 1, 0, 1 }, .{ 1, 1, 1 }, .{ 0, 1, 1 }, .{ 0, 0, 1 } },
    .{ .{ 0, 0, 1 }, .{ 0, 1, 1 }, .{ 0, 1, 0 }, .{ 0, 0, 0 } },
    .{ .{ 1, 0, 0 }, .{ 1, 1, 0 }, .{ 1, 1, 1 }, .{ 1, 0, 1 } },
};

const Sorted = struct {
    meshes: *ChunkMeshes,
    coord: world.World.ChunkCoord,
    distance: f32,
    in_frustum: bool = false,

    fn nearestFirst(_: void, a: Sorted, b: Sorted) bool {
        return a.distance < b.distance;
    }
};

pub const Eye = struct { x: f64, y: f64, z: f64 };

fn appendQueryBox(mesh: *MeshBuilder, gpa: std.mem.Allocator, coord: world.World.ChunkCoord) !void {
    const bounds = chunkBounds(coord);
    const corner = [2][3]f32{
        .{ bounds.min[0] - query_box_margin, bounds.min[1] - query_box_margin, bounds.min[2] - query_box_margin },
        .{ bounds.max[0] + query_box_margin, bounds.max[1] + query_box_margin, bounds.max[2] + query_box_margin },
    };
    for (query_box_faces) |face| {
        var positions: [4][3]f32 = undefined;
        for (face, 0..) |pick, i| {
            positions[i] = .{ corner[pick[0]][0], corner[pick[1]][1], corner[pick[2]][2] };
        }
        try mesh.quad(gpa, positions, @splat(.{ 0, 0 }), .{ 255, 255, 255, 255 });
    }
}

fn readQueryResults(entries: []const Sorted) void {
    for (entries) |entry| {
        if (!entry.meshes.waiting) continue;
        var available: gl.uint = 0;
        gl.GetQueryObjectuiv(entry.meshes.query, gl.QUERY_RESULT_AVAILABLE, @ptrCast(&available));
        if (available == 0) continue;
        entry.meshes.waiting = false;
        var samples: gl.uint = 0;
        gl.GetQueryObjectuiv(entry.meshes.query, gl.QUERY_RESULT, @ptrCast(&samples));
        entry.meshes.visible = samples != 0;
    }
}

fn issueQueries(gpa: std.mem.Allocator, shader: Shader, entries: []const Sorted, offset: usize, frame: u64) !void {
    var boxes: MeshBuilder = .{};
    defer boxes.deinit(gpa);
    var queried: std.ArrayList(*ChunkMeshes) = .empty;
    defer queried.deinit(gpa);

    for (entries, offset..) |entry, index| {
        if (!entry.in_frustum or entry.meshes.waiting) continue;
        const step: u64 = @intFromFloat(1.0 + @sqrt(entry.distance) / query_stagger_distance);
        if (frame % step != index % step) continue;
        try appendQueryBox(&boxes, gpa, entry.coord);
        try queried.append(gpa, entry.meshes);
    }
    if (queried.items.len == 0) return;

    const mesh = GpuMesh.upload(&boxes);
    defer mesh.deinit();

    gl.ColorMask(gl.FALSE, gl.FALSE, gl.FALSE, gl.FALSE);
    gl.DepthMask(gl.FALSE);
    shader.setInt(.u_textured, 0);
    shader.setInt(.u_alpha_test, 0);
    for (queried.items, 0..) |meshes, box| {
        if (meshes.query == 0) gl.GenQueries(1, @ptrCast(&meshes.query));
        gl.BeginQuery(query_target, meshes.query);
        mesh.drawRange(box * indices_per_query_box, indices_per_query_box);
        gl.EndQuery(query_target);
        meshes.waiting = true;
    }
    shader.setInt(.u_alpha_test, 1);
    shader.setInt(.u_textured, 1);
    gl.DepthMask(gl.TRUE);
    gl.ColorMask(gl.TRUE, gl.TRUE, gl.TRUE, gl.TRUE);
}

fn drawVisible(entries: []const Sorted) u32 {
    var drawn: u32 = 0;
    for (entries) |entry| {
        if (!entry.in_frustum or !entry.meshes.visible) continue;
        if (entry.meshes.solid.index_count == 0) continue;
        entry.meshes.solid.draw();
        drawn += 1;
    }
    return drawn;
}

pub fn drawSolid(
    self: *ChunkRenderer,
    gpa: std.mem.Allocator,
    shader: Shader,
    frustum: math.Frustum,
    eye: Eye,
    occlusion: bool,
    frame: u64,
) !u32 {
    if (!occlusion) {
        var drawn: u32 = 0;
        var it = self.meshes.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.visible = true;
            if (entry.value_ptr.solid.index_count == 0) continue;
            const bounds = chunkBounds(entry.key_ptr.*);
            if (!frustum.containsBox(bounds.min, bounds.max)) continue;
            entry.value_ptr.solid.draw();
            drawn += 1;
        }
        return drawn;
    }

    var sorted: std.ArrayList(Sorted) = .empty;
    defer sorted.deinit(gpa);
    try sorted.ensureTotalCapacity(gpa, self.meshes.count());

    var it = self.meshes.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.drawsNothing()) continue;
        const bounds = chunkBounds(entry.key_ptr.*);
        const dx = (bounds.min[0] + bounds.max[0]) / 2 - @as(f32, @floatCast(eye.x));
        const dy = (bounds.min[1] + bounds.max[1]) / 2 - @as(f32, @floatCast(eye.y));
        const dz = (bounds.min[2] + bounds.max[2]) / 2 - @as(f32, @floatCast(eye.z));
        sorted.appendAssumeCapacity(.{
            .meshes = entry.value_ptr,
            .coord = entry.key_ptr.*,
            .distance = dx * dx + dy * dy + dz * dz,
            .in_frustum = frustum.containsBox(bounds.min, bounds.max),
        });
    }
    std.mem.sort(Sorted, sorted.items, {}, Sorted.nearestFirst);

    for (sorted.items) |entry| {
        if (!entry.in_frustum) entry.meshes.visible = true;
    }

    var end: usize = @min(first_query_batch, sorted.items.len);
    readQueryResults(sorted.items[0..end]);
    for (sorted.items[0..end]) |entry| entry.meshes.visible = true;
    var drawn = drawVisible(sorted.items[0..end]);

    while (end < sorted.items.len) {
        const start = end;
        end = @min(end * 2, sorted.items.len);
        readQueryResults(sorted.items[start..end]);
        try issueQueries(gpa, shader, sorted.items[start..end], start, frame);
        drawn += drawVisible(sorted.items[start..end]);
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

    const width: f64 = @floatFromInt(world.Chunk.width);
    var it = self.meshes.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.translucent.index_count == 0) continue;
        if (!entry.value_ptr.visible) continue;
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

test "a query box wraps its chunk by the original's six block margin" {
    const gpa = std.testing.allocator;
    var boxes: MeshBuilder = .{};
    defer boxes.deinit(gpa);

    try appendQueryBox(&boxes, gpa, .{ .x = 0, .z = 0 });

    try std.testing.expectEqual(@as(usize, indices_per_query_box), boxes.indices.items.len);

    var min: [3]f32 = .{ std.math.floatMax(f32), std.math.floatMax(f32), std.math.floatMax(f32) };
    var max: [3]f32 = .{ -std.math.floatMax(f32), -std.math.floatMax(f32), -std.math.floatMax(f32) };
    for (boxes.vertices.items) |vertex| {
        const position = [3]f32{ vertex.x, vertex.y, vertex.z };
        for (position, 0..) |value, axis| {
            min[axis] = @min(min[axis], value);
            max[axis] = @max(max[axis], value);
        }
    }

    const width: f32 = @floatFromInt(world.Chunk.width);
    const height: f32 = @floatFromInt(world.Chunk.height);
    try std.testing.expectEqual([3]f32{ -query_box_margin, -query_box_margin, -query_box_margin }, min);
    try std.testing.expectEqual([3]f32{
        width + query_box_margin,
        height + query_box_margin,
        width + query_box_margin,
    }, max);
}

test "every query box face winds outward so back face culling keeps the near side" {
    const gpa = std.testing.allocator;
    var boxes: MeshBuilder = .{};
    defer boxes.deinit(gpa);

    try appendQueryBox(&boxes, gpa, .{ .x = 3, .z = -2 });

    var low: [3]f32 = .{ std.math.floatMax(f32), std.math.floatMax(f32), std.math.floatMax(f32) };
    var high: [3]f32 = .{ -std.math.floatMax(f32), -std.math.floatMax(f32), -std.math.floatMax(f32) };
    for (boxes.vertices.items) |vertex| {
        const position = [3]f32{ vertex.x, vertex.y, vertex.z };
        for (position, 0..) |value, axis| {
            low[axis] = @min(low[axis], value);
            high[axis] = @max(high[axis], value);
        }
    }
    const center = [3]f32{
        (low[0] + high[0]) / 2,
        (low[1] + high[1]) / 2,
        (low[2] + high[2]) / 2,
    };

    var face: usize = 0;
    while (face < query_box_faces.len) : (face += 1) {
        const corners = boxes.vertices.items[face * 4 ..][0..3];
        const a = [3]f32{ corners[0].x, corners[0].y, corners[0].z };
        const b = [3]f32{ corners[1].x, corners[1].y, corners[1].z };
        const c = [3]f32{ corners[2].x, corners[2].y, corners[2].z };
        const edge0 = [3]f32{ b[0] - a[0], b[1] - a[1], b[2] - a[2] };
        const edge1 = [3]f32{ c[0] - b[0], c[1] - b[1], c[2] - b[2] };
        const normal = [3]f32{
            edge0[1] * edge1[2] - edge0[2] * edge1[1],
            edge0[2] * edge1[0] - edge0[0] * edge1[2],
            edge0[0] * edge1[1] - edge0[1] * edge1[0],
        };
        const outward = [3]f32{ a[0] - center[0], a[1] - center[1], a[2] - center[2] };
        const alignment = normal[0] * outward[0] + normal[1] * outward[1] + normal[2] * outward[2];
        try std.testing.expect(alignment > 0);
    }
}
