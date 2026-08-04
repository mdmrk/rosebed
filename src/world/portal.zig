const std = @import("std");

const block = @import("block.zig");
const Block = block.Block;
const JavaRandom = @import("java_random.zig");
const World = @import("world_map.zig");

pub const frame_width = 2;
pub const frame_height = 3;

pub fn spansX(world_map: *const World, x: i32, y: i32, z: i32) bool {
    return world_map.getBlock(x - 1, y, z) == .portal or world_map.getBlock(x + 1, y, z) == .portal;
}

pub fn bounds(world_map: *const World, x: i32, y: i32, z: i32) block.Bounds {
    return block.portalBounds(spansX(world_map, x, y, z));
}

pub fn tryCreate(world_map: *World, x_in: i32, y: i32, z_in: i32) !bool {
    var x = x_in;
    var z = z_in;

    var step_x: i32 = 0;
    var step_z: i32 = 0;
    if (world_map.getBlock(x - 1, y, z) == .obsidian or world_map.getBlock(x + 1, y, z) == .obsidian) step_x = 1;
    if (world_map.getBlock(x, y, z - 1) == .obsidian or world_map.getBlock(x, y, z + 1) == .obsidian) step_z = 1;
    if (step_x == step_z) return false;

    if (world_map.getBlock(x - step_x, y, z - step_z) == .air) {
        x -= step_x;
        z -= step_z;
    }

    var across: i32 = -1;
    while (across <= frame_width) : (across += 1) {
        var up: i32 = -1;
        while (up <= frame_height) : (up += 1) {
            const on_frame = across == -1 or across == frame_width or up == -1 or up == frame_height;
            if ((across == -1 or across == frame_width) and (up == -1 or up == frame_height)) continue;

            const found = world_map.getBlock(x + step_x * across, y + up, z + step_z * across);
            if (on_frame) {
                if (found != .obsidian) return false;
            } else if (found != .air and found != .fire) {
                return false;
            }
        }
    }

    world_map.editing_blocks = true;
    defer world_map.editing_blocks = false;

    across = 0;
    while (across < frame_width) : (across += 1) {
        var up: i32 = 0;
        while (up < frame_height) : (up += 1) {
            try world_map.setBlockWithNotify(x + step_x * across, y + up, z + step_z * across, .portal);
        }
    }
    return true;
}

pub fn onNeighborChange(world_map: *World, x: i32, y: i32, z: i32) !void {
    var side_x: i32 = 0;
    var side_z: i32 = 1;
    if (world_map.getBlock(x - 1, y, z) == .portal or world_map.getBlock(x + 1, y, z) == .portal) {
        side_x = 1;
        side_z = 0;
    }

    var base = y;
    while (world_map.getBlock(x, base - 1, z) == .portal) base -= 1;

    if (world_map.getBlock(x, base - 1, z) != .obsidian) {
        try world_map.setBlockWithNotify(x, y, z, .air);
        return;
    }

    var height: i32 = 1;
    while (height < 4 and world_map.getBlock(x, base + height, z) == .portal) height += 1;

    if (height != frame_height or world_map.getBlock(x, base + height, z) != .obsidian) {
        try world_map.setBlockWithNotify(x, y, z, .air);
        return;
    }

    const along_x = world_map.getBlock(x - 1, y, z) == .portal or world_map.getBlock(x + 1, y, z) == .portal;
    const along_z = world_map.getBlock(x, y, z - 1) == .portal or world_map.getBlock(x, y, z + 1) == .portal;
    if (along_x and along_z) {
        try world_map.setBlockWithNotify(x, y, z, .air);
        return;
    }

    const forward_framed = world_map.getBlock(x + side_x, y, z + side_z) == .obsidian and
        world_map.getBlock(x - side_x, y, z - side_z) == .portal;
    const backward_framed = world_map.getBlock(x - side_x, y, z - side_z) == .obsidian and
        world_map.getBlock(x + side_x, y, z + side_z) == .portal;
    if (!forward_framed and !backward_framed) try world_map.setBlockWithNotify(x, y, z, .air);
}

pub const Destination = struct {
    x: f64,
    y: f64,
    z: f64,
};

const search_radius: i32 = 128;
const build_radius: i32 = 16;

pub fn findExisting(world_map: *const World, from_x: f64, from_y: f64, from_z: f64) ?Destination {
    var best_distance: f64 = -1.0;
    var best_x: i32 = 0;
    var best_y: i32 = 0;
    var best_z: i32 = 0;

    const center_x = @as(i32, @intFromFloat(@floor(from_x)));
    const center_z = @as(i32, @intFromFloat(@floor(from_z)));

    var x = center_x - search_radius;
    while (x <= center_x + search_radius) : (x += 1) {
        const dx = @as(f64, @floatFromInt(x)) + 0.5 - from_x;
        var z = center_z - search_radius;
        while (z <= center_z + search_radius) : (z += 1) {
            const dz = @as(f64, @floatFromInt(z)) + 0.5 - from_z;
            var y: i32 = 127;
            while (y >= 0) : (y -= 1) {
                if (world_map.getBlock(x, y, z) != .portal) continue;
                while (world_map.getBlock(x, y - 1, z) == .portal) y -= 1;

                const dy = @as(f64, @floatFromInt(y)) + 0.5 - from_y;
                const distance = dx * dx + dy * dy + dz * dz;
                if (best_distance < 0.0 or distance < best_distance) {
                    best_distance = distance;
                    best_x = x;
                    best_y = y;
                    best_z = z;
                }
            }
        }
    }

    if (best_distance < 0.0) return null;

    var out_x = @as(f64, @floatFromInt(best_x)) + 0.5;
    const out_y = @as(f64, @floatFromInt(best_y)) + 0.5;
    var out_z = @as(f64, @floatFromInt(best_z)) + 0.5;

    if (world_map.getBlock(best_x - 1, best_y, best_z) == .portal) out_x -= 0.5;
    if (world_map.getBlock(best_x + 1, best_y, best_z) == .portal) out_x += 0.5;
    if (world_map.getBlock(best_x, best_y, best_z - 1) == .portal) out_z -= 0.5;
    if (world_map.getBlock(best_x, best_y, best_z + 1) == .portal) out_z += 0.5;

    return .{ .x = out_x, .y = out_y, .z = out_z };
}

const Placement = struct {
    x: i32,
    y: i32,
    z: i32,
    orientation: i32,
    distance: f64,
};

fn clearanceAt(world_map: *const World, x: i32, y: i32, z: i32, step_x: i32, step_z: i32, depth: i32) bool {
    var across: i32 = 0;
    while (across < 4) : (across += 1) {
        var up: i32 = -1;
        while (up < 4) : (up += 1) {
            const cell_x = x + (across - 1) * step_x + depth * step_z;
            const cell_y = y + up;
            const cell_z = z + (across - 1) * step_z - depth * step_x;
            if (up < 0) {
                if (!world_map.getBlock(cell_x, cell_y, cell_z).material().isSolid()) return false;
            } else if (world_map.getBlock(cell_x, cell_y, cell_z) != .air) {
                return false;
            }
        }
    }
    return true;
}

fn searchPlacement(world_map: *const World, from_x: f64, from_y: f64, from_z: f64, first_orientation: i32, orientations: i32, depths: i32) ?Placement {
    var best: ?Placement = null;

    const center_x = @as(i32, @intFromFloat(@floor(from_x)));
    const center_z = @as(i32, @intFromFloat(@floor(from_z)));

    var x = center_x - build_radius;
    while (x <= center_x + build_radius) : (x += 1) {
        const dx = @as(f64, @floatFromInt(x)) + 0.5 - from_x;
        var z = center_z - build_radius;
        while (z <= center_z + build_radius) : (z += 1) {
            const dz = @as(f64, @floatFromInt(z)) + 0.5 - from_z;
            var y: i32 = 127;
            column: while (y >= 0) : (y -= 1) {
                if (world_map.getBlock(x, y, z) != .air) continue;
                while (y > 0 and world_map.getBlock(x, y - 1, z) == .air) y -= 1;

                var orientation = first_orientation;
                while (orientation < first_orientation + orientations) : (orientation += 1) {
                    var step_x = @mod(orientation, 2);
                    var step_z = 1 - step_x;
                    if (orientations == 4 and @mod(orientation, 4) >= 2) {
                        step_x = -step_x;
                        step_z = -step_z;
                    }

                    var depth: i32 = 0;
                    while (depth < depths) : (depth += 1) {
                        if (!clearanceAt(world_map, x, y, z, step_x, step_z, depth)) continue :column;
                    }

                    const dy = @as(f64, @floatFromInt(y)) + 0.5 - from_y;
                    const distance = dx * dx + dy * dy + dz * dz;
                    if (best == null or distance < best.?.distance) {
                        best = .{
                            .x = x,
                            .y = y,
                            .z = z,
                            .orientation = @mod(orientation, orientations),
                            .distance = distance,
                        };
                    }
                }
            }
        }
    }

    return best;
}

pub fn create(world_map: *World, rand: *JavaRandom, from_x: f64, from_y: f64, from_z: f64) !void {
    const first_orientation = rand.nextIntBound(4);

    var placement = searchPlacement(world_map, from_x, from_y, from_z, first_orientation, 4, 3);
    if (placement == null) placement = searchPlacement(world_map, from_x, from_y, from_z, first_orientation, 2, 1);

    var origin_x = @as(i32, @intFromFloat(@floor(from_x)));
    var origin_y = @as(i32, @intFromFloat(@floor(from_y)));
    var origin_z = @as(i32, @intFromFloat(@floor(from_z)));
    var orientation: i32 = 0;
    const clear = placement != null;

    if (placement) |found| {
        origin_x = found.x;
        origin_y = found.y;
        origin_z = found.z;
        orientation = found.orientation;
    }

    var step_x = @mod(orientation, 2);
    var step_z = 1 - step_x;
    if (@mod(orientation, 4) >= 2) {
        step_x = -step_x;
        step_z = -step_z;
    }

    if (!clear) {
        origin_y = std.math.clamp(origin_y, 70, 118);

        var side: i32 = -1;
        while (side <= 1) : (side += 1) {
            var across: i32 = 1;
            while (across < 3) : (across += 1) {
                var up: i32 = -1;
                while (up < 3) : (up += 1) {
                    const cell_x = origin_x + (across - 1) * step_x + side * step_z;
                    const cell_y = origin_y + up;
                    const cell_z = origin_z + (across - 1) * step_z - side * step_x;
                    try world_map.setBlockWithNotify(cell_x, cell_y, cell_z, if (up < 0) .obsidian else .air);
                }
            }
        }
    }

    for (0..4) |_| {
        world_map.editing_blocks = true;
        var across: i32 = 0;
        while (across < 4) : (across += 1) {
            var up: i32 = -1;
            while (up < 4) : (up += 1) {
                const cell_x = origin_x + (across - 1) * step_x;
                const cell_y = origin_y + up;
                const cell_z = origin_z + (across - 1) * step_z;
                const frame = across == 0 or across == 3 or up == -1 or up == frame_height;
                try world_map.setBlockWithNotify(cell_x, cell_y, cell_z, if (frame) .obsidian else .portal);
            }
        }
        world_map.editing_blocks = false;

        across = 0;
        while (across < 4) : (across += 1) {
            var up: i32 = -1;
            while (up < 4) : (up += 1) {
                const cell_x = origin_x + (across - 1) * step_x;
                const cell_y = origin_y + up;
                const cell_z = origin_z + (across - 1) * step_z;
                try world_map.notifyBlocksOfNeighborChange(cell_x, cell_y, cell_z, world_map.getBlock(cell_x, cell_y, cell_z));
            }
        }
    }
}

pub fn placeInto(world_map: *World, rand: *JavaRandom, from_x: f64, from_y: f64, from_z: f64) !Destination {
    if (findExisting(world_map, from_x, from_y, from_z)) |found| return found;

    try create(world_map, rand, from_x, from_y, from_z);
    return findExisting(world_map, from_x, from_y, from_z) orelse .{ .x = from_x, .y = from_y, .z = from_z };
}

fn obsidianFrameWorld(gpa: std.mem.Allocator, along_x: bool) !World {
    var w = World.init(gpa);
    var chunk_x: i32 = -1;
    while (chunk_x <= 1) : (chunk_x += 1) {
        var chunk_z: i32 = -1;
        while (chunk_z <= 1) : (chunk_z += 1) {
            const chunk = try w.createChunk(chunk_x, chunk_z);
            for (0..16) |x| {
                for (0..16) |z| {
                    chunk.setBlock(@intCast(x), 63, @intCast(z), .stone);
                }
            }
        }
    }

    const step_x: i32 = if (along_x) 1 else 0;
    const step_z: i32 = if (along_x) 0 else 1;

    var across: i32 = -1;
    while (across <= frame_width) : (across += 1) {
        var up: i32 = -1;
        while (up <= frame_height) : (up += 1) {
            const on_frame = across == -1 or across == frame_width or up == -1 or up == frame_height;
            const corner = (across == -1 or across == frame_width) and (up == -1 or up == frame_height);
            if (!on_frame or corner) continue;
            w.setBlock(8 + step_x * across, 64 + up, 8 + step_z * across, .obsidian);
        }
    }
    return w;
}

test "lighting a fire inside a finished obsidian frame fills it with portal blocks" {
    const gpa = std.testing.allocator;

    for ([_]bool{ true, false }) |along_x| {
        var w = try obsidianFrameWorld(gpa, along_x);
        defer w.deinit();

        try std.testing.expect(try tryCreate(&w, 8, 64, 8));

        const step_x: i32 = if (along_x) 1 else 0;
        const step_z: i32 = if (along_x) 0 else 1;
        var across: i32 = 0;
        while (across < frame_width) : (across += 1) {
            var up: i32 = 0;
            while (up < frame_height) : (up += 1) {
                try std.testing.expectEqual(
                    .portal,
                    w.getBlock(8 + step_x * across, 64 + up, 8 + step_z * across),
                );
            }
        }
    }
}

test "a frame with a hole in it does not light" {
    const gpa = std.testing.allocator;
    var w = try obsidianFrameWorld(gpa, true);
    defer w.deinit();

    w.setBlock(8, 67, 8, .air);

    try std.testing.expect(!try tryCreate(&w, 8, 64, 8));
    try std.testing.expectEqual(.air, w.getBlock(8, 64, 8));
}

test "a frame blocked by something other than fire does not light" {
    const gpa = std.testing.allocator;
    var w = try obsidianFrameWorld(gpa, true);
    defer w.deinit();

    w.setBlock(9, 65, 8, .stone);

    try std.testing.expect(!try tryCreate(&w, 8, 64, 8));
}

test "fire already burning in the frame does not stop it lighting" {
    const gpa = std.testing.allocator;
    var w = try obsidianFrameWorld(gpa, true);
    defer w.deinit();

    w.setBlock(8, 64, 8, .fire);

    try std.testing.expect(try tryCreate(&w, 8, 64, 8));
    try std.testing.expectEqual(.portal, w.getBlock(8, 64, 8));
}

test "obsidian on neither axis, or both, leaves the frame unlit" {
    const gpa = std.testing.allocator;
    var w = World.init(gpa);
    defer w.deinit();
    _ = try w.createChunk(0, 0);

    try std.testing.expect(!try tryCreate(&w, 8, 64, 8));

    w.setBlock(7, 64, 8, .obsidian);
    w.setBlock(8, 64, 7, .obsidian);
    try std.testing.expect(!try tryCreate(&w, 8, 64, 8));
}

fn litPortalWorld(gpa: std.mem.Allocator) !World {
    var w = try obsidianFrameWorld(gpa, true);
    _ = try tryCreate(&w, 8, 64, 8);
    return w;
}

test "knocking the frame out breaks the portal blocks that leaned on it" {
    const gpa = std.testing.allocator;
    var w = try litPortalWorld(gpa);
    defer w.deinit();

    w.setBlock(8, 63, 8, .air);
    try onNeighborChange(&w, 8, 64, 8);

    try std.testing.expectEqual(.air, w.getBlock(8, 64, 8));
}

test "a portal block in a whole frame survives its neighbours changing" {
    const gpa = std.testing.allocator;
    var w = try litPortalWorld(gpa);
    defer w.deinit();

    var across: i32 = 0;
    while (across < frame_width) : (across += 1) {
        var up: i32 = 0;
        while (up < frame_height) : (up += 1) {
            try onNeighborChange(&w, 8 + across, 64 + up, 8);
            try std.testing.expectEqual(.portal, w.getBlock(8 + across, 64 + up, 8));
        }
    }
}

test "a portal too tall for its frame breaks" {
    const gpa = std.testing.allocator;
    var w = try litPortalWorld(gpa);
    defer w.deinit();

    w.setBlock(8, 67, 8, .portal);
    try onNeighborChange(&w, 8, 67, 8);

    try std.testing.expectEqual(.air, w.getBlock(8, 67, 8));
}

test "the teleporter lands on the nearest portal, centred in its mouth" {
    const gpa = std.testing.allocator;
    var w = try litPortalWorld(gpa);
    defer w.deinit();

    const found = findExisting(&w, 8.5, 64.0, 8.5).?;

    try std.testing.expectApproxEqAbs(@as(f64, 9.0), found.x, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 64.5), found.y, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 8.5), found.z, 1.0e-9);
}

test "the teleporter finds the foot of a portal, not its middle" {
    const gpa = std.testing.allocator;
    var w = try litPortalWorld(gpa);
    defer w.deinit();

    const from_above = findExisting(&w, 8.5, 80.0, 8.5).?;
    try std.testing.expectApproxEqAbs(@as(f64, 64.5), from_above.y, 1.0e-9);
}

test "a world with no portal in it hands the teleporter nothing" {
    const gpa = std.testing.allocator;
    var w = try obsidianFrameWorld(gpa, true);
    defer w.deinit();

    try std.testing.expect(findExisting(&w, 8.5, 64.0, 8.5) == null);
}

test "the teleporter carves a fresh portal where none exists, and lands in it" {
    const gpa = std.testing.allocator;
    var w = World.init(gpa);
    defer w.deinit();

    var chunk_x: i32 = -2;
    while (chunk_x <= 2) : (chunk_x += 1) {
        var chunk_z: i32 = -2;
        while (chunk_z <= 2) : (chunk_z += 1) {
            const chunk = try w.createChunk(chunk_x, chunk_z);
            for (0..16) |x| {
                for (0..16) |z| {
                    for (0..64) |y| chunk.setBlock(@intCast(x), @intCast(y), @intCast(z), .stone);
                }
            }
        }
    }

    var rand = JavaRandom.init(7);
    const landed = try placeInto(&w, &rand, 8.5, 64.0, 8.5);

    const at_x: i32 = @intFromFloat(@floor(landed.x));
    const at_y: i32 = @intFromFloat(@floor(landed.y));
    const at_z: i32 = @intFromFloat(@floor(landed.z));
    try std.testing.expectEqual(.portal, w.getBlock(at_x, at_y, at_z));
    try std.testing.expect(findExisting(&w, 8.5, 64.0, 8.5) != null);
}

test "a portal carved out of thin air still gets an obsidian frame under it" {
    const gpa = std.testing.allocator;
    var w = World.init(gpa);
    defer w.deinit();

    var chunk_x: i32 = -2;
    while (chunk_x <= 2) : (chunk_x += 1) {
        var chunk_z: i32 = -2;
        while (chunk_z <= 2) : (chunk_z += 1) {
            _ = try w.createChunk(chunk_x, chunk_z);
        }
    }

    var rand = JavaRandom.init(3);
    const landed = try placeInto(&w, &rand, 8.5, 90.0, 8.5);

    const at_x: i32 = @intFromFloat(@floor(landed.x));
    const at_y: i32 = @intFromFloat(@floor(landed.y));
    const at_z: i32 = @intFromFloat(@floor(landed.z));

    try std.testing.expectEqual(.portal, w.getBlock(at_x, at_y, at_z));
    try std.testing.expect(at_y >= 70 and at_y <= 118);
    try std.testing.expectEqual(.obsidian, w.getBlock(at_x, at_y - 1, at_z));
}

test "a portal lights the frame it stands in" {
    const gpa = std.testing.allocator;
    var w = try litPortalWorld(gpa);
    defer w.deinit();

    const light = @import("light.zig");
    try light.relightChunk(gpa, &w, 0, 0);

    try std.testing.expectEqual(@as(u4, 11), w.getBlockLight(8, 64, 8));
    try std.testing.expectEqual(@as(u4, 10), w.getBlockLight(8, 64, 9));
}

test "arriving in the nether carves a portal into real nether terrain" {
    const gpa = std.testing.allocator;
    const NetherGenerator = @import("nether_gen.zig");

    var gen = try NetherGenerator.init(gpa, 12345);
    defer gen.deinit(gpa);

    var w = World.init(gpa);
    defer w.deinit();

    const from_x: f64 = 8.5 / 8.0;
    const from_z: f64 = 8.5 / 8.0;
    var chunk_x: i32 = -2;
    while (chunk_x <= 2) : (chunk_x += 1) {
        var chunk_z: i32 = -2;
        while (chunk_z <= 2) : (chunk_z += 1) {
            _ = try w.getOrGenerateChunk(&gen, chunk_x, chunk_z);
        }
    }

    var rand = JavaRandom.init(9);
    const landed = try placeInto(&w, &rand, from_x, 70.0, from_z);

    const at_x: i32 = @intFromFloat(@floor(landed.x));
    const at_y: i32 = @intFromFloat(@floor(landed.y));
    const at_z: i32 = @intFromFloat(@floor(landed.z));

    try std.testing.expectEqual(.portal, w.getBlock(at_x, at_y, at_z));
    try std.testing.expectEqual(.obsidian, w.getBlock(at_x, at_y - 1, at_z));

    const found_again = findExisting(&w, from_x, 70.0, from_z).?;
    try std.testing.expectApproxEqAbs(landed.x, found_again.x, 1.0e-9);
    try std.testing.expectApproxEqAbs(landed.z, found_again.z, 1.0e-9);
}
