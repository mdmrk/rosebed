const std = @import("std");

const game = @import("game");
const Animal = game.Animal;
const Mob = game.mob;
const math = @import("math");
const world = @import("world");

const Hooks = @import("Hooks.zig");

pub const capacity: usize = 16;

pub const Def = struct {
    key: []const u8 = "",
    model: Mob.Model = .{ .builtin = .pig },
    spawns: ?Mob.Spawns = null,
    width: f64 = default_width,
    height: f64 = default_height,
    health: i32 = Animal.default_max_health,
    speed: f32 = Animal.default_move_speed,
    wing_beat: f32 = 0,
    step_height: f64 = Animal.default_step_height,
    movement: Animal.Movement = .walking,
    monster: bool = false,
    immune_to_fire: bool = false,
    breathes_underwater: bool = false,
    takes_fall_damage: bool = true,
};

pub const Refs = struct {
    drop: ?i32 = null,
    on_tick: ?i32 = null,
    path_weight: ?i32 = null,
    think: ?i32 = null,
    after_move: ?i32 = null,
};

pub const Patch = struct {
    health: ?i32 = null,
    speed: ?f32 = null,
};

pub const PatchRefs = struct {
    on_tick: ?i32 = null,
    drop: ?i32 = null,
    path_weight: ?i32 = null,
    think: ?i32 = null,
    after_move: ?i32 = null,
};

pub const default_width: f64 = 0.6;
pub const default_height: f64 = 1.8;

const Slot = struct {
    def: Def = .{},
    refs: Refs = .{},
    inner_think: ?Animal.ActionState = null,
};

var slots: [capacity]Slot = @splat(.{});
var count: usize = 0;

const Body = struct {
    animal: Animal,
    slot: u16,
};

pub fn claim(def: Def, refs: Refs) !Mob.Id {
    if (Mob.find(def.key) != null) return error.DuplicateKey;
    if (count == capacity or Mob.registered() == Mob.capacity) return error.RegistryFull;

    slots[count] = .{ .def = def, .refs = refs };
    const entry = entries[count];
    count += 1;

    return Mob.register(.{
        .name = def.key,
        .wire_id = Mob.first_mod_wire_id + @as(u8, @intCast(count - 1)),
        .monster = def.monster,
        .spawns = def.spawns,
        .canSpawnHere = if (def.spawns) |spawns| Mob.spawnCheckFor(spawns.category) else Mob.spawnCheckFor(.creature),
        .spawn = entry.spawn,
        .tick = tick,
        .takeDrops = takeDrops,
        .store = store,
        .load = entry.load,
        .destroy = destroy,
        .afterTick = afterTick,
    });
}

pub fn reset() void {
    count = 0;
    overrides = @splat(.{});
}

const Override = struct {
    health: ?i32 = null,
    speed: ?f32 = null,
    on_tick: ?i32 = null,
    drop: ?i32 = null,
    path_weight: ?i32 = null,
    think: ?i32 = null,
    after_move: ?i32 = null,
    inner_think: ?Animal.ActionState = null,
    inner_spawn: ?*const fn (std.mem.Allocator, math.Vec3, *world.JavaRandom) anyerror!*Animal = null,
    inner_load: ?*const fn (std.mem.Allocator, world.nbt.Compound) anyerror!?*Animal = null,
    inner_after_tick: ?*const fn (*Animal, Mob.Tick) anyerror!void = null,
    inner_take_drops: ?*const fn (*Animal) ?Mob.Drops = null,
    inner_on_death: ?*const fn (*Animal, *world.JavaRandom) void = null,
};

var overrides: [Mob.capacity]Override = @splat(.{});

pub fn override(type_id: Mob.Id, patch: Patch, refs: PatchRefs) void {
    const slot = &overrides[type_id];
    if (patch.health) |health| slot.health = health;
    if (patch.speed) |speed| slot.speed = speed;
    if (refs.on_tick) |ref| slot.on_tick = ref;
    if (refs.drop) |ref| slot.drop = ref;
    if (refs.path_weight) |ref| slot.path_weight = ref;
    if (refs.think) |ref| slot.think = ref;
    if (refs.after_move) |ref| slot.after_move = ref;

    var definition = Mob.get(type_id).*;
    if (slot.inner_spawn == null) {
        slot.inner_spawn = definition.spawn;
        slot.inner_load = definition.load;
        slot.inner_after_tick = definition.afterTick;
        slot.inner_take_drops = definition.takeDrops;
        definition.spawn = wrappers[type_id].spawn;
        definition.load = wrappers[type_id].load;
        definition.afterTick = wrappers[type_id].afterTick;
        definition.takeDrops = wrappers[type_id].takeDrops;
        Mob.replace(type_id, definition);
    }
}

const Wrapper = struct {
    spawn: *const fn (std.mem.Allocator, math.Vec3, *world.JavaRandom) anyerror!*Animal,
    load: *const fn (std.mem.Allocator, world.nbt.Compound) anyerror!?*Animal,
    afterTick: *const fn (*Animal, Mob.Tick) anyerror!void,
    takeDrops: *const fn (*Animal) ?Mob.Drops,
    onDeath: *const fn (*Animal, *world.JavaRandom) void,
    pathWeight: *const fn (*const world.World, world.BlockPos) f32,
    think: Animal.ActionState,
    afterMove: *const fn (*Animal, *const world.World, *world.JavaRandom) void,
};

const wrappers: [Mob.capacity]Wrapper = blk: {
    var out: [Mob.capacity]Wrapper = undefined;
    for (&out, 0..) |*entry, type_id| entry.* = wrapperFor(type_id);
    break :blk out;
};

fn wrapperFor(comptime type_id: Mob.Id) Wrapper {
    return .{
        .spawn = &struct {
            fn call(gpa: std.mem.Allocator, position: math.Vec3, rand: *world.JavaRandom) anyerror!*Animal {
                const animal = try overrides[type_id].inner_spawn.?(gpa, position, rand);
                reshape(type_id, animal, .fresh);
                return animal;
            }
        }.call,
        .load = &struct {
            fn call(gpa: std.mem.Allocator, entity: world.nbt.Compound) anyerror!?*Animal {
                const animal = try overrides[type_id].inner_load.?(gpa, entity) orelse return null;
                reshape(type_id, animal, .restored);
                return animal;
            }
        }.call,
        .afterTick = &struct {
            fn call(animal: *Animal, context: Mob.Tick) anyerror!void {
                try overrides[type_id].inner_after_tick.?(animal, context);
                const ref = overrides[type_id].on_tick orelse return;
                const hooks = Hooks.active orelse return;
                hooks.callMob(ref, animal, context.world_map, context.rand);
            }
        }.call,
        .takeDrops = &struct {
            fn call(animal: *Animal) ?Mob.Drops {
                return overrides[type_id].inner_take_drops.?(animal) orelse takeDrops(animal);
            }
        }.call,
        .onDeath = &struct {
            fn call(animal: *Animal, rand: *world.JavaRandom) void {
                const slot = overrides[type_id];
                if (slot.inner_on_death) |inner| inner(animal, rand);
                const ref = slot.drop orelse return;
                const hooks = Hooks.active orelse return;
                animal.owed_drop = hooks.rollDrop(ref, null, rand);
            }
        }.call,
        .pathWeight = &struct {
            fn call(world_map: *const world.World, pos: world.BlockPos) f32 {
                const ref = overrides[type_id].path_weight orelse return Animal.blockPathWeight(world_map, pos);
                const hooks = Hooks.active orelse return Animal.blockPathWeight(world_map, pos);
                return hooks.pathWeight(ref, world_map, pos) orelse Animal.blockPathWeight(world_map, pos);
            }
        }.call,
        .think = &struct {
            fn call(
                animal: *Animal,
                gpa: std.mem.Allocator,
                world_map: *const world.World,
                players: Animal.Players,
                rand: *world.JavaRandom,
            ) anyerror!void {
                const slot = overrides[type_id];
                const ref = slot.think orelse return;
                const hooks = Hooks.active orelse return;
                hooks.think(ref, .{
                    .animal = animal,
                    .gpa = gpa,
                    .world_map = world_map,
                    .players = players,
                    .rand = rand,
                    .inner = slot.inner_think orelse Animal.updateActionState,
                });
            }
        }.call,
        .afterMove = &struct {
            fn call(animal: *Animal, world_map: *const world.World, rand: *world.JavaRandom) void {
                const ref = overrides[type_id].after_move orelse return;
                const hooks = Hooks.active orelse return;
                hooks.callMob(ref, animal, @constCast(world_map), rand);
            }
        }.call,
    };
}

const Wounds = enum { fresh, restored };

fn reshape(type_id: Mob.Id, animal: *Animal, wounds: Wounds) void {
    if (animal.on_death != wrappers[type_id].onDeath) {
        overrides[type_id].inner_on_death = animal.on_death;
        animal.on_death = wrappers[type_id].onDeath;
    }
    if (overrides[type_id].path_weight != null) animal.path_weight = wrappers[type_id].pathWeight;
    if (overrides[type_id].think != null and animal.action_state != wrappers[type_id].think) {
        overrides[type_id].inner_think = animal.action_state;
        animal.action_state = wrappers[type_id].think;
    }
    if (overrides[type_id].after_move != null) animal.after_move = wrappers[type_id].afterMove;

    const slot = overrides[type_id];
    if (slot.health) |health| {
        animal.max_health = health;
        if (wounds == .fresh) animal.health = health;
    }
    if (slot.speed) |speed| animal.move_speed = speed;
}

const Entry = struct {
    spawn: *const fn (std.mem.Allocator, math.Vec3, *world.JavaRandom) anyerror!*Animal,
    load: *const fn (std.mem.Allocator, world.nbt.Compound) anyerror!?*Animal,
    pathWeight: *const fn (*const world.World, world.BlockPos) f32,
};

const entries: [capacity]Entry = blk: {
    var out: [capacity]Entry = undefined;
    for (&out, 0..) |*entry, slot| entry.* = entryFor(slot);
    break :blk out;
};

fn entryFor(comptime slot: u16) Entry {
    return .{
        .pathWeight = &struct {
            fn call(world_map: *const world.World, pos: world.BlockPos) f32 {
                const ref = slots[slot].refs.path_weight orelse return Animal.blockPathWeight(world_map, pos);
                const hooks = Hooks.active orelse return Animal.blockPathWeight(world_map, pos);
                return hooks.pathWeight(ref, world_map, pos) orelse Animal.blockPathWeight(world_map, pos);
            }
        }.call,
        .spawn = &struct {
            fn call(gpa: std.mem.Allocator, position: math.Vec3, _: *world.JavaRandom) anyerror!*Animal {
                return &(try create(gpa, slot, position)).animal;
            }
        }.call,
        .load = &struct {
            fn call(gpa: std.mem.Allocator, entity: world.nbt.Compound) anyerror!?*Animal {
                const record = world.entity_nbt.loadMob(entity, slots[slot].def.key) orelse return null;
                const body = try create(gpa, slot, record.position);
                body.animal.restore(record);
                return &body.animal;
            }
        }.call,
    };
}

fn create(gpa: std.mem.Allocator, slot: u16, position: math.Vec3) !*Body {
    const def = slots[slot].def;
    const body = try gpa.create(Body);
    body.* = .{
        .animal = .spawn(position, .{
            .width = def.width,
            .height = def.height,
            .max_health = def.health,
            .step_height = def.step_height,
            .movement = def.movement,
            .immune_to_fire = def.immune_to_fire,
            .breathes_underwater = def.breathes_underwater,
            .takes_fall_damage = def.takes_fall_damage,
            .move_speed = def.speed,
        }),
        .slot = slot,
    };
    body.animal.on_death = rollDrop;
    if (slots[slot].refs.path_weight != null) body.animal.path_weight = entries[slot].pathWeight;
    if (slots[slot].refs.think != null) {
        slots[slot].inner_think = body.animal.action_state;
        body.animal.action_state = think;
    }
    if (slots[slot].refs.after_move != null) body.animal.after_move = afterMove;
    return body;
}

fn think(
    animal: *Animal,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    players: Animal.Players,
    rand: *world.JavaRandom,
) anyerror!void {
    const body: *Body = @fieldParentPtr("animal", animal);
    const slot = slots[body.slot];
    const ref = slot.refs.think orelse return;
    const hooks = Hooks.active orelse return;
    hooks.think(ref, .{
        .animal = animal,
        .gpa = gpa,
        .world_map = world_map,
        .players = players,
        .rand = rand,
        .inner = slot.inner_think orelse Animal.updateActionState,
    });
}

fn afterMove(animal: *Animal, world_map: *const world.World, rand: *world.JavaRandom) void {
    const body: *Body = @fieldParentPtr("animal", animal);
    const ref = slots[body.slot].refs.after_move orelse return;
    const hooks = Hooks.active orelse return;
    hooks.callMob(ref, animal, @constCast(world_map), rand);
}

fn rollDrop(animal: *Animal, rand: *world.JavaRandom) void {
    const body: *Body = @fieldParentPtr("animal", animal);
    const ref = slots[body.slot].refs.drop orelse return;
    const hooks = Hooks.active orelse return;
    animal.owed_drop = hooks.rollDrop(ref, null, rand);
}

fn tick(
    animal: *Animal,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    players: Animal.Players,
    rand: *world.JavaRandom,
) anyerror!void {
    try animal.tick(gpa, world_map, players, rand);
}

fn afterTick(animal: *Animal, context: Mob.Tick) anyerror!void {
    const body: *Body = @fieldParentPtr("animal", animal);
    const ref = slots[body.slot].refs.on_tick orelse return;
    const hooks = Hooks.active orelse return;
    hooks.callMob(ref, animal, context.world_map, context.rand);
}

fn takeDrops(animal: *Animal) ?Mob.Drops {
    const stack = animal.owed_drop orelse return null;
    animal.owed_drop = null;
    return .{ .count = stack.count, .stack = .{ .id = stack.id, .count = 1, .meta = stack.meta } };
}

fn store(animal: *Animal, gpa: std.mem.Allocator) anyerror!world.nbt.Tag {
    const body: *Body = @fieldParentPtr("animal", animal);
    return world.entity_nbt.storeMob(gpa, slots[body.slot].def.key, animal.toRecord());
}

fn destroy(animal: *Animal, gpa: std.mem.Allocator) void {
    const body: *Body = @fieldParentPtr("animal", animal);
    body.animal.deinit(gpa);
    gpa.destroy(body);
}
