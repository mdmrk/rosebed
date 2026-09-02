const std = @import("std");

const world = @import("world");

const explosion = @import("explosion.zig");
const Level = @import("Level.zig");

pub const occupied_line = "This bed is occupied";
pub const no_sleep_line = "You can only sleep at night";

const blast_size: f32 = 5.0;
const blast_is_flaming = true;

pub fn blowUp(gpa: std.mem.Allocator, level: *Level, pillow: [3]i32, metadata: u4) !void {
    var x = pillow[0];
    var z = pillow[2];
    try level.world_map.setBlockWithNotify(.init(x, pillow[1], z), .air);

    const step = world.block.bedStep(world.block.bedFacing(metadata));
    x += step[0];
    z += step[1];
    if (level.world_map.getBlock(.init(x, pillow[1], z)) == .bed) {
        try level.world_map.setBlockWithNotify(.init(x, pillow[1], z), .air);
    }

    try explosion.detonate(
        gpa,
        &level.entities,
        &level.world_map,
        level.roster.items,
        .{
            .x = @as(f64, @as(f32, @floatFromInt(x)) + 0.5),
            .y = @as(f64, @as(f32, @floatFromInt(pillow[1])) + 0.5),
            .z = @as(f64, @as(f32, @floatFromInt(z)) + 0.5),
        },
        blast_size,
        blast_is_flaming,
        &level.world_map.rand,
    );
}
