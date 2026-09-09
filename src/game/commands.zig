const std = @import("std");

const world = @import("world");

pub const max_count: u8 = 64;
pub const max_fill_volume: u32 = 32768;

pub const Verb = enum {
    help,
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

pub const Fill = struct {
    from: world.BlockPos,
    to: world.BlockPos,
    id: world.Block,
};

pub const Give = struct {
    id: world.Id,
    raw_id: u32,
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
    fill: Fill,
    seed: Seed,
    give: Give,
    spawn: Spawn,
    time: Time,
    tp: Tp,
    weather: Weather,
    missing_item: u32,
    missing_block: []const u8,
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
        const padding = " " ** (widest - signature(verb).len + help_gap);
        lines[index] = help_indent ++ signature(verb) ++ padding ++ verb.description();
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
        const id: world.Block = @enumFromInt(raw);
        return if (std.enums.tagName(world.Block, id) == null) null else .{ .block = id };
    }
    if (raw > std.math.maxInt(u16)) return null;
    const id: world.Item = @enumFromInt(raw);
    return if (std.enums.tagName(world.Item, id) == null) null else .{ .item = id };
}

pub fn resolveBlock(raw: u32) ?world.Block {
    if (raw > 255) return null;
    const id: world.Block = @enumFromInt(raw);
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

pub fn numericId(id: world.Id) u32 {
    return switch (id) {
        .block => |block| @intFromEnum(block),
        .item => |item| @intFromEnum(item),
    };
}

pub fn parse(line: []const u8) Result {
    if (!std.mem.startsWith(u8, line, "/")) return .nothing;

    var words = std.mem.tokenizeScalar(u8, line[1..], ' ');
    const word = words.next() orelse return .nothing;

    return switch (verbFromWord(word) orelse return .{ .unknown = word }) {
        .help => .help,
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
        .raw_id = numericId(id),
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

test "a line without a leading slash is not a command" {
    try std.testing.expectEqual(Result.nothing, parse("hello world"));
    try std.testing.expectEqual(Result.nothing, parse(""));
}

test "help answers to its own name and to a question mark" {
    try std.testing.expectEqual(Result.help, parse("/help"));
    try std.testing.expectEqual(Result.help, parse("/?"));
}

test "give hands over a block id and defaults to one" {
    const result = parse("/give 1");
    try std.testing.expectEqual(world.Block.stone, result.give.id.block);
    try std.testing.expectEqual(@as(u32, 1), result.give.raw_id);
    try std.testing.expectEqual(@as(u8, 1), result.give.count);
}

test "give reads ids above 255 out of the item table" {
    const result = parse("/give 264 5");
    try std.testing.expectEqual(world.Item.diamond, result.give.id.item);
    try std.testing.expectEqual(@as(u8, 5), result.give.count);
}

test "give clamps the count into a single stack" {
    try std.testing.expectEqual(@as(u8, 64), parse("/give 1 100").give.count);
    try std.testing.expectEqual(@as(u8, 1), parse("/give 1 0").give.count);
    try std.testing.expectEqual(@as(u8, 1), parse("/give 1 nine").give.count);
}

test "give rejects ids that name nothing, and air" {
    try std.testing.expectEqual(@as(u32, 0), parse("/give 0").missing_item);
    try std.testing.expectEqual(@as(u32, 250), parse("/give 250").missing_item);
    try std.testing.expectEqual(@as(u32, 400), parse("/give 400").missing_item);
    try std.testing.expectEqual(@as(u32, 4000), parse("/give 4000").missing_item);
    try std.testing.expectEqualStrings("turnip", parse("/give turnip").unparsed_item);
}

test "give stays silent when the argument count is wrong" {
    try std.testing.expectEqual(Result.nothing, parse("/give"));
    try std.testing.expectEqual(Result.nothing, parse("/give 1 2 3"));
}

test "spawn names a mob and defaults to one" {
    const result = parse("/spawn pig");
    try std.testing.expectEqual(Mob.pig, result.spawn.mob);
    try std.testing.expectEqual(@as(u8, 1), result.spawn.count);

    try std.testing.expectEqual(Mob.squid, parse("/spawn squid").spawn.mob);
    try std.testing.expectEqual(Mob.chicken, parse("/spawn chicken 3").spawn.mob);
    try std.testing.expectEqual(@as(u8, 3), parse("/spawn chicken 3").spawn.count);
}

test "spawn rejects a mob it cannot build" {
    try std.testing.expectEqualStrings("a" ** 20, parse("/spawn " ++ "a" ** 20).missing_mob);
    try std.testing.expectEqual(Result.nothing, parse("/spawn"));
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

test "time reads its amount before it judges the method" {
    try std.testing.expectEqualStrings("noon", parse("/time set noon").unparsed);
    try std.testing.expectEqualStrings("noon", parse("/time skip noon").unparsed);
    try std.testing.expectEqualStrings("99999999999", parse("/time set 99999999999").unparsed);
    try std.testing.expect(parse("/time skip 1000") == .unknown_method);
    try std.testing.expect(parse("/time Set 1000") == .unknown_method);
}

test "time stays silent when the argument count is wrong" {
    try std.testing.expectEqual(Result.nothing, parse("/time"));
    try std.testing.expectEqual(Result.nothing, parse("/time set"));
    try std.testing.expectEqual(Result.nothing, parse("/time set 0 0"));
}

test "kill takes no arguments at all" {
    try std.testing.expectEqual(Result.kill, parse("/kill"));
    try std.testing.expectEqual(Result.nothing, parse("/kill Player"));
    try std.testing.expectEqualStrings("Kill", parse("/Kill").unknown);
}

test "tp reads three coordinates" {
    const jump = parse("/tp 12.5 64 -3.25").tp;
    try std.testing.expectApproxEqAbs(@as(f64, 12.5), jump.x, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 64.0), jump.y, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -3.25), jump.z, 1.0e-9);
}

test "tp reports whichever coordinate it could not read" {
    try std.testing.expectEqualStrings("here", parse("/tp here 64 0").unparsed);
    try std.testing.expectEqualStrings("up", parse("/tp 0 up 0").unparsed);
    try std.testing.expectEqualStrings("yonder", parse("/tp 0 64 yonder").unparsed);
}

test "tp stays silent when the argument count is wrong" {
    try std.testing.expectEqual(Result.nothing, parse("/tp"));
    try std.testing.expectEqual(Result.nothing, parse("/tp 0"));
    try std.testing.expectEqual(Result.nothing, parse("/tp 0 64"));
    try std.testing.expectEqual(Result.nothing, parse("/tp 0 64 0 0"));
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

test "weather reads its spell before it judges the sky" {
    try std.testing.expectEqualStrings("soon", parse("/weather rain soon").unparsed);
    try std.testing.expectEqualStrings("soon", parse("/weather drizzle soon").unparsed);
    try std.testing.expect(parse("/weather drizzle") == .unknown_method);
    try std.testing.expect(parse("/weather Rain") == .unknown_method);
}

test "weather refuses a spell that runs backwards" {
    try std.testing.expectEqualStrings("-1", parse("/weather rain -1").unparsed);
    try std.testing.expectEqual(@as(i32, 0), parse("/weather rain 0").weather.duration.?);
}

test "weather stays silent when the argument count is wrong" {
    try std.testing.expectEqual(Result.nothing, parse("/weather"));
    try std.testing.expectEqual(Result.nothing, parse("/weather rain 600 600"));
}

test "an unrecognised verb reports itself" {
    try std.testing.expectEqualStrings("gamemode", parse("/gamemode").unknown);
    try std.testing.expectEqualStrings("warp", parse("/warp Player Notch").unknown);
    try std.testing.expectEqual(Result.nothing, parse("/"));
}

test "every verb names itself in help and answers to that name" {
    for (std.enums.values(Verb), help_lines[1..]) |verb, line| {
        try std.testing.expect(std.mem.startsWith(u8, line, help_indent));
        try std.testing.expect(std.mem.startsWith(u8, line[help_indent.len..], @tagName(verb)));
        try std.testing.expectEqual(verb, verbFromWord(@tagName(verb)).?);
        try std.testing.expect(std.mem.endsWith(u8, line, verb.description()));
    }
}

test "help lines all break for their description in the same column" {
    const column = std.mem.indexOf(u8, help_lines[1], Verb.help.description()).?;
    var tightest: usize = std.math.maxInt(usize);
    for (std.enums.values(Verb), help_lines[1..]) |verb, line| {
        try std.testing.expectEqual(column, std.mem.indexOf(u8, line, verb.description()).?);
        const written = std.mem.trimEnd(u8, line[0..column], " ");
        try std.testing.expect(std.mem.endsWith(u8, written, verb.usage()));
        tightest = @min(tightest, column - written.len);
    }
    try std.testing.expectEqual(@as(usize, help_gap), tightest);
}

test "verbs and mob names are all matched exactly" {
    try std.testing.expectEqualStrings("HELP", parse("/HELP").unknown);
    try std.testing.expectEqualStrings("Give", parse("/Give 1").unknown);
    try std.testing.expectEqualStrings("spawner", parse("/spawner pig").unknown);
    try std.testing.expectEqualStrings("Pig", parse("/spawn Pig").missing_mob);
}

test "resolveId spans both halves of the id space" {
    try std.testing.expectEqual(world.Block.wool, resolveId(35).?.block);
    try std.testing.expectEqual(world.Item.bone, resolveId(352).?.item);
    try std.testing.expectEqual(@as(?world.Id, null), resolveId(0));
    try std.testing.expectEqual(@as(?world.Id, null), resolveId(70000));
}

test "give takes a block or item by its own name" {
    try std.testing.expectEqual(world.Block.stone, parse("/give stone").give.id.block);
    try std.testing.expectEqual(world.Item.diamond, parse("/give diamond").give.id.item);
    try std.testing.expectEqual(world.Block.jack_o_lantern, parse("/give jack_o_lantern").give.id.block);
}

test "a name that is both a block and an item hands over the item" {
    for ([_][]const u8{ "cake", "reed", "brick", "door_wood", "door_iron" }) |name| {
        var line: [64]u8 = undefined;
        const typed = std.fmt.bufPrint(&line, "/give {s}", .{name}) catch unreachable;
        const given = parse(typed).give;
        try std.testing.expect(given.id == .item);
        try std.testing.expectEqualStrings(name, @tagName(given.id.item));
    }
}

test "a numeric id still reaches the block half of a shared name" {
    try std.testing.expectEqual(world.Block.cake, parse("/give 92").give.id.block);
    try std.testing.expectEqual(world.Item.cake, parse("/give 354").give.id.item);
}

test "a name is matched exactly, like every other command word" {
    try std.testing.expectEqualStrings("Stone", parse("/give Stone").unparsed_item);
    try std.testing.expectEqualStrings("banana", parse("/give banana").unparsed_item);
}

test "the count still follows a name the way it follows an id" {
    const given = parse("/give cobblestone 32").give;
    try std.testing.expectEqual(world.Block.cobblestone, given.id.block);
    try std.testing.expectEqual(@as(u8, 32), given.count);
}

test "a name reports the id it resolved to, so the reply reads the same either way" {
    try std.testing.expectEqual(@as(u32, 264), parse("/give diamond").give.raw_id);
    try std.testing.expectEqual(@as(u32, 264), parse("/give 264").give.raw_id);
    try std.testing.expectEqual(@as(u32, 1), parse("/give 001").give.raw_id);
}

test "freecam takes no arguments at all" {
    try std.testing.expectEqual(Result.freecam, parse("/freecam"));
    try std.testing.expectEqual(Result.nothing, parse("/freecam on"));
}

test "fly takes no arguments at all" {
    try std.testing.expectEqual(Result.fly, parse("/fly"));
    try std.testing.expectEqual(Result.nothing, parse("/fly on"));
}

test "fill reads two corners and a block" {
    const box = parse("/fill 0 64 0 3 66 5 stone").fill;
    try std.testing.expectEqual(world.Block.stone, box.id);
    try std.testing.expectEqual(@as(i32, 0), box.from.x);
    try std.testing.expectEqual(@as(i32, 64), box.from.y);
    try std.testing.expectEqual(@as(i32, 0), box.from.z);
    try std.testing.expectEqual(@as(i32, 3), box.to.x);
    try std.testing.expectEqual(@as(i32, 66), box.to.y);
    try std.testing.expectEqual(@as(i32, 5), box.to.z);
}

test "fill sorts the corners onto each other" {
    const box = parse("/fill 3 66 5 -2 64 0 1").fill;
    try std.testing.expectEqual(@as(i32, -2), box.from.x);
    try std.testing.expectEqual(@as(i32, 64), box.from.y);
    try std.testing.expectEqual(@as(i32, 0), box.from.z);
    try std.testing.expectEqual(@as(i32, 3), box.to.x);
    try std.testing.expectEqual(@as(i32, 66), box.to.y);
    try std.testing.expectEqual(@as(i32, 5), box.to.z);
}

test "fill takes a block by number or by name, air included" {
    try std.testing.expectEqual(world.Block.wool, parse("/fill 0 0 0 0 0 0 35").fill.id);
    try std.testing.expectEqual(world.Block.air, parse("/fill 0 0 0 0 0 0 0").fill.id);
    try std.testing.expectEqual(world.Block.air, parse("/fill 0 0 0 0 0 0 air").fill.id);
}

test "fill refuses anything that is not a block" {
    try std.testing.expectEqualStrings("264", parse("/fill 0 0 0 0 0 0 264").missing_block);
    try std.testing.expectEqualStrings("250", parse("/fill 0 0 0 0 0 0 250").missing_block);
    try std.testing.expectEqualStrings("diamond", parse("/fill 0 0 0 0 0 0 diamond").missing_block);
    try std.testing.expectEqualStrings("Stone", parse("/fill 0 0 0 0 0 0 Stone").missing_block);
}

test "fill reports whichever coordinate it could not read" {
    try std.testing.expectEqualStrings("here", parse("/fill here 0 0 0 0 0 stone").unparsed);
    try std.testing.expectEqualStrings("64.5", parse("/fill 0 64.5 0 0 0 0 stone").unparsed);
    try std.testing.expectEqualStrings("yonder", parse("/fill 0 0 0 0 0 yonder stone").unparsed);
}

test "fill refuses a box bigger than a stack of chunks" {
    const one_over = max_fill_volume + 1;
    try std.testing.expectEqual(@as(u128, one_over), parse("/fill 0 0 0 0 0 32768 stone").too_many_blocks);
    try std.testing.expectEqual(@as(i32, 32767), parse("/fill 0 0 0 0 0 32767 stone").fill.to.z);
    try std.testing.expect(parse("/fill -2147483648 -2147483648 -2147483648 2147483647 2147483647 2147483647 stone") == .too_many_blocks);
}

test "fill stays silent when the argument count is wrong" {
    try std.testing.expectEqual(Result.nothing, parse("/fill"));
    try std.testing.expectEqual(Result.nothing, parse("/fill 0 0 0 0 0 0"));
    try std.testing.expectEqual(Result.nothing, parse("/fill 0 0 0 0 0 0 stone 1"));
}
