rosebed.register_item {
    key = "wings",
    name = "Elytra",
    max_stack_size = 1,
    max_damage = 432,
    texture = "wings.png",
    armor = { slot = "chestplate", material = "leather" },
}

rosebed.register_recipe {
    grid = { "l l", "fff", "l l" },
    where = { l = "leather", f = "feather" },
    result = "elytra:wings",
}
