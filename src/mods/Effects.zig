const std = @import("std");

const game = @import("game");
const math = @import("math");
const world = @import("world");
const zlua = @import("zlua");
const Lua = zlua.Lua;

const bind = @import("bind.zig");
const Vm = @import("Vm.zig");

const Effects = @This();

pub const Effect = union(enum) {
    sound: struct {
        sound: world.sound.Sound,
        at: math.Vec3,
        volume: f32,
        pitch: f32,
    },
    particle: struct {
        kind: game.Particle.Vanilla,
        at: math.Vec3,
        drift: math.Vec3,
    },
    explode: struct {
        at: math.Vec3,
        size: f32,
        flaming: bool,
    },
    spawn: struct {
        type_id: game.mob.Id,
        at: math.Vec3,
    },
};

gpa: std.mem.Allocator,
outgoing: std.ArrayList(Effect) = .empty,

pub var active: ?*Effects = null;

pub fn install(self: *Effects, lua: *Lua) void {
    _ = lua.getGlobal("rosebed");
    bind.fields(lua, self, &.{
        .{ .name = "play_sound", .function = zlua.wrap(playSound) },
        .{ .name = "particle", .function = zlua.wrap(particle) },
        .{ .name = "explode", .function = zlua.wrap(explode) },
        .{ .name = "spawn", .function = zlua.wrap(spawn) },
    });
    lua.pop(1);
    active = self;
}

pub fn deinit(self: *Effects) void {
    self.outgoing.deinit(self.gpa);
    if (active == self) active = null;
}

pub fn take(self: *Effects) []Effect {
    return self.outgoing.toOwnedSlice(self.gpa) catch &.{};
}

pub fn release(self: *Effects, effects: []Effect) void {
    self.gpa.free(effects);
}

fn context(lua: *Lua) *Effects {
    return bind.upvalue(Effects, lua);
}

fn place(lua: *Lua, first: i32) math.Vec3 {
    return .init(lua.checkNumber(first), lua.checkNumber(first + 1), lua.checkNumber(first + 2));
}

fn playSound(lua: *Lua) i32 {
    const self = context(lua);
    const sound = world.sound.byKey(lua.checkString(1)) orelse lua.argError(1, "no sound is named that");

    const at = place(lua, 2);
    const volume: f32 = @floatCast(bind.optionalNumber(lua, 5, 1.0));
    const pitch: f32 = @floatCast(bind.optionalNumber(lua, 6, 1.0));

    self.outgoing.append(self.gpa, .{ .sound = .{
        .sound = sound,
        .at = at,
        .volume = volume,
        .pitch = pitch,
    } }) catch lua.raiseErrorStr("out of memory", .{});
    return 0;
}

fn particle(lua: *Lua) i32 {
    const self = context(lua);
    const kind = game.Particle.Vanilla.fromKey(lua.checkString(1)) orelse
        lua.argError(1, "no particle is named that");

    const at = place(lua, 2);
    const drift: math.Vec3 = .init(
        bind.optionalNumber(lua, 5, 0),
        bind.optionalNumber(lua, 6, 0),
        bind.optionalNumber(lua, 7, 0),
    );

    self.outgoing.append(self.gpa, .{ .particle = .{
        .kind = kind,
        .at = at,
        .drift = drift,
    } }) catch lua.raiseErrorStr("out of memory", .{});
    return 0;
}

fn explode(lua: *Lua) i32 {
    const self = context(lua);
    const at = place(lua, 1);
    const size = lua.checkNumber(4);
    if (size <= 0) lua.argError(4, "an explosion needs a size");
    const flaming = !lua.isNoneOrNil(5) and lua.toBoolean(5);

    self.outgoing.append(self.gpa, .{ .explode = .{
        .at = at,
        .size = @floatCast(size),
        .flaming = flaming,
    } }) catch lua.raiseErrorStr("out of memory", .{});
    return 0;
}

fn spawn(lua: *Lua) i32 {
    const self = context(lua);
    const type_id = game.mob.find(lua.checkString(1)) orelse lua.argError(1, "no mob is named that");
    const at = place(lua, 2);

    self.outgoing.append(self.gpa, .{ .spawn = .{
        .type_id = type_id,
        .at = at,
    } }) catch lua.raiseErrorStr("out of memory", .{});
    return 0;
}

const Harness = struct {
    vm: Vm,
    api: Effects,

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

test "a mod queues the sounds and particles it asks for, in order" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try harness.vm.exec("=test",
        \\rosebed.play_sound("random.explode", 8.5, 64, -3.25, 4, 0.7)
        \\rosebed.play_sound("random.pop", 1, 2, 3)
        \\rosebed.particle("heart", 1.5, 2.5, 3.5)
        \\rosebed.particle("reddust", 0, 0, 0, 1, 0.5, 0.25)
    );

    const queued = harness.api.take();
    defer harness.api.release(queued);
    try std.testing.expectEqual(@as(usize, 4), queued.len);

    try std.testing.expectEqualStrings("random.explode", queued[0].sound.sound.key);
    try std.testing.expectEqual(@as(f64, 8.5), queued[0].sound.at.x);
    try std.testing.expectEqual(@as(f32, 4), queued[0].sound.volume);
    try std.testing.expectEqual(@as(f32, 0.7), queued[0].sound.pitch);

    try std.testing.expectEqualStrings("random.pop", queued[1].sound.sound.key);
    try std.testing.expectEqual(@as(f32, 1), queued[1].sound.volume);
    try std.testing.expectEqual(@as(f32, 1), queued[1].sound.pitch);

    try std.testing.expectEqual(game.Particle.Vanilla.heart, queued[2].particle.kind);
    try std.testing.expectEqual(@as(f64, 2.5), queued[2].particle.at.y);
    try std.testing.expectEqual(@as(f64, 0), queued[2].particle.drift.x);

    try std.testing.expectEqual(game.Particle.Vanilla.reddust, queued[3].particle.kind);
    try std.testing.expectEqual(@as(f64, 0.5), queued[3].particle.drift.y);

    try std.testing.expectEqual(@as(usize, 0), harness.api.take().len);
}

test "an explosion is queued with the size and the fire the mod asked for" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try harness.vm.exec("=test",
        \\rosebed.explode(8, 64, 8, 4)
        \\rosebed.explode(0, 0, 0, 1.5, true)
    );

    const queued = harness.api.take();
    defer harness.api.release(queued);
    try std.testing.expectEqual(@as(usize, 2), queued.len);
    try std.testing.expectEqual(@as(f64, 64), queued[0].explode.at.y);
    try std.testing.expectEqual(@as(f32, 4), queued[0].explode.size);
    try std.testing.expect(!queued[0].explode.flaming);
    try std.testing.expectEqual(@as(f32, 1.5), queued[1].explode.size);
    try std.testing.expect(queued[1].explode.flaming);

    try std.testing.expectError(error.ScriptFailed, harness.vm.exec("=test",
        \\rosebed.explode(0, 0, 0, 0)
    ));
    try std.testing.expect(std.mem.indexOf(u8, harness.vm.errorMessage(), "an explosion needs a size") != null);
}

test "a mob is queued by the name it is registered under" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try harness.vm.exec("=test",
        \\rosebed.spawn("Pig", 8.5, 64, -3.5)
    );

    const queued = harness.api.take();
    defer harness.api.release(queued);
    try std.testing.expectEqual(@as(usize, 1), queued.len);
    try std.testing.expectEqual(game.mob.pig, queued[0].spawn.type_id);
    try std.testing.expectEqual(@as(f64, -3.5), queued[0].spawn.at.z);

    try std.testing.expectError(error.ScriptFailed, harness.vm.exec("=test",
        \\rosebed.spawn("Wyvern", 0, 0, 0)
    ));
    try std.testing.expect(std.mem.indexOf(u8, harness.vm.errorMessage(), "no mob is named that") != null);
}

test "a sound or a particle nothing is named after is refused as it is asked for" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try std.testing.expectError(error.ScriptFailed, harness.vm.exec("=test",
        \\rosebed.play_sound("random.nothing", 0, 0, 0)
    ));
    try std.testing.expect(std.mem.indexOf(u8, harness.vm.errorMessage(), "no sound is named that") != null);

    try std.testing.expectError(error.ScriptFailed, harness.vm.exec("=test",
        \\rosebed.particle("sparkle", 0, 0, 0)
    ));
    try std.testing.expect(std.mem.indexOf(u8, harness.vm.errorMessage(), "no particle is named that") != null);

    try std.testing.expectEqual(@as(usize, 0), harness.api.take().len);
}
