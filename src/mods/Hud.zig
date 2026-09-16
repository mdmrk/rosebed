const std = @import("std");

const zlua = @import("zlua");
const Lua = zlua.Lua;

const Hud = @This();

lua: ?*Lua = null,
on_draw: ?i32 = null,
frame: ?std.mem.Allocator = null,
commands: std.ArrayList(Command) = .empty,

pub const Command = union(enum) {
    text: Text,
    rect: Rect,

    pub const Text = struct { text: []const u8, x: f32, y: f32, color: [4]u8 };
    pub const Rect = struct { x: f32, y: f32, width: f32, height: f32, color: [4]u8 };
};

pub fn install(self: *Hud, lua: *Lua) void {
    self.lua = lua;
    _ = lua.getGlobal("rosebed");
    lua.newTable();
    const functions = [_]struct { name: [:0]const u8, function: zlua.CFn }{
        .{ .name = "on_draw", .function = zlua.wrap(onDraw) },
        .{ .name = "text", .function = zlua.wrap(text) },
        .{ .name = "rect", .function = zlua.wrap(rect) },
    };
    for (functions) |entry| {
        lua.pushLightUserdata(self);
        lua.pushClosure(entry.function, 1);
        lua.setField(-2, entry.name);
    }
    lua.setField(-2, "hud");
    lua.pop(1);
}

// Runs the mods' draw callbacks for one frame and returns what they asked for, in
// the order they asked. Everything returned lives in `frame`.
pub fn collect(self: *Hud, frame: std.mem.Allocator, width: f32, height: f32) []const Command {
    const lua = self.lua orelse return &.{};
    const ref = self.on_draw orelse return &.{};

    self.commands = .empty;
    self.frame = frame;
    defer self.frame = null;

    _ = lua.getIndexRaw(zlua.registry_index, ref);
    lua.pushNumber(width);
    lua.pushNumber(height);
    lua.protectedCall(.{ .args = 2, .results = 0 }) catch {
        // A draw callback runs every frame, so one that fails is dropped rather than
        // left to fill the log sixty times a second.
        std.log.warn("a mod hud failed and is switched off: {s}", .{lua.toString(-1) catch "(no message)"});
        lua.pop(1);
        self.on_draw = null;
    };
    return self.commands.items;
}

fn hud(lua: *Lua) *Hud {
    return @ptrCast(@alignCast(@constCast(lua.toPointer(Lua.upvalueIndex(1)).?)));
}

fn drawing(lua: *Lua) struct { *Hud, std.mem.Allocator } {
    const self = hud(lua);
    const frame = self.frame orelse lua.raiseErrorStr("the hud is only drawn from inside on_draw", .{});
    return .{ self, frame };
}

fn onDraw(lua: *Lua) i32 {
    const self = hud(lua);
    lua.checkType(1, .function);
    if (self.on_draw) |old| lua.unref(zlua.registry_index, old);
    lua.pushValue(1);
    self.on_draw = lua.ref(zlua.registry_index);
    return 0;
}

fn text(lua: *Lua) i32 {
    const self, const frame = drawing(lua);
    const line = lua.checkString(1);
    const command: Command = .{ .text = .{
        .text = frame.dupe(u8, line) catch lua.raiseErrorStr("out of memory", .{}),
        .x = @floatCast(lua.checkNumber(2)),
        .y = @floatCast(lua.checkNumber(3)),
        .color = color(lua, 4),
    } };
    self.commands.append(frame, command) catch lua.raiseErrorStr("out of memory", .{});
    return 0;
}

fn rect(lua: *Lua) i32 {
    const self, const frame = drawing(lua);
    const command: Command = .{ .rect = .{
        .x = @floatCast(lua.checkNumber(1)),
        .y = @floatCast(lua.checkNumber(2)),
        .width = @floatCast(lua.checkNumber(3)),
        .height = @floatCast(lua.checkNumber(4)),
        .color = color(lua, 5),
    } };
    self.commands.append(frame, command) catch lua.raiseErrorStr("out of memory", .{});
    return 0;
}

// Colours are written the way the original's font renderer takes them, 0xAARRGGBB,
// and like it a colour with no alpha given at all is drawn fully opaque.
fn color(lua: *Lua, arg: i32) [4]u8 {
    const value: u32 = switch (lua.typeOf(arg)) {
        .none, .nil => 0xFFFFFFFF,
        else => std.math.cast(u32, lua.checkInteger(arg)) orelse lua.argError(arg, "a colour is 0xAARRGGBB"),
    };
    const argb = if (value & 0xFC000000 == 0) value | 0xFF000000 else value;
    return .{ @truncate(argb >> 16), @truncate(argb >> 8), @truncate(argb), @truncate(argb >> 24) };
}

const Vm = @import("Vm.zig");

test "a mod draws on the hud from its on_draw, in the order it asked" {
    var vm: Vm = try .init(std.testing.allocator);
    defer vm.deinit();
    vm.lua.newTable();
    vm.lua.setGlobal("rosebed");
    var self: Hud = .{};
    self.install(vm.lua);

    try vm.exec("=test",
        \\rosebed.hud.on_draw(function(width, height)
        \\  rosebed.hud.rect(1, 2, 3, 4, 0x80FF0000)
        \\  rosebed.hud.text("hi " .. width .. "x" .. height, 5, 6, 0x00FF00)
        \\end)
    );

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const commands = self.collect(arena.allocator(), 320, 240);

    try std.testing.expectEqual(@as(usize, 2), commands.len);
    try std.testing.expectEqual(@as(f32, 3), commands[0].rect.width);
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 128 }, commands[0].rect.color);
    try std.testing.expectEqualStrings("hi 320.0x240.0", commands[1].text.text);
    try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, commands[1].text.color);
}

test "a hud that fails is switched off, and nothing draws outside on_draw" {
    var vm: Vm = try .init(std.testing.allocator);
    defer vm.deinit();
    vm.lua.newTable();
    vm.lua.setGlobal("rosebed");
    var self: Hud = .{};
    self.install(vm.lua);

    try std.testing.expectError(error.ScriptFailed, vm.exec("=test", "rosebed.hud.text('early', 0, 0)"));
    try std.testing.expect(std.mem.endsWith(u8, vm.errorMessage(), "the hud is only drawn from inside on_draw"));

    try vm.exec("=test", "rosebed.hud.on_draw(function() error('boom') end)");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(usize, 0), self.collect(arena.allocator(), 320, 240).len);
    try std.testing.expect(self.on_draw == null);
}
