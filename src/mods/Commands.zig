const std = @import("std");

const game = @import("game");
const net = @import("net");
const zlua = @import("zlua");
const Lua = zlua.Lua;

const Commands = @This();

arena: std.mem.Allocator,
lua: ?*Lua = null,
refs: [game.commands.mod_capacity]?i32 = @splat(null),
on_client: bool = false,
reply: [net.packet.max_chat]u8 = undefined,

pub var active: ?*Commands = null;

pub fn install(self: *Commands, lua: *Lua) void {
    self.lua = lua;
    _ = lua.getGlobal("rosebed");
    lua.pushLightUserdata(self);
    lua.pushClosure(zlua.wrap(registerCommand), 1);
    lua.setField(-2, "register_command");
    lua.pop(1);
    active = self;
}

pub fn deinit(self: *Commands) void {
    if (active == self) active = null;
}

pub fn run(self: *Commands, index: usize, args: []const u8, who: ?[]const u8) ?[]const u8 {
    const lua = self.lua orelse return null;
    const ref = self.refs[index] orelse return null;

    _ = lua.getIndexRaw(zlua.registry_index, ref);
    lua.newTable();
    var words = std.mem.tokenizeScalar(u8, args, ' ');
    var count: i32 = 0;
    while (words.next()) |word| {
        count += 1;
        _ = lua.pushString(word);
        lua.setIndex(-2, count);
    }
    if (who) |name| _ = lua.pushString(name) else lua.pushNil();

    lua.protectedCall(.{ .args = 2, .results = 1 }) catch {
        std.log.warn("a mod command failed: {s}", .{lua.toString(-1) catch "(no message)"});
        lua.pop(1);
        return null;
    };
    defer lua.pop(1);

    if (lua.typeOf(-1) != .string) return null;
    const said = lua.toString(-1) catch return null;
    const len = @min(said.len, self.reply.len);
    @memcpy(self.reply[0..len], said[0..len]);
    return self.reply[0..len];
}

fn context(lua: *Lua) *Commands {
    return @ptrCast(@alignCast(@constCast(lua.toPointer(Lua.upvalueIndex(1)).?)));
}

fn field(lua: *Lua, name: [:0]const u8) []const u8 {
    if (lua.getField(2, name) != .string) {
        lua.pop(1);
        return "";
    }
    const text = lua.toString(-1) catch "";
    lua.pop(1);
    return text;
}

fn registerCommand(lua: *Lua) i32 {
    const self = context(lua);
    const name = lua.checkString(1);
    if (name.len == 0) lua.argError(1, "a command needs a name");
    for (name) |letter| {
        if (!std.ascii.isLower(letter)) lua.argError(1, "a command is named in lowercase letters");
    }
    lua.checkType(2, .table);

    if (lua.getField(2, "run") != .function) lua.raiseErrorStr("'run' must be a function", .{});
    const ref = lua.ref(zlua.registry_index);

    const index = game.commands.register(.{
        .name = self.own(lua, name),
        .usage = self.own(lua, field(lua, "usage")),
        .description = self.own(lua, field(lua, "description")),
        .local = self.on_client,
    }) catch |err| switch (err) {
        error.RegistryFull => lua.raiseErrorStr("no room is left for another command", .{}),
        error.DuplicateKey => lua.raiseErrorStr("'%s' is already a command", .{name.ptr}),
    };
    self.refs[index] = ref;
    return 0;
}

fn own(self: *Commands, lua: *Lua, text: []const u8) []const u8 {
    return self.arena.dupe(u8, text) catch lua.raiseErrorStr("out of memory", .{});
}

const Vm = @import("Vm.zig");

const Harness = struct {
    arena: std.heap.ArenaAllocator,
    vm: Vm,
    api: Commands,

    fn init(self: *Harness) !void {
        self.arena = .init(std.testing.allocator);
        self.vm = try .init(std.testing.allocator);
        self.vm.lua.newTable();
        self.vm.lua.setGlobal("rosebed");
        self.api = .{ .arena = self.arena.allocator() };
        self.api.install(self.vm.lua);
    }

    fn deinit(self: *Harness) void {
        self.api.deinit();
        self.vm.deinit();
        self.arena.deinit();
        game.commands.resetRegistry();
    }
};

test "a command a mod registers reaches its handler with the words and the caller" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try harness.vm.exec("=test",
        \\rosebed.register_command("wings", {
        \\  usage = "<on|off>",
        \\  description = "toggles the wings",
        \\  run = function(args, who)
        \\    return (who or "nobody") .. " said " .. #args .. ":" .. table.concat(args, ",")
        \\  end,
        \\})
    );

    const entry = game.commands.registered()[0];
    try std.testing.expectEqualStrings("wings", entry.name);
    try std.testing.expectEqualStrings("<on|off>", entry.usage);
    try std.testing.expectEqualStrings("toggles the wings", entry.description);
    try std.testing.expect(!entry.local);

    try std.testing.expectEqualStrings("Steve said 2:on,loud", harness.api.run(0, "on loud", "Steve").?);
    try std.testing.expectEqualStrings("nobody said 0:", harness.api.run(0, "", null).?);
}

test "a command registered by a client script is kept on the client" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    harness.api.on_client = true;
    try harness.vm.exec("=test",
        \\rosebed.register_command("wings", { run = function() end })
    );

    try std.testing.expect(game.commands.registered()[0].local);
    try std.testing.expectEqualStrings("", game.commands.registered()[0].usage);
}

test "a handler that answers with nothing says nothing, and one that fails is reported" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try harness.vm.exec("=test",
        \\rosebed.register_command("quiet", { run = function() end })
        \\rosebed.register_command("broken", { run = function() error("boom") end })
    );

    try std.testing.expect(harness.api.run(0, "", null) == null);
    try std.testing.expect(harness.api.run(1, "", null) == null);
}

test "a command needs a lowercase name and something to run" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try std.testing.expectError(error.ScriptFailed, harness.vm.exec("=test",
        \\rosebed.register_command("Wings", { run = function() end })
    ));
    try std.testing.expect(std.mem.indexOf(u8, harness.vm.errorMessage(), "lowercase") != null);

    try std.testing.expectError(error.ScriptFailed, harness.vm.exec("=test",
        \\rosebed.register_command("wings", {})
    ));
    try std.testing.expect(std.mem.indexOf(u8, harness.vm.errorMessage(), "'run' must be a function") != null);

    try std.testing.expectEqual(@as(usize, 0), game.commands.registered().len);
}
