extends Node2D

# Battery: pickup that Enemy.kill() drops with a flat 15% (independent of
# the prize and the heart). Restores 5 ammo when collected. Same
# lifecycle as Heart: lives in the level, freed on level change.

const AMMO_RESTORE := 5

@onready var sprite: Sprite2D = $Sprite2D


# Called by Character._check_prize_pickup when passing within
# PRIZE_PICKUP_RADIUS. Delegates to player.add_ammo (clamped to max_ammo).
# Returns true for consistency with Prize.apply_buff.
func pickup(player) -> bool:
	if player != null and player.has_method("add_ammo"):
		player.add_ammo(AMMO_RESTORE)
	return true
