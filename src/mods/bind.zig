const std = @import("std");

const zlua = @import("zlua");
const Lua = zlua.Lua;

pub const Entry = struct { name: [:0]const u8, function: zlua.CFn };

pub fn upvalue(comptime T: type, lua: *Lua) *T {
    return @ptrCast(@alignCast(@constCast(lua.toPointer(Lua.upvalueIndex(1)).?)));
}

pub fn fields(lua: *Lua, context: *const anyopaque, entries: []const Entry) void {
    for (entries) |entry| {
        lua.pushLightUserdata(context);
        lua.pushClosure(entry.function, 1);
        lua.setField(-2, entry.name);
    }
}

pub fn subtable(lua: *Lua, name: [:0]const u8, context: *const anyopaque, entries: []const Entry) void {
    lua.newTable();
    fields(lua, context, entries);
    lua.setField(-2, name);
}

pub fn listener(lua: *Lua, slot: *?i32) void {
    lua.checkType(1, .function);
    if (slot.*) |old| lua.unref(zlua.registry_index, old);
    lua.pushValue(1);
    slot.* = lua.ref(zlua.registry_index);
}

pub fn optionalNumber(lua: *Lua, arg: i32, fallback: f64) f64 {
    if (lua.isNoneOrNil(arg)) return fallback;
    return lua.checkNumber(arg);
}

pub fn number(lua: *Lua, table: i32, name: [:0]const u8, fallback: f32) f32 {
    defer lua.pop(1);
    if (lua.getField(table, name) == .nil) return fallback;
    if (lua.typeOf(-1) != .number) lua.raiseErrorStr("'%s' must be a number", .{name.ptr});
    const value: f32 = @floatCast(lua.toNumber(-1) catch unreachable);
    if (!std.math.isFinite(value)) lua.raiseErrorStr("'%s' must be a finite number", .{name.ptr});
    return value;
}

pub fn whole(lua: *Lua, table: i32, comptime T: type, name: [:0]const u8, fallback: T) T {
    defer lua.pop(1);
    if (lua.getField(table, name) == .nil) return fallback;
    const value = lua.toInteger(-1) catch lua.raiseErrorStr("'%s' must be a whole number", .{name.ptr});
    return std.math.cast(T, value) orelse lua.raiseErrorStr("'%s' is out of range", .{name.ptr});
}

pub fn flag(lua: *Lua, table: i32, name: [:0]const u8, fallback: bool) bool {
    defer lua.pop(1);
    return switch (lua.getField(table, name)) {
        .nil => fallback,
        .boolean => lua.toBoolean(-1),
        else => lua.raiseErrorStr("'%s' must be true or false", .{name.ptr}),
    };
}

pub fn pushStack(lua: *Lua, stack: anytype) i32 {
    const held = stack orelse {
        lua.pushNil();
        return 1;
    };
    _ = lua.pushString(held.id.key());
    lua.pushInteger(held.count);
    lua.pushInteger(held.meta);
    return 3;
}
