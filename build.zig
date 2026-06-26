const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const debug = optimize == .Debug;
    const linux = target.result.os.tag == .linux;
    const lto: std.zig.LtoMode = if (!debug and linux) .full else .none;

    const gl_bindings = @import("zigglgen").generateModule(b, .{
        .api = .gl,
        .version = .@"3.3",
        .profile = .core,
    });

    const sdl3 = b.dependency("sdl3", .{
        .target = target,
        .optimize = optimize,
        .main = true,
        .c_sdl_strip = !debug,
        .c_sdl_lto = lto,
    });

    const client = b.addExecutable(.{
        .name = "rosebed",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/client/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = !debug,
            .imports = &.{
                .{ .name = "gl", .module = gl_bindings },
                .{ .name = "sdl3", .module = sdl3.module("sdl3") },
            },
        }),
    });
    client.lto = lto;

    b.installArtifact(client);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(client);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
