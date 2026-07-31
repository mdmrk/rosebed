const std = @import("std");

const math = @import("math");
const world = @import("world");

const Animal = @import("animal.zig");
const Player = @import("player.zig");

pub const Drops = struct {
    count: u8,
    stack: world.Stack,
};

pub const Tick = struct {
    entities: *anyopaque,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    player: *Player,
    view: Animal.PlayerView,
    rand: *world.JavaRandom,
};

pub const Type = struct {
    name: []const u8,
    spawn: *const fn (std.mem.Allocator, math.Vec3, *world.JavaRandom) anyerror!*Animal,
    tick: *const fn (*Animal, std.mem.Allocator, *const world.World, Animal.PlayerView, *world.JavaRandom) anyerror!void,
    takeDrops: *const fn (*Animal) ?Drops,
    store: *const fn (*Animal, std.mem.Allocator) anyerror!world.nbt.Tag,
    load: *const fn (std.mem.Allocator, world.nbt.Compound) anyerror!?*Animal,
    destroy: *const fn (*Animal, std.mem.Allocator) void,
    hurt: *const fn (*Animal, i32, ?math.Vec3, *world.JavaRandom) bool = hurtBase,
    afterTick: *const fn (*Animal, Tick) anyerror!void = ignore,
    onDeath: *const fn (*Animal, Tick) anyerror!void = ignore,
};

fn ignore(_: *Animal, _: Tick) anyerror!void {}

fn hurtBase(animal: *Animal, amount: i32, source: ?math.Vec3, rand: *world.JavaRandom) bool {
    return animal.hurt(amount, source, rand);
}

pub const Id = u16;
pub const capacity: usize = 64;

const vanilla = [_]Type{
    @import("pig.zig").mob_type,
    @import("sheep.zig").mob_type,
    @import("cow.zig").mob_type,
    @import("chicken.zig").mob_type,
    @import("slime.zig").mob_type,
};

pub const pig: Id = 0;
pub const sheep: Id = 1;
pub const cow: Id = 2;
pub const chicken: Id = 3;
pub const slime: Id = 4;

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
    try std.testing.expectEqual(@as(Id, 5), registered());
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

    try std.testing.expectEqual(@as(Id, 5), custom);
    try std.testing.expectEqual(custom, find("Rosebug").?);
    try std.testing.expectEqualStrings("Rosebug", get(custom).name);
    try std.testing.expectEqual(@as(Id, 6), registered());
}
