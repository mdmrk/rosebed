const std = @import("std");

pub const protocol_version: i32 = 14;

pub const Id = enum(u8) {
    keep_alive = 0,
    login = 1,
    handshake = 2,
    chat = 3,
    update_time = 4,
    spawn_position = 6,
    update_health = 8,
    respawn = 9,
    flying = 10,
    player_position = 11,
    player_look = 12,
    player_look_move = 13,
    block_dig = 14,
    place = 15,
    block_item_switch = 16,
    animation = 18,
    named_entity_spawn = 20,
    destroy_entity = 29,
    entity = 30,
    rel_entity_move = 31,
    entity_look = 32,
    rel_entity_move_look = 33,
    entity_teleport = 34,
    pre_chunk = 50,
    map_chunk = 51,
    multi_block_change = 52,
    block_change = 53,
    kick_disconnect = 255,
};

pub const Direction = struct {
    to_client: bool,
    to_server: bool,
};

pub fn direction(id: Id) Direction {
    return switch (id) {
        .keep_alive => .{ .to_client = true, .to_server = true },
        .login => .{ .to_client = true, .to_server = true },
        .handshake => .{ .to_client = true, .to_server = true },
        .chat => .{ .to_client = true, .to_server = true },
        .update_time => .{ .to_client = true, .to_server = false },
        .spawn_position => .{ .to_client = true, .to_server = false },
        .update_health => .{ .to_client = true, .to_server = false },
        .respawn => .{ .to_client = true, .to_server = true },
        .flying => .{ .to_client = true, .to_server = true },
        .player_position => .{ .to_client = true, .to_server = true },
        .player_look => .{ .to_client = true, .to_server = true },
        .player_look_move => .{ .to_client = true, .to_server = true },
        .block_dig => .{ .to_client = false, .to_server = true },
        .place => .{ .to_client = false, .to_server = true },
        .block_item_switch => .{ .to_client = false, .to_server = true },
        .animation => .{ .to_client = true, .to_server = true },
        .named_entity_spawn => .{ .to_client = true, .to_server = false },
        .destroy_entity => .{ .to_client = true, .to_server = false },
        .entity => .{ .to_client = true, .to_server = false },
        .rel_entity_move => .{ .to_client = true, .to_server = false },
        .entity_look => .{ .to_client = true, .to_server = false },
        .rel_entity_move_look => .{ .to_client = true, .to_server = false },
        .entity_teleport => .{ .to_client = true, .to_server = false },
        .pre_chunk => .{ .to_client = true, .to_server = false },
        .map_chunk => .{ .to_client = true, .to_server = false },
        .multi_block_change => .{ .to_client = true, .to_server = false },
        .block_change => .{ .to_client = true, .to_server = false },
        .kick_disconnect => .{ .to_client = true, .to_server = true },
    };
}

pub const max_username = 16;
pub const max_handshake_name = 32;
pub const max_chat = 119;
pub const max_kick_reason = 100;

pub const Stack = struct {
    id: i16,
    count: i8,
    damage: i16,
};

pub const Packet = union(Id) {
    keep_alive,
    login: struct {
        protocol_version: i32,
        username: []const u8,
        map_seed: i64,
        dimension: i8,
    },
    handshake: struct { username: []const u8 },
    chat: struct { message: []const u8 },
    update_time: struct { time: i64 },
    spawn_position: struct { x: i32, y: i32, z: i32 },
    update_health: struct { health: i16 },
    respawn: struct { dimension: i8 },
    flying: struct { on_ground: bool },
    player_position: struct {
        x: f64,
        y: f64,
        stance: f64,
        z: f64,
        on_ground: bool,
    },
    player_look: struct { yaw: f32, pitch: f32, on_ground: bool },
    player_look_move: struct {
        x: f64,
        y: f64,
        stance: f64,
        z: f64,
        yaw: f32,
        pitch: f32,
        on_ground: bool,
    },
    block_dig: struct { status: u8, x: i32, y: u8, z: i32, face: u8 },
    place: struct { x: i32, y: u8, z: i32, face: u8, held: ?Stack },
    block_item_switch: struct { slot: i16 },
    animation: struct { entity_id: i32, animate: i8 },
    named_entity_spawn: struct {
        entity_id: i32,
        name: []const u8,
        x: i32,
        y: i32,
        z: i32,
        rotation: i8,
        pitch: i8,
        current_item: i16,
    },
    destroy_entity: struct { entity_id: i32 },
    entity: struct { entity_id: i32 },
    rel_entity_move: struct { entity_id: i32, dx: i8, dy: i8, dz: i8 },
    entity_look: struct { entity_id: i32, yaw: i8, pitch: i8 },
    rel_entity_move_look: struct {
        entity_id: i32,
        dx: i8,
        dy: i8,
        dz: i8,
        yaw: i8,
        pitch: i8,
    },
    entity_teleport: struct {
        entity_id: i32,
        x: i32,
        y: i32,
        z: i32,
        yaw: i8,
        pitch: i8,
    },
    pre_chunk: struct { x: i32, z: i32, load: bool },
    map_chunk: struct {
        x: i32,
        y: i16,
        z: i32,
        size_x: u8,
        size_y: u8,
        size_z: u8,
        compressed: []const u8,
    },
    multi_block_change: struct {
        chunk_x: i32,
        chunk_z: i32,
        coordinates: []const i16,
        types: []const u8,
        metadata: []const u8,
    },
    block_change: struct { x: i32, y: u8, z: i32, block: u8, metadata: u8 },
    kick_disconnect: struct { reason: []const u8 },

    pub fn id(self: Packet) Id {
        return std.meta.activeTag(self);
    }

    pub fn deinit(self: Packet, gpa: std.mem.Allocator) void {
        switch (self) {
            .login => |body| gpa.free(body.username),
            .handshake => |body| gpa.free(body.username),
            .chat => |body| gpa.free(body.message),
            .named_entity_spawn => |body| gpa.free(body.name),
            .kick_disconnect => |body| gpa.free(body.reason),
            .map_chunk => |body| gpa.free(body.compressed),
            .multi_block_change => |body| {
                gpa.free(body.coordinates);
                gpa.free(body.types);
                gpa.free(body.metadata);
            },
            else => {},
        }
    }
};

pub const ReadError = error{
    UnknownPacketId,
    WrongDirection,
    StringTooLong,
    NegativeLength,
    InvalidUtf16,
} || std.mem.Allocator.Error || std.Io.Reader.Error || error{EndOfStream};

pub const WriteError = error{ StringTooLong, InvalidUtf8 } ||
    std.mem.Allocator.Error || std.Io.Writer.Error;

fn readString(gpa: std.mem.Allocator, r: *std.Io.Reader, limit: u16) ![]u8 {
    const length = try r.takeInt(i16, .big);
    if (length < 0) return error.NegativeLength;
    if (length > limit) return error.StringTooLong;

    const units = try gpa.alloc(u16, @intCast(length));
    defer gpa.free(units);
    for (units) |*unit| unit.* = try r.takeInt(u16, .big);

    return std.unicode.utf16LeToUtf8Alloc(gpa, units) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidUtf16,
    };
}

const longest_string = @max(@max(max_username, max_handshake_name), @max(max_chat, max_kick_reason));

fn writeString(w: *std.Io.Writer, text: []const u8, limit: u16) !void {
    const length = std.unicode.calcUtf16LeLen(text) catch return error.InvalidUtf8;
    if (length > limit) return error.StringTooLong;

    var buffer: [longest_string]u16 = undefined;
    const written = std.unicode.utf8ToUtf16Le(buffer[0..length], text) catch return error.InvalidUtf8;

    try w.writeInt(i16, @intCast(written), .big);
    for (buffer[0..written]) |unit| try w.writeInt(u16, unit, .big);
}

fn readStack(r: *std.Io.Reader) !?Stack {
    const item_id = try r.takeInt(i16, .big);
    if (item_id < 0) return null;
    return .{
        .id = item_id,
        .count = try r.takeInt(i8, .big),
        .damage = try r.takeInt(i16, .big),
    };
}

fn writeStack(w: *std.Io.Writer, held: ?Stack) !void {
    const stack = held orelse return w.writeInt(i16, -1, .big);
    try w.writeInt(i16, stack.id, .big);
    try w.writeInt(i8, stack.count, .big);
    try w.writeInt(i16, stack.damage, .big);
}

fn takeBytes(gpa: std.mem.Allocator, r: *std.Io.Reader, length: usize) ![]u8 {
    const buffer = try gpa.alloc(u8, length);
    errdefer gpa.free(buffer);
    try r.readSliceAll(buffer);
    return buffer;
}

pub fn readId(r: *std.Io.Reader) !Id {
    const raw = try r.takeInt(u8, .big);
    inline for (@typeInfo(Id).@"enum".fields) |field| {
        if (raw == field.value) return @enumFromInt(raw);
    }
    return error.UnknownPacketId;
}

pub fn read(gpa: std.mem.Allocator, r: *std.Io.Reader, from_client: bool) ReadError!Packet {
    const packet_id = try readId(r);
    const allowed = direction(packet_id);
    if (from_client and !allowed.to_server) return error.WrongDirection;
    if (!from_client and !allowed.to_client) return error.WrongDirection;
    return readBody(gpa, r, packet_id);
}

pub fn readBody(gpa: std.mem.Allocator, r: *std.Io.Reader, packet_id: Id) ReadError!Packet {
    switch (packet_id) {
        .keep_alive => return .keep_alive,
        .login => {
            const version = try r.takeInt(i32, .big);
            const username = try readString(gpa, r, max_username);
            errdefer gpa.free(username);
            return .{ .login = .{
                .protocol_version = version,
                .username = username,
                .map_seed = try r.takeInt(i64, .big),
                .dimension = try r.takeInt(i8, .big),
            } };
        },
        .handshake => return .{ .handshake = .{ .username = try readString(gpa, r, max_handshake_name) } },
        .chat => return .{ .chat = .{ .message = try readString(gpa, r, max_chat) } },
        .update_time => return .{ .update_time = .{ .time = try r.takeInt(i64, .big) } },
        .spawn_position => return .{ .spawn_position = .{
            .x = try r.takeInt(i32, .big),
            .y = try r.takeInt(i32, .big),
            .z = try r.takeInt(i32, .big),
        } },
        .update_health => return .{ .update_health = .{ .health = try r.takeInt(i16, .big) } },
        .respawn => return .{ .respawn = .{ .dimension = try r.takeInt(i8, .big) } },
        .flying => return .{ .flying = .{ .on_ground = try r.takeInt(u8, .big) != 0 } },
        .player_position => return .{ .player_position = .{
            .x = @bitCast(try r.takeInt(u64, .big)),
            .y = @bitCast(try r.takeInt(u64, .big)),
            .stance = @bitCast(try r.takeInt(u64, .big)),
            .z = @bitCast(try r.takeInt(u64, .big)),
            .on_ground = try r.takeInt(u8, .big) != 0,
        } },
        .player_look => return .{ .player_look = .{
            .yaw = @bitCast(try r.takeInt(u32, .big)),
            .pitch = @bitCast(try r.takeInt(u32, .big)),
            .on_ground = try r.takeInt(u8, .big) != 0,
        } },
        .player_look_move => return .{ .player_look_move = .{
            .x = @bitCast(try r.takeInt(u64, .big)),
            .y = @bitCast(try r.takeInt(u64, .big)),
            .stance = @bitCast(try r.takeInt(u64, .big)),
            .z = @bitCast(try r.takeInt(u64, .big)),
            .yaw = @bitCast(try r.takeInt(u32, .big)),
            .pitch = @bitCast(try r.takeInt(u32, .big)),
            .on_ground = try r.takeInt(u8, .big) != 0,
        } },
        .block_dig => return .{ .block_dig = .{
            .status = try r.takeInt(u8, .big),
            .x = try r.takeInt(i32, .big),
            .y = try r.takeInt(u8, .big),
            .z = try r.takeInt(i32, .big),
            .face = try r.takeInt(u8, .big),
        } },
        .place => return .{ .place = .{
            .x = try r.takeInt(i32, .big),
            .y = try r.takeInt(u8, .big),
            .z = try r.takeInt(i32, .big),
            .face = try r.takeInt(u8, .big),
            .held = try readStack(r),
        } },
        .block_item_switch => return .{ .block_item_switch = .{ .slot = try r.takeInt(i16, .big) } },
        .animation => return .{ .animation = .{
            .entity_id = try r.takeInt(i32, .big),
            .animate = try r.takeInt(i8, .big),
        } },
        .named_entity_spawn => {
            const entity_id = try r.takeInt(i32, .big);
            const name = try readString(gpa, r, max_username);
            errdefer gpa.free(name);
            return .{ .named_entity_spawn = .{
                .entity_id = entity_id,
                .name = name,
                .x = try r.takeInt(i32, .big),
                .y = try r.takeInt(i32, .big),
                .z = try r.takeInt(i32, .big),
                .rotation = try r.takeInt(i8, .big),
                .pitch = try r.takeInt(i8, .big),
                .current_item = try r.takeInt(i16, .big),
            } };
        },
        .destroy_entity => return .{ .destroy_entity = .{ .entity_id = try r.takeInt(i32, .big) } },
        .entity => return .{ .entity = .{ .entity_id = try r.takeInt(i32, .big) } },
        .rel_entity_move => return .{ .rel_entity_move = .{
            .entity_id = try r.takeInt(i32, .big),
            .dx = try r.takeInt(i8, .big),
            .dy = try r.takeInt(i8, .big),
            .dz = try r.takeInt(i8, .big),
        } },
        .entity_look => return .{ .entity_look = .{
            .entity_id = try r.takeInt(i32, .big),
            .yaw = try r.takeInt(i8, .big),
            .pitch = try r.takeInt(i8, .big),
        } },
        .rel_entity_move_look => return .{ .rel_entity_move_look = .{
            .entity_id = try r.takeInt(i32, .big),
            .dx = try r.takeInt(i8, .big),
            .dy = try r.takeInt(i8, .big),
            .dz = try r.takeInt(i8, .big),
            .yaw = try r.takeInt(i8, .big),
            .pitch = try r.takeInt(i8, .big),
        } },
        .entity_teleport => return .{ .entity_teleport = .{
            .entity_id = try r.takeInt(i32, .big),
            .x = try r.takeInt(i32, .big),
            .y = try r.takeInt(i32, .big),
            .z = try r.takeInt(i32, .big),
            .yaw = try r.takeInt(i8, .big),
            .pitch = try r.takeInt(i8, .big),
        } },
        .pre_chunk => return .{ .pre_chunk = .{
            .x = try r.takeInt(i32, .big),
            .z = try r.takeInt(i32, .big),
            .load = try r.takeInt(u8, .big) != 0,
        } },
        .map_chunk => {
            const x = try r.takeInt(i32, .big);
            const y = try r.takeInt(i16, .big);
            const z = try r.takeInt(i32, .big);
            const size_x = @as(u16, try r.takeInt(u8, .big)) + 1;
            const size_y = @as(u16, try r.takeInt(u8, .big)) + 1;
            const size_z = @as(u16, try r.takeInt(u8, .big)) + 1;
            const length = try r.takeInt(i32, .big);
            if (length < 0) return error.NegativeLength;
            return .{ .map_chunk = .{
                .x = x,
                .y = y,
                .z = z,
                .size_x = @intCast(size_x),
                .size_y = @intCast(size_y),
                .size_z = @intCast(size_z),
                .compressed = try takeBytes(gpa, r, @intCast(length)),
            } };
        },
        .multi_block_change => {
            const chunk_x = try r.takeInt(i32, .big);
            const chunk_z = try r.takeInt(i32, .big);
            const count: u16 = @bitCast(try r.takeInt(i16, .big));

            const coordinates = try gpa.alloc(i16, count);
            errdefer gpa.free(coordinates);
            for (coordinates) |*coordinate| coordinate.* = try r.takeInt(i16, .big);

            const types = try takeBytes(gpa, r, count);
            errdefer gpa.free(types);
            const metadata = try takeBytes(gpa, r, count);

            return .{ .multi_block_change = .{
                .chunk_x = chunk_x,
                .chunk_z = chunk_z,
                .coordinates = coordinates,
                .types = types,
                .metadata = metadata,
            } };
        },
        .block_change => return .{ .block_change = .{
            .x = try r.takeInt(i32, .big),
            .y = try r.takeInt(u8, .big),
            .z = try r.takeInt(i32, .big),
            .block = try r.takeInt(u8, .big),
            .metadata = try r.takeInt(u8, .big),
        } },
        .kick_disconnect => return .{ .kick_disconnect = .{ .reason = try readString(gpa, r, max_kick_reason) } },
    }
}

pub fn write(w: *std.Io.Writer, packet: Packet) WriteError!void {
    try w.writeInt(u8, @intFromEnum(packet.id()), .big);
    switch (packet) {
        .keep_alive => {},
        .login => |body| {
            try w.writeInt(i32, body.protocol_version, .big);
            try writeString(w, body.username, max_username);
            try w.writeInt(i64, body.map_seed, .big);
            try w.writeInt(i8, body.dimension, .big);
        },
        .handshake => |body| try writeString(w, body.username, max_handshake_name),
        .chat => |body| try writeString(w, body.message, max_chat),
        .update_time => |body| try w.writeInt(i64, body.time, .big),
        .spawn_position => |body| {
            try w.writeInt(i32, body.x, .big);
            try w.writeInt(i32, body.y, .big);
            try w.writeInt(i32, body.z, .big);
        },
        .update_health => |body| try w.writeInt(i16, body.health, .big),
        .respawn => |body| try w.writeInt(i8, body.dimension, .big),
        .flying => |body| try w.writeInt(u8, @intFromBool(body.on_ground), .big),
        .player_position => |body| {
            try w.writeInt(u64, @bitCast(body.x), .big);
            try w.writeInt(u64, @bitCast(body.y), .big);
            try w.writeInt(u64, @bitCast(body.stance), .big);
            try w.writeInt(u64, @bitCast(body.z), .big);
            try w.writeInt(u8, @intFromBool(body.on_ground), .big);
        },
        .player_look => |body| {
            try w.writeInt(u32, @bitCast(body.yaw), .big);
            try w.writeInt(u32, @bitCast(body.pitch), .big);
            try w.writeInt(u8, @intFromBool(body.on_ground), .big);
        },
        .player_look_move => |body| {
            try w.writeInt(u64, @bitCast(body.x), .big);
            try w.writeInt(u64, @bitCast(body.y), .big);
            try w.writeInt(u64, @bitCast(body.stance), .big);
            try w.writeInt(u64, @bitCast(body.z), .big);
            try w.writeInt(u32, @bitCast(body.yaw), .big);
            try w.writeInt(u32, @bitCast(body.pitch), .big);
            try w.writeInt(u8, @intFromBool(body.on_ground), .big);
        },
        .block_dig => |body| {
            try w.writeInt(u8, body.status, .big);
            try w.writeInt(i32, body.x, .big);
            try w.writeInt(u8, body.y, .big);
            try w.writeInt(i32, body.z, .big);
            try w.writeInt(u8, body.face, .big);
        },
        .place => |body| {
            try w.writeInt(i32, body.x, .big);
            try w.writeInt(u8, body.y, .big);
            try w.writeInt(i32, body.z, .big);
            try w.writeInt(u8, body.face, .big);
            try writeStack(w, body.held);
        },
        .block_item_switch => |body| try w.writeInt(i16, body.slot, .big),
        .animation => |body| {
            try w.writeInt(i32, body.entity_id, .big);
            try w.writeInt(i8, body.animate, .big);
        },
        .named_entity_spawn => |body| {
            try w.writeInt(i32, body.entity_id, .big);
            try writeString(w, body.name, max_username);
            try w.writeInt(i32, body.x, .big);
            try w.writeInt(i32, body.y, .big);
            try w.writeInt(i32, body.z, .big);
            try w.writeInt(i8, body.rotation, .big);
            try w.writeInt(i8, body.pitch, .big);
            try w.writeInt(i16, body.current_item, .big);
        },
        .destroy_entity => |body| try w.writeInt(i32, body.entity_id, .big),
        .entity => |body| try w.writeInt(i32, body.entity_id, .big),
        .rel_entity_move => |body| {
            try w.writeInt(i32, body.entity_id, .big);
            try w.writeInt(i8, body.dx, .big);
            try w.writeInt(i8, body.dy, .big);
            try w.writeInt(i8, body.dz, .big);
        },
        .entity_look => |body| {
            try w.writeInt(i32, body.entity_id, .big);
            try w.writeInt(i8, body.yaw, .big);
            try w.writeInt(i8, body.pitch, .big);
        },
        .rel_entity_move_look => |body| {
            try w.writeInt(i32, body.entity_id, .big);
            try w.writeInt(i8, body.dx, .big);
            try w.writeInt(i8, body.dy, .big);
            try w.writeInt(i8, body.dz, .big);
            try w.writeInt(i8, body.yaw, .big);
            try w.writeInt(i8, body.pitch, .big);
        },
        .entity_teleport => |body| {
            try w.writeInt(i32, body.entity_id, .big);
            try w.writeInt(i32, body.x, .big);
            try w.writeInt(i32, body.y, .big);
            try w.writeInt(i32, body.z, .big);
            try w.writeInt(i8, body.yaw, .big);
            try w.writeInt(i8, body.pitch, .big);
        },
        .pre_chunk => |body| {
            try w.writeInt(i32, body.x, .big);
            try w.writeInt(i32, body.z, .big);
            try w.writeInt(u8, @intFromBool(body.load), .big);
        },
        .map_chunk => |body| {
            try w.writeInt(i32, body.x, .big);
            try w.writeInt(i16, body.y, .big);
            try w.writeInt(i32, body.z, .big);
            try w.writeInt(u8, body.size_x - 1, .big);
            try w.writeInt(u8, body.size_y - 1, .big);
            try w.writeInt(u8, body.size_z - 1, .big);
            try w.writeInt(i32, @intCast(body.compressed.len), .big);
            try w.writeAll(body.compressed);
        },
        .multi_block_change => |body| {
            try w.writeInt(i32, body.chunk_x, .big);
            try w.writeInt(i32, body.chunk_z, .big);
            try w.writeInt(i16, @bitCast(@as(u16, @intCast(body.coordinates.len))), .big);
            for (body.coordinates) |coordinate| try w.writeInt(i16, coordinate, .big);
            try w.writeAll(body.types);
            try w.writeAll(body.metadata);
        },
        .block_change => |body| {
            try w.writeInt(i32, body.x, .big);
            try w.writeInt(u8, body.y, .big);
            try w.writeInt(i32, body.z, .big);
            try w.writeInt(u8, body.block, .big);
            try w.writeInt(u8, body.metadata, .big);
        },
        .kick_disconnect => |body| try writeString(w, body.reason, max_kick_reason),
    }
}

pub fn encodeAlloc(gpa: std.mem.Allocator, packet: Packet) ![]u8 {
    var allocating: std.Io.Writer.Allocating = .init(gpa);
    errdefer allocating.deinit();
    try write(&allocating.writer, packet);
    return allocating.toOwnedSlice();
}

pub fn decode(gpa: std.mem.Allocator, bytes: []const u8, from_client: bool) !Packet {
    var reader = std.Io.Reader.fixed(bytes);
    return read(gpa, &reader, from_client);
}

const Golden = struct {
    hex: []const u8,
    packet: Packet,
};

const golden = [_]Golden{
    .{ .hex = "00", .packet = .keep_alive },
    .{ .hex = "010000000e0005004e006f0074006300681122334455667788ff", .packet = .{ .login = .{
        .protocol_version = 14,
        .username = "Notch",
        .map_seed = 0x1122334455667788,
        .dimension = -1,
    } } },
    .{ .hex = "0200060050006c0061007900650072", .packet = .{ .handshake = .{ .username = "Player" } } },
    .{
        .hex = "03000d00680065006c006c006f002000e900200077006f0072006c0064",
        .packet = .{ .chat = .{ .message = "hello é world" } },
    },
    .{ .hex = "040000011f71fb04cb", .packet = .{ .update_time = .{ .time = 1234567890123 } } },
    .{ .hex = "06fffffff0000000400000012c", .packet = .{ .spawn_position = .{ .x = -16, .y = 64, .z = 300 } } },
    .{ .hex = "080011", .packet = .{ .update_health = .{ .health = 17 } } },
    .{ .hex = "09ff", .packet = .{ .respawn = .{ .dimension = -1 } } },
    .{ .hex = "0a01", .packet = .{ .flying = .{ .on_ground = true } } },
    .{
        .hex = "0b3ff8000000000000405067ae147ae1484050000000000000c02080000000000000",
        .packet = .{ .player_position = .{
            .x = 1.5,
            .y = 65.62,
            .stance = 64.0,
            .z = -8.25,
            .on_ground = false,
        } },
    },
    .{ .hex = "0c41480000c205000001", .packet = .{ .player_look = .{
        .yaw = 12.5,
        .pitch = -33.25,
        .on_ground = true,
    } } },
    .{
        .hex = "0d3ff8000000000000405067ae147ae1484050000000000000c02080000000000041480000c205000001",
        .packet = .{ .player_look_move = .{
            .x = 1.5,
            .y = 65.62,
            .stance = 64.0,
            .z = -8.25,
            .yaw = 12.5,
            .pitch = -33.25,
            .on_ground = true,
        } },
    },
    .{ .hex = "0e02ffffffe2c80000002f04", .packet = .{ .block_dig = .{
        .status = 2,
        .x = -30,
        .y = 200,
        .z = 47,
        .face = 4,
    } } },
    .{ .hex = "0ffffffffbfa0000000903ffff", .packet = .{ .place = .{
        .x = -5,
        .y = 250,
        .z = 9,
        .face = 3,
        .held = null,
    } } },
    .{ .hex = "0ffffffffbfa0000000903002311000b", .packet = .{ .place = .{
        .x = -5,
        .y = 250,
        .z = 9,
        .face = 3,
        .held = .{ .id = 35, .count = 17, .damage = 11 },
    } } },
    .{ .hex = "100007", .packet = .{ .block_item_switch = .{ .slot = 7 } } },
    .{ .hex = "120000232901", .packet = .{ .animation = .{ .entity_id = 9001, .animate = 1 } } },
    .{
        .hex = "1400001092000500530074006500760065ffffff9c000008000000004d88280116",
        .packet = .{ .named_entity_spawn = .{
            .entity_id = 4242,
            .name = "Steve",
            .x = -100,
            .y = 2048,
            .z = 77,
            .rotation = -120,
            .pitch = 40,
            .current_item = 278,
        } },
    },
    .{ .hex = "1d00000037", .packet = .{ .destroy_entity = .{ .entity_id = 55 } } },
    .{ .hex = "1e00000038", .packet = .{ .entity = .{ .entity_id = 56 } } },
    .{ .hex = "1f00000039fd0480", .packet = .{ .rel_entity_move = .{
        .entity_id = 57,
        .dx = -3,
        .dy = 4,
        .dz = -128,
    } } },
    .{ .hex = "200000003a7fc0", .packet = .{ .entity_look = .{
        .entity_id = 58,
        .yaw = 127,
        .pitch = -64,
    } } },
    .{ .hex = "210000003b01fe03fc05", .packet = .{ .rel_entity_move_look = .{
        .entity_id = 59,
        .dx = 1,
        .dy = -2,
        .dz = 3,
        .yaw = -4,
        .pitch = 5,
    } } },
    .{ .hex = "220000003cffffffff00000002fffffffda60c", .packet = .{ .entity_teleport = .{
        .entity_id = 60,
        .x = -1,
        .y = 2,
        .z = -3,
        .yaw = -90,
        .pitch = 12,
    } } },
    .{ .hex = "32fffffffc0000000901", .packet = .{ .pre_chunk = .{ .x = -4, .z = 9, .load = true } } },
    .{ .hex = "33ffffffe00000000000300f7f0f000000050102030405", .packet = .{ .map_chunk = .{
        .x = -32,
        .y = 0,
        .z = 48,
        .size_x = 16,
        .size_y = 128,
        .size_z = 16,
        .compressed = &.{ 1, 2, 3, 4, 5 },
    } } },
    .{ .hex = "3400000002fffffffd00030102f0f00004010203040506", .packet = .{ .multi_block_change = .{
        .chunk_x = 2,
        .chunk_z = -3,
        .coordinates = &.{ 0x0102, -3856, 4 },
        .types = &.{ 1, 2, 3 },
        .metadata = &.{ 4, 5, 6 },
    } } },
    .{ .hex = "35fffffff9780000000d3809", .packet = .{ .block_change = .{
        .x = -7,
        .y = 120,
        .z = 13,
        .block = 56,
        .metadata = 9,
    } } },
    .{
        .hex = "ff0010004f007500740064006100740065006400200063006c00690065006e00740021",
        .packet = .{ .kick_disconnect = .{ .reason = "Outdated client!" } },
    },
};

fn fromHex(gpa: std.mem.Allocator, hex: []const u8) ![]u8 {
    const bytes = try gpa.alloc(u8, hex.len / 2);
    errdefer gpa.free(bytes);
    for (bytes, 0..) |*byte, index| {
        byte.* = try std.fmt.parseInt(u8, hex[index * 2 ..][0..2], 16);
    }
    return bytes;
}

test "every packet encodes to the bytes vanilla writes for it" {
    const gpa = std.testing.allocator;

    for (golden) |entry| {
        const expected = try fromHex(gpa, entry.hex);
        defer gpa.free(expected);

        const encoded = try encodeAlloc(gpa, entry.packet);
        defer gpa.free(encoded);

        std.testing.expectEqualSlices(u8, expected, encoded) catch |err| {
            std.debug.print("mismatch encoding {s}\n", .{@tagName(entry.packet.id())});
            return err;
        };
    }
}

test "every packet decodes back out of the bytes vanilla wrote" {
    const gpa = std.testing.allocator;

    for (golden) |entry| {
        const bytes = try fromHex(gpa, entry.hex);
        defer gpa.free(bytes);

        const from_client = direction(entry.packet.id()).to_server;
        const decoded = try decode(gpa, bytes, from_client);
        defer decoded.deinit(gpa);

        const round_tripped = try encodeAlloc(gpa, decoded);
        defer gpa.free(round_tripped);

        try std.testing.expectEqual(entry.packet.id(), decoded.id());
        std.testing.expectEqualSlices(u8, bytes, round_tripped) catch |err| {
            std.debug.print("mismatch round tripping {s}\n", .{@tagName(entry.packet.id())});
            return err;
        };
    }
}

test "each packet is allowed in exactly the directions vanilla registers it for" {
    const registered = [_]struct { id: Id, to_client: bool, to_server: bool }{
        .{ .id = .keep_alive, .to_client = true, .to_server = true },
        .{ .id = .login, .to_client = true, .to_server = true },
        .{ .id = .handshake, .to_client = true, .to_server = true },
        .{ .id = .chat, .to_client = true, .to_server = true },
        .{ .id = .update_time, .to_client = true, .to_server = false },
        .{ .id = .spawn_position, .to_client = true, .to_server = false },
        .{ .id = .update_health, .to_client = true, .to_server = false },
        .{ .id = .respawn, .to_client = true, .to_server = true },
        .{ .id = .flying, .to_client = true, .to_server = true },
        .{ .id = .player_position, .to_client = true, .to_server = true },
        .{ .id = .player_look, .to_client = true, .to_server = true },
        .{ .id = .player_look_move, .to_client = true, .to_server = true },
        .{ .id = .block_dig, .to_client = false, .to_server = true },
        .{ .id = .place, .to_client = false, .to_server = true },
        .{ .id = .block_item_switch, .to_client = false, .to_server = true },
        .{ .id = .animation, .to_client = true, .to_server = true },
        .{ .id = .named_entity_spawn, .to_client = true, .to_server = false },
        .{ .id = .destroy_entity, .to_client = true, .to_server = false },
        .{ .id = .entity, .to_client = true, .to_server = false },
        .{ .id = .rel_entity_move, .to_client = true, .to_server = false },
        .{ .id = .entity_look, .to_client = true, .to_server = false },
        .{ .id = .rel_entity_move_look, .to_client = true, .to_server = false },
        .{ .id = .entity_teleport, .to_client = true, .to_server = false },
        .{ .id = .pre_chunk, .to_client = true, .to_server = false },
        .{ .id = .map_chunk, .to_client = true, .to_server = false },
        .{ .id = .multi_block_change, .to_client = true, .to_server = false },
        .{ .id = .block_change, .to_client = true, .to_server = false },
        .{ .id = .kick_disconnect, .to_client = true, .to_server = true },
    };

    try std.testing.expectEqual(@typeInfo(Id).@"enum".fields.len, registered.len);
    for (registered) |entry| {
        const allowed = direction(entry.id);
        try std.testing.expectEqual(entry.to_client, allowed.to_client);
        try std.testing.expectEqual(entry.to_server, allowed.to_server);
    }
}

test "an id the protocol does not define is refused rather than guessed at" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.UnknownPacketId, decode(gpa, &.{ 0x77, 0, 0 }, true));
}

test "a packet arriving from the wrong side is refused" {
    const gpa = std.testing.allocator;

    const dig = [_]u8{ 0x0e, 2, 0, 0, 0, 30, 200, 0, 0, 0, 47, 4 };
    const decoded = try decode(gpa, &dig, true);
    decoded.deinit(gpa);
    try std.testing.expectError(error.WrongDirection, decode(gpa, &dig, false));

    const spawn = [_]u8{ 0x06, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 3 };
    const inbound = try decode(gpa, &spawn, false);
    inbound.deinit(gpa);
    try std.testing.expectError(error.WrongDirection, decode(gpa, &spawn, true));
}

test "a string longer than its packet allows is refused both ways" {
    const gpa = std.testing.allocator;

    const long_login = "a" ** (max_username + 1);
    try std.testing.expectError(error.StringTooLong, encodeAlloc(gpa, .{ .login = .{
        .protocol_version = protocol_version,
        .username = long_login,
        .map_seed = 0,
        .dimension = 0,
    } }));

    const long_handshake = "a" ** (max_handshake_name + 1);
    try std.testing.expectError(error.StringTooLong, encodeAlloc(gpa, .{ .handshake = .{ .username = long_handshake } }));

    var claimed: [4]u8 = .{ 0x02, 0x00, max_handshake_name + 1, 0 };
    try std.testing.expectError(error.StringTooLong, decode(gpa, &claimed, true));

    claimed[2] = 0xff;
    claimed[1] = 0xff;
    try std.testing.expectError(error.NegativeLength, decode(gpa, &claimed, true));
}

test "a packet cut short is refused rather than read past its end" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.EndOfStream, decode(gpa, &.{ 0x06, 0, 0, 0 }, false));
    try std.testing.expectError(error.EndOfStream, decode(gpa, &.{0x0e}, true));
}

test "a string that fills its whole allowance still fits" {
    const gpa = std.testing.allocator;

    const full = "b" ** max_chat;
    const encoded = try encodeAlloc(gpa, .{ .chat = .{ .message = full } });
    defer gpa.free(encoded);

    try std.testing.expectEqual(@as(usize, 1 + 2 + max_chat * 2), encoded.len);

    const decoded = try decode(gpa, encoded, true);
    defer decoded.deinit(gpa);
    try std.testing.expectEqualStrings(full, decoded.chat.message);
}

test "a packet body reads exactly as many bytes as vanilla wrote" {
    const gpa = std.testing.allocator;

    for (golden) |entry| {
        const bytes = try fromHex(gpa, entry.hex);
        defer gpa.free(bytes);

        var reader = std.Io.Reader.fixed(bytes);
        const packet_id = try readId(&reader);
        const decoded = try readBody(gpa, &reader, packet_id);
        defer decoded.deinit(gpa);

        try std.testing.expectEqual(@as(usize, 0), reader.bufferedLen());
    }
}
