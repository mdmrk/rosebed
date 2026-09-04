const std = @import("std");

const block = @import("../block.zig");
const Block = @import("../block.zig").Block;
const BlockPos = @import("../BlockPos.zig");
const chest = @import("../chest.zig");
const entity_nbt = @import("../entity_nbt.zig");
const JavaRandom = @import("../JavaRandom.zig");
const World = @import("../World.zig");

const room_height: i32 = 3;

pub fn generate(world_map: *World, rand: *JavaRandom, pos: BlockPos) !bool {
    const radius_x = rand.nextIntBound(2) + 2;
    const radius_z = rand.nextIntBound(2) + 2;

    var openings: i32 = 0;
    var dx = -radius_x - 1;
    while (dx <= radius_x + 1) : (dx += 1) {
        var dz = -radius_z - 1;
        while (dz <= radius_z + 1) : (dz += 1) {
            const bottom = world_map.getBlock(pos.offset(dx, -1, dz));
            if (!bottom.isSolid()) return false;
            const top = world_map.getBlock(.init(pos.x + dx, pos.y + room_height + 1, pos.z + dz));
            if (!top.isSolid()) return false;

            const on_perimeter = dx == -radius_x - 1 or dx == radius_x + 1 or dz == -radius_z - 1 or dz == radius_z + 1;
            if (on_perimeter) {
                const floor_level = world_map.getBlock(pos.offset(dx, 0, dz));
                const above_floor = world_map.getBlock(pos.offset(dx, 1, dz));
                if (floor_level == .air and above_floor == .air) openings += 1;
            }
        }
    }
    if (openings < 1 or openings > 5) return false;

    var dy = room_height;
    while (dy >= -1) : (dy -= 1) {
        var dx2 = -radius_x - 1;
        while (dx2 <= radius_x + 1) : (dx2 += 1) {
            var dz2 = -radius_z - 1;
            while (dz2 <= radius_z + 1) : (dz2 += 1) {
                const on_perimeter = dx2 == -radius_x - 1 or dx2 == radius_x + 1 or dz2 == -radius_z - 1 or dz2 == radius_z + 1;
                if (!on_perimeter and dy != -1) {
                    world_map.setBlock(pos.offset(dx2, dy, dz2), .air);
                    continue;
                }

                if (pos.y + dy >= 0 and !world_map.getBlock(.init(pos.x + dx2, pos.y + dy - 1, pos.z + dz2)).isSolid()) {
                    world_map.setBlock(pos.offset(dx2, dy, dz2), .air);
                } else if (world_map.getBlock(pos.offset(dx2, dy, dz2)).isSolid()) {
                    const wall_id: Block = if (dy == -1 and rand.nextIntBound(4) != 0) .cobblestone_mossy else .cobblestone;
                    world_map.setBlock(pos.offset(dx2, dy, dz2), wall_id);
                }
            }
        }
    }

    for (0..2) |_| {
        tries: for (0..3) |_| {
            const cx = pos.x + rand.nextIntBound(radius_x * 2 + 1) - radius_x;
            const cz = pos.z + rand.nextIntBound(radius_z * 2 + 1) - radius_z;
            if (world_map.getBlock(.init(cx, pos.y, cz)) != .air) continue;

            var solid_sides: i32 = 0;
            if (world_map.getBlock(.init(cx - 1, pos.y, cz)).isSolid()) solid_sides += 1;
            if (world_map.getBlock(.init(cx + 1, pos.y, cz)).isSolid()) solid_sides += 1;
            if (world_map.getBlock(.init(cx, pos.y, cz - 1)).isSolid()) solid_sides += 1;
            if (world_map.getBlock(.init(cx, pos.y, cz + 1)).isSolid()) solid_sides += 1;
            if (solid_sides != 1) continue;

            world_map.setBlock(.init(cx, pos.y, cz), .chest);
            const state = try world_map.addChest(.init(cx, pos.y, cz));
            for (0..8) |_| {
                const stack = rollLootItem(rand) orelse continue;
                state.slot(@intCast(rand.nextIntBound(chest.slot_count))).* = stack;
            }
            break :tries;
        }
    }

    world_map.setBlock(pos, .mob_spawner);
    (try world_map.addMobSpawner(pos)).setMobName(rollSpawnerMob(rand));
    return true;
}

fn rollSpawnerMob(rand: *JavaRandom) []const u8 {
    return switch (rand.nextIntBound(4)) {
        0 => entity_nbt.skeleton_id,
        1, 2 => entity_nbt.zombie_id,
        else => entity_nbt.spider_id,
    };
}

fn some(rand: *JavaRandom, id: block.Id) block.Stack {
    return .{ .id = id, .count = @intCast(rand.nextIntBound(4) + 1) };
}

fn one(id: block.Id) block.Stack {
    return .{ .id = id, .count = 1 };
}

fn rollLootItem(rand: *JavaRandom) ?block.Stack {
    return switch (rand.nextIntBound(11)) {
        0 => one(.{ .item = .saddle }),
        1 => some(rand, .{ .item = .ingot_iron }),
        2 => one(.{ .item = .bread }),
        3 => some(rand, .{ .item = .wheat }),
        4 => some(rand, .{ .item = .gunpowder }),
        5 => some(rand, .{ .item = .string }),
        6 => one(.{ .item = .bucket }),
        7 => if (rand.nextIntBound(100) == 0) one(.{ .item = .apple_gold }) else null,
        8 => if (rand.nextIntBound(2) == 0) some(rand, .{ .item = .redstone }) else null,
        9 => if (rand.nextIntBound(10) == 0)
            one(.{ .item = if (rand.nextIntBound(2) == 0) .record_13 else .record_cat })
        else
            null,
        10 => .{ .id = .{ .item = .dye }, .count = 1, .meta = cocoa_beans_meta },
        else => unreachable,
    };
}

const cocoa_beans_meta: u16 = 3;

fn burnLootRolls(rand: *JavaRandom) void {
    switch (rand.nextIntBound(11)) {
        0, 2, 6, 10 => {},
        1, 3, 4, 5 => _ = rand.nextIntBound(4),
        7 => _ = rand.nextIntBound(100),
        8 => if (rand.nextIntBound(2) == 0) {
            _ = rand.nextIntBound(4);
        },
        9 => if (rand.nextIntBound(10) == 0) {
            _ = rand.nextIntBound(2);
        },
        else => unreachable,
    }
}

test "handing out real stacks draws exactly the stream the RNG-only roll drew" {
    // Dungeon loot sits in the middle of decoration, so any change to how many values
    // pickCheckLootItem takes shifts every later feature in the chunk. burnLootRolls is
    // the draw pattern this file had while it only counted; the two must stay in step.
    var giving = JavaRandom.init(12345);
    var burning = JavaRandom.init(12345);

    for (0..5000) |_| {
        _ = rollLootItem(&giving);
        burnLootRolls(&burning);
    }

    try std.testing.expectEqual(burning.seed, giving.seed);
}

test "every branch of the loot table can come out of it" {
    var seen_saddle = false;
    var seen_apple = false;
    var seen_record = false;
    var seen_cocoa = false;
    var seen_stack = false;

    var rand = JavaRandom.init(99);
    for (0..20000) |_| {
        const stack = rollLootItem(&rand) orelse continue;
        switch (stack.id.item) {
            .saddle => seen_saddle = true,
            .apple_gold => seen_apple = true,
            .record_13, .record_cat => seen_record = true,
            .dye => {
                try std.testing.expectEqual(cocoa_beans_meta, stack.meta);
                seen_cocoa = true;
            },
            .ingot_iron, .wheat, .gunpowder, .string, .redstone => {
                try std.testing.expect(stack.count >= 1 and stack.count <= 4);
                seen_stack = true;
            },
            .bread, .bucket => try std.testing.expectEqual(@as(u8, 1), stack.count),
            else => return error.TestUnexpectedResult,
        }
    }

    try std.testing.expect(seen_saddle and seen_apple and seen_record and seen_cocoa and seen_stack);
}

fn testWorldWithChunk() !World {
    var w = World.init(std.testing.allocator);
    const chunk = try w.createChunk(0, 0);
    for (0..16) |x| {
        for (0..128) |y| {
            for (0..16) |z| {
                chunk.setBlock(@intCast(x), @intCast(y), @intCast(z), .stone);
            }
        }
    }
    return w;
}

test "a dungeon carves a room and places a spawner in solid stone" {
    var w = try testWorldWithChunk();
    defer w.deinit();

    w.setBlock(.init(11, 40, 8), .air);
    w.setBlock(.init(11, 41, 8), .air);
    w.setBlock(.init(12, 40, 8), .air);
    w.setBlock(.init(12, 41, 8), .air);

    var rand = JavaRandom.init(1);
    const made = try generate(&w, &rand, .init(8, 40, 8));
    try std.testing.expect(made);
    try std.testing.expectEqual(.mob_spawner, w.getBlock(.init(8, 40, 8)));
    try std.testing.expectEqual(.air, w.getBlock(.init(8, 41, 8)));

    var found_wall = false;
    for (0..16) |x| {
        for (0..16) |z| {
            const id = w.getBlock(.init(@intCast(x), 40, @intCast(z)));
            if (id == .cobblestone or id == .cobblestone_mossy) found_wall = true;
        }
    }
    try std.testing.expect(found_wall);
}

test "a carved dungeon leaves a stocked chest behind, not a bare block" {
    var stocked = false;
    var slots_used: usize = 0;

    for (0..24) |seed| {
        var w = try testWorldWithChunk();
        defer w.deinit();
        w.setBlock(.init(12, 40, 8), .air);
        w.setBlock(.init(12, 41, 8), .air);

        var rand = JavaRandom.init(@intCast(seed));
        if (!try generate(&w, &rand, .init(8, 40, 8))) continue;

        for (0..16) |x| {
            for (0..16) |z| {
                const cx: i32 = @intCast(x);
                const cz: i32 = @intCast(z);
                if (w.getBlock(.init(cx, 40, cz)) != .chest) continue;

                const state = w.chestAt(.init(cx, 40, cz)) orelse return error.TestUnexpectedResult;
                for (state.items) |maybe| {
                    if (maybe != null) slots_used += 1;
                }
                if (!state.isEmpty()) stocked = true;
            }
        }
    }

    try std.testing.expect(stocked);
    try std.testing.expect(slots_used > 0);
}

test "a dungeon refuses to carve into open air" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    _ = try w.createChunk(0, 0);

    var rand = JavaRandom.init(1);
    const made = try generate(&w, &rand, .init(8, 40, 8));
    try std.testing.expect(!made);
}

test "a dungeon spills across a chunk boundary into the neighbor chunk" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    const a = try w.createChunk(0, 0);
    const b = try w.createChunk(1, 0);
    for (0..16) |x| {
        for (0..128) |y| {
            for (0..16) |z| {
                a.setBlock(@intCast(x), @intCast(y), @intCast(z), .stone);
                b.setBlock(@intCast(x), @intCast(y), @intCast(z), .stone);
            }
        }
    }

    w.setBlock(.init(19, 40, 8), .air);
    w.setBlock(.init(19, 41, 8), .air);
    w.setBlock(.init(20, 40, 8), .air);
    w.setBlock(.init(20, 41, 8), .air);

    var rand = JavaRandom.init(1);
    const made = try generate(&w, &rand, .init(15, 40, 8));
    try std.testing.expect(made);

    var found_wall_in_neighbor = false;
    for (0..16) |x| {
        for (0..16) |z| {
            const id = w.getBlock(.init(16 + @as(i32, @intCast(x)), 40, @as(i32, @intCast(z))));
            if (id == .cobblestone or id == .cobblestone_mossy or id == .air) found_wall_in_neighbor = true;
        }
    }
    try std.testing.expect(found_wall_in_neighbor);
}

test "a dungeon leaves the stone above its room untouched" {
    var w = try testWorldWithChunk();
    defer w.deinit();

    w.setBlock(.init(11, 40, 8), .air);
    w.setBlock(.init(11, 41, 8), .air);
    w.setBlock(.init(12, 40, 8), .air);
    w.setBlock(.init(12, 41, 8), .air);

    var rand = JavaRandom.init(1);
    try std.testing.expect(try generate(&w, &rand, .init(8, 40, 8)));

    try std.testing.expectEqual(.air, w.getBlock(.init(8, 43, 8)));
    for (0..16) |x| {
        for (0..16) |z| {
            const id = w.getBlock(.init(@intCast(x), 44, @intCast(z)));
            try std.testing.expect(id != .cobblestone and id != .cobblestone_mossy);
        }
    }
}
