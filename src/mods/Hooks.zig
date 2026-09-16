const std = @import("std");

const game = @import("game");
const math = @import("math");
const world = @import("world");
const zlua = @import("zlua");
const Lua = zlua.Lua;

const Hooks = @This();

lua: ?*Lua = null,
current_world: ?*world.World = null,
current_rand: ?*world.JavaRandom = null,
current_mob: ?*game.Animal = null,
block_refs: [256]BlockRefs = @splat(.{}),
item_refs: [world.item.def_capacity]ItemRefs = @splat(.{}),

pub var active: ?*Hooks = null;

pub const ItemRefs = struct {
    on_use: ?i32 = null,
};

pub fn attachItem(self: *Hooks, item: world.Item, refs: ItemRefs) void {
    const ref = refs.on_use orelse return;
    self.item_refs[@intFromEnum(item) - world.item.first_item_id].on_use = ref;
    var definition = item.def().*;
    definition.on_use = itemUsed;
    item.register(definition);
}

fn itemUsed(world_map: *world.World, pos: world.BlockPos, side: world.Side, item: world.Item, damage: u16) std.mem.Allocator.Error!bool {
    const self = active orelse return false;
    const ref = self.item_refs[@intFromEnum(item) - world.item.first_item_id].on_use orelse return false;
    return self.call(world_map, ref, pos, .{ @tagName(side), damage });
}

pub const BlockRefs = struct {
    drop: ?i32 = null,
    on_tick: ?i32 = null,
    on_random_tick: ?i32 = null,
    on_neighbor_change: ?i32 = null,
    on_activated: ?i32 = null,
};

pub fn attachBlock(self: *Hooks, block: world.Block, refs: BlockRefs) void {
    const slot = &self.block_refs[@intFromEnum(block)];
    var definition = block.def().*;
    inline for (@typeInfo(BlockRefs).@"struct".fields) |field| {
        if (@field(refs, field.name)) |ref| {
            @field(slot, field.name) = ref;
            @field(definition, field.name) = if (comptime std.mem.eql(u8, field.name, "on_activated"))
                activated
            else if (comptime std.mem.eql(u8, field.name, "drop"))
                dropped
            else
                blockEvent(field.name);
        }
    }
    block.register(definition);
}

fn blockEvent(comptime event: []const u8) *const fn (*world.World, world.BlockPos, world.Block) std.mem.Allocator.Error!void {
    return &struct {
        fn run(world_map: *world.World, pos: world.BlockPos, block: world.Block) std.mem.Allocator.Error!void {
            const self = active orelse return;
            const ref = @field(self.block_refs[@intFromEnum(block)], event) orelse return;
            _ = self.call(world_map, ref, pos, .{});
        }
    }.run;
}

fn activated(world_map: *world.World, pos: world.BlockPos, block: world.Block) std.mem.Allocator.Error!bool {
    const self = active orelse return false;
    const ref = self.block_refs[@intFromEnum(block)].on_activated orelse return false;
    return self.call(world_map, ref, pos, .{});
}

fn dropped(block: world.Block, meta: u4, rand: *world.JavaRandom) ?world.Stack {
    const self = active orelse return null;
    const ref = self.block_refs[@intFromEnum(block)].drop orelse return null;
    return self.rollDrop(ref, meta, rand);
}

pub fn rollDrop(self: *Hooks, ref: i32, meta: ?u4, rand: *world.JavaRandom) ?world.Stack {
    const lua = self.lua.?;

    const outer_rand = self.current_rand;
    self.current_rand = rand;
    defer self.current_rand = outer_rand;

    _ = lua.getIndexRaw(zlua.registry_index, ref);
    const args: i32 = if (meta) |value| blk: {
        lua.pushInteger(value);
        break :blk 1;
    } else 0;
    lua.protectedCall(.{ .args = args, .results = 3 }) catch {
        std.log.warn("a mod drop failed: {s}", .{lua.toString(-1) catch "(no message)"});
        lua.pop(1);
        return null;
    };
    defer lua.pop(3);

    if (lua.typeOf(-3) != .string) return null;
    const key = lua.toString(-3) catch unreachable;
    const id: world.Id = if (world.Block.fromKey(key)) |block_id|
        .{ .block = block_id }
    else if (world.Item.fromKey(key)) |item_id|
        .{ .item = item_id }
    else {
        std.log.warn("a mod dropped '{s}', which nothing is registered as", .{key});
        return null;
    };

    const count = std.math.cast(u8, lua.toInteger(-2) catch 1) orelse return null;
    if (count == 0) return null;
    return .{ .id = id, .count = count, .meta = std.math.cast(u16, lua.toInteger(-1) catch 0) orelse 0 };
}

pub fn callMob(self: *Hooks, ref: i32, animal: *game.Animal, world_map: *world.World, rand: *world.JavaRandom) void {
    const lua = self.lua orelse return;

    const outer_world = self.current_world;
    const outer_rand = self.current_rand;
    const outer_mob = self.current_mob;
    self.current_world = world_map;
    self.current_rand = rand;
    self.current_mob = animal;
    defer {
        self.current_world = outer_world;
        self.current_rand = outer_rand;
        self.current_mob = outer_mob;
    }

    _ = lua.getIndexRaw(zlua.registry_index, ref);
    lua.pushInteger(math.util.floorDouble(animal.base.position.x));
    lua.pushInteger(math.util.floorDouble(animal.base.position.y));
    lua.pushInteger(math.util.floorDouble(animal.base.position.z));
    lua.protectedCall(.{ .args = 3, .results = 0 }) catch {
        std.log.warn("a mod mob failed: {s}", .{lua.toString(-1) catch "(no message)"});
        lua.pop(1);
    };
}

fn mobPosition(lua: *Lua) i32 {
    const animal = currentMob(lua);
    lua.pushNumber(animal.base.position.x);
    lua.pushNumber(animal.base.position.y);
    lua.pushNumber(animal.base.position.z);
    return 3;
}

fn mobHealth(lua: *Lua) i32 {
    const animal = currentMob(lua);
    lua.pushInteger(animal.health);
    lua.pushInteger(animal.max_health);
    return 2;
}

fn mobHurt(lua: *Lua) i32 {
    const self = hooks(lua);
    const animal = self.current_mob orelse lua.raiseErrorStr("a mob is only reached from its own callback", .{});
    const world_map = self.current_world orelse lua.raiseErrorStr("a mob is only reached from its own callback", .{});
    const amount = std.math.cast(i32, lua.checkInteger(1)) orelse lua.argError(1, "the damage is out of range");
    if (amount < 0) lua.argError(1, "the damage cannot be negative");
    _ = animal.hurt(world_map, amount, null, self.current_rand orelse &world_map.rand);
    return 0;
}

fn currentMob(lua: *Lua) *game.Animal {
    return hooks(lua).current_mob orelse lua.raiseErrorStr("a mob is only reached from its own callback", .{});
}

fn random(lua: *Lua) i32 {
    const self = hooks(lua);
    const rand = self.current_rand orelse blk: {
        const world_map = self.current_world orelse lua.raiseErrorStr("random only rolls inside a callback", .{});
        break :blk &world_map.rand;
    };
    const bound = lua.checkInteger(1);
    if (bound <= 0) lua.argError(1, "the bound must be positive");
    lua.pushInteger(rand.nextIntBound(std.math.cast(i32, bound) orelse lua.argError(1, "the bound is too large")));
    return 1;
}

fn call(self: *Hooks, world_map: *world.World, ref: i32, pos: world.BlockPos, extra: anytype) bool {
    const lua = self.lua.?;
    const outer_world = self.current_world;
    self.current_world = world_map;
    defer self.current_world = outer_world;

    _ = lua.getIndexRaw(zlua.registry_index, ref);
    lua.pushInteger(pos.x);
    lua.pushInteger(pos.y);
    lua.pushInteger(pos.z);
    inline for (extra) |value| {
        if (comptime @TypeOf(value) == u16) lua.pushInteger(value) else _ = lua.pushString(value);
    }
    lua.protectedCall(.{ .args = 3 + extra.len, .results = 1 }) catch {
        std.log.warn("a mod callback failed: {s}", .{lua.toString(-1) catch "(no message)"});
        lua.pop(1);
        return false;
    };
    const handled = lua.toBoolean(-1);
    lua.pop(1);
    return handled;
}

pub fn install(self: *Hooks, lua: *Lua) void {
    self.lua = lua;
    if (lua.getGlobal("rosebed") != .table) {
        lua.pop(1);
        lua.newTable();
        lua.pushValue(-1);
        lua.setGlobal("rosebed");
    }
    lua.newTable();
    const functions = [_]struct { name: [:0]const u8, function: zlua.CFn }{
        .{ .name = "get_block", .function = zlua.wrap(getBlock) },
        .{ .name = "get_meta", .function = zlua.wrap(getMeta) },
        .{ .name = "set_block", .function = zlua.wrap(setBlock) },
        .{ .name = "set_meta", .function = zlua.wrap(setMeta) },
        .{ .name = "schedule_tick", .function = zlua.wrap(scheduleTick) },
    };
    for (functions) |entry| {
        lua.pushLightUserdata(self);
        lua.pushClosure(entry.function, 1);
        lua.setField(-2, entry.name);
    }
    lua.setField(-2, "world");

    lua.newTable();
    const mob_functions = [_]struct { name: [:0]const u8, function: zlua.CFn }{
        .{ .name = "position", .function = zlua.wrap(mobPosition) },
        .{ .name = "health", .function = zlua.wrap(mobHealth) },
        .{ .name = "hurt", .function = zlua.wrap(mobHurt) },
    };
    for (mob_functions) |entry| {
        lua.pushLightUserdata(self);
        lua.pushClosure(entry.function, 1);
        lua.setField(-2, entry.name);
    }
    lua.setField(-2, "mob");

    lua.pushLightUserdata(self);
    lua.pushClosure(zlua.wrap(random), 1);
    lua.setField(-2, "random");
    lua.pop(1);
}

fn getBlock(lua: *Lua) i32 {
    const world_map = currentWorld(lua);
    const key = world_map.getBlock(position(lua, 1)).def().key;
    if (key.len == 0) lua.pushNil() else _ = lua.pushString(key);
    return 1;
}

fn getMeta(lua: *Lua) i32 {
    const world_map = currentWorld(lua);
    lua.pushInteger(world_map.getBlockMetadata(position(lua, 1)));
    return 1;
}

fn setBlock(lua: *Lua) i32 {
    const world_map = currentWorld(lua);
    const pos = position(lua, 1);
    const block = blockArgument(lua, 4);
    const changed = switch (lua.typeOf(5)) {
        .none, .nil => world_map.setBlockWithNotify(pos, block),
        else => world_map.setBlockAndMetadataWithNotify(pos, block, metadata(lua, 5)),
    };
    changed catch lua.raiseErrorStr("out of memory", .{});
    return 0;
}

fn setMeta(lua: *Lua) i32 {
    const world_map = currentWorld(lua);
    world_map.setBlockMetadataWithNotify(position(lua, 1), metadata(lua, 4)) catch lua.raiseErrorStr("out of memory", .{});
    return 0;
}

fn scheduleTick(lua: *Lua) i32 {
    const world_map = currentWorld(lua);
    const pos = position(lua, 1);
    const delay = std.math.cast(u32, lua.checkInteger(4)) orelse lua.argError(4, "delay must be a whole number of ticks");
    world_map.scheduleBlockUpdate(pos, world_map.getBlock(pos), delay) catch lua.raiseErrorStr("out of memory", .{});
    return 0;
}

fn hooks(lua: *Lua) *Hooks {
    return @ptrCast(@alignCast(@constCast(lua.toPointer(Lua.upvalueIndex(1)).?)));
}

fn currentWorld(lua: *Lua) *world.World {
    return hooks(lua).current_world orelse lua.raiseErrorStr("the world can only be reached from a callback", .{});
}

fn position(lua: *Lua, first: i32) world.BlockPos {
    return .init(coordinate(lua, first), coordinate(lua, first + 1), coordinate(lua, first + 2));
}

fn coordinate(lua: *Lua, arg: i32) i32 {
    return std.math.cast(i32, lua.checkInteger(arg)) orelse lua.argError(arg, "coordinate out of range");
}

fn metadata(lua: *Lua, arg: i32) u4 {
    return std.math.cast(u4, lua.checkInteger(arg)) orelse lua.argError(arg, "metadata must be 0 to 15");
}

fn blockArgument(lua: *Lua, arg: i32) world.Block {
    const key = lua.checkString(arg);
    return world.Block.fromKey(key) orelse lua.raiseErrorStr("no block is registered as '%s'", .{key.ptr});
}

const Vm = @import("Vm.zig");

const Harness = struct {
    vm: Vm,
    hooks: Hooks,
    world_map: world.World,

    fn init(self: *Harness) !void {
        self.vm = try .init(std.testing.allocator);
        self.hooks = .{};
        self.hooks.install(self.vm.lua);
        self.world_map = .init(std.testing.allocator);
        var chunk_x: i32 = -1;
        while (chunk_x <= 1) : (chunk_x += 1) {
            var chunk_z: i32 = -1;
            while (chunk_z <= 1) : (chunk_z += 1) _ = try self.world_map.createChunk(chunk_x, chunk_z);
        }
    }

    fn deinit(self: *Harness) void {
        self.world_map.deinit();
        self.vm.deinit();
    }

    fn expectFailure(self: *Harness, source: []const u8, message: []const u8) !void {
        try std.testing.expectError(error.ScriptFailed, self.vm.exec("=test", source));
        try std.testing.expect(std.mem.endsWith(u8, self.vm.errorMessage(), message));
    }
};

test "a script reads and writes blocks in the world it is given" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    harness.hooks.current_world = &harness.world_map;

    try harness.vm.exec("=test",
        \\local w = rosebed.world
        \\assert(w.get_block(4, 10, 4) == "air")
        \\w.set_block(4, 10, 4, "stone")
        \\assert(w.get_block(4, 10, 4) == "stone")
        \\w.set_block(5, 10, 4, "log", 2)
        \\assert(w.get_block(5, 10, 4) == "log")
        \\assert(w.get_meta(5, 10, 4) == 2)
        \\w.set_meta(5, 10, 4, 1)
        \\assert(w.get_meta(5, 10, 4) == 1)
    );
    try std.testing.expectEqual(world.Block.stone, harness.world_map.getBlock(.init(4, 10, 4)));
    try std.testing.expectEqual(@as(u4, 1), harness.world_map.getBlockMetadata(.init(5, 10, 4)));
}

var ticks_seen: usize = 0;

fn countTick(_: *world.World, _: world.BlockPos, _: world.Block) std.mem.Allocator.Error!void {
    ticks_seen += 1;
}

test "a script can schedule a block's next tick" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    defer world.Block.resetRegistry();
    harness.hooks.current_world = &harness.world_map;
    ticks_seen = 0;

    _ = try world.Block.claim(.{ .key = "test:ticker", .on_tick = countTick });
    try harness.vm.exec("=test",
        \\rosebed.world.set_block(4, 10, 4, "test:ticker")
        \\rosebed.world.schedule_tick(4, 10, 4, 1)
    );
    harness.world_map.time += 2;
    try harness.world_map.tickUpdates();
    try std.testing.expectEqual(@as(usize, 1), ticks_seen);
}

test "the world is out of reach outside a callback" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try harness.expectFailure("rosebed.world.get_block(0, 0, 0)", "the world can only be reached from a callback");
}

test "bad arguments are reported" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    harness.hooks.current_world = &harness.world_map;

    try harness.expectFailure("rosebed.world.set_block(0, 10, 0, 'granite')", "no block is registered as 'granite'");
    try harness.expectFailure("rosebed.world.set_meta(0, 10, 0, 16)", "metadata must be 0 to 15)");
    try harness.expectFailure("rosebed.world.get_block(0, 1e12, 0)", "coordinate out of range)");
    try harness.expectFailure("rosebed.world.schedule_tick(0, 10, 0, -1)", "delay must be a whole number of ticks)");
}
