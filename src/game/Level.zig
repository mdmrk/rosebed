const std = @import("std");

const math = @import("math");
const world = @import("world");

const Entities = @import("Entities.zig");
const Animal = @import("entity/Animal.zig");
const Inventory = @import("Inventory.zig");
const Player = @import("Player.zig");
const physics = @import("physics.zig");
const spawner = @import("spawner.zig");

const Level = @This();

const mounted_fraction: f64 = 0.75;

world_map: world.World,
generator: world.Generator,
entities: Entities = .{},
spawn: [3]i32 = .{ 0, 64, 0 },
tick_count: u64 = 0,
occupants: std.ArrayList(Occupant) = .empty,
roster: std.ArrayList(*Player) = .empty,
views: std.ArrayList(Animal.PlayerView) = .empty,

pub const Occupant = struct {
    player: *Player,
    active: bool = true,
};

pub fn players(self: *const Level) Animal.Players {
    return .of(self.views.items);
}

pub fn init(gpa: std.mem.Allocator, generator: world.Generator) Level {
    return .{ .world_map = world.World.init(gpa), .generator = generator };
}

pub fn attach(self: *Level) void {
    self.world_map.entity_io = self.entities.entityIo();
    self.world_map.entity_probe = .{ .context = self, .anyInBox = probeAnyInBox };
}

fn probeAnyInBox(context: *anyopaque, min: [3]f64, max: [3]f64, living_only: bool) bool {
    const self: *Level = @ptrCast(@alignCast(context));
    const box = math.Aabb.init(min[0], min[1], min[2], max[0], max[1], max[2]);
    for (self.occupants.items) |occupant| {
        if (occupant.active and occupant.player.base.boundingBox().intersects(box)) return true;
    }
    return self.entities.anyInBox(box, living_only);
}

pub fn enter(self: *Level, gpa: std.mem.Allocator, player: *Player) !void {
    player.base.id = self.entities.takeId();
    try self.occupants.append(gpa, .{ .player = player });
    try self.roster.append(gpa, player);
    try self.views.append(gpa, Entities.viewOf(player));
}

pub fn leave(self: *Level, player: *const Player) void {
    for (self.occupants.items, 0..) |occupant, index| {
        if (occupant.player != player) continue;
        _ = self.occupants.orderedRemove(index);
        _ = self.roster.orderedRemove(index);
        _ = self.views.orderedRemove(index);
        return;
    }
}

pub fn setOccupantActive(self: *Level, active: bool) void {
    for (self.occupants.items) |*occupant| occupant.active = active;
}

fn refreshViews(self: *Level) void {
    for (self.occupants.items, self.views.items) |occupant, *view| {
        view.* = Entities.viewOf(occupant.player);
    }
}

pub fn deinit(self: *Level, gpa: std.mem.Allocator) void {
    self.entities.deinit(gpa);
    self.world_map.deinit();
    self.generator.deinit(gpa);
    self.occupants.deinit(gpa);
    self.roster.deinit(gpa);
    self.views.deinit(gpa);
}

pub fn closeWorld(self: *Level, gpa: std.mem.Allocator) void {
    self.world_map.persistence = null;
    const rand = self.world_map.rand;
    self.world_map.deinit();
    self.world_map = world.World.init(gpa);
    self.world_map.rand = rand;
    self.entities.deinit(gpa);
    self.entities = .{};
    self.occupants.clearRetainingCapacity();
    self.roster.clearRetainingCapacity();
    self.views.clearRetainingCapacity();
    self.attach();
}

pub fn reseed(self: *Level, gpa: std.mem.Allocator, dimension: world.Dimension, seed: i64) !void {
    self.generator.deinit(gpa);
    self.generator = try world.Generator.init(gpa, dimension, seed);
}

pub fn dropStackAt(self: *Level, gpa: std.mem.Allocator, x: i32, y: i32, z: i32, stack: Inventory.ItemStack) !void {
    try self.entities.dropStack(gpa, x, y, z, stack, &self.world_map.rand);
}

pub fn applyBlockChanges(self: *Level, gpa: std.mem.Allocator, scratch: std.mem.Allocator) !void {
    const width = world.Chunk.width;
    var columns: std.AutoHashMapUnmanaged(world.World.ChunkCoord, void) = .{};
    defer columns.deinit(scratch);

    for (self.world_map.changed.items) |pos| {
        const chunk_x = @divFloor(pos.x, width);
        const chunk_z = @divFloor(pos.z, width);
        const local_x = @mod(pos.x, width);
        const local_z = @mod(pos.z, width);

        try columns.put(scratch, .{ .x = chunk_x, .z = chunk_z }, {});
        if (local_x == 0) try columns.put(scratch, .{ .x = chunk_x - 1, .z = chunk_z }, {});
        if (local_x == width - 1) try columns.put(scratch, .{ .x = chunk_x + 1, .z = chunk_z }, {});
        if (local_z == 0) try columns.put(scratch, .{ .x = chunk_x, .z = chunk_z - 1 }, {});
        if (local_z == width - 1) try columns.put(scratch, .{ .x = chunk_x, .z = chunk_z + 1 }, {});
    }
    self.world_map.changed.clearRetainingCapacity();

    var it = columns.keyIterator();
    while (it.next()) |coord| try world.light.relightChunk(gpa, &self.world_map, coord.x, coord.z);

    for (self.world_map.dropped.items) |drop| {
        try self.dropStackAt(gpa, drop.pos.x, drop.pos.y, drop.pos.z, .{
            .id = drop.stack.id,
            .count = drop.stack.count,
            .meta = drop.stack.meta,
        });
    }
    self.world_map.dropped.clearRetainingCapacity();

    for (self.world_map.falling.items) |fall| {
        try self.entities.spawnFallingBlock(gpa, fall.pos.x, fall.pos.y, fall.pos.z, fall.id);
    }
    self.world_map.falling.clearRetainingCapacity();

    for (self.world_map.primed.items) |lit| {
        try self.entities.primeTnt(gpa, lit, &self.world_map.rand);
    }
    self.world_map.primed.clearRetainingCapacity();

    for (self.world_map.dispensed.items) |shot| {
        try self.entities.dispense(gpa, shot, &self.world_map.rand);
    }
    self.world_map.dispensed.clearRetainingCapacity();
}

fn tickBoats(self: *Level, gpa: std.mem.Allocator, rand: *world.JavaRandom) !void {
    var rider: ?Entities.BoatRider = null;
    for (self.roster.items) |player| {
        if (player.riding == Animal.Entity.no_id) continue;
        rider = .{ .id = player.riding, .motion = player.ride_input };
        break;
    }

    try self.entities.tickBoats(gpa, &self.world_map, rider, rand);

    for (self.roster.items) |player| {
        if (player.riding == Animal.Entity.no_id) continue;
        const boat = self.entities.boatById(player.riding) orelse continue;
        player.base.position = boat.riderPosition();
        player.base.prev_position = player.base.position;
        player.base.motion = math.Vec3.init(0, 0, 0);
    }
}

fn dropStaleRides(self: *Level) void {
    for (self.roster.items) |player| {
        if (player.riding == Animal.Entity.no_id) continue;
        if (self.entities.boatById(player.riding) != null) continue;
        if (self.entities.minecartById(player.riding)) |cart| {
            cart.rider = player.base.id;
            continue;
        }
        if (self.entities.mobById(player.riding)) |mount| {
            if (mount.animal.isAlive()) {
                player.base.position = mountedSeat(mount.animal);
                player.base.prev_position = player.base.position;
                player.base.motion = math.Vec3.init(0, 0, 0);
                continue;
            }
        }
        player.riding = Animal.Entity.no_id;
    }
}

fn seatMobRiders(self: *Level) void {
    for (self.entities.mobs.items) |entry| {
        const mount_id = entry.animal.riding;
        if (mount_id == Animal.Entity.no_id) continue;
        if (self.entities.minecartById(mount_id) != null) continue;

        const mount = self.entities.mobById(mount_id) orelse {
            entry.animal.riding = Animal.Entity.no_id;
            continue;
        };
        if (!mount.animal.isAlive()) {
            entry.animal.riding = Animal.Entity.no_id;
            continue;
        }

        entry.animal.base.position = mountedSeat(mount.animal);
        entry.animal.base.motion = math.Vec3.init(0, 0, 0);
    }
}

fn mountedSeat(animal: *const Animal) math.Vec3 {
    return math.Vec3.init(
        animal.base.position.x,
        animal.base.position.y + animal.base.height * mounted_fraction,
        animal.base.position.z,
    );
}

fn tickMinecarts(self: *Level, gpa: std.mem.Allocator, rand: *world.JavaRandom) !void {
    try self.entities.tickMinecarts(gpa, &self.world_map, self.roster.items, rand);

    for (self.roster.items) |player| {
        if (player.riding == Animal.Entity.no_id) continue;
        const cart = self.entities.minecartById(player.riding) orelse continue;
        player.base.position = cart.riderPosition();
        player.base.prev_position = player.base.position;
        player.base.motion = math.Vec3.init(0, 0, 0);
    }

    for (self.entities.minecarts.items) |*cart| {
        if (cart.rider == Animal.Entity.no_id) continue;
        const entry = self.entities.mobById(cart.rider) orelse continue;
        if (!entry.animal.isAlive()) {
            entry.animal.riding = Animal.Entity.no_id;
            cart.rider = Animal.Entity.no_id;
            continue;
        }
        entry.animal.base.position = cart.riderPosition();
        entry.animal.base.prev_position = entry.animal.base.position;
        entry.animal.base.motion = math.Vec3.init(0, 0, 0);
    }
}

fn tickFallingBlocks(self: *Level, gpa: std.mem.Allocator) !void {
    var index: usize = 0;
    while (index < self.entities.falling_blocks.items.len) {
        const block = &self.entities.falling_blocks.items[index];
        const outcome = block.tick(&self.world_map);

        if (outcome == .falling) {
            index += 1;
            continue;
        }

        const x: i32 = @intFromFloat(@floor(block.base.position.x));
        const y: i32 = @intFromFloat(@floor(block.base.position.y));
        const z: i32 = @intFromFloat(@floor(block.base.position.z));

        const landing_empty = !self.world_map.getBlock(x, y, z).isSolid();
        const support_solid = !self.world_map.getBlock(x, y - 1, z).canFallInto();
        if (outcome == .landed and landing_empty and support_solid) {
            try self.world_map.setBlockWithNotify(x, y, z, block.block_id);
        } else {
            try self.dropStackAt(gpa, x, y, z, .{ .id = .{ .block = block.block_id }, .count = 1 });
        }

        _ = self.entities.falling_blocks.swapRemove(index);
    }
}

fn collideWithBlocks(self: *Level, box: math.Aabb) !void {
    var cells = physics.touchedCells(box);
    while (cells.next()) |cell| {
        try world.redstone.onEntityCollided(&self.world_map, cell[0], cell[1], cell[2]);
    }
}

pub fn allPlayersFullyAsleep(self: *const Level) bool {
    if (self.occupants.items.len == 0) return false;
    for (self.occupants.items) |occupant| {
        if (!occupant.player.isFullyAsleep()) return false;
    }
    return true;
}

pub fn wakeUpAllPlayers(self: *Level) !void {
    for (self.occupants.items) |occupant| {
        if (occupant.player.sleeping) try occupant.player.wakeUp(&self.world_map, false, true);
    }
    self.world_map.weather.clear();
}

pub fn standInPortals(self: *Level) void {
    for (self.occupants.items) |occupant| {
        if (!occupant.active) continue;
        if (physics.touchesBlock(&self.world_map, occupant.player.base.boundingBox(), .portal)) occupant.player.setInPortal();
    }
}

fn walkOnBlocks(self: *Level) !void {
    for (self.occupants.items) |occupant| {
        const stepped = occupant.player.stepped_on orelse continue;
        occupant.player.stepped_on = null;
        if (!occupant.active) continue;
        try world.farming.trample(&self.world_map, stepped[0], stepped[1], stepped[2]);
    }
}

fn pressPressurePlates(self: *Level) !void {
    for (self.occupants.items) |occupant| {
        if (occupant.active) try self.collideWithBlocks(occupant.player.base.boundingBox());
    }
    for (self.entities.mobs.items) |entry| try self.collideWithBlocks(entry.animal.base.boundingBox());
    for (self.entities.items.items) |*dropped| try self.collideWithBlocks(dropped.base.boundingBox());
}

fn playerChunkCoord(player: *const Player) world.World.ChunkCoord {
    const x: i32 = @intFromFloat(@floor(player.base.position.x));
    const z: i32 = @intFromFloat(@floor(player.base.position.z));
    return .{
        .x = @divFloor(x, world.Chunk.width),
        .z = @divFloor(z, world.Chunk.width),
    };
}

fn advanceTime(self: *Level) !void {
    self.world_map.time += 1;

    const subtracted = self.world_map.calculateSkylightSubtracted(1.0);
    if (subtracted != self.world_map.skylight_subtracted) {
        self.world_map.skylight_subtracted = subtracted;
        try self.world_map.updateAllRenderers();
    }
}

pub fn tick(self: *Level, gpa: std.mem.Allocator, scratch: std.mem.Allocator) !void {
    if (self.occupants.items.len == 0) return;
    const rand = &self.world_map.rand;
    self.tick_count += 1;
    self.refreshViews();

    try self.tickBoats(gpa, rand);
    try self.tickMinecarts(gpa, rand);
    self.dropStaleRides();
    try self.entities.tickHooks(gpa, &self.world_map, self.roster.items, rand);
    try self.entities.tickArrows(gpa, &self.world_map, self.roster.items, rand);
    try self.entities.tickFireballs(gpa, &self.world_map, self.roster.items, rand);
    try self.entities.tickThrownEggs(gpa, &self.world_map, self.roster.items, rand);
    try self.entities.tickItems(gpa, &self.world_map, self.roster.items, rand);
    try self.entities.tickPrimed(gpa, &self.world_map, self.roster.items, rand);
    try self.tickFallingBlocks(gpa);

    self.world_map.tickWeather();
    for (self.roster.items) |player| {
        const center = playerChunkCoord(player);
        try self.world_map.tickRandomBlocks(center.x, center.z);
    }
    for (self.world_map.takeStrikes()) |strike| {
        try self.entities.strikeLightning(gpa, &self.world_map, .{
            .x = @floatFromInt(strike.x),
            .y = @floatFromInt(strike.y),
            .z = @floatFromInt(strike.z),
        }, rand);
    }
    self.world_map.clearStrikes();
    try self.entities.tickLightning(gpa, &self.world_map, self.roster.items, rand);
    try self.walkOnBlocks();
    try self.pressPressurePlates();
    self.standInPortals();
    try self.world_map.tickUpdates();
    try self.world_map.tickFurnaces();
    try self.world_map.spillOrphanChests();
    try self.world_map.spillOrphanJukeboxes();
    try self.world_map.forgetOrphanNotes();
    try self.world_map.spillOrphanDispensers();
    try self.world_map.tickPistons();
    try self.entities.applyPistonShoves(&self.world_map, self.roster.items);
    try self.applyBlockChanges(gpa, scratch);
    self.refreshViews();
    try self.entities.tickMobs(gpa, &self.world_map, self.roster.items, self.players(), rand);
    self.seatMobRiders();

    if (self.allPlayersFullyAsleep()) {
        const disturbed = self.world_map.difficulty.atLeast(.easy) and
            try spawner.performSleepSpawning(gpa, &self.entities, &self.world_map, self.roster.items, rand);
        if (!disturbed) {
            self.world_map.skipToDawn();
            try self.wakeUpAllPlayers();
        }
    }

    _ = try spawner.performSpawning(
        gpa,
        &self.entities,
        &self.world_map,
        self.views.items,
        self.spawn,
        self.generator.dimension(),
        self.generator.worldSeed(),
        rand,
    );

    try self.entities.tickPaintings(gpa, &self.world_map, rand);
    self.entities.stampIds();
    try self.advanceTime();
}

fn testLevel(gpa: std.mem.Allocator) !Level {
    var level = Level.init(gpa, try world.Generator.init(gpa, .overworld, 1));
    errdefer level.deinit(gpa);

    var chunk_x: i32 = -1;
    while (chunk_x <= 1) : (chunk_x += 1) {
        var chunk_z: i32 = -1;
        while (chunk_z <= 1) : (chunk_z += 1) {
            const chunk = try level.world_map.createChunk(chunk_x, chunk_z);
            for (0..world.Chunk.width) |x| {
                for (0..world.Chunk.width) |z| {
                    chunk.setBlock(@intCast(x), 0, @intCast(z), .stone);
                    chunk.setSkyLight(@intCast(x), 1, @intCast(z), 15);
                }
            }
        }
    }
    return level;
}

fn enterLevel(gpa: std.mem.Allocator, level: *Level, player: *Player) !void {
    level.attach();
    try level.enter(gpa, player);
}

test "a level tick advances the world clock and its own tick count" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var level = try testLevel(gpa);
    defer level.deinit(gpa);

    var player = Player.spawn(math.Vec3.init(8.5, 1, 8.5));
    try enterLevel(gpa, &level, &player);

    const before = level.world_map.time;
    try level.tick(gpa, arena.allocator());

    try std.testing.expectEqual(@as(u64, 1), level.tick_count);
    try std.testing.expectEqual(before + 1, level.world_map.time);
}

test "a level tick moves the mobs standing in it" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var level = try testLevel(gpa);
    defer level.deinit(gpa);

    var player = Player.spawn(math.Vec3.init(8.5, 1, 8.5));
    try enterLevel(gpa, &level, &player);
    try level.entities.spawnPig(gpa, math.Vec3.init(8.5, 8, 8.5));

    const pig = level.entities.mobs.items[0].animal;
    const started = pig.base.position.y;
    for (0..5) |_| try level.tick(gpa, arena.allocator());

    try std.testing.expect(pig.base.position.y < started);
}

const Recorder = struct {
    gpa: std.mem.Allocator,
    blocks: std.ArrayList(world.World.BlockPos) = .empty,
    redraws: u32 = 0,

    fn deinit(self: *Recorder) void {
        self.blocks.deinit(self.gpa);
    }

    fn access(self: *Recorder) world.World.Access {
        return .{
            .context = self,
            .markBlockNeedsUpdate = mark,
            .updateAllRenderers = redraw,
        };
    }

    fn mark(context: *anyopaque, x: i32, y: i32, z: i32) std.mem.Allocator.Error!void {
        const self: *Recorder = @ptrCast(@alignCast(context));
        try self.blocks.append(self.gpa, .{ .x = x, .y = y, .z = z });
    }

    fn redraw(context: *anyopaque) std.mem.Allocator.Error!void {
        const self: *Recorder = @ptrCast(@alignCast(context));
        self.redraws += 1;
    }

    fn sawBlockAt(self: *const Recorder, x: i32, y: i32, z: i32) bool {
        for (self.blocks.items) |pos| {
            if (pos.x == x and pos.y == y and pos.z == z) return true;
        }
        return false;
    }
};

test "the world access hears about a block change the moment it is made" {
    const gpa = std.testing.allocator;
    var level = try testLevel(gpa);
    defer level.deinit(gpa);

    var recorder: Recorder = .{ .gpa = gpa };
    defer recorder.deinit();
    level.world_map.access = recorder.access();

    try level.world_map.setBlockWithNotify(4, 0, 4, .air);

    try std.testing.expect(recorder.sawBlockAt(4, 0, 4));
}

test "a block broken during the tick reaches the world access" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var level = try testLevel(gpa);
    defer level.deinit(gpa);

    var player = Player.spawn(math.Vec3.init(8.5, 1, 8.5));
    try enterLevel(gpa, &level, &player);

    var recorder: Recorder = .{ .gpa = gpa };
    defer recorder.deinit();
    level.world_map.access = recorder.access();

    try level.world_map.setBlockWithNotify(4, 0, 4, .air);
    try level.tick(gpa, arena.allocator());

    try std.testing.expect(recorder.sawBlockAt(4, 0, 4));
    try std.testing.expectEqual(@as(usize, 0), level.world_map.changed.items.len);
}

test "a level with no world access attached still ticks" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var level = try testLevel(gpa);
    defer level.deinit(gpa);

    var player = Player.spawn(math.Vec3.init(8.5, 1, 8.5));
    try enterLevel(gpa, &level, &player);

    try std.testing.expect(level.world_map.access == null);
    try level.world_map.setBlockWithNotify(4, 0, 4, .air);
    try level.tick(gpa, arena.allocator());

    try std.testing.expectEqual(world.Block.air, level.world_map.getBlock(4, 0, 4));
}

test "the light crossing a step asks the front end to redraw everything" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var level = try testLevel(gpa);
    defer level.deinit(gpa);

    var player = Player.spawn(math.Vec3.init(8.5, 1, 8.5));
    try enterLevel(gpa, &level, &player);

    var stepped: i64 = 1;
    while (stepped < world.World.ticks_per_day) : (stepped += 1) {
        level.world_map.setTime(stepped - 1);
        const before = level.world_map.calculateSkylightSubtracted(1.0);
        level.world_map.setTime(stepped);
        if (level.world_map.calculateSkylightSubtracted(1.0) != before) break;
    }
    try std.testing.expect(stepped < world.World.ticks_per_day);

    level.world_map.setTime(stepped - 1);
    level.world_map.skylight_subtracted = level.world_map.calculateSkylightSubtracted(1.0);

    var recorder: Recorder = .{ .gpa = gpa };
    defer recorder.deinit();
    level.world_map.access = recorder.access();

    try level.tick(gpa, arena.allocator());
    try std.testing.expectEqual(@as(u32, 1), recorder.redraws);

    try level.tick(gpa, arena.allocator());
    try std.testing.expectEqual(@as(u32, 1), recorder.redraws);
}

test "lit tnt becomes an entity, burns down its fuse and blows a hole in the ground" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var level = try testLevel(gpa);
    defer level.deinit(gpa);

    var player = Player.spawn(math.Vec3.init(8.5, 1, 8.5));
    try enterLevel(gpa, &level, &player);

    try level.world_map.setBlockWithNotify(4, 1, 4, .tnt);
    try level.world_map.setBlockWithNotify(4, 1, 4, .air);
    try world.tnt.primeByPlayer(&level.world_map, 4, 1, 4);

    try level.tick(gpa, arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), level.entities.primed.items.len);
    try std.testing.expectEqual(@as(usize, 0), level.world_map.primed.items.len);

    for (0..world.tnt.fuse_ticks + 2) |_| {
        try level.tick(gpa, arena.allocator());
        if (level.entities.primed.items.len == 0) break;
    }

    try std.testing.expectEqual(@as(usize, 0), level.entities.primed.items.len);
    try std.testing.expectEqual(world.Block.air, level.world_map.getBlock(4, 0, 4));
}

test "a stick of tnt caught in a blast is lit rather than smashed" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var level = try testLevel(gpa);
    defer level.deinit(gpa);

    var player = Player.spawn(math.Vec3.init(8.5, 1, 8.5));
    try enterLevel(gpa, &level, &player);

    try level.world_map.setBlockWithNotify(4, 1, 4, .tnt);
    try level.world_map.setBlockWithNotify(6, 1, 4, .tnt);
    try level.world_map.setBlockWithNotify(6, 1, 4, .air);
    try world.tnt.primeByPlayer(&level.world_map, 6, 1, 4);

    for (0..world.tnt.fuse_ticks + 2) |_| {
        try level.tick(gpa, arena.allocator());
        if (level.world_map.getBlock(4, 1, 4) != .tnt) break;
    }

    try std.testing.expectEqual(world.Block.air, level.world_map.getBlock(4, 1, 4));
    try std.testing.expectEqual(@as(usize, 1), level.entities.primed.items.len);
    for (level.entities.items.items) |dropped| {
        try std.testing.expect(!dropped.stack.id.eql(.{ .block = .tnt }));
    }
}

test "a falling block that lands becomes a block again" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var level = try testLevel(gpa);
    defer level.deinit(gpa);

    var player = Player.spawn(math.Vec3.init(8.5, 1, 8.5));
    try enterLevel(gpa, &level, &player);
    try level.entities.spawnFallingBlock(gpa, 4, 6, 4, .sand);

    for (0..60) |_| {
        try level.tick(gpa, arena.allocator());
        if (level.entities.falling_blocks.items.len == 0) break;
    }

    try std.testing.expectEqual(@as(usize, 0), level.entities.falling_blocks.items.len);
    try std.testing.expectEqual(world.Block.sand, level.world_map.getBlock(4, 1, 4));
}

test "an inactive occupant does not stand on pressure plates" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var level = try testLevel(gpa);
    defer level.deinit(gpa);

    try level.world_map.setBlockWithNotify(8, 1, 8, .pressure_plate_stone);

    var player = Player.spawn(math.Vec3.init(8.5, 1, 8.5));
    try enterLevel(gpa, &level, &player);
    level.setOccupantActive(false);
    try level.tick(gpa, arena.allocator());
    level.setOccupantActive(true);
    try std.testing.expectEqual(@as(u4, 0), level.world_map.getBlockMetadata(8, 1, 8));

    try level.tick(gpa, arena.allocator());
    try std.testing.expectEqual(@as(u4, 1), level.world_map.getBlockMetadata(8, 1, 8));
}

test "closing a world empties it but keeps the random stream running" {
    const gpa = std.testing.allocator;
    var level = try testLevel(gpa);
    defer level.deinit(gpa);

    try level.entities.spawnPig(gpa, math.Vec3.init(8.5, 1, 8.5));
    _ = level.world_map.rand.nextInt();
    const carried = level.world_map.rand;

    level.closeWorld(gpa);

    try std.testing.expectEqual(@as(usize, 0), level.entities.mobs.items.len);
    try std.testing.expect(level.world_map.getChunk(0, 0) == null);
    try std.testing.expectEqual(carried, level.world_map.rand);
}

test "a level ticks for every player standing in it" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var level = try testLevel(gpa);
    defer level.deinit(gpa);
    level.attach();

    var first = Player.spawn(math.Vec3.init(4.5, 1, 4.5));
    var second = Player.spawn(math.Vec3.init(12.5, 1, 12.5));
    try level.enter(gpa, &first);
    try level.enter(gpa, &second);

    try std.testing.expect(first.base.id != second.base.id);
    try std.testing.expectEqual(@as(usize, 2), level.players().views.len);

    try level.tick(gpa, arena.allocator());

    try std.testing.expectEqual(@as(u64, 1), level.tick_count);
    try std.testing.expectEqual(first.base.id, level.players().views[0].id);
    try std.testing.expectEqual(second.base.id, level.players().views[1].id);
}

test "a player who leaves is dropped from the roster and its views" {
    const gpa = std.testing.allocator;
    var level = try testLevel(gpa);
    defer level.deinit(gpa);
    level.attach();

    var first = Player.spawn(math.Vec3.init(4.5, 1, 4.5));
    var second = Player.spawn(math.Vec3.init(12.5, 1, 12.5));
    try level.enter(gpa, &first);
    try level.enter(gpa, &second);

    level.leave(&first);

    try std.testing.expectEqual(@as(usize, 1), level.occupants.items.len);
    try std.testing.expectEqual(@as(usize, 1), level.roster.items.len);
    try std.testing.expectEqual(second.base.id, level.players().views[0].id);
    try std.testing.expectEqual(&second, level.roster.items[0]);
}

test "the views a level hands its mobs follow the players as they move" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var level = try testLevel(gpa);
    defer level.deinit(gpa);
    level.attach();

    var player = Player.spawn(math.Vec3.init(4.5, 1, 4.5));
    try level.enter(gpa, &player);

    player.base.position = math.Vec3.init(9.5, 1, 9.5);
    try level.tick(gpa, arena.allocator());

    try std.testing.expectApproxEqAbs(@as(f64, 9.5), level.players().views[0].position.x, 1.0e-9);
}

test "a level with nobody in it does not tick" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var level = try testLevel(gpa);
    defer level.deinit(gpa);
    level.attach();

    try level.tick(gpa, arena.allocator());
    try std.testing.expectEqual(@as(u64, 0), level.tick_count);
}

fn lightPortalAt(level: *Level, x: i32, y: i32, z: i32) !void {
    var across: i32 = -1;
    while (across <= 2) : (across += 1) {
        var up: i32 = -1;
        while (up <= 3) : (up += 1) {
            const on_frame = across == -1 or across == 2 or up == -1 or up == 3;
            const corner = (across == -1 or across == 2) and (up == -1 or up == 3);
            if (!on_frame or corner) continue;
            level.world_map.setBlock(x + across, y + up, z, .obsidian);
        }
    }
    try std.testing.expect(try world.portal.tryCreate(&level.world_map, x, y, z));
}

test "a player standing in a portal is marked for travel, and one beside it is not" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var level = try testLevel(gpa);
    defer level.deinit(gpa);
    try lightPortalAt(&level, 8, 1, 8);

    var player = Player.spawn(math.Vec3.init(8.5, 1, 8.5));
    player.time_until_portal = 0;
    try enterLevel(gpa, &level, &player);

    try level.tick(gpa, arena.allocator());
    try std.testing.expect(player.in_portal);

    player.in_portal = false;
    player.base.position = math.Vec3.init(12.5, 1, 12.5);
    try level.tick(gpa, arena.allocator());
    try std.testing.expect(!player.in_portal);
}

test "an inactive occupant does not walk into portals either" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var level = try testLevel(gpa);
    defer level.deinit(gpa);
    try lightPortalAt(&level, 8, 1, 8);

    var player = Player.spawn(math.Vec3.init(8.5, 1, 8.5));
    player.time_until_portal = 0;
    try enterLevel(gpa, &level, &player);
    level.setOccupantActive(false);

    try level.tick(gpa, arena.allocator());
    try std.testing.expect(!player.in_portal);
}

test "the nether spawns none of the overworld's animals" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var level = Level.init(gpa, try world.Generator.init(gpa, .nether, 1));
    defer level.deinit(gpa);

    var chunk_x: i32 = -1;
    while (chunk_x <= 1) : (chunk_x += 1) {
        var chunk_z: i32 = -1;
        while (chunk_z <= 1) : (chunk_z += 1) {
            const chunk = try level.world_map.createChunk(chunk_x, chunk_z);
            for (0..world.Chunk.width) |x| {
                for (0..world.Chunk.width) |z| {
                    chunk.setBlock(@intCast(x), 0, @intCast(z), .netherrack);
                }
            }
        }
    }

    var player = Player.spawn(math.Vec3.init(8.5, 1, 8.5));
    try enterLevel(gpa, &level, &player);

    for (0..200) |_| try level.tick(gpa, arena.allocator());

    try std.testing.expectEqual(@as(usize, 0), level.entities.animalCount());
}

test "a jockey's skeleton is carried on its spider's back every tick" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var level = try testLevel(gpa);
    defer level.deinit(gpa);

    var player = Player.spawn(math.Vec3.init(8.5, 1, 8.5));
    try enterLevel(gpa, &level, &player);
    try level.entities.spawnSpider(gpa, math.Vec3.init(4.5, 6, 4.5));
    try level.entities.spawnSkeleton(gpa, math.Vec3.init(4.5, 6, 4.5));

    const spider = level.entities.mobs.items[0].animal;
    const skeleton = level.entities.mobs.items[1].animal;
    skeleton.riding = spider.base.id;

    for (0..10) |_| {
        try level.tick(gpa, arena.allocator());
        try std.testing.expectEqual(mountedSeat(spider), skeleton.base.position);
    }
}

test "a jockey steps off when its spider dies, and stays where it was let down" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var level = try testLevel(gpa);
    defer level.deinit(gpa);

    var player = Player.spawn(math.Vec3.init(8.5, 1, 8.5));
    try enterLevel(gpa, &level, &player);
    try level.entities.spawnSpider(gpa, math.Vec3.init(4.5, 6, 4.5));
    try level.entities.spawnSkeleton(gpa, math.Vec3.init(4.5, 6, 4.5));

    const spider = level.entities.mobs.items[0].animal;
    const skeleton = level.entities.mobs.items[1].animal;
    skeleton.riding = spider.base.id;
    try level.tick(gpa, arena.allocator());

    const seat = skeleton.base.position;
    spider.health = 0;
    try level.tick(gpa, arena.allocator());

    try std.testing.expectEqual(Animal.Entity.no_id, skeleton.riding);
    try std.testing.expect(skeleton.base.position.y <= seat.y);
}
