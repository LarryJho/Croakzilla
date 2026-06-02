extends CanvasLayer

# Full-screen overlay shown during the async generation of new levels
# (enter_dungeon, change_room("down") new-level branch). Reuses the
# Character's SpriteFrames to show the "Der_Move" animation centered.
# process_mode = ALWAYS so the animation keeps ticking even when
# get_tree().paused = true.

@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D


func _ready() -> void:
	# Reuse of the Character's SpriteFrames: instantiate once, copy the
	# resource reference (shared via reference-counting) and free the temp
	# char without adding it to the tree.
	var char_scene = preload("res://Character.tscn")
	var temp = char_scene.instantiate()
	var anim = temp.find_child("AnimatedSprite2D", true, false)
	if anim != null and anim.sprite_frames != null:
		sprite.sprite_frames = anim.sprite_frames
	temp.free()
	_center_sprite()
	get_viewport().size_changed.connect(_center_sprite)


# Centers the sprite in the viewport. CanvasLayer has no auto-anchoring,
# so we do it manually. Re-called on size_changed in case the window
# is resized during loading.
func _center_sprite() -> void:
	var vp = get_viewport().get_visible_rect().size
	sprite.position = vp / 2.0


func show_loading() -> void:
	visible = true
	sprite.play("Der_Move")


func hide_loading() -> void:
	sprite.stop()
	visible = false
