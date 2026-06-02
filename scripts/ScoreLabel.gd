extends Label

var score: int = 0


func _ready() -> void:
	_refresh()


# Adds points when killing an enemy. amount can be negative (snek = -10).
# Called from Enemy.kill() via a lookup in Main by node path.
func add_score(amount: int) -> void:
	score += amount
	_refresh()


func _refresh() -> void:
	text = "SCORE: %d" % score
