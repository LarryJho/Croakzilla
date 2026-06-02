extends Node2D

######################################################################
##### MAIN IS WHERE THE GAME BEGINS. IT HAS FUNCTIONS FOR HANDLING ###
##### LEVELS AND THE PLAYER. IT SHOULD ALSO START THE MENU         ###
######################################################################


var actual_level = 0
var Level = preload("res://Level.tscn")
var Entrance = preload("res://Special/Entrances/Noob_Woods_ERoom.tscn")
var Boss_Room = preload("res://Special/Boss Rooms/Noob_Woods_FRoom.tscn")


# Dictionary of enemies in world and list of appearances
var Mobs = {
			"Noob_Woods": [["Big_Rat", 0, 0.5], ["Giant_Shroom", 0.5, 0.8], ["Snek", 0.8, 1.0]],
			"Marshlands": [["Big_Rat", 0.0, 0.2], ["Giant_Shroom", 0.2, 0.6], ["Snek", 0.6, 1.0]]
			}


# Per-biome configuration:
# [num_rooms, min_rooms, min_size, max_size, hspread, vspread, cull, spawn,
#  max_enemies, world_name, numlvs, mob_table]

var Noob_Woods = [20, 10, 3, 8, 200, 280, 0.5, 0.5, 12, "Noob_Woods", 2, Mobs["Noob_Woods"]]
var Marshlands = [26, 12, 3, 7, 100, 180, 0.4, 0.4, 20, "Marshlands", 4, Mobs["Marshlands"]]

var lv_type = Noob_Woods

var levels = []
const OFFSET = 10000
var changing = false
# Set of biomes whose boss room has already been visited in this run.
# BossRoom.gd reads + sets in charge(); used to trigger the heal + green
# flash only on the first entry (per biome). Resets when returning to the
# main menu because Main gets re-instantiated.
var boss_rooms_visited: Dictionary = {}
var tile_size = 32
var listo = false

var entrance
var final
var level


# Called when the node enters the scene tree for the first time.
func _ready():
	# BGM NOTE: the loop is set via edit/loop_mode=1 in each .wav.import,
	# NOT via runtime mutation. Mutating stream.loop_mode at startup broke
	# AudioStreamWAV with compress/mode=2 (QOA) — the streams were changed
	# to compress/mode=0 (PCM) and the loop is already baked into the import.
	# Safety net: we connect `finished` -> `play()` on each BGM player. If
	# the native AudioStreamWAV loop works, `finished` is not emitted
	# (manual stop() also doesn't emit it) and the callback stays dormant.
	# If for some reason the native loop fails, the callback re-starts the
	# playback — loop guaranteed in both cases.
	for n in _BGM_NODE_NAMES.values():
		var p = get_node_or_null(n)
		if p != null and not p.finished.is_connected(p.play):
			p.finished.connect(p.play)

	# Apply difficulty multipliers BEFORE charging entrance — scales
	# num_rooms/min_rooms and max_enemies in the biome configs in-place,
	# so that Entrance/Level/BossRoom already use the correct values.
	_apply_difficulty_to_biomes()
	$CanvasMenu/PauseMenu.visible = false


	entrance = Entrance.instantiate()
	add_child(entrance)

	#### HERE THE PLAYER IS INTRODUCED ####
	entrance.player = entrance.Player.instantiate()
	entrance.add_child(entrance.player)
	entrance.player.connect_lifebar()
	#####################################

	entrance.charge()

	# Make the player's camera the active one (otherwise the root Camera2D
	# of the scene, very far away, stays active and everything looks tiny).
	entrance.player.cam.make_current()

	var lvs = get_children()
	for i in range(2, get_children().size()):
		for j in range(0, i):
			if lvs[j].name == str("res://Level", i, ".tscn"):
				lvs[j].queue_free()
	randomize()
	_set_level_label_in_room("entrance")
	# Initial BGM: the entrance has just loaded; apply its get_bgm_track
	# (StrangeFarm for NW, Swamp for HR). Subsequent level transitions
	# call _apply_bgm_for_level and only change if the track differs.
	_apply_bgm_for_level(entrance)


# Scales num_rooms/min_rooms (indices 0,1) and max_enemies (8) in the
# biome config arrays according to GameState.difficulty. Other parameters
# (size, spread, cull) stay the same. All scaled values use ceil() so that
# downscale (Baby) never floors to 0 and upscale stays consistent.
# Baby   : rooms x0.5,  enemies x0.5 (NW 20->10/10->5, HR 26->13/12->6).
# Hell   : rooms x2.0,  enemies x2.0.
# Insane : rooms x2.0,  enemies x3.0  (same rooms as Hell, more enemies
#          per room — denser instead of larger maps).
func _apply_difficulty_to_biomes():
	var d = GameState.difficulty
	var rooms_mult: float = 1.0
	var enemies_mult: float = 1.0
	if d == "Baby":
		rooms_mult = 0.5
		enemies_mult = 0.5
	elif d == "Hell":
		rooms_mult = 2.0
		enemies_mult = 2.0
	elif d == "This doesn't make any sense":
		rooms_mult = 2.0
		enemies_mult = 3.0
	for cfg in [Noob_Woods, Marshlands]:
		cfg[0] = int(ceil(cfg[0] * rooms_mult))            # num_rooms
		cfg[1] = int(ceil(cfg[1] * rooms_mult))            # min_rooms
		cfg[8] = int(ceil(cfg[8] * enemies_mult))          # max_enemies (rounded up)


# Sets the HUD LevelLabel text. kind ∈ {"entrance", "level", "boss"}.
# "level" uses actual_level + 1 (1-indexed display). Called on every
# transition: _ready, enter_dungeon, change_room(up/down × each branch),
# change_world.
func _set_level_label_in_room(kind: String):
	var lbl = get_node_or_null("CanvasMenu/ControlMenu/LevelLabel")
	if lbl == null:
		return
	match kind:
		"entrance":
			lbl.text = "Level: 0"
		"boss":
			lbl.text = "Level: boss"
		_:
			lbl.text = "Level: %d" % (actual_level + 1)


# Centralized BGM: THREE AudioStreamPlayer nodes pre-instantiated in
# Main.tscn (BgmStrange/BgmSwamp/BgmBoss), each with its stream
# pre-assigned via ExtResource. We never create/destroy players nor
# mutate `.stream` at runtime — we avoid the AudioStreamWAV (QOA) quirks
# that broke the previous approaches. We only call stop()/play() on the
# existing nodes.
#
# `_current_bgm_track` prevents restarting the track when crossing
# levels of the same biome. BgmStrange has autoplay=true in .tscn, so
# the game starts with StrangeFarm. _ready() initializes
# _current_bgm_track = "StrangeFarm" in Godot via the first
# _apply_bgm_for_level(entrance).
var _current_bgm_track: String = ""


# Resolves track name → node name (the naming convention in Main.tscn).
const _BGM_NODE_NAMES := {
	"StrangeFarm": "BgmStrange",
	"Swamp": "BgmSwamp",
	"Boss": "BgmBoss",
}


func _apply_bgm(track: String) -> void:
	if track == _current_bgm_track:
		return  # same track = continuity, don't touch
	var target_name: String = _BGM_NODE_NAMES.get(track, "")
	if target_name == "":
		# Unknown or empty track (e.g., a future level with no BGM).
		# Stop ALL players and leave it without music.
		for n in _BGM_NODE_NAMES.values():
			var p = get_node_or_null(n)
			if p != null and p.playing:
				p.stop()
		_current_bgm_track = ""
		return
	var target = get_node_or_null(target_name)
	if target == null:
		push_warning("[Main] _apply_bgm: missing node '%s' for track '%s'" % [target_name, track])
		return
	# Stop all players OTHER than the target. The target stays as it is:
	# if it's playing (e.g., autoplay from BgmStrange), play() below is a
	# no-op (Godot's AudioStreamPlayer.play() restarts if already playing
	# — that's why we gate with .playing).
	for n in _BGM_NODE_NAMES.values():
		var p = get_node_or_null(n)
		if p != null and p != target and p.playing:
			p.stop()
	if not target.playing:
		target.play()
	_current_bgm_track = track


# Helper: reads get_bgm_track from the current level/entrance/boss-room
# and applies it. Called on ALL transitions; those that don't change
# biome become an automatic no-op thanks to the _apply_bgm guard.
func _apply_bgm_for_level(levell) -> void:
	if levell == null or not levell.has_method("get_bgm_track"):
		return
	_apply_bgm(levell.get_bgm_track())


# Show/hide of the LoadingOverlay. No-op if the node doesn't exist.
func _set_loading(active: bool) -> void:
	var overlay = get_node_or_null("LoadingOverlay")
	if overlay == null:
		return
	if active:
		overlay.show_loading()
	else:
		overlay.hide_loading()


##### Change the world
func change_world(w):
	var lvs = get_children()

	var player_global = final.player
	final.remove_child(final.player)

	Entrance = load("res://Special/Entrances/"+w[9]+"_ERoom.tscn")
	Boss_Room = load("res://Special/Boss Rooms/"+w[9]+"_FRoom.tscn")
	actual_level = 0

	entrance = Entrance.instantiate()
	add_child(entrance)

	final.queue_free()

	entrance.add_child(player_global)
	entrance.player = player_global

	entrance.charge()

	# Re-assign the player's camera as current. During the world change
	# the player leaves the tree (final.remove_child) and re-enters in
	# the new entrance; in that gap Godot may pick another Camera2D (the
	# Cam_2d of the new entrance, or that of the not-yet-freed boss
	# room) and the player's camera stops following the actor.
	entrance.player.cam.make_current()

	lvs = get_children()
	for i in range(2, get_children().size()):
		for j in range(0, i):
			if lvs[j].name == str("res://Level", i, ".tscn"):
				lvs[j].queue_free()
	_set_level_label_in_room("entrance")
	# BGM: biome change → the track almost always changes (NW→HR = Swamp).
	# The _apply_bgm guard short-circuits if for some reason it's the same.
	_apply_bgm_for_level(entrance)


func enter_dungeon(world_data):
	if changing:
		return
	changing = true
	# Deactivate entrance — symmetric with how change_room("down") deactivates
	# the previous level before the await. Stops any processing + freezes any
	# (currently no-op for Entrance) enemies, so nothing acts during loading.
	if entrance != null:
		entrance.deactivate()

	level = Level.instantiate()
	level.name = "Level_1"
	level.num_level = 0
	add_child(level)
	levels.append(level)

	# We reparent the player BEFORE charge() so that the
	# `if player != null:` block at the end of charge positions it on
	# start_stair_tile.
	var player_global = entrance.player
	entrance.remove_child(entrance.player)
	level.add_child(player_global)
	level.player = player_global

	# Make the player's camera current BEFORE the await: otherwise, during
	# the transition the Level's Cam_2d (zoom 0.1, very zoomed-out) may be
	# picked as active camera between the player leaving the previous level
	# and the player's camera becoming current again.
	level.player.cam.make_current()

	# Loading overlay during the async generation. We do NOT set
	# get_tree().paused — that freezes the physics of make_rooms() (the
	# Rooms' RigidBody2D don't separate). Instead, entrance was already
	# deactivate'd above, which stops its enemies via the symmetric
	# version of LevelBase.deactivate (set play_mode=false).
	_set_loading(true)
	# We wait for charge() to finish COMPLETELY — make_rooms, make_map,
	# and the block that assigns player.position. Without await, the rest
	# runs before the player is positioned, leaving them stuck at old coords.
	await level.charge(world_data)
	_set_loading(false)

	# Belt and suspenders: reposition explicitly.
	if level.start_stair_tile != null:
		level.player.position = level.start_stair_tile

	for child in entrance.get_children():
		child.queue_free()
	entrance.queue_free()

	level.player.play_mode = true
	_set_level_label_in_room("level")
	# Same biome as entrance → no-op due to guard. Defensive in case a
	# Level in the future has BGM logic distinct from the entrance.
	_apply_bgm_for_level(level)

	changing = false


# Change level
func change_room(ind):
	if changing:
		return
	changing = true
	if ind == "up":
		if actual_level <= 0:
			return
		else:
			var anterior = levels[actual_level]
			var destino = levels[actual_level-1]

			anterior.deactivate()

			var player_global = anterior.player
			anterior.remove_child(anterior.player)
			destino.add_child(player_global)
			destino.player = player_global
			destino.player.position = destino.end_stair_tile
			destino.player.cam.make_current()
			destino.player.play_mode = true

			actual_level -= 1
			destino.activate()
			_set_level_label_in_room("level")
			# Same biome → no-op due to guard.
			_apply_bgm_for_level(destino)

	elif ind == "down":
		var anterior = levels[actual_level]
		### Case: only the boss level
		if actual_level + 1 >= anterior.numlvs:
			final = Boss_Room.instantiate()
			add_child(final)

			var player_global = anterior.player
			anterior.remove_child(anterior.player)
			final.add_child(player_global)
			final.player = player_global

			final.player.cam.make_current()
			final.player.play_mode = true

			final.charge()
			for lv in levels:
				lv.queue_free()
			levels = []
			_set_level_label_in_room("boss")
			# Boss room: in Marshlands changes to "Boss"; in NW stays on
			# StrangeFarm (BossRoom.get_bgm_track returns based on biome).
			_apply_bgm_for_level(final)
		### Case: next level
		else:
			var lv = null
			if levels.size() <= actual_level + 1:
				lv = Level.instantiate()
				lv.name = str("level", levels.size())
				lv.num_level = actual_level + 1
				add_child(lv)
				levels.append(lv)

				# We reparent the player BEFORE charge() so that its final
				# block places it on start_stair_tile.
				anterior.deactivate()
				var player_global = anterior.player
				anterior.remove_child(anterior.player)
				lv.add_child(player_global)
				lv.player = player_global

				# Make the player's camera current BEFORE the await: otherwise,
				# the Level's Cam_2d (zoom 0.1) may become active during the
				# transition and the view jumps to (offset*num_level, 0) zoomed-out.
				lv.player.cam.make_current()

				# Loading overlay. WITHOUT get_tree().paused (interferes with
				# the physics of make_rooms). anterior.deactivate() above already
				# froze the enemies of the previous level via play_mode=false.
				_set_loading(true)
				# We wait for charge() to finish: make_rooms + make_map +
				# positioning block. Without await the rest runs before
				# the player has valid coordinates from the new level.
				await lv.charge(lv_type)
				_set_loading(false)

				# Belt and suspenders: reposition explicitly.
				if lv.start_stair_tile != null:
					lv.player.position = lv.start_stair_tile

				lv.player.play_mode = true
				actual_level += 1
				_set_level_label_in_room("level")
				# Same biome → no-op due to guard.
				_apply_bgm_for_level(lv)
			else:
				var destino = levels[actual_level+1]
				anterior.deactivate()

				var player_global = anterior.player
				anterior.remove_child(anterior.player)
				destino.add_child(player_global)
				destino.player = player_global

				destino.player.position = destino.start_stair_tile
				destino.player.cam.make_current()
				destino.player.play_mode = true

				destino.activate()

				actual_level += 1
				_set_level_label_in_room("level")
				# Same biome → no-op due to guard.
				_apply_bgm_for_level(destino)

	changing = false


func can_change_room(ind):
	if ind == "up":
		if actual_level <= 0:
			return false
		else:
			return true
	elif ind == "down":
		return true


func change_level(i, path_i, path_j):
	var packed_scene = PackedScene.new()
	packed_scene.pack(get_children()[i])
	ResourceSaver.save(packed_scene, path_i)

	# Load the PackedScene resource
	packed_scene = load(path_j)
	# Instance the scene
	var my_scene = packed_scene.instantiate()
	add_child(my_scene)


func _on_PauseButton_pressed():
	get_tree().paused = !get_tree().paused
	$CanvasMenu/PauseMenu.visible = !$CanvasMenu/PauseMenu.visible





func _on_Continue_pressed():
	get_tree().paused = !get_tree().paused
	$CanvasMenu/PauseMenu.visible = !$CanvasMenu/PauseMenu.visible





func _on_Quit_pressed():
	get_tree().paused = !get_tree().paused
	get_tree().change_scene_to_file("res://interface/Main_Menu.tscn")


# PauseMenu's "Settings" button: instantiates Settings.tscn as an OVERLAY,
# add_child to CanvasMenu (PROCESS_MODE_ALWAYS, so it reacts to clicks
# during pause). is_overlay=true in Settings.gd changes BACK so that it
# only does queue_free, leaving the PauseMenu visible and the game
# paused. Different from opening Settings from Main_Menu, where it's a
# scene change.
func _on_Settings_pressed():
	var settings_scene = preload("res://interface/Settings.tscn")
	var settings = settings_scene.instantiate()
	settings.is_overlay = true
	$CanvasMenu.add_child(settings)
