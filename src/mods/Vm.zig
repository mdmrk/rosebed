const std = @import("std");

const zlua = @import("zlua");
const Lua = zlua.Lua;

const Vm = @This();

lua: *Lua,

pub const Error = error{ OutOfMemory, ScriptFailed };

const removed_globals = [_][:0]const u8{ "dofile", "loadfile", "load" };

pub fn init(gpa: std.mem.Allocator) error{OutOfMemory}!Vm {
    const lua = try Lua.init(gpa);
    lua.openBase();
    lua.openCoroutine();
    lua.openTable();
    lua.openString();
    lua.openMath();
    lua.openUtf8();
    for (removed_globals) |name| {
        lua.pushNil();
        lua.setGlobal(name);
    }
    _ = lua.getGlobal("string");
    lua.pushNil();
    lua.setField(-2, "dump");
    lua.setTop(0);
    return .{ .lua = lua };
}

pub fn deinit(self: *Vm) void {
    self.lua.deinit();
}

pub fn exec(self: *Vm, name: [:0]const u8, source: []const u8) Error!void {
    self.lua.setTop(0);
    self.lua.loadBuffer(source, name, .text) catch |err| return failure(err);
    self.lua.protectedCall(.{}) catch |err| return failure(err);
}

pub fn errorMessage(self: *const Vm) []const u8 {
    if (self.lua.getTop() == 0) return "";
    return self.lua.toString(-1) catch "";
}

fn failure(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ScriptFailed,
    };
}

test "a script runs against the standard libraries" {
    var vm: Vm = try .init(std.testing.allocator);
    defer vm.deinit();
    try vm.exec("=test", "assert(string.format('%d', math.max(6, 7) * 6) == '42')");
    try std.testing.expectEqualStrings("", vm.errorMessage());
}

test "the sandbox exposes nothing that reaches the host" {
    var vm: Vm = try .init(std.testing.allocator);
    defer vm.deinit();
    try vm.exec("=test",
        \\assert(io == nil)
        \\assert(os == nil)
        \\assert(package == nil)
        \\assert(require == nil)
        \\assert(debug == nil)
        \\assert(dofile == nil)
        \\assert(loadfile == nil)
        \\assert(load == nil)
        \\assert(string.dump == nil)
    );
}

test "a failing script reports where it failed" {
    var vm: Vm = try .init(std.testing.allocator);
    defer vm.deinit();
    try std.testing.expectError(error.ScriptFailed, vm.exec("=probe", "error('boom')"));
    try std.testing.expectEqualStrings("probe:1: boom", vm.errorMessage());
}

test "precompiled chunks are refused" {
    var vm: Vm = try .init(std.testing.allocator);
    defer vm.deinit();
    try std.testing.expectError(error.ScriptFailed, vm.exec("=probe", "\x1bLua"));
}
