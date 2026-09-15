const std = @import("std");

const world = @import("world");
const zlua = @import("zlua");
const Lua = zlua.Lua;

const Hooks = @This();

current_world: ?*world.World = null,

pub fn install(self: *Hooks, lua: *Lua) void {
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

fn currentWorld(lua: *Lua) *world.World {
    const self: *Hooks = @ptrCast(@alignCast(@constCast(lua.toPointer(Lua.upvalueIndex(1)).?)));
    return self.current_world orelse lua.raiseErrorStr("the world can only be reached from a callback", .{});
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
