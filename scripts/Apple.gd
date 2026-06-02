extends Node2D

# Apple: pickup that spawns procedurally per room (not corridors),
# with 10% probability. Restores 20 hunger when collected. Same
# lifecycle as Heart/Prize: lives in the level, freed on level change.

const HUNGER_RESTORE := 20

@onready var sprite: Sprite2D = $Sprite2D


# Called by Character._check_prize_pickup when passing within
# PRIZE_PICKUP_RADIUS. Delegates to player.add_hunger (clamped to max_hunger).
# Returns true for consistency with Prize.apply_buff.
func pickup(player) -> bool:
	if player != null and player.has_method("add_hunger"):
		player.add_hunger(HUNGER_RESTORE)
	return true
