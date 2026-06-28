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

    const math_mod = b.createModule(.{
        .root_source_file = b.path("src/math/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const core_mod = b.createModule(.{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const world_mod = b.createModule(.{
        .root_source_file = b.path("src/world/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "math", .module = math_mod },
        },
    });

    const game_mod = b.createModule(.{
        .root_source_file = b.path("src/game/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "math", .module = math_mod },
            .{ .name = "world", .module = world_mod },
        },
    });

    const render_mod = b.createModule(.{
        .root_source_file = b.path("src/render/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "gl", .module = gl_bindings },
            .{ .name = "sdl3", .module = sdl3.module("sdl3") },
            .{ .name = "world", .module = world_mod },
            .{ .name = "game", .module = game_mod },
        },
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
                .{ .name = "math", .module = math_mod },
                .{ .name = "core", .module = core_mod },
                .{ .name = "world", .module = world_mod },
                .{ .name = "render", .module = render_mod },
                .{ .name = "game", .module = game_mod },
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

    const fetch_assets = b.addExecutable(.{
        .name = "fetch-assets",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/fetch_assets.zig"),
            .target = b.graph.host,
        }),
    });
    const fetch_assets_step = b.step("fetch-assets", "Download the official Beta 1.7.3 client jar and extract its assets");
    fetch_assets_step.dependOn(&b.addRunArtifact(fetch_assets).step);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = math_mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = core_mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = world_mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = render_mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = game_mod })).step);
}
