const std = @import("std");

const core = @import("core");
const game = @import("game");
const net = @import("net");
const world = @import("world");
const chunk_payload = world.chunk_payload;

const Session = @import("session.zig");

pub const default_port: u16 = 25565;
pub const ticks_per_second: u32 = 20;
pub const read_buffer_len: usize = 64 * 1024;
pub const write_buffer_len: usize = 64 * 1024;
pub const outgoing_high_water: usize = 4 * 1024 * 1024;
pub const autosave_interval_ticks: u64 = 900;
pub const save_chunks_per_pass: usize = 64;

pub const Options = struct {
    port: u16 = default_port,
    folder: []const u8 = "world",
    seed: ?i64 = null,
    ticks: ?u64 = null,
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

const Server = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    level: game.Level,
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
};

fn worldAccess(server: *Server) world.World.Access {
    return .{
        .context = server,
        .markBlockNeedsUpdate = markBlockNeedsUpdate,
        .updateAllRenderers = updateAllRenderers,
    };
}

fn markBlockNeedsUpdate(context: *anyopaque, x: i32, y: i32, z: i32) std.mem.Allocator.Error!void {
    const server: *Server = @ptrCast(@alignCast(context));
    if (y < 0 or y >= world.constants.chunk_height) return;

    const block = server.level.world_map.getBlock(x, y, z);
    const metadata = server.level.world_map.getBlockMetadata(x, y, z);

    for (server.connections.items) |connection| {
        connection.session.sendBlockChange(server.gpa, x, y, z, block, metadata) catch |err| switch (err) {
            error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
            error.StringTooLong, error.InvalidUtf8 => unreachable,
        };
    }
}

fn updateAllRenderers(_: *anyopaque) std.mem.Allocator.Error!void {}

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
        try connection.session.handle(server.gpa, &server.level, message);
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
    try level.world_map.ensureDecorated(level.generator, 0, 0);

    var y: i32 = world.constants.chunk_height - 2;
    while (y > 0) : (y -= 1) {
        if (!level.world_map.getBlock(8, y, 8).isSolid()) continue;
        return .{ 8, y + 1, 8 };
    }
    return .{ 8, 64, 8 };
}

fn saveWorld(server: *Server, handle: *world.save.Save, name: []const u8) !void {
    const info: world.save.LevelInfo = .{
        .seed = server.level.generator.world_seed,
        .spawn = server.level.spawn,
        .time = server.level.world_map.time,
        .last_played = world.RegionFile.unixMilliseconds(server.io),
        .size_on_disk = @intCast(handle.diskSize(server.io)),
        .name = @constCast(name),
    };
    try handle.writeLevel(server.gpa, server.io, info);

    try server.level.world_map.beginSaveRound();
    while (try server.level.world_map.saveQueuedChunks(save_chunks_per_pass) > 0) {}
}

fn broadcastChat(server: *Server, line: []const u8) void {
    std.log.info("{s}", .{line});
    for (server.connections.items) |connection| {
        connection.session.sendChat(server.gpa, line) catch {};
    }
}

fn announceAll(server: *Server, who: []const u8, joined: bool) void {
    for (server.connections.items) |connection| {
        connection.session.announce(server.gpa, who, joined) catch {};
    }
}

fn collectPeers(server: *Server, out: *std.ArrayList(Session.Peer)) !void {
    for (server.connections.items) |connection| {
        if (connection.session.state != .playing) continue;
        const player = connection.session.player orelse continue;
        try out.append(server.gpa, .{
            .id = player.base.id,
            .body = .{ .player = .{ .name = player.name.text(), .player = player } },
        });
    }

    for (server.level.entities.mobs.items) |entry| {
        try out.append(server.gpa, .{ .id = entry.animal.base.id, .body = .{ .mob = entry } });
    }
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
        if (connection.outgoing.items.len < outgoing_high_water) {
            _ = connection.session.streamChunks(server.gpa, &server.level, Session.chunks_per_tick) catch 0;
        }

        if (!connection.open or connection.session.state == .closed) {
            if (connection.session.player != null) {
                announceAll(server, connection.session.name.text(), false);
            }
            queueOutbox(server, connection) catch {};
            connection.open = false;
            connection.session.leave(server.gpa, &server.level);
            connection.stream.shutdown(server.io, .both) catch {};
            try server.retired.append(server.gpa, connection);
            _ = server.connections.orderedRemove(index);
            continue;
        }
        index += 1;
    }

    var arena: std.heap.ArenaAllocator = .init(server.gpa);
    defer arena.deinit();
    try server.level.tick(server.gpa, arena.allocator());

    var peers: std.ArrayList(Session.Peer) = .empty;
    defer peers.deinit(server.gpa);
    try collectPeers(server, &peers);

    for (server.connections.items) |connection| {
        connection.session.trackPeers(server.gpa, peers.items) catch {};
        connection.session.reportHealth(server.gpa) catch {};
        queueOutbox(server, connection) catch {};
    }

    server.ticks_since_save += 1;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = try parseArgs(args);

    var saves_dir = try world.save.openSavesDir(io, .cwd());
    defer saves_dir.close(io);

    var handle = try world.save.open(io, saves_dir, options.folder);
    defer handle.close(gpa, io);

    var stored = handle.readLevel(gpa, io) catch null;
    defer if (stored) |*info| info.deinit(gpa);

    var seed_source: world.JavaRandom = .init(world.RegionFile.unixMilliseconds(io));
    const seed = if (stored) |info| info.seed else options.seed orelse seed_source.nextLong();

    var server: Server = .{
        .gpa = gpa,
        .io = io,
        .level = game.Level.init(gpa, try world.TerrainGenerator.init(gpa, seed)),
    };
    defer server.level.deinit(gpa);
    server.level.attach();
    server.level.world_map.persistence = .{ .handle = &handle, .io = io };
    server.level.world_map.access = worldAccess(&server);

    if (stored) |info| {
        server.level.spawn = info.spawn;
        server.level.world_map.time = info.time;
    } else {
        server.level.spawn = try findSpawn(&server.level);
    }

    var address: std.Io.net.IpAddress = .{ .ip4 = .unspecified(options.port) };
    var listener = try address.listen(io, .{ .reuse_address = true });

    std.log.info("rosebed server listening on port {d}: world \"{s}\", seed {d}, spawn {d},{d},{d}{s}", .{
        options.port,
        options.folder,
        seed,
        server.level.spawn[0],
        server.level.spawn[1],
        server.level.spawn[2],
        if (stored == null) " (new)" else "",
    });

    const accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{ &server, &listener });

    var timer: core.Timer = .init(ticks_per_second, monotonicNs(io));
    while (server.running.load(.acquire)) {
        timer.advance(monotonicNs(io));
        for (0..@intCast(timer.elapsed_ticks)) |_| try tick(&server);

        if (server.ticks_since_save >= autosave_interval_ticks) {
            server.ticks_since_save = 0;
            saveWorld(&server, &handle, options.folder) catch |err| {
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
        connection.session.leave(gpa, &server.level);
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

    saveWorld(&server, &handle, options.folder) catch |err| {
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
