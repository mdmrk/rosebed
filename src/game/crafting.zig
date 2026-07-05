const std = @import("std");
const world = @import("world");
const Inventory = @import("inventory.zig");

pub const player_grid_size: u8 = 2;
pub const workbench_grid_size: u8 = 3;

const max_pattern = workbench_grid_size * workbench_grid_size;

pub const Ingredient = struct { id: world.Id, meta: ?u4 = null };

pub const Recipe = struct {
    width: u8,
    height: u8,
    pattern: [max_pattern]?Ingredient,
    output_id: world.Id,
    output_count: u8,
    output_meta: u4 = 0,
};

fn b(id: world.Block) ?Ingredient {
    return .{ .id = .{ .block = id } };
}

fn i(id: world.Item) ?Ingredient {
    return .{ .id = .{ .item = id } };
}

fn dye(meta: u4) ?Ingredient {
    return .{ .id = .{ .item = .dye }, .meta = meta };
}

fn shaped(width: u8, height: u8, cells: []const ?Ingredient, output: world.Id, count: u8) Recipe {
    var pattern: [max_pattern]?Ingredient = @splat(null);
    for (cells, 0..) |cell, index| pattern[index] = cell;
    return .{ .width = width, .height = height, .pattern = pattern, .output_id = output, .output_count = count };
}

fn shapedMeta(width: u8, height: u8, cells: []const ?Ingredient, output: world.Id, count: u8, meta: u4) Recipe {
    var recipe = shaped(width, height, cells, output, count);
    recipe.output_meta = meta;
    return recipe;
}

fn storageBlock(ingredient: ?Ingredient, output: world.Block) Recipe {
    return shaped(3, 3, &@as([9]?Ingredient, @splat(ingredient)), .{ .block = output }, 1);
}

const recipes = [_]Recipe{
    shaped(1, 1, &.{b(.log)}, .{ .block = .planks }, 4),
    shaped(1, 2, &.{ b(.planks), b(.planks) }, .{ .item = .stick }, 4),
    shaped(2, 2, &.{ i(.clay_ball), i(.clay_ball), i(.clay_ball), i(.clay_ball) }, .{ .block = .clay }, 1),
    shaped(2, 2, &.{ b(.planks), b(.planks), b(.planks), b(.planks) }, .{ .block = .workbench }, 1),
    shaped(2, 2, &.{ i(.snowball), i(.snowball), i(.snowball), i(.snowball) }, .{ .block = .snow_block }, 1),
    shaped(2, 2, &.{ i(.brick), i(.brick), i(.brick), i(.brick) }, .{ .block = .brick }, 1),
    shaped(2, 2, &.{ i(.string), i(.string), i(.string), i(.string) }, .{ .block = .wool }, 1),
    shaped(2, 2, &.{ i(.glowstone_dust), i(.glowstone_dust), i(.glowstone_dust), i(.glowstone_dust) }, .{ .block = .glowstone }, 1),
    shaped(1, 1, &.{i(.reed)}, .{ .item = .sugar }, 1),
    shaped(3, 1, &.{ i(.reed), i(.reed), i(.reed) }, .{ .item = .paper }, 3),
    shaped(1, 3, &.{ i(.paper), i(.paper), i(.paper) }, .{ .item = .book }, 1),
    shaped(3, 1, &.{ i(.wheat), i(.wheat), i(.wheat) }, .{ .item = .bread }, 1),
    shaped(3, 2, &.{ b(.planks), null, b(.planks), null, b(.planks), null }, .{ .item = .bowl }, 4),
    shaped(1, 3, &.{ b(.mushroom_red), b(.mushroom_brown), i(.bowl) }, .{ .item = .mushroom_stew }, 1),
    shaped(1, 3, &.{ b(.mushroom_brown), b(.mushroom_red), i(.bowl) }, .{ .item = .mushroom_stew }, 1),
    shaped(3, 3, &.{
        b(.planks), b(.planks), b(.planks),
        b(.planks), i(.diamond), b(.planks),
        b(.planks), b(.planks), b(.planks),
    }, .{ .block = .jukebox }, 1),
    shaped(3, 3, &.{
        b(.planks),   b(.planks), b(.planks),
        b(.planks),   i(.redstone), b(.planks),
        b(.planks),   b(.planks), b(.planks),
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

fn matchesAt(grid: []const ?Inventory.ItemStack, size: u8, recipe: Recipe, offset_x: u8, offset_y: u8) bool {
    for (0..size) |y| {
        for (0..size) |x| {
            const rx = @as(i32, @intCast(x)) - @as(i32, offset_x);
            const ry = @as(i32, @intCast(y)) - @as(i32, offset_y);
            var want: ?Ingredient = null;
            if (rx >= 0 and ry >= 0 and rx < recipe.width and ry < recipe.height) {
                want = recipe.pattern[@intCast(rx + ry * recipe.width)];
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

pub fn findMatch(grid: []const ?Inventory.ItemStack, size: u8) ?Inventory.ItemStack {
    for (recipes) |recipe| {
        if (recipe.width > size or recipe.height > size) continue;
        for (0..size + 1 - recipe.height) |offset_y| {
            for (0..size + 1 - recipe.width) |offset_x| {
                if (matchesAt(grid, size, recipe, @intCast(offset_x), @intCast(offset_y))) {
                    return .{ .id = recipe.output_id, .count = recipe.output_count, .meta = recipe.output_meta };
                }
            }
        }
    }
    return null;
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
    try std.testing.expectEqual(@as(u4, 0), findMatch(&grid, player_grid_size).?.meta);
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
    try std.testing.expectEqual(@as(u4, world.item.dye_meta_lapis), unpacked.meta);
    try std.testing.expectEqual(@as(u8, 9), unpacked.count);
}
