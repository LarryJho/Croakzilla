extends Control

@onready var baby_btn: TextureButton = $VBoxContainer/BabyButton
@onready var normal_btn: TextureButton = $VBoxContainer/NormalButton
@onready var hell_btn: TextureButton = $VBoxContainer/HellButton
@onready var nonsense_btn: TextureButton = $VBoxContainer/NonsenseButton


func _ready() -> void:
	baby_btn.pressed.connect(_select.bind("Baby"))
	normal_btn.pressed.connect(_select.bind("Normal"))
	hell_btn.pressed.connect(_select.bind("Hell"))
	nonsense_btn.pressed.connect(_select.bind("This doesn't make any sense"))


# Stash difficulty in GameState (static var) and proceed to the BeamMode
# selection screen, which is the last step before Main.tscn. Main.gd reads
# GameState.difficulty in _ready and applies the multipliers to the biome
# arrays; Character/Enemy/AmmoMenu/HungerMenu also read it to adjust their
# behavior (speed, recharge, damage taken, starvation).
func _select(d: String) -> void:
	GameState.difficulty = d
	get_tree().change_scene_to_file("res://interface/BeamModeSelect.tscn")
