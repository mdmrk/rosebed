const std = @import("std");

const chunk_payload = @import("world").chunk_payload;
const game = @import("game");
const math = @import("math");
const net = @import("net");
const world = @import("world");

const Window = @import("Window.zig");

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
sent_bed: ?[3]i32 = null,
pending_chat: ?ChatLine = null,
pending_swing: bool = false,
equipment: [equipment_slots]?world.Stack = @splat(null),
riding: game.Entity.Id = game.Entity.no_id,
crafting: [Window.crafting_grid]?world.Stack = @splat(null),
workbench: [Window.workbench_grid]?world.Stack = @splat(null),
carried: ?world.Stack = null,
mirror: [Window.max_slots]?world.Stack = @splat(null),
mirror_used: usize = 0,
mirror_carried: ?world.Stack = null,
open: Open = .player,
window_id: i8 = player_window,
next_window_id: i8 = 1,
progress: [3]i16 = @splat(-1),
pending_sign: ?world.World.BlockPos = null,
quiet_ticks: u32 = 0,
last_height: f64 = 0,
dimension: world.Dimension = .overworld,
raining: bool = false,
emptied_on_death: bool = false,
kicked: bool = false,

pub const max_chat_in: usize = 100;
pub const track_range: f64 = 160.0;
pub const player_track_range: f64 = 512.0;
pub const close_track_range: f64 = 64.0;
pub const move_step_threshold: i32 = 8;
pub const relative_move_limit: i32 = 128;
pub const player_update_period: u32 = 2;
pub const mob_update_period: u32 = 3;
pub const vehicle_update_period: u32 = 5;
pub const fireball_update_period: u32 = 10;
pub const slow_update_period: u32 = 20;
pub const still_update_period: u32 = std.math.maxInt(u32);
pub const resync_period: u32 = 400;

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
        item: *const game.ItemEntity,
        arrow: *const game.Arrow,
        fireball: *const game.Fireball,
        falling_block: *const game.FallingBlock,
        boat: *const game.Boat,
        minecart: *const game.Minecart,
        hook: *const game.FishHook,
        painting: *const game.Painting,
    };

    pub fn position(self: Peer) math.Vec3 {
        return switch (self.body) {
            .player => |who| who.player.base.position,
            .mob => |entry| entry.animal.base.position,
            .painting => |hung| hung.position,
            inline else => |it| it.base.position,
        };
    }

    pub fn yaw(self: Peer) f32 {
        return switch (self.body) {
            .player => |who| who.player.yaw,
            .mob => |entry| entry.animal.yaw,
            .item, .falling_block, .painting => 0,
            inline else => |it| it.yaw,
        };
    }

    pub fn pitch(self: Peer) f32 {
        return switch (self.body) {
            .player => |who| who.player.pitch,
            .mob => |entry| entry.animal.pitch,
            .item, .falling_block, .painting => 0,
            inline else => |it| it.pitch,
        };
    }
};

pub const Tracked = struct {
    x: i32,
    y: i32,
    z: i32,
    yaw: i8,
    pitch: i8,
    period: u32 = player_update_period,
    updates: u32 = 0,
    since_resync: u32 = 0,
    hurt_time: i32 = 0,
    alive: bool = true,
    motion: math.Vec3 = math.Vec3.init(0, 0, 0),
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

pub const status_hurt: i8 = 2;
pub const status_death: i8 = 3;
pub const velocity_epsilon: f64 = 0.02;
pub const velocity_scale: f64 = 8000.0;

fn peerHurtTime(peer: Peer) i32 {
    return switch (peer.body) {
        .player => |who| who.player.hurt_time,
        .mob => |entry| entry.animal.hurt_time,
        else => 0,
    };
}

fn peerAlive(peer: Peer) bool {
    return switch (peer.body) {
        .player => |who| who.player.health > 0,
        .mob => |entry| entry.animal.health > 0,
        else => true,
    };
}

fn peerMotion(peer: Peer) math.Vec3 {
    return switch (peer.body) {
        .player => |who| who.player.base.motion,
        .mob => |entry| entry.animal.base.motion,
        .painting => math.Vec3.init(0, 0, 0),
        inline else => |it| it.base.motion,
    };
}

fn sendsMotion(peer: Peer) bool {
    return switch (peer.body) {
        .item, .boat, .minecart, .falling_block, .hook => true,
        .mob => |entry| entry.type_id == game.mob.squid,
        else => false,
    };
}

fn encodeVelocity(value: f64) i16 {
    return @truncate(@as(i32, @intFromFloat(value * velocity_scale)));
}

fn trackRange(peer: Peer) f64 {
    return switch (peer.body) {
        .player => player_track_range,
        .item, .arrow, .fireball, .hook => close_track_range,
        else => track_range,
    };
}

fn updatePeriod(peer: Peer) u32 {
    return switch (peer.body) {
        .player => player_update_period,
        .mob => mob_update_period,
        .hook, .boat, .minecart => vehicle_update_period,
        .fireball => fireball_update_period,
        .item, .arrow, .falling_block => slow_update_period,
        .painting => still_update_period,
    };
}

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

fn withinTrackRange(watcher: math.Vec3, peer: Peer) bool {
    // Vanilla measures the two flat axes separately, not the diagonal.
    const reach = trackRange(peer);
    const at = peer.position();
    return @abs(watcher.x - at.x) <= reach and @abs(watcher.z - at.z) <= reach;
}

pub fn collectWorldPeers(
    gpa: std.mem.Allocator,
    level: *const game.Level,
    out: *std.ArrayList(Peer),
) !void {
    for (level.entities.mobs.items) |entry| {
        try out.append(gpa, .{ .id = entry.animal.base.id, .body = .{ .mob = entry } });
    }
    inline for (.{
        .{ "items", "item" },
        .{ "arrows", "arrow" },
        .{ "fireballs", "fireball" },
        .{ "falling_blocks", "falling_block" },
        .{ "boats", "boat" },
        .{ "minecarts", "minecart" },
        .{ "hooks", "hook" },
    }) |pair| {
        for (@field(level.entities, pair[0]).items) |*entity| {
            try out.append(gpa, .{ .id = entity.base.id, .body = @unionInit(Peer.Body, pair[1], entity) });
        }
    }
    for (level.entities.paintings.items) |*hung| {
        try out.append(gpa, .{ .id = hung.id, .body = .{ .painting = hung } });
    }
}

pub fn trackPeers(self: *Session, gpa: std.mem.Allocator, peers: []const Peer) !void {
    if (self.state != .playing) return;
    const mine = self.player orelse return;

    var entries = self.tracked.iterator();
    while (entries.next()) |entry| entry.value_ptr.seen = false;

    for (peers) |peer| {
        if (peer.id == mine.base.id) continue;
        if (peer.body == .mob and game.mob.get(peer.body.mob.type_id).wire_id == null) continue;
        if (!withinTrackRange(mine.base.position, peer)) continue;
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
        entry.value_ptr.period = updatePeriod(peer);
        entry.value_ptr.hurt_time = peerHurtTime(peer);
        entry.value_ptr.alive = peerAlive(peer);
        entry.value_ptr.motion = peerMotion(peer);
        return self.spawnPeer(gpa, peer, now, entry.value_ptr);
    }

    entry.value_ptr.seen = true;
    if (peer.body == .mob) try self.reportWatched(gpa, peer, entry.value_ptr);
    try self.reportStatus(gpa, peer, entry.value_ptr);

    entry.value_ptr.since_resync += 1;
    entry.value_ptr.updates += 1;
    if (entry.value_ptr.updates % entry.value_ptr.period != 0) return;

    try self.reportVelocity(gpa, peer, entry.value_ptr);

    const was = entry.value_ptr.*;
    const dx = now.x - was.x;
    const dy = now.y - was.y;
    const dz = now.z - was.z;

    // EntityTrackerEntry weighs the encoded position, not the step just taken. The effect
    // is a fresh delta on nearly every update, which is what keeps a peer gliding rather
    // than hopping a quarter block at a time, so the oddity is load-bearing.
    const moved = @abs(now.x) >= move_step_threshold or @abs(now.y) >= move_step_threshold or @abs(now.z) >= move_step_threshold;
    const turned = @abs(@as(i32, now.yaw) - was.yaw) >= move_step_threshold or
        @abs(@as(i32, now.pitch) - was.pitch) >= move_step_threshold;

    const fits = @abs(dx) < relative_move_limit and @abs(dy) < relative_move_limit and
        @abs(dz) < relative_move_limit and was.since_resync <= resync_period;
    if (!fits) {
        entry.value_ptr.since_resync = 0;
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

pub const vehicle_boat: u8 = 1;
pub const vehicle_minecart: u8 = 10;
pub const vehicle_arrow: u8 = 60;
pub const vehicle_fireball: u8 = 63;
pub const vehicle_falling_sand: u8 = 70;
pub const vehicle_falling_gravel: u8 = 71;
pub const vehicle_fish_hook: u8 = 90;
pub const fireball_speed_scale: f64 = 8000.0;
pub const item_motion_scale: f64 = 128.0;

fn encodeMotion(value: f64) i8 {
    return @truncate(@as(i32, @intFromFloat(value * item_motion_scale)));
}

fn encodeFireballSpeed(value: f64) i16 {
    return @truncate(@as(i32, @intFromFloat(value * fireball_speed_scale)));
}

fn fallingVehicleKind(block: world.Block) ?u8 {
    return switch (block) {
        .sand => vehicle_falling_sand,
        .gravel => vehicle_falling_gravel,
        else => null,
    };
}

fn spawnPeer(self: *Session, gpa: std.mem.Allocator, peer: Peer, now: Tracked, entry: *Tracked) !void {
    switch (peer.body) {
        .player => |who| {
            try self.send(gpa, .{ .named_entity_spawn = .{
                .entity_id = @bitCast(peer.id),
                .name = who.name,
                .x = now.x,
                .y = now.y,
                .z = now.z,
                .rotation = now.yaw,
                .pitch = now.pitch,
                .current_item = heldNumericId(who.player),
            } });
            for (0..equipment_slots) |slot| {
                try self.sendEquipment(gpa, peer.id, slot, equipmentAt(who.player, slot));
            }
        },
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
        .item => |dropped| try self.send(gpa, .{ .pickup_spawn = .{
            .entity_id = @bitCast(peer.id),
            .item_id = dropped.stack.id.numeric(),
            .count = @intCast(dropped.stack.count),
            .damage = @bitCast(dropped.stack.meta),
            .x = now.x,
            .y = now.y,
            .z = now.z,
            .rotation = encodeMotion(dropped.base.motion.x),
            .pitch = encodeMotion(dropped.base.motion.y),
            .roll = encodeMotion(dropped.base.motion.z),
        } }),
        .arrow => |shot| try self.send(gpa, .{ .vehicle_spawn = .{
            .entity_id = @bitCast(peer.id),
            .kind = vehicle_arrow,
            .x = now.x,
            .y = now.y,
            .z = now.z,
            .thrower_id = @bitCast(if (shot.owner != game.Entity.no_id) shot.owner else peer.id),
        } }),
        .fireball => |shot| try self.send(gpa, .{ .vehicle_spawn = .{
            .entity_id = @bitCast(peer.id),
            .kind = vehicle_fireball,
            .x = now.x,
            .y = now.y,
            .z = now.z,
            .thrower_id = @bitCast(shot.shooter),
            .speed_x = encodeFireballSpeed(shot.acceleration.x),
            .speed_y = encodeFireballSpeed(shot.acceleration.y),
            .speed_z = encodeFireballSpeed(shot.acceleration.z),
        } }),
        .falling_block => |falling| try self.send(gpa, .{ .vehicle_spawn = .{
            .entity_id = @bitCast(peer.id),
            .kind = fallingVehicleKind(falling.block_id) orelse vehicle_falling_sand,
            .x = now.x,
            .y = now.y,
            .z = now.z,
        } }),
        .boat => try self.send(gpa, .{ .vehicle_spawn = .{
            .entity_id = @bitCast(peer.id),
            .kind = vehicle_boat,
            .x = now.x,
            .y = now.y,
            .z = now.z,
        } }),
        .minecart => |cart| try self.send(gpa, .{ .vehicle_spawn = .{
            .entity_id = @bitCast(peer.id),
            .kind = vehicle_minecart + @intFromEnum(cart.kind),
            .x = now.x,
            .y = now.y,
            .z = now.z,
        } }),
        .hook => try self.send(gpa, .{ .vehicle_spawn = .{
            .entity_id = @bitCast(peer.id),
            .kind = vehicle_fish_hook,
            .x = now.x,
            .y = now.y,
            .z = now.z,
        } }),
        .painting => |hung| try self.send(gpa, .{ .entity_painting = .{
            .entity_id = @bitCast(peer.id),
            .title = hung.art.info().title,
            .x = hung.tile[0],
            .y = hung.tile[1],
            .z = hung.tile[2],
            .direction = hung.direction,
        } }),
    }
}

fn heldNumericId(player: *const game.Player) i16 {
    const held = player.inventory.selectedStack() orelse return 0;
    return held.id.numeric();
}

fn reportStatus(self: *Session, gpa: std.mem.Allocator, peer: Peer, entry: *Tracked) !void {
    const hurt_now = peerHurtTime(peer);
    if (hurt_now > entry.hurt_time) {
        try self.send(gpa, .{ .entity_status = .{
            .entity_id = @bitCast(peer.id),
            .status = status_hurt,
        } });
    }
    entry.hurt_time = hurt_now;

    const alive_now = peerAlive(peer);
    if (entry.alive and !alive_now) {
        try self.send(gpa, .{ .entity_status = .{
            .entity_id = @bitCast(peer.id),
            .status = status_death,
        } });
    }
    entry.alive = alive_now;
}

fn reportVelocity(self: *Session, gpa: std.mem.Allocator, peer: Peer, entry: *Tracked) !void {
    if (!sendsMotion(peer)) return;

    const motion = peerMotion(peer);
    const dx = motion.x - entry.motion.x;
    const dy = motion.y - entry.motion.y;
    const dz = motion.z - entry.motion.z;
    const change = dx * dx + dy * dy + dz * dz;

    const stopped = motion.x == 0.0 and motion.y == 0.0 and motion.z == 0.0;
    if (change <= velocity_epsilon * velocity_epsilon and !(change > 0.0 and stopped)) return;

    entry.motion = motion;
    try self.send(gpa, .{ .entity_velocity = .{
        .entity_id = @bitCast(peer.id),
        .motion_x = encodeVelocity(motion.x),
        .motion_y = encodeVelocity(motion.y),
        .motion_z = encodeVelocity(motion.z),
    } });
}

fn reportWatched(self: *Session, gpa: std.mem.Allocator, peer: Peer, entry: *Tracked) !void {
    var fresh: Snapshot = .{};
    const encoded = watchedBytes(peer.id, peer.body.mob, &fresh) orelse return;
    if (std.mem.eql(u8, entry.watched.text(), encoded)) return;

    entry.watched = fresh;
    try self.outbox.appendSlice(gpa, encoded);
}

pub const keep_alive_period: u32 = 20;

pub fn tickPlayer(self: *Session, gpa: std.mem.Allocator, level: *game.Level) !bool {
    if (self.state != .playing) return false;
    const player = self.player orelse return false;

    const dy = player.base.position.y - self.last_height;
    self.last_height = player.base.position.y;
    player.tickEnvironment(&level.world_map, dy);
    try self.tickSleep(gpa, level);
    try self.tickCarriedMaps(gpa, level);

    if (player.health > 0) {
        self.emptied_on_death = false;
        return player.tickPortal() == .travel;
    }
    if (self.emptied_on_death) return false;
    self.emptied_on_death = true;
    try self.spillOnDeath(gpa, level);
    return false;
}

pub const map_item_id: i16 = @intFromEnum(world.Item.map);

fn holdsMap(player: *const game.Player, stack: world.Stack) bool {
    for (player.inventory.slots) |carried| {
        const held = carried orelse continue;
        if (held.id.eql(stack.id) and held.meta == stack.meta) return true;
    }
    return false;
}

fn tickCarriedMaps(self: *Session, gpa: std.mem.Allocator, level: *game.Level) !void {
    const player = self.player orelse return;

    var states: std.ArrayList(world.map.ViewerState) = .empty;
    defer states.deinit(gpa);
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);

    for (player.inventory.slots, 0..) |carried, slot| {
        const stack = carried orelse continue;
        if (!stack.id.eql(.{ .item = .map })) continue;

        const data = try level.world_map.mapData(@bitCast(stack.meta));

        states.clearRetainingCapacity();
        for (level.occupants.items) |occupant| {
            try states.append(gpa, .{
                .id = occupant.player.base.id,
                .x = occupant.player.base.position.x,
                .z = occupant.player.base.position.z,
                .dimension = @intFromEnum(self.dimension),
                .alive = !occupant.player.isDead(),
                .holding = holdsMap(occupant.player, stack),
            });
        }
        try data.updateMarkers(gpa, player.yaw, states.items);

        if (slot == player.inventory.selected) {
            data.updateColors(
                &level.world_map,
                @intFromEnum(self.dimension),
                self.dimension.hasSky(),
                player.base.position.x,
                player.base.position.z,
            );
        }

        if (!try data.buildPayload(gpa, player.base.id, &payload)) continue;
        try self.send(gpa, .{ .map_data = .{
            .kind = map_item_id,
            .map_id = @bitCast(stack.meta),
            .data = payload.items,
        } });
    }
}

fn tickSleep(self: *Session, gpa: std.mem.Allocator, level: *game.Level) !void {
    const player = self.player orelse return;
    player.tickSleep();
    if (!player.sleeping) return;

    if (player.wake_pending) {
        player.wake_pending = false;
        try player.wakeUp(&level.world_map, true, false);
    } else if (!player.isInBed(&level.world_map)) {
        try player.wakeUp(&level.world_map, true, false);
    } else if (level.world_map.isDaytime()) {
        try player.wakeUp(&level.world_map, false, true);
    } else return;

    self.last_height = player.base.position.y;
    try self.sendPosition(gpa);
}

pub fn travel(
    self: *Session,
    gpa: std.mem.Allocator,
    from: *game.Level,
    to: *game.Level,
    target: world.Dimension,
    x: f64,
    y: f64,
    z: f64,
) !void {
    const player = self.player orelse return;

    var stale = self.tracked.keyIterator();
    while (stale.next()) |id| {
        try self.send(gpa, .{ .destroy_entity = .{ .entity_id = @bitCast(id.*) } });
    }
    self.tracked.clearRetainingCapacity();
    self.sent_chunks.clearRetainingCapacity();

    from.leave(player);

    const centre_x = @divFloor(math.util.floorDouble(x), world.Chunk.width);
    const centre_z = @divFloor(math.util.floorDouble(z), world.Chunk.width);
    var dx: i32 = -1;
    while (dx <= 1) : (dx += 1) {
        var dz: i32 = -1;
        while (dz <= 1) : (dz += 1) {
            try to.world_map.ensureDecorated(&to.generator, centre_x + dx, centre_z + dz);
        }
    }
    const landed = try world.portal.placeInto(&to.world_map, &to.world_map.rand, x, y, z);

    const keep_id = player.base.id;
    player.base.position = .{ .x = landed.x, .y = landed.y, .z = landed.z };
    player.base.prev_position = player.base.position;
    player.base.motion = .{ .x = 0, .y = 0, .z = 0 };
    player.fall_distance = 0;
    try to.enter(gpa, player);
    player.base.id = keep_id;

    self.dimension = target;
    self.last_height = player.base.position.y;
    self.open = .player;
    self.window_id = player_window;
    self.progress = @splat(-1);

    try self.send(gpa, .{ .respawn = .{ .dimension = @intFromEnum(target) } });
    try self.sendPosition(gpa);
    try self.send(gpa, .{ .update_time = .{ .time = to.world_map.time } });
    try self.sendWindowContents(gpa, to);
}

fn spillOnDeath(self: *Session, gpa: std.mem.Allocator, level: *game.Level) !void {
    const player = self.player orelse return;
    const x = math.util.floorDouble(player.base.position.x);
    const y = math.util.floorDouble(player.base.position.y);
    const z = math.util.floorDouble(player.base.position.z);

    for (&player.inventory.slots) |*slot| {
        const stack = slot.* orelse continue;
        slot.* = null;
        try level.dropStackAt(gpa, x, y, z, stack);
    }
    for (&player.inventory.armor) |*slot| {
        const stack = slot.* orelse continue;
        slot.* = null;
        try level.dropStackAt(gpa, x, y, z, stack);
    }
    for (&self.crafting) |*slot| {
        const stack = slot.* orelse continue;
        slot.* = null;
        try level.dropStackAt(gpa, x, y, z, stack);
    }
    for (&self.workbench) |*slot| {
        const stack = slot.* orelse continue;
        slot.* = null;
        try level.dropStackAt(gpa, x, y, z, stack);
    }
    if (self.carried) |stack| {
        self.carried = null;
        try level.dropStackAt(gpa, x, y, z, stack);
    }
}

pub fn pingIfQuiet(self: *Session, gpa: std.mem.Allocator) !void {
    if (self.state != .playing) return;
    self.quiet_ticks += 1;
    if (self.quiet_ticks <= keep_alive_period) return;
    self.quiet_ticks = 0;
    try self.send(gpa, .keep_alive);
}

pub fn reportHealth(self: *Session, gpa: std.mem.Allocator) !void {
    if (self.state != .playing) return;
    const player = self.player orelse return;

    const health: i16 = @intCast(std.math.clamp(player.health, 0, std.math.maxInt(i16)));
    if (health == self.sent_health) return;

    const lost = self.sent_health - health;
    const was_alive = self.sent_health > 0 and self.sent_health != std.math.maxInt(i16);

    self.sent_health = health;
    try self.send(gpa, .{ .update_health = .{ .health = health } });

    if (lost > 0 and was_alive) try self.award(gpa, .{ .general = .damage_taken }, lost);
    if (health <= 0 and was_alive) try self.award(gpa, .{ .general = .deaths }, 1);
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
    self.last_height = player.base.position.y;
    self.state = .playing;

    try self.send(gpa, .{ .login = .{
        .protocol_version = @intCast(player.base.id),
        .username = "",
        .map_seed = level.generator.worldSeed(),
        .dimension = @intFromEnum(self.dimension),
    } });
    try self.send(gpa, .{ .spawn_position = .{
        .x = level.spawn[0],
        .y = level.spawn[1],
        .z = level.spawn[2],
    } });
    try self.sendPosition(gpa);
    try self.send(gpa, .{ .update_time = .{ .time = level.world_map.time } });
    try self.sendWindowContents(gpa, level);
}

fn spawnPlacement(level: *const game.Level) math.Vec3 {
    return .{
        .x = @as(f64, @floatFromInt(level.spawn[0])) + 0.5,
        .y = @floatFromInt(level.spawn[1]),
        .z = @as(f64, @floatFromInt(level.spawn[2])) + 0.5,
    };
}

fn respawnPlayer(self: *Session, gpa: std.mem.Allocator, level: *game.Level) !void {
    const player = self.player orelse return;
    if (player.health > 0) return;

    player.respawn(try self.respawnPlacement(gpa, level));
    self.last_height = player.base.position.y;
    self.sent_health = std.math.maxInt(i16);
    try self.sendPosition(gpa);
    try self.send(gpa, .{ .respawn = .{ .dimension = @intFromEnum(self.dimension) } });
    try self.reportHealth(gpa);
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
    self.quiet_ticks = 0;
    switch (message) {
        .keep_alive => {},
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
        .animation => |body| {
            if (body.animate == net.packet.swing_animation) self.pending_swing = true;
        },
        .use_entity => |body| try self.useEntity(gpa, level, @bitCast(body.target_id), body.left_click),
        .entity_action => |body| switch (body.state) {
            action_start_sneaking => player.base.sneaking = true,
            action_stop_sneaking => player.base.sneaking = false,
            else => {},
        },
        .block_dig => |body| try self.digBlock(gpa, level, body.status, body.x, body.y, body.z),
        .place => |body| try self.placeBlock(gpa, level, body.x, body.y, body.z, body.face),
        .chat => |body| try self.handleChat(gpa, level, body.message),
        .respawn => try self.respawnPlayer(gpa, level),
        .window_click => |body| try self.windowClick(gpa, level, body),
        .update_sign => |body| try self.updateSign(level, body),
        .close_window => try self.closeWindow(gpa, level),
        .kick_disconnect => self.state = .closed,
        else => {},
    }
}

pub const action_start_sneaking: i8 = 1;
pub const action_stop_sneaking: i8 = 2;
pub const use_interact: i8 = 0;
pub const use_attack: i8 = 1;

fn entityPositionOf(level: *game.Level, id: game.Entity.Id) ?math.Vec3 {
    if (level.entities.mobById(id)) |entry| return entry.animal.base.position;
    if (level.entities.boatById(id)) |boat| return boat.base.position;
    if (level.entities.minecartById(id)) |cart| return cart.base.position;
    return null;
}

fn targetOf(level: *game.Level, id: game.Entity.Id) ?game.Entities.Target {
    if (level.entities.mobById(id) != null) return .{ .mob = id };
    if (level.entities.boatById(id) != null) return .{ .boat = id };
    if (level.entities.minecartById(id) != null) return .{ .minecart = id };
    for (level.entities.paintings.items) |hung| {
        if (hung.id == id) return .{ .painting = id };
    }
    return null;
}

fn heldDamage(player: *const game.Player) i32 {
    const stack = player.inventory.selectedStack() orelse return 1;
    return switch (stack.id) {
        .item => |held| held.damageVsEntity(),
        .block => 1,
    };
}

fn interactMinecart(self: *Session, gpa: std.mem.Allocator, level: *game.Level, cart: *game.Minecart) !void {
    const player = self.player orelse return;
    switch (cart.kind) {
        .empty => {
            if (cart.rider != game.Entity.no_id and cart.rider != player.base.id) return;
            player.riding = cart.base.id;
            cart.rider = player.base.id;
        },
        .chest => try self.openContainer(gpa, level, .{ .minecart = cart.base.id }, window_chest, "Minecart with chest"),
        .furnace => {
            if (player.inventory.selectedStack()) |stack| {
                if (stack.id.eql(.{ .item = .coal })) {
                    self.consumeHeld();
                    cart.fuel += game.Minecart.coal_fuel;
                }
            }
            cart.push = math.Vec3.init(
                cart.base.position.x - player.base.position.x,
                0,
                cart.base.position.z - player.base.position.z,
            );
        },
    }
}

fn damageHeld(self: *Session, amount: u16) void {
    const player = self.player orelse return;
    const slot = &player.inventory.slots[player.inventory.selected];
    var stack = slot.* orelse return;
    stack.damage(amount);
    slot.* = if (stack.count == 0) null else stack;
}

fn interactEntity(self: *Session, gpa: std.mem.Allocator, level: *game.Level, id: game.Entity.Id) !void {
    const player = self.player orelse return;

    if (level.entities.boatById(id)) |boat| {
        player.riding = boat.base.id;
        return;
    }
    if (level.entities.minecartById(id)) |cart| return self.interactMinecart(gpa, level, cart);

    const entry = level.entities.mobById(id) orelse return;
    const held: ?world.Item = if (player.inventory.selectedStack()) |stack| switch (stack.id) {
        .item => |item| item,
        .block => null,
    } else null;

    if (entry.type_id == game.mob.pig) {
        const pig: *game.Pig = @fieldParentPtr("animal", entry.animal);
        if (pig.saddled) {
            player.riding = entry.animal.base.id;
            return;
        }
        if ((held orelse return) != .saddle) return;
        pig.saddled = true;
        self.consumeHeld();
        return;
    }

    if (entry.type_id == game.mob.sheep) {
        if ((held orelse return) != .shears) return;
        const sheep: *game.Sheep = @fieldParentPtr("animal", entry.animal);
        const drops = sheep.shear(&level.world_map.rand) orelse return;
        try level.entities.dropShearedWool(gpa, sheep, drops, &level.world_map.rand);
        self.damageHeld(1);
        return;
    }

    if (entry.type_id == game.mob.wolf) {
        const wolf: *game.Wolf = @fieldParentPtr("animal", entry.animal);
        const used = wolf.interactWith(
            gpa,
            game.Entities.viewOf(player),
            held,
            &level.world_map.rand,
        ) orelse return;
        switch (used) {
            .tamed, .refused => {
                self.consumeHeld();
                try level.entities.spawnTreatReaction(gpa, wolf.animal, used == .tamed, &level.world_map.rand);
            },
            .fed => self.consumeHeld(),
            .sat, .stood => {},
        }
        return;
    }

    if (entry.type_id == game.mob.cow) {
        const milked = game.Cow.interact(held orelse return) orelse return;
        player.inventory.slots[player.inventory.selected] = .{ .id = .{ .item = milked }, .count = 1 };
    }
}

fn useEntity(self: *Session, gpa: std.mem.Allocator, level: *game.Level, id: game.Entity.Id, click: i8) !void {
    const player = self.player orelse return;

    if (click == use_interact) {
        const at = entityPositionOf(level, id) orelse return;
        if (player.base.position.distanceSquaredTo(at) > reach_squared) return;
        return self.interactEntity(gpa, level, id);
    }
    if (click != use_attack) return;

    if (game.Entities.playerById(level.roster.items, id)) |struck| {
        if (struck == player) return;
        if (player.base.position.distanceSquaredTo(struck.base.position) > reach_squared) return;
        var damage = heldDamage(player);
        if (damage <= 0) return;
        if (player.base.motion.y < 0.0) damage += 1;
        struck.hurtFrom(damage, player.base.position);
        try self.award(gpa, .{ .general = .damage_dealt }, damage);
        return;
    }

    const target = targetOf(level, id) orelse return;

    const at = switch (target) {
        .mob => (level.entities.mobById(id) orelse return).animal.base.position,
        .boat => (level.entities.boatById(id) orelse return).base.position,
        .minecart => (level.entities.minecartById(id) orelse return).base.position,
        .painting => blk: {
            for (level.entities.paintings.items) |hung| {
                if (hung.id == id) break :blk hung.position;
            }
            return;
        },
    };
    if (player.base.position.distanceSquaredTo(at) > reach_squared) return;

    var damage = heldDamage(player);
    if (damage <= 0) return;
    if (player.base.motion.y < 0.0) damage += 1;

    const landed = level.entities.hurtTarget(target, damage, .{
        .position = player.base.position,
        .player = player.base.id,
    }, &level.world_map.rand);
    if (landed) try self.award(gpa, .{ .general = .damage_dealt }, damage);
}

fn handleChat(self: *Session, gpa: std.mem.Allocator, level: *game.Level, message: []const u8) !void {
    if (message.len > max_chat_in) return self.kick(gpa, "Chat message too long");

    const trimmed = std.mem.trim(u8, message, " ");
    for (trimmed) |c| {
        if (!chatAllowed(c)) return self.kick(gpa, "Illegal characters in chat");
    }
    if (trimmed.len == 0) return;
    if (trimmed[0] == '/') return self.runCommand(gpa, level, trimmed);

    var line: ChatLine = .{};
    const written = std.fmt.bufPrint(&line.bytes, "<{s}> {s}", .{ self.name.text(), trimmed }) catch return;
    line.len = written.len;
    self.pending_chat = line;
}

fn runCommand(self: *Session, gpa: std.mem.Allocator, level: *game.Level, line: []const u8) !void {
    switch (game.commands.parse(line)) {
        .weather => |asked| {
            if (!self.dimension.hasSky()) return self.sendChat(gpa, game.commands.no_sky_line);

            game.commands.applyWeather(&level.world_map.weather, asked);

            var buffer: [net.packet.max_chat]u8 = undefined;
            const said = std.fmt.bufPrint(&buffer, game.commands.set_weather_line, .{@tagName(asked.sky)}) catch return;
            try self.sendChat(gpa, said);
        },
        else => {},
    }
}

pub const equipment_slots: usize = 5;
pub const player_window: i8 = 0;
pub const carried_window: i8 = -1;
pub const carried_slot: i16 = -1;
pub const player_window_slots: usize = 45;
pub const last_window_id: i8 = 100;

pub const window_chest: i8 = 0;
pub const window_workbench: i8 = 1;
pub const window_furnace: i8 = 2;
pub const window_dispenser: i8 = 3;

pub const Open = union(enum) {
    player,
    workbench,
    chest: world.World.ChestPair,
    furnace: world.World.BlockPos,
    dispenser: world.World.BlockPos,
    minecart: game.Entity.Id,
};

pub fn currentWindow(self: *Session, level: *game.Level) Window {
    var window: Window = .{};
    const player = self.player orelse return window;

    switch (self.open) {
        .player => {
            window.addGrid(&self.crafting, Window.crafting_side);
            for (0..game.Inventory.armor_size) |piece| {
                window.add(.{
                    .stack = &player.inventory.armor[piece],
                    .kind = .armor,
                    .armor = @enumFromInt(piece),
                });
            }
        },
        .workbench => window.addGrid(&self.workbench, Window.workbench_side),
        .chest => |pair| {
            const upper = level.world_map.chestAt(pair.upper.x, pair.upper.y, pair.upper.z) orelse return window;
            window.addStore(&upper.items, .chest);
            if (pair.lower) |at| {
                const lower = level.world_map.chestAt(at.x, at.y, at.z) orelse return window;
                window.addStore(&lower.items, .chest);
            }
        },
        .furnace => |at| {
            const fire = level.world_map.furnaceAt(at.x, at.y, at.z) orelse return window;
            window.add(.{ .stack = &fire.input });
            window.add(.{ .stack = &fire.fuel });
            window.add(.{ .stack = &fire.output, .kind = .output });
            window.store_count = window.count;
        },
        .dispenser => |at| {
            const trap = level.world_map.dispenserAt(at.x, at.y, at.z) orelse return window;
            window.addStore(&trap.items, .chest);
        },
        .minecart => |id| {
            const cart = level.entities.minecartById(id) orelse return window;
            window.addStore(&cart.items, .chest);
        },
    }

    window.addPlayer(&player.inventory);
    return window;
}

fn wireStack(stack: ?world.Stack) ?net.packet.Stack {
    const held = stack orelse return null;
    return .{
        .id = held.id.numeric(),
        .count = @intCast(held.count),
        .damage = @bitCast(held.meta),
    };
}

fn fromWire(stack: ?net.packet.Stack) ?world.Stack {
    const held = stack orelse return null;
    if (held.count <= 0) return null;
    return .{
        .id = world.Id.fromNumeric(held.id),
        .count = @intCast(held.count),
        .meta = @bitCast(held.damage),
    };
}

pub fn sendWindowContents(self: *Session, gpa: std.mem.Allocator, level: *game.Level) !void {
    if (self.state != .playing) return;
    var window = self.currentWindow(level);
    if (window.count == 0) return;

    var stacks: [Window.max_slots]?net.packet.Stack = @splat(null);
    for (0..window.count) |slot| {
        const held = window.stackAt(slot);
        stacks[slot] = wireStack(held);
        self.mirror[slot] = held;
    }
    self.mirror_used = window.count;

    try self.send(gpa, .{ .window_items = .{
        .window_id = self.window_id,
        .stacks = stacks[0..window.count],
    } });
    try self.sendCarried(gpa);
}

fn sendCarried(self: *Session, gpa: std.mem.Allocator) !void {
    self.mirror_carried = self.carried;
    try self.send(gpa, .{ .set_slot = .{
        .window_id = carried_window,
        .slot = carried_slot,
        .stack = wireStack(self.carried),
    } });
}

pub fn syncWindow(self: *Session, gpa: std.mem.Allocator, level: *game.Level) !void {
    if (self.state != .playing) return;
    var window = self.currentWindow(level);
    if (window.count != self.mirror_used) return self.sendWindowContents(gpa, level);

    for (0..window.count) |slot| {
        const held = window.stackAt(slot);
        if (sameStack(self.mirror[slot], held)) continue;
        self.mirror[slot] = held;
        try self.send(gpa, .{ .set_slot = .{
            .window_id = self.window_id,
            .slot = @intCast(slot),
            .stack = wireStack(held),
        } });
    }

    if (!sameStack(self.mirror_carried, self.carried)) try self.sendCarried(gpa);
    try self.sendProgress(gpa, level);
}

fn sendProgress(self: *Session, gpa: std.mem.Allocator, level: *game.Level) !void {
    const at = switch (self.open) {
        .furnace => |spot| spot,
        else => {
            self.progress = @splat(-1);
            return;
        },
    };
    const fire = level.world_map.furnaceAt(at.x, at.y, at.z) orelse return;
    const now: [3]i16 = .{ fire.cook_time, fire.burn_time, fire.item_burn_time };

    for (now, 0..) |value, bar| {
        if (self.progress[bar] == value) continue;
        self.progress[bar] = value;
        try self.send(gpa, .{ .update_progressbar = .{
            .window_id = self.window_id,
            .bar = @intCast(bar),
            .value = value,
        } });
    }
}

fn takeWindowId(self: *Session) i8 {
    self.next_window_id += 1;
    if (self.next_window_id > last_window_id) self.next_window_id = 1;
    return self.next_window_id;
}

fn openContainer(self: *Session, gpa: std.mem.Allocator, level: *game.Level, open: Open, kind: i8, title: []const u8) !void {
    self.open = open;
    self.window_id = self.takeWindowId();
    self.progress = @splat(-1);

    const window = self.currentWindow(level);
    if (window.count == 0) {
        self.open = .player;
        self.window_id = player_window;
        return;
    }

    try self.send(gpa, .{ .open_window = .{
        .window_id = self.window_id,
        .kind = kind,
        .title = title,
        .slots = @intCast(window.store_count),
    } });
    try self.sendWindowContents(gpa, level);
}

fn mintCraftedMap(self: *Session, level: *game.Level, window: *Window) !void {
    const player = self.player orelse return;
    if (window.grid.len == 0) return;

    const result = game.crafting.findMatch(window.grid, window.grid_side) orelse return;
    if (!result.id.eql(.{ .item = .map })) return;

    const id = try level.world_map.nextMapId();
    window.minted_map = @bitCast(id);

    const data = try level.world_map.mapData(id);
    data.center_x = math.util.floorDouble(player.base.position.x);
    data.center_z = math.util.floorDouble(player.base.position.z);
    data.scale = world.map.default_scale;
    data.dimension = @intFromEnum(self.dimension);
    data.markDirty();
}

fn windowClick(self: *Session, gpa: std.mem.Allocator, level: *game.Level, body: anytype) !void {
    const player = self.player orelse return;
    if (body.window_id != self.window_id) return;

    var window = self.currentWindow(level);
    if (window.count == 0) return;
    try self.mintCraftedMap(level, &window);

    const outcome = window.click(
        body.slot,
        if (body.right_click == 0) .left else .right,
        body.shift,
        &self.carried,
    );

    if (outcome.crafted) |made| try self.award(gpa, .{ .crafted = made.id }, made.count);
    if (outcome.smelted) |made| try self.award(gpa, .{ .crafted = made.id }, made.count);

    if (outcome.thrown) |stack| {
        try level.dropStackAt(
            gpa,
            math.util.floorDouble(player.base.position.x),
            math.util.floorDouble(player.base.position.y),
            math.util.floorDouble(player.base.position.z),
            stack,
        );
        try self.award(gpa, .{ .general = .drop }, 1);
    }

    const agreed = sameStack(fromWire(body.held), self.carried);
    try self.send(gpa, .{ .transaction = .{
        .window_id = body.window_id,
        .action = body.action,
        .accepted = agreed,
    } });
    if (agreed) return try self.syncWindow(gpa, level);
    try self.sendWindowContents(gpa, level);
}

fn closeWindow(self: *Session, gpa: std.mem.Allocator, level: *game.Level) !void {
    const player = self.player orelse return;
    const x = math.util.floorDouble(player.base.position.x);
    const y = math.util.floorDouble(player.base.position.y);
    const z = math.util.floorDouble(player.base.position.z);

    for (&self.crafting) |*slot| {
        const stack = slot.* orelse continue;
        slot.* = null;
        try level.dropStackAt(gpa, x, y, z, stack);
    }
    for (&self.workbench) |*slot| {
        const stack = slot.* orelse continue;
        slot.* = null;
        try level.dropStackAt(gpa, x, y, z, stack);
    }
    if (self.carried) |stack| {
        self.carried = null;
        try level.dropStackAt(gpa, x, y, z, stack);
    }

    self.open = .player;
    self.window_id = player_window;
    self.progress = @splat(-1);
    try self.sendWindowContents(gpa, level);
}

pub fn equipmentAt(player: *const game.Player, slot: usize) ?world.Stack {
    if (slot == 0) return player.inventory.selectedStack();
    return player.inventory.armor[slot - 1];
}

fn sameStack(a: ?world.Stack, b: ?world.Stack) bool {
    const left = a orelse return b == null;
    const right = b orelse return false;
    return left.id.eql(right.id) and left.count == right.count and left.meta == right.meta;
}

pub fn refreshEquipment(self: *Session, changed: *[equipment_slots]bool) bool {
    changed.* = @splat(false);
    const player = self.player orelse return false;

    var any = false;
    for (0..equipment_slots) |slot| {
        const worn = equipmentAt(player, slot);
        if (sameStack(self.equipment[slot], worn)) continue;
        self.equipment[slot] = worn;
        changed[slot] = true;
        any = true;
    }
    return any;
}

pub fn sendEquipment(
    self: *Session,
    gpa: std.mem.Allocator,
    id: game.Entity.Id,
    slot: usize,
    worn: ?world.Stack,
) !void {
    if (self.state != .playing) return;
    if (!self.tracked.contains(id)) return;
    try self.send(gpa, .{ .player_inventory = .{
        .entity_id = @bitCast(id),
        .slot = @intCast(slot),
        .item_id = if (worn) |stack| stack.id.numeric() else -1,
        .damage = if (worn) |stack| @bitCast(stack.meta) else 0,
    } });
}

pub const max_stat_step: i32 = std.math.maxInt(i8);

pub fn award(self: *Session, gpa: std.mem.Allocator, stat: game.stats.Key, amount: i32) !void {
    if (self.state != .playing or amount == 0) return;

    var left = amount;
    while (left != 0) {
        const step = std.math.clamp(left, -max_stat_step, max_stat_step);
        left -= step;
        try self.send(gpa, .{ .statistic = .{
            .stat_id = @bitCast(game.stats.statId(stat)),
            .amount = @intCast(step),
        } });
    }
}

pub fn sendRainState(self: *Session, gpa: std.mem.Allocator, raining: bool) !void {
    if (self.state != .playing) return;
    if (self.raining == raining) return;

    self.raining = raining;
    try self.send(gpa, .{ .bed = .{ .state = if (raining) bed_rain_starts else bed_rain_stops } });
}

pub fn sendLightning(
    self: *Session,
    gpa: std.mem.Allocator,
    id: game.Entity.Id,
    at: math.Vec3,
) !void {
    if (self.state != .playing) return;
    const player = self.player orelse return;
    if (player.base.position.distanceTo(at) > weather_range) return;

    try self.send(gpa, .{ .weather = .{
        .entity_id = @bitCast(id),
        .lightning = lightning_kind,
        .x = encodePosition(at.x),
        .y = encodePosition(at.y),
        .z = encodePosition(at.z),
    } });
}

pub const note_range: f64 = 64.0;

pub fn sendNote(
    self: *Session,
    gpa: std.mem.Allocator,
    x: i32,
    y: i32,
    z: i32,
    instrument: world.note.Instrument,
    pitch: u8,
) !void {
    if (self.state != .playing) return;
    const player = self.player orelse return;

    const at = math.Vec3.init(
        @as(f64, @floatFromInt(x)) + 0.5,
        @as(f64, @floatFromInt(y)) + 0.5,
        @as(f64, @floatFromInt(z)) + 0.5,
    );
    if (player.base.position.distanceTo(at) > note_range) return;

    try self.send(gpa, .{ .play_note_block = .{
        .x = x,
        .y = @intCast(y),
        .z = z,
        .instrument = @intFromEnum(instrument),
        .pitch = pitch,
    } });
}

pub const blast_range: f64 = 64.0;

pub fn sendBlast(
    self: *Session,
    gpa: std.mem.Allocator,
    blast: game.Entities.Blast,
    broken: []const [3]i8,
) !void {
    if (self.state != .playing) return;
    const player = self.player orelse return;
    if (player.base.position.distanceTo(blast.at) > blast_range) return;

    try self.send(gpa, .{ .explosion = .{
        .x = blast.at.x,
        .y = blast.at.y,
        .z = blast.at.z,
        .radius = blast.size,
        .broken = broken,
    } });
}

pub fn sendCollect(
    self: *Session,
    gpa: std.mem.Allocator,
    collected: game.Entity.Id,
    by: game.Entity.Id,
) !void {
    if (self.state != .playing) return;
    if (!self.tracked.contains(collected)) return;
    try self.send(gpa, .{ .collect = .{
        .collected_id = @bitCast(collected),
        .collector_id = @bitCast(by),
    } });
}

pub fn sendRiding(self: *Session, gpa: std.mem.Allocator) !void {
    if (self.state != .playing) return;
    const player = self.player orelse return;
    if (player.riding == self.riding) return;

    self.riding = player.riding;
    try self.send(gpa, .{ .attach_entity = .{
        .entity_id = @bitCast(player.base.id),
        .vehicle_id = if (player.riding == game.Entity.no_id) -1 else @bitCast(player.riding),
    } });
}

pub fn takeSwing(self: *Session) bool {
    defer self.pending_swing = false;
    return self.pending_swing;
}

pub fn sendSwing(self: *Session, gpa: std.mem.Allocator, id: game.Entity.Id) !void {
    if (self.state != .playing) return;
    if (!self.tracked.contains(id)) return;
    try self.send(gpa, .{ .animation = .{
        .entity_id = @bitCast(id),
        .animate = net.packet.swing_animation,
    } });
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

pub const dig_started: u8 = 0;

fn digBlock(
    self: *Session,
    gpa: std.mem.Allocator,
    level: *game.Level,
    status: u8,
    x: i32,
    y: u8,
    z: i32,
) !void {
    const player = self.player orelse return;
    const height: i32 = y;
    if (!withinReach(player, x, height, z)) return;

    if (status == dig_started) return world.note.onPunched(&level.world_map, x, height, z);
    if (status != dig_finished) return;

    const broken = level.world_map.getBlock(x, height, z);
    if (broken == .air) return;

    const meta = level.world_map.getBlockMetadata(x, height, z);
    try level.world_map.setBlockWithNotify(x, height, z, .air);
    _ = level.world_map.removeSign(x, height, z);
    _ = level.world_map.removeNote(x, height, z);
    if (broken.harvestableWith(player.inventory.selectedStack())) {
        try self.award(gpa, .{ .mined = .{ .block = broken } }, 1);
    }

    if (broken.drop(meta, &level.world_map.rand)) |dropped| {
        try level.dropStackAt(gpa, x, height, z, .{
            .id = dropped.id,
            .count = dropped.count,
            .meta = dropped.meta,
        });
    }
}

fn activateBlock(self: *Session, gpa: std.mem.Allocator, level: *game.Level, x: i32, y: i32, z: i32) !bool {
    const standing = level.world_map.getBlock(x, y, z);
    switch (standing) {
        .workbench => {
            try self.openContainer(gpa, level, .workbench, window_workbench, "Crafting");
            return true;
        },
        .chest => {
            if (level.world_map.chestIsBlocked(x, y, z)) return true;
            const pair = level.world_map.chestPairAt(x, y, z);
            _ = try level.world_map.addChest(pair.upper.x, pair.upper.y, pair.upper.z);
            if (pair.lower) |at| _ = try level.world_map.addChest(at.x, at.y, at.z);
            const title = if (pair.lower == null) "Chest" else "Large chest";
            try self.openContainer(gpa, level, .{ .chest = pair }, window_chest, title);
            return true;
        },
        .furnace, .burning_furnace => {
            _ = try level.world_map.addFurnace(x, y, z);
            try self.openContainer(gpa, level, .{ .furnace = .{ .x = x, .y = y, .z = z } }, window_furnace, "Furnace");
            return true;
        },
        .dispenser => {
            _ = try level.world_map.addDispenser(x, y, z);
            try self.openContainer(gpa, level, .{ .dispenser = .{ .x = x, .y = y, .z = z } }, window_dispenser, "Trap");
            return true;
        },
        else => {},
    }
    switch (standing) {
        .door_wood => {
            try world.block_update.toggleDoor(&level.world_map, x, y, z);
            return true;
        },
        .door_iron => return true,
        .trapdoor => {
            try world.block_update.toggleTrapdoor(&level.world_map, x, y, z);
            return true;
        },
        .lever, .button, .repeater_off, .repeater_on => {
            _ = try world.redstone.activate(&level.world_map, x, y, z);
            return true;
        },
        .note_block => return world.note.onActivated(&level.world_map, x, y, z, .note_block),
        .bed => {
            try self.sleepInBed(gpa, level, x, y, z);
            return true;
        },
        .jukebox, .cake => return true,
        else => {
            const hook = standing.def().on_activated orelse return false;
            return hook(&level.world_map, x, y, z, standing);
        },
    }
}

pub const in_air_face: u8 = 255;
pub const bucket_reach_squared: f64 = 25.0;

fn bucketPourStep(face: world.block.Side) [3]i32 {
    return switch (face) {
        .down => .{ 0, -1, 0 },
        .up => .{ 0, 1, 0 },
        .north => .{ 0, 0, -1 },
        .south => .{ 0, 0, 1 },
        .west => .{ -1, 0, 0 },
        .east => .{ 1, 0, 0 },
    };
}

fn holdStack(self: *Session, held: world.Item) void {
    const player = self.player orelse return;
    player.inventory.slots[player.inventory.selected] = .{ .id = .{ .item = held }, .count = 1 };
}

fn useBucket(
    self: *Session,
    level: *game.Level,
    fill: world.item.Fill,
    x: i32,
    y: i32,
    z: i32,
    face: world.block.Side,
) !void {
    switch (fill) {
        .empty => {
            const scooped = try world.block_update.scoopLiquid(&level.world_map, x, y, z) orelse return;
            self.holdStack(scooped.bucketItem());
        },
        .milk => self.holdStack(.bucket),
        .water, .lava => {
            const step = bucketPourStep(face);
            if (!try world.block_update.pourLiquid(&level.world_map, x + step[0], y + step[1], z + step[2], fill)) return;
            self.holdStack(.bucket);
        },
    }
}

fn useItemOn(
    self: *Session,
    gpa: std.mem.Allocator,
    level: *game.Level,
    held: world.Item,
    stack: world.Stack,
    x: i32,
    y: i32,
    z: i32,
    face: world.block.Side,
) !void {
    const player = self.player orelse return;

    if (held.bucketFill()) |fill| return self.useBucket(level, fill, x, y, z, face);

    if (held.def().on_use) |hook| {
        if (try hook(&level.world_map, x, y, z, face, held, stack.meta)) return self.consumeHeld();
    }

    switch (held) {
        .door_wood, .door_iron => {
            if (face != .up) return;
            const leaf: world.Block = if (held == .door_wood) .door_wood else .door_iron;
            if (!try world.block_update.placeDoor(&level.world_map, x, y + 1, z, leaf, player.yaw)) return;
            self.consumeHeld();
        },
        .sign => try self.placeSign(level, x, y, z, face),
        .bed => {
            if (face != .up) return;
            if (!try world.block_update.placeBed(&level.world_map, x, y + 1, z, player.yaw)) return;
            self.consumeHeld();
        },
        .flint_and_steel => {
            const target = world.block_update.placementTarget(&level.world_map, x, y, z, face);
            if (target.y < 0 or target.y >= world.Chunk.height) return;
            if (level.world_map.getBlock(target.x, target.y, target.z) == .air) {
                try level.world_map.setBlockWithNotify(target.x, target.y, target.z, .fire);
            }
            self.damageHeld(1);
        },
        .painting => {
            const facing = game.Painting.directionFromFace(face) orelse return;
            const hung = game.Painting.pickArt(
                .{ x, y, z },
                facing,
                &level.world_map,
                level.entities.paintings.items,
                &level.world_map.rand,
            ) orelse return;
            try level.entities.spawnPainting(gpa, hung);
            self.consumeHeld();
        },
        .boat => {
            const on_snow = level.world_map.getBlock(x, y, z) == .snow_layer;
            const floor = if (on_snow) y - 1 else y;
            _ = try level.entities.spawnBoat(
                gpa,
                @as(f64, @floatFromInt(x)) + 0.5,
                @as(f64, @floatFromInt(floor)) + 1.0,
                @as(f64, @floatFromInt(z)) + 0.5,
            );
            self.consumeHeld();
        },
        .fishing_rod => try self.useFishingRod(gpa, level),
        else => {
            if (held.minecartKind()) |kind| {
                if (!world.block.isRail(level.world_map.getBlock(x, y, z))) return;
                _ = try level.entities.spawnMinecart(
                    gpa,
                    @as(f64, @floatFromInt(x)) + 0.5,
                    @as(f64, @floatFromInt(y)) + 0.5,
                    @as(f64, @floatFromInt(z)) + 0.5,
                    kind,
                );
                self.consumeHeld();
                return;
            }
            if (held.recordName() != null) {
                if (level.world_map.getBlock(x, y, z) != .jukebox) return;
                if (level.world_map.getBlockMetadata(x, y, z) != 0) return;
                try world.jukebox.insertRecord(&level.world_map, x, y, z, held);
                self.consumeHeld();
            }
        },
    }
}

fn useFishingRod(self: *Session, gpa: std.mem.Allocator, level: *game.Level) !void {
    const player = self.player orelse return;

    if (try level.entities.reelHook(gpa, player, &level.world_map.rand)) |what| {
        self.damageHeld(@intFromEnum(what));
        return;
    }
    try level.entities.castHook(gpa, player, &level.world_map.rand);
}

fn useItemInAir(self: *Session, gpa: std.mem.Allocator, level: *game.Level) !void {
    const player = self.player orelse return;
    const stack = player.inventory.selectedStack() orelse return;
    const held = switch (stack.id) {
        .item => |id| id,
        .block => return,
    };

    if (held.healAmount()) |amount| {
        player.heal(amount);
        self.consumeHeld();
        if (held == .mushroom_stew) self.holdStack(.bowl);
        return;
    }
    if (held == .fishing_rod) return self.useFishingRod(gpa, level);
    if (held != .bow) return;
    if (!player.inventory.consumeItem(.{ .item = .arrow })) return;
    try level.entities.shootArrow(gpa, player, &level.world_map.rand);
}

fn placeSign(self: *Session, level: *game.Level, x: i32, y: i32, z: i32, face: world.block.Side) !void {
    const player = self.player orelse return;
    if (face == .down) return;
    if (!level.world_map.getBlock(x, y, z).material().isSolid()) return;

    const target = world.block_update.placementTarget(&level.world_map, x, y, z, face);
    if (target.y < 0 or target.y >= world.Chunk.height) return;
    if (!level.world_map.getBlock(target.x, target.y, target.z).isReplaceable()) return;

    if (face == .up) {
        const facing = world.block.signPostFacingFromYaw(player.yaw);
        try level.world_map.setBlockAndMetadataWithNotify(target.x, target.y, target.z, .sign_post, facing);
    } else {
        try level.world_map.setBlockAndMetadataWithNotify(
            target.x,
            target.y,
            target.z,
            .wall_sign,
            @intFromEnum(face),
        );
    }

    _ = try level.world_map.addSign(target.x, target.y, target.z);
    self.consumeHeld();
}

pub const bed_not_valid: i8 = 0;
pub const bed_rain_starts: i8 = 1;
pub const bed_rain_stops: i8 = 2;
pub const lightning_kind: i8 = 1;
pub const weather_range: f64 = 512.0;
pub const bed_reach_x: f64 = 3.0;
pub const bed_reach_y: f64 = 2.0;

fn sleepInBed(self: *Session, gpa: std.mem.Allocator, level: *game.Level, x: i32, y: i32, z: i32) !void {
    const player = self.player orelse return;

    var pillow: [3]i32 = .{ x, y, z };
    var metadata = level.world_map.getBlockMetadata(pillow[0], pillow[1], pillow[2]);
    if (!world.block.bedIsPillow(metadata)) {
        pillow = world.block_update.bedPartner(&level.world_map, x, y, z) orelse return;
        metadata = level.world_map.getBlockMetadata(pillow[0], pillow[1], pillow[2]);
    }

    if (self.dimension == .nether) return self.blowUpBed(gpa, level, pillow, metadata);

    if (world.block.bedIsOccupied(metadata)) {
        if (anySleeperIn(level, pillow)) return self.sendChat(gpa, bed_occupied_line);
        try world.block_update.setBedOccupied(&level.world_map, pillow[0], pillow[1], pillow[2], false);
    }

    switch (player.sleepInBedAt(&level.world_map, self.dimension, pillow[0], pillow[1], pillow[2])) {
        .ok => try world.block_update.setBedOccupied(&level.world_map, pillow[0], pillow[1], pillow[2], true),
        .not_possible_now => try self.sendChat(gpa, bed_no_sleep_line),
        else => {},
    }
}

const bed_occupied_line = "This bed is occupied";
const bed_no_sleep_line = "You can only sleep at night";
const bed_blast_size: f32 = 5.0;
const bed_blast_is_flaming = true;

fn anySleeperIn(level: *game.Level, pillow: [3]i32) bool {
    for (level.occupants.items) |occupant| {
        if (occupant.player.sleeping and std.meta.eql(occupant.player.bed, pillow)) return true;
    }
    return false;
}

fn blowUpBed(self: *Session, gpa: std.mem.Allocator, level: *game.Level, pillow: [3]i32, metadata: u4) !void {
    _ = self;
    var x = pillow[0];
    var z = pillow[2];
    try level.world_map.setBlockWithNotify(x, pillow[1], z, .air);

    const step = world.block.bedStep(world.block.bedFacing(metadata));
    x += step[0];
    z += step[1];
    if (level.world_map.getBlock(x, pillow[1], z) == .bed) {
        try level.world_map.setBlockWithNotify(x, pillow[1], z, .air);
    }

    try game.explosion.detonate(
        gpa,
        &level.entities,
        &level.world_map,
        level.roster.items,
        .{
            .x = @as(f64, @as(f32, @floatFromInt(x)) + 0.5),
            .y = @as(f64, @as(f32, @floatFromInt(pillow[1])) + 0.5),
            .z = @as(f64, @as(f32, @floatFromInt(z)) + 0.5),
        },
        bed_blast_size,
        bed_blast_is_flaming,
        &level.world_map.rand,
    );
}

pub fn sendSleep(self: *Session, gpa: std.mem.Allocator, id: game.Entity.Id, bed: [3]i32) !void {
    if (self.state != .playing) return;
    if (id != self.playerId() and !self.tracked.contains(id)) return;
    try self.send(gpa, .{ .sleep = .{
        .entity_id = @bitCast(id),
        .state = net.packet.enter_bed_state,
        .x = bed[0],
        .y = @intCast(bed[1]),
        .z = bed[2],
    } });
}

pub fn sendWakeUp(self: *Session, gpa: std.mem.Allocator, id: game.Entity.Id) !void {
    if (self.state != .playing) return;
    if (id != self.playerId() and !self.tracked.contains(id)) return;
    try self.send(gpa, .{ .animation = .{
        .entity_id = @bitCast(id),
        .animate = net.packet.wake_up_animation,
    } });
}

fn playerId(self: *const Session) game.Entity.Id {
    const player = self.player orelse return game.Entity.no_id;
    return player.base.id;
}

pub const SleepChange = union(enum) { lay_down: [3]i32, wake_up };

pub fn takeSleepChange(self: *Session) ?SleepChange {
    const player = self.player orelse return null;
    const bed = if (player.sleeping) player.bed else null;
    if (std.meta.eql(bed, self.sent_bed)) return null;
    self.sent_bed = bed;
    if (bed) |spot| return .{ .lay_down = spot };
    return .wake_up;
}

fn respawnPlacement(self: *Session, gpa: std.mem.Allocator, level: *game.Level) !math.Vec3 {
    const player = self.player orelse return spawnPlacement(level);

    if (player.spawn_point) |bed| {
        if (world.block_update.bedRespawnSpot(&level.world_map, bed[0], bed[1], bed[2], 0)) |spot| {
            return .{
                .x = @as(f64, @floatFromInt(spot[0])) + 0.5,
                .y = @floatFromInt(spot[1]),
                .z = @as(f64, @floatFromInt(spot[2])) + 0.5,
            };
        }
        player.spawn_point = null;
        try self.send(gpa, .{ .bed = .{ .state = bed_not_valid } });
    }
    return spawnPlacement(level);
}

fn consumeHeld(self: *Session) void {
    const player = self.player orelse return;
    const slot = &player.inventory.slots[player.inventory.selected];
    const stack = slot.* orelse return;
    if (stack.count <= 1) {
        slot.* = null;
        return;
    }
    slot.*.?.count = stack.count - 1;
}

fn placeBlock(
    self: *Session,
    gpa: std.mem.Allocator,
    level: *game.Level,
    x: i32,
    y: u8,
    z: i32,
    face: u8,
) !void {
    const player = self.player orelse return;
    if (face == in_air_face) return self.useItemInAir(gpa, level);
    if (face > 5) return;

    const hit_y: i32 = y;
    if (!withinReach(player, x, hit_y, z)) return;
    if (try self.activateBlock(gpa, level, x, hit_y, z)) return;

    // Vanilla places whatever the server thinks is in hand; the stack on the wire is
    // only the client's guess and is never trusted.
    const stack = player.inventory.selectedStack() orelse return;
    const placed = switch (stack.id) {
        .block => |id| id,
        .item => |id| id.placedBlock() orelse return self.useItemOn(gpa, level, id, stack, x, hit_y, z, @enumFromInt(face)),
    };
    if (placed == .air) return;

    const target = world.block_update.placementTarget(
        &level.world_map,
        x,
        hit_y,
        z,
        @enumFromInt(face),
    );
    if (target.y < 0 or target.y >= world.Chunk.height) return;
    if (!withinReach(player, target.x, target.y, target.z)) return;
    if (!level.world_map.getBlock(target.x, target.y, target.z).isReplaceable()) return;
    if (!world.block_update.canPlaceOnSide(&level.world_map, target.x, target.y, target.z, placed, target.face)) return;
    if (placed == .chest and !level.world_map.canPlaceChestAt(target.x, target.y, target.z)) return;

    const meta = world.block_update.placementMetadata(
        &level.world_map,
        target.x,
        target.y,
        target.z,
        placed,
        target.face,
        stack.blockMeta(),
    );
    try level.world_map.setBlockAndMetadataWithNotify(target.x, target.y, target.z, placed, meta);
    self.consumeHeld();
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
    if (y < 0 or y >= world.Chunk.height) return;

    const width = world.Chunk.width;
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
    const width = world.Chunk.width;
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
            try level.world_map.ensureDecorated(&level.generator, coord.x + dx, coord.z + dz);
        }
    }

    const chunk = level.world_map.getChunk(coord.x, coord.z) orelse return;

    try self.send(gpa, .{ .pre_chunk = .{ .x = coord.x, .z = coord.z, .load = true } });

    const compressed = try chunk_payload.compressFull(gpa, chunk);
    defer gpa.free(compressed);

    try self.send(gpa, .{ .map_chunk = .{
        .x = coord.x * world.Chunk.width,
        .y = 0,
        .z = coord.z * world.Chunk.width,
        .size_x = chunk_payload.size_x,
        .size_y = chunk_payload.size_y,
        .size_z = chunk_payload.size_z,
        .compressed = compressed,
    } });

    try self.sendSignsIn(gpa, level, coord);
}

fn sendSignsIn(
    self: *Session,
    gpa: std.mem.Allocator,
    level: *game.Level,
    coord: world.World.ChunkCoord,
) !void {
    const width = world.Chunk.width;
    var posts = level.world_map.signs.iterator();
    while (posts.next()) |entry| {
        const at = entry.key_ptr.*;
        if (@divFloor(at.x, width) != coord.x or @divFloor(at.z, width) != coord.z) continue;
        try self.sendSign(gpa, at.x, at.y, at.z, entry.value_ptr);
    }
}

pub fn sendSign(
    self: *Session,
    gpa: std.mem.Allocator,
    x: i32,
    y: i32,
    z: i32,
    post: *const world.sign.Sign,
) !void {
    if (self.state != .playing) return;
    try self.send(gpa, .{ .update_sign = .{
        .x = x,
        .y = @intCast(y),
        .z = z,
        .lines = .{ post.line(0), post.line(1), post.line(2), post.line(3) },
    } });
}

pub fn seesChunkAt(self: *const Session, x: i32, z: i32) bool {
    const width = world.Chunk.width;
    return self.sent_chunks.contains(.{ .x = @divFloor(x, width), .z = @divFloor(z, width) });
}

fn updateSign(self: *Session, level: *game.Level, body: anytype) !void {
    const player = self.player orelse return;
    const y: i32 = body.y;
    if (!withinReach(player, body.x, y, body.z)) return;
    if (!level.world_map.getBlock(body.x, y, body.z).isSign()) return;

    const post = try level.world_map.addSign(body.x, y, body.z);
    for (body.lines, 0..) |text, index| post.setLine(index, text);
    self.pending_sign = .{ .x = body.x, .y = y, .z = body.z };
}

pub fn takeSign(self: *Session) ?world.World.BlockPos {
    const at = self.pending_sign orelse return null;
    self.pending_sign = null;
    return at;
}

pub fn leave(self: *Session, gpa: std.mem.Allocator, level: *game.Level) void {
    const player = self.player orelse return;
    level.leave(player);
    gpa.destroy(player);
    self.player = null;
    self.state = .closed;
}

fn testLevel(gpa: std.mem.Allocator) !game.Level {
    var level = game.Level.init(gpa, try world.Generator.init(gpa, .overworld, 99));
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

    const expected = [_]net.packet.Id{
        .handshake,
        .login,
        .spawn_position,
        .player_look_move,
        .update_time,
        .window_items,
        .set_slot,
    };
    try std.testing.expectEqual(expected.len, replies.items.len);
    for (expected, replies.items) |want, got| try std.testing.expectEqual(want, got.id());

    try std.testing.expectEqual(level.generator.worldSeed(), replies.items[1].login.map_seed);
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

test "a quiet client is prodded with a keep alive, a talkative one is left alone" {
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

    var replies: std.ArrayList(net.packet.Packet) = .empty;
    defer freeAll(gpa, &replies);

    for (0..keep_alive_period) |_| try session.pingIfQuiet(gpa);
    try drain(gpa, &session, &replies);
    try std.testing.expectEqual(@as(usize, 0), replies.items.len);

    try session.pingIfQuiet(gpa);
    try drain(gpa, &session, &replies);
    try std.testing.expectEqual(@as(usize, 1), replies.items.len);
    try std.testing.expectEqual(net.packet.Id.keep_alive, replies.items[0].id());

    // A client that keeps talking is never pinged; vanilla only prods a quiet one.
    for (0..keep_alive_period * 2) |_| {
        try session.handle(gpa, &level, .keep_alive);
        try session.pingIfQuiet(gpa);
    }
    replies.clearRetainingCapacity();
    try drain(gpa, &session, &replies);
    try std.testing.expectEqual(@as(usize, 0), replies.items.len);
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
            for (0..world.Chunk.width) |x| {
                for (0..world.Chunk.width) |z| {
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
    const holder = session.player.?;
    holder.inventory.slots[holder.inventory.selected] = .{ .id = .{ .block = .planks }, .count = 1 };

    try session.handle(gpa, &level, .{ .place = .{
        .x = 8,
        .y = 63,
        .z = 8,
        .face = 1,
        .held = .{ .id = @intFromEnum(world.Block.planks), .count = 1, .damage = 0 },
    } });

    try std.testing.expectEqual(world.Block.planks, level.world_map.getBlock(8, 64, 8));
    try std.testing.expect(holder.inventory.slots[holder.inventory.selected] == null);
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
