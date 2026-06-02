extends Node2D

# Pickup that Enemy.kill() drops with a flat 10% (independent of the prize).
# No PointLight2D, no variants — just heals HEAL_AMOUNT to the player when
# they walk over it. Character._check_prize_pickup iterates over both prizes
# and hearts.

const HEAL_AMOUNT := 10

@onready var sprite: Sprite2D = $Sprite2D


# Called by Character on pickup. Heals HEAL_AMOUNT (Character.heal
# delegates to set_health, which clamps to max_health — safe overshoot).
# Returns true for consistency with Prize.apply_buff.
func pickup(player) -> bool:
	if player != null and player.has_method("heal"):
		player.heal(HEAL_AMOUNT)
	return true
