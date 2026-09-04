const std = @import("std");

const block = @import("block.zig");
const Block = block.Block;
const nbt = @import("nbt.zig");
const World = @import("World.zig");

pub const width: i32 = 128;
pub const height: i32 = 128;
pub const area: usize = @intCast(width * height);

pub const default_scale: u8 = 3;
pub const max_scale: u8 = 4;
pub const marker_reach: f32 = 64.0;
pub const payload_columns: u8 = 0;
pub const payload_markers: u8 = 1;
const marker_period: i32 = 4;
const columns_per_send: usize = 10;
const column_stride: i32 = 11;

pub const Marker = struct {
    icon: u8,
    x: i8,
    z: i8,
    rotation: u8,
};

pub const ViewerState = struct {
    id: u32,
    x: f64,
    z: f64,
    dimension: i8,
    alive: bool,
    holding: bool,
};

const Viewer = struct {
    id: u32,
    min_row: [@intCast(width)]i32,
    max_row: [@intCast(width)]i32,
    column_cursor: i32 = 0,
    marker_countdown: i32 = 0,
    last_markers: std.ArrayList(u8) = .empty,

    fn init(id: u32) Viewer {
        return .{
            .id = id,
            .min_row = @splat(0),
            .max_row = @splat(height - 1),
        };
    }
};

pub const MapData = struct {
    id: i16,
    center_x: i32 = 0,
    center_z: i32 = 0,
    dimension: i8 = 0,
    scale: u8 = default_scale,
    colors: [area]u8 = @splat(0),
    stripe: i32 = 0,
    markers: std.ArrayList(Marker) = .empty,
    viewers: std.ArrayList(Viewer) = .empty,
    dirty: bool = false,

    pub fn deinit(self: *MapData, gpa: std.mem.Allocator) void {
        self.markers.deinit(gpa);
        for (self.viewers.items) |*viewer| viewer.last_markers.deinit(gpa);
        self.viewers.deinit(gpa);
    }

    pub fn markDirty(self: *MapData) void {
        self.dirty = true;
    }

    fn touchColumn(self: *MapData, column: i32, first_row: i32, last_row: i32) void {
        self.markDirty();
        for (self.viewers.items) |*viewer| {
            const at: usize = @intCast(column);
            if (viewer.min_row[at] < 0 or viewer.min_row[at] > first_row) viewer.min_row[at] = first_row;
            if (viewer.max_row[at] < 0 or viewer.max_row[at] < last_row) viewer.max_row[at] = last_row;
        }
    }

    pub fn updateColors(
        self: *MapData,
        world_map: *const World,
        world_type: i8,
        has_sky: bool,
        at_x: f64,
        at_z: f64,
    ) void {
        if (world_type != self.dimension) return;

        const step: i32 = @as(i32, 1) << @intCast(self.scale);
        const player_column = @divTrunc(floorDouble(at_x - @as(f64, @floatFromInt(self.center_x))), step) + @divTrunc(width, 2);
        const player_row = @divTrunc(floorDouble(at_z - @as(f64, @floatFromInt(self.center_z))), step) + @divTrunc(height, 2);
        var radius = @divTrunc(width, step);
        if (!has_sky) radius = @divTrunc(radius, 2);

        self.stripe += 1;

        var column = player_column - radius + 1;
        while (column < player_column + radius) : (column += 1) {
            if ((column & 15) != (self.stripe & 15)) continue;

            var first_row: i32 = 255;
            var last_row: i32 = 0;
            var previous_height: f64 = 0.0;

            var row = player_row - radius - 1;
            while (row < player_row + radius) : (row += 1) {
                if (column < 0 or row < -1 or column >= width or row >= height) continue;

                const dx = column - player_column;
                const dz = row - player_row;
                const fringe = dx * dx + dz * dz > (radius - 2) * (radius - 2);
                const world_x = (@divTrunc(self.center_x, step) + column - @divTrunc(width, 2)) * step;
                const world_z = (@divTrunc(self.center_z, step) + row - @divTrunc(height, 2)) * step;

                var histogram: [256]i32 = @splat(0);
                var depth: i32 = 0;
                var height_sum: f64 = 0.0;

                if (!has_sky) {
                    var hash: i32 = world_x +% world_z *% 231871;
                    hash = hash *% hash *% 31287121 +% hash *% 11;
                    if (hash >> 20 & 1 == 0) {
                        histogram[@intFromEnum(Block.dirt)] += 10;
                    } else {
                        histogram[@intFromEnum(Block.stone)] += 10;
                    }
                    height_sum = 100.0;
                } else {
                    const samples: f64 = @floatFromInt(step * step);
                    var sx: i32 = 0;
                    while (sx < step) : (sx += 1) {
                        var sz: i32 = 0;
                        while (sz < step) : (sz += 1) {
                            const sampled = sampleColumn(world_map, world_x + sx, world_z + sz, &depth);
                            height_sum += @as(f64, @floatFromInt(sampled.top)) / samples;
                            histogram[@intFromEnum(sampled.id)] += 1;
                        }
                    }
                }

                depth = @divTrunc(depth, step * step);

                var best_count: i32 = 0;
                var best_id: usize = 0;
                for (histogram, 0..) |count, id| {
                    if (count > best_count) {
                        best_id = id;
                        best_count = count;
                    }
                }

                const checker: f64 = @floatFromInt((column + row) & 1);
                var relief = (height_sum - previous_height) * 4.0 / @as(f64, @floatFromInt(step + 4)) + (checker - 0.5) * 0.4;
                var shade: u8 = 1;
                if (relief > 0.6) shade = 2;
                if (relief < -0.6) shade = 0;

                var tone: u8 = 0;
                if (best_id > 0) {
                    const map_color = @as(Block, @enumFromInt(best_id)).material().mapColor();
                    if (map_color == .water) {
                        relief = @as(f64, @floatFromInt(depth)) * 0.1 + checker * 0.2;
                        shade = 1;
                        if (relief < 0.5) shade = 2;
                        if (relief > 0.9) shade = 0;
                    }
                    tone = @intFromEnum(map_color);
                }

                previous_height = height_sum;
                if (row < 0) continue;
                if (dx * dx + dz * dz >= radius * radius) continue;
                if (fringe and (column + row) & 1 == 0) continue;

                const at: usize = @intCast(column + row * width);
                const shaded = tone * 4 + shade;
                if (self.colors[at] == shaded) continue;
                if (first_row > row) first_row = row;
                if (last_row < row) last_row = row;
                self.colors[at] = shaded;
            }

            if (first_row <= last_row) self.touchColumn(column, first_row, last_row);
        }
    }

    pub fn updateMarkers(
        self: *MapData,
        gpa: std.mem.Allocator,
        holder_yaw: f32,
        states: []const ViewerState,
    ) !void {
        for (states) |state| {
            if (self.viewerFor(state.id) != null) continue;
            try self.viewers.append(gpa, Viewer.init(state.id));
        }

        self.markers.clearRetainingCapacity();

        var index: usize = 0;
        while (index < self.viewers.items.len) {
            const state = stateFor(states, self.viewers.items[index].id);
            if (state == null or !state.?.alive or !state.?.holding) {
                self.viewers.items[index].last_markers.deinit(gpa);
                _ = self.viewers.orderedRemove(index);
                continue;
            }
            index += 1;

            const seen = state.?;
            const spread: f32 = @floatFromInt(@as(i32, 1) << @intCast(self.scale));
            const from_x = @as(f32, @floatCast(seen.x - @as(f64, @floatFromInt(self.center_x)))) / spread;
            const from_z = @as(f32, @floatCast(seen.z - @as(f64, @floatFromInt(self.center_z)))) / spread;
            if (from_x < -marker_reach or from_z < -marker_reach or from_x > marker_reach or from_z > marker_reach) continue;

            var rotation: i8 = @intCast(@as(i32, @intFromFloat(@as(f64, holder_yaw * 16.0 / 360.0) + 0.5)) & 0xff);
            if (self.dimension < 0) {
                const spin: i32 = @divTrunc(self.stripe, 10);
                rotation = @truncate(spin *% spin *% 34187121 +% spin *% 121 >> 15 & 15);
            }
            if (seen.dimension != self.dimension) continue;

            try self.markers.append(gpa, .{
                .icon = 0,
                .x = @truncate(@as(i32, @intFromFloat(@as(f64, from_x * 2.0) + 0.5))),
                .z = @truncate(@as(i32, @intFromFloat(@as(f64, from_z * 2.0) + 0.5))),
                .rotation = @bitCast(rotation),
            });
        }
    }

    fn viewerFor(self: *MapData, id: u32) ?*Viewer {
        for (self.viewers.items) |*viewer| {
            if (viewer.id == id) return viewer;
        }
        return null;
    }

    pub fn buildPayload(self: *MapData, gpa: std.mem.Allocator, id: u32, out: *std.ArrayList(u8)) !bool {
        const viewer = self.viewerFor(id) orelse return false;

        viewer.marker_countdown -= 1;
        if (viewer.marker_countdown < 0) {
            viewer.marker_countdown = marker_period;
            out.clearRetainingCapacity();
            try out.append(gpa, payload_markers);
            for (self.markers.items) |marker| {
                try out.append(gpa, marker.icon +% (marker.rotation & 15) *% 16);
                try out.append(gpa, @bitCast(marker.x));
                try out.append(gpa, @bitCast(marker.z));
            }
            if (!std.mem.eql(u8, out.items, viewer.last_markers.items)) {
                viewer.last_markers.clearRetainingCapacity();
                try viewer.last_markers.appendSlice(gpa, out.items);
                return true;
            }
        }

        for (0..columns_per_send) |_| {
            const column = @mod(viewer.column_cursor *% column_stride, width);
            viewer.column_cursor +%= 1;
            const at: usize = @intCast(column);
            if (viewer.min_row[at] < 0) continue;

            const first = viewer.min_row[at];
            const rows: usize = @intCast(viewer.max_row[at] - first + 1);
            out.clearRetainingCapacity();
            try out.append(gpa, payload_columns);
            try out.append(gpa, @intCast(column));
            try out.append(gpa, @intCast(first));
            for (0..rows) |offset| {
                const row: usize = @intCast(first + @as(i32, @intCast(offset)));
                try out.append(gpa, self.colors[row * @as(usize, @intCast(width)) + at]);
            }
            viewer.max_row[at] = -1;
            viewer.min_row[at] = -1;
            return true;
        }

        return false;
    }

    pub fn applyPayload(self: *MapData, gpa: std.mem.Allocator, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        if (bytes[0] == payload_columns) {
            if (bytes.len < 3) return;
            const column: usize = bytes[1];
            const first: usize = bytes[2];
            for (bytes[3..], 0..) |value, offset| {
                const row = first + offset;
                if (row >= @as(usize, @intCast(height)) or column >= @as(usize, @intCast(width))) continue;
                self.colors[row * @as(usize, @intCast(width)) + column] = value;
            }
            self.markDirty();
            return;
        }
        if (bytes[0] != payload_markers) return;

        self.markers.clearRetainingCapacity();
        var index: usize = 0;
        while (index < (bytes.len - 1) / 3) : (index += 1) {
            const packed_rotation: i8 = @bitCast(bytes[index * 3 + 1]);
            try self.markers.append(gpa, .{
                .icon = @bitCast(@as(i8, @rem(packed_rotation, 16))),
                .x = @bitCast(bytes[index * 3 + 2]),
                .z = @bitCast(bytes[index * 3 + 3]),
                .rotation = @bitCast(@as(i8, @divTrunc(packed_rotation, 16))),
            });
        }
    }
};

const Sampled = struct { top: i32, id: Block };

fn sampleColumn(world_map: *const World, x: i32, z: i32, depth: *i32) Sampled {
    const chunk = world_map.getChunk(x >> 4, z >> 4) orelse return .{ .top = 0, .id = .air };
    var top: i32 = @as(i32, chunk.getHeightValue(@intCast(x & 15), @intCast(z & 15))) + 1;
    var id: Block = .air;
    if (top <= 1) return .{ .top = top, .id = id };

    while (true) {
        id = world_map.getBlock(.init(x, top - 1, z));
        var covering = true;
        if (id == .air) {
            covering = false;
        } else if (top > 0 and id.material().mapColor() == .air) {
            covering = false;
        }

        if (!covering) {
            top -= 1;
            id = world_map.getBlock(.init(x, top - 1, z));
            if (top <= 0) return .{ .top = top, .id = id };
            continue;
        }

        if (!id.material().isLiquid()) return .{ .top = top, .id = id };

        var below = top - 1;
        while (true) {
            const under = world_map.getBlock(.init(x, below, z));
            below -= 1;
            depth.* += 1;
            if (below <= 0 or under == .air or !under.material().isLiquid()) return .{ .top = top, .id = id };
        }
    }
}

fn stateFor(states: []const ViewerState, id: u32) ?ViewerState {
    for (states) |state| {
        if (state.id == id) return state;
    }
    return null;
}

fn floorDouble(value: f64) i32 {
    const floored: i32 = @intFromFloat(value);
    return if (value < @as(f64, @floatFromInt(floored))) floored - 1 else floored;
}

pub fn writeToNbt(data: *const MapData, gpa: std.mem.Allocator, compound: *nbt.Compound) !void {
    try nbt.putDuped(gpa, compound, "dimension", .{ .byte = data.dimension });
    try nbt.putDuped(gpa, compound, "xCenter", .{ .int = data.center_x });
    try nbt.putDuped(gpa, compound, "zCenter", .{ .int = data.center_z });
    try nbt.putDuped(gpa, compound, "scale", .{ .byte = @intCast(data.scale) });
    try nbt.putDuped(gpa, compound, "width", .{ .short = @intCast(width) });
    try nbt.putDuped(gpa, compound, "height", .{ .short = @intCast(height) });
    try nbt.putDuped(gpa, compound, "colors", .{ .byte_array = try gpa.dupe(u8, &data.colors) });
}

pub fn readFromNbt(data: *MapData, compound: nbt.Compound) void {
    data.dimension = byteField(compound, "dimension", 0);
    data.center_x = intField(compound, "xCenter", 0);
    data.center_z = intField(compound, "zCenter", 0);

    const stored_scale = byteField(compound, "scale", 0);
    data.scale = if (stored_scale < 0) 0 else if (stored_scale > max_scale) max_scale else @intCast(stored_scale);

    const stored_width = shortField(compound, "width", 0);
    const stored_height = shortField(compound, "height", 0);
    const stored = switch (compound.get("colors") orelse return) {
        .byte_array => |value| value,
        else => return,
    };

    if (stored_width == width and stored_height == height) {
        const span = @min(stored.len, data.colors.len);
        @memcpy(data.colors[0..span], stored[0..span]);
        return;
    }

    data.colors = @splat(0);
    const left = @divTrunc(width - stored_width, 2);
    const top = @divTrunc(height - stored_height, 2);
    var row: i32 = 0;
    while (row < stored_height) : (row += 1) {
        const target_row = row + top;
        var column: i32 = 0;
        while (column < stored_width) : (column += 1) {
            const target_column = column + left;
            if (target_row < 0 or target_row >= height or target_column < 0 or target_column >= width) continue;
            const source: usize = @intCast(column + row * stored_width);
            if (source >= stored.len) continue;
            data.colors[@intCast(target_column + target_row * width)] = stored[source];
        }
    }
}

fn byteField(compound: nbt.Compound, key: []const u8, fallback: i8) i8 {
    return switch (compound.get(key) orelse return fallback) {
        .byte => |value| value,
        else => fallback,
    };
}

fn shortField(compound: nbt.Compound, key: []const u8, fallback: i16) i16 {
    return switch (compound.get(key) orelse return fallback) {
        .short => |value| value,
        else => fallback,
    };
}

fn intField(compound: nbt.Compound, key: []const u8, fallback: i32) i32 {
    return switch (compound.get(key) orelse return fallback) {
        .int => |value| value,
        else => fallback,
    };
}
