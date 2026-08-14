const std = @import("std");

const world = @import("world");

pub const Id = enum(u8) {
    open_inventory,
    mine_wood,
    build_work_bench,
    build_pickaxe,
    build_furnace,
    acquire_iron,
    build_hoe,
    make_bread,
    bake_cake,
    build_better_pickaxe,
    cook_fish,
    on_a_rail,
    build_sword,
    kill_enemy,
    kill_cow,
    fly_pig,

    pub fn def(self: Id) Def {
        return table[@intFromEnum(self)];
    }

    pub fn statId(self: Id) u32 {
        return stat_base + @intFromEnum(self);
    }
};

pub const Def = struct {
    key: []const u8,
    title: []const u8,
    description: []const u8,
    column: i32,
    row: i32,
    icon: world.Id,
    parent: ?Id,
    special: bool = false,
};

pub const stat_base: u32 = 5242880;

fn block(id: world.Block) world.Id {
    return .{ .block = id };
}

fn item(id: world.Item) world.Id {
    return .{ .item = id };
}

const table = [_]Def{
    .{
        .key = "openInventory",
        .title = "Taking Inventory",
        .description = "Press '%1$s' to open your inventory.",
        .column = 0,
        .row = 0,
        .icon = item(.book),
        .parent = null,
    },
    .{
        .key = "mineWood",
        .title = "Getting Wood",
        .description = "Attack a tree until a block of wood pops out",
        .column = 2,
        .row = 1,
        .icon = block(.log),
        .parent = .open_inventory,
    },
    .{
        .key = "buildWorkBench",
        .title = "Benchmarking",
        .description = "Craft a workbench with four blocks of planks",
        .column = 4,
        .row = -1,
        .icon = block(.workbench),
        .parent = .mine_wood,
    },
    .{
        .key = "buildPickaxe",
        .title = "Time to Mine!",
        .description = "Use planks and sticks to make a pickaxe",
        .column = 4,
        .row = 2,
        .icon = item(.pickaxe_wood),
        .parent = .build_work_bench,
    },
    .{
        .key = "buildFurnace",
        .title = "Hot Topic",
        .description = "Construct a furnace out of eight stone blocks",
        .column = 3,
        .row = 4,
        .icon = block(.burning_furnace),
        .parent = .build_pickaxe,
    },
    .{
        .key = "acquireIron",
        .title = "Acquire Hardware",
        .description = "Smelt an iron ingot",
        .column = 1,
        .row = 4,
        .icon = item(.ingot_iron),
        .parent = .build_furnace,
    },
    .{
        .key = "buildHoe",
        .title = "Time to Farm!",
        .description = "Use planks and sticks to make a hoe",
        .column = 2,
        .row = -3,
        .icon = item(.hoe_wood),
        .parent = .build_work_bench,
    },
    .{
        .key = "makeBread",
        .title = "Bake Bread",
        .description = "Turn wheat into bread",
        .column = -1,
        .row = -3,
        .icon = item(.bread),
        .parent = .build_hoe,
    },
    .{
        .key = "bakeCake",
        .title = "The Lie",
        .description = "Wheat, sugar, milk and eggs!",
        .column = 0,
        .row = -5,
        .icon = item(.cake),
        .parent = .build_hoe,
    },
    .{
        .key = "buildBetterPickaxe",
        .title = "Getting an Upgrade",
        .description = "Construct a better pickaxe",
        .column = 6,
        .row = 2,
        .icon = item(.pickaxe_stone),
        .parent = .build_pickaxe,
    },
    .{
        .key = "cookFish",
        .title = "Delicious Fish",
        .description = "Catch and cook fish!",
        .column = 2,
        .row = 6,
        .icon = item(.fish_cooked),
        .parent = .build_furnace,
    },
    .{
        .key = "onARail",
        .title = "On A Rail",
        .description = "Travel by minecart at least 1 km from where you started ",
        .column = 2,
        .row = 3,
        .icon = block(.rail),
        .parent = .acquire_iron,
        .special = true,
    },
    .{
        .key = "buildSword",
        .title = "Time to Strike!",
        .description = "Use planks and sticks to make a sword",
        .column = 6,
        .row = -1,
        .icon = item(.sword_wood),
        .parent = .build_work_bench,
    },
    .{
        .key = "killEnemy",
        .title = "Monster Hunter",
        .description = "Attack and destroy a monster",
        .column = 8,
        .row = -1,
        .icon = item(.bone),
        .parent = .build_sword,
    },
    .{
        .key = "killCow",
        .title = "Cow Tipper",
        .description = "Harvest some leather",
        .column = 7,
        .row = -3,
        .icon = item(.leather),
        .parent = .build_sword,
    },
    .{
        .key = "flyPig",
        .title = "When Pigs Fly",
        .description = "Fly a pig off a cliff",
        .column = 8,
        .row = -4,
        .icon = item(.saddle),
        .parent = .kill_cow,
        .special = true,
    },
};

pub fn forCrafted(id: world.Id) ?Id {
    return switch (id) {
        .block => |value| switch (value) {
            .workbench => .build_work_bench,
            .furnace => .build_furnace,
            else => null,
        },
        .item => |value| switch (value) {
            .pickaxe_wood => .build_pickaxe,
            .hoe_wood => .build_hoe,
            .bread => .make_bread,
            .cake => .bake_cake,
            .pickaxe_stone => .build_better_pickaxe,
            .sword_wood => .build_sword,
            else => null,
        },
    };
}

pub fn forSmelted(id: world.Id) ?Id {
    const smelted = switch (id) {
        .block => return null,
        .item => |value| value,
    };
    return switch (smelted) {
        .ingot_iron => .acquire_iron,
        .fish_cooked => .cook_fish,
        else => null,
    };
}

pub const key_placeholder = "%1$s";

pub fn describe(buffer: []u8, id: Id, inventory_key: []const u8) []const u8 {
    const raw = id.def().description;
    const at = std.mem.indexOf(u8, raw, key_placeholder) orelse return raw;
    return std.fmt.bufPrint(buffer, "{s}{s}{s}", .{
        raw[0..at],
        inventory_key,
        raw[at + key_placeholder.len ..],
    }) catch raw;
}

pub const get_banner = "Achievement get!";
pub const taken_banner = "Taken!";

pub fn requiresText(buffer: []u8, parent: Id) []const u8 {
    return std.fmt.bufPrint(buffer, "Requires '{s}'", .{parent.def().title}) catch "";
}

pub const Bounds = struct {
    min_column: i32,
    min_row: i32,
    max_column: i32,
    max_row: i32,
};

pub const bounds: Bounds = blk: {
    var found: Bounds = .{ .min_column = 0, .min_row = 0, .max_column = 0, .max_row = 0 };
    for (table) |entry| {
        found.min_column = @min(found.min_column, entry.column);
        found.min_row = @min(found.min_row, entry.row);
        found.max_column = @max(found.max_column, entry.column);
        found.max_row = @max(found.max_row, entry.row);
    }
    break :blk found;
};

pub fn fromStatId(id: u32) ?Id {
    if (id < stat_base) return null;
    const offset = id - stat_base;
    if (offset >= table.len) return null;
    return @enumFromInt(@as(u8, @intCast(offset)));
}

pub fn find(key: []const u8) ?Id {
    for (table, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.key, key)) return @enumFromInt(@as(u8, @intCast(index)));
    }
    return null;
}

fn langValue(key: []const u8) ?[]const u8 {
    const assets = @import("assets");
    var lines = std.mem.tokenizeAny(u8, assets.lang.stats_US_lang.bytes, "\r\n");
    while (lines.next()) |line| {
        const split = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (std.mem.eql(u8, line[0..split], key)) return line[split + 1 ..];
    }
    return null;
}

test "every achievement's title and description come from the real stats_US lang keys" {
    var buffer: [64]u8 = undefined;

    for (std.enums.values(Id)) |id| {
        const entry = id.def();

        const title_key = try std.fmt.bufPrint(&buffer, "achievement.{s}", .{entry.key});
        try std.testing.expectEqualStrings(langValue(title_key).?, entry.title);
    }

    for (std.enums.values(Id)) |id| {
        const entry = id.def();
        const desc_key = try std.fmt.bufPrint(&buffer, "achievement.{s}.desc", .{entry.key});
        try std.testing.expectEqualStrings(langValue(desc_key).?, entry.description);
    }

    try std.testing.expectEqualStrings(langValue("achievement.get").?, get_banner);
    try std.testing.expectEqualStrings(langValue("achievement.taken").?, taken_banner);
}

test "the inventory hint fills the key placeholder the way StatStringFormatKeyInv does" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Press 'E' to open your inventory.",
        describe(&buffer, .open_inventory, "E"),
    );
    try std.testing.expectEqualStrings(
        "Attack a tree until a block of wood pops out",
        describe(&buffer, .mine_wood, "E"),
    );
}

test "achievement stat ids run from AchievementList's base in declaration order" {
    try std.testing.expectEqual(@as(u32, 5242880), Id.open_inventory.statId());
    try std.testing.expectEqual(@as(u32, 5242880 + 11), Id.on_a_rail.statId());
    try std.testing.expectEqual(@as(u32, 5242880 + 15), Id.fly_pig.statId());

    for (std.enums.values(Id)) |id| {
        try std.testing.expectEqual(id, fromStatId(id.statId()).?);
    }
    try std.testing.expectEqual(@as(?Id, null), fromStatId(stat_base + 16));
    try std.testing.expectEqual(@as(?Id, null), fromStatId(2000));
}

test "the tree hangs off Taking Inventory the way AchievementList builds it" {
    try std.testing.expectEqual(@as(?Id, null), Id.open_inventory.def().parent);

    for (std.enums.values(Id)) |id| {
        if (id == .open_inventory) continue;
        var walk = id;
        var steps: usize = 0;
        while (walk.def().parent) |parent| : (steps += 1) {
            try std.testing.expect(steps < table.len);
            walk = parent;
        }
        try std.testing.expectEqual(Id.open_inventory, walk);
    }
}

test "only On A Rail and When Pigs Fly are drawn on the special plate" {
    for (std.enums.values(Id)) |id| {
        const want = id == .on_a_rail or id == .fly_pig;
        try std.testing.expectEqual(want, id.def().special);
    }
}

test "the display bounds span the columns and rows the achievements occupy" {
    try std.testing.expectEqual(@as(i32, -1), bounds.min_column);
    try std.testing.expectEqual(@as(i32, -5), bounds.min_row);
    try std.testing.expectEqual(@as(i32, 8), bounds.max_column);
    try std.testing.expectEqual(@as(i32, 6), bounds.max_row);
}

test "the crafting bench hands out the achievements SlotCrafting checks for" {
    try std.testing.expectEqual(@as(?Id, .build_work_bench), forCrafted(.{ .block = .workbench }));
    try std.testing.expectEqual(@as(?Id, .build_furnace), forCrafted(.{ .block = .furnace }));
    try std.testing.expectEqual(@as(?Id, .build_pickaxe), forCrafted(.{ .item = .pickaxe_wood }));
    try std.testing.expectEqual(@as(?Id, .build_hoe), forCrafted(.{ .item = .hoe_wood }));
    try std.testing.expectEqual(@as(?Id, .make_bread), forCrafted(.{ .item = .bread }));
    try std.testing.expectEqual(@as(?Id, .bake_cake), forCrafted(.{ .item = .cake }));
    try std.testing.expectEqual(@as(?Id, .build_better_pickaxe), forCrafted(.{ .item = .pickaxe_stone }));
    try std.testing.expectEqual(@as(?Id, .build_sword), forCrafted(.{ .item = .sword_wood }));

    try std.testing.expectEqual(@as(?Id, null), forCrafted(.{ .block = .burning_furnace }));
    try std.testing.expectEqual(@as(?Id, null), forCrafted(.{ .item = .pickaxe_iron }));
    try std.testing.expectEqual(@as(?Id, null), forCrafted(.{ .item = .ingot_iron }));
}

test "the furnace hands out only the two achievements SlotFurnace checks for" {
    try std.testing.expectEqual(@as(?Id, .acquire_iron), forSmelted(.{ .item = .ingot_iron }));
    try std.testing.expectEqual(@as(?Id, .cook_fish), forSmelted(.{ .item = .fish_cooked }));

    try std.testing.expectEqual(@as(?Id, null), forSmelted(.{ .item = .ingot_gold }));
    try std.testing.expectEqual(@as(?Id, null), forSmelted(.{ .block = .glass }));
    try std.testing.expectEqual(@as(?Id, null), forSmelted(.{ .item = .pickaxe_wood }));
}
