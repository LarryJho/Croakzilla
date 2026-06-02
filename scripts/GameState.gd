class_name GameState
extends RefCounted

# Data stash across the scene change to GameOver. Static vars persist while
# the app is running (they reset when the game closes).
# Set by Character.kill() BEFORE change_scene_to_file (because ScoreLabel
# and others are freed together with Main on scene change); read by GameOver._ready().
static var last_score: int = 0
static var last_damage_source: String = ""

# Difficulty selected in DifficultySelect.tscn. Read by Main.gd
# (scales biome configs), Character.gd (damage modifier + speed),
# Enemy.gd (speed), AmmoMenu.gd (recharge interval), HungerMenu.gd
# (skip starve damage on Baby). Valid values: "Baby", "Normal",
# "Hell", "This doesn't make any sense". Default Normal in case something
# starts Main.tscn without going through DifficultySelect.
static var difficulty: String = "Normal"

# Beam aiming mode for the player's laser. Chosen in BeamModeSelect.tscn
# right after difficulty. Two valid values:
#   - "fixed"  : aims along the player's last cardinal facing (last_move).
#                Current/legacy behavior — no diagonals.
#   - "cursor" : aims from player toward the global mouse position.
#                Restores the original Godot-3-era free-aim behavior.
# Default "fixed" so anything starting Main.tscn without going through
# BeamModeSelect.tscn (testing/debug) keeps the established behavior.
static var beam_mode: String = "fixed"

# === SECRET ZOMBIE TRACKING (cross-run, in-session) ===
# Set by Character.kill() on death: flags the next run to spawn ONE
# Mobs/Zombie.tscn in the level the player died on (entrance → level 1,
# boss → last level before boss, else → same level index). Consumed
# (set false) by Level.gd when it actually spawns the zombie, so the
# zombie appears at most once per run. All three reset when the app
# quits (static vars).
static var zombie_pending: bool = false
static var zombie_target_biome: String = ""
static var zombie_target_level_index: int = -1   # 0-indexed num_level
