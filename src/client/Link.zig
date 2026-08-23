const std = @import("std");

const game = @import("game");
const net = @import("net");
const remote = @import("remote");

const Link = @This();

pub const read_buffer_len: usize = 64 * 1024;
pub const write_buffer_len: usize = 32 * 1024;

gpa: std.mem.Allocator,
io: std.Io,
stream: std.Io.net.Stream,
connection: remote.Connection = .{},
username: NameBuffer = .{},
inbox: std.ArrayList(net.packet.Packet) = .empty,
outgoing: std.ArrayList(u8) = .empty,
mutex: std.Io.Mutex = .init,
running: std.atomic.Value(bool) = .init(true),
open: bool = true,
reader_thread: ?std.Thread = null,
writer_thread: ?std.Thread = null,

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

fn lock(self: *Link) void {
    self.mutex.lockUncancelable(self.io);
}

fn unlock(self: *Link) void {
    self.mutex.unlock(self.io);
}

pub fn connect(
    gpa: std.mem.Allocator,
    io: std.Io,
    host: []const u8,
    port: u16,
    username: []const u8,
) !*Link {
    var address = try resolve(io, host, port);
    const stream = try address.connect(io, .{ .mode = .stream });
    errdefer stream.close(io);

    const self = try gpa.create(Link);
    errdefer gpa.destroy(self);
    self.* = .{ .gpa = gpa, .io = io, .stream = stream };
    self.username.set(username);

    try self.connection.begin(gpa, self.username.text());

    self.reader_thread = try std.Thread.spawn(.{}, readLoop, .{self});
    self.writer_thread = try std.Thread.spawn(.{}, writeLoop, .{self});
    return self;
}

fn resolve(io: std.Io, host: []const u8, port: u16) !std.Io.net.IpAddress {
    if (std.Io.net.IpAddress.parse(host, port)) |parsed| return parsed else |_| {}
    return std.Io.net.IpAddress.resolve(io, host, port);
}

pub fn deinit(self: *Link) void {
    self.running.store(false, .release);
    self.stream.shutdown(self.io, .both) catch {};

    if (self.reader_thread) |thread| thread.join();
    if (self.writer_thread) |thread| thread.join();
    self.stream.close(self.io);

    for (self.inbox.items) |message| message.deinit(self.gpa);
    self.inbox.deinit(self.gpa);
    self.outgoing.deinit(self.gpa);
    self.connection.deinit(self.gpa);
    self.gpa.destroy(self);
}

fn readLoop(self: *Link) void {
    var buffer: [read_buffer_len]u8 = undefined;
    var reader = self.stream.reader(self.io, &buffer);

    while (self.running.load(.acquire)) {
        const packet_id = net.packet.readId(&reader.interface) catch break;
        if (!net.packet.direction(packet_id).to_client) break;

        const message = net.packet.readBody(self.gpa, &reader.interface, packet_id) catch break;

        self.lock();
        self.inbox.append(self.gpa, message) catch {
            self.unlock();
            message.deinit(self.gpa);
            break;
        };
        self.unlock();
    }

    self.lock();
    self.open = false;
    self.unlock();
}

fn writeLoop(self: *Link) void {
    var buffer: [write_buffer_len]u8 = undefined;
    var writer = self.stream.writer(self.io, &buffer);

    while (true) {
        self.lock();
        const open = self.open;
        const bytes = self.outgoing.toOwnedSlice(self.gpa) catch &.{};
        self.unlock();

        defer self.gpa.free(bytes);

        if (bytes.len > 0) {
            writer.interface.writeAll(bytes) catch break;
            writer.interface.flush() catch break;
            continue;
        }

        if (!open or !self.running.load(.acquire)) break;
        std.Io.sleep(self.io, .{ .nanoseconds = std.time.ns_per_ms }, .awake) catch {};
    }

    self.lock();
    self.open = false;
    self.unlock();
}

pub fn pump(self: *Link, level: *game.Level) !void {
    self.lock();
    const messages = try self.inbox.toOwnedSlice(self.gpa);
    self.unlock();

    defer {
        for (messages) |message| message.deinit(self.gpa);
        self.gpa.free(messages);
    }

    for (messages) |message| {
        try self.connection.handle(self.gpa, level, self.username.text(), message);
    }
}

pub fn flush(self: *Link) !void {
    const bytes = try self.connection.takeOutbox(self.gpa);
    defer self.gpa.free(bytes);
    if (bytes.len == 0) return;

    self.lock();
    defer self.unlock();
    try self.outgoing.appendSlice(self.gpa, bytes);
}

pub fn isOpen(self: *Link) bool {
    self.lock();
    defer self.unlock();
    return self.open and self.connection.state != .closed;
}

pub fn disconnectReason(self: *Link) ?[]const u8 {
    if (self.connection.disconnect) |reason| return reason.reason;
    return null;
}
