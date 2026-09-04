const std = @import("std");

const block = @import("block.zig");
const Block = @import("block.zig").Block;
const BlockPos = @import("BlockPos.zig");
const Chunk = @import("Chunk.zig");
const World = @import("World.zig");

pub const max_level: u4 = 15;

pub const Kind = enum { sky, block };

pub fn opacity(id: Block) u8 {
    return switch (id) {
        .flowing_water, .stationary_water, .ice => 3,
        .leaves, .web => 1,
        .flowing_lava, .stationary_lava => 255,
        .stairs_wood, .stairs_cobblestone, .slab, .farmland => 255,
        else => if (id.isOpaqueCube()) 255 else 0,
    };
}

pub fn columnSkyLight(world_map: *const World, pos: BlockPos) i32 {
    var value: i32 = 15;
    var above: i32 = 127;
    while (above > pos.y) : (above -= 1) {
        value -= opacity(world_map.getBlock(.{ .x = pos.x, .y = above, .z = pos.z }));
        if (value <= 0) return 0;
    }
    return value;
}

pub fn emission(id: Block) u4 {
    return switch (id) {
        .flowing_lava, .stationary_lava, .glowstone, .fire, .locked_chest => 15,
        .torch => 14,
        .portal => 11,
        .burning_furnace => 13,
        .ore_redstone_glowing, .repeater_on => 9,
        .torch_redstone_on => 7,
        else => 0,
    };
}

pub fn brightnessTable(ambient: f32) [16]f32 {
    var table: [16]f32 = undefined;
    for (&table, 0..) |*entry, level| {
        const darkness = 1.0 - @as(f32, @floatFromInt(level)) / 15.0;
        entry.* = (1.0 - darkness) / (darkness * 3.0 + 1.0) * (1.0 - ambient) + ambient;
    }
    return table;
}

pub const brightness_table: [16]f32 = brightnessTable(0.05);

fn storedLevelAt(world_map: anytype, pos: BlockPos) u4 {
    const sky = world_map.getSkyLight(pos) -| world_map.skylight_subtracted;
    return @max(sky, world_map.getBlockLight(pos));
}

fn borrowsNeighborLight(id: Block) bool {
    return switch (id) {
        .slab, .stairs_wood, .stairs_cobblestone => true,
        else => false,
    };
}

pub fn levelAt(world_map: anytype, pos: BlockPos) u4 {
    if (!borrowsNeighborLight(world_map.getBlock(pos))) {
        return storedLevelAt(world_map, pos);
    }
    var level = storedLevelAt(world_map, pos.offset(0, 1, 0));
    level = @max(level, storedLevelAt(world_map, pos.offset(1, 0, 0)));
    level = @max(level, storedLevelAt(world_map, pos.offset(-1, 0, 0)));
    level = @max(level, storedLevelAt(world_map, pos.offset(0, 0, 1)));
    level = @max(level, storedLevelAt(world_map, pos.offset(0, 0, -1)));
    return level;
}

pub fn brightnessAt(world_map: anytype, pos: BlockPos, minimum: u4) f32 {
    return world_map.brightness[@max(levelAt(world_map, pos), minimum)];
}

fn spreadCost(id: Block) u8 {
    return @max(opacity(id), 1);
}

pub fn generateHeightMap(chunk: *Chunk) void {
    for (0..Chunk.width) |x| {
        for (0..Chunk.width) |z| {
            var y: u32 = Chunk.height - 1;
            while (y > 0 and opacity(chunk.getBlock(@intCast(x), y - 1, @intCast(z))) == 0) y -= 1;
            chunk.setHeightValue(@intCast(x), @intCast(z), @intCast(y));
        }
    }
}

pub fn generateSkylightMap(chunk: *Chunk) void {
    generateHeightMap(chunk);

    for (0..Chunk.width) |x| {
        for (0..Chunk.width) |z| {
            var level: i32 = max_level;
            var y: i32 = Chunk.height - 1;
            while (true) {
                level -= opacity(chunk.getBlock(@intCast(x), @intCast(y), @intCast(z)));
                if (level > 0) chunk.setSkyLight(@intCast(x), @intCast(y), @intCast(z), @intCast(level));
                y -= 1;
                if (y <= 0 or level <= 0) break;
            }
        }
    }
}

const Propagation = struct {
    world_map: *World,
    queue: std.ArrayList(BlockPos) = .empty,
    kind: Kind,
    min_x: i32,
    min_z: i32,

    fn get(self: *const Propagation, pos: BlockPos) u4 {
        return switch (self.kind) {
            .sky => self.world_map.getSkyLight(pos),
            .block => self.world_map.getBlockLight(pos),
        };
    }

    fn set(self: *Propagation, pos: BlockPos, value: u4) void {
        switch (self.kind) {
            .sky => self.world_map.setSkyLight(pos, value),
            .block => self.world_map.setBlockLight(pos, value),
        }
    }

    fn inside(self: *const Propagation, pos: BlockPos) bool {
        return pos.y >= 0 and pos.y < Chunk.height and
            pos.x >= self.min_x and pos.x < self.min_x + Chunk.width and
            pos.z >= self.min_z and pos.z < self.min_z + Chunk.width;
    }

    fn seed(self: *Propagation, gpa: std.mem.Allocator, pos: BlockPos) !void {
        try self.queue.append(gpa, pos);
    }

    fn run(self: *Propagation, gpa: std.mem.Allocator) !void {
        const offsets = [6][3]i32{
            .{ -1, 0, 0 }, .{ 1, 0, 0 },
            .{ 0, -1, 0 }, .{ 0, 1, 0 },
            .{ 0, 0, -1 }, .{ 0, 0, 1 },
        };

        var head: usize = 0;
        while (head < self.queue.items.len) : (head += 1) {
            const node = self.queue.items[head];
            const level = self.get(node);
            if (level <= 1) continue;

            for (offsets) |offset| {
                const next = node.offset(offset[0], offset[1], offset[2]);
                if (!self.inside(next)) continue;

                const cost = spreadCost(self.world_map.getBlock(next));
                if (level <= cost) continue;

                const spread: u4 = @intCast(level - cost);
                if (spread <= self.get(next)) continue;

                self.set(next, spread);
                try self.seed(gpa, next);
            }
        }
    }
};

fn skyCanSpread(chunk: *const Chunk, lx: usize, ly: usize, lz: usize, sky_floor: u8) bool {
    if (ly == sky_floor) return true;
    const last = Chunk.width - 1;
    if (lx > 0 and chunk.getHeightValue(@intCast(lx - 1), @intCast(lz)) > ly) return true;
    if (lx < last and chunk.getHeightValue(@intCast(lx + 1), @intCast(lz)) > ly) return true;
    if (lz > 0 and chunk.getHeightValue(@intCast(lx), @intCast(lz - 1)) > ly) return true;
    if (lz < last and chunk.getHeightValue(@intCast(lx), @intCast(lz + 1)) > ly) return true;
    return false;
}

pub fn relightChunk(gpa: std.mem.Allocator, world_map: *World, chunk_x: i32, chunk_z: i32) !void {
    const chunk = world_map.getChunk(chunk_x, chunk_z) orelse return;
    generateHeightMap(chunk);

    chunk.sky_light = .{};
    chunk.block_light = .{};

    const min_x = chunk_x * Chunk.width;
    const min_z = chunk_z * Chunk.width;

    var sky: Propagation = .{ .world_map = world_map, .kind = .sky, .min_x = min_x, .min_z = min_z };
    defer sky.queue.deinit(gpa);
    var lamps: Propagation = .{ .world_map = world_map, .kind = .block, .min_x = min_x, .min_z = min_z };
    defer lamps.queue.deinit(gpa);

    for (0..Chunk.width) |lx| {
        for (0..Chunk.width) |lz| {
            const sky_floor = chunk.getHeightValue(@intCast(lx), @intCast(lz));
            const x = min_x + @as(i32, @intCast(lx));
            const z = min_z + @as(i32, @intCast(lz));

            for (0..Chunk.height) |ly| {
                const y: i32 = @intCast(ly);
                if (ly >= sky_floor) {
                    chunk.setSkyLight(@intCast(lx), @intCast(ly), @intCast(lz), max_level);
                    if (skyCanSpread(chunk, lx, ly, lz, sky_floor)) try sky.seed(gpa, .init(x, y, z));
                }
                const emitted = emission(chunk.getBlock(@intCast(lx), @intCast(ly), @intCast(lz)));
                if (emitted > 0) {
                    chunk.setBlockLight(@intCast(lx), @intCast(ly), @intCast(lz), emitted);
                    try lamps.seed(gpa, .init(x, y, z));
                }
            }
        }
    }

    try seedBorder(gpa, &sky, chunk_x, chunk_z);
    try seedBorder(gpa, &lamps, chunk_x, chunk_z);

    try sky.run(gpa);
    try lamps.run(gpa);
}

const Side = struct { chunk_x: i32, chunk_z: i32, local_x: ?u32, local_z: ?u32 };

fn seedBorder(gpa: std.mem.Allocator, propagation: *Propagation, chunk_x: i32, chunk_z: i32) !void {
    const last = Chunk.width - 1;
    const sides = [4]Side{
        .{ .chunk_x = chunk_x - 1, .chunk_z = chunk_z, .local_x = last, .local_z = null },
        .{ .chunk_x = chunk_x + 1, .chunk_z = chunk_z, .local_x = 0, .local_z = null },
        .{ .chunk_x = chunk_x, .chunk_z = chunk_z - 1, .local_x = null, .local_z = last },
        .{ .chunk_x = chunk_x, .chunk_z = chunk_z + 1, .local_x = null, .local_z = 0 },
    };

    for (sides) |side| {
        const neighbor = propagation.world_map.getChunk(side.chunk_x, side.chunk_z) orelse continue;
        const origin_x = side.chunk_x * Chunk.width;
        const origin_z = side.chunk_z * Chunk.width;

        for (0..Chunk.width) |along| {
            const lx = side.local_x orelse @as(u32, @intCast(along));
            const lz = side.local_z orelse @as(u32, @intCast(along));
            for (0..Chunk.height) |ly| {
                const level = switch (propagation.kind) {
                    .sky => neighbor.getSkyLight(lx, @intCast(ly), lz),
                    .block => neighbor.getBlockLight(lx, @intCast(ly), lz),
                };
                if (level > 1) {
                    try propagation.seed(gpa, .init(origin_x + @as(i32, @intCast(lx)), @intCast(ly), origin_z + @as(i32, @intCast(lz))));
                }
            }
        }
    }
}

test "light opacity follows isOpaqueCube, not the material" {
    try std.testing.expectEqual(@as(u8, 0), opacity(.bed));
    try std.testing.expectEqual(@as(u8, 0), opacity(.glass));
    try std.testing.expectEqual(@as(u8, 0), opacity(.cactus));
    try std.testing.expectEqual(@as(u8, 0), opacity(.door_wood));
    try std.testing.expectEqual(@as(u8, 0), opacity(.cake));
    try std.testing.expectEqual(@as(u8, 0), opacity(.sign_post));
    try std.testing.expectEqual(@as(u8, 0), opacity(.pressure_plate_stone));
    try std.testing.expectEqual(@as(u8, 0), opacity(.piston_moving));
    try std.testing.expectEqual(@as(u8, 0), opacity(.mob_spawner));
}

test "the blocks vanilla gives an explicit opacity keep it" {
    try std.testing.expectEqual(@as(u8, 3), opacity(.stationary_water));
    try std.testing.expectEqual(@as(u8, 3), opacity(.ice));
    try std.testing.expectEqual(@as(u8, 1), opacity(.leaves));
    try std.testing.expectEqual(@as(u8, 255), opacity(.stationary_lava));
    try std.testing.expectEqual(@as(u8, 255), opacity(.slab));
    try std.testing.expectEqual(@as(u8, 255), opacity(.stairs_wood));
    try std.testing.expectEqual(@as(u8, 255), opacity(.stone));
    try std.testing.expectEqual(@as(u8, 255), opacity(.slab_double));
}

test "an open column is fully sky lit down to the ground" {
    const gpa = std.testing.allocator;
    var world_map = World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    for (0..Chunk.width) |x| {
        for (0..Chunk.width) |z| {
            chunk.setBlock(@intCast(x), 0, @intCast(z), .stone);
        }
    }

    try relightChunk(gpa, &world_map, 0, 0);

    try std.testing.expectEqual(@as(u4, 15), world_map.getSkyLight(.init(4, 1, 4)));
    try std.testing.expectEqual(@as(u4, 15), world_map.getSkyLight(.init(4, 64, 4)));
    try std.testing.expectEqual(@as(u4, 0), world_map.getSkyLight(.init(4, 0, 4)));
}

test "sky light decays by one per block sideways under an overhang" {
    const gpa = std.testing.allocator;
    var world_map = World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    for (0..Chunk.width) |x| {
        for (0..Chunk.width) |z| {
            chunk.setBlock(@intCast(x), 0, @intCast(z), .stone);
            if (x > 0) chunk.setBlock(@intCast(x), 2, @intCast(z), .stone);
        }
    }

    try relightChunk(gpa, &world_map, 0, 0);

    try std.testing.expectEqual(@as(u4, 15), world_map.getSkyLight(.init(0, 1, 8)));
    try std.testing.expectEqual(@as(u4, 14), world_map.getSkyLight(.init(1, 1, 8)));
    try std.testing.expectEqual(@as(u4, 13), world_map.getSkyLight(.init(2, 1, 8)));
    try std.testing.expectEqual(@as(u4, 12), world_map.getSkyLight(.init(3, 1, 8)));
}

test "water dims the sky light passing through it" {
    const gpa = std.testing.allocator;
    var world_map = World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    for (0..Chunk.width) |x| {
        for (0..Chunk.width) |z| {
            chunk.setBlock(@intCast(x), 0, @intCast(z), .stone);
            chunk.setBlock(@intCast(x), 1, @intCast(z), .stationary_water);
            chunk.setBlock(@intCast(x), 2, @intCast(z), .stationary_water);
        }
    }

    try relightChunk(gpa, &world_map, 0, 0);

    try std.testing.expectEqual(@as(u4, 15), world_map.getSkyLight(.init(8, 3, 8)));
    try std.testing.expectEqual(@as(u4, 12), world_map.getSkyLight(.init(8, 2, 8)));
    try std.testing.expectEqual(@as(u4, 9), world_map.getSkyLight(.init(8, 1, 8)));
}

test "lava lights a sealed cave and nothing lights an empty one" {
    const gpa = std.testing.allocator;
    var world_map = World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    for (0..Chunk.width) |x| {
        for (0..Chunk.width) |z| {
            for (0..8) |y| chunk.setBlock(@intCast(x), @intCast(y), @intCast(z), .stone);
        }
    }
    chunk.setBlock(4, 4, 4, .air);
    chunk.setBlock(5, 4, 4, .air);
    chunk.setBlock(6, 4, 4, .air);

    try relightChunk(gpa, &world_map, 0, 0);
    try std.testing.expectEqual(@as(u4, 0), world_map.getBlockLight(.init(5, 4, 4)));

    chunk.setBlock(4, 4, 4, .flowing_lava);
    try relightChunk(gpa, &world_map, 0, 0);

    try std.testing.expectEqual(@as(u4, 15), world_map.getBlockLight(.init(4, 4, 4)));
    try std.testing.expectEqual(@as(u4, 14), world_map.getBlockLight(.init(5, 4, 4)));
    try std.testing.expectEqual(@as(u4, 13), world_map.getBlockLight(.init(6, 4, 4)));
}

test "glowstone and fire light the nether the way lava does" {
    const gpa = std.testing.allocator;
    var world_map = World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    for (0..Chunk.width) |x| {
        for (0..Chunk.width) |z| {
            for (0..8) |y| chunk.setBlock(@intCast(x), @intCast(y), @intCast(z), .netherrack);
        }
    }
    chunk.setBlock(4, 4, 4, .glowstone);
    chunk.setBlock(5, 4, 4, .air);
    chunk.setBlock(6, 4, 4, .air);
    chunk.setBlock(7, 4, 4, .fire);

    try relightChunk(gpa, &world_map, 0, 0);

    try std.testing.expectEqual(@as(u4, 15), world_map.getBlockLight(.init(4, 4, 4)));
    try std.testing.expectEqual(@as(u4, 15), world_map.getBlockLight(.init(7, 4, 4)));
    try std.testing.expectEqual(@as(u4, 14), world_map.getBlockLight(.init(5, 4, 4)));
    try std.testing.expectEqual(@as(u4, 14), world_map.getBlockLight(.init(6, 4, 4)));
}

test "light crosses a chunk seam from an already lit neighbor" {
    const gpa = std.testing.allocator;
    var world_map = World.init(gpa);
    defer world_map.deinit();
    const open = try world_map.createChunk(0, 0);
    const roofed = try world_map.createChunk(1, 0);
    for (0..Chunk.width) |x| {
        for (0..Chunk.width) |z| {
            for (0..2) |y| {
                open.setBlock(@intCast(x), @intCast(y), @intCast(z), .stone);
                roofed.setBlock(@intCast(x), @intCast(y), @intCast(z), .stone);
            }
            roofed.setBlock(@intCast(x), 3, @intCast(z), .stone);
        }
    }

    try relightChunk(gpa, &world_map, 0, 0);
    try relightChunk(gpa, &world_map, 1, 0);

    try std.testing.expectEqual(@as(u4, 15), world_map.getSkyLight(.init(15, 2, 8)));
    try std.testing.expectEqual(@as(u4, 14), world_map.getSkyLight(.init(16, 2, 8)));
    try std.testing.expectEqual(@as(u4, 13), world_map.getSkyLight(.init(17, 2, 8)));
}

test "a generated chunk is lit down to its surface and dark at bedrock" {
    const gpa = std.testing.allocator;
    const TerrainGenerator = @import("gen/TerrainGenerator.zig");

    const generator = try TerrainGenerator.init(gpa, 1);
    defer generator.deinit(gpa);
    var world_map = World.init(gpa);
    defer world_map.deinit();
    try world_map.ensureDecorated(generator, 0, 0);

    const chunk = world_map.getChunk(0, 0).?;
    var lit_surfaces: u32 = 0;
    for (0..Chunk.width) |x| {
        for (0..Chunk.width) |z| {
            const surface = chunk.getHeightValue(@intCast(x), @intCast(z));
            try std.testing.expect(surface > 0);
            if (world_map.getSkyLight(.init(@intCast(x), surface, @intCast(z))) == max_level) lit_surfaces += 1;
            try std.testing.expectEqual(@as(u4, 0), world_map.getSkyLight(.init(@intCast(x), 1, @intCast(z))));
        }
    }
    try std.testing.expectEqual(@as(u32, Chunk.width * Chunk.width), lit_surfaces);
}

test "the brightness table matches WorldProvider's curve" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), brightness_table[0], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), brightness_table[15], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2611111), brightness_table[8], 1.0e-6);
}

test "a torch lights the block it sits in and fades by one per step" {
    const gpa = std.testing.allocator;
    var world_map = World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    for (0..Chunk.width) |x| {
        for (0..Chunk.width) |z| {
            for (0..12) |y| chunk.setBlock(@intCast(x), @intCast(y), @intCast(z), .stone);
        }
    }
    chunk.setBlock(8, 12, 8, .torch);
    chunk.setBlockMetadata(8, 12, 8, 5);

    try relightChunk(gpa, &world_map, 0, 0);

    try std.testing.expectEqual(@as(u4, 14), world_map.getBlockLight(.init(8, 12, 8)));
    try std.testing.expectEqual(@as(u4, 13), world_map.getBlockLight(.init(9, 12, 8)));
    try std.testing.expectEqual(@as(u4, 12), world_map.getBlockLight(.init(10, 12, 8)));
    try std.testing.expectEqual(@as(u4, 0), world_map.getBlockLight(.init(8, 11, 8)));
}

test "a door casts no shadow, so daylight reaches the floor of the doorway" {
    const gpa = std.testing.allocator;
    var world_map = World.init(gpa);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    for (0..Chunk.width) |x| {
        for (0..Chunk.width) |z| {
            for (0..12) |y| chunk.setBlock(@intCast(x), @intCast(y), @intCast(z), .stone);
        }
    }
    chunk.setBlock(8, 13, 8, .door_wood);
    chunk.setBlockMetadata(8, 13, 8, 1 | block.door_top_bit);
    chunk.setBlock(8, 12, 8, .door_wood);
    chunk.setBlockMetadata(8, 12, 8, 1);

    try relightChunk(gpa, &world_map, 0, 0);

    try std.testing.expectEqual(@as(u8, 0), opacity(.door_wood));
    try std.testing.expectEqual(@as(u4, max_level), world_map.getSkyLight(.init(8, 12, 8)));
    try std.testing.expectEqual(@as(u4, max_level), world_map.getSkyLight(.init(8, 13, 8)));
}

test "a stair borrows light from around it instead of the darkness in its own cell" {
    var world_map = World.init(std.testing.allocator);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    for (0..Chunk.width) |x| {
        for (0..Chunk.width) |z| {
            chunk.setBlock(@intCast(x), 0, @intCast(z), .stone);
        }
    }
    chunk.setBlock(8, 1, 8, .stairs_cobblestone);
    try relightChunk(std.testing.allocator, &world_map, 0, 0);

    try std.testing.expectEqual(@as(u4, 0), storedLevelAt(&world_map, .init(8, 1, 8)));
    try std.testing.expectEqual(max_level, levelAt(&world_map, .init(8, 1, 8)));
    try std.testing.expect(brightnessAt(&world_map, .init(8, 1, 8), 0) > 0.9);
}

test "a slab borrows light the same way, but a double slab keeps its own darkness" {
    var world_map = World.init(std.testing.allocator);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    for (0..Chunk.width) |x| {
        for (0..Chunk.width) |z| {
            chunk.setBlock(@intCast(x), 0, @intCast(z), .stone);
        }
    }
    chunk.setBlock(8, 1, 8, .slab);
    chunk.setBlock(10, 1, 10, .slab_double);
    try relightChunk(std.testing.allocator, &world_map, 0, 0);

    try std.testing.expectEqual(max_level, levelAt(&world_map, .init(8, 1, 8)));
    try std.testing.expectEqual(@as(u4, 0), levelAt(&world_map, .init(10, 1, 10)));
}

test "a stair sealed away from the sky borrows only the dark around it" {
    var world_map = World.init(std.testing.allocator);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    for (0..Chunk.width) |x| {
        for (0..Chunk.width) |z| {
            var y: u32 = 0;
            while (y <= 3) : (y += 1) chunk.setBlock(@intCast(x), y, @intCast(z), .stone);
        }
    }
    chunk.setBlock(8, 2, 8, .stairs_wood);
    try relightChunk(std.testing.allocator, &world_map, 0, 0);

    try std.testing.expectEqual(@as(u4, 0), levelAt(&world_map, .init(8, 2, 8)));

    chunk.setBlock(9, 2, 8, .torch);
    try relightChunk(std.testing.allocator, &world_map, 0, 0);
    try std.testing.expect(levelAt(&world_map, .init(8, 2, 8)) > 0);
}

test "a stair never borrows light from the block beneath it" {
    var world_map = World.init(std.testing.allocator);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    for (0..Chunk.width) |x| {
        for (0..Chunk.width) |z| {
            var y: u32 = 0;
            while (y <= 4) : (y += 1) chunk.setBlock(@intCast(x), y, @intCast(z), .stone);
        }
    }
    chunk.setBlock(8, 3, 8, .stairs_wood);
    chunk.setBlock(8, 2, 8, .torch);
    try relightChunk(std.testing.allocator, &world_map, 0, 0);

    try std.testing.expectEqual(@as(u4, 14), world_map.getBlockLight(.init(8, 2, 8)));
    try std.testing.expectEqual(@as(u4, 0), levelAt(&world_map, .init(8, 3, 8)));
}

test "a sign lets light straight through, as any block that is not a full cube does" {
    try std.testing.expectEqual(@as(u8, 0), opacity(.sign_post));
    try std.testing.expectEqual(@as(u8, 0), opacity(.wall_sign));
    try std.testing.expectEqual(@as(u8, 255), opacity(.planks));
}

test "a piston lets light past it, stone though its material is" {
    try std.testing.expectEqual(@as(u8, 0), opacity(.piston));
    try std.testing.expectEqual(@as(u8, 0), opacity(.piston_sticky));
    try std.testing.expectEqual(@as(u8, 0), opacity(.piston_head));
    try std.testing.expectEqual(@as(u8, 0), opacity(.piston_moving));
}

test "a pressure plate lets daylight through instead of casting a shadow under itself" {
    const gpa = std.testing.allocator;
    var world_map = World.init(gpa);
    defer world_map.deinit();

    const chunk = try world_map.createChunk(0, 0);
    for (0..Chunk.width) |x| {
        for (0..Chunk.width) |z| {
            chunk.setBlock(@intCast(x), 0, @intCast(z), .stone);
        }
    }
    chunk.setBlock(8, 1, 8, .pressure_plate_stone);

    try relightChunk(gpa, &world_map, 0, 0);

    try std.testing.expectEqual(max_level, world_map.getSkyLight(.init(8, 1, 8)));
    try std.testing.expectEqual(brightness_table[max_level], brightnessAt(&world_map, .init(8, 1, 8), 0));
}
