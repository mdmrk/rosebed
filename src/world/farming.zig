const std = @import("std");

const assets = @import("assets");
const math = @import("math");

const block = @import("block.zig");
const Block = block.Block;
const block_update = @import("block_update.zig");
const BlockPos = @import("BlockPos.zig");
const Chunk = @import("Chunk.zig");
const light = @import("light.zig");
const random_tick = @import("random_tick.zig");
const testing_world = @import("testing.zig");
const World = @import("World.zig");

const growth_light_level: u4 = 9;
const growth_denominator: f32 = 100.0;
const dry_odds: i32 = 5;
const trample_odds: i32 = 4;
const water_radius: i32 = 4;
const wet_metadata: u4 = 7;

fn growthRate(world_map: *const World, pos: BlockPos) f32 {
    var rate: f32 = 1.0;

    var soil_x = pos.x - 1;
    while (soil_x <= pos.x + 1) : (soil_x += 1) {
        var soil_z = pos.z - 1;
        while (soil_z <= pos.z + 1) : (soil_z += 1) {
            var share: f32 = 0.0;
            if (world_map.getBlock(.init(soil_x, pos.y - 1, soil_z)) == .farmland) {
                share = if (world_map.getBlockMetadata(.init(soil_x, pos.y - 1, soil_z)) > 0) 3.0 else 1.0;
            }
            if (soil_x != pos.x or soil_z != pos.z) share /= 4.0;
            rate += share;
        }
    }

    const west = world_map.getBlock(pos.offset(-1, 0, 0)) == .crops;
    const east = world_map.getBlock(pos.offset(1, 0, 0)) == .crops;
    const north = world_map.getBlock(pos.offset(0, 0, -1)) == .crops;
    const south = world_map.getBlock(pos.offset(0, 0, 1)) == .crops;
    const diagonal = world_map.getBlock(pos.offset(-1, 0, -1)) == .crops or
        world_map.getBlock(pos.offset(1, 0, -1)) == .crops or
        world_map.getBlock(pos.offset(1, 0, 1)) == .crops or
        world_map.getBlock(pos.offset(-1, 0, 1)) == .crops;

    if (diagonal or ((west or east) and (north or south))) rate /= 2.0;
    return rate;
}

pub fn tickCrops(world_map: *World, pos: BlockPos, id: Block) std.mem.Allocator.Error!void {
    try block_update.popIfUnsupported(world_map, pos, id);
    if (world_map.getBlock(pos) != id) return;

    if (light.levelAt(world_map, pos.offset(0, 1, 0)) < growth_light_level) return;

    const metadata = world_map.getBlockMetadata(pos);
    if (metadata >= block.crops_ripe) return;

    const bound: i32 = @intFromFloat(growth_denominator / growthRate(world_map, pos));
    if (world_map.rand.nextIntBound(bound) != 0) return;
    try world_map.setBlockMetadataWithNotify(pos, metadata + 1);
}

fn waterNearby(world_map: *const World, pos: BlockPos) bool {
    var at_x = pos.x - water_radius;
    while (at_x <= pos.x + water_radius) : (at_x += 1) {
        var at_y = pos.y;
        while (at_y <= pos.y + 1) : (at_y += 1) {
            var at_z = pos.z - water_radius;
            while (at_z <= pos.z + water_radius) : (at_z += 1) {
                if (world_map.getBlock(.init(at_x, at_y, at_z)).material() == .water) return true;
            }
        }
    }
    return false;
}

pub fn tickFarmland(world_map: *World, pos: BlockPos, _: Block) std.mem.Allocator.Error!void {
    if (world_map.rand.nextIntBound(dry_odds) != 0) return;

    if (waterNearby(world_map, pos) or world_map.canBlockBeRainedOn(pos.offset(0, 1, 0))) {
        try world_map.setBlockMetadataWithNotify(pos, wet_metadata);
        return;
    }

    const metadata = world_map.getBlockMetadata(pos);
    if (metadata > 0) {
        try world_map.setBlockMetadataWithNotify(pos, metadata - 1);
    } else if (world_map.getBlock(pos.offset(0, 1, 0)) != .crops) {
        try world_map.setBlockWithNotify(pos, .dirt);
    }
}

pub fn onFarmlandNeighborChange(world_map: *World, pos: BlockPos, _: Block) std.mem.Allocator.Error!void {
    if (!world_map.getBlock(pos.offset(0, 1, 0)).material().isSolid()) return;
    try world_map.setBlockWithNotify(pos, .dirt);
}

pub fn trample(world_map: *World, pos: BlockPos) std.mem.Allocator.Error!void {
    if (world_map.getBlock(pos) != .farmland) return;
    if (world_map.rand.nextIntBound(trample_odds) != 0) return;
    try world_map.setBlockWithNotify(pos, .dirt);
}

pub const bone_meal_attempts: usize = 128;
pub const bone_meal_steps_per: usize = 16;
const tall_grass_odds: i32 = 10;
const dandelion_odds: i32 = 3;
const tall_grass_metadata: u4 = 1;

pub fn applyBoneMeal(world_map: *World, pos: BlockPos) std.mem.Allocator.Error!bool {
    switch (world_map.getBlock(pos)) {
        .sapling => try random_tick.growTree(world_map, pos),
        .crops => try world_map.setBlockMetadataWithNotify(pos, block.crops_ripe),
        .grass => try scatterOverGrass(world_map, pos),
        else => return false,
    }
    return true;
}

fn scatterOverGrass(world_map: *World, pos: BlockPos) std.mem.Allocator.Error!void {
    const rand = &world_map.rand;

    for (0..bone_meal_attempts) |attempt| {
        var at = pos.offset(0, 1, 0);
        const steps = attempt / bone_meal_steps_per;

        var step: usize = 0;
        const wandered = while (step < steps) : (step += 1) {
            const dx = rand.nextIntBound(3) - 1;
            const dy = @divTrunc((rand.nextIntBound(3) - 1) * rand.nextIntBound(3), 2);
            const dz = rand.nextIntBound(3) - 1;
            at = at.offset(dx, dy, dz);

            if (world_map.getBlock(at.offset(0, -1, 0)) != .grass) break false;
            if (world_map.getBlock(at).isNormalCube()) break false;
        } else true;

        if (!wandered) continue;
        if (world_map.getBlock(at) != .air) continue;

        if (rand.nextIntBound(tall_grass_odds) != 0) {
            try world_map.setBlockAndMetadataWithNotify(at, .tall_grass, tall_grass_metadata);
        } else if (rand.nextIntBound(dandelion_odds) != 0) {
            try world_map.setBlockWithNotify(at, .dandelion);
        } else {
            try world_map.setBlockWithNotify(at, .rose);
        }
    }
}

pub fn till(world_map: *World, pos: BlockPos, face: block.Side) std.mem.Allocator.Error!bool {
    const target = world_map.getBlock(pos);
    const tillable = target == .dirt or
        (target == .grass and face != .down and world_map.getBlock(pos.offset(0, 1, 0)) == .air);
    if (!tillable) return false;

    const step_sound = Block.farmland.stepSound();
    world_map.playSoundEffect(
        pos.center(),
        step_sound.walk(),
        (step_sound.volume() + 1.0) / 2.0,
        step_sound.pitch() * 0.8,
    );
    try world_map.setBlockWithNotify(pos, .farmland);
    return true;
}

pub fn plant(world_map: *World, pos: BlockPos, face: block.Side) std.mem.Allocator.Error!bool {
    if (face != .up) return false;
    if (world_map.getBlock(pos) != .farmland) return false;
    if (world_map.getBlock(pos.offset(0, 1, 0)) != .air) return false;

    try world_map.setBlockAndMetadataWithNotify(pos.offset(0, 1, 0), .crops, 0);
    return true;
}

test "crops ripen fastest on watered soil and slow down when they crowd each other" {
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    defer w.deinit();

    w.setBlock(.init(8, 11, 8), .farmland);
    w.setBlock(.init(8, 12, 8), .crops);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), growthRate(&w, .init(8, 12, 8)), 1.0e-6);

    w.setBlockMetadata(.init(8, 11, 8), wet_metadata);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), growthRate(&w, .init(8, 12, 8)), 1.0e-6);

    w.setBlock(.init(9, 11, 8), .farmland);
    try std.testing.expectApproxEqAbs(@as(f32, 4.25), growthRate(&w, .init(8, 12, 8)), 1.0e-6);

    w.setBlock(.init(9, 12, 8), .crops);
    w.setBlock(.init(8, 12, 9), .crops);
    try std.testing.expectApproxEqAbs(@as(f32, 2.125), growthRate(&w, .init(8, 12, 8)), 1.0e-6);
}

test "a crop steps up one stage at a time and stops when it is ripe" {
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    defer w.deinit();
    w.setBlock(.init(8, 11, 8), .farmland);
    w.setBlock(.init(8, 12, 8), .crops);
    try light.relightChunk(std.testing.allocator, &w, 0, 0);

    var grown = false;
    for (0..4000) |_| {
        try tickCrops(&w, .init(8, 12, 8), .crops);
        if (w.getBlockMetadata(.init(8, 12, 8)) > 0) {
            grown = true;
            break;
        }
    }
    try std.testing.expect(grown);
    try std.testing.expectEqual(@as(u4, 1), w.getBlockMetadata(.init(8, 12, 8)));

    w.setBlockMetadata(.init(8, 12, 8), block.crops_ripe);
    for (0..100) |_| try tickCrops(&w, .init(8, 12, 8), .crops);
    try std.testing.expectEqual(block.crops_ripe, w.getBlockMetadata(.init(8, 12, 8)));
}

test "a crop in the dark never grows" {
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    defer w.deinit();
    w.setBlock(.init(8, 11, 8), .farmland);
    w.setBlock(.init(8, 12, 8), .crops);
    w.setBlock(.init(8, 13, 8), .stone);
    try light.relightChunk(std.testing.allocator, &w, 0, 0);

    for (0..2000) |_| try tickCrops(&w, .init(8, 12, 8), .crops);
    try std.testing.expectEqual(@as(u4, 0), w.getBlockMetadata(.init(8, 12, 8)));
}

test "farmland soaks up nearby water and dries back to dirt without it" {
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    defer w.deinit();
    w.setBlock(.init(8, 11, 8), .farmland);
    w.setBlock(.init(12, 11, 8), .stationary_water);

    for (0..200) |_| try tickFarmland(&w, .init(8, 11, 8), .farmland);
    try std.testing.expectEqual(wet_metadata, w.getBlockMetadata(.init(8, 11, 8)));

    w.setBlock(.init(12, 11, 8), .air);
    for (0..2000) |_| try tickFarmland(&w, .init(8, 11, 8), .farmland);
    try std.testing.expectEqual(.dirt, w.getBlock(.init(8, 11, 8)));
}

test "bare farmland under a crop stays farmland even when it dries out" {
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    defer w.deinit();
    w.setBlock(.init(8, 11, 8), .farmland);
    w.setBlock(.init(8, 12, 8), .crops);

    for (0..2000) |_| try tickFarmland(&w, .init(8, 11, 8), .farmland);
    try std.testing.expectEqual(.farmland, w.getBlock(.init(8, 11, 8)));
    try std.testing.expectEqual(@as(u4, 0), w.getBlockMetadata(.init(8, 11, 8)));
}

const HeardSound = struct {
    key: []const u8 = "",
    volume: f32 = 0,
    pitch: f32 = 0,

    fn record(context: *anyopaque, sound: assets.Sound, _: math.Vec3, volume: f32, pitch: f32) void {
        const self: *HeardSound = @ptrCast(@alignCast(context));
        self.key = sound.key;
        self.volume = volume;
        self.pitch = pitch;
    }

    fn ignoreRecord(_: *anyopaque, _: ?[]const u8, _: BlockPos) void {}

    fn sink(self: *HeardSound) World.SoundSink {
        return .{ .context = self, .playSound = record, .playRecord = ignoreRecord };
    }
};

test "tilling is heard as farmland's own footfall" {
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    defer w.deinit();
    w.setBlock(.init(8, 11, 8), .dirt);

    var heard: HeardSound = .{};
    w.sound_sink = heard.sink();

    try std.testing.expect(try till(&w, .init(8, 11, 8), .up));

    const step_sound = Block.farmland.stepSound();
    try std.testing.expectEqualStrings(step_sound.walk().key, heard.key);
    try std.testing.expectApproxEqAbs((step_sound.volume() + 1.0) / 2.0, heard.volume, 1.0e-6);
    try std.testing.expectApproxEqAbs(step_sound.pitch() * 0.8, heard.pitch, 1.0e-6);
}

test "a hoe tills dirt from any side but only bare grass" {
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    defer w.deinit();
    w.setBlock(.init(8, 11, 8), .dirt);
    w.setBlock(.init(9, 11, 8), .grass);
    w.setBlock(.init(10, 11, 8), .grass);
    w.setBlock(.init(10, 12, 8), .stone);
    w.setBlock(.init(11, 11, 8), .stone);

    try std.testing.expect(try till(&w, .init(8, 11, 8), .down));
    try std.testing.expectEqual(.farmland, w.getBlock(.init(8, 11, 8)));

    try std.testing.expect(try till(&w, .init(9, 11, 8), .up));
    try std.testing.expectEqual(.farmland, w.getBlock(.init(9, 11, 8)));

    try std.testing.expect(!try till(&w, .init(10, 11, 8), .up));
    try std.testing.expect(!try till(&w, .init(11, 11, 8), .up));
}

test "seeds only go into the top of farmland" {
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    defer w.deinit();
    w.setBlock(.init(8, 11, 8), .farmland);
    w.setBlock(.init(9, 11, 8), .dirt);

    try std.testing.expect(!try plant(&w, .init(8, 11, 8), .north));
    try std.testing.expect(!try plant(&w, .init(9, 11, 8), .up));

    try std.testing.expect(try plant(&w, .init(8, 11, 8), .up));
    try std.testing.expectEqual(.crops, w.getBlock(.init(8, 12, 8)));
    try std.testing.expectEqual(@as(u4, 0), w.getBlockMetadata(.init(8, 12, 8)));

    try std.testing.expect(!try plant(&w, .init(8, 11, 8), .up));
}

test "walking on farmland packs it back down to dirt" {
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    defer w.deinit();
    w.setBlock(.init(8, 11, 8), .farmland);

    for (0..100) |_| try trample(&w, .init(8, 11, 8));
    try std.testing.expectEqual(.dirt, w.getBlock(.init(8, 11, 8)));
}

fn boneMealWorld(gpa: std.mem.Allocator) !World {
    var w = try testing_world.flatWorld(gpa, 2);
    errdefer w.deinit();

    const chunk = w.getChunk(0, 0).?;
    for (0..Chunk.width) |x| {
        for (0..Chunk.width) |z| chunk.setBlock(@intCast(x), 1, @intCast(z), .grass);
    }
    try light.relightChunk(gpa, &w, 0, 0);
    return w;
}

test "bone meal ripens a crop in one go" {
    const gpa = std.testing.allocator;
    var w = try boneMealWorld(gpa);
    defer w.deinit();

    w.setBlock(.init(8, 1, 8), .farmland);
    try w.setBlockAndMetadataWithNotify(.init(8, 2, 8), .crops, 2);

    try std.testing.expect(try applyBoneMeal(&w, .init(8, 2, 8)));
    try std.testing.expectEqual(block.crops_ripe, w.getBlockMetadata(.init(8, 2, 8)));
}

test "bone meal turns a sapling into a tree" {
    const gpa = std.testing.allocator;
    var w = try boneMealWorld(gpa);
    defer w.deinit();

    w.setBlock(.init(8, 1, 8), .dirt);
    try w.setBlockWithNotify(.init(8, 2, 8), .sapling);

    var grown = false;
    for (0..64) |_| {
        w.setBlock(.init(8, 2, 8), .sapling);
        w.setBlockMetadata(.init(8, 2, 8), 0);
        try std.testing.expect(try applyBoneMeal(&w, .init(8, 2, 8)));
        if (w.getBlock(.init(8, 2, 8)) == .log) {
            grown = true;
            break;
        }
    }
    try std.testing.expect(grown);
}

test "bone meal on a grass block scatters tall grass and flowers over it" {
    const gpa = std.testing.allocator;
    var w = try boneMealWorld(gpa);
    defer w.deinit();

    try std.testing.expect(try applyBoneMeal(&w, .init(8, 1, 8)));

    var tall_grass: usize = 0;
    var flowers: usize = 0;
    const chunk = w.getChunk(0, 0).?;
    for (0..Chunk.width) |x| {
        for (0..Chunk.width) |z| {
            switch (chunk.getBlock(@intCast(x), 2, @intCast(z))) {
                .tall_grass => tall_grass += 1,
                .dandelion, .rose => flowers += 1,
                else => {},
            }
        }
    }

    try std.testing.expect(tall_grass > 0);
    try std.testing.expect(tall_grass > flowers);
}

test "the scatter never plants on anything but grass, nor into a filled cell" {
    const gpa = std.testing.allocator;
    var w = try boneMealWorld(gpa);
    defer w.deinit();

    const chunk = w.getChunk(0, 0).?;
    for (0..Chunk.width) |x| {
        for (0..Chunk.width) |z| {
            if (x % 2 != 0) chunk.setBlock(@intCast(x), 1, @intCast(z), .stone);
        }
    }
    chunk.setBlock(10, 2, 8, .cobblestone);
    try light.relightChunk(gpa, &w, 0, 0);

    try std.testing.expect(!try applyBoneMeal(&w, .init(9, 1, 8)));
    try std.testing.expect(try applyBoneMeal(&w, .init(8, 1, 8)));

    try std.testing.expectEqual(Block.cobblestone, w.getBlock(.init(10, 2, 8)));
    for (0..Chunk.width) |x| {
        for (0..Chunk.width) |z| {
            if (x % 2 == 0) continue;
            try std.testing.expectEqual(Block.air, chunk.getBlock(@intCast(x), 2, @intCast(z)));
        }
    }
}

test "bone meal does nothing to a block that is not a sapling, crop or grass" {
    const gpa = std.testing.allocator;
    var w = try boneMealWorld(gpa);
    defer w.deinit();

    w.setBlock(.init(8, 1, 8), .stone);
    try std.testing.expect(!try applyBoneMeal(&w, .init(8, 1, 8)));
    try std.testing.expect(!try applyBoneMeal(&w, .init(8, 2, 8)));
}
