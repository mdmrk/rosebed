const std = @import("std");
const gl = @import("gl");

const Shader = @This();

program: gl.uint,

fn compile(kind: gl.@"enum", source: [:0]const u8) !gl.uint {
    const shader = gl.CreateShader(kind);
    const sources = [_][*]const u8{source.ptr};
    gl.ShaderSource(shader, 1, &sources, null);
    gl.CompileShader(shader);

    var status: gl.int = 0;
    gl.GetShaderiv(shader, gl.COMPILE_STATUS, @ptrCast(&status));
    if (status == gl.FALSE) {
        var log: [1024]u8 = undefined;
        var len: gl.sizei = 0;
        gl.GetShaderInfoLog(shader, log.len, &len, &log);
        std.log.err("shader compile error: {s}", .{log[0..@intCast(len)]});
        return error.ShaderCompileFailed;
    }
    return shader;
}

pub fn init(vertex_source: [:0]const u8, fragment_source: [:0]const u8) !Shader {
    const vertex = try compile(gl.VERTEX_SHADER, vertex_source);
    defer gl.DeleteShader(vertex);
    const fragment = try compile(gl.FRAGMENT_SHADER, fragment_source);
    defer gl.DeleteShader(fragment);

    const program = gl.CreateProgram();
    gl.AttachShader(program, vertex);
    gl.AttachShader(program, fragment);
    gl.LinkProgram(program);

    var status: gl.int = 0;
    gl.GetProgramiv(program, gl.LINK_STATUS, @ptrCast(&status));
    if (status == gl.FALSE) {
        var log: [1024]u8 = undefined;
        var len: gl.sizei = 0;
        gl.GetProgramInfoLog(program, log.len, &len, &log);
        std.log.err("program link error: {s}", .{log[0..@intCast(len)]});
        return error.ProgramLinkFailed;
    }

    return .{ .program = program };
}

pub fn use(self: Shader) void {
    gl.UseProgram(self.program);
}

pub fn setMat4(self: Shader, name: [:0]const u8, value: [16]f32) void {
    const location = gl.GetUniformLocation(self.program, name);
    gl.UniformMatrix4fv(location, 1, gl.FALSE, @ptrCast(&value));
}

pub fn setInt(self: Shader, name: [:0]const u8, value: gl.int) void {
    const location = gl.GetUniformLocation(self.program, name);
    gl.Uniform1i(location, value);
}

pub fn setFloat(self: Shader, name: [:0]const u8, value: f32) void {
    const location = gl.GetUniformLocation(self.program, name);
    gl.Uniform1f(location, value);
}

pub fn setVec3(self: Shader, name: [:0]const u8, value: [3]f32) void {
    const location = gl.GetUniformLocation(self.program, name);
    gl.Uniform3f(location, value[0], value[1], value[2]);
}

pub fn deinit(self: Shader) void {
    gl.DeleteProgram(self.program);
}
