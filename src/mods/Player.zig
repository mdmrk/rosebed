const std = @import("std");

const game = @import("game");
const world = @import("world");
const zlua = @import("zlua");
const Lua = zlua.Lua;

const Player = @This();

lua: ?*Lua = null,
on_tick: ?i32 = null,
current: ?*game.Player = null,
pose: ?game.mob_model.BipedOverride = null,

pub var active: ?*Player = null;

pub const Slot = enum { helmet, chestplate, leggings, boots, held };

pub fn install(self: *Player, lua: *Lua) void {
    self.lua = lua;
    _ = lua.getGlobal("rosebed");
    lua.newTable();
    const functions = [_]struct { name: [:0]const u8, function: zlua.CFn }{
        .{ .name = "on_tick", .function = zlua.wrap(onTick) },
        .{ .name = "position", .function = zlua.wrap(position) },
        .{ .name = "motion", .function = zlua.wrap(motion) },
        .{ .name = "look", .function = zlua.wrap(look) },
        .{ .name = "on_ground", .function = zlua.wrap(onGround) },
        .{ .name = "fall_distance", .function = zlua.wrap(fallDistance) },
        .{ .name = "health", .function = zlua.wrap(health) },
        .{ .name = "equipped", .function = zlua.wrap(equipped) },
        .{ .name = "set_motion", .function = zlua.wrap(setMotion) },
        .{ .name = "set_fall_distance", .function = zlua.wrap(setFallDistance) },
        .{ .name = "damage_equipped", .function = zlua.wrap(damageEquipped) },
        .{ .name = "set_pose", .function = zlua.wrap(setPose) },
    };
    for (functions) |entry| {
        lua.pushLightUserdata(self);
        lua.pushClosure(entry.function, 1);
        lua.setField(-2, entry.name);
    }
    lua.setField(-2, "player");
    lua.pop(1);
    active = self;
}

pub fn steer(player: *game.Player, _: *const world.World, jump: bool, sneak: bool) bool {
    const self = active orelse return false;
    const lua = self.lua orelse return false;
    const ref = self.on_tick orelse return false;

    const outer = self.current;
    self.current = player;
    defer self.current = outer;

    _ = lua.getIndexRaw(zlua.registry_index, ref);
    lua.pushBoolean(jump);
    lua.pushBoolean(sneak);
    lua.protectedCall(.{ .args = 2, .results = 1 }) catch {
        std.log.warn("a mod player tick failed and is switched off: {s}", .{lua.toString(-1) catch "(no message)"});
        lua.pop(1);
        self.on_tick = null;
        return false;
    };
    const claimed = lua.toBoolean(-1);
    lua.pop(1);
    return claimed;
}

fn api(lua: *Lua) *Player {
    return @ptrCast(@alignCast(@constCast(lua.toPointer(Lua.upvalueIndex(1)).?)));
}

fn steered(lua: *Lua) *game.Player {
    return api(lua).current orelse lua.raiseErrorStr("the player is only reached from rosebed.player.on_tick", .{});
}

fn onTick(lua: *Lua) i32 {
    const self = api(lua);
    lua.checkType(1, .function);
    if (self.on_tick) |old| lua.unref(zlua.registry_index, old);
    lua.pushValue(1);
    self.on_tick = lua.ref(zlua.registry_index);
    return 0;
}

fn position(lua: *Lua) i32 {
    const player = steered(lua);
    lua.pushNumber(player.base.position.x);
    lua.pushNumber(player.base.position.y);
    lua.pushNumber(player.base.position.z);
    return 3;
}

fn motion(lua: *Lua) i32 {
    const player = steered(lua);
    lua.pushNumber(player.base.motion.x);
    lua.pushNumber(player.base.motion.y);
    lua.pushNumber(player.base.motion.z);
    return 3;
}

fn look(lua: *Lua) i32 {
    const player = steered(lua);
    lua.pushNumber(player.yaw);
    lua.pushNumber(player.pitch);
    return 2;
}

fn onGround(lua: *Lua) i32 {
    lua.pushBoolean(steered(lua).base.on_ground);
    return 1;
}

fn fallDistance(lua: *Lua) i32 {
    lua.pushNumber(steered(lua).fall_distance);
    return 1;
}

fn health(lua: *Lua) i32 {
    const player = steered(lua);
    lua.pushInteger(player.health);
    lua.pushInteger(game.Player.max_health);
    return 2;
}

fn slotArgument(lua: *Lua, arg: i32) Slot {
    const name = lua.checkString(arg);
    return std.meta.stringToEnum(Slot, name) orelse
        lua.argError(arg, "a slot is 'helmet', 'chestplate', 'leggings', 'boots' or 'held'");
}

fn stackAt(player: *game.Player, slot: Slot) *?game.Inventory.ItemStack {
    return switch (slot) {
        .helmet => player.inventory.armorSlot(.helmet),
        .chestplate => player.inventory.armorSlot(.chestplate),
        .leggings => player.inventory.armorSlot(.leggings),
        .boots => player.inventory.armorSlot(.boots),
        .held => &player.inventory.slots[player.inventory.selected],
    };
}

fn equipped(lua: *Lua) i32 {
    const player = steered(lua);
    const stack = stackAt(player, slotArgument(lua, 1)).* orelse {
        lua.pushNil();
        return 1;
    };
    _ = lua.pushString(switch (stack.id) {
        .block => |id| id.def().key,
        .item => |id| id.def().key,
    });
    lua.pushInteger(stack.count);
    lua.pushInteger(stack.meta);
    return 3;
}

fn setMotion(lua: *Lua) i32 {
    const player = steered(lua);
    player.base.motion.x = finite(lua, 1);
    player.base.motion.y = finite(lua, 2);
    player.base.motion.z = finite(lua, 3);
    return 0;
}

fn setFallDistance(lua: *Lua) i32 {
    const player = steered(lua);
    const distance = finite(lua, 1);
    if (distance < 0) lua.argError(1, "a fall distance cannot be negative");
    player.fall_distance = @floatCast(distance);
    return 0;
}

fn damageEquipped(lua: *Lua) i32 {
    const player = steered(lua);
    const slot = stackAt(player, slotArgument(lua, 1));
    const amount = std.math.cast(u16, lua.optInteger(2) orelse 1) orelse lua.argError(2, "the wear is out of range");
    if (slot.*) |*stack| {
        stack.damage(amount);
        if (stack.count == 0) {
            slot.* = null;
            lua.pushBoolean(true);
            return 1;
        }
    }
    lua.pushBoolean(false);
    return 1;
}

fn setPose(lua: *Lua) i32 {
    const self = api(lua);
    if (lua.isNoneOrNil(1)) {
        self.pose = null;
        return 0;
    }
    lua.checkType(1, .table);

    var turned: game.mob_model.BipedOverride = .{
        .pitch = poseAngle(lua, "pitch"),
        .roll = poseAngle(lua, "roll"),
        .spin = poseAngle(lua, "spin"),
        .lift = poseAngle(lua, "lift"),
    };

    if (lua.getField(1, "limbs") != .nil) {
        if (lua.typeOf(-1) != .table) lua.raiseErrorStr("'limbs' turns each limb it names", .{});
        const limbs = lua.getTop();
        lua.pushNil();
        while (lua.next(limbs)) {
            if (lua.typeOf(-2) != .string) lua.raiseErrorStr("a limb is named", .{});
            const name = lua.toString(-2) catch unreachable;
            const limb = std.meta.stringToEnum(game.mob_model.Limb, name) orelse
                lua.raiseErrorStr("'%s' is not a limb the player has", .{name.ptr});
            turned.limbs[@intFromEnum(limb)] = limbAngles(lua, name);
            lua.pop(1);
        }
    }
    lua.pop(1);

    self.pose = turned;
    return 0;
}

fn poseAngle(lua: *Lua, name: [:0]const u8) f32 {
    defer lua.pop(1);
    if (lua.getField(1, name) == .nil) return 0;
    if (lua.typeOf(-1) != .number) lua.raiseErrorStr("'%s' must be a number", .{name.ptr});
    const value: f32 = @floatCast(lua.toNumber(-1) catch unreachable);
    if (!std.math.isFinite(value)) lua.raiseErrorStr("'%s' must be a finite number", .{name.ptr});
    return value;
}

fn limbAngles(lua: *Lua, name: [:0]const u8) [3]f32 {
    if (lua.typeOf(-1) != .table) lua.raiseErrorStr("'%s' turns by a list of three angles", .{name.ptr});
    const list = lua.getTop();
    var out: [3]f32 = @splat(0);
    for (&out, 0..) |*angle, slot| {
        if (lua.getIndex(list, @as(i64, @intCast(slot + 1))) != .number) {
            lua.raiseErrorStr("'%s' turns by a list of three angles", .{name.ptr});
        }
        angle.* = @floatCast(lua.toNumber(-1) catch unreachable);
        if (!std.math.isFinite(angle.*)) lua.raiseErrorStr("'%s' turns by a finite angle", .{name.ptr});
        lua.pop(1);
    }
    return out;
}

fn finite(lua: *Lua, arg: i32) f64 {
    const value = lua.checkNumber(arg);
    if (!std.math.isFinite(value)) lua.argError(arg, "must be a finite number");
    return value;
}

const Vm = @import("Vm.zig");

const Harness = struct {
    vm: Vm,
    api: Player,
    world_map: world.World,
    player: game.Player,

    fn init(self: *Harness) !void {
        self.vm = try .init(std.testing.allocator);
        self.vm.lua.newTable();
        self.vm.lua.setGlobal("rosebed");
        self.api = .{};
        self.api.install(self.vm.lua);
        game.Player.steer = steer;

        self.world_map = .init(std.testing.allocator);
        var chunk_x: i32 = -1;
        while (chunk_x <= 1) : (chunk_x += 1) {
            var chunk_z: i32 = -1;
            while (chunk_z <= 1) : (chunk_z += 1) _ = try self.world_map.createChunk(chunk_x, chunk_z);
        }
        self.player = .spawn(.init(8, 80, 8));
    }

    fn deinit(self: *Harness) void {
        game.Player.steer = null;
        active = null;
        self.world_map.deinit();
        self.vm.deinit();
    }

    fn tick(self: *Harness, jump: bool) void {
        self.player.tick(&self.world_map, 0, 0, jump, false);
    }
};

test "with no player hook the fall is exactly the one vanilla takes" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var bare: game.Player = .spawn(.init(8, 80, 8));

    for (0..20) |_| {
        harness.tick(false);
        bare.tick(&harness.world_map, 0, 0, false, false);
    }
    try std.testing.expectEqual(bare.base.position.y, harness.player.base.position.y);
    try std.testing.expectEqual(bare.base.motion.y, harness.player.base.motion.y);
}

test "a hook that claims the tick flies the player instead of letting it fall" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try harness.vm.exec("=test",
        \\gliding = false
        \\rosebed.player.on_tick(function(jump)
        \\  if jump and not rosebed.player.on_ground() then gliding = true end
        \\  if not gliding then return false end
        \\  rosebed.player.set_motion(0.4, -0.05, 0)
        \\  rosebed.player.set_fall_distance(0)
        \\  return true
        \\end)
    );

    harness.tick(false);
    const fell = harness.player.base.motion.y;
    try std.testing.expect(fell < -0.07);

    harness.tick(true);
    try std.testing.expectApproxEqAbs(@as(f64, -0.05), harness.player.base.motion.y, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), harness.player.base.motion.x, 1.0e-9);

    const before = harness.player.base.position;
    harness.tick(false);
    try std.testing.expectApproxEqAbs(@as(f64, -0.05), harness.player.base.motion.y, 1.0e-9);
    try std.testing.expect(harness.player.base.position.x > before.x);
    try std.testing.expect(harness.player.base.position.y < before.y);
    try std.testing.expect(before.y - harness.player.base.position.y < 0.1);

    for (0..100) |_| {
        harness.tick(false);
        try std.testing.expect(harness.player.fall_distance < game.Player.safe_fall_distance);
    }
    try std.testing.expect(harness.player.base.position.x - before.x > 30);
    try std.testing.expect(before.y - harness.player.base.position.y < 6);
}

test "a hook that does not claim the tick leaves the fall alone" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try harness.vm.exec("=test", "seen = 0 rosebed.player.on_tick(function() seen = seen + 1 return false end)");
    for (0..5) |_| harness.tick(false);

    try std.testing.expect(harness.player.base.motion.y < -0.3);
    try std.testing.expectEqual(zlua.LuaType.number, harness.vm.lua.getGlobal("seen"));
    try std.testing.expectEqual(@as(i64, 5), harness.vm.lua.toInteger(-1) catch unreachable);
    harness.vm.lua.pop(1);
}

test "a player hook that fails is switched off and the fall carries on" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try harness.vm.exec("=test", "rosebed.player.on_tick(function() error('boom') end)");
    harness.tick(false);
    try std.testing.expect(harness.api.on_tick == null);
    try std.testing.expect(harness.player.base.motion.y < -0.07);
}

test "the player is out of reach outside its own hook" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try std.testing.expectError(error.ScriptFailed, harness.vm.exec("=test", "rosebed.player.position()"));
    try std.testing.expect(std.mem.endsWith(u8, harness.vm.errorMessage(), "the player is only reached from rosebed.player.on_tick"));
}

test "a hook reads what the player wears and wears it out" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    harness.player.inventory.armorSlot(.chestplate).* = .{ .id = .{ .item = .chestplate_iron }, .count = 1 };
    harness.player.inventory.slots[0] = .{ .id = .{ .item = .diamond }, .count = 3, .meta = 0 };

    try harness.vm.exec("=test",
        \\rosebed.player.on_tick(function()
        \\  worn, count, meta = rosebed.player.equipped("chestplate")
        \\  held = rosebed.player.equipped("held")
        \\  boots = rosebed.player.equipped("boots")
        \\  broke = rosebed.player.damage_equipped("chestplate", 4)
        \\  return false
        \\end)
    );
    harness.tick(false);

    try std.testing.expectEqual(zlua.LuaType.string, harness.vm.lua.getGlobal("worn"));
    try std.testing.expectEqualStrings("chestplate_iron", try harness.vm.lua.toString(-1));
    harness.vm.lua.pop(1);
    try std.testing.expectEqual(zlua.LuaType.string, harness.vm.lua.getGlobal("held"));
    harness.vm.lua.pop(1);
    try std.testing.expectEqual(zlua.LuaType.nil, harness.vm.lua.getGlobal("boots"));
    harness.vm.lua.pop(1);
    try std.testing.expectEqual(@as(u16, 4), harness.player.inventory.armorSlot(.chestplate).*.?.meta);
}

test "a hook lays the player flat and folds the limbs it names" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try harness.vm.exec("=test",
        \\rosebed.player.on_tick(function()
        \\  rosebed.player.set_pose {
        \\    pitch = 1.5,
        \\    lift = 0.25,
        \\    limbs = {
        \\      right_arm = { -0.2, 0, -1.4 },
        \\      left_arm = { -0.2, 0, 1.4 },
        \\      right_leg = { 0.1, 0, 0 },
        \\      left_leg = { 0.1, 0, 0 },
        \\    },
        \\  }
        \\  return false
        \\end)
    );
    harness.tick(false);

    const pose = harness.api.pose.?;
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), pose.pitch, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), pose.lift, 1.0e-6);
    try std.testing.expectEqual(@as(f32, 0), pose.roll);

    const limbs = game.mob_model.Limb;
    try std.testing.expectEqual([3]f32{ -0.2, 0, -1.4 }, pose.limbs[@intFromEnum(limbs.right_arm)].?);
    try std.testing.expectEqual([3]f32{ -0.2, 0, 1.4 }, pose.limbs[@intFromEnum(limbs.left_arm)].?);
    try std.testing.expectEqual([3]f32{ 0.1, 0, 0 }, pose.limbs[@intFromEnum(limbs.right_leg)].?);
    try std.testing.expectEqual([3]f32{ 0.1, 0, 0 }, pose.limbs[@intFromEnum(limbs.left_leg)].?);
    try std.testing.expect(pose.limbs[@intFromEnum(limbs.head)] == null);
    try std.testing.expect(pose.limbs[@intFromEnum(limbs.body)] == null);
}

test "a pose is dropped once the mod stops asking for one" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try harness.vm.exec("=test",
        \\standing = false
        \\rosebed.player.on_tick(function()
        \\  if standing then rosebed.player.set_pose() else rosebed.player.set_pose { roll = 0.5 } end
        \\  return false
        \\end)
    );
    harness.tick(false);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), harness.api.pose.?.roll, 1.0e-6);

    try harness.vm.exec("=test", "standing = true");
    harness.tick(false);
    try std.testing.expect(harness.api.pose == null);
}

test "a pose that names something the player has not got is refused" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try harness.vm.exec("=test",
        \\failure = nil
        \\rosebed.player.on_tick(function()
        \\  local ok, message = pcall(function() rosebed.player.set_pose { limbs = { tail = { 0, 0, 0 } } } end)
        \\  failure = message
        \\  return false
        \\end)
    );
    harness.tick(false);

    try std.testing.expectEqual(zlua.LuaType.string, harness.vm.lua.getGlobal("failure"));
    try std.testing.expect(std.mem.endsWith(u8, try harness.vm.lua.toString(-1), "'tail' is not a limb the player has"));
    harness.vm.lua.pop(1);
    try std.testing.expect(harness.api.on_tick != null);
}
