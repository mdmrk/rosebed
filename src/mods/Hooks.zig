const std = @import("std");

const game = @import("game");
const math = @import("math");
const world = @import("world");
const zlua = @import("zlua");
const Lua = zlua.Lua;

const structures = @import("structures.zig");
const Vm = @import("Vm.zig");

const Hooks = @This();

lua: ?*Lua = null,
current_world: ?*world.World = null,
current_rand: ?*world.JavaRandom = null,
current_mob: ?*game.Animal = null,
current_wander: ?Wander = null,
current_chunk: ?*world.Chunk = null,
current_dimension: world.Dimension = .overworld,
current_seed: ?i64 = null,
current_plan: ?*structures.Plan = null,
current_terrain: ?*structures.Terrain = null,
decorating: bool = false,
world_tick_ref: ?i32 = null,
chunk_load_ref: ?i32 = null,
player_hurt_ref: ?i32 = null,
player_death_ref: ?i32 = null,
mob_death_ref: ?i32 = null,
block_broken_ref: ?i32 = null,
block_placed_ref: ?i32 = null,
decorators: std.ArrayList(Decorator) = .empty,
shapers: std.ArrayList(Decorator) = .empty,
noises: std.ArrayList(Noise) = .empty,
structure_specs: std.ArrayList(structures.Structure) = .empty,
plans: [structures.cache_size]?*structures.Plan = @splat(null),
next_plan: usize = 0,
block_refs: [256]BlockRefs = @splat(.{}),
item_refs: [world.item.def_capacity]ItemRefs = @splat(.{}),

pub var active: ?*Hooks = null;

pub const Decorator = struct {
    ref: i32,
    salt: i64,
    warned: bool = false,
};

pub const Noise = struct {
    mod_salt: i64,
    index: i64,
    scale: f64,
    octaves: []world.PerlinNoise,
    seeded_for: ?i64 = null,
};

pub const max_octaves = 16;
const shape_salt: i64 = 0x73686170696e67;
const noise_salt: i64 = @bitCast(@as(u64, 0x9e3779b97f4a7c15));

fn modSalt(mod_id: []const u8) i64 {
    return @bitCast(std.hash.Fnv1a_64.hash(mod_id));
}

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

pub const Wander = struct {
    animal: *game.Animal,
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    players: game.Animal.Players,
    rand: *world.JavaRandom,
    inner: *const fn (
        *game.Animal,
        std.mem.Allocator,
        *const world.World,
        game.Animal.Players,
        *world.JavaRandom,
    ) anyerror!void,
};

pub fn pathWeight(self: *Hooks, ref: i32, world_map: *const world.World, pos: world.BlockPos) ?f32 {
    const lua = self.lua orelse return null;

    const outer = self.current_world;
    self.current_world = @constCast(world_map);
    defer self.current_world = outer;

    _ = lua.getIndexRaw(zlua.registry_index, ref);
    lua.pushInteger(pos.x);
    lua.pushInteger(pos.y);
    lua.pushInteger(pos.z);
    lua.protectedCall(.{ .args = 3, .results = 1 }) catch {
        std.log.warn("a mod path weight failed: {s}", .{lua.toString(-1) catch "(no message)"});
        lua.pop(1);
        return null;
    };
    defer lua.pop(1);
    if (lua.typeOf(-1) != .number) return null;
    return @floatCast(lua.toNumber(-1) catch return null);
}

pub fn think(self: *Hooks, ref: i32, wander: Wander) void {
    const outer = self.current_wander;
    self.current_wander = wander;
    defer self.current_wander = outer;
    self.callMob(ref, wander.animal, @constCast(wander.world_map), wander.rand);
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

pub const Event = enum { world_tick, chunk_load, player_hurt, player_death, mob_death, block_broken, block_placed };

pub fn listenerFor(self: *Hooks, event: Event) *?i32 {
    return self.refFor(event);
}

fn refFor(self: *Hooks, event: Event) *?i32 {
    return switch (event) {
        .world_tick => &self.world_tick_ref,
        .chunk_load => &self.chunk_load_ref,
        .player_hurt => &self.player_hurt_ref,
        .player_death => &self.player_death_ref,
        .mob_death => &self.mob_death_ref,
        .block_broken => &self.block_broken_ref,
        .block_placed => &self.block_placed_ref,
    };
}

fn begin(self: *Hooks, event: Event) ?*Lua {
    const lua = self.lua orelse return null;
    const ref = self.refFor(event).* orelse return null;
    _ = lua.getIndexRaw(zlua.registry_index, ref);
    return lua;
}

fn settle(self: *Hooks, event: Event, lua: *Lua, args: i32, results: i32) bool {
    lua.protectedCall(.{ .args = args, .results = results }) catch {
        std.log.warn("a mod event failed and is switched off: {s}", .{lua.toString(-1) catch "(no message)"});
        lua.pop(1);
        self.refFor(event).* = null;
        return false;
    };
    if (results == 0) return false;
    const answered = lua.toBoolean(-1);
    lua.pop(1);
    return answered;
}

pub fn worldTicked(level: *game.Level) void {
    const self = active orelse return;
    const lua = self.begin(.world_tick) orelse return;
    const outer = self.current_world;
    self.current_world = &level.world_map;
    defer self.current_world = outer;
    _ = lua.pushString(@tagName(level.generator.dimension()));
    lua.pushInteger(@bitCast(level.tick_count));
    _ = self.settle(.world_tick, lua, 2, 0);
}

pub fn chunkLoaded(world_map: *world.World, chunk_x: i32, chunk_z: i32, fresh: bool) void {
    const self = active orelse return;
    const lua = self.begin(.chunk_load) orelse return;
    const outer = self.current_world;
    self.current_world = world_map;
    defer self.current_world = outer;
    lua.pushInteger(chunk_x);
    lua.pushInteger(chunk_z);
    lua.pushBoolean(fresh);
    _ = self.settle(.chunk_load, lua, 3, 0);
}

fn pushPlace(lua: *Lua, at: math.Vec3) void {
    lua.pushNumber(at.x);
    lua.pushNumber(at.y);
    lua.pushNumber(at.z);
}

pub fn playerHurt(player: *game.Player, amount: i32) bool {
    const self = active orelse return false;
    const lua = self.begin(.player_hurt) orelse return false;
    lua.pushInteger(amount);
    lua.pushInteger(player.health);
    pushPlace(lua, player.base.position);
    return self.settle(.player_hurt, lua, 5, 1);
}

pub fn playerDied(player: *game.Player) void {
    const self = active orelse return;
    const lua = self.begin(.player_death) orelse return;
    pushPlace(lua, player.base.position);
    _ = self.settle(.player_death, lua, 3, 0);
}

pub fn mobDied(type_id: game.mob.Id, animal: *game.Animal, world_map: *world.World) void {
    const self = active orelse return;
    const lua = self.begin(.mob_death) orelse return;
    const outer = self.current_world;
    const outer_mob = self.current_mob;
    self.current_world = world_map;
    self.current_mob = animal;
    defer {
        self.current_world = outer;
        self.current_mob = outer_mob;
    }
    _ = lua.pushString(game.mob.get(type_id).name);
    pushPlace(lua, animal.base.position);
    _ = self.settle(.mob_death, lua, 4, 0);
}

pub fn blockBroken(level: *game.Level, pos: world.BlockPos, block: world.Block, meta: u4) void {
    reportBlock(.block_broken, level, pos, block, meta);
}

pub fn blockPlaced(level: *game.Level, pos: world.BlockPos, block: world.Block, meta: u4) void {
    reportBlock(.block_placed, level, pos, block, meta);
}

fn reportBlock(event: Event, level: *game.Level, pos: world.BlockPos, block: world.Block, meta: u4) void {
    const self = active orelse return;
    const lua = self.begin(event) orelse return;
    const outer = self.current_world;
    self.current_world = &level.world_map;
    defer self.current_world = outer;
    const key = block.def().key;
    if (key.len == 0) _ = lua.pushString(@tagName(world.Block.air)) else _ = lua.pushString(key);
    lua.pushInteger(pos.x);
    lua.pushInteger(pos.y);
    lua.pushInteger(pos.z);
    lua.pushInteger(meta);
    _ = self.settle(event, lua, 5, 0);
}

pub fn addDecorator(self: *Hooks, arena: std.mem.Allocator, ref: i32, mod_id: []const u8) !void {
    try self.decorators.append(arena, .{ .ref = ref, .salt = modSalt(mod_id) });
}

pub fn addShaper(self: *Hooks, arena: std.mem.Allocator, ref: i32, mod_id: []const u8) !void {
    try self.shapers.append(arena, .{ .ref = ref, .salt = modSalt(mod_id) ^ shape_salt });
}

pub fn addNoise(self: *Hooks, arena: std.mem.Allocator, mod_id: []const u8, octaves: usize, scale: f64) !usize {
    const mod_salt = modSalt(mod_id);
    var index: i64 = 1;
    for (self.noises.items) |entry| {
        if (entry.mod_salt == mod_salt) index += 1;
    }
    try self.noises.append(arena, .{
        .mod_salt = mod_salt,
        .index = index,
        .scale = scale,
        .octaves = try arena.alloc(world.PerlinNoise, octaves),
    });
    return self.noises.items.len - 1;
}

pub fn deinit(self: *Hooks) void {
    for (&self.plans) |*slot| {
        const plan = slot.* orelse continue;
        plan.deinit();
        plan.gpa.destroy(plan);
        slot.* = null;
    }
}

pub fn addStructure(self: *Hooks, arena: std.mem.Allocator, spec: structures.Structure) !void {
    try self.structure_specs.append(arena, spec);
}

pub fn decorate(world_map: *world.World, generator: *world.Generator, chunk_x: i32, chunk_z: i32) std.mem.Allocator.Error!void {
    const self = active orelse return;
    const outer_world = self.current_world;
    const outer_decorating = self.decorating;
    self.current_world = world_map;
    self.decorating = true;
    defer {
        self.current_world = outer_world;
        self.decorating = outer_decorating;
    }
    try self.placeStructures(world_map, generator, chunk_x, chunk_z);
    self.runWorldHooks(self.decorators.items, generator.dimension(), generator.worldSeed(), chunk_x, chunk_z);
}

fn placeStructures(self: *Hooks, world_map: *world.World, generator: *world.Generator, chunk_x: i32, chunk_z: i32) std.mem.Allocator.Error!void {
    const seed = generator.worldSeed();
    for (self.structure_specs.items, 0..) |spec, index| {
        if (spec.dimension != generator.dimension()) continue;
        const cells_x = structures.cellRange(spec, chunk_x);
        const cells_z = structures.cellRange(spec, chunk_z);
        var cell_x = cells_x[0];
        while (cell_x <= cells_x[1]) : (cell_x += 1) {
            var cell_z = cells_z[0];
            while (cell_z <= cells_z[1]) : (cell_z += 1) {
                const instance = structures.instanceIn(spec, seed, cell_x, cell_z) orelse continue;
                if (!structures.reaches(spec, instance, chunk_x, chunk_z)) continue;
                const plan = try self.planFor(world_map.allocator, generator, index, cell_x, cell_z, instance);
                try plan.apply(world_map, chunk_x, chunk_z);
            }
        }
    }
}

fn planFor(self: *Hooks, gpa: std.mem.Allocator, generator: *world.Generator, index: usize, cell_x: i32, cell_z: i32, instance: structures.Instance) std.mem.Allocator.Error!*structures.Plan {
    const seed = generator.worldSeed();
    for (self.plans) |slot| {
        const cached = slot orelse continue;
        if (cached.structure == index and cached.seed == seed and cached.cell_x == cell_x and cached.cell_z == cell_z) return cached;
    }

    const plan = try gpa.create(structures.Plan);
    errdefer gpa.destroy(plan);
    const spec = &self.structure_specs.items[index];
    plan.* = .init(gpa, index, spec.*, seed, cell_x, cell_z, instance);
    errdefer plan.deinit();
    try self.runPlace(plan, spec, generator, instance);
    try plan.seal();

    if (self.plans[self.next_plan]) |evicted| {
        evicted.deinit();
        evicted.gpa.destroy(evicted);
    }
    self.plans[self.next_plan] = plan;
    self.next_plan = (self.next_plan + 1) % structures.cache_size;
    return plan;
}

fn runPlace(self: *Hooks, plan: *structures.Plan, spec: *structures.Structure, generator: *world.Generator, instance: structures.Instance) std.mem.Allocator.Error!void {
    const lua = self.lua orelse return;
    const saved_generator = generator.*;
    defer generator.* = saved_generator;
    var terrain: structures.Terrain = .{ .gpa = plan.gpa, .generator = generator };
    defer terrain.deinit();

    const dimension = generator.dimension();
    if (spec.biomes) |allowed| {
        const chunk, const x, const z = try terrain.column(instance.origin_x, instance.origin_z);
        if (!allowed.isSet(@intFromEnum(chunk.getBiome(x, z)))) return;
    }

    var rand = instance.rand;
    const outer_plan = self.current_plan;
    const outer_terrain = self.current_terrain;
    const outer_rand = self.current_rand;
    const outer_seed = self.current_seed;
    const outer_dimension = self.current_dimension;
    self.current_plan = plan;
    self.current_terrain = &terrain;
    self.current_rand = &rand;
    self.current_seed = generator.worldSeed();
    self.current_dimension = dimension;
    defer {
        self.current_plan = outer_plan;
        self.current_terrain = outer_terrain;
        self.current_rand = outer_rand;
        self.current_seed = outer_seed;
        self.current_dimension = outer_dimension;
    }

    _ = lua.getIndexRaw(zlua.registry_index, spec.ref);
    lua.pushInteger(instance.origin_x);
    lua.pushInteger(instance.origin_z);
    _ = lua.pushString(@tagName(dimension));
    lua.protectedCall(.{ .args = 3, .results = 0 }) catch {
        if (!spec.warned) {
            std.log.warn("a mod's structure failed: {s}", .{lua.toString(-1) catch "(no message)"});
            spec.warned = true;
        }
        lua.pop(1);
        plan.clear();
    };
}

pub fn shape(chunk: *world.Chunk, dimension: world.Dimension, seed: i64) void {
    const self = active orelse return;
    const outer_chunk = self.current_chunk;
    self.current_chunk = chunk;
    defer self.current_chunk = outer_chunk;
    self.runWorldHooks(self.shapers.items, dimension, seed, chunk.x, chunk.z);
}

fn runWorldHooks(self: *Hooks, list: []Decorator, dimension: world.Dimension, seed: i64, chunk_x: i32, chunk_z: i32) void {
    const lua = self.lua orelse return;
    if (list.len == 0) return;

    var seeder = world.JavaRandom.init(seed);
    const mult_x = @divTrunc(seeder.nextLong(), 2) *% 2 +% 1;
    const mult_z = @divTrunc(seeder.nextLong(), 2) *% 2 +% 1;
    const chunk_seed = (@as(i64, chunk_x) *% mult_x +% @as(i64, chunk_z) *% mult_z) ^ seed;

    const outer_rand = self.current_rand;
    const outer_seed = self.current_seed;
    const outer_dimension = self.current_dimension;
    self.current_seed = seed;
    self.current_dimension = dimension;
    defer {
        self.current_rand = outer_rand;
        self.current_seed = outer_seed;
        self.current_dimension = outer_dimension;
    }

    for (list) |*hook| {
        var rand = world.JavaRandom.init(chunk_seed ^ hook.salt);
        self.current_rand = &rand;
        _ = lua.getIndexRaw(zlua.registry_index, hook.ref);
        lua.pushInteger(chunk_x);
        lua.pushInteger(chunk_z);
        _ = lua.pushString(@tagName(dimension));
        lua.protectedCall(.{ .args = 3, .results = 0 }) catch {
            if (!hook.warned) {
                std.log.warn("a mod's world generation failed: {s}", .{lua.toString(-1) catch "(no message)"});
                hook.warned = true;
            }
            lua.pop(1);
        };
    }
}

pub fn sampleNoise(lua: *Lua) i32 {
    const self = hooks(lua);
    const seed = self.current_seed orelse lua.raiseErrorStr("noise is only sampled while the world generates", .{});
    const index: usize = @intCast(lua.toInteger(Lua.upvalueIndex(2)) catch unreachable);
    const entry = &self.noises.items[index];
    if (entry.seeded_for != seed) {
        var rand = world.JavaRandom.init(seed ^ entry.mod_salt ^ (entry.index *% noise_salt));
        for (entry.octaves) |*octave| octave.* = .init(&rand);
        entry.seeded_for = seed;
    }

    const flat = lua.isNoneOrNil(3);
    const x = lua.checkNumber(1);
    const y = if (flat) 0 else lua.checkNumber(2);
    const z = if (flat) lua.checkNumber(2) else lua.checkNumber(3);

    var total: f64 = 0;
    var weight: f64 = 0;
    var amplitude: f64 = 1;
    var frequency = entry.scale;
    for (entry.octaves) |octave| {
        total += octave.noise(x * frequency, y * frequency, z * frequency) * amplitude;
        weight += amplitude;
        amplitude /= 2;
        frequency *= 2;
    }
    lua.pushNumber(total / weight);
    return 1;
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

fn mobSteer(lua: *Lua) i32 {
    const animal = currentMob(lua);
    animal.move_forward = @floatCast(lua.checkNumber(1));
    animal.move_strafing = @floatCast(optionalNumber(lua, 2, 0));
    animal.random_yaw_velocity = @floatCast(optionalNumber(lua, 3, 0));
    return 0;
}

fn mobJump(lua: *Lua) i32 {
    const animal = currentMob(lua);
    animal.is_jumping = lua.isNoneOrNil(1) or lua.toBoolean(1);
    return 0;
}

fn mobLook(lua: *Lua) i32 {
    const animal = currentMob(lua);
    animal.yaw = @floatCast(lua.checkNumber(1));
    animal.pitch = @floatCast(optionalNumber(lua, 2, animal.pitch));
    return 0;
}

fn mobWander(lua: *Lua) i32 {
    const wander = hooks(lua).current_wander orelse
        lua.raiseErrorStr("only a mob's own think callback can hand the tick back", .{});
    wander.inner(wander.animal, wander.gpa, wander.world_map, wander.players, wander.rand) catch
        lua.raiseErrorStr("the mob could not be steered", .{});
    return 0;
}

fn optionalNumber(lua: *Lua, arg: i32, fallback: f64) f64 {
    if (lua.isNoneOrNil(arg)) return fallback;
    return lua.checkNumber(arg);
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
        .{ .name = "biome", .function = zlua.wrap(biomeName) },
        .{ .name = "height", .function = zlua.wrap(height) },
        .{ .name = "get_chest_item", .function = zlua.wrap(getChestItem) },
        .{ .name = "set_chest_item", .function = zlua.wrap(setChestItem) },
        .{ .name = "set_spawner", .function = zlua.wrap(setSpawner) },
        .{ .name = "get_state", .function = zlua.wrap(getState) },
        .{ .name = "set_state", .function = zlua.wrap(setState) },
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
        .{ .name = "steer", .function = zlua.wrap(mobSteer) },
        .{ .name = "jump", .function = zlua.wrap(mobJump) },
        .{ .name = "look", .function = zlua.wrap(mobLook) },
        .{ .name = "wander", .function = zlua.wrap(mobWander) },
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

fn shapedCell(chunk: *world.Chunk, pos: world.BlockPos) ?[3]u32 {
    if (pos.y < 0 or pos.y >= world.Chunk.height) return null;
    const local_x = pos.x -% chunk.x *% world.Chunk.width;
    const local_z = pos.z -% chunk.z *% world.Chunk.width;
    if (local_x < 0 or local_x >= world.Chunk.width or local_z < 0 or local_z >= world.Chunk.width) return null;
    return .{ @intCast(local_x), @intCast(pos.y), @intCast(local_z) };
}

fn planning(lua: *Lua) ?*structures.Plan {
    const self = hooks(lua);
    if (self.current_chunk != null) return null;
    return self.current_plan;
}

fn plannedColumn(lua: *Lua, plan: *structures.Plan, x: i32, z: i32) ?struct { *world.Chunk, u32, u32 } {
    if (!plan.contains(.init(x, 0, z))) return null;
    return hooks(lua).current_terrain.?.column(x, z) catch lua.raiseErrorStr("out of memory", .{});
}

fn readBlock(lua: *Lua, pos: world.BlockPos) ?world.Block {
    if (hooks(lua).current_chunk) |chunk| {
        const cell = shapedCell(chunk, pos) orelse return null;
        return chunk.getBlock(cell[0], cell[1], cell[2]);
    }
    if (planning(lua)) |plan| {
        if (!plan.contains(pos)) return null;
        if (plan.blocks.get(pos)) |placed| {
            if (placed.block) |block| return block;
        }
        const chunk, const x, const z = plannedColumn(lua, plan, pos.x, pos.z).?;
        return chunk.getBlock(x, @intCast(pos.y), z);
    }
    return currentWorld(lua).getBlock(pos);
}

fn readMeta(lua: *Lua, pos: world.BlockPos) ?u4 {
    if (hooks(lua).current_chunk) |chunk| {
        const cell = shapedCell(chunk, pos) orelse return null;
        return chunk.getBlockMetadata(cell[0], cell[1], cell[2]);
    }
    if (planning(lua)) |plan| {
        if (!plan.contains(pos)) return null;
        if (plan.blocks.get(pos)) |placed| {
            if (placed.meta) |meta| return meta;
        }
        const chunk, const x, const z = plannedColumn(lua, plan, pos.x, pos.z).?;
        return chunk.getBlockMetadata(x, @intCast(pos.y), z);
    }
    return currentWorld(lua).getBlockMetadata(pos);
}

fn getBlock(lua: *Lua) i32 {
    const block = readBlock(lua, position(lua, 1)) orelse {
        lua.pushNil();
        return 1;
    };
    const key = block.def().key;
    if (key.len == 0) lua.pushNil() else _ = lua.pushString(key);
    return 1;
}

fn getMeta(lua: *Lua) i32 {
    if (readMeta(lua, position(lua, 1))) |meta| lua.pushInteger(meta) else lua.pushNil();
    return 1;
}

fn setBlock(lua: *Lua) i32 {
    const pos = position(lua, 1);
    const block = blockArgument(lua, 4);
    const meta: ?u4 = if (lua.isNoneOrNil(5)) null else metadata(lua, 5);
    if (hooks(lua).current_chunk) |chunk| {
        const cell = shapedCell(chunk, pos) orelse return 0;
        chunk.setBlock(cell[0], cell[1], cell[2], block);
        if (meta) |value| chunk.setBlockMetadata(cell[0], cell[1], cell[2], value);
        return 0;
    }
    if (planning(lua)) |plan| {
        if (!plan.contains(pos)) return 0;
        plan.setBlock(pos, block, meta) catch lua.raiseErrorStr("out of memory", .{});
        return 0;
    }
    const world_map = currentWorld(lua);
    if (hooks(lua).decorating) {
        world_map.setBlock(pos, block);
        if (meta) |value| world_map.setBlockMetadata(pos, value);
        return 0;
    }
    const changed = if (meta) |value|
        world_map.setBlockAndMetadataWithNotify(pos, block, value)
    else
        world_map.setBlockWithNotify(pos, block);
    changed catch lua.raiseErrorStr("out of memory", .{});
    return 0;
}

fn setMeta(lua: *Lua) i32 {
    const pos = position(lua, 1);
    const meta = metadata(lua, 4);
    if (hooks(lua).current_chunk) |chunk| {
        const cell = shapedCell(chunk, pos) orelse return 0;
        chunk.setBlockMetadata(cell[0], cell[1], cell[2], meta);
        return 0;
    }
    if (planning(lua)) |plan| {
        if (!plan.contains(pos)) return 0;
        plan.setMeta(pos, meta) catch lua.raiseErrorStr("out of memory", .{});
        return 0;
    }
    const world_map = currentWorld(lua);
    if (hooks(lua).decorating) {
        world_map.setBlockMetadata(pos, meta);
        return 0;
    }
    world_map.setBlockMetadataWithNotify(pos, meta) catch lua.raiseErrorStr("out of memory", .{});
    return 0;
}

fn scheduleTick(lua: *Lua) i32 {
    const world_map = currentWorld(lua);
    const pos = position(lua, 1);
    const delay = std.math.cast(u32, lua.checkInteger(4)) orelse lua.argError(4, "delay must be a whole number of ticks");
    world_map.scheduleBlockUpdate(pos, world_map.getBlock(pos), delay) catch lua.raiseErrorStr("out of memory", .{});
    return 0;
}

fn columnHeight(chunk: *const world.Chunk, x: u32, z: u32) u32 {
    var y: u32 = world.Chunk.height - 1;
    while (y > 0 and world.light.opacity(chunk.getBlock(x, y - 1, z)) == 0) y -= 1;
    return y;
}

fn generatedColumn(lua: *Lua, x: i32, z: i32) ?struct { *world.Chunk, u32, u32 } {
    if (hooks(lua).current_chunk) |chunk| {
        const cell = shapedCell(chunk, .init(x, 0, z)) orelse return null;
        return .{ chunk, cell[0], cell[2] };
    }
    const plan = planning(lua).?;
    return plannedColumn(lua, plan, x, z);
}

fn generating(lua: *Lua) bool {
    return hooks(lua).current_chunk != null or planning(lua) != null;
}

fn biomeName(lua: *Lua) i32 {
    const x = coordinate(lua, 1);
    const z = coordinate(lua, 2);
    if (generating(lua)) {
        const chunk, const local_x, const local_z = generatedColumn(lua, x, z) orelse {
            lua.pushNil();
            return 1;
        };
        const name = if (hooks(lua).current_dimension != .overworld) "nether" else chunk.getBiome(local_x, local_z).name();
        _ = lua.pushString(name);
        return 1;
    }
    const world_map = currentWorld(lua);
    _ = lua.pushString(if (world_map.has_sky) world_map.biomeAt(x, z).name() else "nether");
    return 1;
}

fn height(lua: *Lua) i32 {
    const x = coordinate(lua, 1);
    const z = coordinate(lua, 2);
    if (generating(lua)) {
        const chunk, const local_x, const local_z = generatedColumn(lua, x, z) orelse {
            lua.pushNil();
            return 1;
        };
        lua.pushInteger(columnHeight(chunk, local_x, local_z));
        return 1;
    }
    lua.pushInteger(world.decorate.heightValueAt(currentWorld(lua), x, z));
    return 1;
}

fn requireBlock(lua: *Lua, pos: world.BlockPos, block: world.Block, comptime message: [:0]const u8) void {
    if (readBlock(lua, pos) != block) lua.raiseErrorStr(message, .{ pos.x, pos.y, pos.z });
}

fn chestSlot(lua: *Lua, arg: i32) usize {
    const slot = lua.checkInteger(arg);
    if (slot < 1 or slot > world.chest.slot_count) lua.argError(arg, "a chest slot is 1 to 27");
    return @intCast(slot - 1);
}

fn getChestItem(lua: *Lua) i32 {
    const pos = position(lua, 1);
    const slot = chestSlot(lua, 4);
    requireBlock(lua, pos, .chest, "there is no chest at %d %d %d");
    const found = if (planning(lua)) |plan|
        plan.chestItem(pos, slot)
    else
        (currentWorld(lua).addChest(pos) catch lua.raiseErrorStr("out of memory", .{})).items[slot];
    const stack = found orelse {
        lua.pushNil();
        return 1;
    };
    _ = lua.pushString(switch (stack.id) {
        .block => |id| id.def().key,
        .item => |id| id.def().key,
    });
    lua.pushInteger(stack.count);
    lua.pushInteger(stack.meta);
    return 3;
}

fn setChestItem(lua: *Lua) i32 {
    const pos = position(lua, 1);
    const slot = chestSlot(lua, 4);
    requireBlock(lua, pos, .chest, "there is no chest at %d %d %d");
    const stack: ?world.Stack = if (lua.isNoneOrNil(5)) null else blk: {
        const key = lua.checkString(5);
        const id: world.Id = if (world.Block.fromKey(key)) |block|
            .{ .block = block }
        else if (world.Item.fromKey(key)) |item|
            .{ .item = item }
        else
            lua.raiseErrorStr("no block or item is registered as '%s'", .{key.ptr});
        const count = std.math.cast(u8, lua.optInteger(6) orelse 1) orelse lua.argError(6, "a count is 1 to 64");
        if (count == 0 or count > world.chest.stack_limit) lua.argError(6, "a count is 1 to 64");
        const meta = std.math.cast(u16, lua.optInteger(7) orelse 0) orelse lua.argError(7, "meta is 0 to 65535");
        break :blk .{ .id = id, .count = count, .meta = meta };
    };
    if (planning(lua)) |plan| {
        plan.chest_items.append(plan.gpa, .{ .pos = pos, .slot = slot, .stack = stack }) catch lua.raiseErrorStr("out of memory", .{});
        return 0;
    }
    (currentWorld(lua).addChest(pos) catch lua.raiseErrorStr("out of memory", .{})).slot(slot).* = stack;
    return 0;
}

fn setSpawner(lua: *Lua) i32 {
    const pos = position(lua, 1);
    requireBlock(lua, pos, .mob_spawner, "there is no mob spawner at %d %d %d");
    const name = lua.checkString(4);
    if (game.mob.find(name) == null) lua.raiseErrorStr("no mob is registered as '%s'", .{name.ptr});
    if (name.len > world.mob_spawner.max_mob_name) lua.argError(4, "the mob's name is too long for a spawner");
    if (planning(lua)) |plan| {
        var entry: structures.SpawnerMob = .{ .pos = pos, .name = undefined, .len = @intCast(name.len) };
        @memcpy(entry.name[0..name.len], name);
        plan.spawners.append(plan.gpa, entry) catch lua.raiseErrorStr("out of memory", .{});
        return 0;
    }
    const spawner = currentWorld(lua).addMobSpawner(pos) catch lua.raiseErrorStr("out of memory", .{});
    spawner.setMobName(name);
    return 0;
}

fn pushState(lua: *Lua, state: world.nbt.Compound) void {
    lua.newTable();
    for (state.keys(), state.values()) |key, value| {
        _ = lua.pushString(key);
        switch (value) {
            .byte => |number| lua.pushBoolean(number != 0),
            .short => |number| lua.pushNumber(@floatFromInt(number)),
            .int => |number| lua.pushNumber(@floatFromInt(number)),
            .long => |number| lua.pushNumber(@floatFromInt(number)),
            .float => |number| lua.pushNumber(number),
            .double => |number| lua.pushNumber(number),
            .string => |text| _ = lua.pushString(text),
            else => {
                lua.pop(1);
                continue;
            },
        }
        lua.setTableRaw(-3);
    }
}

fn readState(lua: *Lua, arg: i32, gpa: std.mem.Allocator) world.nbt.Compound {
    var state: world.nbt.Compound = .{};
    errdefer {
        var owned: world.nbt.Tag = .{ .compound = state };
        world.nbt.deinit(gpa, &owned);
    }

    lua.pushNil();
    while (lua.next(arg)) {
        if (lua.typeOf(-2) != .string) lua.argError(arg, "a state is keyed by strings");
        const key = lua.toString(-2) catch unreachable;
        const value: world.nbt.Tag = switch (lua.typeOf(-1)) {
            .boolean => .{ .byte = if (lua.toBoolean(-1)) 1 else 0 },
            .number => .{ .double = lua.toNumber(-1) catch unreachable },
            .string => .{ .string = gpa.dupe(u8, lua.toString(-1) catch unreachable) catch
                lua.raiseErrorStr("out of memory", .{}) },
            else => lua.argError(arg, "a state holds numbers, strings and booleans"),
        };
        world.nbt.putDuped(gpa, &state, key, value) catch lua.raiseErrorStr("out of memory", .{});
        lua.pop(1);
    }
    return state;
}

fn getState(lua: *Lua) i32 {
    const pos = position(lua, 1);
    const state = currentWorld(lua).blockStateAt(pos) orelse {
        lua.pushNil();
        return 1;
    };
    pushState(lua, state.*);
    return 1;
}

fn setState(lua: *Lua) i32 {
    const pos = position(lua, 1);
    const world_map = currentWorld(lua);
    if (lua.isNoneOrNil(4)) {
        _ = world_map.removeBlockState(pos);
        return 0;
    }
    lua.checkType(4, .table);

    const state = readState(lua, 4, world_map.allocator);
    world_map.putBlockState(pos, state) catch lua.raiseErrorStr("out of memory", .{});
    return 0;
}

fn hooks(lua: *Lua) *Hooks {
    return @ptrCast(@alignCast(@constCast(lua.toPointer(Lua.upvalueIndex(1)).?)));
}

fn currentWorld(lua: *Lua) *world.World {
    const self = hooks(lua);
    if (self.current_chunk != null) lua.raiseErrorStr("only the blocks of the chunk being shaped can be reached here", .{});
    if (self.current_plan != null) lua.raiseErrorStr("a structure only reaches blocks, chests and spawners within its radius", .{});
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

    fn listen(self: *Harness, event: Event, source: [:0]const u8) !void {
        try self.vm.exec("=test", source);
        _ = self.vm.lua.getGlobal("handler");
        self.hooks.listenerFor(event).* = self.vm.lua.ref(zlua.registry_index);
    }

    fn global(self: *Harness, name: [:0]const u8) !zlua.LuaType {
        return self.vm.lua.getGlobal(name);
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

test "a script asks which biome a column is in and where its ground is" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    harness.hooks.current_world = &harness.world_map;

    const chunk = harness.world_map.getChunk(0, 0).?;
    chunk.setClimate(4, 4, 0.99, 0.1);
    chunk.setClimate(5, 4, 0.05, 0.5);
    harness.world_map.setBlock(.init(4, 60, 4), .sand);
    harness.world_map.setBlock(.init(4, 61, 4), .sand);
    harness.world_map.setBlock(.init(5, 70, 4), .leaves);

    try harness.vm.exec("=test",
        \\local w = rosebed.world
        \\assert(w.biome(4, 4) == "desert")
        \\assert(w.biome(5, 4) == "tundra")
        \\assert(w.height(4, 4) == 62)
        \\assert(w.height(5, 4) == 71)
        \\assert(w.height(6, 4) == 0)
    );

    harness.world_map.has_sky = false;
    try harness.vm.exec("=test", "assert(rosebed.world.biome(4, 4) == 'nether')");
}

test "a script fills a chest and names a spawner's mob" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    harness.hooks.current_world = &harness.world_map;

    try harness.vm.exec("=test",
        \\local w = rosebed.world
        \\w.set_block(4, 10, 4, "chest")
        \\assert(w.get_chest_item(4, 10, 4, 1) == nil)
        \\w.set_chest_item(4, 10, 4, 1, "ingot_iron", 5)
        \\w.set_chest_item(4, 10, 4, 27, "dye", 1, 3)
        \\w.set_chest_item(4, 10, 4, 2, "cobblestone", 64)
        \\w.set_chest_item(4, 10, 4, 2, nil)
        \\local key, count, meta = w.get_chest_item(4, 10, 4, 27)
        \\assert(key == "dye" and count == 1 and meta == 3)
        \\w.set_block(6, 10, 4, "mob_spawner")
        \\w.set_spawner(6, 10, 4, "Skeleton")
    );

    const box = harness.world_map.chestAt(.init(4, 10, 4)).?;
    try std.testing.expectEqual(world.Item.ingot_iron, box.items[0].?.id.item);
    try std.testing.expectEqual(@as(u8, 5), box.items[0].?.count);
    try std.testing.expectEqual(@as(?world.Stack, null), box.items[1]);
    try std.testing.expectEqual(@as(u16, 3), box.items[26].?.meta);
    try std.testing.expectEqualStrings("Skeleton", harness.world_map.mobSpawnerAt(.init(6, 10, 4)).?.mobName());
}

test "chests and spawners refuse what they cannot hold" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    harness.hooks.current_world = &harness.world_map;
    harness.world_map.setBlock(.init(4, 10, 4), .chest);
    harness.world_map.setBlock(.init(6, 10, 4), .mob_spawner);

    try harness.expectFailure("rosebed.world.set_chest_item(5, 10, 4, 1, 'stick')", "there is no chest at 5 10 4");
    try harness.expectFailure("rosebed.world.set_chest_item(4, 10, 4, 28, 'stick')", "a chest slot is 1 to 27)");
    try harness.expectFailure("rosebed.world.set_chest_item(4, 10, 4, 1, 'stick', 65)", "a count is 1 to 64)");
    try harness.expectFailure("rosebed.world.set_chest_item(4, 10, 4, 1, 'granite')", "no block or item is registered as 'granite'");
    try harness.expectFailure("rosebed.world.set_spawner(4, 10, 4, 'Pig')", "there is no mob spawner at 4 10 4");
    try harness.expectFailure("rosebed.world.set_spawner(6, 10, 4, 'Dragon')", "no mob is registered as 'Dragon'");
}

test "while a chunk is shaped only that chunk's blocks answer" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var chunk = world.Chunk.init(0, 0);
    harness.hooks.current_chunk = &chunk;

    try harness.vm.exec("=test",
        \\rosebed.world.set_block(3, 10, 4, "log", 2)
        \\rosebed.world.set_block(3, 10, 4, "log")
        \\assert(rosebed.world.get_meta(3, 10, 4) == 2)
        \\rosebed.world.set_meta(3, 10, 4, 1)
        \\rosebed.world.set_block(16, 10, 4, "stone")
        \\assert(rosebed.world.get_block(16, 10, 4) == nil)
        \\assert(rosebed.world.get_meta(-1, 10, 4) == nil)
    );
    try std.testing.expectEqual(world.Block.log, chunk.getBlock(3, 10, 4));
    try std.testing.expectEqual(@as(u4, 1), chunk.getBlockMetadata(3, 10, 4));
    try harness.expectFailure("rosebed.world.schedule_tick(3, 10, 4, 1)", "only the blocks of the chunk being shaped can be reached here");
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

test "a mod hears a chunk arrive and can tell a fresh one from a reloaded one" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    defer Hooks.active = null;
    Hooks.active = &harness.hooks;

    try harness.listen(.chunk_load,
        \\seen = ""
        \\function handler(x, z, fresh)
        \\  seen = seen .. x .. "," .. z .. (fresh and "!" or "?") .. ";"
        \\  rosebed.world.set_block(x * 16, 5, z * 16, "stone")
        \\end
    );

    Hooks.chunkLoaded(&harness.world_map, 0, 0, true);
    Hooks.chunkLoaded(&harness.world_map, 1, -1, false);

    try std.testing.expectEqual(zlua.LuaType.string, try harness.global("seen"));
    try std.testing.expectEqualStrings("0,0!;1,-1?;", try harness.vm.lua.toString(-1));
    harness.vm.lua.pop(1);
    try std.testing.expectEqual(world.Block.stone, harness.world_map.getBlock(.init(0, 5, 0)));
}

test "a mod can swallow the damage a player was about to take" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    defer Hooks.active = null;
    Hooks.active = &harness.hooks;

    try harness.listen(.player_hurt,
        \\taken = 0
        \\height = 0
        \\function handler(amount, health, x, y, z)
        \\  taken = taken + amount
        \\  height = y
        \\  return amount < 3
        \\end
    );

    var player: game.Player = .spawn(.init(2, 70, 3));
    try std.testing.expect(Hooks.playerHurt(&player, 1));
    try std.testing.expect(!Hooks.playerHurt(&player, 5));

    try std.testing.expectEqual(zlua.LuaType.number, try harness.global("taken"));
    try std.testing.expectEqual(@as(i64, 6), harness.vm.lua.toInteger(-1) catch unreachable);
    harness.vm.lua.pop(1);
    try std.testing.expectEqual(zlua.LuaType.number, try harness.global("height"));
    try std.testing.expectEqual(@as(f64, 70), harness.vm.lua.toNumber(-1) catch unreachable);
    harness.vm.lua.pop(1);
}

test "a mod hears a player die where it died" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    defer Hooks.active = null;
    Hooks.active = &harness.hooks;

    try harness.listen(.player_death, "fell = nil function handler(x, y, z) fell = y end");
    var player: game.Player = .spawn(.init(0, 12, 0));
    Hooks.playerDied(&player);

    try std.testing.expectEqual(zlua.LuaType.number, try harness.global("fell"));
    try std.testing.expectEqual(@as(f64, 12), harness.vm.lua.toNumber(-1) catch unreachable);
    harness.vm.lua.pop(1);
}

test "a mod hears which mob died and reaches the world where it fell" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    defer Hooks.active = null;
    Hooks.active = &harness.hooks;

    try harness.listen(.mob_death,
        \\who = nil
        \\function handler(key, x, y, z)
        \\  who = key
        \\  rosebed.world.set_block(math.floor(x), math.floor(y), math.floor(z), "gravel")
        \\end
    );

    var rand: world.JavaRandom = .init(1);
    const animal = try game.mob.get(game.mob.pig).spawn(std.testing.allocator, .init(3, 6, 4), &rand);
    defer game.mob.get(game.mob.pig).destroy(animal, std.testing.allocator);
    Hooks.mobDied(game.mob.pig, animal, &harness.world_map);

    try std.testing.expectEqual(zlua.LuaType.string, try harness.global("who"));
    try std.testing.expectEqualStrings("Pig", try harness.vm.lua.toString(-1));
    harness.vm.lua.pop(1);
    try std.testing.expectEqual(world.Block.gravel, harness.world_map.getBlock(.init(3, 6, 4)));
}

test "a mod hears a block placed and reaches the world it landed in" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    defer Hooks.active = null;
    Hooks.active = &harness.hooks;

    try harness.listen(.block_placed,
        \\what = nil
        \\function handler(key, x, y, z, meta)
        \\  what = key
        \\  facing = meta
        \\  rosebed.world.set_block(x, y + 1, z, "gravel")
        \\end
    );

    var level = game.Level.init(std.testing.allocator, try world.Generator.init(std.testing.allocator, .overworld, 7));
    defer level.deinit(std.testing.allocator);
    _ = try level.world_map.createChunk(0, 0);
    Hooks.blockPlaced(&level, .init(3, 6, 4), .furnace, 2);

    try std.testing.expectEqual(zlua.LuaType.string, try harness.global("what"));
    try std.testing.expectEqualStrings("furnace", try harness.vm.lua.toString(-1));
    harness.vm.lua.pop(1);
    try std.testing.expectEqual(zlua.LuaType.number, try harness.global("facing"));
    try std.testing.expectEqual(@as(i64, 2), harness.vm.lua.toInteger(-1) catch unreachable);
    harness.vm.lua.pop(1);
    try std.testing.expectEqual(world.Block.gravel, level.world_map.getBlock(.init(3, 7, 4)));
}

test "a mod keeps its own state on a block and reads it back" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    harness.hooks.current_world = &harness.world_map;

    try harness.vm.exec("=test",
        \\local w = rosebed.world
        \\assert(w.get_state(4, 10, 4) == nil)
        \\w.set_state(4, 10, 4, { charge = 2.5, owner = "Steve", lit = true })
        \\local held = w.get_state(4, 10, 4)
        \\assert(held.charge == 2.5, "charge")
        \\assert(held.owner == "Steve", "owner")
        \\assert(held.lit == true, "lit")
        \\w.set_state(4, 10, 4, { charge = 3 })
        \\held = w.get_state(4, 10, 4)
        \\assert(held.charge == 3 and held.owner == nil, "replaced")
        \\w.set_state(4, 10, 4, nil)
        \\assert(w.get_state(4, 10, 4) == nil, "cleared")
    );
}

test "a state only holds what NBT can carry" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    harness.hooks.current_world = &harness.world_map;

    try harness.expectFailure(
        \\rosebed.world.set_state(4, 10, 4, { nested = {} })
    , "a state holds numbers, strings and booleans)");
    try std.testing.expect(harness.world_map.blockStateAt(.init(4, 10, 4)) == null);
}

test "an event handler that fails is switched off and stops being called" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    defer Hooks.active = null;
    Hooks.active = &harness.hooks;

    try harness.listen(.chunk_load, "count = 0 function handler() count = count + 1 error('boom') end");
    Hooks.chunkLoaded(&harness.world_map, 0, 0, true);
    Hooks.chunkLoaded(&harness.world_map, 0, 0, true);

    try std.testing.expect(harness.hooks.listenerFor(.chunk_load).* == null);
    try std.testing.expectEqual(zlua.LuaType.number, try harness.global("count"));
    try std.testing.expectEqual(@as(i64, 1), harness.vm.lua.toInteger(-1) catch unreachable);
    harness.vm.lua.pop(1);
}

test "with nothing listening an event costs nothing and changes nothing" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    defer Hooks.active = null;
    Hooks.active = &harness.hooks;

    var player: game.Player = .spawn(.init(0, 64, 0));
    try std.testing.expect(!Hooks.playerHurt(&player, 5));
    Hooks.playerDied(&player);
    Hooks.chunkLoaded(&harness.world_map, 0, 0, true);
    try std.testing.expectEqual(world.Block.air, harness.world_map.getBlock(.init(0, 5, 0)));
}
