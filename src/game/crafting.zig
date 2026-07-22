const std = @import("std");

const world = @import("world");
const dye_blue: u16 = world.item.dye_meta_lapis;

const Inventory = @import("inventory.zig");

pub const player_grid_size: u8 = 2;
pub const workbench_grid_size: u8 = 3;

const max_pattern = workbench_grid_size * workbench_grid_size;

pub const Ingredient = struct { id: world.Id, meta: ?u16 = null };

pub const Recipe = struct {
    width: u8,
    height: u8,
    pattern: [max_pattern]?Ingredient,
    output_id: world.Id,
    output_count: u8,
    output_meta: u16 = 0,
};

fn b(id: world.Block) ?Ingredient {
    return .{ .id = .{ .block = id } };
}

fn i(id: world.Item) ?Ingredient {
    return .{ .id = .{ .item = id } };
}

fn dye(meta: u16) ?Ingredient {
    return .{ .id = .{ .item = .dye }, .meta = meta };
}

fn shaped(
    comptime width: u8,
    comptime height: u8,
    comptime cells: []const ?Ingredient,
    comptime output: world.Id,
    comptime count: u8,
) Recipe {
    var pattern: [max_pattern]?Ingredient = @splat(null);
    for (cells, 0..) |cell, index| pattern[index] = cell;
    return .{ .width = width, .height = height, .pattern = pattern, .output_id = output, .output_count = count };
}

fn shapedMeta(
    comptime width: u8,
    comptime height: u8,
    comptime cells: []const ?Ingredient,
    comptime output: world.Id,
    comptime count: u8,
    comptime meta: u16,
) Recipe {
    var recipe = shaped(width, height, cells, output, count);
    recipe.output_meta = meta;
    return recipe;
}

fn storageBlock(ingredient: ?Ingredient, output: world.Block) Recipe {
    return shaped(3, 3, &@as([9]?Ingredient, @splat(ingredient)), .{ .block = output }, 1);
}

fn family(
    comptime width: u8,
    comptime height: u8,
    comptime pattern: []const u8,
    comptime heads: []const ?Ingredient,
    comptime outputs: []const world.Item,
) [outputs.len]Recipe {
    var list: [outputs.len]Recipe = undefined;
    for (heads, outputs, &list) |head, output, *recipe| {
        var cells: [max_pattern]?Ingredient = @splat(null);
        for (pattern, 0..) |symbol, index| {
            cells[index] = switch (symbol) {
                'X' => head,
                '#' => i(.stick),
                else => null,
            };
        }
        recipe.* = .{
            .width = width,
            .height = height,
            .pattern = cells,
            .output_id = .{ .item = output },
            .output_count = 1,
        };
    }
    return list;
}

const tool_heads = [_]?Ingredient{ b(.planks), b(.cobblestone), i(.ingot_iron), i(.diamond), i(.ingot_gold) };

const armor_heads = [_]?Ingredient{ i(.leather), i(.ingot_iron), i(.diamond), i(.ingot_gold) };

const tool_recipes =
    family(1, 3, "X" ++ "X" ++ "#", &tool_heads, &.{ .sword_wood, .sword_stone, .sword_iron, .sword_diamond, .sword_gold }) ++
    family(3, 3, "XXX" ++ " # " ++ " # ", &tool_heads, &.{ .pickaxe_wood, .pickaxe_stone, .pickaxe_iron, .pickaxe_diamond, .pickaxe_gold }) ++
    family(1, 3, "X" ++ "#" ++ "#", &tool_heads, &.{ .shovel_wood, .shovel_stone, .shovel_iron, .shovel_diamond, .shovel_gold }) ++
    family(2, 3, "XX" ++ "X#" ++ " #", &tool_heads, &.{ .axe_wood, .axe_stone, .axe_iron, .axe_diamond, .axe_gold }) ++
    family(2, 3, "XX" ++ " #" ++ " #", &tool_heads, &.{ .hoe_wood, .hoe_stone, .hoe_iron, .hoe_diamond, .hoe_gold });

const armor_recipes =
    family(3, 2, "XXX" ++ "X X", &armor_heads, &.{ .helmet_leather, .helmet_iron, .helmet_diamond, .helmet_gold }) ++
    family(3, 3, "X X" ++ "XXX" ++ "XXX", &armor_heads, &.{ .chestplate_leather, .chestplate_iron, .chestplate_diamond, .chestplate_gold }) ++
    family(3, 3, "XXX" ++ "X X" ++ "X X", &armor_heads, &.{ .leggings_leather, .leggings_iron, .leggings_diamond, .leggings_gold }) ++
    family(3, 2, "X X" ++ "X X", &armor_heads, &.{ .boots_leather, .boots_iron, .boots_diamond, .boots_gold });

const recipes = tool_recipes ++ armor_recipes ++ [_]Recipe{
    shaped(1, 1, &.{b(.log)}, .{ .block = .planks }, 4),
    shaped(1, 2, &.{ b(.planks), b(.planks) }, .{ .item = .stick }, 4),
    shaped(2, 2, &.{ i(.clay_ball), i(.clay_ball), i(.clay_ball), i(.clay_ball) }, .{ .block = .clay }, 1),
    shaped(2, 2, &.{ b(.planks), b(.planks), b(.planks), b(.planks) }, .{ .block = .workbench }, 1),
    shaped(2, 2, &.{ i(.snowball), i(.snowball), i(.snowball), i(.snowball) }, .{ .block = .snow_block }, 1),
    shaped(2, 2, &.{ b(.sand), b(.sand), b(.sand), b(.sand) }, .{ .block = .sandstone }, 1),
    shaped(2, 2, &.{ i(.brick), i(.brick), i(.brick), i(.brick) }, .{ .block = .brick }, 1),
    shaped(2, 2, &.{ i(.string), i(.string), i(.string), i(.string) }, .{ .block = .wool }, 1),
    shaped(2, 2, &.{ i(.glowstone_dust), i(.glowstone_dust), i(.glowstone_dust), i(.glowstone_dust) }, .{ .block = .glowstone }, 1),
    shaped(1, 2, &.{ i(.coal), i(.stick) }, .{ .block = .torch }, 4),
    shaped(3, 3, &.{
        null,      i(.stick), i(.string),
        i(.stick), null,      i(.string),
        null,      i(.stick), i(.string),
    }, .{ .item = .bow }, 1),
    shaped(1, 3, &.{ i(.flint), i(.stick), i(.feather) }, .{ .item = .arrow }, 4),
    shaped(3, 3, &.{
        b(.planks), b(.planks), b(.planks),
        b(.planks), b(.planks), b(.planks),
        null,       i(.stick),  null,
    }, .{ .item = .sign }, 1),
    shaped(1, 1, &.{i(.reed)}, .{ .item = .sugar }, 1),
    shaped(3, 1, &.{ i(.reed), i(.reed), i(.reed) }, .{ .item = .paper }, 3),
    shaped(1, 3, &.{ i(.paper), i(.paper), i(.paper) }, .{ .item = .book }, 1),
    shaped(3, 1, &.{ i(.wheat), i(.wheat), i(.wheat) }, .{ .item = .bread }, 1),
    shaped(3, 3, &.{
        i(.bucket_milk), i(.bucket_milk), i(.bucket_milk),
        i(.sugar),       i(.egg),         i(.sugar),
        i(.wheat),       i(.wheat),       i(.wheat),
    }, .{ .item = .cake }, 1),
    shaped(3, 2, &.{ b(.planks), null, b(.planks), null, b(.planks), null }, .{ .item = .bowl }, 4),
    shaped(2, 3, &.{
        b(.planks), b(.planks),
        b(.planks), b(.planks),
        b(.planks), b(.planks),
    }, .{ .item = .door_wood }, 1),
    shaped(2, 3, &.{
        i(.ingot_iron), i(.ingot_iron),
        i(.ingot_iron), i(.ingot_iron),
        i(.ingot_iron), i(.ingot_iron),
    }, .{ .item = .door_iron }, 1),
    shaped(3, 2, &.{
        b(.planks), b(.planks), b(.planks),
        b(.planks), b(.planks), b(.planks),
    }, .{ .block = .trapdoor }, 2),
    shaped(3, 2, &.{
        i(.ingot_iron), null,           i(.ingot_iron),
        null,           i(.ingot_iron), null,
    }, .{ .item = .bucket }, 1),
    shapedMeta(3, 1, &.{ b(.cobblestone), b(.cobblestone), b(.cobblestone) }, .{ .block = .slab }, 3, world.block.slab_cobblestone),
    shapedMeta(3, 1, &.{ b(.stone), b(.stone), b(.stone) }, .{ .block = .slab }, 3, world.block.slab_stone),
    shapedMeta(3, 1, &.{ b(.sandstone), b(.sandstone), b(.sandstone) }, .{ .block = .slab }, 3, world.block.slab_sandstone),
    shapedMeta(3, 1, &.{ b(.planks), b(.planks), b(.planks) }, .{ .block = .slab }, 3, world.block.slab_wood),
    shaped(3, 3, &.{
        b(.planks), null,       null,
        b(.planks), b(.planks), null,
        b(.planks), b(.planks), b(.planks),
    }, .{ .block = .stairs_wood }, 4),
    shaped(3, 3, &.{
        b(.cobblestone), null,            null,
        b(.cobblestone), b(.cobblestone), null,
        b(.cobblestone), b(.cobblestone), b(.cobblestone),
    }, .{ .block = .stairs_cobblestone }, 4),
    shaped(1, 3, &.{ b(.mushroom_red), b(.mushroom_brown), i(.bowl) }, .{ .item = .mushroom_stew }, 1),
    shaped(1, 3, &.{ b(.mushroom_brown), b(.mushroom_red), i(.bowl) }, .{ .item = .mushroom_stew }, 1),
    shaped(3, 3, &.{
        b(.cobblestone), b(.cobblestone), b(.cobblestone),
        b(.cobblestone), null,            b(.cobblestone),
        b(.cobblestone), b(.cobblestone), b(.cobblestone),
    }, .{ .block = .furnace }, 1),
    shaped(3, 3, &.{
        b(.planks), b(.planks),  b(.planks),
        b(.planks), i(.diamond), b(.planks),
        b(.planks), b(.planks),  b(.planks),
    }, .{ .block = .jukebox }, 1),
    shaped(3, 3, &.{
        b(.planks), b(.planks),   b(.planks),
        b(.planks), i(.redstone), b(.planks),
        b(.planks), b(.planks),   b(.planks),
    }, .{ .block = .note_block }, 1),
    shaped(3, 3, &.{
        b(.planks), b(.planks), b(.planks),
        i(.book),   i(.book),   i(.book),
        b(.planks), b(.planks), b(.planks),
    }, .{ .block = .bookshelf }, 1),
    shaped(3, 3, &.{
        i(.gunpowder), b(.sand),      i(.gunpowder),
        b(.sand),      i(.gunpowder), b(.sand),
        i(.gunpowder), b(.sand),      i(.gunpowder),
    }, .{ .block = .tnt }, 1),
    storageBlock(i(.ingot_gold), .block_gold),
    storageBlock(i(.ingot_iron), .block_iron),
    storageBlock(i(.diamond), .block_diamond),
    storageBlock(dye(world.item.dye_meta_lapis), .block_lapis),
    shaped(1, 1, &.{b(.block_gold)}, .{ .item = .ingot_gold }, 9),
    shaped(1, 1, &.{b(.block_iron)}, .{ .item = .ingot_iron }, 9),
    shaped(1, 1, &.{b(.block_diamond)}, .{ .item = .diamond }, 9),
    shapedMeta(1, 1, &.{b(.block_lapis)}, .{ .item = .dye }, 9, world.item.dye_meta_lapis),
};

const max_shapeless = 4;

pub const ShapelessRecipe = struct {
    ingredients: [max_shapeless]?Ingredient,
    output_id: world.Id,
    output_count: u8,
    output_meta: u16 = 0,
};

fn shapeless(ingredients: []const ?Ingredient, output: world.Id, count: u8, meta: u16) ShapelessRecipe {
    var list: [max_shapeless]?Ingredient = @splat(null);
    for (ingredients, 0..) |ingredient, index| list[index] = ingredient;
    return .{ .ingredients = list, .output_id = output, .output_count = count, .output_meta = meta };
}

fn dyeFrom(ingredients: []const ?Ingredient, count: u8, meta: u16) ShapelessRecipe {
    return shapeless(ingredients, .{ .item = .dye }, count, meta);
}

const dye_black: u16 = 0;
const dye_red: u16 = 1;
const dye_green: u16 = 2;
const dye_purple: u16 = 5;
const dye_cyan: u16 = 6;
const dye_light_gray: u16 = 7;
const dye_gray: u16 = 8;
const dye_pink: u16 = 9;
const dye_lime: u16 = 10;
const dye_yellow: u16 = 11;
const dye_light_blue: u16 = 12;
const dye_magenta: u16 = 13;
const dye_orange: u16 = 14;
const dye_white: u16 = 15;

fn woolDyeRecipes() [16]ShapelessRecipe {
    var list: [16]ShapelessRecipe = undefined;
    for (0..16) |index| {
        const meta: u16 = @intCast(index);
        list[index] = shapeless(
            &.{ dye(meta), .{ .id = .{ .block = .wool }, .meta = 0 } },
            .{ .block = .wool },
            1,
            ~@as(u4, @intCast(meta)),
        );
    }
    return list;
}

const shapeless_recipes = woolDyeRecipes() ++ [_]ShapelessRecipe{
    dyeFrom(&.{b(.dandelion)}, 2, dye_yellow),
    dyeFrom(&.{b(.rose)}, 2, dye_red),
    dyeFrom(&.{i(.bone)}, 3, dye_white),
    dyeFrom(&.{ dye(dye_red), dye(dye_white) }, 2, dye_pink),
    dyeFrom(&.{ dye(dye_red), dye(dye_yellow) }, 2, dye_orange),
    dyeFrom(&.{ dye(dye_green), dye(dye_white) }, 2, dye_lime),
    dyeFrom(&.{ dye(dye_black), dye(dye_white) }, 2, dye_gray),
    dyeFrom(&.{ dye(dye_gray), dye(dye_white) }, 2, dye_light_gray),
    dyeFrom(&.{ dye(dye_black), dye(dye_white), dye(dye_white) }, 3, dye_light_gray),
    dyeFrom(&.{ dye(dye_blue), dye(dye_white) }, 2, dye_light_blue),
    dyeFrom(&.{ dye(dye_blue), dye(dye_green) }, 2, dye_cyan),
    dyeFrom(&.{ dye(dye_blue), dye(dye_red) }, 2, dye_purple),
    dyeFrom(&.{ dye(dye_purple), dye(dye_pink) }, 2, dye_magenta),
    dyeFrom(&.{ dye(dye_blue), dye(dye_red), dye(dye_pink) }, 3, dye_magenta),
    dyeFrom(&.{ dye(dye_blue), dye(dye_red), dye(dye_red), dye(dye_white) }, 4, dye_magenta),
};

fn matchesAt(
    grid: []const ?Inventory.ItemStack,
    size: u8,
    recipe: Recipe,
    offset_x: u8,
    offset_y: u8,
    mirrored: bool,
) bool {
    for (0..size) |y| {
        for (0..size) |x| {
            const rx = @as(i32, @intCast(x)) - @as(i32, offset_x);
            const ry = @as(i32, @intCast(y)) - @as(i32, offset_y);
            var want: ?Ingredient = null;
            if (rx >= 0 and ry >= 0 and rx < recipe.width and ry < recipe.height) {
                const px: u8 = if (mirrored)
                    recipe.width - 1 - @as(u8, @intCast(rx))
                else
                    @intCast(rx);

                want = recipe.pattern[px + @as(u8, @intCast(ry)) * recipe.width];
            }
            const have = grid[x + y * size];
            if (have == null and want == null) continue;
            if (have == null or want == null) return false;
            if (!have.?.id.eql(want.?.id)) return false;
            if (want.?.meta) |m| {
                if (have.?.meta != m) return false;
            }
        }
    }
    return true;
}

fn matchesShapeless(grid: []const ?Inventory.ItemStack, recipe: ShapelessRecipe) bool {
    var used: [max_shapeless]bool = @splat(false);
    var wanted: usize = 0;
    for (recipe.ingredients) |ingredient| {
        if (ingredient != null) wanted += 1;
    }

    var matched: usize = 0;
    for (grid) |maybe_stack| {
        const stack = maybe_stack orelse continue;
        var found = false;
        for (recipe.ingredients, 0..) |maybe_ingredient, index| {
            const ingredient = maybe_ingredient orelse continue;
            if (used[index]) continue;
            if (!stack.id.eql(ingredient.id)) continue;
            if (ingredient.meta) |m| {
                if (stack.meta != m) continue;
            }
            used[index] = true;
            matched += 1;
            found = true;
            break;
        }
        if (!found) return false;
    }
    return matched == wanted;
}

pub fn findMatch(grid: []const ?Inventory.ItemStack, size: u8) ?Inventory.ItemStack {
    for (recipes) |recipe| {
        if (recipe.width > size or recipe.height > size) continue;
        for (0..size + 1 - recipe.height) |offset_y| {
            for (0..size + 1 - recipe.width) |offset_x| {
                if (matchesAt(grid, size, recipe, @intCast(offset_x), @intCast(offset_y), true) or
                    matchesAt(grid, size, recipe, @intCast(offset_x), @intCast(offset_y), false))
                {
                    return .{ .id = recipe.output_id, .count = recipe.output_count, .meta = recipe.output_meta };
                }
            }
        }
    }

    for (shapeless_recipes) |recipe| {
        if (matchesShapeless(grid, recipe)) {
            return .{ .id = recipe.output_id, .count = recipe.output_count, .meta = recipe.output_meta };
        }
    }
    return null;
}

pub fn isCraftable(id: world.Id) bool {
    for (recipes) |recipe| {
        if (recipe.output_id.eql(id)) return true;
    }
    for (shapeless_recipes) |recipe| {
        if (recipe.output_id.eql(id)) return true;
    }
    return false;
}

pub fn consume(grid: []?Inventory.ItemStack) void {
    for (grid) |*slot| {
        if (slot.*) |*stack| {
            stack.count -= 1;
            if (stack.count == 0) slot.* = null;
        }
    }
}

test "log crafts into planks in any grid cell" {
    var grid: [4]?Inventory.ItemStack = @splat(null);
    grid[3] = .{ .id = .{ .block = .log }, .count = 1, .meta = 2 };
    const result = findMatch(&grid, player_grid_size).?;
    try std.testing.expectEqual(world.Id{ .block = .planks }, result.id);
    try std.testing.expectEqual(@as(u8, 4), result.count);
}

test "two stacked planks craft into sticks" {
    var grid: [4]?Inventory.ItemStack = @splat(null);
    grid[0] = .{ .id = .{ .block = .planks }, .count = 5 };
    grid[2] = .{ .id = .{ .block = .planks }, .count = 5 };
    const result = findMatch(&grid, player_grid_size).?;
    try std.testing.expectEqual(world.Id{ .item = .stick }, result.id);
    try std.testing.expectEqual(@as(u8, 4), result.count);
}

test "planks side by side do not match the stick recipe" {
    var grid: [4]?Inventory.ItemStack = @splat(null);
    grid[0] = .{ .id = .{ .block = .planks }, .count = 5 };
    grid[1] = .{ .id = .{ .block = .planks }, .count = 5 };
    try std.testing.expect(findMatch(&grid, player_grid_size) == null);
}

test "four clay balls fill the grid to craft a clay block" {
    var grid: [4]?Inventory.ItemStack = @splat(null);
    for (&grid) |*slot| slot.* = .{ .id = .{ .item = .clay_ball }, .count = 1 };
    const result = findMatch(&grid, player_grid_size).?;
    try std.testing.expectEqual(world.Id{ .block = .clay }, result.id);
    try std.testing.expectEqual(@as(u8, 1), result.count);
}

test "three clay balls are not enough to fill the grid" {
    var grid: [4]?Inventory.ItemStack = @splat(null);
    grid[0] = .{ .id = .{ .item = .clay_ball }, .count = 1 };
    grid[1] = .{ .id = .{ .item = .clay_ball }, .count = 1 };
    grid[2] = .{ .id = .{ .item = .clay_ball }, .count = 1 };
    try std.testing.expect(findMatch(&grid, player_grid_size) == null);
}

test "an unrelated extra item in the grid blocks the match" {
    var grid: [4]?Inventory.ItemStack = @splat(null);
    grid[0] = .{ .id = .{ .block = .log }, .count = 1 };
    grid[1] = .{ .id = .{ .block = .dirt }, .count = 1 };
    try std.testing.expect(findMatch(&grid, player_grid_size) == null);
}

test "consume removes one item from every filled grid slot" {
    var grid: [4]?Inventory.ItemStack = @splat(null);
    grid[0] = .{ .id = .{ .block = .planks }, .count = 1 };
    grid[2] = .{ .id = .{ .block = .planks }, .count = 2 };
    consume(&grid);
    try std.testing.expect(grid[0] == null);
    try std.testing.expectEqual(@as(u8, 1), grid[2].?.count);
}

test "a filled grid of planks crafts a workbench" {
    var grid: [4]?Inventory.ItemStack = @splat(null);
    for (&grid) |*slot| slot.* = .{ .id = .{ .block = .planks }, .count = 1 };
    const result = findMatch(&grid, player_grid_size).?;
    try std.testing.expectEqual(world.Id{ .block = .workbench }, result.id);
    try std.testing.expectEqual(@as(u8, 1), result.count);
}

test "a ring of cobblestone crafts a furnace, but a filled grid does not" {
    var ring: [9]?Inventory.ItemStack = @splat(.{ .id = .{ .block = .cobblestone }, .count = 1 });
    ring[4] = null;
    try std.testing.expectEqual(world.Id{ .block = .furnace }, findMatch(&ring, workbench_grid_size).?.id);

    var filled: [9]?Inventory.ItemStack = @splat(.{ .id = .{ .block = .cobblestone }, .count = 1 });
    try std.testing.expect(findMatch(&filled, workbench_grid_size) == null);
}

test "the other filled-grid recipes each craft their block" {
    const cases = [_]struct { ingredient: world.Id, output: world.Id }{
        .{ .ingredient = .{ .item = .snowball }, .output = .{ .block = .snow_block } },
        .{ .ingredient = .{ .item = .brick }, .output = .{ .block = .brick } },
        .{ .ingredient = .{ .item = .string }, .output = .{ .block = .wool } },
        .{ .ingredient = .{ .item = .glowstone_dust }, .output = .{ .block = .glowstone } },
    };
    for (cases) |case| {
        var grid: [4]?Inventory.ItemStack = @splat(null);
        for (&grid) |*slot| slot.* = .{ .id = case.ingredient, .count = 1 };
        try std.testing.expectEqual(case.output, findMatch(&grid, player_grid_size).?.id);
    }
}

test "wool crafted from string comes out white" {
    var grid: [4]?Inventory.ItemStack = @splat(null);
    for (&grid) |*slot| slot.* = .{ .id = .{ .item = .string }, .count = 1 };
    try std.testing.expectEqual(@as(u16, 0), findMatch(&grid, player_grid_size).?.meta);
}

test "a single sugar cane crafts sugar in any grid cell" {
    for (0..4) |cell| {
        var grid: [4]?Inventory.ItemStack = @splat(null);
        grid[cell] = .{ .id = .{ .item = .reed }, .count = 1 };
        try std.testing.expectEqual(world.Id{ .item = .sugar }, findMatch(&grid, player_grid_size).?.id);
    }
}

test "a three-wide recipe cannot be crafted in the player's 2x2 grid" {
    var small: [4]?Inventory.ItemStack = @splat(null);
    for (&small) |*slot| slot.* = .{ .id = .{ .item = .reed }, .count = 1 };
    try std.testing.expect(findMatch(&small, player_grid_size) == null);

    var large: [9]?Inventory.ItemStack = @splat(null);
    for (0..3) |cell| large[cell] = .{ .id = .{ .item = .reed }, .count = 1 };
    const result = findMatch(&large, workbench_grid_size).?;
    try std.testing.expectEqual(world.Id{ .item = .paper }, result.id);
    try std.testing.expectEqual(@as(u8, 3), result.count);
}

test "the shifted-window search finds a small recipe anywhere in the 3x3 grid" {
    for (0..workbench_grid_size) |offset| {
        var grid: [9]?Inventory.ItemStack = @splat(null);
        grid[offset] = .{ .id = .{ .item = .paper }, .count = 1 };
        grid[offset + 3] = .{ .id = .{ .item = .paper }, .count = 1 };
        grid[offset + 6] = .{ .id = .{ .item = .paper }, .count = 1 };
        try std.testing.expectEqual(world.Id{ .item = .book }, findMatch(&grid, workbench_grid_size).?.id);
    }
}

test "the bookshelf needs its planks and books in the right rows" {
    var grid: [9]?Inventory.ItemStack = @splat(null);
    for (0..3) |col| {
        grid[col] = .{ .id = .{ .block = .planks }, .count = 1 };
        grid[col + 3] = .{ .id = .{ .item = .book }, .count = 1 };
        grid[col + 6] = .{ .id = .{ .block = .planks }, .count = 1 };
    }
    try std.testing.expectEqual(world.Id{ .block = .bookshelf }, findMatch(&grid, workbench_grid_size).?.id);

    grid[0] = .{ .id = .{ .item = .book }, .count = 1 };
    try std.testing.expect(findMatch(&grid, workbench_grid_size) == null);
}

test "mushroom stew accepts either mushroom on top" {
    for ([2][2]world.Block{
        .{ .mushroom_red, .mushroom_brown },
        .{ .mushroom_brown, .mushroom_red },
    }) |order| {
        var grid: [9]?Inventory.ItemStack = @splat(null);
        grid[0] = .{ .id = .{ .block = order[0] }, .count = 1 };
        grid[3] = .{ .id = .{ .block = order[1] }, .count = 1 };
        grid[6] = .{ .id = .{ .item = .bowl }, .count = 1 };
        try std.testing.expectEqual(world.Id{ .item = .mushroom_stew }, findMatch(&grid, workbench_grid_size).?.id);
    }
}

test "planks craft four bowls in a v shape" {
    var grid: [9]?Inventory.ItemStack = @splat(null);
    grid[0] = .{ .id = .{ .block = .planks }, .count = 1 };
    grid[2] = .{ .id = .{ .block = .planks }, .count = 1 };
    grid[4] = .{ .id = .{ .block = .planks }, .count = 1 };
    const result = findMatch(&grid, workbench_grid_size).?;
    try std.testing.expectEqual(world.Id{ .item = .bowl }, result.id);
    try std.testing.expectEqual(@as(u8, 4), result.count);
}

test "storage blocks round-trip back into nine items" {
    var packed_grid: [9]?Inventory.ItemStack = @splat(null);
    for (&packed_grid) |*slot| slot.* = .{ .id = .{ .item = .diamond }, .count = 1 };
    try std.testing.expectEqual(world.Id{ .block = .block_diamond }, findMatch(&packed_grid, workbench_grid_size).?.id);

    var single: [4]?Inventory.ItemStack = @splat(null);
    single[0] = .{ .id = .{ .block = .block_diamond }, .count = 1 };
    const unpacked = findMatch(&single, player_grid_size).?;
    try std.testing.expectEqual(world.Id{ .item = .diamond }, unpacked.id);
    try std.testing.expectEqual(@as(u8, 9), unpacked.count);
}

test "the lapis block recipe rejects other dye colours and keeps lapis metadata" {
    var grid: [9]?Inventory.ItemStack = @splat(null);
    for (&grid) |*slot| slot.* = .{ .id = .{ .item = .dye }, .count = 1, .meta = world.item.dye_meta_lapis };
    try std.testing.expectEqual(world.Id{ .block = .block_lapis }, findMatch(&grid, workbench_grid_size).?.id);

    for (&grid) |*slot| slot.* = .{ .id = .{ .item = .dye }, .count = 1, .meta = 0 };
    try std.testing.expect(findMatch(&grid, workbench_grid_size) == null);

    var single: [4]?Inventory.ItemStack = @splat(null);
    single[0] = .{ .id = .{ .block = .block_lapis }, .count = 1 };
    const unpacked = findMatch(&single, player_grid_size).?;
    try std.testing.expectEqual(@as(u16, world.item.dye_meta_lapis), unpacked.meta);
    try std.testing.expectEqual(@as(u8, 9), unpacked.count);
}

test "a flower dyes into two of its colour anywhere in the grid" {
    const cases = [_]struct { flower: world.Block, meta: u16 }{
        .{ .flower = .dandelion, .meta = dye_yellow },
        .{ .flower = .rose, .meta = dye_red },
    };
    for (cases) |case| {
        var grid: [9]?Inventory.ItemStack = @splat(null);
        grid[4] = .{ .id = .{ .block = case.flower }, .count = 1 };
        const result = findMatch(&grid, workbench_grid_size).?;
        try std.testing.expectEqual(world.Id{ .item = .dye }, result.id);
        try std.testing.expectEqual(case.meta, result.meta);
        try std.testing.expectEqual(@as(u8, 2), result.count);
    }
}

test "a flower dyes in the player's 2x2 grid too, since shapeless recipes have no shape" {
    var grid: [4]?Inventory.ItemStack = @splat(null);
    grid[3] = .{ .id = .{ .block = .rose }, .count = 1 };
    try std.testing.expectEqual(@as(u16, dye_red), findMatch(&grid, player_grid_size).?.meta);
}

test "mixing two dyes ignores which cells they sit in" {
    for ([2][2]usize{ .{ 0, 8 }, .{ 5, 2 } }) |cells| {
        var grid: [9]?Inventory.ItemStack = @splat(null);
        grid[cells[0]] = .{ .id = .{ .item = .dye }, .count = 1, .meta = dye_blue };
        grid[cells[1]] = .{ .id = .{ .item = .dye }, .count = 1, .meta = dye_red };
        const result = findMatch(&grid, workbench_grid_size).?;
        try std.testing.expectEqual(@as(u16, dye_purple), result.meta);
        try std.testing.expectEqual(@as(u8, 2), result.count);
    }
}

test "a shapeless recipe needs its exact ingredients, no more and no fewer" {
    var grid: [9]?Inventory.ItemStack = @splat(null);
    grid[0] = .{ .id = .{ .item = .dye }, .count = 1, .meta = dye_blue };
    try std.testing.expect(findMatch(&grid, workbench_grid_size) == null);

    grid[1] = .{ .id = .{ .item = .dye }, .count = 1, .meta = dye_red };
    try std.testing.expectEqual(@as(u16, dye_purple), findMatch(&grid, workbench_grid_size).?.meta);

    grid[2] = .{ .id = .{ .block = .dirt }, .count = 1 };
    try std.testing.expect(findMatch(&grid, workbench_grid_size) == null);
}

test "the three-dye and four-dye magenta recipes both match their own multiset" {
    var three: [9]?Inventory.ItemStack = @splat(null);
    three[0] = .{ .id = .{ .item = .dye }, .count = 1, .meta = dye_blue };
    three[1] = .{ .id = .{ .item = .dye }, .count = 1, .meta = dye_red };
    three[2] = .{ .id = .{ .item = .dye }, .count = 1, .meta = dye_pink };
    const from_three = findMatch(&three, workbench_grid_size).?;
    try std.testing.expectEqual(@as(u16, dye_magenta), from_three.meta);
    try std.testing.expectEqual(@as(u8, 3), from_three.count);

    var four: [9]?Inventory.ItemStack = @splat(null);
    four[0] = .{ .id = .{ .item = .dye }, .count = 1, .meta = dye_blue };
    four[1] = .{ .id = .{ .item = .dye }, .count = 1, .meta = dye_red };
    four[2] = .{ .id = .{ .item = .dye }, .count = 1, .meta = dye_red };
    four[3] = .{ .id = .{ .item = .dye }, .count = 1, .meta = dye_white };
    const from_four = findMatch(&four, workbench_grid_size).?;
    try std.testing.expectEqual(@as(u16, dye_magenta), from_four.meta);
    try std.testing.expectEqual(@as(u8, 4), from_four.count);
}

test "dyeing white wool inverts the dye's metadata like BlockCloth does" {
    for (0..16) |index| {
        const meta: u16 = @intCast(index);
        var grid: [4]?Inventory.ItemStack = @splat(null);
        grid[0] = .{ .id = .{ .item = .dye }, .count = 1, .meta = meta };
        grid[1] = .{ .id = .{ .block = .wool }, .count = 1, .meta = 0 };
        const result = findMatch(&grid, player_grid_size).?;
        try std.testing.expectEqual(world.Id{ .block = .wool }, result.id);
        try std.testing.expectEqual(~@as(u4, @intCast(meta)), result.meta);
    }
}

test "only white wool can be dyed" {
    var grid: [4]?Inventory.ItemStack = @splat(null);
    grid[0] = .{ .id = .{ .item = .dye }, .count = 1, .meta = dye_red };
    grid[1] = .{ .id = .{ .block = .wool }, .count = 1, .meta = 5 };
    try std.testing.expect(findMatch(&grid, player_grid_size) == null);
}

test "shaped recipes win over shapeless ones, as RecipeSorter orders them" {
    var grid: [9]?Inventory.ItemStack = @splat(null);
    for (&grid) |*slot| slot.* = .{ .id = .{ .item = .dye }, .count = 1, .meta = dye_blue };
    try std.testing.expectEqual(world.Id{ .block = .block_lapis }, findMatch(&grid, workbench_grid_size).?.id);
}

test "four sand craft sandstone" {
    var grid: [4]?Inventory.ItemStack = @splat(null);
    for (&grid) |*slot| slot.* = .{ .id = .{ .block = .sand }, .count = 1 };
    try std.testing.expectEqual(world.Id{ .block = .sandstone }, findMatch(&grid, player_grid_size).?.id);
}

fn craftOnWorkbench(cells: []const ?world.Id) ?Inventory.ItemStack {
    var grid: [9]?Inventory.ItemStack = @splat(null);
    for (cells, 0..) |cell, index| {
        grid[index] = if (cell) |id| .{ .id = id, .count = 1 } else null;
    }
    return findMatch(&grid, workbench_grid_size);
}

test "each tool layout crafts its own head, shifted anywhere it fits" {
    const wood: world.Id = .{ .block = .planks };
    const stick: world.Id = .{ .item = .stick };

    try std.testing.expectEqual(world.Id{ .item = .sword_wood }, craftOnWorkbench(&.{
        wood,  null, null,
        wood,  null, null,
        stick, null, null,
    }).?.id);
    try std.testing.expectEqual(world.Id{ .item = .shovel_wood }, craftOnWorkbench(&.{
        null, wood,  null,
        null, stick, null,
        null, stick, null,
    }).?.id);
    try std.testing.expectEqual(world.Id{ .item = .pickaxe_wood }, craftOnWorkbench(&.{
        wood, wood,  wood,
        null, stick, null,
        null, stick, null,
    }).?.id);
    try std.testing.expectEqual(world.Id{ .item = .axe_wood }, craftOnWorkbench(&.{
        wood, wood,  null,
        wood, stick, null,
        null, stick, null,
    }).?.id);
    try std.testing.expectEqual(world.Id{ .item = .hoe_wood }, craftOnWorkbench(&.{
        wood, wood,  null,
        null, stick, null,
        null, stick, null,
    }).?.id);
}

test "a bow is strung from three sticks and three string, and only that way round" {
    const stick: world.Id = .{ .item = .stick };
    const string: world.Id = .{ .item = .string };

    const bow = craftOnWorkbench(&.{
        null,  stick, string,
        stick, null,  string,
        null,  stick, string,
    }).?;
    try std.testing.expectEqual(world.Id{ .item = .bow }, bow.id);
    try std.testing.expectEqual(@as(u8, 1), bow.count);

    try std.testing.expect(craftOnWorkbench(&.{
        null,   string, stick,
        string, null,   stick,
        null,   string, stick,
    }) == null);
}

test "six planks over a stick make a sign" {
    const plank: world.Id = .{ .block = .planks };
    const sign = craftOnWorkbench(&.{
        plank, plank,               plank,
        plank, plank,               plank,
        null,  .{ .item = .stick }, null,
    }).?;
    try std.testing.expectEqual(world.Id{ .item = .sign }, sign.id);
    try std.testing.expectEqual(@as(u8, 1), sign.count);
}

test "flint, a stick and a feather make four arrows" {
    const arrows = craftOnWorkbench(&.{
        .{ .item = .flint },   null, null,
        .{ .item = .stick },   null, null,
        .{ .item = .feather }, null, null,
    }).?;
    try std.testing.expectEqual(world.Id{ .item = .arrow }, arrows.id);
    try std.testing.expectEqual(@as(u8, 4), arrows.count);
}

test "the head material picks which tier of tool comes out" {
    const stick: world.Id = .{ .item = .stick };
    const heads = [_]world.Id{
        .{ .block = .cobblestone },
        .{ .item = .ingot_iron },
        .{ .item = .diamond },
        .{ .item = .ingot_gold },
    };
    const swords = [_]world.Item{ .sword_stone, .sword_iron, .sword_diamond, .sword_gold };

    for (heads, swords) |head, sword| {
        try std.testing.expectEqual(world.Id{ .item = sword }, craftOnWorkbench(&.{
            head,  null, null,
            head,  null, null,
            stick, null, null,
        }).?.id);
    }
}

test "each armour layout crafts its own piece" {
    const iron: world.Id = .{ .item = .ingot_iron };

    try std.testing.expectEqual(world.Id{ .item = .helmet_iron }, craftOnWorkbench(&.{
        iron, iron, iron,
        iron, null, iron,
    }).?.id);
    try std.testing.expectEqual(world.Id{ .item = .chestplate_iron }, craftOnWorkbench(&.{
        iron, null, iron,
        iron, iron, iron,
        iron, iron, iron,
    }).?.id);
    try std.testing.expectEqual(world.Id{ .item = .leggings_iron }, craftOnWorkbench(&.{
        iron, iron, iron,
        iron, null, iron,
        iron, null, iron,
    }).?.id);
    try std.testing.expectEqual(world.Id{ .item = .boots_iron }, craftOnWorkbench(&.{
        iron, null, iron,
        iron, null, iron,
    }).?.id);
}

test "a tool needs the full workbench, so the personal grid cannot make one" {
    var grid: [4]?Inventory.ItemStack = @splat(null);
    grid[0] = .{ .id = .{ .block = .planks }, .count = 1 };
    grid[2] = .{ .id = .{ .item = .stick }, .count = 1 };
    try std.testing.expectEqual(@as(?Inventory.ItemStack, null), findMatch(&grid, player_grid_size));
}

test "coal over a stick crafts four torches" {
    var grid: [4]?Inventory.ItemStack = @splat(null);
    grid[0] = .{ .id = .{ .item = .coal }, .count = 1 };
    grid[2] = .{ .id = .{ .item = .stick }, .count = 1 };
    const result = findMatch(&grid, player_grid_size).?;
    try std.testing.expectEqual(world.Id{ .block = .torch }, result.id);
    try std.testing.expectEqual(@as(u8, 4), result.count);
}

test "a stick over coal is upside down and crafts nothing" {
    var grid: [4]?Inventory.ItemStack = @splat(null);
    grid[0] = .{ .id = .{ .item = .stick }, .count = 1 };
    grid[2] = .{ .id = .{ .item = .coal }, .count = 1 };
    try std.testing.expect(findMatch(&grid, player_grid_size) == null);
}

test "six planks in two columns craft a wooden door" {
    var grid: [9]?Inventory.ItemStack = @splat(null);
    for ([_]usize{ 0, 1, 3, 4, 6, 7 }) |cell| {
        grid[cell] = .{ .id = .{ .block = .planks }, .count = 1 };
    }
    const result = findMatch(&grid, workbench_grid_size).?;
    try std.testing.expectEqual(world.Id{ .item = .door_wood }, result.id);
    try std.testing.expectEqual(@as(u8, 1), result.count);
}

test "six iron ingots in two columns craft an iron door" {
    var grid: [9]?Inventory.ItemStack = @splat(null);
    for ([_]usize{ 1, 2, 4, 5, 7, 8 }) |cell| {
        grid[cell] = .{ .id = .{ .item = .ingot_iron }, .count = 1 };
    }
    const result = findMatch(&grid, workbench_grid_size).?;
    try std.testing.expectEqual(world.Id{ .item = .door_iron }, result.id);
}

test "a door needs all six cells filled" {
    var grid: [9]?Inventory.ItemStack = @splat(null);
    for ([_]usize{ 0, 1, 3, 4 }) |cell| {
        grid[cell] = .{ .id = .{ .block = .planks }, .count = 1 };
    }
    try std.testing.expectEqual(world.Id{ .block = .workbench }, findMatch(&grid, workbench_grid_size).?.id);
}

test "six planks in two rows craft a pair of trapdoors" {
    var grid: [9]?Inventory.ItemStack = @splat(null);
    for ([_]usize{ 0, 1, 2, 3, 4, 5 }) |cell| {
        grid[cell] = .{ .id = .{ .block = .planks }, .count = 1 };
    }
    const result = findMatch(&grid, workbench_grid_size).?;
    try std.testing.expectEqual(world.Id{ .block = .trapdoor }, result.id);
    try std.testing.expectEqual(@as(u8, 2), result.count);
}

test "three blocks in a row craft three slabs, tagged with which block they came from" {
    for ([_]struct { cut: world.Block, meta: u4 }{
        .{ .cut = .cobblestone, .meta = world.block.slab_cobblestone },
        .{ .cut = .stone, .meta = world.block.slab_stone },
        .{ .cut = .sandstone, .meta = world.block.slab_sandstone },
        .{ .cut = .planks, .meta = world.block.slab_wood },
    }) |pair| {
        var grid: [9]?Inventory.ItemStack = @splat(null);
        for ([_]usize{ 3, 4, 5 }) |cell| {
            grid[cell] = .{ .id = .{ .block = pair.cut }, .count = 1 };
        }
        const result = findMatch(&grid, workbench_grid_size).?;
        try std.testing.expectEqual(world.Id{ .block = .slab }, result.id);
        try std.testing.expectEqual(@as(u8, 3), result.count);
        try std.testing.expectEqual(@as(u16, pair.meta), result.meta);
    }
}

test "two blocks in a row are not enough for slabs" {
    var grid: [9]?Inventory.ItemStack = @splat(null);
    for ([_]usize{ 3, 4 }) |cell| {
        grid[cell] = .{ .id = .{ .block = .stone }, .count = 1 };
    }
    try std.testing.expect(findMatch(&grid, workbench_grid_size) == null);
}

test "a staircase of six blocks crafts four stairs of that block" {
    for ([_]struct { cut: world.Block, out: world.Block }{
        .{ .cut = .planks, .out = .stairs_wood },
        .{ .cut = .cobblestone, .out = .stairs_cobblestone },
    }) |pair| {
        var grid: [9]?Inventory.ItemStack = @splat(null);
        for ([_]usize{ 0, 3, 4, 6, 7, 8 }) |cell| {
            grid[cell] = .{ .id = .{ .block = pair.cut }, .count = 1 };
        }
        const result = findMatch(&grid, workbench_grid_size).?;
        try std.testing.expectEqual(world.Id{ .block = pair.out }, result.id);
        try std.testing.expectEqual(@as(u8, 4), result.count);
    }
}

test "a staircase climbing the other way still crafts stairs, since shapes match mirrored" {
    var grid: [9]?Inventory.ItemStack = @splat(null);
    for ([_]usize{ 2, 4, 5, 6, 7, 8 }) |cell| {
        grid[cell] = .{ .id = .{ .block = .planks }, .count = 1 };
    }
    try std.testing.expectEqual(world.Id{ .block = .stairs_wood }, findMatch(&grid, workbench_grid_size).?.id);
}

test "the same six planks turned on their side craft a door instead" {
    var grid: [9]?Inventory.ItemStack = @splat(null);
    for ([_]usize{ 0, 1, 3, 4, 6, 7 }) |cell| {
        grid[cell] = .{ .id = .{ .block = .planks }, .count = 1 };
    }
    try std.testing.expectEqual(world.Id{ .item = .door_wood }, findMatch(&grid, workbench_grid_size).?.id);
}

test "three iron ingots in a v craft a bucket" {
    var grid: [9]?Inventory.ItemStack = @splat(null);
    for ([_]usize{ 0, 2, 4 }) |cell| {
        grid[cell] = .{ .id = .{ .item = .ingot_iron }, .count = 1 };
    }
    const result = findMatch(&grid, workbench_grid_size).?;
    try std.testing.expectEqual(world.Id{ .item = .bucket }, result.id);
    try std.testing.expectEqual(@as(u8, 1), result.count);
}

test "the bucket's iron must be in a v, not a row or a full square" {
    var row: [9]?Inventory.ItemStack = @splat(null);
    for ([_]usize{ 0, 1, 2 }) |cell| {
        row[cell] = .{ .id = .{ .item = .ingot_iron }, .count = 1 };
    }
    try std.testing.expect(findMatch(&row, workbench_grid_size) == null);
}

test "milk, sugar, egg and wheat craft one cake" {
    var grid: [9]?Inventory.ItemStack = @splat(null);
    for (0..3) |cell| grid[cell] = .{ .id = .{ .item = .bucket_milk }, .count = 1 };
    grid[3] = .{ .id = .{ .item = .sugar }, .count = 1 };
    grid[4] = .{ .id = .{ .item = .egg }, .count = 1 };
    grid[5] = .{ .id = .{ .item = .sugar }, .count = 1 };
    for (6..9) |cell| grid[cell] = .{ .id = .{ .item = .wheat }, .count = 1 };

    const result = findMatch(&grid, workbench_grid_size).?;
    try std.testing.expectEqual(world.Id{ .item = .cake }, result.id);
    try std.testing.expectEqual(@as(u8, 1), result.count);
}

test "the cake's sugar and egg cannot swap places" {
    var grid: [9]?Inventory.ItemStack = @splat(null);
    for (0..3) |cell| grid[cell] = .{ .id = .{ .item = .bucket_milk }, .count = 1 };
    grid[3] = .{ .id = .{ .item = .egg }, .count = 1 };
    grid[4] = .{ .id = .{ .item = .sugar }, .count = 1 };
    grid[5] = .{ .id = .{ .item = .sugar }, .count = 1 };
    for (6..9) |cell| grid[cell] = .{ .id = .{ .item = .wheat }, .count = 1 };

    try std.testing.expect(findMatch(&grid, workbench_grid_size) == null);
}
