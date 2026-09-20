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
- [x] **Block state** - `get_state` and `set_state` keep a table of numbers,
      strings and booleans on any position. It is written into the chunk's
      `TileEntities` list as `RosebedState` and read back out of it, so it
      survives a save, and breaking the block takes it with it.
- [x] **Player** - `on_tick` reads position, motion, look, ground, fall
      distance, health and equipment, and can set motion, fall distance and
      wear. Returning true claims the tick and replaces the air physics.
- [x] **Poses** - `set_pose` turns the whole body and any of the six limbs, for
      the local player and, through `on_peer_pose`, for everybody else.
- [x] **Commands** - `register_command(name, { usage, description, run })`.
      `run(args, who)` gets the words after the verb and the caller's name,
      and the string it returns is said back to whoever typed it. Listed by
      `/help` under the vanilla verbs.
- [x] **Effects** - `play_sound` (any key in the vanilla sound tree),
      `particle` (the 13 kinds `RenderGlobal.spawnParticle` accepts and this
      port has), `explode` and `spawn`. Queued the way `rosebed.net.send` is:
      the client plays what it drains, the server broadcasts a sound 64 blocks
      and a particle 16, and detonates or spawns on the level that just
      ticked.
- [x] **HUD** - `on_draw` with `text` and `rect`.
- [x] **Input** - `on_key`.
- [x] **Multiplayer** - mod list handshake, mod ids on the wire, block palette
      and stack keys in the save, so a world survives an id shuffle.

Ceilings: 22 biomes, 16 mob types (wire ids 96 to 111), 32 commands,
32 parts per model,
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

### What used to block the rest

Sound and particles had no way onto the wire, so `common.lua` could not reach
a client at all. Packet 251 carries a mod's own messages, and packets 252 and
253 carry a sound and a particle. Both are rosebed's, not vanilla's:
`WorldManager.playSound` and `WorldManager.spawnParticle` are empty on a
vanilla server, which is why the eight aux effects of packet 61 were the only
thing a b1.7.3 server could make a client hear.

### Order

1. ~~**Mod networking.**~~ Done. Packet 251 `mod_message` carries
   `(channel, payload)` both ways, up to a 64 byte channel and 32 KB of
   arbitrary bytes. `rosebed.net.send(channel, text)` and
   `rosebed.net.on(channel, function(payload, from) end)`, installed for both
   `common.lua` and `client.lua`. `from` is the sender's name on the server
   and nil on the client. In single player there is no link, so a send loops
   straight back into the same VM on the next tick: a mod behaves the same
   in both modes without knowing which one it is in.
2. ~~**Events.**~~ Done. `on_world_tick(dimension, count)`,
   `on_chunk_load(x, z, fresh)`, `on_player_hurt(amount, health, x, y, z)`
   (return true to swallow the damage), `on_player_death(x, y, z)` and
   `on_mob_death(key, x, y, z)`. A handler that throws is switched off rather
   than run again, and an engine hook is only installed when a mod actually
   listens, so an unmodded game pays nothing. `rosebed.world` is reachable
   from the world, chunk and mob events. It is **not** reachable from the two
   player events: `Player.damageFrom` only holds a `*const World`, and making
   it mutable would ripple through `Player.tick` and every caller, so those
   two hand the numbers over as arguments instead.
   `on_block_broken(key, x, y, z, meta)` fires from
   `interact.breakBlockAt` and `on_block_placed(key, x, y, z, meta)` from
   `interact.placeBlockAt`, the single paths both sides now take. The
   metadata reported is the one that settled, after the facing a furnace,
   dispenser, pumpkin, stairs or repeater takes from the placer's yaw.
3. ~~**Effects.**~~ Done. `rosebed.play_sound(key, x, y, z, volume, pitch)`,
   `rosebed.particle(kind, x, y, z, dx, dy, dz)`,
   `rosebed.explode(x, y, z, size, flaming)` and
   `rosebed.spawn(name, x, y, z)`. A key, kind or mob name nothing is
   registered under is refused where the mod asks for it. The drift is read
   the way vanilla reads it: a tone for `note`, a colour for `reddust`, and
   ignored for `lava`, `slime` and `heart`. `explode` and `spawn` only land
   where the world is authoritative, so calling either from `client.lua`
   while connected to a server does nothing.
4. ~~**Commands.**~~ Done. `commands.zig` keeps a runtime registry beside the
   comptime `Verb` table, and `parse` hands back the rest of the line for a
   mod to tokenise. A name a vanilla verb or another mod already answers to
   is refused. One registered in `client.lua` runs on the client; one
   registered in `common.lua` is forwarded to the server when there is one.
5. ~~**Block entities.**~~ Done, as much as a mod needs. `World.block_states`
   is one map of position to `nbt.Compound`, saved and loaded through the same
   `TileEntities` list the vanilla eight use. What is **not** done is folding
   those eight typed maps (`furnaces`, `chests`, `signs`, `jukeboxes`,
   `notes`, `dispensers`, `mob_spawners`, `pistons`) into one registry with a
   vtable. They work, they are exact, and rewriting them buys a mod nothing
   that the state map does not already give it. If a mod ever needs to tick
   its own block entity or open a screen onto it, that is the moment to
   revisit, and step 6 is where it would land.
6. **Screens and containers.** Next up. Needs 1 and 5.
7. **Mob AI.** Expose the three seams `Animal` already has: `path_weight`,
   `action_state`, `after_move`. Until then a mod mob wanders like a vanilla
   animal and runs its `on_tick` afterwards.

Steps 1 to 5 are done and leave the API close to Fabric. Step 6 is the
expensive one left.

The glue between the mod VM and each end has no automated test: the server
peels `mod_message` in `drainPending` and flushes in `tick`, the client drains
`Connection.mod_inbox` and fills the outbox in `tickRemote`, and the same
holds for `flushModEffects`, `playModEffects` and the two `.custom` arms of
`runCommand`. The packets, the queues and
the dispatch are covered; those few lines of wiring are not. The client half
was walked through by hand instead: a probe mod placed a block, exploded it
and read back air, with a sound, two particles and a mob spawn in between.

### Known risks

- ~~**Breaking a block takes two paths.**~~ Unified into
  `interact.breakBlockAt`. Reading the reference first turned this from a
  refactor into a bug fix: `ItemInWorldManager.func_325_c` and
  `PlayerControllerSP.sendBlockRemoved` both drop only when
  `canHarvestBlock`, and both spill containers through
  `onBlockDestroyedByPlayer`. The server did neither, so it dropped
  cobblestone from a bare-fisted punch on stone and lost what a furnace or a
  dispenser held. A server test had the wrong behaviour written into it.
- ~~**Placing a block takes two paths.**~~ Unified into
  `interact.placeBlockAt`. Same shape of bug as the break path: the server
  wrote the block and stopped there, so a chest, furnace or dispenser placed
  on a dedicated server got no block entity at all, nothing took its facing
  from the placer's yaw, a repeater never got its metadata or its scheduled
  tick, and two slabs never merged. Vanilla runs both ends through
  `ItemBlock.onItemUse`; rosebed now does the same.
- Neither path does vanilla's `checkIfAABBIsClear` from
  `World.canBlockBePlacedAt`, so a block can be placed inside a standing
  entity. That predates the unification and is still open.
- Breaking a chest drops nothing, on either side. That one predates the
  unification and is still open.
- **A world with nobody in it does not tick.** `Level.tick` returns early when
  `occupants` is empty, so a dedicated server sitting idle runs no
  `on_world_tick`, no block ticks and no mod events at all. Vanilla ticks its
  worlds regardless.
- A mod effect is drained once per dimension, straight after that dimension's
  level ticks, which places anything queued from inside a tick correctly. One
  queued outside a tick, from a `mod_message` handler say, falls to whichever
  dimension drains first.
- **A tile entity outlives the block it belonged to.** Vanilla drops it in
  `Chunk.setBlockIDWithMetadata` whenever the old block was a `BlockContainer`;
  rosebed only clears one where a call site remembers to, which is
  `interact.breakBlockAt`. Replace a furnace by any other route and its
  contents are still in the map, and still saved. A mod's state has the same
  hole. Fixing it is the natural first step of folding the eight maps into
  one registry.
- Mods run before the world loads, so registration order decides ids. The block
  palette in the save covers a shuffle, but two mods claiming the same key
  still collide at load.
