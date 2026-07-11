const assets = @import("assets");

const Atlas = @import("atlas.zig");

const Textures = @This();

terrain: Atlas,
gui: Atlas,
icons: Atlas,
items: Atlas,
inventory: Atlas,
crafting: Atlas,
slot: Atlas,
dirt: Atlas,
logo: Atlas,
mojang: Atlas,
pig: Atlas,
char: Atlas,
sun: Atlas,
moon: Atlas,
clouds: Atlas,
water: Atlas,

pub fn load() !Textures {
    return .{
        .terrain = try Atlas.load(assets.terrain_png),
        .gui = try Atlas.load(assets.gui.gui_png),
        .icons = try Atlas.load(assets.gui.icons_png),
        .items = try Atlas.load(assets.gui.items_png),
        .inventory = try Atlas.load(assets.gui.inventory_png),
        .crafting = try Atlas.load(assets.gui.crafting_png),
        .slot = try Atlas.load(assets.gui.slot_png),
        .dirt = try Atlas.loadRepeat(assets.gui.background_png),
        .logo = try Atlas.load(assets.title.mclogo_png),
        .mojang = try Atlas.load(assets.title.mojang_png),
        .pig = try Atlas.load(assets.mob.pig_png),
        .char = try Atlas.load(assets.mob.char_png),
        .sun = try Atlas.load(assets.terrain.sun_png),
        .moon = try Atlas.load(assets.terrain.moon_png),
        .clouds = try Atlas.loadRepeat(assets.environment.clouds_png),
        .water = try Atlas.loadRepeat(assets.misc.water_png),
    };
}

pub fn deinit(self: Textures) void {
    inline for (@typeInfo(Textures).@"struct".fields) |field| {
        @field(self, field.name).deinit();
    }
}
