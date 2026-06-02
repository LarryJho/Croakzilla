extends LevelBase

#####################################################################
### BOSSROOM: fixed final room of the biome.                      ###
### Inherits fog, turns, reservations and queries from LevelBase. ###
### The map is pre-painted in the scene; we only build the        ###
### AStar2D graph and decorate.                                   ###
#####################################################################

# Cell coords of the entry / exit stairs (terrain 1 / 0 when scanned).
# Captured in charge() and used by the seal helpers to change tiles to
# terrain 2 (locked) / 3 (open) depending on the biome and boss-room state.
var _start_stair_cell: Vector2i = Vector2i.ZERO
var _has_start_stair_cell: bool = false
var _end_stair_cell: Vector2i = Vector2i.ZERO
var _has_end_stair_cell: bool = false

# NW boss-room exit gating: when the gray rat is the "marked mob",
# `_marked_mob_alive = true` blocks player_gone() so the player cannot
# warp to the next biome until she dies. The exit stair tile is also
# visually locked (terrain 2) while she's alive. HR boss-room has no
# marked mob → _has_marked_mob stays false → no gating.
var _has_marked_mob: bool = false
var _marked_mob_alive: bool = false


func charge():
	make_map()

	# Instead of hardcoding coords, we scan the TileMapLayer Stairs to
	# find the up stair (terrain 1) and the down stair (terrain 0).
	# This way the player spawn aligns with where the stair was painted
	# in the scene, regardless of whether it moves during level design.
	# (Project convention: terrain 0 = down/exit, terrain 1 = up/entrance.)
	for cell in Stairs.get_used_cells():
		var data = Stairs.get_cell_tile_data(cell)
		if data == null:
			continue
		if data.terrain == 1 and start_stair_tile == null:
			start_stair_tile = Vector2(cell.x, cell.y) * tile_size + Vector2.ONE * tile_size/2
			_start_stair_cell = cell
			_has_start_stair_cell = true
		elif data.terrain == 0 and end_stair_tile == null:
			end_stair_tile = Vector2(cell.x, cell.y) * tile_size + Vector2.ONE * tile_size/2
			_end_stair_cell = cell
			_has_end_stair_cell = true

	# Fallback in case the scene doesn't have stairs with terrain marked:
	# we use the original coords to avoid breaking.
	if start_stair_tile == null:
		start_stair_tile = (Vector2(14, 17) * tile_size) + Vector2.ONE * tile_size/2
	if end_stair_tile == null:
		end_stair_tile = (Vector2(15, -3) * tile_size) + Vector2.ONE * tile_size/2

	player.position = start_stair_tile

	if player != null:
		play_mode = true
		# Spawn protection: the player enters the boss room ON TOP OF start_stair_tile.
		# Without this, the next frame would trigger transition and return to the level.
		_was_on_stair = true
		player.play_mode = true

	# Seal the entry stair — the player should not go back from a boss
	# room. Visual cue: terrain 3 = "closed/sealed". NW override below
	# changes it to terrain 2 = "locked until the gray rat dies".
	_seal_entry_stair(3)

	# Predefined boss room mobs per biome. They are spawned after the
	# player is positioned so that positions are chosen relative to an
	# already-initialized Map.
	if get_biome() == "Noob_Woods":
		_spawn_mobs(load("res://Mobs/Noob_Woods/Big_Rat.tscn"), 10)
		# 1 gray rat at the center of the room (midpoint between the up
		# stair and the down stair) — the player sees it as soon as they
		# enter the room. We capture the ref + connect its killed signal so
		# when it dies the entry stair returns to "open" state 
		var gray = _spawn_mobs_at_center(load("res://Mobs/Noob_Woods/Big_Rat_Gray.tscn"), 1)
		if gray != null and gray.has_signal("killed"):
			gray.killed.connect(_on_marked_mob_killed)
			_has_marked_mob = true
			_marked_mob_alive = true
			# Lock both stairs visually while she lives. _on_marked_mob_killed
			# flips them open (entry → 3, exit → 0 functional).
			_seal_entry_stair(2)
			_seal_exit_stair(2)
	elif get_biome() == "Marshlands":
		# Layout (entrance/stair at (13, 11), big field to the north y=-61..-21):
		#   - Plague Rat 1: 15 tiles up from entrance = (13, -4) — mid corridor.
		#   - Plague Rat 2: middle of the big field = (13, -41).
		#   - Croakzilla: upper end of the big field = (13, -58).
		# _spawn_mob_at_tile validates that each tile is floor and searches for
		# the nearest one if it isn't; see helper below.
		var plague = load("res://Mobs/Marshlands/Plague_Big_Rat.tscn")
		var croak = load("res://Mobs/Marshlands/Croakzilla.tscn")
		_spawn_mob_at_tile(plague, Vector2i(13, -4))
		_spawn_mob_at_tile(plague, Vector2i(13, -41))
		_spawn_mob_at_tile(croak, Vector2i(13, -58))
		# Hell / Insane add-ons: 4 Marshlands Giant Shrooms approximately
		# at each corner of the boss-room floor section. Computed at runtime
		# from the floor bounding box so it survives any future map edits.
		var d = GameState.difficulty
		if d == "Hell" or d == "This doesn't make any sense":
			_spawn_shrooms_at_floor_corners()

	# Hunger heal (+30) + green flash on the first visit to this boss
	# room (per biome). Main.boss_rooms_visited persists across boss
	# room instances within the same game.
	var main = get_parent()
	if main != null and not main.boss_rooms_visited.has(get_biome()):
		main.boss_rooms_visited[get_biome()] = true
		var hunger_menu = main.get_node_or_null("CanvasMenu/ControlMenu/HungerMenu")
		if hunger_menu != null:
			hunger_menu.add_hunger(30)
		if player != null:
			player.flash_heal(0.5)

	# Difficulty Baby: +20 HP on entering the boss room. Gated by difficulty
	# only (not by first-visit), so it keeps applying if in the future the
	# player can re-enter a boss room. player.heal clamps to max_health
	# internally, so it's safe to pass overshoot.
	if GameState.difficulty == "Baby" and player != null:
		player.heal(20)


# Places `count` instances of `mob_scene` on random floor tiles of the Map.
# Excludes the central strip where the player walks and tiles occupied by
# stairs or by already-placed enemies. If there aren't enough free tiles,
# it spawns as many as it can and finishes.
func _spawn_mobs(mob_scene: PackedScene, count: int):
	if mob_scene == null:
		return
	# Build the candidate list: floor tiles that are not part of the
	# central corridor, nor a stair, nor the player spawn.
	var candidates: Array[Vector2i] = []
	var stairs_used: Dictionary = {}
	for cell in Stairs.get_used_cells():
		stairs_used[cell] = true
	for cell in Map.get_used_cells():
		if not map_is_floor(cell):
			continue
		if cell.x >= 14 and cell.x <= 16 and cell.y >= 1 and cell.y <= 3:
			continue  # central corridor, we leave it free
		if stairs_used.has(cell):
			continue  # tile with stair
		candidates.append(cell)
	candidates.shuffle()

	var spawned := 0
	for cell in candidates:
		if spawned >= count:
			break
		var pos = Vector2(cell.x, cell.y) * tile_size + Vector2.ONE * tile_size / 2
		# Avoid spawning too close to the player.
		if player != null and pos.distance_to(player.position) < tile_size * 2.0:
			continue
		var mob = mob_scene.instantiate()
		add_child(mob)
		enemies.append(mob)
		num_enemies += 1
		mob.position = pos
		mob.play_mode = true
		spawned += 1


# Spawns ONE mob on a specific tile. Validates that it's floor; if it isn't,
# expands in a growing ring up to `search_radius` to find the nearest floor.
# Silent skip if there's no floor within the radius. Used by the Marshlands
# branch of the boss room for manual positioning (Croakzilla + plague rats)
# — mob_scene = null is also skipped.
func _spawn_mob_at_tile(mob_scene: PackedScene, tile: Vector2i, search_radius: int = 6):
	if mob_scene == null:
		return
	var target = tile
	if not map_is_floor(target):
		var found = false
		for r in range(1, search_radius + 1):
			for dx in range(-r, r + 1):
				for dy in range(-r, r + 1):
					# Only the outer ring of radius r (the inner ones have
					# already been tried in previous iterations).
					if abs(dx) != r and abs(dy) != r:
						continue
					var c = tile + Vector2i(dx, dy)
					if map_is_floor(c):
						target = c
						found = true
						break
				if found: break
			if found: break
		if not found:
			push_warning("[BossRoom] No floor near %s for %s" % [str(tile), mob_scene.resource_path])
			return
	var pos = Vector2(target.x, target.y) * tile_size + Vector2.ONE * tile_size / 2
	var mob = mob_scene.instantiate()
	add_child(mob)
	enemies.append(mob)
	num_enemies += 1
	mob.position = pos
	mob.play_mode = true


# Spawns 4 Giant Shrooms at approximate corners of the floor section.
# Used in the Marshlands boss room on Hell + Insane as an extra-add layer.
# Algorithm:
#   1. Scan Map.get_used_cells, filter for floor (terrain 0), compute the
#      bounding box (min/max x/y).
#   2. Inset by 4 tiles from each edge so spawns land INSIDE the playable
#      area instead of right on the wall border.
#   3. Hand the four inset corners to _spawn_mob_at_tile with a generous
#      search_radius=15, which does its own ring-search-for-nearest-floor
#      fallback if the chosen tile isn't actually floor (irregular maps).
# Silent if Giant_Shroom.tscn fails to load or there are no floor cells.
func _spawn_shrooms_at_floor_corners() -> void:
	var shroom_scene = load("res://Mobs/Marshlands/Giant_Shroom.tscn")
	if shroom_scene == null:
		return
	var have_any := false
	var min_x: int = 0
	var max_x: int = 0
	var min_y: int = 0
	var max_y: int = 0
	for cell in Map.get_used_cells():
		if not map_is_floor(cell):
			continue
		if not have_any:
			min_x = cell.x
			max_x = cell.x
			min_y = cell.y
			max_y = cell.y
			have_any = true
		else:
			if cell.x < min_x: min_x = cell.x
			if cell.x > max_x: max_x = cell.x
			if cell.y < min_y: min_y = cell.y
			if cell.y > max_y: max_y = cell.y
	if not have_any:
		return
	# Inset 4 tiles so corners are clearly inside, never flush against a wall.
	# If the room is too small for the inset, fall back to the raw bounds.
	var inset: int = 4
	var w: int = max_x - min_x
	var h: int = max_y - min_y
	if w < inset * 2:
		inset = max(0, w / 2)
	if h < inset * 2:
		inset = min(inset, max(0, h / 2))
	var corners = [
		Vector2i(min_x + inset, min_y + inset),   # NW (top-left)
		Vector2i(max_x - inset, min_y + inset),   # NE (top-right)
		Vector2i(min_x + inset, max_y - inset),   # SW (bottom-left)
		Vector2i(max_x - inset, max_y - inset),   # SE (bottom-right)
	]
	for c in corners:
		_spawn_mob_at_tile(shroom_scene, c, 15)


# Spawns `count` mobs at the center of the room (midpoint between stairs).
# The offsets distribute the first N instances in a horizontal pattern
# (center, 1 tile left, 1 tile right, up, down). Enough for up to 5 mobs;
# if you ask for more, they stack at the center and collision separates them.
func _spawn_mobs_at_center(mob_scene: PackedScene, count: int):
	if mob_scene == null or start_stair_tile == null or end_stair_tile == null:
		return null
	var center: Vector2 = (start_stair_tile + end_stair_tile) / 2.0
	var offsets = [
		Vector2(0, 0),
		Vector2(-tile_size, 0),
		Vector2(tile_size, 0),
		Vector2(0, -tile_size),
		Vector2(0, tile_size),
	]
	var first_mob = null
	for i in range(min(count, offsets.size())):
		var mob = mob_scene.instantiate()
		add_child(mob)
		enemies.append(mob)
		num_enemies += 1
		mob.position = center + offsets[i]
		mob.play_mode = true
		if first_mob == null:
			first_mob = mob
	# If you asked for more mobs than slots, the extras go to the center
	# (collision between enemies pushes them to nearby valid positions).
	for i in range(offsets.size(), count):
		var mob = mob_scene.instantiate()
		add_child(mob)
		enemies.append(mob)
		num_enemies += 1
		mob.position = center
		mob.play_mode = true
		if first_mob == null:
			first_mob = mob
	# Return the first spawned mob — used by NW boss room to connect the
	# gray rat's killed signal to the entry stair change.
	return first_mob


# Changes the entry stair (cell captured when scanning the TileMapLayer Stairs)
# to a specific terrain. Used for visual "sealing" of the stair on entering
# the boss room (terrain 3) and for the NW override (terrain 2 while the
# gray rat lives, terrain 3 when it dies). It does not change warp
# functionality (player_gone only checks end_stair_tile), only the visual tile.
#
# We scan the TileSet to find the FIRST atlas position whose TileData has
# terrain == terrain_id, and use set_cell directly. 
# (coords, source_id, atlas_coords [, alternative_tile]).
func _seal_entry_stair(terrain_id: int) -> void:
	if _has_start_stair_cell:
		_set_stair_cell_terrain(_start_stair_cell, terrain_id)


# Same pattern for the exit stair. Default state is terrain 0 (functional
# down-stair); during NW boss room we lock to terrain 2 until the gray rat
# dies, then restore to terrain 0 so the player can proceed to the next
# biome. Marshlands boss room doesn't call this (no marked-mob gating).
func _seal_exit_stair(terrain_id: int) -> void:
	if _has_end_stair_cell:
		_set_stair_cell_terrain(_end_stair_cell, terrain_id)


# Shared lookup: scan Stairs.tile_set for the first atlas tile whose
# TileData.terrain matches `terrain_id`, then set the given cell to it.

func _set_stair_cell_terrain(cell: Vector2i, terrain_id: int) -> void:
	if Stairs == null or Stairs.tile_set == null:
		return
	var ts = Stairs.tile_set
	for sidx in range(ts.get_source_count()):
		var source_id = ts.get_source_id(sidx)
		var source = ts.get_source(source_id)
		if not (source is TileSetAtlasSource):
			continue
		var atlas: TileSetAtlasSource = source
		for i in range(atlas.get_tiles_count()):
			var atlas_coord = atlas.get_tile_id(i)
			var data = atlas.get_tile_data(atlas_coord, 0)
			if data != null and data.terrain == terrain_id:
				Stairs.set_cell(cell, source_id, atlas_coord)
				return
	push_warning("[BossRoom] No tile with terrain %d in Stairs TileSet" % terrain_id)


# Killed callback for the boss room "marked mob" (gray rat in NW).
# Changes the entry stair from terrain 2 (locked) -> terrain 3 (open) as
# visual feedback of "boss defeated". In NW there is no warp-back implemented
# (that would require preserving levels[] after entering the boss), so the
# change is only visual.
func _on_marked_mob_killed() -> void:
	_marked_mob_alive = false
	# Entry stair: locked → open ("boss vanquished" feedback, no warp).
	_seal_entry_stair(3)
	# Exit stair: locked → functional (terrain 0, the original down-stair
	# tile). Player can now walk onto it to proceed via _on_player_gone.
	_seal_exit_stair(0)


func make_map():
	# The TileMapLayer is already painted in the scene.
	scan_existing_map()

	# Static fog band around the painted Map area.
	var occupied: Dictionary = {}
	for c in Map.get_used_cells():
		occupied[c] = true
	make_fog_band(occupied, 10)

	# Bush decoration in the fixed range (-100, 50) x (-100, 50).
	# We keep the exclusion of the central strip where the player passes
	# (x in [14,16], y in [1,3]) to avoid blocking the path to the stair.
	# Per-biome variations:
	#   - Marshlands: density 0.1 + 3x3 centered clearance.
	#   - Noob_Woods   : density 0.5 + 2x2 anchored clearance.
	var is_marsh = get_biome() == "Marshlands"
	var density: float = 0.1 if is_marsh else 0.5
	for x in range(-100, 50):
		for y in range(-100, 50):
			if x >= 14 and x <= 16 and y >= 1 and y <= 3:
				continue
			if randf() < density and not _scenery_blocked(x, y, is_marsh):
				Scenario.set_cell(Vector2i(x, y), 0, Vector2i(0, 0))


# True if tile (x, y) is too close to a floor to place scenery.
# Marshlands requires 1 more tile of margin on the right side (+x axis):
# asymmetric 4x3 check with i in [-1, 2], j in [-1, 1].
func _scenery_blocked(x: int, y: int, is_marsh: bool) -> bool:
	if is_marsh:
		# 6x5 around the tile (+1 buffer over the original 4x3): Marshlands
		# scenery must stay 1 tile farther from the floor.
		for i in range(-2, 4):
			for j in range(-2, 3):
				if map_is_floor(Vector2i(x + i, y + j)):
					return true
	else:
		for i in range(0, 2):
			for j in range(0, 2):
				if map_is_floor(Vector2i(x + i, y + j)):
					return true
	return false


# --- LevelBase overrides ---

const _STAIR_TRIGGER_DIST: float = 10.0


func player_gone():
	if get_parent() == null or end_stair_tile == null:
		return false
	# FINAL LEVEL GUARD: Marshlands is the last biome — the player must
	# not warp out of its boss room under any circumstance. The only
	# valid "exit" is killing Croakzilla, which triggers YouWin via
	# Enemy.triggers_win=true. Without this guard, end_stair_tile (either
	# a painted terrain-0 tile or the (15,-3) fallback in charge()) would
	# warp the player to a brand-new Marshlands level, skipping the boss
	# entirely and making the win condition unreachable.
	if get_biome() == "Marshlands":
		return false
	# Gate by marked-mob (NW gray rat): while she's alive, the exit stair
	# is locked (visual terrain 2) AND functionally blocked here. HR boss
	# room has no marked mob (_has_marked_mob = false) so this never blocks.
	if _has_marked_mob and _marked_mob_alive:
		return false
	return player.position.distance_to(end_stair_tile) <= _STAIR_TRIGGER_DIST


func _on_player_gone():
	# CHANGE THE WIRING HERE when there are more worlds
	get_parent().lv_type = get_parent().Marshlands
	get_parent().change_world(get_parent().Marshlands)


# Override of LevelBase.is_boss_room — used by Character.damage to apply
# the Hell x2 to boss room enemies.
func is_boss_room() -> bool:
	return true


func get_level_kind() -> String:
	return "boss"


# Override of LevelBase.get_bgm_track: the Marshlands boss room has its
# own music "Boss" (Croakzilla). The NW one keeps using StrangeFarm.
func get_bgm_track() -> String:
	if get_biome() == "Marshlands":
		return "Boss"
	return "StrangeFarm"
