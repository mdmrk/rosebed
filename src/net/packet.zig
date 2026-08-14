const std = @import("std");

pub const protocol_version: i32 = 14;

pub const Id = enum(u8) {
    keep_alive = 0,
    login = 1,
    handshake = 2,
    chat = 3,
    update_time = 4,
    player_inventory = 5,
    spawn_position = 6,
    use_entity = 7,
    update_health = 8,
    respawn = 9,
    flying = 10,
    player_position = 11,
    player_look = 12,
    player_look_move = 13,
    block_dig = 14,
    place = 15,
    block_item_switch = 16,
    sleep = 17,
    animation = 18,
    entity_action = 19,
    named_entity_spawn = 20,
    pickup_spawn = 21,
    collect = 22,
    vehicle_spawn = 23,
    mob_spawn = 24,
    entity_painting = 25,
    stance_update = 27,
    entity_velocity = 28,
    destroy_entity = 29,
    entity = 30,
    rel_entity_move = 31,
    entity_look = 32,
    rel_entity_move_look = 33,
    entity_teleport = 34,
    entity_status = 38,
    attach_entity = 39,
    entity_metadata = 40,
    pre_chunk = 50,
    map_chunk = 51,
    multi_block_change = 52,
    block_change = 53,
    play_note_block = 54,
    explosion = 60,
    door_change = 61,
    bed = 70,
    weather = 71,
    open_window = 100,
    close_window = 101,
    window_click = 102,
    set_slot = 103,
    window_items = 104,
    update_progressbar = 105,
    transaction = 106,
    update_sign = 130,
    map_data = 131,
    statistic = 200,
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
        .player_inventory => .{ .to_client = true, .to_server = false },
        .spawn_position => .{ .to_client = true, .to_server = false },
        .use_entity => .{ .to_client = false, .to_server = true },
        .update_health => .{ .to_client = true, .to_server = false },
        .respawn => .{ .to_client = true, .to_server = true },
        .flying => .{ .to_client = true, .to_server = true },
        .player_position => .{ .to_client = true, .to_server = true },
        .player_look => .{ .to_client = true, .to_server = true },
        .player_look_move => .{ .to_client = true, .to_server = true },
        .block_dig => .{ .to_client = false, .to_server = true },
        .place => .{ .to_client = false, .to_server = true },
        .block_item_switch => .{ .to_client = false, .to_server = true },
        .sleep => .{ .to_client = true, .to_server = false },
        .animation => .{ .to_client = true, .to_server = true },
        .entity_action => .{ .to_client = false, .to_server = true },
        .named_entity_spawn => .{ .to_client = true, .to_server = false },
        .pickup_spawn => .{ .to_client = true, .to_server = false },
        .collect => .{ .to_client = true, .to_server = false },
        .vehicle_spawn => .{ .to_client = true, .to_server = false },
        .mob_spawn => .{ .to_client = true, .to_server = false },
        .entity_painting => .{ .to_client = true, .to_server = false },
        .stance_update => .{ .to_client = false, .to_server = true },
        .entity_velocity => .{ .to_client = true, .to_server = false },
        .destroy_entity => .{ .to_client = true, .to_server = false },
        .entity => .{ .to_client = true, .to_server = false },
        .rel_entity_move => .{ .to_client = true, .to_server = false },
        .entity_look => .{ .to_client = true, .to_server = false },
        .rel_entity_move_look => .{ .to_client = true, .to_server = false },
        .entity_teleport => .{ .to_client = true, .to_server = false },
        .entity_status => .{ .to_client = true, .to_server = false },
        .attach_entity => .{ .to_client = true, .to_server = false },
        .entity_metadata => .{ .to_client = true, .to_server = false },
        .pre_chunk => .{ .to_client = true, .to_server = false },
        .map_chunk => .{ .to_client = true, .to_server = false },
        .multi_block_change => .{ .to_client = true, .to_server = false },
        .block_change => .{ .to_client = true, .to_server = false },
        .play_note_block => .{ .to_client = true, .to_server = false },
        .explosion => .{ .to_client = true, .to_server = false },
        .door_change => .{ .to_client = true, .to_server = false },
        .bed => .{ .to_client = true, .to_server = false },
        .weather => .{ .to_client = true, .to_server = false },
        .open_window => .{ .to_client = true, .to_server = false },
        .close_window => .{ .to_client = true, .to_server = true },
        .window_click => .{ .to_client = false, .to_server = true },
        .set_slot => .{ .to_client = true, .to_server = false },
        .window_items => .{ .to_client = true, .to_server = false },
        .update_progressbar => .{ .to_client = true, .to_server = false },
        .transaction => .{ .to_client = true, .to_server = true },
        .update_sign => .{ .to_client = true, .to_server = true },
        .map_data => .{ .to_client = true, .to_server = false },
        .statistic => .{ .to_client = true, .to_server = false },
        .kick_disconnect => .{ .to_client = true, .to_server = true },
    };
}

pub const swing_animation: i8 = 1;

pub const max_username = 16;
pub const max_handshake_name = 32;
pub const max_chat = 119;
pub const max_kick_reason = 100;
pub const max_art_title = 13;
pub const max_window_title = 64;
pub const max_sign_line = 15;
pub const sign_lines = 4;
pub const max_window_slots = 256;
pub const max_explosion_blocks = 1 << 20;
pub const max_map_bytes = 255;

pub const Stack = struct {
    id: i16,
    count: i8,
    damage: i16,
};

pub const max_metadata_text = 64;
pub const metadata_end: u8 = 127;

pub const Metadata = struct {
    entries: []const Entry = &.{},

    pub const Kind = enum(u3) { byte, short, int, float, text, stack, coords };

    pub const Value = union(Kind) {
        byte: i8,
        short: i16,
        int: i32,
        float: f32,
        text: []const u8,
        stack: Stack,
        coords: [3]i32,
    };

    pub const Entry = struct { key: u5, value: Value };

    pub fn find(self: Metadata, key: u5) ?Value {
        for (self.entries) |entry| {
            if (entry.key == key) return entry.value;
        }
        return null;
    }

    pub fn byteAt(self: Metadata, key: u5) ?i8 {
        const value = self.find(key) orelse return null;
        return switch (value) {
            .byte => |raw| raw,
            else => null,
        };
    }

    pub fn intAt(self: Metadata, key: u5) ?i32 {
        const value = self.find(key) orelse return null;
        return switch (value) {
            .int => |raw| raw,
            else => null,
        };
    }

    pub fn textAt(self: Metadata, key: u5) ?[]const u8 {
        const value = self.find(key) orelse return null;
        return switch (value) {
            .text => |raw| raw,
            else => null,
        };
    }
};

pub const Watched = struct {
    entries: [max_watched]Metadata.Entry = undefined,
    len: usize = 0,

    pub const max_watched = 32;

    pub fn add(self: *Watched, key: u5, value: Metadata.Value) void {
        std.debug.assert(self.len < max_watched);
        self.entries[self.len] = .{ .key = key, .value = value };
        self.len += 1;
    }

    pub fn view(self: *const Watched) Metadata {
        return .{ .entries = self.entries[0..self.len] };
    }
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
    player_inventory: struct { entity_id: i32, slot: i16, item_id: i16, damage: i16 },
    spawn_position: struct { x: i32, y: i32, z: i32 },
    use_entity: struct { player_id: i32, target_id: i32, left_click: i8 },
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
    sleep: struct { entity_id: i32, unused: i8, x: i32, y: i8, z: i32 },
    animation: struct { entity_id: i32, animate: i8 },
    entity_action: struct { entity_id: i32, state: i8 },
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
    pickup_spawn: struct {
        entity_id: i32,
        item_id: i16,
        count: i8,
        damage: i16,
        x: i32,
        y: i32,
        z: i32,
        rotation: i8,
        pitch: i8,
        roll: i8,
    },
    collect: struct { collected_id: i32, collector_id: i32 },
    vehicle_spawn: struct {
        entity_id: i32,
        kind: u8,
        x: i32,
        y: i32,
        z: i32,
        thrower_id: i32 = 0,
        speed_x: i16 = 0,
        speed_y: i16 = 0,
        speed_z: i16 = 0,
    },
    mob_spawn: struct {
        entity_id: i32,
        kind: u8,
        x: i32,
        y: i32,
        z: i32,
        yaw: i8,
        pitch: i8,
        metadata: Metadata,
    },
    entity_painting: struct {
        entity_id: i32,
        title: []const u8,
        x: i32,
        y: i32,
        z: i32,
        direction: i32,
    },
    stance_update: struct {
        stride: f32,
        yaw: f32,
        pitch: f32,
        lift: f32,
        on_ground: bool,
        sneaking: bool,
    },
    entity_velocity: struct { entity_id: i32, motion_x: i16, motion_y: i16, motion_z: i16 },
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
    entity_status: struct { entity_id: i32, status: i8 },
    attach_entity: struct { entity_id: i32, vehicle_id: i32 },
    entity_metadata: struct { entity_id: i32, metadata: Metadata },
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
    play_note_block: struct { x: i32, y: i16, z: i32, instrument: u8, pitch: u8 },
    explosion: struct {
        x: f64,
        y: f64,
        z: f64,
        radius: f32,
        broken: []const [3]i8,
    },
    door_change: struct { x: i32, y: i32, state: i8, z: i32, extra: i32 },
    bed: struct { state: i8 },
    weather: struct { entity_id: i32, lightning: i8, x: i32, y: i32, z: i32 },
    open_window: struct { window_id: i8, kind: i8, title: []const u8, slots: i8 },
    close_window: struct { window_id: i8 },
    window_click: struct {
        window_id: i8,
        slot: i16,
        right_click: i8,
        action: i16,
        shift: bool,
        held: ?Stack,
    },
    set_slot: struct { window_id: i8, slot: i16, stack: ?Stack },
    window_items: struct { window_id: i8, stacks: []const ?Stack },
    update_progressbar: struct { window_id: i8, bar: i16, value: i16 },
    transaction: struct { window_id: i8, action: i16, accepted: bool },
    update_sign: struct { x: i32, y: i16, z: i32, lines: [sign_lines][]const u8 },
    map_data: struct { kind: i16, map_id: i16, data: []const u8 },
    statistic: struct { stat_id: i32, amount: i8 },
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
            .entity_painting => |body| gpa.free(body.title),
            .open_window => |body| gpa.free(body.title),
            .explosion => |body| gpa.free(body.broken),
            .window_items => |body| gpa.free(body.stacks),
            .map_data => |body| gpa.free(body.data),
            .update_sign => |body| for (body.lines) |line| gpa.free(line),
            .mob_spawn => |body| freeMetadata(gpa, body.metadata),
            .entity_metadata => |body| freeMetadata(gpa, body.metadata),
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
    InvalidUtf8Text,
    UnknownMetadataType,
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

const longest_string = @max(
    @max(max_username, max_handshake_name),
    @max(@max(max_chat, max_kick_reason), max_metadata_text),
);

fn writeString(w: *std.Io.Writer, text: []const u8, limit: u16) !void {
    const length = std.unicode.calcUtf16LeLen(text) catch return error.InvalidUtf8;
    if (length > limit) return error.StringTooLong;

    var buffer: [longest_string]u16 = undefined;
    const written = std.unicode.utf8ToUtf16Le(buffer[0..length], text) catch return error.InvalidUtf8;

    try w.writeInt(i16, @intCast(written), .big);
    for (buffer[0..written]) |unit| try w.writeInt(u16, unit, .big);
}

fn readUtf8(gpa: std.mem.Allocator, r: *std.Io.Reader, limit: u16) ![]u8 {
    const length = try r.takeInt(u16, .big);
    if (length > limit) return error.StringTooLong;

    const text = try gpa.alloc(u8, length);
    errdefer gpa.free(text);
    try r.readSliceAll(text);
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8Text;
    return text;
}

fn writeUtf8(w: *std.Io.Writer, text: []const u8, limit: u16) !void {
    if (text.len > limit) return error.StringTooLong;
    try w.writeInt(u16, @intCast(text.len), .big);
    try w.writeAll(text);
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

fn freeMetadata(gpa: std.mem.Allocator, metadata: Metadata) void {
    for (metadata.entries) |entry| {
        switch (entry.value) {
            .text => |raw| gpa.free(raw),
            else => {},
        }
    }
    gpa.free(metadata.entries);
}

fn readMetadata(gpa: std.mem.Allocator, r: *std.Io.Reader) !Metadata {
    var entries: std.ArrayList(Metadata.Entry) = .empty;
    errdefer {
        for (entries.items) |entry| {
            switch (entry.value) {
                .text => |raw| gpa.free(raw),
                else => {},
            }
        }
        entries.deinit(gpa);
    }

    while (true) {
        const header = try r.takeInt(u8, .big);
        if (header == metadata_end) break;

        const kind = std.enums.fromInt(Metadata.Kind, @as(u3, @truncate(header >> 5))) orelse
            return error.UnknownMetadataType;
        const key: u5 = @truncate(header);

        const value: Metadata.Value = switch (kind) {
            .byte => .{ .byte = try r.takeInt(i8, .big) },
            .short => .{ .short = try r.takeInt(i16, .big) },
            .int => .{ .int = try r.takeInt(i32, .big) },
            .float => .{ .float = @bitCast(try r.takeInt(u32, .big)) },
            .text => .{ .text = try readString(gpa, r, max_metadata_text) },
            .stack => .{ .stack = .{
                .id = try r.takeInt(i16, .big),
                .count = try r.takeInt(i8, .big),
                .damage = try r.takeInt(i16, .big),
            } },
            .coords => .{ .coords = .{
                try r.takeInt(i32, .big),
                try r.takeInt(i32, .big),
                try r.takeInt(i32, .big),
            } },
        };
        errdefer switch (value) {
            .text => |raw| gpa.free(raw),
            else => {},
        };

        try entries.append(gpa, .{ .key = key, .value = value });
    }

    return .{ .entries = try entries.toOwnedSlice(gpa) };
}

fn writeMetadata(w: *std.Io.Writer, metadata: Metadata) !void {
    for (metadata.entries) |entry| {
        const kind: u8 = @intFromEnum(std.meta.activeTag(entry.value));
        try w.writeInt(u8, (kind << 5) | entry.key, .big);
        switch (entry.value) {
            .byte => |raw| try w.writeInt(i8, raw, .big),
            .short => |raw| try w.writeInt(i16, raw, .big),
            .int => |raw| try w.writeInt(i32, raw, .big),
            .float => |raw| try w.writeInt(u32, @bitCast(raw), .big),
            .text => |raw| try writeString(w, raw, max_metadata_text),
            .stack => |raw| {
                try w.writeInt(i16, raw.id, .big);
                try w.writeInt(i8, raw.count, .big);
                try w.writeInt(i16, raw.damage, .big);
            },
            .coords => |raw| for (raw) |axis| try w.writeInt(i32, axis, .big),
        }
    }
    try w.writeInt(u8, metadata_end, .big);
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
        .mob_spawn => {
            const entity_id = try r.takeInt(i32, .big);
            const kind = try r.takeInt(u8, .big);
            const x = try r.takeInt(i32, .big);
            const y = try r.takeInt(i32, .big);
            const z = try r.takeInt(i32, .big);
            const yaw = try r.takeInt(i8, .big);
            const pitch = try r.takeInt(i8, .big);
            return .{ .mob_spawn = .{
                .entity_id = entity_id,
                .kind = kind,
                .x = x,
                .y = y,
                .z = z,
                .yaw = yaw,
                .pitch = pitch,
                .metadata = try readMetadata(gpa, r),
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
        .entity_metadata => {
            const entity_id = try r.takeInt(i32, .big);
            return .{ .entity_metadata = .{
                .entity_id = entity_id,
                .metadata = try readMetadata(gpa, r),
            } };
        },
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
        .player_inventory => return .{ .player_inventory = .{
            .entity_id = try r.takeInt(i32, .big),
            .slot = try r.takeInt(i16, .big),
            .item_id = try r.takeInt(i16, .big),
            .damage = try r.takeInt(i16, .big),
        } },
        .use_entity => return .{ .use_entity = .{
            .player_id = try r.takeInt(i32, .big),
            .target_id = try r.takeInt(i32, .big),
            .left_click = try r.takeInt(i8, .big),
        } },
        .sleep => return .{ .sleep = .{
            .entity_id = try r.takeInt(i32, .big),
            .unused = try r.takeInt(i8, .big),
            .x = try r.takeInt(i32, .big),
            .y = try r.takeInt(i8, .big),
            .z = try r.takeInt(i32, .big),
        } },
        .entity_action => return .{ .entity_action = .{
            .entity_id = try r.takeInt(i32, .big),
            .state = try r.takeInt(i8, .big),
        } },
        .pickup_spawn => return .{ .pickup_spawn = .{
            .entity_id = try r.takeInt(i32, .big),
            .item_id = try r.takeInt(i16, .big),
            .count = try r.takeInt(i8, .big),
            .damage = try r.takeInt(i16, .big),
            .x = try r.takeInt(i32, .big),
            .y = try r.takeInt(i32, .big),
            .z = try r.takeInt(i32, .big),
            .rotation = try r.takeInt(i8, .big),
            .pitch = try r.takeInt(i8, .big),
            .roll = try r.takeInt(i8, .big),
        } },
        .collect => return .{ .collect = .{
            .collected_id = try r.takeInt(i32, .big),
            .collector_id = try r.takeInt(i32, .big),
        } },
        .vehicle_spawn => {
            var body: @FieldType(Packet, "vehicle_spawn") = .{
                .entity_id = try r.takeInt(i32, .big),
                .kind = try r.takeInt(u8, .big),
                .x = try r.takeInt(i32, .big),
                .y = try r.takeInt(i32, .big),
                .z = try r.takeInt(i32, .big),
                .thrower_id = try r.takeInt(i32, .big),
            };
            if (body.thrower_id > 0) {
                body.speed_x = try r.takeInt(i16, .big);
                body.speed_y = try r.takeInt(i16, .big);
                body.speed_z = try r.takeInt(i16, .big);
            }
            return .{ .vehicle_spawn = body };
        },
        .entity_painting => {
            const entity_id = try r.takeInt(i32, .big);
            const title = try readString(gpa, r, max_art_title);
            errdefer gpa.free(title);
            return .{ .entity_painting = .{
                .entity_id = entity_id,
                .title = title,
                .x = try r.takeInt(i32, .big),
                .y = try r.takeInt(i32, .big),
                .z = try r.takeInt(i32, .big),
                .direction = try r.takeInt(i32, .big),
            } };
        },
        .stance_update => return .{ .stance_update = .{
            .stride = @bitCast(try r.takeInt(u32, .big)),
            .yaw = @bitCast(try r.takeInt(u32, .big)),
            .pitch = @bitCast(try r.takeInt(u32, .big)),
            .lift = @bitCast(try r.takeInt(u32, .big)),
            .on_ground = try r.takeInt(u8, .big) != 0,
            .sneaking = try r.takeInt(u8, .big) != 0,
        } },
        .entity_velocity => return .{ .entity_velocity = .{
            .entity_id = try r.takeInt(i32, .big),
            .motion_x = try r.takeInt(i16, .big),
            .motion_y = try r.takeInt(i16, .big),
            .motion_z = try r.takeInt(i16, .big),
        } },
        .entity_status => return .{ .entity_status = .{
            .entity_id = try r.takeInt(i32, .big),
            .status = try r.takeInt(i8, .big),
        } },
        .attach_entity => return .{ .attach_entity = .{
            .entity_id = try r.takeInt(i32, .big),
            .vehicle_id = try r.takeInt(i32, .big),
        } },
        .play_note_block => return .{ .play_note_block = .{
            .x = try r.takeInt(i32, .big),
            .y = try r.takeInt(i16, .big),
            .z = try r.takeInt(i32, .big),
            .instrument = try r.takeInt(u8, .big),
            .pitch = try r.takeInt(u8, .big),
        } },
        .explosion => {
            const x: f64 = @bitCast(try r.takeInt(u64, .big));
            const y: f64 = @bitCast(try r.takeInt(u64, .big));
            const z: f64 = @bitCast(try r.takeInt(u64, .big));
            const radius: f32 = @bitCast(try r.takeInt(u32, .big));
            const count = try r.takeInt(i32, .big);
            if (count < 0) return error.NegativeLength;
            if (count > max_explosion_blocks) return error.StringTooLong;

            const broken = try gpa.alloc([3]i8, @intCast(count));
            errdefer gpa.free(broken);
            for (broken) |*offset| {
                offset[0] = try r.takeInt(i8, .big);
                offset[1] = try r.takeInt(i8, .big);
                offset[2] = try r.takeInt(i8, .big);
            }
            return .{ .explosion = .{ .x = x, .y = y, .z = z, .radius = radius, .broken = broken } };
        },
        .door_change => return .{ .door_change = .{
            .x = try r.takeInt(i32, .big),
            .y = try r.takeInt(i32, .big),
            .state = try r.takeInt(i8, .big),
            .z = try r.takeInt(i32, .big),
            .extra = try r.takeInt(i32, .big),
        } },
        .bed => return .{ .bed = .{ .state = try r.takeInt(i8, .big) } },
        .weather => return .{ .weather = .{
            .entity_id = try r.takeInt(i32, .big),
            .lightning = try r.takeInt(i8, .big),
            .x = try r.takeInt(i32, .big),
            .y = try r.takeInt(i32, .big),
            .z = try r.takeInt(i32, .big),
        } },
        .open_window => {
            const window_id = try r.takeInt(i8, .big);
            const kind = try r.takeInt(i8, .big);
            const title = try readUtf8(gpa, r, max_window_title);
            errdefer gpa.free(title);
            return .{ .open_window = .{
                .window_id = window_id,
                .kind = kind,
                .title = title,
                .slots = try r.takeInt(i8, .big),
            } };
        },
        .close_window => return .{ .close_window = .{ .window_id = try r.takeInt(i8, .big) } },
        .window_click => return .{ .window_click = .{
            .window_id = try r.takeInt(i8, .big),
            .slot = try r.takeInt(i16, .big),
            .right_click = try r.takeInt(i8, .big),
            .action = try r.takeInt(i16, .big),
            .shift = try r.takeInt(u8, .big) != 0,
            .held = try readStack(r),
        } },
        .set_slot => return .{ .set_slot = .{
            .window_id = try r.takeInt(i8, .big),
            .slot = try r.takeInt(i16, .big),
            .stack = try readStack(r),
        } },
        .window_items => {
            const window_id = try r.takeInt(i8, .big);
            const count = try r.takeInt(i16, .big);
            if (count < 0) return error.NegativeLength;
            if (count > max_window_slots) return error.StringTooLong;

            const stacks = try gpa.alloc(?Stack, @intCast(count));
            errdefer gpa.free(stacks);
            for (stacks) |*slot| slot.* = try readStack(r);
            return .{ .window_items = .{ .window_id = window_id, .stacks = stacks } };
        },
        .update_progressbar => return .{ .update_progressbar = .{
            .window_id = try r.takeInt(i8, .big),
            .bar = try r.takeInt(i16, .big),
            .value = try r.takeInt(i16, .big),
        } },
        .transaction => return .{ .transaction = .{
            .window_id = try r.takeInt(i8, .big),
            .action = try r.takeInt(i16, .big),
            .accepted = try r.takeInt(u8, .big) != 0,
        } },
        .update_sign => {
            const x = try r.takeInt(i32, .big);
            const y = try r.takeInt(i16, .big);
            const z = try r.takeInt(i32, .big);

            var lines: [sign_lines][]const u8 = undefined;
            var filled: usize = 0;
            errdefer for (lines[0..filled]) |line| gpa.free(line);
            while (filled < sign_lines) : (filled += 1) {
                lines[filled] = try readString(gpa, r, max_sign_line);
            }
            return .{ .update_sign = .{ .x = x, .y = y, .z = z, .lines = lines } };
        },
        .map_data => {
            const kind = try r.takeInt(i16, .big);
            const map_id = try r.takeInt(i16, .big);
            const length = try r.takeInt(u8, .big);
            const data = try takeBytes(gpa, r, length);
            return .{ .map_data = .{ .kind = kind, .map_id = map_id, .data = data } };
        },
        .statistic => return .{ .statistic = .{
            .stat_id = try r.takeInt(i32, .big),
            .amount = try r.takeInt(i8, .big),
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
        .mob_spawn => |body| {
            try w.writeInt(i32, body.entity_id, .big);
            try w.writeInt(u8, body.kind, .big);
            try w.writeInt(i32, body.x, .big);
            try w.writeInt(i32, body.y, .big);
            try w.writeInt(i32, body.z, .big);
            try w.writeInt(i8, body.yaw, .big);
            try w.writeInt(i8, body.pitch, .big);
            try writeMetadata(w, body.metadata);
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
        .entity_metadata => |body| {
            try w.writeInt(i32, body.entity_id, .big);
            try writeMetadata(w, body.metadata);
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
        .player_inventory => |body| {
            try w.writeInt(i32, body.entity_id, .big);
            try w.writeInt(i16, body.slot, .big);
            try w.writeInt(i16, body.item_id, .big);
            try w.writeInt(i16, body.damage, .big);
        },
        .use_entity => |body| {
            try w.writeInt(i32, body.player_id, .big);
            try w.writeInt(i32, body.target_id, .big);
            try w.writeInt(i8, body.left_click, .big);
        },
        .sleep => |body| {
            try w.writeInt(i32, body.entity_id, .big);
            try w.writeInt(i8, body.unused, .big);
            try w.writeInt(i32, body.x, .big);
            try w.writeInt(i8, body.y, .big);
            try w.writeInt(i32, body.z, .big);
        },
        .entity_action => |body| {
            try w.writeInt(i32, body.entity_id, .big);
            try w.writeInt(i8, body.state, .big);
        },
        .pickup_spawn => |body| {
            try w.writeInt(i32, body.entity_id, .big);
            try w.writeInt(i16, body.item_id, .big);
            try w.writeInt(i8, body.count, .big);
            try w.writeInt(i16, body.damage, .big);
            try w.writeInt(i32, body.x, .big);
            try w.writeInt(i32, body.y, .big);
            try w.writeInt(i32, body.z, .big);
            try w.writeInt(i8, body.rotation, .big);
            try w.writeInt(i8, body.pitch, .big);
            try w.writeInt(i8, body.roll, .big);
        },
        .collect => |body| {
            try w.writeInt(i32, body.collected_id, .big);
            try w.writeInt(i32, body.collector_id, .big);
        },
        .vehicle_spawn => |body| {
            try w.writeInt(i32, body.entity_id, .big);
            try w.writeInt(u8, body.kind, .big);
            try w.writeInt(i32, body.x, .big);
            try w.writeInt(i32, body.y, .big);
            try w.writeInt(i32, body.z, .big);
            try w.writeInt(i32, body.thrower_id, .big);
            if (body.thrower_id > 0) {
                try w.writeInt(i16, body.speed_x, .big);
                try w.writeInt(i16, body.speed_y, .big);
                try w.writeInt(i16, body.speed_z, .big);
            }
        },
        .entity_painting => |body| {
            try w.writeInt(i32, body.entity_id, .big);
            try writeString(w, body.title, max_art_title);
            try w.writeInt(i32, body.x, .big);
            try w.writeInt(i32, body.y, .big);
            try w.writeInt(i32, body.z, .big);
            try w.writeInt(i32, body.direction, .big);
        },
        .stance_update => |body| {
            try w.writeInt(u32, @bitCast(body.stride), .big);
            try w.writeInt(u32, @bitCast(body.yaw), .big);
            try w.writeInt(u32, @bitCast(body.pitch), .big);
            try w.writeInt(u32, @bitCast(body.lift), .big);
            try w.writeInt(u8, @intFromBool(body.on_ground), .big);
            try w.writeInt(u8, @intFromBool(body.sneaking), .big);
        },
        .entity_velocity => |body| {
            try w.writeInt(i32, body.entity_id, .big);
            try w.writeInt(i16, body.motion_x, .big);
            try w.writeInt(i16, body.motion_y, .big);
            try w.writeInt(i16, body.motion_z, .big);
        },
        .entity_status => |body| {
            try w.writeInt(i32, body.entity_id, .big);
            try w.writeInt(i8, body.status, .big);
        },
        .attach_entity => |body| {
            try w.writeInt(i32, body.entity_id, .big);
            try w.writeInt(i32, body.vehicle_id, .big);
        },
        .play_note_block => |body| {
            try w.writeInt(i32, body.x, .big);
            try w.writeInt(i16, body.y, .big);
            try w.writeInt(i32, body.z, .big);
            try w.writeInt(u8, body.instrument, .big);
            try w.writeInt(u8, body.pitch, .big);
        },
        .explosion => |body| {
            try w.writeInt(u64, @bitCast(body.x), .big);
            try w.writeInt(u64, @bitCast(body.y), .big);
            try w.writeInt(u64, @bitCast(body.z), .big);
            try w.writeInt(u32, @bitCast(body.radius), .big);
            try w.writeInt(i32, @intCast(body.broken.len), .big);
            for (body.broken) |offset| {
                try w.writeInt(i8, offset[0], .big);
                try w.writeInt(i8, offset[1], .big);
                try w.writeInt(i8, offset[2], .big);
            }
        },
        .door_change => |body| {
            try w.writeInt(i32, body.x, .big);
            try w.writeInt(i32, body.y, .big);
            try w.writeInt(i8, body.state, .big);
            try w.writeInt(i32, body.z, .big);
            try w.writeInt(i32, body.extra, .big);
        },
        .bed => |body| try w.writeInt(i8, body.state, .big),
        .weather => |body| {
            try w.writeInt(i32, body.entity_id, .big);
            try w.writeInt(i8, body.lightning, .big);
            try w.writeInt(i32, body.x, .big);
            try w.writeInt(i32, body.y, .big);
            try w.writeInt(i32, body.z, .big);
        },
        .open_window => |body| {
            try w.writeInt(i8, body.window_id, .big);
            try w.writeInt(i8, body.kind, .big);
            try writeUtf8(w, body.title, max_window_title);
            try w.writeInt(i8, body.slots, .big);
        },
        .close_window => |body| try w.writeInt(i8, body.window_id, .big),
        .window_click => |body| {
            try w.writeInt(i8, body.window_id, .big);
            try w.writeInt(i16, body.slot, .big);
            try w.writeInt(i8, body.right_click, .big);
            try w.writeInt(i16, body.action, .big);
            try w.writeInt(u8, @intFromBool(body.shift), .big);
            try writeStack(w, body.held);
        },
        .set_slot => |body| {
            try w.writeInt(i8, body.window_id, .big);
            try w.writeInt(i16, body.slot, .big);
            try writeStack(w, body.stack);
        },
        .window_items => |body| {
            try w.writeInt(i8, body.window_id, .big);
            try w.writeInt(i16, @intCast(body.stacks.len), .big);
            for (body.stacks) |slot| try writeStack(w, slot);
        },
        .update_progressbar => |body| {
            try w.writeInt(i8, body.window_id, .big);
            try w.writeInt(i16, body.bar, .big);
            try w.writeInt(i16, body.value, .big);
        },
        .transaction => |body| {
            try w.writeInt(i8, body.window_id, .big);
            try w.writeInt(i16, body.action, .big);
            try w.writeInt(u8, @intFromBool(body.accepted), .big);
        },
        .update_sign => |body| {
            try w.writeInt(i32, body.x, .big);
            try w.writeInt(i16, body.y, .big);
            try w.writeInt(i32, body.z, .big);
            for (body.lines) |line| try writeString(w, line, max_sign_line);
        },
        .map_data => |body| {
            try w.writeInt(i16, body.kind, .big);
            try w.writeInt(i16, body.map_id, .big);
            try w.writeInt(u8, @intCast(body.data.len), .big);
            try w.writeAll(body.data);
        },
        .statistic => |body| {
            try w.writeInt(i32, body.stat_id, .big);
            try w.writeInt(i8, body.amount, .big);
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
    .{
        .hex = "18000010925a000003e800000800fffffeb340f0000010017f",
        .packet = .{ .mob_spawn = .{
            .entity_id = 4242,
            .kind = 90,
            .x = 1000,
            .y = 2048,
            .z = -333,
            .yaw = 64,
            .pitch = -16,
            .metadata = .{ .entries = &.{
                .{ .key = 0, .value = .{ .byte = 0 } },
                .{ .key = 16, .value = .{ .byte = 1 } },
            } },
        } },
    },
    .{
        .hex = "18000000075fffffffff0000000000000020000000011003910005004e006f00740063006852000000147f",
        .packet = .{ .mob_spawn = .{
            .entity_id = 7,
            .kind = 95,
            .x = -1,
            .y = 0,
            .z = 32,
            .yaw = 0,
            .pitch = 0,
            .metadata = .{ .entries = &.{
                .{ .key = 0, .value = .{ .byte = 1 } },
                .{ .key = 16, .value = .{ .byte = 3 } },
                .{ .key = 17, .value = .{ .text = "Notch" } },
                .{ .key = 18, .value = .{ .int = 20 } },
            } },
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
    .{
        .hex = "280000006300fe21012c42fffeee90633f00000084000200680069c600000001fffffffe000000037f",
        .packet = .{ .entity_metadata = .{
            .entity_id = 99,
            .metadata = .{ .entries = &.{
                .{ .key = 0, .value = .{ .byte = -2 } },
                .{ .key = 1, .value = .{ .short = 300 } },
                .{ .key = 2, .value = .{ .int = -70000 } },
                .{ .key = 3, .value = .{ .float = 0.5 } },
                .{ .key = 4, .value = .{ .text = "hi" } },
                .{ .key = 6, .value = .{ .coords = .{ 1, -2, 3 } } },
            } },
        } },
    },
    .{ .hex = "28000000057f", .packet = .{ .entity_metadata = .{ .entity_id = 5, .metadata = .{} } } },
    .{
        .hex = "2800000007100452000000087f",
        .packet = .{ .entity_metadata = .{
            .entity_id = 7,
            .metadata = .{ .entries = &.{
                .{ .key = 16, .value = .{ .byte = 4 } },
                .{ .key = 18, .value = .{ .int = 8 } },
            } },
        } },
    },
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
    .{ .hex = "0500001092000101160007", .packet = .{ .player_inventory = .{
        .entity_id = 4242,
        .slot = 1,
        .item_id = 278,
        .damage = 7,
    } } },
    .{ .hex = "0700000009fffffffd01", .packet = .{ .use_entity = .{
        .player_id = 9,
        .target_id = -3,
        .left_click = 1,
    } } },
    .{ .hex = "110000000c00ffffffd8460000012c", .packet = .{ .sleep = .{
        .entity_id = 12,
        .unused = 0,
        .x = -40,
        .y = 70,
        .z = 300,
    } } },
    .{ .hex = "130000005802", .packet = .{ .entity_action = .{ .entity_id = 88, .state = 2 } } },
    .{ .hex = "150000004d01080c000300000400000008c0fffffe000aec1e", .packet = .{ .pickup_spawn = .{
        .entity_id = 77,
        .item_id = 264,
        .count = 12,
        .damage = 3,
        .x = 1024,
        .y = 2240,
        .z = -512,
        .rotation = 10,
        .pitch = -20,
        .roll = 30,
    } } },
    .{ .hex = "160000000500000006", .packet = .{ .collect = .{
        .collected_id = 5,
        .collector_id = 6,
    } } },
    .{ .hex = "170000001f0a00000064000000c80000012c00000000", .packet = .{ .vehicle_spawn = .{
        .entity_id = 31,
        .kind = 10,
        .x = 100,
        .y = 200,
        .z = 300,
    } } },
    .{ .hex = "170000001f3c00000064000000c80000012c0000000903e8f8300bb8", .packet = .{ .vehicle_spawn = .{
        .entity_id = 31,
        .kind = 60,
        .x = 100,
        .y = 200,
        .z = 300,
        .thrower_id = 9,
        .speed_x = 1000,
        .speed_y = -2000,
        .speed_z = 3000,
    } } },
    .{
        .hex = "19000000290005004b00650062006100620000000300000041fffffff700000002",
        .packet = .{ .entity_painting = .{
            .entity_id = 41,
            .title = "Kebab",
            .x = 3,
            .y = 65,
            .z = -9,
            .direction = 2,
        } },
    },
    .{ .hex = "1b3fc00000c0100000407000003f0000000100", .packet = .{ .stance_update = .{
        .stride = 1.5,
        .yaw = -2.25,
        .pitch = 3.75,
        .lift = 0.5,
        .on_ground = true,
        .sneaking = false,
    } } },
    .{ .hex = "1c0000000f0320f9c00020", .packet = .{ .entity_velocity = .{
        .entity_id = 15,
        .motion_x = 800,
        .motion_y = -1600,
        .motion_z = 32,
    } } },
    .{ .hex = "260000001502", .packet = .{ .entity_status = .{ .entity_id = 21, .status = 2 } } },
    .{ .hex = "2700000003ffffffff", .packet = .{ .attach_entity = .{
        .entity_id = 3,
        .vehicle_id = -1,
    } } },
    .{ .hex = "36000000080040fffffff8010c", .packet = .{ .play_note_block = .{
        .x = 8,
        .y = 64,
        .z = -8,
        .instrument = 1,
        .pitch = 12,
    } } },
    .{
        .hex = "3c40250000000000004050400000000000c00a000000000000408000000000000101fe03",
        .packet = .{ .explosion = .{
            .x = 10.5,
            .y = 65.0,
            .z = -3.25,
            .radius = 4.0,
            .broken = &.{.{ 1, -2, 3 }},
        } },
    },
    .{ .hex = "3d000000050000004201fffffff900000009", .packet = .{ .door_change = .{
        .x = 5,
        .y = 66,
        .state = 1,
        .z = -7,
        .extra = 9,
    } } },
    .{ .hex = "4602", .packet = .{ .bed = .{ .state = 2 } } },
    .{ .hex = "47000000630100000140000008c0fffffd80", .packet = .{ .weather = .{
        .entity_id = 99,
        .lightning = 1,
        .x = 320,
        .y = 2240,
        .z = -640,
    } } },
    .{ .hex = "640300000543686573741b", .packet = .{ .open_window = .{
        .window_id = 3,
        .kind = 0,
        .title = "Chest",
        .slots = 27,
    } } },
    .{ .hex = "6503", .packet = .{ .close_window = .{ .window_id = 3 } } },
    .{ .hex = "6603001101002a010118050000", .packet = .{ .window_click = .{
        .window_id = 3,
        .slot = 17,
        .right_click = 1,
        .action = 42,
        .shift = true,
        .held = .{ .id = 280, .count = 5, .damage = 0 },
    } } },
    .{ .hex = "6600fc1900000100ffff", .packet = .{ .window_click = .{
        .window_id = 0,
        .slot = -999,
        .right_click = 0,
        .action = 1,
        .shift = false,
        .held = null,
    } } },
    .{ .hex = "67ff00090001400000", .packet = .{ .set_slot = .{
        .window_id = -1,
        .slot = 9,
        .stack = .{ .id = 1, .count = 64, .damage = 0 },
    } } },
    .{ .hex = "680000030003020001ffff0165010000", .packet = .{ .window_items = .{
        .window_id = 0,
        .stacks = &.{
            .{ .id = 3, .count = 2, .damage = 1 },
            null,
            .{ .id = 357, .count = 1, .damage = 0 },
        },
    } } },
    .{ .hex = "690400020096", .packet = .{ .update_progressbar = .{
        .window_id = 4,
        .bar = 2,
        .value = 150,
    } } },
    .{ .hex = "6a03004d01", .packet = .{ .transaction = .{
        .window_id = 3,
        .action = 77,
        .accepted = true,
    } } },
    .{
        .hex = "82fffffffc0046000000100003006f006e0065000000050074006800720065006500040066006f00750072",
        .packet = .{ .update_sign = .{
            .x = -4,
            .y = 70,
            .z = 16,
            .lines = .{ "one", "", "three", "four" },
        } },
    },
    .{ .hex = "830166000104000102ff", .packet = .{ .map_data = .{
        .kind = 358,
        .map_id = 1,
        .data = &.{ 0, 1, 2, 0xff },
    } } },
    .{ .hex = "c8000003e805", .packet = .{ .statistic = .{ .stat_id = 1000, .amount = 5 } } },
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

test "every packet the protocol defines has a byte vector taken from vanilla" {
    var seen: [@typeInfo(Id).@"enum".fields.len]bool = @splat(false);

    for (golden) |entry| {
        inline for (@typeInfo(Id).@"enum".fields, 0..) |field, index| {
            if (entry.packet.id() == @as(Id, @enumFromInt(field.value))) seen[index] = true;
        }
    }

    inline for (@typeInfo(Id).@"enum".fields, 0..) |field, index| {
        if (!seen[index]) {
            std.debug.print("no golden vector for {s}\n", .{field.name});
            return error.TestExpectedEqual;
        }
    }
}

test "each packet is allowed in exactly the directions vanilla registers it for" {
    const registered = [_]struct { id: Id, to_client: bool, to_server: bool }{
        .{ .id = .keep_alive, .to_client = true, .to_server = true },
        .{ .id = .login, .to_client = true, .to_server = true },
        .{ .id = .handshake, .to_client = true, .to_server = true },
        .{ .id = .chat, .to_client = true, .to_server = true },
        .{ .id = .update_time, .to_client = true, .to_server = false },
        .{ .id = .player_inventory, .to_client = true, .to_server = false },
        .{ .id = .spawn_position, .to_client = true, .to_server = false },
        .{ .id = .use_entity, .to_client = false, .to_server = true },
        .{ .id = .update_health, .to_client = true, .to_server = false },
        .{ .id = .respawn, .to_client = true, .to_server = true },
        .{ .id = .flying, .to_client = true, .to_server = true },
        .{ .id = .player_position, .to_client = true, .to_server = true },
        .{ .id = .player_look, .to_client = true, .to_server = true },
        .{ .id = .player_look_move, .to_client = true, .to_server = true },
        .{ .id = .block_dig, .to_client = false, .to_server = true },
        .{ .id = .place, .to_client = false, .to_server = true },
        .{ .id = .block_item_switch, .to_client = false, .to_server = true },
        .{ .id = .sleep, .to_client = true, .to_server = false },
        .{ .id = .animation, .to_client = true, .to_server = true },
        .{ .id = .entity_action, .to_client = false, .to_server = true },
        .{ .id = .named_entity_spawn, .to_client = true, .to_server = false },
        .{ .id = .pickup_spawn, .to_client = true, .to_server = false },
        .{ .id = .collect, .to_client = true, .to_server = false },
        .{ .id = .vehicle_spawn, .to_client = true, .to_server = false },
        .{ .id = .mob_spawn, .to_client = true, .to_server = false },
        .{ .id = .entity_painting, .to_client = true, .to_server = false },
        .{ .id = .stance_update, .to_client = false, .to_server = true },
        .{ .id = .entity_velocity, .to_client = true, .to_server = false },
        .{ .id = .destroy_entity, .to_client = true, .to_server = false },
        .{ .id = .entity, .to_client = true, .to_server = false },
        .{ .id = .rel_entity_move, .to_client = true, .to_server = false },
        .{ .id = .entity_look, .to_client = true, .to_server = false },
        .{ .id = .rel_entity_move_look, .to_client = true, .to_server = false },
        .{ .id = .entity_teleport, .to_client = true, .to_server = false },
        .{ .id = .entity_status, .to_client = true, .to_server = false },
        .{ .id = .attach_entity, .to_client = true, .to_server = false },
        .{ .id = .entity_metadata, .to_client = true, .to_server = false },
        .{ .id = .pre_chunk, .to_client = true, .to_server = false },
        .{ .id = .map_chunk, .to_client = true, .to_server = false },
        .{ .id = .multi_block_change, .to_client = true, .to_server = false },
        .{ .id = .block_change, .to_client = true, .to_server = false },
        .{ .id = .play_note_block, .to_client = true, .to_server = false },
        .{ .id = .explosion, .to_client = true, .to_server = false },
        .{ .id = .door_change, .to_client = true, .to_server = false },
        .{ .id = .bed, .to_client = true, .to_server = false },
        .{ .id = .weather, .to_client = true, .to_server = false },
        .{ .id = .open_window, .to_client = true, .to_server = false },
        .{ .id = .close_window, .to_client = true, .to_server = true },
        .{ .id = .window_click, .to_client = false, .to_server = true },
        .{ .id = .set_slot, .to_client = true, .to_server = false },
        .{ .id = .window_items, .to_client = true, .to_server = false },
        .{ .id = .update_progressbar, .to_client = true, .to_server = false },
        .{ .id = .transaction, .to_client = true, .to_server = true },
        .{ .id = .update_sign, .to_client = true, .to_server = true },
        .{ .id = .map_data, .to_client = true, .to_server = false },
        .{ .id = .statistic, .to_client = true, .to_server = false },
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

test "a watched stack survives the trip the golden set cannot reach" {
    const gpa = std.testing.allocator;

    const encoded = try encodeAlloc(gpa, .{ .entity_metadata = .{
        .entity_id = 3,
        .metadata = .{ .entries = &.{
            .{ .key = 10, .value = .{ .stack = .{ .id = 280, .count = 3, .damage = 7 } } },
        } },
    } });
    defer gpa.free(encoded);

    try std.testing.expectEqualSlices(u8, &.{ 0x28, 0, 0, 0, 3, 0xaa, 1, 24, 3, 0, 7, metadata_end }, encoded);

    const decoded = try decode(gpa, encoded, false);
    defer decoded.deinit(gpa);

    const value = decoded.entity_metadata.metadata.find(10).?;
    try std.testing.expectEqual(@as(i16, 280), value.stack.id);
    try std.testing.expectEqual(@as(i8, 3), value.stack.count);
    try std.testing.expectEqual(@as(i16, 7), value.stack.damage);
}

test "a watched value of a type the protocol does not define is refused" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(
        error.UnknownMetadataType,
        decode(gpa, &.{ 0x28, 0, 0, 0, 1, 0xe0, 0 }, false),
    );
}

test "a mob spawn with nothing watched still carries the terminator" {
    const gpa = std.testing.allocator;

    const encoded = try encodeAlloc(gpa, .{ .mob_spawn = .{
        .entity_id = 1,
        .kind = 91,
        .x = 0,
        .y = 0,
        .z = 0,
        .yaw = 0,
        .pitch = 0,
        .metadata = .{},
    } });
    defer gpa.free(encoded);

    try std.testing.expectEqual(metadata_end, encoded[encoded.len - 1]);

    const decoded = try decode(gpa, encoded, false);
    defer decoded.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), decoded.mob_spawn.metadata.entries.len);
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
