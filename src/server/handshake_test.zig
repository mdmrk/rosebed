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
            .server_level = game.Level.init(gpa, try world.TerrainGenerator.init(gpa, 4242)),
            .client_level = game.Level.init(gpa, try world.TerrainGenerator.init(gpa, 0)),
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
    try std.testing.expectEqual(pair.server_level.generator.world_seed, pair.connection.map_seed);
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

    try pair.connection.reportPlace(gpa, x, y, z, 1, .{
        .id = @intFromEnum(world.Block.planks),
        .count = 1,
        .damage = 0,
    });
    try pair.settle(2);

    try std.testing.expectEqual(world.Block.planks, pair.server_level.world_map.getBlock(x, y + 1, z));
    try std.testing.expectEqual(world.Block.planks, pair.client_level.world_map.getBlock(x, y + 1, z));
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
