extends Control


# Declare member variables here. Examples:
# var a = 2
# var b = "text"

var maximum_value = 100
# Called when the node enters the scene tree for the first time.
func initialize():
	maximum_value = 100
	$LifeBar.max_value = 100

func _on_Character_health_updated(health,max_health = 100):
	$LifeBar.value = health
	$LifeLabel.text = "%s/%s" % [health,max_health]
# Called every frame. 'delta' is the elapsed time since the previous frame.
#func _process(delta):
#	pass
