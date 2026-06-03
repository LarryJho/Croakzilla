# The Hunt of Croakzilla
*by LarryJho*

You are Edward Salami. The local national park has called you in to deal with a giant mutant animal that's destroying the ecosystem, and a rat plague spreading through the woods.

Earn the highest score you can — a 5-star recommendation means more contracts. Don't kill the snakes; they're a protected species and you **LOSE points** for each one.

![Gameplay](assets/gameplay.gif)

🎮 [**Play in your browser on itch.io**](https://larryjho.itch.io/the-hunt-of-croakzilla)

---

## Run Setup

Each run, after pressing **START** on the main menu, you'll pick:

1. **Difficulty** — Baby / Normal / Hell / This Doesn't Make Any Sense
2. **Beam Mode** — Fixed (cardinal aim) / Cursor (mouse aim)

Both choices persist for the run. Restart from the main menu to change them.

---

## Controls

| Action | Input |
|--------|-------|
| Move | `WASD` or Arrow keys |
| Shoot | `Space` (any mode) · `Left-click` (Cursor mode only) |
| Punch | `Left-click` on a nearby enemy (Fixed mode only) |
| Walk to | `Left-click` on the floor (Fixed mode only) |
| Zoom | Mouse wheel up / down |
| Pause | `ESC` |

**Beam mode details:**

- **Fixed** — beam fires in the direction you last moved (4 cardinals). Left-click punches adjacent enemies or walks to the clicked spot.
- **Cursor** — beam fires toward the mouse cursor at any angle. The sprite faces the cursor for each shot. Movement is keyboard-only; left-click always fires.

---

## Stats

| Bar | Color | Effect |
|-----|-------|--------|
| Health | 🔴 Red | Reach 0 and you die. |
| Hunger | 🔵 Blue | Reach 0 and you start taking damage. |
| Energy | 🟡 Yellow | Recharges automatically. Required to fire. |

---

## Enemies

| Enemy | Score | Notes |
|-------|-------|-------|
| Big Rat | +5 | Skittish. Runs, but turns to fight when cornered. |
| Snake | **−10** | **PROTECTED. Do not engage.** |
| Giant Shroom | +1 | Don't wake it up. Persistent once roused. |

---

## Pickups

| Pickup | Effect | Drop Rate |
|--------|--------|-----------|
| Heart | +10 HP | 8% from any kill |
| Battery | +5 energy | 15% from any kill (30% on Hell / Insane) |
| Apple | +20 hunger | 10% chance per room |
| Prize | Permanent buff (stacks up to 2 per type) | — |

**Prize pools:**
- **Normal** — range, damage, radius, speed, shield
- **Elite** — same effects scaled up, with bonus damage baked in (dark aura)

> Shield reduces each incoming hit by N damage (N = total shield stacks). Hits always deal at least 1 damage — no invincibility.

---

## Difficulty

| Mode | Description |
|------|-------------|
| **Baby** | Half damage taken (except from Croakzilla), slower enemies, half the rooms and enemies, +20 HP heal on boss-room entry, hunger doesn't kill, Croakzilla at 0.6× speed. |
| **Normal** | Default balanced run. |
| **Hell** | 2× rooms + 2× enemies, slower energy recharge, ×2 damage in boss rooms, 2× battery drop chance. |
| **This Doesn't Make Any Sense** | 2× rooms + 3× enemies (same map size as Hell, but denser), ×2 damage always, faster player AND enemies, 2× battery drop chance. |

---

## Star Rating

| | ⭐ | ⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ |
|---|---|---|---|---|---|
| Baby | ≤ 88 | ≤ 125 | ≤ 163 | ≤ 200 | > 200 |
| Normal | ≤ 175 | ≤ 250 | ≤ 325 | ≤ 400 | > 400 |
| Hell / Insane | ≤ 200 | ≤ 280 | ≤ 360 | ≤ 440 | > 440 |

---

## Tips

- Snakes give negative score. Walk past them.
- Hearts, Batteries, and Apples spawn often — search every room.
- Stack shields early: every shield point trims 1 damage from every hit. Two normal stacks + two elite stacks = 6 shield.
- The Marshlands boss room is a one-way trip. Heal up and stock energy before entering.

---

*Have fun, and don't get eaten.*
