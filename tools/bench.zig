const std = @import("std");

const game = @import("game");
const math = @import("math");
const render = @import("render");
const world = @import("world");

const seed: i64 = 123456789;
const radius: i32 = 10;
const ticks: usize = 2000;

fn nowNs(io: std.Io) u64 {
    return @intCast(@max(std.Io.Clock.now(.awake, io).nanoseconds, 0));
}

fn report(name: []const u8, start: u64, end: u64, hash: u64) void {
    std.debug.print("{s:<6} {d:>8.1} ms  {x:0>16}\n", .{ name, @as(f64, @floatFromInt(end - start)) / std.time.ns_per_ms, hash });
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const only: ?[]const u8 = if (args.len > 1) args[1] else null;
    const runs = struct {
        fn wanted(filter: ?[]const u8, name: []const u8) bool {
            return filter == null or std.mem.eql(u8, filter.?, name);
        }
    };

    var level = game.Level.init(gpa, try world.Generator.init(gpa, .overworld, seed));
    defer level.deinit(gpa);
    level.attach();

    var start = nowNs(io);
    var cz: i32 = -radius;
    while (cz <= radius) : (cz += 1) {
        var cx: i32 = -radius;
        while (cx <= radius) : (cx += 1) try level.world_map.ensureDecorated(&level.generator, cx, cz);
    }
    var hash = std.hash.Wyhash.init(0);
    cz = -radius - 1;
    while (cz <= radius + 1) : (cz += 1) {
        var cx: i32 = -radius - 1;
        while (cx <= radius + 1) : (cx += 1) {
            const chunk = level.world_map.getChunk(cx, cz) orelse continue;
            hash.update(std.mem.asBytes(&chunk.blocks));
            hash.update(std.mem.asBytes(&chunk.metadata));
            hash.update(std.mem.asBytes(&chunk.sky_light));
            hash.update(std.mem.asBytes(&chunk.block_light));
        }
    }
    report("gen", start, nowNs(io), hash.final());

    if (runs.wanted(only, "mesh")) {
        var mesh: render.chunk_mesher.Mesh = .{};
        defer mesh.deinit(gpa);
        hash = std.hash.Wyhash.init(0);
        start = nowNs(io);
        for ([_]bool{ false, true }) |smooth| {
            cz = -radius + 1;
            while (cz < radius) : (cz += 1) {
                var cx: i32 = -radius + 1;
                while (cx < radius) : (cx += 1) {
                    const chunk = level.world_map.getChunk(cx, cz).?;
                    try render.chunk_mesher.buildInto(gpa, &mesh, &level.world_map, chunk, .untinted, .{ .smooth = smooth, .fancy = true });
                    hash.update(std.mem.sliceAsBytes(mesh.solid.vertices.items));
                    hash.update(std.mem.sliceAsBytes(mesh.translucent.vertices.items));
                }
            }
        }
        report("mesh", start, nowNs(io), hash.final());
    }

    if (runs.wanted(only, "tick")) {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        var y: i32 = world.Chunk.height - 2;
        while (y > 0 and !level.world_map.getBlock(.init(8, y, 8)).isSolid()) y -= 1;
        level.spawn = .{ 8, y + 1, 8 };
        var player = game.Player.spawn(math.Vec3.init(8.5, @floatFromInt(y + 1), 8.5));
        try level.enter(gpa, &player);

        start = nowNs(io);
        for (0..ticks) |_| {
            try level.tick(gpa, arena.allocator());
            _ = arena.reset(.retain_capacity);
        }
        const end = nowNs(io);
        hash = std.hash.Wyhash.init(0);
        hash.update(std.mem.asBytes(&level.world_map.rand));
        for (level.entities.mobs.items) |entry| hash.update(std.mem.asBytes(&entry.type_id));
        report("tick", start, end, hash.final());
    }
}
