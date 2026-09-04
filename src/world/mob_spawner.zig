const std = @import("std");

const BlockPos = @import("BlockPos.zig");
const nbt = @import("nbt.zig");
const tile = @import("tile.zig");

pub const id_key = "MobSpawner";
pub const default_mob = "Pig";
pub const max_mob_name = 32;
pub const initial_delay: i32 = 20;
pub const idle_delay: i32 = -1;
pub const delay_floor: i32 = 200;
pub const delay_spread: i32 = 600;
pub const spin_numerator: f64 = 1000.0;
pub const spin_denominator: f64 = 200.0;

fn nameBuffer(comptime name: []const u8) [max_mob_name]u8 {
    var out: [max_mob_name]u8 = @splat(0);
    for (name, 0..) |char, index| out[index] = char;
    return out;
}

pub const MobSpawner = struct {
    mob: [max_mob_name]u8 = nameBuffer(default_mob),
    mob_length: u8 = default_mob.len,
    delay: i32 = initial_delay,
    yaw: f64 = 0,
    prev_yaw: f64 = 0,

    pub fn mobName(self: *const MobSpawner) []const u8 {
        return self.mob[0..self.mob_length];
    }

    pub fn setMobName(self: *MobSpawner, name: []const u8) void {
        const kept = @min(name.len, max_mob_name);
        @memcpy(self.mob[0..kept], name[0..kept]);
        self.mob_length = @intCast(kept);
    }

    pub fn spin(self: *MobSpawner) void {
        self.prev_yaw = self.yaw;
        self.yaw += spin_numerator / (@as(f64, @floatFromInt(self.delay)) + spin_denominator);
        while (self.yaw > 360.0) {
            self.yaw -= 360.0;
            self.prev_yaw -= 360.0;
        }
    }

    pub fn renderYaw(self: MobSpawner, partial_ticks: f64) f64 {
        return self.prev_yaw + (self.yaw - self.prev_yaw) * partial_ticks;
    }
};

const put = nbt.putDuped;

pub fn store(gpa: std.mem.Allocator, pos: BlockPos, state: MobSpawner) !nbt.Tag {
    var compound: nbt.Compound = .{};
    errdefer {
        var owned: nbt.Tag = .{ .compound = compound };
        nbt.deinit(gpa, &owned);
    }

    try tile.header(gpa, &compound, id_key, pos);
    try put(gpa, &compound, "EntityId", .{ .string = try gpa.dupe(u8, state.mobName()) });
    try put(gpa, &compound, "Delay", .{ .short = @intCast(std.math.clamp(state.delay, std.math.minInt(i16), std.math.maxInt(i16))) });

    return .{ .compound = compound };
}

pub const Placed = struct {
    pos: BlockPos,
    state: MobSpawner,
};

pub fn isMobSpawner(compound: nbt.Compound) bool {
    return tile.isKind(compound, id_key);
}

fn stringField(compound: nbt.Compound, key: []const u8) ?[]const u8 {
    return switch (compound.get(key) orelse return null) {
        .string => |value| value,
        else => null,
    };
}

fn shortField(compound: nbt.Compound, key: []const u8) ?i16 {
    return switch (compound.get(key) orelse return null) {
        .short => |value| value,
        else => null,
    };
}

pub fn load(compound: nbt.Compound) ?Placed {
    if (!isMobSpawner(compound)) return null;

    var state: MobSpawner = .{ .delay = shortField(compound, "Delay") orelse initial_delay };
    state.setMobName(stringField(compound, "EntityId") orelse default_mob);

    return .{
        .pos = tile.position(compound) orelse return null,
        .state = state,
    };
}

test "a fresh spawner is a pig on a twenty tick fuse, the way TileEntityMobSpawner starts" {
    const state: MobSpawner = .{};
    try std.testing.expectEqualStrings("Pig", state.mobName());
    try std.testing.expectEqual(initial_delay, state.delay);
}

test "a spawner keeps its mob and its delay across a round trip" {
    const gpa = std.testing.allocator;

    var state: MobSpawner = .{ .delay = 417 };
    state.setMobName("Skeleton");

    var stored = try store(gpa, .init(3, 40, -7), state);
    defer nbt.deinit(gpa, &stored);

    const placed = load(stored.compound).?;
    try std.testing.expectEqual(@as(i32, 3), placed.pos.x);
    try std.testing.expectEqual(@as(i32, 40), placed.pos.y);
    try std.testing.expectEqual(@as(i32, -7), placed.pos.z);
    try std.testing.expectEqualStrings("Skeleton", placed.state.mobName());
    try std.testing.expectEqual(@as(i32, 417), placed.state.delay);
}

test "a spawner nobody has ever ticked writes the negative delay vanilla leaves in place" {
    const gpa = std.testing.allocator;

    var stored = try store(gpa, .init(0, 0, 0), .{ .delay = idle_delay });
    defer nbt.deinit(gpa, &stored);

    try std.testing.expectEqual(@as(i32, idle_delay), load(stored.compound).?.state.delay);
}

test "a spawner NBT that names no mob loads as the pig the field defaults to" {
    const gpa = std.testing.allocator;

    var compound: nbt.Compound = .{};
    defer {
        var owned: nbt.Tag = .{ .compound = compound };
        nbt.deinit(gpa, &owned);
    }
    try put(gpa, &compound, "id", .{ .string = try gpa.dupe(u8, id_key) });
    try put(gpa, &compound, "x", .{ .int = 1 });
    try put(gpa, &compound, "y", .{ .int = 2 });
    try put(gpa, &compound, "z", .{ .int = 3 });

    const placed = load(compound).?;
    try std.testing.expectEqualStrings(default_mob, placed.state.mobName());
    try std.testing.expectEqual(initial_delay, placed.state.delay);
}

test "the spin winds up faster the shorter the fuse, and wraps both angles together" {
    var slow: MobSpawner = .{ .delay = 800 };
    var fast: MobSpawner = .{ .delay = 0 };

    slow.spin();
    fast.spin();
    try std.testing.expect(fast.yaw > slow.yaw);

    var wrapping: MobSpawner = .{ .delay = 0, .yaw = 359.0, .prev_yaw = 359.0 };
    wrapping.spin();
    try std.testing.expect(wrapping.yaw <= 360.0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), wrapping.yaw - wrapping.prev_yaw - spin_numerator / spin_denominator, 1.0e-9);
}

test "the render yaw walks from the previous angle to the current one" {
    const state: MobSpawner = .{ .prev_yaw = 10.0, .yaw = 20.0 };
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), state.renderYaw(0.0), 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 15.0), state.renderYaw(0.5), 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 20.0), state.renderYaw(1.0), 1.0e-9);
}

test "a mob name longer than the buffer is cut rather than overrunning it" {
    var state: MobSpawner = .{};
    state.setMobName("A" ** (max_mob_name + 8));
    try std.testing.expectEqual(@as(usize, max_mob_name), state.mobName().len);
}
