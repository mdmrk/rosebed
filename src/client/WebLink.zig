const std = @import("std");

const game = @import("game");
const net = @import("net");
const remote = @import("remote");

const WebLink = @This();

pub const max_url_len: usize = 256;

const calling_thread: usize = 2;

const Socket = i32;

const CreateAttributes = extern struct {
    url: [*:0]const u8,
    protocols: ?[*:0]const u8,
    create_on_main_thread: bool,
};

const OpenEvent = extern struct {
    socket: Socket,
};

const MessageEvent = extern struct {
    socket: Socket,
    data: [*]const u8,
    num_bytes: u32,
    is_text: bool,
};

const ErrorEvent = extern struct {
    socket: Socket,
};

const CloseEvent = extern struct {
    socket: Socket,
    was_clean: bool,
    code: u16,
    reason: [512]u8,
};

const OpenCallback = *const fn (i32, *const OpenEvent, ?*anyopaque) callconv(.c) bool;
const MessageCallback = *const fn (i32, *const MessageEvent, ?*anyopaque) callconv(.c) bool;
const ErrorCallback = *const fn (i32, *const ErrorEvent, ?*anyopaque) callconv(.c) bool;
const CloseCallback = *const fn (i32, *const CloseEvent, ?*anyopaque) callconv(.c) bool;

extern fn emscripten_websocket_new(attributes: *CreateAttributes) Socket;
extern fn emscripten_websocket_send_binary(socket: Socket, data: [*]const u8, length: u32) i32;
extern fn emscripten_websocket_close(socket: Socket, code: u16, reason: ?[*:0]const u8) i32;
extern fn emscripten_websocket_delete(socket: Socket) i32;
extern fn emscripten_websocket_set_onopen_callback_on_thread(Socket, ?*anyopaque, OpenCallback, usize) i32;
extern fn emscripten_websocket_set_onmessage_callback_on_thread(Socket, ?*anyopaque, MessageCallback, usize) i32;
extern fn emscripten_websocket_set_onerror_callback_on_thread(Socket, ?*anyopaque, ErrorCallback, usize) i32;
extern fn emscripten_websocket_set_onclose_callback_on_thread(Socket, ?*anyopaque, CloseCallback, usize) i32;
extern fn rosebed_page_is_secure() i32;

gpa: std.mem.Allocator,
socket: Socket = 0,
connection: remote.Connection = .{},
username: NameBuffer = .{},
inbound: std.ArrayList(u8) = .empty,
outgoing: std.ArrayList(u8) = .empty,
ready: bool = false,
failed: bool = false,

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

fn loopback(host: []const u8) bool {
    return std.mem.eql(u8, host, "localhost") or
        std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "::1");
}

fn url(buffer: []u8, host: []const u8, port: u16) ![:0]u8 {
    const scheme = if (!loopback(host) and rosebed_page_is_secure() != 0) "wss" else "ws";
    if (std.mem.indexOfScalar(u8, host, ':') != null)
        return std.fmt.bufPrintZ(buffer, "{s}://[{s}]:{d}", .{ scheme, host, port });
    return std.fmt.bufPrintZ(buffer, "{s}://{s}:{d}", .{ scheme, host, port });
}

pub fn connect(
    gpa: std.mem.Allocator,
    io: std.Io,
    host: []const u8,
    port: u16,
    username: []const u8,
) !*WebLink {
    _ = io;

    var buffer: [max_url_len]u8 = undefined;
    const target = try url(&buffer, host, port);

    const self = try gpa.create(WebLink);
    errdefer gpa.destroy(self);
    self.* = .{ .gpa = gpa };
    self.username.set(username);

    errdefer self.connection.deinit(gpa);
    try self.connection.begin(gpa, self.username.text());

    var attributes: CreateAttributes = .{
        .url = target.ptr,
        .protocols = null,
        .create_on_main_thread = false,
    };
    const socket = emscripten_websocket_new(&attributes);
    if (socket <= 0) return error.WebSocketUnavailable;

    self.socket = socket;
    _ = emscripten_websocket_set_onopen_callback_on_thread(socket, self, onOpen, calling_thread);
    _ = emscripten_websocket_set_onmessage_callback_on_thread(socket, self, onMessage, calling_thread);
    _ = emscripten_websocket_set_onerror_callback_on_thread(socket, self, onError, calling_thread);
    _ = emscripten_websocket_set_onclose_callback_on_thread(socket, self, onClose, calling_thread);
    return self;
}

pub fn deinit(self: *WebLink) void {
    if (self.socket > 0) {
        _ = emscripten_websocket_close(self.socket, net.websocket.normal_closure, null);
        _ = emscripten_websocket_delete(self.socket);
    }

    self.inbound.deinit(self.gpa);
    self.outgoing.deinit(self.gpa);
    self.connection.deinit(self.gpa);
    self.gpa.destroy(self);
}

fn onOpen(event_type: i32, event: *const OpenEvent, user_data: ?*anyopaque) callconv(.c) bool {
    _ = event_type;
    _ = event;
    const self: *WebLink = @ptrCast(@alignCast(user_data.?));
    self.ready = true;
    self.send();
    return true;
}

fn onMessage(event_type: i32, event: *const MessageEvent, user_data: ?*anyopaque) callconv(.c) bool {
    _ = event_type;
    const self: *WebLink = @ptrCast(@alignCast(user_data.?));
    if (event.is_text) return true;

    self.inbound.appendSlice(self.gpa, event.data[0..event.num_bytes]) catch {
        self.failed = true;
    };
    return true;
}

fn onError(event_type: i32, event: *const ErrorEvent, user_data: ?*anyopaque) callconv(.c) bool {
    _ = event_type;
    _ = event;
    const self: *WebLink = @ptrCast(@alignCast(user_data.?));
    self.failed = true;
    return true;
}

fn onClose(event_type: i32, event: *const CloseEvent, user_data: ?*anyopaque) callconv(.c) bool {
    _ = event_type;
    _ = event;
    const self: *WebLink = @ptrCast(@alignCast(user_data.?));
    self.failed = true;
    return true;
}

fn send(self: *WebLink) void {
    if (!self.ready or self.outgoing.items.len == 0) return;
    const result = emscripten_websocket_send_binary(
        self.socket,
        self.outgoing.items.ptr,
        @intCast(self.outgoing.items.len),
    );
    if (result != 0) {
        self.failed = true;
        return;
    }
    self.outgoing.clearRetainingCapacity();
}

pub fn pump(self: *WebLink, level: *game.Level) !void {
    var messages: std.ArrayList(net.packet.Packet) = .empty;
    defer {
        for (messages.items) |message| message.deinit(self.gpa);
        messages.deinit(self.gpa);
    }

    const consumed = net.packet.drain(self.gpa, self.inbound.items, false, &messages) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            self.failed = true;
            return;
        },
    };

    const rest = self.inbound.items.len - consumed;
    std.mem.copyForwards(u8, self.inbound.items[0..rest], self.inbound.items[consumed..]);
    self.inbound.shrinkRetainingCapacity(rest);

    for (messages.items) |message| {
        try self.connection.handle(self.gpa, level, self.username.text(), message);
    }
}

pub fn flush(self: *WebLink) !void {
    const bytes = try self.connection.takeOutbox(self.gpa);
    defer self.gpa.free(bytes);

    if (bytes.len > 0) try self.outgoing.appendSlice(self.gpa, bytes);
    self.send();
}

pub fn isOpen(self: *WebLink) bool {
    return !self.failed and self.connection.state != .closed;
}

pub fn disconnectReason(self: *WebLink) ?[]const u8 {
    if (self.connection.disconnect) |reason| return reason.reason;
    return null;
}
