# Meadow

An example rosebed mod about bees, flowers and honey. Every part of the mod API
gets something from the theme.

| API | In Meadow |
| --- | --- |
| `register_item` | honeycomb, beeswax, pollen; a bowl of honey you can eat (`heal_amount`) |
| item `on_use` | the bee smoker fills a beehive at once |
| `register_block` | beehive (cube), shed comb (half height, `shape = 0.5`), wildflower (`shape = "cross"`) |
| block `drop` | a hive gives more comb the fuller it is; shed comb gives three |
| `on_random_tick` | a hive fills with honey, 0 to 3, in its metadata |
| `on_activated` | using a full hive empties it and drops shed comb to the ground below |
| `on_neighbor_change` | comb with nothing under it falls away; a wildflower off soil dies |
| `schedule_tick` / `on_tick` | comb that touches fire or lava melts two seconds later |
| `rosebed.world` get/set block and meta | all of the above |
| `override_block` | dandelions sometimes drop pollen instead of themselves |
| `override_item` | sugar is renamed Cane Sugar |
| `register_recipe` grid / any | beehive, wax, honey, smoker, comb from pollen |
| `{ key, meta }` ingredient | the smoker needs a birch log, `{ "log", 2 }` |
| `register_mob` | bee (flying, chicken body), pond skater (swims, pig body), fire hornet (nether monster, creeper body) |
| mob `drop` / `on_tick` | bees drop pollen, plant wildflowers when healthy, and take damage in water |
| `rosebed.mob` | the bee's exact height, health and wounds |
| `spawns` | bees in plains and forests, skaters in swamps, hornets in the nether |
| `override_mob` | pigs are tougher and slower, trample wildflowers and sometimes drop pollen |
| `on_decorate` | hives hang under leaves and netherrack, wildflowers grow on grass |
| `rosebed.random` | every roll above, so a world always turns out the same |
| `client.lua` hud and keys | a recipe panel, hidden and shown with `H` |

Two parts of the API cannot live in a single mod: `depends` in `mod.json` needs a
second mod to depend on, and a client-only mod is one with no `common.lua` at all.

## Try it

The game reads mods from `mods/` beside where it starts, so `zig build run` from
the repository root loads Meadow. To run a built binary elsewhere, copy this
folder into a `mods/` next to where you launch it. `/give meadow:smoker`,
`/give beehive`, `/spawn meadow:bee` and the recipes on the panel are the quick
way in.

## Why it looks the way it does

Vanilla `terrain.png` has two free tiles, so Meadow uses exactly two block
textures: `comb.png` is shared by the hive and the shed comb, and
`wildflower.png` is the flower. Blocks that name the same file share one tile.
Item icons and mob skins have no such limit.
