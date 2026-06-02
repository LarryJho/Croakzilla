extends LevelBase

#####################################################################
### LEVEL: procedural management of a dungeon level.              ###
### Inherits fog, turns, reservations and queries from LevelBase. ###
#####################################################################
### Notes:                                                            ##
### - TileMapLayer.set_cell(Vector2i, source_id, atlas_coords)        ##
### - Croakzilla: real-time movement, no turns nor                    ##
###   tile reservations. The AStar2D still exists for click-to-move   ##
###   of the player and for the PURSUER mode of the enemies.         ##
#####################################################################

var Enemy = []  # list of enemy loads available for the biome

# Caches used by make_map and carve_path. Cells are accumulated here
# while carving, and at the end they are painted in one go with
# set_cells_terrain_connect so that the autotile works.
var wall_cells: Dictionary = {}
var floor_cells: Dictionary = {}

# Procedural tunables (filled in charge())
var num_rooms = 20
var min_rooms = 10
var min_size = 3
var max_size = 8
var hspread = 200
var vspread = 280
var cull = 0.5
var spawn = 0.2
var max_enemies = 10
var numlvs = 5


func charge(data):
	# Keeps the flag active to block player input during generation.
	charging = true

	num_rooms = data[0]
	min_rooms = data[1]
	min_size = data[2]
	max_size = data[3]
	hspread = data[4]
	vspread = data[5]
	cull = data[6]
	spawn = data[7]
	max_enemies = data[8]
	numlvs = data[10]

	Scenario.tile_set = load('res://assets/'+data[9]+'/Resources.tres')
	Stairs.tile_set = load('res://assets/'+data[9]+'/Stairs.tres')
	Map.tile_set = load('res://assets/'+data[9]+'/'+data[9]+'.tres')

	load_enemies(data[9], data[11])

	make_rooms()

	await get_tree().create_timer(0.02*num_rooms/(max_size)*15).timeout

	make_map()

	# Apple spawn: 3.5% per floor tile of each room (not corridors). Done
	# after make_map so that floor_cells is complete. Apples live
	# in parent.apples (LevelBase), Character._check_prize_pickup consumes them.
	_spawn_apples()

	if player != null:
		player.position = start_stair_tile
		create_enemies()
		play_mode = true
		# Spawn protection: the player appears ON the up-stair,
		# we prevent the next frame from firing _on_player_gone and going back.
		_was_on_stair = true
		player.play_mode = true

	charging = false


func make_rooms():
	Cam_2d.position += Vector2.RIGHT * get_parent().OFFSET * (num_level)

	for _i in range(num_rooms):
		var pos = Vector2(randf_range(-hspread, hspread), randf_range(-vspread, vspread))
		pos += Vector2.RIGHT * get_parent().OFFSET * num_level

		var r = Room.instantiate()
		var w = min_size + randi() % (max_size - min_size)
		var h = min_size + randi() % (max_size - min_size)
		r.make_room(pos, Vector2(w, h) * tile_size)
		$Rooms.add_child(r)

	# Wait for the physics simulation to separate the rooms
	await get_tree().create_timer(0.02*num_rooms/(max_size)*10).timeout

	# Random discard of rooms (cull)
	var room_positions = []
	num_rooms = $Rooms.get_child_count()
	for room in $Rooms.get_children():
		if (randf() < cull) and (num_rooms > min_rooms):
			room.queue_free()
			num_rooms -= 1
		else:
			room.freeze = true
			room_positions.append(Vector3(room.position.x, room.position.y, 0))
	await get_tree().process_frame

	# MST with the room centers
	path = find_mst(room_positions)


func load_enemies(scene, info):
	for mob in info:
		Enemy.append([load("res://Mobs/"+scene+"/"+mob[0]+".tscn"), mob[1], mob[2]])


func create_enemies():
	var pos_enemy = Vector2(0.0, 0.0)

	for room in $Rooms.get_children():
		if !room.start and !room.end:
			for _i in range(0, 3, 1):
				if (randf() < spawn) and (num_enemies < max_enemies):
					var x_max = (room.position.x + ((room.size.x/2)-tile_size))
					var x_min = (room.position.x - ((room.size.x/2)))
					var y_max = (room.position.y + ((room.size.y/2)-tile_size))
					var y_min = (room.position.y - ((room.size.y/2)))

					# Look for a free tile to spawn the enemy. Original
					# bug: av_pos was declared OUTSIDE the while and once set
					# to false it never reset -> infinite loop and the
					# game froze (more likely with high max_enemies).
					# Fix: reset every iteration + attempt cap so that
					# if the room is already saturated we don't hang.
					var aux
					var av_pos := false
					var max_attempts := 50
					var attempts := 0
					while not av_pos and attempts < max_attempts:
						attempts += 1
						av_pos = true
						pos_enemy.x = randf_range(x_min, x_max)
						pos_enemy.y = randf_range(y_min, y_max)
						aux = pos_enemy.snapped(Vector2.ONE * tile_size) + Vector2.ONE * tile_size/2
						for i in range(0, enemies.size()):
							if enemies[i].position.x == aux.x and enemies[i].position.y == aux.y:
								av_pos = false
								break

					# If the room is so full that we can't find a gap, skip
					# this spawn attempt instead of creating an overlapping enemy.
					if not av_pos:
						continue

					var variant = randf()
					for mob in Enemy:
						if variant >= mob[1] and variant <= mob[2]:
							enemy = mob[0].instantiate()
							break

					add_child(enemy)
					enemies.append(enemy)

					num_enemies += 1

					enemy.position = aux
					enemy.play_mode = true

	# Plague rat: spawns ONE on the last level of Marshlands (the one
	# right before the boss room). Uses any room that is not start
	# nor end so as not to block the player's trajectory.
	if num_level == numlvs - 1 and get_biome() == "Marshlands":
		_spawn_one_plague_rat()

	# Secret Zombie (cross-run revenge): if the player died last run in
	# THIS biome + level index, spawn ONE Zombie here. Consumed (flag
	# cleared) on spawn so it only appears once per run. See GameState
	# for the protocol and Character._record_death_for_zombie for who
	# writes it.
	_try_spawn_zombie()


# Helper: 10% probability PER ROOM of containing an Apple. If the roll
# wins, we pick a random floor tile inside the room (cross-checked against
# floor_cells to avoid cull-removed or non-carved tiles). At ~10 rooms/level
# you expect ~1 apple per level on average; with the 20-hunger restore
# (down from 50) the player gets more frequent but smaller refills.
const APPLE_SPAWN_CHANCE: float = 0.10

func _spawn_apples() -> void:
	var apple_scene = load("res://Apple.tscn")
	if apple_scene == null:
		return
	for room in $Rooms.get_children():
		if not is_instance_valid(room):
			continue
		if randf() >= APPLE_SPAWN_CHANCE:
			continue
		# Room bounding box in tile coords. room.size is in px
		# (set in make_room as Vector2(w,h)*tile_size).
		var x_min: int = int(floor((room.position.x - room.size.x / 2.0) / tile_size))
		var x_max: int = int(floor((room.position.x + room.size.x / 2.0) / tile_size))
		var y_min: int = int(floor((room.position.y - room.size.y / 2.0) / tile_size))
		var y_max: int = int(floor((room.position.y + room.size.y / 2.0) / tile_size))
		# Collect all valid floor tiles of the room, then pick a
		# random one. If the room has no floor tiles (rare but possible if
		# the whole interior was cull-removed), silent skip.
		var valid_cells: Array[Vector2i] = []
		for tx in range(x_min, x_max + 1):
			for ty in range(y_min, y_max + 1):
				var cell = Vector2i(tx, ty)
				if floor_cells.has(cell):
					valid_cells.append(cell)
		if valid_cells.is_empty():
			continue
		var pick: Vector2i = valid_cells[randi() % valid_cells.size()]
		var apple = apple_scene.instantiate()
		apple.position = Vector2(pick.x, pick.y) * tile_size + Vector2.ONE * tile_size / 2
		add_child(apple)
		apples.append(apple)


# Helper: checks if this level matches the GameState zombie target
# (biome + 0-indexed level index) and spawns ONE Mobs/Zombie.tscn in
# a random non-start, non-end room. Consumes the flag so the zombie
# appears at most once per run. Silent if there's no pending target,
# no biome match, no level match, the scene fails to load, or the
# map has no candidate rooms (very degenerate, won't normally happen).
func _try_spawn_zombie() -> void:
	if not GameState.zombie_pending:
		return
	if GameState.zombie_target_biome != get_biome():
		return
	if GameState.zombie_target_level_index != num_level:
		return
	var scene = load("res://Mobs/Zombie.tscn")
	if scene == null:
		return
	var candidates = []
	for r in $Rooms.get_children():
		if not r.start and not r.end:
			candidates.append(r)
	if candidates.is_empty():
		return
	candidates.shuffle()
	var room = candidates[0]
	var aux = room.position.snapped(Vector2.ONE * tile_size) + Vector2.ONE * tile_size / 2
	var zombie = scene.instantiate()
	add_child(zombie)
	enemies.append(zombie)
	num_enemies += 1
	zombie.position = aux
	zombie.play_mode = true
	# Consume — at most one Zombie per run.
	GameState.zombie_pending = false


# Helper: spawns 1 Plague_Big_Rat in a random room (no start/no end).
# Called from create_enemies ONLY on the last level of HR. If for some
# reason there are no valid rooms (degenerate map), skips without error.
func _spawn_one_plague_rat():
	var scene = load("res://Mobs/Marshlands/Plague_Big_Rat.tscn")
	if scene == null:
		return
	var candidates = []
	for r in $Rooms.get_children():
		if not r.start and not r.end:
			candidates.append(r)
	if candidates.is_empty():
		return
	candidates.shuffle()
	var room = candidates[0]
	var aux = room.position.snapped(Vector2.ONE * tile_size) + Vector2.ONE * tile_size / 2
	var rat = scene.instantiate()
	add_child(rat)
	enemies.append(rat)
	num_enemies += 1
	rat.position = aux
	rat.play_mode = true


func make_map():
	# Creates the TileMapLayer from the rooms and the MST path
	Map.clear()
	Scenario.clear()
	find_start_room()
	find_end_room()

	# Bounding rect of all the rooms
	var full_rect = Rect2()
	full_rect.position += Vector2.RIGHT * get_parent().OFFSET * num_level

	for room in $Rooms.get_children():
		var r = Rect2(room.position - room.size, room.get_node("CollisionShape2D").shape.size)
		full_rect = full_rect.merge(r)
	var topleft = Map.local_to_map(full_rect.position)
	var bottomright = Map.local_to_map(full_rect.end)

	# Reset the caches; we will accumulate cells and paint them at the end.
	wall_cells.clear()
	floor_cells.clear()

	# Fill the rect with walls (terrain 1). The rooms and the
	# corridors will move cells from wall_cells to floor_cells.
	for x in range(topleft.x-7, bottomright.x+7):
		for y in range(topleft.y-5, bottomright.y+5):
			wall_cells[Vector2i(x, y)] = true

	# The fog is seeded at the end of make_map, once wall_cells/floor_cells
	# are finalized, as a static band around the painted area.

	# Carving of rooms and registering of points in the AStar2D graph
	var corridors = []

	for room in $Rooms.get_children():
		var r_grid = []
		var s = (room.size / tile_size).floor()
		var ul = (room.position / tile_size).floor() - s

		var size_y = ((s.y * 2) - 3)

		var i = 0
		for x in range(2, s.x * 2 - 1):
			for y in range(2, s.y * 2 - 1):
				var carve = Vector2i(ul.x + x, ul.y + y)
				floor_cells[carve] = true
				wall_cells.erase(carve)
				var aux = Vector2(ul.x+x, ul.y+y) * tile_size + (Vector2.ONE * tile_size/2)

				grid.add_point(idcount, aux)
				r_grid.append(grid.get_closest_point(aux))
				var d_id = -1

				if x != 2:
					grid.connect_points(r_grid[i-size_y], r_grid[i])
				elif x == 2:
					var diag_mm = aux + Vector2(-tile_size, -tile_size)
					d_id = grid.get_closest_point(diag_mm)
					if adjacent(grid.get_point_position(d_id), aux):
						if (r_grid[i] != d_id) and !grid.are_points_connected(r_grid[i], d_id):
							grid.connect_points(r_grid[i], d_id)
					var diag_mp = aux + Vector2(-tile_size, tile_size)
					d_id = grid.get_closest_point(diag_mp)
					if adjacent(grid.get_point_position(d_id), aux):
						if (r_grid[i] != d_id) and !grid.are_points_connected(r_grid[i], d_id):
							grid.connect_points(r_grid[i], d_id)

				if y != 2:
					grid.connect_points(r_grid[i-1], r_grid[i])
				elif y == 2:
					var diag_mm = aux + Vector2(-tile_size, -tile_size)
					d_id = grid.get_closest_point(diag_mm)
					if adjacent(grid.get_point_position(d_id), aux):
						if (r_grid[i] != d_id) and !grid.are_points_connected(r_grid[i], d_id):
							grid.connect_points(r_grid[i], d_id)
					var diag_pm = aux + Vector2(tile_size, -tile_size)
					d_id = grid.get_closest_point(diag_pm)
					if adjacent(grid.get_point_position(d_id), aux):
						if (r_grid[i] != d_id) and !grid.are_points_connected(r_grid[i], d_id):
							grid.connect_points(r_grid[i], d_id)

				if x >= 3:
					if y < (s.y * 2 - 2):
						grid.connect_points(r_grid[i-(size_y-1)], r_grid[i])
					if y > 2:
						grid.connect_points(r_grid[i-(size_y+1)], r_grid[i])

				if x == (s.x * 2 - 2):
					var diag_pm = aux + Vector2(tile_size, -tile_size)
					d_id = grid.get_closest_point(diag_pm)
					if adjacent(grid.get_point_position(d_id), aux):
						if (r_grid[i] != d_id) and !grid.are_points_connected(r_grid[i], d_id):
							grid.connect_points(r_grid[i], d_id)
					var diag_pp = aux + Vector2(tile_size, tile_size)
					d_id = grid.get_closest_point(diag_pp)
					if adjacent(grid.get_point_position(d_id), aux):
						if (r_grid[i] != d_id) and !grid.are_points_connected(r_grid[i], d_id):
							grid.connect_points(r_grid[i], d_id)

				if y == (s.y * 2 - 2):
					var diag_mp = aux + Vector2(-tile_size, tile_size)
					d_id = grid.get_closest_point(diag_mp)
					if adjacent(grid.get_point_position(d_id), aux):
						if (r_grid[i] != d_id) and !grid.are_points_connected(r_grid[i], d_id):
							grid.connect_points(r_grid[i], d_id)
					var diag_pp = aux + Vector2(tile_size, tile_size)
					d_id = grid.get_closest_point(diag_pp)
					if adjacent(grid.get_point_position(d_id), aux):
						if (r_grid[i] != d_id) and !grid.are_points_connected(r_grid[i], d_id):
							grid.connect_points(r_grid[i], d_id)

				idcount += 1
				i += 1

		# Carving of corridors toward the MST neighbors
		var p = path.get_closest_point(Vector3(room.position.x, room.position.y, 0))
		for conn in path.get_point_connections(p):
			if not conn in corridors:
				var start = Map.local_to_map(Vector2(path.get_point_position(p).x, path.get_point_position(p).y))
				var end = Map.local_to_map(Vector2(path.get_point_position(conn).x, path.get_point_position(conn).y))
				# Corridor width: 1 tile 5%, 2 tiles 65%, 3 tiles 30%.
				var r = randf()
				var corridor_width: int
				if r < 0.05:
					corridor_width = 1
				elif r < 0.7:
					corridor_width = 2
				else:
					corridor_width = 3
				carve_path(start, end, corridor_width)
		corridors.append(p)

		# Cleanup of AStar2D points that ended up on wall tiles.
		# (No print: this loop runs N_rooms * N_grid_points times and saturates
		# the engine's output buffer.)
		var g_p = null
		var g_map = null
		for g in grid.get_point_ids():
			g_p = grid.get_point_position(g)
			g_map = Map.local_to_map(g_p)
			if wall_cells.has(g_map):
				grid.remove_point(g)

		# Stairs (terrain 0 = down/exit, terrain 1 = up/entrance).
		if room.start:
			Stairs.set_cells_terrain_connect([Vector2i(ul.x+s.x, ul.y+s.y)], 0, 1)
			start_stair_tile = (ul + s) * tile_size + Vector2.ONE * tile_size/2
		if room.end:
			Stairs.set_cells_terrain_connect([Vector2i(ul.x+s.x, ul.y+s.y)], 0, 0)
			end_stair_tile = (ul + s) * tile_size + Vector2.ONE * tile_size/2

	# Apply the autotile to Map: walls first, then floors, then walls
	# again so their borders refresh now that the floors exist as
	# neighbors. set_cells_terrain_connect picks the correct tile based on the
	# peering bits of the tiles of each terrain.
	# Dictionary.keys() returns an untyped Array; assign() copies it respecting
	# the destination type Array[Vector2i] that set_cells_terrain_connect requires.
	var wall_array: Array[Vector2i] = []
	wall_array.assign(wall_cells.keys())
	var floor_array: Array[Vector2i] = []
	floor_array.assign(floor_cells.keys())
	if wall_array.size() > 0:
		Map.set_cells_terrain_connect(wall_array, 0, 1)
	if floor_array.size() > 0:
		Map.set_cells_terrain_connect(floor_array, 0, 0)
	if wall_array.size() > 0:
		Map.set_cells_terrain_connect(wall_array, 0, 1)

	# Static fog band around the painted area: 10 tiles wide,
	# without touching occupied cells (neither walls nor floors). Replaces the old
	# dynamic LOS — the fog no longer updates per turn.
	var occupied: Dictionary = {}
	for c in wall_cells.keys():
		occupied[c] = true
	for c in floor_cells.keys():
		occupied[c] = true
	make_fog_band(occupied, 10)

	# Tree/bush decoration. Per-biome variations:
	#   - Marshlands: density 0.1 + 3x3 centered clearance (1 tile gap).
	#   - Noob_Woods   : density 0.4 + 2x2 anchored clearance (original).
	var is_haunted = get_biome() == "Marshlands"
	var density: float = 0.1 if is_haunted else 0.4
	var sce = true
	for x in range(topleft.x-7, bottomright.x+6):
		for y in range(topleft.y-5, bottomright.y+4):
			if (randf() < density):
				if is_haunted:
					# 6x5 around the tile (+1 buffer in each direction over
					# the original 4x3): the Marshlands Resources must stay
					# 1 tile farther from the floor so as not to box in the player.
					sce = true
					for i in range(-2, 4):
						for j in range(-2, 3):
							if floor_cells.has(Vector2i(x+i, y+j)):
								sce = false
								break
						if not sce:
							break
				else:
					for i in range(0, 2, 1):
						for j in range(0, 2, 1):
							if floor_cells.has(Vector2i(x+i, y+j)):
								sce = false
				if sce == true:
					var variant = randf()
					var sid: int
					if variant < 0.7:
						sid = 0
					elif variant < 0.85:
						sid = 1
					elif variant < 0.95:
						sid = 2
					else:
						sid = 3
					# If the biome's TileSet does not define that source (e.g. HR
					# only has source 0), fall back to 0. Without this we'd get
					# "phantom cells" recorded with source 1/2/3 that didn't
					# render but spammed errors whenever something called
					# get_cell_tile_data on them (laser, debug, etc).
					if Scenario.tile_set == null or not Scenario.tile_set.has_source(sid):
						sid = 0
					Scenario.set_cell(Vector2i(x, y), sid, Vector2i(0, 0))
				else:
					sce = true


func carve_path(pos1, pos2, width: int = 1):
	var last = -1

	# Perpendicular offsets to the advance direction to widen the
	# corridor. The extra carving only converts wall->floor; no
	# points are added to the AStar graph (the original center line already connects the MST and
	# is enough for player and enemy pathfinding).
	#   width 1 -> []         (not widened)
	#   width 2 -> [+/-1]     (2 tiles, random side)
	#   width 3 -> [-1, 1]    (3 tiles, centered)
	var perp_offsets: Array
	match width:
		2: perp_offsets = [1 if randi() % 2 == 0 else -1]
		3: perp_offsets = [-1, 1]
		_: perp_offsets = []

	var x_diff = sign(pos2.x - pos1.x)
	var y_diff = sign(pos2.y - pos1.y)
	if x_diff == 0: x_diff = pow(-1.0, randi() % 2)
	if y_diff == 0: y_diff = pow(-1.0, randi() % 2)

	# Randomly chooses whether to traverse X first or Y first
	var x_y = pos1
	var y_x = pos2
	if (randi() % 2) > 0:
		x_y = pos2
		y_x = pos1

	for x in range(pos1.x, pos2.x+x_diff, x_diff):
		# Widening: carves walls into perpendicular tiles (Y axis).
		for off in perp_offsets:
			var wide = Vector2i(x, x_y.y + off)
			if wall_cells.has(wide):
				wall_cells.erase(wide)
				floor_cells[wide] = true
		var coord = Vector2i(x, x_y.y)
		if wall_cells.has(coord):
			wall_cells.erase(coord)
			floor_cells[coord] = true

			var aux = Vector2(0, 0)

			if last != -1:
				grid.add_point(idcount, Vector2(x, x_y.y) * tile_size + (Vector2.ONE * tile_size/2) + aux)
				grid.connect_points(idcount, last)

				# Diagonals with the existing neighbors
				for point in grid.get_point_ids():
					if idcount != point:
						var p_p1 = grid.get_point_position(idcount)
						var p_p2 = grid.get_point_position(point)
						if adjacent(p_p1, p_p2):
							grid.connect_points(point, idcount)

				last = idcount
				idcount += 1
			else:
				grid.add_point(idcount, Vector2(x, x_y.y) * tile_size + (Vector2.ONE * tile_size/2))
				last = grid.get_closest_point(Vector2(x-x_diff, x_y.y) * tile_size + (Vector2.ONE * tile_size/2))
				if idcount != last:
					grid.connect_points(idcount, last)

				last = idcount
				idcount += 1
		else:
			if last != -1:
				last = grid.get_closest_point(Vector2(x, x_y.y) * tile_size + (Vector2.ONE * tile_size/2))
				var aux = grid.get_closest_point(Vector2(x-x_diff, x_y.y) * tile_size + (Vector2.ONE * tile_size/2))
				var adj = adjacent(grid.get_point_position(aux), grid.get_point_position(last))
				if aux != last and adj:
					grid.connect_points(aux, last)
			else:
				last = grid.get_closest_point(Vector2(x, x_y.y) * tile_size + (Vector2.ONE * tile_size/2))
				var aux = grid.get_closest_point(Vector2(x-x_diff, x_y.y) * tile_size + (Vector2.ONE * tile_size/2))
				var adj = adjacent(grid.get_point_position(aux), grid.get_point_position(last))
				if aux != last and adj:
					grid.connect_points(aux, last)

	for y in range(pos1.y, pos2.y+y_diff, y_diff):
		# Widening: carves walls into perpendicular tiles (X axis).
		for off in perp_offsets:
			var wide = Vector2i(y_x.x + off, y)
			if wall_cells.has(wide):
				wall_cells.erase(wide)
				floor_cells[wide] = true
		var coord_y = Vector2i(y_x.x, y)
		if wall_cells.has(coord_y):
			wall_cells.erase(coord_y)
			floor_cells[coord_y] = true
			var aux = Vector2(0, 0)

			if last != -1:
				grid.add_point(idcount, Vector2(y_x.x, y) * tile_size + (Vector2.ONE * tile_size/2) + aux)
				grid.connect_points(idcount, last)

				# Diagonals with the existing neighbors
				for point in grid.get_point_ids():
					if idcount != point:
						var p_p1 = grid.get_point_position(idcount)
						var p_p2 = grid.get_point_position(point)
						if adjacent(p_p1, p_p2):
							grid.connect_points(point, idcount)

				last = idcount
				idcount += 1
			else:
				grid.add_point(idcount, Vector2(y_x.x, y) * tile_size + (Vector2.ONE * tile_size/2))
				last = grid.get_closest_point(Vector2(y_x.x, y-y_diff) * tile_size + (Vector2.ONE * tile_size/2))
				grid.connect_points(idcount, last)

				last = idcount
				idcount += 1
		else:
			if last != -1:
				last = grid.get_closest_point(Vector2(y_x.x, y) * tile_size + (Vector2.ONE * tile_size/2))
				var aux = grid.get_closest_point(Vector2(y_x.x, y-y_diff) * tile_size + (Vector2.ONE * tile_size/2))
				var adj = adjacent(grid.get_point_position(aux), grid.get_point_position(last))
				if aux != last and adj:
					grid.connect_points(aux, last)
			else:
				last = grid.get_closest_point(Vector2(y_x.x, y) * tile_size + (Vector2.ONE * tile_size/2))
				var aux = grid.get_closest_point(Vector2(y_x.x, y-y_diff) * tile_size + (Vector2.ONE * tile_size/2))
				var adj = adjacent(grid.get_point_position(aux), grid.get_point_position(last))
				if aux != last and adj:
					grid.connect_points(aux, last)


# --- LevelBase overrides ---

# In real time the player does not reach exactly the tile center, so
# we use a distance threshold (~10 px) instead of is_equal_approx.
const _STAIR_TRIGGER_DIST: float = 10.0


func player_gone():
	if get_parent() == null:
		return false
	if start_stair_tile != null and player.position.distance_to(start_stair_tile) <= _STAIR_TRIGGER_DIST:
		return get_parent().can_change_room("up")
	if end_stair_tile != null and player.position.distance_to(end_stair_tile) <= _STAIR_TRIGGER_DIST:
		return get_parent().can_change_room("down")
	return false


func _on_player_gone():
	var x = ""
	if start_stair_tile != null and player.position.distance_to(start_stair_tile) <= _STAIR_TRIGGER_DIST:
		x = "up"
	elif end_stair_tile != null and player.position.distance_to(end_stair_tile) <= _STAIR_TRIGGER_DIST:
		x = "down"
	get_parent().change_room(x)
