const std = @import("std");

const assets = @import("assets");

const block = @import("block.zig");
const BlockPos = @import("BlockPos.zig");
const nbt = @import("nbt.zig");
const testing_world = @import("testing.zig");
const tile = @import("tile.zig");
const World = @import("World.zig");

pub const id_key = "Music";
pub const pitch_count: u8 = 25;

pub const Instrument = enum(u8) {
    harp = 0,
    bass_drum = 1,
    snare = 2,
    click = 3,
    bass = 4,

    pub fn soundName(self: Instrument) assets.Sound {
        return switch (self) {
            .harp => assets.sounds.note.harp,
            .bass_drum => assets.sounds.note.bd,
            .snare => assets.sounds.note.snare,
            .click => assets.sounds.note.hat,
            .bass => assets.sounds.note.bassattack,
        };
    }
};

pub const Note = struct {
    note: u8 = 0,
    powered: bool = false,
};

pub fn instrumentUnder(world_map: *const World, pos: BlockPos) Instrument {
    return switch (world_map.getBlock(pos.offset(0, -1, 0)).material()) {
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

pub fn changePitch(world_map: *World, pos: BlockPos) !void {
    const state = try world_map.addNote(pos);
    state.note = (state.note + 1) % pitch_count;
}

pub fn trigger(world_map: *World, pos: BlockPos) !void {
    if (world_map.getBlock(pos.offset(0, 1, 0)).material() != .air) return;
    const state = try world_map.addNote(pos);
    world_map.playNoteAt(pos, instrumentUnder(world_map, pos), state.note);
}

pub fn onActivated(world_map: *World, pos: BlockPos, id: block.Block) std.mem.Allocator.Error!bool {
    if (id != .note_block) return false;
    try changePitch(world_map, pos);
    try trigger(world_map, pos);
    return true;
}

pub fn onPunched(world_map: *World, pos: BlockPos) std.mem.Allocator.Error!void {
    if (world_map.getBlock(pos) != .note_block) return;
    try trigger(world_map, pos);
}

pub fn onPowerChange(world_map: *World, pos: BlockPos, powered: bool) std.mem.Allocator.Error!void {
    const state = try world_map.addNote(pos);
    if (state.powered == powered) return;
    state.powered = powered;
    if (powered) try trigger(world_map, pos);
}

pub fn store(gpa: std.mem.Allocator, pos: BlockPos, state: Note) !nbt.Tag {
    var compound: nbt.Compound = .{};
    errdefer {
        var owned: nbt.Tag = .{ .compound = compound };
        nbt.deinit(gpa, &owned);
    }

    try tile.header(gpa, &compound, id_key, pos);
    try nbt.putDuped(gpa, &compound, "note", .{ .byte = @intCast(state.note) });

    return .{ .compound = compound };
}

pub const Placed = struct {
    pos: BlockPos,
    state: Note,
};

pub fn isNote(compound: nbt.Compound) bool {
    return tile.isKind(compound, id_key);
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
        .pos = tile.position(compound) orelse return null,
        .state = .{ .note = note },
    };
}

test "the block under the note block picks the instrument" {
    var w = try testing_world.flatWorld(std.testing.allocator, 4);
    defer w.deinit();

    try w.setBlockWithNotify(.init(8, 4, 8), .stone);
    try w.setBlockWithNotify(.init(8, 5, 8), .note_block);
    try std.testing.expectEqual(Instrument.bass_drum, instrumentUnder(&w, .init(8, 5, 8)));

    try w.setBlockWithNotify(.init(8, 4, 8), .sand);
    try std.testing.expectEqual(Instrument.snare, instrumentUnder(&w, .init(8, 5, 8)));

    try w.setBlockWithNotify(.init(8, 4, 8), .glass);
    try std.testing.expectEqual(Instrument.click, instrumentUnder(&w, .init(8, 5, 8)));

    try w.setBlockWithNotify(.init(8, 4, 8), .planks);
    try std.testing.expectEqual(Instrument.bass, instrumentUnder(&w, .init(8, 5, 8)));

    try w.setBlockWithNotify(.init(8, 4, 8), .wool);
    try std.testing.expectEqual(Instrument.harp, instrumentUnder(&w, .init(8, 5, 8)));
}

test "right clicking walks the note up and wraps after two octaves" {
    var w = try testing_world.flatWorld(std.testing.allocator, 4);
    defer w.deinit();
    try w.setBlockWithNotify(.init(8, 5, 8), .note_block);

    try std.testing.expect(w.noteAt(.init(8, 5, 8)) == null);

    try changePitch(&w, .init(8, 5, 8));
    try std.testing.expectEqual(@as(u8, 1), w.noteAt(.init(8, 5, 8)).?.note);

    for (0..pitch_count) |_| try changePitch(&w, .init(8, 5, 8));
    try std.testing.expectEqual(@as(u8, 1), w.noteAt(.init(8, 5, 8)).?.note);
}

test "the pitch doubles every twelve notes, the way vanilla tunes it" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), pitchOf(0), 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), pitchOf(12), 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), pitchOf(24), 1.0e-6);
}

test "a note block with something on its head stays quiet" {
    var w = try testing_world.flatWorld(std.testing.allocator, 4);
    defer w.deinit();
    try w.setBlockWithNotify(.init(8, 5, 8), .note_block);
    try w.setBlockWithNotify(.init(8, 6, 8), .stone);

    var heard: usize = 0;
    w.note_sink = .{ .context = &heard, .playNote = countNote };

    try trigger(&w, .init(8, 5, 8));
    try std.testing.expectEqual(@as(usize, 0), heard);

    try w.setBlockWithNotify(.init(8, 6, 8), .air);
    try trigger(&w, .init(8, 5, 8));
    try std.testing.expectEqual(@as(usize, 1), heard);
}

fn countNote(context: *anyopaque, _: BlockPos, _: Instrument, _: u8) void {
    const heard: *usize = @ptrCast(@alignCast(context));
    heard.* += 1;
}

test "a note block only sounds on the rising edge of redstone power" {
    var w = try testing_world.flatWorld(std.testing.allocator, 4);
    defer w.deinit();
    try w.setBlockWithNotify(.init(8, 5, 8), .note_block);

    var heard: usize = 0;
    w.note_sink = .{ .context = &heard, .playNote = countNote };

    try onPowerChange(&w, .init(8, 5, 8), true);
    try std.testing.expectEqual(@as(usize, 1), heard);

    try onPowerChange(&w, .init(8, 5, 8), true);
    try std.testing.expectEqual(@as(usize, 1), heard);

    try onPowerChange(&w, .init(8, 5, 8), false);
    try onPowerChange(&w, .init(8, 5, 8), true);
    try std.testing.expectEqual(@as(usize, 2), heard);
}

test "the tuning of a note block survives a trip through NBT" {
    const gpa = std.testing.allocator;

    var tag = try store(gpa, .init(4, 70, -9), .{ .note = 17 });
    defer nbt.deinit(gpa, &tag);

    const placed = load(tag.compound).?;
    try std.testing.expectEqual(BlockPos.init(4, 70, -9), placed.pos);
    try std.testing.expectEqual(@as(u8, 17), placed.state.note);
}
