extends CanvasLayer


func _ready():
	pass # Replace with function body.

func make_invisible():
	Control.visible = false

func change_visibility():
	Control.visible = !Control.visible
