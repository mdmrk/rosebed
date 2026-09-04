const std = @import("std");

const math = @import("math");
const world = @import("world");
const BlockPos = world.BlockPos;
const State = world.mob_spawner.MobSpawner;

const Entities = @import("Entities.zig");
const Animal = @import("entity/Animal.zig");
const Particle = @import("entity/Particle.zig");
const mob = @import("mob.zig");

pub const player_range: f64 = 16.0;
pub const attempts: usize = 4;
pub const crowd_limit: usize = 6;
pub const crowd_reach_x: f64 = 8.0;
pub const crowd_reach_y: f64 = 4.0;
pub const spread: f64 = 4.0;
pub const lift_spread: i32 = 3;
pub const burst_particles: usize = 20;
pub const burst_reach: f64 = 2.0;
pub const explosion_particles: usize = 20;
pub const explosion_drift: f64 = 0.02;
pub const explosion_stretch: f64 = 10.0;

pub const Context = struct {
    gpa: std.mem.Allocator,
    entities: *Entities,
    world_map: *world.World,
    players: Animal.Players,
    world_seed: i64,
    rand: *world.JavaRandom,
};

pub fn tickAll(context: Context) !void {
    var it = context.world_map.mob_spawners.iterator();
    while (it.next()) |entry| {
        try tick(context, entry.key_ptr.*, entry.value_ptr);
    }
}

pub fn tick(context: Context, pos: BlockPos, state: *State) !void {
    state.prev_yaw = state.yaw;
    if (context.players.closestTo(pos.center(), player_range) == null) return;

    const rand = context.rand;
    try smokeAndFlame(context, .init(
        @as(f64, @floatFromInt(pos.x)) + rand.nextFloat(),
        @as(f64, @floatFromInt(pos.y)) + rand.nextFloat(),
        @as(f64, @floatFromInt(pos.z)) + rand.nextFloat(),
    ));

    state.yaw += world.mob_spawner.spin_numerator /
        (@as(f64, @floatFromInt(state.delay)) + world.mob_spawner.spin_denominator);
    while (state.yaw > 360.0) {
        state.yaw -= 360.0;
        state.prev_yaw -= 360.0;
    }

    if (state.delay == world.mob_spawner.idle_delay) rewind(state, rand);
    if (state.delay > 0) {
        state.delay -= 1;
        return;
    }

    const type_id = mob.find(state.mobName()) orelse return;

    for (0..attempts) |_| {
        const animal = try mob.get(type_id).spawn(context.gpa, .init(0, 0, 0), rand);
        var adopted = false;
        errdefer if (!adopted) mob.get(type_id).destroy(animal, context.gpa);

        if (context.entities.countOfInBox(type_id, crowdBox(pos)) >= crowd_limit) {
            mob.get(type_id).destroy(animal, context.gpa);
            rewind(state, rand);
            return;
        }

        animal.placeAt(.init(
            @as(f64, @floatFromInt(pos.x)) + (rand.nextDouble() - rand.nextDouble()) * spread,
            @floatFromInt(pos.y + rand.nextIntBound(lift_spread) - 1),
            @as(f64, @floatFromInt(pos.z)) + (rand.nextDouble() - rand.nextDouble()) * spread,
        ));
        animal.faceYaw(rand.nextFloat() * 360.0);

        if (!mob.get(type_id).canSpawnHere(animal, context.world_map, context.world_seed, rand)) {
            mob.get(type_id).destroy(animal, context.gpa);
            continue;
        }

        try context.entities.adoptMob(context.gpa, type_id, animal);
        adopted = true;

        for (0..burst_particles) |_| {
            try smokeAndFlame(context, .init(
                @as(f64, @floatFromInt(pos.x)) + 0.5 + (rand.nextFloat() - 0.5) * burst_reach,
                @as(f64, @floatFromInt(pos.y)) + 0.5 + (rand.nextFloat() - 0.5) * burst_reach,
                @as(f64, @floatFromInt(pos.z)) + 0.5 + (rand.nextFloat() - 0.5) * burst_reach,
            ));
        }
        try explode(context, animal.*);
        rewind(state, rand);
    }
}

fn crowdBox(pos: BlockPos) math.Aabb {
    const box: math.Aabb = .{
        .min_x = @floatFromInt(pos.x),
        .min_y = @floatFromInt(pos.y),
        .min_z = @floatFromInt(pos.z),
        .max_x = @floatFromInt(pos.x + 1),
        .max_y = @floatFromInt(pos.y + 1),
        .max_z = @floatFromInt(pos.z + 1),
    };
    return box.expand(crowd_reach_x, crowd_reach_y, crowd_reach_x);
}

fn rewind(state: *State, rand: *world.JavaRandom) void {
    state.delay = world.mob_spawner.delay_floor + rand.nextIntBound(world.mob_spawner.delay_spread);
}

fn smokeAndFlame(context: Context, at: math.Vec3) !void {
    const still = math.Vec3.init(0, 0, 0);
    try context.entities.particles.append(context.gpa, Particle.spawnSmoke(at, still, context.rand));
    try context.entities.particles.append(context.gpa, Particle.spawnFlame(at, still, context.rand));
}

fn explode(context: Context, animal: Animal) !void {
    const rand = context.rand;
    const at = animal.base.position;

    for (0..explosion_particles) |_| {
        const drift = math.Vec3.init(
            rand.nextGaussian() * explosion_drift,
            rand.nextGaussian() * explosion_drift,
            rand.nextGaussian() * explosion_drift,
        );
        const spot = math.Vec3.init(
            at.x + rand.nextFloat() * animal.base.width * 2.0 - animal.base.width - drift.x * explosion_stretch,
            at.y + rand.nextFloat() * animal.base.height - drift.y * explosion_stretch,
            at.z + rand.nextFloat() * animal.base.width * 2.0 - animal.base.width - drift.z * explosion_stretch,
        );
        try context.entities.particles.append(context.gpa, Particle.spawnExplode(spot, drift, rand));
    }
}

fn spawnerWorld(gpa: std.mem.Allocator, mob_name: []const u8) !world.World {
    var w = try world.testing.flatWorld(gpa, 1);
    errdefer w.deinit();

    const chunk = w.getChunk(0, 0).?;
    for (0..world.Chunk.width) |x| {
        for (0..world.Chunk.width) |z| chunk.setBlock(@intCast(x), 8, @intCast(z), .stone);
    }
    try world.light.relightChunk(gpa, &w, 0, 0);

    w.setBlock(.init(8, 1, 8), .mob_spawner);
    (try w.addMobSpawner(.init(8, 1, 8))).setMobName(mob_name);
    return w;
}

fn watcherAt(x: f64, z: f64) Animal.PlayerView {
    return .{ .id = 1, .position = math.Vec3.init(x, 1, z), .eye_height = 1.62, .alive = true };
}

test "a spawner with nobody watching never counts down" {
    const gpa = std.testing.allocator;
    var w = try spawnerWorld(gpa, "Zombie");
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);
    var rand = world.JavaRandom.init(3);

    const far = watcherAt(200.5, 200.5);
    const state = w.mobSpawnerAt(.init(8, 1, 8)).?;
    const before = state.delay;

    for (0..200) |_| try tickAll(.{
        .gpa = gpa,
        .entities = &entities,
        .world_map = &w,
        .players = Animal.Players.one(&far),
        .world_seed = 1,
        .rand = &rand,
    });

    try std.testing.expectEqual(before, state.delay);
    try std.testing.expectEqual(@as(usize, 0), entities.mobs.items.len);
    try std.testing.expectEqual(@as(usize, 0), entities.particles.items.len);
}

test "a watched spawner counts down and then fills the room with mobs" {
    const gpa = std.testing.allocator;
    var w = try spawnerWorld(gpa, "Zombie");
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);
    var rand = world.JavaRandom.init(11);

    const near = watcherAt(8.5, 8.5);
    const context: Context = .{
        .gpa = gpa,
        .entities = &entities,
        .world_map = &w,
        .players = Animal.Players.one(&near),
        .world_seed = 1,
        .rand = &rand,
    };

    var ticks: usize = 0;
    while (ticks < 4000 and entities.mobs.items.len == 0) : (ticks += 1) try tickAll(context);

    try std.testing.expect(entities.mobs.items.len > 0);
    try std.testing.expectEqual(mob.zombie, entities.mobs.items[0].type_id);
    try std.testing.expect(w.mobSpawnerAt(.init(8, 1, 8)).?.delay >= world.mob_spawner.delay_floor);
}

test "a spawner stops once its own mobs crowd around it" {
    const gpa = std.testing.allocator;
    var w = try spawnerWorld(gpa, "Zombie");
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);
    var rand = world.JavaRandom.init(11);

    const near = watcherAt(8.5, 8.5);
    const context: Context = .{
        .gpa = gpa,
        .entities = &entities,
        .world_map = &w,
        .players = Animal.Players.one(&near),
        .world_seed = 1,
        .rand = &rand,
    };

    for (0..40000) |_| try tickAll(context);
    try std.testing.expectEqual(@as(usize, crowd_limit), entities.countOfInBox(mob.zombie, crowdBox(.init(8, 1, 8))));
}

test "a spawner naming a mob nothing answers to never fires" {
    const gpa = std.testing.allocator;
    var w = try spawnerWorld(gpa, "Rosebug");
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);
    var rand = world.JavaRandom.init(5);

    const near = watcherAt(8.5, 8.5);
    for (0..4000) |_| try tickAll(.{
        .gpa = gpa,
        .entities = &entities,
        .world_map = &w,
        .players = Animal.Players.one(&near),
        .world_seed = 1,
        .rand = &rand,
    });

    try std.testing.expectEqual(@as(usize, 0), entities.mobs.items.len);
    try std.testing.expectEqual(@as(i32, 0), w.mobSpawnerAt(.init(8, 1, 8)).?.delay);
}

test "a watched spawner smokes and flames while it waits" {
    const gpa = std.testing.allocator;
    var w = try spawnerWorld(gpa, "Zombie");
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);
    var rand = world.JavaRandom.init(3);

    const near = watcherAt(8.5, 8.5);
    try tickAll(.{
        .gpa = gpa,
        .entities = &entities,
        .world_map = &w,
        .players = Animal.Players.one(&near),
        .world_seed = 1,
        .rand = &rand,
    });

    try std.testing.expectEqual(@as(usize, 2), entities.particles.items.len);
}

test "a watched spawner turns, and turns faster the closer it is to firing" {
    const gpa = std.testing.allocator;
    var w = try spawnerWorld(gpa, "Zombie");
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);
    var rand = world.JavaRandom.init(3);

    const near = watcherAt(8.5, 8.5);
    const context: Context = .{
        .gpa = gpa,
        .entities = &entities,
        .world_map = &w,
        .players = Animal.Players.one(&near),
        .world_seed = 1,
        .rand = &rand,
    };

    const state = w.mobSpawnerAt(.init(8, 1, 8)).?;
    state.delay = 800;
    try tick(context, .init(8, 1, 8), state);
    const slow = state.yaw - state.prev_yaw;

    state.delay = 0;
    try tick(context, .init(8, 1, 8), state);
    const fast = state.yaw - state.prev_yaw;

    try std.testing.expect(fast > slow);
}

test "breaking the spawner block forgets the spawner behind it" {
    const gpa = std.testing.allocator;
    var w = try spawnerWorld(gpa, "Zombie");
    defer w.deinit();

    try std.testing.expect(w.mobSpawnerAt(.init(8, 1, 8)) != null);

    try w.setBlockWithNotify(.init(8, 1, 8), .air);
    try w.forgetOrphanSpawners();

    try std.testing.expect(w.mobSpawnerAt(.init(8, 1, 8)) == null);
}
