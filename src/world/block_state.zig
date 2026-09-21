const std = @import("std");

const BlockPos = @import("BlockPos.zig");
const nbt = @import("nbt.zig");
const tile = @import("tile.zig");

pub const id_key = "RosebedState";

const header_keys = [_][]const u8{ "id", "x", "y", "z" };

fn isHeader(key: []const u8) bool {
    for (header_keys) |reserved| {
        if (std.mem.eql(u8, key, reserved)) return true;
    }
    return false;
}

fn copyFields(gpa: std.mem.Allocator, into: *nbt.Compound, from: nbt.Compound) !void {
    for (from.keys(), from.values()) |key, value| {
        if (isHeader(key)) continue;
        try nbt.putDuped(gpa, into, key, try nbt.dupe(gpa, value));
    }
}

pub fn store(gpa: std.mem.Allocator, pos: BlockPos, state: nbt.Compound) !nbt.Tag {
    var compound: nbt.Compound = .{};
    errdefer {
        var owned: nbt.Tag = .{ .compound = compound };
        nbt.deinit(gpa, &owned);
    }

    try tile.header(gpa, &compound, id_key, pos);
    try copyFields(gpa, &compound, state);

    return .{ .compound = compound };
}

pub const Placed = struct {
    pos: BlockPos,
    state: nbt.Compound,
};

pub fn isBlockState(compound: nbt.Compound) bool {
    return tile.isKind(compound, id_key);
}

pub fn load(gpa: std.mem.Allocator, compound: nbt.Compound) !?Placed {
    if (!isBlockState(compound)) return null;
    const pos = tile.position(compound) orelse return null;

    var state: nbt.Compound = .{};
    errdefer {
        var owned: nbt.Tag = .{ .compound = state };
        nbt.deinit(gpa, &owned);
    }
    try copyFields(gpa, &state, compound);

    return .{ .pos = pos, .state = state };
}

test "a mod's state keeps its fields through a trip to NBT and back" {
    const gpa = std.testing.allocator;

    var state: nbt.Compound = .{};
    defer {
        var owned: nbt.Tag = .{ .compound = state };
        nbt.deinit(gpa, &owned);
    }
    try nbt.putDuped(gpa, &state, "charge", .{ .double = 2.5 });
    try nbt.putDuped(gpa, &state, "owner", .{ .string = try gpa.dupe(u8, "Steve") });
    try nbt.putDuped(gpa, &state, "lit", .{ .byte = 1 });

    var tag = try store(gpa, .init(4, 70, -9), state);
    defer nbt.deinit(gpa, &tag);

    var placed = (try load(gpa, tag.compound)).?;
    defer {
        var owned: nbt.Tag = .{ .compound = placed.state };
        nbt.deinit(gpa, &owned);
    }

    try std.testing.expectEqual(BlockPos.init(4, 70, -9), placed.pos);
    try std.testing.expectEqual(@as(usize, 3), placed.state.count());
    try std.testing.expectEqual(@as(f64, 2.5), placed.state.get("charge").?.double);
    try std.testing.expectEqualStrings("Steve", placed.state.get("owner").?.string);
    try std.testing.expectEqual(@as(i8, 1), placed.state.get("lit").?.byte);
}

test "a state compound that is not a mod's is left to whoever owns it" {
    const gpa = std.testing.allocator;

    var compound: nbt.Compound = .{};
    defer {
        var owned: nbt.Tag = .{ .compound = compound };
        nbt.deinit(gpa, &owned);
    }
    try tile.header(gpa, &compound, "Furnace", .init(0, 0, 0));

    try std.testing.expect(try load(gpa, compound) == null);
}
