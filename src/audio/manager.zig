const std = @import("std");

const assets = @import("assets");
const math = @import("math");
const sdl3 = @import("sdl3");

const Pool = @import("pool.zig");

const Manager = @This();

pub const folder_name = "resources";

const voice_count = 28;
const fade_distance: f32 = 16.0;
const streaming_fade_distance: f32 = fade_distance * 4.0;
const streaming_gain: f32 = 0.5;
const interface_gain: f32 = 0.25;
const music_interval = 12000;

const Voice = struct {
    track: sdl3.mixer.Track,
    position: ?math.Vec3 = null,
    gain: f32 = 0,
    fade: f32 = fade_distance,
};

const Target = struct {
    pool: *Pool,
    name: []const u8,
};

mixer: sdl3.mixer.Mixer,
audios: []sdl3.mixer.Audio,
sounds: Pool = .{},
streaming: Pool = .{ .strip_digits = false },
music: Pool = .{},
voices: [voice_count]Voice,
next_voice: usize = 0,
streaming_voice: Voice,
music_voice: Voice,
listener: math.Vec3 = .init(0, 0, 0),
yaw: f32 = 0,
sound_volume: f32 = 1,
music_volume: f32 = 1,
prng: std.Random.DefaultPrng,
ticks_before_music: i32,

pub fn init(gpa: std.mem.Allocator, seed: u64) !Manager {
    try sdl3.mixer.init();
    errdefer sdl3.mixer.quit();

    const mixer = try sdl3.mixer.Mixer.initDevice(sdl3.audio.Device.default_playback, null);
    errdefer mixer.deinit();

    return create(gpa, seed, mixer);
}

pub fn initOffline(gpa: std.mem.Allocator, seed: u64, spec: sdl3.audio.Spec) !Manager {
    try sdl3.mixer.init();
    errdefer sdl3.mixer.quit();

    const mixer = try sdl3.mixer.Mixer.init(spec);
    errdefer mixer.deinit();

    return create(gpa, seed, mixer);
}

fn create(gpa: std.mem.Allocator, seed: u64, mixer: sdl3.mixer.Mixer) !Manager {
    var prng: std.Random.DefaultPrng = .init(seed);
    const ticks_before_music = prng.random().intRangeLessThan(i32, 0, music_interval);

    var self: Manager = .{
        .mixer = mixer,
        .audios = try gpa.alloc(sdl3.mixer.Audio, embedded_sound_count),
        .voices = undefined,
        .streaming_voice = undefined,
        .music_voice = undefined,
        .prng = prng,
        .ticks_before_music = ticks_before_music,
    };
    errdefer gpa.free(self.audios);

    for (&self.voices) |*voice| voice.* = .{ .track = try .init(mixer) };
    self.streaming_voice = .{ .track = try .init(mixer) };
    self.music_voice = .{ .track = try .init(mixer) };

    errdefer {
        self.sounds.deinit(gpa);
        self.streaming.deinit(gpa);
        self.music.deinit(gpa);
    }

    var loaded: usize = 0;
    for (sound_groups) |group| {
        for (group.variants) |variant| {
            self.audios[loaded] = try .initNoCopy(mixer, variant.bytes, false);
            try self.sounds.addKeyed(gpa, group.key, .{ .embedded = @intCast(loaded) });
            loaded += 1;
        }
    }

    return self;
}

pub fn deinit(self: *Manager, gpa: std.mem.Allocator) void {
    self.sounds.deinit(gpa);
    self.streaming.deinit(gpa);
    self.music.deinit(gpa);
    for (self.audios) |audio| audio.deinit();
    gpa.free(self.audios);
    for (self.voices) |voice| voice.track.deinit();
    self.streaming_voice.track.deinit();
    self.music_voice.track.deinit();
    self.mixer.deinit();
    sdl3.mixer.quit();
}

fn collectGroups(comptime namespace: type) []const assets.Sound {
    comptime {
        var found: []const assets.Sound = &.{};
        for (@typeInfo(namespace).@"struct".decls) |decl| {
            const entry = @field(namespace, decl.name);
            const Entry = @TypeOf(entry);
            if (Entry == assets.Sound) {
                found = found ++ [_]assets.Sound{entry};
            } else if (Entry == type) {
                found = found ++ collectGroups(entry);
            }
        }
        return found;
    }
}

pub const sound_groups = blk: {
    @setEvalBranchQuota(200000);
    break :blk collectGroups(assets.sounds);
};

pub const embedded_sound_count = blk: {
    var total: usize = 0;
    for (sound_groups) |group| total += group.variants.len;
    break :blk total;
};

fn targetFor(self: *Manager, path: []const u8) ?Target {
    const slash = std.mem.indexOfScalar(u8, path, '/') orelse return null;
    const prefix = path[0..slash];
    const name = path[slash + 1 ..];
    const pool: *Pool = if (std.mem.eql(u8, prefix, "sound") or std.mem.eql(u8, prefix, "newsound"))
        &self.sounds
    else if (std.mem.eql(u8, prefix, "streaming"))
        &self.streaming
    else if (std.mem.eql(u8, prefix, "music") or std.mem.eql(u8, prefix, "newmusic"))
        &self.music
    else
        return null;
    return .{ .pool = pool, .name = name };
}

fn install(self: *Manager, gpa: std.mem.Allocator, path: []const u8, source: Pool.Source) !void {
    const target = self.targetFor(path) orelse return;
    try target.pool.add(gpa, target.name, source);
}

pub fn loadResources(self: *Manager, gpa: std.mem.Allocator, io: std.Io, root: []const u8) !void {
    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;

        const relative = try gpa.dupe(u8, entry.path);
        defer gpa.free(relative);
        std.mem.replaceScalar(u8, relative, std.fs.path.sep, '/');

        const target = self.targetFor(relative) orelse continue;
        const path = try std.fs.path.joinZ(gpa, &.{ root, entry.path });
        errdefer gpa.free(path);
        try target.pool.add(gpa, target.name, .{ .file = path });
    }
}

pub fn listenerSpace(delta: math.Vec3, yaw: f32) math.Vec3 {
    const angle = -yaw * std.math.rad_per_deg - std.math.pi;
    const cos = math.util.cos(angle);
    const sin = math.util.sin(angle);
    const forward = math.Vec3.init(-sin, 0, -cos);
    const right = math.Vec3.init(cos, 0, -sin);
    return .init(delta.dot(right), delta.y, -delta.dot(forward));
}

pub fn attenuation(distance: f32, fade: f32) f32 {
    if (distance <= 0) return 1;
    if (distance >= fade) return 0;
    return 1 - distance / fade;
}

fn apply(self: *const Manager, voice: *Voice) !void {
    const position = voice.position orelse {
        try voice.track.set3dPosition(null);
        try voice.track.setGain(voice.gain);
        return;
    };

    const local = listenerSpace(position.sub(self.listener), self.yaw);
    const distance = local.length();
    const direction: sdl3.mixer.Point3d = if (distance <= 0) .{ .x = 0, .y = 0, .z = 0 } else .{
        .x = @floatCast(local.x / distance),
        .y = @floatCast(local.y / distance),
        .z = @floatCast(local.z / distance),
    };

    try voice.track.set3dPosition(direction);
    try voice.track.setGain(attenuation(@floatCast(distance), voice.fade) * voice.gain);
}

fn nextVoice(self: *Manager) *Voice {
    const voice = &self.voices[self.next_voice];
    self.next_voice = (self.next_voice + 1) % voice_count;
    return voice;
}

fn start(self: *Manager, voice: *Voice, source: Pool.Source, pitch: f32) !void {
    try voice.track.stop(0);
    switch (source) {
        .embedded => |index| try voice.track.setAudio(self.audios[index]),
        .file => |path| {
            const stream = try sdl3.io_stream.Stream.initFromFile(path, .read_binary);
            try voice.track.setIoStream(stream, true);
        },
    }
    try voice.track.setFrequencyRatio(pitch);
    try self.apply(voice);
    try voice.track.play(null);
}

pub fn setListener(self: *Manager, position: math.Vec3, yaw: f32) !void {
    if (self.sound_volume == 0) return;
    self.listener = position;
    self.yaw = yaw;
    for (&self.voices) |*voice| try self.apply(voice);
    try self.apply(&self.streaming_voice);
}

pub fn setVolumes(self: *Manager, sound: f32, music: f32) !void {
    self.sound_volume = sound;
    self.music_volume = music;
    if (music == 0) {
        try self.music_voice.track.stop(0);
    } else {
        self.music_voice.gain = music;
        try self.music_voice.track.setGain(music);
    }
}

pub fn playSound(self: *Manager, sound: assets.Sound, x: f64, y: f64, z: f64, volume: f32, pitch: f32) !void {
    if (self.sound_volume == 0) return;
    const source = self.sounds.pick(sound.key, self.prng.random()) orelse return;
    if (volume <= 0) return;

    const voice = self.nextVoice();
    voice.position = .init(x, y, z);
    voice.fade = if (volume > 1) fade_distance * volume else fade_distance;
    voice.gain = @min(volume, 1) * self.sound_volume;
    try self.start(voice, source, pitch);
}

pub fn playSoundFx(self: *Manager, sound: assets.Sound, volume: f32, pitch: f32) !void {
    if (self.sound_volume == 0) return;
    const source = self.sounds.pick(sound.key, self.prng.random()) orelse return;

    const voice = self.nextVoice();
    voice.position = null;
    voice.gain = @min(volume, 1) * interface_gain * self.sound_volume;
    try self.start(voice, source, pitch);
}

pub fn playStreaming(self: *Manager, name: ?[]const u8, x: f64, y: f64, z: f64, volume: f32) !void {
    if (self.sound_volume == 0) return;
    try self.streaming_voice.track.stop(0);

    const key = name orelse return;
    const source = self.streaming.pick(key, self.prng.random()) orelse return;
    if (volume <= 0) return;

    try self.music_voice.track.stop(0);
    self.streaming_voice.position = .init(x, y, z);
    self.streaming_voice.fade = streaming_fade_distance;
    self.streaming_voice.gain = streaming_gain * self.sound_volume;
    try self.start(&self.streaming_voice, source, 1);
}

pub fn playRandomMusicIfReady(self: *Manager) !void {
    if (self.music_volume == 0) return;
    if (self.music_voice.track.isPlaying() or self.streaming_voice.track.isPlaying()) return;
    if (self.ticks_before_music > 0) {
        self.ticks_before_music -= 1;
        return;
    }

    const source = self.music.pickAny(self.prng.random()) orelse return;
    self.ticks_before_music = self.prng.random().intRangeLessThan(i32, 0, music_interval) + music_interval;
    self.music_voice.position = null;
    self.music_voice.gain = self.music_volume;
    try self.start(&self.music_voice, source, 1);
}

test "an embedded sound decodes and reaches the mix" {
    const gpa = std.testing.allocator;
    const spec: sdl3.audio.Spec = .{ .format = .signed_16_bit_little_endian, .num_channels = 2, .sample_rate = 44100 };

    var manager = Manager.initOffline(gpa, 0, spec) catch return error.SkipZigTest;
    defer manager.deinit(gpa);

    var buffer: [16384]u8 = undefined;
    const silence = try manager.mixer.generate(&buffer);
    try std.testing.expect(std.mem.allEqual(u8, silence, 0));

    try manager.playSound(assets.sounds.step.grass, 0, 0, 0, 1.0, 1.0);

    var loudest: i16 = 0;
    for (0..8) |_| {
        const mixed = try manager.mixer.generate(&buffer);
        var samples: []const i16 = undefined;
        samples.ptr = @ptrCast(@alignCast(mixed.ptr));
        samples.len = mixed.len / 2;
        for (samples) |sample| loudest = @max(loudest, @as(i16, @intCast(@abs(@as(i32, sample)))));
    }
    try std.testing.expect(loudest > 0);
}

test "sound fades out linearly and falls silent at the fade distance" {
    try std.testing.expectEqual(@as(f32, 1.0), attenuation(0, fade_distance));
    try std.testing.expectEqual(@as(f32, 0.5), attenuation(8, fade_distance));
    try std.testing.expectEqual(@as(f32, 0.0), attenuation(16, fade_distance));
    try std.testing.expectEqual(@as(f32, 0.0), attenuation(64, fade_distance));
    try std.testing.expectEqual(@as(f32, 0.75), attenuation(16, streaming_fade_distance));
}

test "a source ahead of the listener sits in front, and one behind sits back" {
    const ahead = listenerSpace(.init(0, 0, 4), 0);
    try std.testing.expect(ahead.z < -3.9);
    try std.testing.expect(@abs(ahead.x) < 0.01);

    const behind = listenerSpace(.init(0, 0, -4), 0);
    try std.testing.expect(behind.z > 3.9);
}

test "turning the listener swings a fixed source across the stereo field" {
    const east = math.Vec3.init(4, 0, 0);

    const facing_north = listenerSpace(east, 0);
    try std.testing.expect(facing_north.x < -3.9);

    const facing_east = listenerSpace(east, -90);
    try std.testing.expect(facing_east.z < -3.9);
    try std.testing.expect(@abs(facing_east.x) < 0.01);

    const turned_around = listenerSpace(east, 180);
    try std.testing.expect(turned_around.x > 3.9);
}

test "height offsets survive the listener transform" {
    const above = listenerSpace(.init(0, 3, 0), 37);
    try std.testing.expectEqual(@as(f64, 3), above.y);
}

test "every sound group is named by its own key and backed by ogg variants" {
    try std.testing.expect(sound_groups.len > 0);
    for (sound_groups) |group| {
        try std.testing.expect(group.variants.len > 0);
        for (group.variants) |variant| {
            try std.testing.expect(std.mem.endsWith(u8, variant.path, ".ogg"));
        }
    }
}

test "a group gathers the numbered takes the pool used to collapse by hand" {
    try std.testing.expectEqualStrings("step.grass", assets.sounds.step.grass.key);
    try std.testing.expectEqual(@as(usize, 4), assets.sounds.step.grass.variants.len);
    try std.testing.expectEqualStrings("mob.wolf.growl", assets.sounds.mob.wolf.growl.key);
    try std.testing.expectEqual(@as(usize, 3), assets.sounds.mob.wolf.growl.variants.len);
}
