const std = @import("std");

const assets = @import("assets");
const math = @import("math");

const block = @import("block.zig");
const Block = block.Block;
const Side = block.Side;
const BlockPos = @import("BlockPos.zig");
const nbt = @import("nbt.zig");
const tile = @import("tile.zig");
const redstone = @import("redstone.zig");
const testing_world = @import("testing.zig");
const World = @import("World.zig");

pub const id_key = "Piston";
pub const push_limit: u32 = 12;
pub const progress_per_tick: f32 = 0.5;
pub const shove_lead: f32 = 1.0 / 16.0;
pub const final_shove: f32 = 0.25;

pub const Moving = struct {
    stored: Block = .air,
    stored_metadata: u4 = 0,
    facing: Side = .up,
    extending: bool = false,
    source: bool = false,
    progress: f32 = 0,
    prev_progress: f32 = 0,

    pub fn offsetAt(self: Moving, progress: f32) f32 {
        return if (self.extending) progress - 1.0 else 1.0 - progress;
    }

    pub fn offset(self: Moving, partial_ticks: f32) f32 {
        return self.offsetAt(self.renderProgress(partial_ticks));
    }

    pub fn shoveAlong(self: Moving, amount: f32) math.Vec3 {
        const delta = self.facing.step();
        return .{
            .x = @as(f64, amount) * @as(f64, @floatFromInt(delta[0])),
            .y = @as(f64, amount) * @as(f64, @floatFromInt(delta[1])),
            .z = @as(f64, amount) * @as(f64, @floatFromInt(delta[2])),
        };
    }

    pub fn renderProgress(self: Moving, partial_ticks: f32) f32 {
        const t = @min(partial_ticks, 1.0);
        return self.prev_progress + (self.progress - self.prev_progress) * t;
    }

    pub fn displacement(self: Moving, partial_ticks: f32) [3]f32 {
        const along = self.offset(partial_ticks);
        const delta = self.facing.step();
        return .{
            along * @as(f32, @floatFromInt(delta[0])),
            along * @as(f32, @floatFromInt(delta[1])),
            along * @as(f32, @floatFromInt(delta[2])),
        };
    }

    pub fn isFinished(self: Moving) bool {
        return self.prev_progress >= 1.0;
    }
};

pub const Placed = struct {
    pos: BlockPos,
    state: Moving,
};

const put = nbt.putDuped;

pub fn store(gpa: std.mem.Allocator, pos: BlockPos, state: Moving) !nbt.Tag {
    var compound: nbt.Compound = .{};
    errdefer {
        var owned: nbt.Tag = .{ .compound = compound };
        nbt.deinit(gpa, &owned);
    }

    try tile.header(gpa, &compound, id_key, pos);
    try put(gpa, &compound, "blockId", .{ .int = @intFromEnum(state.stored) });
    try put(gpa, &compound, "blockData", .{ .int = state.stored_metadata });
    try put(gpa, &compound, "facing", .{ .int = block.pistonFacingValue(state.facing) });
    try put(gpa, &compound, "progress", .{ .float = state.prev_progress });
    try put(gpa, &compound, "extending", .{ .byte = @intFromBool(state.extending) });

    return .{ .compound = compound };
}

pub fn isPiston(compound: nbt.Compound) bool {
    return tile.isKind(compound, id_key);
}

fn floatField(compound: nbt.Compound, key: []const u8) f32 {
    return switch (compound.get(key) orelse return 0) {
        .float => |value| value,
        else => 0,
    };
}

fn boolField(compound: nbt.Compound, key: []const u8) bool {
    return switch (compound.get(key) orelse return false) {
        .byte => |value| value != 0,
        else => false,
    };
}

pub fn load(compound: nbt.Compound) ?Placed {
    if (!isPiston(compound)) return null;

    const raw_id = nbt.intField(compound, "blockId") orelse 0;
    const stored: Block = if (raw_id >= 0 and raw_id <= 255 and
        std.enums.tagName(Block, @as(Block, @enumFromInt(@as(u8, @intCast(raw_id))))) != null)
        @enumFromInt(@as(u8, @intCast(raw_id)))
    else
        .air;

    const progress = floatField(compound, "progress");
    const state: Moving = .{
        .stored = stored,
        .stored_metadata = @intCast(@as(u32, @bitCast(nbt.intField(compound, "blockData") orelse 0)) & 15),
        .facing = block.pistonFacing(@intCast(@as(u32, @bitCast(nbt.intField(compound, "facing") orelse 0)) & 15)),
        .extending = boolField(compound, "extending"),
        .source = stored.isPistonBase(),
        .progress = progress,
        .prev_progress = progress,
    };

    return .{
        .pos = tile.position(compound) orelse return null,
        .state = state,
    };
}

fn step(pos: BlockPos, facing: Side, times: i32) [3]i32 {
    const delta = facing.step();
    return .{ pos.x + delta[0] * times, pos.y + delta[1] * times, pos.z + delta[2] * times };
}

pub fn hasTileEntity(world_map: *World, pos: BlockPos) bool {
    if (world_map.getBlock(pos) == .chest) return true;
    if (world_map.furnaces.contains(.{ .x = pos.x, .y = pos.y, .z = pos.z })) return true;
    if (world_map.signs.contains(.{ .x = pos.x, .y = pos.y, .z = pos.z })) return true;
    return world_map.pistons.contains(.{ .x = pos.x, .y = pos.y, .z = pos.z });
}

pub fn canPush(world_map: *World, pos: BlockPos, destroying: bool) bool {
    const id = world_map.getBlock(pos);
    if (id == .obsidian) return false;

    if (id.isPistonBase()) {
        if (block.pistonExtended(world_map.getBlockMetadata(pos))) return false;
    } else {
        if (id.isUnbreakable()) return false;
        switch (id.mobility()) {
            .immovable => return false,
            .fragile => if (!destroying) return false,
            .movable => {},
        }
    }

    return !hasTileEntity(world_map, pos);
}

pub fn isPowered(world_map: *World, pos: BlockPos, facing: Side) bool {
    const facing_value = block.pistonFacingValue(facing);
    const around = [_]struct { at: [3]i32, side: Side, skip: u4 }{
        .{ .at = .{ pos.x, pos.y - 1, pos.z }, .side = .down, .skip = 0 },
        .{ .at = .{ pos.x, pos.y + 1, pos.z }, .side = .up, .skip = 1 },
        .{ .at = .{ pos.x, pos.y, pos.z - 1 }, .side = .north, .skip = 2 },
        .{ .at = .{ pos.x, pos.y, pos.z + 1 }, .side = .south, .skip = 3 },
        .{ .at = .{ pos.x + 1, pos.y, pos.z }, .side = .east, .skip = 5 },
        .{ .at = .{ pos.x - 1, pos.y, pos.z }, .side = .west, .skip = 4 },
    };
    for (around) |probe| {
        if (facing_value == probe.skip) continue;
        if (redstone.isBlockIndirectlyProvidingPowerTo(world_map, .init(probe.at[0], probe.at[1], probe.at[2]), probe.side)) return true;
    }

    const above = [_]struct { at: [3]i32, side: Side }{
        .{ .at = .{ pos.x, pos.y, pos.z }, .side = .down },
        .{ .at = .{ pos.x, pos.y + 2, pos.z }, .side = .up },
        .{ .at = .{ pos.x, pos.y + 1, pos.z - 1 }, .side = .north },
        .{ .at = .{ pos.x, pos.y + 1, pos.z + 1 }, .side = .south },
        .{ .at = .{ pos.x - 1, pos.y + 1, pos.z }, .side = .west },
        .{ .at = .{ pos.x + 1, pos.y + 1, pos.z }, .side = .east },
    };
    for (above) |probe| {
        if (redstone.isBlockIndirectlyProvidingPowerTo(world_map, .init(probe.at[0], probe.at[1], probe.at[2]), probe.side)) return true;
    }

    return false;
}

pub fn canExtend(world_map: *World, pos: BlockPos, facing: Side) bool {
    var at = step(pos, facing, 1);

    var travelled: u32 = 0;
    while (travelled <= push_limit) : (travelled += 1) {
        if (at[1] <= 0 or at[1] >= 127) return false;

        const id = world_map.getBlock(.init(at[0], at[1], at[2]));
        if (id == .air) return true;
        if (!canPush(world_map, .init(at[0], at[1], at[2]), true)) return false;
        if (id.mobility() == .fragile) return true;
        if (travelled == push_limit) return false;

        at = step(.init(at[0], at[1], at[2]), facing, 1);
    }

    return true;
}

fn dropBlockAt(world_map: *World, pos: BlockPos) !void {
    const id = world_map.getBlock(pos);
    if (id.drop(world_map.getBlockMetadata(pos), &world_map.rand)) |stack| {
        try world_map.dropped.append(world_map.allocator, .{
            .pos = .{ .x = pos.x, .y = pos.y, .z = pos.z },
            .stack = stack,
        });
    }
}

var pushing: bool = false;

fn extend(world_map: *World, pos: BlockPos, id: Block, facing: Side) !bool {
    if (!canExtend(world_map, pos, facing)) return false;

    var far = step(pos, facing, 1);
    var travelled: u32 = 0;
    while (travelled <= push_limit) : (travelled += 1) {
        const at_id = world_map.getBlock(.init(far[0], far[1], far[2]));
        if (at_id == .air) break;
        if (at_id.mobility() == .fragile) {
            try dropBlockAt(world_map, .init(far[0], far[1], far[2]));
            try world_map.setBlockWithNotify(.init(far[0], far[1], far[2]), .air);
            break;
        }
        far = step(.init(far[0], far[1], far[2]), facing, 1);
    }

    const facing_value = block.pistonFacingValue(facing);
    const head_metadata = facing_value | (if (id == .piston_sticky) block.piston_flag else 0);

    while (far[0] != pos.x or far[1] != pos.y or far[2] != pos.z) {
        const behind = step(.init(far[0], far[1], far[2]), facing, -1);
        const behind_id = world_map.getBlock(.init(behind[0], behind[1], behind[2]));
        const behind_metadata = world_map.getBlockMetadata(.init(behind[0], behind[1], behind[2]));

        const at_base = behind[0] == pos.x and behind[1] == pos.y and behind[2] == pos.z;
        const moving: Moving = if (at_base and behind_id == id) .{
            .stored = .piston_head,
            .stored_metadata = head_metadata,
            .facing = facing,
            .extending = true,
        } else .{
            .stored = behind_id,
            .stored_metadata = behind_metadata,
            .facing = facing,
            .extending = true,
        };

        try world_map.setBlockAndMetadataWithNotify(.init(far[0], far[1], far[2]), .piston_moving, moving.stored_metadata);
        try world_map.addMovingPiston(.init(far[0], far[1], far[2]), moving);

        far = behind;
    }

    return true;
}

fn clearHead(world_map: *World, head: [3]i32) !void {
    pushing = false;
    try world_map.setBlockWithNotify(.init(head[0], head[1], head[2]), .air);
    pushing = true;
}

fn retract(world_map: *World, pos: BlockPos, id: Block, facing: Side) !void {
    const head = step(pos, facing, 1);
    if (world_map.movingPistonAt(.init(head[0], head[1], head[2])) != null) {
        try world_map.finishMovingPiston(.init(head[0], head[1], head[2]));
    }

    const facing_value = block.pistonFacingValue(facing);
    try world_map.setBlockAndMetadataWithNotify(pos, .piston_moving, facing_value);
    try world_map.addMovingPiston(pos, .{
        .stored = id,
        .stored_metadata = facing_value,
        .facing = facing,
        .extending = false,
        .source = true,
    });

    if (id != .piston_sticky) {
        try clearHead(world_map, head);
        return;
    }

    const pulled = step(pos, facing, 2);
    var pulled_id = world_map.getBlock(.init(pulled[0], pulled[1], pulled[2]));
    var pulled_metadata = world_map.getBlockMetadata(.init(pulled[0], pulled[1], pulled[2]));

    var already_moving = false;
    if (pulled_id == .piston_moving) {
        if (world_map.movingPistonAt(.init(pulled[0], pulled[1], pulled[2]))) |state| {
            if (state.facing == facing and state.extending) {
                const carried = state.*;
                try world_map.finishMovingPiston(.init(pulled[0], pulled[1], pulled[2]));
                pulled_id = carried.stored;
                pulled_metadata = carried.stored_metadata;
                already_moving = true;
            }
        }
    }

    const pullable = !already_moving and
        pulled_id != .air and
        canPush(world_map, .init(pulled[0], pulled[1], pulled[2]), false) and
        (pulled_id.mobility() == .movable or pulled_id.isPistonBase());

    if (!pullable) {
        if (!already_moving) try clearHead(world_map, head);
        return;
    }

    try world_map.setBlockWithNotify(.init(pulled[0], pulled[1], pulled[2]), .air);
    try world_map.setBlockAndMetadataWithNotify(.init(head[0], head[1], head[2]), .piston_moving, pulled_metadata);
    try world_map.addMovingPiston(.init(head[0], head[1], head[2]), .{
        .stored = pulled_id,
        .stored_metadata = pulled_metadata,
        .facing = facing,
        .extending = false,
    });
}

pub fn updatePowerState(world_map: *World, pos: BlockPos) !void {
    const id = world_map.getBlock(pos);
    if (!id.isPistonBase()) return;

    const metadata = world_map.getBlockMetadata(pos);
    if (metadata == 7) return;

    const facing = block.pistonFacing(metadata);
    const facing_value = block.pistonFacingValue(facing);
    const powered = isPowered(world_map, pos, facing);
    const extended = block.pistonExtended(metadata);

    if (powered and !extended) {
        if (!canExtend(world_map, pos, facing)) return;
        world_map.setBlockMetadata(pos, facing_value | block.piston_flag);

        pushing = true;
        defer pushing = false;
        if (try extend(world_map, pos, id, facing)) {
            try world_map.setBlockMetadataWithNotify(pos, facing_value | block.piston_flag);
            playPistonSound(world_map, pos, assets.sounds.tile.piston.out, 0.25, 0.6);
        }
    } else if (!powered and extended) {
        world_map.setBlockMetadata(pos, facing_value);

        pushing = true;
        defer pushing = false;
        try retract(world_map, pos, id, facing);
        playPistonSound(world_map, pos, assets.sounds.tile.piston.in, 0.15, 0.6);
    }
}

fn playPistonSound(world_map: *World, pos: BlockPos, sound: assets.Sound, spread: f32, floor: f32) void {
    world_map.playSoundEffect(
        pos.center(),
        sound,
        0.5,
        world_map.rand.nextFloat() * spread + floor,
    );
}

pub fn onNeighborChange(world_map: *World, pos: BlockPos) !void {
    if (pushing) return;
    try updatePowerState(world_map, pos);
}

pub fn onBlockAdded(world_map: *World, pos: BlockPos) !void {
    if (world_map.movingPistonAt(pos) != null) return;
    try updatePowerState(world_map, pos);
}

pub fn onHeadNeighborChange(world_map: *World, pos: BlockPos) !void {
    const facing = block.pistonFacing(world_map.getBlockMetadata(pos));
    const behind = step(pos, facing, -1);

    if (!world_map.getBlock(.init(behind[0], behind[1], behind[2])).isPistonBase()) {
        try world_map.setBlockWithNotify(pos, .air);
        return;
    }

    try onNeighborChange(world_map, .init(behind[0], behind[1], behind[2]));
}

pub fn onHeadRemoved(world_map: *World, pos: BlockPos, metadata: u4) !void {
    const facing = block.pistonFacing(metadata);
    const base = step(pos, facing, -1);

    const id = world_map.getBlock(.init(base[0], base[1], base[2]));
    if (!id.isPistonBase()) return;
    if (!block.pistonExtended(world_map.getBlockMetadata(.init(base[0], base[1], base[2])))) return;

    try dropBlockAt(world_map, .init(base[0], base[1], base[2]));
    try world_map.setBlockWithNotify(.init(base[0], base[1], base[2]), .air);
}

pub const placement_reach: f32 = 2.0;
pub const placement_eye_height: f64 = 1.82;

pub fn facingForPlacement(player: math.Vec3, pos: BlockPos, yaw: f32) Side {
    const to_x = @abs(@as(f32, @floatCast(player.x)) - @as(f32, @floatFromInt(pos.x)));
    const to_z = @abs(@as(f32, @floatCast(player.z)) - @as(f32, @floatFromInt(pos.z)));

    if (to_x < placement_reach and to_z < placement_reach) {
        const eye = player.y + placement_eye_height;
        const block_y: f64 = @floatFromInt(pos.y);
        if (eye - block_y > 2.0) return .up;
        if (block_y - eye > 0.0) return .down;
    }

    return @enumFromInt(block.furnaceFacingFromYaw(yaw));
}

pub fn onBlockPlaced(world_map: *World, pos: BlockPos, player: math.Vec3, yaw: f32) !void {
    const facing = facingForPlacement(player, pos, yaw);
    try world_map.setBlockMetadataWithNotify(pos, block.pistonFacingValue(facing));
    try updatePowerState(world_map, pos);
}

fn pistonWorld(gpa: std.mem.Allocator) !World {
    return testing_world.flatWorld(gpa, 1);
}

fn settle(world_map: *World) !void {
    for (0..4) |_| try world_map.tickPistons();
}

test "a powered piston throws its head out and drops it again when the power goes" {
    const gpa = std.testing.allocator;
    var w = try pistonWorld(gpa);
    defer w.deinit();

    try w.setBlockAndMetadataWithNotify(.init(8, 1, 8), .piston, block.pistonFacingValue(.up));
    try std.testing.expect(!block.pistonExtended(w.getBlockMetadata(.init(8, 1, 8))));

    try w.setBlockWithNotify(.init(9, 1, 8), .torch_redstone_on);
    try std.testing.expect(block.pistonExtended(w.getBlockMetadata(.init(8, 1, 8))));
    try std.testing.expectEqual(Block.piston_moving, w.getBlock(.init(8, 2, 8)));

    try settle(&w);
    try std.testing.expectEqual(Block.piston_head, w.getBlock(.init(8, 2, 8)));
    try std.testing.expectEqual(Side.up, block.pistonFacing(w.getBlockMetadata(.init(8, 2, 8))));

    try w.setBlockWithNotify(.init(9, 1, 8), .air);
    try std.testing.expect(!block.pistonExtended(w.getBlockMetadata(.init(8, 1, 8))));

    try settle(&w);
    try std.testing.expectEqual(Block.piston, w.getBlock(.init(8, 1, 8)));
    try std.testing.expectEqual(Block.air, w.getBlock(.init(8, 2, 8)));
}

test "a piston shoves the block in front of it one along" {
    const gpa = std.testing.allocator;
    var w = try pistonWorld(gpa);
    defer w.deinit();

    try w.setBlockAndMetadataWithNotify(.init(8, 1, 8), .piston, block.pistonFacingValue(.up));
    try w.setBlockWithNotify(.init(8, 2, 8), .wool);

    try w.setBlockWithNotify(.init(9, 1, 8), .torch_redstone_on);
    try settle(&w);

    try std.testing.expectEqual(Block.piston_head, w.getBlock(.init(8, 2, 8)));
    try std.testing.expectEqual(Block.wool, w.getBlock(.init(8, 3, 8)));
}

test "a piston will not push a column longer than twelve blocks" {
    const gpa = std.testing.allocator;
    var w = try pistonWorld(gpa);
    defer w.deinit();

    try w.setBlockAndMetadataWithNotify(.init(8, 1, 8), .piston, block.pistonFacingValue(.up));
    for (2..2 + push_limit + 1) |y| {
        try w.setBlockWithNotify(.init(8, @intCast(y), 8), .wool);
    }

    try std.testing.expect(!canExtend(&w, .init(8, 1, 8), .up));

    try w.setBlockWithNotify(.init(9, 1, 8), .torch_redstone_on);
    try std.testing.expect(!block.pistonExtended(w.getBlockMetadata(.init(8, 1, 8))));
    try std.testing.expectEqual(Block.wool, w.getBlock(.init(8, 2, 8)));
}

test "a piston pushing into a torch snaps it off and drops it" {
    const gpa = std.testing.allocator;
    var w = try pistonWorld(gpa);
    defer w.deinit();

    try w.setBlockAndMetadataWithNotify(.init(8, 1, 8), .piston, block.pistonFacingValue(.up));
    try w.setBlockWithNotify(.init(8, 2, 8), .torch);

    try w.setBlockWithNotify(.init(9, 1, 8), .torch_redstone_on);
    try settle(&w);

    try std.testing.expectEqual(Block.piston_head, w.getBlock(.init(8, 2, 8)));

    var dropped_torch = false;
    for (w.dropped.items) |drop| {
        if (drop.stack.id.eql(.{ .block = .torch })) dropped_torch = true;
    }
    try std.testing.expect(dropped_torch);
}

test "obsidian and bedrock will not budge" {
    const gpa = std.testing.allocator;
    var w = try pistonWorld(gpa);
    defer w.deinit();

    try w.setBlockWithNotify(.init(8, 2, 8), .obsidian);
    try std.testing.expect(!canPush(&w, .init(8, 2, 8), true));

    try w.setBlockWithNotify(.init(8, 2, 8), .bedrock);
    try std.testing.expect(!canPush(&w, .init(8, 2, 8), true));

    try w.setBlockWithNotify(.init(8, 2, 8), .wool);
    try std.testing.expect(canPush(&w, .init(8, 2, 8), true));
}

test "a sticky piston drags its block back, a plain one leaves it behind" {
    const gpa = std.testing.allocator;

    for ([_]Block{ .piston_sticky, .piston }) |kind| {
        var w = try pistonWorld(gpa);
        defer w.deinit();

        try w.setBlockAndMetadataWithNotify(.init(8, 1, 8), kind, block.pistonFacingValue(.up));
        try w.setBlockWithNotify(.init(8, 2, 8), .wool);

        try w.setBlockWithNotify(.init(9, 1, 8), .torch_redstone_on);
        try settle(&w);
        try std.testing.expectEqual(Block.wool, w.getBlock(.init(8, 3, 8)));

        try w.setBlockWithNotify(.init(9, 1, 8), .air);
        try settle(&w);

        try std.testing.expectEqual(kind, w.getBlock(.init(8, 1, 8)));
        if (kind == .piston_sticky) {
            try std.testing.expectEqual(Block.wool, w.getBlock(.init(8, 2, 8)));
            try std.testing.expectEqual(Block.air, w.getBlock(.init(8, 3, 8)));
        } else {
            try std.testing.expectEqual(Block.air, w.getBlock(.init(8, 2, 8)));
            try std.testing.expectEqual(Block.wool, w.getBlock(.init(8, 3, 8)));
        }
    }
}

test "breaking the head takes the piston with it" {
    const gpa = std.testing.allocator;
    var w = try pistonWorld(gpa);
    defer w.deinit();

    try w.setBlockAndMetadataWithNotify(.init(8, 1, 8), .piston, block.pistonFacingValue(.up));
    try w.setBlockWithNotify(.init(9, 1, 8), .torch_redstone_on);
    try settle(&w);
    try std.testing.expectEqual(Block.piston_head, w.getBlock(.init(8, 2, 8)));

    try w.setBlockWithNotify(.init(8, 2, 8), .air);

    try std.testing.expectEqual(Block.air, w.getBlock(.init(8, 1, 8)));
    var dropped_piston = false;
    for (w.dropped.items) |drop| {
        if (drop.stack.id.eql(.{ .block = .piston })) dropped_piston = true;
    }
    try std.testing.expect(dropped_piston);
}

test "a head left without its base removes itself" {
    const gpa = std.testing.allocator;
    var w = try pistonWorld(gpa);
    defer w.deinit();

    try w.setBlockAndMetadataWithNotify(.init(8, 2, 8), .piston_head, block.pistonFacingValue(.up));
    try w.setBlockWithNotify(.init(8, 3, 8), .wool);

    try std.testing.expectEqual(Block.air, w.getBlock(.init(8, 2, 8)));
}

test "a pushed block slides over two ticks before it lands" {
    const gpa = std.testing.allocator;
    var w = try pistonWorld(gpa);
    defer w.deinit();

    try w.setBlockAndMetadataWithNotify(.init(8, 1, 8), .piston, block.pistonFacingValue(.up));
    try w.setBlockWithNotify(.init(8, 2, 8), .wool);
    try w.setBlockWithNotify(.init(9, 1, 8), .torch_redstone_on);

    try std.testing.expectEqual(Block.piston_moving, w.getBlock(.init(8, 3, 8)));
    const carried = w.movingPistonAt(.init(8, 3, 8)).?;
    try std.testing.expectEqual(Block.wool, carried.stored);
    try std.testing.expect(carried.extending);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), carried.progress, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), carried.offset(0), 1.0e-6);

    try w.tickPistons();
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), w.movingPistonAt(.init(8, 3, 8)).?.progress, 1.0e-6);

    try w.tickPistons();
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), w.movingPistonAt(.init(8, 3, 8)).?.progress, 1.0e-6);

    try w.tickPistons();
    try std.testing.expectEqual(Block.wool, w.getBlock(.init(8, 3, 8)));
    try std.testing.expect(w.movingPistonAt(.init(8, 3, 8)) == null);
}

test "an extending piston asks for its riders to be shoved along" {
    const gpa = std.testing.allocator;
    var w = try pistonWorld(gpa);
    defer w.deinit();

    try w.setBlockAndMetadataWithNotify(.init(8, 1, 8), .piston, block.pistonFacingValue(.up));
    try w.setBlockWithNotify(.init(8, 2, 8), .wool);
    try w.setBlockWithNotify(.init(9, 1, 8), .torch_redstone_on);

    try w.tickPistons();

    var shoved_wool = false;
    for (w.piston_shoves.items) |shove| {
        if (shove.state.stored != .wool) continue;
        shoved_wool = true;
        try std.testing.expectEqual(Side.up, shove.state.facing);
        try std.testing.expect(shove.amount > 0.5);
    }
    try std.testing.expect(shoved_wool);
}

test "a retracting piston asks for no shove at all" {
    const gpa = std.testing.allocator;
    var w = try pistonWorld(gpa);
    defer w.deinit();

    try w.setBlockAndMetadataWithNotify(.init(8, 1, 8), .piston_sticky, block.pistonFacingValue(.up));
    try w.setBlockWithNotify(.init(8, 2, 8), .wool);
    try w.setBlockWithNotify(.init(9, 1, 8), .torch_redstone_on);
    try settle(&w);

    try w.setBlockWithNotify(.init(9, 1, 8), .air);
    try w.tickPistons();

    for (w.piston_shoves.items) |shove| {
        try std.testing.expect(shove.state.extending);
    }
}

test "a piston placed at your feet faces up, one above your head faces down" {
    const standing = math.Vec3.init(8.5, 10.0, 8.5);

    try std.testing.expectEqual(Side.up, facingForPlacement(standing, .init(8, 7, 8), 0));
    try std.testing.expectEqual(Side.down, facingForPlacement(standing, .init(8, 13, 8), 0));
}

test "a piston placed at arm's length faces the way you were looking" {
    const standing = math.Vec3.init(8.5, 10.0, 8.5);

    try std.testing.expectEqual(Side.north, facingForPlacement(standing, .init(8, 10, 8), 0));
    try std.testing.expectEqual(Side.east, facingForPlacement(standing, .init(8, 10, 8), 90));
    try std.testing.expectEqual(Side.south, facingForPlacement(standing, .init(8, 10, 8), 180));
    try std.testing.expectEqual(Side.west, facingForPlacement(standing, .init(8, 10, 8), 270));
}

test "a piston placed from further off ignores the up and down rule" {
    const far_off = math.Vec3.init(20.0, 10.0, 8.5);

    try std.testing.expectEqual(Side.north, facingForPlacement(far_off, .init(8, 7, 8), 0));
    try std.testing.expectEqual(Side.north, facingForPlacement(far_off, .init(8, 13, 8), 0));
}

test "a moving block leads by a whole block and closes on its target" {
    var state: Moving = .{ .facing = .up, .extending = true };

    try std.testing.expectApproxEqAbs(@as(f32, -1.0), state.offset(0), 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), state.displacement(0)[1], 1.0e-6);

    state.progress = 1.0;
    state.prev_progress = 1.0;
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), state.offset(0), 1.0e-6);
}

test "a retracting block starts under the piston and is drawn back in" {
    var state: Moving = .{ .facing = .up, .extending = false };

    try std.testing.expectApproxEqAbs(@as(f32, 1.0), state.offset(0), 1.0e-6);

    state.progress = 1.0;
    state.prev_progress = 1.0;
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), state.offset(0), 1.0e-6);
}

test "the slide is interpolated between the last tick and this one" {
    const state: Moving = .{ .facing = .east, .extending = true, .prev_progress = 0.0, .progress = 0.5 };

    try std.testing.expectApproxEqAbs(@as(f32, -1.0), state.offset(0.0), 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -0.75), state.offset(0.5), 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), state.offset(1.0), 1.0e-6);

    try std.testing.expectApproxEqAbs(@as(f32, -0.5), state.displacement(1.0)[0], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), state.displacement(1.0)[1], 1.0e-6);
}

test "a moving block survives a record round trip" {
    const gpa = std.testing.allocator;
    const state: Moving = .{
        .stored = .cobblestone,
        .stored_metadata = 3,
        .facing = .north,
        .extending = true,
        .progress = 0.5,
        .prev_progress = 0.5,
    };

    var tag = try store(gpa, .init(4, 70, -9), state);
    defer nbt.deinit(gpa, &tag);

    const restored = load(tag.compound).?;
    try std.testing.expectEqual(BlockPos.init(4, 70, -9), restored.pos);
    try std.testing.expectEqual(Block.cobblestone, restored.state.stored);
    try std.testing.expectEqual(@as(u4, 3), restored.state.stored_metadata);
    try std.testing.expectEqual(Side.north, restored.state.facing);
    try std.testing.expect(restored.state.extending);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), restored.state.progress, 1.0e-6);
}

test "a record naming a block this port does not have comes back as air" {
    const gpa = std.testing.allocator;
    var tag = try store(gpa, .init(0, 0, 0), .{ .stored = .cobblestone });
    defer nbt.deinit(gpa, &tag);

    tag.compound.getPtr("blockId").?.* = .{ .int = 97 };

    try std.testing.expectEqual(Block.air, load(tag.compound).?.state.stored);
}
