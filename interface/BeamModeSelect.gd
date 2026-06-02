extends Control

# Second step of the run setup (after DifficultySelect). Lets the player
# choose how the laser aims:
#   - FIXED  : along the player's last cardinal facing (current default).
#   - CURSOR : toward the global mouse position (the original Godot-3
#              free-aim behavior, restored as a mode).
# Selection is stashed in GameState.beam_mode (static var) and read by
# Character._shoot_laser when computing the beam direction.

@onready var fixed_btn: TextureButton = $VBoxContainer/FixedButton
@onready var cursor_btn: TextureButton = $VBoxContainer/CursorButton


func _ready() -> void:
	fixed_btn.pressed.connect(_select.bind("fixed"))
	cursor_btn.pressed.connect(_select.bind("cursor"))


func _select(mode: String) -> void:
	GameState.beam_mode = mode
	get_tree().change_scene_to_file("res://Main.tscn")
