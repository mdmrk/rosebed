const std = @import("std");

const block = @import("block.zig");
const nbt = @import("nbt.zig");
const testing_world = @import("testing.zig");
const World = @import("world_map.zig");

pub const id_key = "Music";
pub const pitch_count: u8 = 25;

pub const Instrument = enum(u8) {
    harp = 0,
    bass_drum = 1,
    snare = 2,
    click = 3,
    bass = 4,

    pub fn soundName(self: Instrument) []const u8 {
        return switch (self) {
            .harp => "note.harp",
            .bass_drum => "note.bd",
            .snare => "note.snare",
            .click => "note.hat",
            .bass => "note.bassattack",
        };
    }
};

pub const Note = struct {
    note: u8 = 0,
    powered: bool = false,
};

pub fn instrumentUnder(world_map: *const World, x: i32, y: i32, z: i32) Instrument {
    return switch (world_map.getBlock(x, y - 1, z).material()) {
        .rock => .bass_drum,
        .sand => .snare,
        .glass => .click,
        .wood => .bass,
        else => .harp,
    };
}

pub fn pitchOf(note: u8) f32 {
    const step = (@as(f64, @floatFromInt(note)) - 12.0) / 12.0;
    return @floatCast(std.math.pow(f64, 2.0, step));
}

pub fn changePitch(world_map: *World, x: i32, y: i32, z: i32) !void {
    const state = try world_map.addNote(x, y, z);
    state.note = (state.note + 1) % pitch_count;
}

pub fn trigger(world_map: *World, x: i32, y: i32, z: i32) !void {
    if (world_map.getBlock(x, y + 1, z).material() != .air) return;
    const state = try world_map.addNote(x, y, z);
    world_map.playNoteAt(x, y, z, instrumentUnder(world_map, x, y, z), state.note);
}

pub fn onActivated(world_map: *World, x: i32, y: i32, z: i32, id: block.Block) std.mem.Allocator.Error!bool {
    if (id != .note_block) return false;
    try changePitch(world_map, x, y, z);
    try trigger(world_map, x, y, z);
    return true;
}

pub fn onPunched(world_map: *World, x: i32, y: i32, z: i32) std.mem.Allocator.Error!void {
    if (world_map.getBlock(x, y, z) != .note_block) return;
    try trigger(world_map, x, y, z);
}

pub fn onPowerChange(world_map: *World, x: i32, y: i32, z: i32, powered: bool) std.mem.Allocator.Error!void {
    const state = try world_map.addNote(x, y, z);
    if (state.powered == powered) return;
    state.powered = powered;
    if (powered) try trigger(world_map, x, y, z);
}

fn put(gpa: std.mem.Allocator, compound: *nbt.Compound, key: []const u8, tag: nbt.Tag) !void {
    try nbt.putDuped(gpa, compound, key, tag);
}

pub fn store(gpa: std.mem.Allocator, x: i32, y: i32, z: i32, state: Note) !nbt.Tag {
    var compound: nbt.Compound = .{};
    errdefer {
        var owned: nbt.Tag = .{ .compound = compound };
        nbt.deinit(gpa, &owned);
    }

    try put(gpa, &compound, "id", .{ .string = try gpa.dupe(u8, id_key) });
    try put(gpa, &compound, "x", .{ .int = x });
    try put(gpa, &compound, "y", .{ .int = y });
    try put(gpa, &compound, "z", .{ .int = z });
    try put(gpa, &compound, "note", .{ .byte = @intCast(state.note) });

    return .{ .compound = compound };
}

pub const Placed = struct {
    x: i32,
    y: i32,
    z: i32,
    state: Note,
};

pub fn isNote(compound: nbt.Compound) bool {
    return switch (compound.get("id") orelse return false) {
        .string => |value| std.mem.eql(u8, value, id_key),
        else => false,
    };
}

fn byteField(compound: nbt.Compound, key: []const u8) ?i8 {
    return switch (compound.get(key) orelse return null) {
        .byte => |value| value,
        else => null,
    };
}

pub fn load(compound: nbt.Compound) ?Placed {
    if (!isNote(compound)) return null;

    const raw = byteField(compound, "note") orelse 0;
    const note: u8 = if (raw < 0) 0 else @min(@as(u8, @intCast(raw)), pitch_count - 1);

    return .{
        .x = nbt.intField(compound, "x") orelse return null,
        .y = nbt.intField(compound, "y") orelse return null,
        .z = nbt.intField(compound, "z") orelse return null,
        .state = .{ .note = note },
    };
}

test "the block under the note block picks the instrument" {
    var w = try testing_world.flatWorld(std.testing.allocator, 4);
    defer w.deinit();

    try w.setBlockWithNotify(8, 4, 8, .stone);
    try w.setBlockWithNotify(8, 5, 8, .note_block);
    try std.testing.expectEqual(Instrument.bass_drum, instrumentUnder(&w, 8, 5, 8));

    try w.setBlockWithNotify(8, 4, 8, .sand);
    try std.testing.expectEqual(Instrument.snare, instrumentUnder(&w, 8, 5, 8));

    try w.setBlockWithNotify(8, 4, 8, .glass);
    try std.testing.expectEqual(Instrument.click, instrumentUnder(&w, 8, 5, 8));

    try w.setBlockWithNotify(8, 4, 8, .planks);
    try std.testing.expectEqual(Instrument.bass, instrumentUnder(&w, 8, 5, 8));

    try w.setBlockWithNotify(8, 4, 8, .wool);
    try std.testing.expectEqual(Instrument.harp, instrumentUnder(&w, 8, 5, 8));
}

test "right clicking walks the note up and wraps after two octaves" {
    var w = try testing_world.flatWorld(std.testing.allocator, 4);
    defer w.deinit();
    try w.setBlockWithNotify(8, 5, 8, .note_block);

    try std.testing.expect(w.noteAt(8, 5, 8) == null);

    try changePitch(&w, 8, 5, 8);
    try std.testing.expectEqual(@as(u8, 1), w.noteAt(8, 5, 8).?.note);

    for (0..pitch_count) |_| try changePitch(&w, 8, 5, 8);
    try std.testing.expectEqual(@as(u8, 1), w.noteAt(8, 5, 8).?.note);
}

test "the pitch doubles every twelve notes, the way vanilla tunes it" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), pitchOf(0), 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), pitchOf(12), 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), pitchOf(24), 1.0e-6);
}

test "a note block with something on its head stays quiet" {
    var w = try testing_world.flatWorld(std.testing.allocator, 4);
    defer w.deinit();
    try w.setBlockWithNotify(8, 5, 8, .note_block);
    try w.setBlockWithNotify(8, 6, 8, .stone);

    var heard: usize = 0;
    w.note_sink = .{ .context = &heard, .playNote = countNote };

    try trigger(&w, 8, 5, 8);
    try std.testing.expectEqual(@as(usize, 0), heard);

    try w.setBlockWithNotify(8, 6, 8, .air);
    try trigger(&w, 8, 5, 8);
    try std.testing.expectEqual(@as(usize, 1), heard);
}

fn countNote(context: *anyopaque, _: i32, _: i32, _: i32, _: Instrument, _: u8) void {
    const heard: *usize = @ptrCast(@alignCast(context));
    heard.* += 1;
}

test "a note block only sounds on the rising edge of redstone power" {
    var w = try testing_world.flatWorld(std.testing.allocator, 4);
    defer w.deinit();
    try w.setBlockWithNotify(8, 5, 8, .note_block);

    var heard: usize = 0;
    w.note_sink = .{ .context = &heard, .playNote = countNote };

    try onPowerChange(&w, 8, 5, 8, true);
    try std.testing.expectEqual(@as(usize, 1), heard);

    try onPowerChange(&w, 8, 5, 8, true);
    try std.testing.expectEqual(@as(usize, 1), heard);

    try onPowerChange(&w, 8, 5, 8, false);
    try onPowerChange(&w, 8, 5, 8, true);
    try std.testing.expectEqual(@as(usize, 2), heard);
}

test "the tuning of a note block survives a trip through NBT" {
    const gpa = std.testing.allocator;

    var tag = try store(gpa, 4, 70, -9, .{ .note = 17 });
    defer nbt.deinit(gpa, &tag);

    const placed = load(tag.compound).?;
    try std.testing.expectEqual(@as(i32, 4), placed.x);
    try std.testing.expectEqual(@as(i32, 70), placed.y);
    try std.testing.expectEqual(@as(i32, -9), placed.z);
    try std.testing.expectEqual(@as(u8, 17), placed.state.note);
}
