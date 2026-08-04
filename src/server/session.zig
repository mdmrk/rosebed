const std = @import("std");

const chunk_payload = @import("world").chunk_payload;
const game = @import("game");
const math = @import("math");
const net = @import("net");
const world = @import("world");

const Session = @This();

pub const State = enum { greeting, awaiting_login, playing, closed };

pub const view_radius: i32 = 8;
pub const chunks_per_tick: usize = 8;
pub const offline_server_id = "-";
pub const dig_finished: u8 = 2;
pub const reach_squared: f64 = 36.0;
pub const join_colour = "\u{00a7}e";

state: State = .greeting,
name: NameBuffer = .{},
player: ?*game.Player = null,
outbox: std.ArrayList(u8) = .empty,
sent_chunks: std.AutoHashMapUnmanaged(world.World.ChunkCoord, void) = .{},
tracked: std.AutoHashMapUnmanaged(game.Entity.Id, Tracked) = .{},
sent_health: i16 = std.math.maxInt(i16),
pending_chat: ?ChatLine = null,
kicked: bool = false,

pub const max_chat_in: usize = 100;
pub const track_range: f64 = 160.0;
pub const move_step_threshold: i32 = 8;
pub const relative_move_limit: i32 = 128;

pub const ChatLine = struct {
    bytes: [net.packet.max_chat]u8 = undefined,
    len: usize = 0,

    pub fn text(self: *const ChatLine) []const u8 {
        return self.bytes[0..self.len];
    }
};

fn chatAllowed(c: u8) bool {
    return c >= 32 and c < 127 and c != '`';
}

pub const Peer = struct {
    id: game.Entity.Id,
    body: Body,

    pub const Body = union(enum) {
        player: struct { name: []const u8, player: *const game.Player },
        mob: game.Entities.Mob,
    };

    pub fn position(self: Peer) math.Vec3 {
        return switch (self.body) {
            .player => |who| who.player.base.position,
            .mob => |entry| entry.animal.base.position,
        };
    }

    pub fn yaw(self: Peer) f32 {
        return switch (self.body) {
            .player => |who| who.player.yaw,
            .mob => |entry| entry.animal.yaw,
        };
    }

    pub fn pitch(self: Peer) f32 {
        return switch (self.body) {
            .player => |who| who.player.pitch,
            .mob => |entry| entry.animal.pitch,
        };
    }
};

pub const Tracked = struct {
    x: i32,
    y: i32,
    z: i32,
    yaw: i8,
    pitch: i8,
    watched: Snapshot = .{},
    seen: bool = true,

    pub fn place(self: *Tracked, now: Tracked) void {
        self.x = now.x;
        self.y = now.y;
        self.z = now.z;
        self.yaw = now.yaw;
        self.pitch = now.pitch;
        self.seen = true;
    }
};

pub const Snapshot = struct {
    bytes: [max_watched_bytes]u8 = undefined,
    len: usize = 0,

    pub fn text(self: *const Snapshot) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const max_watched_bytes: usize = 256;

fn watchedBytes(id: game.Entity.Id, entry: game.Entities.Mob, out: *Snapshot) ?[]const u8 {
    var watched: net.packet.Watched = .{};
    game.mob.watch(entry.type_id, entry.animal, &watched);

    var writer = std.Io.Writer.fixed(&out.bytes);
    net.packet.write(&writer, .{ .entity_metadata = .{
        .entity_id = @bitCast(id),
        .metadata = watched.view(),
    } }) catch return null;

    out.len = writer.buffered().len;
    return out.text();
}

fn encodePosition(value: f64) i32 {
    return math.util.floorDouble(value * 32.0);
}

fn encodeRotation(degrees: f32) i8 {
    return @truncate(@as(i32, @intFromFloat(@floor(degrees * 256.0 / 360.0))));
}

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

pub fn deinit(self: *Session, gpa: std.mem.Allocator) void {
    self.outbox.deinit(gpa);
    self.sent_chunks.deinit(gpa);
    self.tracked.deinit(gpa);
}

pub fn trackPeers(self: *Session, gpa: std.mem.Allocator, peers: []const Peer) !void {
    if (self.state != .playing) return;
    const mine = self.player orelse return;

    var entries = self.tracked.iterator();
    while (entries.next()) |entry| entry.value_ptr.seen = false;

    for (peers) |peer| {
        if (peer.id == mine.base.id) continue;
        if (peer.body == .mob and game.mob.get(peer.body.mob.type_id).wire_id == null) continue;
        if (mine.base.position.distanceTo(peer.position()) > track_range) continue;
        try self.trackOne(gpa, peer);
    }

    var stale: std.ArrayList(game.Entity.Id) = .empty;
    defer stale.deinit(gpa);

    var walk = self.tracked.iterator();
    while (walk.next()) |entry| {
        if (!entry.value_ptr.seen) try stale.append(gpa, entry.key_ptr.*);
    }

    for (stale.items) |id| {
        _ = self.tracked.remove(id);
        try self.send(gpa, .{ .destroy_entity = .{ .entity_id = @bitCast(id) } });
    }
}

fn trackOne(self: *Session, gpa: std.mem.Allocator, peer: Peer) !void {
    const at = peer.position();
    const now: Tracked = .{
        .x = encodePosition(at.x),
        .y = encodePosition(at.y),
        .z = encodePosition(at.z),
        .yaw = encodeRotation(peer.yaw()),
        .pitch = encodeRotation(peer.pitch()),
    };

    const entry = try self.tracked.getOrPut(gpa, peer.id);
    if (!entry.found_existing) {
        entry.value_ptr.* = now;
        return self.spawnPeer(gpa, peer, now, entry.value_ptr);
    }

    entry.value_ptr.seen = true;
    if (peer.body == .mob) try self.reportWatched(gpa, peer, entry.value_ptr);

    const was = entry.value_ptr.*;
    const dx = now.x - was.x;
    const dy = now.y - was.y;
    const dz = now.z - was.z;
    const moved = @abs(dx) >= move_step_threshold or @abs(dy) >= move_step_threshold or @abs(dz) >= move_step_threshold;
    const turned = @abs(@as(i32, now.yaw) - was.yaw) >= move_step_threshold or
        @abs(@as(i32, now.pitch) - was.pitch) >= move_step_threshold;

    const fits = @abs(dx) < relative_move_limit and @abs(dy) < relative_move_limit and @abs(dz) < relative_move_limit;
    if (!fits) {
        entry.value_ptr.place(now);
        return self.send(gpa, .{ .entity_teleport = .{
            .entity_id = @bitCast(peer.id),
            .x = now.x,
            .y = now.y,
            .z = now.z,
            .yaw = now.yaw,
            .pitch = now.pitch,
        } });
    }

    if (moved and turned) {
        entry.value_ptr.place(now);
        return self.send(gpa, .{ .rel_entity_move_look = .{
            .entity_id = @bitCast(peer.id),
            .dx = @truncate(dx),
            .dy = @truncate(dy),
            .dz = @truncate(dz),
            .yaw = now.yaw,
            .pitch = now.pitch,
        } });
    }
    if (moved) {
        entry.value_ptr.x = now.x;
        entry.value_ptr.y = now.y;
        entry.value_ptr.z = now.z;
        return self.send(gpa, .{ .rel_entity_move = .{
            .entity_id = @bitCast(peer.id),
            .dx = @truncate(dx),
            .dy = @truncate(dy),
            .dz = @truncate(dz),
        } });
    }
    if (turned) {
        entry.value_ptr.yaw = now.yaw;
        entry.value_ptr.pitch = now.pitch;
        return self.send(gpa, .{ .entity_look = .{
            .entity_id = @bitCast(peer.id),
            .yaw = now.yaw,
            .pitch = now.pitch,
        } });
    }
}

fn spawnPeer(self: *Session, gpa: std.mem.Allocator, peer: Peer, now: Tracked, entry: *Tracked) !void {
    switch (peer.body) {
        .player => |who| try self.send(gpa, .{ .named_entity_spawn = .{
            .entity_id = @bitCast(peer.id),
            .name = who.name,
            .x = now.x,
            .y = now.y,
            .z = now.z,
            .rotation = now.yaw,
            .pitch = now.pitch,
            .current_item = 0,
        } }),
        .mob => |body| {
            var watched: net.packet.Watched = .{};
            game.mob.watch(body.type_id, body.animal, &watched);

            try self.send(gpa, .{ .mob_spawn = .{
                .entity_id = @bitCast(peer.id),
                .kind = game.mob.get(body.type_id).wire_id.?,
                .x = now.x,
                .y = now.y,
                .z = now.z,
                .yaw = now.yaw,
                .pitch = now.pitch,
                .metadata = watched.view(),
            } });

            _ = watchedBytes(peer.id, body, &entry.watched);
        },
    }
}

fn reportWatched(self: *Session, gpa: std.mem.Allocator, peer: Peer, entry: *Tracked) !void {
    var fresh: Snapshot = .{};
    const encoded = watchedBytes(peer.id, peer.body.mob, &fresh) orelse return;
    if (std.mem.eql(u8, entry.watched.text(), encoded)) return;

    entry.watched = fresh;
    try self.outbox.appendSlice(gpa, encoded);
}

pub fn reportHealth(self: *Session, gpa: std.mem.Allocator) !void {
    if (self.state != .playing) return;
    const player = self.player orelse return;

    const health: i16 = @intCast(std.math.clamp(player.health, 0, std.math.maxInt(i16)));
    if (health == self.sent_health) return;

    self.sent_health = health;
    try self.send(gpa, .{ .update_health = .{ .health = health } });
}

pub fn send(self: *Session, gpa: std.mem.Allocator, message: net.packet.Packet) !void {
    var allocating: std.Io.Writer.Allocating = .fromArrayList(gpa, &self.outbox);
    defer self.outbox = allocating.toArrayList();
    try net.packet.write(&allocating.writer, message);
}

pub fn takeOutbox(self: *Session, gpa: std.mem.Allocator) ![]u8 {
    const bytes = try self.outbox.toOwnedSlice(gpa);
    return bytes;
}

pub fn kick(self: *Session, gpa: std.mem.Allocator, reason: []const u8) !void {
    try self.send(gpa, .{ .kick_disconnect = .{ .reason = reason } });
    self.state = .closed;
    self.kicked = true;
}

pub fn handle(
    self: *Session,
    gpa: std.mem.Allocator,
    level: *game.Level,
    message: net.packet.Packet,
) !void {
    switch (self.state) {
        .closed => {},
        .greeting => switch (message) {
            .handshake => {
                self.state = .awaiting_login;
                try self.send(gpa, .{ .handshake = .{ .username = offline_server_id } });
            },
            else => try self.kick(gpa, "Protocol error"),
        },
        .awaiting_login => switch (message) {
            .login => |body| try self.acceptLogin(gpa, level, body.protocol_version, body.username),
            else => try self.kick(gpa, "Protocol error"),
        },
        .playing => try self.handlePlaying(gpa, level, message),
    }
}

fn acceptLogin(
    self: *Session,
    gpa: std.mem.Allocator,
    level: *game.Level,
    protocol: i32,
    username: []const u8,
) !void {
    if (protocol != net.packet.protocol_version) {
        return self.kick(gpa, if (protocol > net.packet.protocol_version) "Outdated server!" else "Outdated client!");
    }

    self.name.set(username);

    const player = try gpa.create(game.Player);
    errdefer gpa.destroy(player);
    player.* = game.Player.spawn(spawnPlacement(level));
    player.name.set(self.name.text());
    try level.enter(gpa, player);
    self.player = player;
    self.state = .playing;

    try self.send(gpa, .{ .login = .{
        .protocol_version = @intCast(player.base.id),
        .username = "",
        .map_seed = level.generator.world_seed,
        .dimension = 0,
    } });
    try self.send(gpa, .{ .spawn_position = .{
        .x = level.spawn[0],
        .y = level.spawn[1],
        .z = level.spawn[2],
    } });
    try self.sendPosition(gpa);
    try self.send(gpa, .{ .update_time = .{ .time = level.world_map.time } });
}

fn spawnPlacement(level: *const game.Level) math.Vec3 {
    return .{
        .x = @as(f64, @floatFromInt(level.spawn[0])) + 0.5,
        .y = @floatFromInt(level.spawn[1]),
        .z = @as(f64, @floatFromInt(level.spawn[2])) + 0.5,
    };
}

pub fn sendPosition(self: *Session, gpa: std.mem.Allocator) !void {
    const player = self.player orelse return;
    try self.send(gpa, .{ .player_look_move = .{
        .x = player.base.position.x,
        .y = player.base.position.y + game.Player.eye_height,
        .stance = player.base.position.y,
        .z = player.base.position.z,
        .yaw = player.yaw,
        .pitch = player.pitch,
        .on_ground = false,
    } });
}

fn handlePlaying(
    self: *Session,
    gpa: std.mem.Allocator,
    level: *game.Level,
    message: net.packet.Packet,
) !void {
    const player = self.player orelse return;
    switch (message) {
        .keep_alive => try self.send(gpa, .keep_alive),
        .flying => |body| player.base.on_ground = body.on_ground,
        .player_position => |body| {
            moveTo(player, body.x, body.y, body.z);
            player.base.on_ground = body.on_ground;
        },
        .player_look => |body| {
            player.yaw = body.yaw;
            player.pitch = body.pitch;
            player.base.on_ground = body.on_ground;
        },
        .player_look_move => |body| {
            moveTo(player, body.x, body.y, body.z);
            player.yaw = body.yaw;
            player.pitch = body.pitch;
            player.base.on_ground = body.on_ground;
        },
        .block_item_switch => |body| {
            if (body.slot >= 0 and body.slot < game.Inventory.hotbar_size) {
                player.inventory.selected = @intCast(body.slot);
            }
        },
        .block_dig => |body| try self.digBlock(gpa, level, body.status, body.x, body.y, body.z),
        .place => |body| try self.placeBlock(gpa, level, body.x, body.y, body.z, body.face, body.held),
        .chat => |body| try self.handleChat(gpa, body.message),
        .kick_disconnect => self.state = .closed,
        else => {},
    }
}

fn handleChat(self: *Session, gpa: std.mem.Allocator, message: []const u8) !void {
    if (message.len > max_chat_in) return self.kick(gpa, "Chat message too long");

    const trimmed = std.mem.trim(u8, message, " ");
    for (trimmed) |c| {
        if (!chatAllowed(c)) return self.kick(gpa, "Illegal characters in chat");
    }
    if (trimmed.len == 0) return;
    if (trimmed[0] == '/') return;

    var line: ChatLine = .{};
    const written = std.fmt.bufPrint(&line.bytes, "<{s}> {s}", .{ self.name.text(), trimmed }) catch return;
    line.len = written.len;
    self.pending_chat = line;
}

pub fn takeChat(self: *Session) ?ChatLine {
    const line = self.pending_chat orelse return null;
    self.pending_chat = null;
    return line;
}

pub fn announce(self: *Session, gpa: std.mem.Allocator, who: []const u8, joined: bool) !void {
    if (self.state != .playing) return;

    var buffer: [net.packet.max_chat]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, "{s}{s} {s} the game.", .{
        join_colour,
        who,
        if (joined) "joined" else "left",
    }) catch return;

    try self.send(gpa, .{ .chat = .{ .message = line } });
}

pub fn sendChat(self: *Session, gpa: std.mem.Allocator, line: []const u8) !void {
    if (self.state != .playing) return;
    try self.send(gpa, .{ .chat = .{ .message = line } });
}

fn withinReach(player: *const game.Player, x: i32, y: i32, z: i32) bool {
    const dx = player.base.position.x - (@as(f64, @floatFromInt(x)) + 0.5);
    const dy = player.base.position.y - (@as(f64, @floatFromInt(y)) + 0.5);
    const dz = player.base.position.z - (@as(f64, @floatFromInt(z)) + 0.5);
    return dx * dx + dy * dy + dz * dz <= reach_squared;
}

fn digBlock(
    self: *Session,
    gpa: std.mem.Allocator,
    level: *game.Level,
    status: u8,
    x: i32,
    y: u8,
    z: i32,
) !void {
    if (status != dig_finished) return;

    const player = self.player orelse return;
    const height: i32 = y;
    if (!withinReach(player, x, height, z)) return;

    const broken = level.world_map.getBlock(x, height, z);
    if (broken == .air) return;

    const meta = level.world_map.getBlockMetadata(x, height, z);
    try level.world_map.setBlockWithNotify(x, height, z, .air);
    _ = level.world_map.removeSign(x, height, z);

    if (broken.drop(meta, &level.world_map.rand)) |dropped| {
        try level.dropStackAt(gpa, x, height, z, .{
            .id = dropped.id,
            .count = dropped.count,
            .meta = dropped.meta,
        });
    }
}

fn placeBlock(
    self: *Session,
    _: std.mem.Allocator,
    level: *game.Level,
    x: i32,
    y: u8,
    z: i32,
    face: u8,
    held: ?net.packet.Stack,
) !void {
    const player = self.player orelse return;
    const stack = held orelse return;
    if (face > 5) return;

    const placed = switch (world.Id.fromNumeric(stack.id)) {
        .block => |id| id,
        .item => return,
    };
    if (placed == .air) return;

    const target = world.block_update.placementTarget(
        &level.world_map,
        x,
        @as(i32, y),
        z,
        @enumFromInt(face),
    );
    if (target.y < 0 or target.y >= world.constants.chunk_height) return;
    if (!withinReach(player, target.x, target.y, target.z)) return;
    if (level.world_map.getBlock(target.x, target.y, target.z).isSolid()) return;
    if (!world.block_update.canPlaceAt(&level.world_map, target.x, target.y, target.z, placed)) return;

    try level.world_map.setBlockWithNotify(target.x, target.y, target.z, placed);
}

pub fn sendBlockChange(
    self: *Session,
    gpa: std.mem.Allocator,
    x: i32,
    y: i32,
    z: i32,
    block: world.Block,
    metadata: u4,
) !void {
    if (self.state != .playing) return;
    if (y < 0 or y >= world.constants.chunk_height) return;

    const width = world.constants.chunk_width;
    const coord: world.World.ChunkCoord = .{ .x = @divFloor(x, width), .z = @divFloor(z, width) };
    if (!self.sent_chunks.contains(coord)) return;

    try self.send(gpa, .{ .block_change = .{
        .x = x,
        .y = @intCast(y),
        .z = z,
        .block = @intFromEnum(block),
        .metadata = metadata,
    } });
}

fn moveTo(player: *game.Player, x: f64, y: f64, z: f64) void {
    player.base.position = .{ .x = x, .y = y, .z = z };
    player.base.prev_position = player.base.position;
}

fn playerChunk(player: *const game.Player) world.World.ChunkCoord {
    const width = world.constants.chunk_width;
    return .{
        .x = @divFloor(math.util.floorDouble(player.base.position.x), width),
        .z = @divFloor(math.util.floorDouble(player.base.position.z), width),
    };
}

pub fn streamChunks(self: *Session, gpa: std.mem.Allocator, level: *game.Level, budget: usize) !usize {
    if (self.state != .playing) return 0;
    const player = self.player orelse return 0;
    const centre = playerChunk(player);

    var sent: usize = 0;
    var ring: i32 = 0;
    while (ring <= view_radius) : (ring += 1) {
        var offset_x: i32 = -ring;
        while (offset_x <= ring) : (offset_x += 1) {
            var offset_z: i32 = -ring;
            while (offset_z <= ring) : (offset_z += 1) {
                if (@max(@abs(offset_x), @abs(offset_z)) != ring) continue;

                const coord: world.World.ChunkCoord = .{ .x = centre.x + offset_x, .z = centre.z + offset_z };
                if (self.sent_chunks.contains(coord)) continue;

                try self.sendChunk(gpa, level, coord);
                try self.sent_chunks.put(gpa, coord, {});

                sent += 1;
                if (sent >= budget) return sent;
            }
        }
    }
    return sent;
}

fn sendChunk(self: *Session, gpa: std.mem.Allocator, level: *game.Level, coord: world.World.ChunkCoord) !void {
    var dx: i32 = -1;
    while (dx <= 1) : (dx += 1) {
        var dz: i32 = -1;
        while (dz <= 1) : (dz += 1) {
            try level.world_map.ensureDecorated(level.generator, coord.x + dx, coord.z + dz);
        }
    }

    const chunk = level.world_map.getChunk(coord.x, coord.z) orelse return;

    try self.send(gpa, .{ .pre_chunk = .{ .x = coord.x, .z = coord.z, .load = true } });

    const compressed = try chunk_payload.compressFull(gpa, chunk);
    defer gpa.free(compressed);

    try self.send(gpa, .{ .map_chunk = .{
        .x = coord.x * world.constants.chunk_width,
        .y = 0,
        .z = coord.z * world.constants.chunk_width,
        .size_x = chunk_payload.size_x,
        .size_y = chunk_payload.size_y,
        .size_z = chunk_payload.size_z,
        .compressed = compressed,
    } });
}

pub fn leave(self: *Session, gpa: std.mem.Allocator, level: *game.Level) void {
    const player = self.player orelse return;
    level.leave(player);
    gpa.destroy(player);
    self.player = null;
    self.state = .closed;
}

fn testLevel(gpa: std.mem.Allocator) !game.Level {
    var level = game.Level.init(gpa, try world.TerrainGenerator.init(gpa, 99));
    errdefer level.deinit(gpa);
    level.spawn = .{ 8, 64, 8 };
    return level;
}

fn drain(gpa: std.mem.Allocator, session: *Session, out: *std.ArrayList(net.packet.Packet)) !void {
    const bytes = try session.takeOutbox(gpa);
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

test "a handshake is answered with the offline server id" {
    const gpa = std.testing.allocator;
    var level = try testLevel(gpa);
    defer level.deinit(gpa);
    level.attach();

    var session: Session = .{};
    defer session.deinit(gpa);

    try session.handle(gpa, &level, .{ .handshake = .{ .username = "Steve" } });
    try std.testing.expectEqual(State.awaiting_login, session.state);

    var replies: std.ArrayList(net.packet.Packet) = .empty;
    defer freeAll(gpa, &replies);
    try drain(gpa, &session, &replies);

    try std.testing.expectEqual(@as(usize, 1), replies.items.len);
    try std.testing.expectEqualStrings(offline_server_id, replies.items[0].handshake.username);
}

test "a login on the right protocol is answered with the joining sequence" {
    const gpa = std.testing.allocator;
    var level = try testLevel(gpa);
    defer level.deinit(gpa);
    level.attach();

    var session: Session = .{};
    defer session.deinit(gpa);
    defer session.leave(gpa, &level);

    try session.handle(gpa, &level, .{ .handshake = .{ .username = "Steve" } });
    try session.handle(gpa, &level, .{ .login = .{
        .protocol_version = net.packet.protocol_version,
        .username = "Steve",
        .map_seed = 0,
        .dimension = 0,
    } });

    try std.testing.expectEqual(State.playing, session.state);
    try std.testing.expectEqualStrings("Steve", session.name.text());
    try std.testing.expectEqual(@as(usize, 1), level.occupants.items.len);

    var replies: std.ArrayList(net.packet.Packet) = .empty;
    defer freeAll(gpa, &replies);
    try drain(gpa, &session, &replies);

    const expected = [_]net.packet.Id{ .handshake, .login, .spawn_position, .player_look_move, .update_time };
    try std.testing.expectEqual(expected.len, replies.items.len);
    for (expected, replies.items) |want, got| try std.testing.expectEqual(want, got.id());

    try std.testing.expectEqual(level.generator.world_seed, replies.items[1].login.map_seed);
    try std.testing.expectEqual(@as(i32, 8), replies.items[2].spawn_position.x);
}

test "a login carries the entity id the level handed the player" {
    const gpa = std.testing.allocator;
    var level = try testLevel(gpa);
    defer level.deinit(gpa);
    level.attach();

    var session: Session = .{};
    defer session.deinit(gpa);
    defer session.leave(gpa, &level);

    try session.handle(gpa, &level, .{ .handshake = .{ .username = "Steve" } });
    try session.handle(gpa, &level, .{ .login = .{
        .protocol_version = net.packet.protocol_version,
        .username = "Steve",
        .map_seed = 0,
        .dimension = 0,
    } });

    var replies: std.ArrayList(net.packet.Packet) = .empty;
    defer freeAll(gpa, &replies);
    try drain(gpa, &session, &replies);

    const announced: u32 = @intCast(replies.items[1].login.protocol_version);
    try std.testing.expectEqual(session.player.?.base.id, announced);
    try std.testing.expect(announced != game.Entity.no_id);
}

test "an outdated protocol is kicked with the message vanilla uses" {
    const gpa = std.testing.allocator;
    var level = try testLevel(gpa);
    defer level.deinit(gpa);
    level.attach();

    for ([_]i32{ 13, 15 }) |protocol| {
        var session: Session = .{};
        defer session.deinit(gpa);

        session.state = .awaiting_login;
        try session.handle(gpa, &level, .{ .login = .{
            .protocol_version = protocol,
            .username = "Steve",
            .map_seed = 0,
            .dimension = 0,
        } });

        try std.testing.expectEqual(State.closed, session.state);
        try std.testing.expectEqual(@as(usize, 0), level.occupants.items.len);

        var replies: std.ArrayList(net.packet.Packet) = .empty;
        defer freeAll(gpa, &replies);
        try drain(gpa, &session, &replies);

        const wanted = if (protocol < net.packet.protocol_version) "Outdated client!" else "Outdated server!";
        try std.testing.expectEqualStrings(wanted, replies.items[0].kick_disconnect.reason);
    }
}

test "a packet out of turn is a protocol error" {
    const gpa = std.testing.allocator;
    var level = try testLevel(gpa);
    defer level.deinit(gpa);
    level.attach();

    var session: Session = .{};
    defer session.deinit(gpa);

    try session.handle(gpa, &level, .{ .chat = .{ .message = "hello" } });

    try std.testing.expectEqual(State.closed, session.state);
    try std.testing.expect(session.kicked);
}

test "the position the server sends puts the eye line in y and the feet in stance" {
    const gpa = std.testing.allocator;
    var level = try testLevel(gpa);
    defer level.deinit(gpa);
    level.attach();

    var session: Session = .{};
    defer session.deinit(gpa);
    defer session.leave(gpa, &level);

    try session.handle(gpa, &level, .{ .handshake = .{ .username = "Steve" } });
    try session.handle(gpa, &level, .{ .login = .{
        .protocol_version = net.packet.protocol_version,
        .username = "Steve",
        .map_seed = 0,
        .dimension = 0,
    } });

    var replies: std.ArrayList(net.packet.Packet) = .empty;
    defer freeAll(gpa, &replies);
    try drain(gpa, &session, &replies);

    const placed = replies.items[3].player_look_move;
    try std.testing.expectApproxEqAbs(@as(f64, 8.5), placed.x, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 64.0), placed.stance, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 64.0 + game.Player.eye_height), placed.y, 1.0e-9);
}

test "a moving client drags its player along behind it" {
    const gpa = std.testing.allocator;
    var level = try testLevel(gpa);
    defer level.deinit(gpa);
    level.attach();

    var session: Session = .{};
    defer session.deinit(gpa);
    defer session.leave(gpa, &level);

    try session.handle(gpa, &level, .{ .handshake = .{ .username = "Steve" } });
    try session.handle(gpa, &level, .{ .login = .{
        .protocol_version = net.packet.protocol_version,
        .username = "Steve",
        .map_seed = 0,
        .dimension = 0,
    } });

    try session.handle(gpa, &level, .{ .player_look_move = .{
        .x = 40.25,
        .y = 70.0,
        .stance = 70.0 + game.Player.eye_height,
        .z = -12.5,
        .yaw = 90.0,
        .pitch = -20.0,
        .on_ground = true,
    } });

    const player = session.player.?;
    try std.testing.expectApproxEqAbs(@as(f64, 40.25), player.base.position.x, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 70.0), player.base.position.y, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -12.5), player.base.position.z, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f32, 90.0), player.yaw, 1.0e-6);
    try std.testing.expect(player.base.on_ground);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try level.tick(gpa, arena.allocator());
    try std.testing.expectApproxEqAbs(@as(f64, 40.25), level.players().views[0].position.x, 1.0e-9);
}

test "a keep alive is answered so the client knows the server is still there" {
    const gpa = std.testing.allocator;
    var level = try testLevel(gpa);
    defer level.deinit(gpa);
    level.attach();

    var session: Session = .{};
    defer session.deinit(gpa);
    defer session.leave(gpa, &level);

    try session.handle(gpa, &level, .{ .handshake = .{ .username = "Steve" } });
    try session.handle(gpa, &level, .{ .login = .{
        .protocol_version = net.packet.protocol_version,
        .username = "Steve",
        .map_seed = 0,
        .dimension = 0,
    } });
    const joining = try session.takeOutbox(gpa);
    gpa.free(joining);

    try session.handle(gpa, &level, .keep_alive);

    var replies: std.ArrayList(net.packet.Packet) = .empty;
    defer freeAll(gpa, &replies);
    try drain(gpa, &session, &replies);

    try std.testing.expectEqual(@as(usize, 1), replies.items.len);
    try std.testing.expectEqual(net.packet.Id.keep_alive, replies.items[0].id());
}

fn joinedSession(gpa: std.mem.Allocator, level: *game.Level, session: *Session) !void {
    try session.handle(gpa, level, .{ .handshake = .{ .username = "Digger" } });
    try session.handle(gpa, level, .{ .login = .{
        .protocol_version = net.packet.protocol_version,
        .username = "Digger",
        .map_seed = 0,
        .dimension = 0,
    } });
    const joining = try session.takeOutbox(gpa);
    gpa.free(joining);
}

fn stoneFloorLevel(gpa: std.mem.Allocator) !game.Level {
    var level = try testLevel(gpa);
    errdefer level.deinit(gpa);

    var chunk_x: i32 = -1;
    while (chunk_x <= 1) : (chunk_x += 1) {
        var chunk_z: i32 = -1;
        while (chunk_z <= 1) : (chunk_z += 1) {
            const chunk = try level.world_map.createChunk(chunk_x, chunk_z);
            for (0..world.constants.chunk_width) |x| {
                for (0..world.constants.chunk_width) |z| {
                    chunk.setBlock(@intCast(x), 63, @intCast(z), .stone);
                }
            }
        }
    }
    return level;
}

test "a finished dig takes the block out of the world and leaves its drop" {
    const gpa = std.testing.allocator;
    var level = try stoneFloorLevel(gpa);
    defer level.deinit(gpa);
    level.attach();

    var session: Session = .{};
    defer session.deinit(gpa);
    defer session.leave(gpa, &level);
    try joinedSession(gpa, &level, &session);

    session.player.?.base.position = .{ .x = 8.5, .y = 64, .z = 8.5 };

    try session.handle(gpa, &level, .{ .block_dig = .{
        .status = dig_finished,
        .x = 8,
        .y = 63,
        .z = 8,
        .face = 1,
    } });

    try std.testing.expectEqual(world.Block.air, level.world_map.getBlock(8, 63, 8));
    try std.testing.expectEqual(@as(usize, 1), level.entities.items.items.len);
    try std.testing.expectEqual(world.Id{ .block = .cobblestone }, level.entities.items.items[0].stack.id);
}

test "a dig that has only started leaves the block alone" {
    const gpa = std.testing.allocator;
    var level = try stoneFloorLevel(gpa);
    defer level.deinit(gpa);
    level.attach();

    var session: Session = .{};
    defer session.deinit(gpa);
    defer session.leave(gpa, &level);
    try joinedSession(gpa, &level, &session);

    session.player.?.base.position = .{ .x = 8.5, .y = 64, .z = 8.5 };
    try session.handle(gpa, &level, .{ .block_dig = .{ .status = 0, .x = 8, .y = 63, .z = 8, .face = 1 } });

    try std.testing.expectEqual(world.Block.stone, level.world_map.getBlock(8, 63, 8));
}

test "a block out of arm's reach cannot be dug" {
    const gpa = std.testing.allocator;
    var level = try stoneFloorLevel(gpa);
    defer level.deinit(gpa);
    level.attach();

    var session: Session = .{};
    defer session.deinit(gpa);
    defer session.leave(gpa, &level);
    try joinedSession(gpa, &level, &session);

    session.player.?.base.position = .{ .x = 8.5, .y = 64, .z = 8.5 };
    try std.testing.expectEqual(world.Block.stone, level.world_map.getBlock(8, 63, 28));

    try session.handle(gpa, &level, .{ .block_dig = .{
        .status = dig_finished,
        .x = 8,
        .y = 63,
        .z = 28,
        .face = 1,
    } });

    try std.testing.expectEqual(world.Block.stone, level.world_map.getBlock(8, 63, 28));
}

test "a place puts the held block against the face the client clicked" {
    const gpa = std.testing.allocator;
    var level = try stoneFloorLevel(gpa);
    defer level.deinit(gpa);
    level.attach();

    var session: Session = .{};
    defer session.deinit(gpa);
    defer session.leave(gpa, &level);
    try joinedSession(gpa, &level, &session);

    session.player.?.base.position = .{ .x = 8.5, .y = 64, .z = 8.5 };
    try session.handle(gpa, &level, .{ .place = .{
        .x = 8,
        .y = 63,
        .z = 8,
        .face = 1,
        .held = .{ .id = @intFromEnum(world.Block.planks), .count = 1, .damage = 0 },
    } });

    try std.testing.expectEqual(world.Block.planks, level.world_map.getBlock(8, 64, 8));
}

test "an empty hand and an item that is not a block place nothing" {
    const gpa = std.testing.allocator;
    var level = try stoneFloorLevel(gpa);
    defer level.deinit(gpa);
    level.attach();

    var session: Session = .{};
    defer session.deinit(gpa);
    defer session.leave(gpa, &level);
    try joinedSession(gpa, &level, &session);

    session.player.?.base.position = .{ .x = 8.5, .y = 64, .z = 8.5 };

    try session.handle(gpa, &level, .{ .place = .{ .x = 8, .y = 63, .z = 8, .face = 1, .held = null } });
    try std.testing.expectEqual(world.Block.air, level.world_map.getBlock(8, 64, 8));

    try session.handle(gpa, &level, .{ .place = .{
        .x = 8,
        .y = 63,
        .z = 8,
        .face = 1,
        .held = .{ .id = 280, .count = 1, .damage = 0 },
    } });
    try std.testing.expectEqual(world.Block.air, level.world_map.getBlock(8, 64, 8));
}

fn mobPeers(gpa: std.mem.Allocator, level: *game.Level, out: *std.ArrayList(Peer)) !void {
    out.clearRetainingCapacity();
    for (level.entities.mobs.items) |entry| {
        try out.append(gpa, .{ .id = entry.animal.base.id, .body = .{ .mob = entry } });
    }
}

test "a mob is spawned once, then only its changes are sent after that" {
    const gpa = std.testing.allocator;
    var level = try stoneFloorLevel(gpa);
    defer level.deinit(gpa);
    level.attach();

    var session: Session = .{};
    defer session.deinit(gpa);
    defer session.leave(gpa, &level);
    try joinedSession(gpa, &level, &session);
    session.player.?.base.position = .{ .x = 8.5, .y = 64, .z = 8.5 };

    const animal = try level.entities.spawnMob(gpa, game.mob.sheep, .{ .x = 9.5, .y = 64, .z = 8.5 }, &level.world_map.rand);
    const sheep: *game.Sheep = @fieldParentPtr("animal", animal);
    sheep.fleece_color = 12;

    var peers: std.ArrayList(Peer) = .empty;
    defer peers.deinit(gpa);
    try mobPeers(gpa, &level, &peers);

    try session.trackPeers(gpa, peers.items);

    var replies: std.ArrayList(net.packet.Packet) = .empty;
    defer freeAll(gpa, &replies);
    try drain(gpa, &session, &replies);

    try std.testing.expectEqual(@as(usize, 1), replies.items.len);
    const spawned = replies.items[0].mob_spawn;
    try std.testing.expectEqual(game.Sheep.wire_id, spawned.kind);
    try std.testing.expectEqual(@as(i8, 12), spawned.metadata.byteAt(game.Sheep.watched_fleece).?);

    try session.trackPeers(gpa, peers.items);
    const quiet = try session.takeOutbox(gpa);
    defer gpa.free(quiet);
    try std.testing.expectEqual(@as(usize, 0), quiet.len);

    sheep.sheared = true;
    try session.trackPeers(gpa, peers.items);

    var updates: std.ArrayList(net.packet.Packet) = .empty;
    defer freeAll(gpa, &updates);
    try drain(gpa, &session, &updates);

    try std.testing.expectEqual(@as(usize, 1), updates.items.len);
    const changed = updates.items[0].entity_metadata;
    try std.testing.expectEqual(@as(u32, @bitCast(changed.entity_id)), animal.base.id);
    try std.testing.expectEqual(@as(i8, 12 | 16), changed.metadata.byteAt(game.Sheep.watched_fleece).?);
}

test "a block change only reaches a player who has been sent that chunk" {
    const gpa = std.testing.allocator;
    var level = try stoneFloorLevel(gpa);
    defer level.deinit(gpa);
    level.attach();

    var session: Session = .{};
    defer session.deinit(gpa);
    defer session.leave(gpa, &level);
    try joinedSession(gpa, &level, &session);

    try session.sendBlockChange(gpa, 8, 63, 8, .stone, 0);
    const unsent = try session.takeOutbox(gpa);
    gpa.free(unsent);
    try std.testing.expectEqual(@as(usize, 0), unsent.len);

    try session.sent_chunks.put(gpa, .{ .x = 0, .z = 0 }, {});
    try session.sendBlockChange(gpa, 8, 63, 8, .stone, 5);

    var replies: std.ArrayList(net.packet.Packet) = .empty;
    defer freeAll(gpa, &replies);
    try drain(gpa, &session, &replies);

    try std.testing.expectEqual(@as(usize, 1), replies.items.len);
    const change = replies.items[0].block_change;
    try std.testing.expectEqual(@as(i32, 8), change.x);
    try std.testing.expectEqual(@as(u8, 63), change.y);
    try std.testing.expectEqual(@intFromEnum(world.Block.stone), change.block);
    try std.testing.expectEqual(@as(u8, 5), change.metadata);
}
