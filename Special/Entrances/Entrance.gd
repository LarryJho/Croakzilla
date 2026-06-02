extends LevelBase

#####################################################################
### ENTRANCE: fixed entry room to the world.                      ###
### Inherits fog, turns, reservations and queries from LevelBase. ###
### The map is static: there is a TileMapLayer already painted in ###
### the scene and we only build the AStar2D graph over the        ###
### floor-tiles via LevelBase.scan_existing_map().                ###
#####################################################################


func charge():
	make_map()

	# Detects the entrance stair by scanning the TileMapLayer Stairs
	# (entrance only has one "down" stair to the dungeon). This way it
	# automatically aligns with where it was painted in the scene,
	# regardless of biome.
	for cell in Stairs.get_used_cells():
		if Stairs.get_cell_tile_data(cell) == null:
			continue
		end_stair_tile = Vector2(cell.x, cell.y) * tile_size + Vector2.ONE * tile_size/2
		break

	# Fallback to the original Noob_Woods tile if the scene doesn't have
	# a stair with terrain marked.
	if end_stair_tile == null:
		end_stair_tile = (Vector2(6, 3) * tile_size) + Vector2.ONE * tile_size/2

	# Player spawn position, per biome:
	#   - Noob_Woods    : tile (18, 7)  (original — note: 15,9 used to be the start,
	#                     7,4 the stair; current values reflect the repaint)
	#   - Marshlands : tile (14, 8)
	var spawn_tile: Vector2
	if get_biome() == "Marshlands":
		spawn_tile = Vector2(14, 8)
	else:
		spawn_tile = Vector2(18, 7)
	player.position = spawn_tile * tile_size + Vector2.ONE * tile_size/2

	if player != null:
		play_mode = true
		# Spawn protection: the player appears far from the stair, so
		# _was_on_stair=false would let the rising-edge fire as soon as
		# they walk on it (desired). We initialize to false explicitly.
		_was_on_stair = false
		player.play_mode = true


func make_map():
	# The TileMapLayer is already painted in the scene.
	scan_existing_map()

	# Static fog band around the painted Map area.
	var occupied: Dictionary = {}
	for c in Map.get_used_cells():
		occupied[c] = true
	make_fog_band(occupied, 10)

	# Bush decoration in the fixed range (-100, 50) x (-100, 50).
	# Per-biome variations:
	#   - Marshlands: density 0.1 (sparse) + 3x3 centered clearance.
	#   - Noob_Woods   : density 0.5 (dense) + 2x2 anchored clearance.
	var is_haunted = get_biome() == "Marshlands"
	var density: float = 0.1 if is_haunted else 0.5
	for x in range(-100, 50):
		for y in range(-100, 50):
			if randf() < density and not _scenery_blocked(x, y, is_haunted):
				Scenario.set_cell(Vector2i(x, y), 0, Vector2i(0, 0))


# True if tile (x, y) is too close to a floor to place scenery.
# Marshlands requires 1 more tile of margin on the right side (+x axis):
# asymmetric 4x3 check with i in [-1, 2], j in [-1, 1].
func _scenery_blocked(x: int, y: int, is_haunted: bool) -> bool:
	if is_haunted:
		for i in range(-1, 3):
			for j in range(-1, 2):
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
	return player.position.distance_to(end_stair_tile) <= _STAIR_TRIGGER_DIST


func _on_player_gone():
	get_parent().enter_dungeon(get_parent().lv_type)


func get_level_kind() -> String:
	return "entrance"
