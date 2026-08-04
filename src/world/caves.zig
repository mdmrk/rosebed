const std = @import("std");

const math = @import("math");

const block = @import("block.zig");
const Block = @import("block.zig").Block;
const Chunk = @import("chunk.zig");
const JavaRandom = @import("java_random.zig");

const chunk_radius: i32 = 8;

pub const Variant = enum { overworld, nether };

fn carveTunnel(
    variant: Variant,
    target_chunk_x: i32,
    target_chunk_z: i32,
    chunk: *Chunk,
    rand: *JavaRandom,
    x_in: f64,
    y_in: f64,
    z_in: f64,
    radius: f32,
    yaw_in: f32,
    pitch_in: f32,
    start_step_in: i32,
    total_steps_in: i32,
    vertical_stretch: f64,
) void {
    const center_x: f64 = @floatFromInt(target_chunk_x * 16 + 8);
    const center_z: f64 = @floatFromInt(target_chunk_z * 16 + 8);
    var x = x_in;
    var y = y_in;
    var z = z_in;
    var yaw = yaw_in;
    var pitch = pitch_in;
    var yaw_velocity: f32 = 0;
    var pitch_velocity: f32 = 0;

    var branch_rand = JavaRandom.init(rand.nextLong());

    var total_steps = total_steps_in;
    if (total_steps <= 0) {
        const max_len = chunk_radius * 16 - 16;
        total_steps = max_len - branch_rand.nextIntBound(@divTrunc(max_len, 4));
    }

    var start_step = start_step_in;
    var is_room = false;
    if (start_step == -1) {
        start_step = @divTrunc(total_steps, 2);
        is_room = true;
    }

    const branch_step = branch_rand.nextIntBound(@divTrunc(total_steps, 2)) + @divTrunc(total_steps, 4);
    const thick = branch_rand.nextIntBound(6) == 0;

    var step = start_step;
    while (step < total_steps) : (step += 1) {
        const step_f: f32 = @floatFromInt(step);
        const total_f: f32 = @floatFromInt(total_steps);
        const horizontal_radius: f64 = 1.5 + @as(f64, math.util.sin(step_f * std.math.pi / total_f) * radius);
        const vertical_radius = horizontal_radius * vertical_stretch;

        const cos_pitch = math.util.cos(pitch);
        const sin_pitch = math.util.sin(pitch);
        x += @as(f64, math.util.cos(yaw) * cos_pitch);
        y += @as(f64, sin_pitch);
        z += @as(f64, math.util.sin(yaw) * cos_pitch);

        pitch *= if (thick) 0.92 else 0.7;
        pitch += pitch_velocity * 0.1;
        yaw += yaw_velocity * 0.1;
        pitch_velocity *= 0.9;
        yaw_velocity *= 12.0 / 16.0;
        pitch_velocity += (branch_rand.nextFloat() - branch_rand.nextFloat()) * branch_rand.nextFloat() * 2.0;
        yaw_velocity += (branch_rand.nextFloat() - branch_rand.nextFloat()) * branch_rand.nextFloat() * 4.0;

        if (!is_room and step == branch_step and radius > 1.0) {
            carveTunnel(variant, target_chunk_x, target_chunk_z, chunk, rand, x, y, z, branch_rand.nextFloat() * 0.5 + 0.5, yaw - std.math.pi * 0.5, pitch / 3.0, step, total_steps, 1.0);
            carveTunnel(variant, target_chunk_x, target_chunk_z, chunk, rand, x, y, z, branch_rand.nextFloat() * 0.5 + 0.5, yaw + std.math.pi * 0.5, pitch / 3.0, step, total_steps, 1.0);
            return;
        }

        if (!is_room and branch_rand.nextIntBound(4) == 0) continue;

        const dx = x - center_x;
        const dz = z - center_z;
        const remaining: f64 = @floatFromInt(total_steps - step);
        const max_dist: f64 = radius + 2.0 + 16.0;
        if (dx * dx + dz * dz - remaining * remaining > max_dist * max_dist) return;

        if (x < center_x - 16.0 - horizontal_radius * 2.0 or
            z < center_z - 16.0 - horizontal_radius * 2.0 or
            x > center_x + 16.0 + horizontal_radius * 2.0 or
            z > center_z + 16.0 + horizontal_radius * 2.0) continue;

        var x0 = math.util.floorDouble(x - horizontal_radius) - target_chunk_x * 16 - 1;
        var x1 = math.util.floorDouble(x + horizontal_radius) - target_chunk_x * 16 + 1;
        var y0 = math.util.floorDouble(y - vertical_radius) - 1;
        var y1 = math.util.floorDouble(y + vertical_radius) + 1;
        var z0 = math.util.floorDouble(z - horizontal_radius) - target_chunk_z * 16 - 1;
        var z1 = math.util.floorDouble(z + horizontal_radius) - target_chunk_z * 16 + 1;

        if (x0 < 0) x0 = 0;
        if (x1 > 16) x1 = 16;
        if (y0 < 1) y0 = 1;
        if (y1 > 120) y1 = 120;
        if (z0 < 0) z0 = 0;
        if (z1 > 16) z1 = 16;

        var found_fluid = false;
        var bx = x0;
        fluid_scan: while (bx < x1) : (bx += 1) {
            var bz = z0;
            while (bz < z1) : (bz += 1) {
                const on_shell = bx == x0 or bx == x1 - 1 or bz == z0 or bz == z1 - 1;
                var by = y1 + 1;
                while (by >= y0 - 1) : (by -= 1) {
                    if (blocksTunnel(variant, chunk.getBlock(@intCast(bx), @intCast(by), @intCast(bz)))) {
                        found_fluid = true;
                        break :fluid_scan;
                    }
                    if (by != y0 - 1 and !on_shell) by = y0;
                }
            }
        }
        if (found_fluid) continue;

        bx = x0;
        while (bx < x1) : (bx += 1) {
            const nx: f64 = (@as(f64, @floatFromInt(bx + target_chunk_x * 16)) + 0.5 - x) / horizontal_radius;
            var bz = z0;
            while (bz < z1) : (bz += 1) {
                const nz: f64 = (@as(f64, @floatFromInt(bz + target_chunk_z * 16)) + 0.5 - z) / horizontal_radius;
                if (nx * nx + nz * nz >= 1.0) continue;

                var was_grass = false;
                var by = y1 - 1;
                while (by >= y0) : (by -= 1) {
                    const ny: f64 = (@as(f64, @floatFromInt(by)) + 0.5 - y) / vertical_radius;
                    if (ny <= -0.7 or nx * nx + ny * ny + nz * nz >= 1.0) continue;

                    const id = chunk.getBlock(@intCast(bx), @intCast(by + 1), @intCast(bz));
                    if (id == .grass) was_grass = true;
                    if (!isCarvable(variant, id)) continue;

                    switch (variant) {
                        .overworld => if (by < 10) {
                            chunk.setBlock(@intCast(bx), @intCast(by + 1), @intCast(bz), .flowing_lava);
                        } else {
                            chunk.setBlock(@intCast(bx), @intCast(by + 1), @intCast(bz), .air);
                            if (was_grass and chunk.getBlock(@intCast(bx), @intCast(by), @intCast(bz)) == .dirt) {
                                chunk.setBlock(@intCast(bx), @intCast(by), @intCast(bz), .grass);
                            }
                        },
                        .nether => chunk.setBlock(@intCast(bx), @intCast(by + 1), @intCast(bz), .air),
                    }
                }
            }
        }

        if (is_room) return;
    }
}

fn blocksTunnel(variant: Variant, id: Block) bool {
    return switch (variant) {
        .overworld => id == .stationary_water,
        .nether => id == .flowing_lava or id == .stationary_lava,
    };
}

fn isCarvable(variant: Variant, id: Block) bool {
    const native: Block = switch (variant) {
        .overworld => .stone,
        .nether => .netherrack,
    };
    return id == native or id == .dirt or id == .grass;
}

fn carveRoom(variant: Variant, target_chunk_x: i32, target_chunk_z: i32, chunk: *Chunk, rand: *JavaRandom, x: f64, y: f64, z: f64) void {
    carveTunnel(variant, target_chunk_x, target_chunk_z, chunk, rand, x, y, z, 1.0 + rand.nextFloat() * 6.0, 0.0, 0.0, -1, -1, 0.5);
}

fn carveFromChunk(variant: Variant, target_chunk_x: i32, target_chunk_z: i32, chunk: *Chunk, rand: *JavaRandom, source_chunk_x: i32, source_chunk_z: i32) void {
    const attempt_bound: i32 = switch (variant) {
        .overworld => 40,
        .nether => 10,
    };
    const rarity: i32 = switch (variant) {
        .overworld => 15,
        .nether => 5,
    };

    var tunnel_count = rand.nextIntBound(rand.nextIntBound(rand.nextIntBound(attempt_bound) + 1) + 1);
    if (rand.nextIntBound(rarity) != 0) tunnel_count = 0;

    for (0..@intCast(tunnel_count)) |_| {
        const x: f64 = @floatFromInt(source_chunk_x * 16 + rand.nextIntBound(16));
        const y: f64 = @floatFromInt(switch (variant) {
            .overworld => rand.nextIntBound(rand.nextIntBound(120) + 8),
            .nether => rand.nextIntBound(128),
        });
        const z: f64 = @floatFromInt(source_chunk_z * 16 + rand.nextIntBound(16));

        var systems: i32 = 1;
        if (rand.nextIntBound(4) == 0) {
            carveRoom(variant, target_chunk_x, target_chunk_z, chunk, rand, x, y, z);
            systems += rand.nextIntBound(4);
        }

        for (0..@intCast(systems)) |_| {
            const yaw = rand.nextFloat() * std.math.pi * 2.0;
            const pitch = (rand.nextFloat() - 0.5) * 2.0 / 8.0;
            const radius = rand.nextFloat() * 2.0 + rand.nextFloat();
            switch (variant) {
                .overworld => carveTunnel(variant, target_chunk_x, target_chunk_z, chunk, rand, x, y, z, radius, yaw, pitch, 0, 0, 1.0),
                .nether => carveTunnel(variant, target_chunk_x, target_chunk_z, chunk, rand, x, y, z, radius * 2.0, yaw, pitch, 0, 0, 0.5),
            }
        }
    }
}

pub fn carve(variant: Variant, chunk: *Chunk, chunk_x: i32, chunk_z: i32, world_seed: i64) void {
    var rand = JavaRandom.init(world_seed);
    const mult_x = @divTrunc(rand.nextLong(), 2) *% 2 +% 1;
    const mult_z = @divTrunc(rand.nextLong(), 2) *% 2 +% 1;

    var source_x = chunk_x - chunk_radius;
    while (source_x <= chunk_x + chunk_radius) : (source_x += 1) {
        var source_z = chunk_z - chunk_radius;
        while (source_z <= chunk_z + chunk_radius) : (source_z += 1) {
            const seed = (@as(i64, source_x) *% mult_x +% @as(i64, source_z) *% mult_z) ^ world_seed;
            rand.setSeed(seed);
            carveFromChunk(variant, chunk_x, chunk_z, chunk, &rand, source_x, source_z);
        }
    }
}

test "carving a chunk doesn't crash and can remove some solid blocks" {
    var chunk = Chunk.init(0, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            for (0..80) |y| {
                chunk.setBlock(@intCast(x), @intCast(y), @intCast(z), .stone);
            }
        }
    }

    var solid_before: usize = 0;
    for (0..16) |x| {
        for (0..16) |z| {
            for (0..80) |y| {
                if (chunk.getBlock(@intCast(x), @intCast(y), @intCast(z)) != .air) solid_before += 1;
            }
        }
    }

    carve(.overworld, &chunk, 0, 0, 12345);

    var solid_after: usize = 0;
    for (0..16) |x| {
        for (0..16) |z| {
            for (0..80) |y| {
                if (chunk.getBlock(@intCast(x), @intCast(y), @intCast(z)) != .air) solid_after += 1;
            }
        }
    }

    try std.testing.expect(solid_after <= solid_before);
}

test "hell caves eat netherrack and never leave a lava floor behind" {
    var chunk = Chunk.init(0, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            for (1..120) |y| {
                chunk.setBlock(@intCast(x), @intCast(y), @intCast(z), .netherrack);
            }
        }
    }

    carve(.nether, &chunk, 0, 0, 12345);

    var carved: usize = 0;
    for (0..16) |x| {
        for (0..16) |z| {
            for (1..120) |y| {
                const id = chunk.getBlock(@intCast(x), @intCast(y), @intCast(z));
                try std.testing.expect(id == .netherrack or id == .air);
                if (id == .air) carved += 1;
            }
        }
    }
    try std.testing.expect(carved > 0);
}

test "the overworld carver leaves netherrack alone, and the hell carver leaves stone alone" {
    var netherrack_chunk = Chunk.init(0, 0);
    var stone_chunk = Chunk.init(0, 0);
    for (0..16) |x| {
        for (0..16) |z| {
            for (1..120) |y| {
                netherrack_chunk.setBlock(@intCast(x), @intCast(y), @intCast(z), .netherrack);
                stone_chunk.setBlock(@intCast(x), @intCast(y), @intCast(z), .stone);
            }
        }
    }

    carve(.overworld, &netherrack_chunk, 0, 0, 12345);
    carve(.nether, &stone_chunk, 0, 0, 12345);

    for (0..16) |x| {
        for (0..16) |z| {
            for (1..120) |y| {
                try std.testing.expectEqual(.netherrack, netherrack_chunk.getBlock(@intCast(x), @intCast(y), @intCast(z)));
                try std.testing.expectEqual(.stone, stone_chunk.getBlock(@intCast(x), @intCast(y), @intCast(z)));
            }
        }
    }
}

test "the same seed and chunk position carve identical caves" {
    var chunk_a = Chunk.init(2, -1);
    var chunk_b = Chunk.init(2, -1);
    for (0..16) |x| {
        for (0..16) |z| {
            for (0..100) |y| {
                chunk_a.setBlock(@intCast(x), @intCast(y), @intCast(z), .stone);
                chunk_b.setBlock(@intCast(x), @intCast(y), @intCast(z), .stone);
            }
        }
    }

    carve(.overworld, &chunk_a, 2, -1, 777);
    carve(.overworld, &chunk_b, 2, -1, 777);

    for (0..16) |x| {
        for (0..16) |z| {
            for (0..100) |y| {
                try std.testing.expectEqual(
                    chunk_a.getBlock(@intCast(x), @intCast(y), @intCast(z)),
                    chunk_b.getBlock(@intCast(x), @intCast(y), @intCast(z)),
                );
            }
        }
    }
}
