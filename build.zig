const std = @import("std");
const Build = std.Build;
const Compile = Build.Step.Compile;
const LazyPath = Build.LazyPath;
const Module = Build.Module;
const OptimizeMode = std.builtin.OptimizeMode;
const ResolvedTarget = Build.ResolvedTarget;

const zigglgen = @import("zigglgen");

const android_min_api = 21;
const android_target_api = 35;
const android_sdl_root = "android/sdl";
const android_nullability_qualifiers = [_][]const u8{ "_Nonnull", "_Nullable", "_Null_unspecified" };

const ios_sdl_root = "ios/sdl";
const ios_app_dir = "Payload/rosebed.app";

const Platform = enum {
    desktop,
    web,
    android,
    ios,

    fn of(target: ResolvedTarget) Platform {
        if (target.result.os.tag == .emscripten) return .web;
        if (target.result.abi == .android or target.result.abi == .androideabi) return .android;
        if (target.result.os.tag == .ios) return .ios;
        return .desktop;
    }
};

const Modules = struct {
    gl: *Module,
    sdl3: *Module,
    zlua: *Module,
    math: *Module,
    core: *Module,
    assets: *Module,
    world: *Module,
    net: *Module,
    audio: *Module,
    game: *Module,
    mods: *Module,
    remote: *Module,
    render: *Module,
    server: *Module,

    const Name = std.meta.FieldEnum(Modules);

    fn imports(self: *const Modules, b: *Build, names: []const Name) []const Module.Import {
        const list = b.allocator.alloc(Module.Import, names.len) catch @panic("OOM");
        for (list, names) |*import, name| {
            import.* = .{ .name = @tagName(name), .module = self.get(name) };
        }
        return list;
    }

    fn get(self: *const Modules, name: Name) *Module {
        return switch (name) {
            inline else => |tag| @field(self, @tagName(tag)),
        };
    }
};

const client_imports = [_]Modules.Name{ .gl, .sdl3, .math, .core, .world, .render, .game, .assets, .audio, .net, .remote, .mods };

const ClientOptions = struct {
    root: []const u8 = "src/client/main.zig",
    strip: ?bool = null,
    link_libc: ?bool = null,
    touch: bool = false,
};

const Project = struct {
    b: *Build,
    target: ResolvedTarget,
    optimize: OptimizeMode,
    modules: Modules,
    lua: ?*Compile,

    fn init(b: *Build, target: ResolvedTarget, optimize: OptimizeMode, sdl_include: ?LazyPath, libc_include: []const LazyPath) Project {
        const platform = Platform.of(target);
        var project: Project = .{ .b = b, .target = target, .optimize = optimize, .modules = undefined, .lua = null };
        const modules = &project.modules;

        modules.gl = if (platform == .desktop) zigglgen.generateModule(b, .{
            .api = .gl,
            .version = .@"3.3",
            .profile = .core,
        }) else zigglgen.generateModule(b, .{
            .api = .gles,
            .version = .@"3.0",
        });

        const sdl3 = b.dependency("sdl3", .{
            .target = target,
            .optimize = optimize,
            .c_sdl_strip = !project.debug(),
            .c_sdl_lto = project.lto(),
            .c_sdl_sanitize_c = .off,
            .ext_mixer = true,
            .sdl_system_include_path = sdl_include,
        });
        modules.sdl3 = sdl3.module("sdl3");

        modules.math = project.source("src/math/root.zig", &.{});
        modules.core = project.source("src/core/root.zig", &.{});
        modules.assets = project.source("src/assets/root.zig", &.{});
        modules.world = project.source("src/world/root.zig", &.{ .math, .assets });
        modules.net = project.source("src/net/root.zig", &.{});

        const zlua = b.dependency("zlua", .{
            .target = target,
            .optimize = optimize,
            .lang = .lua54,
            .additional_system_headers = libc_include,
        });
        modules.zlua = zlua.module("zlua");
        project.lua = installedArtifact(zlua, "lua");
        if (project.lua) |lua| {
            if (platform == .web) for (libc_include) |include_path| lua.root_module.addSystemIncludePath(include_path);
            if (platform == .ios) lua.root_module.addCMacro("LUA_USE_IOS", "1");
        }

        modules.audio = project.source("src/audio/root.zig", &.{ .sdl3, .math, .assets });
        modules.game = project.source("src/game/root.zig", &.{ .math, .world, .assets, .net });
        modules.mods = project.source("src/mods/root.zig", &.{ .zlua, .math, .world, .net, .game });
        modules.remote = project.source("src/remote/root.zig", &.{ .math, .world, .game, .net, .assets });
        modules.render = project.source("src/render/root.zig", &.{ .gl, .sdl3, .math, .world, .game, .assets });
        modules.server = project.source("src/server/root.zig", &.{ .math, .world, .game, .net, .remote });
        return project;
    }

    fn debug(self: Project) bool {
        return self.optimize == .Debug;
    }

    fn lto(self: Project) std.zig.LtoMode {
        return if (!self.debug() and self.target.result.os.tag == .linux) .full else .none;
    }

    fn source(self: *const Project, root: []const u8, imports: []const Modules.Name) *Module {
        return self.b.createModule(.{
            .root_source_file = self.b.path(root),
            .target = self.target,
            .optimize = self.optimize,
            .imports = self.modules.imports(self.b, imports),
        });
    }

    fn client(self: *const Project, options: ClientOptions) *Module {
        const b = self.b;
        const module = b.createModule(.{
            .root_source_file = b.path(options.root),
            .target = self.target,
            .optimize = self.optimize,
            .strip = options.strip,
            .link_libc = options.link_libc,
            .imports = self.modules.imports(b, &client_imports),
        });
        module.addAnonymousImport("icon_png", .{ .root_source_file = b.path("web/favicon-96x96.png") });
        module.addAnonymousImport("github_png", .{ .root_source_file = b.path("web/github.png") });
        if (options.touch) module.addAnonymousImport("touch_png", .{ .root_source_file = b.path("android/hud.png") });
        return module;
    }

    fn prebuiltSdl(self: *const Project, lib_dir: LazyPath, mixer_file_name: []const u8) *Compile {
        systemLibsWithoutPkgConfig(self.modules.sdl3);
        const mixer = linkedLibrary(self.modules.sdl3, "SDL3_mixer");
        mixer.root_module.addLibraryPath(lib_dir);
        systemLibsWithoutPkgConfig(mixer.root_module);
        mixer.version = null;
        mixer.out_filename = mixer_file_name;
        mixer.out_lib_filename = mixer_file_name;
        mixer.major_only_filename = null;
        mixer.name_only_filename = null;
        return mixer;
    }
};

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    switch (Platform.of(target)) {
        .desktop => buildDesktop(b, target, optimize),
        .web => buildWeb(b, target, optimize),
        .android => buildAndroid(b, target, optimize),
        .ios => buildIos(b, target, optimize),
    }
}

fn buildDesktop(b: *Build, target: ResolvedTarget, optimize: OptimizeMode) void {
    const project = Project.init(b, target, optimize, null, &.{});
    const modules = &project.modules;

    const client = b.addExecutable(.{
        .name = "rosebed",
        .root_module = project.client(.{ .strip = !project.debug() }),
    });
    client.lto = project.lto();
    b.installArtifact(client);
    addRunStep(b, client, "run", "Run the app");

    const server = b.addExecutable(.{
        .name = "rosebed-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = !project.debug(),
            .imports = modules.imports(b, &.{ .math, .core, .world, .game, .net, .mods }),
        }),
    });
    server.lto = project.lto();
    b.installArtifact(server);
    addRunStep(b, server, "run-server", "Run the dedicated server");

    addToolStep(b, "fetch-assets", "tools/fetch_assets.zig", b.getInstallPath(.bin, "resources"), "Download the official Beta 1.7.3 client jar and extract its assets");
    addFetchAndroidSdl(b);
    addFetchIosSdl(b);

    const tested = [_]*Module{
        modules.math,
        modules.core,
        modules.net,
        modules.server,
        modules.remote,
        server.root_module,
        project.client(.{ .root = "src/client/app.zig" }),
        modules.world,
        modules.render,
        modules.audio,
        modules.game,
        modules.mods,
    };
    const test_step = b.step("test", "Run unit tests");
    for (tested) |module| {
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = module })).step);
    }
}

fn addRunStep(b: *Build, artifact: *Compile, name: []const u8, description: []const u8) void {
    const run = b.addRunArtifact(artifact);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step(name, description).dependOn(&run.step);
}

fn addToolStep(b: *Build, name: []const u8, root: []const u8, argument: []const u8, description: []const u8) void {
    const tool = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(root),
            .target = b.graph.host,
        }),
    });
    const run = b.addRunArtifact(tool);
    run.addArg(argument);
    b.step(name, description).dependOn(&run.step);
}

fn addFetchAndroidSdl(b: *Build) void {
    addToolStep(b, "fetch-android-sdl", "tools/fetch_android_sdl.zig", android_sdl_root, "Download the prebuilt SDL3 Android library and its Java glue");
}

fn addFetchIosSdl(b: *Build) void {
    addToolStep(b, "fetch-ios-sdl", "tools/fetch_ios_sdl.zig", ios_sdl_root, "Download the prebuilt SDL3 iOS framework from the official disk image");
}

const web_pre_js =
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
;

const web_persist_js =
    \\addToLibrary({
    \\    rosebed_persist: () => {
    \\        FS.syncfs(false, (err) => {
    \\            if (err) console.error('rosebed: saving to browser storage failed', err);
    \\        });
    \\    },
    \\    rosebed_page_is_secure: () => (typeof location !== 'undefined' && location.protocol === 'https:') ? 1 : 0,
    \\});
;

fn buildWeb(b: *Build, target: ResolvedTarget, optimize: OptimizeMode) void {
    const sysroot = b.sysroot orelse fail("'--sysroot' is required when building for Emscripten", .{});
    const sysroot_include: LazyPath = .{ .cwd_relative = b.pathJoin(&.{ sysroot, "include" }) };
    const project = Project.init(b, target, optimize, sysroot_include, &.{sysroot_include});

    const client_module = project.client(.{ .strip = !project.debug(), .link_libc = true });
    client_module.addSystemIncludePath(sysroot_include);
    const client = b.addLibrary(.{
        .linkage = .static,
        .name = "rosebed",
        .root_module = client_module,
    });
    client.lto = if (project.debug()) .none else .full;

    const emcc = b.addSystemCommand(&.{"emcc"});
    for (client.getCompileDependencies(false)) |artifact| {
        if (artifact.isStaticLibrary() or artifact.kind == .obj) emcc.addArtifactArg(artifact);
    }
    if (target.result.cpu.arch == .wasm64) emcc.addArg("-m64");
    emcc.addArgs(switch (optimize) {
        .Debug => &.{ "-O0", "-g", "-fsanitize=undefined" },
        .ReleaseSafe => &.{ "-O3", "-fsanitize=undefined", "-fsanitize-minimal-runtime" },
        .ReleaseFast => &.{"-O3"},
        .ReleaseSmall => &.{"-Oz"},
    });
    if (!project.debug()) emcc.addArgs(&.{ "--closure", "1" });
    emcc.addArgs(&.{
        "-sFULL_ES3",
        "-sSTACK_SIZE=4mb",
        "-sALLOW_MEMORY_GROWTH=1",
        "-lidbfs.js",
        "-lwebsocket.js",
        "-sEXPORTED_RUNTIME_METHODS=addRunDependency,removeRunDependency",
    });
    emcc.addArg("--pre-js");
    emcc.addFileArg(b.addWriteFiles().add("pre.js", web_pre_js));
    emcc.addArg("--pre-js");
    emcc.addFileArg(b.addWriteFiles().add("cache.js", b.fmt(
        \\Module['locateFile'] = (path, prefix) => prefix + path + '?v={s}';
        \\
    , .{commandOutput(b, &.{ "git", "rev-parse", "--short", "HEAD" }) orelse "dev"})));
    emcc.addArg("--js-library");
    emcc.addFileArg(b.addWriteFiles().add("persist.js", web_persist_js));
    emcc.addArg("--shell-file");
    emcc.addFileArg(b.path("web/shell.html"));
    emcc.addArg("-o");
    const app_html = emcc.addOutputFileArg("index.html");

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

fn buildAndroid(b: *Build, target: ResolvedTarget, optimize: OptimizeMode) void {
    const arch = target.result.cpu.arch;
    const abi_name = androidAbiName(arch);
    const api = b.option(u32, "android-api", "Minimum Android API level (default: 21)") orelse android_min_api;
    const ndk = androidPath(b, "android-ndk", "Path to the Android NDK", &.{ "ANDROID_NDK_HOME", "ANDROID_NDK_ROOT" });
    const sdk = androidPath(b, "android-sdk", "Path to the Android SDK", &.{ "ANDROID_HOME", "ANDROID_SDK_ROOT" });
    const build_tools = b.option([]const u8, "android-build-tools", "Android build-tools version (default: 35.0.0)") orelse "35.0.0";
    const platform = b.option([]const u8, "android-platform", "Android platform to link against (default: android-35)") orelse b.fmt("android-{d}", .{android_target_api});

    const sysroot = b.pathJoin(&.{ ndk, "toolchains/llvm/prebuilt", androidHostTag(b.graph.host.result), "sysroot" });
    const triple = androidTriple(arch);
    const libc_file = androidLibC(b, sysroot, triple, api);
    b.libc_file = libc_file;
    b.graph.environ_map.put("ZIG_LIBC", libc_file) catch @panic("OOM");
    b.graph.system_library_options.put(b.allocator, "sdl", .user_enabled) catch @panic("OOM");

    const sdl_lib_dir = b.path(b.fmt("{s}/lib/{s}", .{ android_sdl_root, abi_name }));
    const project = Project.init(b, target, optimize, b.path(android_sdl_root ++ "/include"), &.{
        .{ .cwd_relative = b.fmt("{s}/usr/include", .{sysroot}) },
        .{ .cwd_relative = b.fmt("{s}/usr/include/{s}", .{ sysroot, triple }) },
    });

    const client_module = project.client(.{ .strip = !project.debug(), .link_libc = true, .touch = true });
    client_module.addLibraryPath(sdl_lib_dir);
    const client = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "main",
        .root_module = client_module,
    });

    androidPatchSdl(project.modules.sdl3);
    if (project.lua) |lua| lua.root_module.pic = true;
    const mixer = project.prebuiltSdl(sdl_lib_dir, "libSDL3_mixer.so");

    const apk = androidApk(b, .{
        .sdk = sdk,
        .build_tools = build_tools,
        .platform = platform,
        .api = api,
        .abi_name = abi_name,
        .client = client,
        .mixer = mixer,
    });
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(apk, .prefix, "rosebed.apk").step);

    const adb = b.pathJoin(&.{ sdk, "platform-tools", "adb" });
    const install_apk = b.addSystemCommand(&.{ adb, "install", "-r" });
    install_apk.addFileArg(apk);
    const launch = b.addSystemCommand(&.{ adb, "shell", "am", "start", "-n", "io.github.mdmrk.rosebed/org.libsdl.app.SDLActivity" });
    launch.step.dependOn(&install_apk.step);
    b.step("run", "Install and launch the APK on a connected device").dependOn(&launch.step);

    addFetchAndroidSdl(b);
}

fn androidAbiName(arch: std.Target.Cpu.Arch) []const u8 {
    return switch (arch) {
        .aarch64 => "arm64-v8a",
        .arm => "armeabi-v7a",
        .x86_64 => "x86_64",
        .x86 => "x86",
        else => fail("unsupported Android architecture: {t}", .{arch}),
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

fn androidPath(b: *Build, option_name: []const u8, description: []const u8, variables: []const []const u8) []const u8 {
    if (b.option([]const u8, option_name, description)) |value| return value;
    for (variables) |variable| {
        if (b.graph.environ_map.get(variable)) |value| return value;
    }
    fail("'-D{s}' is required when building for Android (or set {s})", .{ option_name, variables[0] });
}

fn androidLibC(b: *Build, sysroot: []const u8, triple: []const u8, api: u32) []const u8 {
    return writeLibCFile(
        b,
        b.fmt("android-libc-{s}-{d}.txt", .{ triple, api }),
        b.fmt("{s}/usr/include", .{sysroot}),
        b.fmt("{s}/usr/include/{s}", .{ sysroot, triple }),
        b.fmt("{s}/usr/lib/{s}/{d}", .{ sysroot, triple, api }),
    );
}

fn androidPatchSdl(module: *Module) void {
    for (android_nullability_qualifiers) |qualifier| module.addCMacro(qualifier, "");
    const translate = sdlTranslateC(module) orelse return;
    translate.system_libs.clearRetainingCapacity();
    inline for (android_nullability_qualifiers) |qualifier| translate.defineCMacroRaw(qualifier ++ "=");
}

const AndroidApkOptions = struct {
    sdk: []const u8,
    build_tools: []const u8,
    platform: []const u8,
    api: u32,
    abi_name: []const u8,
    client: *Compile,
    mixer: *Compile,
};

fn androidApk(b: *Build, options: AndroidApkOptions) LazyPath {
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

    const align_apk = b.addSystemCommand(&.{ b.pathJoin(&.{ tools, "zipalign" }), "-p", "-f", "4" });
    align_apk.addFileArg(unsigned);
    const aligned = align_apk.addOutputFileArg("aligned.apk");

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

fn buildIos(b: *Build, target: ResolvedTarget, optimize: OptimizeMode) void {
    const sdk = iosSdk(b);
    const libc_file: LazyPath = .{ .cwd_relative = writeLibCFile(
        b,
        "ios-libc.txt",
        b.fmt("{s}/usr/include", .{sdk}),
        b.fmt("{s}/usr/include", .{sdk}),
        b.fmt("{s}/usr/lib", .{sdk}),
    ) };
    b.graph.system_library_options.put(b.allocator, "sdl", .user_enabled) catch @panic("OOM");

    const sdl_lib_dir = b.path(ios_sdl_root ++ "/lib");
    const sdk_include: LazyPath = .{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/include" }) };
    const project = Project.init(b, target, optimize, b.path(ios_sdl_root ++ "/include"), &.{sdk_include});

    const client_module = project.client(.{ .strip = !project.debug(), .link_libc = true, .touch = true });
    client_module.addLibraryPath(sdl_lib_dir);
    client_module.addRPathSpecial("@executable_path/Frameworks");
    const client = b.addExecutable(.{
        .name = "rosebed",
        .root_module = client_module,
    });
    client.setLibCFile(libc_file);

    iosPatchSdl(project.modules.sdl3, sdk_include);
    if (project.lua) |lua| lua.setLibCFile(libc_file);
    const mixer = project.prebuiltSdl(sdl_lib_dir, "libSDL3_mixer.dylib");
    mixer.setLibCFile(libc_file);

    const ipa = iosIpa(b, client, mixer);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(ipa, .prefix, "rosebed.ipa").step);

    addFetchIosSdl(b);
}

fn iosSdk(b: *Build) []const u8 {
    if (b.option([]const u8, "ios-sdk", "Path to the iPhoneOS SDK")) |value| return value;
    return commandOutput(b, &.{ "xcrun", "--sdk", "iphoneos", "--show-sdk-path" }) orelse
        fail("'-Dios-sdk' is required when 'xcrun' cannot locate the iPhoneOS SDK", .{});
}

fn iosPatchSdl(module: *Module, sdk_include: LazyPath) void {
    const translate = sdlTranslateC(module) orelse return;
    translate.system_libs.clearRetainingCapacity();
    translate.addSystemIncludePath(sdk_include);
}

fn iosIpa(b: *Build, client: *Compile, mixer: *Compile) LazyPath {
    const staging = b.addWriteFiles();
    _ = staging.addCopyFile(client.getEmittedBin(), ios_app_dir ++ "/rosebed");
    _ = staging.addCopyFile(b.path("ios/Info.plist"), ios_app_dir ++ "/Info.plist");
    _ = staging.addCopyFile(mixer.getEmittedBin(), ios_app_dir ++ "/Frameworks/libSDL3_mixer.dylib");
    _ = staging.addCopyDirectory(b.path(ios_sdl_root ++ "/SDL3.framework"), ios_app_dir ++ "/Frameworks/SDL3.framework", .{});

    const zip = b.addSystemCommand(&.{ "zip", "-q", "-X", "-r" });
    const ipa = zip.addOutputFileArg("rosebed.ipa");
    zip.addArg("Payload");
    zip.setCwd(staging.getDirectory());
    return ipa;
}

fn writeLibCFile(b: *Build, name: []const u8, include_dir: []const u8, sys_include_dir: []const u8, crt_dir: []const u8) []const u8 {
    const contents = b.fmt(
        \\include_dir={s}
        \\sys_include_dir={s}
        \\crt_dir={s}
        \\msvc_lib_dir=
        \\kernel32_lib_dir=
        \\gcc_dir=
        \\
    , .{ include_dir, sys_include_dir, crt_dir });
    b.cache_root.handle.writeFile(b.graph.io, .{ .sub_path = name, .data = contents }) catch |err| {
        fail("unable to write {s}: {t}", .{ name, err });
    };
    return b.cache_root.join(b.allocator, &.{name}) catch @panic("OOM");
}

fn sdlTranslateC(module: *Module) ?*Build.Step.TranslateC {
    const c_module = module.import_table.get("c") orelse return null;
    const generated = switch (c_module.root_source_file orelse return null) {
        .generated => |generated| generated,
        else => return null,
    };
    if (generated.file.step.id != .translate_c) return null;
    return @fieldParentPtr("step", generated.file.step);
}

fn systemLibsWithoutPkgConfig(module: *Module) void {
    for (module.link_objects.items) |*object| switch (object.*) {
        .system_lib => |*system_lib| system_lib.use_pkg_config = .no,
        else => {},
    };
}

fn installedArtifact(dependency: *Build.Dependency, name: []const u8) ?*Compile {
    for (dependency.builder.install_tls.step.dependencies.items) |step| {
        const install = step.cast(Build.Step.InstallArtifact) orelse continue;
        if (std.mem.eql(u8, install.artifact.name, name)) return install.artifact;
    }
    return null;
}

fn linkedLibrary(module: *Module, name: []const u8) *Compile {
    for (module.link_objects.items) |object| switch (object) {
        .other_step => |compile| if (std.mem.eql(u8, compile.name, name)) return compile,
        else => {},
    };
    fail("the sdl3 package no longer links {s}", .{name});
}

fn commandOutput(b: *Build, argv: []const []const u8) ?[]const u8 {
    var code: u8 = undefined;
    const output = b.runAllowFail(argv, &code, .ignore) catch return null;
    return std.mem.trim(u8, output, " \r\n");
}

fn fail(comptime format: []const u8, args: anytype) noreturn {
    std.log.err(format, args);
    std.process.exit(1);
}
