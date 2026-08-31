const std = @import("std");

const assets = @import("assets");
const math = @import("math");

const block = @import("block.zig");
const Block = block.Block;
const block_update = @import("block_update.zig");
const chest = @import("chest.zig");
const Chunk = @import("Chunk.zig");
const dispenser = @import("dispenser.zig");
const fluid = @import("fluid.zig");
const furnace = @import("furnace.zig");
const biome = @import("gen/biome.zig");
const TerrainGenerator = @import("gen/TerrainGenerator.zig");
const JavaRandom = @import("JavaRandom.zig");
const jukebox = @import("jukebox.zig");
const leaf_decay = @import("leaf_decay.zig");
const light = @import("light.zig");
const map = @import("map.zig");
const nbt = @import("nbt.zig");
const note = @import("note.zig");
const piston = @import("piston.zig");
const portal = @import("portal.zig");
const rail = @import("rail.zig");
const redstone = @import("redstone.zig");
const save = @import("save.zig");
const sign = @import("sign.zig");
const tnt = @import("tnt.zig");
const Weather = @import("Weather.zig");

const World = @This();

pub const Persistence = struct {
    handle: *save.Save,
    io: std.Io,
};

pub const EntityIo = struct {
    context: *anyopaque,
    collect: *const fn (
        context: *anyopaque,
        gpa: std.mem.Allocator,
        chunk_x: i32,
        chunk_z: i32,
        out: *std.ArrayList(nbt.Tag),
    ) anyerror!void,
    restore: *const fn (context: *anyopaque, gpa: std.mem.Allocator, entity: nbt.Compound) anyerror!void,
};

pub const ChunkCoord = struct { x: i32, z: i32 };

pub const BlockPos = struct { x: i32, y: i32, z: i32 };

pub const DroppedBlock = struct { pos: BlockPos, stack: block.Stack };
pub const Dispensed = struct { pos: BlockPos, step: [2]i32, stack: block.Stack };

pub const FallingBlock = struct { pos: BlockPos, id: Block };

pub const PrimedTnt = struct { pos: BlockPos, fuse: i32 };

pub const TorchUpdate = struct { pos: BlockPos, time: i64 };

pub const Access = struct {
    context: *anyopaque,
    markBlockNeedsUpdate: *const fn (context: *anyopaque, x: i32, y: i32, z: i32) std.mem.Allocator.Error!void,
    updateAllRenderers: *const fn (context: *anyopaque) std.mem.Allocator.Error!void,
};

pub const EntityProbe = struct {
    context: *anyopaque,
    anyInBox: *const fn (context: *anyopaque, box: math.Aabb, living_only: bool) bool,
};

pub const SoundSink = struct {
    context: *anyopaque,
    playSound: *const fn (context: *anyopaque, sound: assets.Sound, x: f64, y: f64, z: f64, volume: f32, pitch: f32) void,
    playRecord: *const fn (context: *anyopaque, name: ?[]const u8, x: i32, y: i32, z: i32) void,
};

pub const ScheduledTick = struct {
    pos: BlockPos,
    id: Block,
    time: i64,

    fn key(self: ScheduledTick) Key {
        return .{ .pos = self.pos, .id = self.id };
    }

    fn soonestFirst(_: void, a: ScheduledTick, b: ScheduledTick) bool {
        return a.time < b.time;
    }

    pub const Key = struct { pos: BlockPos, id: Block };
};

pub const Difficulty = enum(u2) {
    peaceful,
    easy,
    normal,
    hard,

    pub fn label(self: Difficulty) []const u8 {
        return switch (self) {
            .peaceful => "Peaceful",
            .easy => "Easy",
            .normal => "Normal",
            .hard => "Hard",
        };
    }

    pub fn next(self: Difficulty) Difficulty {
        return @enumFromInt(@intFromEnum(self) +% 1);
    }

    pub fn atLeast(self: Difficulty, floor: Difficulty) bool {
        return @intFromEnum(self) >= @intFromEnum(floor);
    }

    pub fn scaleHostileDamage(self: Difficulty, amount: i32) i32 {
        return switch (self) {
            .peaceful => 0,
            .easy => @divTrunc(amount, 3) + 1,
            .normal => amount,
            .hard => @divTrunc(amount * 3, 2),
        };
    }
};

allocator: std.mem.Allocator,
chunks: std.AutoHashMapUnmanaged(ChunkCoord, *Chunk) = .{},
decorated: std.AutoHashMapUnmanaged(ChunkCoord, void) = .{},
scheduled: std.ArrayList(ScheduledTick) = .empty,
scheduled_keys: std.AutoHashMapUnmanaged(ScheduledTick.Key, void) = .{},
due: std.ArrayList(ScheduledTick) = .empty,
changed: std.ArrayList(BlockPos) = .empty,
dropped: std.ArrayList(DroppedBlock) = .empty,
falling: std.ArrayList(FallingBlock) = .empty,
primed: std.ArrayList(PrimedTnt) = .empty,
rand: JavaRandom = JavaRandom.init(0),
update_lcg: i32 = 0,
time: i64 = 0,
difficulty: Difficulty = .normal,
skylight_subtracted: u4 = 0,
scheduled_updates_are_immediate: bool = false,
editing_blocks: bool = false,
brightness: [16]f32 = light.brightness_table,
torch_updates: std.ArrayList(TorchUpdate) = .empty,
entity_probe: ?EntityProbe = null,
remote: bool = false,
sound_sink: ?SoundSink = null,
note_sink: ?NoteSink = null,
weather: Weather = .{},
has_sky: bool = true,
strikes: std.ArrayList(Strike) = .empty,
access: ?Access = null,
persistence: ?Persistence = null,
entity_io: ?EntityIo = null,
save_queue: std.ArrayList(ChunkCoord) = .empty,
furnaces: std.AutoHashMapUnmanaged(BlockPos, furnace.Furnace) = .{},
chests: std.AutoHashMapUnmanaged(BlockPos, chest.Chest) = .{},
signs: std.AutoHashMapUnmanaged(BlockPos, sign.Sign) = .{},
maps: std.AutoHashMapUnmanaged(i16, *map.MapData) = .{},
next_map_id: ?i16 = null,
jukeboxes: std.AutoHashMapUnmanaged(BlockPos, jukebox.Jukebox) = .{},
notes: std.AutoHashMapUnmanaged(BlockPos, note.Note) = .{},
dispensers: std.AutoHashMapUnmanaged(BlockPos, dispenser.Dispenser) = .{},
pistons: std.AutoHashMapUnmanaged(BlockPos, piston.Moving) = .{},
furnace_updates: std.ArrayList(BlockPos) = .empty,
chest_updates: std.ArrayList(BlockPos) = .empty,
jukebox_updates: std.ArrayList(BlockPos) = .empty,
note_updates: std.ArrayList(BlockPos) = .empty,
dispenser_updates: std.ArrayList(BlockPos) = .empty,
dispensed: std.ArrayList(Dispensed) = .empty,
piston_updates: std.ArrayList(BlockPos) = .empty,
piston_shoves: std.ArrayList(PistonShove) = .empty,

pub const ticks_per_day: i64 = 24000;

pub const max_ticks_per_update: usize = 1000;

const load_radius: i32 = 8;

pub fn isDaytime(self: *const World) bool {
    return self.skylight_subtracted < 4;
}

pub fn skipToDawn(self: *World) void {
    const tomorrow = self.time + ticks_per_day;
    self.time = tomorrow - @mod(tomorrow, ticks_per_day);
}

pub fn setTime(self: *World, time: i64) void {
    const shift = time - self.time;
    for (self.scheduled.items) |*entry| entry.time += shift;
    self.time = time;
}

pub fn celestialAngle(self: *const World, partial_ticks: f32) f32 {
    const day_time: f32 = @floatFromInt(@mod(self.time, ticks_per_day));
    var fraction = (day_time + partial_ticks) / @as(f32, ticks_per_day) - 0.25;
    if (fraction < 0.0) fraction += 1.0;
    if (fraction > 1.0) fraction -= 1.0;

    const linear = fraction;
    const eased: f32 = 1.0 - @as(f32, @floatCast((@cos(@as(f64, linear) * std.math.pi) + 1.0) / 2.0));
    return linear + (eased - linear) / 3.0;
}

pub fn calculateSkylightSubtracted(self: *const World, partial_ticks: f32) u4 {
    const angle = self.celestialAngle(partial_ticks);
    const darkness = std.math.clamp(1.0 - (math.util.cos(angle * std.math.pi * 2.0) * 2.0 + 0.5), 0.0, 1.0);

    var daylight: f64 = 1.0 - darkness;
    daylight *= 1.0 - @as(f64, self.weather.rainStrength(partial_ticks) * 5.0) / 16.0;
    daylight *= 1.0 - @as(f64, self.weather.thunderStrength(partial_ticks) * 5.0) / 16.0;
    return @intFromFloat((1.0 - daylight) * 11.0);
}

pub fn tickWeather(self: *World) void {
    if (!self.has_sky) return;
    self.weather.tick(&self.rand);
}

pub fn findTopSolidBlock(self: *const World, x: i32, z: i32) i32 {
    var y: i32 = Chunk.height - 1;
    while (y > 0) : (y -= 1) {
        const material = self.getBlock(x, y, z).material();
        if (material.isSolid() or material.isLiquid()) return y + 1;
    }
    return -1;
}

pub fn canBlockBeRainedOn(self: *const World, x: i32, y: i32, z: i32) bool {
    if (!self.weather.isRaining()) return false;
    if (!self.canBlockSeeTheSky(x, y, z)) return false;
    if (self.findTopSolidBlock(x, z) > y) return false;
    return self.biomeAt(x, z).canSpawnLightningBolt();
}

pub fn init(allocator: std.mem.Allocator) World {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *World) void {
    var it = self.chunks.valueIterator();
    while (it.next()) |chunk| self.allocator.destroy(chunk.*);
    self.chunks.deinit(self.allocator);
    self.decorated.deinit(self.allocator);
    self.scheduled.deinit(self.allocator);
    self.due.deinit(self.allocator);
    self.scheduled_keys.deinit(self.allocator);
    self.changed.deinit(self.allocator);
    self.dropped.deinit(self.allocator);
    self.falling.deinit(self.allocator);
    self.primed.deinit(self.allocator);
    self.save_queue.deinit(self.allocator);
    self.furnaces.deinit(self.allocator);
    self.chests.deinit(self.allocator);
    self.signs.deinit(self.allocator);
    var open_maps = self.maps.valueIterator();
    while (open_maps.next()) |data| {
        data.*.deinit(self.allocator);
        self.allocator.destroy(data.*);
    }
    self.maps.deinit(self.allocator);
    self.jukeboxes.deinit(self.allocator);
    self.notes.deinit(self.allocator);
    self.strikes.deinit(self.allocator);
    self.note_updates.deinit(self.allocator);
    self.dispensers.deinit(self.allocator);
    self.pistons.deinit(self.allocator);
    self.piston_updates.deinit(self.allocator);
    self.piston_shoves.deinit(self.allocator);
    self.furnace_updates.deinit(self.allocator);
    self.chest_updates.deinit(self.allocator);
    self.jukebox_updates.deinit(self.allocator);
    self.dispenser_updates.deinit(self.allocator);
    self.dispensed.deinit(self.allocator);
    self.torch_updates.deinit(self.allocator);
}

pub fn getChunk(self: *const World, chunk_x: i32, chunk_z: i32) ?*Chunk {
    return self.chunks.get(.{ .x = chunk_x, .z = chunk_z });
}

pub fn createChunk(self: *World, chunk_x: i32, chunk_z: i32) !*Chunk {
    const coord = ChunkCoord{ .x = chunk_x, .z = chunk_z };
    const entry = try self.chunks.getOrPut(self.allocator, coord);
    if (entry.found_existing) return entry.value_ptr.*;

    const chunk = self.allocator.create(Chunk) catch |err| {
        _ = self.chunks.remove(coord);
        return err;
    };
    chunk.* = Chunk.init(chunk_x, chunk_z);
    entry.value_ptr.* = chunk;
    return chunk;
}

pub fn getOrGenerateChunk(self: *World, generator: anytype, chunk_x: i32, chunk_z: i32) !*Chunk {
    if (self.getChunk(chunk_x, chunk_z)) |existing| return existing;

    if (try self.loadChunk(generator, chunk_x, chunk_z)) |loaded| return loaded;

    const chunk = try self.createChunk(chunk_x, chunk_z);
    generator.generateShape(chunk);
    return chunk;
}

fn restoreEntity(context: *anyopaque, gpa: std.mem.Allocator, entity: nbt.Compound) anyerror!void {
    const self: *World = @ptrCast(@alignCast(context));
    const io = self.entity_io.?;
    try io.restore(io.context, gpa, entity);
}

fn entityVisitor(self: *World) ?save.Save.EntityVisitor {
    if (self.entity_io == null) return null;
    return .{ .context = self, .visit = restoreEntity };
}

fn loadChunk(self: *World, generator: anytype, chunk_x: i32, chunk_z: i32) !?*Chunk {
    const persistence = self.persistence orelse return null;
    const found = persistence.handle.readChunk(
        self.allocator,
        persistence.io,
        chunk_x,
        chunk_z,
        self.entityVisitor(),
        .{ .context = self, .visit = restoreTileEntity },
    ) catch return null;
    const stored = found orelse return null;

    const chunk = try self.createChunk(chunk_x, chunk_z);
    const climate = generator.sampleClimate(chunk_x * Chunk.width, chunk_z * Chunk.width);
    chunk.* = stored.chunk;
    chunk.stored_entities = stored.entities.len > 0 or stored.tile_entities.len > 0;
    for (0..Chunk.width) |x| {
        for (0..Chunk.width) |z| {
            const i = x * Chunk.width + z;
            chunk.setClimate(@intCast(x), @intCast(z), @floatCast(climate.temperature[i]), @floatCast(climate.humidity[i]));
        }
    }

    if (stored.populated) try self.decorated.put(self.allocator, .{ .x = chunk_x, .z = chunk_z }, {});
    return chunk;
}

fn writeChunkAt(self: *World, coord: ChunkCoord) !bool {
    const persistence = self.persistence orelse return false;
    const chunk = self.getChunk(coord.x, coord.z) orelse return false;

    var entities: std.ArrayList(nbt.Tag) = .empty;
    errdefer {
        for (entities.items) |*tag| nbt.deinit(self.allocator, tag);
        entities.deinit(self.allocator);
    }
    if (self.entity_io) |io| try io.collect(io.context, self.allocator, coord.x, coord.z, &entities);

    var tile_entities: std.ArrayList(nbt.Tag) = .empty;
    errdefer {
        for (tile_entities.items) |*tag| nbt.deinit(self.allocator, tag);
        tile_entities.deinit(self.allocator);
    }
    try self.collectTileEntities(coord, &tile_entities);

    const holds_entities = entities.items.len > 0 or tile_entities.items.len > 0;
    if (!chunk.modified and !chunk.stored_entities and !holds_entities) {
        for (entities.items) |*tag| nbt.deinit(self.allocator, tag);
        entities.deinit(self.allocator);
        for (tile_entities.items) |*tag| nbt.deinit(self.allocator, tag);
        tile_entities.deinit(self.allocator);
        return false;
    }

    try persistence.handle.writeChunk(
        self.allocator,
        persistence.io,
        chunk,
        self.time,
        self.isDecorated(coord.x, coord.z),
        try entities.toOwnedSlice(self.allocator),
        try tile_entities.toOwnedSlice(self.allocator),
    );

    chunk.modified = false;
    chunk.stored_entities = holds_entities;
    return true;
}

pub fn saveLoadedChunks(self: *World) !void {
    if (self.persistence == null) return;

    var it = self.chunks.keyIterator();
    while (it.next()) |coord| _ = try self.writeChunkAt(coord.*);
    self.save_queue.clearRetainingCapacity();
}

const map_data_prefix = "map_";

fn mapFileName(buffer: []u8, id: i16) ![]const u8 {
    return std.fmt.bufPrint(buffer, map_data_prefix ++ "{d}", .{id});
}

pub fn mapData(self: *World, id: i16) !*map.MapData {
    if (self.maps.get(id)) |existing| return existing;

    const data = try self.allocator.create(map.MapData);
    errdefer self.allocator.destroy(data);
    data.* = .{ .id = id };

    if (self.persistence) |store| {
        var name: [32]u8 = undefined;
        if (save.readDataTag(self.allocator, store.io, store.handle.dir, try mapFileName(&name, id), true)) |root| {
            var owned = root;
            defer nbt.deinit(self.allocator, &owned);
            if (owned == .compound) {
                if (owned.compound.get("data")) |stored| {
                    if (stored == .compound) map.readFromNbt(data, stored.compound);
                }
            }
        } else |_| {}
    }

    try self.maps.put(self.allocator, id, data);
    return data;
}

pub fn nextMapId(self: *World) !i16 {
    if (self.next_map_id == null) {
        self.next_map_id = 0;
        if (self.persistence) |store| {
            if (save.readDataTag(self.allocator, store.io, store.handle.dir, "idcounts", false)) |root| {
                var owned = root;
                defer nbt.deinit(self.allocator, &owned);
                if (owned == .compound) {
                    if (owned.compound.get("map")) |stored| {
                        if (stored == .short) self.next_map_id = stored.short + 1;
                    }
                }
            } else |_| {}
        }
    }

    const claimed = self.next_map_id.?;
    self.next_map_id = claimed + 1;

    if (self.persistence) |store| {
        var counts: nbt.Compound = .empty;
        defer counts.deinit(self.allocator);
        try nbt.putDuped(self.allocator, &counts, "map", .{ .short = claimed });
        save.writeDataTag(self.allocator, store.io, store.handle.dir, "idcounts", .{ .compound = counts }, false) catch {};
    }

    return claimed;
}

pub fn saveDirtyMaps(self: *World) !void {
    const store = self.persistence orelse return;

    var it = self.maps.valueIterator();
    while (it.next()) |entry| {
        const data = entry.*;
        if (!data.dirty) continue;

        var body: nbt.Compound = .empty;
        defer body.deinit(self.allocator);
        try map.writeToNbt(data, self.allocator, &body);

        var root: nbt.Compound = .empty;
        defer root.deinit(self.allocator);
        try nbt.putDuped(self.allocator, &root, "data", .{ .compound = body });

        var name: [32]u8 = undefined;
        save.writeDataTag(
            self.allocator,
            store.io,
            store.handle.dir,
            try mapFileName(&name, data.id),
            .{ .compound = root },
            true,
        ) catch continue;
        data.dirty = false;
    }
}

pub fn beginSaveRound(self: *World) !void {
    self.save_queue.clearRetainingCapacity();
    if (self.persistence == null) return;

    var it = self.chunks.keyIterator();
    while (it.next()) |coord| try self.save_queue.append(self.allocator, coord.*);
}

pub fn saveQueuedChunks(self: *World, limit: usize) !usize {
    var written: usize = 0;
    while (written < limit) {
        const coord = self.save_queue.pop() orelse break;
        if (try self.writeChunkAt(coord)) written += 1;
    }
    return self.save_queue.items.len;
}

pub fn markDecorated(self: *World, chunk_x: i32, chunk_z: i32) !void {
    try self.decorated.put(self.allocator, .{ .x = chunk_x, .z = chunk_z }, {});
}

pub fn forgetChunk(self: *World, chunk_x: i32, chunk_z: i32) void {
    const coord: ChunkCoord = .{ .x = chunk_x, .z = chunk_z };
    if (self.chunks.fetchRemove(coord)) |entry| self.allocator.destroy(entry.value);
    _ = self.decorated.remove(coord);
}

pub fn isDecorated(self: *const World, chunk_x: i32, chunk_z: i32) bool {
    return self.decorated.contains(.{ .x = chunk_x, .z = chunk_z });
}

pub const DecorateStep = enum { generated, decorated, done };

pub fn stepDecorate(self: *World, generator: anytype, chunk_x: i32, chunk_z: i32) !DecorateStep {
    if (self.isDecorated(chunk_x, chunk_z)) return .done;

    var dx: i32 = -1;
    while (dx <= 1) : (dx += 1) {
        var dz: i32 = -1;
        while (dz <= 1) : (dz += 1) {
            if (self.getChunk(chunk_x + dx, chunk_z + dz) != null) continue;
            _ = try self.getOrGenerateChunk(generator, chunk_x + dx, chunk_z + dz);
            return .generated;
        }
    }

    try generator.decorateChunk(self, chunk_x, chunk_z);
    try self.decorated.put(self.allocator, .{ .x = chunk_x, .z = chunk_z }, {});
    try light.relightChunk(self.allocator, self, chunk_x, chunk_z);
    return .decorated;
}

pub fn ensureDecorated(self: *World, generator: anytype, chunk_x: i32, chunk_z: i32) !void {
    while (true) {
        const step = try self.stepDecorate(generator, chunk_x, chunk_z);
        if (step != .generated) return;
    }
}

fn floorDiv(value: i32, divisor: i32) i32 {
    return @divFloor(value, divisor);
}

fn floorMod(value: i32, divisor: i32) i32 {
    return @mod(value, divisor);
}

pub fn getBlock(self: *const World, x: i32, y: i32, z: i32) Block {
    if (y < 0 or y >= Chunk.height) return .air;
    const chunk = self.getChunk(floorDiv(x, Chunk.width), floorDiv(z, Chunk.width)) orelse return .air;
    return chunk.getBlock(@intCast(floorMod(x, Chunk.width)), @intCast(y), @intCast(floorMod(z, Chunk.width)));
}

pub fn biomeAt(self: *const World, x: i32, z: i32) biome.Biome {
    const chunk = self.getChunk(floorDiv(x, Chunk.width), floorDiv(z, Chunk.width)) orelse return .plains;
    const local_x: u32 = @intCast(floorMod(x, Chunk.width));
    const local_z: u32 = @intCast(floorMod(z, Chunk.width));
    return biome.classify(chunk.getTemperature(local_x, local_z), chunk.getHumidity(local_x, local_z));
}

pub fn setBlock(self: *World, x: i32, y: i32, z: i32, id: Block) void {
    if (y < 0 or y >= Chunk.height) return;
    const chunk = self.getChunk(floorDiv(x, Chunk.width), floorDiv(z, Chunk.width)) orelse return;
    chunk.setBlock(@intCast(floorMod(x, Chunk.width)), @intCast(y), @intCast(floorMod(z, Chunk.width)), id);
}

pub fn getSkyLight(self: *const World, x: i32, y: i32, z: i32) u4 {
    if (y < 0) return 0;
    if (y >= Chunk.height) return 15;
    const chunk = self.getChunk(floorDiv(x, Chunk.width), floorDiv(z, Chunk.width)) orelse return 0;
    return chunk.getSkyLight(@intCast(floorMod(x, Chunk.width)), @intCast(y), @intCast(floorMod(z, Chunk.width)));
}

pub fn setSkyLight(self: *World, x: i32, y: i32, z: i32, value: u4) void {
    if (y < 0 or y >= Chunk.height) return;
    const chunk = self.getChunk(floorDiv(x, Chunk.width), floorDiv(z, Chunk.width)) orelse return;
    chunk.setSkyLight(@intCast(floorMod(x, Chunk.width)), @intCast(y), @intCast(floorMod(z, Chunk.width)), value);
}

pub fn getBlockLight(self: *const World, x: i32, y: i32, z: i32) u4 {
    if (y < 0 or y >= Chunk.height) return 0;
    const chunk = self.getChunk(floorDiv(x, Chunk.width), floorDiv(z, Chunk.width)) orelse return 0;
    return chunk.getBlockLight(@intCast(floorMod(x, Chunk.width)), @intCast(y), @intCast(floorMod(z, Chunk.width)));
}

pub fn setBlockLight(self: *World, x: i32, y: i32, z: i32, value: u4) void {
    if (y < 0 or y >= Chunk.height) return;
    const chunk = self.getChunk(floorDiv(x, Chunk.width), floorDiv(z, Chunk.width)) orelse return;
    chunk.setBlockLight(@intCast(floorMod(x, Chunk.width)), @intCast(y), @intCast(floorMod(z, Chunk.width)), value);
}

pub fn getBlockMetadata(self: *const World, x: i32, y: i32, z: i32) u4 {
    if (y < 0 or y >= Chunk.height) return 0;
    const chunk = self.getChunk(floorDiv(x, Chunk.width), floorDiv(z, Chunk.width)) orelse return 0;
    return chunk.getBlockMetadata(@intCast(floorMod(x, Chunk.width)), @intCast(y), @intCast(floorMod(z, Chunk.width)));
}

pub fn setBlockMetadata(self: *World, x: i32, y: i32, z: i32, value: u4) void {
    if (y < 0 or y >= Chunk.height) return;
    const chunk = self.getChunk(floorDiv(x, Chunk.width), floorDiv(z, Chunk.width)) orelse return;
    chunk.setBlockMetadata(@intCast(floorMod(x, Chunk.width)), @intCast(y), @intCast(floorMod(z, Chunk.width)), value);
}

pub fn canBlockSeeTheSky(self: *const World, x: i32, y: i32, z: i32) bool {
    const chunk = self.getChunk(floorDiv(x, Chunk.width), floorDiv(z, Chunk.width)) orelse return false;
    const height = chunk.getHeightValue(@intCast(floorMod(x, Chunk.width)), @intCast(floorMod(z, Chunk.width)));
    return y >= height;
}

pub fn chunksExist(self: *const World, min_x: i32, min_y: i32, min_z: i32, max_x: i32, max_y: i32, max_z: i32) bool {
    if (max_y < 0 or min_y >= Chunk.height) return false;
    const width = Chunk.width;
    var chunk_x = floorDiv(min_x, width);
    while (chunk_x <= floorDiv(max_x, width)) : (chunk_x += 1) {
        var chunk_z = floorDiv(min_z, width);
        while (chunk_z <= floorDiv(max_z, width)) : (chunk_z += 1) {
            if (self.getChunk(chunk_x, chunk_z) == null) return false;
        }
    }
    return true;
}

pub fn markChanged(self: *World, x: i32, y: i32, z: i32) !void {
    try self.changed.append(self.allocator, .{ .x = x, .y = y, .z = z });
    if (self.access) |access| try access.markBlockNeedsUpdate(access.context, x, y, z);
}

pub fn updateAllRenderers(self: *World) std.mem.Allocator.Error!void {
    if (self.access) |access| try access.updateAllRenderers(access.context);
}

pub fn playIgniteAt(self: *World, x: i32, y: i32, z: i32) void {
    self.playSoundEffect(
        @as(f64, @floatFromInt(x)) + 0.5,
        @as(f64, @floatFromInt(y)) + 0.5,
        @as(f64, @floatFromInt(z)) + 0.5,
        assets.sounds.fire.ignite,
        1.0,
        self.rand.nextFloat() * 0.4 + 0.8,
    );
}

pub fn playFizzAt(self: *World, x: i32, y: i32, z: i32) void {
    self.playSoundEffect(
        @as(f64, @floatFromInt(x)) + 0.5,
        @as(f64, @floatFromInt(y)) + 0.5,
        @as(f64, @floatFromInt(z)) + 0.5,
        assets.sounds.random.fizz,
        0.5,
        2.6 + (self.rand.nextFloat() - self.rand.nextFloat()) * 0.8,
    );
}

pub fn playDispenserFailure(self: *const World, x: i32, y: i32, z: i32) void {
    self.playSoundEffect(
        @floatFromInt(x),
        @floatFromInt(y),
        @floatFromInt(z),
        assets.sounds.random.click,
        1.0,
        1.2,
    );
}

pub fn playDispenserShot(self: *const World, x: i32, y: i32, z: i32, stack: block.Stack) void {
    const launched = switch (stack.id) {
        .item => |id| id == .arrow or id == .egg or id == .snowball,
        .block => false,
    };
    self.playSoundEffect(
        @floatFromInt(x),
        @floatFromInt(y),
        @floatFromInt(z),
        if (launched) assets.sounds.random.bow else assets.sounds.random.click,
        1.0,
        if (launched) 1.2 else 1.0,
    );
}

pub fn playDoorToggle(self: *World, x: i32, y: i32, z: i32) void {
    const sound = if (self.rand.nextDouble() < 0.5) assets.sounds.random.door_open else assets.sounds.random.door_close;
    self.playSoundEffect(
        @as(f64, @floatFromInt(x)) + 0.5,
        @as(f64, @floatFromInt(y)) + 0.5,
        @as(f64, @floatFromInt(z)) + 0.5,
        sound,
        1.0,
        self.rand.nextFloat() * 0.1 + 0.9,
    );
}

pub fn playSoundEffect(self: *const World, x: f64, y: f64, z: f64, sound: assets.Sound, volume: f32, pitch: f32) void {
    const sink = self.sound_sink orelse return;
    sink.playSound(sink.context, sound, x, y, z, volume, pitch);
}

pub fn playRecord(self: *const World, name: ?[]const u8, x: i32, y: i32, z: i32) void {
    const sink = self.sound_sink orelse return;
    sink.playRecord(sink.context, name, x, y, z);
}

pub fn setBlockWithNotify(self: *World, x: i32, y: i32, z: i32, id: Block) !void {
    try self.setBlockAndMetadataWithNotify(x, y, z, id, 0);
}

pub fn setBlockAndMetadataWithNotify(self: *World, x: i32, y: i32, z: i32, id: Block, meta: u4) !void {
    if (y < 0 or y >= Chunk.height) return;
    const chunk = self.getChunk(floorDiv(x, Chunk.width), floorDiv(z, Chunk.width)) orelse return;
    const local_x: u32 = @intCast(floorMod(x, Chunk.width));
    const local_z: u32 = @intCast(floorMod(z, Chunk.width));
    const previous = chunk.getBlock(local_x, @intCast(y), local_z);
    const previous_meta = chunk.getBlockMetadata(local_x, @intCast(y), local_z);
    chunk.setBlock(local_x, @intCast(y), local_z, id);
    if (previous != id) try redstone.onBlockRemoved(self, x, y, z, previous, previous_meta);
    chunk.setBlockMetadata(local_x, @intCast(y), local_z, meta);
    if (previous != id) leaf_decay.onBlockRemoved(self, x, y, z, previous);
    try self.onBlockAdded(x, y, z, id);
    try self.notifyBlockChange(x, y, z);
}

pub fn setBlockMetadataWithNotify(self: *World, x: i32, y: i32, z: i32, meta: u4) !void {
    if (y < 0 or y >= Chunk.height) return;
    if (self.getChunk(floorDiv(x, Chunk.width), floorDiv(z, Chunk.width)) == null) return;
    self.setBlockMetadata(x, y, z, meta);
    try self.notifyBlockChange(x, y, z);
}

pub fn furnaceAt(self: *World, x: i32, y: i32, z: i32) ?*furnace.Furnace {
    return self.furnaces.getPtr(.{ .x = x, .y = y, .z = z });
}

pub fn addFurnace(self: *World, x: i32, y: i32, z: i32) !*furnace.Furnace {
    const entry = try self.furnaces.getOrPut(self.allocator, .{ .x = x, .y = y, .z = z });
    if (!entry.found_existing) entry.value_ptr.* = .{};
    return entry.value_ptr;
}

pub fn removeFurnace(self: *World, x: i32, y: i32, z: i32) ?furnace.Furnace {
    const removed = self.furnaces.fetchRemove(.{ .x = x, .y = y, .z = z }) orelse return null;
    return removed.value;
}

pub fn chestAt(self: *World, x: i32, y: i32, z: i32) ?*chest.Chest {
    return self.chests.getPtr(.{ .x = x, .y = y, .z = z });
}

pub fn addChest(self: *World, x: i32, y: i32, z: i32) !*chest.Chest {
    const entry = try self.chests.getOrPut(self.allocator, .{ .x = x, .y = y, .z = z });
    if (!entry.found_existing) entry.value_ptr.* = .{};
    return entry.value_ptr;
}

pub const ChestPair = struct { upper: BlockPos, lower: ?BlockPos = null };

pub fn chestPairAt(self: *World, x: i32, y: i32, z: i32) ChestPair {
    const here: BlockPos = .{ .x = x, .y = y, .z = z };
    if (self.getBlock(x - 1, y, z) == .chest) return .{ .upper = .{ .x = x - 1, .y = y, .z = z }, .lower = here };
    if (self.getBlock(x + 1, y, z) == .chest) return .{ .upper = here, .lower = .{ .x = x + 1, .y = y, .z = z } };
    if (self.getBlock(x, y, z - 1) == .chest) return .{ .upper = .{ .x = x, .y = y, .z = z - 1 }, .lower = here };
    if (self.getBlock(x, y, z + 1) == .chest) return .{ .upper = here, .lower = .{ .x = x, .y = y, .z = z + 1 } };
    return .{ .upper = here };
}

fn hasNeighborChest(self: *World, x: i32, y: i32, z: i32) bool {
    if (self.getBlock(x, y, z) != .chest) return false;
    return self.getBlock(x - 1, y, z) == .chest or self.getBlock(x + 1, y, z) == .chest or
        self.getBlock(x, y, z - 1) == .chest or self.getBlock(x, y, z + 1) == .chest;
}

pub fn canPlaceChestAt(self: *World, x: i32, y: i32, z: i32) bool {
    var adjacent: u8 = 0;
    if (self.getBlock(x - 1, y, z) == .chest) adjacent += 1;
    if (self.getBlock(x + 1, y, z) == .chest) adjacent += 1;
    if (self.getBlock(x, y, z - 1) == .chest) adjacent += 1;
    if (self.getBlock(x, y, z + 1) == .chest) adjacent += 1;
    if (adjacent > 1) return false;

    return !self.hasNeighborChest(x - 1, y, z) and !self.hasNeighborChest(x + 1, y, z) and
        !self.hasNeighborChest(x, y, z - 1) and !self.hasNeighborChest(x, y, z + 1);
}

pub fn chestIsBlocked(self: *World, x: i32, y: i32, z: i32) bool {
    if (self.getBlock(x, y + 1, z).isNormalCube()) return true;
    if (self.getBlock(x - 1, y, z) == .chest and self.getBlock(x - 1, y + 1, z).isNormalCube()) return true;
    if (self.getBlock(x + 1, y, z) == .chest and self.getBlock(x + 1, y + 1, z).isNormalCube()) return true;
    if (self.getBlock(x, y, z - 1) == .chest and self.getBlock(x, y + 1, z - 1).isNormalCube()) return true;
    if (self.getBlock(x, y, z + 1) == .chest and self.getBlock(x, y + 1, z + 1).isNormalCube()) return true;
    return false;
}

pub fn signAt(self: *World, x: i32, y: i32, z: i32) ?*sign.Sign {
    return self.signs.getPtr(.{ .x = x, .y = y, .z = z });
}

pub fn addSign(self: *World, x: i32, y: i32, z: i32) !*sign.Sign {
    const entry = try self.signs.getOrPut(self.allocator, .{ .x = x, .y = y, .z = z });
    if (!entry.found_existing) entry.value_ptr.* = .{};
    return entry.value_ptr;
}

pub fn removeSign(self: *World, x: i32, y: i32, z: i32) ?sign.Sign {
    const removed = self.signs.fetchRemove(.{ .x = x, .y = y, .z = z }) orelse return null;
    return removed.value;
}

pub fn jukeboxAt(self: *World, x: i32, y: i32, z: i32) ?*jukebox.Jukebox {
    return self.jukeboxes.getPtr(.{ .x = x, .y = y, .z = z });
}

pub fn addJukebox(self: *World, x: i32, y: i32, z: i32) !*jukebox.Jukebox {
    const entry = try self.jukeboxes.getOrPut(self.allocator, .{ .x = x, .y = y, .z = z });
    if (!entry.found_existing) entry.value_ptr.* = .{};
    return entry.value_ptr;
}

pub fn removeJukebox(self: *World, x: i32, y: i32, z: i32) ?jukebox.Jukebox {
    const removed = self.jukeboxes.fetchRemove(.{ .x = x, .y = y, .z = z }) orelse return null;
    return removed.value;
}

pub fn noteAt(self: *World, x: i32, y: i32, z: i32) ?*note.Note {
    return self.notes.getPtr(.{ .x = x, .y = y, .z = z });
}

pub fn addNote(self: *World, x: i32, y: i32, z: i32) !*note.Note {
    const entry = try self.notes.getOrPut(self.allocator, .{ .x = x, .y = y, .z = z });
    if (!entry.found_existing) entry.value_ptr.* = .{};
    return entry.value_ptr;
}

pub fn removeNote(self: *World, x: i32, y: i32, z: i32) ?note.Note {
    const removed = self.notes.fetchRemove(.{ .x = x, .y = y, .z = z }) orelse return null;
    return removed.value;
}

pub fn forgetOrphanNotes(self: *World) !void {
    self.note_updates.clearRetainingCapacity();

    var it = self.notes.iterator();
    while (it.next()) |entry| {
        const pos = entry.key_ptr.*;
        if (self.getChunk(floorDiv(pos.x, Chunk.width), floorDiv(pos.z, Chunk.width)) == null) continue;
        if (self.getBlock(pos.x, pos.y, pos.z) == .note_block) continue;
        try self.note_updates.append(self.allocator, pos);
    }

    for (self.note_updates.items) |pos| _ = self.notes.remove(pos);
}

pub fn playNoteAt(self: *World, x: i32, y: i32, z: i32, instrument: note.Instrument, pitch: u8) void {
    self.playSoundEffect(
        @as(f64, @floatFromInt(x)) + 0.5,
        @as(f64, @floatFromInt(y)) + 0.5,
        @as(f64, @floatFromInt(z)) + 0.5,
        instrument.soundName(),
        note_volume,
        note.pitchOf(pitch),
    );

    const sink = self.note_sink orelse return;
    sink.playNote(sink.context, x, y, z, instrument, pitch);
}

pub const note_volume: f32 = 3.0;

pub const NoteSink = struct {
    context: *anyopaque,
    playNote: *const fn (
        context: *anyopaque,
        x: i32,
        y: i32,
        z: i32,
        instrument: note.Instrument,
        pitch: u8,
    ) void,
};

pub fn dispenserAt(self: *World, x: i32, y: i32, z: i32) ?*dispenser.Dispenser {
    return self.dispensers.getPtr(.{ .x = x, .y = y, .z = z });
}

pub fn addDispenser(self: *World, x: i32, y: i32, z: i32) !*dispenser.Dispenser {
    const entry = try self.dispensers.getOrPut(self.allocator, .{ .x = x, .y = y, .z = z });
    if (!entry.found_existing) entry.value_ptr.* = .{};
    return entry.value_ptr;
}

pub fn removeDispenser(self: *World, x: i32, y: i32, z: i32) ?dispenser.Dispenser {
    const removed = self.dispensers.fetchRemove(.{ .x = x, .y = y, .z = z }) orelse return null;
    return removed.value;
}

pub fn movingPistonAt(self: *World, x: i32, y: i32, z: i32) ?*piston.Moving {
    return self.pistons.getPtr(.{ .x = x, .y = y, .z = z });
}

pub fn addMovingPiston(self: *World, x: i32, y: i32, z: i32, state: piston.Moving) !void {
    try self.pistons.put(self.allocator, .{ .x = x, .y = y, .z = z }, state);
}

pub fn removeMovingPiston(self: *World, x: i32, y: i32, z: i32) ?piston.Moving {
    const removed = self.pistons.fetchRemove(.{ .x = x, .y = y, .z = z }) orelse return null;
    return removed.value;
}

pub fn finishMovingPiston(self: *World, x: i32, y: i32, z: i32) !void {
    const state = self.removeMovingPiston(x, y, z) orelse return;
    if (self.getBlock(x, y, z) != .piston_moving) return;
    try self.setBlockAndMetadataWithNotify(x, y, z, state.stored, state.stored_metadata);
}

pub const PistonShove = struct {
    pos: BlockPos,
    state: piston.Moving,
    progress: f32,
    amount: f32,
};

pub fn tickPistons(self: *World) !void {
    self.piston_updates.clearRetainingCapacity();
    self.piston_shoves.clearRetainingCapacity();

    var it = self.pistons.iterator();
    while (it.next()) |entry| {
        const pos = entry.key_ptr.*;
        if (self.getBlock(pos.x, pos.y, pos.z) != .piston_moving) {
            try self.piston_updates.append(self.allocator, pos);
            continue;
        }

        const state = entry.value_ptr;
        state.prev_progress = state.progress;
        if (state.prev_progress >= 1.0) {
            try self.piston_shoves.append(self.allocator, .{
                .pos = pos,
                .state = state.*,
                .progress = 1.0,
                .amount = piston.final_shove,
            });
            try self.piston_updates.append(self.allocator, pos);
            continue;
        }

        state.progress = @min(state.progress + piston.progress_per_tick, 1.0);
        if (state.extending) {
            try self.piston_shoves.append(self.allocator, .{
                .pos = pos,
                .state = state.*,
                .progress = state.progress,
                .amount = state.progress - state.prev_progress + piston.shove_lead,
            });
        }
    }

    for (self.piston_updates.items) |pos| {
        try self.finishMovingPiston(pos.x, pos.y, pos.z);
        _ = self.pistons.remove(pos);
    }
}

fn isFurnaceBlock(id: Block) bool {
    return id == .furnace or id == .burning_furnace;
}

pub fn tickFurnaces(self: *World) !void {
    self.furnace_updates.clearRetainingCapacity();

    var it = self.furnaces.iterator();
    while (it.next()) |entry| {
        if (!isFurnaceBlock(self.getBlock(entry.key_ptr.x, entry.key_ptr.y, entry.key_ptr.z))) {
            try self.furnace_updates.append(self.allocator, entry.key_ptr.*);
            continue;
        }
        if (entry.value_ptr.tick()) try self.furnace_updates.append(self.allocator, entry.key_ptr.*);
    }

    for (self.furnace_updates.items) |pos| {
        const state = self.furnaces.get(pos) orelse continue;
        const id = self.getBlock(pos.x, pos.y, pos.z);
        if (!isFurnaceBlock(id)) {
            _ = self.furnaces.remove(pos);
            continue;
        }

        const lit: Block = if (state.isBurning()) .burning_furnace else .furnace;
        if (id == lit) continue;
        const meta = self.getBlockMetadata(pos.x, pos.y, pos.z);
        try self.setBlockAndMetadataWithNotify(pos.x, pos.y, pos.z, lit, meta);
    }
}

pub fn spillOrphanChests(self: *World) !void {
    self.chest_updates.clearRetainingCapacity();

    var it = self.chests.iterator();
    while (it.next()) |entry| {
        const pos = entry.key_ptr.*;
        if (self.getChunk(floorDiv(pos.x, Chunk.width), floorDiv(pos.z, Chunk.width)) == null) continue;
        if (self.getBlock(pos.x, pos.y, pos.z) == .chest) continue;

        for (entry.value_ptr.items) |maybe_stack| {
            const stack = maybe_stack orelse continue;
            try self.dropped.append(self.allocator, .{ .pos = pos, .stack = stack });
        }
        try self.chest_updates.append(self.allocator, pos);
    }

    for (self.chest_updates.items) |pos| _ = self.chests.remove(pos);
}

pub fn spillOrphanJukeboxes(self: *World) !void {
    self.jukebox_updates.clearRetainingCapacity();

    var it = self.jukeboxes.iterator();
    while (it.next()) |entry| {
        const pos = entry.key_ptr.*;
        if (self.getChunk(floorDiv(pos.x, Chunk.width), floorDiv(pos.z, Chunk.width)) == null) continue;
        if (self.getBlock(pos.x, pos.y, pos.z) == .jukebox) continue;

        if (entry.value_ptr.record) |record| {
            try self.dropped.append(self.allocator, .{ .pos = pos, .stack = .{ .id = .{ .item = record }, .count = 1 } });
        }
        try self.jukebox_updates.append(self.allocator, pos);
    }

    for (self.jukebox_updates.items) |pos| _ = self.jukeboxes.remove(pos);
}

pub fn spillOrphanDispensers(self: *World) !void {
    self.dispenser_updates.clearRetainingCapacity();

    var it = self.dispensers.iterator();
    while (it.next()) |entry| {
        const pos = entry.key_ptr.*;
        if (self.getChunk(floorDiv(pos.x, Chunk.width), floorDiv(pos.z, Chunk.width)) == null) continue;
        if (self.getBlock(pos.x, pos.y, pos.z) == .dispenser) continue;

        for (entry.value_ptr.items) |maybe_stack| {
            const stack = maybe_stack orelse continue;
            try self.dropped.append(self.allocator, .{ .pos = pos, .stack = stack });
        }
        try self.dispenser_updates.append(self.allocator, pos);
    }

    for (self.dispenser_updates.items) |pos| _ = self.dispensers.remove(pos);
}

pub fn dispense(self: *World, x: i32, y: i32, z: i32) std.mem.Allocator.Error!void {
    const step = block.dispenserStep(self.getBlockMetadata(x, y, z));
    const state = self.dispensers.getPtr(.{ .x = x, .y = y, .z = z }) orelse return;
    const stack = state.takeRandomStack(&self.rand) orelse {
        self.playDispenserFailure(x, y, z);
        return;
    };
    self.playDispenserShot(x, y, z, stack);
    try self.dispensed.append(self.allocator, .{
        .pos = .{ .x = x, .y = y, .z = z },
        .step = step,
        .stack = stack,
    });
}

fn collectTileEntities(self: *World, coord: ChunkCoord, out: *std.ArrayList(nbt.Tag)) !void {
    var it = self.furnaces.iterator();
    while (it.next()) |entry| {
        const pos = entry.key_ptr.*;
        if (floorDiv(pos.x, Chunk.width) != coord.x or floorDiv(pos.z, Chunk.width) != coord.z) continue;
        try out.append(self.allocator, try furnace.store(self.allocator, pos.x, pos.y, pos.z, entry.value_ptr.*));
    }

    var chests_it = self.chests.iterator();
    while (chests_it.next()) |entry| {
        const pos = entry.key_ptr.*;
        if (floorDiv(pos.x, Chunk.width) != coord.x or floorDiv(pos.z, Chunk.width) != coord.z) continue;
        try out.append(self.allocator, try chest.store(self.allocator, pos.x, pos.y, pos.z, entry.value_ptr.*));
    }

    var signs_it = self.signs.iterator();
    while (signs_it.next()) |entry| {
        const pos = entry.key_ptr.*;
        if (floorDiv(pos.x, Chunk.width) != coord.x or floorDiv(pos.z, Chunk.width) != coord.z) continue;
        try out.append(self.allocator, try sign.store(self.allocator, pos.x, pos.y, pos.z, entry.value_ptr.*));
    }

    var pistons_it = self.pistons.iterator();
    while (pistons_it.next()) |entry| {
        const pos = entry.key_ptr.*;
        if (floorDiv(pos.x, Chunk.width) != coord.x or floorDiv(pos.z, Chunk.width) != coord.z) continue;
        try out.append(self.allocator, try piston.store(self.allocator, pos.x, pos.y, pos.z, entry.value_ptr.*));
    }

    var jukeboxes_it = self.jukeboxes.iterator();
    while (jukeboxes_it.next()) |entry| {
        const pos = entry.key_ptr.*;
        if (floorDiv(pos.x, Chunk.width) != coord.x or floorDiv(pos.z, Chunk.width) != coord.z) continue;
        try out.append(self.allocator, try jukebox.store(self.allocator, pos.x, pos.y, pos.z, entry.value_ptr.*));
    }

    var notes_it = self.notes.iterator();
    while (notes_it.next()) |entry| {
        const pos = entry.key_ptr.*;
        if (floorDiv(pos.x, Chunk.width) != coord.x or floorDiv(pos.z, Chunk.width) != coord.z) continue;
        try out.append(self.allocator, try note.store(self.allocator, pos.x, pos.y, pos.z, entry.value_ptr.*));
    }

    var dispensers_it = self.dispensers.iterator();
    while (dispensers_it.next()) |entry| {
        const pos = entry.key_ptr.*;
        if (floorDiv(pos.x, Chunk.width) != coord.x or floorDiv(pos.z, Chunk.width) != coord.z) continue;
        try out.append(self.allocator, try dispenser.store(self.allocator, pos.x, pos.y, pos.z, entry.value_ptr.*));
    }
}

fn restoreTileEntity(context: *anyopaque, gpa: std.mem.Allocator, compound: nbt.Compound) anyerror!void {
    _ = gpa;
    const self: *World = @ptrCast(@alignCast(context));
    if (sign.load(compound)) |placed| {
        (try self.addSign(placed.x, placed.y, placed.z)).* = placed.state;
        return;
    }
    if (piston.load(compound)) |placed| {
        try self.addMovingPiston(placed.x, placed.y, placed.z, placed.state);
        return;
    }
    if (chest.load(compound)) |placed| {
        (try self.addChest(placed.x, placed.y, placed.z)).* = placed.state;
        return;
    }
    if (jukebox.load(compound)) |placed| {
        (try self.addJukebox(placed.x, placed.y, placed.z)).* = placed.state;
        return;
    }
    if (note.load(compound)) |placed| {
        (try self.addNote(placed.x, placed.y, placed.z)).* = placed.state;
        return;
    }
    if (dispenser.load(compound)) |placed| {
        (try self.addDispenser(placed.x, placed.y, placed.z)).* = placed.state;
        return;
    }
    const placed = furnace.load(compound) orelse return;
    (try self.addFurnace(placed.x, placed.y, placed.z)).* = placed.state;
}

pub fn notifyBlockChange(self: *World, x: i32, y: i32, z: i32) !void {
    try self.markChanged(x, y, z);
    try self.notifyBlocksOfNeighborChange(x, y, z, self.getBlock(x, y, z));
}

pub fn notifyBlocksOfNeighborChange(self: *World, x: i32, y: i32, z: i32, source: Block) std.mem.Allocator.Error!void {
    if (self.editing_blocks) return;
    try self.onNeighborBlockChange(x - 1, y, z, source);
    try self.onNeighborBlockChange(x + 1, y, z, source);
    try self.onNeighborBlockChange(x, y - 1, z, source);
    try self.onNeighborBlockChange(x, y + 1, z, source);
    try self.onNeighborBlockChange(x, y, z - 1, source);
    try self.onNeighborBlockChange(x, y, z + 1, source);
}

fn onBlockAdded(self: *World, x: i32, y: i32, z: i32, id: Block) std.mem.Allocator.Error!void {
    if (id == .fire and self.getBlock(x, y - 1, z) == .obsidian) _ = try portal.tryCreate(self, x, y, z);
    if (id.isLiquid()) try fluid.onBlockAdded(self, x, y, z);
    if (id.isFalling()) try self.scheduleBlockUpdate(x, y, z, id, id.tickRate());
    if (id == .dispenser) try self.setBlockMetadataWithNotify(x, y, z, self.dispenserDefaultFacing(x, y, z));
    if (block.isRail(id)) try rail.refreshAt(self, x, y, z, true);
    if (id == .tnt) try tnt.onBlockAdded(self, x, y, z);
    try redstone.onBlockAdded(self, x, y, z, id);
}

fn dispenserDefaultFacing(self: *const World, x: i32, y: i32, z: i32) u4 {
    const north = self.getBlock(x, y, z - 1).isOpaqueCube();
    const south = self.getBlock(x, y, z + 1).isOpaqueCube();
    const west = self.getBlock(x - 1, y, z).isOpaqueCube();
    const east = self.getBlock(x + 1, y, z).isOpaqueCube();

    var facing: u4 = @intFromEnum(block.Side.south);
    if (north and !south) facing = @intFromEnum(block.Side.south);
    if (south and !north) facing = @intFromEnum(block.Side.north);
    if (west and !east) facing = @intFromEnum(block.Side.east);
    if (east and !west) facing = @intFromEnum(block.Side.west);
    return facing;
}

fn onNeighborBlockChange(self: *World, x: i32, y: i32, z: i32, source: Block) std.mem.Allocator.Error!void {
    const id = self.getBlock(x, y, z);
    if (id.isLiquid()) try fluid.onNeighborChange(self, x, y, z);
    if (id.isFalling()) try self.scheduleBlockUpdate(x, y, z, id, id.tickRate());
    if (id == .tnt) try tnt.onNeighborChange(self, x, y, z, source);
    try block_update.onNeighborChange(self, x, y, z);
    try redstone.onNeighborChange(self, x, y, z, source);
}

pub fn scheduleBlockUpdate(self: *World, x: i32, y: i32, z: i32, id: Block, delay: u32) std.mem.Allocator.Error!void {
    const radius = load_radius;
    if (!self.chunksExist(x - radius, y - radius, z - radius, x + radius, y + radius, z + radius)) return;

    if (self.scheduled_updates_are_immediate) {
        if (self.getBlock(x, y, z) != id) return;
        if (id.isLiquid()) try fluid.tick(self, x, y, z);
        if (id.isFalling()) try block_update.tickFalling(self, x, y, z);
        if (redstone.handlesTick(id)) try redstone.tick(self, x, y, z, id);
        return;
    }

    const entry: ScheduledTick = .{
        .pos = .{ .x = x, .y = y, .z = z },
        .id = id,
        .time = self.time + delay,
    };
    const slot = try self.scheduled_keys.getOrPut(self.allocator, entry.key());
    if (slot.found_existing) return;
    self.scheduled.append(self.allocator, entry) catch |err| {
        _ = self.scheduled_keys.remove(entry.key());
        return err;
    };
}

pub fn tickUpdates(self: *World) !void {
    std.mem.sort(ScheduledTick, self.scheduled.items, {}, ScheduledTick.soonestFirst);

    var count: usize = 0;
    while (count < self.scheduled.items.len and count < max_ticks_per_update) : (count += 1) {
        if (self.scheduled.items[count].time > self.time) break;
    }
    if (count == 0) return;

    self.due.clearRetainingCapacity();
    try self.due.appendSlice(self.allocator, self.scheduled.items[0..count]);
    self.scheduled.replaceRangeAssumeCapacity(0, count, &[_]ScheduledTick{});
    for (self.due.items) |entry| _ = self.scheduled_keys.remove(entry.key());

    const radius = load_radius;
    for (self.due.items) |entry| {
        const pos = entry.pos;
        if (!self.chunksExist(pos.x - radius, pos.y - radius, pos.z - radius, pos.x + radius, pos.y + radius, pos.z + radius)) continue;
        if (self.getBlock(pos.x, pos.y, pos.z) != entry.id) continue;
        if (entry.id.isLiquid()) try fluid.tick(self, pos.x, pos.y, pos.z);
        if (entry.id.isFalling()) try block_update.tickFalling(self, pos.x, pos.y, pos.z);
        if (redstone.handlesTick(entry.id)) try redstone.tick(self, pos.x, pos.y, pos.z, entry.id);
        if (entry.id.def().on_tick) |hook| try hook(self, pos.x, pos.y, pos.z, entry.id);
    }
}

pub const random_tick_samples: usize = 80;

const random_tick_chunk_radius: i32 = 9;

pub const lightning_odds: i32 = 100000;
pub const snow_odds: i32 = 16;
pub const frost_light_limit: u4 = 10;

pub const Strike = struct { x: i32, y: i32, z: i32 };

fn settleFrost(self: *World, chunk: *Chunk, x: i32, z: i32, local_x: u32, local_z: u32) !void {
    if (!self.biomeAt(x, z).snows()) return;

    const y = self.findTopSolidBlock(x, z);
    if (y < 0 or y >= Chunk.height) return;
    if (chunk.getBlockLight(local_x, @intCast(y), local_z) >= frost_light_limit) return;

    const below = self.getBlock(x, y - 1, z);
    if (self.weather.isRaining() and
        self.getBlock(x, y, z) == .air and
        block_update.canPlaceAt(self, x, y, z, .snow_layer) and
        below != .air and below != .ice and below.material().isSolid())
    {
        try self.setBlockWithNotify(x, y, z, .snow_layer);
    }

    if (below == .stationary_water and self.getBlockMetadata(x, y - 1, z) == 0) {
        try self.setBlockWithNotify(x, y - 1, z, .ice);
    }
}

pub fn takeStrikes(self: *World) []const Strike {
    return self.strikes.items;
}

pub fn clearStrikes(self: *World) void {
    self.strikes.clearRetainingCapacity();
}

pub fn tickRandomBlocks(self: *World, center_chunk_x: i32, center_chunk_z: i32) !void {
    var chunk_x = center_chunk_x - random_tick_chunk_radius;
    while (chunk_x <= center_chunk_x + random_tick_chunk_radius) : (chunk_x += 1) {
        var chunk_z = center_chunk_z - random_tick_chunk_radius;
        while (chunk_z <= center_chunk_z + random_tick_chunk_radius) : (chunk_z += 1) {
            const chunk = self.getChunk(chunk_x, chunk_z) orelse continue;
            const base_x = chunk_x * Chunk.width;
            const base_z = chunk_z * Chunk.width;

            if (self.rand.nextIntBound(lightning_odds) == 0 and self.weather.isThundering() and self.weather.isRaining()) {
                self.update_lcg = self.update_lcg *% 3 +% 1013904223;
                const bits = self.update_lcg >> 2;
                const strike_x = base_x + @as(i32, @intCast(bits & 15));
                const strike_z = base_z + @as(i32, @intCast((bits >> 8) & 15));
                const strike_y = self.findTopSolidBlock(strike_x, strike_z);
                if (self.canBlockBeRainedOn(strike_x, strike_y, strike_z)) {
                    try self.strikes.append(self.allocator, .{ .x = strike_x, .y = strike_y, .z = strike_z });
                    self.weather.flash = Weather.flash_ticks;
                }
            }

            if (self.rand.nextIntBound(snow_odds) == 0) {
                self.update_lcg = self.update_lcg *% 3 +% 1013904223;
                const bits = self.update_lcg >> 2;
                const local_x: u32 = @intCast(bits & 15);
                const local_z: u32 = @intCast((bits >> 8) & 15);
                try self.settleFrost(chunk, base_x + @as(i32, @intCast(local_x)), base_z + @as(i32, @intCast(local_z)), local_x, local_z);
            }

            for (0..random_tick_samples) |_| {
                self.update_lcg = self.update_lcg *% 3 +% 1013904223;
                const bits = self.update_lcg >> 2;
                const local_x: u32 = @intCast(bits & 15);
                const local_z: u32 = @intCast((bits >> 8) & 15);
                const local_y: u32 = @intCast((bits >> 16) & 127);
                const sampled = chunk.getBlock(local_x, local_y, local_z);
                const at_x = chunk_x * Chunk.width + @as(i32, @intCast(local_x));
                const at_y: i32 = @intCast(local_y);
                const at_z = chunk_z * Chunk.width + @as(i32, @intCast(local_z));

                if (sampled == .leaves) {
                    try leaf_decay.tick(self, at_x, at_y, at_z);
                    continue;
                }
                if (sampled.def().on_random_tick) |hook| try hook(self, at_x, at_y, at_z, sampled);
            }
        }
    }
}

test "block access spans chunk boundaries using world coordinates" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();

    const a = try w.createChunk(0, 0);
    a.setBlock(15, 5, 0, .stone);
    const b = try w.createChunk(1, 0);
    b.setBlock(0, 5, 0, .dirt);

    try std.testing.expectEqual(.stone, w.getBlock(15, 5, 0));
    try std.testing.expectEqual(.dirt, w.getBlock(16, 5, 0));
}

test "a lit furnace swaps the block for its burning id, keeping its facing" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    _ = try w.createChunk(0, 0);

    const facing: u4 = @intFromEnum(block.Side.west);
    try w.setBlockAndMetadataWithNotify(3, 10, 4, .furnace, facing);
    const state = try w.addFurnace(3, 10, 4);
    state.input = .{ .id = .{ .block = .sand }, .count = 1 };
    state.fuel = .{ .id = .{ .item = .coal }, .count = 1 };

    try w.tickFurnaces();
    try std.testing.expectEqual(.burning_furnace, w.getBlock(3, 10, 4));
    try std.testing.expectEqual(facing, w.getBlockMetadata(3, 10, 4));
    try std.testing.expect(w.furnaceAt(3, 10, 4).?.isBurning());

    w.furnaceAt(3, 10, 4).?.burn_time = 1;
    w.furnaceAt(3, 10, 4).?.fuel = null;
    try w.tickFurnaces();
    try std.testing.expectEqual(.furnace, w.getBlock(3, 10, 4));
    try std.testing.expectEqual(facing, w.getBlockMetadata(3, 10, 4));
}

test "a furnace whose block is gone is forgotten on the next tick" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    _ = try w.createChunk(0, 0);

    try w.setBlockAndMetadataWithNotify(1, 5, 1, .furnace, 3);
    _ = try w.addFurnace(1, 5, 1);
    w.setBlock(1, 5, 1, .air);

    try w.tickFurnaces();
    try std.testing.expect(w.furnaceAt(1, 5, 1) == null);
}

test "breaking a furnace hands back what it held" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    _ = try w.createChunk(0, 0);

    const state = try w.addFurnace(2, 6, 2);
    state.output = .{ .id = .{ .item = .ingot_iron }, .count = 3 };

    const removed = w.removeFurnace(2, 6, 2).?;
    try std.testing.expectEqual(@as(u8, 3), removed.output.?.count);
    try std.testing.expect(w.furnaceAt(2, 6, 2) == null);
    try std.testing.expectEqual(@as(?furnace.Furnace, null), w.removeFurnace(2, 6, 2));
}

test "a chest whose block is gone spills what it held and is forgotten" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    _ = try w.createChunk(0, 0);

    try w.setBlockWithNotify(4, 7, 5, .chest);
    const state = try w.addChest(4, 7, 5);
    state.slot(2).* = .{ .id = .{ .item = .diamond }, .count = 3 };
    state.slot(9).* = .{ .id = .{ .block = .planks }, .count = 64 };

    try w.spillOrphanChests();
    try std.testing.expect(w.chestAt(4, 7, 5) != null);
    try std.testing.expectEqual(@as(usize, 0), w.dropped.items.len);

    w.setBlock(4, 7, 5, .air);
    try w.spillOrphanChests();
    try std.testing.expect(w.chestAt(4, 7, 5) == null);
    try std.testing.expectEqual(@as(usize, 2), w.dropped.items.len);
    try std.testing.expectEqual(Block.planks, w.dropped.items[1].stack.id.block);
}

test "a chest in an unloaded chunk keeps its contents" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();

    const state = try w.addChest(100, 40, 100);
    state.slot(0).* = .{ .id = .{ .item = .diamond }, .count = 1 };

    try w.spillOrphanChests();
    try std.testing.expect(w.chestAt(100, 40, 100) != null);
    try std.testing.expectEqual(@as(usize, 0), w.dropped.items.len);
}

test "chests pair with the lower coordinate first, the way InventoryLargeChest stacks them" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    _ = try w.createChunk(0, 0);

    try w.setBlockWithNotify(4, 7, 5, .chest);
    const lone = w.chestPairAt(4, 7, 5);
    try std.testing.expectEqual(@as(?BlockPos, null), lone.lower);
    try std.testing.expectEqual(@as(i32, 4), lone.upper.x);

    try w.setBlockWithNotify(5, 7, 5, .chest);
    const west = w.chestPairAt(4, 7, 5);
    try std.testing.expectEqual(@as(i32, 4), west.upper.x);
    try std.testing.expectEqual(@as(i32, 5), west.lower.?.x);

    const east = w.chestPairAt(5, 7, 5);
    try std.testing.expectEqual(@as(i32, 4), east.upper.x);
    try std.testing.expectEqual(@as(i32, 5), east.lower.?.x);
}

test "a third chest cannot join a pair, and none may make a neighbour a triple" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    _ = try w.createChunk(0, 0);

    try std.testing.expect(w.canPlaceChestAt(4, 7, 5));
    try w.setBlockWithNotify(4, 7, 5, .chest);
    try std.testing.expect(w.canPlaceChestAt(5, 7, 5));
    try w.setBlockWithNotify(5, 7, 5, .chest);

    try std.testing.expect(!w.canPlaceChestAt(6, 7, 5));
    try std.testing.expect(!w.canPlaceChestAt(4, 7, 6));
    try std.testing.expect(!w.canPlaceChestAt(5, 7, 4));
    try std.testing.expect(w.canPlaceChestAt(4, 7, 8));
}

test "a solid block over either half seals the chest shut" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    _ = try w.createChunk(0, 0);

    try w.setBlockWithNotify(4, 7, 5, .chest);
    try w.setBlockWithNotify(5, 7, 5, .chest);
    try std.testing.expect(!w.chestIsBlocked(4, 7, 5));

    try w.setBlockWithNotify(5, 8, 5, .stone);
    try std.testing.expect(w.chestIsBlocked(4, 7, 5));
    try std.testing.expect(w.chestIsBlocked(5, 7, 5));

    try w.setBlockWithNotify(5, 8, 5, .glass);
    try std.testing.expect(!w.chestIsBlocked(4, 7, 5));
}

test "reading an unloaded chunk returns air" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    try std.testing.expectEqual(.air, w.getBlock(1000, 5, 1000));
}

test "negative coordinates resolve to the correct chunk" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    const neg = try w.createChunk(-1, -1);
    neg.setBlock(15, 5, 15, .stone);
    try std.testing.expectEqual(.stone, w.getBlock(-1, 5, -1));
    try std.testing.expectEqual(.air, w.getBlock(-2, 5, -1));
}

test "setBlock writes through to the owning chunk" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    _ = try w.createChunk(0, 0);
    w.setBlock(3, 10, 4, .stone);
    try std.testing.expectEqual(.stone, w.getBlock(3, 10, 4));
}

test "ensureDecorated shape-generates the full 3x3 neighbor block" {
    const gpa = std.testing.allocator;
    const gen = try TerrainGenerator.init(gpa, 1);
    defer gen.deinit(gpa);

    var w = World.init(gpa);
    defer w.deinit();
    try w.ensureDecorated(gen, 0, 0);

    var dx: i32 = -1;
    while (dx <= 1) : (dx += 1) {
        var dz: i32 = -1;
        while (dz <= 1) : (dz += 1) {
            try std.testing.expect(w.getChunk(dx, dz) != null);
        }
    }
}

test "stepDecorate walks one chunk of work at a time" {
    const gpa = std.testing.allocator;
    const gen = try TerrainGenerator.init(gpa, 1);
    defer gen.deinit(gpa);

    var w = World.init(gpa);
    defer w.deinit();

    var generated: usize = 0;
    while (true) {
        const step = try w.stepDecorate(gen, 0, 0);
        if (step != .generated) {
            try std.testing.expectEqual(DecorateStep.decorated, step);
            break;
        }
        generated += 1;
        try std.testing.expect(!w.isDecorated(0, 0));
    }

    try std.testing.expectEqual(@as(usize, 9), generated);
    try std.testing.expect(w.isDecorated(0, 0));
    try std.testing.expectEqual(DecorateStep.done, try w.stepDecorate(gen, 0, 0));
}

test "stepping a chunk decorates it exactly as one ensureDecorated call would" {
    const gpa = std.testing.allocator;
    const gen = try TerrainGenerator.init(gpa, 7);
    defer gen.deinit(gpa);

    var whole = World.init(gpa);
    defer whole.deinit();
    try whole.ensureDecorated(gen, 0, 0);

    var stepped = World.init(gpa);
    defer stepped.deinit();
    while (true) {
        const step = try stepped.stepDecorate(gen, 0, 0);
        if (step != .generated) break;
    }

    for (0..16) |x| {
        for (0..128) |y| {
            for (0..16) |z| {
                try std.testing.expectEqual(
                    whole.getBlock(@intCast(x), @intCast(y), @intCast(z)),
                    stepped.getBlock(@intCast(x), @intCast(y), @intCast(z)),
                );
            }
        }
    }
}

test "ensureDecorated only decorates a chunk once" {
    const gpa = std.testing.allocator;
    const gen = try TerrainGenerator.init(gpa, 1);
    defer gen.deinit(gpa);

    var w = World.init(gpa);
    defer w.deinit();
    try w.ensureDecorated(gen, 0, 0);

    var before: [16 * 128 * 16]Block = undefined;
    var idx: usize = 0;
    for (0..16) |x| {
        for (0..128) |y| {
            for (0..16) |z| {
                before[idx] = w.getBlock(@intCast(x), @intCast(y), @intCast(z));
                idx += 1;
            }
        }
    }

    try w.ensureDecorated(gen, 0, 0);

    idx = 0;
    for (0..16) |x| {
        for (0..128) |y| {
            for (0..16) |z| {
                try std.testing.expectEqual(before[idx], w.getBlock(@intCast(x), @intCast(y), @intCast(z)));
                idx += 1;
            }
        }
    }
}

test "celestialAngle matches WorldProvider across the day" {
    var world_map = World.init(std.testing.allocator);
    defer world_map.deinit();

    const cases = [_]struct { time: i64, angle: f32 }{
        .{ .time = 0, .angle = 0.784517825 },
        .{ .time = 1000, .angle = 0.826669991 },
        .{ .time = 6000, .angle = 0.0 },
        .{ .time = 12000, .angle = 0.215482190 },
        .{ .time = 18000, .angle = 0.5 },
        .{ .time = 22000, .angle = 0.694444478 },
    };
    for (cases) |case| {
        world_map.time = case.time;
        try std.testing.expectApproxEqAbs(case.angle, world_map.celestialAngle(0.0), 1.0e-6);
    }
}

test "skylight is only subtracted between dusk and dawn" {
    var world_map = World.init(std.testing.allocator);
    defer world_map.deinit();

    const cases = [_]struct { time: i64, subtracted: u4 }{
        .{ .time = 0, .subtracted = 0 },
        .{ .time = 6000, .subtracted = 0 },
        .{ .time = 12000, .subtracted = 0 },
        .{ .time = 13000, .subtracted = 6 },
        .{ .time = 15000, .subtracted = 11 },
        .{ .time = 18000, .subtracted = 11 },
        .{ .time = 22000, .subtracted = 11 },
        .{ .time = 23999, .subtracted = 0 },
    };
    for (cases) |case| {
        world_map.time = case.time;
        try std.testing.expectEqual(case.subtracted, world_map.calculateSkylightSubtracted(0.0));
    }
}

test "a day wraps around without discontinuity" {
    var world_map = World.init(std.testing.allocator);
    defer world_map.deinit();

    world_map.time = 24000;
    const wrapped = world_map.celestialAngle(0.0);
    world_map.time = 0;
    try std.testing.expectEqual(world_map.celestialAngle(0.0), wrapped);
}

test "a world with a save reloads its chunks from disk instead of regenerating them" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const generator = try TerrainGenerator.init(gpa, 4321);
    defer generator.deinit(gpa);

    var handle = try save.open(io, tmp.dir, "Persisted");
    defer handle.close(gpa, io);

    {
        var world_map = World.init(gpa);
        defer world_map.deinit();
        world_map.persistence = .{ .handle = &handle, .io = io };

        try world_map.ensureDecorated(generator, 0, 0);
        world_map.setBlock(4, 100, 6, .glowstone);
        try world_map.saveLoadedChunks();
    }

    var reloaded = World.init(gpa);
    defer reloaded.deinit();
    reloaded.persistence = .{ .handle = &handle, .io = io };

    const chunk = try reloaded.getOrGenerateChunk(generator, 0, 0);
    try std.testing.expectEqual(.glowstone, chunk.getBlock(4, 100, 6));
    try std.testing.expect(reloaded.isDecorated(0, 0));
}

test "a second save skips chunks that have not changed since the first" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const generator = try TerrainGenerator.init(gpa, 4321);
    defer generator.deinit(gpa);

    var handle = try save.open(io, tmp.dir, "Unchanged");
    defer handle.close(gpa, io);

    var world_map = World.init(gpa);
    defer world_map.deinit();
    world_map.persistence = .{ .handle = &handle, .io = io };

    try world_map.ensureDecorated(generator, 0, 0);
    try world_map.saveLoadedChunks();

    const chunk = world_map.getChunk(0, 0).?;
    try std.testing.expect(!chunk.modified);

    world_map.setBlock(4, 100, 6, .glowstone);
    try std.testing.expect(chunk.modified);
    try world_map.saveLoadedChunks();
    try std.testing.expect(!chunk.modified);
}

test "a chunk loaded from disk is clean until something changes it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const generator = try TerrainGenerator.init(gpa, 909);
    defer generator.deinit(gpa);

    var handle = try save.open(io, tmp.dir, "Clean");
    defer handle.close(gpa, io);

    {
        var world_map = World.init(gpa);
        defer world_map.deinit();
        world_map.persistence = .{ .handle = &handle, .io = io };
        try world_map.ensureDecorated(generator, 0, 0);
        try world_map.saveLoadedChunks();
    }

    var reloaded = World.init(gpa);
    defer reloaded.deinit();
    reloaded.persistence = .{ .handle = &handle, .io = io };

    const chunk = try reloaded.getOrGenerateChunk(generator, 0, 0);
    try std.testing.expect(!chunk.modified);
}

test "a chunk keeps being written while it still holds the entities it stored" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const generator = try TerrainGenerator.init(gpa, 77);
    defer generator.deinit(gpa);

    var handle = try save.open(io, tmp.dir, "Tenants");
    defer handle.close(gpa, io);

    var world_map = World.init(gpa);
    defer world_map.deinit();
    world_map.persistence = .{ .handle = &handle, .io = io };

    try world_map.ensureDecorated(generator, 0, 0);
    (try world_map.addSign(3, 90, 5)).* = .{};
    try world_map.saveLoadedChunks();

    const chunk = world_map.getChunk(0, 0).?;
    try std.testing.expect(chunk.stored_entities);

    _ = world_map.removeSign(3, 90, 5);
    chunk.modified = false;
    try world_map.saveLoadedChunks();
    try std.testing.expect(!chunk.stored_entities);
}

test "a world without a save still generates chunks" {
    const gpa = std.testing.allocator;
    const generator = try TerrainGenerator.init(gpa, 4321);
    defer generator.deinit(gpa);

    var world_map = World.init(gpa);
    defer world_map.deinit();

    const chunk = try world_map.getOrGenerateChunk(generator, 0, 0);
    try std.testing.expectEqual(.bedrock, chunk.getBlock(0, 0, 0));
    try world_map.saveLoadedChunks();
}

test "an incremental save round writes every loaded chunk a few at a time" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const generator = try TerrainGenerator.init(gpa, 55);
    defer generator.deinit(gpa);

    var handle = try save.open(io, tmp.dir, "Incremental");
    defer handle.close(gpa, io);

    {
        var world_map = World.init(gpa);
        defer world_map.deinit();
        world_map.persistence = .{ .handle = &handle, .io = io };

        var cx: i32 = 0;
        while (cx < 2) : (cx += 1) {
            _ = try world_map.getOrGenerateChunk(generator, cx, 0);
            world_map.setBlock(cx * 16 + 1, 90, 1, .glowstone);
        }

        try world_map.beginSaveRound();
        var rounds: usize = 0;
        while (try world_map.saveQueuedChunks(1) > 0) : (rounds += 1) {
            try std.testing.expect(rounds < 16);
        }
        try std.testing.expect(rounds > 0);
    }

    var reloaded = World.init(gpa);
    defer reloaded.deinit();
    reloaded.persistence = .{ .handle = &handle, .io = io };

    var cx: i32 = 0;
    while (cx < 2) : (cx += 1) {
        _ = try reloaded.getOrGenerateChunk(generator, cx, 0);
        try std.testing.expectEqual(.glowstone, reloaded.getBlock(cx * 16 + 1, 90, 1));
    }
}

test "sleeping rounds the clock up to the next dawn" {
    var world_map = World.init(std.testing.allocator);
    defer world_map.deinit();

    world_map.time = 13000;
    world_map.skipToDawn();
    try std.testing.expectEqual(@as(i64, 24000), world_map.time);

    world_map.time = 24001;
    world_map.skipToDawn();
    try std.testing.expectEqual(@as(i64, 48000), world_map.time);

    world_map.time = 0;
    world_map.skipToDawn();
    try std.testing.expectEqual(@as(i64, 24000), world_map.time);
}

test "moving the clock drags the pending scheduled ticks along with it" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    for ([_][2]i32{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 } }) |coord| _ = try w.createChunk(coord[0], coord[1]);

    w.time = 100;
    w.setBlock(8, 10, 8, .flowing_water);
    try w.scheduleBlockUpdate(8, 10, 8, .flowing_water, 5);
    try std.testing.expectEqual(@as(i64, 105), w.scheduled.items[0].time);

    w.setTime(18000);
    try std.testing.expectEqual(@as(i64, 18000), w.time);
    try std.testing.expectEqual(@as(i64, 18005), w.scheduled.items[0].time);

    w.setTime(0);
    try std.testing.expectEqual(@as(i64, 5), w.scheduled.items[0].time);
}

test "day and night follow how much skylight is taken away" {
    var world_map = World.init(std.testing.allocator);
    defer world_map.deinit();

    world_map.skylight_subtracted = 0;
    try std.testing.expect(world_map.isDaytime());
    world_map.skylight_subtracted = 3;
    try std.testing.expect(world_map.isDaytime());
    world_map.skylight_subtracted = 4;
    try std.testing.expect(!world_map.isDaytime());
    world_map.skylight_subtracted = 11;
    try std.testing.expect(!world_map.isDaytime());
}

var hook_hits: usize = 0;

fn countHook(_: *World, _: i32, _: i32, _: i32, _: Block) std.mem.Allocator.Error!void {
    hook_hits += 1;
}

fn clearHook(world_map: *World, x: i32, y: i32, z: i32, _: Block) std.mem.Allocator.Error!void {
    hook_hits += 1;
    try world_map.setBlockWithNotify(x, y, z, .air);
}

fn loadedWorld(allocator: std.mem.Allocator) !World {
    var w = World.init(allocator);
    errdefer w.deinit();
    var chunk_x: i32 = -1;
    while (chunk_x <= 1) : (chunk_x += 1) {
        var chunk_z: i32 = -1;
        while (chunk_z <= 1) : (chunk_z += 1) _ = try w.createChunk(chunk_x, chunk_z);
    }
    return w;
}

test "a registered block's scheduled tick hook runs when its update falls due" {
    defer Block.resetRegistry();
    hook_hits = 0;

    const custom: Block = @enumFromInt(200);
    custom.register(.{ .key = "rosebed:ticker", .on_tick = countHook });

    var w = try loadedWorld(std.testing.allocator);
    defer w.deinit();

    w.setBlock(8, 5, 8, custom);
    try w.scheduleBlockUpdate(8, 5, 8, custom, 1);
    w.time += 2;
    try w.tickUpdates();

    try std.testing.expectEqual(@as(usize, 1), hook_hits);
}

test "a block with no tick hook costs nothing on the same path" {
    hook_hits = 0;

    var w = try loadedWorld(std.testing.allocator);
    defer w.deinit();

    w.setBlock(8, 5, 8, .stone);
    try w.scheduleBlockUpdate(8, 5, 8, .stone, 1);
    w.time += 2;
    try w.tickUpdates();

    try std.testing.expectEqual(@as(usize, 0), hook_hits);
}

test "a registered block's neighbour hook runs when the block beside it changes" {
    defer Block.resetRegistry();
    hook_hits = 0;

    const custom: Block = @enumFromInt(201);
    custom.register(.{ .key = "rosebed:listener", .on_neighbor_change = countHook });

    var w = try loadedWorld(std.testing.allocator);
    defer w.deinit();

    w.setBlock(8, 5, 8, custom);
    try w.setBlockWithNotify(9, 5, 8, .stone);

    try std.testing.expect(hook_hits >= 1);
}

test "a neighbour hook that removes its own block stops the support check running on air" {
    defer Block.resetRegistry();
    hook_hits = 0;

    const custom: Block = @enumFromInt(202);
    custom.register(.{ .key = "rosebed:crumbler", .on_neighbor_change = clearHook });

    var w = try loadedWorld(std.testing.allocator);
    defer w.deinit();

    w.setBlock(8, 5, 8, custom);
    try w.setBlockWithNotify(9, 5, 8, .stone);

    try std.testing.expectEqual(.air, w.getBlock(8, 5, 8));
    try std.testing.expect(hook_hits >= 1);
}

test "a locked chest rots away the first time a random tick lands on it" {
    var w = try loadedWorld(std.testing.allocator);
    defer w.deinit();

    const chunk = w.getChunk(0, 0).?;
    @memset(&chunk.blocks, .locked_chest);

    try w.tickRandomBlocks(0, 0);

    var vanished: usize = 0;
    for (chunk.blocks) |id| {
        if (id == .air) vanished += 1;
    }
    try std.testing.expect(vanished >= 1);
}

test "a registered block's random tick hook runs when the sampler lands on it" {
    defer Block.resetRegistry();
    hook_hits = 0;

    const custom: Block = @enumFromInt(203);
    custom.register(.{ .key = "rosebed:grower", .on_random_tick = countHook });

    var w = try loadedWorld(std.testing.allocator);
    defer w.deinit();

    const chunk = w.getChunk(0, 0).?;
    @memset(&chunk.blocks, custom);

    try w.tickRandomBlocks(0, 0);
    try std.testing.expectEqual(random_tick_samples, hook_hits);
}
