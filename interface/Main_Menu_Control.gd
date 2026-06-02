extends Control


# Declare member variables here. Examples:
# var a = 2
# var b = "text"


# Called when the node enters the scene tree for the first time.
func _ready():
	# The Storm BGM loop is set via edit/loop_mode=1 in the .wav.import
	# (compress/mode=0 = PCM uncompressed). Do NOT mutate stream.loop_mode at
	# runtime — that breaks AudioStreamWAV with QOA.
	# Safety net: finished -> play() ensures Storm loops even if the
	# .import doesn't apply loop_mode correctly. Same pattern as Main.gd.
	var bgm = get_parent().get_node_or_null("Bgm")
	if bgm != null and not bgm.finished.is_connected(bgm.play):
		bgm.finished.connect(bgm.play)


# Called every frame. 'delta' is the elapsed time since the previous frame.
#func _process(delta):
#	pass


func _on_Start_pressed():
	# We go through the difficulty screen before Main; the handler of the
	# 4 buttons sets GameState.difficulty and then loads Main.tscn.
	get_tree().change_scene_to_file("res://interface/DifficultySelect.tscn")


func _on_Quit_pressed():
	get_tree().quit()


# Repurposed: the menu's "Records" button now opens the Tutorial. If a
# records screen is implemented in the future, move this handler to a
# dedicated button or rename the "Records" label again.
func _on_Records_pressed():
	get_tree().change_scene_to_file("res://interface/Tutorial.tscn")


func _on_Settings_pressed():
	get_tree().change_scene_to_file("res://interface/Settings.tscn")
