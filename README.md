# The HUNT of Croakzilla

A top-down, real-time roguelite built in **Godot 4.4**. You play as Edward
Salami, a pest-control contractor hired to clear a national park of a
spreading rat plague — and the giant mutant amphibian, Croakzilla.
Fight through procedurally generated biomes, manage your resources 
and earn the highest score (and star rating) you can before
facing the boss.

🎮 [**Play in your browser on itch.io →**](https://larryjho.itch.io/the-hunt-of-croakzilla)

*Gameplay*

<video src="https://github.com/user-attachments/assets/44d19a63-7179-4b07-a6c8-595746b3339f" autoplay loop muted playsinline></video>
<video src="https://github.com/user-attachments/assets/31800bc0-ea9f-453a-931b-aac78a45d297" autoplay loop muted playsinline></video>
<video src="https://github.com/user-attachments/assets/33963e81-8720-4a1e-a701-8c614ac47386" autoplay loop muted playsinline></video>

---

## About the project

This game was originally created for a **game jam** in 7 days, then patched
afterwards with additional balance passes and minor quality-of-life
improvements. The jam scope shaped the design: a tight, replayable core
loop rather than a long authored campaign. The post-jam work focused on
sharpening that loop — tuning enemy behavior, difficulty scaling, the
boss fight, and adding a second aiming mode — without expanding the
footprint beyond what one developer can maintain.

## Procedural generation

Every level's layout is generated procedurally — rooms scattered, culled,
then connected with a minimum-spanning-tree corridor graph. There are two
reasons for this:

- **Replay value.** No two runs lay out the same, so the moment-to-moment
  navigation, enemy placement, and pickup distribution stay fresh across
  attempts. Combined with multiple difficulties and two aiming modes, a
  single short build supports many distinct playthroughs.
- **Proof of concept.** The generator is deliberately built as a reusable,
  parameter-driven system (room count, spread, density, cull rate, enemy
  budget — all configurable per biome). It serves as a foundation and
  testbed for larger future projects that will lean more heavily on
  procedural content.

## Resource management as a design pillar

The game runs on two depleting resources — **ammo/energy** (to fire your
gun) and a **hunger bar** (which damages you when empty) — and they exist
to push the player toward constant strategic decisions instead of mindless
shooting and forward motion.

The clearest expression of this is the level exit. Often the stairs down
are right nearby, and you *could* just descend. But ignoring the rest of the
level and descending early means leaving value on the table: unfarmed enemies
(points, permanent upgrade drops, energy refills) and apples that restore hunger
and only spawn inside rooms. So every level becomes a small risk/reward judgment
— dive now and stay safe but under-equipped, or sweep the floor for resources 
and upgrades at the cost of exposure, ammo, and hunger. You should manage a
good resource economy.

---

## Features

- Real-time combat with two selectable aiming modes (fixed cardinal aim or
  free cursor aim).
- Four difficulty tiers that scale room count, enemy density, and damage.
- Procedurally generated biomes with handcrafted boss arenas.
- A multi-phase final boss with escalating attack patterns.
- Permanent upgrade drops and consumable pickups.
- Score-based star rating on victory.

## Built with

- **Godot 4.4** / GDScript
- Custom procedural level generator (AStar2D + MST corridors)
- Manual real-time AI state machine for enemies

## Credits

Made by **LarryJho**. Originally a game jam entry, patched post-jam.
