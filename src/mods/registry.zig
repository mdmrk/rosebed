const std = @import("std");

const world = @import("world");
const zlua = @import("zlua");
const Lua = zlua.Lua;

const Hooks = @import("Hooks.zig");
const Manifest = @import("Manifest.zig");

pub const Registrar = struct {
    arena: std.mem.Allocator,
    hooks: *Hooks,
    mod_id: []const u8 = "",
    mod_folder: []const u8 = "",
    open: bool = true,
    block_textures: std.ArrayList(BlockTexture) = .empty,
};

pub const FaceFiles = std.EnumArray(world.Side, ?[]const u8);

pub const BlockTexture = struct {
    block: world.Block,
    folder: []const u8,
    faces: FaceFiles,
};

pub fn install(lua: *Lua, registrar: *Registrar) void {
    lua.newTable();
    const functions = [_]struct { name: [:0]const u8, function: zlua.CFn }{
        .{ .name = "register_block", .function = zlua.wrap(registerFn(world.Block, world.block.Def)) },
        .{ .name = "register_item", .function = zlua.wrap(registerFn(world.Item, world.item.Def)) },
        .{ .name = "override_block", .function = zlua.wrap(overrideFn(world.Block, world.block.Def, "block")) },
        .{ .name = "override_item", .function = zlua.wrap(overrideFn(world.Item, world.item.Def, "item")) },
    };
    for (functions) |entry| {
        lua.pushLightUserdata(registrar);
        lua.pushClosure(entry.function, 1);
        lua.setField(-2, entry.name);
    }
    lua.setGlobal("rosebed");
}

fn registerFn(comptime Registry: type, comptime Def: type) fn (*Lua) i32 {
    return struct {
        fn call(lua: *Lua) i32 {
            const registrar = context(lua);
            lua.checkType(1, .table);
            var definition: Def = .{ .key = namespacedKey(lua, registrar) };
            var extras: Extras(Def) = .{};
            readFields(Def, &definition, &extras, lua, registrar, 1, .skip_key);
            const claimed = Registry.claim(definition) catch |err| raise(lua, err, definition.key);
            attach(lua, registrar, claimed, extras);
            _ = lua.pushString(definition.key);
            return 1;
        }
    }.call;
}

fn overrideFn(comptime Registry: type, comptime Def: type, comptime noun: []const u8) fn (*Lua) i32 {
    return struct {
        fn call(lua: *Lua) i32 {
            const registrar = context(lua);
            const key = lua.checkString(1);
            lua.checkType(2, .table);
            const target = Registry.fromKey(key) orelse lua.raiseErrorStr("no " ++ noun ++ " is registered as '%s'", .{key.ptr});
            var definition: Def = target.def().*;
            var extras: Extras(Def) = .{};
            readFields(Def, &definition, &extras, lua, registrar, 2, .reject_key);
            target.register(definition);
            attach(lua, registrar, target, extras);
            return 0;
        }
    }.call;
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

fn namespacedKey(lua: *Lua, registrar: *Registrar) []const u8 {
    if (lua.getField(1, "key") != .string) lua.raiseErrorStr("'key' must be a string", .{});
    const local_key = lua.toString(-1) catch unreachable;
    if (!Manifest.validId(local_key)) lua.raiseErrorStr("'%s' is not a valid key", .{local_key.ptr});
    const key = std.fmt.allocPrintSentinel(registrar.arena, "{s}:{s}", .{ registrar.mod_id, local_key }, 0) catch
        raise(lua, error.OutOfMemory, local_key);
    lua.pop(1);
    return key;
}

const BlockExtras = struct {
    refs: Hooks.BlockRefs = .{},
    textures: ?FaceFiles = null,
};

fn Extras(comptime Def: type) type {
    return if (Def == world.block.Def) BlockExtras else struct {};
}

fn attach(lua: *Lua, registrar: *Registrar, target: anytype, extras: anytype) void {
    if (comptime @TypeOf(target) != world.Block) return;
    registrar.hooks.attachBlock(target, extras.refs);
    const faces = extras.textures orelse return;
    registrar.block_textures.append(registrar.arena, .{ .block = target, .folder = registrar.mod_folder, .faces = faces }) catch
        raise(lua, error.OutOfMemory, target.def().key);
}

const KeyField = enum { skip_key, reject_key };

fn readFields(comptime Def: type, definition: *Def, extras: *Extras(Def), lua: *Lua, registrar: *Registrar, table: i32, key_field: KeyField) void {
    lua.pushNil();
    while (lua.next(table)) {
        if (lua.typeOf(-2) != .string) lua.raiseErrorStr("field names must be strings", .{});
        const name = lua.toString(-2) catch unreachable;
        if (!(key_field == .skip_key and std.mem.eql(u8, name, "key"))) setField(Def, definition, extras, lua, registrar, name);
        lua.pop(1);
    }
}

fn setField(comptime Def: type, definition: *Def, extras: *Extras(Def), lua: *Lua, registrar: *Registrar, name: [:0]const u8) void {
    if (comptime Extras(Def) == BlockExtras) {
        if (std.mem.eql(u8, name, "textures")) {
            extras.textures = readTextures(lua, registrar);
            return;
        }
        inline for (@typeInfo(Hooks.BlockRefs).@"struct".fields) |field| {
            if (std.mem.eql(u8, field.name, name)) {
                if (lua.typeOf(-1) != .function) lua.raiseErrorStr("'%s' must be a function", .{name.ptr});
                lua.pushValue(-1);
                @field(extras.refs, field.name) = lua.ref(zlua.registry_index);
                return;
            }
        }
    }
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

fn readTextures(lua: *Lua, registrar: *Registrar) FaceFiles {
    var faces: FaceFiles = .initFill(null);
    switch (lua.typeOf(-1)) {
        .string => {
            faces = .initFill(texturePath(lua, registrar, -1, "textures"));
            return faces;
        },
        .table => {},
        else => lua.raiseErrorStr("'textures' must be a file name or a table of them", .{}),
    }

    var all: ?[]const u8 = null;
    var side: ?[]const u8 = null;
    var top: ?[]const u8 = null;
    var bottom: ?[]const u8 = null;
    var exact: FaceFiles = .initFill(null);
    const table = lua.getTop();
    lua.pushNil();
    while (lua.next(table)) {
        if (lua.typeOf(-2) != .string) lua.raiseErrorStr("texture faces must be named", .{});
        const face = lua.toString(-2) catch unreachable;
        const path = texturePath(lua, registrar, -1, face);
        if (std.mem.eql(u8, face, "all")) {
            all = path;
        } else if (std.mem.eql(u8, face, "side")) {
            side = path;
        } else if (std.mem.eql(u8, face, "top")) {
            top = path;
        } else if (std.mem.eql(u8, face, "bottom")) {
            bottom = path;
        } else if (std.meta.stringToEnum(world.Side, face)) |exact_side| {
            exact.set(exact_side, path);
        } else {
            lua.raiseErrorStr("'%s' is not a texture face", .{face.ptr});
        }
        lua.pop(1);
    }

    for (std.enums.values(world.Side)) |each| {
        const group = switch (each) {
            .up => top,
            .down => bottom,
            .north, .south, .west, .east => side,
        };
        faces.set(each, exact.get(each) orelse group orelse all);
    }
    return faces;
}

fn texturePath(lua: *Lua, registrar: *Registrar, index: i32, face: [:0]const u8) []const u8 {
    if (lua.typeOf(index) != .string) lua.raiseErrorStr("the '%s' texture must be a file name", .{face.ptr});
    const path = lua.toString(index) catch unreachable;
    const escapes = std.mem.indexOf(u8, path, "..") != null or std.mem.indexOfScalar(u8, path, '\\') != null;
    if (escapes or path.len == 0 or path[0] == '/' or !std.mem.endsWith(u8, path, ".png")) {
        lua.raiseErrorStr("'%s' is not a png inside the mod folder", .{path.ptr});
    }
    return registrar.arena.dupe(u8, path) catch raise(lua, error.OutOfMemory, path);
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
    hooks: Hooks,
    registrar: Registrar,
    vm: Vm,

    fn init(self: *Harness) !void {
        self.arena = .init(std.testing.allocator);
        self.hooks = .{};
        self.registrar = .{ .arena = self.arena.allocator(), .hooks = &self.hooks, .mod_id = "quartz" };
        self.vm = try .init(std.testing.allocator);
        install(self.vm.lua, &self.registrar);
    }

    fn deinit(self: *Harness) void {
        self.vm.deinit();
        self.arena.deinit();
        world.Block.resetRegistry();
        world.Item.resetRegistry();
    }

    fn expectFailure(self: *Harness, source: []const u8, message: []const u8) !void {
        try std.testing.expectError(error.ScriptFailed, self.vm.exec("=quartz", source));
        try std.testing.expect(std.mem.endsWith(u8, self.vm.errorMessage(), message));
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

    try harness.expectFailure("rosebed.register_block { key = 'marble', colour = 'white' }", "unknown field 'colour'");
    try harness.expectFailure("rosebed.register_block { key = 'marble', material = 'marble' }", "'marble' is not a valid 'material'");
    try harness.expectFailure("rosebed.register_block { key = 'marble', hardness = 'hard' }", "'hardness' must be a number");
    try harness.expectFailure("rosebed.register_block { key = 'stone:marble' }", "'stone:marble' is not a valid key");
    try harness.expectFailure("rosebed.register_block { name = 'Marble' }", "'key' must be a string");
    try harness.expectFailure("rosebed.register_item { key = 'gem', max_stack_size = 300 }", "'max_stack_size' is out of range");
    try harness.expectFailure("rosebed.register_block { key = 'marble', on_tick = 5 }", "'on_tick' must be a function");
    try harness.expectFailure("rosebed.register_item { key = 'gem', on_tick = function() end }", "unknown field 'on_tick'");
}

test "the same key cannot be registered twice" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try harness.vm.exec("=quartz", "rosebed.register_block { key = 'marble' }");
    try harness.expectFailure("rosebed.register_block { key = 'marble' }", "'quartz:marble' is already registered");
}

test "registering after loading has finished is refused" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    harness.registrar.open = false;
    try harness.expectFailure("rosebed.register_block { key = 'marble' }", "registration is closed once every mod has loaded");
    try harness.expectFailure("rosebed.override_block('stone', { hardness = 3 })", "registration is closed once every mod has loaded");
    try std.testing.expect(world.Block.fromKey("quartz:marble") == null);
}

test "overriding a vanilla block changes only the fields given" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    const before = world.Block.stone.def().*;
    try harness.vm.exec("=quartz", "rosebed.override_block('stone', { hardness = 3, name = 'Hard Stone' })");
    try std.testing.expectEqual(@as(f32, 3), world.Block.stone.def().hardness);
    try std.testing.expectEqualStrings("Hard Stone", world.Block.stone.def().name);
    try std.testing.expectEqualStrings("stone", world.Block.stone.def().key);
    try std.testing.expectEqual(before.material, world.Block.stone.material());
    try std.testing.expectEqual(before.explosion_resistance, world.Block.stone.def().explosion_resistance);
    try std.testing.expectEqual(world.Block.stone, world.Block.fromKey("stone").?);
}

test "overriding reaches items and blocks another mod registered" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try harness.vm.exec("=quartz",
        \\rosebed.register_block { key = "marble", hardness = 1 }
        \\rosebed.override_block("quartz:marble", { hardness = 4 })
        \\rosebed.override_item("shears", { max_stack_size = 16 })
    );
    try std.testing.expectEqual(@as(f32, 4), world.Block.fromKey("quartz:marble").?.def().hardness);
    try std.testing.expectEqual(@as(u8, 16), world.Item.shears.def().max_stack_size);
}

test "a block names the textures its faces are painted with" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    harness.registrar.mod_folder = "quartz_folder";

    try harness.vm.exec("=quartz",
        \\rosebed.register_block { key = "marble", textures = "marble.png" }
        \\rosebed.register_block {
        \\  key = "pillar",
        \\  textures = { all = "pillar.png", top = "textures/pillar_top.png", north = "pillar_front.png" },
        \\}
        \\rosebed.override_block("stone", { textures = { side = "granite.png" } })
    );
    const textures = harness.registrar.block_textures.items;
    try std.testing.expectEqual(3, textures.len);

    try std.testing.expectEqual(world.Block.fromKey("quartz:marble").?, textures[0].block);
    try std.testing.expectEqualStrings("quartz_folder", textures[0].folder);
    for (std.enums.values(world.Side)) |side| try std.testing.expectEqualStrings("marble.png", textures[0].faces.get(side).?);

    const pillar = textures[1].faces;
    try std.testing.expectEqualStrings("textures/pillar_top.png", pillar.get(.up).?);
    try std.testing.expectEqualStrings("pillar.png", pillar.get(.down).?);
    try std.testing.expectEqualStrings("pillar_front.png", pillar.get(.north).?);
    try std.testing.expectEqualStrings("pillar.png", pillar.get(.east).?);

    try std.testing.expectEqual(world.Block.stone, textures[2].block);
    try std.testing.expectEqualStrings("granite.png", textures[2].faces.get(.west).?);
    try std.testing.expect(textures[2].faces.get(.up) == null);
}

test "a texture must be a png inside the mod folder on a known face" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try harness.expectFailure("rosebed.register_block { key = 'a', textures = '../other/stone.png' }", "'../other/stone.png' is not a png inside the mod folder");
    try harness.expectFailure("rosebed.register_block { key = 'b', textures = '/etc/stone.png' }", "'/etc/stone.png' is not a png inside the mod folder");
    try harness.expectFailure("rosebed.register_block { key = 'c', textures = 'stone.jpg' }", "'stone.jpg' is not a png inside the mod folder");
    try harness.expectFailure("rosebed.register_block { key = 'd', textures = { front = 'd.png' } }", "'front' is not a texture face");
    try harness.expectFailure("rosebed.register_block { key = 'e', textures = 5 }", "'textures' must be a file name or a table of them");
    try harness.expectFailure("rosebed.register_block { key = 'f', textures = { top = 5 } }", "the 'top' texture must be a file name");
}

test "an override names an existing key and cannot rename it" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try harness.expectFailure("rosebed.override_block('quartz:nothing', { hardness = 3 })", "no block is registered as 'quartz:nothing'");
    try harness.expectFailure("rosebed.override_item('stick_of_truth', {})", "no item is registered as 'stick_of_truth'");
    try harness.expectFailure("rosebed.override_block('stone', { key = 'granite' })", "unknown field 'key'");
    try std.testing.expectEqualStrings("stone", world.Block.stone.def().key);
}
