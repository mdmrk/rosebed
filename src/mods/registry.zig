const std = @import("std");

const world = @import("world");
const zlua = @import("zlua");
const Lua = zlua.Lua;

const Manifest = @import("Manifest.zig");

pub const Registrar = struct {
    arena: std.mem.Allocator,
    mod_id: []const u8 = "",
    open: bool = true,
};

pub fn install(lua: *Lua, registrar: *Registrar) void {
    lua.newTable();
    lua.pushLightUserdata(registrar);
    lua.pushClosure(zlua.wrap(registerBlock), 1);
    lua.setField(-2, "register_block");
    lua.pushLightUserdata(registrar);
    lua.pushClosure(zlua.wrap(registerItem), 1);
    lua.setField(-2, "register_item");
    lua.setGlobal("rosebed");
}

fn registerBlock(lua: *Lua) i32 {
    const registrar = context(lua);
    const definition = readDef(world.block.Def, lua, registrar);
    _ = world.Block.claim(definition) catch |err| raise(lua, err, definition.key);
    _ = lua.pushString(definition.key);
    return 1;
}

fn registerItem(lua: *Lua) i32 {
    const registrar = context(lua);
    const definition = readDef(world.item.Def, lua, registrar);
    _ = world.Item.claim(definition) catch |err| raise(lua, err, definition.key);
    _ = lua.pushString(definition.key);
    return 1;
}

fn context(lua: *Lua) *Registrar {
    const registrar: *Registrar = @ptrCast(@alignCast(@constCast(lua.toPointer(Lua.upvalueIndex(1)).?)));
    if (!registrar.open) lua.raiseErrorStr("registration is closed once every mod has loaded", .{});
    return registrar;
}

fn raise(lua: *Lua, err: error{ DuplicateKey, RegistryFull, OutOfMemory }, key: []const u8) noreturn {
    const text = switch (err) {
        error.DuplicateKey => "'%s' is already registered",
        error.RegistryFull => "no free id is left for '%s'",
        error.OutOfMemory => "out of memory registering '%s'",
    };
    lua.raiseErrorStr(text, .{key.ptr});
}

fn readDef(comptime Def: type, lua: *Lua, registrar: *Registrar) Def {
    lua.checkType(1, .table);
    var definition: Def = .{};

    if (lua.getField(1, "key") != .string) lua.raiseErrorStr("'key' must be a string", .{});
    const local_key = lua.toString(-1) catch unreachable;
    if (!Manifest.validId(local_key)) lua.raiseErrorStr("'%s' is not a valid key", .{local_key.ptr});
    definition.key = std.fmt.allocPrintSentinel(registrar.arena, "{s}:{s}", .{ registrar.mod_id, local_key }, 0) catch
        raise(lua, error.OutOfMemory, local_key);
    lua.pop(1);

    lua.pushNil();
    while (lua.next(1)) {
        if (lua.typeOf(-2) != .string) lua.raiseErrorStr("field names must be strings", .{});
        const name = lua.toString(-2) catch unreachable;
        if (!std.mem.eql(u8, name, "key")) setField(Def, &definition, lua, registrar, name);
        lua.pop(1);
    }
    return definition;
}

fn setField(comptime Def: type, definition: *Def, lua: *Lua, registrar: *Registrar, name: [:0]const u8) void {
    inline for (@typeInfo(Def).@"struct".fields) |field| {
        if (comptime !std.mem.eql(u8, field.name, "key") and readable(field.type)) {
            if (std.mem.eql(u8, field.name, name)) {
                @field(definition, field.name) = readValue(field.type, lua, registrar, name);
                return;
            }
        }
    }
    lua.raiseErrorStr("unknown field '%s'", .{name.ptr});
}

fn readable(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .bool, .int, .float, .@"enum" => true,
        .optional => |optional| readable(optional.child),
        .pointer => T == []const u8,
        else => false,
    };
}

fn readValue(comptime T: type, lua: *Lua, registrar: *Registrar, name: [:0]const u8) T {
    switch (@typeInfo(T)) {
        .optional => |optional| return readValue(optional.child, lua, registrar, name),
        .bool => {
            if (lua.typeOf(-1) != .boolean) lua.raiseErrorStr("'%s' must be a boolean", .{name.ptr});
            return lua.toBoolean(-1);
        },
        .int => {
            const number = lua.toInteger(-1) catch lua.raiseErrorStr("'%s' must be an integer", .{name.ptr});
            return std.math.cast(T, number) orelse lua.raiseErrorStr("'%s' is out of range", .{name.ptr});
        },
        .float => {
            if (lua.typeOf(-1) != .number) lua.raiseErrorStr("'%s' must be a number", .{name.ptr});
            return @floatCast(lua.toNumber(-1) catch unreachable);
        },
        .@"enum" => {
            if (lua.typeOf(-1) != .string) lua.raiseErrorStr("'%s' must be a string", .{name.ptr});
            const tag = lua.toString(-1) catch unreachable;
            return std.meta.stringToEnum(T, tag) orelse lua.raiseErrorStr("'%s' is not a valid '%s'", .{ tag.ptr, name.ptr });
        },
        .pointer => {
            if (lua.typeOf(-1) != .string) lua.raiseErrorStr("'%s' must be a string", .{name.ptr});
            const text = lua.toString(-1) catch unreachable;
            return registrar.arena.dupe(u8, text) catch raise(lua, error.OutOfMemory, name);
        },
        else => comptime unreachable,
    }
}

const Vm = @import("Vm.zig");

const Harness = struct {
    arena: std.heap.ArenaAllocator,
    registrar: Registrar,
    vm: Vm,

    fn init(self: *Harness) !void {
        self.arena = .init(std.testing.allocator);
        self.registrar = .{ .arena = self.arena.allocator(), .mod_id = "quartz" };
        self.vm = try .init(std.testing.allocator);
        install(self.vm.lua, &self.registrar);
    }

    fn deinit(self: *Harness) void {
        self.vm.deinit();
        self.arena.deinit();
        world.Block.resetRegistry();
        world.Item.resetRegistry();
    }
};

test "a block registered from lua lands in the registry under its mod's namespace" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try harness.vm.exec("=quartz",
        \\local key = rosebed.register_block {
        \\  key = "marble",
        \\  name = "Marble",
        \\  material = "rock",
        \\  step_sound = "stone",
        \\  hardness = 1.5,
        \\  explosion_resistance = 10,
        \\  translucent = false,
        \\}
        \\assert(key == "quartz:marble")
    );
    const marble = world.Block.fromKey("quartz:marble").?;
    try std.testing.expectEqual(@as(world.Block, @enumFromInt(97)), marble);
    try std.testing.expectEqualStrings("Marble", marble.def().name);
    try std.testing.expectEqual(world.Material.rock, marble.material());
    try std.testing.expectEqual(world.block.StepSound.stone, marble.stepSound());
    try std.testing.expectEqual(@as(f32, 1.5), marble.def().hardness);
    try std.testing.expectEqual(@as(f32, 10), marble.def().explosion_resistance);
}

test "an item registered from lua lands in the registry under its mod's namespace" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try harness.vm.exec("=quartz",
        \\rosebed.register_item { key = "gem", name = "Quartz Gem", max_stack_size = 16 }
    );
    const gem = world.Item.fromKey("quartz:gem").?;
    try std.testing.expectEqual(@as(world.Item, @enumFromInt(360)), gem);
    try std.testing.expectEqualStrings("Quartz Gem", gem.def().name);
    try std.testing.expectEqual(@as(u8, 16), gem.def().max_stack_size);
}

test "a bad definition fails the script with a message naming the problem" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    const cases = [_]struct { source: []const u8, message: []const u8 }{
        .{ .source = "rosebed.register_block { key = 'marble', colour = 'white' }", .message = "unknown field 'colour'" },
        .{ .source = "rosebed.register_block { key = 'marble', material = 'marble' }", .message = "'marble' is not a valid 'material'" },
        .{ .source = "rosebed.register_block { key = 'marble', hardness = 'hard' }", .message = "'hardness' must be a number" },
        .{ .source = "rosebed.register_block { key = 'stone:marble' }", .message = "'stone:marble' is not a valid key" },
        .{ .source = "rosebed.register_block { name = 'Marble' }", .message = "'key' must be a string" },
        .{ .source = "rosebed.register_item { key = 'gem', max_stack_size = 300 }", .message = "'max_stack_size' is out of range" },
    };
    for (cases) |case| {
        try std.testing.expectError(error.ScriptFailed, harness.vm.exec("=quartz", case.source));
        try std.testing.expect(std.mem.endsWith(u8, harness.vm.errorMessage(), case.message));
    }
}

test "the same key cannot be registered twice" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try harness.vm.exec("=quartz", "rosebed.register_block { key = 'marble' }");
    try std.testing.expectError(error.ScriptFailed, harness.vm.exec("=quartz", "rosebed.register_block { key = 'marble' }"));
    try std.testing.expect(std.mem.endsWith(u8, harness.vm.errorMessage(), "'quartz:marble' is already registered"));
}

test "registering after loading has finished is refused" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    harness.registrar.open = false;
    try std.testing.expectError(error.ScriptFailed, harness.vm.exec("=quartz", "rosebed.register_block { key = 'marble' }"));
    try std.testing.expect(std.mem.endsWith(u8, harness.vm.errorMessage(), "registration is closed once every mod has loaded"));
    try std.testing.expect(world.Block.fromKey("quartz:marble") == null);
}
