const std = @import("std");

const assets = @import("assets");
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

pub const Awarded = struct {
    stat: game.stats.Key,
    amount: i8,
};

fn decodeRotation(value: i8) f32 {
    return @as(f32, @floatFromInt(value)) * 360.0 / 256.0;
}

state: State = .greeting,
dimension: world.Dimension = .overworld,
pending_dimension: ?world.Dimension = null,
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
awarded: std.ArrayList(Awarded) = .empty,
sneaking: bool = false,
held_slot: u4 = 0,
window_action: i16 = 0,
crafting: [crafting_grid]?world.Stack = @splat(null),
workbench: [workbench_grid]?world.Stack = @splat(null),
carried: ?world.Stack = null,
opened: ?Opened = null,
aiming_at: [3]i32 = .{ 0, 0, 0 },
aiming_cart: game.Entity.Id = game.Entity.no_id,

pub fn deinit(self: *Connection, gpa: std.mem.Allocator) void {
    self.peers.deinit(gpa);
    self.chat.deinit(gpa);
    self.awarded.deinit(gpa);
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
                self.dimension = @enumFromInt(body.dimension);
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
        .keep_alive => {},
        .spawn_position => |body| self.spawn = .{ body.x, body.y, body.z },
        .update_time => |body| level.world_map.time = body.time,
        .update_health => |body| {
            self.health = body.health;
            if (level.occupants.items.len > 0) level.occupants.items[0].player.health = body.health;
        },
        .respawn => |body| {
            const target: world.Dimension = @enumFromInt(body.dimension);
            if (target != self.dimension) {
                self.dimension = target;
                self.pending_dimension = target;
                self.placed = false;
                self.peers.clearRetainingCapacity();
                self.opened = null;
                return;
            }
            if (level.occupants.items.len > 0) {
                const player = level.occupants.items[0].player;
                player.respawn(player.base.position);
                self.health = player.health;
            }
        },
        .chat => |body| {
            var line: ChatLine = .{};
            line.len = @min(body.message.len, line.bytes.len);
            @memcpy(line.bytes[0..line.len], body.message[0..line.len]);
            try self.chat.append(gpa, line);
        },
        .named_entity_spawn => |body| try self.spawnPeer(gpa, body),
        .mob_spawn => |body| try spawnMob(gpa, level, body),
        .pickup_spawn => |body| try spawnItem(gpa, level, body),
        .vehicle_spawn => |body| try spawnVehicle(gpa, level, body),
        .entity_painting => |body| try spawnPainting(gpa, level, body),
        .entity_metadata => |body| adoptWatched(level, @bitCast(body.entity_id), body.metadata),
        .player_inventory => |body| self.outfitPeer(body),
        .entity_velocity => |body| {
            if (self.bodyById(level, @bitCast(body.entity_id))) |moved| {
                moved.base().motion = .{
                    .x = decodeVelocity(body.motion_x),
                    .y = decodeVelocity(body.motion_y),
                    .z = decodeVelocity(body.motion_z),
                };
            }
        },
        .entity_status => |body| self.entityStatus(level, @bitCast(body.entity_id), body.status),
        .attach_entity => |body| self.attachEntity(level, @bitCast(body.entity_id), @bitCast(body.vehicle_id)),
        .collect => |body| try self.collectItem(gpa, level, @bitCast(body.collected_id), @bitCast(body.collector_id)),
        .animation => |body| {
            const id: game.Entity.Id = @bitCast(body.entity_id);
            switch (body.animate) {
                net.packet.swing_animation => {
                    const peer = self.peerById(id) orelse return;
                    peer.player.swingItem();
                },
                net.packet.wake_up_animation => {
                    const player = self.playerById(level, id) orelse return;
                    try player.wakeUp(&level.world_map, false, false);
                },
                else => {},
            }
        },
        .sleep => |body| {
            if (body.state != net.packet.enter_bed_state) return;
            const player = self.playerById(level, @bitCast(body.entity_id)) orelse return;
            player.layInBed(&level.world_map, body.x, body.y, body.z);
        },
        .destroy_entity => |body| {
            const id: game.Entity.Id = @bitCast(body.entity_id);
            self.removePeer(id);
            _ = level.entities.removeById(gpa, id);
        },
        .entity_teleport => |body| {
            if (self.bodyById(level, @bitCast(body.entity_id))) |moved| {
                moved.warp(
                    body.x,
                    body.y,
                    body.z,
                    decodeRotation(body.yaw),
                    decodeRotation(body.pitch),
                );
            }
        },
        .rel_entity_move => |body| {
            if (self.bodyById(level, @bitCast(body.entity_id))) |moved| {
                moved.steer(true, body.dx, body.dy, body.dz, moved.yaw(), moved.pitch());
            }
        },
        .entity_look => |body| {
            if (self.bodyById(level, @bitCast(body.entity_id))) |moved| {
                moved.steer(false, 0, 0, 0, decodeRotation(body.yaw), decodeRotation(body.pitch));
            }
        },
        .rel_entity_move_look => |body| {
            if (self.bodyById(level, @bitCast(body.entity_id))) |moved| {
                moved.steer(
                    true,
                    body.dx,
                    body.dy,
                    body.dz,
                    decodeRotation(body.yaw),
                    decodeRotation(body.pitch),
                );
            }
        },
        .player_look_move => |body| try self.placePlayer(level, body.x, body.stance, body.z, body.yaw, body.pitch),
        .pre_chunk => |body| try self.preChunk(gpa, level, body.x, body.z, body.load),
        .map_chunk => |body| try self.mapChunk(gpa, level, body),
        .statistic => |body| {
            const stat = game.stats.keyFromStatId(@bitCast(body.stat_id)) orelse return;
            try self.awarded.append(gpa, .{ .stat = stat, .amount = body.amount });
        },
        .play_note_block => |body| level.world_map.playNoteAt(
            body.x,
            body.y,
            body.z,
            @enumFromInt(body.instrument),
            body.pitch,
        ),
        .explosion => |body| try self.showBlast(gpa, level, body),
        .weather => |body| {
            if (body.lightning != lightning_kind) return;
            try level.entities.showLightning(gpa, @bitCast(body.entity_id), .{
                .x = game.Entity.Remote.decode(body.x),
                .y = game.Entity.Remote.decode(body.y),
                .z = game.Entity.Remote.decode(body.z),
            }, &level.world_map.rand);
        },
        .bed => |body| {
            switch (body.state) {
                bed_rain_starts => level.world_map.weather.raining = true,
                bed_rain_stops => level.world_map.weather.raining = false,
                else => {},
            }
            if (body.state != bed_not_valid) return;
            var line: ChatLine = .{};
            line.len = @min(bed_not_valid_line.len, line.bytes.len);
            @memcpy(line.bytes[0..line.len], bed_not_valid_line[0..line.len]);
            try self.chat.append(gpa, line);
        },
        .map_data => |body| {
            if (body.kind != @as(i16, @intFromEnum(world.Item.map))) return;
            const data = try level.world_map.mapData(body.map_id);
            try data.applyPayload(gpa, body.data);
        },
        .update_sign => |body| {
            const y: i32 = body.y;
            const post = try level.world_map.addSign(body.x, y, body.z);
            for (body.lines, 0..) |text, index| post.setLine(index, text);
        },
        .open_window => |body| try self.openWindow(level, body),
        .close_window => self.closeOpenWindow(),
        .set_slot => |body| self.setSlot(level, body.window_id, body.slot, body.stack),
        .window_items => |body| self.setWindowContents(level, body),
        .update_progressbar => |body| self.setProgress(level, body),
        .block_change => |body| try self.blockChange(level, body.x, body.y, body.z, body.block, body.metadata),
        .multi_block_change => |body| try self.multiBlockChange(level, body),
        else => {},
    }
}

pub fn tickBodies(self: *Connection, gpa: std.mem.Allocator, level: *game.Level) !void {
    const rand = &level.world_map.rand;

    level.world_map.weather.tickStrength();
    try level.entities.tickLightning(gpa, &level.world_map, &.{}, rand);

    for (self.peers.items) |*peer| peer.player.tickRemote();

    for (level.entities.mobs.items) |entry| {
        try game.mob.get(entry.type_id).tick(
            entry.animal,
            gpa,
            &level.world_map,
            level.players(),
            rand,
        );
    }

    inline for (.{ "boats", "minecarts" }) |name| {
        for (@field(level.entities, name).items) |*vehicle| {
            vehicle.base.beginTick();
            vehicle.prev_yaw = vehicle.yaw;
            vehicle.prev_pitch = vehicle.pitch;
            game.Entity.stepRemote(vehicle);
        }
    }

    try level.entities.tickItems(gpa, &level.world_map, level.roster.items, rand);
    try level.entities.tickPrimed(gpa, &level.world_map, level.roster.items, rand);
    try level.entities.tickArrows(gpa, &level.world_map, level.roster.items, rand);
    try level.entities.tickFireballs(gpa, &level.world_map, level.roster.items, rand);
    try level.entities.tickHooks(gpa, &level.world_map, level.roster.items, rand);
    tickRemoteFallingBlocks(level);
}

fn tickRemoteFallingBlocks(level: *game.Level) void {
    var index: usize = 0;
    while (index < level.entities.falling_blocks.items.len) {
        const falling = &level.entities.falling_blocks.items[index];
        if (falling.tick(&level.world_map) != .falling) {
            _ = level.entities.falling_blocks.swapRemove(index);
            continue;
        }
        index += 1;
    }
}

fn playerById(self: *Connection, level: *game.Level, id: game.Entity.Id) ?*game.Player {
    if (id == self.entity_id) {
        if (level.occupants.items.len == 0) return null;
        return level.occupants.items[0].player;
    }
    const peer = self.peerById(id) orelse return null;
    return &peer.player;
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
    item: *game.ItemEntity,
    arrow: *game.Arrow,
    fireball: *game.Fireball,
    falling_block: *game.FallingBlock,
    primed_tnt: *game.PrimedTnt,
    boat: *game.Boat,
    minecart: *game.Minecart,
    hook: *game.FishHook,

    fn target(self: Body) *game.Entity.Remote {
        return switch (self) {
            inline else => |it| &it.base.remote.?,
        };
    }

    fn base(self: Body) *game.Entity {
        return switch (self) {
            inline else => |it| &it.base,
        };
    }

    fn yaw(self: Body) f32 {
        return switch (self) {
            inline else => |it| if (@hasField(@TypeOf(it.*), "yaw")) it.yaw else 0,
        };
    }

    fn pitch(self: Body) f32 {
        return switch (self) {
            inline else => |it| if (@hasField(@TypeOf(it.*), "pitch")) it.pitch else 0,
        };
    }

    fn increments(self: Body) i32 {
        const base_steps = game.Entity.Remote.increments_per_update;
        return switch (self) {
            .player, .animal => base_steps,
            .boat => base_steps + game.Entity.Remote.boat_extra_increments,
            .minecart => base_steps + game.Entity.Remote.minecart_extra_increments,
            else => 0,
        };
    }

    fn eases(self: Body) bool {
        return self.increments() > 0;
    }

    fn steer(self: Body, moved: bool, dx: i8, dy: i8, dz: i8, facing: f32, tilt: f32) void {
        const aim = self.target();
        if (moved) {
            aim.shiftBy(dx, dy, dz, facing, tilt);
        } else {
            aim.yaw = facing;
            aim.pitch = tilt;
        }
        aim.increments = self.increments();
        if (!self.eases()) self.snapToTarget();
    }

    fn warp(self: Body, x: i32, y: i32, z: i32, facing: f32, tilt: f32) void {
        self.target().teleportTo(x, y, z, facing, tilt, self.eases());
        self.target().increments = self.increments();
        if (!self.eases()) self.snapToTarget();
    }

    fn snapToTarget(self: Body) void {
        const aim = self.target();
        aim.increments = 0;
        switch (self) {
            inline else => |it| {
                it.base.position = aim.position;
                if (@hasField(@TypeOf(it.*), "yaw")) {
                    it.yaw = @floatCast(aim.yaw);
                    it.pitch = @floatCast(aim.pitch);
                }
            },
        }
    }

    fn place(self: Body, x: i32, y: i32, z: i32, facing: f32, tilt: f32) void {
        switch (self) {
            inline else => |it| {
                const Held = @TypeOf(it.*);
                it.base.remote = .at(x, y, z);
                it.base.position = it.base.remote.?.position;
                it.base.prev_position = it.base.position;
                if (@hasField(Held, "yaw")) {
                    it.yaw = facing;
                    it.prev_yaw = facing;
                    it.pitch = tilt;
                    it.prev_pitch = tilt;
                }
                if (@hasField(Held, "render_yaw")) {
                    it.render_yaw = facing;
                    it.prev_render_yaw = facing;
                }
            },
        }
    }
};

fn bodyById(self: *Connection, level: *game.Level, id: game.Entity.Id) ?Body {
    if (self.peerById(id)) |peer| {
        if (peer.player.base.remote == null) return null;
        return .{ .player = &peer.player };
    }
    if (level.entities.mobById(id)) |entry| {
        if (entry.animal.base.remote == null) return null;
        return .{ .animal = entry.animal };
    }
    inline for (.{
        .{ "items", "item" },
        .{ "arrows", "arrow" },
        .{ "fireballs", "fireball" },
        .{ "falling_blocks", "falling_block" },
        .{ "primed", "primed_tnt" },
        .{ "boats", "boat" },
        .{ "minecarts", "minecart" },
        .{ "hooks", "hook" },
    }) |pair| {
        for (@field(level.entities, pair[0]).items) |*entity| {
            if (entity.base.id != id or entity.base.remote == null) continue;
            return @unionInit(Body, pair[1], entity);
        }
    }
    return null;
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
        .player = game.Player.spawn(math.Vec3.init(0, 0, 0)),
    };
    peer.name.set(body.name);
    peer.player.base.id = id;

    const placed: Body = .{ .player = &peer.player };
    placed.place(body.x, body.y, body.z, decodeRotation(body.rotation), decodeRotation(body.pitch));

    try self.peers.append(gpa, peer);
}

fn spawnMob(gpa: std.mem.Allocator, level: *game.Level, body: anytype) !void {
    const type_id = game.mob.byWireId(body.kind) orelse return;
    const id: game.Entity.Id = @bitCast(body.entity_id);
    _ = level.entities.removeMob(gpa, id);

    const kind = game.mob.get(type_id);
    const animal = try kind.spawn(gpa, math.Vec3.init(0, 0, 0), &level.world_map.rand);
    errdefer kind.destroy(animal, gpa);

    game.mob.adopt(type_id, animal, body.metadata);

    const placed: Body = .{ .animal = animal };
    placed.place(body.x, body.y, body.z, decodeRotation(body.yaw), decodeRotation(body.pitch));

    try level.entities.adoptMobAs(gpa, type_id, animal, id);
}

pub const status_hurt: i8 = 2;
pub const status_death: i8 = 3;
pub const status_wolf_smoke: i8 = 6;
pub const status_wolf_hearts: i8 = 7;
pub const status_wolf_shake: i8 = 8;
pub const hurt_flash_ticks: i32 = 10;

fn outfitPeer(self: *Connection, body: anytype) void {
    const peer = self.peerById(@bitCast(body.entity_id)) orelse return;
    const worn: ?world.Stack = if (body.item_id < 0) null else .{
        .id = world.Id.fromNumeric(body.item_id),
        .count = 1,
        .meta = @bitCast(body.damage),
    };

    if (body.slot == 0) {
        peer.player.inventory.slots[peer.player.inventory.selected] = worn;
        return;
    }
    const armour = body.slot - 1;
    if (armour < 0 or armour >= game.Inventory.armor_size) return;
    peer.player.inventory.armor[@intCast(armour)] = worn;
}

fn entityStatus(self: *Connection, level: *game.Level, id: game.Entity.Id, status: i8) void {
    if (self.peerById(id)) |peer| {
        switch (status) {
            status_hurt => {
                peer.player.hurt_time = hurt_flash_ticks;
                peer.player.limb_swing_amount = 1.5;
                peer.player.playHurtSound(&level.world_map);
            },
            status_death => {
                peer.player.playHurtSound(&level.world_map);
                peer.player.health = 0;
                peer.player.death_time = 1;
            },
            else => {},
        }
        return;
    }

    const entry = level.entities.mobById(id) orelse return;
    switch (status) {
        status_hurt => {
            entry.animal.hurt_time = hurt_flash_ticks;
            entry.animal.limb_swing_amount = 1.5;
            entry.animal.playDamageSound(&level.world_map, entry.animal.hurt_sound, &level.world_map.rand);
        },
        status_death => {
            entry.animal.playDamageSound(&level.world_map, entry.animal.death_sound, &level.world_map.rand);
            entry.animal.health = 0;
            entry.animal.death_time = 1;
        },
        status_wolf_shake => {
            if (entry.type_id == game.mob.wolf) {
                const dog: *game.Wolf = @fieldParentPtr("animal", entry.animal);
                dog.shaking = true;
                dog.shake_running = false;
                dog.shake_time = 0;
                dog.prev_shake_time = 0;
            }
        },
        else => {},
    }
}

fn attachEntity(self: *Connection, level: *game.Level, id: game.Entity.Id, vehicle: game.Entity.Id) void {
    if (id == self.entity_id) {
        if (level.occupants.items.len > 0) level.occupants.items[0].player.riding = vehicle;
        return;
    }
    const peer = self.peerById(id) orelse return;
    peer.player.riding = vehicle;
}

fn collectItem(
    self: *Connection,
    gpa: std.mem.Allocator,
    level: *game.Level,
    collected: game.Entity.Id,
    collector: game.Entity.Id,
) !void {
    _ = collector;
    for (level.entities.items.items, 0..) |dropped, index| {
        if (dropped.base.id != collected) continue;
        try level.entities.pickups.append(gpa, game.PickupFx.spawn(dropped));
        _ = level.entities.items.orderedRemove(index);
        level.world_map.playSoundEffect(
            dropped.base.position.x,
            dropped.base.position.y,
            dropped.base.position.z,
            assets.sounds.random.pop,
            game.ItemEntity.pickup_volume,
            game.ItemEntity.pickupPitch(&level.world_map.rand),
        );
        return;
    }
    _ = self;
}

pub const vehicle_boat: u8 = 1;
pub const vehicle_minecart: u8 = 10;
pub const vehicle_arrow: u8 = 60;
pub const vehicle_fireball: u8 = 63;
pub const vehicle_primed_tnt: u8 = 50;
pub const vehicle_falling_sand: u8 = 70;
pub const vehicle_falling_gravel: u8 = 71;
pub const vehicle_fish_hook: u8 = 90;
pub const fireball_speed_scale: f64 = 8000.0;
pub const item_motion_scale: f64 = 128.0;
pub const velocity_scale: f64 = 8000.0;

fn decodeMotion(value: i8) f64 {
    return @as(f64, @floatFromInt(value)) / item_motion_scale;
}

fn decodeVelocity(value: i16) f64 {
    return @as(f64, @floatFromInt(value)) / velocity_scale;
}

fn spawnItem(gpa: std.mem.Allocator, level: *game.Level, body: anytype) !void {
    const id: game.Entity.Id = @bitCast(body.entity_id);
    _ = level.entities.removeById(gpa, id);

    var dropped: game.ItemEntity = .{
        .base = game.Entity.init(math.Vec3.init(0, 0, 0), game.ItemEntity.width, game.ItemEntity.height),
        .stack = .{
            .id = world.Id.fromNumeric(body.item_id),
            .count = @intCast(@max(body.count, 0)),
            .meta = @bitCast(body.damage),
        },
    };
    dropped.base.id = id;

    const placed: Body = .{ .item = &dropped };
    placed.place(body.x, body.y, body.z, 0, 0);
    dropped.base.motion = .{
        .x = decodeMotion(body.rotation),
        .y = decodeMotion(body.pitch),
        .z = decodeMotion(body.roll),
    };

    try level.entities.items.append(gpa, dropped);
}

fn spawnPainting(gpa: std.mem.Allocator, level: *game.Level, body: anytype) !void {
    const id: game.Entity.Id = @bitCast(body.entity_id);
    _ = level.entities.removeById(gpa, id);

    const art = game.Painting.Art.byTitle(body.title) orelse return;
    const facing: u2 = @truncate(@as(u32, @bitCast(body.direction)));

    var hung = game.Painting.place(.{ body.x, body.y, body.z }, facing, art);
    hung.id = id;
    try level.entities.paintings.append(gpa, hung);
}

fn spawnVehicle(gpa: std.mem.Allocator, level: *game.Level, body: anytype) !void {
    const id: game.Entity.Id = @bitCast(body.entity_id);
    _ = level.entities.removeById(gpa, id);

    switch (body.kind) {
        vehicle_boat => {
            var boat = game.Boat.spawn(0, 0, 0);
            boat.base.id = id;
            (Body{ .boat = &boat }).place(body.x, body.y, body.z, 0, 0);
            try level.entities.boats.append(gpa, boat);
        },
        vehicle_minecart, vehicle_minecart + 1, vehicle_minecart + 2 => {
            var cart = game.Minecart.spawn(0, 0, 0, @enumFromInt(body.kind - vehicle_minecart));
            cart.base.id = id;
            (Body{ .minecart = &cart }).place(body.x, body.y, body.z, 0, 0);
            try level.entities.minecarts.append(gpa, cart);
        },
        vehicle_arrow => {
            var shot: game.Arrow = .{
                .base = game.Entity.init(math.Vec3.init(0, 0, 0), game.Arrow.size, game.Arrow.size),
                .owner = @bitCast(body.thrower_id),
            };
            shot.base.id = id;
            (Body{ .arrow = &shot }).place(body.x, body.y, body.z, 0, 0);
            try level.entities.arrows.append(gpa, shot);
        },
        vehicle_fireball => {
            var shot: game.Fireball = .{
                .base = game.Entity.init(math.Vec3.init(0, 0, 0), game.Fireball.size, game.Fireball.size),
                .shooter = @bitCast(body.thrower_id),
                .acceleration = math.Vec3.init(
                    @as(f64, @floatFromInt(body.speed_x)) / fireball_speed_scale,
                    @as(f64, @floatFromInt(body.speed_y)) / fireball_speed_scale,
                    @as(f64, @floatFromInt(body.speed_z)) / fireball_speed_scale,
                ),
            };
            shot.base.id = id;
            (Body{ .fireball = &shot }).place(body.x, body.y, body.z, 0, 0);
            try level.entities.fireballs.append(gpa, shot);
        },
        vehicle_primed_tnt => {
            var lit = game.PrimedTnt.spawn(math.Vec3.init(0, 0, 0), world.tnt.fuse_ticks, &level.world_map.rand);
            lit.base.id = id;
            (Body{ .primed_tnt = &lit }).place(body.x, body.y, body.z, 0, 0);
            try level.entities.primed.append(gpa, lit);
        },
        vehicle_falling_sand, vehicle_falling_gravel => {
            const block: world.Block = if (body.kind == vehicle_falling_sand) .sand else .gravel;
            var falling = game.FallingBlock.spawn(math.Vec3.init(0, 0, 0), block);
            falling.base.id = id;
            (Body{ .falling_block = &falling }).place(body.x, body.y, body.z, 0, 0);
            try level.entities.falling_blocks.append(gpa, falling);
        },
        vehicle_fish_hook => {
            var hook: game.FishHook = .{
                .base = game.Entity.init(math.Vec3.init(0, 0, 0), game.FishHook.size, game.FishHook.size),
                .angler = @bitCast(body.thrower_id),
            };
            hook.base.id = id;
            (Body{ .hook = &hook }).place(body.x, body.y, body.z, 0, 0);
            try level.entities.hooks.append(gpa, hook);
        },
        else => {},
    }
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
    const width = world.Chunk.width;
    if (body.size_x != width or body.size_z != width) return;
    if (body.size_y != world.Chunk.height) return;

    const coord: world.World.ChunkCoord = .{
        .x = @divFloor(body.x, width),
        .z = @divFloor(body.z, width),
    };
    const chunk = try level.world_map.createChunk(coord.x, coord.z);
    world.chunk_payload.decompressFull(gpa, chunk, body.compressed) catch return;

    try level.world_map.markDecorated(coord.x, coord.z);
    self.loaded_chunks += 1;
}

fn blockChange(_: *Connection, level: *game.Level, x: i32, y: u8, z: i32, block: u8, metadata: u8) !void {
    level.world_map.setBlock(x, @intCast(y), z, @enumFromInt(block));
    level.world_map.setBlockMetadata(x, @intCast(y), z, @truncate(metadata));
    try level.world_map.markChanged(x, @intCast(y), z);
}

fn multiBlockChange(self: *Connection, level: *game.Level, body: anytype) !void {
    const width = world.Chunk.width;
    for (body.coordinates, body.types, body.metadata) |packed_xz, block, meta| {
        const raw: u16 = @bitCast(packed_xz);
        const local_x: i32 = @intCast((raw >> 12) & 0x0f);
        const local_z: i32 = @intCast((raw >> 8) & 0x0f);
        const y: i32 = @intCast(raw & 0xff);
        try self.blockChange(
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

pub fn takeAwards(self: *Connection, gpa: std.mem.Allocator) ![]Awarded {
    return self.awarded.toOwnedSlice(gpa);
}

pub fn takeDimensionChange(self: *Connection) ?world.Dimension {
    const target = self.pending_dimension orelse return null;
    self.pending_dimension = null;
    return target;
}

pub fn say(self: *Connection, gpa: std.mem.Allocator, message: []const u8) !void {
    if (self.state != .playing) return;
    try self.send(gpa, .{ .chat = .{ .message = message } });
}

pub fn reportSwing(self: *Connection, gpa: std.mem.Allocator) !void {
    if (self.state != .playing) return;
    try self.send(gpa, .{ .animation = .{
        .entity_id = @bitCast(self.entity_id),
        .animate = net.packet.swing_animation,
    } });
}

pub const use_interact: i8 = 0;
pub const use_attack: i8 = 1;
pub const action_start_sneaking: i8 = 1;
pub const action_stop_sneaking: i8 = 2;
pub const player_window: i8 = 0;
pub const carried_window: i8 = -1;
pub const carried_slot: i16 = -1;
pub const outside_slot: i16 = -999;
pub const crafting_grid: usize = 4;
pub const workbench_grid: usize = 9;
pub const player_window_slots: usize = 45;
pub const craft_result_slot: usize = 0;
pub const craft_input_start: usize = 1;
pub const armor_start: usize = 5;
pub const main_start: usize = 9;
pub const hotbar_start: usize = 36;

pub const window_chest: i8 = 0;
pub const window_workbench: i8 = 1;
pub const window_furnace: i8 = 2;
pub const window_dispenser: i8 = 3;

pub const Opened = struct {
    id: i8,
    kind: i8,
    store: usize,
    at: [3]i32,
    cart: game.Entity.Id = game.Entity.no_id,
};

pub fn openWindowId(self: *const Connection) i8 {
    const open = self.opened orelse return player_window;
    return open.id;
}

pub fn reportWindowClick(
    self: *Connection,
    gpa: std.mem.Allocator,
    slot: i16,
    right_click: bool,
    shift: bool,
    carried: ?world.Stack,
) !void {
    if (self.state != .playing) return;
    self.window_action +%= 1;
    try self.send(gpa, .{ .window_click = .{
        .window_id = self.openWindowId(),
        .slot = slot,
        .right_click = if (right_click) 1 else 0,
        .action = self.window_action,
        .shift = shift,
        .held = wireStack(carried),
    } });
}

pub fn reportSign(
    self: *Connection,
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

pub fn reportCloseWindow(self: *Connection, gpa: std.mem.Allocator) !void {
    if (self.state != .playing) return;
    const id = self.openWindowId();
    self.closeOpenWindow();
    try self.send(gpa, .{ .close_window = .{ .window_id = id } });
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

fn playerSlot(level: *game.Level, slot: usize, store: usize) ?*?world.Stack {
    if (level.occupants.items.len == 0) return null;
    const player = level.occupants.items[0].player;

    const offset = slot - store;
    const main_rows = game.Inventory.size - game.Inventory.hotbar_size;
    if (offset < main_rows) return &player.inventory.slots[game.Inventory.hotbar_size + offset];
    if (offset < game.Inventory.size) return &player.inventory.slots[offset - main_rows];
    return null;
}

fn storeSlot(self: *Connection, level: *game.Level, open: Opened, slot: usize) ?*?world.Stack {
    switch (open.kind) {
        window_workbench => {
            if (slot == craft_result_slot) return null;
            return &self.workbench[slot - craft_input_start];
        },
        window_furnace => {
            const fire = level.world_map.furnaceAt(open.at[0], open.at[1], open.at[2]) orelse return null;
            return switch (slot) {
                0 => &fire.input,
                1 => &fire.fuel,
                2 => &fire.output,
                else => null,
            };
        },
        window_dispenser => {
            const trap = level.world_map.dispenserAt(open.at[0], open.at[1], open.at[2]) orelse return null;
            return trap.slot(slot);
        },
        window_chest => {
            if (open.cart != game.Entity.no_id) {
                const cart = level.entities.minecartById(open.cart) orelse return null;
                return cart.slot(slot);
            }
            const pair = level.world_map.chestPairAt(open.at[0], open.at[1], open.at[2]);
            const half = if (slot < world.chest.slot_count) pair.upper else (pair.lower orelse return null);
            const box = level.world_map.chestAt(half.x, half.y, half.z) orelse return null;
            return box.slot(slot % world.chest.slot_count);
        },
        else => return null,
    }
}

fn windowSlot(self: *Connection, level: *game.Level, slot: usize) ?*?world.Stack {
    if (self.opened) |open| {
        if (slot < open.store) return self.storeSlot(level, open, slot);
        return playerSlot(level, slot, open.store);
    }

    if (slot == craft_result_slot) return null;
    if (slot < armor_start) return &self.crafting[slot - craft_input_start];

    if (level.occupants.items.len == 0) return null;
    const player = level.occupants.items[0].player;

    if (slot < main_start) return &player.inventory.armor[slot - armor_start];
    if (slot < hotbar_start) return &player.inventory.slots[slot];
    if (slot < player_window_slots) return &player.inventory.slots[slot - hotbar_start];
    return null;
}

fn openWindow(self: *Connection, level: *game.Level, body: anytype) !void {
    const store: usize = @intCast(@max(body.slots, 0));
    var open: Opened = .{
        .id = body.window_id,
        .kind = body.kind,
        .store = store,
        .at = self.aiming_at,
        .cart = self.aiming_cart,
    };
    if (body.kind == window_workbench) {
        open.store = workbench_grid + 1;
        self.workbench = @splat(null);
    }

    switch (body.kind) {
        window_furnace => _ = try level.world_map.addFurnace(open.at[0], open.at[1], open.at[2]),
        window_dispenser => _ = try level.world_map.addDispenser(open.at[0], open.at[1], open.at[2]),
        window_chest => {
            if (open.cart == game.Entity.no_id) {
                const pair = level.world_map.chestPairAt(open.at[0], open.at[1], open.at[2]);
                _ = try level.world_map.addChest(pair.upper.x, pair.upper.y, pair.upper.z);
                if (pair.lower) |at| _ = try level.world_map.addChest(at.x, at.y, at.z);
            }
        },
        else => {},
    }

    self.opened = open;
    self.window_action = 0;
}

pub fn aimAtBlock(self: *Connection, x: i32, y: i32, z: i32) void {
    self.aiming_at = .{ x, y, z };
    self.aiming_cart = game.Entity.no_id;
}

pub fn aimAtMinecart(self: *Connection, id: game.Entity.Id) void {
    self.aiming_cart = id;
}

pub fn closeOpenWindow(self: *Connection) void {
    self.opened = null;
    self.window_action = 0;
}

fn setSlot(self: *Connection, level: *game.Level, window_id: i8, slot: i16, stack: ?net.packet.Stack) void {
    if (window_id == carried_window and slot == carried_slot) {
        self.carried = fromWire(stack);
        return;
    }
    if (window_id != self.openWindowId() or slot < 0) return;
    const target = self.windowSlot(level, @intCast(slot)) orelse return;
    target.* = fromWire(stack);
}

fn showBlast(self: *Connection, gpa: std.mem.Allocator, level: *game.Level, body: anytype) !void {
    _ = self;
    const at = math.Vec3.init(body.x, body.y, body.z);
    const rand = &level.world_map.rand;
    level.world_map.playSoundEffect(
        at.x,
        at.y,
        at.z,
        assets.sounds.random.explode,
        game.explosion.blast_volume,
        game.explosion.blastPitch(rand),
    );

    const origin: [3]i32 = .{
        @intFromFloat(body.x),
        @intFromFloat(body.y),
        @intFromFloat(body.z),
    };

    for (body.broken) |offset| {
        const cell = math.Vec3.init(
            @as(f64, @floatFromInt(origin[0] + offset[0])) + rand.nextDouble(),
            @as(f64, @floatFromInt(origin[1] + offset[1])) + rand.nextDouble(),
            @as(f64, @floatFromInt(origin[2] + offset[2])) + rand.nextDouble(),
        );
        const away = cell.sub(at);
        const reach = @sqrt(away.x * away.x + away.y * away.y + away.z * away.z);
        if (reach <= 0.0) continue;

        var speed = blast_drift / (reach / @as(f64, body.radius) + blast_falloff);
        speed *= @as(f64, rand.nextFloat() * rand.nextFloat() + 0.3);
        const drift = math.Vec3.init(
            away.x / reach * speed,
            away.y / reach * speed,
            away.z / reach * speed,
        );
        try level.entities.particles.append(gpa, game.Particle.spawnExplode(cell, drift, rand));
        try level.entities.particles.append(gpa, game.Particle.spawnSmoke(cell, drift, rand));
    }
}

const blast_drift: f64 = 0.5;
const blast_falloff: f64 = 0.1;

fn setProgress(self: *Connection, level: *game.Level, body: anytype) void {
    const open = self.opened orelse return;
    if (body.window_id != open.id or open.kind != window_furnace) return;

    const fire = level.world_map.furnaceAt(open.at[0], open.at[1], open.at[2]) orelse return;
    switch (body.bar) {
        0 => fire.cook_time = body.value,
        1 => fire.burn_time = body.value,
        2 => fire.item_burn_time = body.value,
        else => {},
    }
}

fn setWindowContents(self: *Connection, level: *game.Level, body: anytype) void {
    for (body.stacks, 0..) |stack, slot| {
        self.setSlot(level, body.window_id, @intCast(slot), stack);
    }
}

pub fn reportUse(self: *Connection, gpa: std.mem.Allocator, target: game.Entity.Id, attack: bool) !void {
    if (self.state != .playing) return;
    try self.send(gpa, .{ .use_entity = .{
        .player_id = @bitCast(self.entity_id),
        .target_id = @bitCast(target),
        .left_click = if (attack) use_attack else use_interact,
    } });
}

pub fn reportSneak(self: *Connection, gpa: std.mem.Allocator, sneaking: bool) !void {
    if (self.state != .playing or sneaking == self.sneaking) return;
    self.sneaking = sneaking;
    try self.send(gpa, .{ .entity_action = .{
        .entity_id = @bitCast(self.entity_id),
        .state = if (sneaking) action_start_sneaking else action_stop_sneaking,
    } });
}

pub fn reportHeldSlot(self: *Connection, gpa: std.mem.Allocator, slot: u4) !void {
    if (self.state != .playing or slot == self.held_slot) return;
    self.held_slot = slot;
    try self.send(gpa, .{ .block_item_switch = .{ .slot = slot } });
}

pub fn reportRespawn(self: *Connection, gpa: std.mem.Allocator) !void {
    if (self.state != .playing) return;
    try self.send(gpa, .{ .respawn = .{ .dimension = 0 } });
}

pub const dig_started: u8 = 0;
pub const dig_finished: u8 = 2;

pub fn reportDigStart(self: *Connection, gpa: std.mem.Allocator, x: i32, y: i32, z: i32, face: u8) !void {
    if (self.state != .playing) return;
    try self.send(gpa, .{ .block_dig = .{
        .status = dig_started,
        .x = x,
        .y = @intCast(y),
        .z = z,
        .face = face,
    } });
}

pub fn reportDig(self: *Connection, gpa: std.mem.Allocator, x: i32, y: i32, z: i32, face: u8) !void {
    if (self.state != .playing) return;
    try self.send(gpa, .{ .block_dig = .{
        .status = dig_finished,
        .x = x,
        .y = @intCast(y),
        .z = z,
        .face = face,
    } });
}

pub const bed_not_valid: i8 = 0;
pub const bed_rain_starts: i8 = 1;
pub const bed_rain_stops: i8 = 2;
pub const lightning_kind: i8 = 1;
pub const bed_not_valid_line = "Your home bed was missing or obstructed";
pub const in_air_face: u8 = 255;

pub fn reportUseInAir(self: *Connection, gpa: std.mem.Allocator, held: ?net.packet.Stack) !void {
    if (self.state != .playing) return;
    try self.send(gpa, .{ .place = .{
        .x = -1,
        .y = in_air_face,
        .z = -1,
        .face = in_air_face,
        .held = held,
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
    self.aimAtBlock(x, y, z);
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
    return game.Level.init(gpa, try world.Generator.init(gpa, .overworld, 1));
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
    for (0..world.Chunk.width) |x| {
        for (0..world.Chunk.width) |z| {
            source.setBlock(@intCast(x), 40, @intCast(z), .stone);
            source.setSkyLight(@intCast(x), 41, @intCast(z), 15);
        }
    }
    source.setBlockMetadata(1, 40, 2, 6);

    const compressed = try world.chunk_payload.compressFull(gpa, source);
    defer gpa.free(compressed);

    try connection.handle(gpa, &level, testing_username, .{ .pre_chunk = .{ .x = 2, .z = -3, .load = true } });
    try connection.handle(gpa, &level, testing_username, .{ .map_chunk = .{
        .x = 2 * world.Chunk.width,
        .y = 0,
        .z = -3 * world.Chunk.width,
        .size_x = world.Chunk.width,
        .size_y = world.Chunk.height,
        .size_z = world.Chunk.width,
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
