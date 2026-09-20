const std = @import("std");

const assets = @import("assets");

fn collect(comptime T: type, comptime found: []const assets.Sound) []const assets.Sound {
    var out = found;
    for (@typeInfo(T).@"struct".decls) |decl| {
        const member = @field(T, decl.name);
        if (@TypeOf(member) == assets.Sound) {
            out = out ++ [_]assets.Sound{member};
        } else if (@TypeOf(member) == type and @typeInfo(member) == .@"struct") {
            out = collect(member, out);
        }
    }
    return out;
}

pub const table = collect(assets.sounds, &.{});

pub fn byKey(key: []const u8) ?assets.Sound {
    for (table) |sound| {
        if (std.mem.eql(u8, sound.key, key)) return sound;
    }
    return null;
}

test "a sound is found by the key vanilla names it with" {
    try std.testing.expectEqualStrings("random.explode", byKey("random.explode").?.key);
    try std.testing.expectEqualStrings("mob.ghast.moan", byKey("mob.ghast.moan").?.key);
    try std.testing.expect(byKey("random.nothing") == null);
    try std.testing.expect(byKey("") == null);
}
