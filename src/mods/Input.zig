const std = @import("std");

const zlua = @import("zlua");
const Lua = zlua.Lua;

const Vm = @import("Vm.zig");

const Input = @This();

lua: ?*Lua = null,
on_key: ?i32 = null,

pub fn install(self: *Input, lua: *Lua) void {
    self.lua = lua;
    _ = lua.getGlobal("rosebed");
    lua.newTable();
    lua.pushLightUserdata(self);
    lua.pushClosure(zlua.wrap(onKey), 1);
    lua.setField(-2, "on_key");
    lua.setField(-2, "input");
    lua.pop(1);
}

pub fn key(self: *Input, name: []const u8, pressed: bool) void {
    const lua = self.lua orelse return;
    const ref = self.on_key orelse return;

    _ = lua.getIndexRaw(zlua.registry_index, ref);
    _ = lua.pushString(name);
    lua.pushBoolean(pressed);
    lua.protectedCall(.{ .args = 2, .results = 0 }) catch {
        std.log.warn("a mod key handler failed and is switched off: {s}", .{lua.toString(-1) catch "(no message)"});
        lua.pop(1);
        self.on_key = null;
    };
}

fn onKey(lua: *Lua) i32 {
    const self: *Input = @ptrCast(@alignCast(@constCast(lua.toPointer(Lua.upvalueIndex(1)).?)));
    lua.checkType(1, .function);
    if (self.on_key) |old| lua.unref(zlua.registry_index, old);
    lua.pushValue(1);
    self.on_key = lua.ref(zlua.registry_index);
    return 0;
}

test "a mod hears each key by name, pressed and let go" {
    var vm: Vm = try .init(std.testing.allocator);
    defer vm.deinit();
    vm.lua.newTable();
    vm.lua.setGlobal("rosebed");
    var self: Input = .{};
    self.install(vm.lua);

    try vm.exec("=test",
        \\heard = ""
        \\rosebed.input.on_key(function(key, pressed)
        \\  heard = heard .. key .. (pressed and "+" or "-")
        \\end)
    );
    self.key("G", true);
    self.key("G", false);

    try std.testing.expectEqual(zlua.LuaType.string, vm.lua.getGlobal("heard"));
    try std.testing.expectEqualStrings("G+G-", try vm.lua.toString(-1));
    vm.lua.pop(1);
}

test "a key handler that fails is switched off" {
    var vm: Vm = try .init(std.testing.allocator);
    defer vm.deinit();
    vm.lua.newTable();
    vm.lua.setGlobal("rosebed");
    var self: Input = .{};
    self.install(vm.lua);

    try vm.exec("=test", "rosebed.input.on_key(function() error('boom') end)");
    self.key("G", true);
    try std.testing.expect(self.on_key == null);
}
