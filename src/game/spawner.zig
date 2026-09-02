const std = @import("std");

const math = @import("math");
const world = @import("world");
const BlockPos = world.BlockPos;

const Entities = @import("Entities.zig");
const Animal = @import("entity/Animal.zig");
const Chicken = @import("entity/Chicken.zig");
const Cow = @import("entity/Cow.zig");
const Creeper = @import("entity/Creeper.zig");
const Ghast = @import("entity/Ghast.zig");
const Pig = @import("entity/Pig.zig");
const PigZombie = @import("entity/PigZombie.zig");
const Sheep = @import("entity/Sheep.zig");
const Skeleton = @import("entity/Skeleton.zig");
const Slime = @import("entity/Slime.zig");
const Spider = @import("entity/Spider.zig");
const Squid = @import("entity/Squid.zig");
const Wolf = @import("entity/Wolf.zig");
const Zombie = @import("entity/Zombie.zig");
const mob = @import("mob.zig");
const Player = @import("Player.zig");

pub const eligible_radius: i32 = 8;
pub const max_creatures: i32 = 15;
pub const max_monsters: i32 = 70;
pub const max_water_creatures: i32 = 5;
pub const chunks_per_cap: i32 = 256;
pub const max_per_chunk: u32 = 4;
pub const player_clearance: f64 = 24.0;
pub const spawn_clearance_squared: f32 = 576.0;

const pack_attempts: usize = 3;
const placement_attempts: usize = 4;
const pack_spread: i32 = 6;
const jockey_odds: i32 = 100;

pub const Category = enum {
    monster,
    creature,
    water_creature,

    pub fn allowancePerChunk(self: Category) i32 {
        return switch (self) {
            .monster => max_monsters,
            .creature => max_creatures,
            .water_creature => max_water_creatures,
        };
    }

    pub fn material(self: Category) world.Material {
        return switch (self) {
            .monster, .creature => .air,
            .water_creature => .water,
        };
    }

    pub fn spawnsUnder(self: Category, difficulty: world.Difficulty) bool {
        return self != .monster or difficulty.atLeast(.easy);
    }
};

pub const Kind = enum {
    sheep,
    pig,
    chicken,
    cow,
    wolf,

    pub fn maxPerChunk(self: Kind) u32 {
        return switch (self) {
            .wolf => Wolf.max_spawned_in_chunk,
            else => max_per_chunk,
        };
    }
};

pub const Monster = enum {
    slime,
    creeper,
    skeleton,
    spider,
    zombie,
    ghast,
    pig_zombie,

    pub fn maxPerChunk(self: Monster) u32 {
        return switch (self) {
            .ghast => Ghast.max_spawned_in_chunk,
            .slime, .creeper, .skeleton, .spider, .zombie, .pig_zombie => max_per_chunk,
        };
    }
};

pub const Swimmer = enum {
    squid,

    pub fn maxPerChunk(_: Swimmer) u32 {
        return max_per_chunk;
    }
};

const Creature = struct { weight: i32, kind: Kind };
const Horror = struct { weight: i32, monster: Monster };
const Shoal = struct { weight: i32, swimmer: Swimmer };
const Chosen = union(Category) { monster: Monster, creature: Kind, water_creature: Swimmer };

const base_creatures = [_]Creature{
    .{ .weight = 12, .kind = .sheep },
    .{ .weight = 10, .kind = .pig },
    .{ .weight = 10, .kind = .chicken },
    .{ .weight = 8, .kind = .cow },
};

const wooded_creatures = base_creatures ++ [_]Creature{
    .{ .weight = 2, .kind = .wolf },
};

const overworld_monsters = [_]Horror{
    .{ .weight = 10, .monster = .spider },
    .{ .weight = 10, .monster = .zombie },
    .{ .weight = 10, .monster = .skeleton },
    .{ .weight = 10, .monster = .creeper },
    .{ .weight = 10, .monster = .slime },
};

const water_creatures = [_]Shoal{
    .{ .weight = 10, .swimmer = .squid },
};

const nether_monsters = [_]Horror{
    .{ .weight = 10, .monster = .ghast },
    .{ .weight = 10, .monster = .pig_zombie },
};

pub fn creatureList(in_biome: world.biome.Biome) []const Creature {
    return switch (in_biome) {
        .forest, .taiga => &wooded_creatures,
        else => &base_creatures,
    };
}

pub fn monsterList(dimension: world.Dimension) []const Horror {
    return switch (dimension) {
        .overworld => &overworld_monsters,
        .nether => &nether_monsters,
    };
}

fn mountJockey(
    gpa: std.mem.Allocator,
    entities: *Entities,
    rand: *world.JavaRandom,
    mount: Animal.Entity.Id,
    at: math.Vec3,
    yaw: f32,
) !void {
    if (rand.nextIntBound(jockey_odds) != 0) return;

    var skeleton = Skeleton.spawn(at);
    skeleton.animal.faceYaw(yaw);
    skeleton.animal.riding = mount;
    try entities.adopt(gpa, mob.skeleton, skeleton);
}

fn pickWeighted(comptime T: type, list: []const T, rand: *world.JavaRandom) T {
    var total: i32 = 0;
    for (list) |entry| total += entry.weight;

    var roll = rand.nextIntBound(total);
    for (list) |entry| {
        roll -= entry.weight;
        if (roll < 0) return entry;
    }
    return list[0];
}

pub fn populationCap(category: Category, eligible_chunks: usize) i32 {
    return @divTrunc(category.allowancePerChunk() * @as(i32, @intCast(eligible_chunks)), chunks_per_cap);
}

pub fn chunksAroundOnePlayer() usize {
    return (eligible_radius * 2 + 1) * (eligible_radius * 2 + 1);
}

fn liveCount(entities: *const Entities, category: Category) i32 {
    return switch (category) {
        .monster => @intCast(entities.countOf(mob.slime) + entities.countOf(mob.ghast) +
            entities.countOf(mob.creeper) + entities.countOf(mob.skeleton) +
            entities.countOf(mob.spider) + entities.countOf(mob.zombie) +
            entities.countOf(mob.pig_zombie)),
        .creature => @intCast(entities.animalCount()),
        .water_creature => @intCast(entities.countOf(mob.squid)),
    };
}

fn canSpawnAtLocation(category: Category, world_map: *const world.World, pos: BlockPos) bool {
    if (category.material() == .water) {
        return world_map.getBlock(pos).material().isLiquid() and
            !world_map.getBlock(pos.offset(0, 1, 0)).isOpaqueCube();
    }
    return world_map.getBlock(pos.offset(0, -1, 0)).isOpaqueCube() and
        !world_map.getBlock(pos).isOpaqueCube() and
        !world_map.getBlock(pos).material().isLiquid() and
        !world_map.getBlock(pos.offset(0, 1, 0)).isOpaqueCube();
}

fn anyPlayerWithin(players: []const Animal.PlayerView, x: f64, y: f64, z: f64, range: f64) bool {
    for (players) |view| {
        const dx = view.position.x - x;
        const dy = view.position.y - y;
        const dz = view.position.z - z;
        if (dx * dx + dy * dy + dz * dz < range * range) return true;
    }
    return false;
}

fn collectEligibleChunks(
    gpa: std.mem.Allocator,
    players: []const Animal.PlayerView,
    out: *std.ArrayList(world.World.ChunkCoord),
) !void {
    var seen: std.AutoHashMapUnmanaged(world.World.ChunkCoord, void) = .{};
    defer seen.deinit(gpa);

    for (players) |view| {
        const center_x = math.util.floorDouble(view.position.x / 16.0);
        const center_z = math.util.floorDouble(view.position.z / 16.0);

        var offset_x: i32 = -eligible_radius;
        while (offset_x <= eligible_radius) : (offset_x += 1) {
            var offset_z: i32 = -eligible_radius;
            while (offset_z <= eligible_radius) : (offset_z += 1) {
                const coord: world.World.ChunkCoord = .{ .x = center_x + offset_x, .z = center_z + offset_z };
                if ((try seen.getOrPut(gpa, coord)).found_existing) continue;
                try out.append(gpa, coord);
            }
        }
    }
}

pub fn performSpawning(
    gpa: std.mem.Allocator,
    entities: *Entities,
    world_map: *const world.World,
    players: []const Animal.PlayerView,
    spawn_point: [3]i32,
    dimension: world.Dimension,
    world_seed: i64,
    rand: *world.JavaRandom,
) !u32 {
    if (players.len == 0) return 0;

    var eligible: std.ArrayList(world.World.ChunkCoord) = .empty;
    defer eligible.deinit(gpa);
    try collectEligibleChunks(gpa, players, &eligible);

    var spawned: u32 = 0;
    for (std.enums.values(Category)) |category| {
        if (!category.spawnsUnder(world_map.difficulty)) continue;
        if (liveCount(entities, category) > populationCap(category, eligible.items.len)) continue;

        for (eligible.items) |coord| {
            spawned += try spawnInChunk(
                gpa,
                entities,
                world_map,
                players,
                spawn_point,
                dimension,
                world_seed,
                rand,
                category,
                coord.x,
                coord.z,
            );
        }
    }
    return spawned;
}

fn spawnInChunk(
    gpa: std.mem.Allocator,
    entities: *Entities,
    world_map: *const world.World,
    players: []const Animal.PlayerView,
    spawn_point: [3]i32,
    dimension: world.Dimension,
    world_seed: i64,
    rand: *world.JavaRandom,
    category: Category,
    chunk_x: i32,
    chunk_z: i32,
) !u32 {
    const chosen: Chosen = switch (category) {
        .creature => .{ .creature = pickWeighted(
            Creature,
            creatureList(world_map.biomeAt(chunk_x * world.Chunk.width, chunk_z * world.Chunk.width)),
            rand,
        ).kind },
        .monster => .{ .monster = pickWeighted(Horror, monsterList(dimension), rand).monster },
        .water_creature => .{ .water_creature = pickWeighted(Shoal, &water_creatures, rand).swimmer },
    };

    const origin_x = chunk_x * world.Chunk.width + rand.nextIntBound(world.Chunk.width);
    const origin_y = rand.nextIntBound(world.Chunk.height);
    const origin_z = chunk_z * world.Chunk.width + rand.nextIntBound(world.Chunk.width);

    if (world_map.getBlock(.init(origin_x, origin_y, origin_z)).isOpaqueCube()) return 0;
    if (world_map.getBlock(.init(origin_x, origin_y, origin_z)).material() != category.material()) return 0;

    var spawned: u32 = 0;
    for (0..pack_attempts) |_| {
        var x = origin_x;
        var y = origin_y;
        var z = origin_z;

        for (0..placement_attempts) |_| {
            x += rand.nextIntBound(pack_spread) - rand.nextIntBound(pack_spread);
            y += rand.nextIntBound(1) - rand.nextIntBound(1);
            z += rand.nextIntBound(pack_spread) - rand.nextIntBound(pack_spread);
            if (!canSpawnAtLocation(category, world_map, .init(x, y, z))) continue;

            const at_x: f64 = @as(f64, @floatFromInt(x)) + 0.5;
            const at_y: f64 = @floatFromInt(y);
            const at_z: f64 = @as(f64, @floatFromInt(z)) + 0.5;
            if (anyPlayerWithin(players, at_x, at_y, at_z, player_clearance)) continue;

            const from_spawn_x: f32 = @floatCast(at_x - @as(f64, @floatFromInt(spawn_point[0])));
            const from_spawn_y: f32 = @floatCast(at_y - @as(f64, @floatFromInt(spawn_point[1])));
            const from_spawn_z: f32 = @floatCast(at_z - @as(f64, @floatFromInt(spawn_point[2])));
            const from_spawn = from_spawn_x * from_spawn_x + from_spawn_y * from_spawn_y + from_spawn_z * from_spawn_z;
            if (from_spawn < spawn_clearance_squared) continue;

            // The mob is built first (a chicken rolls its first clutch there), then turned,
            // then asked whether it can stand where it was put. What vanilla leaves until
            // after the mob has joined — a sheep's fleece, a spider's jockey — waits too.
            const position = math.Vec3.init(at_x, at_y, at_z);
            switch (chosen) {
                .monster => |monster| {
                    switch (monster) {
                        .slime => {
                            var slime = Slime.spawn(position, rand);
                            slime.animal.faceYaw(rand.nextFloat() * 360.0);
                            if (!slime.canSpawnHere(world_map, world_seed, rand)) continue;
                            try entities.adopt(gpa, mob.slime, slime);
                        },
                        .spider => {
                            var spider = Spider.spawn(position);
                            spider.animal.faceYaw(rand.nextFloat() * 360.0);
                            if (!spider.canSpawnHere(world_map, rand)) continue;
                            const mount = entities.takeId();
                            try entities.adoptAs(gpa, mob.spider, spider, mount);
                            try mountJockey(gpa, entities, rand, mount, position, spider.animal.yaw);
                        },
                        .skeleton => {
                            var skeleton = Skeleton.spawn(position);
                            skeleton.animal.faceYaw(rand.nextFloat() * 360.0);
                            if (!skeleton.canSpawnHere(world_map, rand)) continue;
                            try entities.adopt(gpa, mob.skeleton, skeleton);
                        },
                        .creeper => {
                            var creeper = Creeper.spawn(position);
                            creeper.animal.faceYaw(rand.nextFloat() * 360.0);
                            if (!creeper.canSpawnHere(world_map, rand)) continue;
                            try entities.adopt(gpa, mob.creeper, creeper);
                        },
                        .zombie => {
                            var zombie = Zombie.spawn(position);
                            zombie.animal.faceYaw(rand.nextFloat() * 360.0);
                            if (!zombie.canSpawnHere(world_map, rand)) continue;
                            try entities.adopt(gpa, mob.zombie, zombie);
                        },
                        .ghast => {
                            var ghast = Ghast.spawn(position);
                            ghast.animal.faceYaw(rand.nextFloat() * 360.0);
                            if (!ghast.canSpawnHere(world_map, rand)) continue;
                            try entities.adopt(gpa, mob.ghast, ghast);
                        },
                        .pig_zombie => {
                            var pig_zombie = PigZombie.spawn(position);
                            pig_zombie.animal.faceYaw(rand.nextFloat() * 360.0);
                            if (!pig_zombie.canSpawnHere(world_map)) continue;
                            try entities.adopt(gpa, mob.pig_zombie, pig_zombie);
                        },
                    }

                    spawned += 1;
                    if (spawned >= monster.maxPerChunk()) return spawned;
                },
                .creature => |kind| {
                    switch (kind) {
                        .pig => {
                            var pig = Pig.spawn(position);
                            pig.animal.faceYaw(rand.nextFloat() * 360.0);
                            if (!pig.animal.canSpawnHere(world_map)) continue;
                            try entities.adopt(gpa, mob.pig, pig);
                        },
                        .sheep => {
                            var sheep = Sheep.init(position);
                            sheep.animal.faceYaw(rand.nextFloat() * 360.0);
                            if (!sheep.animal.canSpawnHere(world_map)) continue;
                            sheep.fleece_color = Sheep.randomFleeceColor(rand);
                            try entities.adopt(gpa, mob.sheep, sheep);
                        },
                        .cow => {
                            var cow = Cow.spawn(position);
                            cow.animal.faceYaw(rand.nextFloat() * 360.0);
                            if (!cow.animal.canSpawnHere(world_map)) continue;
                            try entities.adopt(gpa, mob.cow, cow);
                        },
                        .chicken => {
                            var chicken = Chicken.spawn(position, rand);
                            chicken.animal.faceYaw(rand.nextFloat() * 360.0);
                            if (!chicken.animal.canSpawnHere(world_map)) continue;
                            try entities.adopt(gpa, mob.chicken, chicken);
                        },
                        .wolf => {
                            var wolf = Wolf.spawn(position);
                            wolf.animal.faceYaw(rand.nextFloat() * 360.0);
                            if (!wolf.animal.canSpawnHere(world_map)) continue;
                            try entities.adopt(gpa, mob.wolf, wolf);
                        },
                    }

                    spawned += 1;
                    if (spawned >= kind.maxPerChunk()) return spawned;
                },
                .water_creature => |swimmer| {
                    switch (swimmer) {
                        .squid => {
                            var squid = Squid.spawn(position, rand);
                            squid.animal.faceYaw(rand.nextFloat() * 360.0);
                            if (!squid.canSpawnHere(world_map)) continue;
                            try entities.adopt(gpa, mob.squid, squid);
                        },
                    }

                    spawned += 1;
                    if (spawned >= swimmer.maxPerChunk()) return spawned;
                },
            }
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
        for (0..world.Chunk.width) |x| {
            for (0..world.Chunk.width) |z| {
                var y: u32 = 0;
                while (y <= surface_y) : (y += 1) {
                    chunk.setBlock(@intCast(x), y, @intCast(z), .stone);
                }
                chunk.setBlock(@intCast(x), surface_y, @intCast(z), .grass);
                chunk.setSkyLight(@intCast(x), surface_y + 1, @intCast(z), 15);
            }
        }
    }
    return w;
}

fn stoneCavern(gpa: std.mem.Allocator, from_chunk_x: i32, to_chunk_x: i32, cavern_y: u32) !world.World {
    var w = world.World.init(gpa);
    errdefer w.deinit();

    var chunk_x = from_chunk_x;
    while (chunk_x <= to_chunk_x) : (chunk_x += 1) {
        const chunk = try w.createChunk(chunk_x, 0);
        for (0..world.Chunk.width) |x| {
            for (0..world.Chunk.width) |z| {
                var y: u32 = 0;
                while (y <= cavern_y + 4) : (y += 1) {
                    const solid = y < cavern_y or y > cavern_y + 1;
                    if (solid) chunk.setBlock(@intCast(x), y, @intCast(z), .stone);
                }
            }
        }
    }
    return w;
}

fn openSea(gpa: std.mem.Allocator, from_chunk_x: i32, to_chunk_x: i32, sea_level: u32) !world.World {
    var w = world.World.init(gpa);
    errdefer w.deinit();

    var chunk_x = from_chunk_x;
    while (chunk_x <= to_chunk_x) : (chunk_x += 1) {
        const chunk = try w.createChunk(chunk_x, 0);
        for (0..world.Chunk.width) |x| {
            for (0..world.Chunk.width) |z| {
                chunk.setBlock(@intCast(x), 0, @intCast(z), .stone);
                var y: u32 = 1;
                while (y <= sea_level) : (y += 1) {
                    chunk.setBlock(@intCast(x), y, @intCast(z), .stationary_water);
                }
            }
        }
    }
    return w;
}

fn stampClimate(w: *world.World, from_chunk_x: i32, to_chunk_x: i32, temperature: f32, humidity: f32) void {
    var chunk_x = from_chunk_x;
    while (chunk_x <= to_chunk_x) : (chunk_x += 1) {
        const chunk = w.getChunk(chunk_x, 0).?;
        for (0..world.Chunk.width) |x| {
            for (0..world.Chunk.width) |z| {
                chunk.setClimate(@intCast(x), @intCast(z), temperature, humidity);
            }
        }
    }
}

fn soloView(position: math.Vec3) [1]Animal.PlayerView {
    return .{.{ .id = 1, .position = position, .eye_height = 1.62, .alive = true }};
}

const surface: u32 = 63;
const cavern: u32 = 8;
const test_seed: i64 = 9;

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
        total += try performSpawning(gpa, entities, world_map, &soloView(player_position), spawn_point, .overworld, test_seed, rand);
        if (total > 0) break;
    }
    return total;
}

fn expectStandingOnGrass(world_map: *const world.World, animal: Animal) !void {
    try std.testing.expectApproxEqAbs(@as(f64, surface + 1), animal.base.position.y, 1.0e-9);
    try std.testing.expectEqual(.grass, world_map.getBlock(
        .init(math.util.floorDouble(animal.base.position.x), surface, math.util.floorDouble(animal.base.position.z)),
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
    var walk_pigs = entities.of(Pig, mob.pig);
    while (walk_pigs.next()) |pig| try expectStandingOnGrass(&w, pig.animal);
    var walk_sheep = entities.of(Sheep, mob.sheep);
    while (walk_sheep.next()) |sheep| try expectStandingOnGrass(&w, sheep.animal);
    var walk_cows = entities.of(Cow, mob.cow);
    while (walk_cows.next()) |cow| try expectStandingOnGrass(&w, cow.animal);
    var walk_chickens = entities.of(Chicken, mob.chicken);
    while (walk_chickens.next()) |chicken| try expectStandingOnGrass(&w, chicken.animal);
}

test "every kind we can make finds its way into a grassy world" {
    const gpa = std.testing.allocator;
    var w = try grassPlateau(gpa, 3, 5, surface);
    defer w.deinit();
    stampClimate(&w, 3, 5, 0.4, 0.9);
    try std.testing.expectEqual(world.biome.Biome.taiga, w.biomeAt(3 * world.Chunk.width, 0));

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(9);
    const player = math.Vec3.init(0, surface + 1, 0);
    var seen = [_]bool{false} ** std.enums.values(Kind).len;

    for (0..4000) |_| {
        _ = try performSpawning(gpa, &entities, &w, &soloView(player), .{ 0, 64, 0 }, .overworld, test_seed, &rand);

        // Empty the fields between rounds, so the population cap never ends the run early.
        inline for (.{ mob.sheep, mob.pig, mob.chicken, mob.cow, mob.wolf }, 0..) |type_id, kind| {
            if (entities.countOf(type_id) > 0) seen[kind] = true;
        }
        for (entities.mobs.items) |entry| mob.get(entry.type_id).destroy(entry.animal, gpa);
        entities.mobs.clearRetainingCapacity();

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
        for (0..world.Chunk.width) |x| {
            for (0..world.Chunk.width) |z| {
                chunk.setBlock(@intCast(x), surface, @intCast(z), .stone);
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
        for (0..world.Chunk.width) |x| {
            for (0..world.Chunk.width) |z| {
                chunk.setSkyLight(@intCast(x), surface + 1, @intCast(z), 0);
            }
        }
    }

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(9);
    const player = math.Vec3.init(0, surface + 1, 0);
    _ = try spawnUntilFirstAnimal(gpa, &entities, &w, player, .{ 0, 64, 0 }, &rand, 4000);

    // The dark is the monsters' to have; it is the animals that need the light.
    try std.testing.expectEqual(@as(usize, 0), entities.animalCount());
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

    var clear_pigs = entities.of(Pig, mob.pig);
    while (clear_pigs.next()) |pig| try expectClearOf(spawn_point, pig.animal);
    var clear_sheep = entities.of(Sheep, mob.sheep);
    while (clear_sheep.next()) |sheep| try expectClearOf(spawn_point, sheep.animal);
    var clear_cows = entities.of(Cow, mob.cow);
    while (clear_cows.next()) |cow| try expectClearOf(spawn_point, cow.animal);
    var clear_chickens = entities.of(Chicken, mob.chicken);
    while (clear_chickens.next()) |chicken| try expectClearOf(spawn_point, chicken.animal);
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

    for (0..@intCast(populationCap(.creature, chunksAroundOnePlayer()) + 1)) |_| {
        try entities.spawnPig(gpa, math.Vec3.init(64, surface + 1, 8));
    }

    var rand = world.JavaRandom.init(9);
    const player = math.Vec3.init(0, surface + 1, 0);
    const before = entities.countOf(mob.pig);
    const total = try spawnUntilFirstAnimal(gpa, &entities, &w, player, .{ 0, 64, 0 }, &rand, 500);

    try std.testing.expectEqual(@as(u32, 0), total);
    try std.testing.expectEqual(before, entities.countOf(mob.pig));
}

test "squid spawn into water, and only into water" {
    const gpa = std.testing.allocator;
    var w = try openSea(gpa, 3, 5, surface);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(9);
    const player = math.Vec3.init(0, surface + 1, 0);

    for (0..4000) |_| {
        _ = try performSpawning(gpa, &entities, &w, &soloView(player), .{ 0, 64, 0 }, .overworld, test_seed, &rand);
        if (entities.countOf(mob.squid) > 0) break;
    }

    try std.testing.expect(entities.countOf(mob.squid) > 0);
    var shoal = entities.of(Squid, mob.squid);
    while (shoal.next()) |squid| {
        const at = squid.animal.base.position;
        try std.testing.expectEqual(.stationary_water, w.getBlock(
            .init(math.util.floorDouble(at.x), math.util.floorDouble(at.y), math.util.floorDouble(at.z)),
        ));
    }
}

test "the water creature cap is its own, not the land animals'" {
    const gpa = std.testing.allocator;
    var w = try openSea(gpa, 3, 5, surface);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(1);
    for (0..@intCast(populationCap(.water_creature, chunksAroundOnePlayer()) + 1)) |_| {
        try entities.spawnSquid(gpa, math.Vec3.init(64, surface, 8), &rand);
    }

    const before = entities.countOf(mob.squid);
    const player = math.Vec3.init(0, surface + 1, 0);
    for (0..200) |_| {
        _ = try performSpawning(gpa, &entities, &w, &soloView(player), .{ 0, 64, 0 }, .overworld, test_seed, &rand);
    }

    try std.testing.expectEqual(before, entities.countOf(mob.squid));
}

test "slimes spawn in caverns down in the bottom sixteen layers" {
    const gpa = std.testing.allocator;
    var w = try stoneCavern(gpa, 2, 5, cavern);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(9);
    const player = math.Vec3.init(0, cavern, 0);

    // The other monsters are swept between rounds: left in place they reach the
    // population cap first and the monster pass stops rolling for slimes at all.
    for (0..8000) |_| {
        _ = try performSpawning(gpa, &entities, &w, &soloView(player), .{ 0, 64, 0 }, .overworld, test_seed, &rand);
        if (entities.countOf(mob.slime) > 0) break;
        while (entities.mobs.items.len > 0) {
            _ = entities.removeMob(gpa, entities.mobs.items[0].animal.base.id);
        }
    }

    try std.testing.expect(entities.countOf(mob.slime) > 0);
    var walk_slimes = entities.of(Slime, mob.slime);
    while (walk_slimes.next()) |slime| {
        const at = slime.animal.base.position;
        try std.testing.expect(at.y < Slime.spawn_ceiling);
        try std.testing.expectEqual(.stone, w.getBlock(
            .init(math.util.floorDouble(at.x), math.util.floorDouble(at.y) - 1, math.util.floorDouble(at.z)),
        ));
        try std.testing.expect(slime.size == 1 or slime.size == 2 or slime.size == 4);
    }
    try std.testing.expectEqual(@as(usize, 0), entities.animalCount());
}

test "zombies spawn in the overworld's dark caverns, and never in the daylight" {
    const gpa = std.testing.allocator;
    var w = try stoneCavern(gpa, 2, 5, cavern);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(9);
    const player = math.Vec3.init(0, cavern, 0);

    for (0..8000) |_| {
        _ = try performSpawning(gpa, &entities, &w, &soloView(player), .{ 0, 64, 0 }, .overworld, test_seed, &rand);
        if (entities.countOf(mob.zombie) > 0 and entities.countOf(mob.creeper) > 0 and
            entities.countOf(mob.skeleton) > 0 and entities.countOf(mob.spider) > 0) break;
    }

    try std.testing.expect(entities.countOf(mob.zombie) > 0);
    try std.testing.expect(entities.countOf(mob.creeper) > 0);
    try std.testing.expect(entities.countOf(mob.skeleton) > 0);
    try std.testing.expect(entities.countOf(mob.spider) > 0);
    try std.testing.expectEqual(@as(usize, 0), entities.countOf(mob.pig_zombie));
    try std.testing.expectEqual(@as(usize, 0), entities.countOf(mob.ghast));
    try std.testing.expectEqual(@as(usize, 0), entities.animalCount());

    var shamblers = entities.of(Zombie, mob.zombie);
    while (shamblers.next()) |zombie| {
        const at = zombie.animal.base.position;
        try std.testing.expectEqual(.stone, w.getBlock(
            .init(math.util.floorDouble(at.x), math.util.floorDouble(at.y) - 1, math.util.floorDouble(at.z)),
        ));
    }
}

test "a lit overworld surface keeps the zombies out" {
    const gpa = std.testing.allocator;
    var w = try grassPlateau(gpa, 3, 5, surface);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(9);
    const player = math.Vec3.init(0, surface + 1, 0);

    for (0..4000) |_| {
        _ = try performSpawning(gpa, &entities, &w, &soloView(player), .{ 0, 64, 0 }, .overworld, test_seed, &rand);
    }

    try std.testing.expectEqual(@as(usize, 0), entities.countOf(mob.zombie));
    try std.testing.expectEqual(@as(usize, 0), entities.countOf(mob.creeper));
    try std.testing.expectEqual(@as(usize, 0), entities.countOf(mob.skeleton));
    try std.testing.expectEqual(@as(usize, 0), entities.countOf(mob.spider));
}

test "the nether fills its caverns with pig zombies as well as ghasts" {
    const gpa = std.testing.allocator;
    var w = try stoneCavern(gpa, 2, 5, cavern);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(9);
    const player = math.Vec3.init(0, cavern, 0);

    for (0..8000) |_| {
        _ = try performSpawning(gpa, &entities, &w, &soloView(player), .{ 0, 64, 0 }, .nether, test_seed, &rand);
        if (entities.countOf(mob.pig_zombie) > 0 and entities.countOf(mob.ghast) > 0) break;
    }

    try std.testing.expect(entities.countOf(mob.pig_zombie) > 0);
    try std.testing.expect(entities.countOf(mob.ghast) > 0);
    try std.testing.expectEqual(@as(usize, 0), entities.countOf(mob.slime));
    try std.testing.expectEqual(@as(usize, 0), entities.animalCount());

    var horde = entities.of(PigZombie, mob.pig_zombie);
    while (horde.next()) |pig_zombie| {
        const at = pig_zombie.animal.base.position;
        try std.testing.expectEqual(.stone, w.getBlock(
            .init(math.util.floorDouble(at.x), math.util.floorDouble(at.y) - 1, math.util.floorDouble(at.z)),
        ));
        try std.testing.expectEqual(@as(i32, 0), pig_zombie.anger_level);
    }
}

test "the overworld's monster list never rolls a nether horror" {
    var rand = world.JavaRandom.init(4);
    for (0..2000) |_| {
        switch (pickWeighted(Horror, monsterList(.overworld), &rand).monster) {
            .slime, .creeper, .skeleton, .spider, .zombie => {},
            .ghast, .pig_zombie => return error.TestUnexpectedResult,
        }
    }

    var ghasts: u32 = 0;
    var pig_zombies: u32 = 0;
    const total = 4000;
    for (0..total) |_| {
        switch (pickWeighted(Horror, monsterList(.nether), &rand).monster) {
            .ghast => ghasts += 1,
            .pig_zombie => pig_zombies += 1,
            .slime, .creeper, .skeleton, .spider, .zombie => unreachable,
        }
    }

    // BiomeGenHell weights the ghast and the pig zombie ten apiece.
    try std.testing.expect(ghasts * 100 / total > 45 and ghasts * 100 / total < 55);
    try std.testing.expectEqual(total, ghasts + pig_zombies);
}

test "slimes never spawn in a cavern above the sixteenth layer" {
    const gpa = std.testing.allocator;
    var w = try stoneCavern(gpa, 2, 5, 40);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(9);
    const player = math.Vec3.init(0, 40, 0);

    for (0..8000) |_| {
        _ = try performSpawning(gpa, &entities, &w, &soloView(player), .{ 0, 64, 0 }, .overworld, test_seed, &rand);
    }

    try std.testing.expectEqual(@as(usize, 0), entities.countOf(mob.slime));
}

test "the monster cap is counted apart from the animals" {
    const gpa = std.testing.allocator;
    var w = try stoneCavern(gpa, 2, 5, cavern);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(9);
    for (0..@intCast(populationCap(.monster, chunksAroundOnePlayer()) + 1)) |_| {
        try entities.spawnSlime(gpa, math.Vec3.init(64, cavern, 8), &rand);
    }

    const before = entities.countOf(mob.slime);
    const player = math.Vec3.init(0, cavern, 0);
    for (0..500) |_| {
        _ = try performSpawning(gpa, &entities, &w, &soloView(player), .{ 0, 64, 0 }, .overworld, test_seed, &rand);
    }

    try std.testing.expectEqual(before, entities.countOf(mob.slime));
}

test "the population cap follows the vanilla per-chunk allowance" {
    try std.testing.expectEqual(@as(i32, 16), populationCap(.creature, chunksAroundOnePlayer()));
    try std.testing.expectEqual(@as(i32, 79), populationCap(.monster, chunksAroundOnePlayer()));
}

test "the biome's creature list picks each kind by its own weight" {
    var rand = world.JavaRandom.init(4);
    var rolls = [_]u32{0} ** std.enums.values(Kind).len;
    const total = 4000;
    for (0..total) |_| {
        rolls[@intFromEnum(pickWeighted(Creature, creatureList(.plains), &rand).kind)] += 1;
    }

    // Of the plains list's 40 weight: sheep 12, pig 10, chicken 10, cow 8.
    const expected = [_]u32{ 30, 25, 25, 20 };
    for (expected, 0..) |percent, kind| {
        const share = rolls[kind] * 100 / total;
        try std.testing.expect(share > percent - 4 and share < percent + 4);
    }

    try std.testing.expectEqual(@as(u32, 0), rolls[@intFromEnum(Kind.wolf)]);
    try std.testing.expect(rolls[@intFromEnum(Kind.sheep)] > rolls[@intFromEnum(Kind.pig)]);
    try std.testing.expect(rolls[@intFromEnum(Kind.pig)] > rolls[@intFromEnum(Kind.cow)]);
}

test "only forest and taiga put a wolf on the list, at one part in twenty-one" {
    for (std.enums.values(world.biome.Biome)) |in_biome| {
        var wolves: i32 = 0;
        for (creatureList(in_biome)) |entry| {
            if (entry.kind == .wolf) wolves = entry.weight;
        }

        const wooded = in_biome == .forest or in_biome == .taiga;
        try std.testing.expectEqual(if (wooded) @as(i32, 2) else 0, wolves);
    }

    var rand = world.JavaRandom.init(6);
    var rolled: u32 = 0;
    const total = 20000;
    for (0..total) |_| {
        if (pickWeighted(Creature, creatureList(.taiga), &rand).kind == .wolf) rolled += 1;
    }

    const share = rolled * 1000 / total;
    try std.testing.expect(share > 35 and share < 60);
}

test "a wolf pack fills a chunk twice as deep as the other animals" {
    try std.testing.expectEqual(@as(u32, 8), Kind.wolf.maxPerChunk());
    for ([_]Kind{ .sheep, .pig, .chicken, .cow }) |kind| {
        try std.testing.expectEqual(max_per_chunk, kind.maxPerChunk());
    }
}

test "two distant players make more of the world eligible, and raise the cap with it" {
    const gpa = std.testing.allocator;

    const alone = [_]Animal.PlayerView{
        .{ .id = 1, .position = math.Vec3.init(0, 64, 0), .eye_height = 1.62, .alive = true },
    };
    var solo: std.ArrayList(world.World.ChunkCoord) = .empty;
    defer solo.deinit(gpa);
    try collectEligibleChunks(gpa, &alone, &solo);
    try std.testing.expectEqual(chunksAroundOnePlayer(), solo.items.len);

    const apart = [_]Animal.PlayerView{
        alone[0],
        .{ .id = 2, .position = math.Vec3.init(4000, 64, 4000), .eye_height = 1.62, .alive = true },
    };
    var pair: std.ArrayList(world.World.ChunkCoord) = .empty;
    defer pair.deinit(gpa);
    try collectEligibleChunks(gpa, &apart, &pair);

    try std.testing.expectEqual(chunksAroundOnePlayer() * 2, pair.items.len);
    try std.testing.expect(populationCap(.creature, pair.items.len) > populationCap(.creature, solo.items.len));
}

test "players standing together do not count the same chunk twice" {
    const gpa = std.testing.allocator;

    const together = [_]Animal.PlayerView{
        .{ .id = 1, .position = math.Vec3.init(0, 64, 0), .eye_height = 1.62, .alive = true },
        .{ .id = 2, .position = math.Vec3.init(4, 64, 4), .eye_height = 1.62, .alive = true },
    };
    var eligible: std.ArrayList(world.World.ChunkCoord) = .empty;
    defer eligible.deinit(gpa);
    try collectEligibleChunks(gpa, &together, &eligible);

    try std.testing.expectEqual(chunksAroundOnePlayer(), eligible.items.len);
}

test "nothing spawns near any player, not merely the first" {
    const near_second = [_]Animal.PlayerView{
        .{ .id = 1, .position = math.Vec3.init(0, 64, 0), .eye_height = 1.62, .alive = true },
        .{ .id = 2, .position = math.Vec3.init(500, 64, 500), .eye_height = 1.62, .alive = true },
    };

    try std.testing.expect(anyPlayerWithin(&near_second, 505, 64, 500, player_clearance));
    try std.testing.expect(anyPlayerWithin(&near_second, 5, 64, 0, player_clearance));
    try std.testing.expect(!anyPlayerWithin(&near_second, 250, 64, 250, player_clearance));
}

pub const night_spawn_attempts: usize = 20;
pub const night_spawn_spread: i32 = 32;
pub const night_spawn_lift: i32 = 16;
pub const night_spawn_ceiling: i32 = 128;
pub const night_spawn_path_reach: f32 = 32.0;
const night_bedside_reach: f64 = 1.5;

const NightSpawn = enum { spider, zombie, skeleton };

fn reachesSleeper(
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    animal: Animal,
    sleeper: math.Vec3,
) !bool {
    var path = try world.pathfinder.toPosition(
        gpa,
        world_map,
        animal.pathMob(),
        sleeper.x,
        sleeper.y,
        sleeper.z,
        night_spawn_path_reach,
    ) orelse return false;
    defer path.deinit(gpa);

    if (path.points.len <= 1) return false;
    const last = path.destination() orelse return false;
    return @abs(@as(f64, @floatFromInt(last.x)) - sleeper.x) < night_bedside_reach and
        @abs(@as(f64, @floatFromInt(last.z)) - sleeper.z) < night_bedside_reach and
        @abs(@as(f64, @floatFromInt(last.y)) - sleeper.y) < night_bedside_reach;
}

fn placeNightSpawn(
    gpa: std.mem.Allocator,
    entities: *Entities,
    world_map: *const world.World,
    rand: *world.JavaRandom,
    kind: NightSpawn,
    at: math.Vec3,
    bedside: [3]i32,
    sleeper: math.Vec3,
) !bool {
    const yaw = rand.nextFloat() * 360.0;
    const landing = math.Vec3.init(
        @as(f64, @as(f32, @floatFromInt(bedside[0])) + 0.5),
        @floatFromInt(bedside[1]),
        @as(f64, @as(f32, @floatFromInt(bedside[2])) + 0.5),
    );

    switch (kind) {
        inline else => |tag| {
            const Horde = switch (tag) {
                .spider => Spider,
                .zombie => Zombie,
                .skeleton => Skeleton,
            };
            const type_id = switch (tag) {
                .spider => mob.spider,
                .zombie => mob.zombie,
                .skeleton => mob.skeleton,
            };
            var spawned = Horde.spawn(at);
            spawned.animal.faceYaw(yaw);
            if (!spawned.canSpawnHere(world_map, rand)) return false;
            if (!try reachesSleeper(gpa, world_map, spawned.animal, sleeper)) return false;
            spawned.animal.faceYaw(0);
            spawned.animal.base.position = landing;
            spawned.animal.base.prev_position = landing;

            const mount = entities.takeId();
            try entities.adoptAs(gpa, type_id, spawned, mount);
            if (tag == .spider) try mountJockey(gpa, entities, rand, mount, landing, 0);
            spawned.animal.playLivingSound(world_map, rand);
        },
    }
    return true;
}

pub fn performSleepSpawning(
    gpa: std.mem.Allocator,
    entities: *Entities,
    world_map: *world.World,
    sleepers: []const *Player,
    rand: *world.JavaRandom,
) !bool {
    const kinds = std.enums.values(NightSpawn);
    var spawned_any = false;

    for (sleepers) |player| {
        var placed = false;
        var attempt: usize = 0;
        while (attempt < night_spawn_attempts and !placed) : (attempt += 1) {
            const anchor = math.Vec3.init(player.base.position.x, player.anchorY(), player.base.position.z);
            const x = math.util.floorDouble(anchor.x) + rand.nextIntBound(night_spawn_spread) - rand.nextIntBound(night_spawn_spread);
            const z = math.util.floorDouble(anchor.z) + rand.nextIntBound(night_spawn_spread) - rand.nextIntBound(night_spawn_spread);
            var start_y = math.util.floorDouble(anchor.y) + rand.nextIntBound(night_spawn_lift) - rand.nextIntBound(night_spawn_lift);
            if (start_y < 1) {
                start_y = 1;
            } else if (start_y > night_spawn_ceiling) {
                start_y = night_spawn_ceiling;
            }

            const kind = kinds[@intCast(rand.nextIntBound(@intCast(kinds.len)))];

            var y = start_y;
            while (y > 2 and !world_map.getBlock(.init(x, y - 1, z)).isOpaqueCube()) y -= 1;
            while (!canSpawnAtLocation(.monster, world_map, .init(x, y, z)) and
                y < start_y + night_spawn_lift and
                y < night_spawn_ceiling) : (y += 1)
            {}
            if (y >= start_y + night_spawn_lift or y >= night_spawn_ceiling) continue;

            const at = math.Vec3.init(
                @as(f64, @as(f32, @floatFromInt(x)) + 0.5),
                @floatFromInt(y),
                @as(f64, @as(f32, @floatFromInt(z)) + 0.5),
            );
            const bedside = world.block_update.bedRespawnSpot(
                world_map,
                .init(math.util.floorDouble(anchor.x), math.util.floorDouble(anchor.y), math.util.floorDouble(anchor.z)),
                1,
            ) orelse [3]i32{ x, y + 1, z };

            if (!try placeNightSpawn(gpa, entities, world_map, rand, kind, at, bedside, anchor)) continue;

            try player.wakeUp(world_map, true, false);
            placed = true;
            spawned_any = true;
        }
    }

    return spawned_any;
}

test "one spider in a hundred rides out of the spawner carrying a skeleton" {
    const gpa = std.testing.allocator;

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(11);
    const rolls: usize = 20_000;
    for (0..rolls) |_| {
        try mountJockey(gpa, &entities, &rand, 1, math.Vec3.init(0, 0, 0), 0);
    }

    const jockeys = entities.countOf(mob.skeleton);
    try std.testing.expect(jockeys > rolls / jockey_odds * 9 / 10);
    try std.testing.expect(jockeys < rolls / jockey_odds * 11 / 10);
}

test "the jockey's skeleton takes the spider's own bearing and rides its id" {
    const gpa = std.testing.allocator;

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(11);
    const mount: Animal.Entity.Id = 7;
    while (entities.countOf(mob.skeleton) == 0) {
        try mountJockey(gpa, &entities, &rand, mount, math.Vec3.init(4.5, 9, 2.5), 131.0);
    }

    const jockey = entities.first(Skeleton, mob.skeleton).?;
    try std.testing.expectEqual(mount, jockey.animal.riding);
    try std.testing.expectEqual(@as(f32, 131.0), jockey.animal.yaw);
    try std.testing.expectEqual(math.Vec3.init(4.5, 9, 2.5), jockey.animal.base.position);
}

test "a spider the spawner rejects never rolls for a jockey" {
    const gpa = std.testing.allocator;
    var w = try grassPlateau(gpa, 3, 5, surface);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var rand = world.JavaRandom.init(9);
    const player = math.Vec3.init(0, surface + 1, 0);
    for (0..4000) |_| {
        _ = try performSpawning(gpa, &entities, &w, &soloView(player), .{ 0, 64, 0 }, .overworld, test_seed, &rand);
    }

    // Broad daylight on the plateau: no spider gets in, so no jockey can be riding one.
    try std.testing.expectEqual(@as(usize, 0), entities.countOf(mob.spider));
    var walk = entities.of(Skeleton, mob.skeleton);
    while (walk.next()) |skeleton| {
        try std.testing.expectEqual(Animal.Entity.no_id, skeleton.animal.riding);
    }
}
