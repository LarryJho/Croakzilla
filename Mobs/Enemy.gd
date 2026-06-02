extends CharacterBody2D

############################################################
### ENEMY (Croakzilla, real time):                       ###
### CharacterBody2D with manual movement (no physics).   ###
### Real-time AI, 4 states: IDLE / ROAMING /             ###
### PERSECUTOR / ASLEEP. Each physics frame:             ###
###   1. If player is in attack range -> strike.         ###
###   2. State transition by distance + LOS.             ###
###   3. Match current state -> set velocity.            ###
###   4. Apply movement with manual blocking.            ###
###   5. Update animation.                               ###
############################################################

signal health_updated(health, max_health)
signal killed

@onready var damage_timer = $DamageTimer
@onready var attack_timer = $AttackTimer

# Stats. @export so they can be tuned per mob from the .tscn inspector.
@export var max_health: int = 10
@export var attack: int = 5
# Points awarded when killing this mob. Default 2; overridden per mob in .tscn
# (Big_Rat=5, Snek=-10, Big_Rat_Gray=15, Giant_Shroom=1). Negative = penalty.
@export var kill_score: int = 2
# Probability of dropping a Prize (Power_Up) on death. 0.0-1.0.
@export var drop_chance: float = 0.1
# Type of Prize dropped. true = elite pool (3 strong buffs with +2 damage),
# false = normal pool (3 basic buffs). Only Plague_Big_Rat has this set to
# true; the rest use the normal pool.
@export var drops_elite: bool = false
# Flat probabilities of dropping Heart (+10 HP) and Battery (+10 ammo) on
# death. Independent of the prize and of each other. Default: heart 8%, battery 5%.
# Croakzilla sets them to 0.0 — the boss drops nothing (drop_chance=0 +
# heart_drop_chance=0 + battery_drop_chance=0).
@export var heart_drop_chance: float = 0.08
@export var battery_drop_chance: float = 0.15
# Guaranteed drops: independent of the probability-based drops above.
# kill() spawns EXACTLY this many of each on death. Used by the secret
# Zombie enemy (always drops 2 batteries + 1 heart + 1 apple). For
# normal mobs leave all three at 0 so behavior is unchanged.
@export var guaranteed_battery_drops: int = 0
@export var guaranteed_heart_drops: int = 0
@export var guaranteed_apple_drops: int = 0
# Opt-in sounds per mob. idle_sound plays every random 2-6s
# while the mob is NOT ASLEEP. death_sound plays once on
# death (in an AudioStreamPlayer that lives in the enemy's parent, in order
# to survive the queue_free). Both use the bus indicated by sfx_bus
# (default "SFX" — halved to -6dB). Croakzilla overrides to "Master"
# so its Ribbits play at the original volume. null = silent
# (e.g., Snek emits no sounds).
@export var idle_sound: AudioStream = null
@export var death_sound: AudioStream = null
@export var sfx_bus: StringName = &"SFX"
# Internal: player + countdown for the idle sound. Only created if idle_sound
# != null in _ready, to avoid adding empty nodes to silent mobs.
var _idle_sound_player: AudioStreamPlayer = null
var _idle_sound_cooldown: float = 0.0
@onready var health: int = max_health

# Tunables. @export = can be overridden per mob from the .tscn (in the
# Godot Inspector). The defaults apply if the .tscn doesn't set a value.
# All ranges in TILES (32 px) — multiplied by tile_size when used.
@export var speed: float = 2.0                     # base speed, tiles/sec
@export var detection_range_tiles: float = 5.0     # enters PERSECUTOR/FLEEING if player <= this
@export var lose_range_tiles: float = 6.0          # returns to ROAMING if player > this
@export var sleep_range_tiles: float = 15.0        # enters ASLEEP if player > this
@export var wake_range_tiles: float = 14.0         # wakes to ROAMING if player <= this
@export var attack_range_tiles: float = 1.0        # attacks if player <= this
@export var attack_cooldown: float = 1.0           # seconds between strikes
# Distance (px) the player is pushed when this mob hits them. Default 10
# = same value as Character.KNOCKBACK_DISTANCE, so existing mobs
# keep their previous behavior. Croakzilla overrides to 32.0 (1 tile)
# for the boss push. from==ZERO in damage() still cancels the knockback.
@export var attack_knockback: float = 10.0
@export var require_los_to_detect: bool = true     # false = sees through walls
# Passes through wall tiles of the Map (full bypass of _blocked_by_wall, doesn't
# affect collision against other actors). Default false; enabled in HR Snek for
# the "snakes phase through walls in Haunted Ruins" feature.
@export var can_pass_walls: bool = false

# FLEEING — for cowardly mobs (rats). When flees_when_detected=true,
# detecting the player does NOT send them to PERSECUTOR but to FLEEING (run away). They only
# switch to PERSECUTOR if the player corners them (dist <= corner_range_tiles).
# If the player just barely moves away (dist > corner_exit_tiles), they return to FLEEING.
@export var flees_when_detected: bool = false      # true = rat; false = predator
@export var corner_range_tiles: float = 2.0        # cornered -> PERSECUTOR
@export var corner_exit_tiles: float = 3.0         # hysteresis: PERSECUTOR -> FLEEING

# Direct pursuit: when true, PERSECUTOR mode walks straight toward the
# player (like FLEEING but inverted) instead of following an AStar path.
# Makes sense for bosses that can_pass_walls (Croakzilla) — AStar would
# route around walls the boss can phase through, and the 0.3 s
# path-request interval adds latency. Direct = aggressive, sticky pursuit.
@export var direct_pursuit: bool = false

# Multiplier applied to Character.LASER_HIT_RADIUS when the player's
# laser checks for hits on THIS mob. Default 1.0 = unchanged. Croakzilla
# overrides to 1.5 (50% bigger laser-target box) — fits the 64×64 sprite,
# since the default 8 px radius is too small to register grazes on a
# boss-sized target.
@export var body_hit_radius_mult: float = 1.0

# Per-mob velocity multiplier applied in Baby difficulty. Default
# 1.0 / 1.5 = 0.667 approx. (matches the old hardcoded `speed /= 1.5` so all
# existing mobs are unchanged). Croakzilla overrides to 0.8 — softer
# nerf so the boss is still a threat on easy mode.
@export var baby_speed_mult: float = 1.0 / 1.5

# Special LASER (hitscan ranged) — opt-in per mob. When laser_enabled=true,
# the mob fires once every laser_cooldown seconds if the player is within
# laser_range_tiles AND has LOS. Instant damage: the player takes laser_damage
# (halved in Baby difficulty) without knockback. Used by Croakzilla; other mobs
# default false. Visual: Line2D of color laser_color with fade out.
@export var laser_enabled: bool = false
@export var laser_damage: int = 20
@export var laser_range_tiles: float = 20.0
@export var laser_cooldown: float = 3.5
@export var laser_color: Color = Color(0.3, 1.0, 0.3, 1.0)
@export var laser_fade: float = 0.4              # s; duration of the laser's visual fade
@export var laser_width: float = 4.0             # px; thickness of the Line2D
@export var laser_mouth_offset: float = 16.0     # px; offset from center toward facing (mouth)
# Beam travel speed in tiles/sec. Replaces the instant hitscan model
# with a beam that visibly grows from the target. Default 10
# tiles/sec = 0.5s to reach 5 tiles, giving the player a dodge window.
# Lower = slower/more dodge-able; higher = more hitscan-feel.
@export var laser_speed_tiles_per_sec: float = 10.0
# Tiles the beam OVERSHOOTS past the player in the same direction. 0 = the beam
# ends exactly at the player's position at fire time (classic). >0 =
# the beam continues N tiles further, passing through the player and hitting
# anything behind. Croakzilla overrides to 20.
@export var laser_overshoot_tiles: float = 0.0
# Hit-check radius at the moment of impact. Any actor whose position
# is <= this radius from the beam SEGMENT (not just the endpoint) takes
# damage. Default 24 px ~ 3/4 tile.
@export var laser_hit_radius: float = 24.0
# If true, the beam also damages OTHER enemies (parent.enemies, excluding
# self) that are in the path. Used by Croakzilla for friendly-fire on
# the plague rats of the boss room. Default false: only damages the player.
@export var laser_damages_enemies: bool = false
# Win trigger: when this mob dies, snapshot the score and change_scene_to_file
# to YouWin.tscn. Used by final bosses (Croakzilla). Default false:
# death just follows the normal flow (flash + queue_free).
@export var triggers_win: bool = false

# === CHARGE ATTACK (telegraphed dash) ===
# When enabled, every charge_attack_cooldown seconds, IF the player is within
# charge_attack_range_tiles, the mob freezes for charge_attack_windup_time
# seconds (telegraph), then dashes straight toward the player at
# charge_attack_speed_mult * base persecutor speed for charge_attack_dash_time
# seconds. Used by Croakzilla as its main "tell-and-rush" attack.
@export var charge_attack_enabled: bool = false
@export var charge_attack_cooldown: float = 20.0
@export var charge_attack_range_tiles: float = 20.0
@export var charge_attack_windup_time: float = 3.0
@export var charge_attack_dash_time: float = 4.5
@export var charge_attack_speed_mult: float = 2.0

# === RAPID BEAM (phase-2 burst) ===
# When enabled AND the mob is below rapid_beam_health_threshold fraction of
# max_health, every rapid_beam_cooldown seconds the mob freezes and fires a
# special laser every rapid_beam_interval seconds for rapid_beam_duration
# seconds. Used by Croakzilla as its desperation phase-2 attack.
@export var rapid_beam_enabled: bool = false
@export var rapid_beam_cooldown: float = 25.0
@export var rapid_beam_health_threshold: float = 0.5
@export var rapid_beam_interval: float = 0.25
@export var rapid_beam_duration: float = 1.0
# Phase-3 escalation: at or below this fraction of max_health, the burst
# fires beams TWICE as fast (interval × rapid_beam_phase3_interval_mult).
# Same duration → 2x beam count in the same window. Applies on every
# difficulty (no Baby exemption). 0.1 = 10%. The interval is snapshotted
# at burst start so a mid-burst heal doesn't slow the in-flight rhythm.
@export var rapid_beam_phase3_threshold: float = 0.1
@export var rapid_beam_phase3_interval_mult: float = 0.5

# === RADIAL BURST (phase-3 omni-beam) ===
# When enabled AND below radial_burst_health_threshold of max_health, every
# radial_burst_cooldown seconds the mob plays radial_burst_sound, freezes
# for 2s (light shrinks 50% over a 1s tween), fires N beams in a full
# 360° fan (each beam length = randf_range(player_dist_tiles, +3)), stays
# still 1 more second, then resumes (light tweens back). Disabled on Baby
# difficulty by an explicit check at the start gate. Beam count + per-phase
# durations are constants — only the gate parameters and the sound are
# inspector-tunable.
@export var radial_burst_enabled: bool = false
@export var radial_burst_cooldown: float = 70.0
@export var radial_burst_health_threshold: float = 0.3
@export var radial_burst_sound: AudioStream = null
@export var radial_burst_sound_db: float = 18.0

# === HEAL ATTACK (self-regen at range) ===
# When enabled AND below heal_attack_health_threshold of max_health AND
# the player is at least heal_attack_min_player_distance_tiles away, every
# heal_attack_cooldown seconds the mob freezes for heal_attack_duration
# seconds and heals heal_attack_heal_percent of max_health (rounded up).
# Plays the green flash_heal shader effect during the freeze (same
# parameters Character.gd uses on boss-room arrival).
@export var heal_attack_enabled: bool = false
@export var heal_attack_cooldown: float = 8.0
@export var heal_attack_health_threshold: float = 0.6
@export var heal_attack_min_player_distance_tiles: float = 15.0
@export var heal_attack_heal_percent: float = 0.07
@export var heal_attack_duration: float = 1.0
# Hardcoded internals (the user-facing spec is "18 beams, 20° apart,
# stay still 2s then 1s, range = randf_range(d, d+3)").
const _RADIAL_BURST_BEAMS: int = 18
const _RADIAL_BURST_WINDUP: float = 2.0
const _RADIAL_BURST_SETTLE: float = 1.0
const _RADIAL_BURST_BEAM_EXTRA_TILES: float = 3.0
# Cap on the "d" used in each beam's randf_range(d, d+3). If the player is
# 80 tiles away during the burst we don't want 80-tile-long beams (visual
# cost + nonsense). Effective max beam length = MAX + EXTRA = 23 tiles.
const _RADIAL_BURST_BEAM_MAX_DIST_TILES: float = 20.0
# Travel-speed multiplier vs the normal targeted laser. 2.0 = radial beams
# extend twice as fast — the omni-fan reads as a "shockwave" instead of
# 18 slow targeted lasers.
const _RADIAL_BURST_BEAM_SPEED_MULT: float = 2.0
const _RADIAL_BURST_LIGHT_TWEEN: float = 1.0      # shrink to 0.5x base during windup
# Finale (chained, fires at end of settle): aura BURSTS to 3x base over
# 0.2s — a shockwave beat — then RETURNS to base over 0.4s. Visually sells
# the "released" energy of the radial blast after the 1s settle pause.
const _RADIAL_BURST_LIGHT_BURST_MULT: float = 3.0
const _RADIAL_BURST_LIGHT_BURST: float = 0.2
const _RADIAL_BURST_LIGHT_RETURN: float = 0.4

# Internal laser timer. Created in _ready only if laser_enabled=true to
# avoid adding overhead to mobs that don't use the ability.
var _laser_timer: Timer = null

# Charge attack runtime: cooldown_left ticks down even when phase != "ready"
# (no-op), phase is "ready" -> "windup" -> "dash" -> "ready".
var _charge_attack_cooldown_left: float = 0.0
var _charge_attack_phase: String = "ready"
var _charge_attack_phase_left: float = 0.0

# Rapid beam runtime: active=true blocks movement and fires beams on the
# interval. cooldown_left only starts ticking after the burst ends.
# _rapid_beam_active_interval is the per-burst snapshot of the firing
# interval (chosen at start based on phase-3 HP threshold) so a mid-burst
# heal can't slow the rhythm down. _rapid_beam_phase3_first_done flips
# true the first time the phase-3 burst (HP <= 10%) fires, so the wired
# bypass only happens once per Croakzilla life.
var _rapid_beam_cooldown_left: float = 0.0
var _rapid_beam_active: bool = false
var _rapid_beam_time_left: float = 0.0
var _rapid_beam_next_shot_in: float = 0.0
var _rapid_beam_active_interval: float = 0.25
var _rapid_beam_phase3_first_done: bool = false

# Radial burst runtime: elapsed counts from 0 at burst start. The 18 beams
# fire ONCE when elapsed crosses _RADIAL_BURST_WINDUP (shot_fired guard).
# At elapsed >= WINDUP+SETTLE the burst ends and cooldown resets.
var _radial_burst_cooldown_left: float = 0.0
var _radial_burst_active: bool = false
var _radial_burst_elapsed: float = 0.0
var _radial_burst_shot_fired: bool = false
# "Wired" first radial burst: when HP first crosses below the threshold
# (e.g. 30%), the start gate bypasses the cooldown check and fires immediately.
# After the first fire this stays true forever; subsequent bursts use the
# normal 70-second cooldown.
var _radial_burst_first_done: bool = false

# Heal-attack runtime: time_left ticks during the freeze. The heal itself
# is applied at start (one-shot); the freeze is the "telegraph" so the
# player can close the gap and interrupt the next heal.
var _heal_attack_cooldown_left: float = 0.0
var _heal_attack_active: bool = false
var _heal_attack_time_left: float = 0.0

# Cached PointLight2D for the charge-attack telegraph: light shrinks to
# half during windup, then bursts to double during the dash, then returns
# to base. Null on mobs without a PointLight2D (most of them).
var _point_light: PointLight2D = null
var _point_light_base_scale: float = 1.0
# Cached tween for the aura's scale changes. Killed before starting a
# new one so back-to-back transitions (windup -> dash -> ready) don't
# overlap and produce jittery values.
var _point_light_tween: Tween = null

var play_mode = false
var last_move = "Down_Idle"
var actual = "ROAMING"
var tile_size = 32

# Internal AI state
var roam_dir: Vector2 = Vector2.ZERO
var roam_timer: float = 0.0
var path_request_timer: float = 0.0
const PATH_REQUEST_INTERVAL: float = 0.3

var behaviors = ["IDLE", "ROAMING", "FLEEING", "PERSECUTOR", "ASLEEP"]

# Collision radii against other actors.
#   vs other enemies: 8 px — swarms can compact so that
#     all reach attack range (with 24 px only 3-4 made it).
#   vs player:        14 px — must be less than attack_range_tiles * 32
#     so the enemy stops INSIDE attack range and fires.
const ACTOR_RADIUS_VS_ENEMY: float = 8.0
const ACTOR_RADIUS_VS_PLAYER: float = 14.0

# Speed multiplier in PERSECUTOR and in FLEEING (roam uses base speed).
const PERSECUTOR_SPEED_MULT: float = 2.0
const FLEE_SPEED_MULT: float = 2.0

# Path produced by LevelBase.ask_for_path_player(self). The setter removes
# the first waypoint (the enemy's own current position).
var path: PackedVector2Array = PackedVector2Array():
	set(value):
		path = value
		if path.size() > 0:
			path.remove_at(0)


func _ready():
	randomize()
	# Override the .tscn Timer's wait_time (all .tscn have 0.5)
	# to take the @export value. This way each mob can have its own cooldown.
	attack_timer.wait_time = attack_cooldown
	# Y-sort: the enemy is drawn according to its Y relative to other Y-sorted
	# nodes under the same parent (the Level/Entrance/BossRoom also enables y_sort).
	y_sort_enabled = true
	# Own (non-shared) material for the damage/death flash. It has to
	# be one instance per enemy so it doesn't tint the rest of the swarm.
	var mat := ShaderMaterial.new()
	mat.shader = load("res://assets/shaders/flash.gdshader")
	$AnimatedSprite2D.material = mat
	# Optional HealthBar — only mobs whose .tscn includes it as a child
	# (Big_Rat_Gray, Plague_Big_Rat). Initialized with max_value =
	# max_health and hidden; appears on the first hit in damage() and remains
	# visible until death.
	if has_node("HealthBar"):
		var bar = $HealthBar
		bar.max_value = max_health
		bar.value = health
		bar.visible = false
	# Difficulty: in "This doesn't make any sense" all actors
	# move 1.5x. In "Baby" enemies move at 1/1.5 = 0.66x
	# (slower, gives the player a chance). Applied in-place on the
	# mob's @export — only affects base speed; the PERSECUTOR/FLEE
	# multipliers are applied on top.
	if GameState.difficulty == "This doesn't make any sense":
		speed *= 1.5
	elif GameState.difficulty == "Baby":
		speed *= baby_speed_mult
	# Cursor beam mode lets the player aim from any angle at long range,
	# so enemies need slightly wider awareness windows to stay challenging.
	# Bosses that use the charge attack (only Croakzilla today, but
	# gated by `charge_attack_enabled` for any future charge-using mob)
	# also get a shorter charge cooldown — 20 s → 17 s — so their dash
	# pressure keeps pace with the player's expanded shooting freedom.
	# Final boss ALSO get +20% HP and +0.1 speed in cursor mode, 
	# since the player's free-aim makes the existing pool melt faster.
	# HealthBar is refreshed inline because it was already initialized
	# to the pre-boost max above. The +0.1 speed is applied AFTER the
	# Baby multiplier so easy mode still feels softer (Baby cursor =
	# 2.7 * 0.6 + 0.1 = 1.72; Normal cursor = 2.7 + 0.1 = 2.8).
	if GameState.beam_mode == "cursor":
		if kill_score >= 0:
			detection_range_tiles += 2.0
			lose_range_tiles += 2.0
			sleep_range_tiles += 2.0
			wake_range_tiles += 2.0
		if charge_attack_enabled:
			charge_attack_cooldown = 17.0
		if triggers_win:
			max_health = int(max_health * 1.2)
			health = max_health
			if has_node("HealthBar"):
				$HealthBar.max_value = max_health
				$HealthBar.value = health
			speed += 0.1
	# Setup the laser timer if enabled. one_shot=true because _fire_special_laser
	# restarts it after each shot. autostart=false; we start it manually
	# at the end of _ready so the first laser respects laser_cooldown from
	# spawn (doesn't fire immediately as soon as the mob appears).
	if laser_enabled:
		_laser_timer = Timer.new()
		_laser_timer.wait_time = laser_cooldown
		_laser_timer.one_shot = true
		add_child(_laser_timer)
		_laser_timer.start()
	# Cache the PointLight2D (if any) and its base texture_scale so the
	# charge-attack telegraph can multiply against the inspector value
	# instead of hardcoding a fixed scale.
	if has_node("PointLight2D"):
		_point_light = $PointLight2D
		_point_light_base_scale = _point_light.texture_scale
	# Idle sound: only create the player if the mob has sound. Bus "SFX"
	# to respond to the Settings slider. Random initial cooldown so
	# swarms of the same mob don't sound in lockstep.
	if idle_sound != null:
		_idle_sound_player = AudioStreamPlayer.new()
		_idle_sound_player.stream = idle_sound
		_idle_sound_player.bus = sfx_bus
		add_child(_idle_sound_player)
		_idle_sound_cooldown = randf_range(2.0, 6.0)


############# health

func damage(amount, from: Vector2 = Vector2.ZERO):
	if damage_timer.is_stopped():
		damage_timer.start()
		_apply_knockback(from)
		set_health(health - amount)
		# If the mob's .tscn includes HealthBar, sync and show it.
		# It stays visible forever after the first hit; the queue_free on
		# death takes it along with the actor. No-op for mobs without HealthBar.
		if has_node("HealthBar"):
			var bar = $HealthBar
			bar.value = health
			bar.visible = true
		if health > 0:
			_flash_damage()
			# AGGRO ON DAMAGE: a mob shot from outside its detection_range
			# would otherwise stay ROAMING (the state machine only transitions
			# to PERSECUTOR/FLEEING on distance+LOS). Getting hit at any
			# range should kick it out of passive states immediately.
			# Cowardly mobs (rats with flees_when_detected=true) -> FLEEING;
			# everything else -> PERSECUTOR. Already-active states unchanged.
			if actual == "IDLE" or actual == "ROAMING" or actual == "ASLEEP":
				if flees_when_detected:
					actual = "FLEEING"
				else:
					actual = "PERSECUTOR"
					path = PackedVector2Array()
					path_request_timer = 0.0


# Pushes 6 px in the direction opposite to the damage source. Per-axis slide when
# the target is blocked, same as manual movement. from == ZERO ⇒
# unknown source ⇒ no push.
const KNOCKBACK_DISTANCE: float = 6.0

func _apply_knockback(from: Vector2):
	if from == Vector2.ZERO:
		return
	var dir = (position - from).normalized()
	if dir == Vector2.ZERO:
		return
	var displacement = dir * KNOCKBACK_DISTANCE
	var target = position + displacement
	if not _is_blocked(target):
		position = target
		return
	var x_only = position + Vector2(displacement.x, 0)
	if displacement.x != 0.0 and not _is_blocked(x_only):
		position = x_only
		return
	var y_only = position + Vector2(0, displacement.y)
	if displacement.y != 0.0 and not _is_blocked(y_only):
		position = y_only


# Pops sprite to pure white (via flash.gdshader), holds one frame, fades out.
# Tween auto-bound to self, so dying mid-flash doesn't crash.
func _flash_damage():
	var mat := $AnimatedSprite2D.material as ShaderMaterial
	if mat == null:
		return
	mat.set_shader_parameter("flash", 1.0)
	var tw = create_tween()
	tw.tween_interval(0.02)
	tw.tween_property(mat, "shader_parameter/flash", 0.0, 0.05)


func set_health(value):
	var prev_health = health
	health = clamp(value, 0, max_health)
	if health != prev_health:
		if health == 0:
			kill()
			killed.emit()


# Random offset for items dropped on kill (prize + heart + battery).
# Distance 2-6 px in a random direction: prevents multiple drops from the
# same kill from landing on exactly the same pixel and being visually
# stacked. The radius is small enough that the pickup (20 px radius
# from the player) grabs them all on pass.
func _drop_offset() -> Vector2:
	var angle = randf() * TAU
	var dist = randf_range(2.0, 6.0)
	return Vector2(cos(angle), sin(angle)) * dist


# Mob name for the GameOver "Died to X." message. Derived from the
# scene_file_path (all .tscn in Mobs/.../X.tscn share root name
# "Enemy", so the filename is the only distinguishing thing).
func _source_name() -> String:
	if scene_file_path == "":
		return ""
	return scene_file_path.get_file().get_basename()


func kill():
	# Remove the enemy from the registry: stops blocking movement, stops
	# being a click-to-attack target, and the list reflects real num_enemies.
	var parent = get_parent()
	if parent != null:
		parent.enemies.erase(self)
		parent.num_enemies -= 1
		# Add score — looks for ScoreLabel in Main (parent.parent). Same
		# pattern as the hunger heal on boss room arrival.
		var main = parent.get_parent()
		if main != null:
			var score_label = main.get_node_or_null("CanvasMenu/ControlMenu/ScoreLabel")
			if score_label != null:
				score_label.add_score(kill_score)
		# Drop Prize based on drop_chance + drops_elite. The prize stays on the
		# level floor; Character._check_prize_pickup consumes it on
		# passing nearby. If Prize.tscn doesn't load (missing asset), silent.
		# Halve drop_chance if the player already has >2 stacks of normal buffs:
		# avoids flooding the HUD with normal buffs as the run progresses.
		var chance: float = drop_chance
		var player = get_tree().get_first_node_in_group("player")
		if player != null and player.has_method("get_normal_buff_count"):
			if player.get_normal_buff_count() > 2:
				chance *= 0.5
		if randf() < chance:
			var prize_scene = load("res://Prize.tscn")
			if prize_scene != null:
				var prize = prize_scene.instantiate()
				prize.is_elite = drops_elite
				prize.position = position + _drop_offset()
				parent.add_child(prize)
				parent.prizes.append(prize)
		# Heart drop: @export heart_drop_chance (default 8%), independent
		# of the prize. Heals 10 HP on pickup. Croakzilla overrides to 0.0.
		if randf() < heart_drop_chance:
			var heart_scene = load("res://Heart.tscn")
			if heart_scene != null:
				var heart = heart_scene.instantiate()
				heart.position = position + _drop_offset()
				parent.add_child(heart)
				parent.hearts.append(heart)
		# Battery drop: @export battery_drop_chance (default 15%), independent
		# of prize/heart. Restores 5 ammo on pickup. Croakzilla overrides to 0.0.
		# Hell / Insane DOUBLE the chance (energy economy is tighter on these
		# difficulties because there are more enemies to shoot — more drops
		# keep the ammo pool sustainable). Mobs that override the @export to
		# 0 (Croakzilla, Zombie) stay at 0 because 0 × 2 = 0.
		var battery_chance: float = battery_drop_chance
		var d_bat: String = GameState.difficulty
		if d_bat == "Hell" or d_bat == "This doesn't make any sense":
			battery_chance *= 2.0
		if randf() < battery_chance:
			var battery_scene = load("res://Battery.tscn")
			if battery_scene != null:
				var battery = battery_scene.instantiate()
				battery.position = position + _drop_offset()
				parent.add_child(battery)
				parent.batteries.append(battery)
		# Guaranteed drops: spawn N copies of battery/heart/apple
		# unconditionally. Each uses _drop_offset() so they spread
		# visually instead of stacking on the same pixel. Default
		# all zero — only the Zombie sets these to (2, 1, 1).
		if guaranteed_battery_drops > 0:
			var bs = load("res://Battery.tscn")
			if bs != null:
				for _i in range(guaranteed_battery_drops):
					var b = bs.instantiate()
					b.position = position + _drop_offset()
					parent.add_child(b)
					parent.batteries.append(b)
		if guaranteed_heart_drops > 0:
			var hs = load("res://Heart.tscn")
			if hs != null:
				for _i in range(guaranteed_heart_drops):
					var h = hs.instantiate()
					h.position = position + _drop_offset()
					parent.add_child(h)
					parent.hearts.append(h)
		if guaranteed_apple_drops > 0:
			var aps = load("res://Apple.tscn")
			if aps != null:
				for _i in range(guaranteed_apple_drops):
					var a = aps.instantiate()
					a.position = position + _drop_offset()
					parent.add_child(a)
					parent.apples.append(a)
	# Death sound: instantiate an AudioStreamPlayer IN THE PARENT (level) so
	# it survives this enemy's queue_free. Auto-free via the finished signal.
	if death_sound != null and parent != null:
		var dp := AudioStreamPlayer.new()
		dp.stream = death_sound
		dp.bus = sfx_bus
		parent.add_child(dp)
		dp.play()
		dp.finished.connect(dp.queue_free)
	# Freeze AI during the death flash: without this it would keep moving
	# and hitting the player during the ~0.2s the flash lasts.
	play_mode = false
	_flash_death_and_free()


# Longer white pop than the damage one, then queue_free. If for some reason
# there's no material (shader didn't load), free immediately so we don't leave
# a zombie enemy on screen.
func _flash_death_and_free():
	var mat := $AnimatedSprite2D.material as ShaderMaterial
	if mat == null:
		# No shader: rare case (shader didn't load). If triggers_win, we still
		# fire the transition to the WIN screen before queue_free.
		if triggers_win:
			_do_win_transition()
		queue_free()
		return
	mat.set_shader_parameter("flash", 1.0)
	var tw = create_tween()
	tw.tween_interval(0.1)
	# Win trigger (final boss): dramatic pause + scene change BEFORE the
	# queue_free. _do_win_transition calls change_scene_to_file which is deferred
	# (processed at the end of the frame); the queue_free stays queued but doesn't
	# get to run because the scene change frees the entire tree.
	if triggers_win:
		tw.tween_interval(0.4)
		tw.tween_callback(_do_win_transition)
	tw.tween_callback(queue_free)


# Snapshot of the final score + change_scene_to_file to YouWin. Executed as a
# tween callback BEFORE queue_free, so self remains valid when reading ScoreLabel.
# Same pattern as Character.kill() for GameOver: assumes the hierarchy
# is boss → BossRoom → Main, and ScoreLabel hangs from Main's CanvasMenu.
func _do_win_transition() -> void:
	var p = get_parent()
	if p != null:
		var pp = p.get_parent()
		if pp != null:
			var sl = pp.get_node_or_null("CanvasMenu/ControlMenu/ScoreLabel")
			if sl != null:
				GameState.last_score = sl.score
	get_tree().change_scene_to_file("res://interface/YouWin.tscn")

##################


#################### Real-time AI

func _physics_process(delta):
	if not play_mode:
		velocity = Vector2.ZERO
		return

	var parent = get_parent()
	var has_player = parent != null and parent.player != null

	# Distance to player and "in attack range" flag — computed once
	# to be used in the attack block, transition, and match.
	var dist_to_player := INF
	if has_player:
		dist_to_player = position.distance_to(parent.player.position)
	var in_attack_range = has_player and dist_to_player <= attack_range_tiles * tile_size

	# Tick special attack cooldowns every frame (regardless of phase).
	if charge_attack_enabled:
		_charge_attack_cooldown_left = max(0.0, _charge_attack_cooldown_left - delta)
	if rapid_beam_enabled:
		_rapid_beam_cooldown_left = max(0.0, _rapid_beam_cooldown_left - delta)
	if radial_burst_enabled:
		_radial_burst_cooldown_left = max(0.0, _radial_burst_cooldown_left - delta)
	if heal_attack_enabled:
		_heal_attack_cooldown_left = max(0.0, _heal_attack_cooldown_left - delta)

	# Try to start a charge attack: ready + cooldown up + player in range.
	# Don't start if any other special is active (mutual exclusion).
	# Extra gate: not at full HP (the boss only uses it once the fight is
	# under way). On Baby difficulty the charge IS used but windup and dash
	# durations are halved (cooldown is unchanged), via _charge_baby_mult().
	if charge_attack_enabled and _charge_attack_phase == "ready" \
			and not _rapid_beam_active and not _radial_burst_active and not _heal_attack_active \
			and health < max_health:
		if _charge_attack_cooldown_left <= 0.0 and has_player:
			if dist_to_player <= charge_attack_range_tiles * tile_size:
				_charge_attack_phase = "windup"
				_charge_attack_phase_left = charge_attack_windup_time * _charge_baby_mult()
				_face(parent.player.position)
				# Telegraph: aura shrinks to half over most of the windup
				# (slow gather — player reads it as "the boss is
				# concentrating" before the dash).
				_set_charge_light_mult(0.5, 1.0)

	# Try to start a rapid beam burst: low health + no other special active.
	# Two paths into the burst:
	#   - PERIODIC: cooldown up + HP < 50% (normal rapid beam).
	#   - WIRED PHASE-3: first time HP <= 10%, bypass cooldown so the doubled
	#     burst is guaranteed as a "death scream" cue. Subsequent phase-3
	#     bursts use the normal cooldown again.
	# After any burst ends, cooldown resets to rapid_beam_cooldown (25s by
	# default) — so even the wired bypass doesn't immediately chain into
	# another burst right after (overkill prevention).
	if rapid_beam_enabled and not _rapid_beam_active \
			and _charge_attack_phase == "ready" and not _radial_burst_active and not _heal_attack_active:
		var _phase3_now: bool = health <= int(max_health * rapid_beam_phase3_threshold)
		var _can_fire_first: bool = _phase3_now and not _rapid_beam_phase3_first_done
		var _can_fire_periodic: bool = _rapid_beam_cooldown_left <= 0.0
		if (_can_fire_first or _can_fire_periodic) and health < int(max_health * rapid_beam_health_threshold):
			_rapid_beam_active = true
			_rapid_beam_time_left = rapid_beam_duration
			_rapid_beam_next_shot_in = 0.0  # fire immediately
			# Phase-3 escalation: at/below 10% HP, halve the firing interval
			# (~double the beam count in the same duration). Snapshot now so
			# a heal mid-burst doesn't change the rhythm.
			if _phase3_now:
				_rapid_beam_active_interval = rapid_beam_interval * rapid_beam_phase3_interval_mult
				_rapid_beam_phase3_first_done = true
			else:
				_rapid_beam_active_interval = rapid_beam_interval

	# Try to start a radial burst: low health + no other special active.
	# WIRED FIRST (all difficulties incl. Baby): the first time HP drops
	# below the threshold, the cooldown check is bypassed so the burst is
	# guaranteed to play once as a "phase transition" cue.
	# PERIODIC (Normal and harder): after the first fire, the 70s cooldown
	# allows repeat bursts. On Baby the periodic path is blocked, so the
	# wired-first is the ONLY radial burst Baby ever sees.
	if radial_burst_enabled and not _radial_burst_active \
			and _charge_attack_phase == "ready" and not _rapid_beam_active and not _heal_attack_active \
			and health < int(max_health * radial_burst_health_threshold):
		var _is_baby := GameState.difficulty == "Baby"
		var _can_fire_first: bool = not _radial_burst_first_done
		var _can_fire_periodic: bool = (not _is_baby) and _radial_burst_cooldown_left <= 0.0
		if _can_fire_first or _can_fire_periodic:
			_start_radial_burst()
			_radial_burst_first_done = true

	# Try to start a heal: low health + player far enough + cooldown
	# up + no other special active. Heal applied at start (one-shot); the
	# 1s freeze that follows is the "telegraph" — the player can close the
	# gap and interrupt the next heal.
	if heal_attack_enabled and not _heal_attack_active \
			and _charge_attack_phase == "ready" and not _rapid_beam_active and not _radial_burst_active:
		if _heal_attack_cooldown_left <= 0.0 and has_player \
				and health < int(max_health * heal_attack_health_threshold) \
				and dist_to_player >= heal_attack_min_player_distance_tiles * tile_size:
			_start_heal_attack()

	# "Stationary special": windup of charge OR rapid beam burst OR radial
	# burst OR heal attack. Any of these freeze the mob (no movement, no
	# melee). The actual attack/laser blocks below skip when this is true.
	var in_special_still = (_charge_attack_phase == "windup") or _rapid_beam_active or _radial_burst_active or _heal_attack_active
	# "Dash override": during charge dash, velocity is forced toward the
	# player at boosted speed regardless of the state machine.
	var in_special_dash = (_charge_attack_phase == "dash")

	# 1) ATTACK ALWAYS — before the state machine. This way a mob strikes at 1 tile
	#    even if it's in ROAMING (random-walked up to the player) or in future
	#    states that don't yet enter PERSECUTOR. Skipped during stationary specials
	#    so the boss visibly "freezes" during windup / rapid burst.
	if in_attack_range and not in_special_still:
		_face(parent.player.position)
		velocity = Vector2.ZERO
		if attack_timer.is_stopped():
			attack_timer.start()
			# Pass triggers_win as ignore_baby_halve: bosses (Croakzilla)
			# deal full damage on Baby; regular mobs let Character halve.
			parent.player.damage(attack, position, _source_name(), attack_knockback, triggers_win)

	# 1.5) Special LASER — independent of melee. No in_attack_range gate:
	# the boss can fire it even if the player is in melee range too.
	# Gating: cooldown ready + player within laser_range + clear LOS.
	# Disabled while a rapid beam burst or radial burst is active (those
	# specials own the lasers / require visual silence).
	if laser_enabled and has_player and _laser_timer != null and _laser_timer.is_stopped() \
			and not _rapid_beam_active and not _radial_burst_active and not _heal_attack_active:
		var laser_max_px = laser_range_tiles * tile_size
		if dist_to_player <= laser_max_px and _player_visible():
			_face(parent.player.position)
			_fire_special_laser(parent.player)
			_laser_timer.start()

	# 2) STATE TRANSITION with sleep + optional LOS + flee (opt-in per mob).
	#    States: IDLE, ROAMING, FLEEING, PERSECUTOR, ASLEEP.
	#    - ASLEEP <-> ROAMING: very high distance turns the AI off (saves CPU);
	#      when back in reasonable range it wakes up. Sleep/wake hysteresis.
	#    - ROAMING -> FLEEING or PERSECUTOR: on detection (detection_range + LOS).
	#      If flees_when_detected=true (rats), goes to FLEEING instead of PERSECUTOR.
	#      If VERY close (<=corner_range), goes straight to PERSECUTOR.
	#    - FLEEING -> PERSECUTOR: cornered (dist <= corner_range_tiles).
	#    - PERSECUTOR -> FLEEING: only for cowardly mobs, if the player moves away
	#      past corner_exit_tiles (they go back to fleeing once no longer cornered).
	#    - FLEEING/PERSECUTOR -> ROAMING: lose_range_tiles (clean escape).
	#    IDLE is not touched here: it's the responsibility of external code.
	if has_player and actual != "IDLE":
		var dist_tiles = dist_to_player / tile_size
		var sees_player = (not require_los_to_detect) or _player_visible()

		if actual == "ASLEEP":
			if dist_tiles <= wake_range_tiles:
				actual = "ROAMING"
				roam_timer = 0.0
		elif dist_tiles > sleep_range_tiles:
			actual = "ASLEEP"
			path = PackedVector2Array()
		elif actual == "ROAMING":
			if dist_tiles <= corner_range_tiles and sees_player:
				# Player very close even in ROAMING — always engages.
				actual = "PERSECUTOR"
				path = PackedVector2Array()
				path_request_timer = 0.0
			elif dist_tiles <= detection_range_tiles and sees_player:
				if flees_when_detected:
					actual = "FLEEING"
				else:
					actual = "PERSECUTOR"
					path = PackedVector2Array()
					path_request_timer = 0.0
		elif actual == "FLEEING":
			if dist_tiles <= corner_range_tiles:
				# Cornered — turn and fight.
				actual = "PERSECUTOR"
				path = PackedVector2Array()
				path_request_timer = 0.0
			elif dist_tiles > lose_range_tiles:
				actual = "ROAMING"
				roam_timer = 0.0
		elif actual == "PERSECUTOR":
			if flees_when_detected and dist_tiles > corner_exit_tiles and dist_tiles <= lose_range_tiles:
				# Cowardly mob: the player moved out of combat range.
				# Goes back to fleeing (don't switch directly to ROAMING if still
				# within detection range).
				actual = "FLEEING"
				path = PackedVector2Array()
			elif dist_tiles > lose_range_tiles:
				actual = "ROAMING"
				path = PackedVector2Array()
				roam_timer = 0.0

	# 3) MATCH STATE -> set velocity (unless the ATTACK block has already
	#    set it to 0; the match doesn't overwrite if in_attack_range).
	match actual:
		"IDLE", "ASLEEP":
			velocity = Vector2.ZERO

		"ROAMING":
			if not in_attack_range:
				roam_timer -= delta
				if roam_timer <= 0.0:
					# 4 cardinals only. The old version included Vector2.ZERO
					# (1/5 chance to stand still 0.5-1.5 s) for an "ambient
					# pause" feel, but it caused mobs to look stuck/idle
					# when in the gap between wake_range and detection_range
					# (mob is awake but not chasing yet). Removed so roaming
					# always moves.
					var choices = [Vector2.UP, Vector2.DOWN, Vector2.LEFT, Vector2.RIGHT]
					roam_dir = choices[randi() % choices.size()]
					roam_timer = randf_range(0.5, 1.5)
				velocity = roam_dir * speed * tile_size

		"FLEEING":
			# Walks straight in the direction opposite to the player. Doesn't use AStar:
			# if it hits a wall, the collision system slides along the free axis
			# and eventually the player will corner it -> PERSECUTOR.
			if has_player:
				var flee_dir = (position - parent.player.position).normalized()
				velocity = flee_dir * speed * tile_size * FLEE_SPEED_MULT
			else:
				velocity = Vector2.ZERO

		"PERSECUTOR":
			if not in_attack_range:
				if direct_pursuit:
					# Straight-line chase, no AStar. Same shape as FLEEING
					# but inverted (toward player). The slide-on-axis logic
					# in the movement section handles walls — except for
					# can_pass_walls bosses, where there's nothing to slide
					# against anyway.
					if has_player:
						var to_player = (parent.player.position - position).normalized()
						velocity = to_player * speed * tile_size * PERSECUTOR_SPEED_MULT
					else:
						velocity = Vector2.ZERO
				else:
					path_request_timer -= delta
					if path_request_timer <= 0.0 and parent != null:
						parent.ask_for_path_player(self)
						path_request_timer = PATH_REQUEST_INTERVAL
					# Drop already-reached waypoints in one go, instead of
					# stopping for a frame each time. The previous code set
					# velocity=ZERO after popping a waypoint and then waited
					# until next frame to read [0], which made mobs visibly
					# stutter to idle every few tiles.
					while path.size() > 0 and (path[0] - position).length() <= 4.0:
						path.remove_at(0)
					if path.size() > 0:
						var to_target = (path[0] - position).normalized()
						velocity = to_target * speed * tile_size * PERSECUTOR_SPEED_MULT
					elif has_player:
						# FALLBACK: AStar returned no usable path this frame
						# (request still pending, player unreachable, or
						# trimmed to empty). Walk straight at the player
						# instead of standing still. This fixes the "rat
						# goes idle in chase range" bug.
						var to_player = (parent.player.position - position).normalized()
						velocity = to_player * speed * tile_size * PERSECUTOR_SPEED_MULT
					else:
						velocity = Vector2.ZERO

	# 3.5) SPECIAL ATTACK PHASE OVERRIDES — applied AFTER the state machine
	# so they win over the regular velocity set by the match block.
	if _charge_attack_phase == "windup":
		# Telegraph: completely still + face player.
		velocity = Vector2.ZERO
		if has_player:
			_face(parent.player.position)
		_charge_attack_phase_left -= delta
		if _charge_attack_phase_left <= 0.0:
			_charge_attack_phase = "dash"
			# Dash duration is NOT scaled by Baby — only the windup is.
			# Reasoning: short windup gives Baby players warning AND lets
			# the dash land hits at full duration, so the attack still has
			# meaningful weight on easy mode.
			_charge_attack_phase_left = charge_attack_dash_time
			# Burst: aura snaps to double almost instantly. The quick
			# pop sells the "release" moment as the boss takes off.
			_set_charge_light_mult(2.0, 0.15)
	elif _charge_attack_phase == "dash":
		# Boosted straight-line chase; ignores AStar, walls handled by
		# can_pass_walls or the per-axis slide in section 4.
		# Speed mult is the inspector value (default 2x), additionally
		# multiplied by 1.5 on Baby — compensates for the halved base
		# speed (baby_speed_mult=0.5) so the Baby dash still has weight.
		if has_player:
			var dash_dir = (parent.player.position - position).normalized()
			velocity = dash_dir * speed * tile_size * PERSECUTOR_SPEED_MULT * _charge_dash_speed_mult()
		else:
			velocity = Vector2.ZERO
		_charge_attack_phase_left -= delta
		if _charge_attack_phase_left <= 0.0:
			_charge_attack_phase = "ready"
			_charge_attack_cooldown_left = charge_attack_cooldown
			# Dash over: aura eases back to its inspector base size
			# over a relaxed cool-down.
			_set_charge_light_mult(1.0, 0.6)

	if _rapid_beam_active:
		# Frozen burst: stay still + face player + fire on the interval.
		velocity = Vector2.ZERO
		if has_player:
			_face(parent.player.position)
		_rapid_beam_next_shot_in -= delta
		if _rapid_beam_next_shot_in <= 0.0 and has_player and is_instance_valid(parent.player):
			_fire_special_laser(parent.player)
			_rapid_beam_next_shot_in = _rapid_beam_active_interval
		_rapid_beam_time_left -= delta
		if _rapid_beam_time_left <= 0.0:
			_rapid_beam_active = false
			_rapid_beam_cooldown_left = rapid_beam_cooldown

	if _radial_burst_active:
		# Frozen 3s: at t=2s fire the 18-beam fan exactly once, at t=3s end.
		# Light shrink/return tweens are kicked off elsewhere (_start_radial_burst
		# at t=0; _set_charge_light_mult(1.0, ...) here at t=3).
		velocity = Vector2.ZERO
		_radial_burst_elapsed += delta
		if not _radial_burst_shot_fired and _radial_burst_elapsed >= _RADIAL_BURST_WINDUP:
			_radial_burst_shot_fired = true
			_fire_radial_burst()
		if _radial_burst_elapsed >= _RADIAL_BURST_WINDUP + _RADIAL_BURST_SETTLE:
			_radial_burst_active = false
			_radial_burst_cooldown_left = radial_burst_cooldown
			# Aura: burst to 3x over 0.2s, then ease back to base over 0.4s.
			# Visual punch beat at the end of the special.
			_radial_burst_light_finale()

	if _heal_attack_active:
		# Frozen freeze; heal was applied at start. Counts down and ends.
		velocity = Vector2.ZERO
		_heal_attack_time_left -= delta
		if _heal_attack_time_left <= 0.0:
			_heal_attack_active = false
			_heal_attack_cooldown_left = heal_attack_cooldown

	# 4) APPLY MOVEMENT with manual blocking: walls + actors. Sliding
	#    on a single axis when one direction is blocked.
	var step = velocity * delta
	if step != Vector2.ZERO:
		var attempted = position + step
		if not _is_blocked(attempted):
			position = attempted
		else:
			var x_only = position + Vector2(step.x, 0)
			if step.x != 0 and not _is_blocked(x_only):
				position = x_only
			else:
				var y_only = position + Vector2(0, step.y)
				if step.y != 0 and not _is_blocked(y_only):
					position = y_only

	# 5) Animation.
	_update_animation()

	# 6) Idle sound tick: only while NOT ASLEEP. Random cooldown 2-6s
	#    between playbacks. Guard against null (mobs without idle_sound like Snek).
	if _idle_sound_player != null and actual != "ASLEEP":
		_idle_sound_cooldown -= delta
		if _idle_sound_cooldown <= 0.0 and not _idle_sound_player.playing:
			_idle_sound_player.play()
			_idle_sound_cooldown = randf_range(2.0, 6.0)


func _is_blocked(world_pos: Vector2) -> bool:
	return _blocked_by_wall(world_pos) or _blocked_by_actor(world_pos)


func _blocked_by_wall(world_pos: Vector2) -> bool:
	var parent = get_parent()
	if parent == null:
		return false
	# In Marshlands, Resources (trees/ruins) block ALL
	# mobs — even those with can_pass_walls=true (snek HR). This way
	# wall phasing doesn't extend to the biome's decorative obstacles.
	# Check intentionally placed BEFORE the can_pass_walls bypass.
	if parent.get_biome() == "Marshlands" and _blocked_by_resource(world_pos, parent):
		return true
	# Per-mob bypass: snek HR (can_pass_walls=true) passes through walls. Only
	# affects this check — collision against other actors is still active.
	if can_pass_walls:
		return false
	var map = parent.Map
	if map == null:
		return false
	# half=10 -> virtual 20x20 box (2 px larger in each direction than
	# the player's 16x16). Makes enemies stop a touch further
	# from walls and not fit into narrow gaps meant only
	# for the player.
	var half := 12
	for offset in [Vector2(-half, -half), Vector2(half, -half), Vector2(-half, half), Vector2(half, half)]:
		if parent.map_is_wall(map.local_to_map(world_pos + offset)):
			return true
	return false


# Center-only point-in-polygon against Scenario. Same pattern as
# Character.gd::_laser_hits_resource: 3x3 neighborhood with offset (-2,-1,0)
# because the HR Resources' collision box extends +x/+y from the
# tile anchor. Phantom cells (source not existing in TileSet) are skipped.
func _blocked_by_resource(world_pos: Vector2, parent) -> bool:
	var sc = parent.Scenario
	if sc == null:
		return false
	var ts = sc.tile_set
	var tile_p = sc.local_to_map(world_pos)
	for dx in [-2, -1, 0]:
		for dy in [-2, -1, 0]:
			var c = tile_p + Vector2i(dx, dy)
			var sid = sc.get_cell_source_id(c)
			if sid == -1:
				continue
			if ts == null or not ts.has_source(sid):
				continue
			var data = sc.get_cell_tile_data(c)
			if data == null:
				continue
			if data.get_collision_polygons_count(0) == 0:
				continue
			var poly = data.get_collision_polygon_points(0, 0)
			if poly.size() < 3:
				continue
			var center = sc.map_to_local(c)
			if Geometry2D.is_point_in_polygon(world_pos - center, poly):
				return true
	return false


# Asymmetric blocking against other actors:
#   - vs other enemies: ACTOR_RADIUS_VS_ENEMY (8 px) — swarms can
#     compact so they all reach attack range.
#   - vs player:        ACTOR_RADIUS_VS_PLAYER (14 px) — must be less than
#     attack_range_tiles * tile_size so the enemy stops INSIDE
#     attack range.
func _blocked_by_actor(world_pos: Vector2) -> bool:
	var parent = get_parent()
	if parent == null:
		return false
	for e in parent.enemies:
		if e == null or e == self:
			continue
		if world_pos.distance_to(e.position) < ACTOR_RADIUS_VS_ENEMY:
			return true
	if parent.player != null and world_pos.distance_to(parent.player.position) < ACTOR_RADIUS_VS_PLAYER:
		return true
	return false


# True if the player is within `range_px` (raw distance, no LOS).
# For checks with LOS, call `_player_visible()` separately.
func _player_in_range(range_px: float) -> bool:
	var parent = get_parent()
	if parent == null or parent.player == null:
		return false
	return position.distance_to(parent.player.position) <= range_px


# True if there is no wall tile between the enemy and the player.
# Implementation: Bresenham over the Map grid (doesn't use RayCast2D to
# avoid the physics collisions of ALL TileSet tiles — the Map
# has physics on floors and walls alike, so a raycast with
# move_and_slide would always hit the first tile).
# Safety cap of 50 iterations in case the algorithm doesn't terminate.
func _player_visible() -> bool:
	var parent = get_parent()
	if parent == null or parent.player == null:
		return false
	var map = parent.Map
	if map == null:
		return true   # no map = no walls = visible

	var start_tile = map.local_to_map(position)
	var end_tile = map.local_to_map(parent.player.position)
	if start_tile == end_tile:
		return true   # same tile, of course they see each other

	var dx = abs(end_tile.x - start_tile.x)
	var dy = abs(end_tile.y - start_tile.y)
	var sx := 1 if start_tile.x < end_tile.x else -1
	var sy := 1 if start_tile.y < end_tile.y else -1
	var err = dx - dy
	var x = start_tile.x
	var y = start_tile.y
	var safety := 50

	while safety > 0:
		safety -= 1
		if x == end_tile.x and y == end_tile.y:
			return true
		# Doesn't check the starting tile (the enemy itself); any other
		# wall tile on the line blocks LOS.
		if Vector2i(x, y) != start_tile and parent.map_is_wall(Vector2i(x, y)):
			return false
		var e2 = 2 * err
		if e2 > -dy:
			err -= dy
			x += sx
		if e2 < dx:
			err += dx
			y += sy
	return true   # fallback: if Bresenham doesn't terminate in 50 steps, assume visible


# Special laser: beam that visibly travels from the mob's "mouth".
# Endpoint = player's position at fire-time + (laser_overshoot_tiles tiles
# in the same direction). With overshoot=0 the beam ends at the player;
# with overshoot=20 (Croakzilla) it continues 20 tiles further, hitting whatever
# is in a straight line behind. Hit-check on impact is by SEGMENT
# (not just endpoint), so any actor in the path takes damage if it's
# within laser_hit_radius of the segment. No knockback. Halved in Baby.
func _fire_special_laser(player):
	var facing := _facing_vector()
	var origin := position + facing * laser_mouth_offset
	var to_player = player.position - origin
	# Aim direction: toward the player. Fallback to facing if the player
	# is perfectly overlapping the origin (edge case).
	var aim_dir = to_player.normalized()
	if aim_dir == Vector2.ZERO:
		aim_dir = facing
	# Endpoint = player + overshoot. We don't truncate by laser_range_tiles here
	# (that variable is only the fire gate in _physics_process); here the beam
	# extends freely so the overshoot works even if the player
	# is at the edge of range.
	var overshoot_px = laser_overshoot_tiles * tile_size
	var target: Vector2 = player.position + aim_dir * overshoot_px
	_spawn_laser_beam(origin, target, player)


# Low-level beam spawner: tween a Line2D from origin to target at
# laser_speed_tiles_per_sec * speed_mult, then apply segment-based damage
# via _laser_impact and fade out. Shared by _fire_special_laser (targeted,
# speed_mult=1.0) and _fire_radial_burst (omni, speed_mult=2.0).
# player_ref is the actor the impact callback tests against — typically
# parent.player; friendly fire on other enemies is handled inside
# _laser_impact when laser_damages_enemies=true.
func _spawn_laser_beam(origin: Vector2, target: Vector2, player_ref, speed_mult: float = 1.0) -> void:
	var parent = get_parent()
	if parent == null:
		return
	var dist = origin.distance_to(target)
	# Travel time = distance / (speed * mult). Clamp to avoid division by
	# zero if laser_speed_tiles_per_sec is set to 0 by accident.
	var speed_px = max(1.0, laser_speed_tiles_per_sec * tile_size * speed_mult)
	var travel_time = dist / speed_px
	var line := Line2D.new()
	# Starts as a "point" at origin; the first tween_method extends it.
	line.points = PackedVector2Array([origin, origin])
	line.width = laser_width
	line.default_color = laser_color
	line.z_index = 1
	parent.add_child(line)
	# Tween bound to self (boss): if the boss dies mid-travel, the tween
	# dies too and the callbacks don't run. is_instance_valid in _laser_grow
	# protects against the already-freed line (e.g., scene transition).
	var tw := create_tween()
	tw.tween_method(_laser_grow.bind(line, origin, target), 0.0, 1.0, travel_time)
	tw.tween_callback(_laser_impact.bind(origin, target, player_ref))
	tw.tween_property(line, "modulate:a", 0.0, laser_fade)
	tw.tween_callback(line.queue_free)


# Starts the radial-burst special: plays the burst sound, kicks the
# light-shrink tween, and flips _radial_burst_active=true so the
# per-frame tick in _physics_process drives the 2s windup -> shoot
# -> 1s settle sequence. Called from the start-gate check; safe to
# call only when not already active.
func _start_radial_burst() -> void:
	_radial_burst_active = true
	_radial_burst_elapsed = 0.0
	_radial_burst_shot_fired = false
	# Play the burst sound (RibbitMF for Croakzilla) via a one-shot player
	# parented to the level so it survives if the boss dies mid-burst.
	if radial_burst_sound != null:
		var parent = get_parent()
		if parent != null:
			var sp := AudioStreamPlayer.new()
			sp.stream = radial_burst_sound
			sp.bus = sfx_bus
			sp.volume_db = radial_burst_sound_db
			parent.add_child(sp)
			sp.play()
			sp.finished.connect(sp.queue_free)
	# Aura shrinks to half over 1s while the boss winds up.
	_set_charge_light_mult(0.5, _RADIAL_BURST_LIGHT_TWEEN)


# Spawns _RADIAL_BURST_BEAMS beams in a full 360° fan (uniformly spaced
# at 360/N degrees apart — at N=18 that's 20°). Each beam's length is
# randf_range(d, d+3) tiles, where d = current player-to-boss distance
# in tiles. Beams travel out using the standard laser visual/damage
# pipeline (_spawn_laser_beam), so they also do friendly-fire on
# other enemies if laser_damages_enemies=true.
func _fire_radial_burst() -> void:
	var parent = get_parent()
	if parent == null:
		return
	var player_ref = parent.player
	if player_ref == null or not is_instance_valid(player_ref):
		return
	# Cap the player-distance input so a far-away player doesn't produce
	# 50+ tile beams in every direction. d is the clamped baseline; each
	# beam's randf_range(d, d+EXTRA) adds 0..3 tiles of variance on top.
	var dist_tiles_to_player: float = position.distance_to(player_ref.position) / tile_size
	var d: float = min(dist_tiles_to_player, _RADIAL_BURST_BEAM_MAX_DIST_TILES)
	var step_deg: float = 360.0 / float(_RADIAL_BURST_BEAMS)
	for i in range(_RADIAL_BURST_BEAMS):
		var angle_rad: float = deg_to_rad(i * step_deg)
		var dir := Vector2(cos(angle_rad), sin(angle_rad))
		var length_tiles: float = randf_range(d, d + _RADIAL_BURST_BEAM_EXTRA_TILES)
		var origin: Vector2 = position + dir * laser_mouth_offset
		var target: Vector2 = origin + dir * length_tiles * tile_size
		_spawn_laser_beam(origin, target, player_ref, _RADIAL_BURST_BEAM_SPEED_MULT)


# Starts the heal-attack special: applies the heal one-shot (ceil of
# heal_attack_heal_percent * max_health) and kicks the green flash_heal
# tween across the duration. _physics_process drives the 1s freeze and
# resets the cooldown when it ends. set_health clamps internally so
# overshoot past max_health is safe.
func _start_heal_attack() -> void:
	_heal_attack_active = true
	_heal_attack_time_left = heal_attack_duration
	var heal_amount: int = int(ceil(max_health * heal_attack_heal_percent))
	set_health(health + heal_amount)
	if has_node("HealthBar"):
		var bar = $HealthBar
		bar.value = health
		bar.visible = true
	_flash_heal(heal_attack_duration)


# Green heal flash on the enemy's AnimatedSprite2D — same shader recipe
# as Character.flash_heal (boss-room arrival): tint flash_color to green,
# pop flash=0.6 + modulate=light green, then tween both back to neutral
# across `duration`. Restores flash_color to white at the end so it
# doesn't contaminate the white _flash_damage pop. No-op if the mob
# doesn't have a ShaderMaterial on its AnimatedSprite2D (it always does
# in _ready, but null-checked for safety).
func _flash_heal(duration: float = 1.0) -> void:
	if not has_node("AnimatedSprite2D"):
		return
	var sprite := $AnimatedSprite2D
	var mat := sprite.material as ShaderMaterial
	if mat == null:
		return
	mat.set_shader_parameter("flash_color", Color(0.4, 1.6, 0.4, 1))
	mat.set_shader_parameter("flash", 0.6)
	sprite.modulate = Color(0.7, 1.6, 0.7, 1)
	var tw := create_tween()
	tw.tween_property(mat, "shader_parameter/flash", 0.0, duration)
	tw.parallel().tween_property(sprite, "modulate", Color.WHITE, duration)
	tw.tween_callback(func(): mat.set_shader_parameter("flash_color", Color(1, 1, 1, 1)))


# tween_method callback: extends the second point of the Line2D from origin
# toward target as t goes from 0 to 1. Guards against freed line.
func _laser_grow(t: float, line: Line2D, origin: Vector2, target: Vector2) -> void:
	if not is_instance_valid(line):
		return
	line.points = PackedVector2Array([origin, origin.lerp(target, t)])


# Callback at the moment of beam impact. SEGMENT hit-check (not just
# endpoint) — any actor whose current position is <= laser_hit_radius
# from the origin→target segment takes damage. This covers the overshoot case:
# the player can be hit even if the endpoint is 20 tiles behind them.
# Also applies friendly-fire to other enemies if laser_damages_enemies.
# Particles at the endpoint or, if there were hits, at each hit position.
func _laser_impact(origin: Vector2, target: Vector2, player) -> void:
	var parent = get_parent()
	if parent == null:
		return
	var hit_positions: Array[Vector2] = []
	# Player vs beam segment. 6 px push (consistent with the default
	# KNOCKBACK_DISTANCE of Enemy attacks; the beam pushes slightly on graze).
	if player != null and is_instance_valid(player):
		if _distance_point_to_segment(player.position, origin, target) <= laser_hit_radius:
			hit_positions.append(player.position)
			# Let Character.damage handle Baby halving via the ignore_baby_halve
			# param. For bosses (triggers_win=true), no halving happens at all
			# (full damage on Baby). Previously this code halved `dmg` too,
			# which combined with Character's halving = 0.25x on Baby (bug).
			player.damage(laser_damage, target, _source_name(), 6.0, triggers_win)
	# Friendly fire vs other enemies in parent.enemies (excluding self).
	# Damage via Enemy.damage(amount, from) — from = target so the
	# victim's knockback is in the direction of the beam.
	if laser_damages_enemies and parent.get("enemies") != null:
		for e in parent.enemies:
			if e == null or e == self or not is_instance_valid(e):
				continue
			if _distance_point_to_segment(e.position, origin, target) <= laser_hit_radius:
				hit_positions.append(e.position)
				e.damage(laser_damage, target)
	# Particles: one per hit (clear feedback of who got hit), or a
	# small one at the endpoint if there were no hits ("successful dodge" / beam into the void).
	if hit_positions.is_empty():
		_spawn_laser_impact_particles(target, false)
	else:
		for hp in hit_positions:
			_spawn_laser_impact_particles(hp, true)


# Minimum perpendicular distance from point `p` to the line segment a→b.
# If the projection falls outside the segment, returns the distance to the
# nearest endpoint. Used by the beam hit-check.
func _distance_point_to_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab = b - a
	var len_sq = ab.length_squared()
	if len_sq == 0.0:
		return p.distance_to(a)
	var t = clamp((p - a).dot(ab) / len_sq, 0.0, 1.0)
	var closest = a + ab * t
	return p.distance_to(closest)


# Particle burst at the laser impact point. Higher amount on
# real hit for clear visual feedback. Color = laser_color (Croakzilla green).
# Added to the boss's parent (Level/BossRoom) so it survives the boss's
# queue_free if the boss dies during travel.
func _spawn_laser_impact_particles(at: Vector2, hit: bool) -> void:
	var parent = get_parent()
	if parent == null:
		return
	var p := CPUParticles2D.new()
	p.position = at
	p.one_shot = true
	p.explosiveness = 1.0
	p.amount = 28 if hit else 10
	p.lifetime = 0.35
	p.spread = 180.0
	p.initial_velocity_min = 40.0
	p.initial_velocity_max = 120.0
	p.scale_amount_min = 1.0
	p.scale_amount_max = 3.0
	p.color = laser_color
	p.z_index = 1
	p.emitting = true
	parent.add_child(p)
	var tw := p.create_tween()
	tw.tween_interval(p.lifetime + 0.1)
	tw.tween_callback(p.queue_free)


# Per-difficulty multiplier for the charge-attack WINDUP only. The
# dash itself runs at full duration on every difficulty (so the
# attack still lands with weight on Baby). Cooldown is also unscaled
# — Baby just gets a shorter telegraph.
# Baby: 0.5 (windup 3s -> 1.5s). Others: 1.0.
func _charge_baby_mult() -> float:
	return 0.5 if GameState.difficulty == "Baby" else 1.0


# Effective speed multiplier for the charge DASH velocity. On Baby the
# dash gets an extra 1.5x on top of the inspector charge_attack_speed_mult.
# Net dash speed on Baby = speed (already halved by baby_speed_mult)
# * PERSECUTOR_MULT (2.0) * charge_attack_speed_mult (2.0) * 1.5 — so the
# dash feels meaningful despite the slower base speed.
const _CHARGE_DASH_BABY_BONUS: float = 1.5

func _charge_dash_speed_mult() -> float:
	if GameState.difficulty == "Baby":
		return charge_attack_speed_mult * _CHARGE_DASH_BABY_BONUS
	return charge_attack_speed_mult


# Tweens the cached PointLight2D's texture_scale to `mult` * base over
# `duration` seconds. Per-transition timing: slow gather, snap burst,
# medium cool-down. No-op for mobs without a PointLight2D (most enemies).
# Kills any in-flight tween first so transitions don't fight each other.
func _set_charge_light_mult(mult: float, duration: float = 0.2) -> void:
	if _point_light == null:
		return
	if _point_light_tween != null and _point_light_tween.is_valid():
		_point_light_tween.kill()
	var target_scale: float = _point_light_base_scale * mult
	_point_light_tween = create_tween()
	_point_light_tween.tween_property(_point_light, "texture_scale", target_scale, duration)


# Two-step finale tween for the radial-burst aura: first expand to
# _RADIAL_BURST_LIGHT_BURST_MULT × base over _RADIAL_BURST_LIGHT_BURST
# seconds, then ease back to base over _RADIAL_BURST_LIGHT_RETURN seconds.
# Reuses _point_light_tween so the windup-shrink tween (if somehow still
# running) gets killed first; the two `tween_property` calls run
# sequentially on the same Tween (default = sequential, not parallel).
# No-op for mobs without a PointLight2D.
func _radial_burst_light_finale() -> void:
	if _point_light == null:
		return
	if _point_light_tween != null and _point_light_tween.is_valid():
		_point_light_tween.kill()
	var burst_scale: float = _point_light_base_scale * _RADIAL_BURST_LIGHT_BURST_MULT
	var base_scale: float = _point_light_base_scale
	_point_light_tween = create_tween()
	_point_light_tween.tween_property(_point_light, "texture_scale", burst_scale, _RADIAL_BURST_LIGHT_BURST)
	_point_light_tween.tween_property(_point_light, "texture_scale", base_scale, _RADIAL_BURST_LIGHT_RETURN)


# Cardinal vector of the mob's current facing, derived from last_move (which is
# set from _face and from _update_animation). Used to offset the
# laser's origin toward the mob's "mouth".
func _facing_vector() -> Vector2:
	match last_move:
		"Up_Idle": return Vector2.UP
		"Down_Idle": return Vector2.DOWN
		"Izq_Idle": return Vector2.LEFT
		"Der_Idle": return Vector2.RIGHT
		_: return Vector2.DOWN


# Sets `last_move` so the next _update_animation plays the
# animation (Idle/Atk/Damage) toward the correct side of the target.
func _face(target_pos: Vector2):
	var dx = target_pos.x - position.x
	var dy = target_pos.y - position.y
	if abs(dx) >= abs(dy):
		last_move = "Der_Idle" if dx > 0 else "Izq_Idle"
	else:
		last_move = "Down_Idle" if dy > 0 else "Up_Idle"


# Dominant velocity axis decides _Move; when idle prioritizes attack > damage > idle.
func _update_animation():
	if velocity != Vector2.ZERO:
		if abs(velocity.x) > abs(velocity.y):
			if velocity.x > 0:
				last_move = "Der_Idle"
				$AnimatedSprite2D.play("Der_Move")
			else:
				last_move = "Izq_Idle"
				$AnimatedSprite2D.play("Izq_Move")
		else:
			if velocity.y > 0:
				last_move = "Down_Idle"
				$AnimatedSprite2D.play("Down_Move")
			else:
				last_move = "Up_Idle"
				$AnimatedSprite2D.play("Up_Move")
		return

	if not attack_timer.is_stopped():
		$AnimatedSprite2D.play(last_move.replace("_Idle", "_Atk"))
	elif not damage_timer.is_stopped():
		$AnimatedSprite2D.play(last_move.replace("_Idle", "_Damage"))
	else:
		$AnimatedSprite2D.play(last_move)
