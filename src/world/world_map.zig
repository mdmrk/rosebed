const std = @import("std");
const Chunk = @import("chunk.zig");
const constants = @import("constants.zig");
const block = @import("block.zig");
const Block = block.Block;
const TerrainGenerator = @import("terrain_gen.zig");
const JavaRandom = @import("java_random.zig");
const light = @import("light.zig");
const fluid = @import("fluid.zig");
const leaf_decay = @import("leaf_decay.zig");
const block_update = @import("block_update.zig");
const save = @import("save.zig");
const nbt = @import("nbt.zig");
const math = @import("math");

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

pub const FallingBlock = struct { pos: BlockPos, id: Block };

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

allocator: std.mem.Allocator,
chunks: std.AutoHashMapUnmanaged(ChunkCoord, *Chunk) = .{},
decorated: std.AutoHashMapUnmanaged(ChunkCoord, void) = .{},
scheduled: std.ArrayList(ScheduledTick) = .empty,
scheduled_keys: std.AutoHashMapUnmanaged(ScheduledTick.Key, void) = .{},
due: std.ArrayList(ScheduledTick) = .empty,
changed: std.ArrayList(BlockPos) = .empty,
dropped: std.ArrayList(DroppedBlock) = .empty,
falling: std.ArrayList(FallingBlock) = .empty,
rand: JavaRandom = JavaRandom.init(0),
update_lcg: i32 = 0,
time: i64 = 0,
skylight_subtracted: u4 = 0,
scheduled_updates_are_immediate: bool = false,
persistence: ?Persistence = null,
entity_io: ?EntityIo = null,
save_queue: std.ArrayList(ChunkCoord) = .empty,

pub const ticks_per_day: i64 = 24000;

pub const max_ticks_per_update: usize = 1000;

const load_radius: i32 = 8;

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
    return @intFromFloat(darkness * 11.0);
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
    self.save_queue.deinit(self.allocator);
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

pub fn getOrGenerateChunk(self: *World, generator: TerrainGenerator, chunk_x: i32, chunk_z: i32) !*Chunk {
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

fn loadChunk(self: *World, generator: TerrainGenerator, chunk_x: i32, chunk_z: i32) !?*Chunk {
    const persistence = self.persistence orelse return null;
    const found = persistence.handle.readChunk(
        self.allocator,
        persistence.io,
        chunk_x,
        chunk_z,
        self.entityVisitor(),
    ) catch return null;
    const stored = found orelse return null;

    const chunk = try self.createChunk(chunk_x, chunk_z);
    const climate = generator.climate.sample(chunk_x * Chunk.width, chunk_z * Chunk.width);
    chunk.* = stored.chunk;
    for (0..Chunk.width) |x| {
        for (0..Chunk.width) |z| {
            const i = x * Chunk.width + z;
            chunk.setClimate(@intCast(x), @intCast(z), @floatCast(climate.temperature[i]), @floatCast(climate.humidity[i]));
        }
    }

    if (stored.populated) try self.decorated.put(self.allocator, .{ .x = chunk_x, .z = chunk_z }, {});
    return chunk;
}

fn writeChunkAt(self: *World, coord: ChunkCoord) !void {
    const persistence = self.persistence orelse return;
    const chunk = self.getChunk(coord.x, coord.z) orelse return;

    var entities: std.ArrayList(nbt.Tag) = .empty;
    errdefer {
        for (entities.items) |*tag| nbt.deinit(self.allocator, tag);
        entities.deinit(self.allocator);
    }
    if (self.entity_io) |io| try io.collect(io.context, self.allocator, coord.x, coord.z, &entities);

    try persistence.handle.writeChunk(
        self.allocator,
        persistence.io,
        chunk,
        self.time,
        self.isDecorated(coord.x, coord.z),
        try entities.toOwnedSlice(self.allocator),
    );
}

pub fn saveLoadedChunks(self: *World) !void {
    if (self.persistence == null) return;

    var it = self.chunks.keyIterator();
    while (it.next()) |coord| try self.writeChunkAt(coord.*);
    self.save_queue.clearRetainingCapacity();
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
        try self.writeChunkAt(coord);
        written += 1;
    }
    return self.save_queue.items.len;
}

pub fn isDecorated(self: *const World, chunk_x: i32, chunk_z: i32) bool {
    return self.decorated.contains(.{ .x = chunk_x, .z = chunk_z });
}

pub fn ensureDecorated(self: *World, generator: TerrainGenerator, chunk_x: i32, chunk_z: i32) !void {
    if (self.isDecorated(chunk_x, chunk_z)) return;

    var dx: i32 = -1;
    while (dx <= 1) : (dx += 1) {
        var dz: i32 = -1;
        while (dz <= 1) : (dz += 1) {
            _ = try self.getOrGenerateChunk(generator, chunk_x + dx, chunk_z + dz);
        }
    }

    try generator.decorateChunk(self, chunk_x, chunk_z);
    try self.decorated.put(self.allocator, .{ .x = chunk_x, .z = chunk_z }, {});
    try light.relightChunk(self.allocator, self, chunk_x, chunk_z);
}

fn floorDiv(value: i32, divisor: i32) i32 {
    return @divFloor(value, divisor);
}

fn floorMod(value: i32, divisor: i32) i32 {
    return @mod(value, divisor);
}

pub fn getBlock(self: *const World, x: i32, y: i32, z: i32) Block {
    if (y < 0 or y >= constants.chunk_height) return Block.air;
    const chunk = self.getChunk(floorDiv(x, constants.chunk_width), floorDiv(z, constants.chunk_width)) orelse return Block.air;
    return chunk.getBlock(@intCast(floorMod(x, constants.chunk_width)), @intCast(y), @intCast(floorMod(z, constants.chunk_width)));
}

pub fn setBlock(self: *World, x: i32, y: i32, z: i32, id: Block) void {
    if (y < 0 or y >= constants.chunk_height) return;
    const chunk = self.getChunk(floorDiv(x, constants.chunk_width), floorDiv(z, constants.chunk_width)) orelse return;
    chunk.setBlock(@intCast(floorMod(x, constants.chunk_width)), @intCast(y), @intCast(floorMod(z, constants.chunk_width)), id);
}

pub fn getSkyLight(self: *const World, x: i32, y: i32, z: i32) u4 {
    if (y < 0) return 0;
    if (y >= constants.chunk_height) return 15;
    const chunk = self.getChunk(floorDiv(x, constants.chunk_width), floorDiv(z, constants.chunk_width)) orelse return 0;
    return chunk.getSkyLight(@intCast(floorMod(x, constants.chunk_width)), @intCast(y), @intCast(floorMod(z, constants.chunk_width)));
}

pub fn setSkyLight(self: *World, x: i32, y: i32, z: i32, value: u4) void {
    if (y < 0 or y >= constants.chunk_height) return;
    const chunk = self.getChunk(floorDiv(x, constants.chunk_width), floorDiv(z, constants.chunk_width)) orelse return;
    chunk.setSkyLight(@intCast(floorMod(x, constants.chunk_width)), @intCast(y), @intCast(floorMod(z, constants.chunk_width)), value);
}

pub fn getBlockLight(self: *const World, x: i32, y: i32, z: i32) u4 {
    if (y < 0 or y >= constants.chunk_height) return 0;
    const chunk = self.getChunk(floorDiv(x, constants.chunk_width), floorDiv(z, constants.chunk_width)) orelse return 0;
    return chunk.getBlockLight(@intCast(floorMod(x, constants.chunk_width)), @intCast(y), @intCast(floorMod(z, constants.chunk_width)));
}

pub fn setBlockLight(self: *World, x: i32, y: i32, z: i32, value: u4) void {
    if (y < 0 or y >= constants.chunk_height) return;
    const chunk = self.getChunk(floorDiv(x, constants.chunk_width), floorDiv(z, constants.chunk_width)) orelse return;
    chunk.setBlockLight(@intCast(floorMod(x, constants.chunk_width)), @intCast(y), @intCast(floorMod(z, constants.chunk_width)), value);
}

pub fn getBlockMetadata(self: *const World, x: i32, y: i32, z: i32) u4 {
    if (y < 0 or y >= constants.chunk_height) return 0;
    const chunk = self.getChunk(floorDiv(x, constants.chunk_width), floorDiv(z, constants.chunk_width)) orelse return 0;
    return chunk.getBlockMetadata(@intCast(floorMod(x, constants.chunk_width)), @intCast(y), @intCast(floorMod(z, constants.chunk_width)));
}

pub fn setBlockMetadata(self: *World, x: i32, y: i32, z: i32, value: u4) void {
    if (y < 0 or y >= constants.chunk_height) return;
    const chunk = self.getChunk(floorDiv(x, constants.chunk_width), floorDiv(z, constants.chunk_width)) orelse return;
    chunk.setBlockMetadata(@intCast(floorMod(x, constants.chunk_width)), @intCast(y), @intCast(floorMod(z, constants.chunk_width)), value);
}

pub fn canBlockSeeTheSky(self: *const World, x: i32, y: i32, z: i32) bool {
    const chunk = self.getChunk(floorDiv(x, constants.chunk_width), floorDiv(z, constants.chunk_width)) orelse return false;
    const height = chunk.getHeightValue(@intCast(floorMod(x, constants.chunk_width)), @intCast(floorMod(z, constants.chunk_width)));
    return y >= height;
}

pub fn chunksExist(self: *const World, min_x: i32, min_y: i32, min_z: i32, max_x: i32, max_y: i32, max_z: i32) bool {
    if (max_y < 0 or min_y >= constants.chunk_height) return false;
    const width = constants.chunk_width;
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
}

pub fn setBlockWithNotify(self: *World, x: i32, y: i32, z: i32, id: Block) !void {
    try self.setBlockAndMetadataWithNotify(x, y, z, id, 0);
}

pub fn setBlockAndMetadataWithNotify(self: *World, x: i32, y: i32, z: i32, id: Block, meta: u4) !void {
    if (y < 0 or y >= constants.chunk_height) return;
    const chunk = self.getChunk(floorDiv(x, constants.chunk_width), floorDiv(z, constants.chunk_width)) orelse return;
    const local_x: u32 = @intCast(floorMod(x, constants.chunk_width));
    const local_z: u32 = @intCast(floorMod(z, constants.chunk_width));
    const previous = chunk.getBlock(local_x, @intCast(y), local_z);
    chunk.setBlock(local_x, @intCast(y), local_z, id);
    chunk.setBlockMetadata(local_x, @intCast(y), local_z, meta);
    if (previous != id) leaf_decay.onBlockRemoved(self, x, y, z, previous);
    try self.onBlockAdded(x, y, z, id);
    try self.notifyBlockChange(x, y, z);
}

pub fn setBlockMetadataWithNotify(self: *World, x: i32, y: i32, z: i32, meta: u4) !void {
    if (y < 0 or y >= constants.chunk_height) return;
    if (self.getChunk(floorDiv(x, constants.chunk_width), floorDiv(z, constants.chunk_width)) == null) return;
    self.setBlockMetadata(x, y, z, meta);
    try self.notifyBlockChange(x, y, z);
}

pub fn notifyBlockChange(self: *World, x: i32, y: i32, z: i32) !void {
    try self.markChanged(x, y, z);
    try self.notifyBlocksOfNeighborChange(x, y, z);
}

pub fn notifyBlocksOfNeighborChange(self: *World, x: i32, y: i32, z: i32) !void {
    try self.onNeighborBlockChange(x - 1, y, z);
    try self.onNeighborBlockChange(x + 1, y, z);
    try self.onNeighborBlockChange(x, y - 1, z);
    try self.onNeighborBlockChange(x, y + 1, z);
    try self.onNeighborBlockChange(x, y, z - 1);
    try self.onNeighborBlockChange(x, y, z + 1);
}

fn onBlockAdded(self: *World, x: i32, y: i32, z: i32, id: Block) std.mem.Allocator.Error!void {
    if (id.isLiquid()) try fluid.onBlockAdded(self, x, y, z);
    if (id.isFalling()) try self.scheduleBlockUpdate(x, y, z, id, id.tickRate());
}

fn onNeighborBlockChange(self: *World, x: i32, y: i32, z: i32) std.mem.Allocator.Error!void {
    const id = self.getBlock(x, y, z);
    if (id.isLiquid()) try fluid.onNeighborChange(self, x, y, z);
    if (id.isFalling()) try self.scheduleBlockUpdate(x, y, z, id, id.tickRate());
    try block_update.onNeighborChange(self, x, y, z);
}

pub fn scheduleBlockUpdate(self: *World, x: i32, y: i32, z: i32, id: Block, delay: u32) std.mem.Allocator.Error!void {
    const radius = load_radius;
    if (!self.chunksExist(x - radius, y - radius, z - radius, x + radius, y + radius, z + radius)) return;

    if (self.scheduled_updates_are_immediate) {
        if (self.getBlock(x, y, z) != id) return;
        if (id.isLiquid()) try fluid.tick(self, x, y, z);
        if (id.isFalling()) try block_update.tickFalling(self, x, y, z);
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
    }
}

pub const random_tick_samples: usize = 80;

const random_tick_chunk_radius: i32 = 9;

pub fn tickRandomBlocks(self: *World, center_chunk_x: i32, center_chunk_z: i32) !void {
    var chunk_x = center_chunk_x - random_tick_chunk_radius;
    while (chunk_x <= center_chunk_x + random_tick_chunk_radius) : (chunk_x += 1) {
        var chunk_z = center_chunk_z - random_tick_chunk_radius;
        while (chunk_z <= center_chunk_z + random_tick_chunk_radius) : (chunk_z += 1) {
            const chunk = self.getChunk(chunk_x, chunk_z) orelse continue;
            for (0..random_tick_samples) |_| {
                self.update_lcg = self.update_lcg *% 3 +% 1013904223;
                const bits = self.update_lcg >> 2;
                const local_x: u32 = @intCast(bits & 15);
                const local_z: u32 = @intCast((bits >> 8) & 15);
                const local_y: u32 = @intCast((bits >> 16) & 127);
                if (chunk.getBlock(local_x, local_y, local_z) != .leaves) continue;
                try leaf_decay.tick(
                    self,
                    chunk_x * constants.chunk_width + @as(i32, @intCast(local_x)),
                    @intCast(local_y),
                    chunk_z * constants.chunk_width + @as(i32, @intCast(local_z)),
                );
            }
        }
    }
}

test "block access spans chunk boundaries using world coordinates" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();

    const a = try w.createChunk(0, 0);
    a.setBlock(15, 5, 0, Block.stone);
    const b = try w.createChunk(1, 0);
    b.setBlock(0, 5, 0, Block.dirt);

    try std.testing.expectEqual(Block.stone, w.getBlock(15, 5, 0));
    try std.testing.expectEqual(Block.dirt, w.getBlock(16, 5, 0));
}

test "reading an unloaded chunk returns air" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    try std.testing.expectEqual(Block.air, w.getBlock(1000, 5, 1000));
}

test "negative coordinates resolve to the correct chunk" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    const neg = try w.createChunk(-1, -1);
    neg.setBlock(15, 5, 15, Block.stone);
    try std.testing.expectEqual(Block.stone, w.getBlock(-1, 5, -1));
    try std.testing.expectEqual(Block.air, w.getBlock(-2, 5, -1));
}

test "setBlock writes through to the owning chunk" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    _ = try w.createChunk(0, 0);
    w.setBlock(3, 10, 4, Block.stone);
    try std.testing.expectEqual(Block.stone, w.getBlock(3, 10, 4));
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
        world_map.setBlock(4, 100, 6, Block.glowstone);
        try world_map.saveLoadedChunks();
    }

    var reloaded = World.init(gpa);
    defer reloaded.deinit();
    reloaded.persistence = .{ .handle = &handle, .io = io };

    const chunk = try reloaded.getOrGenerateChunk(generator, 0, 0);
    try std.testing.expectEqual(Block.glowstone, chunk.getBlock(4, 100, 6));
    try std.testing.expect(reloaded.isDecorated(0, 0));
}

test "a world without a save still generates chunks" {
    const gpa = std.testing.allocator;
    const generator = try TerrainGenerator.init(gpa, 4321);
    defer generator.deinit(gpa);

    var world_map = World.init(gpa);
    defer world_map.deinit();

    const chunk = try world_map.getOrGenerateChunk(generator, 0, 0);
    try std.testing.expectEqual(Block.bedrock, chunk.getBlock(0, 0, 0));
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
            world_map.setBlock(cx * 16 + 1, 90, 1, Block.glowstone);
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
        try std.testing.expectEqual(Block.glowstone, reloaded.getBlock(cx * 16 + 1, 90, 1));
    }
}
