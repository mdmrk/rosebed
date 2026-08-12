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

fn resourceFor(comptime field: []const u8) Resource {
    return switch (@as(Field, @field(Field, field))) {
        .terrain => .{ .path = "terrain.png", .bytes = assets.terrain_png },
        .gui => .{ .path = "gui/gui.png", .bytes = assets.gui.gui_png },
        .icons => .{ .path = "gui/icons.png", .bytes = assets.gui.icons_png },
        .items => .{ .path = "gui/items.png", .bytes = assets.gui.items_png },
        .inventory => .{ .path = "gui/inventory.png", .bytes = assets.gui.inventory_png },
        .crafting => .{ .path = "gui/crafting.png", .bytes = assets.gui.crafting_png },
        .furnace => .{ .path = "gui/furnace.png", .bytes = assets.gui.furnace_png },
        .container => .{ .path = "gui/container.png", .bytes = assets.gui.container_png },
        .trap => .{ .path = "gui/trap.png", .bytes = assets.gui.trap_png },
        .slot => .{ .path = "gui/slot.png", .bytes = assets.gui.slot_png },
        .dirt => .{ .path = "gui/background.png", .bytes = assets.gui.background_png, .wrap = .repeat },
        .logo => .{ .path = "title/mclogo.png", .bytes = assets.title.mclogo_png },
        .mojang => .{ .path = "title/mojang.png", .bytes = assets.title.mojang_png },
        .particles => .{ .path = "particles.png", .bytes = assets.particles_png },
        .art => .{ .path = "art/kz.png", .bytes = assets.art.kz_png },
        .arrows => .{ .path = "item/arrows.png", .bytes = assets.item.arrows_png },
        .boat => .{ .path = "item/boat.png", .bytes = assets.item.boat_png },
        .cart => .{ .path = "item/cart.png", .bytes = assets.item.cart_png },
        .sign => .{ .path = "item/sign.png", .bytes = assets.item.sign_png },
        .pig => .{ .path = "mob/pig.png", .bytes = assets.mob.pig_png },
        .saddle => .{ .path = "mob/saddle.png", .bytes = assets.mob.saddle_png },
        .sheep => .{ .path = "mob/sheep.png", .bytes = assets.mob.sheep_png },
        .sheep_fur => .{ .path = "mob/sheep_fur.png", .bytes = assets.mob.sheep_fur_png },
        .cow => .{ .path = "mob/cow.png", .bytes = assets.mob.cow_png },
        .chicken => .{ .path = "mob/chicken.png", .bytes = assets.mob.chicken_png },
        .slime => .{ .path = "mob/slime.png", .bytes = assets.mob.slime_png },
        .wolf => .{ .path = "mob/wolf.png", .bytes = assets.mob.wolf_png },
        .wolf_tame => .{ .path = "mob/wolf_tame.png", .bytes = assets.mob.wolf_tame_png },
        .wolf_angry => .{ .path = "mob/wolf_angry.png", .bytes = assets.mob.wolf_angry_png },
        .creeper => .{ .path = "mob/creeper.png", .bytes = assets.mob.creeper_png },
        .skeleton => .{ .path = "mob/skeleton.png", .bytes = assets.mob.skeleton_png },
        .spider => .{ .path = "mob/spider.png", .bytes = assets.mob.spider_png },
        .spider_eyes => .{ .path = "mob/spider_eyes.png", .bytes = assets.mob.spider_eyes_png },
        .zombie => .{ .path = "mob/zombie.png", .bytes = assets.mob.zombie_png },
        .pig_zombie => .{ .path = "mob/pigzombie.png", .bytes = assets.mob.pigzombie_png },
        .char => .{ .path = "mob/char.png", .bytes = assets.mob.char_png },
        .armor_cloth_1 => .{ .path = "armor/cloth_1.png", .bytes = assets.armor.cloth_1_png },
        .armor_cloth_2 => .{ .path = "armor/cloth_2.png", .bytes = assets.armor.cloth_2_png },
        .armor_chain_1 => .{ .path = "armor/chain_1.png", .bytes = assets.armor.chain_1_png },
        .armor_chain_2 => .{ .path = "armor/chain_2.png", .bytes = assets.armor.chain_2_png },
        .armor_iron_1 => .{ .path = "armor/iron_1.png", .bytes = assets.armor.iron_1_png },
        .armor_iron_2 => .{ .path = "armor/iron_2.png", .bytes = assets.armor.iron_2_png },
        .armor_diamond_1 => .{ .path = "armor/diamond_1.png", .bytes = assets.armor.diamond_1_png },
        .armor_diamond_2 => .{ .path = "armor/diamond_2.png", .bytes = assets.armor.diamond_2_png },
        .armor_gold_1 => .{ .path = "armor/gold_1.png", .bytes = assets.armor.gold_1_png },
        .armor_gold_2 => .{ .path = "armor/gold_2.png", .bytes = assets.armor.gold_2_png },
        .sun => .{ .path = "terrain/sun.png", .bytes = assets.terrain.sun_png },
        .moon => .{ .path = "terrain/moon.png", .bytes = assets.terrain.moon_png },
        .clouds => .{ .path = "environment/clouds.png", .bytes = assets.environment.clouds_png, .wrap = .repeat },
        .water => .{ .path = "misc/water.png", .bytes = assets.misc.water_png, .wrap = .repeat },
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
