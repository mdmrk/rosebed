const std = @import("std");

const assets = @import("assets");
const world = @import("world");

const Atlas = @import("atlas.zig");
const texture_pack = @import("texture_pack.zig");

const Textures = @This();

terrain: Atlas,
gui: Atlas,
icons: Atlas,
items: Atlas,
inventory: Atlas,
crafting: Atlas,
furnace: Atlas,
container: Atlas,
trap: Atlas,
slot: Atlas,
dirt: Atlas,
logo: Atlas,
mojang: Atlas,
particles: Atlas,
art: Atlas,
arrows: Atlas,
boat: Atlas,
cart: Atlas,
sign: Atlas,
pig: Atlas,
saddle: Atlas,
sheep: Atlas,
sheep_fur: Atlas,
cow: Atlas,
chicken: Atlas,
slime: Atlas,
wolf: Atlas,
wolf_tame: Atlas,
wolf_angry: Atlas,
creeper: Atlas,
skeleton: Atlas,
spider: Atlas,
spider_eyes: Atlas,
zombie: Atlas,
pig_zombie: Atlas,
char: Atlas,
armor_cloth_1: Atlas,
armor_cloth_2: Atlas,
armor_chain_1: Atlas,
armor_chain_2: Atlas,
armor_iron_1: Atlas,
armor_iron_2: Atlas,
armor_diamond_1: Atlas,
armor_diamond_2: Atlas,
armor_gold_1: Atlas,
armor_gold_2: Atlas,
sun: Atlas,
moon: Atlas,
clouds: Atlas,
water: Atlas,

const Wrap = enum { clamp, repeat };

const Resource = struct {
    path: []const u8,
    bytes: []const u8,
    wrap: Wrap = .clamp,
};

fn clamped(asset: assets.Asset) Resource {
    return .{ .path = asset.path, .bytes = asset.bytes };
}

fn repeated(asset: assets.Asset) Resource {
    return .{ .path = asset.path, .bytes = asset.bytes, .wrap = .repeat };
}

fn resourceFor(comptime field: []const u8) Resource {
    return switch (@as(Field, @field(Field, field))) {
        .terrain => clamped(assets.terrain_png),
        .gui => clamped(assets.gui.gui_png),
        .icons => clamped(assets.gui.icons_png),
        .items => clamped(assets.gui.items_png),
        .inventory => clamped(assets.gui.inventory_png),
        .crafting => clamped(assets.gui.crafting_png),
        .furnace => clamped(assets.gui.furnace_png),
        .container => clamped(assets.gui.container_png),
        .trap => clamped(assets.gui.trap_png),
        .slot => clamped(assets.gui.slot_png),
        .dirt => repeated(assets.gui.background_png),
        .logo => clamped(assets.title.mclogo_png),
        .mojang => clamped(assets.title.mojang_png),
        .particles => clamped(assets.particles_png),
        .art => clamped(assets.art.kz_png),
        .arrows => clamped(assets.item.arrows_png),
        .boat => clamped(assets.item.boat_png),
        .cart => clamped(assets.item.cart_png),
        .sign => clamped(assets.item.sign_png),
        .pig => clamped(assets.mob.pig_png),
        .saddle => clamped(assets.mob.saddle_png),
        .sheep => clamped(assets.mob.sheep_png),
        .sheep_fur => clamped(assets.mob.sheep_fur_png),
        .cow => clamped(assets.mob.cow_png),
        .chicken => clamped(assets.mob.chicken_png),
        .slime => clamped(assets.mob.slime_png),
        .wolf => clamped(assets.mob.wolf_png),
        .wolf_tame => clamped(assets.mob.wolf_tame_png),
        .wolf_angry => clamped(assets.mob.wolf_angry_png),
        .creeper => clamped(assets.mob.creeper_png),
        .skeleton => clamped(assets.mob.skeleton_png),
        .spider => clamped(assets.mob.spider_png),
        .spider_eyes => clamped(assets.mob.spider_eyes_png),
        .zombie => clamped(assets.mob.zombie_png),
        .pig_zombie => clamped(assets.mob.pigzombie_png),
        .char => clamped(assets.mob.char_png),
        .armor_cloth_1 => clamped(assets.armor.cloth_1_png),
        .armor_cloth_2 => clamped(assets.armor.cloth_2_png),
        .armor_chain_1 => clamped(assets.armor.chain_1_png),
        .armor_chain_2 => clamped(assets.armor.chain_2_png),
        .armor_iron_1 => clamped(assets.armor.iron_1_png),
        .armor_iron_2 => clamped(assets.armor.iron_2_png),
        .armor_diamond_1 => clamped(assets.armor.diamond_1_png),
        .armor_diamond_2 => clamped(assets.armor.diamond_2_png),
        .armor_gold_1 => clamped(assets.armor.gold_1_png),
        .armor_gold_2 => clamped(assets.armor.gold_2_png),
        .sun => clamped(assets.terrain.sun_png),
        .moon => clamped(assets.terrain.moon_png),
        .clouds => repeated(assets.environment.clouds_png),
        .water => repeated(assets.misc.water_png),
    };
}

const Field = std.meta.FieldEnum(Textures);

fn atlasFrom(bytes: []const u8, wrap: Wrap) !Atlas {
    return switch (wrap) {
        .clamp => Atlas.load(bytes),
        .repeat => Atlas.loadRepeat(bytes),
    };
}

fn loadOne(gpa: std.mem.Allocator, archive: ?[]const u8, resource: Resource) !Atlas {
    const bytes = archive orelse return atlasFrom(resource.bytes, resource.wrap);

    const overridden = texture_pack.readArchiveEntry(gpa, bytes, resource.path, texture_pack.max_resource_bytes) catch null;
    const replacement = overridden orelse return atlasFrom(resource.bytes, resource.wrap);
    defer gpa.free(replacement);

    return atlasFrom(replacement, resource.wrap) catch atlasFrom(resource.bytes, resource.wrap);
}

pub fn load(gpa: std.mem.Allocator, archive: ?[]const u8) !Textures {
    var loaded: Textures = undefined;
    inline for (@typeInfo(Textures).@"struct".fields) |field| {
        @field(loaded, field.name) = try loadOne(gpa, archive, resourceFor(field.name));
    }
    return loaded;
}

pub fn openArchive(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    pack_name: []const u8,
) ?[]u8 {
    if (std.mem.eql(u8, pack_name, texture_pack.default_name)) return null;
    return texture_pack.readArchive(gpa, io, dir, pack_name) catch null;
}

pub fn armor(self: Textures, material: world.item.ArmorMaterial, second_texture: bool) Atlas {
    return switch (material) {
        .leather => if (second_texture) self.armor_cloth_2 else self.armor_cloth_1,
        .chain => if (second_texture) self.armor_chain_2 else self.armor_chain_1,
        .iron => if (second_texture) self.armor_iron_2 else self.armor_iron_1,
        .diamond => if (second_texture) self.armor_diamond_2 else self.armor_diamond_1,
        .gold => if (second_texture) self.armor_gold_2 else self.armor_gold_1,
    };
}

pub fn deinit(self: Textures) void {
    inline for (@typeInfo(Textures).@"struct".fields) |field| {
        @field(self, field.name).deinit();
    }
}

test "every atlas names the jar path a texture pack would override it with" {
    inline for (@typeInfo(Textures).@"struct".fields) |field| {
        const resource = resourceFor(field.name);
        try std.testing.expect(resource.path.len > 0);
        try std.testing.expect(resource.bytes.len > 0);
        try std.testing.expect(!std.mem.startsWith(u8, resource.path, "/"));
        try std.testing.expect(std.mem.endsWith(u8, resource.path, ".png"));
    }
}

test "the paths are the ones the original reads, and none is claimed twice" {
    @setEvalBranchQuota(10000);
    const fields = @typeInfo(Textures).@"struct".fields;
    inline for (fields, 0..) |field, index| {
        inline for (fields, 0..) |other, other_index| {
            if (index != other_index) {
                try std.testing.expect(!std.mem.eql(u8, resourceFor(field.name).path, resourceFor(other.name).path));
            }
        }
    }

    try std.testing.expectEqualStrings("terrain.png", resourceFor("terrain").path);
    try std.testing.expectEqualStrings("particles.png", resourceFor("particles").path);
    try std.testing.expectEqualStrings("gui/items.png", resourceFor("items").path);
    try std.testing.expectEqualStrings("mob/char.png", resourceFor("char").path);
}

test "only the tiling atlases ask for repeat wrapping" {
    try std.testing.expectEqual(Wrap.repeat, resourceFor("dirt").wrap);
    try std.testing.expectEqual(Wrap.repeat, resourceFor("clouds").wrap);
    try std.testing.expectEqual(Wrap.repeat, resourceFor("water").wrap);
    try std.testing.expectEqual(Wrap.clamp, resourceFor("terrain").wrap);
    try std.testing.expectEqual(Wrap.clamp, resourceFor("gui").wrap);
}
