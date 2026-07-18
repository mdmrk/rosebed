const std = @import("std");
const math = @import("math");
const world = @import("world");
const Animal = @import("animal.zig");
const Chicken = @import("chicken.zig");
const Cow = @import("cow.zig");
const Entities = @import("entities.zig");
const Pig = @import("pig.zig");
const Sheep = @import("sheep.zig");

pub const eligible_radius: i32 = 8;
pub const max_creatures: i32 = 15;
pub const chunks_per_cap: i32 = 256;
pub const max_per_chunk: u32 = 4;
pub const player_clearance: f64 = 24.0;
pub const spawn_clearance_squared: f32 = 576.0;

const pack_attempts: usize = 3;
const placement_attempts: usize = 4;
const pack_spread: i32 = 6;

pub const Kind = enum { sheep, pig, chicken, cow };

const Creature = struct { weight: i32, kind: Kind };

/// `SpawnerAnimals`: sheep, pig, chicken, cow.
const creature_list = [_]Creature{
    .{ .weight = 12, .kind = .sheep },
    .{ .weight = 10, .kind = .pig },
    .{ .weight = 10, .kind = .chicken },
    .{ .weight = 8, .kind = .cow },
};

fn totalWeight() i32 {
    var total: i32 = 0;
    for (creature_list) |entry| total += entry.weight;
    return total;
}

fn pickCreature(rand: *world.JavaRandom) Creature {
    var roll = rand.nextIntBound(totalWeight());
    for (creature_list) |entry| {
        roll -= entry.weight;
        if (roll < 0) return entry;
    }
    return creature_list[0];
}

pub fn populationCap() i32 {
    const eligible_chunks = (eligible_radius * 2 + 1) * (eligible_radius * 2 + 1);
    return @divTrunc(max_creatures * eligible_chunks, chunks_per_cap);
}

fn canSpawnAtLocation(world_map: *const world.World, x: i32, y: i32, z: i32) bool {
    return world_map.getBlock(x, y - 1, z).isOpaqueCube() and
        !world_map.getBlock(x, y, z).isOpaqueCube() and
        !world_map.getBlock(x, y, z).material().isLiquid() and
        !world_map.getBlock(x, y + 1, z).isOpaqueCube();
}

fn playerWithin(player_position: math.Vec3, x: f64, y: f64, z: f64, range: f64) bool {
    const dx = player_position.x - x;
    const dy = player_position.y - y;
    const dz = player_position.z - z;
    return dx * dx + dy * dy + dz * dz < range * range;
}

pub fn performSpawning(
    gpa: std.mem.Allocator,
    entities: *Entities,
    world_map: *const world.World,
    player_position: math.Vec3,
    spawn_point: [3]i32,
    rand: *world.JavaRandom,
) !u32 {
    if (@as(i32, @intCast(entities.animalCount())) > populationCap()) return 0;

    const center_x = math.util.floorDouble(player_position.x / 16.0);
    const center_z = math.util.floorDouble(player_position.z / 16.0);

    var spawned: u32 = 0;
    var offset_x: i32 = -eligible_radius;
    while (offset_x <= eligible_radius) : (offset_x += 1) {
        var offset_z: i32 = -eligible_radius;
        while (offset_z <= eligible_radius) : (offset_z += 1) {
            spawned += try spawnInChunk(
                gpa,
                entities,
                world_map,
                player_position,
                spawn_point,
                rand,
                center_x + offset_x,
                center_z + offset_z,
            );
        }
    }
    return spawned;
}

fn spawnInChunk(
    gpa: std.mem.Allocator,
    entities: *Entities,
    world_map: *const world.World,
    player_position: math.Vec3,
    spawn_point: [3]i32,
    rand: *world.JavaRandom,
    chunk_x: i32,
    chunk_z: i32,
) !u32 {
    const creature = pickCreature(rand);

    const origin_x = chunk_x * world.constants.chunk_width + rand.nextIntBound(world.constants.chunk_width);
    const origin_y = rand.nextIntBound(world.constants.chunk_height);
    const origin_z = chunk_z * world.constants.chunk_width + rand.nextIntBound(world.constants.chunk_width);

    if (world_map.getBlock(origin_x, origin_y, origin_z).isOpaqueCube()) return 0;
    if (world_map.getBlock(origin_x, origin_y, origin_z).material() != .air) return 0;

    var spawned: u32 = 0;
    for (0..pack_attempts) |_| {
        var x = origin_x;
        var y = origin_y;
        var z = origin_z;

        for (0..placement_attempts) |_| {
            x += rand.nextIntBound(pack_spread) - rand.nextIntBound(pack_spread);
            y += rand.nextIntBound(1) - rand.nextIntBound(1);
            z += rand.nextIntBound(pack_spread) - rand.nextIntBound(pack_spread);
            if (!canSpawnAtLocation(world_map, x, y, z)) continue;

            const at_x: f64 = @as(f64, @floatFromInt(x)) + 0.5;
            const at_y: f64 = @floatFromInt(y);
            const at_z: f64 = @as(f64, @floatFromInt(z)) + 0.5;
            if (playerWithin(player_position, at_x, at_y, at_z, player_clearance)) continue;

            const from_spawn_x: f32 = @floatCast(at_x - @as(f64, @floatFromInt(spawn_point[0])));
            const from_spawn_y: f32 = @floatCast(at_y - @as(f64, @floatFromInt(spawn_point[1])));
            const from_spawn_z: f32 = @floatCast(at_z - @as(f64, @floatFromInt(spawn_point[2])));
            const from_spawn = from_spawn_x * from_spawn_x + from_spawn_y * from_spawn_y + from_spawn_z * from_spawn_z;
            if (from_spawn < spawn_clearance_squared) continue;

            // The mob is built first (a sheep rolls its fleece there, a chicken its first clutch),
            // then turned, then asked whether it can stand where it was put.
            const position = math.Vec3.init(at_x, at_y, at_z);
            switch (creature.kind) {
                .pig => {
                    var pig = Pig.spawn(position);
                    pig.animal.faceYaw(rand.nextFloat() * 360.0);
                    if (!pig.animal.canSpawnHere(world_map)) continue;
                    try entities.pigs.append(gpa, pig);
                },
                .sheep => {
                    var sheep = Sheep.spawn(position, rand);
                    sheep.animal.faceYaw(rand.nextFloat() * 360.0);
                    if (!sheep.animal.canSpawnHere(world_map)) continue;
                    try entities.sheep.append(gpa, sheep);
                },
                .cow => {
                    var cow = Cow.spawn(position);
                    cow.animal.faceYaw(rand.nextFloat() * 360.0);
                    if (!cow.animal.canSpawnHere(world_map)) continue;
                    try entities.cows.append(gpa, cow);
                },
                .chicken => {
                    var chicken = Chicken.spawn(position, rand);
                    chicken.animal.faceYaw(rand.nextFloat() * 360.0);
                    if (!chicken.animal.canSpawnHere(world_map)) continue;
                    try entities.chickens.append(gpa, chicken);
                },
            }

            spawned += 1;
            if (spawned >= max_per_chunk) return spawned;
        }
    }

    return spawned;
}

fn grassPlateau(gpa: std.mem.Allocator, from_chunk_x: i32, to_chunk_x: i32, surface_y: u32) !world.World {
    var w = world.World.init(gpa);
    errdefer w.deinit();

    var chunk_x = from_chunk_x;
    while (chunk_x <= to_chunk_x) : (chunk_x += 1) {
        const chunk = try w.createChunk(chunk_x, 0);
        for (0..world.constants.chunk_width) |x| {
            for (0..world.constants.chunk_width) |z| {
                var y: u32 = 0;
                while (y <= surface_y) : (y += 1) {
                    chunk.setBlock(@intCast(x), y, @intCast(z), world.Block.stone);
                }
                chunk.setBlock(@intCast(x), surface_y, @intCast(z), world.Block.grass);
                chunk.setSkyLight(@intCast(x), surface_y + 1, @intCast(z), 15);
            }
        }
    }
    return w;
}

const surface: u32 = 63;

fn spawnUntilFirstAnimal(
    gpa: std.mem.Allocator,
    entities: *Entities,
    world_map: *const world.World,
    player_position: math.Vec3,
    spawn_point: [3]i32,
    rand: *world.JavaRandom,
    rounds: usize,
) !u32 {
    var total: u32 = 0;
    for (0..rounds) |_| {
        total += try performSpawning(gpa, entities, world_map, player_position, spawn_point, rand);
        if (total > 0) break;
    }
    return total;
}

fn expectStandingOnGrass(world_map: *const world.World, animal: Animal) !void {
    try std.testing.expectApproxEqAbs(@as(f64, surface + 1), animal.base.position.y, 1.0e-9);
    try std.testing.expectEqual(world.Block.grass, world_map.getBlock(
        math.util.floorDouble(animal.base.position.x),
        surface,
        math.util.floorDouble(animal.base.position.z),
    ));
}

test "animals spawn onto lit grass away from the player" {
    const gpa = std.testing.allocator;
    var w = try grassPlateau(gpa, 3, 5, surface);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(9);
    const player = math.Vec3.init(0, surface + 1, 0);
    const total = try spawnUntilFirstAnimal(gpa, &entities, &w, player, .{ 0, 64, 0 }, &rand, 4000);

    try std.testing.expect(total > 0);
    for (entities.pigs.items) |pig| try expectStandingOnGrass(&w, pig.animal);
    for (entities.sheep.items) |sheep| try expectStandingOnGrass(&w, sheep.animal);
    for (entities.cows.items) |cow| try expectStandingOnGrass(&w, cow.animal);
    for (entities.chickens.items) |chicken| try expectStandingOnGrass(&w, chicken.animal);
}

test "every kind we can make finds its way into a grassy world" {
    const gpa = std.testing.allocator;
    var w = try grassPlateau(gpa, 3, 5, surface);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(9);
    const player = math.Vec3.init(0, surface + 1, 0);
    var seen = [_]bool{false} ** std.enums.values(Kind).len;

    for (0..4000) |_| {
        _ = try performSpawning(gpa, &entities, &w, player, .{ 0, 64, 0 }, &rand);

        // Empty the fields between rounds, so the population cap never ends the run early.
        inline for (.{ &entities.pigs, &entities.sheep, &entities.chickens, &entities.cows }, 0..) |herd, kind| {
            if (herd.items.len > 0) seen[kind] = true;
            for (herd.items) |*animal| animal.deinit(gpa);
            herd.clearRetainingCapacity();
        }

        if (std.mem.allEqual(bool, &seen, true)) break;
    }

    for (seen) |kind_seen| try std.testing.expect(kind_seen);
}

test "nothing spawns on bare stone" {
    const gpa = std.testing.allocator;
    var w = try grassPlateau(gpa, 3, 5, surface);
    defer w.deinit();

    for (3..6) |chunk_x| {
        const chunk = w.getChunk(@intCast(chunk_x), 0).?;
        for (0..world.constants.chunk_width) |x| {
            for (0..world.constants.chunk_width) |z| {
                chunk.setBlock(@intCast(x), surface, @intCast(z), world.Block.stone);
            }
        }
    }

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(9);
    const player = math.Vec3.init(0, surface + 1, 0);
    const total = try spawnUntilFirstAnimal(gpa, &entities, &w, player, .{ 0, 64, 0 }, &rand, 4000);

    try std.testing.expectEqual(@as(u32, 0), total);
}

test "nothing spawns in the dark" {
    const gpa = std.testing.allocator;
    var w = try grassPlateau(gpa, 3, 5, surface);
    defer w.deinit();

    for (3..6) |chunk_x| {
        const chunk = w.getChunk(@intCast(chunk_x), 0).?;
        for (0..world.constants.chunk_width) |x| {
            for (0..world.constants.chunk_width) |z| {
                chunk.setSkyLight(@intCast(x), surface + 1, @intCast(z), 0);
            }
        }
    }

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(9);
    const player = math.Vec3.init(0, surface + 1, 0);
    const total = try spawnUntilFirstAnimal(gpa, &entities, &w, player, .{ 0, 64, 0 }, &rand, 4000);

    try std.testing.expectEqual(@as(u32, 0), total);
}

test "nothing spawns within twenty-four blocks of the player" {
    const gpa = std.testing.allocator;
    var w = try grassPlateau(gpa, 0, 0, surface);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(9);
    const player = math.Vec3.init(8, surface + 1, 8);
    const total = try spawnUntilFirstAnimal(gpa, &entities, &w, player, .{ 0, 0, 0 }, &rand, 4000);

    try std.testing.expectEqual(@as(u32, 0), total);
}

test "nothing spawns within twenty-four blocks of the world spawn point" {
    const gpa = std.testing.allocator;
    var w = try grassPlateau(gpa, 3, 5, surface);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(9);
    const player = math.Vec3.init(0, surface + 1, 0);
    const spawn_point = [3]i32{ 64, @intCast(surface + 1), 8 };
    _ = try spawnUntilFirstAnimal(gpa, &entities, &w, player, spawn_point, &rand, 4000);

    for (entities.pigs.items) |pig| try expectClearOf(spawn_point, pig.animal);
    for (entities.sheep.items) |sheep| try expectClearOf(spawn_point, sheep.animal);
    for (entities.cows.items) |cow| try expectClearOf(spawn_point, cow.animal);
    for (entities.chickens.items) |chicken| try expectClearOf(spawn_point, chicken.animal);
}

fn expectClearOf(spawn_point: [3]i32, animal: Animal) !void {
    const dx = animal.base.position.x - @as(f64, @floatFromInt(spawn_point[0]));
    const dy = animal.base.position.y - @as(f64, @floatFromInt(spawn_point[1]));
    const dz = animal.base.position.z - @as(f64, @floatFromInt(spawn_point[2]));
    try std.testing.expect(dx * dx + dy * dy + dz * dz >= spawn_clearance_squared);
}

test "spawning stops once the population cap is reached" {
    const gpa = std.testing.allocator;
    var w = try grassPlateau(gpa, 3, 5, surface);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    for (0..@intCast(populationCap() + 1)) |_| {
        try entities.spawnPig(gpa, math.Vec3.init(64, surface + 1, 8));
    }

    var rand = world.JavaRandom.init(9);
    const player = math.Vec3.init(0, surface + 1, 0);
    const before = entities.pigs.items.len;
    const total = try spawnUntilFirstAnimal(gpa, &entities, &w, player, .{ 0, 64, 0 }, &rand, 500);

    try std.testing.expectEqual(@as(u32, 0), total);
    try std.testing.expectEqual(before, entities.pigs.items.len);
}

test "the population cap follows the vanilla per-chunk allowance" {
    try std.testing.expectEqual(@as(i32, 16), populationCap());
}

test "the biome's creature list picks each kind by its own weight" {
    var rand = world.JavaRandom.init(4);
    var rolls = [_]u32{0} ** std.enums.values(Kind).len;
    const total = 4000;
    for (0..total) |_| {
        rolls[@intFromEnum(pickCreature(&rand).kind)] += 1;
    }

    // Of the list's 40 weight: sheep 12, pig 10, chicken 10, cow 8.
    const expected = [_]u32{ 30, 25, 25, 20 };
    for (expected, 0..) |percent, kind| {
        const share = rolls[kind] * 100 / total;
        try std.testing.expect(share > percent - 4 and share < percent + 4);
    }

    try std.testing.expect(rolls[@intFromEnum(Kind.sheep)] > rolls[@intFromEnum(Kind.pig)]);
    try std.testing.expect(rolls[@intFromEnum(Kind.pig)] > rolls[@intFromEnum(Kind.cow)]);
}
