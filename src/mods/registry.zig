const std = @import("std");

const game = @import("game");
const math = @import("math");
const world = @import("world");
const zlua = @import("zlua");
const Lua = zlua.Lua;

const Hooks = @import("Hooks.zig");
const Manifest = @import("Manifest.zig");
const mobs = @import("mobs.zig");
const structures = @import("structures.zig");

pub const Registrar = struct {
    arena: std.mem.Allocator,
    hooks: *Hooks,
    mod_id: []const u8 = "",
    mod_folder: []const u8 = "",
    open: bool = true,
    block_textures: std.ArrayList(BlockTexture) = .empty,
    item_textures: std.ArrayList(ItemTexture) = .empty,
    mob_skins: std.ArrayList(MobSkin) = .empty,
    structure_keys: std.ArrayList([]const u8) = .empty,
};

pub const MobSkin = struct {
    type_id: game.mob.Id,
    model: game.mob.Model,
    wing_beat: f32,
    folder: []const u8,
    file: []const u8,
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
        .{ .name = "override_mob", .function = zlua.wrap(overrideMob) },
        .{ .name = "register_recipe", .function = zlua.wrap(registerRecipe) },
        .{ .name = "on_decorate", .function = zlua.wrap(onDecorate) },
        .{ .name = "on_generate", .function = zlua.wrap(onGenerate) },
        .{ .name = "noise", .function = zlua.wrap(createNoise) },
        .{ .name = "register_structure", .function = zlua.wrap(registerStructure) },
        .{ .name = "register_biome", .function = zlua.wrap(registerBiome) },
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
    texture: ?[]const u8 = null,
};

const PatchExtras = struct {
    refs: mobs.PatchRefs = .{},
};

fn Extras(comptime Def: type) type {
    return switch (Def) {
        world.block.Def => BlockExtras,
        world.item.Def => ItemExtras,
        mobs.Def => MobExtras,
        mobs.Patch => PatchExtras,
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
    } else {
        if (comptime @hasField(Extras(Def), "texture")) {
            if (std.mem.eql(u8, name, "texture")) {
                extras.texture = texturePath(lua, registrar, -1, "texture");
                return;
            }
        }
        if (comptime Extras(Def) == MobExtras) {
            if (std.mem.eql(u8, name, "spawns")) {
                definition.spawns = readSpawns(lua);
                return;
            }
            if (std.mem.eql(u8, name, "model")) {
                definition.model = readModel(lua, registrar);
                return;
            }
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
    if (definition.wing_beat < 0) lua.raiseErrorStr("'wing_beat' is how fast a wing beats, so it cannot be negative", .{});
    const type_id = mobs.claim(definition, extras.refs) catch |err| raise(lua, err, definition.key);
    if (extras.texture) |file| {
        registrar.mob_skins.append(registrar.arena, .{
            .type_id = type_id,
            .model = definition.model,
            .wing_beat = definition.wing_beat,
            .folder = registrar.mod_folder,
            .file = file,
        }) catch raise(lua, error.OutOfMemory, definition.key);
    }
    _ = lua.pushString(definition.key);
    return 1;
}

fn onDecorate(lua: *Lua) i32 {
    const registrar = context(lua);
    lua.checkType(1, .function);
    lua.pushValue(1);
    const ref = lua.ref(zlua.registry_index);
    registrar.hooks.addDecorator(registrar.arena, ref, registrar.mod_id) catch lua.raiseErrorStr("out of memory", .{});
    return 0;
}

fn onGenerate(lua: *Lua) i32 {
    const registrar = context(lua);
    lua.checkType(1, .function);
    lua.pushValue(1);
    const ref = lua.ref(zlua.registry_index);
    registrar.hooks.addShaper(registrar.arena, ref, registrar.mod_id) catch lua.raiseErrorStr("out of memory", .{});
    return 0;
}

fn registerBiome(lua: *Lua) i32 {
    const registrar = context(lua);
    lua.checkType(1, .table);
    const key = namespacedKey(lua, registrar);

    if (lua.getField(1, "parent") != .string) lua.raiseErrorStr("'parent' names the vanilla biome to take ground from", .{});
    const parent_name = lua.toString(-1) catch unreachable;
    const parent = std.meta.stringToEnum(world.biome.Biome, parent_name) orelse
        lua.raiseErrorStr("there is no vanilla biome called '%s'", .{parent_name.ptr});
    lua.pop(1);

    if (lua.getField(1, "share") != .number) lua.raiseErrorStr("'share' is the part of its parent it takes, above 0 and at most 1", .{});
    const share = lua.toNumber(-1) catch unreachable;
    if (!(share > 0 and share <= 1)) lua.raiseErrorStr("'share' is the part of its parent it takes, above 0 and at most 1", .{});
    lua.pop(1);

    const entry: world.biome.Def = .{
        .key = key,
        .parent = parent,
        .share = share,
        .top = biomeBlock(lua, "top", parent.topBlock()),
        .filler = biomeBlock(lua, "filler", parent.fillerBlock()),
        .snows = biomeFlag(lua, "snows", parent.snows()),
        .rains = biomeFlag(lua, "rains", parent.rains()),
        .trees = biomeCount(lua, "trees", -64),
        .grass = biomeCount(lua, "grass", 0),
        .flowers = biomeCount(lua, "flowers", 0),
    };

    _ = world.biome.register(entry) catch |err| switch (err) {
        error.DuplicateKey => raise(lua, error.DuplicateKey, key),
        error.RegistryFull => raise(lua, error.RegistryFull, key),
        error.NoShareLeft => lua.raiseErrorStr("'%s' has no share left to give", .{parent_name.ptr}),
    };
    _ = lua.pushString(key);
    return 1;
}

fn biomeBlock(lua: *Lua, name: [:0]const u8, fallback: world.Block) world.Block {
    defer lua.pop(1);
    return switch (lua.getField(1, name)) {
        .nil => fallback,
        .string => world.Block.fromKey(lua.toString(-1) catch unreachable) orelse
            lua.raiseErrorStr("'%s' must be a registered block", .{name.ptr}),
        else => lua.raiseErrorStr("'%s' must be a registered block", .{name.ptr}),
    };
}

fn biomeFlag(lua: *Lua, name: [:0]const u8, fallback: bool) bool {
    defer lua.pop(1);
    return switch (lua.getField(1, name)) {
        .nil => fallback,
        .boolean => lua.toBoolean(-1),
        else => lua.raiseErrorStr("'%s' must be true or false", .{name.ptr}),
    };
}

fn biomeCount(lua: *Lua, name: [:0]const u8, lowest: i32) ?i32 {
    if (lua.getField(1, name) == .nil) {
        lua.pop(1);
        return null;
    }
    lua.pop(1);
    const count = spawnsNumber(lua, 1, i32, name, 0);
    if (count < lowest or count > 64) lua.raiseErrorStr("'%s' is out of range", .{name.ptr});
    return count;
}

fn registerStructure(lua: *Lua) i32 {
    const registrar = context(lua);
    lua.checkType(1, .table);
    const key = namespacedKey(lua, registrar);
    for (registrar.structure_keys.items) |taken| {
        if (std.mem.eql(u8, taken, key)) raise(lua, error.DuplicateKey, key);
    }

    if (lua.getField(1, "place") != .function) lua.raiseErrorStr("'place' must be a function", .{});
    const ref = lua.ref(zlua.registry_index);

    var spec: structures.Structure = .{
        .ref = ref,
        .salt = @bitCast(std.hash.Fnv1a_64.hash(key)),
        .spacing = spawnsNumber(lua, 1, i32, "spacing", 16),
        .chance = 1,
        .radius = spawnsNumber(lua, 1, i32, "radius", 1),
        .dimension = .overworld,
    };
    if (spec.spacing < 1 or spec.spacing > structures.max_spacing) lua.raiseErrorStr("'spacing' is 1 to 4096 chunks", .{});
    if (spec.radius < 0 or spec.radius > structures.max_radius) lua.raiseErrorStr("'radius' is 0 to 8 chunks", .{});

    if (lua.getField(1, "chance") != .nil) {
        spec.chance = lua.toNumber(-1) catch lua.raiseErrorStr("'chance' must be a number", .{});
        if (!(spec.chance > 0 and spec.chance <= 1)) lua.raiseErrorStr("'chance' is above 0 and at most 1", .{});
    }
    lua.pop(1);

    switch (lua.getField(1, "dimension")) {
        .nil => {},
        .string => {
            const dimension = lua.toString(-1) catch unreachable;
            spec.dimension = std.meta.stringToEnum(world.Dimension, dimension) orelse
                lua.raiseErrorStr("there is no dimension called '%s'", .{dimension.ptr});
        },
        else => lua.raiseErrorStr("'dimension' is 'overworld' or 'nether'", .{}),
    }
    lua.pop(1);

    switch (lua.getField(1, "biomes")) {
        .nil => {},
        .table => spec.biomes = readBiomes(lua),
        else => lua.raiseErrorStr("'biomes' is a list of biome names", .{}),
    }
    lua.pop(1);
    if (spec.biomes != null and spec.dimension == .nether) lua.raiseErrorStr("the nether has no biomes to choose from", .{});

    registrar.structure_keys.append(registrar.arena, key) catch raise(lua, error.OutOfMemory, key);
    registrar.hooks.addStructure(registrar.arena, spec) catch raise(lua, error.OutOfMemory, key);
    _ = lua.pushString(key);
    return 1;
}

fn createNoise(lua: *Lua) i32 {
    const registrar = context(lua);
    var octaves: usize = 1;
    var scale: f64 = 1;
    if (!lua.isNoneOrNil(1)) {
        lua.checkType(1, .table);
        octaves = spawnsNumber(lua, 1, usize, "octaves", 1);
        if (octaves < 1 or octaves > Hooks.max_octaves) lua.raiseErrorStr("'octaves' is 1 to 16", .{});
        if (lua.getField(1, "scale") != .nil) {
            scale = lua.toNumber(-1) catch lua.raiseErrorStr("'scale' must be a number", .{});
            if (!(scale > 0)) lua.raiseErrorStr("'scale' must be above zero", .{});
        }
        lua.pop(1);
    }
    const index = registrar.hooks.addNoise(registrar.arena, registrar.mod_id, octaves, scale) catch lua.raiseErrorStr("out of memory", .{});
    lua.pushLightUserdata(registrar.hooks);
    lua.pushInteger(@intCast(index));
    lua.pushClosure(zlua.wrap(Hooks.sampleNoise), 2);
    return 1;
}

fn overrideMob(lua: *Lua) i32 {
    const registrar = context(lua);
    const name = lua.checkString(1);
    lua.checkType(2, .table);
    const type_id = game.mob.find(name) orelse lua.raiseErrorStr("no mob is registered as '%s'", .{name.ptr});

    var patch: mobs.Patch = .{};
    var extras: PatchExtras = .{};
    readFields(mobs.Patch, &patch, &extras, lua, registrar, 2, .reject_key);
    if (patch.health) |health| {
        if (health <= 0) lua.raiseErrorStr("'health' is at least one", .{});
    }
    mobs.override(type_id, patch, extras.refs);
    return 0;
}

fn readSpawns(lua: *Lua) game.mob.Spawns {
    if (lua.typeOf(-1) != .table) lua.raiseErrorStr("'spawns' names a 'category' and a 'weight'", .{});
    const table = lua.getTop();

    if (lua.getField(table, "category") != .string) lua.raiseErrorStr("'category' is 'creature', 'monster' or 'water_creature'", .{});
    const name = lua.toString(-1) catch unreachable;
    const category = std.meta.stringToEnum(game.spawner.Category, name) orelse
        lua.raiseErrorStr("nothing spawns as a '%s'", .{name.ptr});
    lua.pop(1);

    var spawns: game.mob.Spawns = .{ .category = category, .weight = spawnsNumber(lua, table, i32, "weight", 0) };
    if (spawns.weight <= 0) lua.raiseErrorStr("'weight' is how often a mob is picked, so it must be positive", .{});
    spawns.max_per_chunk = spawnsNumber(lua, table, u32, "max_per_chunk", game.spawner.max_per_chunk);
    if (spawns.max_per_chunk == 0) lua.raiseErrorStr("'max_per_chunk' must be at least one", .{});

    switch (lua.getField(table, "dimension")) {
        .nil => {},
        .string => {
            const dimension = lua.toString(-1) catch unreachable;
            spawns.dimension = std.meta.stringToEnum(world.Dimension, dimension) orelse
                lua.raiseErrorStr("there is no dimension called '%s'", .{dimension.ptr});
        },
        else => lua.raiseErrorStr("'dimension' is 'overworld' or 'nether'", .{}),
    }
    lua.pop(1);

    switch (lua.getField(table, "biomes")) {
        .nil => {},
        .table => spawns.biomes = readBiomes(lua),
        else => lua.raiseErrorStr("'biomes' is a list of biome names", .{}),
    }
    lua.pop(1);
    if (spawns.biomes != null and spawns.dimension == .nether) {
        lua.raiseErrorStr("the nether has no biomes to choose from", .{});
    }
    return spawns;
}

pub const max_model_parts = 32;

fn readModel(lua: *Lua, registrar: *Registrar) game.mob.Model {
    switch (lua.typeOf(-1)) {
        .string => {
            const tag = lua.toString(-1) catch unreachable;
            const builtin = std.meta.stringToEnum(game.mob.Model.Builtin, tag) orelse
                lua.raiseErrorStr("'%s' is not a model a mod can borrow", .{tag.ptr});
            return .{ .builtin = builtin };
        },
        .table => {},
        else => lua.raiseErrorStr("'model' names a vanilla model or lays one out in a table", .{}),
    }

    const table = lua.getTop();
    const texture_width = modelSize(lua, table, "texture_width", 64);
    const texture_height = modelSize(lua, table, "texture_height", 32);

    if (lua.getField(table, "parts") != .table) lua.raiseErrorStr("a model is built from a list of 'parts'", .{});
    const list = lua.getTop();
    var parts: std.ArrayList(game.mob_model.Part) = .empty;
    var head_index: ?usize = null;
    var index: i64 = 1;
    while (lua.getIndex(list, index) != .nil) : (index += 1) {
        if (parts.items.len == max_model_parts) lua.raiseErrorStr("a model is built from at most 32 parts", .{});
        if (lua.typeOf(-1) != .table) lua.raiseErrorStr("every part of a model is a table", .{});
        const part = readPart(lua);
        if (part.role == .head and head_index == null) head_index = parts.items.len;
        parts.append(registrar.arena, part) catch raise(lua, error.OutOfMemory, "model");
        lua.pop(1);
    }
    lua.pop(2);
    if (parts.items.len == 0) lua.raiseErrorStr("a model is built from at least one part", .{});

    return .{ .custom = .{
        .parts = parts.items,
        .head_index = head_index orelse 0,
        .texture_width = texture_width,
        .texture_height = texture_height,
    } };
}

fn readPart(lua: *Lua) game.mob_model.Part {
    const table = lua.getTop();
    const box = modelVector(lua, table, "box", 6, null);
    const uv = modelVector(lua, table, "uv", 2, .{ 0, 0 });
    for (box[3..]) |side| {
        if (!(side > 0)) lua.raiseErrorStr("a part's width, height and depth are above zero", .{});
    }
    return .{
        .box = .{
            .origin = box[0..3].*,
            .size = box[3..6].*,
            .tex_u = uv[0],
            .tex_v = uv[1],
            .inflate = modelNumber(lua, table, "inflate", 0),
            .mirror = modelFlag(lua, table, "mirror"),
        },
        .pivot = modelVector(lua, table, "pivot", 3, .{ 0, 0, 0 }),
        .rotate_x = modelNumber(lua, table, "rotate_x", 0),
        .rotate_y = modelNumber(lua, table, "rotate_y", 0),
        .rotate_z = modelNumber(lua, table, "rotate_z", 0),
        .role = modelRole(lua, table),
    };
}

fn modelVector(lua: *Lua, table: i32, name: [:0]const u8, comptime count: usize, fallback: ?[count]f32) [count]f32 {
    if (lua.getField(table, name) == .nil) {
        lua.pop(1);
        return fallback orelse lua.raiseErrorStr("a part of a model needs its '%s'", .{name.ptr});
    }
    if (lua.typeOf(-1) != .table) lua.raiseErrorStr("'%s' is a list of numbers", .{name.ptr});
    const list = lua.getTop();
    var out: [count]f32 = undefined;
    for (&out, 0..) |*value, slot| {
        if (lua.getIndex(list, @as(i64, @intCast(slot + 1))) != .number) {
            lua.raiseErrorStr("'%s' is a list of %d numbers", .{ name.ptr, @as(i32, @intCast(count)) });
        }
        value.* = @floatCast(lua.toNumber(-1) catch unreachable);
        if (!std.math.isFinite(value.*)) lua.raiseErrorStr("'%s' holds a number that is not finite", .{name.ptr});
        lua.pop(1);
    }
    if (lua.getIndex(list, @as(i64, count + 1)) != .nil) {
        lua.raiseErrorStr("'%s' is a list of %d numbers", .{ name.ptr, @as(i32, @intCast(count)) });
    }
    lua.pop(2);
    return out;
}

fn modelNumber(lua: *Lua, table: i32, name: [:0]const u8, fallback: f32) f32 {
    defer lua.pop(1);
    if (lua.getField(table, name) == .nil) return fallback;
    if (lua.typeOf(-1) != .number) lua.raiseErrorStr("'%s' must be a number", .{name.ptr});
    const value: f32 = @floatCast(lua.toNumber(-1) catch unreachable);
    if (!std.math.isFinite(value)) lua.raiseErrorStr("'%s' must be a finite number", .{name.ptr});
    return value;
}

fn modelSize(lua: *Lua, table: i32, name: [:0]const u8, fallback: f32) f32 {
    const value = modelNumber(lua, table, name, fallback);
    if (!(value > 0)) lua.raiseErrorStr("'%s' is above zero", .{name.ptr});
    return value;
}

fn modelFlag(lua: *Lua, table: i32, name: [:0]const u8) bool {
    defer lua.pop(1);
    return switch (lua.getField(table, name)) {
        .nil => false,
        .boolean => lua.toBoolean(-1),
        else => lua.raiseErrorStr("'%s' must be true or false", .{name.ptr}),
    };
}

fn modelRole(lua: *Lua, table: i32) game.mob_model.Role {
    defer lua.pop(1);
    return switch (lua.getField(table, "role")) {
        .nil => .still,
        .string => blk: {
            const tag = lua.toString(-1) catch unreachable;
            break :blk std.meta.stringToEnum(game.mob_model.Role, tag) orelse
                lua.raiseErrorStr("'%s' is not a part a model animates", .{tag.ptr});
        },
        else => lua.raiseErrorStr("'role' names how a part moves", .{}),
    };
}

fn readBiomes(lua: *Lua) world.biome.Set {
    const list = lua.getTop();
    var biomes: world.biome.Set = .initEmpty();
    var index: i64 = 1;
    while (lua.getIndex(list, index) != .nil) : (index += 1) {
        if (lua.typeOf(-1) != .string) lua.raiseErrorStr("'biomes' is a list of biome names", .{});
        const name = lua.toString(-1) catch unreachable;
        const found = world.biome.Biome.fromName(name) orelse lua.raiseErrorStr("there is no biome called '%s'", .{name.ptr});
        biomes.set(@intFromEnum(found));
        lua.pop(1);
    }
    lua.pop(1);
    if (biomes.count() == 0) lua.raiseErrorStr("'biomes' names at least one biome", .{});
    return biomes;
}

fn spawnsNumber(lua: *Lua, table: i32, comptime T: type, name: [:0]const u8, fallback: T) T {
    defer lua.pop(1);
    if (lua.getField(table, name) == .nil) return fallback;
    const value = lua.toInteger(-1) catch lua.raiseErrorStr("'%s' must be a whole number", .{name.ptr});
    return std.math.cast(T, value) orelse lua.raiseErrorStr("'%s' is out of range", .{name.ptr});
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

fn readIngredient(lua: *Lua) game.crafting.Ingredient {
    switch (lua.typeOf(-1)) {
        .string => return .{ .id = keyedId(lua, lua.toString(-1) catch unreachable) },
        .table => {
            const table = lua.getTop();
            if (lua.getIndex(table, 1) != .string) lua.raiseErrorStr("an ingredient is a key, or { key, meta }", .{});
            const id = keyedId(lua, lua.toString(-1) catch unreachable);
            lua.pop(1);
            defer lua.pop(1);
            if (lua.getIndex(table, 2) == .nil) return .{ .id = id };
            const meta = lua.toInteger(-1) catch lua.raiseErrorStr("an ingredient's meta must be a whole number", .{});
            return .{ .id = id, .meta = std.math.cast(u16, meta) orelse lua.raiseErrorStr("an ingredient's meta is out of range", .{}) };
        },
        else => lua.raiseErrorStr("an ingredient is a key, or { key, meta }", .{}),
    }
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
            if (lua.getField(where, &name) == .nil) lua.raiseErrorStr("'where' does not name '%s'", .{&name});
            pattern[column + height * width] = readIngredient(lua);
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
        if (lua.getIndex(list, @intCast(gathered + 1)) == .nil) {
            lua.pop(1);
            break;
        }
        ingredients[gathered] = readIngredient(lua);
        lua.pop(1);
    }
    if (gathered == 0) lua.raiseErrorStr("a gathered recipe needs at least one ingredient", .{});
    if (lua.getIndex(list, @intCast(gathered + 1)) != .nil) lua.raiseErrorStr("a gathered recipe holds at most four ingredients", .{});
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
        world.biome.resetRegistry();
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

test "a mod lays out a model of its own, and its parts keep the order they were given" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try harness.vm.exec("=quartz",
        \\rosebed.register_mob {
        \\  key = "bumbler",
        \\  texture = "bumbler.png",
        \\  model = {
        \\    texture_width = 32,
        \\    texture_height = 16,
        \\    parts = {
        \\      { box = { -2, -6, -3, 4, 4, 6 }, uv = { 0, 0 }, pivot = { 0, -9, -4 }, role = "head" },
        \\      { box = { -3, -5, -4, 6, 5, 8 }, uv = { 0, 10 }, pivot = { 0, -8, 0 }, rotate_x = 0.25 },
        \\      { box = { 0, 0, -3, 1, 4, 6 }, uv = { 24, 0 }, pivot = { -4, -11, 0 }, role = "wing_right", mirror = true },
        \\      { box = { -1, 0, -3, 1, 4, 6 }, uv = { 24, 0 }, pivot = { 4, -11, 0 }, role = "wing_left", inflate = 0.5 },
        \\    },
        \\  },
        \\}
    );

    const model = harness.registrar.mob_skins.items[0].model.custom;
    try std.testing.expectEqual(@as(f32, 32), model.texture_width);
    try std.testing.expectEqual(@as(f32, 16), model.texture_height);
    try std.testing.expectEqual(@as(usize, 4), model.parts.len);
    try std.testing.expectEqual(@as(usize, 0), model.head_index);

    const head = model.parts[0];
    try std.testing.expectEqual([3]f32{ -2, -6, -3 }, head.box.origin);
    try std.testing.expectEqual([3]f32{ 4, 4, 6 }, head.box.size);
    try std.testing.expectEqual([3]f32{ 0, -9, -4 }, head.pivot);
    try std.testing.expectEqual(game.mob_model.Role.head, head.role);

    try std.testing.expectEqual(game.mob_model.Role.still, model.parts[1].role);
    try std.testing.expectEqual(@as(f32, 0.25), model.parts[1].rotate_x);
    try std.testing.expectEqual([3]f32{ 0, -8, 0 }, model.parts[1].pivot);

    try std.testing.expect(model.parts[2].box.mirror);
    try std.testing.expectEqual(game.mob_model.Role.wing_right, model.parts[2].role);
    try std.testing.expectEqual(@as(f32, 0.5), model.parts[3].box.inflate);
    try std.testing.expectEqual(@as(f32, 24), model.parts[3].box.tex_u);
}

test "a model says how fast its wings beat, and refuses to beat backwards" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try harness.vm.exec("=quartz",
        \\rosebed.register_mob { key = "bumbler", texture = "bumbler.png", model = "chicken", wing_beat = 0.8 }
        \\rosebed.register_mob { key = "plodder", texture = "plodder.png", model = "cow" }
    );
    try std.testing.expectEqual(@as(f32, 0.8), harness.registrar.mob_skins.items[0].wing_beat);
    try std.testing.expectEqual(@as(f32, 0), harness.registrar.mob_skins.items[1].wing_beat);
    try harness.expectFailure(
        "rosebed.register_mob { key = 'other', wing_beat = -1 }",
        "'wing_beat' is how fast a wing beats, so it cannot be negative",
    );
}

test "a model with no head still points its head index at a part it has" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try harness.vm.exec("=quartz",
        \\rosebed.register_mob { key = "blob", texture = "blob.png", model = { parts = { { box = { 0, 0, 0, 8, 8, 8 } } } } }
    );
    const model = harness.registrar.mob_skins.items[0].model.custom;
    try std.testing.expectEqual(@as(usize, 1), model.parts.len);
    try std.testing.expectEqual([3]f32{ 0, 0, 0 }, model.parts[0].pivot);
    try std.testing.expectEqual(game.mob_model.Role.still, model.parts[0].role);
    try std.testing.expect(model.head_index < model.parts.len);
    try std.testing.expectEqual(@as(f32, 64), model.texture_width);
    try std.testing.expectEqual(@as(f32, 32), model.texture_height);
}

test "a mob still borrows a vanilla model by name" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try harness.vm.exec("=quartz", "rosebed.register_mob { key = 'bumbler', texture = 'b.png', model = 'chicken' }");
    try std.testing.expectEqual(game.mob.Model.Builtin.chicken, harness.registrar.mob_skins.items[0].model.builtin);
    try harness.expectFailure("rosebed.register_mob { key = 'other', model = 'wolf' }", "'wolf' is not a model a mod can borrow");
    try harness.expectFailure("rosebed.register_mob { key = 'other', model = 5 }", "'model' names a vanilla model or lays one out in a table");
}

test "a model a mod cannot draw is refused as it registers" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try harness.expectFailure("rosebed.register_mob { key = 'a', model = {} }", "a model is built from a list of 'parts'");
    try harness.expectFailure("rosebed.register_mob { key = 'b', model = { parts = {} } }", "a model is built from at least one part");
    try harness.expectFailure("rosebed.register_mob { key = 'c', model = { parts = { 5 } } }", "every part of a model is a table");
    try harness.expectFailure("rosebed.register_mob { key = 'd', model = { parts = { {} } } }", "a part of a model needs its 'box'");
    try harness.expectFailure(
        "rosebed.register_mob { key = 'e', model = { parts = { { box = { 0, 0, 0, 1, 1 } } } } }",
        "'box' is a list of 6 numbers",
    );
    try harness.expectFailure(
        "rosebed.register_mob { key = 'f', model = { parts = { { box = { 0, 0, 0, 1, 1, 1, 1 } } } } }",
        "'box' is a list of 6 numbers",
    );
    try harness.expectFailure(
        "rosebed.register_mob { key = 'g', model = { parts = { { box = { 0, 0, 0, 0, 1, 1 } } } } }",
        "a part's width, height and depth are above zero",
    );
    try harness.expectFailure(
        "rosebed.register_mob { key = 'h', model = { parts = { { box = { 0, 0, 0, 1, 1, 1 }, role = 'tail' } } } }",
        "'tail' is not a part a model animates",
    );
    try harness.expectFailure(
        "rosebed.register_mob { key = 'i', model = { texture_width = 0, parts = { { box = { 0, 0, 0, 1, 1, 1 } } } } }",
        "'texture_width' is above zero",
    );
    try harness.expectFailure(
        "rosebed.register_mob { key = 'j', model = { parts = { { box = { 0, 0, 0, 1, 1, 1 }, pivot = { 0, 0, 0 / 0 } } } } }",
        "'pivot' holds a number that is not finite",
    );
}

test "a model is refused once it asks for more parts than the renderer takes" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try harness.vm.exec("=quartz",
        \\parts = {}
        \\for i = 1, 33 do parts[i] = { box = { 0, 0, 0, 1, 1, 1 } } end
    );
    try harness.expectFailure(
        "rosebed.register_mob { key = 'many', model = { parts = parts } }",
        "a model is built from at most 32 parts",
    );
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
        \\  model = "cow",
        \\  texture = "bumbler.png",
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
    try std.testing.expectEqual(@as(usize, 1), harness.registrar.mob_skins.items.len);
    try std.testing.expectEqual(type_id, harness.registrar.mob_skins.items[0].type_id);
    try std.testing.expectEqual(game.mob.Model.Builtin.cow, harness.registrar.mob_skins.items[0].model.builtin);
    try std.testing.expectEqualStrings("bumbler.png", harness.registrar.mob_skins.items[0].file);
    try std.testing.expectEqual(game.mob.first_mod_wire_id, game.mob.get(type_id).wire_id.?);

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

test "a mob from lua reaches the world and itself from its own tick" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    const gpa = std.testing.allocator;
    harness.hooks.install(harness.vm.lua);
    Hooks.active = &harness.hooks;
    defer Hooks.active = null;

    try harness.vm.exec("=quartz",
        \\ticked = 0
        \\rosebed.register_mob {
        \\  key = "bumbler",
        \\  health = 20,
        \\  on_tick = function(x, y, z)
        \\    ticked = ticked + 1
        \\    seen = { x, y, z }
        \\    rosebed.world.set_block(x, y - 1, z, "stone")
        \\    local health, max = rosebed.mob.health()
        \\    assert(max == 20)
        \\    if health == max then rosebed.mob.hurt(3) end
        \\  end,
        \\}
    );
    const kind = game.mob.get(game.mob.find("quartz:bumbler").?);

    var world_map: world.World = .init(gpa);
    defer world_map.deinit();
    _ = try world_map.createChunk(0, 0);
    var rand: world.JavaRandom = .init(4);
    const animal = try kind.spawn(gpa, math.Vec3.init(4.5, 10.0, 6.5), &rand);
    defer kind.destroy(animal, gpa);

    const ticking: game.mob.Tick = .{
        .entities = &world_map,
        .gpa = gpa,
        .world_map = &world_map,
        .roster = &.{},
        .players = .{},
        .rand = &rand,
    };
    try kind.afterTick(animal, ticking);
    try kind.afterTick(animal, ticking);

    try std.testing.expectEqual(world.Block.stone, world_map.getBlock(.init(4, 9, 6)));
    try std.testing.expectEqual(@as(i32, 17), animal.health);
    try std.testing.expectEqual(zlua.LuaType.number, harness.vm.lua.getGlobal("ticked"));
    try std.testing.expectEqual(@as(i64, 2), harness.vm.lua.toInteger(-1) catch unreachable);
    harness.vm.lua.pop(1);
}

test "a mob is out of reach outside its own callback" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    harness.hooks.install(harness.vm.lua);

    try harness.expectFailure("rosebed.mob.health()", "a mob is only reached from its own callback");
    try harness.expectFailure("rosebed.mob.position()", "a mob is only reached from its own callback");
}

test "a mob names where it spawns, and is checked by the rule of that category" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try harness.vm.exec("=quartz",
        \\rosebed.register_mob {
        \\  key = "bumbler",
        \\  spawns = { category = "creature", weight = 8 },
        \\}
        \\rosebed.register_mob {
        \\  key = "horror",
        \\  monster = true,
        \\  spawns = { category = "monster", weight = 3, max_per_chunk = 1 },
        \\}
        \\rosebed.register_mob { key = "drifter" }
    );

    const bumbler = game.mob.get(game.mob.find("quartz:bumbler").?);
    const spawns = bumbler.spawns.?;
    try std.testing.expectEqual(game.spawner.Category.creature, spawns.category);
    try std.testing.expectEqual(@as(i32, 8), spawns.weight);
    try std.testing.expectEqual(game.spawner.max_per_chunk, spawns.max_per_chunk);
    try std.testing.expectEqual(game.mob.spawnCheckFor(.creature), bumbler.canSpawnHere);

    const horror = game.mob.get(game.mob.find("quartz:horror").?);
    try std.testing.expectEqual(game.spawner.Category.monster, horror.spawns.?.category);
    try std.testing.expectEqual(@as(u32, 1), horror.spawns.?.max_per_chunk);
    try std.testing.expectEqual(game.mob.spawnCheckFor(.monster), horror.canSpawnHere);

    try std.testing.expect(game.mob.get(game.mob.find("quartz:drifter").?).spawns == null);
}

test "a spawn rule has to say where and how often" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try harness.expectFailure(
        "rosebed.register_mob { key = \"bumbler\", spawns = { weight = 4 } }",
        "'category' is 'creature', 'monster' or 'water_creature'",
    );
    try harness.expectFailure(
        "rosebed.register_mob { key = \"bumbler\", spawns = { category = \"boss\", weight = 4 } }",
        "nothing spawns as a 'boss'",
    );
    try harness.expectFailure(
        "rosebed.register_mob { key = \"bumbler\", spawns = { category = \"creature\" } }",
        "so it must be positive",
    );
    try harness.expectFailure(
        "rosebed.register_mob { key = \"bumbler\", spawns = { category = \"creature\", weight = 4, max_per_chunk = 0 } }",
        "'max_per_chunk' must be at least one",
    );
    try harness.expectFailure(
        "rosebed.register_mob { key = \"bumbler\", spawns = \"creature\" }",
        "'spawns' names a 'category' and a 'weight'",
    );
}

test "an overridden vanilla mob is built to the numbers the mod gave it" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    const gpa = std.testing.allocator;

    try harness.vm.exec("=quartz", "rosebed.override_mob(\"Pig\", { health = 25, speed = 1.5 })");

    const kind = game.mob.get(game.mob.pig);
    var rand: world.JavaRandom = .init(2);
    const animal = try kind.spawn(gpa, math.Vec3.init(0, 64, 0), &rand);
    defer kind.destroy(animal, gpa);

    try std.testing.expectEqual(@as(i32, 25), animal.max_health);
    try std.testing.expectEqual(@as(i32, 25), animal.health);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), animal.move_speed, 1.0e-6);

    const cow = game.mob.get(game.mob.cow);
    const other = try cow.spawn(gpa, math.Vec3.init(0, 64, 0), &rand);
    defer cow.destroy(other, gpa);
    try std.testing.expectEqual(game.Cow.max_health, other.max_health);
}

test "an overridden mob read back out of a save keeps the wounds it was written with" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    const gpa = std.testing.allocator;

    const kind = game.mob.get(game.mob.pig);
    var rand: world.JavaRandom = .init(2);
    const animal = try kind.spawn(gpa, math.Vec3.init(0, 64, 0), &rand);
    defer kind.destroy(animal, gpa);
    animal.health = 4;

    var stored = try kind.store(animal, gpa);
    defer world.nbt.deinit(gpa, &stored);

    try harness.vm.exec("=quartz", "rosebed.override_mob(\"Pig\", { health = 25 })");

    const restored = try game.mob.get(game.mob.pig).load(gpa, stored.compound) orelse return error.TestUnexpectedResult;
    defer game.mob.get(game.mob.pig).destroy(restored, gpa);
    try std.testing.expectEqual(@as(i32, 4), restored.health);
    try std.testing.expectEqual(@as(i32, 25), restored.max_health);
}

test "an overridden mob still does what it always did, then what the mod added" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    const gpa = std.testing.allocator;
    harness.hooks.install(harness.vm.lua);
    Hooks.active = &harness.hooks;
    defer Hooks.active = null;

    const before = game.mob.get(game.mob.creeper).afterTick;
    try harness.vm.exec("=quartz",
        \\seen = 0
        \\rosebed.override_mob("Creeper", { on_tick = function(x, y, z) seen = seen + 1 end })
    );
    try std.testing.expect(before != game.mob.get(game.mob.creeper).afterTick);

    var world_map: world.World = .init(gpa);
    defer world_map.deinit();
    _ = try world_map.createChunk(0, 0);
    var entities: game.Entities = .{};
    defer entities.deinit(gpa);
    var rand: world.JavaRandom = .init(5);

    const kind = game.mob.get(game.mob.creeper);
    const animal = try kind.spawn(gpa, math.Vec3.init(4.5, 10.0, 6.5), &rand);
    defer kind.destroy(animal, gpa);

    const creeper: *game.Creeper = @fieldParentPtr("animal", animal);
    creeper.pending_blast = game.Creeper.blast_size;

    const ticking: game.mob.Tick = .{
        .entities = &entities,
        .gpa = gpa,
        .world_map = &world_map,
        .roster = &.{},
        .players = .{},
        .rand = &rand,
    };
    try kind.afterTick(animal, ticking);

    try std.testing.expect(creeper.pending_blast == null);
    try std.testing.expectEqual(zlua.LuaType.number, harness.vm.lua.getGlobal("seen"));
    try std.testing.expectEqual(@as(i64, 1), harness.vm.lua.toInteger(-1) catch unreachable);
    harness.vm.lua.pop(1);
}

test "two mods overriding one mob both get their say, and neither loses the vanilla call" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    const gpa = std.testing.allocator;

    const vanilla = game.mob.get(game.mob.pig).spawn;
    try harness.vm.exec("=quartz",
        \\rosebed.override_mob("Pig", { health = 25 })
        \\rosebed.override_mob("Pig", { speed = 1.5 })
    );
    const wrapped = game.mob.get(game.mob.pig).spawn;
    try std.testing.expect(vanilla != wrapped);

    try harness.vm.exec("=quartz", "rosebed.override_mob(\"Pig\", { health = 30 })");
    try std.testing.expectEqual(wrapped, game.mob.get(game.mob.pig).spawn);

    var rand: world.JavaRandom = .init(2);
    const kind = game.mob.get(game.mob.pig);
    const animal = try kind.spawn(gpa, math.Vec3.init(0, 64, 0), &rand);
    defer kind.destroy(animal, gpa);

    try std.testing.expectEqual(@as(i32, 30), animal.max_health);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), animal.move_speed, 1.0e-6);
}

test "a mob has to exist before it can be changed" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try harness.expectFailure("rosebed.override_mob(\"Turnip\", { health = 4 })", "no mob is registered as 'Turnip'");
    try harness.expectFailure("rosebed.override_mob(\"Pig\", { health = 0 })", "'health' is at least one");
    try harness.expectFailure("rosebed.override_mob(\"Pig\", { legs = 6 })", "unknown field 'legs'");
}

test "a spawn rule can keep a mob to some biomes, or to the nether" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try harness.vm.exec("=quartz",
        \\rosebed.register_mob {
        \\  key = "bumbler",
        \\  spawns = { category = "creature", weight = 8, biomes = { "forest", "taiga" } },
        \\}
        \\rosebed.register_mob {
        \\  key = "imp",
        \\  spawns = { category = "monster", weight = 4, dimension = "nether" },
        \\}
    );

    const bumbler = game.mob.get(game.mob.find("quartz:bumbler").?).spawns.?;
    try std.testing.expectEqual(world.Dimension.overworld, bumbler.dimension);
    try std.testing.expectEqual(@as(usize, 2), bumbler.biomes.?.count());
    try std.testing.expect(bumbler.biomes.?.isSet(@intFromEnum(world.biome.Biome.forest)));
    try std.testing.expect(bumbler.biomes.?.isSet(@intFromEnum(world.biome.Biome.taiga)));

    const imp = game.mob.get(game.mob.find("quartz:imp").?).spawns.?;
    try std.testing.expectEqual(world.Dimension.nether, imp.dimension);
    try std.testing.expect(imp.biomes == null);
}

test "a spawn rule's biomes and dimension have to be real ones" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try harness.expectFailure(
        "rosebed.register_mob { key = \"a\", spawns = { category = \"creature\", weight = 1, biomes = { \"moon\" } } }",
        "there is no biome called 'moon'",
    );
    try harness.expectFailure(
        "rosebed.register_mob { key = \"b\", spawns = { category = \"creature\", weight = 1, biomes = {} } }",
        "'biomes' names at least one biome",
    );
    try harness.expectFailure(
        "rosebed.register_mob { key = \"c\", spawns = { category = \"monster\", weight = 1, dimension = \"end\" } }",
        "there is no dimension called 'end'",
    );
    try harness.expectFailure(
        "rosebed.register_mob { key = \"d\", spawns = { category = \"monster\", weight = 1, dimension = \"nether\", biomes = { \"forest\" } } }",
        "the nether has no biomes to choose from",
    );
}

test "an overridden mob leaves what the mod adds after its own drops" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    const gpa = std.testing.allocator;
    harness.hooks.install(harness.vm.lua);
    Hooks.active = &harness.hooks;
    defer Hooks.active = null;

    try harness.vm.exec("=quartz", "rosebed.override_mob(\"Cow\", { drop = function() return \"feather\", 3 end })");

    var world_map: world.World = .init(gpa);
    defer world_map.deinit();
    const kind = game.mob.get(game.mob.cow);

    var saw_leather = false;
    for (0..20) |seed| {
        var rand: world.JavaRandom = .init(@intCast(seed));
        const animal = try kind.spawn(gpa, math.Vec3.init(8, 1, 8), &rand);
        defer kind.destroy(animal, gpa);

        _ = animal.hurt(&world_map, game.Cow.max_health, null, &rand);

        var feathers: ?u8 = null;
        while (kind.takeDrops(animal)) |drops| {
            switch (drops.stack.id) {
                .item => |item| if (item == .leather) {
                    try std.testing.expect(feathers == null);
                    saw_leather = true;
                } else if (item == .feather) {
                    feathers = drops.count;
                },
                else => {},
            }
        }
        try std.testing.expectEqual(@as(?u8, 3), feathers);
    }
    try std.testing.expect(saw_leather);
}

fn decorateOnce(gpa: std.mem.Allocator, harness: *Harness, seed: i64) !struct { world.Block, u4 } {
    var world_map: world.World = .init(gpa);
    defer world_map.deinit();
    var generator = try world.Generator.init(gpa, .overworld, seed);
    defer generator.deinit(gpa);
    _ = try world_map.createChunk(2, 3);
    try Hooks.decorate(&world_map, &generator, 2, 3);
    _ = harness;
    return .{ world_map.getBlock(.init(32, 70, 48)), world_map.getBlockMetadata(.init(32, 70, 48)) };
}

test "a mod decorates each chunk from a random of its own, the same every time" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    const gpa = std.testing.allocator;
    harness.hooks.install(harness.vm.lua);
    Hooks.active = &harness.hooks;
    defer Hooks.active = null;

    try harness.vm.exec("=quartz",
        \\rosebed.on_decorate(function(chunk_x, chunk_z, dimension)
        \\  assert(dimension == "overworld")
        \\  rosebed.world.set_block(chunk_x * 16, 70, chunk_z * 16, "log", rosebed.random(3))
        \\end)
    );
    try std.testing.expectEqual(@as(usize, 1), harness.hooks.decorators.items.len);

    const first = try decorateOnce(gpa, &harness, 1234);
    const again = try decorateOnce(gpa, &harness, 1234);
    try std.testing.expectEqual(world.Block.log, first[0]);
    try std.testing.expectEqual(first, again);
}

test "decorating is only offered while mods load" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    harness.registrar.open = false;

    try harness.expectFailure("rosebed.on_decorate(function() end)", "registration is closed once every mod has loaded");
}

test "a mod shapes the whole chunk being generated before caves, and nothing beside it" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    const gpa = std.testing.allocator;
    harness.hooks.install(harness.vm.lua);
    Hooks.active = &harness.hooks;
    defer Hooks.active = null;

    var generator = try world.TerrainGenerator.init(gpa, 42);
    defer generator.deinit(gpa);
    var vanilla = world.Chunk.init(1, 2);
    generator.generateShape(&vanilla);

    try harness.vm.exec("=quartz",
        \\rosebed.on_generate(function(chunk_x, chunk_z, dimension)
        \\  assert(dimension == "overworld")
        \\  local x, z = chunk_x * 16, chunk_z * 16
        \\  assert(rosebed.world.get_block(x - 1, 60, z) == nil)
        \\  assert(rosebed.world.height(x + 16, z) == nil)
        \\  assert(type(rosebed.world.biome(x, z)) == "string")
        \\  rosebed.world.set_block(x - 1, 120, z, "stone")
        \\  for dx = 0, 15 do
        \\    for dz = 0, 15 do rosebed.world.set_block(x + dx, 120, z + dz, "stone") end
        \\  end
        \\  assert(rosebed.world.height(x + 3, z + 5) == 121)
        \\end)
    );
    world.generator.after_shape = Hooks.shape;
    defer world.generator.after_shape = null;

    var shaped = world.Chunk.init(1, 2);
    generator.generateShape(&shaped);
    try std.testing.expectEqual(world.Block.stone, shaped.getBlock(0, 120, 0));
    try std.testing.expectEqual(world.Block.stone, shaped.getBlock(15, 120, 15));

    for (0..world.Chunk.width) |x| {
        for (0..world.Chunk.width) |z| {
            for (0..world.Chunk.height) |y| {
                if (y == 120) continue;
                try std.testing.expectEqual(vanilla.getBlock(@intCast(x), @intCast(y), @intCast(z)), shaped.getBlock(@intCast(x), @intCast(y), @intCast(z)));
            }
        }
    }
}

const structure_wall =
    \\rosebed.register_structure {
    \\  key = "wall",
    \\  spacing = 3,
    \\  radius = 1,
    \\  place = function(x, z, dimension)
    \\    assert(dimension == "overworld")
    \\    local ground = rosebed.world.height(x, z)
    \\    for dx = -20, 20 do
    \\      rosebed.world.set_block(x + dx, ground + 40, z, "brick")
    \\    end
    \\    rosebed.world.set_block(x, ground + 41, z, "chest")
    \\    rosebed.world.set_chest_item(x, ground + 41, z, 1, "diamond", rosebed.random(3) + 1)
    \\    rosebed.world.set_block(x + 1, ground + 41, z, "mob_spawner")
    \\    rosebed.world.set_spawner(x + 1, ground + 41, z, "Spider")
    \\    rosebed.world.set_block(x + 200, ground, z, "brick")
    \\    assert(rosebed.world.get_block(x + 200, ground, z) == nil)
    \\    local id = x .. "," .. z
    \\    placed[id] = (placed[id] or 0) + 1
    \\    if placed[id] == 1 then origins[#origins + 1] = { x, ground + 40, z } end
    \\  end,
    \\}
;

fn decorateArea(world_map: *world.World, generator: *world.Generator, reversed: bool) !void {
    var step: i32 = 0;
    while (step < 6) : (step += 1) {
        const chunk_x = if (reversed) 5 - step else step;
        var row: i32 = 0;
        while (row < 6) : (row += 1) {
            const chunk_z = if (reversed) row else 5 - row;
            try world_map.ensureDecorated(generator, chunk_x, chunk_z);
        }
    }
}

test "a structure comes out the same whatever order its chunks are decorated in" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    defer harness.hooks.deinit();
    const gpa = std.testing.allocator;
    harness.hooks.install(harness.vm.lua);
    Hooks.active = &harness.hooks;
    defer Hooks.active = null;
    world.generator.after_decorate = Hooks.decorate;
    defer world.generator.after_decorate = null;

    try harness.vm.exec("=quartz", structure_wall);
    try harness.vm.exec("=quartz", "placed, origins = {}, {}");

    var generator = try world.Generator.init(gpa, .overworld, 2024);
    defer generator.deinit(gpa);

    var forward: world.World = .init(gpa);
    defer forward.deinit();
    try decorateArea(&forward, &generator, false);
    harness.hooks.deinit();

    var backward: world.World = .init(gpa);
    defer backward.deinit();
    try decorateArea(&backward, &generator, true);

    try harness.vm.exec("=quartz",
        \\for _, count in pairs(placed) do assert(count == 2) end
        \\assert(#origins > 0)
    );

    const lua = harness.vm.lua;
    _ = lua.getGlobal("origins");
    const origin_count: i64 = @intCast(lua.lenRaw(-1));
    var checked: usize = 0;
    var index: i64 = 1;
    while (index <= origin_count) : (index += 1) {
        _ = lua.getIndex(-1, index);
        var corner: [3]i32 = undefined;
        for (&corner, 1..) |*value, field| {
            _ = lua.getIndex(-1, @intCast(field));
            value.* = @intCast(try lua.toInteger(-1));
            lua.pop(1);
        }
        lua.pop(1);

        var dx: i32 = -20;
        while (dx <= 20) : (dx += 1) {
            const pos: world.BlockPos = .init(corner[0] + dx, corner[1], corner[2]);
            if (pos.x < 8 or pos.x >= 104 or pos.z < 8 or pos.z >= 104) continue;
            try std.testing.expectEqual(world.Block.brick, forward.getBlock(pos));
            try std.testing.expectEqual(world.Block.brick, backward.getBlock(pos));
            checked += 1;
        }

        const chest_pos: world.BlockPos = .init(corner[0], corner[1] + 1, corner[2]);
        if (chest_pos.x < 8 or chest_pos.x >= 103 or chest_pos.z < 8 or chest_pos.z >= 104) continue;
        const kept = forward.chestAt(chest_pos).?.items[0].?;
        try std.testing.expectEqual(world.Item.diamond, kept.id.item);
        try std.testing.expectEqual(kept.count, backward.chestAt(chest_pos).?.items[0].?.count);
        try std.testing.expectEqualStrings("Spider", backward.mobSpawnerAt(.init(chest_pos.x + 1, chest_pos.y, chest_pos.z)).?.mobName());
    }
    lua.pop(1);
    try std.testing.expect(checked > 40);
}

test "a mod biome takes its share of its parent, with its own surface, and spawn rules can name it" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    const gpa = std.testing.allocator;

    try harness.vm.exec("=quartz",
        \\assert(rosebed.register_biome {
        \\  key = "grove", parent = "forest", share = 1,
        \\  top = "obsidian", filler = "gravel", snows = true, trees = -64, flowers = 0,
        \\} == "quartz:grove")
        \\rosebed.register_mob {
        \\  key = "moth",
        \\  spawns = { category = "creature", weight = 3, biomes = { "quartz:grove" } },
        \\}
    );
    const grove = world.biome.Biome.fromName("quartz:grove").?;
    try std.testing.expect(grove.snows());
    const moth = game.mob.get(game.mob.find("quartz:moth").?).spawns.?;
    try std.testing.expect(moth.biomes.?.isSet(@intFromEnum(grove)));
    try std.testing.expect(!moth.biomes.?.isSet(@intFromEnum(world.biome.Biome.forest)));

    var generator = try world.TerrainGenerator.init(gpa, 31337);
    defer generator.deinit(gpa);

    var grove_columns: usize = 0;
    var obsidian_tops: usize = 0;
    var grass_tops: usize = 0;
    var chunk_x: i32 = 0;
    while (chunk_x < 24) : (chunk_x += 1) {
        var chunk = world.Chunk.init(chunk_x * 4, 0);
        generator.generateShape(&chunk);
        for (0..world.Chunk.width) |x| {
            for (0..world.Chunk.width) |z| {
                const column = chunk.getBiome(@intCast(x), @intCast(z));
                try std.testing.expect(column != .forest);
                if (column != grove) continue;
                grove_columns += 1;
                var y: u32 = world.Chunk.height - 1;
                while (y > 0 and chunk.getBlock(@intCast(x), y, @intCast(z)) == .air) y -= 1;
                switch (chunk.getBlock(@intCast(x), y, @intCast(z))) {
                    .obsidian => obsidian_tops += 1,
                    .grass => grass_tops += 1,
                    else => {},
                }
            }
        }
    }
    try std.testing.expect(grove_columns > 0);
    try std.testing.expect(obsidian_tops > 0);
    try std.testing.expectEqual(@as(usize, 0), grass_tops);
}

test "a mod biome's parent, share and blocks are checked as it registers" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try harness.expectFailure("rosebed.register_biome { key = 'grove', parent = 'jungle', share = 0.5 }", "there is no vanilla biome called 'jungle'");
    try harness.expectFailure("rosebed.register_biome { key = 'grove', parent = 'forest', share = 0 }", "'share' is the part of its parent it takes, above 0 and at most 1");
    try harness.expectFailure("rosebed.register_biome { key = 'grove', parent = 'forest', share = 0.5, top = 'granite' }", "'top' must be a registered block");
    try harness.vm.exec("=quartz", "rosebed.register_biome { key = 'grove', parent = 'forest', share = 0.6 }");
    try harness.expectFailure("rosebed.register_biome { key = 'glade', parent = 'forest', share = 0.5 }", "'forest' has no share left to give");
    try harness.expectFailure("rosebed.register_biome { key = 'grove', parent = 'plains', share = 0.1 }", "'quartz:grove' is already registered");
}

test "a structure's spacing, chance, radius and biomes are checked as it registers" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try harness.expectFailure("rosebed.register_structure { key = 'hut' }", "'place' must be a function");
    try harness.expectFailure("rosebed.register_structure { key = 'hut', place = print, spacing = 0 }", "'spacing' is 1 to 4096 chunks");
    try harness.expectFailure("rosebed.register_structure { key = 'hut', place = print, radius = 9 }", "'radius' is 0 to 8 chunks");
    try harness.expectFailure("rosebed.register_structure { key = 'hut', place = print, chance = 0 }", "'chance' is above 0 and at most 1");
    try harness.expectFailure("rosebed.register_structure { key = 'hut', place = print, dimension = 'nether', biomes = { 'forest' } }", "the nether has no biomes to choose from");
    try harness.vm.exec("=quartz", "assert(rosebed.register_structure { key = 'hut', place = print } == 'quartz:hut')");
    try harness.expectFailure("rosebed.register_structure { key = 'hut', place = print }", "'quartz:hut' is already registered");
}

test "noise follows the world seed, differs between noises, and is only sampled while a world generates" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    harness.hooks.install(harness.vm.lua);
    Hooks.active = &harness.hooks;
    defer Hooks.active = null;

    try harness.vm.exec("=quartz",
        \\hills = rosebed.noise { octaves = 4, scale = 0.05 }
        \\flat = rosebed.noise()
        \\rosebed.on_generate(function(chunk_x, chunk_z)
        \\  seen = { hills(chunk_x * 16 + 3, chunk_z * 16 + 7), flat(chunk_x * 16 + 3, chunk_z * 16 + 7), hills(3.5, 64, 7.5) }
        \\end)
    );
    var chunk = world.Chunk.init(0, 0);
    Hooks.shape(&chunk, .overworld, 1);
    try harness.vm.exec("=quartz", "first = seen");
    Hooks.shape(&chunk, .overworld, 1);
    try harness.vm.exec("=quartz",
        \\assert(seen[1] == first[1] and seen[3] == first[3])
        \\assert(first[1] ~= first[2])
        \\for _, value in ipairs(first) do assert(value >= -1 and value <= 1) end
    );
    Hooks.shape(&chunk, .overworld, 2);
    try harness.vm.exec("=quartz", "assert(seen[1] ~= first[1])");

    try harness.expectFailure("hills(0, 0)", "noise is only sampled while the world generates");
    try harness.expectFailure("rosebed.noise { octaves = 0 }", "'octaves' is 1 to 16");
    try harness.expectFailure("rosebed.noise { scale = -1 }", "'scale' must be above zero");
}

test "a recipe can ask for one damage value of an ingredient" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try harness.vm.exec("=quartz",
        \\rosebed.register_item { key = "gem" }
        \\rosebed.register_item { key = "sash" }
        \\rosebed.register_recipe {
        \\  grid = { "gw" },
        \\  where = { g = "quartz:gem", w = { "wool", 1 } },
        \\  result = "quartz:sash",
        \\}
        \\rosebed.register_recipe { any = { "quartz:gem", { "dye", 4 } }, result = "quartz:gem", count = 3 }
    );

    const gem: world.Id = .{ .item = world.Item.fromKey("quartz:gem").? };
    var grid: [4]?game.Inventory.ItemStack = @splat(null);

    grid[0] = .{ .id = gem, .count = 1 };
    grid[1] = .{ .id = .{ .block = .wool }, .count = 1, .meta = 1 };
    try std.testing.expectEqual(world.Item.fromKey("quartz:sash").?, game.crafting.findMatch(&grid, game.crafting.player_grid_size).?.id.item);
    grid[1].?.meta = 0;
    try std.testing.expect(game.crafting.findMatch(&grid, game.crafting.player_grid_size) == null);

    grid = @splat(null);
    grid[2] = .{ .id = gem, .count = 1 };
    grid[3] = .{ .id = .{ .item = .dye }, .count = 1, .meta = 4 };
    try std.testing.expectEqual(@as(u8, 3), game.crafting.findMatch(&grid, game.crafting.player_grid_size).?.count);
    grid[3].?.meta = 1;
    try std.testing.expect(game.crafting.findMatch(&grid, game.crafting.player_grid_size) == null);
}

test "an ingredient table has to name something first" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try harness.expectFailure(
        "rosebed.register_recipe { any = { { 4, \"dye\" } }, result = \"stick\" }",
        "an ingredient is a key, or { key, meta }",
    );
    try harness.expectFailure(
        "rosebed.register_recipe { any = { { \"dye\", 70000 } }, result = \"stick\" }",
        "an ingredient's meta is out of range",
    );
}
