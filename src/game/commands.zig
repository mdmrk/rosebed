const std = @import("std");

const world = @import("world");

pub const max_count: u8 = 64;

pub const Verb = enum {
    help,
    give,
    kill,
    spawn,
    seed,
    time,

    pub fn usage(self: Verb) []const u8 {
        return switch (self) {
            .help => "",
            .give => "<player> <id|name> [num]",
            .kill => "",
            .spawn => "<mob> [num]",
            .seed => "<|copy>",
            .time => "<add|set> <amount>",
        };
    }

    pub fn description(self: Verb) []const u8 {
        return switch (self) {
            .help => "shows this message",
            .give => "gives a player a resource",
            .kill => "kills the player",
            .spawn => "spawns a mob where you look",
            .seed => "shows world seed",
            .time => "adds to or sets the world time (0-24000)",
        };
    }
};

pub const Mob = enum { pig, cow, sheep, chicken, slime, wolf };

pub const Give = struct {
    user: []const u8,
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

pub const Result = union(enum) {
    nothing,
    help,
    kill,
    seed: Seed,
    give: Give,
    spawn: Spawn,
    time: Time,
    unparsed_item: []const u8,
    missing_item: u32,
    missing_user: []const u8,
    missing_mob: []const u8,
    unparsed_time: []const u8,
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

pub const unknown_method_line = "Unknown method, use ";

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

pub fn parse(line: []const u8, username: []const u8) Result {
    if (!std.mem.startsWith(u8, line, "/")) return .nothing;

    var words = std.mem.tokenizeScalar(u8, line[1..], ' ');
    const word = words.next() orelse return .nothing;

    return switch (verbFromWord(word) orelse return .{ .unknown = word }) {
        .help => .help,
        .kill => if (words.next() == null) .kill else .nothing,
        .give => parseGive(&words, username),
        .spawn => parseSpawn(&words),
        .seed => parseSeed(&words),
        .time => parseTime(&words),
    };
}

const Words = std.mem.TokenIterator(u8, .scalar);

fn parseGive(words: *Words, username: []const u8) Result {
    const user = words.next() orelse return .nothing;
    const id_text = words.next() orelse return .nothing;
    const count_text = words.next();
    if (words.next() != null) return .nothing;

    if (!std.mem.eql(u8, user, username)) return .{ .missing_user = user };

    const id = if (std.fmt.parseInt(u32, id_text, 10)) |raw|
        resolveId(raw) orelse return .{ .missing_item = raw }
    else |_|
        resolveName(id_text) orelse return .{ .unparsed_item = id_text };

    return .{ .give = .{
        .user = user,
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

    const amount = std.fmt.parseInt(i32, amount_text, 10) catch return .{ .unparsed_time = amount_text };
    const method = std.meta.stringToEnum(Time.Method, method_text) orelse return .{ .unknown_method = "either \"add\" or \"set\"" };
    return .{ .time = .{ .method = method, .amount = amount } };
}

const local_user = "Player";

test "a line without a leading slash is not a command" {
    try std.testing.expectEqual(Result.nothing, parse("hello world", local_user));
    try std.testing.expectEqual(Result.nothing, parse("", local_user));
}

test "help answers to its own name and to a question mark" {
    try std.testing.expectEqual(Result.help, parse("/help", local_user));
    try std.testing.expectEqual(Result.help, parse("/?", local_user));
}

test "give hands over a block id and defaults to one" {
    const result = parse("/give Player 1", local_user);
    try std.testing.expectEqual(world.Block.stone, result.give.id.block);
    try std.testing.expectEqual(@as(u32, 1), result.give.raw_id);
    try std.testing.expectEqual(@as(u8, 1), result.give.count);
    try std.testing.expectEqualStrings("Player", result.give.user);
}

test "give reads ids above 255 out of the item table" {
    const result = parse("/give Player 264 5", local_user);
    try std.testing.expectEqual(world.Item.diamond, result.give.id.item);
    try std.testing.expectEqual(@as(u8, 5), result.give.count);
}

test "give clamps the count into a single stack" {
    try std.testing.expectEqual(@as(u8, 64), parse("/give Player 1 100", local_user).give.count);
    try std.testing.expectEqual(@as(u8, 1), parse("/give Player 1 0", local_user).give.count);
    try std.testing.expectEqual(@as(u8, 1), parse("/give Player 1 nine", local_user).give.count);
}

test "give rejects ids that name nothing, and air" {
    try std.testing.expectEqual(@as(u32, 0), parse("/give Player 0", local_user).missing_item);
    try std.testing.expectEqual(@as(u32, 250), parse("/give Player 250", local_user).missing_item);
    try std.testing.expectEqual(@as(u32, 400), parse("/give Player 400", local_user).missing_item);
    try std.testing.expectEqual(@as(u32, 259), parse("/give Player 259", local_user).missing_item);
    try std.testing.expectEqualStrings("turnip", parse("/give Player turnip", local_user).unparsed_item);
}

test "give only knows the one local player, spelled exactly" {
    try std.testing.expectEqual(world.Block.stone, parse("/give Player 1", local_user).give.id.block);
    try std.testing.expectEqualStrings("Notch", parse("/give Notch 1", local_user).missing_user);
    try std.testing.expectEqualStrings("player", parse("/give player 1", local_user).missing_user);
}

test "give stays silent when the argument count is wrong" {
    try std.testing.expectEqual(Result.nothing, parse("/give", local_user));
    try std.testing.expectEqual(Result.nothing, parse("/give Player", local_user));
    try std.testing.expectEqual(Result.nothing, parse("/give Player 1 2 3", local_user));
}

test "spawn names a mob and defaults to one" {
    const result = parse("/spawn pig", local_user);
    try std.testing.expectEqual(Mob.pig, result.spawn.mob);
    try std.testing.expectEqual(@as(u8, 1), result.spawn.count);

    try std.testing.expectEqual(Mob.chicken, parse("/spawn chicken 3", local_user).spawn.mob);
    try std.testing.expectEqual(@as(u8, 3), parse("/spawn chicken 3", local_user).spawn.count);
}

test "spawn rejects a mob it cannot build" {
    try std.testing.expectEqualStrings("creeper", parse("/spawn creeper", local_user).missing_mob);
    try std.testing.expectEqualStrings("a" ** 20, parse("/spawn " ++ "a" ** 20, local_user).missing_mob);
    try std.testing.expectEqual(Result.nothing, parse("/spawn", local_user));
}

test "time adds to or sets the clock" {
    const added = parse("/time add 1000", local_user).time;
    try std.testing.expectEqual(Time.Method.add, added.method);
    try std.testing.expectEqual(@as(i32, 1000), added.amount);

    const set = parse("/time set 18000", local_user).time;
    try std.testing.expectEqual(Time.Method.set, set.method);
    try std.testing.expectEqual(@as(i32, 18000), set.amount);

    try std.testing.expectEqual(@as(i32, -500), parse("/time add -500", local_user).time.amount);
}

test "time reads its amount before it judges the method" {
    try std.testing.expectEqualStrings("noon", parse("/time set noon", local_user).unparsed_time);
    try std.testing.expectEqualStrings("noon", parse("/time skip noon", local_user).unparsed_time);
    try std.testing.expectEqualStrings("99999999999", parse("/time set 99999999999", local_user).unparsed_time);
    try std.testing.expect(parse("/time skip 1000", local_user) == .unknown_method);
    try std.testing.expect(parse("/time Set 1000", local_user) == .unknown_method);
}

test "time stays silent when the argument count is wrong" {
    try std.testing.expectEqual(Result.nothing, parse("/time", local_user));
    try std.testing.expectEqual(Result.nothing, parse("/time set", local_user));
    try std.testing.expectEqual(Result.nothing, parse("/time set 0 0", local_user));
}

test "kill takes no arguments at all" {
    try std.testing.expectEqual(Result.kill, parse("/kill", local_user));
    try std.testing.expectEqual(Result.nothing, parse("/kill Player", local_user));
    try std.testing.expectEqualStrings("Kill", parse("/Kill", local_user).unknown);
}

test "an unrecognised verb reports itself" {
    try std.testing.expectEqualStrings("tp", parse("/tp Player Notch", local_user).unknown);
    try std.testing.expectEqual(Result.nothing, parse("/", local_user));
}

test "help is built from the verbs, one line each under a heading" {
    try std.testing.expectEqual(std.enums.values(Verb).len + 1, help_lines.len);
    try std.testing.expectEqualStrings("Commands:", help_lines[0]);
    try std.testing.expectEqualStrings("   help                           shows this message", help_lines[1]);
    try std.testing.expectEqualStrings("   give <player> <id|name> [num]  gives a player a resource", help_lines[2]);
    try std.testing.expectEqualStrings("   kill                           kills the player", help_lines[3]);
    try std.testing.expectEqualStrings("   spawn <mob> [num]              spawns a mob where you look", help_lines[4]);
    try std.testing.expectEqualStrings("   seed <|copy>                   shows world seed", help_lines[5]);
    try std.testing.expectEqualStrings("   time <add|set> <amount>        adds to or sets the world time (0-24000)", help_lines[6]);
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

test "verbs, mobs and player names are all matched exactly" {
    try std.testing.expectEqualStrings("HELP", parse("/HELP", local_user).unknown);
    try std.testing.expectEqualStrings("Give", parse("/Give Player 1", local_user).unknown);
    try std.testing.expectEqualStrings("spawner", parse("/spawner pig", local_user).unknown);
    try std.testing.expectEqualStrings("Pig", parse("/spawn Pig", local_user).missing_mob);
    try std.testing.expectEqualStrings("player", parse("/give player 1", local_user).missing_user);
}

test "resolveId spans both halves of the id space" {
    try std.testing.expectEqual(world.Block.wool, resolveId(35).?.block);
    try std.testing.expectEqual(world.Item.bone, resolveId(352).?.item);
    try std.testing.expectEqual(@as(?world.Id, null), resolveId(0));
    try std.testing.expectEqual(@as(?world.Id, null), resolveId(70000));
}

test "give takes a block or item by its own name" {
    try std.testing.expectEqual(world.Block.stone, parse("/give Player stone", local_user).give.id.block);
    try std.testing.expectEqual(world.Item.diamond, parse("/give Player diamond", local_user).give.id.item);
    try std.testing.expectEqual(world.Block.jack_o_lantern, parse("/give Player jack_o_lantern", local_user).give.id.block);
}

test "a name that is both a block and an item hands over the item" {
    for ([_][]const u8{ "cake", "reed", "brick", "door_wood", "door_iron" }) |name| {
        var line: [64]u8 = undefined;
        const typed = std.fmt.bufPrint(&line, "/give Player {s}", .{name}) catch unreachable;
        const given = parse(typed, local_user).give;
        try std.testing.expect(given.id == .item);
        try std.testing.expectEqualStrings(name, @tagName(given.id.item));
    }
}

test "a numeric id still reaches the block half of a shared name" {
    try std.testing.expectEqual(world.Block.cake, parse("/give Player 92", local_user).give.id.block);
    try std.testing.expectEqual(world.Item.cake, parse("/give Player 354", local_user).give.id.item);
}

test "a name is matched exactly, like every other command word" {
    try std.testing.expectEqualStrings("Stone", parse("/give Player Stone", local_user).unparsed_item);
    try std.testing.expectEqualStrings("banana", parse("/give Player banana", local_user).unparsed_item);
}

test "the count still follows a name the way it follows an id" {
    const given = parse("/give Player cobblestone 32", local_user).give;
    try std.testing.expectEqual(world.Block.cobblestone, given.id.block);
    try std.testing.expectEqual(@as(u8, 32), given.count);
}

test "a name reports the id it resolved to, so the reply reads the same either way" {
    try std.testing.expectEqual(@as(u32, 264), parse("/give Player diamond", local_user).give.raw_id);
    try std.testing.expectEqual(@as(u32, 264), parse("/give Player 264", local_user).give.raw_id);
    try std.testing.expectEqual(@as(u32, 1), parse("/give Player 001", local_user).give.raw_id);
}
