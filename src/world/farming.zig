const std = @import("std");

const assets = @import("assets");

const block = @import("block.zig");
const Block = block.Block;
const block_update = @import("block_update.zig");
const light = @import("light.zig");
const testing_world = @import("testing.zig");
const World = @import("World.zig");

const growth_light_level: u4 = 9;
const growth_denominator: f32 = 100.0;
const dry_odds: i32 = 5;
const trample_odds: i32 = 4;
const water_radius: i32 = 4;
const wet_metadata: u4 = 7;

fn growthRate(world_map: *const World, x: i32, y: i32, z: i32) f32 {
    var rate: f32 = 1.0;

    var soil_x = x - 1;
    while (soil_x <= x + 1) : (soil_x += 1) {
        var soil_z = z - 1;
        while (soil_z <= z + 1) : (soil_z += 1) {
            var share: f32 = 0.0;
            if (world_map.getBlock(soil_x, y - 1, soil_z) == .farmland) {
                share = if (world_map.getBlockMetadata(soil_x, y - 1, soil_z) > 0) 3.0 else 1.0;
            }
            if (soil_x != x or soil_z != z) share /= 4.0;
            rate += share;
        }
    }

    const west = world_map.getBlock(x - 1, y, z) == .crops;
    const east = world_map.getBlock(x + 1, y, z) == .crops;
    const north = world_map.getBlock(x, y, z - 1) == .crops;
    const south = world_map.getBlock(x, y, z + 1) == .crops;
    const diagonal = world_map.getBlock(x - 1, y, z - 1) == .crops or
        world_map.getBlock(x + 1, y, z - 1) == .crops or
        world_map.getBlock(x + 1, y, z + 1) == .crops or
        world_map.getBlock(x - 1, y, z + 1) == .crops;

    if (diagonal or ((west or east) and (north or south))) rate /= 2.0;
    return rate;
}

pub fn tickCrops(world_map: *World, x: i32, y: i32, z: i32, id: Block) std.mem.Allocator.Error!void {
    try block_update.popIfUnsupported(world_map, x, y, z, id);
    if (world_map.getBlock(x, y, z) != id) return;

    if (light.levelAt(world_map, x, y + 1, z) < growth_light_level) return;

    const metadata = world_map.getBlockMetadata(x, y, z);
    if (metadata >= block.crops_ripe) return;

    const bound: i32 = @intFromFloat(growth_denominator / growthRate(world_map, x, y, z));
    if (world_map.rand.nextIntBound(bound) != 0) return;
    try world_map.setBlockMetadataWithNotify(x, y, z, metadata + 1);
}

fn waterNearby(world_map: *const World, x: i32, y: i32, z: i32) bool {
    var at_x = x - water_radius;
    while (at_x <= x + water_radius) : (at_x += 1) {
        var at_y = y;
        while (at_y <= y + 1) : (at_y += 1) {
            var at_z = z - water_radius;
            while (at_z <= z + water_radius) : (at_z += 1) {
                if (world_map.getBlock(at_x, at_y, at_z).material() == .water) return true;
            }
        }
    }
    return false;
}

pub fn tickFarmland(world_map: *World, x: i32, y: i32, z: i32, _: Block) std.mem.Allocator.Error!void {
    if (world_map.rand.nextIntBound(dry_odds) != 0) return;

    if (waterNearby(world_map, x, y, z) or world_map.canBlockBeRainedOn(x, y + 1, z)) {
        try world_map.setBlockMetadataWithNotify(x, y, z, wet_metadata);
        return;
    }

    const metadata = world_map.getBlockMetadata(x, y, z);
    if (metadata > 0) {
        try world_map.setBlockMetadataWithNotify(x, y, z, metadata - 1);
    } else if (world_map.getBlock(x, y + 1, z) != .crops) {
        try world_map.setBlockWithNotify(x, y, z, .dirt);
    }
}

pub fn onFarmlandNeighborChange(world_map: *World, x: i32, y: i32, z: i32, _: Block) std.mem.Allocator.Error!void {
    if (!world_map.getBlock(x, y + 1, z).material().isSolid()) return;
    try world_map.setBlockWithNotify(x, y, z, .dirt);
}

pub fn trample(world_map: *World, x: i32, y: i32, z: i32) std.mem.Allocator.Error!void {
    if (world_map.getBlock(x, y, z) != .farmland) return;
    if (world_map.rand.nextIntBound(trample_odds) != 0) return;
    try world_map.setBlockWithNotify(x, y, z, .dirt);
}

pub fn till(world_map: *World, x: i32, y: i32, z: i32, face: block.Side) std.mem.Allocator.Error!bool {
    const target = world_map.getBlock(x, y, z);
    const tillable = target == .dirt or
        (target == .grass and face != .down and world_map.getBlock(x, y + 1, z) == .air);
    if (!tillable) return false;

    const step_sound = Block.farmland.stepSound();
    world_map.playSoundEffect(
        @as(f64, @floatFromInt(x)) + 0.5,
        @as(f64, @floatFromInt(y)) + 0.5,
        @as(f64, @floatFromInt(z)) + 0.5,
        step_sound.walk(),
        (step_sound.volume() + 1.0) / 2.0,
        step_sound.pitch() * 0.8,
    );
    try world_map.setBlockWithNotify(x, y, z, .farmland);
    return true;
}

pub fn plant(world_map: *World, x: i32, y: i32, z: i32, face: block.Side) std.mem.Allocator.Error!bool {
    if (face != .up) return false;
    if (world_map.getBlock(x, y, z) != .farmland) return false;
    if (world_map.getBlock(x, y + 1, z) != .air) return false;

    try world_map.setBlockAndMetadataWithNotify(x, y + 1, z, .crops, 0);
    return true;
}

test "crops ripen fastest on watered soil and slow down when they crowd each other" {
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    defer w.deinit();

    w.setBlock(8, 11, 8, .farmland);
    w.setBlock(8, 12, 8, .crops);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), growthRate(&w, 8, 12, 8), 1.0e-6);

    w.setBlockMetadata(8, 11, 8, wet_metadata);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), growthRate(&w, 8, 12, 8), 1.0e-6);

    w.setBlock(9, 11, 8, .farmland);
    try std.testing.expectApproxEqAbs(@as(f32, 4.25), growthRate(&w, 8, 12, 8), 1.0e-6);

    w.setBlock(9, 12, 8, .crops);
    w.setBlock(8, 12, 9, .crops);
    try std.testing.expectApproxEqAbs(@as(f32, 2.125), growthRate(&w, 8, 12, 8), 1.0e-6);
}

test "a crop steps up one stage at a time and stops when it is ripe" {
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    defer w.deinit();
    w.setBlock(8, 11, 8, .farmland);
    w.setBlock(8, 12, 8, .crops);
    try light.relightChunk(std.testing.allocator, &w, 0, 0);

    var grown = false;
    for (0..4000) |_| {
        try tickCrops(&w, 8, 12, 8, .crops);
        if (w.getBlockMetadata(8, 12, 8) > 0) {
            grown = true;
            break;
        }
    }
    try std.testing.expect(grown);
    try std.testing.expectEqual(@as(u4, 1), w.getBlockMetadata(8, 12, 8));

    w.setBlockMetadata(8, 12, 8, block.crops_ripe);
    for (0..100) |_| try tickCrops(&w, 8, 12, 8, .crops);
    try std.testing.expectEqual(block.crops_ripe, w.getBlockMetadata(8, 12, 8));
}

test "a crop in the dark never grows" {
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    defer w.deinit();
    w.setBlock(8, 11, 8, .farmland);
    w.setBlock(8, 12, 8, .crops);
    w.setBlock(8, 13, 8, .stone);
    try light.relightChunk(std.testing.allocator, &w, 0, 0);

    for (0..2000) |_| try tickCrops(&w, 8, 12, 8, .crops);
    try std.testing.expectEqual(@as(u4, 0), w.getBlockMetadata(8, 12, 8));
}

test "farmland soaks up nearby water and dries back to dirt without it" {
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    defer w.deinit();
    w.setBlock(8, 11, 8, .farmland);
    w.setBlock(12, 11, 8, .stationary_water);

    for (0..200) |_| try tickFarmland(&w, 8, 11, 8, .farmland);
    try std.testing.expectEqual(wet_metadata, w.getBlockMetadata(8, 11, 8));

    w.setBlock(12, 11, 8, .air);
    for (0..2000) |_| try tickFarmland(&w, 8, 11, 8, .farmland);
    try std.testing.expectEqual(.dirt, w.getBlock(8, 11, 8));
}

test "bare farmland under a crop stays farmland even when it dries out" {
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    defer w.deinit();
    w.setBlock(8, 11, 8, .farmland);
    w.setBlock(8, 12, 8, .crops);

    for (0..2000) |_| try tickFarmland(&w, 8, 11, 8, .farmland);
    try std.testing.expectEqual(.farmland, w.getBlock(8, 11, 8));
    try std.testing.expectEqual(@as(u4, 0), w.getBlockMetadata(8, 11, 8));
}

const HeardSound = struct {
    key: []const u8 = "",
    volume: f32 = 0,
    pitch: f32 = 0,

    fn record(context: *anyopaque, sound: assets.Sound, _: f64, _: f64, _: f64, volume: f32, pitch: f32) void {
        const self: *HeardSound = @ptrCast(@alignCast(context));
        self.key = sound.key;
        self.volume = volume;
        self.pitch = pitch;
    }

    fn ignoreRecord(_: *anyopaque, _: ?[]const u8, _: i32, _: i32, _: i32) void {}

    fn sink(self: *HeardSound) World.SoundSink {
        return .{ .context = self, .playSound = record, .playRecord = ignoreRecord };
    }
};

test "tilling is heard as farmland's own footfall" {
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    defer w.deinit();
    w.setBlock(8, 11, 8, .dirt);

    var heard: HeardSound = .{};
    w.sound_sink = heard.sink();

    try std.testing.expect(try till(&w, 8, 11, 8, .up));

    const step_sound = Block.farmland.stepSound();
    try std.testing.expectEqualStrings(step_sound.walk().key, heard.key);
    try std.testing.expectApproxEqAbs((step_sound.volume() + 1.0) / 2.0, heard.volume, 1.0e-6);
    try std.testing.expectApproxEqAbs(step_sound.pitch() * 0.8, heard.pitch, 1.0e-6);
}

test "a hoe tills dirt from any side but only bare grass" {
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    defer w.deinit();
    w.setBlock(8, 11, 8, .dirt);
    w.setBlock(9, 11, 8, .grass);
    w.setBlock(10, 11, 8, .grass);
    w.setBlock(10, 12, 8, .stone);
    w.setBlock(11, 11, 8, .stone);

    try std.testing.expect(try till(&w, 8, 11, 8, .down));
    try std.testing.expectEqual(.farmland, w.getBlock(8, 11, 8));

    try std.testing.expect(try till(&w, 9, 11, 8, .up));
    try std.testing.expectEqual(.farmland, w.getBlock(9, 11, 8));

    try std.testing.expect(!try till(&w, 10, 11, 8, .up));
    try std.testing.expect(!try till(&w, 11, 11, 8, .up));
}

test "seeds only go into the top of farmland" {
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    defer w.deinit();
    w.setBlock(8, 11, 8, .farmland);
    w.setBlock(9, 11, 8, .dirt);

    try std.testing.expect(!try plant(&w, 8, 11, 8, .north));
    try std.testing.expect(!try plant(&w, 9, 11, 8, .up));

    try std.testing.expect(try plant(&w, 8, 11, 8, .up));
    try std.testing.expectEqual(.crops, w.getBlock(8, 12, 8));
    try std.testing.expectEqual(@as(u4, 0), w.getBlockMetadata(8, 12, 8));

    try std.testing.expect(!try plant(&w, 8, 11, 8, .up));
}

test "walking on farmland packs it back down to dirt" {
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    defer w.deinit();
    w.setBlock(8, 11, 8, .farmland);

    for (0..100) |_| try trample(&w, 8, 11, 8);
    try std.testing.expectEqual(.dirt, w.getBlock(8, 11, 8));
}
