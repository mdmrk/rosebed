const std = @import("std");

pub const guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
pub const key_length: usize = 24;
pub const accept_length: usize = 28;
pub const max_request_bytes: usize = 8 * 1024;
pub const max_payload_bytes: usize = 4 * 1024 * 1024;
pub const normal_closure: u16 = 1000;

pub const Opcode = enum(u4) {
    continuation = 0,
    text = 1,
    binary = 2,
    close = 8,
    ping = 9,
    pong = 10,
    _,

    pub fn control(self: Opcode) bool {
        return @intFromEnum(self) & 0x8 != 0;
    }
};

pub const Frame = struct {
    opcode: Opcode,
    final: bool,
};

pub fn acceptKey(key: []const u8) [accept_length]u8 {
    var hash: std.crypto.hash.Sha1 = .init(.{});
    hash.update(key);
    hash.update(guid);

    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    hash.final(&digest);

    var accept: [accept_length]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&accept, &digest);
    return accept;
}

// One byte, not the whole "GET ": a vanilla handshake for an empty username is only three
// bytes long, so peeking further would block a client that is waiting for its reply. No
// packet a client may send starts with 'G'.
pub fn isUpgrade(r: *std.Io.Reader) !bool {
    return try r.peekByte() == 'G';
}

pub fn readUpgrade(r: *std.Io.Reader) ![accept_length]u8 {
    var key: ?[key_length]u8 = null;
    var read: usize = 0;

    while (true) {
        const raw = try r.takeDelimiterInclusive('\n');
        read += raw.len;
        if (read > max_request_bytes) return error.RequestTooLong;

        const line = std.mem.trimEnd(u8, raw, "\r\n");
        if (line.len == 0) break;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "sec-websocket-key")) continue;

        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (value.len != key_length) return error.MalformedKey;
        key = value[0..key_length].*;
    }

    return acceptKey(&(key orelse return error.MissingKey));
}

pub fn writeAccept(w: *std.Io.Writer, accept: [accept_length]u8) !void {
    try w.print("HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: {s}\r\n\r\n", .{accept[0..]});
}

pub fn readFrame(gpa: std.mem.Allocator, r: *std.Io.Reader, payload: *std.ArrayList(u8)) !Frame {
    const first = try r.takeInt(u8, .big);
    const second = try r.takeInt(u8, .big);
    if (second & 0x80 == 0) return error.UnmaskedFrame;

    const marker: u8 = second & 0x7f;
    const length: usize = switch (marker) {
        126 => try r.takeInt(u16, .big),
        127 => std.math.cast(usize, try r.takeInt(u64, .big)) orelse return error.PayloadTooLong,
        else => marker,
    };
    if (length > max_payload_bytes) return error.PayloadTooLong;

    const mask = (try r.takeArray(4)).*;
    const frame: Frame = .{
        .opcode = @enumFromInt(@as(u4, @truncate(first))),
        .final = first & 0x80 != 0,
    };

    if (frame.opcode.control()) {
        try r.discardAll(length);
        return frame;
    }

    const start = payload.items.len;
    try payload.resize(gpa, start + length);
    errdefer payload.shrinkRetainingCapacity(start);

    const bytes = payload.items[start..];
    try r.readSliceAll(bytes);
    for (bytes, 0..) |*byte, index| byte.* ^= mask[index % mask.len];

    return frame;
}

pub fn writeFrame(w: *std.Io.Writer, opcode: Opcode, payload: []const u8) !void {
    try w.writeInt(u8, 0x80 | @as(u8, @intFromEnum(opcode)), .big);

    if (payload.len < 126) {
        try w.writeInt(u8, @intCast(payload.len), .big);
    } else if (payload.len <= std.math.maxInt(u16)) {
        try w.writeInt(u8, 126, .big);
        try w.writeInt(u16, @intCast(payload.len), .big);
    } else {
        try w.writeInt(u8, 127, .big);
        try w.writeInt(u64, payload.len, .big);
    }

    try w.writeAll(payload);
}

test acceptKey {
    try std.testing.expectEqualStrings(
        "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
        &acceptKey("dGhlIHNhbXBsZSBub25jZQ=="),
    );
}

test isUpgrade {
    var upgrade: std.Io.Reader = .fixed("GET / HTTP/1.1\r\n");
    try std.testing.expect(try isUpgrade(&upgrade));

    var handshake: std.Io.Reader = .fixed(&.{ 0x02, 0x00, 0x04, 0x00 });
    try std.testing.expect(!try isUpgrade(&handshake));
}

test readUpgrade {
    var reader: std.Io.Reader = .fixed(
        "GET /rosebed HTTP/1.1\r\n" ++
            "Host: example.org:25565\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "\r\n",
    );
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &try readUpgrade(&reader));

    var keyless: std.Io.Reader = .fixed("GET / HTTP/1.1\r\nHost: example.org\r\n\r\n");
    try std.testing.expectError(error.MissingKey, readUpgrade(&keyless));
}

fn expectMaskedFrame(gpa: std.mem.Allocator, opcode: Opcode, payload: []const u8) !void {
    var encoded: std.Io.Writer.Allocating = .init(gpa);
    defer encoded.deinit();
    try writeFrame(&encoded.writer, opcode, payload);

    const framed = encoded.written();
    var masked: std.ArrayList(u8) = .empty;
    defer masked.deinit(gpa);

    const header = framed.len - payload.len;
    try masked.appendSlice(gpa, framed[0..header]);
    masked.items[1] |= 0x80;

    const mask: [4]u8 = .{ 0x11, 0x22, 0x33, 0x44 };
    try masked.appendSlice(gpa, &mask);
    for (payload, 0..) |byte, index| try masked.append(gpa, byte ^ mask[index % mask.len]);

    var reader: std.Io.Reader = .fixed(masked.items);
    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(gpa);

    const frame = try readFrame(gpa, &reader, &decoded);
    try std.testing.expectEqual(opcode, frame.opcode);
    try std.testing.expect(frame.final);
    try std.testing.expectEqualSlices(u8, payload, decoded.items);
}

test readFrame {
    const gpa = std.testing.allocator;
    try expectMaskedFrame(gpa, .binary, "");
    try expectMaskedFrame(gpa, .binary, &.{ 0x02, 0x00, 0x04, 0x00 });

    const medium = try gpa.alloc(u8, 4096);
    defer gpa.free(medium);
    for (medium, 0..) |*byte, index| byte.* = @truncate(index);
    try expectMaskedFrame(gpa, .binary, medium);

    var unmasked: std.Io.Reader = .fixed(&.{ 0x82, 0x01, 0x00 });
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    try std.testing.expectError(error.UnmaskedFrame, readFrame(gpa, &unmasked, &payload));
}

test "control frames carry no stream bytes" {
    const gpa = std.testing.allocator;
    var reader: std.Io.Reader = .fixed(&.{ 0x89, 0x82, 0x11, 0x22, 0x33, 0x44, 0x10, 0x23 });

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);

    const frame = try readFrame(gpa, &reader, &payload);
    try std.testing.expectEqual(Opcode.ping, frame.opcode);
    try std.testing.expectEqual(@as(usize, 0), payload.items.len);
}
