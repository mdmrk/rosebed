# Roadmap

## Mod API

The goal is a Fabric-shaped API for rosebed: broad enough that a mod can change
the whole game, minus the paths where a Lua call per item would cost frames.

### What exists today

- [x] **Blocks** - `register_block`, `override_block`. Material, step sound,
      shape (`cube`, `cross`, a partial height), per-face textures, hardness,
      explosion resistance, slipperiness, tick rate, and the flags. Hooks:
      `drop`, `on_tick`, `on_random_tick`, `on_neighbor_change`, `on_activated`.
- [x] **Items** - `register_item`, `override_item`. Name, icon, stack size,
      heal amount, max damage, armour. Hook: `on_use`.
- [x] **Armour** - `armor = { slot, material }`. The inventory, the damage
      model and the player renderer already read it from the registry.
- [x] **Recipes** - `register_recipe`, shaped and shapeless.
- [x] **Mobs** - `register_mob`, `override_mob`. Size, health, speed, step
      height, movement, the flags, and a spawn rule (category, weight, cap per
      chunk, dimension, biomes). Hooks: `drop`, `on_tick`.
- [x] **Mob models** - a vanilla shape by name, or parts laid out in Lua with
      `box`, `uv`, `pivot`, rotations, `inflate` and `mirror`. `role` drives the
      animation: the head follows the look, legs stride, wings beat.
- [x] **Worldgen** - `on_generate` per chunk, `on_decorate`, `noise`,
      `register_structure` (plans across chunks, fills chests, names spawner
      mobs), `register_biome` (takes a share of a vanilla parent).
- [x] **World access** - blocks, metadata, scheduled ticks, biome, ground
      height, chest slots, spawner mobs.
- [x] **Player** - `on_tick` reads position, motion, look, ground, fall
      distance, health and equipment, and can set motion, fall distance and
      wear. Returning true claims the tick and replaces the air physics.
- [x] **Poses** - `set_pose` turns the whole body and any of the six limbs, for
      the local player and, through `on_peer_pose`, for everybody else.
- [x] **HUD** - `on_draw` with `text` and `rect`.
- [x] **Input** - `on_key`.
- [x] **Multiplayer** - mod list handshake, mod ids on the wire, block palette
      and stack keys in the save, so a world survives an id shuffle.

Ceilings: 22 biomes, 16 mob types (wire ids 96 to 111), 32 parts per model,
block ids from 97, item ids from 360, 256 shaped and 256 shapeless recipes.
Block and item textures must be exactly 16 by 16 and claim a free cell of the
256 by 256 vanilla atlas. Mob skins are their own atlas and any size.

### Deliberately out, for performance

These stay in Zig. A mod shapes them with data, never with a callback.

- The chunk mesher, per face and per vertex. Block appearance stays
  declarative through `shape` and `textures`.
- Lighting. `light.zig` runs on every block edit.
- The AABB sweep in `Entity.move`. The seam is claiming a tick, not replacing
  the sweep.
- Worldgen inner loops. Hooks stay per chunk, never per block.
- Entity and world rendering. A mod fills in data, it does not draw.

### The thing that blocks the rest

There is no sound and no particle on the wire. `World.sound_sink` only exists
on the client's world, and particles are client entities. In single player that
does not matter. On a dedicated server blocks tick on the server, so a
`play_sound` from a block's `on_tick` would be silent for everybody.

The same holds for any mod state a client has to see. So the bottleneck is not
any one API: it is that `common.lua` has no way to reach clients. That is why
networking comes first, before the effects that need it.

### Order

1. ~~**Mod networking.**~~ Done. Packet 251 `mod_message` carries
   `(channel, payload)` both ways, up to a 64 byte channel and 32 KB of
   arbitrary bytes. `rosebed.net.send(channel, text)` and
   `rosebed.net.on(channel, function(payload, from) end)`, installed for both
   `common.lua` and `client.lua`. `from` is the sender's name on the server
   and nil on the client. In single player there is no link, so a send loops
   straight back into the same VM on the next tick: a mod behaves the same
   in both modes without knowing which one it is in.
2. **Events.** One registration function per event, in the style of
   `on_decorate` and `player.on_tick`, not a generic bus. `on_world_tick`,
   `on_chunk_load`, `on_block_broken`, `on_block_placed` (cancellable),
   `on_player_hurt`, `on_player_death`, `on_mob_death`.
3. **Effects.** `play_sound`, `particle` (13 vanilla kinds), `explode`, and
   spawning entities at runtime. Needs 1 to work on a server.
4. **Commands.** `register_command`, through `game/commands.zig`.
5. **Block entities.** A registry for per-block state with NBT save and load.
   `World.zig:190` holds fixed hash maps today with no registration seam. This
   is the largest structural gap.
6. **Screens and containers.** Needs 1 and 5.
7. **Mob AI.** Expose the three seams `Animal` already has: `path_weight`,
   `action_state`, `after_move`. Until then a mod mob wanders like a vanilla
   animal and runs its `on_tick` afterwards.

Steps 1 to 4 leave the API close to Fabric. Steps 5 and 6 are the expensive
ones.

The glue between the mod VM and each end has no automated test: the server
peels `mod_message` in `drainPending` and flushes in `tick`, the client drains
`Connection.mod_inbox` and fills the outbox in `tickRemote`. The packet, the
queues and the dispatch are covered; those few lines of wiring are not.

### Known risks

- **Breaking and placing a block take two paths**, the client in single player
  and `Session` in multiplayer. Either they get unified first or the event
  fires in different places depending on the mode. Unifying touches vanilla
  code, so it needs parity tests.
- Mods run before the world loads, so registration order decides ids. The block
  palette in the save covers a shuffle, but two mods claiming the same key
  still collide at load.
