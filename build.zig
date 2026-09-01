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
    const android = androidTarget(target);
    const lto: std.zig.LtoMode = if (!debug and linux) .full else .none;

    const gl_bindings =
        if (emscripten or android) zigglgen.generateModule(b, .{
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

    const assets_mod = b.createModule(.{
        .root_source_file = b.path("src/assets/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const world_mod = b.createModule(.{
        .root_source_file = b.path("src/world/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "math", .module = math_mod },
            .{ .name = "assets", .module = assets_mod },
        },
    });

    const net_mod = b.createModule(.{
        .root_source_file = b.path("src/net/root.zig"),
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
            .{ .name = "assets", .module = assets_mod },
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
    if (androidTarget(target)) return buildAndroid(b, target, optimize);

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
    client.root_module.addAnonymousImport("github_png", .{
        .root_source_file = b.path("web/github.png"),
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

    addFetchAndroidSdl(b);

    const client_test_mod = b.createModule(.{
        .root_source_file = b.path("src/client/app.zig"),
        .target = target,
        .optimize = optimize,
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
    client_test_mod.addAnonymousImport("icon_png", .{
        .root_source_file = b.path("web/favicon-96x96.png"),
    });
    client_test_mod.addAnonymousImport("github_png", .{
        .root_source_file = b.path("web/github.png"),
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = modules.math_mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = modules.core_mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = modules.net_mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = modules.server_mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = modules.remote_mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = server.root_module })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = client_test_mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = modules.world_mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = modules.render_mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = modules.audio_mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = modules.game_mod })).step);
}

fn webBuildId(b: *std.Build) []const u8 {
    var code: u8 = undefined;
    const revision = b.runAllowFail(&.{ "git", "rev-parse", "--short", "HEAD" }, &code, .ignore) catch return "dev";
    return std.mem.trim(u8, revision, " \r\n");
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
    client_mod.addAnonymousImport("github_png", .{
        .root_source_file = b.path("web/github.png"),
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
    run_emcc.addArg("--pre-js");
    run_emcc.addFileArg(b.addWriteFiles().add("cache.js", b.fmt(
        \\Module['locateFile'] = (path, prefix) => prefix + path + '?v={s}';
        \\
    , .{webBuildId(b)})));
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

fn androidTarget(target: std.Build.ResolvedTarget) bool {
    return target.result.abi == .android or target.result.abi == .androideabi;
}

const android_min_api = 21;
const android_target_api = 35;
const android_sdl_root = "android/sdl";

fn androidAbiName(arch: std.Target.Cpu.Arch) []const u8 {
    return switch (arch) {
        .aarch64 => "arm64-v8a",
        .arm => "armeabi-v7a",
        .x86_64 => "x86_64",
        .x86 => "x86",
        else => {
            std.log.err("unsupported Android architecture: {t}", .{arch});
            std.process.exit(1);
        },
    };
}

fn androidTriple(arch: std.Target.Cpu.Arch) []const u8 {
    return switch (arch) {
        .aarch64 => "aarch64-linux-android",
        .arm => "arm-linux-androideabi",
        .x86_64 => "x86_64-linux-android",
        .x86 => "i686-linux-android",
        else => unreachable,
    };
}

fn androidHostTag(host: std.Target) []const u8 {
    return switch (host.os.tag) {
        .macos => "darwin-x86_64",
        .windows => "windows-x86_64",
        else => "linux-x86_64",
    };
}

fn androidPath(b: *std.Build, option_name: []const u8, description: []const u8, variables: []const []const u8) []const u8 {
    if (b.option([]const u8, option_name, description)) |value| return value;
    for (variables) |variable| {
        if (b.graph.environ_map.get(variable)) |value| return value;
    }
    std.log.err("'-D{s}' is required when building for Android (or set {s})", .{ option_name, variables[0] });
    std.process.exit(1);
}

fn androidLibC(b: *std.Build, ndk: []const u8, arch: std.Target.Cpu.Arch, api: u32) []const u8 {
    const sysroot = b.pathJoin(&.{ ndk, "toolchains/llvm/prebuilt", androidHostTag(b.graph.host.result), "sysroot" });
    const contents = b.fmt(
        \\include_dir={s}/usr/include
        \\sys_include_dir={s}/usr/include/{s}
        \\crt_dir={s}/usr/lib/{s}/{d}
        \\msvc_lib_dir=
        \\kernel32_lib_dir=
        \\gcc_dir=
        \\
    , .{ sysroot, sysroot, androidTriple(arch), sysroot, androidTriple(arch), api });

    const name = b.fmt("android-libc-{s}-{d}.txt", .{ androidTriple(arch), api });
    b.cache_root.handle.writeFile(b.graph.io, .{ .sub_path = name, .data = contents }) catch |err| {
        std.log.err("unable to write {s}: {t}", .{ name, err });
        std.process.exit(1);
    };
    return b.cache_root.join(b.allocator, &.{name}) catch @panic("OOM");
}

fn androidPatchSdl(module: *std.Build.Module) void {
    module.addCMacro("_Nonnull", "");
    module.addCMacro("_Nullable", "");
    module.addCMacro("_Null_unspecified", "");

    const c_module = module.import_table.get("c") orelse return;
    const root = c_module.root_source_file orelse return;
    const generated = switch (root) {
        .generated => |generated| generated,
        else => return,
    };
    if (generated.file.step.id != .translate_c) return;
    const translate: *std.Build.Step.TranslateC = @fieldParentPtr("step", generated.file.step);

    translate.system_libs.clearRetainingCapacity();
    translate.defineCMacroRaw("_Nonnull=");
    translate.defineCMacroRaw("_Nullable=");
    translate.defineCMacroRaw("_Null_unspecified=");
}

fn androidSystemLibsWithoutPkgConfig(module: *std.Build.Module) void {
    for (module.link_objects.items) |*object| switch (object.*) {
        .system_lib => |*system_lib| system_lib.use_pkg_config = .no,
        else => {},
    };
}

fn androidLinkedLibrary(module: *std.Build.Module, name: []const u8) *std.Build.Step.Compile {
    for (module.link_objects.items) |object| switch (object) {
        .other_step => |compile| if (std.mem.eql(u8, compile.name, name)) return compile,
        else => {},
    };
    std.log.err("the sdl3 package no longer links {s}", .{name});
    std.process.exit(1);
}

fn buildAndroid(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const debug = optimize == .Debug;
    const arch = target.result.cpu.arch;
    const abi_name = androidAbiName(arch);
    const api = b.option(u32, "android-api", "Minimum Android API level (default: 21)") orelse android_min_api;
    const ndk = androidPath(b, "android-ndk", "Path to the Android NDK", &.{ "ANDROID_NDK_HOME", "ANDROID_NDK_ROOT" });
    const sdk = androidPath(b, "android-sdk", "Path to the Android SDK", &.{ "ANDROID_HOME", "ANDROID_SDK_ROOT" });
    const build_tools_version = b.option([]const u8, "android-build-tools", "Android build-tools version (default: 35.0.0)") orelse "35.0.0";
    const platform = b.option([]const u8, "android-platform", "Android platform to link against (default: android-35)") orelse b.fmt("android-{d}", .{android_target_api});

    const libc_file = androidLibC(b, ndk, arch, api);
    b.libc_file = libc_file;
    b.graph.environ_map.put("ZIG_LIBC", libc_file) catch @panic("OOM");
    b.graph.system_library_options.put(b.allocator, "sdl", .user_enabled) catch @panic("OOM");

    const sdl_lib_dir = b.path(b.fmt("{s}/lib/{s}", .{ android_sdl_root, abi_name }));
    const modules = setupModules(b, target, optimize, b.path(android_sdl_root ++ "/include"));

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
    client_mod.addAnonymousImport("github_png", .{
        .root_source_file = b.path("web/github.png"),
    });
    client_mod.addLibraryPath(sdl_lib_dir);

    const client = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "main",
        .root_module = client_mod,
    });

    androidPatchSdl(modules.sdl3_mod);

    androidSystemLibsWithoutPkgConfig(modules.sdl3_mod);

    const mixer = androidLinkedLibrary(modules.sdl3_mod, "SDL3_mixer");
    mixer.root_module.addLibraryPath(sdl_lib_dir);
    androidSystemLibsWithoutPkgConfig(mixer.root_module);
    mixer.version = null;
    mixer.out_filename = "libSDL3_mixer.so";
    mixer.out_lib_filename = mixer.out_filename;
    mixer.major_only_filename = null;
    mixer.name_only_filename = null;

    const apk = androidApk(b, .{
        .sdk = sdk,
        .build_tools = build_tools_version,
        .platform = platform,
        .api = api,
        .abi_name = abi_name,
        .client = client,
        .mixer = mixer,
    });

    b.getInstallStep().dependOn(&b.addInstallFileWithDir(apk, .prefix, "rosebed.apk").step);

    const run_step = b.step("run", "Install and launch the APK on a connected device");
    const install_apk = b.addSystemCommand(&.{ b.pathJoin(&.{ sdk, "platform-tools", "adb" }), "install", "-r" });
    install_apk.addFileArg(apk);
    const launch = b.addSystemCommand(&.{
        b.pathJoin(&.{ sdk, "platform-tools", "adb" }),
        "shell",
        "am",
        "start",
        "-n",
        "io.github.mdmrk.rosebed/org.libsdl.app.SDLActivity",
    });
    launch.step.dependOn(&install_apk.step);
    run_step.dependOn(&launch.step);

    addFetchAndroidSdl(b);
}

const AndroidApkOptions = struct {
    sdk: []const u8,
    build_tools: []const u8,
    platform: []const u8,
    api: u32,
    abi_name: []const u8,
    client: *std.Build.Step.Compile,
    mixer: *std.Build.Step.Compile,
};

fn androidApk(b: *std.Build, options: AndroidApkOptions) std.Build.LazyPath {
    const tools = b.pathJoin(&.{ options.sdk, "build-tools", options.build_tools });
    const aapt2 = b.pathJoin(&.{ tools, "aapt2" });
    const android_jar = b.pathJoin(&.{ options.sdk, "platforms", options.platform, "android.jar" });
    const min_api = b.fmt("{d}", .{options.api});

    const res = b.addWriteFiles();
    _ = res.addCopyFile(b.path("web/favicon-96x96.png"), "mipmap/icon.png");

    const compile_res = b.addSystemCommand(&.{ aapt2, "compile", "--dir" });
    compile_res.addDirectoryArg(res.getDirectory());
    compile_res.addArg("-o");
    const compiled_res = compile_res.addOutputFileArg("resources.zip");

    const link_res = b.addSystemCommand(&.{ aapt2, "link", "--manifest" });
    link_res.addFileArg(b.path("android/AndroidManifest.xml"));
    link_res.addArgs(&.{
        "-I",                   android_jar,
        "--min-sdk-version",    min_api,
        "--target-sdk-version", b.fmt("{d}", .{android_target_api}),
        "--output-to-dir",      "-o",
    });
    const linked_res = link_res.addOutputDirectoryArg("resources");
    link_res.addFileArg(compiled_res);

    const dex = b.addSystemCommand(&.{ b.pathJoin(&.{ tools, "d8" }), "--min-api", min_api, "--lib", android_jar, "--output" });
    const dex_dir = dex.addOutputDirectoryArg("dex");
    dex.addFileArg(b.path(android_sdl_root ++ "/classes.jar"));

    const staging = b.addWriteFiles();
    _ = staging.addCopyDirectory(linked_res, "", .{});
    _ = staging.addCopyFile(dex_dir.path(b, "classes.dex"), "classes.dex");
    _ = staging.addCopyFile(options.client.getEmittedBin(), b.fmt("lib/{s}/libmain.so", .{options.abi_name}));
    _ = staging.addCopyFile(options.mixer.getEmittedBin(), b.fmt("lib/{s}/libSDL3_mixer.so", .{options.abi_name}));
    _ = staging.addCopyFile(
        b.path(b.fmt("{s}/lib/{s}/libSDL3.so", .{ android_sdl_root, options.abi_name })),
        b.fmt("lib/{s}/libSDL3.so", .{options.abi_name}),
    );

    const zip = b.addSystemCommand(&.{ "zip", "-q", "-X", "-r", "-n", ".arsc" });
    const unsigned = zip.addOutputFileArg("unsigned.apk");
    zip.addArg(".");
    zip.setCwd(staging.getDirectory());

    const aligned_step = b.addSystemCommand(&.{ b.pathJoin(&.{ tools, "zipalign" }), "-p", "-f", "4" });
    aligned_step.addFileArg(unsigned);
    const aligned = aligned_step.addOutputFileArg("aligned.apk");

    const keytool = b.addSystemCommand(&.{
        "keytool",    "-genkeypair", "-keyalg",  "RSA",     "-keysize",  "2048",
        "-validity",  "10000",       "-alias",   "rosebed", "-dname",    "CN=rosebed",
        "-storepass", "android",     "-keypass", "android", "-keystore",
    });
    const keystore = keytool.addOutputFileArg("debug.keystore");

    const sign = b.addSystemCommand(&.{ b.pathJoin(&.{ tools, "apksigner" }), "sign", "--ks" });
    sign.addFileArg(keystore);
    sign.addArgs(&.{ "--ks-pass", "pass:android", "--key-pass", "pass:android", "--out" });
    const signed = sign.addOutputFileArg("rosebed.apk");
    sign.addFileArg(aligned);

    return signed;
}

fn addFetchAndroidSdl(b: *std.Build) void {
    const fetch = b.addExecutable(.{
        .name = "fetch-android-sdl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/fetch_android_sdl.zig"),
            .target = b.graph.host,
        }),
    });
    const run = b.addRunArtifact(fetch);
    run.addArg(android_sdl_root);
    const step = b.step("fetch-android-sdl", "Download the prebuilt SDL3 Android library and its Java glue");
    step.dependOn(&run.step);
}
