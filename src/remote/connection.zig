const std = @import("std");

const game = @import("game");
const math = @import("math");
const net = @import("net");
const world = @import("world");

const Connection = @This();

pub const State = enum { greeting, awaiting_login, playing, closed };

pub const Disconnect = struct {
    reason: []const u8,
    owned: bool,
};

pub const NameBuffer = struct {
    bytes: [net.packet.max_username]u8 = undefined,
    len: usize = 0,

    pub fn set(self: *NameBuffer, value: []const u8) void {
        self.len = @min(value.len, self.bytes.len);
        @memcpy(self.bytes[0..self.len], value[0..self.len]);
    }

    pub fn text(self: *const NameBuffer) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const ChatLine = struct {
    bytes: [net.packet.max_chat]u8 = undefined,
    len: usize = 0,

    pub fn text(self: *const ChatLine) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Peer = struct {
    id: game.Entity.Id,
    name: NameBuffer = .{},
    player: game.Player,
};

fn decodePosition(value: i32) f64 {
    return @as(f64, @floatFromInt(value)) / 32.0;
}

fn decodeRotation(value: i8) f32 {
    return @as(f32, @floatFromInt(value)) * 360.0 / 256.0;
}

state: State = .greeting,
entity_id: game.Entity.Id = game.Entity.no_id,
map_seed: i64 = 0,
spawn: [3]i32 = .{ 0, 64, 0 },
placed: bool = false,
outbox: std.ArrayList(u8) = .empty,
disconnect: ?Disconnect = null,
loaded_chunks: usize = 0,
health: i32 = 20,
peers: std.ArrayList(Peer) = .empty,
chat: std.ArrayList(ChatLine) = .empty,

pub fn deinit(self: *Connection, gpa: std.mem.Allocator) void {
    self.peers.deinit(gpa);
    self.chat.deinit(gpa);
    self.outbox.deinit(gpa);
    if (self.disconnect) |reason| {
        if (reason.owned) gpa.free(reason.reason);
    }
    self.disconnect = null;
}

pub fn send(self: *Connection, gpa: std.mem.Allocator, message: net.packet.Packet) !void {
    var allocating: std.Io.Writer.Allocating = .fromArrayList(gpa, &self.outbox);
    defer self.outbox = allocating.toArrayList();
    try net.packet.write(&allocating.writer, message);
}

pub fn takeOutbox(self: *Connection, gpa: std.mem.Allocator) ![]u8 {
    return self.outbox.toOwnedSlice(gpa);
}

pub fn begin(self: *Connection, gpa: std.mem.Allocator, username: []const u8) !void {
    self.state = .greeting;
    try self.send(gpa, .{ .handshake = .{ .username = username } });
}

fn fail(self: *Connection, gpa: std.mem.Allocator, reason: []const u8, owned: bool) void {
    if (self.disconnect == null) {
        self.disconnect = .{ .reason = reason, .owned = owned };
    } else if (owned) {
        gpa.free(reason);
    }
    self.state = .closed;
}

pub fn handle(
    self: *Connection,
    gpa: std.mem.Allocator,
    level: *game.Level,
    username: []const u8,
    message: net.packet.Packet,
) !void {
    if (message == .kick_disconnect) {
        const copy = try gpa.dupe(u8, message.kick_disconnect.reason);
        self.fail(gpa, copy, true);
        return;
    }

    switch (self.state) {
        .closed => {},
        .greeting => switch (message) {
            .handshake => {
                self.state = .awaiting_login;
                try self.send(gpa, .{ .login = .{
                    .protocol_version = net.packet.protocol_version,
                    .username = username,
                    .map_seed = 0,
                    .dimension = 0,
                } });
            },
            else => self.fail(gpa, "Server spoke out of turn", false),
        },
        .awaiting_login => switch (message) {
            .login => |body| {
                self.entity_id = @bitCast(body.protocol_version);
                self.map_seed = body.map_seed;
                self.state = .playing;
            },
            else => self.fail(gpa, "Server spoke out of turn", false),
        },
        .playing => try self.handlePlaying(gpa, level, message),
    }
}

fn handlePlaying(
    self: *Connection,
    gpa: std.mem.Allocator,
    level: *game.Level,
    message: net.packet.Packet,
) !void {
    switch (message) {
        .keep_alive => try self.send(gpa, .keep_alive),
        .spawn_position => |body| self.spawn = .{ body.x, body.y, body.z },
        .update_time => |body| level.world_map.time = body.time,
        .update_health => |body| {
            self.health = body.health;
            if (level.occupants.items.len > 0) level.occupants.items[0].player.health = body.health;
        },
        .chat => |body| {
            var line: ChatLine = .{};
            line.len = @min(body.message.len, line.bytes.len);
            @memcpy(line.bytes[0..line.len], body.message[0..line.len]);
            try self.chat.append(gpa, line);
        },
        .named_entity_spawn => |body| try self.spawnPeer(gpa, body),
        .mob_spawn => |body| try spawnMob(gpa, level, body),
        .entity_metadata => |body| adoptWatched(level, @bitCast(body.entity_id), body.metadata),
        .destroy_entity => |body| {
            const id: game.Entity.Id = @bitCast(body.entity_id);
            self.removePeer(id);
            _ = level.entities.removeMob(gpa, id);
        },
        .entity_teleport => |body| {
            if (self.bodyById(level, @bitCast(body.entity_id))) |moved| {
                moved.begin();
                moved.placeAt(
                    decodePosition(body.x),
                    decodePosition(body.y),
                    decodePosition(body.z),
                );
                moved.turn(body.yaw, body.pitch);
            }
        },
        .rel_entity_move => |body| {
            if (self.bodyById(level, @bitCast(body.entity_id))) |moved| {
                moved.begin();
                moved.shift(body.dx, body.dy, body.dz);
            }
        },
        .entity_look => |body| {
            if (self.bodyById(level, @bitCast(body.entity_id))) |moved| {
                moved.begin();
                moved.turn(body.yaw, body.pitch);
            }
        },
        .rel_entity_move_look => |body| {
            if (self.bodyById(level, @bitCast(body.entity_id))) |moved| {
                moved.begin();
                moved.shift(body.dx, body.dy, body.dz);
                moved.turn(body.yaw, body.pitch);
            }
        },
        .player_look_move => |body| try self.placePlayer(level, body.x, body.stance, body.z, body.yaw, body.pitch),
        .pre_chunk => |body| try self.preChunk(gpa, level, body.x, body.z, body.load),
        .map_chunk => |body| try self.mapChunk(gpa, level, body),
        .block_change => |body| self.blockChange(level, body.x, body.y, body.z, body.block, body.metadata),
        .multi_block_change => |body| self.multiBlockChange(level, body),
        else => {},
    }
}

pub fn peerById(self: *Connection, id: game.Entity.Id) ?*Peer {
    for (self.peers.items) |*peer| {
        if (peer.id == id) return peer;
    }
    return null;
}

const Body = union(enum) {
    player: *game.Player,
    animal: *game.Animal,

    fn begin(self: Body) void {
        switch (self) {
            inline else => |it| {
                it.base.prev_position = it.base.position;
                it.prev_yaw = it.yaw;
                it.prev_pitch = it.pitch;
                it.prev_render_yaw = it.render_yaw;
            },
        }
    }

    fn placeAt(self: Body, x: f64, y: f64, z: f64) void {
        switch (self) {
            inline else => |it| it.base.position = .{ .x = x, .y = y, .z = z },
        }
    }

    fn shift(self: Body, dx: i8, dy: i8, dz: i8) void {
        switch (self) {
            inline else => |it| {
                it.base.position.x += decodePosition(dx);
                it.base.position.y += decodePosition(dy);
                it.base.position.z += decodePosition(dz);
            },
        }
    }

    fn turn(self: Body, yaw: i8, pitch: i8) void {
        switch (self) {
            inline else => |it| {
                it.yaw = decodeRotation(yaw);
                it.pitch = decodeRotation(pitch);
                it.render_yaw = it.yaw;
            },
        }
    }
};

fn bodyById(self: *Connection, level: *game.Level, id: game.Entity.Id) ?Body {
    if (self.peerById(id)) |peer| return .{ .player = &peer.player };
    const entry = level.entities.mobById(id) orelse return null;
    return .{ .animal = entry.animal };
}

fn adoptWatched(level: *game.Level, id: game.Entity.Id, metadata: net.packet.Metadata) void {
    const entry = level.entities.mobById(id) orelse return;
    game.mob.adopt(entry.type_id, entry.animal, metadata);
}

fn spawnPeer(self: *Connection, gpa: std.mem.Allocator, body: anytype) !void {
    const id: game.Entity.Id = @bitCast(body.entity_id);
    self.removePeer(id);

    var peer: Peer = .{
        .id = id,
        .player = game.Player.spawn(.{
            .x = decodePosition(body.x),
            .y = decodePosition(body.y),
            .z = decodePosition(body.z),
        }),
    };
    peer.name.set(body.name);
    peer.player.base.id = id;

    const placed: Body = .{ .player = &peer.player };
    placed.turn(body.rotation, body.pitch);
    placed.begin();

    try self.peers.append(gpa, peer);
}

fn spawnMob(gpa: std.mem.Allocator, level: *game.Level, body: anytype) !void {
    const type_id = game.mob.byWireId(body.kind) orelse return;
    const id: game.Entity.Id = @bitCast(body.entity_id);
    _ = level.entities.removeMob(gpa, id);

    const kind = game.mob.get(type_id);
    const animal = try kind.spawn(gpa, .{
        .x = decodePosition(body.x),
        .y = decodePosition(body.y),
        .z = decodePosition(body.z),
    }, &level.world_map.rand);
    errdefer kind.destroy(animal, gpa);

    game.mob.adopt(type_id, animal, body.metadata);

    const placed: Body = .{ .animal = animal };
    placed.turn(body.yaw, body.pitch);
    placed.begin();

    try level.entities.adoptMobAs(gpa, type_id, animal, id);
}

fn removePeer(self: *Connection, id: game.Entity.Id) void {
    for (self.peers.items, 0..) |peer, index| {
        if (peer.id != id) continue;
        _ = self.peers.orderedRemove(index);
        return;
    }
}

fn placePlayer(
    self: *Connection,
    level: *game.Level,
    x: f64,
    y: f64,
    z: f64,
    yaw: f32,
    pitch: f32,
) !void {
    const player = (level.occupants.items[0].player);
    player.base.position = .{ .x = x, .y = y, .z = z };
    player.base.prev_position = player.base.position;
    player.base.motion = .{ .x = 0, .y = 0, .z = 0 };
    player.yaw = yaw;
    player.pitch = pitch;
    player.prev_yaw = yaw;
    player.prev_pitch = pitch;
    self.placed = true;
}

fn preChunk(
    self: *Connection,
    gpa: std.mem.Allocator,
    level: *game.Level,
    chunk_x: i32,
    chunk_z: i32,
    load: bool,
) !void {
    _ = gpa;
    if (load) {
        _ = try level.world_map.createChunk(chunk_x, chunk_z);
        return;
    }
    level.world_map.forgetChunk(chunk_x, chunk_z);
    if (self.loaded_chunks > 0) self.loaded_chunks -= 1;
}

fn mapChunk(
    self: *Connection,
    gpa: std.mem.Allocator,
    level: *game.Level,
    body: anytype,
) !void {
    const width = world.constants.chunk_width;
    if (body.size_x != width or body.size_z != width) return;
    if (body.size_y != world.constants.chunk_height) return;

    const coord: world.World.ChunkCoord = .{
        .x = @divFloor(body.x, width),
        .z = @divFloor(body.z, width),
    };
    const chunk = try level.world_map.createChunk(coord.x, coord.z);
    world.chunk_payload.decompressFull(gpa, chunk, body.compressed) catch return;

    try level.world_map.markDecorated(coord.x, coord.z);
    self.loaded_chunks += 1;
}

fn blockChange(_: *Connection, level: *game.Level, x: i32, y: u8, z: i32, block: u8, metadata: u8) void {
    level.world_map.setBlock(x, @intCast(y), z, @enumFromInt(block));
    level.world_map.setBlockMetadata(x, @intCast(y), z, @truncate(metadata));
}

fn multiBlockChange(self: *Connection, level: *game.Level, body: anytype) void {
    const width = world.constants.chunk_width;
    for (body.coordinates, body.types, body.metadata) |packed_xz, block, meta| {
        const raw: u16 = @bitCast(packed_xz);
        const local_x: i32 = @intCast((raw >> 12) & 0x0f);
        const local_z: i32 = @intCast((raw >> 8) & 0x0f);
        const y: i32 = @intCast(raw & 0xff);
        self.blockChange(
            level,
            body.chunk_x * width + local_x,
            @intCast(y),
            body.chunk_z * width + local_z,
            block,
            meta,
        );
    }
}

pub fn reportPosition(self: *Connection, gpa: std.mem.Allocator, player: *const game.Player) !void {
    if (self.state != .playing or !self.placed) return;
    try self.send(gpa, .{ .player_look_move = .{
        .x = player.base.position.x,
        .y = player.base.position.y,
        .stance = player.base.position.y + game.Player.eye_height,
        .z = player.base.position.z,
        .yaw = player.yaw,
        .pitch = player.pitch,
        .on_ground = player.base.on_ground,
    } });
}

pub fn takeChat(self: *Connection, gpa: std.mem.Allocator) ![]ChatLine {
    return self.chat.toOwnedSlice(gpa);
}

pub fn say(self: *Connection, gpa: std.mem.Allocator, message: []const u8) !void {
    if (self.state != .playing) return;
    try self.send(gpa, .{ .chat = .{ .message = message } });
}

pub fn reportDig(self: *Connection, gpa: std.mem.Allocator, x: i32, y: i32, z: i32, face: u8) !void {
    if (self.state != .playing) return;
    try self.send(gpa, .{ .block_dig = .{
        .status = 2,
        .x = x,
        .y = @intCast(y),
        .z = z,
        .face = face,
    } });
}

pub fn reportPlace(
    self: *Connection,
    gpa: std.mem.Allocator,
    x: i32,
    y: i32,
    z: i32,
    face: u8,
    held: ?net.packet.Stack,
) !void {
    if (self.state != .playing) return;
    try self.send(gpa, .{ .place = .{
        .x = x,
        .y = @intCast(y),
        .z = z,
        .face = face,
        .held = held,
    } });
}

const testing_username = "Tester";

fn testLevel(gpa: std.mem.Allocator) !game.Level {
    return game.Level.init(gpa, try world.TerrainGenerator.init(gpa, 1));
}

fn drain(gpa: std.mem.Allocator, connection: *Connection, out: *std.ArrayList(net.packet.Packet)) !void {
    const bytes = try connection.takeOutbox(gpa);
    defer gpa.free(bytes);

    var reader = std.Io.Reader.fixed(bytes);
    while (reader.bufferedLen() > 0) {
        const id = try net.packet.readId(&reader);
        try out.append(gpa, try net.packet.readBody(gpa, &reader, id));
    }
}

fn freeAll(gpa: std.mem.Allocator, list: *std.ArrayList(net.packet.Packet)) void {
    for (list.items) |message| message.deinit(gpa);
    list.deinit(gpa);
}

test "opening a connection sends the handshake the server expects first" {
    const gpa = std.testing.allocator;
    var connection: Connection = .{};
    defer connection.deinit(gpa);

    try connection.begin(gpa, testing_username);

    var sent: std.ArrayList(net.packet.Packet) = .empty;
    defer freeAll(gpa, &sent);
    try drain(gpa, &connection, &sent);

    try std.testing.expectEqual(@as(usize, 1), sent.items.len);
    try std.testing.expectEqualStrings(testing_username, sent.items[0].handshake.username);
}

test "the server's handshake is answered with a protocol 14 login" {
    const gpa = std.testing.allocator;
    var level = try testLevel(gpa);
    defer level.deinit(gpa);

    var connection: Connection = .{};
    defer connection.deinit(gpa);

    try connection.begin(gpa, testing_username);
    const opening = try connection.takeOutbox(gpa);
    gpa.free(opening);

    try connection.handle(gpa, &level, testing_username, .{ .handshake = .{ .username = "-" } });
    try std.testing.expectEqual(State.awaiting_login, connection.state);

    var sent: std.ArrayList(net.packet.Packet) = .empty;
    defer freeAll(gpa, &sent);
    try drain(gpa, &connection, &sent);

    try std.testing.expectEqual(@as(usize, 1), sent.items.len);
    try std.testing.expectEqual(net.packet.protocol_version, sent.items[0].login.protocol_version);
    try std.testing.expectEqualStrings(testing_username, sent.items[0].login.username);
}

test "the login reply carries the entity id and seed the server chose" {
    const gpa = std.testing.allocator;
    var level = try testLevel(gpa);
    defer level.deinit(gpa);

    var connection: Connection = .{};
    defer connection.deinit(gpa);
    connection.state = .awaiting_login;

    try connection.handle(gpa, &level, testing_username, .{ .login = .{
        .protocol_version = 77,
        .username = "",
        .map_seed = -4242,
        .dimension = 0,
    } });

    try std.testing.expectEqual(State.playing, connection.state);
    try std.testing.expectEqual(@as(game.Entity.Id, 77), connection.entity_id);
    try std.testing.expectEqual(@as(i64, -4242), connection.map_seed);
}

test "a kick at any point closes the connection and keeps the reason" {
    const gpa = std.testing.allocator;
    var level = try testLevel(gpa);
    defer level.deinit(gpa);

    var connection: Connection = .{};
    defer connection.deinit(gpa);
    connection.state = .awaiting_login;

    try connection.handle(gpa, &level, testing_username, .{
        .kick_disconnect = .{ .reason = "Outdated client!" },
    });

    try std.testing.expectEqual(State.closed, connection.state);
    try std.testing.expectEqualStrings("Outdated client!", connection.disconnect.?.reason);
}

test "a server that talks out of turn is treated as broken" {
    const gpa = std.testing.allocator;
    var level = try testLevel(gpa);
    defer level.deinit(gpa);

    var connection: Connection = .{};
    defer connection.deinit(gpa);

    try connection.handle(gpa, &level, testing_username, .{ .update_time = .{ .time = 1 } });

    try std.testing.expectEqual(State.closed, connection.state);
    try std.testing.expect(connection.disconnect != null);
}

test "a map chunk from the server becomes a real chunk in the world" {
    const gpa = std.testing.allocator;
    var level = try testLevel(gpa);
    defer level.deinit(gpa);

    var connection: Connection = .{};
    defer connection.deinit(gpa);
    connection.state = .playing;

    const source = try gpa.create(world.Chunk);
    defer gpa.destroy(source);
    source.* = world.Chunk.init(2, -3);
    for (0..world.constants.chunk_width) |x| {
        for (0..world.constants.chunk_width) |z| {
            source.setBlock(@intCast(x), 40, @intCast(z), .stone);
            source.setSkyLight(@intCast(x), 41, @intCast(z), 15);
        }
    }
    source.setBlockMetadata(1, 40, 2, 6);

    const compressed = try world.chunk_payload.compressFull(gpa, source);
    defer gpa.free(compressed);

    try connection.handle(gpa, &level, testing_username, .{ .pre_chunk = .{ .x = 2, .z = -3, .load = true } });
    try connection.handle(gpa, &level, testing_username, .{ .map_chunk = .{
        .x = 2 * world.constants.chunk_width,
        .y = 0,
        .z = -3 * world.constants.chunk_width,
        .size_x = world.constants.chunk_width,
        .size_y = world.constants.chunk_height,
        .size_z = world.constants.chunk_width,
        .compressed = compressed,
    } });

    try std.testing.expectEqual(@as(usize, 1), connection.loaded_chunks);
    try std.testing.expect(level.world_map.isDecorated(2, -3));
    try std.testing.expectEqual(world.Block.stone, level.world_map.getBlock(2 * 16 + 5, 40, -3 * 16 + 5));
    try std.testing.expectEqual(@as(u4, 6), level.world_map.getBlockMetadata(2 * 16 + 1, 40, -3 * 16 + 2));
    try std.testing.expectEqual(@as(u4, 15), level.world_map.getSkyLight(2 * 16 + 3, 41, -3 * 16 + 3));
}

test "a block change from the server lands in the world" {
    const gpa = std.testing.allocator;
    var level = try testLevel(gpa);
    defer level.deinit(gpa);

    var connection: Connection = .{};
    defer connection.deinit(gpa);
    connection.state = .playing;

    _ = try level.world_map.createChunk(0, 0);
    try connection.handle(gpa, &level, testing_username, .{ .block_change = .{
        .x = 5,
        .y = 70,
        .z = 6,
        .block = @intFromEnum(world.Block.planks),
        .metadata = 3,
    } });

    try std.testing.expectEqual(world.Block.planks, level.world_map.getBlock(5, 70, 6));
    try std.testing.expectEqual(@as(u4, 3), level.world_map.getBlockMetadata(5, 70, 6));
}

test "a multi block change unpacks each coordinate the way vanilla packs it" {
    const gpa = std.testing.allocator;
    var level = try testLevel(gpa);
    defer level.deinit(gpa);

    var connection: Connection = .{};
    defer connection.deinit(gpa);
    connection.state = .playing;

    _ = try level.world_map.createChunk(1, 1);

    const packed_a: i16 = @bitCast(@as(u16, (3 << 12) | (9 << 8) | 64));
    const packed_b: i16 = @bitCast(@as(u16, (15 << 12) | (0 << 8) | 100));

    try connection.handle(gpa, &level, testing_username, .{ .multi_block_change = .{
        .chunk_x = 1,
        .chunk_z = 1,
        .coordinates = &.{ packed_a, packed_b },
        .types = &.{ @intFromEnum(world.Block.stone), @intFromEnum(world.Block.glass) },
        .metadata = &.{ 0, 2 },
    } });

    try std.testing.expectEqual(world.Block.stone, level.world_map.getBlock(16 + 3, 64, 16 + 9));
    try std.testing.expectEqual(world.Block.glass, level.world_map.getBlock(16 + 15, 100, 16 + 0));
    try std.testing.expectEqual(@as(u4, 2), level.world_map.getBlockMetadata(16 + 15, 100, 16 + 0));
}

test "the position the server sends is applied to the player and acknowledged" {
    const gpa = std.testing.allocator;
    var level = try testLevel(gpa);
    defer level.deinit(gpa);
    level.attach();

    var player = game.Player.spawn(math.Vec3.init(0, 0, 0));
    try level.enter(gpa, &player);

    var connection: Connection = .{};
    defer connection.deinit(gpa);
    connection.state = .playing;

    try connection.handle(gpa, &level, testing_username, .{ .player_look_move = .{
        .x = 12.5,
        .y = 70.0 + game.Player.eye_height,
        .stance = 70.0,
        .z = -8.25,
        .yaw = 33.0,
        .pitch = -7.0,
        .on_ground = false,
    } });

    try std.testing.expect(connection.placed);
    try std.testing.expectApproxEqAbs(@as(f64, 12.5), player.base.position.x, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 70.0), player.base.position.y, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f32, 33.0), player.yaw, 1.0e-6);

    try connection.reportPosition(gpa, &player);

    var sent: std.ArrayList(net.packet.Packet) = .empty;
    defer freeAll(gpa, &sent);
    try drain(gpa, &connection, &sent);

    try std.testing.expectEqual(@as(usize, 1), sent.items.len);
    const told = sent.items[0].player_look_move;
    try std.testing.expectApproxEqAbs(@as(f64, 70.0), told.y, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 70.0 + game.Player.eye_height), told.stance, 1.0e-9);
}

test "nothing is reported before the server has placed the player" {
    const gpa = std.testing.allocator;
    var connection: Connection = .{};
    defer connection.deinit(gpa);
    connection.state = .playing;

    var player = game.Player.spawn(math.Vec3.init(1, 2, 3));
    try connection.reportPosition(gpa, &player);

    const bytes = try connection.takeOutbox(gpa);
    defer gpa.free(bytes);
    try std.testing.expectEqual(@as(usize, 0), bytes.len);
}
