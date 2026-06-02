extends CharacterBody2D

#######################################################
### CHARACTER (Croakzilla, real time):             ####
### CharacterBody2D + move_and_slide().            ####
### The turn-based system and grid-snapped tweens  ####
### were removed; now velocity is built every      ####
### physics_frame from input or from the           ####
### click-to-move path.                            ####
#######################################################

signal health_updated(health, max_health)
signal killed

@onready var cam = $Camera2D
@onready var damage_timer = $DamageTimer
@onready var attack_timer = $AttackTimer

@export var max_health: float = 100
# tiles per second. speed=3 ~= 96 px/s. Increase to run faster.
@export var speed: float = 6.0

var attack = 5

@onready var health: float = max_health

var play_mode = false
var tile_size = 32
var last_move = "Down_Idle"

# Cardinal directions for input. Diagonals come from the sum.
var inputs := {
	"ui_up": Vector2.UP,
	"ui_down": Vector2.DOWN,
	"ui_right": Vector2.RIGHT,
	"ui_left": Vector2.LEFT,
}

# Path calculated by LevelBase.ask_path() for click-to-move. The setter removes
# the first waypoint (which normally coincides with the player's current position).
var path: PackedVector2Array = PackedVector2Array():
	set(value):
		path = value
		if path.size() > 0:
			path.remove_at(0)


func _ready():
	$AnimatedSprite2D.speed_scale = 1.5
	# Y-sort so the player is ordered by Y relative to enemies
	# (top-down rendering: actor with higher Y is drawn on top).
	y_sort_enabled = true
	# Own material (not shared between ACTORS) so the damage flash
	# only affects this player and doesn't tint all actors at once. The
	# same material IS reused between the body sprite and the gun
	# overlay sprite of the same player — that way both flash in lockstep.
	var mat := ShaderMaterial.new()
	mat.shader = load("res://assets/shaders/flash.gdshader")
	$AnimatedSprite2D.material = mat
	$GunOverlay.sprite_frames = _build_gun_overlay_frames()
	$GunOverlay.speed_scale = 1.5
	$GunOverlay.material = mat
	# "player" group: used by HungerMenu to find the player when
	# ticking starvation damage without having to walk the tree manually.
	add_to_group("player")
	# Laser SFX: persistent AudioStreamPlayer on "SFX" bus with pitch x2.
	# Reused by every shot (Godot's play() cancels the previous playback
	# if the sound hasn't finished yet — acceptable for short shots).
	_laser_sfx_player = AudioStreamPlayer.new()
	_laser_sfx_player.stream = LASER_SFX
	_laser_sfx_player.bus = &"SFX"
	_laser_sfx_player.pitch_scale = 3.0
	_laser_sfx_player.volume_db = -6.0
	add_child(_laser_sfx_player)
	# Difficulty: on "This doesn't make any sense" all actors
	# move at 1.5x. Applied in-place over the player's @export.
	if GameState.difficulty == "This doesn't make any sense":
		speed *= 1.5


# Clones the body's (player) SpriteFrames creating parallel AtlasTextures
# that point to the overlay PNG. The overlay sheet has exactly the same
# layout as Player.png, so reusing the same `region` rects gives the
# correct weapon frame for each body frame. Done at runtime so we don't
# have to maintain 43 duplicated SubResources in Character.tscn.
func _build_gun_overlay_frames() -> SpriteFrames:
	var overlay_tex: Texture2D = load("res://assets/sprites/Player_Gun_Overlay.png")
	var src: SpriteFrames = $AnimatedSprite2D.sprite_frames
	var out := SpriteFrames.new()
	# SpriteFrames starts with a "default" animation that we don't want.
	if out.has_animation(&"default"):
		out.remove_animation(&"default")
	for anim in src.get_animation_names():
		out.add_animation(anim)
		out.set_animation_speed(anim, src.get_animation_speed(anim))
		out.set_animation_loop(anim, src.get_animation_loop(anim))
		for i in src.get_frame_count(anim):
			var src_tex := src.get_frame_texture(anim, i) as AtlasTexture
			var dur := src.get_frame_duration(anim, i)
			var dst_tex := AtlasTexture.new()
			dst_tex.atlas = overlay_tex
			if src_tex != null:
				dst_tex.region = src_tex.region
				dst_tex.margin = src_tex.margin
				dst_tex.filter_clip = src_tex.filter_clip
			out.add_frame(anim, dst_tex, dur)
	return out


# Plays the same animation on the body sprite and the gun overlay.
# AnimatedSprite2D.play() is a no-op if the animation is already playing, so
# calling it every physics tick costs nothing and keeps both in sync.
func _play_anim(anim: String) -> void:
	$AnimatedSprite2D.play(anim)
	$GunOverlay.play(anim)


# Name of the source of the last damage applied (gated by damage_timer).
# Used in kill() to build the GameOver message. "" or "hunger" =
# death by hunger/test damage; any other string is the mob's name.
var _last_damage_source: String = ""


############### Health

func connect_lifebar():
	var lifebar = get_parent().get_parent().get_node("CanvasMenu").get_node("ControlMenu").get_node("LifeMenu")
	health_updated.connect(lifebar._on_Character_health_updated)


func damage(amount, from: Vector2 = Vector2.ZERO, source_name: String = "", knockback_distance: float = KNOCKBACK_DISTANCE, ignore_baby_halve: bool = false):
	if damage_timer.is_stopped():
		damage_timer.start()
		# We save the source ONLY if the damage is applied (post-gate). That way the
		# GameOver message reflects the last real hit, not attempts
		# rejected by i-frames.
		_last_damage_source = source_name
		_apply_knockback(from, knockback_distance)
		# Difficulty scaling on the damage taken by the player:
		#   - Baby: damage * 0.5, UNLESS ignore_baby_halve=true (passed by
		#     bosses like Croakzilla — `triggers_win=true` mobs deal full
		#     damage on Baby so the boss isn't a pushover even on easy mode).
		#   - Nonsense: damage * 2 (always)
		#   - Hell: damage * 2 only if the source is a boss room enemy
		#     (player's parent is BossRoom — the subclass override
		#     is_boss_room() returns true).
		var d = GameState.difficulty
		if d == "Baby" and not ignore_baby_halve:
			amount = amount * 0.5
		elif d == "This doesn't make any sense":
			amount = amount * 2
		elif d == "Hell":
			var p = get_parent()
			if p != null and p.has_method("is_boss_room") and p.is_boss_room():
				amount = amount * 2
		# Shield reduction: each shield point (normal +1, elite +2) trims
		# 1 from the incoming amount. Floor of 1, every hit always
		# does at least 1 damage, regardless of shield total.
		var shield := get_total_shield()
		if shield > 0:
			amount = max(1, amount - shield)
		set_health(health - amount)
		if health > 0:
			_flash_damage()


# Pushes `distance` px in the opposite direction of the damage source. Uses the
# same slide-per-axis pattern as manual movement: if the target is
# blocked (wall or another actor), it tries moving only on x or only on y. from
# == ZERO is treated as "unknown source" and doesn't push (e.g. debug KEY_T,
# hunger tick). KNOCKBACK_DISTANCE is the default for damage() if the caller
# doesn't pass a value — mobs override it via @export attack_knockback.
const KNOCKBACK_DISTANCE: float = 10.0

func _apply_knockback(from: Vector2, distance: float = KNOCKBACK_DISTANCE):
	if from == Vector2.ZERO:
		return
	var dir = (position - from).normalized()
	if dir == Vector2.ZERO:
		return  # actor and source perfectly overlapping — no direction
	var displacement = dir * distance
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


# Pop sprite to pure white (via flash.gdshader), hold one frame, fade out.
# The tween auto-binds to self, so if the node dies mid-flash it doesn't crash.
func _flash_damage():
	var mat := $AnimatedSprite2D.material as ShaderMaterial
	if mat == null:
		return
	mat.set_shader_parameter("flash", 1.0)
	var tw = create_tween()
	tw.tween_interval(0.02)
	tw.tween_property(mat, "shader_parameter/flash", 0.0, 0.05)


# Green heal flash + pseudo-glow for `duration` s (boss room arrival).
# Combines two effects:
#   - Shader tint: green flash_color with G>1 and flash=0.5 (tint over the
#     sprite's silhouette).
#   - Modulate boost: modulate G>1 multiplies the shader output →
#     saturates the green even more and increases the brightness feel inside
#     the silhouette. (A real "glow" that goes beyond the silhouette requires
#     PointLight2D or a sprite-copy with additive blending — out of scope.)
# Both fade in parallel to neutral WHITE. At the end it restores flash_color
# to white so it doesn't contaminate the next damage flash, which assumes default.
func flash_heal(duration: float = 0.5):
	var sprite := $AnimatedSprite2D
	var overlay := $GunOverlay
	var mat := sprite.material as ShaderMaterial
	if mat == null:
		return
	# The shader material is shared body+gun (see _ready), so setting
	# flash_color/flash once tints both. modulate is per-Node2D, so
	# it's applied and tweened in parallel on each one.
	mat.set_shader_parameter("flash_color", Color(0.4, 1.6, 0.4, 1))
	mat.set_shader_parameter("flash", 0.6)
	sprite.modulate = Color(0.7, 1.6, 0.7, 1)
	overlay.modulate = Color(0.7, 1.6, 0.7, 1)
	var tw = create_tween()
	tw.tween_property(mat, "shader_parameter/flash", 0.0, duration)
	tw.parallel().tween_property(sprite, "modulate", Color.WHITE, duration)
	tw.parallel().tween_property(overlay, "modulate", Color.WHITE, duration)
	tw.tween_callback(func(): mat.set_shader_parameter("flash_color", Color(1, 1, 1, 1)))


func attack_enemy(enemy):
	enemy.damage(attack, position)


################# Shooting (laser hitscan)

# Constants. Tunable if it hits too weakly or too far.
# Laser stats. They were `const` before the Prize/buffs system — now
# they're mutable `var` because apply_prize_buff() multiplies/increments
# them in-place. The uppercase is kept for minimal diff vs legacy
# code, even though they're no longer strict constants.
var LASER_DAMAGE: int = 5
var LASER_RANGE: float = 400.0       # px ~ 12.5 tiles
var LASER_HIT_RADIUS: float = 8.0    # effective half-thickness of the beam (px)
const LASER_FADE: float = 0.15         # s; duration of the visual fade
const LASER_STEP_PX: float = 4.0       # sample step for wall clipping
const LASER_IMPACT_GRAVITY_Y: float = -300.0  # px/s² upward on real impact
# Base values used to scale the laser visual proportional to the
# current LASER_HIT_RADIUS. The wider20/wider30 buffs mutate LASER_HIT_RADIUS
# in-place (×1.2 / ×1.3 per stack); the Line2D width and the particle
# burst `amount` grow with the same proportion (radius / radius_base).
const LASER_HIT_RADIUS_BASE: float = 8.0
const LASER_LINE_WIDTH_BASE: float = 3.0
const LASER_PARTICLES_BASE: int = 16
const LASER_SFX = preload("res://assets/Sounds/Effects/Laser.ogg")
var _laser_sfx_player: AudioStreamPlayer = null

# Prize/buff stacks. Each buff type caps at BUFF_MAX_STACKS. apply_prize_buff
# increments the counter AND applies the effect on LASER_DAMAGE / LASER_RANGE
# / LASER_HIT_RADIUS / AmmoMenu.recharge_interval in-place.
const BUFF_MAX_STACKS := 2
var buff_range_stacks: int = 0      # N1: +20% range
var buff_dmg_stacks: int = 0        # N2: +1 damage
var buff_wider_stacks: int = 0      # N3: +20% wider impact
var buff_speed_stacks: int = 0      # N4: +10% speed (player only)
var buff_shield_stacks: int = 0     # N5: +1 shield (incoming dmg reducer)
var buff_e_range_stacks: int = 0    # E1: +30% range, +2 damage
var buff_e_wider_stacks: int = 0    # E2: +30% wider, +2 damage
var buff_e_ammo_stacks: int = 0     # E3: x2 ammo recharge, +2 damage
var buff_e_shield_stacks: int = 0   # E4: +2 shield, +1 damage
# Pickup radius for floor prizes. tile_size/2 + some margin.
const PRIZE_PICKUP_RADIUS: float = 20.0


# 1) clip endpoint to the first wall (sample in steps of LASER_STEP_PX),
# 2) find the first enemy with perpendicular distance to the segment <=
#    LASER_HIT_RADIUS, the one with smallest t wins (closest to the player). The
#    segment is truncated to that enemy ("destroyed on collision"),
# 3) apply damage + spawn of the visual Line2D with fade.
func _shoot_laser():
	var parent = get_parent()
	if parent == null:
		return
	# Spend 1 ammo. If it's empty, it doesn't shoot (no sound, no visual).
	# consume() resets the recharge delay internally.
	var ammo_menu = _get_ammo_menu()
	if ammo_menu == null or not ammo_menu.consume(1):
		return
	# Shot SFX. play() cancels previous playback (no overlap) —
	# OK because the sample is short + pitch_scale=2 makes it shorter.
	if _laser_sfx_player != null:
		_laser_sfx_player.play()
	var origin = position
	# Direction depends on GameState.beam_mode (chosen in BeamModeSelect):
	#   - "fixed"  (default / legacy): along the player's last cardinal
	#              facing (last_move). No diagonals because the animation
	#              set only has 4 cardinals — the sprite would face wrong
	#              for off-cardinal shots.
	#   - "cursor" (free-aim): toward the global mouse position. Restores
	#              the original Godot-3-era behavior. The sprite stays
	#              cardinal for the closest match; only the beam goes
	#              diagonal.
	var dir: Vector2
	if GameState.beam_mode == "cursor":
		dir = (get_global_mouse_position() - origin).normalized()
		if dir == Vector2.ZERO:
			# Edge case: mouse exactly on the player → fall back to facing.
			match last_move:
				"Up_Idle": dir = Vector2.UP
				"Down_Idle": dir = Vector2.DOWN
				"Izq_Idle": dir = Vector2.LEFT
				"Der_Idle": dir = Vector2.RIGHT
				_: dir = Vector2.DOWN
		else:
			# Face the cursor (closest cardinal) so the sprite turns to
			# look where it's shooting. Mirrors the click-attack facing
			# logic at the punch handler. If the player is moving,
			# _update_animation will overwrite last_move from velocity
			# next physics frame — moving-and-shooting still shows the
			# move animation, not the cursor-facing one.
			if abs(dir.x) >= abs(dir.y):
				last_move = "Der_Idle" if dir.x > 0 else "Izq_Idle"
			else:
				last_move = "Down_Idle" if dir.y > 0 else "Up_Idle"
	else:
		match last_move:
			"Up_Idle": dir = Vector2.UP
			"Down_Idle": dir = Vector2.DOWN
			"Izq_Idle": dir = Vector2.LEFT
			"Der_Idle": dir = Vector2.RIGHT
			_: dir = Vector2.DOWN

	var max_endpoint = origin + dir * LASER_RANGE
	var endpoint = _laser_find_endpoint(origin, max_endpoint)
	# If the clip moved the endpoint, there was an obstacle (wall in NW, scenery in HR).
	# is_equal_approx to tolerate sample step rounding.
	var hit_obstacle = not endpoint.is_equal_approx(max_endpoint)

	var hit_enemy = null
	var hit_t = INF
	var seg = endpoint - origin
	var seg_len_sq = seg.length_squared()
	for e in parent.enemies:
		if e == null:
			continue
		var t = 0.0
		if seg_len_sq > 0.0:
			t = clamp((e.position - origin).dot(seg) / seg_len_sq, 0.0, 1.0)
		var closest = origin + seg * t
		# Per-mob body_hit_radius_mult lets bosses (Croakzilla, 64×64) have
		# a larger laser-target box than the base 8 px. Default 1.0 = no
		# change for regular mobs.
		var mult: float = 1.0
		if e.get("body_hit_radius_mult") != null:
			mult = e.body_hit_radius_mult
		if e.position.distance_to(closest) <= LASER_HIT_RADIUS * mult:
			if t < hit_t:
				hit_t = t
				hit_enemy = e

	if hit_enemy != null:
		endpoint = origin + seg * hit_t
		hit_enemy.damage(LASER_DAMAGE, origin)

	_spawn_laser_visual(origin, endpoint)
	# Particles always at the endpoint. On real impact, they rise (inverted
	# gravity) instead of falling with default gravity. Fizzle into the void
	# uses default gravity.
	_spawn_impact_particles(endpoint, hit_obstacle or hit_enemy != null)


# Sample in steps of LASER_STEP_PX from origin towards endpoint. The
# "obstacle" criterion depends on the biome:
#   - Marshlands: blocks ONLY against the collision polygons of the
#     Scenario tiles (not against walls — walls are passable, a biome
#     feature). Collision uses the real TileData polygon, which in HR
#     is ~64x64 and overflows to the +x/+y neighbor; see _laser_hits_resource.
#   - Rest: blocks on Map wall tiles (terrain == 1 or empty tile).
# Returns the last free point before the first hit, or endpoint if the
# trajectory is clean. Implicit cap: total_len <= LASER_RANGE ⇒ <=100
# iterations per shot.
func _laser_find_endpoint(origin: Vector2, endpoint: Vector2) -> Vector2:
	var parent = get_parent()
	if parent == null:
		return endpoint
	var is_hr = parent.get_biome() == "Marshlands"
	var map = parent.Map
	var sc = parent.Scenario
	var total_len = origin.distance_to(endpoint)
	if total_len == 0.0:
		return endpoint
	var step_dir = (endpoint - origin) / total_len
	var traveled = 0.0
	var last_good = origin
	while traveled <= total_len:
		var p = origin + step_dir * traveled
		if is_hr:
			if sc != null and _laser_hits_resource(p, sc):
				return last_good
		else:
			if map != null and parent.map_is_wall(map.local_to_map(p)):
				return last_good
		last_good = p
		traveled += LASER_STEP_PX
	return endpoint


# True if p falls inside the collision polygon of some nearby Scenario
# tile. Uses the real TileData polygon (doesn't assume size/shape), but
# searches only in the relevant neighborhood: in HR the Resources have
# ~64x64 collision that extends +x/+y from the tile's anchor (see
# assets/Marshlands/Resources.tres — polygon goes from (-16,-16) to (48,48)
# relative to the center). That's why a point p can be inside the polygon
# of a tile whose anchor is up to 2 tiles up or to the left.
func _laser_hits_resource(p: Vector2, sc: TileMapLayer) -> bool:
	var tile_p = sc.local_to_map(p)
	var ts = sc.tile_set
	for dx in [-2, -1, 0]:
		for dy in [-2, -1, 0]:
			var c = tile_p + Vector2i(dx, dy)
			# Guard against "phantom cells": Level.gd paints scenery with
			# source_id ∈ {0,1,2,3} for all biomes, but HR's
			# Resources.tres only defines source 0. Cells with
			# source 1/2/3 are stored but with no atlas behind them.
			# get_cell_tile_data() spams "No TileSet atlas source with id N"
			# in those cases, so we filter first by has_source().
			var sid = sc.get_cell_source_id(c)
			if sid == -1:
				continue  # empty cell
			if ts == null or not ts.has_source(sid):
				continue  # phantom — source doesn't exist in this biome
			var data = sc.get_cell_tile_data(c)
			if data == null:
				continue
			if data.get_collision_polygons_count(0) == 0:
				continue
			var poly = data.get_collision_polygon_points(0, 0)
			if poly.size() < 3:
				continue
			# Polygon coords are relative to the tile center.
			var center = sc.map_to_local(c)
			if Geometry2D.is_point_in_polygon(p - center, poly):
				return true
	return false


# Line2D added to the player's parent (not to self) so it doesn't move with the
# actor. Tween bound to the line itself: if the player is freed mid-fade
# (level transition), the tween dies with the line and doesn't touch a freed node.
func _spawn_laser_visual(from: Vector2, to: Vector2):
	var line = Line2D.new()
	line.points = PackedVector2Array([from, to])
	# Width proportional to the current radius. Default 3 px with radius 8; with
	# full wider stacks (1.2^2 * 1.3^2 = roughly 2.43x), the beam looks 7.3 px. approx.
	line.width = LASER_LINE_WIDTH_BASE * LASER_HIT_RADIUS / LASER_HIT_RADIUS_BASE
	line.default_color = Color(1, 1, 0, 1)
	line.z_index = 1
	get_parent().add_child(line)
	var tw = line.create_tween()
	tw.tween_property(line, "modulate:a", 0.0, LASER_FADE)
	tw.tween_callback(line.queue_free)


# Burst of yellow particles at the beam's endpoint. One-shot, full circle,
# lifetime 0.1s. rises=true → inverted gravity so particles
# float upward (impact). rises=false → default gravity = they fall a
# bit (fizzle into the void).
func _spawn_impact_particles(at: Vector2, rises: bool = false):
	var p = CPUParticles2D.new()
	p.position = at
	p.one_shot = true
	p.explosiveness = 1.0       # all emission at t=0
	# Amount proportional to the current radius: default 16 with radius 8; with
	# full wider stacks it goes up to 39 particles. max(1, ...) to avoid ending
	# at 0 if someone sets radius very low.
	p.amount = max(1, int(round(LASER_PARTICLES_BASE * LASER_HIT_RADIUS / LASER_HIT_RADIUS_BASE)))
	p.lifetime = 0.1
	p.spread = 180.0            # full 360 degree cone
	p.initial_velocity_min = 40.0
	p.initial_velocity_max = 80.0
	p.scale_amount_min = 1.0
	p.scale_amount_max = 2.0
	p.color = Color(1, 1, 0, 1)
	p.z_index = 1               # above actors, below Fog (z=2)
	if rises:
		p.gravity = Vector2(0, LASER_IMPACT_GRAVITY_Y)
	p.emitting = true
	get_parent().add_child(p)
	# Free after the burst finishes. lifetime + a short buffer to
	# absorb the spawn frame and avoid cutting live particles.
	var tw = p.create_tween()
	tw.tween_interval(p.lifetime + 0.05)
	tw.tween_callback(p.queue_free)


# Applies the identified buff if its stack count < BUFF_MAX_STACKS. Returns
# true if applied, false if maxed. Called from Prize.apply_buff;
# Prize tries sequentially from the pool until it finds one that isn't maxed.
func apply_prize_buff(buff_id: String) -> bool:
	var applied: bool = false
	match buff_id:
		"range20":
			if buff_range_stacks < BUFF_MAX_STACKS:
				buff_range_stacks += 1
				LASER_RANGE *= 1.2
				applied = true
		"dmg1":
			if buff_dmg_stacks < BUFF_MAX_STACKS:
				buff_dmg_stacks += 1
				LASER_DAMAGE += 1
				applied = true
		"wider20":
			if buff_wider_stacks < BUFF_MAX_STACKS:
				buff_wider_stacks += 1
				LASER_HIT_RADIUS *= 1.2
				applied = true
		"speed10":
			if buff_speed_stacks < BUFF_MAX_STACKS:
				buff_speed_stacks += 1
				speed *= 1.1
				applied = true
		"shield1":
			# Normal buff: +1 shield. Each shield point reduces every
			# enemy damage hit by 1, with a floor of 1 (so the player
			# always takes at least 1 damage from any hit).
			if buff_shield_stacks < BUFF_MAX_STACKS:
				buff_shield_stacks += 1
				applied = true
		"range30_dmg2":
			if buff_e_range_stacks < BUFF_MAX_STACKS:
				buff_e_range_stacks += 1
				LASER_RANGE *= 1.3
				LASER_DAMAGE += 2
				applied = true
		"wider30_dmg2":
			if buff_e_wider_stacks < BUFF_MAX_STACKS:
				buff_e_wider_stacks += 1
				LASER_HIT_RADIUS *= 1.3
				LASER_DAMAGE += 2
				applied = true
		"ammo2x_dmg2":
			if buff_e_ammo_stacks < BUFF_MAX_STACKS:
				buff_e_ammo_stacks += 1
				LASER_DAMAGE += 2
				var ammo = _get_ammo_menu()
				if ammo != null:
					ammo.recharge_interval = ammo.recharge_interval / 2.0
				applied = true
		"shield2_dmg1":
			# Elite buff: +2 shield, +1 damage per stack.
			if buff_e_shield_stacks < BUFF_MAX_STACKS:
				buff_e_shield_stacks += 1
				LASER_DAMAGE += 1
				applied = true
	if applied:
		_refresh_buffs_label()
	return applied


# Sum of normal buff stacks (N1-N5). Used by Enemy.kill to
# halve drop_chance if the player has already accumulated >2 normals — the drop
# rate is cut in half so normals don't flood the inventory.
func get_normal_buff_count() -> int:
	return buff_range_stacks + buff_dmg_stacks + buff_wider_stacks + buff_speed_stacks + buff_shield_stacks


# Total shield amount: each normal "shield1" stack = +1, each elite
# "shield2_dmg1" stack = +2. Cap is 2 stacks per buff (BUFF_MAX_STACKS),
# so the maximum possible shield is 2*1 + 2*2 = 6. Subtracted from
# incoming enemy damage with a floor of 1.
func get_total_shield() -> int:
	return buff_shield_stacks + buff_e_shield_stacks * 2


# Builds multi-line text for the BuffsLabel (bottom-right). Combines
# normal + elite by effect category:
#   - damage: dmg1 (+1 each) + any elite (+2 each)
#   - range: pow(1.2, N) * pow(1.3, E) — multiplicative between stacks
#   - radius (wider): same pattern as range
#   - ammo: 2^E — each elite stack divides interval by 2 = 2x faster
#   - speed: pow(1.1, N) — only normal for now
# Returns "" if there are no active buffs (label effectively invisible).
func get_active_buffs_text() -> String:
	var lines: PackedStringArray = []
	# Damage: +1 per N2 (dmg1), +2 per E1/E2/E3, +1 per E4 (shield2_dmg1).
	var dmg_bonus = buff_dmg_stacks + (buff_e_range_stacks + buff_e_wider_stacks + buff_e_ammo_stacks) * 2 + buff_e_shield_stacks
	if dmg_bonus > 0:
		lines.append("+%d damage" % dmg_bonus)
	var range_mult = pow(1.2, buff_range_stacks) * pow(1.3, buff_e_range_stacks)
	if range_mult > 1.0:
		lines.append("+%d%% range" % int(round((range_mult - 1.0) * 100)))
	var wider_mult = pow(1.2, buff_wider_stacks) * pow(1.3, buff_e_wider_stacks)
	if wider_mult > 1.0:
		lines.append("+%d%% radius" % int(round((wider_mult - 1.0) * 100)))
	if buff_e_ammo_stacks > 0:
		lines.append("x%d ammo recharge" % int(pow(2, buff_e_ammo_stacks)))
	var speed_mult = pow(1.1, buff_speed_stacks)
	if speed_mult > 1.0:
		lines.append("+%d%% speed" % int(round((speed_mult - 1.0) * 100)))
	# Shield: each point cuts 1 from incoming damage (min 1 per hit).
	var shield_total = get_total_shield()
	if shield_total > 0:
		lines.append("+%d shield" % shield_total)
	return "\n".join(lines)


# Finds the BuffsLabel and refreshes its text. Called at the end of
# apply_prize_buff when a new buff is applied.
func _refresh_buffs_label():
	var parent = get_parent()
	if parent == null:
		return
	var main = parent.get_parent()
	if main == null:
		return
	var lbl = main.get_node_or_null("CanvasMenu/ControlMenu/BuffsLabel")
	if lbl != null:
		lbl.text = get_active_buffs_text()


# Every physics tick iterates over parent.prizes and consumes the ones within
# PRIZE_PICKUP_RADIUS. Much cheaper than Area2D because there are few
# simultaneous prizes (~1-10) and the check is trivial O(N). apply_buff
# returns false if the rolled buff is maxed — but the prize is
# consumed anyway (it's freed and doesn't come back).
func _check_prize_pickup():
	var parent = get_parent()
	if parent == null:
		return
	if not (parent is LevelBase):
		return
	# Prizes (power-up buffs)
	var picked: Array = []
	for p in parent.prizes:
		if p == null:
			continue
		if position.distance_to(p.position) < PRIZE_PICKUP_RADIUS:
			p.apply_buff(self)
			picked.append(p)
	for p in picked:
		parent.prizes.erase(p)
		p.queue_free()
	# Hearts (HP heal). Same radius as prizes; the heal is done by Heart.pickup
	# which calls self.heal(10), clamped to max_health internally.
	picked = []
	for h in parent.hearts:
		if h == null:
			continue
		if position.distance_to(h.position) < PRIZE_PICKUP_RADIUS:
			h.pickup(self)
			picked.append(h)
	for h in picked:
		parent.hearts.erase(h)
		h.queue_free()
	# Apples (hunger +50). Apple.pickup calls self.add_hunger(50).
	picked = []
	for a in parent.apples:
		if a == null:
			continue
		if position.distance_to(a.position) < PRIZE_PICKUP_RADIUS:
			a.pickup(self)
			picked.append(a)
	for a in picked:
		parent.apples.erase(a)
		a.queue_free()
	# Batteries (ammo +10). Battery.pickup calls self.add_ammo(10).
	picked = []
	for b in parent.batteries:
		if b == null:
			continue
		if position.distance_to(b.position) < PRIZE_PICKUP_RADIUS:
			b.pickup(self)
			picked.append(b)
	for b in picked:
		parent.batteries.erase(b)
		b.queue_free()


# Hunger restore proxy: Apple pickup calls self.add_hunger(50).
# Looks up HungerMenu via parent.parent (= Main) and delegates. Silent no-op
# if there's no HungerMenu (e.g. testing in an isolated scene).
func add_hunger(amount: int) -> void:
	var parent = get_parent()
	if parent == null:
		return
	var main = parent.get_parent()
	if main == null:
		return
	var hm = main.get_node_or_null("CanvasMenu/ControlMenu/HungerMenu")
	if hm != null and hm.has_method("add_hunger"):
		hm.add_hunger(amount)


# Ammo restore proxy: Battery pickup calls self.add_ammo(10).
# Reuses _get_ammo_menu for the lookup. No-op if not found.
func add_ammo(amount: int) -> void:
	var ammo_menu = _get_ammo_menu()
	if ammo_menu != null and ammo_menu.has_method("add_ammo"):
		ammo_menu.add_ammo(amount)


# Looks up AmmoMenu in the hierarchy: the player is a child of Level/Entrance/BossRoom,
# which in turn is a child of Main, where CanvasMenu/ControlMenu/AmmoMenu lives.
# Same pattern as connect_lifebar but on-demand (the player gets reparented
# between levels, so it can't be cached with @onready).
func _get_ammo_menu() -> Control:
	var p = get_parent()
	if p == null:
		return null
	var pp = p.get_parent()
	if pp == null:
		return null
	return pp.get_node_or_null("CanvasMenu/ControlMenu/AmmoMenu")


func heal(amount):
	set_health(health + amount)


func set_health(value):
	var prev_health = health
	health = clamp(value, 0, max_health)
	if health != prev_health:
		health_updated.emit(health, max_health)
		if health == 0:
			kill()
			killed.emit()


func kill():
	# Game over: snapshot of the score + source of the final damage BEFORE the
	# change_scene_to_file, because loading GameOver.tscn frees the entire
	# current tree (Main and its children), including ScoreLabel.
	GameState.last_damage_source = _last_damage_source
	GameState.last_score = 0
	var p = get_parent()
	if p != null:
		var main = p.get_parent()
		if main != null:
			var sl = main.get_node_or_null("CanvasMenu/ControlMenu/ScoreLabel")
			if sl != null:
				GameState.last_score = sl.score
		# Secret Zombie: record where the player died so the next run
		# spawns a Zombie in the matching level. Entrance -> level 1,
		# boss room -> last level before boss, else -> same level index.
		_record_death_for_zombie(p)
	get_tree().change_scene_to_file("res://interface/GameOver.tscn")


# Reads the level's biome + kind and writes the next-run Zombie spawn
# target into GameState. Boss-room case needs the numlvs from Main's
# biome config (cfg index 10) to find the last procedural level.
# Silent (no zombie pending) if the level lacks the get_biome /
# get_level_kind methods or if Main isn't reachable.
func _record_death_for_zombie(level) -> void:
	if not level.has_method("get_level_kind") or not level.has_method("get_biome"):
		return
	var biome: String = level.get_biome()
	var kind: String = level.get_level_kind()
	if biome == "":
		return
	var target_index: int = 0
	if kind == "entrance":
		target_index = 0    # "level 1" = num_level 0
	elif kind == "boss":
		# Last level before boss = numlvs - 1 (0-indexed). numlvs lives
		# in Main's biome config array at index 10.
		var main = level.get_parent()
		if main == null:
			return
		var cfg = null
		if biome == "Marshlands": cfg = main.Marshlands
		elif biome == "Noob_Woods": cfg = main.Noob_Woods
		if cfg == null:
			return
		target_index = int(cfg[10]) - 1
	else:
		# Procedural Level: spawn in the same level (num_level match).
		target_index = int(level.num_level)
	GameState.zombie_pending = true
	GameState.zombie_target_biome = biome
	GameState.zombie_target_level_index = target_index

################# end health


################# Input and movement

func _input(event):
	if get_parent().charging:
		return
	# Camera2D zoom (Godot 4 inverts the semantics compared to Godot 3:
	# higher values = more zoom in).
	if event.is_action_pressed('scroll_up'):
		if $Camera2D.zoom.x < 10.0:
			$Camera2D.zoom += Vector2(0.2, 0.2)
	if event.is_action_pressed('scroll_down'):
		if $Camera2D.zoom.x > 1.0:
			$Camera2D.zoom -= Vector2(0.2, 0.2)
	# Debug damage test
	if event is InputEventKey and event.pressed and event.keycode == KEY_T:
		damage(2)
	# Hitscan shot with SPACE. Gated by play_mode to not shoot
	# during level transitions. echo discarded: 1 key = 1 shot.
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_SPACE:
		if play_mode:
			_shoot_laser()


func _unhandled_input(event):
	if not play_mode:
		return
	if not event is InputEventMouseButton:
		return
	if event.button_index != MOUSE_BUTTON_LEFT or not event.pressed:
		return

	# Cursor beam mode: left-click is the FIRE button. The shot's direction
	# comes from the same get_global_mouse_position() that drives the aim,
	# so click-where-you-want-to-shoot is the gesture. Click-to-move and
	# click-to-punch are intentionally suppressed in cursor mode —
	# movement is keyboard-only (WASD/arrows), matching a twin-stick-
	# shooter mapping where the mouse is purely aim+fire.
	if GameState.beam_mode == "cursor":
		_shoot_laser()
		return

	# FIXED beam mode (legacy click semantics):
	# If the click is on an adjacent enemy, attack. Otherwise, move there.
	# This was the original behavior from the Game Jam, cursor mode was
	# implemented as the most feedback-requested feature
	var clicked_enemy = null
	for e in get_parent().enemies:
		if get_parent().adjacent(position, e.position):
			if get_parent().adj_attack(e.position, get_global_mouse_position()):
				clicked_enemy = e
				break

	if clicked_enemy != null:
		# Face the enemy
		var dx = clicked_enemy.position.x - position.x
		var dy = clicked_enemy.position.y - position.y
		if abs(dx) >= abs(dy):
			last_move = "Der_Idle" if dx > 0 else "Izq_Idle"
		else:
			last_move = "Down_Idle" if dy > 0 else "Up_Idle"

		if attack_timer.is_stopped():
			attack_timer.start()
			attack_enemy(clicked_enemy)
	else:
		get_parent().ask_path()


func _physics_process(delta):
	if get_parent().charging or not play_mode:
		velocity = Vector2.ZERO
		return

	# Direct cardinal/diagonal input (WASD/arrows). If there's input, it cancels the
	# click-to-move path.
	var input_dir := Vector2.ZERO
	for action in inputs.keys():
		if Input.is_action_pressed(action):
			input_dir += inputs[action]
	# WASD in parallel to the arrows. Done via raw keycode instead of
	# adding it to the InputMap of project.godot to keep the change local
	# to the script. If both (W and Up) are pressed, the vectors sum and
	# normalized() below limits the magnitude — no double-speed.
	if Input.is_key_pressed(KEY_W): input_dir += Vector2.UP
	if Input.is_key_pressed(KEY_S): input_dir += Vector2.DOWN
	if Input.is_key_pressed(KEY_A): input_dir += Vector2.LEFT
	if Input.is_key_pressed(KEY_D): input_dir += Vector2.RIGHT

	if input_dir != Vector2.ZERO:
		path = PackedVector2Array()
		velocity = input_dir.normalized() * speed * tile_size
	elif path.size() > 0:
		var target = path[0]
		var to_target = target - position
		if to_target.length() <= 4.0:
			path.remove_at(0)
			velocity = Vector2.ZERO
		else:
			velocity = to_target.normalized() * speed * tile_size
	else:
		velocity = Vector2.ZERO

	# Movement with manual blocking against walls AND enemies. We do NOT use
	# move_and_slide because the Map's TileSet has physics on ALL
	# tiles (not just walls). We also don't use collision_layer/mask (they're at
	# 0 so the physics doesn't collide with floors). Instead we apply
	# displacement by hand and check map_is_wall + enemy proximity
	# at the destination, sliding along the free axis when one direction
	# is blocked.
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

	_update_animation()
	_check_prize_pickup()


# Unified helper: blocked by a wall or by an enemy.
func _is_blocked(world_pos: Vector2) -> bool:
	return _blocked_by_wall(world_pos) or _blocked_by_actor(world_pos)


# Checks if the world position falls on a wall tile (or outside the map).
# Takes samples at the 4 corners of a 16 px square around the position
# so the player doesn't enter the wall with half its body.
func _blocked_by_wall(world_pos: Vector2) -> bool:
	var parent = get_parent()
	if parent == null:
		return false
	var map = parent.Map
	if map == null:
		return false
	var half := 12
	for offset in [Vector2(-half, -half), Vector2(half, -half), Vector2(-half, half), Vector2(half, half)]:
		if parent.map_is_wall(map.local_to_map(world_pos + offset)):
			return true
	return false


# Checks if the destination position is too close to some enemy.
# Threshold 8 px: the enemy stops 14 px from the player (ACTOR_RADIUS_VS_PLAYER
# in Enemy.gd), so the player has approx. 6 px of "slack" to move when
# surrounded. Without this margin, a ring of enemies would freeze them in place.
# The radius is still non-zero: the player doesn't pass through enemies,
# they just squeeze up until touching them.
func _blocked_by_actor(world_pos: Vector2) -> bool:
	var parent = get_parent()
	if parent == null:
		return false
	const ACTOR_RADIUS := 8.0
	for e in parent.enemies:
		if e == null or e == self:
			continue
		if world_pos.distance_to(e.position) < ACTOR_RADIUS:
			return true
	return false


# Picks animation based on velocity and timer state (attack/damage/idle).
func _update_animation():
	# MID-STRICT cursor-beam override: while the attack_timer is running
	# (the brief 0.2s window right after firing), force the sprite to face
	# the cursor and play the corresponding Atk animation — regardless of
	# velocity. Without this override the velocity branch below would
	# repaint last_move from movement every physics frame, so a moving-
	# while-firing player would see the beam go toward the cursor but the
	# sprite's attack pop would face the movement direction. With this, the
	# sprite "turns and fires" on each shot, then resumes its move animation
	# once the attack pop expires.
	if GameState.beam_mode == "cursor" and not attack_timer.is_stopped():
		var cursor_dir: Vector2 = get_global_mouse_position() - position
		if cursor_dir != Vector2.ZERO:
			if abs(cursor_dir.x) >= abs(cursor_dir.y):
				last_move = "Der_Idle" if cursor_dir.x > 0 else "Izq_Idle"
			else:
				last_move = "Down_Idle" if cursor_dir.y > 0 else "Up_Idle"
		_play_anim(last_move.replace("_Idle", "_Atk"))
		return
	if velocity != Vector2.ZERO:
		# Dominant axis decides the movement animation
		if abs(velocity.x) > abs(velocity.y):
			if velocity.x > 0:
				last_move = "Der_Idle"
				_play_anim("Der_Move")
			else:
				last_move = "Izq_Idle"
				_play_anim("Izq_Move")
		else:
			if velocity.y > 0:
				last_move = "Down_Idle"
				_play_anim("Down_Move")
			else:
				last_move = "Up_Idle"
				_play_anim("Up_Move")
		return

	# Standing: prioritize attack > damage > idle.
	if not attack_timer.is_stopped():
		_play_anim(last_move.replace("_Idle", "_Atk"))
	elif not damage_timer.is_stopped():
		_play_anim(last_move.replace("_Idle", "_Damage"))
	else:
		_play_anim(last_move)


func activate():
	play_mode = true
