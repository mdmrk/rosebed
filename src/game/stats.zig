const std = @import("std");

const world = @import("world");

const achievements = @import("achievements.zig");
const crafting = @import("crafting.zig");

pub const Unit = enum { count, time, distance };

pub const General = enum {
    start_game,
    create_world,
    load_world,
    join_multiplayer,
    leave_game,
    minutes_played,
    distance_walked,
    distance_swum,
    distance_fallen,
    distance_climbed,
    distance_flown,
    distance_dove,
    distance_by_minecart,
    distance_by_boat,
    distance_by_pig,
    jump,
    drop,
    damage_dealt,
    damage_taken,
    deaths,
    mob_kills,
    player_kills,
    fish_caught,

    pub fn statId(self: General) u32 {
        return switch (self) {
            .start_game => 1000,
            .create_world => 1001,
            .load_world => 1002,
            .join_multiplayer => 1003,
            .leave_game => 1004,
            .minutes_played => 1100,
            .distance_walked => 2000,
            .distance_swum => 2001,
            .distance_fallen => 2002,
            .distance_climbed => 2003,
            .distance_flown => 2004,
            .distance_dove => 2005,
            .distance_by_minecart => 2006,
            .distance_by_boat => 2007,
            .distance_by_pig => 2008,
            .jump => 2010,
            .drop => 2011,
            .damage_dealt => 2020,
            .damage_taken => 2021,
            .deaths => 2022,
            .mob_kills => 2023,
            .player_kills => 2024,
            .fish_caught => 2025,
        };
    }

    pub fn label(self: General) []const u8 {
        return switch (self) {
            .start_game => "Times played",
            .create_world => "Worlds played",
            .load_world => "Saves loaded",
            .join_multiplayer => "Multiplayer joins",
            .leave_game => "Games quit",
            .minutes_played => "Minutes Played",
            .distance_walked => "Distance Walked",
            .distance_swum => "Distance Swum",
            .distance_fallen => "Distance Fallen",
            .distance_climbed => "Distance Climbed",
            .distance_flown => "Distance Flown",
            .distance_dove => "Distance Dove",
            .distance_by_minecart => "Distance by Minecart",
            .distance_by_boat => "Distance by Boat",
            .distance_by_pig => "Distance by Pig",
            .jump => "Jumps",
            .drop => "Items Dropped",
            .damage_dealt => "Damage Dealt",
            .damage_taken => "Damage Taken",
            .deaths => "Number of Deaths",
            .mob_kills => "Mob Kills",
            .player_kills => "Player Kills",
            .fish_caught => "Fish Caught",
        };
    }

    pub fn unit(self: General) Unit {
        return switch (self) {
            .minutes_played => .time,
            .distance_walked,
            .distance_swum,
            .distance_fallen,
            .distance_climbed,
            .distance_flown,
            .distance_dove,
            .distance_by_minecart,
            .distance_by_boat,
            .distance_by_pig,
            => .distance,
            else => .count,
        };
    }
};

pub const Kind = enum { mined, crafted, used, depleted };

pub const Key = union(enum) {
    general: General,
    achievement: achievements.Id,
    mined: world.Id,
    crafted: world.Id,
    used: world.Id,
    depleted: world.Id,
};

pub fn key(kind: Kind, id: world.Id) Key {
    return switch (kind) {
        .mined => .{ .mined = id },
        .crafted => .{ .crafted = id },
        .used => .{ .used = id },
        .depleted => .{ .depleted = id },
    };
}

const thing_stat_base: u32 = 16777216;
const thing_stat_stride: u32 = 65536;

pub fn idNumber(id: world.Id) u16 {
    return switch (id) {
        .block => |block| @intFromEnum(block),
        .item => |item| @intFromEnum(item),
    };
}

fn idFromNumber(raw: u16) world.Id {
    if (raw < 256) return .{ .block = @enumFromInt(@as(u8, @intCast(raw))) };
    return .{ .item = @enumFromInt(raw) };
}

pub fn statId(stat: Key) u32 {
    return switch (stat) {
        .general => |general| general.statId(),
        .achievement => |id| id.statId(),
        .mined => |id| thing_stat_base + idNumber(id),
        .crafted => |id| thing_stat_base + thing_stat_stride + idNumber(id),
        .used => |id| thing_stat_base + 2 * thing_stat_stride + idNumber(id),
        .depleted => |id| thing_stat_base + 3 * thing_stat_stride + idNumber(id),
    };
}

pub fn keyFromStatId(id: u32) ?Key {
    if (achievements.fromStatId(id)) |achievement| return .{ .achievement = achievement };
    if (id < thing_stat_base) {
        for (std.enums.values(General)) |general| {
            if (general.statId() == id) return .{ .general = general };
        }
        return null;
    }

    const offset = id - thing_stat_base;
    const raw = offset % thing_stat_stride;
    const thing = idFromNumber(@intCast(raw));
    return switch (offset / thing_stat_stride) {
        0 => if (raw < 256) .{ .mined = thing } else null,
        1 => .{ .crafted = thing },
        2 => .{ .used = thing },
        3 => .{ .depleted = thing },
        else => null,
    };
}

pub fn canonical(id: world.Id) world.Id {
    const block = switch (id) {
        .block => |value| value,
        .item => return id,
    };
    return .{ .block = switch (block) {
        .grass => .dirt,
        .mushroom_red => .mushroom_brown,
        .jack_o_lantern => .pumpkin,
        else => block,
    } };
}

pub fn tracksMining(id: world.Id) bool {
    const block = switch (id) {
        .block => |value| value,
        .item => return false,
    };
    return switch (block) {
        .air,
        .bedrock,
        .flowing_water,
        .stationary_water,
        .flowing_lava,
        .stationary_lava,
        .leaves,
        .mob_spawner,
        .reed,
        .door_wood,
        .door_iron,
        .trapdoor,
        => false,
        else => block.displayName(0).len > 0,
    };
}

pub fn registered(stat: Key) bool {
    return switch (stat) {
        .general, .achievement => true,
        .mined => |id| tracksMining(id),
        .used => true,
        .crafted => |id| crafting.isCraftable(id),
        .depleted => |id| switch (id) {
            .block => false,
            .item => |value| value.isDamageable(),
        },
    };
}

pub const Stats = struct {
    counts: std.AutoHashMapUnmanaged(Key, i32) = .empty,

    pub fn deinit(self: *Stats, gpa: std.mem.Allocator) void {
        self.counts.deinit(gpa);
    }

    pub fn get(self: *const Stats, stat: Key) i32 {
        return self.counts.get(stat) orelse 0;
    }

    pub fn value(self: *const Stats, stat: Key) ?i32 {
        if (!registered(stat)) return null;
        return self.get(stat);
    }

    pub fn add(self: *Stats, gpa: std.mem.Allocator, stat: Key, amount: i32) !void {
        if (amount == 0) return;
        const entry = try self.counts.getOrPut(gpa, stat);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* +|= amount;
    }

    pub fn hasAchievement(self: *const Stats, id: achievements.Id) bool {
        return self.get(.{ .achievement = id }) > 0;
    }

    pub fn canUnlock(self: *const Stats, id: achievements.Id) bool {
        const parent = id.def().parent orelse return true;
        return self.hasAchievement(parent);
    }

    pub fn award(self: *Stats, gpa: std.mem.Allocator, id: achievements.Id) !bool {
        if (!self.canUnlock(id)) return false;
        const fresh = !self.hasAchievement(id);
        try self.add(gpa, .{ .achievement = id }, 1);
        return fresh;
    }

    pub fn mine(self: *Stats, gpa: std.mem.Allocator, block: world.Block) !void {
        const id: world.Id = .{ .block = block };
        if (!tracksMining(id)) return;
        try self.add(gpa, .{ .mined = canonical(id) }, 1);
    }

    pub fn use(self: *Stats, gpa: std.mem.Allocator, id: world.Id) !void {
        try self.add(gpa, .{ .used = canonical(id) }, 1);
    }

    pub fn craft(self: *Stats, gpa: std.mem.Allocator, id: world.Id, count: u8) !void {
        try self.add(gpa, .{ .crafted = canonical(id) }, count);
    }

    pub fn deplete(self: *Stats, gpa: std.mem.Allocator, id: world.Id) !void {
        try self.add(gpa, .{ .depleted = canonical(id) }, 1);
    }
};

fn idLess(_: void, a: world.Id, b: world.Id) bool {
    return idNumber(a) < idNumber(b);
}

const RowSort = struct {
    stats: *const Stats,
    kind: Kind,
    ascending: bool,

    fn less(self: RowSort, a: world.Id, b: world.Id) bool {
        const left = self.stats.value(key(self.kind, a));
        const right = self.stats.value(key(self.kind, b));
        if (left != null or right != null) {
            if (left == null) return false;
            if (right == null) return true;
            if (left.? != right.?) {
                return if (self.ascending) left.? < right.? else left.? > right.?;
            }
        }
        return idNumber(a) < idNumber(b);
    }
};

pub fn sortRows(rows: []world.Id, stats: *const Stats, kind: ?Kind, ascending: bool) void {
    const sort_kind = kind orelse {
        std.mem.sort(world.Id, rows, {}, idLess);
        return;
    };
    const context: RowSort = .{ .stats = stats, .kind = sort_kind, .ascending = ascending };
    std.mem.sort(world.Id, rows, context, RowSort.less);
}

fn collectRows(
    gpa: std.mem.Allocator,
    stats: *const Stats,
    comptime want_blocks: bool,
) ![]world.Id {
    var rows: std.ArrayList(world.Id) = .empty;
    errdefer rows.deinit(gpa);
    var seen: std.AutoHashMapUnmanaged(world.Id, void) = .empty;
    defer seen.deinit(gpa);

    var it = stats.counts.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* <= 0) continue;
        const id = switch (entry.key_ptr.*) {
            .general, .achievement => continue,
            .mined, .crafted, .used, .depleted => |value| value,
        };
        const is_block = id == .block;
        if (is_block != want_blocks) continue;
        if (want_blocks and !tracksMining(id)) continue;
        if ((try seen.getOrPut(gpa, id)).found_existing) continue;
        try rows.append(gpa, id);
    }

    std.mem.sort(world.Id, rows.items, {}, idLess);
    return rows.toOwnedSlice(gpa);
}

pub fn blockRows(gpa: std.mem.Allocator, stats: *const Stats) ![]world.Id {
    return collectRows(gpa, stats, true);
}

pub fn itemRows(gpa: std.mem.Allocator, stats: *const Stats) ![]world.Id {
    return collectRows(gpa, stats, false);
}

fn appendGrouped(buffer: []u8, value: i64) []const u8 {
    var digits: [24]u8 = undefined;
    const text = std.fmt.bufPrint(&digits, "{d}", .{value}) catch return "";
    const negative = text[0] == '-';
    const body = if (negative) text[1..] else text;

    var written: usize = 0;
    if (negative) {
        if (buffer.len == 0) return buffer[0..0];
        buffer[0] = '-';
        written = 1;
    }
    for (body, 0..) |digit, index| {
        if (index > 0 and (body.len - index) % 3 == 0) {
            if (written == buffer.len) return buffer[0..written];
            buffer[written] = ',';
            written += 1;
        }
        if (written == buffer.len) return buffer[0..written];
        buffer[written] = digit;
        written += 1;
    }
    return buffer[0..written];
}

fn javaDouble(buffer: []u8, value: f64) []const u8 {
    const text = std.fmt.bufPrint(buffer, "{d}", .{value}) catch return "";
    if (std.mem.indexOfScalar(u8, text, '.') != null) return text;
    if (text.len + 2 > buffer.len) return text;
    buffer[text.len] = '.';
    buffer[text.len + 1] = '0';
    return buffer[0 .. text.len + 2];
}

pub fn formatValue(buffer: []u8, unit: Unit, value: i32) []const u8 {
    switch (unit) {
        .count => return appendGrouped(buffer, value),
        .time => {
            const seconds = @as(f64, @floatFromInt(value)) / 20.0;
            const minutes = seconds / 60.0;
            const hours = minutes / 60.0;
            const days = hours / 24.0;
            const years = days / 365.0;
            if (years > 0.5) return std.fmt.bufPrint(buffer, "{d:.2} y", .{years}) catch "";
            if (days > 0.5) return std.fmt.bufPrint(buffer, "{d:.2} d", .{days}) catch "";
            if (hours > 0.5) return std.fmt.bufPrint(buffer, "{d:.2} h", .{hours}) catch "";
            if (minutes > 0.5) return std.fmt.bufPrint(buffer, "{d:.2} m", .{minutes}) catch "";
            var number: [32]u8 = undefined;
            return std.fmt.bufPrint(buffer, "{s} s", .{javaDouble(&number, seconds)}) catch "";
        },
        .distance => {
            const meters = @as(f64, @floatFromInt(value)) / 100.0;
            const kilometers = meters / 1000.0;
            if (kilometers > 0.5) return std.fmt.bufPrint(buffer, "{d:.2} km", .{kilometers}) catch "";
            if (meters > 0.5) return std.fmt.bufPrint(buffer, "{d:.2} m", .{meters}) catch "";
            return std.fmt.bufPrint(buffer, "{d} cm", .{value}) catch "";
        },
    }
}

pub fn displayName(id: world.Id) []const u8 {
    return switch (id) {
        .block => |block| block.displayName(0),
        .item => |item| item.displayName(0),
    };
}

test "general stat ids match StatList's registrations" {
    try std.testing.expectEqual(@as(u32, 1000), General.start_game.statId());
    try std.testing.expectEqual(@as(u32, 1100), General.minutes_played.statId());
    try std.testing.expectEqual(@as(u32, 2000), General.distance_walked.statId());
    try std.testing.expectEqual(@as(u32, 2011), General.drop.statId());
    try std.testing.expectEqual(@as(u32, 2025), General.fish_caught.statId());
}

test "per-block stat ids sit at the four bases StatList uses" {
    const stone: world.Id = .{ .block = .stone };
    try std.testing.expectEqual(@as(u32, 16777216 + 1), statId(.{ .mined = stone }));
    try std.testing.expectEqual(@as(u32, 16842752 + 1), statId(.{ .crafted = stone }));
    try std.testing.expectEqual(@as(u32, 16908288 + 1), statId(.{ .used = stone }));
    try std.testing.expectEqual(@as(u32, 16973824 + 1), statId(.{ .depleted = stone }));

    const diamond: world.Id = .{ .item = .diamond };
    try std.testing.expectEqual(@as(u32, 16842752 + 264), statId(.{ .crafted = diamond }));
}

test "every stat id round-trips back to its key" {
    for (std.enums.values(General)) |general| {
        const stat: Key = .{ .general = general };
        try std.testing.expectEqual(stat, keyFromStatId(statId(stat)).?);
    }

    for (std.enums.values(achievements.Id)) |id| {
        const stat: Key = .{ .achievement = id };
        try std.testing.expectEqual(stat, keyFromStatId(statId(stat)).?);
    }

    const cases = [_]Key{
        .{ .mined = .{ .block = .cobblestone } },
        .{ .crafted = .{ .block = .planks } },
        .{ .used = .{ .item = .stick } },
        .{ .depleted = .{ .item = .diamond } },
    };
    for (cases) |stat| {
        try std.testing.expectEqual(stat, keyFromStatId(statId(stat)).?);
    }

    try std.testing.expectEqual(@as(?Key, null), keyFromStatId(1234));
}

test "replaceAllSimilarBlocks folds the merged blocks into their canonical one" {
    try std.testing.expectEqual(world.Id{ .block = .dirt }, canonical(.{ .block = .grass }));
    try std.testing.expectEqual(world.Id{ .block = .mushroom_brown }, canonical(.{ .block = .mushroom_red }));
    try std.testing.expectEqual(world.Id{ .block = .pumpkin }, canonical(.{ .block = .jack_o_lantern }));
    try std.testing.expectEqual(world.Id{ .block = .stone }, canonical(.{ .block = .stone }));
    try std.testing.expectEqual(world.Id{ .item = .diamond }, canonical(.{ .item = .diamond }));
}

test "mining a block with stats disabled records nothing" {
    var stats: Stats = .{};
    defer stats.deinit(std.testing.allocator);

    try stats.mine(std.testing.allocator, .leaves);
    try stats.mine(std.testing.allocator, .bedrock);
    try stats.mine(std.testing.allocator, .stationary_water);
    try std.testing.expectEqual(@as(u32, 0), stats.counts.count());

    try stats.mine(std.testing.allocator, .grass);
    try std.testing.expectEqual(@as(i32, 1), stats.get(.{ .mined = .{ .block = .dirt } }));
}

test "an unregistered stat reads as absent rather than zero" {
    var stats: Stats = .{};
    defer stats.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?i32, 0), stats.value(.{ .crafted = .{ .block = .planks } }));
    try std.testing.expectEqual(@as(?i32, null), stats.value(.{ .crafted = .{ .block = .dirt } }));
    try std.testing.expectEqual(@as(?i32, null), stats.value(.{ .depleted = .{ .item = .diamond } }));
    try std.testing.expectEqual(@as(?i32, null), stats.value(.{ .mined = .{ .block = .leaves } }));
    try std.testing.expectEqual(@as(?i32, 0), stats.value(.{ .used = .{ .block = .leaves } }));
}

test "the blocks tab lists only mineable blocks and the items tab only items" {
    const gpa = std.testing.allocator;
    var stats: Stats = .{};
    defer stats.deinit(gpa);

    try stats.mine(gpa, .stone);
    try stats.use(gpa, .{ .block = .leaves });
    try stats.craft(gpa, .{ .block = .planks }, 4);
    try stats.craft(gpa, .{ .item = .stick }, 4);

    const blocks = try blockRows(gpa, &stats);
    defer gpa.free(blocks);
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqual(world.Id{ .block = .stone }, blocks[0]);
    try std.testing.expectEqual(world.Id{ .block = .planks }, blocks[1]);

    const items = try itemRows(gpa, &stats);
    defer gpa.free(items);
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqual(world.Id{ .item = .stick }, items[0]);
}

test "sorting a column puts unregistered stats last in both directions" {
    const gpa = std.testing.allocator;
    var stats: Stats = .{};
    defer stats.deinit(gpa);

    try stats.craft(gpa, .{ .block = .planks }, 4);
    try stats.mine(gpa, .dirt);
    try stats.mine(gpa, .stone);
    try stats.mine(gpa, .stone);

    var rows = [_]world.Id{
        .{ .block = .dirt },
        .{ .block = .stone },
        .{ .block = .planks },
    };

    sortRows(&rows, &stats, .crafted, false);
    try std.testing.expectEqual(world.Id{ .block = .planks }, rows[0]);

    sortRows(&rows, &stats, .crafted, true);
    try std.testing.expectEqual(world.Id{ .block = .planks }, rows[0]);

    sortRows(&rows, &stats, .mined, false);
    try std.testing.expectEqual(world.Id{ .block = .stone }, rows[0]);

    sortRows(&rows, &stats, null, false);
    try std.testing.expectEqual(world.Id{ .block = .stone }, rows[0]);
    try std.testing.expectEqual(world.Id{ .block = .dirt }, rows[1]);
    try std.testing.expectEqual(world.Id{ .block = .planks }, rows[2]);
}

test "counts are grouped the way NumberFormat's US integer instance groups them" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0", formatValue(&buffer, .count, 0));
    try std.testing.expectEqualStrings("999", formatValue(&buffer, .count, 999));
    try std.testing.expectEqualStrings("1,000", formatValue(&buffer, .count, 1000));
    try std.testing.expectEqualStrings("12,345,678", formatValue(&buffer, .count, 12345678));
}

test "times step through StatTypeTime's units at the half-unit mark" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0.0 s", formatValue(&buffer, .time, 0));
    try std.testing.expectEqualStrings("0.05 s", formatValue(&buffer, .time, 1));
    try std.testing.expectEqualStrings("30.0 s", formatValue(&buffer, .time, 600));
    try std.testing.expectEqualStrings("0.51 m", formatValue(&buffer, .time, 610));
    try std.testing.expectEqualStrings("1.00 h", formatValue(&buffer, .time, 20 * 60 * 60));
    try std.testing.expectEqualStrings("1.00 d", formatValue(&buffer, .time, 20 * 60 * 60 * 24));
}

test "distances step through StatTypeDistance's units at the half-unit mark" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0 cm", formatValue(&buffer, .distance, 0));
    try std.testing.expectEqualStrings("50 cm", formatValue(&buffer, .distance, 50));
    try std.testing.expectEqualStrings("0.51 m", formatValue(&buffer, .distance, 51));
    try std.testing.expectEqualStrings("1.00 m", formatValue(&buffer, .distance, 100));
    try std.testing.expectEqualStrings("0.51 km", formatValue(&buffer, .distance, 51000));
    try std.testing.expectEqualStrings("1.00 km", formatValue(&buffer, .distance, 100000));
}

test "the general list keeps StatList's registration order" {
    const values = std.enums.values(General);
    try std.testing.expectEqual(General.start_game, values[0]);
    try std.testing.expectEqual(General.minutes_played, values[5]);
    try std.testing.expectEqual(General.distance_walked, values[6]);
    try std.testing.expectEqual(General.fish_caught, values[values.len - 1]);
}

test "only damageable items register a depleted count, as StatList's filter does" {
    try std.testing.expect(registered(.{ .depleted = .{ .item = .pickaxe_iron } }));
    try std.testing.expect(registered(.{ .depleted = .{ .item = .helmet_gold } }));
    try std.testing.expect(!registered(.{ .depleted = .{ .item = .ingot_iron } }));
    try std.testing.expect(!registered(.{ .depleted = .{ .block = .stone } }));
}


test "an achievement only counts once its parent is unlocked" {
    const gpa = std.testing.allocator;
    var tally: Stats = .{};
    defer tally.deinit(gpa);

    try std.testing.expect(!try tally.award(gpa, .mine_wood));
    try std.testing.expect(!tally.hasAchievement(.mine_wood));

    try std.testing.expect(try tally.award(gpa, .open_inventory));
    try std.testing.expect(tally.hasAchievement(.open_inventory));

    try std.testing.expect(try tally.award(gpa, .mine_wood));
    try std.testing.expect(tally.hasAchievement(.mine_wood));
}

test "awarding an achievement twice only announces it the first time" {
    const gpa = std.testing.allocator;
    var tally: Stats = .{};
    defer tally.deinit(gpa);

    try std.testing.expect(try tally.award(gpa, .open_inventory));
    try std.testing.expect(!try tally.award(gpa, .open_inventory));
    try std.testing.expectEqual(@as(i32, 2), tally.get(.{ .achievement = .open_inventory }));
}

test "a locked achievement is still a registered stat, so it reads as zero" {
    const gpa = std.testing.allocator;
    var tally: Stats = .{};
    defer tally.deinit(gpa);

    try std.testing.expectEqual(@as(?i32, 0), tally.value(.{ .achievement = .fly_pig }));
    try std.testing.expect(!tally.canUnlock(.fly_pig));
    try std.testing.expect(tally.canUnlock(.open_inventory));
}
