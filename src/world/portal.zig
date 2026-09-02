const std = @import("std");

const math = @import("math");

const block = @import("block.zig");
const Block = block.Block;
const JavaRandom = @import("JavaRandom.zig");
const World = @import("World.zig");
const BlockPos = World.BlockPos;

pub const frame_width = 2;
pub const frame_height = 3;

fn blockAt(world_map: anytype, pos: BlockPos) Block {
    return world_map.getBlock(pos);
}

fn setBlockAt(world_map: *World, pos: BlockPos, id: Block) !void {
    try world_map.setBlockWithNotify(pos, id);
}

pub fn spansX(world_map: anytype, pos: BlockPos) bool {
    return blockAt(world_map, pos.offset(-1, 0, 0)) == .portal or blockAt(world_map, pos.offset(1, 0, 0)) == .portal;
}

pub fn bounds(world_map: anytype, pos: BlockPos) block.Bounds {
    return block.portalBounds(spansX(world_map, pos));
}

pub fn facesNeighbour(world_map: anytype, pos: BlockPos, side: block.Side) bool {
    if (blockAt(world_map, pos) == .portal) return false;

    const along_x = (blockAt(world_map, pos.offset(-1, 0, 0)) == .portal and blockAt(world_map, pos.offset(-2, 0, 0)) != .portal) or
        (blockAt(world_map, pos.offset(1, 0, 0)) == .portal and blockAt(world_map, pos.offset(2, 0, 0)) != .portal);
    const along_z = (blockAt(world_map, pos.offset(0, 0, -1)) == .portal and blockAt(world_map, pos.offset(0, 0, -2)) != .portal) or
        (blockAt(world_map, pos.offset(0, 0, 1)) == .portal and blockAt(world_map, pos.offset(0, 0, 2)) != .portal);

    return switch (side) {
        .west, .east => along_x,
        .north, .south => along_z,
        .down, .up => false,
    };
}

pub fn tryCreate(world_map: *World, origin: BlockPos) !bool {
    var pos = origin;

    var step_x: i32 = 0;
    var step_z: i32 = 0;
    if (blockAt(world_map, pos.offset(-1, 0, 0)) == .obsidian or blockAt(world_map, pos.offset(1, 0, 0)) == .obsidian) step_x = 1;
    if (blockAt(world_map, pos.offset(0, 0, -1)) == .obsidian or blockAt(world_map, pos.offset(0, 0, 1)) == .obsidian) step_z = 1;
    if (step_x == step_z) return false;

    if (blockAt(world_map, pos.offset(-step_x, 0, -step_z)) == .air) pos = pos.offset(-step_x, 0, -step_z);

    var across: i32 = -1;
    while (across <= frame_width) : (across += 1) {
        var up: i32 = -1;
        while (up <= frame_height) : (up += 1) {
            const on_frame = across == -1 or across == frame_width or up == -1 or up == frame_height;
            if ((across == -1 or across == frame_width) and (up == -1 or up == frame_height)) continue;

            const found = blockAt(world_map, pos.offset(step_x * across, up, step_z * across));
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
            try setBlockAt(world_map, pos.offset(step_x * across, up, step_z * across), .portal);
        }
    }
    return true;
}

pub fn onNeighborChange(world_map: *World, pos: BlockPos) !void {
    var side_x: i32 = 0;
    var side_z: i32 = 1;
    if (blockAt(world_map, pos.offset(-1, 0, 0)) == .portal or blockAt(world_map, pos.offset(1, 0, 0)) == .portal) {
        side_x = 1;
        side_z = 0;
    }

    var foot = pos;
    while (blockAt(world_map, foot.offset(0, -1, 0)) == .portal) foot = foot.offset(0, -1, 0);

    if (blockAt(world_map, foot.offset(0, -1, 0)) != .obsidian) {
        try setBlockAt(world_map, pos, .air);
        return;
    }

    var height: i32 = 1;
    while (height < 4 and blockAt(world_map, foot.offset(0, height, 0)) == .portal) height += 1;

    if (height != frame_height or blockAt(world_map, foot.offset(0, height, 0)) != .obsidian) {
        try setBlockAt(world_map, pos, .air);
        return;
    }

    const along_x = blockAt(world_map, pos.offset(-1, 0, 0)) == .portal or blockAt(world_map, pos.offset(1, 0, 0)) == .portal;
    const along_z = blockAt(world_map, pos.offset(0, 0, -1)) == .portal or blockAt(world_map, pos.offset(0, 0, 1)) == .portal;
    if (along_x and along_z) {
        try setBlockAt(world_map, pos, .air);
        return;
    }

    const forward_framed = blockAt(world_map, pos.offset(side_x, 0, side_z)) == .obsidian and
        blockAt(world_map, pos.offset(-side_x, 0, -side_z)) == .portal;
    const backward_framed = blockAt(world_map, pos.offset(-side_x, 0, -side_z)) == .obsidian and
        blockAt(world_map, pos.offset(side_x, 0, side_z)) == .portal;
    if (!forward_framed and !backward_framed) try setBlockAt(world_map, pos, .air);
}

const search_radius: i32 = 128;
const build_radius: i32 = 16;

pub fn findExisting(world_map: *const World, from: math.Vec3) ?math.Vec3 {
    var best_distance: f64 = -1.0;
    var best: BlockPos = .{ .x = 0, .y = 0, .z = 0 };

    const center_x = @as(i32, @intFromFloat(@floor(from.x)));
    const center_z = @as(i32, @intFromFloat(@floor(from.z)));

    var x = center_x - search_radius;
    while (x <= center_x + search_radius) : (x += 1) {
        const dx = @as(f64, @floatFromInt(x)) + 0.5 - from.x;
        var z = center_z - search_radius;
        while (z <= center_z + search_radius) : (z += 1) {
            const dz = @as(f64, @floatFromInt(z)) + 0.5 - from.z;
            var y: i32 = 127;
            while (y >= 0) : (y -= 1) {
                if (world_map.getBlock(.init(x, y, z)) != .portal) continue;
                while (world_map.getBlock(.init(x, y - 1, z)) == .portal) y -= 1;

                const dy = @as(f64, @floatFromInt(y)) + 0.5 - from.y;
                const distance = dx * dx + dy * dy + dz * dz;
                if (best_distance < 0.0 or distance < best_distance) {
                    best_distance = distance;
                    best = .{ .x = x, .y = y, .z = z };
                }
            }
        }
    }

    if (best_distance < 0.0) return null;

    var out = math.Vec3.init(
        @as(f64, @floatFromInt(best.x)) + 0.5,
        @as(f64, @floatFromInt(best.y)) + 0.5,
        @as(f64, @floatFromInt(best.z)) + 0.5,
    );

    if (blockAt(world_map, best.offset(-1, 0, 0)) == .portal) out.x -= 0.5;
    if (blockAt(world_map, best.offset(1, 0, 0)) == .portal) out.x += 0.5;
    if (blockAt(world_map, best.offset(0, 0, -1)) == .portal) out.z -= 0.5;
    if (blockAt(world_map, best.offset(0, 0, 1)) == .portal) out.z += 0.5;

    return out;
}

const Placement = struct {
    pos: BlockPos,
    orientation: i32,
    distance: f64,
};

fn clearanceAt(world_map: *const World, pos: BlockPos, step_x: i32, step_z: i32, depth: i32) bool {
    var across: i32 = 0;
    while (across < 4) : (across += 1) {
        var up: i32 = -1;
        while (up < 4) : (up += 1) {
            const cell = pos.offset((across - 1) * step_x + depth * step_z, up, (across - 1) * step_z - depth * step_x);
            if (up < 0) {
                if (!blockAt(world_map, cell).material().isSolid()) return false;
            } else if (blockAt(world_map, cell) != .air) {
                return false;
            }
        }
    }
    return true;
}

fn searchPlacement(world_map: *const World, from: math.Vec3, first_orientation: i32, orientations: i32, depths: i32) ?Placement {
    var best: ?Placement = null;

    const center_x = @as(i32, @intFromFloat(@floor(from.x)));
    const center_z = @as(i32, @intFromFloat(@floor(from.z)));

    var x = center_x - build_radius;
    while (x <= center_x + build_radius) : (x += 1) {
        const dx = @as(f64, @floatFromInt(x)) + 0.5 - from.x;
        var z = center_z - build_radius;
        while (z <= center_z + build_radius) : (z += 1) {
            const dz = @as(f64, @floatFromInt(z)) + 0.5 - from.z;
            var y: i32 = 127;
            column: while (y >= 0) : (y -= 1) {
                if (world_map.getBlock(.init(x, y, z)) != .air) continue;
                while (y > 0 and world_map.getBlock(.init(x, y - 1, z)) == .air) y -= 1;

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
                        if (!clearanceAt(world_map, .{ .x = x, .y = y, .z = z }, step_x, step_z, depth)) continue :column;
                    }

                    const dy = @as(f64, @floatFromInt(y)) + 0.5 - from.y;
                    const distance = dx * dx + dy * dy + dz * dz;
                    if (best == null or distance < best.?.distance) {
                        best = .{
                            .pos = .{ .x = x, .y = y, .z = z },
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

pub fn create(world_map: *World, rand: *JavaRandom, from: math.Vec3) !void {
    const first_orientation = rand.nextIntBound(4);

    var placement = searchPlacement(world_map, from, first_orientation, 4, 3);
    if (placement == null) placement = searchPlacement(world_map, from, first_orientation, 2, 1);

    var origin: BlockPos = .{
        .x = @as(i32, @intFromFloat(@floor(from.x))),
        .y = @as(i32, @intFromFloat(@floor(from.y))),
        .z = @as(i32, @intFromFloat(@floor(from.z))),
    };
    var orientation: i32 = 0;
    const clear = placement != null;

    if (placement) |found| {
        origin = found.pos;
        orientation = found.orientation;
    }

    var step_x = @mod(orientation, 2);
    var step_z = 1 - step_x;
    if (@mod(orientation, 4) >= 2) {
        step_x = -step_x;
        step_z = -step_z;
    }

    if (!clear) {
        origin.y = std.math.clamp(origin.y, 70, 118);

        var side: i32 = -1;
        while (side <= 1) : (side += 1) {
            var across: i32 = 1;
            while (across < 3) : (across += 1) {
                var up: i32 = -1;
                while (up < 3) : (up += 1) {
                    const cell = origin.offset((across - 1) * step_x + side * step_z, up, (across - 1) * step_z - side * step_x);
                    try setBlockAt(world_map, cell, if (up < 0) .obsidian else .air);
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
                const cell = origin.offset((across - 1) * step_x, up, (across - 1) * step_z);
                const frame = across == 0 or across == 3 or up == -1 or up == frame_height;
                try setBlockAt(world_map, cell, if (frame) .obsidian else .portal);
            }
        }
        world_map.editing_blocks = false;

        across = 0;
        while (across < 4) : (across += 1) {
            var up: i32 = -1;
            while (up < 4) : (up += 1) {
                const cell = origin.offset((across - 1) * step_x, up, (across - 1) * step_z);
                try world_map.notifyBlocksOfNeighborChange(cell, blockAt(world_map, cell));
            }
        }
    }
}

pub fn placeInto(world_map: *World, rand: *JavaRandom, from: math.Vec3) !math.Vec3 {
    if (findExisting(world_map, from)) |found| return found;

    try create(world_map, rand, from);
    return findExisting(world_map, from) orelse from;
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
            w.setBlock(.init(8 + step_x * across, 64 + up, 8 + step_z * across), .obsidian);
        }
    }
    return w;
}

test "lighting a fire inside a finished obsidian frame fills it with portal blocks" {
    const gpa = std.testing.allocator;

    for ([_]bool{ true, false }) |along_x| {
        var w = try obsidianFrameWorld(gpa, along_x);
        defer w.deinit();

        try std.testing.expect(try tryCreate(&w, .{ .x = 8, .y = 64, .z = 8 }));

        const step_x: i32 = if (along_x) 1 else 0;
        const step_z: i32 = if (along_x) 0 else 1;
        var across: i32 = 0;
        while (across < frame_width) : (across += 1) {
            var up: i32 = 0;
            while (up < frame_height) : (up += 1) {
                try std.testing.expectEqual(
                    .portal,
                    w.getBlock(.init(8 + step_x * across, 64 + up, 8 + step_z * across)),
                );
            }
        }
    }
}

test "a frame with a hole in it does not light" {
    const gpa = std.testing.allocator;
    var w = try obsidianFrameWorld(gpa, true);
    defer w.deinit();

    w.setBlock(.init(8, 67, 8), .air);

    try std.testing.expect(!try tryCreate(&w, .{ .x = 8, .y = 64, .z = 8 }));
    try std.testing.expectEqual(.air, w.getBlock(.init(8, 64, 8)));
}

test "a frame blocked by something other than fire does not light" {
    const gpa = std.testing.allocator;
    var w = try obsidianFrameWorld(gpa, true);
    defer w.deinit();

    w.setBlock(.init(9, 65, 8), .stone);

    try std.testing.expect(!try tryCreate(&w, .{ .x = 8, .y = 64, .z = 8 }));
}

test "fire already burning in the frame does not stop it lighting" {
    const gpa = std.testing.allocator;
    var w = try obsidianFrameWorld(gpa, true);
    defer w.deinit();

    w.setBlock(.init(8, 64, 8), .fire);

    try std.testing.expect(try tryCreate(&w, .{ .x = 8, .y = 64, .z = 8 }));
    try std.testing.expectEqual(.portal, w.getBlock(.init(8, 64, 8)));
}

test "obsidian on neither axis, or both, leaves the frame unlit" {
    const gpa = std.testing.allocator;
    var w = World.init(gpa);
    defer w.deinit();
    _ = try w.createChunk(0, 0);

    try std.testing.expect(!try tryCreate(&w, .{ .x = 8, .y = 64, .z = 8 }));

    w.setBlock(.init(7, 64, 8), .obsidian);
    w.setBlock(.init(8, 64, 7), .obsidian);
    try std.testing.expect(!try tryCreate(&w, .{ .x = 8, .y = 64, .z = 8 }));
}

fn litPortalWorld(gpa: std.mem.Allocator) !World {
    var w = try obsidianFrameWorld(gpa, true);
    _ = try tryCreate(&w, .{ .x = 8, .y = 64, .z = 8 });
    return w;
}

test "knocking the frame out breaks the portal blocks that leaned on it" {
    const gpa = std.testing.allocator;
    var w = try litPortalWorld(gpa);
    defer w.deinit();

    w.setBlock(.init(8, 63, 8), .air);
    try onNeighborChange(&w, .{ .x = 8, .y = 64, .z = 8 });

    try std.testing.expectEqual(.air, w.getBlock(.init(8, 64, 8)));
}

test "a portal block in a whole frame survives its neighbours changing" {
    const gpa = std.testing.allocator;
    var w = try litPortalWorld(gpa);
    defer w.deinit();

    var across: i32 = 0;
    while (across < frame_width) : (across += 1) {
        var up: i32 = 0;
        while (up < frame_height) : (up += 1) {
            try onNeighborChange(&w, .{ .x = 8 + across, .y = 64 + up, .z = 8 });
            try std.testing.expectEqual(.portal, w.getBlock(.init(8 + across, 64 + up, 8)));
        }
    }
}

test "a portal too tall for its frame breaks" {
    const gpa = std.testing.allocator;
    var w = try litPortalWorld(gpa);
    defer w.deinit();

    w.setBlock(.init(8, 67, 8), .portal);
    try onNeighborChange(&w, .{ .x = 8, .y = 67, .z = 8 });

    try std.testing.expectEqual(.air, w.getBlock(.init(8, 67, 8)));
}

test "the teleporter lands on the nearest portal, centred in its mouth" {
    const gpa = std.testing.allocator;
    var w = try litPortalWorld(gpa);
    defer w.deinit();

    const found = findExisting(&w, math.Vec3.init(8.5, 64.0, 8.5)).?;

    try std.testing.expectApproxEqAbs(@as(f64, 9.0), found.x, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 64.5), found.y, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 8.5), found.z, 1.0e-9);
}

test "the teleporter finds the foot of a portal, not its middle" {
    const gpa = std.testing.allocator;
    var w = try litPortalWorld(gpa);
    defer w.deinit();

    const from_above = findExisting(&w, math.Vec3.init(8.5, 80.0, 8.5)).?;
    try std.testing.expectApproxEqAbs(@as(f64, 64.5), from_above.y, 1.0e-9);
}

test "a world with no portal in it hands the teleporter nothing" {
    const gpa = std.testing.allocator;
    var w = try obsidianFrameWorld(gpa, true);
    defer w.deinit();

    try std.testing.expect(findExisting(&w, math.Vec3.init(8.5, 64.0, 8.5)) == null);
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
    const landed = try placeInto(&w, &rand, math.Vec3.init(8.5, 64.0, 8.5));

    const at_x: i32 = @intFromFloat(@floor(landed.x));
    const at_y: i32 = @intFromFloat(@floor(landed.y));
    const at_z: i32 = @intFromFloat(@floor(landed.z));
    try std.testing.expectEqual(.portal, w.getBlock(.init(at_x, at_y, at_z)));
    try std.testing.expect(findExisting(&w, math.Vec3.init(8.5, 64.0, 8.5)) != null);
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
    const landed = try placeInto(&w, &rand, math.Vec3.init(8.5, 90.0, 8.5));

    const at_x: i32 = @intFromFloat(@floor(landed.x));
    const at_y: i32 = @intFromFloat(@floor(landed.y));
    const at_z: i32 = @intFromFloat(@floor(landed.z));

    try std.testing.expectEqual(.portal, w.getBlock(.init(at_x, at_y, at_z)));
    try std.testing.expect(at_y >= 70 and at_y <= 118);
    try std.testing.expectEqual(.obsidian, w.getBlock(.init(at_x, at_y - 1, at_z)));
}

test "a portal lights the frame it stands in" {
    const gpa = std.testing.allocator;
    var w = try litPortalWorld(gpa);
    defer w.deinit();

    const light = @import("light.zig");
    try light.relightChunk(gpa, &w, 0, 0);

    try std.testing.expectEqual(@as(u4, 11), w.getBlockLight(.init(8, 64, 8)));
    try std.testing.expectEqual(@as(u4, 10), w.getBlockLight(.init(8, 64, 9)));
}

test "arriving in the nether carves a portal into real nether terrain" {
    const gpa = std.testing.allocator;
    const NetherGenerator = @import("gen/NetherGenerator.zig");

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
    const landed = try placeInto(&w, &rand, math.Vec3.init(from_x, 70.0, from_z));

    const at_x: i32 = @intFromFloat(@floor(landed.x));
    const at_y: i32 = @intFromFloat(@floor(landed.y));
    const at_z: i32 = @intFromFloat(@floor(landed.z));

    try std.testing.expectEqual(.portal, w.getBlock(.init(at_x, at_y, at_z)));
    try std.testing.expectEqual(.obsidian, w.getBlock(.init(at_x, at_y - 1, at_z)));

    const found_again = findExisting(&w, math.Vec3.init(from_x, 70.0, from_z)).?;
    try std.testing.expectApproxEqAbs(landed.x, found_again.x, 1.0e-9);
    try std.testing.expectApproxEqAbs(landed.z, found_again.z, 1.0e-9);
}

test "a portal shows no face towards another portal block" {
    const gpa = std.testing.allocator;
    var w = try litPortalWorld(gpa);
    defer w.deinit();

    try std.testing.expect(!facesNeighbour(&w, .{ .x = 9, .y = 64, .z = 8 }, .east));
    try std.testing.expect(!facesNeighbour(&w, .{ .x = 8, .y = 65, .z = 8 }, .up));
}

test "a portal never caps itself top or bottom" {
    const gpa = std.testing.allocator;
    var w = try litPortalWorld(gpa);
    defer w.deinit();

    try std.testing.expect(!facesNeighbour(&w, .{ .x = 8, .y = 63, .z = 8 }, .down));
    try std.testing.expect(!facesNeighbour(&w, .{ .x = 8, .y = 67, .z = 8 }, .up));
}

test "a portal shows only the two broad faces it presents" {
    const gpa = std.testing.allocator;
    var w = try litPortalWorld(gpa);
    defer w.deinit();

    try std.testing.expect(facesNeighbour(&w, .{ .x = 8, .y = 64, .z = 7 }, .north));
    try std.testing.expect(facesNeighbour(&w, .{ .x = 8, .y = 64, .z = 9 }, .south));

    try std.testing.expect(!facesNeighbour(&w, .{ .x = 7, .y = 64, .z = 8 }, .west));
    try std.testing.expect(!facesNeighbour(&w, .{ .x = 10, .y = 64, .z = 8 }, .east));
}

test "the sheet a portal presents turns with the frame it was lit in" {
    const gpa = std.testing.allocator;
    var w = try obsidianFrameWorld(gpa, false);
    defer w.deinit();
    _ = try tryCreate(&w, .{ .x = 8, .y = 64, .z = 8 });

    try std.testing.expect(facesNeighbour(&w, .{ .x = 7, .y = 64, .z = 8 }, .west));
    try std.testing.expect(facesNeighbour(&w, .{ .x = 9, .y = 64, .z = 8 }, .east));
    try std.testing.expect(!facesNeighbour(&w, .{ .x = 8, .y = 64, .z = 7 }, .north));
}
