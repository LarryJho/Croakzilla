extends Control

# Paginated tutorial: Each page is a dict; the index
# `current_page` decides what is shown. Prev/Next navigate; Finish returns
# to Main_Menu and only appears on the last page.

@onready var title_label: Label = $TitleLabel
@onready var body_label: Label = $BodyLabel
@onready var enemy_sprite: TextureRect = $EnemySprite
@onready var player_sprite: TextureRect = $PlayerSprite
@onready var prev_button: TextureButton = $PrevButton
@onready var next_button: TextureButton = $NextButton
@onready var finish_button: TextureButton = $FinishButton

var current_page: int = 0

# BodyLabel defaults captured in _ready, used to apply per-page offsets
# (a page can set body_offset_y to lift its body N pixels up).
var _body_default_offset_top: float
var _body_default_offset_bottom: float

# Each page: title + body + optional enemy_texture (path to the enemy's
# PNG). When enemy_texture is set, the first frame is shown via an
# AtlasTexture; default region is (0,0,32,32) but a page can override with
# enemy_region. Optional body_offset_y shifts the BodyLabel up by N px
# (useful when a page has no enemy sprite filling the right slot, so the
# text can occupy a higher visual position).
var pages: Array = [
	{
		"title": "Common Man's Plague Control",
		"body": "You are Edward Salami, owner of Common Man's Plague Control.\n\nThe local national park has called you in to handle a crisis.",
		"enemy_texture": "",
	},
	{
		"title": "Your Mission",
		"body": "A giant mutant animal is destroying the ecosystem. Eradicate it.\n\nA rat plague is spreading. Wipe it out.\n\nDo your job well — a 5-star recommendation means more contracts.",
		"enemy_texture": "",
	},
	{
		"title": "Beware the Snakes",
		"body": "Snakes are NOT a plague in this national park.\n\nThey are a protected species. If you kill one, you LOSE points.\n\nLet them be.",
		"enemy_texture": "",
	},
	{
		"title": "Your Stats",
		"body": "HEALTH — if it reaches zero, you die.\n\nHUNGER — when you starve, you start taking damage and can die from it.\n\nENERGY — recharges automatically. Needed to fire the gun you stole from a government facility.",
		"enemy_texture": "",
	},
	{
		"title": "Controls",
		"body": "MOVE     WASD or Arrow keys\nSHOOT    Space (works in either beam mode)\nCLICK    Behavior depends on beam mode — see next page\nSCROLL   Zoom camera in / out\nESC      Pause / unpause (also toggles the pause menu)",
		"enemy_texture": "",
	},
	{
		"title": "Beam Modes",
		"body": "After picking difficulty, you'll also pick a beam mode:\n\nFIXED  — beam fires in the direction you last moved (4 cardinals only). Left-click PUNCHES adjacent enemies or WALKS to the clicked floor tile.\n\nCURSOR — beam fires toward your mouse cursor (any angle). The sprite turns to face the cursor each shot. Left-click FIRES. Movement is keyboard-only (no walk-to-click).",
		"enemy_texture": "",
		"body_offset_y": 50,
	},
	{
		"title": "What You'll Face",
		"body": "The park is crawling with creatures. Some are part of the plague — kill them for points. Others are NOT — kill them and you lose points (the snake is one such example).\n\nExpect stronger variants of the basic mobs deeper in the run, and at least one secret enemy that appears only under certain conditions. Stay alert.",
		"enemy_texture": "",
	},
	{
		"title": "Big Rat",
		"body": "Pest. Skittish — runs when it sees you but turns to fight when cornered.\n\nKill score: +5",
		"enemy_texture": "res://assets/sprites/Noob_Woods/NW_Rat.png",
	},
	{
		"title": "Snake",
		"body": "PROTECTED SPECIES. Do not engage.\n\nKill score: -10",
		"enemy_texture": "res://assets/sprites/Noob_Woods/NW_Snek.png",
	},
	{
		"title": "Giant Shroom",
		"body": "A walking fungus. Sluggish at first but persistent when it chases you.\n\nKill score: +1",
		"enemy_texture": "res://assets/sprites/Noob_Woods/NW_giant_shroom.png",
	},
]


func _ready() -> void:
	prev_button.pressed.connect(_on_prev_pressed)
	next_button.pressed.connect(_on_next_pressed)
	finish_button.pressed.connect(_on_finish_pressed)
	# Snapshot BodyLabel defaults from the .tscn so per-page
	# body_offset_y can shift relative to them (and revert cleanly).
	_body_default_offset_top = body_label.offset_top
	_body_default_offset_bottom = body_label.offset_bottom
	_show_page(0)


# Paints the page at the given index. Idempotent — recalculates visibility
# of buttons and enemy sprite each time. Clamps the index for safety even
# though the handlers already bound-check.
func _show_page(idx: int) -> void:
	current_page = clamp(idx, 0, pages.size() - 1)
	var page = pages[current_page]
	title_label.text = page["title"]
	body_label.text = page["body"]
	# Optional per-page vertical offset for the body (lifts the text
	# block by N px). Pages without `body_offset_y` snap back to the
	# .tscn defaults captured in _ready.
	var offset_y: float = float(page.get("body_offset_y", 0))
	body_label.offset_top = _body_default_offset_top - offset_y
	body_label.offset_bottom = _body_default_offset_bottom - offset_y
	# Enemy sprite: visible only if the page references a texture.
	# Build AtlasTexture at runtime to show only the first frame of
	# the sprite sheet. Default region is (0,0,32,32) for regular mobs;
	# pages can override with enemy_region for larger sheets (Croakzilla
	# uses 64x64 frames).
	var tex_path: String = page["enemy_texture"]
	if tex_path == "":
		enemy_sprite.visible = false
		enemy_sprite.texture = null
	else:
		var src = load(tex_path)
		if src != null:
			var atlas := AtlasTexture.new()
			atlas.atlas = src
			atlas.region = page.get("enemy_region", Rect2(0, 0, 32, 32))
			enemy_sprite.texture = atlas
			enemy_sprite.visible = true
		else:
			enemy_sprite.visible = false
	# PlayerSprite (Edward) only on the first page (lore intro).
	player_sprite.visible = current_page == 0
	# Button visibility: Prev hidden on first, Next hidden on last,
	# Finish visible only on last.
	prev_button.visible = current_page > 0
	var on_last = current_page >= pages.size() - 1
	next_button.visible = not on_last
	finish_button.visible = on_last


func _on_prev_pressed() -> void:
	if current_page > 0:
		_show_page(current_page - 1)


func _on_next_pressed() -> void:
	if current_page < pages.size() - 1:
		_show_page(current_page + 1)


func _on_finish_pressed() -> void:
	get_tree().change_scene_to_file("res://interface/Main_Menu.tscn")
