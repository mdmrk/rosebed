const std = @import("std");

const game = @import("game");
const math = @import("math");
const world = @import("world");

const Hooks = @import("Hooks.zig");

const Animal = game.Animal;
const Mob = game.mob;

pub const capacity: usize = 16;

pub const Def = struct {
    key: []const u8 = "",
    model: Mob.Model = .pig,
    width: f64 = default_width,
    height: f64 = default_height,
    health: i32 = Animal.default_max_health,
    speed: f32 = Animal.default_move_speed,
    step_height: f64 = Animal.default_step_height,
    movement: Animal.Movement = .walking,
    monster: bool = false,
    immune_to_fire: bool = false,
    breathes_underwater: bool = false,
    takes_fall_damage: bool = true,
};

pub const Refs = struct {
    drop: ?i32 = null,
};

pub const default_width: f64 = 0.6;
pub const default_height: f64 = 1.8;

const Slot = struct {
    def: Def = .{},
    refs: Refs = .{},
};

var slots: [capacity]Slot = @splat(.{});
var count: usize = 0;

const Body = struct {
    animal: Animal,
    slot: u16,
    pending: ?world.Stack = null,
};

pub fn claim(def: Def, refs: Refs) !Mob.Id {
    if (Mob.find(def.key) != null) return error.DuplicateKey;
    if (count == capacity or Mob.registered() == Mob.capacity) return error.RegistryFull;

    slots[count] = .{ .def = def, .refs = refs };
    const entry = entries[count];
    count += 1;

    return Mob.register(.{
        .name = def.key,
        .monster = def.monster,
        .spawn = entry.spawn,
        .tick = tick,
        .takeDrops = takeDrops,
        .store = store,
        .load = entry.load,
        .destroy = destroy,
    });
}

pub fn reset() void {
    count = 0;
}

const Entry = struct {
    spawn: *const fn (std.mem.Allocator, math.Vec3, *world.JavaRandom) anyerror!*Animal,
    load: *const fn (std.mem.Allocator, world.nbt.Compound) anyerror!?*Animal,
};

const entries: [capacity]Entry = blk: {
    var out: [capacity]Entry = undefined;
    for (&out, 0..) |*entry, slot| entry.* = entryFor(slot);
    break :blk out;
};

fn entryFor(comptime slot: u16) Entry {
    return .{
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
    return body;
}

fn rollDrop(animal: *Animal, rand: *world.JavaRandom) void {
    const body: *Body = @fieldParentPtr("animal", animal);
    const ref = slots[body.slot].refs.drop orelse return;
    const hooks = Hooks.active orelse return;
    body.pending = hooks.rollDrop(ref, null, rand);
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

fn takeDrops(animal: *Animal) ?Mob.Drops {
    const body: *Body = @fieldParentPtr("animal", animal);
    const stack = body.pending orelse return null;
    body.pending = null;
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
