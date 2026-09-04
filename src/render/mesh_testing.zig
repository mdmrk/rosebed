const std = @import("std");

const MeshBuilder = @import("MeshBuilder.zig");

pub const Shading = struct { top: ?u8, bottom: ?u8 };

pub fn horizontalFaceShading(mesh: MeshBuilder) Shading {
    var found: Shading = .{ .top = null, .bottom = null };
    var highest: f32 = -std.math.floatMax(f32);
    var lowest: f32 = std.math.floatMax(f32);
    var face: usize = 0;
    while (face * 4 < mesh.vertices.items.len) : (face += 1) {
        const corners = mesh.vertices.items[face * 4 ..][0..4];
        if (corners[1].y != corners[0].y or corners[2].y != corners[0].y or corners[3].y != corners[0].y) continue;
        if (corners[0].y > highest) {
            highest = corners[0].y;
            found.top = corners[0].color[0];
        }
        if (corners[0].y < lowest) {
            lowest = corners[0].y;
            found.bottom = corners[0].color[0];
        }
    }
    return found;
}
