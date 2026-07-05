const std = @import("std");
const world = @import("world");
const Inventory = @import("inventory.zig");

pub const grid_size: u8 = 2;

pub const Ingredient = struct { id: world.Id, meta: ?u4 = null };

pub const Recipe = struct {
    width: u8,
    height: u8,
    pattern: [grid_size * grid_size]?Ingredient,
    output_id: world.Id,
    output_count: u8,
    output_meta: u4 = 0,
};

const recipes = [_]Recipe{
    .{
        .width = 1,
        .height = 1,
        .pattern = .{ .{ .id = .{ .block = .log } }, null, null, null },
        .output_id = .{ .block = .planks },
        .output_count = 4,
    },
    .{
        .width = 1,
        .height = 2,
        .pattern = .{ .{ .id = .{ .block = .planks } }, .{ .id = .{ .block = .planks } }, null, null },
        .output_id = .{ .item = .stick },
        .output_count = 4,
    },
    .{
        .width = 2,
        .height = 2,
        .pattern = .{
            .{ .id = .{ .item = .clay_ball } },
            .{ .id = .{ .item = .clay_ball } },
            .{ .id = .{ .item = .clay_ball } },
            .{ .id = .{ .item = .clay_ball } },
        },
        .output_id = .{ .block = .clay },
        .output_count = 1,
    },
    filledGrid(.{ .block = .planks }, .{ .block = .workbench }),
    filledGrid(.{ .item = .snowball }, .{ .block = .snow_block }),
    filledGrid(.{ .item = .brick }, .{ .block = .brick }),
    filledGrid(.{ .item = .string }, .{ .block = .wool }),
    filledGrid(.{ .item = .glowstone_dust }, .{ .block = .glowstone }),
    .{
        .width = 1,
        .height = 1,
        .pattern = .{ .{ .id = .{ .item = .reed } }, null, null, null },
        .output_id = .{ .item = .sugar },
        .output_count = 1,
    },
};

fn filledGrid(ingredient: world.Id, output: world.Id) Recipe {
    return .{
        .width = 2,
        .height = 2,
        .pattern = @splat(.{ .id = ingredient }),
        .output_id = output,
        .output_count = 1,
    };
}

fn matchesAt(grid: [grid_size * grid_size]?Inventory.ItemStack, recipe: Recipe, offset_x: u8, offset_y: u8) bool {
    for (0..grid_size) |y| {
        for (0..grid_size) |x| {
            const rx = @as(i32, @intCast(x)) - @as(i32, offset_x);
            const ry = @as(i32, @intCast(y)) - @as(i32, offset_y);
            var want: ?Ingredient = null;
            if (rx >= 0 and ry >= 0 and rx < recipe.width and ry < recipe.height) {
                want = recipe.pattern[@intCast(rx + ry * recipe.width)];
            }
            const have = grid[x + y * grid_size];
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

pub fn findMatch(grid: [grid_size * grid_size]?Inventory.ItemStack) ?Inventory.ItemStack {
    for (recipes) |recipe| {
        var offset_y: u8 = 0;
        while (offset_y + recipe.height <= grid_size) : (offset_y += 1) {
            var offset_x: u8 = 0;
            while (offset_x + recipe.width <= grid_size) : (offset_x += 1) {
                if (matchesAt(grid, recipe, offset_x, offset_y)) {
                    return .{ .id = recipe.output_id, .count = recipe.output_count, .meta = recipe.output_meta };
                }
            }
        }
    }
    return null;
}

pub fn consume(grid: *[grid_size * grid_size]?Inventory.ItemStack) void {
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
    const result = findMatch(grid).?;
    try std.testing.expectEqual(world.Id{ .block = .planks }, result.id);
    try std.testing.expectEqual(@as(u8, 4), result.count);
}

test "two stacked planks craft into sticks" {
    var grid: [4]?Inventory.ItemStack = @splat(null);
    grid[0] = .{ .id = .{ .block = .planks }, .count = 5 };
    grid[2] = .{ .id = .{ .block = .planks }, .count = 5 };
    const result = findMatch(grid).?;
    try std.testing.expectEqual(world.Id{ .item = .stick }, result.id);
    try std.testing.expectEqual(@as(u8, 4), result.count);
}

test "planks side by side do not match the stick recipe" {
    var grid: [4]?Inventory.ItemStack = @splat(null);
    grid[0] = .{ .id = .{ .block = .planks }, .count = 5 };
    grid[1] = .{ .id = .{ .block = .planks }, .count = 5 };
    try std.testing.expect(findMatch(grid) == null);
}

test "four clay balls fill the grid to craft a clay block" {
    var grid: [4]?Inventory.ItemStack = @splat(null);
    for (&grid) |*slot| slot.* = .{ .id = .{ .item = .clay_ball }, .count = 1 };
    const result = findMatch(grid).?;
    try std.testing.expectEqual(world.Id{ .block = .clay }, result.id);
    try std.testing.expectEqual(@as(u8, 1), result.count);
}

test "three clay balls are not enough to fill the grid" {
    var grid: [4]?Inventory.ItemStack = @splat(null);
    grid[0] = .{ .id = .{ .item = .clay_ball }, .count = 1 };
    grid[1] = .{ .id = .{ .item = .clay_ball }, .count = 1 };
    grid[2] = .{ .id = .{ .item = .clay_ball }, .count = 1 };
    try std.testing.expect(findMatch(grid) == null);
}

test "an unrelated extra item in the grid blocks the match" {
    var grid: [4]?Inventory.ItemStack = @splat(null);
    grid[0] = .{ .id = .{ .block = .log }, .count = 1 };
    grid[1] = .{ .id = .{ .block = .dirt }, .count = 1 };
    try std.testing.expect(findMatch(grid) == null);
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
    const result = findMatch(grid).?;
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
        try std.testing.expectEqual(case.output, findMatch(grid).?.id);
    }
}

test "wool crafted from string comes out white" {
    var grid: [4]?Inventory.ItemStack = @splat(null);
    for (&grid) |*slot| slot.* = .{ .id = .{ .item = .string }, .count = 1 };
    try std.testing.expectEqual(@as(u4, 0), findMatch(grid).?.meta);
}

test "a single sugar cane crafts sugar in any grid cell" {
    for (0..4) |cell| {
        var grid: [4]?Inventory.ItemStack = @splat(null);
        grid[cell] = .{ .id = .{ .item = .reed }, .count = 1 };
        try std.testing.expectEqual(world.Id{ .item = .sugar }, findMatch(grid).?.id);
    }
}
