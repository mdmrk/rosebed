const std = @import("std");

const net = @import("net");
const zlua = @import("zlua");
const Lua = zlua.Lua;

const Vm = @import("Vm.zig");

const Net = @This();

pub const Message = struct {
    channel: []const u8,
    payload: []const u8,
};

gpa: std.mem.Allocator,
lua: ?*Lua = null,
handlers: std.StringHashMapUnmanaged(i32) = .empty,
outgoing: std.ArrayList(Message) = .empty,

pub var active: ?*Net = null;

pub fn install(self: *Net, lua: *Lua) void {
    self.lua = lua;
    _ = lua.getGlobal("rosebed");
    lua.newTable();
    const functions = [_]struct { name: [:0]const u8, function: zlua.CFn }{
        .{ .name = "send", .function = zlua.wrap(send) },
        .{ .name = "on", .function = zlua.wrap(on) },
    };
    for (functions) |entry| {
        lua.pushLightUserdata(self);
        lua.pushClosure(entry.function, 1);
        lua.setField(-2, entry.name);
    }
    lua.setField(-2, "net");
    lua.pop(1);
    active = self;
}

pub fn deinit(self: *Net) void {
    for (self.outgoing.items) |message| self.free(message);
    self.outgoing.deinit(self.gpa);
    var keys = self.handlers.keyIterator();
    while (keys.next()) |key| self.gpa.free(key.*);
    self.handlers.deinit(self.gpa);
    if (active == self) active = null;
}

fn free(self: *Net, message: Message) void {
    self.gpa.free(message.channel);
    self.gpa.free(message.payload);
}

pub fn take(self: *Net) []Message {
    return self.outgoing.toOwnedSlice(self.gpa) catch &.{};
}

pub fn release(self: *Net, messages: []Message) void {
    for (messages) |message| self.free(message);
    self.gpa.free(messages);
}

pub fn deliver(self: *Net, channel: []const u8, payload: []const u8, from: ?[]const u8) void {
    const lua = self.lua orelse return;
    const ref = self.handlers.get(channel) orelse return;

    _ = lua.getIndexRaw(zlua.registry_index, ref);
    _ = lua.pushString(payload);
    if (from) |name| _ = lua.pushString(name) else lua.pushNil();
    lua.protectedCall(.{ .args = 2, .results = 0 }) catch {
        std.log.warn("a mod message on '{s}' failed: {s}", .{ channel, lua.toString(-1) catch "(no message)" });
        lua.pop(1);
    };
}

fn context(lua: *Lua) *Net {
    return @ptrCast(@alignCast(@constCast(lua.toPointer(Lua.upvalueIndex(1)).?)));
}

fn channelArgument(lua: *Lua, arg: i32) []const u8 {
    const channel = lua.checkString(arg);
    if (channel.len == 0) lua.argError(arg, "a channel needs a name");
    if (channel.len > net.packet.max_mod_channel) lua.argError(arg, "a channel name is too long");
    return channel;
}

fn send(lua: *Lua) i32 {
    const self = context(lua);
    const channel = channelArgument(lua, 1);
    const payload = lua.checkString(2);
    if (payload.len > net.packet.max_mod_payload) lua.argError(2, "a message holds at most 32 kilobytes");

    const owned_channel = self.gpa.dupe(u8, channel) catch lua.raiseErrorStr("out of memory", .{});
    const owned_payload = self.gpa.dupe(u8, payload) catch {
        self.gpa.free(owned_channel);
        lua.raiseErrorStr("out of memory", .{});
    };
    self.outgoing.append(self.gpa, .{ .channel = owned_channel, .payload = owned_payload }) catch {
        self.gpa.free(owned_channel);
        self.gpa.free(owned_payload);
        lua.raiseErrorStr("out of memory", .{});
    };
    return 0;
}

fn on(lua: *Lua) i32 {
    const self = context(lua);
    const channel = channelArgument(lua, 1);
    lua.checkType(2, .function);
    lua.pushValue(2);
    const ref = lua.ref(zlua.registry_index);

    const entry = self.handlers.getOrPut(self.gpa, channel) catch lua.raiseErrorStr("out of memory", .{});
    if (entry.found_existing) {
        lua.unref(zlua.registry_index, entry.value_ptr.*);
    } else {
        entry.key_ptr.* = self.gpa.dupe(u8, channel) catch {
            _ = self.handlers.remove(channel);
            lua.raiseErrorStr("out of memory", .{});
        };
    }
    entry.value_ptr.* = ref;
    return 0;
}

const Harness = struct {
    vm: Vm,
    api: Net,

    fn init(self: *Harness) !void {
        self.vm = try .init(std.testing.allocator);
        self.vm.lua.newTable();
        self.vm.lua.setGlobal("rosebed");
        self.api = .{ .gpa = std.testing.allocator };
        self.api.install(self.vm.lua);
    }

    fn deinit(self: *Harness) void {
        self.api.deinit();
        self.vm.deinit();
    }
};

test "a mod queues what it sends and gets it back out in order" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try harness.vm.exec("=test",
        \\rosebed.net.send("meadow:hive", "first")
        \\rosebed.net.send("meadow:hive", "second")
        \\rosebed.net.send("other", "\x00\x01\xff")
    );

    const messages = harness.api.take();
    defer harness.api.release(messages);
    try std.testing.expectEqual(@as(usize, 3), messages.len);
    try std.testing.expectEqualStrings("meadow:hive", messages[0].channel);
    try std.testing.expectEqualStrings("first", messages[0].payload);
    try std.testing.expectEqualStrings("second", messages[1].payload);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 0xff }, messages[2].payload);

    try std.testing.expectEqual(@as(usize, 0), harness.api.take().len);
}

test "a message reaches the handler of its own channel and nobody else" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try harness.vm.exec("=test",
        \\heard = ""
        \\other = 0
        \\rosebed.net.on("hive", function(payload, from)
        \\  heard = heard .. payload .. "/" .. tostring(from) .. ";"
        \\end)
        \\rosebed.net.on("quiet", function() other = other + 1 end)
    );

    harness.api.deliver("hive", "one", "Steve");
    harness.api.deliver("hive", "two", null);
    harness.api.deliver("nobody", "three", null);

    try std.testing.expectEqual(zlua.LuaType.string, harness.vm.lua.getGlobal("heard"));
    try std.testing.expectEqualStrings("one/Steve;two/nil;", try harness.vm.lua.toString(-1));
    harness.vm.lua.pop(1);
    try std.testing.expectEqual(zlua.LuaType.number, harness.vm.lua.getGlobal("other"));
    try std.testing.expectEqual(@as(i64, 0), harness.vm.lua.toInteger(-1) catch unreachable);
    harness.vm.lua.pop(1);
}

test "registering a channel twice replaces the handler instead of stacking one" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try harness.vm.exec("=test",
        \\seen = ""
        \\rosebed.net.on("hive", function() seen = seen .. "a" end)
        \\rosebed.net.on("hive", function() seen = seen .. "b" end)
    );
    harness.api.deliver("hive", "", null);

    try std.testing.expectEqual(@as(u32, 1), harness.api.handlers.count());
    try std.testing.expectEqual(zlua.LuaType.string, harness.vm.lua.getGlobal("seen"));
    try std.testing.expectEqualStrings("b", try harness.vm.lua.toString(-1));
    harness.vm.lua.pop(1);
}

test "a handler that fails is reported and the channel stays open" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try harness.vm.exec("=test",
        \\count = 0
        \\rosebed.net.on("hive", function()
        \\  count = count + 1
        \\  if count == 1 then error("boom") end
        \\end)
    );
    harness.api.deliver("hive", "", null);
    harness.api.deliver("hive", "", null);

    try std.testing.expectEqual(zlua.LuaType.number, harness.vm.lua.getGlobal("count"));
    try std.testing.expectEqual(@as(i64, 2), harness.vm.lua.toInteger(-1) catch unreachable);
    harness.vm.lua.pop(1);
}

test "a channel and a message have a size the protocol can carry" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try std.testing.expectError(error.ScriptFailed, harness.vm.exec("=test", "rosebed.net.send('', 'x')"));
    try std.testing.expect(std.mem.indexOf(u8, harness.vm.errorMessage(), "a channel needs a name") != null);

    try std.testing.expectError(error.ScriptFailed, harness.vm.exec("=test",
        \\rosebed.net.send(string.rep("c", 65), "x")
    ));
    try std.testing.expect(std.mem.indexOf(u8, harness.vm.errorMessage(), "a channel name is too long") != null);

    try std.testing.expectError(error.ScriptFailed, harness.vm.exec("=test",
        \\rosebed.net.send("hive", string.rep("x", 32769))
    ));
    try std.testing.expect(std.mem.indexOf(u8, harness.vm.errorMessage(), "a message holds at most 32 kilobytes") != null);

    try harness.vm.exec("=test", "rosebed.net.send('hive', string.rep('x', 32768))");
    const messages = harness.api.take();
    defer harness.api.release(messages);
    try std.testing.expectEqual(@as(usize, 32768), messages[0].payload.len);
}
