const gl = @import("gl");

const MeshBuilder = @import("MeshBuilder.zig");

const GpuMesh = @This();

vao: gl.uint,
vbo: gl.uint,
ebo: gl.uint,
index_count: gl.sizei,
mode: gl.@"enum" = gl.TRIANGLES,

pub fn uploadLines(mesh: *const MeshBuilder) GpuMesh {
    var uploaded = upload(mesh);
    uploaded.mode = gl.LINES;
    return uploaded;
}

pub fn upload(mesh: *const MeshBuilder) GpuMesh {
    var vao: gl.uint = 0;
    var vbo: gl.uint = 0;
    var ebo: gl.uint = 0;
    gl.GenVertexArrays(1, @ptrCast(&vao));
    gl.GenBuffers(1, @ptrCast(&vbo));
    gl.GenBuffers(1, @ptrCast(&ebo));

    gl.BindVertexArray(vao);

    gl.BindBuffer(gl.ARRAY_BUFFER, vbo);
    gl.BufferData(
        gl.ARRAY_BUFFER,
        @intCast(mesh.vertices.items.len * @sizeOf(MeshBuilder.Vertex)),
        mesh.vertices.items.ptr,
        gl.STATIC_DRAW,
    );

    gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, ebo);
    gl.BufferData(
        gl.ELEMENT_ARRAY_BUFFER,
        @intCast(mesh.indices.items.len * @sizeOf(u32)),
        mesh.indices.items.ptr,
        gl.STATIC_DRAW,
    );

    const stride: gl.sizei = @sizeOf(MeshBuilder.Vertex);
    gl.VertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, stride, @offsetOf(MeshBuilder.Vertex, "x"));
    gl.EnableVertexAttribArray(0);
    gl.VertexAttribPointer(1, 2, gl.FLOAT, gl.FALSE, stride, @offsetOf(MeshBuilder.Vertex, "u"));
    gl.EnableVertexAttribArray(1);
    gl.VertexAttribPointer(2, 4, gl.UNSIGNED_BYTE, gl.TRUE, stride, @offsetOf(MeshBuilder.Vertex, "color"));
    gl.EnableVertexAttribArray(2);

    gl.BindVertexArray(0);

    return .{ .vao = vao, .vbo = vbo, .ebo = ebo, .index_count = @intCast(mesh.indices.items.len) };
}

pub fn draw(self: GpuMesh) void {
    gl.BindVertexArray(self.vao);
    gl.DrawElements(self.mode, self.index_count, gl.UNSIGNED_INT, 0);
}

pub fn drawRange(self: GpuMesh, first_index: usize, count: gl.sizei) void {
    gl.BindVertexArray(self.vao);
    gl.DrawElements(self.mode, count, gl.UNSIGNED_INT, first_index * @sizeOf(u32));
}

pub fn deinit(self: GpuMesh) void {
    gl.DeleteVertexArrays(1, @ptrCast(&self.vao));
    gl.DeleteBuffers(1, @ptrCast(&self.vbo));
    gl.DeleteBuffers(1, @ptrCast(&self.ebo));
}
