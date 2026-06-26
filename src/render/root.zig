pub const Atlas = @import("atlas.zig");
pub const MeshBuilder = @import("mesh_builder.zig");
pub const chunk_mesher = @import("chunk_mesher.zig");
pub const Shader = @import("shader.zig");
pub const GpuMesh = @import("gpu_mesh.zig");
pub const terrain_shader = @import("terrain_shader.zig");

test {
    _ = Atlas;
    _ = MeshBuilder;
    _ = chunk_mesher;
    _ = Shader;
    _ = GpuMesh;
    _ = terrain_shader;
}
