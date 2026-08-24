const std = @import("std");

const math = @import("math");

const block = @import("block.zig");
const Block = block.Block;
const Chunk = @import("Chunk.zig");
const testing = @import("testing.zig");
const World = @import("World.zig");

pub const Point = struct {
    x: i32,
    y: i32,
    z: i32,

    pub fn distanceTo(self: Point, other: Point) f32 {
        const dx: f32 = @floatFromInt(other.x - self.x);
        const dy: f32 = @floatFromInt(other.y - self.y);
        const dz: f32 = @floatFromInt(other.z - self.z);
        return @sqrt(dx * dx + dy * dy + dz * dz);
    }
};

pub const Size = struct { x: i32, y: i32, z: i32 };

pub const Mob = struct {
    min_x: f64,
    min_y: f64,
    min_z: f64,
    width: f32,
    height: f32,

    fn size(self: Mob) Size {
        return .{
            .x = math.util.floorFloat(self.width + 1.0),
            .y = math.util.floorFloat(self.height + 1.0),
            .z = math.util.floorFloat(self.width + 1.0),
        };
    }

    fn footprintOffset(self: Mob) f64 {
        return @as(f64, @floatFromInt(@as(i32, @intFromFloat(self.width + 1.0)))) * 0.5;
    }
};

pub const Path = struct {
    points: []Point,
    index: usize = 0,

    pub fn deinit(self: *Path, gpa: std.mem.Allocator) void {
        gpa.free(self.points);
        self.points = &.{};
    }

    pub fn incrementIndex(self: *Path) void {
        self.index += 1;
    }

    pub fn isFinished(self: Path) bool {
        return self.index >= self.points.len;
    }

    pub fn destination(self: Path) ?Point {
        if (self.points.len == 0) return null;
        return self.points[self.points.len - 1];
    }

    pub fn position(self: Path, mob: Mob) [3]f64 {
        const offset = mob.footprintOffset();
        const point = self.points[self.index];
        return .{
            @as(f64, @floatFromInt(point.x)) + offset,
            @floatFromInt(point.y),
            @as(f64, @floatFromInt(point.z)) + offset,
        };
    }
};

const Clearance = enum { blocked, water, lava, open };

const Node = struct {
    point: Point,
    total_distance: f32 = 0,
    distance_to_next: f32 = 0,
    priority: f32 = 0,
    previous: ?u32 = null,
    heap_index: ?u32 = null,
    closed: bool = false,
};

const Finder = struct {
    gpa: std.mem.Allocator,
    world_map: *const World,
    nodes: std.ArrayList(Node) = .empty,
    lookup: std.AutoHashMapUnmanaged(Point, u32) = .empty,
    heap: std.ArrayList(u32) = .empty,

    fn deinit(self: *Finder) void {
        self.nodes.deinit(self.gpa);
        self.lookup.deinit(self.gpa);
        self.heap.deinit(self.gpa);
    }

    fn openPoint(self: *Finder, point: Point) !u32 {
        const entry = try self.lookup.getOrPut(self.gpa, point);
        if (entry.found_existing) return entry.value_ptr.*;

        const index: u32 = @intCast(self.nodes.items.len);
        self.nodes.append(self.gpa, .{ .point = point }) catch |err| {
            _ = self.lookup.remove(point);
            return err;
        };
        entry.value_ptr.* = index;
        return index;
    }

    fn addToHeap(self: *Finder, index: u32) !void {
        try self.heap.append(self.gpa, index);
        const slot: u32 = @intCast(self.heap.items.len - 1);
        self.nodes.items[index].heap_index = slot;
        self.sortBack(slot);
    }

    fn dequeue(self: *Finder) u32 {
        const first = self.heap.items[0];
        const last = self.heap.pop().?;
        if (self.heap.items.len > 0) {
            self.heap.items[0] = last;
            self.nodes.items[last].heap_index = 0;
            self.sortForward(0);
        }
        self.nodes.items[first].heap_index = null;
        return first;
    }

    fn changePriority(self: *Finder, index: u32, priority: f32) void {
        const previous = self.nodes.items[index].priority;
        self.nodes.items[index].priority = priority;
        const slot = self.nodes.items[index].heap_index.?;
        if (priority < previous) self.sortBack(slot) else self.sortForward(slot);
    }

    fn sortBack(self: *Finder, start: u32) void {
        var slot = start;
        const index = self.heap.items[slot];
        const priority = self.nodes.items[index].priority;

        while (slot > 0) {
            const parent = (slot - 1) >> 1;
            const parent_index = self.heap.items[parent];
            if (priority >= self.nodes.items[parent_index].priority) break;
            self.heap.items[slot] = parent_index;
            self.nodes.items[parent_index].heap_index = slot;
            slot = parent;
        }

        self.heap.items[slot] = index;
        self.nodes.items[index].heap_index = slot;
    }

    fn sortForward(self: *Finder, start: u32) void {
        var slot = start;
        const index = self.heap.items[slot];
        const priority = self.nodes.items[index].priority;
        const count = self.heap.items.len;

        while (true) {
            const left = 1 + (slot << 1);
            const right = left + 1;
            if (left >= count) break;

            const left_index = self.heap.items[left];
            const left_priority = self.nodes.items[left_index].priority;
            const right_priority: f32 = if (right >= count)
                std.math.inf(f32)
            else
                self.nodes.items[self.heap.items[right]].priority;

            const chosen = if (left_priority < right_priority) left else right;
            const chosen_priority = @min(left_priority, right_priority);
            if (chosen_priority >= priority) break;

            const chosen_index = self.heap.items[chosen];
            self.heap.items[slot] = chosen_index;
            self.nodes.items[chosen_index].heap_index = slot;
            slot = @intCast(chosen);
        }

        self.heap.items[slot] = index;
        self.nodes.items[index].heap_index = slot;
    }

    fn clearance(self: *Finder, base: Point, size: Size) Clearance {
        var x = base.x;
        while (x < base.x + size.x) : (x += 1) {
            var y = base.y;
            while (y < base.y + size.y) : (y += 1) {
                var z = base.z;
                while (z < base.z + size.z) : (z += 1) {
                    const id = self.world_map.getBlock(x, y, z);
                    if (id == .air) continue;
                    const material = id.material();
                    if (material.isSolid()) return .blocked;
                    if (material == .water) return .water;
                    if (material == .lava) return .lava;
                }
            }
        }
        return .open;
    }

    fn safePoint(self: *Finder, base: Point, size: Size, step_up: i32) !?u32 {
        var y = base.y;
        var found: ?u32 = null;

        if (self.clearance(base, size) == .open) {
            found = try self.openPoint(base);
        }

        if (found == null and step_up > 0 and self.clearance(.{ .x = base.x, .y = base.y + step_up, .z = base.z }, size) == .open) {
            y += step_up;
            found = try self.openPoint(.{ .x = base.x, .y = y, .z = base.z });
        }

        if (found == null) return null;

        var dropped: i32 = 0;
        var below: Clearance = .blocked;
        while (y > 0) {
            below = self.clearance(.{ .x = base.x, .y = y - 1, .z = base.z }, size);
            if (below != .open) break;

            dropped += 1;
            if (dropped >= 4) return null;

            y -= 1;
            if (y > 0) found = try self.openPoint(.{ .x = base.x, .y = y, .z = base.z });
        }

        if (below == .lava) return null;
        return found;
    }

    fn findOptions(self: *Finder, from: u32, size: Size, target: Point, max_distance: f32, out: *[4]u32) !usize {
        const origin = self.nodes.items[from].point;
        const step_up: i32 = if (self.clearance(.{ .x = origin.x, .y = origin.y + 1, .z = origin.z }, size) == .open) 1 else 0;

        const candidates = [4]Point{
            .{ .x = origin.x, .y = origin.y, .z = origin.z + 1 },
            .{ .x = origin.x - 1, .y = origin.y, .z = origin.z },
            .{ .x = origin.x + 1, .y = origin.y, .z = origin.z },
            .{ .x = origin.x, .y = origin.y, .z = origin.z - 1 },
        };

        var count: usize = 0;
        for (candidates) |candidate| {
            const index = try self.safePoint(candidate, size, step_up) orelse continue;
            const node = self.nodes.items[index];
            if (node.closed) continue;
            if (node.point.distanceTo(target) >= max_distance) continue;
            out[count] = index;
            count += 1;
        }
        return count;
    }

    fn buildPath(self: *Finder, end: u32) ![]Point {
        var length: usize = 1;
        var walk = end;
        while (self.nodes.items[walk].previous) |previous| {
            length += 1;
            walk = previous;
        }

        const points = try self.gpa.alloc(Point, length);
        var slot = length;
        walk = end;
        while (true) {
            slot -= 1;
            points[slot] = self.nodes.items[walk].point;
            walk = self.nodes.items[walk].previous orelse break;
        }
        return points;
    }

    fn search(self: *Finder, start: u32, target: u32, size: Size, max_distance: f32) !?[]Point {
        const target_point = self.nodes.items[target].point;

        self.nodes.items[start].total_distance = 0;
        self.nodes.items[start].distance_to_next = self.nodes.items[start].point.distanceTo(target_point);
        self.nodes.items[start].priority = self.nodes.items[start].distance_to_next;
        try self.addToHeap(start);

        var closest = start;
        var options: [4]u32 = undefined;

        while (self.heap.items.len > 0) {
            const current = self.dequeue();
            const current_point = self.nodes.items[current].point;
            if (std.meta.eql(current_point, target_point)) return try self.buildPath(target);

            if (current_point.distanceTo(target_point) < self.nodes.items[closest].point.distanceTo(target_point)) {
                closest = current;
            }

            self.nodes.items[current].closed = true;
            const count = try self.findOptions(current, size, target_point, max_distance, &options);

            for (options[0..count]) |option| {
                const total = self.nodes.items[current].total_distance +
                    current_point.distanceTo(self.nodes.items[option].point);
                const assigned = self.nodes.items[option].heap_index != null;
                if (assigned and total >= self.nodes.items[option].total_distance) continue;

                self.nodes.items[option].previous = current;
                self.nodes.items[option].total_distance = total;
                self.nodes.items[option].distance_to_next = self.nodes.items[option].point.distanceTo(target_point);

                if (assigned) {
                    self.changePriority(option, total + self.nodes.items[option].distance_to_next);
                } else {
                    self.nodes.items[option].priority = total + self.nodes.items[option].distance_to_next;
                    try self.addToHeap(option);
                }
            }
        }

        if (closest == start) return null;
        return try self.buildPath(closest);
    }
};

pub fn toPosition(
    gpa: std.mem.Allocator,
    world_map: *const World,
    mob: Mob,
    target_x: f64,
    target_y: f64,
    target_z: f64,
    max_distance: f32,
) !?Path {
    var finder = Finder{ .gpa = gpa, .world_map = world_map };
    defer finder.deinit();

    const start = try finder.openPoint(.{
        .x = math.util.floorDouble(mob.min_x),
        .y = math.util.floorDouble(mob.min_y),
        .z = math.util.floorDouble(mob.min_z),
    });
    const target = try finder.openPoint(.{
        .x = math.util.floorDouble(target_x - @as(f64, mob.width / 2.0)),
        .y = math.util.floorDouble(target_y),
        .z = math.util.floorDouble(target_z - @as(f64, mob.width / 2.0)),
    });

    const points = try finder.search(start, target, mob.size(), max_distance) orelse return null;
    return .{ .points = points };
}

pub fn toBlock(
    gpa: std.mem.Allocator,
    world_map: *const World,
    mob: Mob,
    x: i32,
    y: i32,
    z: i32,
    max_distance: f32,
) !?Path {
    return toPosition(
        gpa,
        world_map,
        mob,
        @as(f64, @as(f32, @floatFromInt(x)) + 0.5),
        @as(f64, @as(f32, @floatFromInt(y)) + 0.5),
        @as(f64, @as(f32, @floatFromInt(z)) + 0.5),
        max_distance,
    );
}

fn pigAt(x: f64, y: f64, z: f64) Mob {
    return .{ .min_x = x - 0.45, .min_y = y, .min_z = z - 0.45, .width = 0.9, .height = 0.9 };
}

fn walledWorld(gpa: std.mem.Allocator, floor_height: u32) !World {
    var w = try testing.flatWorld(gpa, floor_height);
    errdefer w.deinit();

    const top: i32 = @intCast(floor_height);
    var x: i32 = 0;
    while (x < Chunk.width) : (x += 1) {
        var z: i32 = 0;
        while (z < Chunk.width) : (z += 1) {
            w.setBlock(x, top, z, .stone);
            w.setBlock(x, top + 1, z, .stone);
        }
    }
    return w;
}

fn carve(w: *World, top: i32, x0: i32, x1: i32, z0: i32, z1: i32) void {
    var x = x0;
    while (x <= x1) : (x += 1) {
        var z = z0;
        while (z <= z1) : (z += 1) {
            w.setBlock(x, top, z, .air);
            w.setBlock(x, top + 1, z, .air);
        }
    }
}

test "a pig-sized mob walks a straight line across open ground" {
    const gpa = std.testing.allocator;
    var w = try testing.flatWorld(gpa, 1);
    defer w.deinit();

    var path = (try toBlock(gpa, &w, pigAt(4.5, 1, 8.5), 10, 1, 8, 16.0)).?;
    defer path.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 7), path.points.len);
    try std.testing.expectEqual(Point{ .x = 4, .y = 1, .z = 8 }, path.points[0]);
    try std.testing.expectEqual(Point{ .x = 10, .y = 1, .z = 8 }, path.points[path.points.len - 1]);
}

test "a wall in the way is routed around through the gap" {
    const gpa = std.testing.allocator;
    var w = try walledWorld(gpa, 1);
    defer w.deinit();

    carve(&w, 1, 2, 12, 2, 14);
    var z: i32 = 2;
    while (z <= 12) : (z += 1) {
        w.setBlock(7, 1, z, .stone);
        w.setBlock(7, 2, z, .stone);
    }

    var path = (try toBlock(gpa, &w, pigAt(4.5, 1, 8.5), 10, 1, 8, 16.0)).?;
    defer path.deinit(gpa);

    try std.testing.expectEqual(Point{ .x = 10, .y = 1, .z = 8 }, path.points[path.points.len - 1]);

    var went_around = false;
    for (path.points) |point| {
        try std.testing.expect(!(point.x == 7 and point.z <= 12));
        if (point.z >= 13) went_around = true;
    }
    try std.testing.expect(went_around);
}

test "a one-block rise is stepped up onto" {
    const gpa = std.testing.allocator;
    var w = try testing.flatWorld(gpa, 1);
    defer w.deinit();

    var x: i32 = 6;
    while (x <= 10) : (x += 1) {
        var z: i32 = 6;
        while (z <= 10) : (z += 1) w.setBlock(x, 1, z, .stone);
    }

    var path = (try toBlock(gpa, &w, pigAt(4.5, 1, 8.5), 8, 2, 8, 16.0)).?;
    defer path.deinit(gpa);

    try std.testing.expectEqual(Point{ .x = 8, .y = 2, .z = 8 }, path.points[path.points.len - 1]);
}

test "a lava moat is never crossed" {
    const gpa = std.testing.allocator;
    var w = try walledWorld(gpa, 1);
    defer w.deinit();

    carve(&w, 1, 2, 13, 7, 9);
    var z: i32 = 7;
    while (z <= 9) : (z += 1) w.setBlock(7, 1, z, .stationary_lava);

    const path = try toBlock(gpa, &w, pigAt(4.5, 1, 8.5), 12, 1, 8, 16.0);
    if (path) |found| {
        var owned = found;
        defer owned.deinit(gpa);
        for (owned.points) |point| try std.testing.expect(point.x < 7);
    }
}

test "a drop of more than three blocks is not taken" {
    const gpa = std.testing.allocator;
    var w = try walledWorld(gpa, 9);
    defer w.deinit();

    carve(&w, 9, 2, 13, 7, 9);
    var x: i32 = 7;
    while (x <= 9) : (x += 1) {
        var z: i32 = 7;
        while (z <= 9) : (z += 1) {
            var y: i32 = 1;
            while (y < 9) : (y += 1) w.setBlock(x, y, z, .air);
        }
    }

    const path = try toBlock(gpa, &w, pigAt(4.5, 9, 8.5), 12, 9, 8, 16.0);
    if (path) |found| {
        var owned = found;
        defer owned.deinit(gpa);
        for (owned.points) |point| try std.testing.expect(point.x < 7);
    }
}

test "an unreachable target still yields the closest approach" {
    const gpa = std.testing.allocator;
    var w = try walledWorld(gpa, 1);
    defer w.deinit();

    carve(&w, 1, 2, 8, 7, 9);

    var path = (try toBlock(gpa, &w, pigAt(4.5, 1, 8.5), 12, 1, 8, 16.0)).?;
    defer path.deinit(gpa);

    const end = path.destination().?;
    try std.testing.expectEqual(@as(i32, 8), end.x);
}

test "the walked position is centred in the block for a pig-sized mob" {
    const gpa = std.testing.allocator;
    var w = try testing.flatWorld(gpa, 1);
    defer w.deinit();

    var path = (try toBlock(gpa, &w, pigAt(4.5, 1, 8.5), 6, 1, 8, 16.0)).?;
    defer path.deinit(gpa);

    const position = path.position(pigAt(4.5, 1, 8.5));
    try std.testing.expectApproxEqAbs(@as(f64, 4.5), position[0], 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 8.5), position[2], 1.0e-9);
}
