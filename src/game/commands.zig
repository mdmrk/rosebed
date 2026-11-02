const std = @import("std");

const world = @import("world");

const achievements = @import("achievements.zig");

pub const max_count: u8 = 64;
pub const max_fill_volume: u32 = 32768;

pub const Verb = enum {
    help,
    achievement,
    clear,
    freecam,
    fill,
    fly,
    give,
    kill,
    spawn,
    seed,
    time,
    tp,
    weather,

    pub fn usage(self: Verb) []const u8 {
        return switch (self) {
            .help => "",
            .achievement => "<grant|revoke> <name|everything>",
            .clear => "",
            .freecam => "",
            .fill => "<x1> <y1> <z1> <x2> <y2> <z2> <id|name>",
            .fly => "",
            .give => "<id|name> [num]",
            .kill => "",
            .spawn => "<mob> [num]",
            .seed => "<|copy>",
            .time => "<add|set> <amount>",
            .tp => "<x> <y> <z>",
            .weather => "<clear|rain|thunder> [duration]",
        };
    }

    pub fn description(self: Verb) []const u8 {
        return switch (self) {
            .help => "shows this message",
            .achievement => "grants or revokes an achievement",
            .clear => "empties your inventory, armor and all",
            .freecam => "detaches the camera from the player",
            .fill => "fills a box of blocks, corner to corner",
            .fly => "lets the player fly, free of gravity",
            .give => "gives the player a resource",
            .kill => "kills the player",
            .spawn => "spawns a mob where you look",
            .seed => "shows world seed",
            .time => "adds to or sets the world time (0-24000)",
            .tp => "teleports player to position in world",
            .weather => "sets the sky, for a while or until it turns",
        };
    }
};

pub const Mob = enum { pig, cow, sheep, chicken, slime, wolf, ghast, creeper, skeleton, spider, zombie, pigzombie, squid };

pub const Achievement = struct {
    method: Method,
    target: Target,

    pub const Method = enum { grant, revoke };

    pub const Target = union(enum) {
        everything,
        one: achievements.Id,
    };
};

pub const Fill = struct {
    from: world.BlockPos,
    to: world.BlockPos,
    id: world.Block,
};

pub const Give = struct {
    id: world.Id,
    count: u8,
};

pub const Seed = struct {
    copy: bool,
};

pub const Spawn = struct {
    mob: Mob,
    count: u8,
};

pub const Time = struct {
    method: Method,
    amount: i32,

    pub const Method = enum { add, set };
};

pub const Tp = struct {
    x: f64,
    y: f64,
    z: f64,
};

pub const Weather = struct {
    sky: Sky,
    duration: ?i32,

    pub const Sky = enum { clear, rain, thunder };
};

pub const Result = union(enum) {
    nothing,
    help,
    freecam,
    fly,
    kill,
    clear,
    achievement: Achievement,
    fill: Fill,
    seed: Seed,
    give: Give,
    spawn: Spawn,
    time: Time,
    tp: Tp,
    weather: Weather,
    missing_item: u32,
    missing_block: []const u8,
    missing_achievement: []const u8,
    missing_mob: []const u8,
    too_many_blocks: u128,
    unparsed: []const u8,
    unparsed_item: []const u8,
    unknown_method: []const u8,
    unknown: []const u8,
};

const help_indent = "   ";
const help_gap = 2;

fn signature(comptime verb: Verb) []const u8 {
    return if (verb.usage().len == 0) @tagName(verb) else @tagName(verb) ++ " " ++ verb.usage();
}

pub const help_lines: []const []const u8 = blk: {
    const verbs = std.enums.values(Verb);

    var widest: usize = 0;
    for (verbs) |verb| widest = @max(widest, signature(verb).len);

    var lines: [verbs.len + 1][]const u8 = undefined;
    lines[0] = "Commands:";
    for (verbs, 1..) |verb, index| {
        const padding: [widest - signature(verb).len + help_gap]u8 = @splat(' ');
        lines[index] = help_indent ++ signature(verb) ++ &padding ++ verb.description();
    }

    const frozen = lines;
    break :blk &frozen;
};

pub const unknown_command_line = "Unknown command. Type /help for a list.";

pub const kill_line = "Ouch. That look like it hurt.";

pub const freecam_on_line = "Freecam on. The camera flies, your body stays.";
pub const freecam_off_line = "Freecam off.";

pub const fly_on_line = "Flying on. Jump to rise, sneak to sink.";
pub const fly_off_line = "Flying off.";

pub const no_sky_line = "There is no sky here to change.";

pub const set_weather_line = "Set the weather to {s}";

pub fn applyWeather(sky: *world.Weather, asked: Weather) void {
    sky.raining = asked.sky != .clear;
    sky.thundering = asked.sky == .thunder;

    sky.rain_time = asked.duration orelse 0;
    sky.thunder_time = asked.duration orelse 0;
}

fn tryParse(text: ?[]const u8, fallback: u8) u8 {
    const raw = std.fmt.parseInt(u32, text orelse return fallback, 10) catch return fallback;
    return @intCast(std.math.clamp(raw, 1, max_count));
}

pub fn resolveId(raw: u32) ?world.Id {
    if (raw == 0) return null;
    if (raw < 256) {
        const id: world.Block = @fromBackingInt(@intCast(raw));
        return if (std.enums.tagName(world.Block, id) == null) null else .{ .block = id };
    }
    if (raw > std.math.maxInt(u16)) return null;
    const id: world.Item = @fromBackingInt(@intCast(raw));
    return if (std.enums.tagName(world.Item, id) == null) null else .{ .item = id };
}

pub fn resolveBlock(raw: u32) ?world.Block {
    if (raw > 255) return null;
    const id: world.Block = @fromBackingInt(@intCast(raw));
    return if (std.enums.tagName(world.Block, id) == null) null else id;
}

fn verbFromWord(word: []const u8) ?Verb {
    if (std.mem.eql(u8, word, "?")) return .help;
    return std.meta.stringToEnum(Verb, word);
}

pub fn resolveName(name: []const u8) ?world.Id {
    if (std.meta.stringToEnum(world.Item, name)) |id| return .{ .item = id };
    if (std.meta.stringToEnum(world.Block, name)) |id| return .{ .block = id };
    return null;
}

pub fn parse(line: []const u8) Result {
    if (!std.mem.startsWith(u8, line, "/")) return .nothing;

    var words = std.mem.tokenizeScalar(u8, line[1..], ' ');
    const word = words.next() orelse return .nothing;

    return switch (verbFromWord(word) orelse return .{ .unknown = word }) {
        .help => .help,
        .achievement => parseAchievement(&words),
        .clear => if (words.next() == null) .clear else .nothing,
        .freecam => if (words.next() == null) .freecam else .nothing,
        .fill => parseFill(&words),
        .fly => if (words.next() == null) .fly else .nothing,
        .kill => if (words.next() == null) .kill else .nothing,
        .give => parseGive(&words),
        .spawn => parseSpawn(&words),
        .seed => parseSeed(&words),
        .time => parseTime(&words),
        .tp => parseTp(&words),
        .weather => parseWeather(&words),
    };
}

const Words = std.mem.TokenIterator(u8, .scalar);

fn parseAchievement(words: *Words) Result {
    const method_text = words.next() orelse return .nothing;
    const target_text = words.next() orelse return .nothing;
    if (words.next() != null) return .nothing;

    const target: Achievement.Target = if (std.mem.eql(u8, target_text, "everything"))
        .everything
    else
        .{ .one = std.meta.stringToEnum(achievements.Id, target_text) orelse
            return .{ .missing_achievement = target_text } };

    const method = std.meta.stringToEnum(Achievement.Method, method_text) orelse
        return .{ .unknown_method = "either \"grant\" or \"revoke\"" };

    return .{ .achievement = .{ .method = method, .target = target } };
}

fn parseFill(words: *Words) Result {
    var texts: [6][]const u8 = undefined;
    for (&texts) |*text| text.* = words.next() orelse return .nothing;
    const id_text = words.next() orelse return .nothing;
    if (words.next() != null) return .nothing;

    var coords: [6]i32 = undefined;
    for (&coords, texts) |*coord, text| {
        coord.* = std.fmt.parseInt(i32, text, 10) catch return .{ .unparsed = text };
    }

    const id = if (std.fmt.parseInt(u32, id_text, 10)) |raw|
        resolveBlock(raw) orelse return .{ .missing_block = id_text }
    else |_|
        std.meta.stringToEnum(world.Block, id_text) orelse return .{ .missing_block = id_text };

    const from: world.BlockPos = .init(
        @min(coords[0], coords[3]),
        @min(coords[1], coords[4]),
        @min(coords[2], coords[5]),
    );
    const to: world.BlockPos = .init(
        @max(coords[0], coords[3]),
        @max(coords[1], coords[4]),
        @max(coords[2], coords[5]),
    );

    const volume = span(from.x, to.x) * span(from.y, to.y) * span(from.z, to.z);
    if (volume > max_fill_volume) return .{ .too_many_blocks = volume };

    return .{ .fill = .{ .from = from, .to = to, .id = id } };
}

fn span(low: i32, high: i32) u128 {
    return @intCast(@as(i64, high) - @as(i64, low) + 1);
}

fn parseGive(words: *Words) Result {
    const id_text = words.next() orelse return .nothing;
    const count_text = words.next();
    if (words.next() != null) return .nothing;

    const id = if (std.fmt.parseInt(u32, id_text, 10)) |raw|
        resolveId(raw) orelse return .{ .missing_item = raw }
    else |_|
        resolveName(id_text) orelse return .{ .unparsed_item = id_text };

    return .{ .give = .{
        .id = id,
        .count = tryParse(count_text, 1),
    } };
}

fn parseSpawn(words: *Words) Result {
    const name = words.next() orelse return .nothing;
    const count_text = words.next();
    if (words.next() != null) return .nothing;

    const mob = std.meta.stringToEnum(Mob, name) orelse return .{ .missing_mob = name };
    return .{ .spawn = .{ .mob = mob, .count = tryParse(count_text, 1) } };
}

fn parseSeed(words: *Words) Result {
    const copy = words.next() orelse return .{ .seed = .{ .copy = false } };
    if (words.next() != null) return .nothing;
    if (!std.mem.eql(u8, copy, "copy")) return .{ .unknown_method = "either \"\" or \"copy\"" };
    return .{ .seed = .{ .copy = true } };
}

fn parseTime(words: *Words) Result {
    const method_text = words.next() orelse return .nothing;
    const amount_text = words.next() orelse return .nothing;
    if (words.next() != null) return .nothing;

    const amount = std.fmt.parseInt(i32, amount_text, 10) catch return .{ .unparsed = amount_text };
    const method = std.meta.stringToEnum(Time.Method, method_text) orelse return .{ .unknown_method = "either \"add\" or \"set\"" };
    return .{ .time = .{ .method = method, .amount = amount } };
}

fn parseWeather(words: *Words) Result {
    const sky_text = words.next() orelse return .nothing;
    const duration_text = words.next();
    if (words.next() != null) return .nothing;

    const duration: ?i32 = if (duration_text) |text|
        std.fmt.parseInt(i32, text, 10) catch return .{ .unparsed = text }
    else
        null;

    const sky = std.meta.stringToEnum(Weather.Sky, sky_text) orelse
        return .{ .unknown_method = "either \"clear\", \"rain\" or \"thunder\"" };

    if (duration) |ticks| {
        if (ticks < 0) return .{ .unparsed = duration_text.? };
    }
    return .{ .weather = .{ .sky = sky, .duration = duration } };
}

fn parseTp(words: *Words) Result {
    const x_text = words.next() orelse return .nothing;
    const y_text = words.next() orelse return .nothing;
    const z_text = words.next() orelse return .nothing;
    if (words.next() != null) return .nothing;

    const x = std.fmt.parseFloat(f64, x_text) catch return .{ .unparsed = x_text };
    const y = std.fmt.parseFloat(f64, y_text) catch return .{ .unparsed = y_text };
    const z = std.fmt.parseFloat(f64, z_text) catch return .{ .unparsed = z_text };
    return .{ .tp = .{ .x = x, .y = y, .z = z } };
}

test "time adds to or sets the clock" {
    const added = parse("/time add 1000").time;
    try std.testing.expectEqual(Time.Method.add, added.method);
    try std.testing.expectEqual(@as(i32, 1000), added.amount);

    const set = parse("/time set 18000").time;
    try std.testing.expectEqual(Time.Method.set, set.method);
    try std.testing.expectEqual(@as(i32, 18000), set.amount);

    try std.testing.expectEqual(@as(i32, -500), parse("/time add -500").time.amount);
}

test "weather names a sky, with or without a spell to hold it" {
    const wet = parse("/weather rain").weather;
    try std.testing.expectEqual(Weather.Sky.rain, wet.sky);
    try std.testing.expect(wet.duration == null);

    const storm = parse("/weather thunder 600").weather;
    try std.testing.expectEqual(Weather.Sky.thunder, storm.sky);
    try std.testing.expectEqual(@as(i32, 600), storm.duration.?);

    try std.testing.expectEqual(Weather.Sky.clear, parse("/weather clear").weather.sky);
}

test "help lines all break for their description in the same column" {
    const column = std.mem.find(u8, help_lines[1], Verb.help.description()).?;
    var tightest: usize = std.math.maxInt(usize);
    for (std.enums.values(Verb), help_lines[1..]) |verb, line| {
        try std.testing.expectEqual(column, std.mem.find(u8, line, verb.description()).?);
        const written = std.mem.trimEnd(u8, line[0..column], " ");
        try std.testing.expect(std.mem.endsWith(u8, written, verb.usage()));
        tightest = @min(tightest, column - written.len);
    }
    try std.testing.expectEqual(@as(usize, help_gap), tightest);
}
