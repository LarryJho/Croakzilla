extends Node2D

# Pickup that Enemy.kill() drops according to drop_chance. Applies a random
# buff from the corresponding pool (normal or elite) when the player walks
# over it. The player checks proximity every physics_process via _check_prize_pickup.

@export var is_elite: bool = false

@onready var sprite: Sprite2D = $Sprite2D
@onready var light: PointLight2D = $PointLight2D


func _ready() -> void:
	# Visual differentiator normal vs elite:
	#   - Normal: base size + additive golden light (glow)
	#   - Elite: 2x sprite + subtractive dark light (gloomy aura)
	if is_elite:
		sprite.scale = Vector2(2, 2)
		light.color = Color(0.4, 0.4, 0.4, 1)
		light.blend_mode = Light2D.BLEND_MODE_SUB
		light.texture_scale = 1.0
	else:
		sprite.scale = Vector2(1, 1)
		light.color = Color(1.0, 0.85, 0.2, 1)
		light.blend_mode = Light2D.BLEND_MODE_ADD
		light.texture_scale = 0.5
	# Fallback: if the .tscn has no texture assigned to the PointLight2D
	# (default is a GradientTexture2D SubResource), we generate one
	# procedurally at runtime — cheap, ~16k pixels.
	if light.texture == null:
		light.texture = _make_light_texture()


func _make_light_texture() -> Texture2D:
	var size := 128
	var img = Image.create(size, size, false, Image.FORMAT_RGBA8)
	var center = Vector2(float(size) / 2.0, float(size) / 2.0)
	var max_d = float(size) / 2.0
	for y in range(size):
		for x in range(size):
			var d = Vector2(x, y).distance_to(center) / max_d
			var a = clamp(1.0 - d, 0.0, 1.0)
			a = a * a   # quadratic falloff
			img.set_pixel(x, y, Color(1, 1, 1, a))
	return ImageTexture.create_from_image(img)


# Applies a random buff from the corresponding pool to the player. If the
# rolled buff is maxed (2 stacks), tries the next one in the pool. If ALL
# are maxed, the prize is "wasted" (return false). In any case the prize
# must be queue_freed by the caller (Character._check_prize_pickup).
func apply_buff(player) -> bool:
	var pool: Array
	if is_elite:
		# E1 range, E2 wider, E3 ammo, E4 shield+2 with +1 dmg.
		pool = ["range30_dmg2", "wider30_dmg2", "ammo2x_dmg2", "shield2_dmg1"]
	else:
		# N1 range, N2 dmg, N3 wider, N4 speed, N5 shield+1.
		pool = ["range20", "dmg1", "wider20", "speed10", "shield1"]
	pool.shuffle()
	for buff_id in pool:
		if player.apply_prize_buff(buff_id):
			return true
	return false
