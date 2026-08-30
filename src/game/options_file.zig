const std = @import("std");

const Settings = @import("Settings.zig");

pub const file_name = "options.txt";

const max_file_bytes = 1 << 16;
const key_prefix = "key_";

fn bindingKey(binding: Settings.Binding) []const u8 {
    return switch (binding) {
        .forward => "key.forward",
        .left => "key.left",
        .back => "key.back",
        .right => "key.right",
        .jump => "key.jump",
        .sneak => "key.sneak",
        .drop => "key.drop",
        .inventory => "key.inventory",
        .chat => "key.chat",
        .fog => "key.fog",
    };
}

fn boolText(value: bool) []const u8 {
    return if (value) "true" else "false";
}

fn parseBool(value: []const u8) bool {
    return std.mem.eql(u8, value, "true");
}

fn parseFloat(value: []const u8) ?f32 {
    if (std.mem.eql(u8, value, "true")) return 1.0;
    if (std.mem.eql(u8, value, "false")) return 0.0;
    return std.fmt.parseFloat(f32, value) catch null;
}

fn parseChoice(comptime Choice: type, value: []const u8) ?Choice {
    const ordinal = std.fmt.parseInt(u8, value, 10) catch return null;
    if (ordinal >= std.enums.values(Choice).len) return null;
    return @enumFromInt(ordinal);
}

fn writeFloat(out: *std.Io.Writer, name: []const u8, value: f32) !void {
    var buffer: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{d}", .{value});
    try out.print("{s}:{s}", .{ name, text });
    if (std.mem.indexOfAny(u8, text, ".eEn") == null) try out.writeAll(".0");
    try out.writeByte('\n');
}

pub fn encode(gpa: std.mem.Allocator, settings: *const Settings) ![]u8 {
    var document: std.Io.Writer.Allocating = .init(gpa);
    errdefer document.deinit();
    const out = &document.writer;

    try writeFloat(out, "music", settings.music_volume);
    try writeFloat(out, "sound", settings.sound_volume);
    try out.print("invertYMouse:{s}\n", .{boolText(settings.invert_mouse)});
    try writeFloat(out, "mouseSensitivity", settings.sensitivity);
    try out.print("viewDistance:{d}\n", .{@intFromEnum(settings.render_distance)});
    try out.print("guiScale:{d}\n", .{@intFromEnum(settings.gui_scale)});
    try out.print("bobView:{s}\n", .{boolText(settings.view_bobbing)});
    try out.print("anaglyph3d:{s}\n", .{boolText(settings.anaglyph)});
    try out.print("advancedOpengl:{s}\n", .{boolText(settings.advanced_opengl)});
    try out.print("fullscreen:{s}\n", .{boolText(settings.fullscreen)});
    try out.print("fpsLimit:{d}\n", .{@intFromEnum(settings.framerate_limit)});
    try out.print("difficulty:{d}\n", .{@intFromEnum(settings.difficulty)});
    try out.print("fancyGraphics:{s}\n", .{boolText(settings.fancy_graphics)});
    try out.print("ao:{s}\n", .{boolText(settings.ambient_occlusion)});
    try out.print("skin:{s}\n", .{settings.skin.text()});
    try out.print("lastServer:{s}\n", .{settings.last_server.text()});

    for (std.enums.values(Settings.Binding)) |binding| {
        try out.print("{s}{s}:{d}\n", .{ key_prefix, bindingKey(binding), settings.keys.get(binding) });
    }

    return document.toOwnedSlice();
}

fn applyOption(settings: *Settings, name: []const u8, value: []const u8) void {
    if (std.mem.startsWith(u8, name, key_prefix)) {
        const description = name[key_prefix.len..];
        for (std.enums.values(Settings.Binding)) |binding| {
            if (!std.mem.eql(u8, description, bindingKey(binding))) continue;
            settings.keys.set(binding, std.fmt.parseInt(u32, value, 10) catch return);
            return;
        }
        return;
    }

    if (std.mem.eql(u8, name, "music")) {
        settings.music_volume = parseFloat(value) orelse return;
    } else if (std.mem.eql(u8, name, "sound")) {
        settings.sound_volume = parseFloat(value) orelse return;
    } else if (std.mem.eql(u8, name, "mouseSensitivity")) {
        settings.sensitivity = parseFloat(value) orelse return;
    } else if (std.mem.eql(u8, name, "invertYMouse")) {
        settings.invert_mouse = parseBool(value);
    } else if (std.mem.eql(u8, name, "viewDistance")) {
        settings.render_distance = parseChoice(Settings.RenderDistance, value) orelse return;
    } else if (std.mem.eql(u8, name, "guiScale")) {
        settings.gui_scale = parseChoice(Settings.GuiScale, value) orelse return;
    } else if (std.mem.eql(u8, name, "bobView")) {
        settings.view_bobbing = parseBool(value);
    } else if (std.mem.eql(u8, name, "anaglyph3d")) {
        settings.anaglyph = parseBool(value);
    } else if (std.mem.eql(u8, name, "advancedOpengl")) {
        settings.advanced_opengl = parseBool(value);
    } else if (std.mem.eql(u8, name, "fullscreen")) {
        settings.fullscreen = parseBool(value);
    } else if (std.mem.eql(u8, name, "fpsLimit")) {
        settings.framerate_limit = parseChoice(Settings.FramerateLimit, value) orelse return;
    } else if (std.mem.eql(u8, name, "difficulty")) {
        settings.difficulty = parseChoice(Settings.Difficulty, value) orelse return;
    } else if (std.mem.eql(u8, name, "fancyGraphics")) {
        settings.fancy_graphics = parseBool(value);
    } else if (std.mem.eql(u8, name, "ao")) {
        settings.ambient_occlusion = parseBool(value);
    } else if (std.mem.eql(u8, name, "skin")) {
        settings.skin.set(value);
    } else if (std.mem.eql(u8, name, "lastServer")) {
        settings.last_server.set(value);
    }
}

pub fn decode(settings: *Settings, text: []const u8) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        applyOption(settings, line[0..colon], line[colon + 1 ..]);
    }
}

pub fn load(gpa: std.mem.Allocator, io: std.Io, base: std.Io.Dir) Settings {
    var settings: Settings = .{};

    const file = base.openFile(io, file_name, .{}) catch return settings;
    defer file.close(io);

    const size = file.length(io) catch return settings;
    if (size == 0 or size > max_file_bytes) return settings;

    const text = gpa.alloc(u8, @intCast(size)) catch return settings;
    defer gpa.free(text);
    if ((file.readPositionalAll(io, text, 0) catch return settings) != text.len) return settings;

    decode(&settings, text);
    return settings;
}

pub fn save(gpa: std.mem.Allocator, io: std.Io, base: std.Io.Dir, settings: *const Settings) !void {
    const text = try encode(gpa, settings);
    defer gpa.free(text);

    const file = try base.createFile(io, file_name, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, text);
}

test "the defaults round-trip through the file the original writes" {
    const gpa = std.testing.allocator;
    const defaults: Settings = .{};

    const text = try encode(gpa, &defaults);
    defer gpa.free(text);

    try std.testing.expect(std.mem.startsWith(u8, text, "music:1.0\nsound:1.0\ninvertYMouse:false\nmouseSensitivity:0.5\n"));
    try std.testing.expect(std.mem.indexOf(u8, text, "\nviewDistance:0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\nfpsLimit:1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\ndifficulty:2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\nskin:Default\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\nlastServer:\n") != null);

    var loaded: Settings = .{ .difficulty = .hard, .anaglyph = true };
    decode(&loaded, text);
    try std.testing.expectEqual(defaults.difficulty, loaded.difficulty);
    try std.testing.expectEqual(defaults.anaglyph, loaded.anaglyph);
    try std.testing.expectEqualStrings(Settings.default_skin, loaded.skin.text());
}

test "every field survives a round trip" {
    const gpa = std.testing.allocator;
    var written: Settings = .{
        .music_volume = 0.25,
        .sound_volume = 0.0,
        .sensitivity = 0.875,
        .invert_mouse = true,
        .difficulty = .peaceful,
        .fancy_graphics = false,
        .render_distance = .tiny,
        .ambient_occlusion = false,
        .framerate_limit = .power_saver,
        .anaglyph = true,
        .view_bobbing = false,
        .gui_scale = .large,
        .advanced_opengl = true,
        .fullscreen = true,
        .skin = .init("Fancy Pack.zip"),
        .last_server = .init("localhost_25565"),
    };
    written.keys.set(.forward, 1234);
    written.keys.set(.fog, 7);

    const text = try encode(gpa, &written);
    defer gpa.free(text);

    var read: Settings = .{};
    decode(&read, text);

    try std.testing.expectEqual(written.music_volume, read.music_volume);
    try std.testing.expectEqual(written.sound_volume, read.sound_volume);
    try std.testing.expectEqual(written.sensitivity, read.sensitivity);
    try std.testing.expectEqual(written.invert_mouse, read.invert_mouse);
    try std.testing.expectEqual(written.difficulty, read.difficulty);
    try std.testing.expectEqual(written.fancy_graphics, read.fancy_graphics);
    try std.testing.expectEqual(written.render_distance, read.render_distance);
    try std.testing.expectEqual(written.ambient_occlusion, read.ambient_occlusion);
    try std.testing.expectEqual(written.framerate_limit, read.framerate_limit);
    try std.testing.expectEqual(written.anaglyph, read.anaglyph);
    try std.testing.expectEqual(written.view_bobbing, read.view_bobbing);
    try std.testing.expectEqual(written.gui_scale, read.gui_scale);
    try std.testing.expectEqual(written.advanced_opengl, read.advanced_opengl);
    try std.testing.expectEqual(written.fullscreen, read.fullscreen);
    try std.testing.expectEqualStrings(written.skin.text(), read.skin.text());
    try std.testing.expectEqualStrings(written.last_server.text(), read.last_server.text());
    try std.testing.expectEqual(@as(u32, 1234), read.keys.get(.forward));
    try std.testing.expectEqual(@as(u32, 7), read.keys.get(.fog));
    try std.testing.expectEqual(written.keys.get(.jump), read.keys.get(.jump));
}

test "a bad line leaves the setting at its default and the rest still loads" {
    var settings: Settings = .{};
    decode(&settings,
        \\music:not-a-number
        \\viewDistance:9
        \\fpsLimit:3
        \\difficulty:banana
        \\guiScale:
        \\unknownOption:true
        \\no-colon-here
        \\anaglyph3d:true
    );

    try std.testing.expectEqual(@as(f32, 1.0), settings.music_volume);
    try std.testing.expectEqual(Settings.RenderDistance.far, settings.render_distance);
    try std.testing.expectEqual(Settings.FramerateLimit.balanced, settings.framerate_limit);
    try std.testing.expectEqual(Settings.Difficulty.normal, settings.difficulty);
    try std.testing.expectEqual(Settings.GuiScale.auto, settings.gui_scale);
    try std.testing.expect(settings.anaglyph);
}

test "a volume written as a boolean reads back as the original does" {
    var settings: Settings = .{};
    decode(&settings, "music:false\nsound:true\n");
    try std.testing.expectEqual(@as(f32, 0.0), settings.music_volume);
    try std.testing.expectEqual(@as(f32, 1.0), settings.sound_volume);
}

test "carriage returns from a file written on another platform are tolerated" {
    var settings: Settings = .{};
    decode(&settings, "anaglyph3d:true\r\nfancyGraphics:false\r\n");
    try std.testing.expect(settings.anaglyph);
    try std.testing.expect(!settings.fancy_graphics);
}

test "the file is written where the original writes it and read back" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.testing.expectEqual(Settings{}, load(gpa, io, tmp.dir));

    var written: Settings = .{ .anaglyph = true, .gui_scale = .normal, .skin = .init("Pack.zip") };
    written.keys.set(.jump, 99);
    try save(gpa, io, tmp.dir, &written);

    const file = try tmp.dir.openFile(io, file_name, .{});
    defer file.close(io);
    var stored: [4096]u8 = undefined;
    const length = try file.readPositionalAll(io, stored[0..@intCast(try file.length(io))], 0);
    try std.testing.expect(std.mem.indexOf(u8, stored[0..length], "\nanaglyph3d:true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, stored[0..length], "\nkey_key.jump:99\n") != null);

    const reloaded = load(gpa, io, tmp.dir);
    try std.testing.expect(reloaded.anaglyph);
    try std.testing.expectEqual(Settings.GuiScale.normal, reloaded.gui_scale);
    try std.testing.expectEqualStrings("Pack.zip", reloaded.skin.text());
    try std.testing.expectEqual(@as(u32, 99), reloaded.keys.get(.jump));
}
