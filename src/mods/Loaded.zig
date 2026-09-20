const std = @import("std");

const game = @import("game");
const net = @import("net");
const world = @import("world");

const discovery = @import("discovery.zig");
const Commands = @import("Commands.zig");
const Effects = @import("Effects.zig");
const Hooks = @import("Hooks.zig");
const Hud = @import("Hud.zig");
const Input = @import("Input.zig");
const load_order = @import("load_order.zig");
const ModPlayer = @import("Player.zig");
const Net = @import("Net.zig");
const mobs = @import("mobs.zig");
const registry = @import("registry.zig");
const Vm = @import("Vm.zig");

const Loaded = @This();

arena: *std.heap.ArenaAllocator,
vm: Vm,
hooks: *Hooks,
hud: *Hud,
input: *Input,
player: *ModPlayer,
net_api: *Net,
effects: *Effects,
commands: *Commands,
mods: []const discovery.Mod,
block_textures: []const registry.BlockTexture,
item_textures: []const registry.ItemTexture,
mob_skins: []const registry.MobSkin,
list: net.packet.ModList,

pub const folder_name = "mods";
pub const entry_point = "common.lua";
pub const client_entry_point = "client.lua";

const source_limit: std.Io.Limit = .limited(4 * 1024 * 1024);

pub fn load(gpa: std.mem.Allocator, io: std.Io, mods_dir: std.Io.Dir, report: *std.Io.Writer) !Loaded {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    const found = discovery.discover(allocator, io, mods_dir) catch |err| {
        report.print("could not read the mods folder: {t}\n", .{err}) catch {};
        return err;
    };
    const mods = load_order.sort(allocator, found) catch |err| {
        report.print("could not order the mods: {t}\n", .{err}) catch {};
        return err;
    };

    const hooks = try allocator.create(Hooks);
    hooks.* = .{};
    const net_api = try allocator.create(Net);
    net_api.* = .{ .gpa = gpa };
    const effects = try allocator.create(Effects);
    effects.* = .{ .gpa = gpa };
    const commands = try allocator.create(Commands);
    commands.* = .{ .arena = allocator };
    const registrar = try allocator.create(registry.Registrar);
    registrar.* = .{ .arena = allocator, .hooks = hooks };
    var vm: Vm = try .init(gpa);
    errdefer vm.deinit();
    registry.install(vm.lua, registrar);
    hooks.install(vm.lua);
    net_api.install(vm.lua);
    effects.install(vm.lua);
    commands.install(vm.lua);

    errdefer resetRegistries();
    var shared: std.ArrayList(discovery.Mod) = .empty;
    for (mods) |mod| {
        var dir = try mods_dir.openDir(io, mod.folder, .{});
        defer dir.close(io);
        const source = dir.readFileAlloc(io, entry_point, allocator, source_limit) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => {
                report.print("{s}/{s}: {t}\n", .{ mod.folder, entry_point, err }) catch {};
                return err;
            },
        };
        registrar.mod_id = mod.manifest.id;
        registrar.mod_folder = mod.folder;
        const chunk_name = try std.fmt.allocPrintSentinel(allocator, "@{s}/{s}", .{ mod.folder, entry_point }, 0);
        vm.exec(chunk_name, source) catch |err| {
            report.print("{s}\n", .{vm.errorMessage()}) catch {};
            return err;
        };
        try shared.append(allocator, mod);
    }
    registrar.open = false;
    const list = try describe(allocator, shared.items);
    const hud = try allocator.create(Hud);
    hud.* = .{};
    const input = try allocator.create(Input);
    input.* = .{};
    const player = try allocator.create(ModPlayer);
    player.* = .{};

    Hooks.active = hooks;
    if (hooks.decorators.items.len > 0 or hooks.structure_specs.items.len > 0) world.generator.after_decorate = Hooks.decorate;
    if (hooks.shapers.items.len > 0) world.generator.after_shape = Hooks.shape;
    if (hooks.listenerFor(.world_tick).* != null) game.Level.on_tick = Hooks.worldTicked;
    if (hooks.listenerFor(.chunk_load).* != null) world.World.on_chunk_load = Hooks.chunkLoaded;
    if (hooks.listenerFor(.player_hurt).* != null) game.Player.on_hurt = Hooks.playerHurt;
    if (hooks.listenerFor(.player_death).* != null) game.Player.on_death = Hooks.playerDied;
    if (hooks.listenerFor(.mob_death).* != null) game.Entities.on_mob_death = Hooks.mobDied;
    if (hooks.listenerFor(.block_broken).* != null) game.interact.on_block_broken = Hooks.blockBroken;
    if (hooks.listenerFor(.block_placed).* != null) game.interact.on_block_placed = Hooks.blockPlaced;

    return .{
        .arena = arena,
        .vm = vm,
        .hooks = hooks,
        .hud = hud,
        .input = input,
        .player = player,
        .net_api = net_api,
        .effects = effects,
        .commands = commands,
        .mods = mods,
        .block_textures = registrar.block_textures.items,
        .item_textures = registrar.item_textures.items,
        .mob_skins = registrar.mob_skins.items,
        .list = list,
    };
}

pub fn runClientScripts(self: *Loaded, io: std.Io, mods_dir: std.Io.Dir, report: *std.Io.Writer) !void {
    self.commands.on_client = true;
    self.hud.install(self.vm.lua);
    self.input.install(self.vm.lua);
    self.player.install(self.vm.lua);
    game.Player.steer = ModPlayer.steer;
    const allocator = self.arena.allocator();
    for (self.mods) |mod| {
        var dir = try mods_dir.openDir(io, mod.folder, .{});
        defer dir.close(io);
        const source = dir.readFileAlloc(io, client_entry_point, allocator, source_limit) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => {
                report.print("{s}/{s}: {t}\n", .{ mod.folder, client_entry_point, err }) catch {};
                return err;
            },
        };
        const chunk_name = try std.fmt.allocPrintSentinel(allocator, "@{s}/{s}", .{ mod.folder, client_entry_point }, 0);
        self.vm.exec(chunk_name, source) catch |err| {
            report.print("{s}\n", .{self.vm.errorMessage()}) catch {};
            return err;
        };
    }
}

fn describe(arena: std.mem.Allocator, mods: []const discovery.Mod) !net.packet.ModList {
    const entries = try arena.alloc(net.packet.ModList.Mod, mods.len);
    for (mods, entries) |mod, *entry| entry.* = .{ .id = mod.manifest.id, .version = mod.manifest.version };

    var keys: std.ArrayList(net.packet.ModList.Key) = .empty;
    for (0..256) |raw| {
        const block: world.Block = @enumFromInt(raw);
        if (block.def().key.len == 0 or block.isVanilla()) continue;
        try keys.append(arena, .{ .key = block.def().key, .numeric = @intCast(raw) });
    }
    for (0..world.item.def_capacity) |offset| {
        const raw = world.item.first_item_id + offset;
        const item: world.Item = @enumFromInt(raw);
        if (item.def().key.len == 0 or item.isVanilla()) continue;
        try keys.append(arena, .{ .key = item.def().key, .numeric = @intCast(raw) });
    }
    var mob_keys: std.ArrayList(net.packet.ModList.Key) = .empty;
    var type_id: game.mob.Id = 0;
    while (type_id < game.mob.registered()) : (type_id += 1) {
        const wire = game.mob.get(type_id).wire_id orelse continue;
        if (wire < game.mob.first_mod_wire_id) continue;
        try mob_keys.append(arena, .{ .key = game.mob.get(type_id).name, .numeric = wire });
    }

    return .{ .mods = entries, .keys = keys.items, .mobs = mob_keys.items };
}

pub fn deinit(self: *Loaded, gpa: std.mem.Allocator) void {
    if (Hooks.active == self.hooks) {
        Hooks.active = null;
        world.generator.after_decorate = null;
        world.generator.after_shape = null;
        game.Level.on_tick = null;
        world.World.on_chunk_load = null;
        game.Player.on_hurt = null;
        game.Player.on_death = null;
        game.Entities.on_mob_death = null;
        game.interact.on_block_broken = null;
        game.interact.on_block_placed = null;
    }
    if (ModPlayer.active == self.player) {
        ModPlayer.active = null;
        game.Player.steer = null;
    }
    self.hooks.deinit();
    self.net_api.deinit();
    self.effects.deinit();
    self.commands.deinit();
    self.vm.deinit();
    self.arena.deinit();
    gpa.destroy(self.arena);
    resetRegistries();
}

fn resetRegistries() void {
    game.commands.resetRegistry();
    world.Block.resetRegistry();
    world.Item.resetRegistry();
    game.crafting.resetRegistry();
    game.mob.reset();
    mobs.reset();
    world.biome.resetRegistry();
}

fn writeMod(io: std.Io, dir: std.Io.Dir, folder: []const u8, manifest: []const u8, common: ?[]const u8) !void {
    try dir.createDirPath(io, folder);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    try dir.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&path_buffer, "{s}/mod.json", .{folder}), .data = manifest });
    if (common) |source| {
        try dir.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&path_buffer, "{s}/" ++ entry_point, .{folder}), .data = source });
    }
}

test "mods load in dependency and id order whatever their folders are called" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    defer world.Block.resetRegistry();

    try writeMod(io, tmp.dir, "aaa",
        \\{ "id": "wiring", "version": "1.0.0", "depends": ["copper"] }
    , "rosebed.register_block { key = 'wire' }");
    try writeMod(io, tmp.dir, "bbb",
        \\{ "id": "stone", "version": "1.0.0" }
    , "rosebed.register_block { key = 'slate' }");
    try writeMod(io, tmp.dir, "zzz",
        \\{ "id": "copper", "version": "1.0.0" }
    , "rosebed.register_block { key = 'ore' }");
    try writeMod(io, tmp.dir, "docs",
        \\{ "id": "docs", "version": "1.0.0" }
    , null);

    var report: std.Io.Writer.Allocating = .init(gpa);
    defer report.deinit();
    var loaded = try load(gpa, io, tmp.dir, &report.writer);
    defer loaded.deinit(gpa);

    try std.testing.expectEqual(4, loaded.mods.len);
    try std.testing.expectEqual(@as(world.Block, @enumFromInt(97)), world.Block.fromKey("copper:ore").?);
    try std.testing.expectEqual(@as(world.Block, @enumFromInt(98)), world.Block.fromKey("stone:slate").?);
    try std.testing.expectEqual(@as(world.Block, @enumFromInt(99)), world.Block.fromKey("wiring:wire").?);
    try std.testing.expectEqualStrings("", report.written());
}

test "block textures are kept with the folder of the mod that named them" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    defer world.Block.resetRegistry();

    try writeMod(io, tmp.dir, "quartz_folder",
        \\{ "id": "quartz", "version": "1.0.0" }
    , "rosebed.register_block { key = 'marble', textures = 'marble.png' }");

    var report: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer report.deinit();
    var loaded = try load(std.testing.allocator, io, tmp.dir, &report.writer);
    defer loaded.deinit(std.testing.allocator);

    try std.testing.expectEqual(1, loaded.block_textures.len);
    try std.testing.expectEqualStrings("quartz_folder", loaded.block_textures[0].folder);
    try std.testing.expectEqualStrings("marble.png", loaded.block_textures[0].faces.get(.up).?);
}

test "the loaded mods describe themselves for the handshake" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    defer world.Block.resetRegistry();
    defer world.Item.resetRegistry();

    try writeMod(io, tmp.dir, "wiring",
        \\{ "id": "wiring", "version": "2.1.0", "depends": ["copper"] }
    , "rosebed.register_item { key = 'spool' }\nrosebed.override_block('stone', { hardness = 3 })");
    try writeMod(io, tmp.dir, "copper",
        \\{ "id": "copper", "version": "1.0.0" }
    , "rosebed.register_block { key = 'ore' }");

    var report: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer report.deinit();
    var loaded = try load(std.testing.allocator, io, tmp.dir, &report.writer);
    defer loaded.deinit(std.testing.allocator);

    const list = loaded.list;
    try std.testing.expectEqual(2, list.mods.len);
    try std.testing.expectEqualStrings("copper", list.mods[0].id);
    try std.testing.expectEqualStrings("1.0.0", list.mods[0].version);
    try std.testing.expectEqualStrings("wiring", list.mods[1].id);
    try std.testing.expectEqualStrings("2.1.0", list.mods[1].version);

    try std.testing.expectEqual(2, list.keys.len);
    try std.testing.expectEqualStrings("copper:ore", list.keys[0].key);
    try std.testing.expectEqual(@as(i16, 97), list.keys[0].numeric);
    try std.testing.expectEqualStrings("wiring:spool", list.keys[1].key);
    try std.testing.expectEqual(@as(i16, 360), list.keys[1].numeric);
}

test "a mod with no common.lua is left out of the handshake" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    defer world.Block.resetRegistry();

    try writeMod(io, tmp.dir, "copper",
        \\{ "id": "copper", "version": "1.0.0" }
    , "rosebed.register_block { key = 'ore' }");
    try writeMod(io, tmp.dir, "minimap",
        \\{ "id": "minimap", "version": "3.0.0" }
    , null);

    var report: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer report.deinit();
    var loaded = try load(std.testing.allocator, io, tmp.dir, &report.writer);
    defer loaded.deinit(std.testing.allocator);

    try std.testing.expectEqual(2, loaded.mods.len);
    try std.testing.expectEqual(1, loaded.list.mods.len);
    try std.testing.expectEqualStrings("copper", loaded.list.mods[0].id);
}

test "registration closes once loading has finished" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    defer world.Block.resetRegistry();

    var report: std.Io.Writer.Allocating = .init(gpa);
    defer report.deinit();
    var loaded = try load(gpa, io, tmp.dir, &report.writer);
    defer loaded.deinit(gpa);

    try std.testing.expectError(error.ScriptFailed, loaded.vm.exec("=late", "rosebed.register_block { key = 'late' }"));
}

test "unloading hands the registries back to vanilla so the same mods load again" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try writeMod(io, tmp.dir, "copper",
        \\{ "id": "copper", "version": "1.0.0" }
    , "rosebed.register_item { key = 'ingot' }\nrosebed.register_recipe { any = { 'coal' }, result = 'copper:ingot' }");

    var grid: [4]?game.Inventory.ItemStack = @splat(null);
    grid[0] = .{ .id = .{ .item = .coal }, .count = 1 };

    var report: std.Io.Writer.Allocating = .init(gpa);
    defer report.deinit();
    var first = try load(gpa, io, tmp.dir, &report.writer);
    try std.testing.expect(game.crafting.findMatch(&grid, game.crafting.player_grid_size) != null);
    first.deinit(gpa);

    try std.testing.expect(world.Item.fromKey("copper:ingot") == null);
    try std.testing.expect(game.crafting.findMatch(&grid, game.crafting.player_grid_size) == null);

    var second = try load(gpa, io, tmp.dir, &report.writer);
    defer second.deinit(gpa);
    try std.testing.expect(world.Item.fromKey("copper:ingot") != null);
}

test "a failing mod is reported by file and line and leaves the registry untouched" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try writeMod(io, tmp.dir, "copper",
        \\{ "id": "copper", "version": "1.0.0" }
    , "rosebed.register_block { key = 'ore' }\nrosebed.override_block('stone', { hardness = 9 })");
    try writeMod(io, tmp.dir, "wiring",
        \\{ "id": "wiring", "version": "1.0.0", "depends": ["copper"] }
    , "local x = 1\nerror('boom')");

    var report: std.Io.Writer.Allocating = .init(gpa);
    defer report.deinit();
    try std.testing.expectError(error.ScriptFailed, load(gpa, io, tmp.dir, &report.writer));
    try std.testing.expectEqualStrings("wiring/common.lua:2: boom\n", report.written());
    try std.testing.expect(world.Block.fromKey("copper:ore") == null);
    try std.testing.expectEqual(@as(f32, 1.5), world.Block.stone.def().hardness);
}

test "a mod that depends on a missing one is reported" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try writeMod(io, tmp.dir, "wiring",
        \\{ "id": "wiring", "version": "1.0.0", "depends": ["copper"] }
    , null);

    var report: std.Io.Writer.Allocating = .init(gpa);
    defer report.deinit();
    try std.testing.expectError(error.MissingDependency, load(gpa, io, tmp.dir, &report.writer));
    try std.testing.expectEqualStrings("could not order the mods: MissingDependency\n", report.written());
}

fn testWorld() !world.World {
    var world_map: world.World = .init(std.testing.allocator);
    errdefer world_map.deinit();
    var chunk_x: i32 = -1;
    while (chunk_x <= 1) : (chunk_x += 1) {
        var chunk_z: i32 = -1;
        while (chunk_z <= 1) : (chunk_z += 1) _ = try world_map.createChunk(chunk_x, chunk_z);
    }
    return world_map;
}

fn loadOne(io: std.Io, dir: std.Io.Dir, common: []const u8) !Loaded {
    try writeMod(io, dir, "quartz",
        \\{ "id": "quartz", "version": "1.0.0" }
    , common);
    var report: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer report.deinit();
    return load(std.testing.allocator, io, dir, &report.writer);
}

test "lua callbacks run when the game reaches their block" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    defer world.Block.resetRegistry();

    var loaded = try loadOne(io, tmp.dir,
        \\rosebed.register_block {
        \\  key = "lamp",
        \\  on_activated = function(x, y, z)
        \\    rosebed.world.set_block(x, y, z, "block_gold")
        \\    return true
        \\  end,
        \\  on_tick = function(x, y, z)
        \\    rosebed.world.set_block(x, y + 1, z, "stone")
        \\  end,
        \\  on_neighbor_change = function(x, y, z)
        \\    rosebed.world.set_meta(x, y, z, 7)
        \\  end,
        \\}
    );
    defer loaded.deinit(std.testing.allocator);

    var world_map = try testWorld();
    defer world_map.deinit();
    const lamp = world.Block.fromKey("quartz:lamp").?;
    const pos: world.BlockPos = .init(4, 10, 4);
    world_map.setBlock(pos, lamp);

    try world_map.setBlockWithNotify(pos.offset(1, 0, 0), .stone);
    try std.testing.expectEqual(@as(u4, 7), world_map.getBlockMetadata(pos));

    try world_map.scheduleBlockUpdate(pos, lamp, 1);
    world_map.time += 2;
    try world_map.tickUpdates();
    try std.testing.expectEqual(world.Block.stone, world_map.getBlock(pos.offset(0, 1, 0)));

    try std.testing.expect(try lamp.def().on_activated.?(&world_map, pos, lamp));
    try std.testing.expectEqual(world.Block.block_gold, world_map.getBlock(pos));
}

test "an item's lua use callback gets the face and damage it was used with" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    defer world.Block.resetRegistry();
    defer world.Item.resetRegistry();

    var loaded = try loadOne(io, tmp.dir,
        \\rosebed.register_item {
        \\  key = "wand",
        \\  on_use = function(x, y, z, face, damage)
        \\    if face ~= "up" or damage ~= 3 then return false end
        \\    rosebed.world.set_block(x, y + 1, z, "stone")
        \\    return true
        \\  end,
        \\}
        \\rosebed.override_item("shears", { on_use = function() return true end })
    );
    defer loaded.deinit(std.testing.allocator);

    var world_map = try testWorld();
    defer world_map.deinit();
    const wand = world.Item.fromKey("quartz:wand").?;
    const pos: world.BlockPos = .init(4, 10, 4);

    try std.testing.expect(!try wand.def().on_use.?(&world_map, pos, .north, wand, 3));
    try std.testing.expectEqual(world.Block.air, world_map.getBlock(pos.offset(0, 1, 0)));
    try std.testing.expect(try wand.def().on_use.?(&world_map, pos, .up, wand, 3));
    try std.testing.expectEqual(world.Block.stone, world_map.getBlock(pos.offset(0, 1, 0)));
    try std.testing.expect(try world.Item.shears.def().on_use.?(&world_map, pos, .up, .shears, 0));
}

test "a block drops what its lua callback names, rolled on the game's own random" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    defer world.Block.resetRegistry();
    defer world.Item.resetRegistry();

    var loaded = try loadOne(io, tmp.dir,
        \\rosebed.register_item { key = "gem" }
        \\rosebed.register_block {
        \\  key = "ore",
        \\  drop = function(meta)
        \\    if meta == 5 then return nil end
        \\    return "quartz:gem", 1 + rosebed.random(3)
        \\  end,
        \\}
        \\rosebed.override_block("stone", { drop = function() return "dirt", 2 end })
    );
    defer loaded.deinit(std.testing.allocator);

    const ore = world.Block.fromKey("quartz:ore").?;
    var rand: world.JavaRandom = .init(42);
    const dropped = ore.drop(0, &rand).?;
    try std.testing.expectEqual(world.Item.fromKey("quartz:gem").?, dropped.id.item);

    var reference: world.JavaRandom = .init(42);
    try std.testing.expectEqual(@as(u8, @intCast(1 + reference.nextIntBound(3))), dropped.count);
    try std.testing.expect(ore.drop(5, &rand) == null);

    const stone_drop = world.Block.stone.drop(0, &rand).?;
    try std.testing.expectEqual(world.Block.dirt, stone_drop.id.block);
    try std.testing.expectEqual(@as(u8, 2), stone_drop.count);
}

test "a drop of something nothing is registered as leaves the block dropping nothing" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    defer world.Block.resetRegistry();

    var loaded = try loadOne(io, tmp.dir,
        \\rosebed.register_block { key = "ore", drop = function() return "quartz:nothing", 1 end }
    );
    defer loaded.deinit(std.testing.allocator);

    var rand: world.JavaRandom = .init(1);
    try std.testing.expect(world.Block.fromKey("quartz:ore").?.drop(0, &rand) == null);
}

test "a vanilla block can be given a lua callback" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    defer world.Block.resetRegistry();

    var loaded = try loadOne(io, tmp.dir,
        \\rosebed.override_block("stone", { on_activated = function() return true end })
    );
    defer loaded.deinit(std.testing.allocator);

    var world_map = try testWorld();
    defer world_map.deinit();
    try std.testing.expect(try world.Block.stone.def().on_activated.?(&world_map, .init(4, 10, 4), .stone));
}

test "a failing callback is contained and unloaded mods stop answering" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    defer world.Block.resetRegistry();

    var loaded = try loadOne(io, tmp.dir,
        \\rosebed.register_block { key = "trap", on_activated = function() error("boom") end }
        \\rosebed.register_block { key = "switch", on_activated = function() return true end }
    );

    var world_map = try testWorld();
    defer world_map.deinit();
    const trap = world.Block.fromKey("quartz:trap").?;
    const switch_block = world.Block.fromKey("quartz:switch").?;
    const pos: world.BlockPos = .init(4, 10, 4);
    world_map.setBlock(pos, trap);

    try std.testing.expect(!try trap.def().on_activated.?(&world_map, pos, trap));
    try std.testing.expectEqual(trap, world_map.getBlock(pos));
    try std.testing.expect(try switch_block.def().on_activated.?(&world_map, pos, switch_block));

    const kept_callback = switch_block.def().on_activated.?;
    loaded.deinit(std.testing.allocator);
    try std.testing.expect(switch_block.def().on_activated == null);
    try std.testing.expect(!try kept_callback(&world_map, pos, switch_block));
}

test "an event a mod listens for is the only one wired into the engine" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try writeMod(io, tmp.dir, "quartz",
        \\{ "id": "quartz", "version": "1.0.0" }
    ,
        \\rosebed.on_world_tick(function() end)
        \\rosebed.on_mob_death(function() end)
    );

    var report: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer report.deinit();
    var loaded = try load(std.testing.allocator, io, tmp.dir, &report.writer);

    try std.testing.expect(game.Level.on_tick != null);
    try std.testing.expect(game.Entities.on_mob_death != null);
    try std.testing.expect(world.World.on_chunk_load == null);
    try std.testing.expect(game.Player.on_hurt == null);
    try std.testing.expect(game.Player.on_death == null);

    loaded.deinit(std.testing.allocator);
    try std.testing.expect(game.Level.on_tick == null);
    try std.testing.expect(game.Entities.on_mob_death == null);
}

test "a world with no mods leaves every engine hook alone" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var report: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer report.deinit();
    var loaded = try load(std.testing.allocator, io, tmp.dir, &report.writer);
    defer loaded.deinit(std.testing.allocator);

    try std.testing.expect(game.Level.on_tick == null);
    try std.testing.expect(world.World.on_chunk_load == null);
    try std.testing.expect(game.Player.on_hurt == null);
    try std.testing.expect(game.Player.on_death == null);
    try std.testing.expect(game.Entities.on_mob_death == null);
    try std.testing.expect(world.generator.after_shape == null);
    try std.testing.expect(world.generator.after_decorate == null);
}
