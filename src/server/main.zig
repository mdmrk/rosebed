const std = @import("std");

const core = @import("core");
const game = @import("game");
const net = @import("net");
const world = @import("world");
const BlockPos = world.BlockPos;
const chunk_payload = world.chunk_payload;

const Session = @import("Session.zig");

pub const default_port: u16 = 25565;
pub const ticks_per_second: u32 = 20;
pub const read_buffer_len: usize = 64 * 1024;
pub const write_buffer_len: usize = 64 * 1024;
pub const outgoing_high_water: usize = 4 * 1024 * 1024;
pub const autosave_interval_ticks: u64 = 900;
pub const save_chunks_per_pass: usize = 64;

// Vanilla's dedicated server has no difficulty setting of its own: it derives one from
// spawn-monsters, landing on easy or peaceful and never anything harder.
pub const default_difficulty: world.Difficulty = .easy;

pub const Options = struct {
    port: u16 = default_port,
    folder: []const u8 = "world",
    seed: ?i64 = null,
    ticks: ?u64 = null,
    difficulty: world.Difficulty = default_difficulty,
};

pub fn parseArgs(args: []const [:0]const u8) !Options {
    var options: Options = .{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--port") and index + 1 < args.len) {
            index += 1;
            options.port = try std.fmt.parseInt(u16, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--world") and index + 1 < args.len) {
            index += 1;
            options.folder = args[index];
        } else if (std.mem.eql(u8, arg, "--seed") and index + 1 < args.len) {
            index += 1;
            options.seed = try std.fmt.parseInt(i64, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--ticks") and index + 1 < args.len) {
            index += 1;
            options.ticks = try std.fmt.parseInt(u64, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--difficulty") and index + 1 < args.len) {
            index += 1;
            options.difficulty = std.meta.stringToEnum(world.Difficulty, args[index]) orelse
                return error.UnknownArgument;
        } else {
            return error.UnknownArgument;
        }
    }
    return options;
}

fn monotonicNs(io: std.Io) u64 {
    const stamp = std.Io.Clock.now(.awake, io);
    return @intCast(@max(stamp.nanoseconds, 0));
}

const Connection = struct {
    stream: std.Io.net.Stream,
    session: Session = .{},
    pending: std.ArrayList(net.packet.Packet) = .empty,
    outgoing: std.ArrayList(u8) = .empty,
    open: bool = true,
    reader_thread: ?std.Thread = null,
    writer_thread: ?std.Thread = null,

    fn deinit(self: *Connection, gpa: std.mem.Allocator) void {
        self.session.deinit(gpa);
        for (self.pending.items) |message| message.deinit(gpa);
        self.pending.deinit(gpa);
        self.outgoing.deinit(gpa);
    }
};

pub const nether_id_base: game.Entity.Id = 1 << 24;

const Dim = struct {
    server: *Server = undefined,
    dimension: world.Dimension,
    level: game.Level,
    handle: world.save.Save,
};

const Server = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    dims: [2]Dim,
    connections: std.ArrayList(*Connection) = .empty,
    retired: std.ArrayList(*Connection) = .empty,
    mutex: std.Io.Mutex = .init,
    running: std.atomic.Value(bool) = .init(true),
    tick_count: u64 = 0,
    ticks_since_save: u64 = 0,

    fn lock(self: *Server) void {
        self.mutex.lockUncancelable(self.io);
    }

    fn unlock(self: *Server) void {
        self.mutex.unlock(self.io);
    }

    fn adopt(self: *Server, connection: *Connection) !void {
        self.lock();
        defer self.unlock();
        try self.connections.append(self.gpa, connection);
    }

    fn dimOf(self: *Server, which: world.Dimension) *Dim {
        for (&self.dims) |*dim| {
            if (dim.dimension == which) return dim;
        }
        return &self.dims[0];
    }

    fn overworld(self: *Server) *game.Level {
        return &self.dimOf(.overworld).level;
    }

    fn levelFor(self: *Server, connection: *Connection) *game.Level {
        return &self.dimOf(connection.session.dimension).level;
    }
};

fn worldAccess(dim: *Dim) world.World.Access {
    return .{
        .context = dim,
        .markBlockNeedsUpdate = markBlockNeedsUpdate,
        .updateAllRenderers = updateAllRenderers,
    };
}

fn markBlockNeedsUpdate(context: *anyopaque, pos: BlockPos) std.mem.Allocator.Error!void {
    const dim: *Dim = @ptrCast(@alignCast(context));
    if (pos.y < 0 or pos.y >= world.Chunk.height) return;

    const block = dim.level.world_map.getBlock(pos);
    const metadata = dim.level.world_map.getBlockMetadata(pos);

    for (dim.server.connections.items) |connection| {
        if (connection.session.dimension != dim.dimension) continue;
        connection.session.sendBlockChange(dim.server.gpa, pos, block, metadata) catch |err| switch (err) {
            error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
            error.StringTooLong, error.InvalidUtf8 => unreachable,
        };
    }
}

fn updateAllRenderers(_: *anyopaque) std.mem.Allocator.Error!void {}

fn playNote(
    context: *anyopaque,
    pos: BlockPos,
    instrument: world.note.Instrument,
    pitch: u8,
) void {
    const dim: *Dim = @ptrCast(@alignCast(context));
    for (dim.server.connections.items) |connection| {
        if (connection.session.dimension != dim.dimension) continue;
        connection.session.sendNote(dim.server.gpa, pos, instrument, pitch) catch {};
    }
}

fn noteSink(dim: *Dim) world.World.NoteSink {
    return .{ .context = dim, .playNote = playNote };
}

fn readLoop(server: *Server, connection: *Connection) void {
    var buffer: [read_buffer_len]u8 = undefined;
    var reader = connection.stream.reader(server.io, &buffer);

    while (server.running.load(.acquire)) {
        const packet_id = net.packet.readId(&reader.interface) catch break;
        if (!net.packet.direction(packet_id).to_server) break;

        const message = net.packet.readBody(server.gpa, &reader.interface, packet_id) catch break;

        server.lock();
        connection.pending.append(server.gpa, message) catch {
            server.unlock();
            message.deinit(server.gpa);
            break;
        };
        server.unlock();
    }

    server.lock();
    connection.open = false;
    server.unlock();
}

fn writeLoop(server: *Server, connection: *Connection) void {
    var buffer: [write_buffer_len]u8 = undefined;
    var writer = connection.stream.writer(server.io, &buffer);

    while (true) {
        server.lock();
        const open = connection.open;
        const bytes = connection.outgoing.toOwnedSlice(server.gpa) catch &.{};
        server.unlock();

        defer server.gpa.free(bytes);

        if (bytes.len > 0) {
            writer.interface.writeAll(bytes) catch break;
            writer.interface.flush() catch break;
            continue;
        }

        if (!open or !server.running.load(.acquire)) break;
        std.Io.sleep(server.io, .{ .nanoseconds = std.time.ns_per_ms }, .awake) catch {};
    }

    server.lock();
    connection.open = false;
    server.unlock();
}

fn acceptLoop(server: *Server, listener: *std.Io.net.Server) void {
    while (server.running.load(.acquire)) {
        const stream = listener.accept(server.io) catch break;

        const connection = server.gpa.create(Connection) catch {
            stream.close(server.io);
            continue;
        };
        connection.* = .{ .stream = stream };

        server.adopt(connection) catch {
            connection.deinit(server.gpa);
            server.gpa.destroy(connection);
            stream.close(server.io);
            continue;
        };

        connection.reader_thread = std.Thread.spawn(.{}, readLoop, .{ server, connection }) catch null;
        connection.writer_thread = std.Thread.spawn(.{}, writeLoop, .{ server, connection }) catch null;
        if (connection.reader_thread == null or connection.writer_thread == null) {
            server.lock();
            connection.open = false;
            server.unlock();
        }
    }
}

fn drainPending(server: *Server, connection: *Connection) !void {
    for (connection.pending.items) |message| {
        defer message.deinit(server.gpa);
        try connection.session.handle(server.gpa, server.levelFor(connection), message);
    }
    connection.pending.clearRetainingCapacity();
}

fn queueOutbox(server: *Server, connection: *Connection) !void {
    const bytes = try connection.session.takeOutbox(server.gpa);
    defer server.gpa.free(bytes);
    if (bytes.len == 0) return;
    try connection.outgoing.appendSlice(server.gpa, bytes);
}

fn findSpawn(level: *game.Level) ![3]i32 {
    try level.world_map.ensureDecorated(&level.generator, 0, 0);

    var y: i32 = world.Chunk.height - 2;
    while (y > 0) : (y -= 1) {
        if (!level.world_map.getBlock(.init(8, y, 8)).isSolid()) continue;
        return .{ 8, y + 1, 8 };
    }
    return .{ 8, 64, 8 };
}

fn saveWorld(server: *Server, name: []const u8) !void {
    const home = server.dimOf(.overworld);
    const info: world.save.LevelInfo = .{
        .seed = home.level.generator.worldSeed(),
        .spawn = home.level.spawn,
        .time = home.level.world_map.time,
        .raining = home.level.world_map.weather.raining,
        .rain_time = home.level.world_map.weather.rain_time,
        .thundering = home.level.world_map.weather.thundering,
        .thunder_time = home.level.world_map.weather.thunder_time,
        .last_played = world.RegionFile.unixMilliseconds(server.io),
        .size_on_disk = @intCast(home.handle.diskSize(server.io)),
        .name = @constCast(name),
    };
    try home.handle.writeLevel(server.gpa, server.io, info);

    for (&server.dims) |*dim| {
        try dim.level.world_map.saveDirtyMaps();
        try dim.level.world_map.beginSaveRound();
        while (try dim.level.world_map.saveQueuedChunks(save_chunks_per_pass) > 0) {}
    }
}

fn broadcastChat(server: *Server, line: []const u8) void {
    std.log.info("{s}", .{line});
    for (server.connections.items) |connection| {
        connection.session.sendChat(server.gpa, line) catch {};
    }
}

fn broadcastSwing(server: *Server, from: *Connection) void {
    const player = from.session.player orelse return;
    for (server.connections.items) |connection| {
        if (connection == from) continue;
        if (connection.session.dimension != from.session.dimension) continue;
        connection.session.sendSwing(server.gpa, player.base.id) catch {};
    }
}

fn broadcastSleep(server: *Server, from: *Connection, change: Session.SleepChange) void {
    const player = from.session.player orelse return;
    for (server.connections.items) |connection| {
        if (connection.session.dimension != from.session.dimension) continue;
        switch (change) {
            .lay_down => |bed| connection.session.sendSleep(server.gpa, player.base.id, bed) catch {},
            .wake_up => connection.session.sendWakeUp(server.gpa, player.base.id) catch {},
        }
    }
    if (change == .wake_up) from.session.sendPosition(server.gpa) catch {};
}

fn broadcastSign(server: *Server, which: world.Dimension, at: world.World.BlockPos) void {
    const dim = server.dimOf(which);
    const post = dim.level.world_map.signAt(at) orelse return;
    for (server.connections.items) |connection| {
        if (connection.session.dimension != which) continue;
        if (!connection.session.seesChunkAt(at.x, at.z)) continue;
        connection.session.sendSign(server.gpa, at, post) catch {};
    }
}

fn broadcastEquipment(server: *Server, from: *Connection) void {
    const player = from.session.player orelse return;

    var changed: [Session.equipment_slots]bool = undefined;
    if (!from.session.refreshEquipment(&changed)) return;

    for (changed, 0..) |dirty, slot| {
        if (!dirty) continue;
        const worn = Session.equipmentAt(player, slot);
        for (server.connections.items) |connection| {
            if (connection == from) continue;
            if (connection.session.dimension != from.session.dimension) continue;
            connection.session.sendEquipment(server.gpa, player.base.id, slot, worn) catch {};
        }
    }
}

fn announceAll(server: *Server, who: []const u8, joined: bool) void {
    for (server.connections.items) |connection| {
        connection.session.announce(server.gpa, who, joined) catch {};
    }
}

fn collectPeers(server: *Server, dim: *Dim, out: *std.ArrayList(Session.Peer)) !void {
    out.clearRetainingCapacity();
    for (server.connections.items) |connection| {
        if (connection.session.state != .playing) continue;
        if (connection.session.dimension != dim.dimension) continue;
        const player = connection.session.player orelse continue;
        try out.append(server.gpa, .{
            .id = player.base.id,
            .body = .{ .player = .{ .name = player.name.text(), .player = player } },
        });
    }

    try Session.collectWorldPeers(server.gpa, &dim.level, out);
}

fn tick(server: *Server) !void {
    server.lock();
    defer server.unlock();

    server.tick_count += 1;

    var index: usize = 0;
    while (index < server.connections.items.len) {
        const connection = server.connections.items[index];

        const was_playing = connection.session.state == .playing;
        drainPending(server, connection) catch {};
        if (!was_playing and connection.session.state == .playing) {
            announceAll(server, connection.session.name.text(), true);
        }
        if (connection.session.takeChat()) |line| broadcastChat(server, line.text());
        if (connection.session.takeSwing()) broadcastSwing(server, connection);
        if (connection.session.takeSign()) |at| broadcastSign(server, connection.session.dimension, at);
        if (connection.outgoing.items.len < outgoing_high_water) {
            _ = connection.session.streamChunks(server.gpa, server.levelFor(connection), Session.chunks_per_tick) catch 0;
        }

        if (!connection.open or connection.session.state == .closed) {
            if (connection.session.player != null) {
                announceAll(server, connection.session.name.text(), false);
            }
            queueOutbox(server, connection) catch {};
            connection.open = false;
            connection.session.leave(server.gpa, server.levelFor(connection));
            connection.stream.shutdown(server.io, .both) catch {};
            try server.retired.append(server.gpa, connection);
            _ = server.connections.orderedRemove(index);
            continue;
        }
        index += 1;
    }

    var arena: std.heap.ArenaAllocator = .init(server.gpa);
    defer arena.deinit();
    for (&server.dims) |*dim| try dim.level.tick(server.gpa, arena.allocator());

    for (server.connections.items) |connection| {
        const travelling = connection.session.tickPlayer(server.gpa, server.levelFor(connection)) catch false;
        if (travelling) sendThroughPortal(server, connection) catch {};
    }

    var peers: std.ArrayList(Session.Peer) = .empty;
    defer peers.deinit(server.gpa);

    for (&server.dims) |*dim| {
        try collectPeers(server, dim, &peers);
        for (server.connections.items) |connection| {
            if (connection.session.dimension != dim.dimension) continue;
            connection.session.trackPeers(server.gpa, peers.items) catch {};
        }

        for (dim.level.entities.blasts.items) |blast| {
            const broken = dim.level.entities.blast_blocks.items[blast.first..][0..blast.count];
            for (server.connections.items) |connection| {
                if (connection.session.dimension != dim.dimension) continue;
                connection.session.sendBlast(server.gpa, blast, broken) catch {};
            }
        }
        dim.level.entities.clearBlasts();

        for (dim.level.entities.struck.items) |bolt| {
            for (server.connections.items) |connection| {
                if (connection.session.dimension != dim.dimension) continue;
                connection.session.sendLightning(server.gpa, bolt.id, bolt.at) catch {};
            }
        }
        dim.level.entities.clearStruck();

        for (dim.level.entities.collected.items) |taken| {
            for (server.connections.items) |connection| {
                if (connection.session.dimension != dim.dimension) continue;
                connection.session.sendCollect(server.gpa, taken.item, taken.by) catch {};
            }
        }
        dim.level.entities.collected.clearRetainingCapacity();
    }

    for (server.connections.items) |connection| {
        if (connection.session.takeSleepChange()) |change| broadcastSleep(server, connection, change);
    }

    for (server.connections.items) |connection| {
        const sky = server.levelFor(connection).world_map.weather;
        connection.session.sendRainState(server.gpa, sky.raining) catch {};
        connection.session.reportHealth(server.gpa) catch {};
        broadcastEquipment(server, connection);
        connection.session.sendRiding(server.gpa) catch {};
        connection.session.syncWindow(server.gpa, server.levelFor(connection)) catch {};
        connection.session.pingIfQuiet(server.gpa) catch {};
        queueOutbox(server, connection) catch {};
    }

    server.ticks_since_save += 1;
}

fn sendThroughPortal(server: *Server, connection: *Connection) !void {
    const from = connection.session.dimension;
    const target = from.other();
    const scale = world.Dimension.nether.coordinateScale();

    const player = connection.session.player orelse return;
    const at = player.base.position;
    const x = if (target == .nether) at.x / scale else at.x * scale;
    const z = if (target == .nether) at.z / scale else at.z * scale;

    try connection.session.travel(
        server.gpa,
        &server.dimOf(from).level,
        &server.dimOf(target).level,
        target,
        x,
        at.y,
        z,
    );
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = try parseArgs(args);

    var saves_dir = try world.save.openSavesDir(io, .cwd());
    defer saves_dir.close(io);

    var overworld_handle = try world.save.open(io, saves_dir, options.folder);
    errdefer overworld_handle.close(gpa, io);

    var nether_handle = try world.save.open(io, saves_dir, options.folder);
    errdefer nether_handle.close(gpa, io);
    try nether_handle.useDimension(gpa, io, .nether);

    var stored = overworld_handle.readLevel(gpa, io) catch null;
    defer if (stored) |*info| info.deinit(gpa);

    var seed_source: world.JavaRandom = .init(world.RegionFile.unixMilliseconds(io));
    const seed = if (stored) |info| info.seed else options.seed orelse seed_source.nextLong();

    var server: Server = .{
        .gpa = gpa,
        .io = io,
        .dims = .{
            .{
                .dimension = .overworld,
                .level = game.Level.init(gpa, try world.Generator.init(gpa, .overworld, seed)),
                .handle = overworld_handle,
            },
            .{
                .dimension = .nether,
                .level = game.Level.init(gpa, try world.Generator.init(gpa, .nether, seed)),
                .handle = nether_handle,
            },
        },
    };
    // Each dim owns its copy of the save handle; the originals above are only the seed for them.
    defer for (&server.dims) |*dim| {
        dim.level.deinit(gpa);
        dim.handle.close(gpa, io);
    };

    for (&server.dims) |*dim| {
        dim.server = &server;
        dim.level.attach();
        dim.level.world_map.persistence = .{ .handle = &dim.handle, .io = io };
        dim.level.world_map.access = worldAccess(dim);
        dim.level.world_map.note_sink = noteSink(dim);
        dim.level.world_map.brightness = world.light.brightnessTable(dim.dimension.ambientLight());
        dim.level.world_map.has_sky = dim.dimension.hasSky();
        dim.level.world_map.difficulty = options.difficulty;
    }
    server.dimOf(.nether).level.entities.next_entity_id = nether_id_base;

    const home = server.overworld();
    if (stored) |info| {
        home.spawn = info.spawn;
        home.world_map.time = info.time;
        home.world_map.weather = .{
            .raining = info.raining,
            .rain_time = info.rain_time,
            .thundering = info.thundering,
            .thunder_time = info.thunder_time,
        };
        home.world_map.weather.settle();
    } else {
        home.spawn = try findSpawn(home);
    }
    server.dimOf(.nether).level.spawn = home.spawn;

    var address: std.Io.net.IpAddress = .{ .ip4 = .unspecified(options.port) };
    var listener = try address.listen(io, .{ .reuse_address = true });

    std.log.info("rosebed server listening on port {d}: world \"{s}\", seed {d}, spawn {d},{d},{d}{s}", .{
        options.port,
        options.folder,
        seed,
        home.spawn[0],
        home.spawn[1],
        home.spawn[2],
        if (stored == null) " (new)" else "",
    });

    const accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{ &server, &listener });

    var timer: core.Timer = .init(ticks_per_second, monotonicNs(io));
    while (server.running.load(.acquire)) {
        timer.advance(monotonicNs(io));
        for (0..@intCast(timer.elapsed_ticks)) |_| try tick(&server);

        if (server.ticks_since_save >= autosave_interval_ticks) {
            server.ticks_since_save = 0;
            saveWorld(&server, options.folder) catch |err| {
                std.log.err("autosave failed: {s}", .{@errorName(err)});
            };
        }

        if (options.ticks) |limit| {
            if (server.tick_count >= limit) server.running.store(false, .release);
        }
        std.Io.sleep(io, .{ .nanoseconds = std.time.ns_per_ms }, .awake) catch {};
    }

    var knock: std.Io.net.IpAddress = .{ .ip4 = .loopback(options.port) };
    if (knock.connect(io, .{ .mode = .stream })) |stream| stream.close(io) else |_| {}
    accept_thread.join();
    listener.deinit(io);

    server.lock();
    for (server.connections.items) |connection| {
        connection.open = false;
        connection.session.leave(gpa, server.levelFor(connection));
        connection.stream.shutdown(io, .both) catch {};
        try server.retired.append(gpa, connection);
    }
    server.connections.clearRetainingCapacity();
    server.unlock();

    for (server.retired.items) |connection| {
        if (connection.reader_thread) |thread| thread.join();
        if (connection.writer_thread) |thread| thread.join();
        connection.stream.close(io);
        connection.deinit(gpa);
        gpa.destroy(connection);
    }
    server.retired.deinit(gpa);
    server.connections.deinit(gpa);

    saveWorld(&server, options.folder) catch |err| {
        std.log.err("could not save the world: {s}", .{@errorName(err)});
    };

    std.log.info("rosebed server stopped after {d} ticks", .{server.tick_count});
}

test "the command line picks the port, world, seed and tick limit" {
    const options = try parseArgs(&.{ "rosebed-server", "--port", "25566", "--world", "flat", "--seed", "-42", "--ticks", "100" });
    try std.testing.expectEqual(@as(u16, 25566), options.port);
    try std.testing.expectEqualStrings("flat", options.folder);
    try std.testing.expectEqual(@as(i64, -42), options.seed.?);
    try std.testing.expectEqual(@as(u64, 100), options.ticks.?);
}

test "an empty command line falls back to the vanilla port" {
    const options = try parseArgs(&.{"rosebed-server"});
    try std.testing.expectEqual(default_port, options.port);
    try std.testing.expect(options.seed == null);
    try std.testing.expect(options.ticks == null);
}

test "an argument the server does not know is refused rather than ignored" {
    try std.testing.expectError(error.UnknownArgument, parseArgs(&.{ "rosebed-server", "--nonsense" }));
}
