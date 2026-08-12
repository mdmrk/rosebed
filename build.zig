const std = @import("std");

const zigglgen = @import("zigglgen");

const Modules = struct {
    gl_bindings: *std.Build.Module,
    sdl3_dep: *std.Build.Dependency,
    sdl3_mod: *std.Build.Module,
    math_mod: *std.Build.Module,
    core_mod: *std.Build.Module,
    net_mod: *std.Build.Module,
    remote_mod: *std.Build.Module,
    server_mod: *std.Build.Module,
    world_mod: *std.Build.Module,
    assets_mod: *std.Build.Module,
    audio_mod: *std.Build.Module,
    game_mod: *std.Build.Module,
    render_mod: *std.Build.Module,
};

pub fn setupModules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sysroot_include_path: ?std.Build.LazyPath,
) Modules {
    const debug = optimize == .Debug;
    const linux = target.result.os.tag == .linux;
    const emscripten = target.result.os.tag == .emscripten;
    const lto: std.zig.LtoMode = if (!debug and linux) .full else .none;

    const gl_bindings =
        if (emscripten) zigglgen.generateModule(b, .{
            .api = .gles,
            .version = .@"3.0",
        }) else zigglgen.generateModule(b, .{
            .api = .gl,
            .version = .@"3.3",
            .profile = .core,
        });

    const sdl3_dep = if (sysroot_include_path) |include_path| b.dependency("sdl3", .{
        .target = target,
        .optimize = optimize,
        .c_sdl_strip = !debug,
        .c_sdl_lto = lto,
        .c_sdl_sanitize_c = .off,
        .ext_mixer = true,
        .sdl_system_include_path = include_path,
    }) else b.dependency("sdl3", .{
        .target = target,
        .optimize = optimize,
        .c_sdl_strip = !debug,
        .c_sdl_lto = lto,
        .c_sdl_sanitize_c = .off,
        .ext_mixer = true,
    });
    const sdl3_mod = sdl3_dep.module("sdl3");

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

    const net_mod = b.createModule(.{
        .root_source_file = b.path("src/net/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const assets_mod = b.createModule(.{
        .root_source_file = b.path("src/assets/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const audio_mod = b.createModule(.{
        .root_source_file = b.path("src/audio/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sdl3", .module = sdl3_mod },
            .{ .name = "math", .module = math_mod },
            .{ .name = "assets", .module = assets_mod },
        },
    });

    const game_mod = b.createModule(.{
        .root_source_file = b.path("src/game/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "math", .module = math_mod },
            .{ .name = "world", .module = world_mod },
            .{ .name = "assets", .module = assets_mod },
            .{ .name = "net", .module = net_mod },
        },
    });

    const remote_mod = b.createModule(.{
        .root_source_file = b.path("src/remote/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "math", .module = math_mod },
            .{ .name = "world", .module = world_mod },
            .{ .name = "game", .module = game_mod },
            .{ .name = "net", .module = net_mod },
        },
    });

    const render_mod = b.createModule(.{
        .root_source_file = b.path("src/render/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "gl", .module = gl_bindings },
            .{ .name = "sdl3", .module = sdl3_mod },
            .{ .name = "math", .module = math_mod },
            .{ .name = "world", .module = world_mod },
            .{ .name = "game", .module = game_mod },
            .{ .name = "assets", .module = assets_mod },
        },
    });

    const server_mod = b.createModule(.{
        .root_source_file = b.path("src/server/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "math", .module = math_mod },
            .{ .name = "world", .module = world_mod },
            .{ .name = "game", .module = game_mod },
            .{ .name = "net", .module = net_mod },
            .{ .name = "remote", .module = remote_mod },
        },
    });

    return .{
        .gl_bindings = gl_bindings,
        .sdl3_dep = sdl3_dep,
        .sdl3_mod = sdl3_mod,
        .math_mod = math_mod,
        .core_mod = core_mod,
        .net_mod = net_mod,
        .remote_mod = remote_mod,
        .server_mod = server_mod,
        .world_mod = world_mod,
        .assets_mod = assets_mod,
        .audio_mod = audio_mod,
        .game_mod = game_mod,
        .render_mod = render_mod,
    };
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const debug = optimize == .Debug;
    const linux = target.result.os.tag == .linux;
    const lto: std.zig.LtoMode = if (!debug and linux) .full else .none;

    if (target.result.os.tag == .emscripten) return buildWeb(b, target, optimize);

    const modules = setupModules(b, target, optimize, null);

    const client = b.addExecutable(.{
        .name = "rosebed",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/client/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = !debug,
            .imports = &.{
                .{ .name = "gl", .module = modules.gl_bindings },
                .{ .name = "sdl3", .module = modules.sdl3_mod },
                .{ .name = "math", .module = modules.math_mod },
                .{ .name = "core", .module = modules.core_mod },
                .{ .name = "world", .module = modules.world_mod },
                .{ .name = "render", .module = modules.render_mod },
                .{ .name = "game", .module = modules.game_mod },
                .{ .name = "assets", .module = modules.assets_mod },
                .{ .name = "audio", .module = modules.audio_mod },
                .{ .name = "net", .module = modules.net_mod },
                .{ .name = "remote", .module = modules.remote_mod },
            },
        }),
    });
    client.root_module.addAnonymousImport("icon_png", .{
        .root_source_file = b.path("web/favicon-96x96.png"),
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

    const server = b.addExecutable(.{
        .name = "rosebed-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = !debug,
            .imports = &.{
                .{ .name = "math", .module = modules.math_mod },
                .{ .name = "core", .module = modules.core_mod },
                .{ .name = "world", .module = modules.world_mod },
                .{ .name = "game", .module = modules.game_mod },
                .{ .name = "net", .module = modules.net_mod },
            },
        }),
    });
    server.lto = lto;
    b.installArtifact(server);

    const run_server_step = b.step("run-server", "Run the dedicated server");
    const run_server_cmd = b.addRunArtifact(server);
    run_server_step.dependOn(&run_server_cmd.step);
    run_server_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_server_cmd.addArgs(args);

    const fetch_assets = b.addExecutable(.{
        .name = "fetch-assets",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/fetch_assets.zig"),
            .target = b.graph.host,
        }),
    });
    const fetch_assets_run = b.addRunArtifact(fetch_assets);
    fetch_assets_run.addArg(b.getInstallPath(.bin, "resources"));
    const fetch_assets_step = b.step("fetch-assets", "Download the official Beta 1.7.3 client jar and extract its assets");
    fetch_assets_step.dependOn(&fetch_assets_run.step);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = modules.math_mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = modules.core_mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = modules.net_mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = modules.server_mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = modules.remote_mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = server.root_module })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = modules.world_mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = modules.render_mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = modules.audio_mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = modules.game_mod })).step);
}

fn buildWeb(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const debug = optimize == .Debug;
    const lto: std.zig.LtoMode = if (!debug) .full else .none;

    const sysroot = b.sysroot orelse {
        std.log.err("'--sysroot' is required when building for Emscripten", .{});
        std.process.exit(1);
    };
    const sysroot_include_path: std.Build.LazyPath = .{ .cwd_relative = b.pathJoin(&.{ sysroot, "include" }) };
    const modules = setupModules(b, target, optimize, sysroot_include_path);

    const client_mod = b.createModule(.{
        .root_source_file = b.path("src/client/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = !debug,
        .link_libc = true,
        .imports = &.{
            .{ .name = "gl", .module = modules.gl_bindings },
            .{ .name = "sdl3", .module = modules.sdl3_mod },
            .{ .name = "math", .module = modules.math_mod },
            .{ .name = "core", .module = modules.core_mod },
            .{ .name = "world", .module = modules.world_mod },
            .{ .name = "render", .module = modules.render_mod },
            .{ .name = "game", .module = modules.game_mod },
            .{ .name = "assets", .module = modules.assets_mod },
            .{ .name = "audio", .module = modules.audio_mod },
            .{ .name = "net", .module = modules.net_mod },
            .{ .name = "remote", .module = modules.remote_mod },
        },
    });
    client_mod.addAnonymousImport("icon_png", .{
        .root_source_file = b.path("web/favicon-96x96.png"),
    });
    client_mod.addSystemIncludePath(sysroot_include_path);
    const client_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "rosebed",
        .root_module = client_mod,
    });
    client_lib.lto = lto;

    const run_emcc = b.addSystemCommand(&.{"emcc"});

    for (client_lib.getCompileDependencies(false)) |artifact| {
        if (artifact.isStaticLibrary() or artifact.kind == .obj) {
            run_emcc.addArtifactArg(artifact);
        }
    }

    if (target.result.cpu.arch == .wasm64) {
        run_emcc.addArg("-m64");
    }

    run_emcc.addArgs(switch (optimize) {
        .Debug => &.{
            "-O0",
            "-g",
            "-fsanitize=undefined",
        },
        .ReleaseSafe => &.{
            "-O3",
            "-fsanitize=undefined",
            "-fsanitize-minimal-runtime",
        },
        .ReleaseFast => &.{
            "-O3",
        },
        .ReleaseSmall => &.{
            "-Oz",
        },
    });

    if (optimize != .Debug) {
        run_emcc.addArgs(&.{ "--closure", "1" });
    }
    run_emcc.addArg("-sFULL_ES3");
    run_emcc.addArg("-sSTACK_SIZE=4mb");
    run_emcc.addArg("-sALLOW_MEMORY_GROWTH=1");
    run_emcc.addArg("-lidbfs.js");
    run_emcc.addArg("-sEXPORTED_RUNTIME_METHODS=addRunDependency,removeRunDependency");
    run_emcc.addArg("--pre-js");
    run_emcc.addFileArg(b.addWriteFiles().add("pre.js", (
        \\Module['print'] ??= (text) => console.log(text);
        \\Module['printErr'] ??= (text) => console.error(text);
        \\Module['preRun'] = [].concat(Module['preRun'] ?? [], () => {
        \\    if (typeof ENV !== 'undefined') ENV['NO_COLOR'] = '1';
        \\    FS.mkdir('/rosebed');
        \\    FS.mount(IDBFS, {}, '/rosebed');
        \\    Module['addRunDependency']('rosebed-idbfs');
        \\    FS.syncfs(true, (err) => {
        \\        if (err) console.error('rosebed: loading saved data failed', err);
        \\        Module['removeRunDependency']('rosebed-idbfs');
        \\    });
        \\});
    )));
    run_emcc.addArg("--js-library");
    run_emcc.addFileArg(b.addWriteFiles().add("persist.js", (
        \\addToLibrary({
        \\    rosebed_persist: () => {
        \\        FS.syncfs(false, (err) => {
        \\            if (err) console.error('rosebed: saving to browser storage failed', err);
        \\        });
        \\    },
        \\});
    )));
    run_emcc.addArg("--shell-file");
    run_emcc.addFileArg(b.path("web/shell.html"));

    run_emcc.addArg("-o");

    const app_html = run_emcc.addOutputFileArg("index.html");

    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = app_html.dirname(),
        .install_dir = .{ .custom = "www" },
        .install_subdir = "",
    }).step);

    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = b.path("web"),
        .install_dir = .{ .custom = "www" },
        .install_subdir = "",
        .exclude_extensions = &.{".html"},
    }).step);
}
