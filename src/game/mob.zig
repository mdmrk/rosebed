const std = @import("std");

const math = @import("math");
const net = @import("net");
pub const Watched = net.packet.Watched;
pub const Metadata = net.packet.Metadata;
const world = @import("world");

const Animal = @import("entity/Animal.zig");
const Player = @import("Player.zig");

pub const Drops = struct {
    count: u8,
    stack: world.Stack,
};

pub const Tick = struct {
    entities: *anyopaque,
    gpa: std.mem.Allocator,
    world_map: *world.World,
    roster: []const *Player,
    players: Animal.Players,
    rand: *world.JavaRandom,

    pub fn playerById(self: Tick, id: Animal.Entity.Id) ?*Player {
        for (self.roster) |player| {
            if (player.base.id == id) return player;
        }
        return null;
    }
};

pub const Type = struct {
    name: []const u8,
    wire_id: ?u8 = null,
    monster: bool = false,
    vanishes_on_peaceful: bool = false,
    spawn: *const fn (std.mem.Allocator, math.Vec3, *world.JavaRandom) anyerror!*Animal,
    tick: *const fn (*Animal, std.mem.Allocator, *const world.World, Animal.Players, *world.JavaRandom) anyerror!void,
    takeDrops: *const fn (*Animal) ?Drops,
    store: *const fn (*Animal, std.mem.Allocator) anyerror!world.nbt.Tag,
    load: *const fn (std.mem.Allocator, world.nbt.Compound) anyerror!?*Animal,
    destroy: *const fn (*Animal, std.mem.Allocator) void,
    hurt: *const fn (*Animal, *const world.World, i32, ?Animal.Attacker, *world.JavaRandom) bool = hurtBase,
    canSpawnHere: *const fn (*const Animal, *const world.World, i64, *world.JavaRandom) bool = canSpawnHereBase,
    afterTick: *const fn (*Animal, Tick) anyerror!void = ignore,
    onDeath: *const fn (*Animal, Tick) anyerror!void = ignore,
    watch: *const fn (*const Animal, *Watched) void = watchNothing,
    adopt: *const fn (*Animal, Metadata) void = adoptNothing,
};

fn ignore(_: *Animal, _: Tick) anyerror!void {}

fn watchNothing(_: *const Animal, _: *Watched) void {}

fn adoptNothing(_: *Animal, _: Metadata) void {}

pub const flags_key: u5 = 0;
pub const burning_flag: u3 = 0;

pub fn watch(type_id: Id, animal: *const Animal, out: *Watched) void {
    var flags: i8 = 0;
    if (animal.fire > 0) flags |= 1 << burning_flag;
    out.add(flags_key, .{ .byte = flags });
    get(type_id).watch(animal, out);
}

pub fn adopt(type_id: Id, animal: *Animal, metadata: Metadata) void {
    if (metadata.byteAt(flags_key)) |flags| {
        animal.fire = if (flags & (1 << burning_flag) != 0) 1 else 0;
    }
    get(type_id).adopt(animal, metadata);
}

pub fn byWireId(id: u8) ?Id {
    for (types[0..count], 0..) |entry, type_id| {
        const wire = entry.wire_id orelse continue;
        if (wire == id) return @intCast(type_id);
    }
    return null;
}

fn hurtBase(animal: *Animal, world_map: *const world.World, amount: i32, source: ?Animal.Attacker, rand: *world.JavaRandom) bool {
    return animal.hurt(world_map, amount, source, rand);
}

fn canSpawnHereBase(animal: *const Animal, world_map: *const world.World, _: i64, _: *world.JavaRandom) bool {
    return animal.canSpawnHere(world_map);
}

pub const Id = u16;
pub const capacity: usize = 64;

const vanilla = [_]Type{
    @import("entity/Pig.zig").mob_type,
    @import("entity/Sheep.zig").mob_type,
    @import("entity/Cow.zig").mob_type,
    @import("entity/Chicken.zig").mob_type,
    @import("entity/Slime.zig").mob_type,
    @import("entity/Wolf.zig").mob_type,
    @import("entity/Ghast.zig").mob_type,
    @import("entity/Creeper.zig").mob_type,
    @import("entity/Skeleton.zig").mob_type,
    @import("entity/Spider.zig").mob_type,
    @import("entity/Zombie.zig").mob_type,
    @import("entity/PigZombie.zig").mob_type,
    @import("entity/Squid.zig").mob_type,
    @import("entity/Giant.zig").mob_type,
};

pub const pig: Id = 0;
pub const sheep: Id = 1;
pub const cow: Id = 2;
pub const chicken: Id = 3;
pub const slime: Id = 4;
pub const wolf: Id = 5;
pub const ghast: Id = 6;
pub const creeper: Id = 7;
pub const skeleton: Id = 8;
pub const spider: Id = 9;
pub const zombie: Id = 10;
pub const pig_zombie: Id = 11;
pub const squid: Id = 12;
pub const giant: Id = 13;

var types: [capacity]Type = initialTypes();
var count: usize = vanilla.len;

fn initialTypes() [capacity]Type {
    var out: [capacity]Type = undefined;
    for (vanilla, 0..) |entry, index| out[index] = entry;
    return out;
}

pub fn get(id: Id) *const Type {
    std.debug.assert(id < count);
    return &types[id];
}

pub fn registered() Id {
    return @intCast(count);
}

pub fn register(entry: Type) Id {
    std.debug.assert(count < capacity);
    types[count] = entry;
    count += 1;
    return @intCast(count - 1);
}

pub fn find(name: []const u8) ?Id {
    for (types[0..count], 0..) |entry, id| {
        if (std.mem.eql(u8, entry.name, name)) return @intCast(id);
    }
    return null;
}

pub fn reset() void {
    types = initialTypes();
    count = vanilla.len;
}

test "the vanilla mob types keep the ids the save format is written against" {
    try std.testing.expectEqual(pig, find("Pig").?);
    try std.testing.expectEqual(sheep, find("Sheep").?);
    try std.testing.expectEqual(cow, find("Cow").?);
    try std.testing.expectEqual(chicken, find("Chicken").?);
    try std.testing.expectEqual(slime, find("Slime").?);
    try std.testing.expectEqual(wolf, find("Wolf").?);
    try std.testing.expectEqual(ghast, find("Ghast").?);
    try std.testing.expectEqual(creeper, find("Creeper").?);
    try std.testing.expectEqual(skeleton, find("Skeleton").?);
    try std.testing.expectEqual(spider, find("Spider").?);
    try std.testing.expectEqual(zombie, find("Zombie").?);
    try std.testing.expectEqual(pig_zombie, find("PigZombie").?);
    try std.testing.expectEqual(squid, find("Squid").?);
    try std.testing.expectEqual(giant, find("Giant").?);
    try std.testing.expectEqual(@as(Id, 14), registered());
}

test "the vanilla mob types carry the entity ids the wire spawns them by" {
    try std.testing.expectEqual(pig, byWireId(90).?);
    try std.testing.expectEqual(sheep, byWireId(91).?);
    try std.testing.expectEqual(cow, byWireId(92).?);
    try std.testing.expectEqual(chicken, byWireId(93).?);
    try std.testing.expectEqual(slime, byWireId(55).?);
    try std.testing.expectEqual(wolf, byWireId(95).?);
    try std.testing.expectEqual(ghast, byWireId(56).?);
    try std.testing.expectEqual(creeper, byWireId(50).?);
    try std.testing.expectEqual(skeleton, byWireId(51).?);
    try std.testing.expectEqual(spider, byWireId(52).?);
    try std.testing.expectEqual(zombie, byWireId(54).?);
    try std.testing.expectEqual(pig_zombie, byWireId(57).?);
    try std.testing.expectEqual(squid, byWireId(94).?);
    try std.testing.expectEqual(giant, byWireId(53).?);
}

test "the monster flag marks exactly the mobs EntityMob covers" {
    const monsters = [_]Id{ creeper, skeleton, spider, zombie, pig_zombie, giant };
    for (0..registered()) |type_id| {
        const id: Id = @intCast(type_id);
        const want = std.mem.indexOfScalar(Id, &monsters, id) != null;
        try std.testing.expectEqual(want, get(id).monster);
    }
}

test "a type with no entity id of its own is never spawned over the wire" {
    defer reset();

    const custom = register(.{
        .name = "Rosebug",
        .spawn = get(pig).spawn,
        .tick = get(pig).tick,
        .takeDrops = get(pig).takeDrops,
        .store = get(pig).store,
        .load = get(pig).load,
        .destroy = get(pig).destroy,
    });

    try std.testing.expectEqual(@as(?u8, null), get(custom).wire_id);
}

test "every mob watches the burning flag vanilla puts in slot zero" {
    const gpa = std.testing.allocator;
    var rand: world.JavaRandom = .init(7);

    const animal = try get(cow).spawn(gpa, math.Vec3.init(0, 0, 0), &rand);
    defer get(cow).destroy(animal, gpa);

    var watched: Watched = .{};
    watch(cow, animal, &watched);
    try std.testing.expectEqual(@as(i8, 0), watched.view().byteAt(flags_key).?);

    animal.fire = 12;
    watched = .{};
    watch(cow, animal, &watched);
    try std.testing.expectEqual(@as(i8, 1), watched.view().byteAt(flags_key).?);

    animal.fire = 0;
    adopt(cow, animal, watched.view());
    try std.testing.expect(animal.fire > 0);
}

test "a registered type lands after the vanilla ones and answers to its name" {
    defer reset();

    const custom = register(.{
        .name = "Rosebug",
        .spawn = get(pig).spawn,
        .tick = get(pig).tick,
        .takeDrops = get(pig).takeDrops,
        .store = get(pig).store,
        .load = get(pig).load,
        .destroy = get(pig).destroy,
    });

    try std.testing.expectEqual(@as(Id, 14), custom);
    try std.testing.expectEqual(custom, find("Rosebug").?);
    try std.testing.expectEqualStrings("Rosebug", get(custom).name);
    try std.testing.expectEqual(@as(Id, 15), registered());
}
