const std = @import("std");

const game = @import("game");
const math = @import("math");
const world = @import("world");
const zlua = @import("zlua");
const Lua = zlua.Lua;

const Hooks = @import("Hooks.zig");
const Manifest = @import("Manifest.zig");
const mobs = @import("mobs.zig");

pub const Registrar = struct {
    arena: std.mem.Allocator,
    hooks: *Hooks,
    mod_id: []const u8 = "",
    mod_folder: []const u8 = "",
    open: bool = true,
    block_textures: std.ArrayList(BlockTexture) = .empty,
    item_textures: std.ArrayList(ItemTexture) = .empty,
};

pub const ItemTexture = struct {
    item: world.Item,
    folder: []const u8,
    file: []const u8,
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
        .{ .name = "register_mob", .function = zlua.wrap(registerMob) },
        .{ .name = "register_recipe", .function = zlua.wrap(registerRecipe) },
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

const ItemExtras = struct {
    refs: Hooks.ItemRefs = .{},
    texture: ?[]const u8 = null,
};

const MobExtras = struct {
    refs: mobs.Refs = .{},
};

fn Extras(comptime Def: type) type {
    return switch (Def) {
        world.block.Def => BlockExtras,
        world.item.Def => ItemExtras,
        mobs.Def => MobExtras,
        else => comptime unreachable,
    };
}

fn attach(lua: *Lua, registrar: *Registrar, target: anytype, extras: anytype) void {
    switch (@TypeOf(target)) {
        world.Block => {
            registrar.hooks.attachBlock(target, extras.refs);
            const faces = extras.textures orelse return;
            registrar.block_textures.append(registrar.arena, .{ .block = target, .folder = registrar.mod_folder, .faces = faces }) catch
                raise(lua, error.OutOfMemory, target.def().key);
        },
        world.Item => {
            registrar.hooks.attachItem(target, extras.refs);
            const file = extras.texture orelse return;
            registrar.item_textures.append(registrar.arena, .{ .item = target, .folder = registrar.mod_folder, .file = file }) catch
                raise(lua, error.OutOfMemory, target.def().key);
        },
        else => comptime unreachable,
    }
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
        if (std.mem.eql(u8, name, "shape")) {
            definition.shape = readShape(lua);
            return;
        }
    } else if (comptime Extras(Def) == ItemExtras) {
        if (std.mem.eql(u8, name, "texture")) {
            extras.texture = texturePath(lua, registrar, -1, "texture");
            return;
        }
    }
    inline for (@typeInfo(@TypeOf(extras.refs)).@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, name)) {
            if (lua.typeOf(-1) != .function) lua.raiseErrorStr("'%s' must be a function", .{name.ptr});
            lua.pushValue(-1);
            @field(extras.refs, field.name) = lua.ref(zlua.registry_index);
            return;
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

fn registerMob(lua: *Lua) i32 {
    const registrar = context(lua);
    lua.checkType(1, .table);
    var definition: mobs.Def = .{ .key = namespacedKey(lua, registrar) };
    var extras: MobExtras = .{};
    readFields(mobs.Def, &definition, &extras, lua, registrar, 1, .skip_key);
    if (!(definition.width > 0) or !(definition.height > 0)) lua.raiseErrorStr("'%s' needs a positive width and height", .{definition.key.ptr});
    if (definition.health <= 0) lua.raiseErrorStr("'%s' needs at least one heart's worth of health", .{definition.key.ptr});
    _ = mobs.claim(definition, extras.refs) catch |err| raise(lua, err, definition.key);
    _ = lua.pushString(definition.key);
    return 1;
}

const max_grid = game.crafting.workbench_grid_size;

fn registerRecipe(lua: *Lua) i32 {
    _ = context(lua);
    lua.checkType(1, .table);

    if (lua.getField(1, "result") != .string) lua.raiseErrorStr("'result' must be a registered key", .{});
    const result = keyedId(lua, lua.toString(-1) catch unreachable);
    lua.pop(1);
    const count = recipeNumber(lua, u8, "count", 1);
    const meta = recipeNumber(lua, u16, "meta", 0);

    if (lua.getField(1, "grid") == .table) {
        game.crafting.register(readGrid(lua, result, count, meta)) catch lua.raiseErrorStr("no room is left for another recipe", .{});
        return 0;
    }
    lua.pop(1);

    if (lua.getField(1, "any") == .table) {
        game.crafting.registerShapeless(readShapeless(lua, result, count, meta)) catch lua.raiseErrorStr("no room is left for another recipe", .{});
        return 0;
    }
    lua.pop(1);
    lua.raiseErrorStr("a recipe is laid out in a 'grid' or gathered in 'any'", .{});
}

fn keyedId(lua: *Lua, key: [:0]const u8) world.Id {
    if (world.Block.fromKey(key)) |block| return .{ .block = block };
    if (world.Item.fromKey(key)) |item| return .{ .item = item };
    lua.raiseErrorStr("nothing is registered as '%s'", .{key.ptr});
}

fn recipeNumber(lua: *Lua, comptime T: type, name: [:0]const u8, fallback: T) T {
    defer lua.pop(1);
    if (lua.getField(1, name) == .nil) return fallback;
    const value = lua.toInteger(-1) catch lua.raiseErrorStr("'%s' must be a whole number", .{name.ptr});
    return std.math.cast(T, value) orelse lua.raiseErrorStr("'%s' is out of range", .{name.ptr});
}

fn readGrid(lua: *Lua, result: world.Id, count: u8, meta: u16) game.crafting.Recipe {
    const grid = lua.getTop();
    if (lua.getField(1, "where") != .table) lua.raiseErrorStr("'where' names what each letter of the grid is", .{});
    const where = lua.getTop();

    var pattern: [max_grid * max_grid]?game.crafting.Ingredient = @splat(null);
    var width: usize = 0;
    var height: usize = 0;
    while (height < max_grid) : (height += 1) {
        if (lua.getIndex(grid, @intCast(height + 1)) != .string) {
            lua.pop(1);
            break;
        }
        const row = lua.toString(-1) catch unreachable;
        if (height == 0) width = row.len;
        if (row.len == 0 or row.len > max_grid) lua.raiseErrorStr("a grid row is 1 to 3 letters wide", .{});
        if (row.len != width) lua.raiseErrorStr("every row of a grid is the same width", .{});
        for (row, 0..) |letter, column| {
            if (letter == ' ' or letter == '.') continue;
            var name: [1:0]u8 = .{letter};
            if (lua.getField(where, &name) != .string) lua.raiseErrorStr("'where' does not name '%s'", .{&name});
            pattern[column + height * width] = .{ .id = keyedId(lua, lua.toString(-1) catch unreachable) };
            lua.pop(1);
        }
        lua.pop(1);
    }
    if (height == 0) lua.raiseErrorStr("a grid needs at least one row", .{});
    lua.pop(1);

    return .{
        .width = @intCast(width),
        .height = @intCast(height),
        .pattern = pattern,
        .output_id = result,
        .output_count = count,
        .output_meta = meta,
    };
}

fn readShapeless(lua: *Lua, result: world.Id, count: u8, meta: u16) game.crafting.ShapelessRecipe {
    const list = lua.getTop();
    var ingredients: [game.crafting.max_shapeless]?game.crafting.Ingredient = @splat(null);
    var gathered: usize = 0;
    while (gathered < ingredients.len) : (gathered += 1) {
        if (lua.getIndex(list, @intCast(gathered + 1)) != .string) {
            lua.pop(1);
            break;
        }
        ingredients[gathered] = .{ .id = keyedId(lua, lua.toString(-1) catch unreachable) };
        lua.pop(1);
    }
    if (gathered == 0) lua.raiseErrorStr("a gathered recipe needs at least one ingredient", .{});
    if (lua.getIndex(list, @intCast(gathered + 1)) == .string) lua.raiseErrorStr("a gathered recipe holds at most four ingredients", .{});
    lua.pop(1);

    return .{ .ingredients = ingredients, .output_id = result, .output_count = count, .output_meta = meta };
}

fn readShape(lua: *Lua) world.Shape {
    switch (lua.typeOf(-1)) {
        .string => {
            const tag = lua.toString(-1) catch unreachable;
            if (std.mem.eql(u8, tag, "cube")) return .cube;
            if (std.mem.eql(u8, tag, "cross")) return .cross;
            lua.raiseErrorStr("'%s' is not a shape a mod can use", .{tag.ptr});
        },
        .number => {
            const height = lua.toNumber(-1) catch unreachable;
            if (!(height > 0) or height > 1) lua.raiseErrorStr("a partial shape stands between 0 and 1 high", .{});
            return .{ .partial = @floatCast(height) };
        },
        else => lua.raiseErrorStr("'shape' is 'cube', 'cross' or a height", .{}),
    }
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
        game.crafting.resetRegistry();
        game.mob.reset();
        mobs.reset();
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
    try harness.expectFailure("rosebed.register_item { key = 'gem', on_use = 'yes' }", "'on_use' must be a function");
    try harness.expectFailure("rosebed.register_item { key = 'gem', textures = 'gem.png' }", "unknown field 'textures'");
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

test "a mod lays out a recipe on the grid or gathers it in any order" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try harness.vm.exec("=quartz",
        \\rosebed.register_item { key = "gem" }
        \\rosebed.register_item { key = "wand" }
        \\rosebed.register_recipe {
        \\  grid = { "g", "s" },
        \\  where = { g = "quartz:gem", s = "stick" },
        \\  result = "quartz:wand",
        \\}
        \\rosebed.register_recipe { any = { "quartz:gem", "coal" }, result = "quartz:gem", count = 2 }
    );

    const gem = world.Item.fromKey("quartz:gem").?;
    var grid: [4]?game.Inventory.ItemStack = @splat(null);
    grid[0] = .{ .id = .{ .item = gem }, .count = 1 };
    grid[2] = .{ .id = .{ .item = .stick }, .count = 1 };
    const wand = game.crafting.findMatch(&grid, game.crafting.player_grid_size).?;
    try std.testing.expectEqual(world.Item.fromKey("quartz:wand").?, wand.id.item);
    try std.testing.expectEqual(@as(u8, 1), wand.count);

    grid = @splat(null);
    grid[1] = .{ .id = .{ .item = .coal }, .count = 1 };
    grid[3] = .{ .id = .{ .item = gem }, .count = 1 };
    const gathered = game.crafting.findMatch(&grid, game.crafting.player_grid_size).?;
    try std.testing.expectEqual(gem, gathered.id.item);
    try std.testing.expectEqual(@as(u8, 2), gathered.count);
}

test "a recipe names what it is made of and what it makes" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try harness.expectFailure("rosebed.register_recipe { any = { 'stick' } }", "'result' must be a registered key");
    try harness.expectFailure("rosebed.register_recipe { any = { 'stick' }, result = 'quartz:nothing' }", "nothing is registered as 'quartz:nothing'");
    try harness.expectFailure("rosebed.register_recipe { result = 'stick' }", "a recipe is laid out in a 'grid' or gathered in 'any'");
    try harness.expectFailure("rosebed.register_recipe { grid = { 'gg' }, result = 'stick' }", "'where' names what each letter of the grid is");
    try harness.expectFailure("rosebed.register_recipe { grid = { 'gg' }, where = {}, result = 'stick' }", "'where' does not name 'g'");
    try harness.expectFailure("rosebed.register_recipe { grid = { 'gg', 'g' }, where = { g = 'stick' }, result = 'stick' }", "every row of a grid is the same width");
    try harness.expectFailure("rosebed.register_recipe { grid = { 'gggg' }, where = { g = 'stick' }, result = 'stick' }", "a grid row is 1 to 3 letters wide");
    try harness.expectFailure("rosebed.register_recipe { any = { 'stick', 'stick', 'stick', 'stick', 'stick' }, result = 'stick' }", "a gathered recipe holds at most four ingredients");
    try harness.expectFailure("rosebed.register_recipe { any = { 'stick' }, result = 'stick', count = 300 }", "'count' is out of range");
}

test "a block can be a cross or stand less than a block high" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try harness.vm.exec("=quartz",
        \\rosebed.register_block { key = "fern", shape = "cross", material = "plants" }
        \\rosebed.register_block { key = "slab", shape = 0.5 }
        \\rosebed.register_block { key = "pillar", shape = "cube" }
    );
    const fern = world.Block.fromKey("quartz:fern").?;
    const slab = world.Block.fromKey("quartz:slab").?;
    try std.testing.expectEqual(world.Shape.cross, fern.shape());
    try std.testing.expectEqual(@as(f32, 0.5), slab.heightScale());
    try std.testing.expectEqual(@as(f32, 0.5), slab.selectionBounds(0).max[1]);
    try std.testing.expect(!slab.isNormalCube());
    try std.testing.expect(world.Block.fromKey("quartz:pillar").?.isNormalCube());
}

test "shapes only vanilla blocks can draw are refused" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try harness.expectFailure("rosebed.register_block { key = 'a', shape = 'stairs' }", "'stairs' is not a shape a mod can use");
    try harness.expectFailure("rosebed.register_block { key = 'b', shape = 0 }", "a partial shape stands between 0 and 1 high");
    try harness.expectFailure("rosebed.register_block { key = 'c', shape = 1.5 }", "a partial shape stands between 0 and 1 high");
    try harness.expectFailure("rosebed.register_block { key = 'd', shape = true }", "'shape' is 'cube', 'cross' or a height");
}

test "an item names the png its icon is painted with" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    harness.registrar.mod_folder = "quartz_folder";

    try harness.vm.exec("=quartz",
        \\rosebed.register_item { key = "gem", texture = "icons/gem.png" }
        \\rosebed.override_item("shears", { texture = "shears.png" })
    );
    const textures = harness.registrar.item_textures.items;
    try std.testing.expectEqual(2, textures.len);
    try std.testing.expectEqual(world.Item.fromKey("quartz:gem").?, textures[0].item);
    try std.testing.expectEqualStrings("quartz_folder", textures[0].folder);
    try std.testing.expectEqualStrings("icons/gem.png", textures[0].file);
    try std.testing.expectEqual(world.Item.shears, textures[1].item);
    try std.testing.expectEqualStrings("shears.png", textures[1].file);

    try harness.expectFailure("rosebed.register_item { key = 'bad', texture = '../gem.png' }", "'../gem.png' is not a png inside the mod folder");
    try harness.expectFailure("rosebed.register_item { key = 'worse', texture = 7 }", "the 'texture' texture must be a file name");
    try harness.expectFailure("rosebed.register_block { key = 'slab', texture = 'slab.png' }", "unknown field 'texture'");
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

test "a mob registered from lua lands after the vanilla types, built to its spec" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try harness.vm.exec("=quartz",
        \\local key = rosebed.register_mob {
        \\  key = "bumbler",
        \\  width = 0.7,
        \\  height = 0.9,
        \\  health = 8,
        \\  speed = 0.5,
        \\  movement = "flying",
        \\  monster = true,
        \\  immune_to_fire = true,
        \\}
        \\assert(key == "quartz:bumbler")
    );

    const type_id = game.mob.find("quartz:bumbler").?;
    try std.testing.expectEqual(@as(game.mob.Id, 14), type_id);
    try std.testing.expect(game.mob.get(type_id).monster);
    try std.testing.expectEqual(@as(?u8, null), game.mob.get(type_id).wire_id);

    var rand: world.JavaRandom = .init(3);
    const animal = try game.mob.get(type_id).spawn(std.testing.allocator, math.Vec3.init(1, 2, 3), &rand);
    defer game.mob.get(type_id).destroy(animal, std.testing.allocator);

    try std.testing.expectEqual(@as(f64, 0.7), animal.base.width);
    try std.testing.expectEqual(@as(f64, 0.9), animal.base.height);
    try std.testing.expectEqual(@as(i32, 8), animal.health);
    try std.testing.expectEqual(@as(f32, 0.5), animal.move_speed);
    try std.testing.expectEqual(game.Animal.Movement.flying, animal.movement);
    try std.testing.expect(animal.immune_to_fire);
}

test "a mob from lua keeps its wounds and its name across a save" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    const gpa = std.testing.allocator;

    try harness.vm.exec("=quartz", "rosebed.register_mob { key = \"bumbler\", height = 0.9 }");
    const type_id = game.mob.find("quartz:bumbler").?;
    const kind = game.mob.get(type_id);

    var rand: world.JavaRandom = .init(3);
    const animal = try kind.spawn(gpa, math.Vec3.init(12.5, 64.0, -3.25), &rand);
    defer kind.destroy(animal, gpa);
    animal.health = 4;
    animal.yaw = 42.0;

    var stored = try kind.store(animal, gpa);
    defer world.nbt.deinit(gpa, &stored);
    try std.testing.expectEqualStrings("quartz:bumbler", stored.compound.get("id").?.string);

    const restored = try kind.load(gpa, stored.compound) orelse return error.TestUnexpectedResult;
    defer kind.destroy(restored, gpa);
    try std.testing.expectEqual(@as(i32, 4), restored.health);
    try std.testing.expectApproxEqAbs(@as(f32, 42.0), restored.yaw, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 12.5), restored.base.position.x, 1.0e-9);
    try std.testing.expect(try game.mob.get(game.mob.cow).load(gpa, stored.compound) == null);
}

test "a mob from lua leaves what its drop callback names" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    const gpa = std.testing.allocator;
    harness.hooks.install(harness.vm.lua);
    Hooks.active = &harness.hooks;
    defer Hooks.active = null;

    try harness.vm.exec("=quartz",
        \\rosebed.register_mob {
        \\  key = "bumbler",
        \\  health = 6,
        \\  drop = function() return "feather", 1 + rosebed.random(2) end,
        \\}
    );
    const kind = game.mob.get(game.mob.find("quartz:bumbler").?);

    var world_map: world.World = .init(gpa);
    defer world_map.deinit();
    var rand: world.JavaRandom = .init(9);
    const animal = try kind.spawn(gpa, math.Vec3.init(8, 1, 8), &rand);
    defer kind.destroy(animal, gpa);

    _ = animal.hurt(&world_map, 6, null, &rand);
    try std.testing.expect(!animal.isAlive());

    const drops = kind.takeDrops(animal) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(world.Id{ .item = .feather }, drops.stack.id);
    try std.testing.expect(drops.count >= 1 and drops.count <= 2);
    try std.testing.expect(kind.takeDrops(animal) == null);
}

test "a mob has to be built to a size that can stand somewhere" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try harness.expectFailure("rosebed.register_mob { key = \"bumbler\", width = 0 }", "needs a positive width and height");
    try harness.expectFailure("rosebed.register_mob { key = \"bumbler\", health = 0 }", "at least one heart's worth of health");
    try harness.expectFailure("rosebed.register_mob { key = \"bumbler\", movement = \"burrowing\" }", "is not a valid 'movement'");
    try harness.expectFailure("rosebed.register_mob { key = \"bumbler\", legs = 6 }", "unknown field 'legs'");
}
