extends Node2D
class_name LevelBase

###########################################################################
### LEVELBASE: base class shared by Level / Entrance / BossRoom         ###
### Contains static fog, pathfinding queries and utilities.             ###
### Movement is in real time (CharacterBody2D + move_and_slide          ###
### in Character/Enemy), there is no turn system nor tile reservations. ###
### Subclasses override:                                                 ###
###   - charge(...)         map construction (procedural vs fixed)     ###
###   - player_gone()       level transition check (realtime)           ###
###   - _on_player_gone()   action on transition                        ###
###########################################################################
### Godot 4.4 port:                                                      ##
### - TileMapLayer replaces TileMap. set_cell(coord, source_id,          ##
###   atlas_coords). source_id keeps the semantics of tile_id from 3.x   ##
### - Navigation2D removed from the tree.                                ##
### - AStar (3D) -> AStar3D. AStar2D same.                               ##
### - update() -> queue_redraw().                                        ##
### - update_bitmask_area(...) removed: autotiling is done by            ##
###   terrains (set_cells_terrain_connect) if the TileSets are           ##
###   re-authored with terrains, or omitted otherwise.                   ##
###########################################################################

var Room = preload("res://Room.tscn")
var Player = preload("res://Character.tscn")
var font = preload("res://assets/RobotoBold120.tres")

var enemies = []
# Prizes dropped by killed enemies. Enemy.kill() appends them, and
# Character._check_prize_pickup iterates them and consumes by proximity.
# They are freed together with the level when changing level.
var prizes: Array = []
# Hearts (heal pickups) dropped at a flat 10% by Enemy.kill(),
# independent of the prize. Same lifecycle as prizes.
var hearts: Array = []
# Apples (hunger restore +50) spawn procedurally on floor tiles of
# rooms when generating the level — Level.gd::charge seeds them at 2% per tile.
# Not dropped by enemies. Same lifecycle as prizes/hearts.
var apples: Array = []
# Batteries (ammo restore +10) dropped at a flat 5% by Enemy.kill(),
# independent of prize/heart. Same lifecycle.
var batteries: Array = []

@onready var Scenario: TileMapLayer = $Scenario
@onready var Stairs: TileMapLayer = $Stairs
@onready var Map: TileMapLayer = $Map
@onready var line_2d: Line2D = $Line2D
@onready var Cam_2d: Camera2D = $Camera2D
@onready var Fog: TileMapLayer = $Fog

var tile_size = 32
var num_enemies = 0

var path  # AStar3D used by Level for the MST; null in Entrance/Boss
var start_room = null
var end_room = null
var start_stair_tile = null
var end_stair_tile = null

var play_mode = false
var player = null
var enemy = null

# Rising-edge debounce for the stair transition: we only fire
# _on_player_gone() when player_gone() returns true AND the previous frame
# returned false. This avoids the infinite loop when the player spawns
# DIRECTLY on top of a stair when entering a new level — they need
# to move off and back to fire another transition.
# We initialize to true so the first post-spawn frame doesn't fire.
var _was_on_stair: bool = true

var num_level = 0
var grid_map = []
var idcount = 0
var grid = AStar2D.new()

var charging = false


func _ready():
	randomize()
	# Explicit z_index per layer:
	#   Map / Stairs : -1  → always below the actors (taken out of the parent's
	#     Y-sort; otherwise, with Map.position=(0,0) and player.position.y<0 the
	#     player would end up BEHIND the map). They are in their own z-group.
	#   player / enemies : 0 (default, Y-sorted against each other)
	#   Scenario     :  1  → above the player (trees cover the actor).
	#   Fog          :  2  → always above everything.
	Map.z_index = -1
	Stairs.z_index = -1
	Scenario.z_index = 1
	Fog.z_index = 2
	# Disables Y-sort inside the TileMapLayers — each layer is drawn as
	# a "flat" plane, without individual tiles reordering against each other
	# by their Y. Combined with the z_indexes above, the layers stay OUTSIDE
	# the parent's Y-sort.
	Map.y_sort_enabled = false
	Scenario.y_sort_enabled = false
	Stairs.y_sort_enabled = false
	Fog.y_sort_enabled = false
	# Y-sort on the parent so that siblings at the same z_index (player +
	# enemies at z=0) are ordered by Y. The TileMapLayers don't participate
	# because their z_index already put them in another z-group.
	y_sort_enabled = true


func _process(_delta):
	if not play_mode or player == null:
		return
	# Subclass decides (via player_gone) whether the player's position counts as
	# "on a transition stair".
	var gone = player_gone()
	# We only fire on the rising edge: was off the previous frame,
	# just stepped onto the stair. Avoids the infinite loop when the player
	# spawns ON a stair when loading the new level.
	if gone and not _was_on_stair:
		play_mode = false
		_on_player_gone()
	_was_on_stair = gone


func activate():
	play_mode = true
	# Spawn protection: when a level is re-activated (e.g. coming back via "up"
	# from the next one), the player is placed on a stair and we do NOT
	# want to fire an immediate transition. We mark it as if it were already
	# on a stair so the rising-edge requires leaving and coming back.
	_was_on_stair = true
	for enem in enemies:
		enem.play_mode = true


func deactivate():
	play_mode = false
	if player != null:
		player.path = PackedVector2Array()
	# Symmetric with activate(): we freeze the level's enemies so they
	# don't move or attack while this level is "out of focus" (e.g.
	# during a loading screen in a new room). Restored by
	# activate() when the player returns.
	for enem in enemies:
		if enem != null:
			enem.play_mode = false


# BGM track identifier for this scene. Main.gd calls this when loading/
# transitioning to the level and applies the track centrally (creates a new
# AudioStreamPlayer only if it differs from the current one). Default: derived from
# the biome. BossRoom overrides to "Boss" in Marshlands.
func get_bgm_track() -> String:
	if get_biome() == "Marshlands":
		return "Swamp"
	return "StrangeFarm"


### -------------------- FOG OF WAR (static band) --------------------

# Paints a fog band (Fog's terrain 0) around the rect occupied
# by the painted map cells. `occupied` is the set of painted cells
# (floors + walls). The fog covers:
#   1) Everything that falls inside the inflated rect and is NOT in `occupied`.
#   2) The cells of occupied that are in the outer ring — those that have
#      at least one cardinal neighbor NOT painted. This makes the fog overlap
#      1 tile with the outer border of the map (the outermost walls).
# Interior cells (surrounded by occupied on all 4 sides) stay clean.
#
#   padding   tiles of band beyond the occupied bounding rect (15 ~= 5
#             tiles more than the previous version, per Croakzilla adjustment).
#
# Replacement of the old dynamic LOS: the fog no longer updates per turn,
# it is seeded only once when loading the level.
func make_fog_band(occupied: Dictionary, padding: int = 15):
	if occupied.is_empty():
		return
	var keys := occupied.keys()
	var first: Vector2i = keys[0]
	var min_x: int = first.x
	var min_y: int = first.y
	var max_x: int = first.x
	var max_y: int = first.y
	for c in keys:
		if c.x < min_x: min_x = c.x
		if c.x > max_x: max_x = c.x
		if c.y < min_y: min_y = c.y
		if c.y > max_y: max_y = c.y

	# Identifies the outer ring: painted cells with >= 1 cardinal neighbor
	# NOT painted. These are the map border walls that the fog must
	# overlap by 1 tile (as requested).
	var outer_ring: Dictionary = {}
	const _NEIGHBORS = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for c in keys:
		for d in _NEIGHBORS:
			if not occupied.has(c + d):
				outer_ring[c] = true
				break

	var fog_cells: Array[Vector2i] = []
	for x in range(min_x - padding, max_x + padding + 1):
		for y in range(min_y - padding, max_y + padding + 1):
			var cell := Vector2i(x, y)
			if occupied.has(cell):
				if outer_ring.has(cell):
					fog_cells.append(cell)  # overlap 1 tile over border
				# else: interior painted cell, kept clean
			else:
				fog_cells.append(cell)
	if fog_cells.size() > 0:
		# ignore_empty_terrains=false: empty cells (map interior)
		# count as real terrain -1 so the autotile picks correct border
		# variants against the playable area.
		Fog.set_cells_terrain_connect(fog_cells, 0, 0, false)


# Returns true if the cell is painted as floor (terrain 0 inside the
# TileMapLayer Map's terrain set 0).
func map_is_floor(coord: Vector2i) -> bool:
	var data = Map.get_cell_tile_data(coord)
	return data != null and data.terrain == 0


# Returns the name of the current biome ("Noob_Woods" / "Marshlands" / "")
# inferred from the Map's TileSet path. Used to differentiate generation
# rules (e.g. scenery clearance) without having to wire it per scene.
func get_biome() -> String:
	if Map == null or Map.tile_set == null:
		return ""
	var pathh: String = Map.tile_set.resource_path
	if "Marshlands" in pathh:
		return "Marshlands"
	if "Noob_Woods" in pathh:
		return "Noob_Woods"
	return ""


# Returns true if the cell is painted as wall (terrain 1) or not painted
# at all (empty outside the map). Used by Character/Enemy for manual
# movement blocking (the TileSets have physical collisions on *all*
# tiles, not just walls, so we can't use move_and_slide for the wall).
func map_is_wall(coord: Vector2i) -> bool:
	var data = Map.get_cell_tile_data(coord)
	# Empty tile (outside painted map) counts as wall: the player must not
	# leave the generated rect.
	if data == null:
		return true
	if data.terrain != 1:
		return false
	# Marshlands: walls without a defined physics_layer_0 polygon count as
	# passable (biome feature — tiles painted as "wall" so that
	# the autotile connects them as borders, but without real collision). Affects
	# movement (Character + Enemy _blocked_by_wall), enemy LOS
	# (_player_visible), and click-to-move via AStar (the "wall without
	# collision" tiles are not filtered as floor for AStar, but actual
	# movement goes through them). In other biomes, terrain==1 is still a solid
	# wall regardless of the physics_layer.
	if get_biome() == "Marshlands":
		if data.get_collision_polygons_count(0) == 0:
			return false
	return true


# Virtual. Returns true if the player's position is on a transition stair.
# Called every _process() in real time; use a distance margin
# (not is_equal_approx) because realtime positions don't fall
# exactly at the tile center.
func player_gone():
	return false


# Virtual. Action when the transition is confirmed.
func _on_player_gone():
	pass


# Virtual: returns the "kind" of this level — "entrance" / "level" / "boss".
# Default "level" (procedural Level.gd). Overridden in Entrance.gd and
# BossRoom.gd. Used by Character.kill() to record the death location so
# the secret Zombie can be spawned in the appropriate level next run.
func get_level_kind() -> String:
	return "level"


# Virtual. True only in BossRoom. Used by Character.damage to apply
# Hell's x2 to boss room enemies (subclass override returns true).
func is_boss_room() -> bool:
	return false


### -------------------- PATHFINDING QUERIES --------------------

func ask_path():
	var pos_fog = Fog.local_to_map(get_global_mouse_position())
	if Fog.get_cell_source_id(pos_fog) == 0:
		return
	var dest = grid.get_closest_point(get_global_mouse_position())
	var origin = grid.get_closest_point(player.position)
	# If the AStar2D graph is empty (map without floor-tiles), get_closest_point
	# returns -1. Exit so as not to break get_point_position / get_point_path.
	if dest == -1 or origin == -1:
		return
	var d = grid.get_point_position(dest)

	var new_path2d = PackedVector2Array()
	var locx = abs((get_global_mouse_position() - d).x)
	var locy = abs((get_global_mouse_position() - d).y)
	if locx > tile_size/2 or locy > tile_size/2:
		return

	new_path2d = grid.get_point_path(origin, dest)
	for i in range(0, new_path2d.size()):
		if new_path2d[i] == start_stair_tile or new_path2d[i] == end_stair_tile:
			if (i != (new_path2d.size()-1)) and (i > 0):
				new_path2d.resize(i-1)
				break

	player.path = new_path2d


func ask_for_path_player(enem):
	var dest = grid.get_closest_point(player.position)
	var enemy_pos = grid.get_closest_point(enem.position)
	if dest == -1 or enemy_pos == -1:
		enem.path = PackedVector2Array()
		return

	# get_point_path returns the route INCLUDING both endpoints. The Enemy.path
	# setter removes the first one (the enemy's own position), so
	# the route ends up as [..., player_tile]. The enemy walks toward the
	# player's tile; the collision system (ACTOR_RADIUS_VS_PLAYER = 14) stops it at
	# ~14 px from the player, inside ATTACK_RANGE_PX = 16 -> the attack fires.
	# We do NOT remove the last waypoint (inherited from the turn-based version) —
	# if we did, at 1-2 tiles from the player the route would end up empty and the
	# enemy would stop 1 tile (32 px) outside the attack range.
	enem.path = grid.get_point_path(enemy_pos, dest)


### -------------------- UTIL --------------------

func in_map():
	var dest = get_global_mouse_position()
	dest = Map.local_to_map(dest)
	var coord = null
	for i in range(0, grid_map.size(), 1):
		if grid_map[i] == dest:
			coord = dest
	return coord


func adjacent(pos1, pos2):
	if abs(pos1.x - pos2.x) <= tile_size and abs(pos1.y - pos2.y) <= tile_size:
		return true
	return false


func adj_attack(pos1, pos2):
	# Click-to-punch reach: tile_size * 0.75 (= 24 px with tile_size=32),
	# a +50% over the original tile_size/2. Makes the click target more
	# tolerant for activating the melee attack on nearby enemies.
	var reach = tile_size * 0.75
	if abs(pos1.x - pos2.x) <= reach and abs(pos1.y - pos2.y) <= reach:
		return true
	return false


### -------------------- MST (used by Level) --------------------

func find_mst(nodes):
	# Prim's algorithm over the room centers.
	path = AStar3D.new()
	path.add_point(path.get_available_point_id(), nodes.pop_front())

	while nodes:
		var min_dist = INF
		var min_p = null
		var p = null
		for p1 in path.get_point_ids():
			p1 = path.get_point_position(p1)
			for p2 in nodes:
				if p1.distance_to(p2) < min_dist:
					min_dist = p1.distance_to(p2)
					min_p = p2
					p = p1
		var n = path.get_available_point_id()
		path.add_point(n, min_p)
		path.connect_points(path.get_closest_point(p), n)
		nodes.erase(min_p)
	return path


### -------------------- FIXED MAP SCAN (used by Entrance / BossRoom) --------------------

# Builds the AStar2D graph by scanning the fixed TileMapLayer in the rect (0..25, 0..25).
# Each floor tile (terrain 0) becomes a point and is connected to its
# cardinal and diagonal neighbors if they are also floor. Uses map_is_floor()
# so that it works with any TileSet sources structure.
func scan_existing_map():
	for x in range(0, 25):
		for y in range(0, 25):
			if map_is_floor(Vector2i(x, y)):
				var aux = Vector2(x, y) * tile_size + (Vector2.ONE * tile_size/2)
				grid.add_point(idcount, aux)
				idcount += 1

	for x in range(0, 25):
		for y in range(0, 25):
			if map_is_floor(Vector2i(x, y)):
				var aux = Vector2(x, y) * tile_size + (Vector2.ONE * tile_size/2)
				var a_id = grid.get_closest_point(aux)

				if map_is_floor(Vector2i(x+1, y)):
					var aux2 = Vector2(x+1, y) * tile_size + (Vector2.ONE * tile_size/2)
					var b_id = grid.get_closest_point(aux2)
					if a_id != b_id:
						grid.connect_points(a_id, b_id)

				if map_is_floor(Vector2i(x, y+1)):
					var aux2 = Vector2(x, y+1) * tile_size + (Vector2.ONE * tile_size/2)
					var b_id = grid.get_closest_point(aux2)
					if a_id != b_id:
						grid.connect_points(a_id, b_id)

				if map_is_floor(Vector2i(x+1, y+1)):
					var aux2 = Vector2(x+1, y+1) * tile_size + (Vector2.ONE * tile_size/2)
					var b_id = grid.get_closest_point(aux2)
					if a_id != b_id:
						grid.connect_points(a_id, b_id)

				if map_is_floor(Vector2i(x+1, y-1)):
					var aux2 = Vector2(x+1, y-1) * tile_size + (Vector2.ONE * tile_size/2)
					var b_id = grid.get_closest_point(aux2)
					if a_id != b_id:
						grid.connect_points(a_id, b_id)


### -------------------- ROOM SELECTION (used by Level) --------------------

# Pick a room as start/end at random among those not already taken.
# With min_rooms=10 this always finds one, but we add an iteration
# cap as defense: if for some reason the rooms array ends up with
# only one marked start/end, the while becomes infinite and the game hangs.
func find_start_room():
	var children = $Rooms.get_children()
	if children.is_empty():
		return
	var attempts := 0
	while attempts < 200:
		attempts += 1
		var room = children[randi() % children.size()]
		if !(room.end):
			start_room = room
			room.start = true
			return
	# Fallback: no free room — grab the first one.
	start_room = children[0]
	start_room.start = true


func find_end_room():
	var children = $Rooms.get_children()
	if children.is_empty():
		return
	var attempts := 0
	while attempts < 200:
		attempts += 1
		var room = children[randi() % children.size()]
		if !(room.start):
			end_room = room
			room.end = true
			return
	# Fallback: grab the last one (probably different from start).
	end_room = children[children.size() - 1]
	end_room.end = true
