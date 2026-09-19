local mod = "meadow:"
local full_hive = 3

local sides = {
    { 1, 0, 0 }, { -1, 0, 0 },
    { 0, 1, 0 }, { 0, -1, 0 },
    { 0, 0, 1 }, { 0, 0, -1 },
}

local soil = { grass = true, dirt = true }
local heat = { fire = true, flowing_lava = true, stationary_lava = true }
local water = { flowing_water = true, stationary_water = true }

local world = rosebed.world

local function touching(x, y, z, kinds)
    for _, side in ipairs(sides) do
        if kinds[world.get_block(x + side[1], y + side[2], z + side[3])] then
            return true
        end
    end
    return false
end

local function drip_spot(x, y, z)
    for height = y - 1, y - 8, -1 do
        if world.get_block(x, height, z) ~= "air" then
            return nil
        end
        if world.get_block(x, height - 1, z) ~= "air" then
            return height
        end
    end
    return nil
end

local function hanging_spot(x, z, top, bottom, ceiling)
    local under_ceiling = false
    for y = top, bottom, -1 do
        local key = world.get_block(x, y, z)
        if key == ceiling then
            under_ceiling = true
        elseif under_ceiling then
            return key == "air" and y or nil
        end
    end
    return nil
end

local function ground(x, z)
    for y = 127, 1, -1 do
        local key = world.get_block(x, y, z)
        if key ~= "air" then
            return y, key
        end
    end
    return nil
end

local function in_chunk(chunk_x, chunk_z)
    return chunk_x * 16 + rosebed.random(16) + 8, chunk_z * 16 + rosebed.random(16) + 8
end

rosebed.register_item {
    key = "honeycomb",
    name = "Honeycomb",
    texture = "honeycomb.png",
}

rosebed.register_item {
    key = "wax",
    name = "Beeswax",
    texture = "wax.png",
}

rosebed.register_item {
    key = "pollen",
    name = "Pollen",
    texture = "pollen.png",
}

rosebed.register_item {
    key = "honey",
    name = "Bowl of Honey",
    heal_amount = 6,
    max_stack_size = 1,
    texture = "honey.png",
}

rosebed.register_item {
    key = "smoker",
    name = "Bee Smoker",
    max_stack_size = 1,
    texture = "smoker.png",
    on_use = function(x, y, z, face, damage)
        if world.get_block(x, y, z) ~= mod .. "beehive" then
            return false
        end
        world.set_meta(x, y, z, full_hive)
        return true
    end,
}

rosebed.register_block {
    key = "beehive",
    name = "Beehive",
    material = "wood",
    step_sound = "wood",
    hardness = 1.5,
    flammable = true,
    textures = "comb.png",
    drop = function(meta)
        return mod .. "honeycomb", 1 + meta
    end,
    on_random_tick = function(x, y, z)
        local honey = world.get_meta(x, y, z)
        if honey < full_hive then
            world.set_meta(x, y, z, honey + 1)
        end
    end,
    on_activated = function(x, y, z)
        if world.get_meta(x, y, z) < full_hive then
            return false
        end
        local spot = drip_spot(x, y, z)
        if not spot and world.get_block(x, y + 1, z) == "air" then
            spot = y + 1
        end
        if not spot then
            return false
        end
        world.set_meta(x, y, z, 0)
        world.set_block(x, spot, z, mod .. "shed_comb")
        return true
    end,
}

rosebed.register_block {
    key = "shed_comb",
    name = "Shed Comb",
    material = "wood",
    step_sound = "wood",
    hardness = 0.4,
    slipperiness = 0.4,
    opaque_cube = false,
    shape = 0.5,
    textures = "comb.png",
    drop = function(meta)
        return mod .. "honeycomb", 3
    end,
    on_neighbor_change = function(x, y, z)
        if world.get_block(x, y - 1, z) == "air" then
            world.set_block(x, y, z, "air")
        elseif touching(x, y, z, heat) then
            world.schedule_tick(x, y, z, 40)
        end
    end,
    on_tick = function(x, y, z)
        if touching(x, y, z, heat) then
            world.set_block(x, y, z, "air")
        end
    end,
}

rosebed.register_block {
    key = "wildflower",
    name = "Wildflower",
    material = "plants",
    step_sound = "grass",
    hardness = 0,
    opaque_cube = false,
    shape = "cross",
    textures = "wildflower.png",
    on_neighbor_change = function(x, y, z)
        if not soil[world.get_block(x, y - 1, z)] then
            world.set_block(x, y, z, "air")
        end
    end,
}

rosebed.override_block("dandelion", {
    drop = function(meta)
        if rosebed.random(3) == 0 then
            return mod .. "pollen", 2
        end
        return "dandelion", 1
    end,
})

rosebed.override_item("sugar", { name = "Cane Sugar" })

rosebed.register_recipe {
    grid = { "ppp", "ccc", "ppp" },
    where = { p = "planks", c = mod .. "honeycomb" },
    result = mod .. "beehive",
}

rosebed.register_recipe {
    any = { mod .. "honeycomb" },
    result = mod .. "wax",
    count = 2,
}

rosebed.register_recipe {
    any = { mod .. "honeycomb", "bowl" },
    result = mod .. "honey",
}

rosebed.register_recipe {
    grid = { "w", "l" },
    where = { w = mod .. "wax", l = { "log", 2 } },
    result = mod .. "smoker",
}

rosebed.register_recipe {
    any = { mod .. "pollen", mod .. "pollen", "sugar" },
    result = mod .. "honeycomb",
}

rosebed.register_mob {
    key = "bee",
    model = "chicken",
    texture = "bee.png",
    width = 0.4,
    height = 0.5,
    health = 4,
    speed = 0.9,
    movement = "flying",
    wing_beat = 0.9,
    takes_fall_damage = false,
    drop = function()
        return mod .. "pollen", 1 + rosebed.random(2)
    end,
    on_tick = function(x, y, z)
        local _, middle = rosebed.mob.position()
        if water[world.get_block(x, math.floor(middle + 0.25), z)] and rosebed.random(20) == 0 then
            rosebed.mob.hurt(1)
        end
        local health, max = rosebed.mob.health()
        if health < max or rosebed.random(1200) ~= 0 then
            return
        end
        local height, key = ground(x, z)
        if key == "grass" and height < y and world.get_block(x, height + 1, z) == "air" then
            world.set_block(x, height + 1, z, mod .. "wildflower")
        end
    end,
    spawns = {
        category = "creature",
        weight = 6,
        biomes = { "plains", "forest", "seasonal_forest", "shrubland" },
    },
}

rosebed.register_mob {
    key = "pond_skater",
    model = "pig",
    texture = "pond_skater.png",
    width = 0.7,
    height = 0.3,
    health = 3,
    speed = 0.6,
    breathes_underwater = true,
    drop = function()
        return "string", 1
    end,
    spawns = {
        category = "water_creature",
        weight = 3,
        biomes = { "swampland" },
    },
}

rosebed.register_mob {
    key = "fire_hornet",
    model = "creeper",
    texture = "fire_hornet.png",
    width = 0.6,
    height = 1.2,
    health = 10,
    speed = 1.1,
    movement = "flying",
    monster = true,
    immune_to_fire = true,
    takes_fall_damage = false,
    drop = function()
        return mod .. "wax", rosebed.random(3)
    end,
    spawns = {
        category = "monster",
        weight = 25,
        max_per_chunk = 2,
        dimension = "nether",
    },
}

rosebed.override_mob("Pig", {
    health = 12,
    speed = 0.6,
    drop = function()
        if rosebed.random(4) == 0 then
            return mod .. "pollen", 1
        end
    end,
    on_tick = function(x, y, z)
        if world.get_block(x, y, z) == mod .. "wildflower" and rosebed.random(40) == 0 then
            world.set_block(x, y, z, "air")
        end
    end,
})

rosebed.on_decorate(function(chunk_x, chunk_z, dimension)
    if dimension == "nether" then
        local x, z = in_chunk(chunk_x, chunk_z)
        local y = hanging_spot(x, z, 120, 32, "netherrack")
        if y then
            world.set_block(x, y, z, mod .. "beehive", rosebed.random(full_hive + 1))
        end
        return
    end

    for _ = 1, 2 do
        local x, z = in_chunk(chunk_x, chunk_z)
        local y = hanging_spot(x, z, 127, 48, "leaves")
        if y then
            world.set_block(x, y, z, mod .. "beehive", rosebed.random(full_hive + 1))
        end
    end

    for _ = 1, 4 do
        local x, z = in_chunk(chunk_x, chunk_z)
        local height, key = ground(x, z)
        if key == "grass" then
            world.set_block(x, height + 1, z, mod .. "wildflower")
        end
    end
end)
