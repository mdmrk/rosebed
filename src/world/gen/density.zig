const Chunk = @import("../Chunk.zig");

pub const size_x = 5;
pub const size_y = 17;
pub const size_z = 5;
pub const cells_xz = 4;
pub const cells_y = 16;

pub const Field = [size_x * size_y * size_z]f64;

pub fn index(ix: usize, iz: usize, iy: usize) usize {
    return (ix * size_z + iz) * size_y + iy;
}

pub fn fill(chunk: *Chunk, field: *const Field, picker: anytype) void {
    for (0..cells_xz) |cx| {
        for (0..cells_xz) |cz| {
            for (0..cells_y) |cy| {
                var corner_x0z0 = field[index(cx, cz, cy)];
                var corner_x0z1 = field[index(cx, cz + 1, cy)];
                var corner_x1z0 = field[index(cx + 1, cz, cy)];
                var corner_x1z1 = field[index(cx + 1, cz + 1, cy)];
                const step_x0z0 = (field[index(cx, cz, cy + 1)] - corner_x0z0) / 8.0;
                const step_x0z1 = (field[index(cx, cz + 1, cy + 1)] - corner_x0z1) / 8.0;
                const step_x1z0 = (field[index(cx + 1, cz, cy + 1)] - corner_x1z0) / 8.0;
                const step_x1z1 = (field[index(cx + 1, cz + 1, cy + 1)] - corner_x1z1) / 8.0;

                for (0..8) |sub_y| {
                    var edge_z0 = corner_x0z0;
                    var edge_z1 = corner_x0z1;
                    const step_edge_z0 = (corner_x1z0 - corner_x0z0) / 4.0;
                    const step_edge_z1 = (corner_x1z1 - corner_x0z1) / 4.0;

                    for (0..4) |sub_x| {
                        const bx: u32 = @intCast(cx * 4 + sub_x);
                        const by: u32 = @intCast(cy * 8 + sub_y);
                        var value = edge_z0;
                        const step_value = (edge_z1 - edge_z0) / 4.0;

                        for (0..4) |sub_z| {
                            const bz: u32 = @intCast(cz * 4 + sub_z);
                            chunk.setBlock(bx, by, bz, picker.pick(bx, by, bz, value));
                            value += step_value;
                        }

                        edge_z0 += step_edge_z0;
                        edge_z1 += step_edge_z1;
                    }

                    corner_x0z0 += step_x0z0;
                    corner_x0z1 += step_x0z1;
                    corner_x1z0 += step_x1z0;
                    corner_x1z1 += step_x1z1;
                }
            }
        }
    }
}
