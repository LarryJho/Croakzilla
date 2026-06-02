extends Control

@onready var score_label: Label = $ScoreLabel
@onready var died_to_label: Label = $DiedToLabel
@onready var retry_button: TextureButton = $RetryButton
@onready var menu_button: TextureButton = $MenuButton


func _ready() -> void:
	score_label.text = "SCORE: %d" % GameState.last_score
	var src = GameState.last_damage_source

	if src == "" or src == "hunger":
		died_to_label.text = "Died of hunger."
	else:
		died_to_label.text = "Died to %s." % src.capitalize()
	retry_button.pressed.connect(_on_retry_pressed)
	menu_button.pressed.connect(_on_menu_pressed)


func _on_retry_pressed() -> void:
	# Retry = reload Main.tscn directly to start a new run.
	# We skip Main_Menu to avoid an extra click. Main._ready
	# rebuilds Entrance + player from scratch (the static vars of
	# GameState are not cleared, but they get overwritten on the next kill).
	get_tree().change_scene_to_file("res://Main.tscn")


func _on_menu_pressed() -> void:
	# Returns to the main menu. The user can then click "Play" to start
	# a new run. Same path as the PauseMenu's Quit.
	get_tree().change_scene_to_file("res://interface/Main_Menu.tscn")
