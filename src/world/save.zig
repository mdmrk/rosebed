const std = @import("std");

const block = @import("block.zig");
const chest = @import("chest.zig");
const Chunk = @import("chunk.zig");
const chunk_nbt = @import("chunk_nbt.zig");
const deflate = @import("deflate.zig");
const furnace = @import("furnace.zig");
const generator = @import("generator.zig");
const nbt = @import("nbt.zig");
const RegionFile = @import("region.zig");

pub const saves_dir_name = "saves";
pub const region_dir_name = "region";
pub const level_file = "level.dat";
pub const lock_file = "session.lock";
pub const level_file_new = "level.dat_new";
pub const level_file_old = "level.dat_old";
pub const default_folder = "World";
pub const max_name_len = 32;

const max_level_bytes = 1024 * 1024;
const default_health: i16 = 10;

pub const InventoryEntry = struct {
    slot: u8,
    id: i16,
    count: u8,
    damage: i16 = 0,
    key: []const u8 = "",
};

pub const PlayerState = struct {
    pos: [3]f64,
    motion: [3]f64 = .{ 0, 0, 0 },
    yaw: f32 = 0,
    pitch: f32 = 0,
    fall_distance: f32 = 0,
    fire: i16 = 0,
    air: i16 = 300,
    on_ground: bool = false,
    health: i16 = default_health,
    hurt_time: i16 = 0,
    death_time: i16 = 0,
    attack_time: i16 = 0,
    spawn: ?[3]i32 = null,
    dimension: generator.Dimension = .overworld,
    inventory: []InventoryEntry = &.{},

    pub fn deinit(self: *PlayerState, gpa: std.mem.Allocator) void {
        gpa.free(self.inventory);
        self.inventory = &.{};
    }
};

pub const LevelInfo = struct {
    seed: i64,
    spawn: [3]i32 = .{ 0, 64, 0 },
    time: i64 = 0,
    last_played: i64 = 0,
    size_on_disk: i64 = 0,
    name: []u8,
    player: ?PlayerState = null,

    pub fn deinit(self: *LevelInfo, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        if (self.player) |*player| player.deinit(gpa);
        self.player = null;
    }
};

pub const Summary = struct {
    folder: []u8,
    name: []u8,
    last_played: i64,
    size_bytes: u64,

    pub fn deinit(self: *Summary, gpa: std.mem.Allocator) void {
        gpa.free(self.folder);
        gpa.free(self.name);
    }

    fn newestFirst(_: void, a: Summary, b: Summary) bool {
        if (a.last_played != b.last_played) return a.last_played > b.last_played;
        return std.mem.order(u8, a.folder, b.folder) == .lt;
    }
};

pub fn isLegalFolderChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_', ' ', '.' => true,
        else => false,
    };
}

pub fn sanitizeFolderName(buffer: []u8, name: []const u8) []u8 {
    const trimmed = std.mem.trim(u8, name, " \t");
    var len: usize = 0;
    for (trimmed) |c| {
        if (len == buffer.len) break;
        buffer[len] = if (isLegalFolderChar(c)) c else '_';
        len += 1;
    }
    while (len > 0 and (buffer[len - 1] == ' ' or buffer[len - 1] == '.')) len -= 1;

    const cleaned = buffer[0..len];
    if (cleaned.len == 0 or std.mem.eql(u8, cleaned, ".") or std.mem.eql(u8, cleaned, "..")) {
        @memcpy(buffer[0..default_folder.len], default_folder);
        return buffer[0..default_folder.len];
    }
    return cleaned;
}

pub fn openSavesDir(io: std.Io, base: std.Io.Dir) !std.Io.Dir {
    return base.createDirPathOpen(io, saves_dir_name, .{ .open_options = .{ .iterate = true } });
}

pub fn folderTaken(io: std.Io, saves_dir: std.Io.Dir, folder: []const u8) bool {
    var dir = saves_dir.openDir(io, folder, .{}) catch return false;
    dir.close(io);
    return true;
}

pub fn unusedFolderName(gpa: std.mem.Allocator, io: std.Io, saves_dir: std.Io.Dir, name: []const u8) ![]u8 {
    var buffer: [max_name_len]u8 = undefined;
    const base = sanitizeFolderName(&buffer, name);

    var candidate = try gpa.dupe(u8, base);
    errdefer gpa.free(candidate);

    while (folderTaken(io, saves_dir, candidate)) {
        const grown = try std.fmt.allocPrint(gpa, "{s}-", .{candidate});
        gpa.free(candidate);
        candidate = grown;
    }
    return candidate;
}

pub fn deleteWorld(io: std.Io, saves_dir: std.Io.Dir, folder: []const u8) !void {
    if (std.mem.eql(u8, folder, ".") or std.mem.eql(u8, folder, "..")) return error.BadPathName;
    for (folder) |c| if (!isLegalFolderChar(c)) return error.BadPathName;
    try saves_dir.deleteTree(io, folder);
}

pub fn list(gpa: std.mem.Allocator, io: std.Io, saves_dir: std.Io.Dir) ![]Summary {
    var found: std.ArrayList(Summary) = .empty;
    errdefer {
        for (found.items) |*summary| summary.deinit(gpa);
        found.deinit(gpa);
    }

    var iterator = saves_dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory) continue;

        var dir = saves_dir.openDir(io, entry.name, .{}) catch continue;
        defer dir.close(io);

        var info = readLevelIn(gpa, io, dir) catch continue;
        defer info.deinit(gpa);

        try found.append(gpa, .{
            .folder = try gpa.dupe(u8, entry.name),
            .name = try gpa.dupe(u8, info.name),
            .last_played = info.last_played,
            .size_bytes = regionBytes(io, dir),
        });
    }

    const summaries = try found.toOwnedSlice(gpa);
    std.mem.sort(Summary, summaries, {}, Summary.newestFirst);
    return summaries;
}

pub fn freeList(gpa: std.mem.Allocator, summaries: []Summary) void {
    for (summaries) |*summary| summary.deinit(gpa);
    gpa.free(summaries);
}

pub fn readLevelIn(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !LevelInfo {
    return readLevelFile(gpa, io, dir, level_file) catch
        try readLevelFile(gpa, io, dir, level_file_old);
}

fn readLevelFile(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8) !LevelInfo {
    const file = try dir.openFile(io, name, .{});
    defer file.close(io);

    const size = try file.length(io);
    if (size > max_level_bytes) return error.StreamTooLong;

    const raw = try gpa.alloc(u8, @intCast(size));
    defer gpa.free(raw);
    if (try file.readPositionalAll(io, raw, 0) != raw.len) return error.EndOfStream;

    const plain = try deflate.decompressAlloc(gpa, .gzip, raw, max_level_bytes);
    defer gpa.free(plain);

    var reader = std.Io.Reader.fixed(plain);
    var named = try nbt.readNamed(gpa, &reader);
    defer {
        gpa.free(named.name);
        nbt.deinit(gpa, &named.tag);
    }

    return try levelFromTag(gpa, named.tag);
}

fn sumFileSizes(io: std.Io, dir: std.Io.Dir) u64 {
    var total: u64 = 0;
    var iterator = dir.iterate();
    while (iterator.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const stat = dir.statFile(io, entry.name, .{}) catch continue;
        total += stat.size;
    }
    return total;
}

pub fn regionBytes(io: std.Io, dir: std.Io.Dir) u64 {
    var region_dir = dir.openDir(io, region_dir_name, .{ .iterate = true }) catch return 0;
    defer region_dir.close(io);
    return sumFileSizes(io, region_dir);
}

pub const LockError = error{SaveInUse};

fn writeLock(io: std.Io, dir: std.Io.Dir, stamp: i64) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(i64, &bytes, stamp, .big);

    const file = try dir.createFile(io, lock_file, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, &bytes);
}

fn readLock(io: std.Io, dir: std.Io.Dir) !i64 {
    const file = try dir.openFile(io, lock_file, .{});
    defer file.close(io);

    var bytes: [8]u8 = undefined;
    if (try file.readPositionalAll(io, &bytes, 0) != bytes.len) return error.EndOfStream;
    return std.mem.readInt(i64, &bytes, .big);
}

const RegionKey = struct { x: i32, z: i32 };

pub const Save = struct {
    dir: std.Io.Dir,
    region_dir: std.Io.Dir,
    lock_stamp: i64,
    regions: std.AutoHashMapUnmanaged(RegionKey, *RegionFile) = .{},

    pub fn useDimension(self: *Save, gpa: std.mem.Allocator, io: std.Io, which: generator.Dimension) !void {
        var it = self.regions.valueIterator();
        while (it.next()) |open_region| {
            open_region.*.close(gpa, io);
            gpa.destroy(open_region.*);
        }
        self.regions.clearRetainingCapacity();

        const opened = try self.dir.createDirPathOpen(io, which.regionPath(), .{ .open_options = .{ .iterate = true } });
        self.region_dir.close(io);
        self.region_dir = opened;
    }

    pub fn checkLock(self: *const Save, io: std.Io) !void {
        const stamp = readLock(io, self.dir) catch return LockError.SaveInUse;
        if (stamp != self.lock_stamp) return LockError.SaveInUse;
    }

    pub fn close(self: *Save, gpa: std.mem.Allocator, io: std.Io) void {
        var it = self.regions.valueIterator();
        while (it.next()) |open_region| {
            open_region.*.close(gpa, io);
            gpa.destroy(open_region.*);
        }
        self.regions.deinit(gpa);
        self.region_dir.close(io);
        self.dir.close(io);
    }

    pub fn diskSize(self: *const Save, io: std.Io) u64 {
        var total: u64 = 0;
        var iterator = self.region_dir.iterate();
        while (iterator.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            const stat = self.region_dir.statFile(io, entry.name, .{}) catch continue;
            total += stat.size;
        }
        return total;
    }

    fn region(self: *Save, gpa: std.mem.Allocator, io: std.Io, chunk_x: i32, chunk_z: i32) !*RegionFile {
        const key: RegionKey = .{ .x = RegionFile.regionCoord(chunk_x), .z = RegionFile.regionCoord(chunk_z) };
        const slot = try self.regions.getOrPut(gpa, key);
        if (slot.found_existing) return slot.value_ptr.*;
        errdefer _ = self.regions.remove(key);

        const opened = try gpa.create(RegionFile);
        errdefer gpa.destroy(opened);
        opened.* = try RegionFile.open(gpa, io, self.region_dir, key.x, key.z);

        slot.value_ptr.* = opened;
        return opened;
    }

    pub fn hasChunk(self: *Save, gpa: std.mem.Allocator, io: std.Io, chunk_x: i32, chunk_z: i32) bool {
        const file = self.region(gpa, io, chunk_x, chunk_z) catch return false;
        return file.hasChunk(RegionFile.localCoord(chunk_x), RegionFile.localCoord(chunk_z));
    }

    pub const EntityVisitor = struct {
        context: *anyopaque,
        visit: *const fn (context: *anyopaque, gpa: std.mem.Allocator, entity: nbt.Compound) anyerror!void,
    };

    pub fn readChunk(
        self: *Save,
        gpa: std.mem.Allocator,
        io: std.Io,
        chunk_x: i32,
        chunk_z: i32,
        visitor: ?EntityVisitor,
        tile_visitor: ?EntityVisitor,
    ) !?chunk_nbt.Loaded {
        const file = try self.region(gpa, io, chunk_x, chunk_z);
        const bytes = try file.readChunk(gpa, io, RegionFile.localCoord(chunk_x), RegionFile.localCoord(chunk_z)) orelse return null;
        defer gpa.free(bytes);

        var reader = std.Io.Reader.fixed(bytes);
        var named = try nbt.readNamed(gpa, &reader);
        defer {
            gpa.free(named.name);
            nbt.deinit(gpa, &named.tag);
        }

        const loaded = try chunk_nbt.load(named.tag);
        if (visitor) |sink| {
            for (loaded.entities) |entity| {
                switch (entity) {
                    .compound => |compound| try sink.visit(sink.context, gpa, compound),
                    else => {},
                }
            }
        }
        if (tile_visitor) |sink| {
            for (loaded.tile_entities) |tile_entity| {
                switch (tile_entity) {
                    .compound => |compound| try sink.visit(sink.context, gpa, compound),
                    else => {},
                }
            }
        }
        return loaded;
    }

    pub fn writeChunk(
        self: *Save,
        gpa: std.mem.Allocator,
        io: std.Io,
        chunk: *const Chunk,
        world_time: i64,
        populated: bool,
        entities: []nbt.Tag,
        tile_entities: []nbt.Tag,
    ) !void {
        try self.checkLock(io);

        var tag = try chunk_nbt.store(gpa, chunk, world_time, populated, entities, tile_entities);
        defer nbt.deinit(gpa, &tag);

        var allocating: std.Io.Writer.Allocating = .init(gpa);
        defer allocating.deinit();
        try nbt.writeNamed(&allocating.writer, "", tag);

        const file = try self.region(gpa, io, chunk.x, chunk.z);
        try file.writeChunk(gpa, io, RegionFile.localCoord(chunk.x), RegionFile.localCoord(chunk.z), allocating.written());
    }

    pub fn readLevel(self: *Save, gpa: std.mem.Allocator, io: std.Io) !LevelInfo {
        return readLevelIn(gpa, io, self.dir);
    }

    pub fn writeLevel(self: *Save, gpa: std.mem.Allocator, io: std.Io, info: LevelInfo) !void {
        try self.checkLock(io);

        var tag = try levelToTag(gpa, info);
        defer nbt.deinit(gpa, &tag);

        var allocating: std.Io.Writer.Allocating = .init(gpa);
        defer allocating.deinit();
        try nbt.writeNamed(&allocating.writer, "", tag);

        const packed_bytes = try deflate.compressAlloc(gpa, .gzip, allocating.written());
        defer gpa.free(packed_bytes);

        {
            const file = try self.dir.createFile(io, level_file_new, .{});
            defer file.close(io);
            try file.writeStreamingAll(io, packed_bytes);
        }

        self.dir.deleteFile(io, level_file_old) catch {};
        self.dir.rename(level_file, self.dir, level_file_old, io) catch {};
        try self.dir.rename(level_file_new, self.dir, level_file, io);
    }
};

pub fn open(io: std.Io, saves_dir: std.Io.Dir, folder: []const u8) !Save {
    var dir = try saves_dir.createDirPathOpen(io, folder, .{});
    errdefer dir.close(io);

    var region_dir = try dir.createDirPathOpen(io, region_dir_name, .{ .open_options = .{ .iterate = true } });
    errdefer region_dir.close(io);

    const stamp = RegionFile.unixMilliseconds(io);
    try writeLock(io, dir, stamp);

    return .{ .dir = dir, .region_dir = region_dir, .lock_stamp = stamp };
}

fn put(gpa: std.mem.Allocator, compound: *nbt.Compound, key: []const u8, tag: nbt.Tag) !void {
    try nbt.putDuped(gpa, compound, key, tag);
}

fn doubleList(gpa: std.mem.Allocator, values: [3]f64) !nbt.Tag {
    const items = try gpa.alloc(nbt.Tag, 3);
    for (items, values) |*item, value| item.* = .{ .double = value };
    return .{ .list = .{ .element_type = .double, .items = items } };
}

fn floatList(gpa: std.mem.Allocator, values: [2]f32) !nbt.Tag {
    const items = try gpa.alloc(nbt.Tag, 2);
    for (items, values) |*item, value| item.* = .{ .float = value };
    return .{ .list = .{ .element_type = .float, .items = items } };
}

fn playerToTag(gpa: std.mem.Allocator, player: PlayerState) !nbt.Tag {
    var compound: nbt.Compound = .{};
    errdefer {
        var owned: nbt.Tag = .{ .compound = compound };
        nbt.deinit(gpa, &owned);
    }

    try put(gpa, &compound, "Pos", try doubleList(gpa, player.pos));
    try put(gpa, &compound, "Motion", try doubleList(gpa, player.motion));
    try put(gpa, &compound, "Rotation", try floatList(gpa, .{ player.yaw, player.pitch }));
    try put(gpa, &compound, "FallDistance", .{ .float = player.fall_distance });
    try put(gpa, &compound, "Fire", .{ .short = player.fire });
    try put(gpa, &compound, "Air", .{ .short = player.air });
    try put(gpa, &compound, "OnGround", .{ .byte = @intFromBool(player.on_ground) });
    try put(gpa, &compound, "Health", .{ .short = player.health });
    try put(gpa, &compound, "HurtTime", .{ .short = player.hurt_time });
    try put(gpa, &compound, "DeathTime", .{ .short = player.death_time });
    try put(gpa, &compound, "AttackTime", .{ .short = player.attack_time });
    try put(gpa, &compound, "Dimension", .{ .int = @intFromEnum(player.dimension) });
    try put(gpa, &compound, "Sleeping", .{ .byte = 0 });
    try put(gpa, &compound, "SleepTimer", .{ .short = 0 });
    if (player.spawn) |spawn| {
        try put(gpa, &compound, "SpawnX", .{ .int = spawn[0] });
        try put(gpa, &compound, "SpawnY", .{ .int = spawn[1] });
        try put(gpa, &compound, "SpawnZ", .{ .int = spawn[2] });
    }

    const items = try gpa.alloc(nbt.Tag, player.inventory.len);
    var built: usize = 0;
    errdefer {
        for (items[0..built]) |*item| nbt.deinit(gpa, item);
        gpa.free(items);
    }
    for (player.inventory, items) |entry, *item| {
        var slot: nbt.Compound = .{};
        errdefer {
            var owned: nbt.Tag = .{ .compound = slot };
            nbt.deinit(gpa, &owned);
        }
        try put(gpa, &slot, "Slot", .{ .byte = @bitCast(entry.slot) });
        try put(gpa, &slot, "id", .{ .short = entry.id });
        try put(gpa, &slot, "Count", .{ .byte = @bitCast(entry.count) });
        try put(gpa, &slot, "Damage", .{ .short = entry.damage });
        if (entry.key.len != 0) try put(gpa, &slot, "Key", .{ .string = try gpa.dupe(u8, entry.key) });
        item.* = .{ .compound = slot };
        built += 1;
    }
    try put(gpa, &compound, "Inventory", .{ .list = .{ .element_type = .compound, .items = items } });

    return .{ .compound = compound };
}

fn levelToTag(gpa: std.mem.Allocator, info: LevelInfo) !nbt.Tag {
    var data: nbt.Compound = .{};
    errdefer {
        var owned: nbt.Tag = .{ .compound = data };
        nbt.deinit(gpa, &owned);
    }

    try put(gpa, &data, "RandomSeed", .{ .long = info.seed });
    try put(gpa, &data, "SpawnX", .{ .int = info.spawn[0] });
    try put(gpa, &data, "SpawnY", .{ .int = info.spawn[1] });
    try put(gpa, &data, "SpawnZ", .{ .int = info.spawn[2] });
    try put(gpa, &data, "Time", .{ .long = info.time });
    try put(gpa, &data, "LastPlayed", .{ .long = info.last_played });
    try put(gpa, &data, "SizeOnDisk", .{ .long = info.size_on_disk });
    try put(gpa, &data, "LevelName", .{ .string = try gpa.dupe(u8, info.name) });
    try put(gpa, &data, "version", .{ .int = 19132 });
    if (info.player) |player| try put(gpa, &data, "Player", try playerToTag(gpa, player));

    var root: nbt.Compound = .{};
    errdefer {
        var owned: nbt.Tag = .{ .compound = root };
        nbt.deinit(gpa, &owned);
    }
    try put(gpa, &root, "Data", .{ .compound = data });
    return .{ .compound = root };
}

fn compoundField(compound: nbt.Compound, key: []const u8) ?nbt.Compound {
    return switch (compound.get(key) orelse return null) {
        .compound => |value| value,
        else => null,
    };
}

fn longField(compound: nbt.Compound, key: []const u8, fallback: i64) i64 {
    return switch (compound.get(key) orelse return fallback) {
        .long => |value| value,
        else => fallback,
    };
}

fn intField(compound: nbt.Compound, key: []const u8, fallback: i32) i32 {
    return switch (compound.get(key) orelse return fallback) {
        .int => |value| value,
        else => fallback,
    };
}

fn shortField(compound: nbt.Compound, key: []const u8, fallback: i16) i16 {
    return switch (compound.get(key) orelse return fallback) {
        .short => |value| value,
        else => fallback,
    };
}

fn floatField(compound: nbt.Compound, key: []const u8, fallback: f32) f32 {
    return switch (compound.get(key) orelse return fallback) {
        .float => |value| value,
        else => fallback,
    };
}

fn stringField(compound: nbt.Compound, key: []const u8) ?[]const u8 {
    return switch (compound.get(key) orelse return null) {
        .string => |value| value,
        else => null,
    };
}

fn doublesFromList(compound: nbt.Compound, key: []const u8, out: *[3]f64) void {
    const items = switch (compound.get(key) orelse return) {
        .list => |value| value.items,
        else => return,
    };
    for (items, 0..) |item, i| {
        if (i >= out.len) break;
        out[i] = switch (item) {
            .double => |value| value,
            else => out[i],
        };
    }
}

fn playerFromTag(gpa: std.mem.Allocator, compound: nbt.Compound) !PlayerState {
    var player: PlayerState = .{ .pos = .{ 0, 64, 0 } };
    doublesFromList(compound, "Pos", &player.pos);
    doublesFromList(compound, "Motion", &player.motion);

    if (compound.get("Rotation")) |tag| switch (tag) {
        .list => |rotation| {
            if (rotation.items.len > 0) player.yaw = switch (rotation.items[0]) {
                .float => |value| value,
                else => 0,
            };
            if (rotation.items.len > 1) player.pitch = switch (rotation.items[1]) {
                .float => |value| value,
                else => 0,
            };
        },
        else => {},
    };

    if (compound.get("OnGround")) |tag| switch (tag) {
        .byte => |value| player.on_ground = value != 0,
        else => {},
    };

    player.fall_distance = floatField(compound, "FallDistance", 0);
    player.fire = shortField(compound, "Fire", 0);
    player.air = shortField(compound, "Air", 300);
    player.dimension = if (intField(compound, "Dimension", 0) == -1) .nether else .overworld;
    player.health = shortField(compound, "Health", default_health);
    player.hurt_time = shortField(compound, "HurtTime", 0);
    player.death_time = shortField(compound, "DeathTime", 0);
    player.attack_time = shortField(compound, "AttackTime", 0);

    if (compound.get("SpawnX") != null and compound.get("SpawnY") != null and compound.get("SpawnZ") != null) {
        player.spawn = .{
            intField(compound, "SpawnX", 0),
            intField(compound, "SpawnY", 0),
            intField(compound, "SpawnZ", 0),
        };
    }

    const slots = switch (compound.get("Inventory") orelse return player) {
        .list => |value| value.items,
        else => return player,
    };

    var entries: std.ArrayList(InventoryEntry) = .empty;
    errdefer entries.deinit(gpa);

    for (slots) |slot_tag| {
        const slot = switch (slot_tag) {
            .compound => |value| value,
            else => continue,
        };
        const slot_index = switch (slot.get("Slot") orelse continue) {
            .byte => |value| value,
            else => continue,
        };
        const id = switch (slot.get("id") orelse continue) {
            .short => |value| value,
            else => continue,
        };
        const count = switch (slot.get("Count") orelse continue) {
            .byte => |value| value,
            else => continue,
        };
        const damage = switch (slot.get("Damage") orelse nbt.Tag{ .short = 0 }) {
            .short => |value| value,
            else => 0,
        };
        const stored_key = switch (slot.get("Key") orelse nbt.Tag{ .string = @constCast("") }) {
            .string => |value| value,
            else => "",
        };

        const resolved = block.Id.resolve(id, stored_key) orelse continue;

        try entries.append(gpa, .{
            .slot = @bitCast(slot_index),
            .id = resolved.numeric(),
            .count = @bitCast(count),
            .damage = damage,
            .key = resolved.key(),
        });
    }

    player.inventory = try entries.toOwnedSlice(gpa);
    return player;
}

fn levelFromTag(gpa: std.mem.Allocator, root: nbt.Tag) !LevelInfo {
    const outer = switch (root) {
        .compound => |value| value,
        else => return error.MissingField,
    };
    const data = compoundField(outer, "Data") orelse return error.MissingField;

    const name = stringField(data, "LevelName") orelse "";
    var info: LevelInfo = .{
        .seed = longField(data, "RandomSeed", 0),
        .spawn = .{ intField(data, "SpawnX", 0), intField(data, "SpawnY", 64), intField(data, "SpawnZ", 0) },
        .time = longField(data, "Time", 0),
        .last_played = longField(data, "LastPlayed", 0),
        .size_on_disk = longField(data, "SizeOnDisk", 0),
        .name = try gpa.dupe(u8, name),
    };
    errdefer info.deinit(gpa);

    if (compoundField(data, "Player")) |player| {
        info.player = try playerFromTag(gpa, player);
    }
    return info;
}

test "folder names drop characters that do not belong in a path" {
    var buffer: [max_name_len]u8 = undefined;
    try std.testing.expectEqualStrings("My World", sanitizeFolderName(&buffer, "My World"));
    try std.testing.expectEqualStrings("bad_name", sanitizeFolderName(&buffer, "bad/name"));
    try std.testing.expectEqualStrings(".._.._etc", sanitizeFolderName(&buffer, "../../etc"));
    try std.testing.expectEqualStrings("World", sanitizeFolderName(&buffer, "   "));
    try std.testing.expectEqualStrings("World", sanitizeFolderName(&buffer, ".."));
    try std.testing.expectEqualStrings("trimmed", sanitizeFolderName(&buffer, "  trimmed  "));
}

test "a level.dat round-trips seed, spawn, time and player state" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var world = try open(io, tmp.dir, "Test World");
    defer world.close(gpa, io);

    const inventory = try gpa.alloc(InventoryEntry, 2);
    inventory[0] = .{ .slot = 0, .id = 1, .count = 42 };
    inventory[1] = .{ .slot = 7, .id = 264, .count = 3, .damage = 5 };

    var written: LevelInfo = .{
        .seed = -8123456789,
        .spawn = .{ 12, 70, -34 },
        .time = 13000,
        .last_played = 1700000000,
        .name = try gpa.dupe(u8, "Test World"),
        .player = .{
            .pos = .{ 1.5, 72.25, -3.75 },
            .motion = .{ 0.1, -0.2, 0.3 },
            .yaw = 45.5,
            .pitch = -12.25,
            .fall_distance = 3.5,
            .fire = 120,
            .air = 45,
            .on_ground = true,
            .health = 7,
            .hurt_time = 6,
            .death_time = 3,
            .inventory = inventory,
        },
    };
    defer written.deinit(gpa);

    try world.writeLevel(gpa, io, written);

    var read_back = try world.readLevel(gpa, io);
    defer read_back.deinit(gpa);

    try std.testing.expectEqual(written.seed, read_back.seed);
    try std.testing.expectEqual(written.spawn, read_back.spawn);
    try std.testing.expectEqual(written.time, read_back.time);
    try std.testing.expectEqual(written.last_played, read_back.last_played);
    try std.testing.expectEqualStrings(written.name, read_back.name);

    const player = read_back.player.?;
    try std.testing.expectEqual(written.player.?.pos, player.pos);
    try std.testing.expectEqual(written.player.?.motion, player.motion);
    try std.testing.expectEqual(written.player.?.yaw, player.yaw);
    try std.testing.expectEqual(written.player.?.pitch, player.pitch);
    try std.testing.expect(player.on_ground);
    try std.testing.expectEqual(written.player.?.fall_distance, player.fall_distance);
    try std.testing.expectEqual(@as(i16, 120), player.fire);
    try std.testing.expectEqual(@as(i16, 45), player.air);
    try std.testing.expectEqual(@as(i16, 7), player.health);
    try std.testing.expectEqual(@as(i16, 6), player.hurt_time);
    try std.testing.expectEqual(@as(i16, 3), player.death_time);
    try std.testing.expectEqual(@as(usize, 2), player.inventory.len);
    try std.testing.expectEqual(@as(i16, 264), player.inventory[1].id);
    try std.testing.expectEqual(@as(u8, 7), player.inventory[1].slot);
    try std.testing.expectEqual(@as(i16, 5), player.inventory[1].damage);
}

test "a player written without vitals reads back at the original's fallback health" {
    const gpa = std.testing.allocator;
    const player: PlayerState = .{ .pos = .{ 0, 64, 0 } };

    var tag = try playerToTag(gpa, player);
    defer nbt.deinit(gpa, &tag);

    var removed = tag.compound.fetchOrderedRemove("Health").?;
    gpa.free(removed.key);
    nbt.deinit(gpa, &removed.value);

    var loaded = try playerFromTag(gpa, tag.compound);
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(default_health, loaded.health);
}

test "a level.dat without a player still loads" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var world = try open(io, tmp.dir, "Fresh");
    defer world.close(gpa, io);

    var written: LevelInfo = .{ .seed = 7, .name = try gpa.dupe(u8, "Fresh") };
    defer written.deinit(gpa);
    try world.writeLevel(gpa, io, written);

    var read_back = try world.readLevel(gpa, io);
    defer read_back.deinit(gpa);
    try std.testing.expectEqual(@as(i64, 7), read_back.seed);
    try std.testing.expectEqual(@as(?PlayerState, null), read_back.player);
}

test "a chunk written through the save handler comes back with its blocks" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var world = try open(io, tmp.dir, "Chunky");
    defer world.close(gpa, io);

    var chunk = Chunk.init(-40, 33);
    chunk.setBlock(1, 2, 3, .stone);
    chunk.setBlock(15, 127, 15, .glowstone);
    chunk.setBlockMetadata(1, 2, 3, 9);

    try std.testing.expect(!world.hasChunk(gpa, io, -40, 33));
    try world.writeChunk(gpa, io, &chunk, 1234, true, try gpa.alloc(nbt.Tag, 0), try gpa.alloc(nbt.Tag, 0));
    try std.testing.expect(world.hasChunk(gpa, io, -40, 33));

    const loaded = (try world.readChunk(gpa, io, -40, 33, null, null)).?;
    try std.testing.expectEqual(@as(i32, -40), loaded.chunk.x);
    try std.testing.expectEqual(@as(i32, 33), loaded.chunk.z);
    try std.testing.expect(loaded.populated);
    try std.testing.expectEqual(Chunk.getBlock(&chunk, 1, 2, 3), loaded.chunk.getBlock(1, 2, 3));
    try std.testing.expectEqual(Chunk.getBlock(&chunk, 15, 127, 15), loaded.chunk.getBlock(15, 127, 15));
    try std.testing.expectEqual(@as(u4, 9), loaded.chunk.getBlockMetadata(1, 2, 3));

    try std.testing.expectEqual(@as(?chunk_nbt.Loaded, null), try world.readChunk(gpa, io, 0, 0, null, null));
}

const FurnaceSink = struct {
    found: ?furnace.Placed = null,

    fn visit(context: *anyopaque, gpa: std.mem.Allocator, compound: nbt.Compound) anyerror!void {
        _ = gpa;
        const self: *FurnaceSink = @ptrCast(@alignCast(context));
        self.found = furnace.load(compound);
    }
};

test "a furnace written with its chunk comes back mid-smelt" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var world = try open(io, tmp.dir, "Smelty");
    defer world.close(gpa, io);

    const chunk = Chunk.init(2, -5);
    const state: furnace.Furnace = .{
        .input = .{ .id = .{ .block = .ore_iron }, .count = 6 },
        .fuel = .{ .id = .{ .item = .coal }, .count = 2 },
        .burn_time = 1200,
        .item_burn_time = 1600,
        .cook_time = 55,
    };

    const tile_entities = try gpa.alloc(nbt.Tag, 1);
    tile_entities[0] = try furnace.store(gpa, 33, 64, -71, state);
    try world.writeChunk(gpa, io, &chunk, 1, true, try gpa.alloc(nbt.Tag, 0), tile_entities);

    var sink: FurnaceSink = .{};
    _ = (try world.readChunk(gpa, io, 2, -5, null, .{ .context = &sink, .visit = FurnaceSink.visit })).?;

    const found = sink.found.?;
    try std.testing.expectEqual(@as(i32, 33), found.x);
    try std.testing.expectEqual(@as(i32, 64), found.y);
    try std.testing.expectEqual(@as(i32, -71), found.z);
    try std.testing.expectEqual(state, found.state);
}

const ChestSink = struct {
    found: ?chest.Placed = null,

    fn visit(context: *anyopaque, gpa: std.mem.Allocator, compound: nbt.Compound) anyerror!void {
        _ = gpa;
        const self: *ChestSink = @ptrCast(@alignCast(context));
        self.found = chest.load(compound);
    }
};

test "a chest written with its chunk comes back with its contents" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var world = try open(io, tmp.dir, "Hoard");
    defer world.close(gpa, io);

    const chunk = Chunk.init(2, -5);
    var state: chest.Chest = .{};
    state.slot(0).* = .{ .id = .{ .item = .diamond }, .count = 7 };
    state.slot(26).* = .{ .id = .{ .block = .wool }, .count = 12, .meta = 14 };

    const tile_entities = try gpa.alloc(nbt.Tag, 1);
    tile_entities[0] = try chest.store(gpa, 33, 64, -71, state);
    try world.writeChunk(gpa, io, &chunk, 1, true, try gpa.alloc(nbt.Tag, 0), tile_entities);

    var sink: ChestSink = .{};
    _ = (try world.readChunk(gpa, io, 2, -5, null, .{ .context = &sink, .visit = ChestSink.visit })).?;

    const found = sink.found.?;
    try std.testing.expectEqual(@as(i32, 33), found.x);
    try std.testing.expectEqual(@as(i32, -71), found.z);
    try std.testing.expectEqual(state, found.state);
}

test "a second session takes the lock and the first refuses to write over it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var first = try open(io, tmp.dir, "Contested");
    defer first.close(gpa, io);

    var info: LevelInfo = .{ .seed = 1, .name = try gpa.dupe(u8, "Contested") };
    defer info.deinit(gpa);
    try first.writeLevel(gpa, io, info);

    var second = try open(io, tmp.dir, "Contested");
    defer second.close(gpa, io);
    second.lock_stamp = first.lock_stamp + 1;
    try writeLock(io, second.dir, second.lock_stamp);

    try std.testing.expectError(LockError.SaveInUse, first.writeLevel(gpa, io, info));

    const chunk = Chunk.init(0, 0);
    try std.testing.expectError(LockError.SaveInUse, first.writeChunk(gpa, io, &chunk, 0, true, try gpa.alloc(nbt.Tag, 0), try gpa.alloc(nbt.Tag, 0)));

    try second.writeLevel(gpa, io, info);
}

test "a save whose lock file has gone refuses to write" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var world = try open(io, tmp.dir, "Unlocked");
    defer world.close(gpa, io);

    try world.dir.deleteFile(io, lock_file);

    var info: LevelInfo = .{ .seed = 1, .name = try gpa.dupe(u8, "Unlocked") };
    defer info.deinit(gpa);
    try std.testing.expectError(LockError.SaveInUse, world.writeLevel(gpa, io, info));
}

test "listing worlds returns them newest first and skips folders without a level.dat" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const names = [_][]const u8{ "Alpha", "Beta", "Gamma" };
    const played = [_]i64{ 100, 300, 200 };
    for (names, played) |name, last_played| {
        var world = try open(io, tmp.dir, name);
        defer world.close(gpa, io);
        var info: LevelInfo = .{ .seed = 1, .last_played = last_played, .name = try gpa.dupe(u8, name) };
        defer info.deinit(gpa);
        try world.writeLevel(gpa, io, info);
    }
    var stray = try tmp.dir.createDirPathOpen(io, "not-a-world", .{});
    stray.close(io);

    const summaries = try list(gpa, io, tmp.dir);
    defer freeList(gpa, summaries);

    try std.testing.expectEqual(@as(usize, 3), summaries.len);
    try std.testing.expectEqualStrings("Beta", summaries[0].folder);
    try std.testing.expectEqualStrings("Gamma", summaries[1].folder);
    try std.testing.expectEqualStrings("Alpha", summaries[2].folder);
}

test "an unused folder name gains a suffix instead of overwriting an existing world" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const first = try unusedFolderName(gpa, io, tmp.dir, "New World");
    defer gpa.free(first);
    try std.testing.expectEqualStrings("New World", first);

    var world = try open(io, tmp.dir, first);
    world.close(gpa, io);

    const second = try unusedFolderName(gpa, io, tmp.dir, "New World");
    defer gpa.free(second);
    try std.testing.expectEqualStrings("New World-", second);
}

test "deleting a world removes it and refuses to escape the saves directory" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var world = try open(io, tmp.dir, "Doomed");
    var info: LevelInfo = .{ .seed = 1, .name = try gpa.dupe(u8, "Doomed") };
    defer info.deinit(gpa);
    try world.writeLevel(gpa, io, info);
    world.close(gpa, io);

    try std.testing.expectError(error.BadPathName, deleteWorld(io, tmp.dir, ".."));
    try std.testing.expectError(error.BadPathName, deleteWorld(io, tmp.dir, "../escape"));

    try deleteWorld(io, tmp.dir, "Doomed");

    const summaries = try list(gpa, io, tmp.dir);
    defer freeList(gpa, summaries);
    try std.testing.expectEqual(@as(usize, 0), summaries.len);
}

test "each dimension keeps its chunks in its own region folder" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var handle = try open(io, tmp.dir, "Dimensions");
    defer handle.close(gpa, io);

    var overworld = Chunk.init(0, 0);
    overworld.setBlock(0, 64, 0, .stone);
    try handle.writeChunk(gpa, io, &overworld, 0, true, try gpa.alloc(nbt.Tag, 0), try gpa.alloc(nbt.Tag, 0));

    try handle.useDimension(gpa, io, .nether);

    var nether = Chunk.init(0, 0);
    nether.setBlock(0, 64, 0, .netherrack);
    try handle.writeChunk(gpa, io, &nether, 0, true, try gpa.alloc(nbt.Tag, 0), try gpa.alloc(nbt.Tag, 0));

    const from_nether = (try handle.readChunk(gpa, io, 0, 0, null, null)).?;
    try std.testing.expectEqual(.netherrack, from_nether.chunk.getBlock(0, 64, 0));

    try handle.useDimension(gpa, io, .overworld);
    const from_overworld = (try handle.readChunk(gpa, io, 0, 0, null, null)).?;
    try std.testing.expectEqual(.stone, from_overworld.chunk.getBlock(0, 64, 0));

    var dim_dir = try tmp.dir.openDir(io, "Dimensions/DIM-1/region", .{ .iterate = true });
    defer dim_dir.close(io);
}

test "the dimension a player logged out in comes back with them" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var handle = try open(io, tmp.dir, "Travelled");
    defer handle.close(gpa, io);

    var info: LevelInfo = .{
        .seed = 5,
        .name = try gpa.dupe(u8, "Travelled"),
        .player = .{ .pos = .{ 1.5, 70.0, 2.5 }, .dimension = .nether },
    };
    defer info.deinit(gpa);
    try handle.writeLevel(gpa, io, info);

    var restored = try handle.readLevel(gpa, io);
    defer restored.deinit(gpa);

    try std.testing.expectEqual(generator.Dimension.nether, restored.player.?.dimension);
}

test "a world saved before dimensions existed loads as the overworld" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var handle = try open(io, tmp.dir, "Legacy");
    defer handle.close(gpa, io);

    var info: LevelInfo = .{
        .seed = 5,
        .name = try gpa.dupe(u8, "Legacy"),
        .player = .{ .pos = .{ 0, 64, 0 } },
    };
    defer info.deinit(gpa);
    try handle.writeLevel(gpa, io, info);

    var restored = try handle.readLevel(gpa, io);
    defer restored.deinit(gpa);

    try std.testing.expectEqual(generator.Dimension.overworld, restored.player.?.dimension);
}
