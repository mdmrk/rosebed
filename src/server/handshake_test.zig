const std = @import("std");

const game = @import("game");
const math = @import("math");
const net = @import("net");
const remote = @import("remote");
const world = @import("world");

const Session = @import("session.zig");

const Pair = struct {
    gpa: std.mem.Allocator,
    server_level: game.Level,
    client_level: game.Level,
    session: Session = .{},
    connection: remote.Connection = .{},
    client_player: game.Player,

    const username = "Tester";

    fn init(gpa: std.mem.Allocator) !Pair {
        return .{
            .gpa = gpa,
            .server_level = game.Level.init(gpa, try world.Generator.init(gpa, .overworld, 4242)),
            .client_level = game.Level.init(gpa, try world.Generator.init(gpa, .overworld, 0)),
            .client_player = game.Player.spawn(math.Vec3.init(0, 0, 0)),
        };
    }

    fn deinit(self: *Pair) void {
        self.session.leave(self.gpa, &self.server_level);
        self.session.deinit(self.gpa);
        self.connection.deinit(self.gpa);
        self.server_level.deinit(self.gpa);
        self.client_level.deinit(self.gpa);
    }

    fn blockNeedsUpdate(context: *anyopaque, x: i32, y: i32, z: i32) std.mem.Allocator.Error!void {
        const self: *Pair = @ptrCast(@alignCast(context));
        if (y < 0 or y >= world.constants.chunk_height) return;
        const block = self.server_level.world_map.getBlock(x, y, z);
        const metadata = self.server_level.world_map.getBlockMetadata(x, y, z);
        self.session.sendBlockChange(self.gpa, x, y, z, block, metadata) catch return error.OutOfMemory;
    }

    fn redrawAll(_: *anyopaque) std.mem.Allocator.Error!void {}

    fn start(self: *Pair) !void {
        self.server_level.attach();
        self.server_level.world_map.access = .{
            .context = self,
            .markBlockNeedsUpdate = blockNeedsUpdate,
            .updateAllRenderers = redrawAll,
        };
        self.server_level.spawn = .{ 8, 70, 8 };
        self.client_level.attach();
        try self.client_level.enter(self.gpa, &self.client_player);
        try self.connection.begin(self.gpa, username);
    }

    fn pumpToServer(self: *Pair) !void {
        const bytes = try self.connection.takeOutbox(self.gpa);
        defer self.gpa.free(bytes);

        var reader = std.Io.Reader.fixed(bytes);
        while (reader.bufferedLen() > 0) {
            const id = try net.packet.readId(&reader);
            try std.testing.expect(net.packet.direction(id).to_server);
            const message = try net.packet.readBody(self.gpa, &reader, id);
            defer message.deinit(self.gpa);
            try self.session.handle(self.gpa, &self.server_level, message);
        }
    }

    fn pumpToClient(self: *Pair) !usize {
        const bytes = try self.session.takeOutbox(self.gpa);
        defer self.gpa.free(bytes);

        var seen: usize = 0;
        var reader = std.Io.Reader.fixed(bytes);
        while (reader.bufferedLen() > 0) {
            const id = try net.packet.readId(&reader);
            try std.testing.expect(net.packet.direction(id).to_client);
            const message = try net.packet.readBody(self.gpa, &reader, id);
            defer message.deinit(self.gpa);
            try self.connection.handle(self.gpa, &self.client_level, username, message);
            seen += 1;
        }
        return seen;
    }

    fn settle(self: *Pair, rounds: usize) !void {
        for (0..rounds) |_| {
            try self.pumpToServer();
            _ = try self.session.streamChunks(self.gpa, &self.server_level, Session.chunks_per_tick);
            _ = try self.pumpToClient();
        }
    }

    fn trackMobs(self: *Pair) !void {
        var peers: std.ArrayList(Session.Peer) = .empty;
        defer peers.deinit(self.gpa);

        for (self.server_level.entities.mobs.items) |entry| {
            try peers.append(self.gpa, .{ .id = entry.animal.base.id, .body = .{ .mob = entry } });
        }

        try self.session.trackPeers(self.gpa, peers.items);
        _ = try self.pumpToClient();
    }

    fn trackWorld(self: *Pair, rounds: usize) !void {
        var peers: std.ArrayList(Session.Peer) = .empty;
        defer peers.deinit(self.gpa);

        for (0..rounds) |_| {
            self.server_level.entities.stampIds();
            peers.clearRetainingCapacity();
            try Session.collectWorldPeers(self.gpa, &self.server_level, &peers);
            try self.session.trackPeers(self.gpa, peers.items);
            _ = try self.pumpToClient();
            try self.connection.tickBodies(self.gpa, &self.client_level);
        }
    }

    fn standOnGround(self: *Pair) [3]i32 {
        const feet = self.client_player.base.position;
        const x: i32 = @intFromFloat(@floor(feet.x));
        const z: i32 = @intFromFloat(@floor(feet.z));

        var y: i32 = world.constants.chunk_height - 1;
        while (y > 0 and !self.server_level.world_map.getBlock(x, y, z).isSolid()) : (y -= 1) {}

        const stand: math.Vec3 = .{
            .x = @as(f64, @floatFromInt(x)) + 0.5,
            .y = @floatFromInt(y + 1),
            .z = @as(f64, @floatFromInt(z)) + 0.5,
        };
        self.client_player.base.position = stand;
        self.session.player.?.base.position = stand;
        return .{ x, y, z };
    }
};

test "a rosebed client and a rosebed server complete the join handshake" {
    const gpa = std.testing.allocator;
    var pair = try Pair.init(gpa);
    defer pair.deinit();
    try pair.start();

    try pair.settle(3);

    try std.testing.expectEqual(Session.State.playing, pair.session.state);
    try std.testing.expectEqual(remote.Connection.State.playing, pair.connection.state);
    try std.testing.expectEqualStrings("Tester", pair.session.name.text());
    try std.testing.expectEqual(pair.session.player.?.base.id, pair.connection.entity_id);
    try std.testing.expectEqual(pair.server_level.generator.worldSeed(), pair.connection.map_seed);
    try std.testing.expectEqual([3]i32{ 8, 70, 8 }, pair.connection.spawn);
}

test "the client is put where the server says, feet and eye line the right way round" {
    const gpa = std.testing.allocator;
    var pair = try Pair.init(gpa);
    defer pair.deinit();
    try pair.start();

    try pair.settle(3);

    try std.testing.expect(pair.connection.placed);
    try std.testing.expectApproxEqAbs(@as(f64, 8.5), pair.client_player.base.position.x, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 70.0), pair.client_player.base.position.y, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 8.5), pair.client_player.base.position.z, 1.0e-9);
}

test "chunks the server streams arrive as real blocks on the client" {
    const gpa = std.testing.allocator;
    var pair = try Pair.init(gpa);
    defer pair.deinit();
    try pair.start();

    try pair.settle(6);

    try std.testing.expect(pair.connection.loaded_chunks > 0);

    var matched: usize = 0;
    var it = pair.client_level.world_map.chunks.iterator();
    while (it.next()) |entry| {
        const coord = entry.key_ptr.*;
        const theirs = pair.server_level.world_map.getChunk(coord.x, coord.z) orelse continue;
        try std.testing.expectEqualSlices(world.Block, &theirs.blocks, &entry.value_ptr.*.blocks);
        try std.testing.expectEqualSlices(u8, &theirs.sky_light.data, &entry.value_ptr.*.sky_light.data);
        matched += 1;
    }
    try std.testing.expect(matched > 0);
}

test "a block the client digs is broken on the server and echoed back" {
    const gpa = std.testing.allocator;
    var pair = try Pair.init(gpa);
    defer pair.deinit();
    try pair.start();
    try pair.settle(6);

    const ground = pair.standOnGround();
    const x, const y, const z = .{ ground[0], ground[1], ground[2] };

    try std.testing.expect(pair.server_level.world_map.getBlock(x, y, z) != .air);
    try std.testing.expect(pair.client_level.world_map.getBlock(x, y, z) != .air);

    try pair.connection.reportDig(gpa, x, y, z, 1);
    try pair.settle(2);

    try std.testing.expectEqual(world.Block.air, pair.server_level.world_map.getBlock(x, y, z));
    try std.testing.expectEqual(world.Block.air, pair.client_level.world_map.getBlock(x, y, z));
}

test "a block the client places appears on both sides" {
    const gpa = std.testing.allocator;
    var pair = try Pair.init(gpa);
    defer pair.deinit();
    try pair.start();
    try pair.settle(6);

    const ground = pair.standOnGround();
    const x, const y, const z = .{ ground[0], ground[1], ground[2] };

    try pair.server_level.world_map.setBlockWithNotify(x, y + 1, z, .air);
    try pair.settle(2);

    const holder = pair.session.player.?;
    holder.inventory.slots[holder.inventory.selected] = .{ .id = .{ .block = .planks }, .count = 2 };

    try pair.connection.reportPlace(gpa, x, y, z, 1, .{
        .id = @intFromEnum(world.Block.planks),
        .count = 2,
        .damage = 0,
    });
    try pair.settle(2);

    try std.testing.expectEqual(world.Block.planks, pair.server_level.world_map.getBlock(x, y + 1, z));
    try std.testing.expectEqual(world.Block.planks, pair.client_level.world_map.getBlock(x, y + 1, z));
    try std.testing.expectEqual(@as(u8, 1), holder.inventory.slots[holder.inventory.selected].?.count);
}

test "where the client walks is where the server puts it" {
    const gpa = std.testing.allocator;
    var pair = try Pair.init(gpa);
    defer pair.deinit();
    try pair.start();
    try pair.settle(3);

    pair.client_player.base.position = .{ .x = 40.25, .y = 72.0, .z = -13.5 };
    pair.client_player.yaw = 123.0;
    try pair.connection.reportPosition(gpa, &pair.client_player);
    try pair.pumpToServer();

    const on_server = pair.session.player.?;
    try std.testing.expectApproxEqAbs(@as(f64, 40.25), on_server.base.position.x, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 72.0), on_server.base.position.y, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -13.5), on_server.base.position.z, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f32, 123.0), on_server.yaw, 1.0e-6);
}

fn spawnServerMob(pair: *Pair, comptime T: type, type_id: game.mob.Id) !*T {
    const at = pair.session.player.?.base.position;
    const animal = try pair.server_level.entities.spawnMob(
        pair.gpa,
        type_id,
        .{ .x = at.x + 2.0, .y = at.y, .z = at.z - 1.0 },
        &pair.server_level.world_map.rand,
    );
    return @fieldParentPtr("animal", animal);
}

test "a mob on the server turns into a real mob on the client" {
    const gpa = std.testing.allocator;
    var pair = try Pair.init(gpa);
    defer pair.deinit();
    try pair.start();
    try pair.settle(3);

    const pig = try spawnServerMob(&pair, game.Pig, game.mob.pig);
    pig.saddled = true;
    try pair.trackMobs();

    const seen = pair.client_level.entities.first(game.Pig, game.mob.pig).?;
    try std.testing.expectEqual(pig.animal.base.id, seen.animal.base.id);
    try std.testing.expect(seen.saddled);
    try std.testing.expectApproxEqAbs(
        pig.animal.base.position.x,
        seen.animal.base.position.x,
        1.0 / 32.0,
    );
    try std.testing.expectApproxEqAbs(
        pig.animal.base.position.z,
        seen.animal.base.position.z,
        1.0 / 32.0,
    );
}

test "a slime arrives at the size the server rolled for it, not a default one" {
    const gpa = std.testing.allocator;
    var pair = try Pair.init(gpa);
    defer pair.deinit();
    try pair.start();
    try pair.settle(3);

    const slime = try spawnServerMob(&pair, game.Slime, game.mob.slime);
    slime.setSize(4);
    try pair.trackMobs();

    const seen = pair.client_level.entities.first(game.Slime, game.mob.slime).?;
    try std.testing.expectEqual(@as(u8, 4), seen.size);
    try std.testing.expectEqual(slime.animal.base.width, seen.animal.base.width);
}

test "shearing a sheep the client can already see reaches it as a metadata update" {
    const gpa = std.testing.allocator;
    var pair = try Pair.init(gpa);
    defer pair.deinit();
    try pair.start();
    try pair.settle(3);

    const sheep = try spawnServerMob(&pair, game.Sheep, game.mob.sheep);
    sheep.fleece_color = 12;
    try pair.trackMobs();

    const woolly = pair.client_level.entities.first(game.Sheep, game.mob.sheep).?;
    try std.testing.expectEqual(@as(u4, 12), woolly.fleece_color);
    try std.testing.expect(!woolly.sheared);

    sheep.sheared = true;
    try pair.trackMobs();

    try std.testing.expectEqual(@as(usize, 1), pair.client_level.entities.mobs.items.len);
    try std.testing.expect(pair.client_level.entities.first(game.Sheep, game.mob.sheep).?.sheared);
}

test "a mob the server stops sending is taken off the client" {
    const gpa = std.testing.allocator;
    var pair = try Pair.init(gpa);
    defer pair.deinit();
    try pair.start();
    try pair.settle(3);

    const cow = try spawnServerMob(&pair, game.Cow, game.mob.cow);
    try pair.trackMobs();
    try std.testing.expectEqual(@as(usize, 1), pair.client_level.entities.mobs.items.len);

    try std.testing.expect(pair.server_level.entities.removeMob(gpa, cow.animal.base.id));
    try pair.trackMobs();

    try std.testing.expectEqual(@as(usize, 0), pair.client_level.entities.mobs.items.len);
}

const Trio = struct {
    gpa: std.mem.Allocator,
    level: game.Level,
    a: Side,
    b: Side,

    const Side = struct {
        name: []const u8,
        session: Session = .{},
        connection: remote.Connection = .{},
        level: game.Level,
        player: game.Player,
    };

    fn init(gpa: std.mem.Allocator) !Trio {
        return .{
            .gpa = gpa,
            .level = game.Level.init(gpa, try world.Generator.init(gpa, .overworld, 77)),
            .a = .{
                .name = "Alice",
                .level = game.Level.init(gpa, try world.Generator.init(gpa, .overworld, 0)),
                .player = game.Player.spawn(math.Vec3.init(0, 0, 0)),
            },
            .b = .{
                .name = "Bob",
                .level = game.Level.init(gpa, try world.Generator.init(gpa, .overworld, 0)),
                .player = game.Player.spawn(math.Vec3.init(0, 0, 0)),
            },
        };
    }

    fn deinit(self: *Trio) void {
        for ([_]*Side{ &self.a, &self.b }) |side| {
            side.session.leave(self.gpa, &self.level);
            side.session.deinit(self.gpa);
            side.connection.deinit(self.gpa);
            side.level.deinit(self.gpa);
        }
        self.level.deinit(self.gpa);
    }

    fn start(self: *Trio) !void {
        self.level.attach();
        self.level.spawn = .{ 8, 70, 8 };
        for ([_]*Side{ &self.a, &self.b }) |side| {
            side.level.attach();
            try side.level.enter(self.gpa, &side.player);
            try side.connection.begin(self.gpa, side.name);
        }
    }

    fn peers(self: *Trio, out: *std.ArrayList(Session.Peer)) !void {
        out.clearRetainingCapacity();
        for ([_]*Side{ &self.a, &self.b }) |side| {
            if (side.session.state != .playing) continue;
            const player = side.session.player orelse continue;
            try out.append(self.gpa, .{
                .id = player.base.id,
                .body = .{ .player = .{ .name = side.session.name.text(), .player = player } },
            });
        }

        for (self.level.entities.mobs.items) |entry| {
            try out.append(self.gpa, .{ .id = entry.animal.base.id, .body = .{ .mob = entry } });
        }
    }

    fn pump(self: *Trio, side: *Side) !void {
        const up = try side.connection.takeOutbox(self.gpa);
        defer self.gpa.free(up);
        var reader = std.Io.Reader.fixed(up);
        while (reader.bufferedLen() > 0) {
            const id = try net.packet.readId(&reader);
            const message = try net.packet.readBody(self.gpa, &reader, id);
            defer message.deinit(self.gpa);
            try side.session.handle(self.gpa, &self.level, message);
        }

        const down = try side.session.takeOutbox(self.gpa);
        defer self.gpa.free(down);
        var back = std.Io.Reader.fixed(down);
        while (back.bufferedLen() > 0) {
            const id = try net.packet.readId(&back);
            const message = try net.packet.readBody(self.gpa, &back, id);
            defer message.deinit(self.gpa);
            try side.connection.handle(self.gpa, &side.level, side.name, message);
        }
    }

    fn settle(self: *Trio, rounds: usize) !void {
        var list: std.ArrayList(Session.Peer) = .empty;
        defer list.deinit(self.gpa);

        for (0..rounds) |_| {
            try self.pump(&self.a);
            try self.pump(&self.b);

            try self.peers(&list);
            for ([_]*Side{ &self.a, &self.b }) |side| {
                try side.session.trackPeers(self.gpa, list.items);
                try side.session.reportHealth(self.gpa);
            }

            for ([_]*Side{ &self.a, &self.b }) |speaker| {
                const line = speaker.session.takeChat() orelse continue;
                for ([_]*Side{ &self.a, &self.b }) |listener| {
                    try listener.session.sendChat(self.gpa, line.text());
                }
            }

            for ([_]*Side{ &self.a, &self.b }) |dresser| {
                const worn_by = dresser.session.player orelse continue;
                var changed: [Session.equipment_slots]bool = undefined;
                if (!dresser.session.refreshEquipment(&changed)) continue;
                for (changed, 0..) |dirty, slot| {
                    if (!dirty) continue;
                    const worn = Session.equipmentAt(worn_by, slot);
                    for ([_]*Side{ &self.a, &self.b }) |onlooker| {
                        if (onlooker == dresser) continue;
                        try onlooker.session.sendEquipment(self.gpa, worn_by.base.id, slot, worn);
                    }
                }
            }

            for ([_]*Side{ &self.a, &self.b }) |speaker| {
                if (!speaker.session.takeSwing()) continue;
                const swinger = speaker.session.player orelse continue;
                for ([_]*Side{ &self.a, &self.b }) |listener| {
                    if (listener == speaker) continue;
                    try listener.session.sendSwing(self.gpa, swinger.base.id);
                }
            }

            try self.pump(&self.a);
            try self.pump(&self.b);

            for ([_]*Side{ &self.a, &self.b }) |side| {
                try side.connection.tickBodies(self.gpa, &side.level);
            }
        }
    }
};

test "two players on one server are told about each other" {
    const gpa = std.testing.allocator;
    var trio = try Trio.init(gpa);
    defer trio.deinit();
    try trio.start();

    try trio.settle(4);

    try std.testing.expectEqual(@as(usize, 1), trio.a.connection.peers.items.len);
    try std.testing.expectEqual(@as(usize, 1), trio.b.connection.peers.items.len);

    try std.testing.expectEqualStrings("Bob", trio.a.connection.peers.items[0].name.text());
    try std.testing.expectEqualStrings("Alice", trio.b.connection.peers.items[0].name.text());

    try std.testing.expectEqual(trio.b.session.player.?.base.id, trio.a.connection.peers.items[0].id);
    try std.testing.expectEqual(trio.a.session.player.?.base.id, trio.b.connection.peers.items[0].id);
}

test "one player walking is seen moving by the other" {
    const gpa = std.testing.allocator;
    var trio = try Trio.init(gpa);
    defer trio.deinit();
    try trio.start();
    try trio.settle(4);

    const before = trio.a.connection.peers.items[0].player.base.position;

    trio.b.player.base.position = .{ .x = before.x + 6.0, .y = before.y, .z = before.z - 3.0 };
    try trio.b.connection.reportPosition(gpa, &trio.b.player);
    try trio.settle(12);

    const after = trio.a.connection.peers.items[0].player.base.position;
    try std.testing.expectApproxEqAbs(before.x + 6.0, after.x, 0.05);
    try std.testing.expectApproxEqAbs(before.z - 3.0, after.z, 0.05);

    while (trio.b.player.yaw < 90.0) {
        trio.b.player.yaw = @min(trio.b.player.yaw + 15.0, 90.0);
        try trio.b.connection.reportPosition(gpa, &trio.b.player);
        try trio.settle(2);
    }
    try trio.settle(6);
    try std.testing.expectApproxEqAbs(@as(f32, 90.0), trio.a.connection.peers.items[0].player.yaw, 10.0);
}

test "a peer eases across the gap between updates instead of jumping it" {
    const gpa = std.testing.allocator;
    var trio = try Trio.init(gpa);
    defer trio.deinit();
    try trio.start();
    try trio.settle(4);

    const watched = &trio.a.connection.peers.items[0].player;
    const start = watched.base.position;

    trio.b.player.base.position = .{ .x = start.x + 1.0, .y = start.y, .z = start.z };
    try trio.b.connection.reportPosition(gpa, &trio.b.player);
    try trio.settle(2);

    const stepped = watched.base.position.x - start.x;
    try std.testing.expect(stepped > 0.0);
    try std.testing.expect(stepped < 1.0);
    try std.testing.expect(watched.base.prev_position.x != watched.base.position.x);

    try trio.settle(8);
    try std.testing.expectApproxEqAbs(start.x + 1.0, watched.base.position.x, 0.05);
}

test "walking makes a peer's legs swing on the watcher's screen" {
    const gpa = std.testing.allocator;
    var trio = try Trio.init(gpa);
    defer trio.deinit();
    try trio.start();
    try trio.settle(4);

    const watched = &trio.a.connection.peers.items[0].player;
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), watched.limb_swing_amount, 1.0e-6);

    for (0..6) |step| {
        trio.b.player.base.position.x += 0.2;
        _ = step;
        try trio.b.connection.reportPosition(gpa, &trio.b.player);
        try trio.settle(1);
    }

    try std.testing.expect(watched.limb_swing_amount > 0.0);
    try std.testing.expect(watched.limb_swing > 0.0);
}

test "a swing on one screen is a swing on the other" {
    const gpa = std.testing.allocator;
    var trio = try Trio.init(gpa);
    defer trio.deinit();
    try trio.start();
    try trio.settle(4);

    const watched = &trio.a.connection.peers.items[0].player;
    try std.testing.expect(!watched.is_swinging);

    trio.b.player.swingItem();
    try trio.b.connection.reportSwing(gpa);
    try trio.settle(3);

    try std.testing.expect(watched.is_swinging);
    try std.testing.expect(watched.swingProgress(1.0) > 0.0);
}

test "a player who leaves is taken off the other's screen" {
    const gpa = std.testing.allocator;
    var trio = try Trio.init(gpa);
    defer trio.deinit();
    try trio.start();
    try trio.settle(4);

    try std.testing.expectEqual(@as(usize, 1), trio.a.connection.peers.items.len);

    trio.b.session.leave(gpa, &trio.level);
    try trio.settle(2);

    try std.testing.expectEqual(@as(usize, 0), trio.a.connection.peers.items.len);
}

test "a player far away is not tracked at all" {
    const gpa = std.testing.allocator;
    var trio = try Trio.init(gpa);
    defer trio.deinit();
    try trio.start();
    try trio.settle(4);

    trio.b.session.player.?.base.position = .{ .x = 5000, .y = 70, .z = 5000 };
    try trio.settle(2);

    try std.testing.expectEqual(@as(usize, 0), trio.a.connection.peers.items.len);
}

test "the server tells the client what its health is" {
    const gpa = std.testing.allocator;
    var trio = try Trio.init(gpa);
    defer trio.deinit();
    try trio.start();
    try trio.settle(4);

    try std.testing.expectEqual(@as(i32, 20), trio.a.connection.health);

    trio.a.session.player.?.health = 6;
    try trio.settle(2);

    try std.testing.expectEqual(@as(i32, 6), trio.a.connection.health);
}

test "a login carries the username through to the player on the server" {
    const gpa = std.testing.allocator;
    var trio = try Trio.init(gpa);
    defer trio.deinit();
    try trio.start();
    try trio.settle(4);

    try std.testing.expectEqualStrings("Alice", trio.a.session.player.?.name.text());
    try std.testing.expectEqualStrings("Bob", trio.b.session.player.?.name.text());
}

test "what one player says reaches everybody, named" {
    const gpa = std.testing.allocator;
    var trio = try Trio.init(gpa);
    defer trio.deinit();
    try trio.start();
    try trio.settle(4);

    for ([_]*Trio.Side{ &trio.a, &trio.b }) |side| {
        const drained = try side.connection.takeChat(gpa);
        gpa.free(drained);
    }

    try trio.a.connection.say(gpa, "hello world");
    try trio.settle(2);

    for ([_]*Trio.Side{ &trio.a, &trio.b }) |side| {
        const heard = try side.connection.takeChat(gpa);
        defer gpa.free(heard);
        try std.testing.expectEqual(@as(usize, 1), heard.len);
        try std.testing.expectEqualStrings("<Alice> hello world", heard[0].text());
    }
}

test "a slash command is kept off the wire's broadcast" {
    const gpa = std.testing.allocator;
    var trio = try Trio.init(gpa);
    defer trio.deinit();
    try trio.start();
    try trio.settle(4);

    for ([_]*Trio.Side{ &trio.a, &trio.b }) |side| {
        const drained = try side.connection.takeChat(gpa);
        gpa.free(drained);
    }

    try trio.a.connection.say(gpa, "/time set 0");
    try trio.settle(2);

    const heard = try trio.b.connection.takeChat(gpa);
    defer gpa.free(heard);
    try std.testing.expectEqual(@as(usize, 0), heard.len);
}

test "chat that breaks the rules disconnects the talker" {
    const gpa = std.testing.allocator;
    var trio = try Trio.init(gpa);
    defer trio.deinit();
    try trio.start();
    try trio.settle(4);

    try trio.a.connection.say(gpa, "bad\x07bell");
    try trio.settle(2);

    try std.testing.expectEqual(Session.State.closed, trio.a.session.state);
    try std.testing.expect(trio.a.session.kicked);
}

test "joining is announced to whoever is already there" {
    const gpa = std.testing.allocator;
    var trio = try Trio.init(gpa);
    defer trio.deinit();
    try trio.start();
    try trio.settle(4);

    try trio.b.session.announce(gpa, "Carol", true);
    try trio.settle(1);

    const heard = try trio.b.connection.takeChat(gpa);
    defer gpa.free(heard);

    var found = false;
    for (heard) |line| {
        if (std.mem.indexOf(u8, line.text(), "Carol joined the game.") != null) found = true;
    }
    try std.testing.expect(found);
}

test "a dropped item on the server becomes a dropped item on the client" {
    const gpa = std.testing.allocator;
    var pair = try Pair.init(gpa);
    defer pair.deinit();
    try pair.start();
    try pair.settle(6);

    const at = pair.session.player.?.base.position;
    try pair.server_level.dropStackAt(gpa, @intFromFloat(at.x), @intFromFloat(at.y), @intFromFloat(at.z), .{
        .id = .{ .item = .diamond },
        .count = 3,
    });
    try pair.trackWorld(1);

    try std.testing.expectEqual(@as(usize, 1), pair.client_level.entities.items.items.len);
    const seen = pair.client_level.entities.items.items[0];
    try std.testing.expect(seen.stack.id.eql(.{ .item = .diamond }));
    try std.testing.expectEqual(@as(u8, 3), seen.stack.count);
    try std.testing.expectEqual(pair.server_level.entities.items.items[0].base.id, seen.base.id);
}

test "a boat and a minecart arrive as the right kind of vehicle" {
    const gpa = std.testing.allocator;
    var pair = try Pair.init(gpa);
    defer pair.deinit();
    try pair.start();
    try pair.settle(6);

    const at = pair.session.player.?.base.position;
    try pair.server_level.entities.boats.append(gpa, game.Boat.spawn(at.x + 3.0, at.y, at.z));
    try pair.server_level.entities.minecarts.append(gpa, game.Minecart.spawn(at.x, at.y, at.z + 3.0, .furnace));
    try pair.trackWorld(1);

    try std.testing.expectEqual(@as(usize, 1), pair.client_level.entities.boats.items.len);
    try std.testing.expectEqual(@as(usize, 1), pair.client_level.entities.minecarts.items.len);
    try std.testing.expectEqual(game.Minecart.Kind.furnace, pair.client_level.entities.minecarts.items[0].kind);
    try std.testing.expectApproxEqAbs(
        at.x + 3.0,
        pair.client_level.entities.boats.items[0].base.position.x,
        1.0 / 32.0,
    );
}

test "an arrow in flight is mirrored on the client with its owner" {
    const gpa = std.testing.allocator;
    var pair = try Pair.init(gpa);
    defer pair.deinit();
    try pair.start();
    try pair.settle(6);

    const shooter = pair.session.player.?;
    try pair.server_level.entities.shootArrow(gpa, shooter, &pair.server_level.world_map.rand);
    try pair.trackWorld(1);

    try std.testing.expectEqual(@as(usize, 1), pair.client_level.entities.arrows.items.len);
    try std.testing.expectEqual(shooter.base.id, pair.client_level.entities.arrows.items[0].owner);
}

test "a painting on the wall reaches the client with its art intact" {
    const gpa = std.testing.allocator;
    var pair = try Pair.init(gpa);
    defer pair.deinit();
    try pair.start();
    try pair.settle(6);

    const at = pair.session.player.?.base.position;
    const tile: [3]i32 = .{ @intFromFloat(at.x), @as(i32, @intFromFloat(at.y)) + 2, @intFromFloat(at.z) };
    try pair.server_level.entities.spawnPainting(gpa, game.Painting.place(tile, 2, .skull_and_roses));
    try pair.trackWorld(1);

    try std.testing.expectEqual(@as(usize, 1), pair.client_level.entities.paintings.items.len);
    const hung = pair.client_level.entities.paintings.items[0];
    try std.testing.expectEqual(game.Painting.Art.skull_and_roses, hung.art);
    try std.testing.expectEqual(@as(u2, 2), hung.direction);
    try std.testing.expectEqual(tile, hung.tile);
}

test "hurting a mob shows as a hurt flash on the client" {
    const gpa = std.testing.allocator;
    var pair = try Pair.init(gpa);
    defer pair.deinit();
    try pair.start();
    try pair.settle(6);

    const cow = try spawnServerMob(&pair, game.Cow, game.mob.cow);
    try pair.trackWorld(1);

    const seen = pair.client_level.entities.first(game.Cow, game.mob.cow).?;
    try std.testing.expectEqual(@as(i32, 0), seen.animal.hurt_time);

    _ = cow.animal.hurt(3, null, &pair.server_level.world_map.rand);
    try pair.trackWorld(1);

    try std.testing.expect(seen.animal.hurt_time > 0);
}

test "an item a player scoops up is taken off every other screen" {
    const gpa = std.testing.allocator;
    var pair = try Pair.init(gpa);
    defer pair.deinit();
    try pair.start();
    try pair.settle(6);

    const player = pair.session.player.?;
    const at = player.base.position;
    try pair.server_level.entities.items.append(gpa, .{
        .base = game.Entity.init(at, game.ItemEntity.width, game.ItemEntity.height),
        .stack = .{ .id = .{ .block = .stone }, .count = 1 },
        .pickup_delay = 0,
    });
    pair.server_level.entities.stampIds();
    try pair.trackWorld(1);
    try std.testing.expectEqual(@as(usize, 1), pair.client_level.entities.items.items.len);

    try pair.server_level.entities.tickItems(gpa, &pair.server_level.world_map, pair.server_level.roster.items);
    try std.testing.expectEqual(@as(usize, 1), pair.server_level.entities.collected.items.len);

    const taken = pair.server_level.entities.collected.items[0];
    try pair.session.sendCollect(gpa, taken.item, taken.by);
    _ = try pair.pumpToClient();

    try std.testing.expectEqual(@as(usize, 0), pair.client_level.entities.items.items.len);
    try std.testing.expectEqual(@as(usize, 1), pair.client_level.entities.pickups.items.len);
}

test "what a player is holding and wearing shows on the other's screen" {
    const gpa = std.testing.allocator;
    var trio = try Trio.init(gpa);
    defer trio.deinit();
    try trio.start();
    try trio.settle(4);

    const watched = &trio.a.connection.peers.items[0].player;

    trio.b.player.inventory.slots[trio.b.player.inventory.selected] = .{ .id = .{ .item = .sword_diamond }, .count = 1 };
    trio.b.player.inventory.armor[0] = .{ .id = .{ .item = .helmet_iron }, .count = 1 };
    trio.b.session.player.?.inventory = trio.b.player.inventory;
    try trio.settle(2);

    try std.testing.expect(watched.inventory.selectedStack() != null);
    try std.testing.expect(watched.inventory.selectedStack().?.id.eql(.{ .item = .sword_diamond }));
    try std.testing.expect(watched.inventory.armor[0] != null);
    try std.testing.expect(watched.inventory.armor[0].?.id.eql(.{ .item = .helmet_iron }));
}

test "a punch aimed at a mob is carried out by the server, not the puncher" {
    const gpa = std.testing.allocator;
    var pair = try Pair.init(gpa);
    defer pair.deinit();
    try pair.start();
    try pair.settle(6);

    const cow = try spawnServerMob(&pair, game.Cow, game.mob.cow);
    const before = cow.animal.health;

    try pair.connection.reportUse(gpa, cow.animal.base.id, true);
    try pair.pumpToServer();

    try std.testing.expect(cow.animal.health < before);
}

test "sneaking and swapping the held slot reach the server" {
    const gpa = std.testing.allocator;
    var pair = try Pair.init(gpa);
    defer pair.deinit();
    try pair.start();
    try pair.settle(6);

    try pair.connection.reportSneak(gpa, true);
    try pair.connection.reportHeldSlot(gpa, 4);
    try pair.pumpToServer();

    try std.testing.expect(pair.session.player.?.base.sneaking);
    try std.testing.expectEqual(@as(u4, 4), pair.session.player.?.inventory.selected);
}

test "a dead player who asks to respawn is put back on their feet" {
    const gpa = std.testing.allocator;
    var pair = try Pair.init(gpa);
    defer pair.deinit();
    try pair.start();
    try pair.settle(6);

    pair.session.player.?.health = 0;
    try pair.connection.reportRespawn(gpa);
    try pair.pumpToServer();
    _ = try pair.pumpToClient();

    try std.testing.expectEqual(@as(i32, 20), pair.session.player.?.health);
    try std.testing.expectEqual(@as(i32, 20), pair.client_player.health);
}

test "what the server puts in a player's inventory turns up on their screen" {
    const gpa = std.testing.allocator;
    var pair = try Pair.init(gpa);
    defer pair.deinit();
    try pair.start();
    try pair.settle(6);

    const held = pair.session.player.?;
    held.inventory.slots[0] = .{ .id = .{ .item = .diamond }, .count = 4 };
    held.inventory.slots[20] = .{ .id = .{ .block = .stone }, .count = 64 };
    held.inventory.armor[2] = .{ .id = .{ .item = .leggings_gold }, .count = 1 };

    try pair.session.syncWindow(gpa, &pair.server_level);
    _ = try pair.pumpToClient();

    try std.testing.expect(pair.client_player.inventory.slots[0].?.id.eql(.{ .item = .diamond }));
    try std.testing.expectEqual(@as(u8, 4), pair.client_player.inventory.slots[0].?.count);
    try std.testing.expect(pair.client_player.inventory.slots[20].?.id.eql(.{ .block = .stone }));
    try std.testing.expect(pair.client_player.inventory.armor[2].?.id.eql(.{ .item = .leggings_gold }));
}

test "a slot the client clicks is moved by the server and acknowledged" {
    const gpa = std.testing.allocator;
    var pair = try Pair.init(gpa);
    defer pair.deinit();
    try pair.start();
    try pair.settle(6);

    pair.session.player.?.inventory.slots[0] = .{ .id = .{ .block = .planks }, .count = 8 };
    try pair.session.sendWindowContents(gpa, &pair.server_level);
    _ = try pair.pumpToClient();

    try pair.connection.reportWindowClick(gpa, 36, false, false, .{
        .id = .{ .block = .planks },
        .count = 8,
    });
    try pair.pumpToServer();

    try std.testing.expect(pair.session.player.?.inventory.slots[0] == null);
    try std.testing.expectEqual(@as(u8, 8), pair.session.carried.?.count);

    _ = try pair.pumpToClient();
    try std.testing.expect(pair.connection.carried != null);
    try std.testing.expectEqual(@as(u8, 8), pair.connection.carried.?.count);
    try std.testing.expect(pair.client_player.inventory.slots[0] == null);
}

test "a click the server disagrees with is answered with the whole window back" {
    const gpa = std.testing.allocator;
    var pair = try Pair.init(gpa);
    defer pair.deinit();
    try pair.start();
    try pair.settle(6);

    pair.session.player.?.inventory.slots[0] = .{ .id = .{ .block = .planks }, .count = 8 };
    try pair.session.sendWindowContents(gpa, &pair.server_level);
    _ = try pair.pumpToClient();

    try pair.connection.reportWindowClick(gpa, 36, false, false, .{
        .id = .{ .block = .stone },
        .count = 1,
    });
    try pair.pumpToServer();

    var replies: std.ArrayList(net.packet.Packet) = .empty;
    defer freeAllPackets(gpa, &replies);
    try drainToClient(&pair, &replies);

    var accepted: ?bool = null;
    var resent = false;
    for (replies.items) |message| {
        switch (message) {
            .transaction => |body| accepted = body.accepted,
            .window_items => resent = true,
            else => {},
        }
    }
    try std.testing.expectEqual(false, accepted.?);
    try std.testing.expect(resent);
}

test "closing the window spills what the player was carrying back into the world" {
    const gpa = std.testing.allocator;
    var pair = try Pair.init(gpa);
    defer pair.deinit();
    try pair.start();
    try pair.settle(6);

    pair.session.carried = .{ .id = .{ .item = .diamond }, .count = 2 };
    pair.session.crafting[0] = .{ .id = .{ .block = .planks }, .count = 1 };

    const before = pair.server_level.entities.items.items.len;
    try pair.connection.reportCloseWindow(gpa);
    try pair.pumpToServer();

    try std.testing.expect(pair.session.carried == null);
    try std.testing.expect(pair.session.crafting[0] == null);
    try std.testing.expectEqual(before + 2, pair.server_level.entities.items.items.len);
}

fn freeAllPackets(gpa: std.mem.Allocator, list: *std.ArrayList(net.packet.Packet)) void {
    for (list.items) |message| message.deinit(gpa);
    list.deinit(gpa);
}

fn drainToClient(pair: *Pair, out: *std.ArrayList(net.packet.Packet)) !void {
    const bytes = try pair.session.takeOutbox(pair.gpa);
    defer pair.gpa.free(bytes);

    var reader = std.Io.Reader.fixed(bytes);
    while (reader.bufferedLen() > 0) {
        const id = try net.packet.readId(&reader);
        try out.append(pair.gpa, try net.packet.readBody(pair.gpa, &reader, id));
    }
}

test "a lever the client right-clicks is thrown by the server" {
    const gpa = std.testing.allocator;
    var pair = try Pair.init(gpa);
    defer pair.deinit();
    try pair.start();
    try pair.settle(6);

    const ground = pair.standOnGround();
    const x, const y, const z = .{ ground[0], ground[1], ground[2] };
    try pair.server_level.world_map.setBlockAndMetadataWithNotify(x, y + 1, z, .lever, 5);
    try pair.settle(2);

    const before = pair.server_level.world_map.getBlockMetadata(x, y + 1, z);
    try pair.connection.reportPlace(gpa, x, y + 1, z, 1, null);
    try pair.settle(2);

    const after = pair.server_level.world_map.getBlockMetadata(x, y + 1, z);
    try std.testing.expect(before != after);
    try std.testing.expectEqual(after, pair.client_level.world_map.getBlockMetadata(x, y + 1, z));
}

test "the block a client asks for is only placed if the server agrees it is held" {
    const gpa = std.testing.allocator;
    var pair = try Pair.init(gpa);
    defer pair.deinit();
    try pair.start();
    try pair.settle(6);

    const ground = pair.standOnGround();
    const x, const y, const z = .{ ground[0], ground[1], ground[2] };
    try pair.server_level.world_map.setBlockWithNotify(x, y + 1, z, .air);
    try pair.settle(2);

    try pair.connection.reportPlace(gpa, x, y, z, 1, .{
        .id = @intFromEnum(world.Block.block_diamond),
        .count = 64,
        .damage = 0,
    });
    try pair.settle(2);

    try std.testing.expectEqual(world.Block.air, pair.server_level.world_map.getBlock(x, y + 1, z));
}

test "one player punching another takes health off on the server" {
    const gpa = std.testing.allocator;
    var trio = try Trio.init(gpa);
    defer trio.deinit();
    try trio.start();
    try trio.settle(4);

    const puncher = trio.a.session.player.?;
    const struck = trio.b.session.player.?;
    struck.base.position = puncher.base.position;

    const before = struck.health;
    try trio.a.connection.reportUse(gpa, struck.base.id, true);
    try trio.settle(2);

    try std.testing.expect(struck.health < before);
}

test "a sign one player writes is readable by the other" {
    const gpa = std.testing.allocator;
    var pair = try Pair.init(gpa);
    defer pair.deinit();
    try pair.start();
    try pair.settle(6);

    const ground = pair.standOnGround();
    const x, const y, const z = .{ ground[0], ground[1], ground[2] };
    try pair.server_level.world_map.setBlockAndMetadataWithNotify(x, y + 1, z, .sign_post, 0);
    try pair.settle(2);

    var post: world.sign.Sign = .{};
    post.setLine(0, "hello");
    post.setLine(2, "rosebed");
    try pair.connection.reportSign(gpa, x, y + 1, z, &post);
    try pair.pumpToServer();

    const stored = pair.server_level.world_map.signAt(x, y + 1, z).?;
    try std.testing.expectEqualStrings("hello", stored.line(0));
    try std.testing.expectEqualStrings("rosebed", stored.line(2));
    try std.testing.expect(pair.session.takeSign() != null);

    try pair.session.sendSign(gpa, x, y + 1, z, stored);
    _ = try pair.pumpToClient();

    const mirrored = pair.client_level.world_map.signAt(x, y + 1, z).?;
    try std.testing.expectEqualStrings("hello", mirrored.line(0));
    try std.testing.expectEqualStrings("rosebed", mirrored.line(2));
}

test "a chest the client opens is filled in from the server's copy" {
    const gpa = std.testing.allocator;
    var pair = try Pair.init(gpa);
    defer pair.deinit();
    try pair.start();
    try pair.settle(6);

    const ground = pair.standOnGround();
    const x, const y, const z = .{ ground[0], ground[1], ground[2] };
    try pair.server_level.world_map.setBlockWithNotify(x, y + 1, z, .chest);
    try pair.settle(2);

    (try pair.server_level.world_map.addChest(x, y + 1, z)).items[3] =
        .{ .id = .{ .item = .diamond }, .count = 5 };

    try pair.connection.reportPlace(gpa, x, y + 1, z, 1, null);
    try pair.settle(2);

    try std.testing.expect(pair.connection.opened != null);
    try std.testing.expectEqual(remote.Connection.window_chest, pair.connection.opened.?.kind);
    try std.testing.expectEqual(@as(usize, world.chest.slot_count), pair.connection.opened.?.store);

    const mirrored = pair.client_level.world_map.chestAt(x, y + 1, z).?;
    try std.testing.expect(mirrored.items[3].?.id.eql(.{ .item = .diamond }));
    try std.testing.expectEqual(@as(u8, 5), mirrored.items[3].?.count);
}

test "taking from an open chest moves the stack on the server" {
    const gpa = std.testing.allocator;
    var pair = try Pair.init(gpa);
    defer pair.deinit();
    try pair.start();
    try pair.settle(6);

    const ground = pair.standOnGround();
    const x, const y, const z = .{ ground[0], ground[1], ground[2] };
    try pair.server_level.world_map.setBlockWithNotify(x, y + 1, z, .chest);
    try pair.settle(2);

    (try pair.server_level.world_map.addChest(x, y + 1, z)).items[0] =
        .{ .id = .{ .block = .stone }, .count = 12 };

    try pair.connection.reportPlace(gpa, x, y + 1, z, 1, null);
    try pair.settle(2);

    // Shift-click slot 0 straight into the player's inventory.
    try pair.connection.reportWindowClick(gpa, 0, false, true, null);
    try pair.pumpToServer();

    try std.testing.expect(pair.server_level.world_map.chestAt(x, y + 1, z).?.items[0] == null);
    var carried_total: u16 = 0;
    for (pair.session.player.?.inventory.slots) |slot| {
        const stack = slot orelse continue;
        if (stack.id.eql(.{ .block = .stone })) carried_total += stack.count;
    }
    try std.testing.expectEqual(@as(u16, 12), carried_total);
}

test "a furnace window carries its burn and cook progress across" {
    const gpa = std.testing.allocator;
    var pair = try Pair.init(gpa);
    defer pair.deinit();
    try pair.start();
    try pair.settle(6);

    const ground = pair.standOnGround();
    const x, const y, const z = .{ ground[0], ground[1], ground[2] };
    try pair.server_level.world_map.setBlockWithNotify(x, y + 1, z, .furnace);
    try pair.settle(2);

    try pair.connection.reportPlace(gpa, x, y + 1, z, 1, null);
    try pair.settle(2);

    try std.testing.expectEqual(remote.Connection.window_furnace, pair.connection.opened.?.kind);

    const fire = pair.server_level.world_map.furnaceAt(x, y + 1, z).?;
    fire.input = .{ .id = .{ .block = .ore_iron }, .count = 1 };
    fire.cook_time = 77;
    fire.burn_time = 300;
    fire.item_burn_time = 1600;

    try pair.session.syncWindow(gpa, &pair.server_level);
    _ = try pair.pumpToClient();

    const seen = pair.client_level.world_map.furnaceAt(x, y + 1, z).?;
    try std.testing.expect(seen.input.?.id.eql(.{ .block = .ore_iron }));
    try std.testing.expectEqual(@as(i16, 77), seen.cook_time);
    try std.testing.expectEqual(@as(i16, 300), seen.burn_time);
    try std.testing.expectEqual(@as(i16, 1600), seen.item_burn_time);
}

test "a workbench window crafts on the server and hands back the result" {
    const gpa = std.testing.allocator;
    var pair = try Pair.init(gpa);
    defer pair.deinit();
    try pair.start();
    try pair.settle(6);

    const ground = pair.standOnGround();
    const x, const y, const z = .{ ground[0], ground[1], ground[2] };
    try pair.server_level.world_map.setBlockWithNotify(x, y + 1, z, .workbench);
    try pair.settle(2);

    try pair.connection.reportPlace(gpa, x, y + 1, z, 1, null);
    try pair.settle(2);
    try std.testing.expectEqual(remote.Connection.window_workbench, pair.connection.opened.?.kind);

    for (0..3) |slot| pair.session.workbench[slot] = .{ .id = .{ .block = .planks }, .count = 1 };
    pair.session.workbench[4] = .{ .id = .{ .item = .stick }, .count = 1 };
    pair.session.workbench[7] = .{ .id = .{ .item = .stick }, .count = 1 };

    try pair.connection.reportWindowClick(gpa, 0, false, false, null);
    try pair.pumpToServer();

    try std.testing.expect(pair.session.carried != null);
    try std.testing.expect(pair.session.carried.?.id.eql(.{ .item = .pickaxe_wood }));
    try std.testing.expect(pair.session.workbench[0] == null);
}

test "closing a workbench spills its grid back into the world" {
    const gpa = std.testing.allocator;
    var pair = try Pair.init(gpa);
    defer pair.deinit();
    try pair.start();
    try pair.settle(6);

    const ground = pair.standOnGround();
    const x, const y, const z = .{ ground[0], ground[1], ground[2] };
    try pair.server_level.world_map.setBlockWithNotify(x, y + 1, z, .workbench);
    try pair.settle(2);
    try pair.connection.reportPlace(gpa, x, y + 1, z, 1, null);
    try pair.settle(2);

    pair.session.workbench[4] = .{ .id = .{ .block = .planks }, .count = 3 };
    const before = pair.server_level.entities.items.items.len;

    try pair.connection.reportCloseWindow(gpa);
    try pair.pumpToServer();

    try std.testing.expect(pair.session.workbench[4] == null);
    try std.testing.expectEqual(before + 1, pair.server_level.entities.items.items.len);
    try std.testing.expectEqual(Session.Open.player, std.meta.activeTag(pair.session.open));
    try std.testing.expect(pair.connection.opened == null);
}

test "shearing a sheep is done by the server when a client asks" {
    const gpa = std.testing.allocator;
    var pair = try Pair.init(gpa);
    defer pair.deinit();
    try pair.start();
    try pair.settle(6);

    const sheep = try spawnServerMob(&pair, game.Sheep, game.mob.sheep);
    sheep.animal.base.position = pair.session.player.?.base.position;

    const holder = pair.session.player.?;
    holder.inventory.slots[holder.inventory.selected] = .{ .id = .{ .item = .shears }, .count = 1 };

    try pair.connection.reportUse(gpa, sheep.animal.base.id, false);
    try pair.pumpToServer();

    try std.testing.expect(sheep.sheared);
    try std.testing.expect(pair.server_level.entities.items.items.len > 0);
}

test "a player who walks through a portal is handed over to the other world" {
    const gpa = std.testing.allocator;
    var pair = try Pair.init(gpa);
    defer pair.deinit();
    try pair.start();
    try pair.settle(6);

    var nether = game.Level.init(gpa, try world.Generator.init(gpa, .nether, 4242));
    defer nether.deinit(gpa);
    nether.attach();
    nether.spawn = pair.server_level.spawn;

    const player = pair.session.player.?;
    player.base.position = .{ .x = 64.0, .y = 70.0, .z = -32.0 };

    try pair.session.travel(gpa, &pair.server_level, &nether, .nether, 8.0, 70.0, -4.0);
    _ = try pair.pumpToClient();

    try std.testing.expectEqual(world.Dimension.nether, pair.session.dimension);
    try std.testing.expectEqual(@as(usize, 1), nether.roster.items.len);
    try std.testing.expectEqual(@as(usize, 0), pair.server_level.roster.items.len);
    try std.testing.expectEqual(world.Dimension.nether, pair.connection.dimension);

    // The client is asked to tear the old world down before it draws the new one.
    try std.testing.expectEqual(world.Dimension.nether, pair.connection.takeDimensionChange().?);
    try std.testing.expect(pair.connection.takeDimensionChange() == null);

    // The server carves a way back in and stands the player in it.
    const landed = nether.roster.items[0].base.position;
    try std.testing.expect(@abs(landed.x - 8.0) < 32.0);
    try std.testing.expect(@abs(landed.z - -4.0) < 32.0);
}

test "travelling forgets every entity and chunk the old world had sent" {
    const gpa = std.testing.allocator;
    var pair = try Pair.init(gpa);
    defer pair.deinit();
    try pair.start();
    try pair.settle(8);

    const cow = try spawnServerMob(&pair, game.Cow, game.mob.cow);
    _ = cow;
    try pair.trackWorld(1);
    try std.testing.expect(pair.client_level.entities.mobs.items.len > 0);
    try std.testing.expect(pair.session.sent_chunks.count() > 0);

    var nether = game.Level.init(gpa, try world.Generator.init(gpa, .nether, 4242));
    defer nether.deinit(gpa);
    nether.attach();

    try pair.session.travel(gpa, &pair.server_level, &nether, .nether, 8.0, 70.0, 8.0);
    _ = try pair.pumpToClient();

    try std.testing.expectEqual(@as(u32, 0), pair.session.sent_chunks.count());
    try std.testing.expectEqual(@as(u32, 0), pair.session.tracked.count());
    try std.testing.expectEqual(@as(usize, 0), pair.client_level.entities.mobs.items.len);
}

test "what the server counts for a player lands in their own tally" {
    const gpa = std.testing.allocator;
    var pair = try Pair.init(gpa);
    defer pair.deinit();
    try pair.start();
    try pair.settle(6);

    try pair.session.award(gpa, .{ .general = .damage_dealt }, 7);
    try pair.session.award(gpa, .{ .mined = .{ .block = .stone } }, 3);
    _ = try pair.pumpToClient();

    const awards = try pair.connection.takeAwards(gpa);
    defer gpa.free(awards);
    try std.testing.expectEqual(@as(usize, 2), awards.len);

    var dealt: i32 = 0;
    var mined: i32 = 0;
    for (awards) |given| {
        switch (given.stat) {
            .general => |which| if (which == .damage_dealt) {
                dealt += given.amount;
            },
            .mined => |id| if (id.eql(.{ .block = .stone })) {
                mined += given.amount;
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(i32, 7), dealt);
    try std.testing.expectEqual(@as(i32, 3), mined);
}

test "a tally bigger than one packet can carry is sent in pieces" {
    const gpa = std.testing.allocator;
    var pair = try Pair.init(gpa);
    defer pair.deinit();
    try pair.start();
    try pair.settle(6);

    try pair.session.award(gpa, .{ .general = .damage_taken }, 300);
    _ = try pair.pumpToClient();

    const awards = try pair.connection.takeAwards(gpa);
    defer gpa.free(awards);
    try std.testing.expect(awards.len > 1);

    var total: i32 = 0;
    for (awards) |given| total += given.amount;
    try std.testing.expectEqual(@as(i32, 300), total);
}

test "digging a block the server counts as mined shows in the tally" {
    const gpa = std.testing.allocator;
    var pair = try Pair.init(gpa);
    defer pair.deinit();
    try pair.start();
    try pair.settle(6);

    const ground = pair.standOnGround();
    const x, const y, const z = .{ ground[0], ground[1], ground[2] };
    const broken = pair.server_level.world_map.getBlock(x, y, z);

    try pair.connection.reportDig(gpa, x, y, z, 1);
    try pair.settle(2);

    const awards = try pair.connection.takeAwards(gpa);
    defer gpa.free(awards);

    var seen = false;
    for (awards) |given| {
        if (given.stat == .mined and given.stat.mined.eql(.{ .block = broken })) seen = true;
    }
    try std.testing.expect(seen);
}
