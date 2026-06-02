extends Control

const DRAIN_INTERVAL := 3.0
const MAX_HUNGER := 100
# When hunger reaches 0, a second timer starts that deals 1 damage to the
# player every STARVE_DAMAGE_INTERVAL seconds until they die or eat.
const STARVE_DAMAGE_INTERVAL := 1.0
const STARVE_DAMAGE := 1

var max_hunger: int = MAX_HUNGER
var hunger: int = MAX_HUNGER

@onready var bar: TextureProgressBar = $HungerBar
@onready var label: Label = $HungerLabel

var _starve_timer: Timer


func _ready() -> void:
	bar.max_value = max_hunger
	bar.value = hunger
	label.text = "%s/%s" % [hunger, max_hunger]

	# Timer must be PAUSABLE explicitly: HungerMenu inherits PROCESS_MODE_ALWAYS
	# from CanvasMenu (so the HUD keeps drawing while paused), which would
	# otherwise let the timer keep ticking during pause.
	var timer := Timer.new()
	timer.wait_time = DRAIN_INTERVAL
	timer.autostart = true
	timer.one_shot = false
	timer.process_mode = Node.PROCESS_MODE_PAUSABLE
	timer.timeout.connect(_on_drain_tick)
	add_child(timer)

	# Second timer for starvation damage. NO autostart — it starts when
	# hunger reaches 0 and stops when it goes back above 0 (via add_hunger).
	# Same PAUSABLE so the damage freezes along with the rest of the game.
	_starve_timer = Timer.new()
	_starve_timer.wait_time = STARVE_DAMAGE_INTERVAL
	_starve_timer.autostart = false
	_starve_timer.one_shot = false
	_starve_timer.process_mode = Node.PROCESS_MODE_PAUSABLE
	_starve_timer.timeout.connect(_on_starve_tick)
	add_child(_starve_timer)


func _on_drain_tick() -> void:
	if hunger <= 0:
		return
	hunger -= 1
	bar.value = hunger
	label.text = "%s/%s" % [hunger, max_hunger]
	# When reaching 0, start the starvation cycle.
	if hunger == 0 and _starve_timer.is_stopped():
		_starve_timer.start()


func _on_starve_tick() -> void:
	# Safety: if for some reason hunger > 0 (race with add_hunger), shut off.
	if hunger > 0:
		_starve_timer.stop()
		return
	# Difficulty Baby: hunger drains to 0 but does NOT apply damage. User
	# spec: "Cannot die from hunger". The timer keeps running (hidden)
	# in case the difficulty changes mid-run — cheap.
	if GameState.difficulty == "Baby":
		return
	# Player is found by group (Character.gd does add_to_group("player")
	# in _ready). If there is no player in the tree (between levels), we skip
	# this tick — not a problem, it retries on the next one.
	var player = get_tree().get_first_node_in_group("player")
	if player != null:
		player.damage(STARVE_DAMAGE, Vector2.ZERO, "hunger")


# Adds `amount` to hunger, capped at max_hunger. Called by BossRoom when
# reaching the boss room for the first time in this biome. If we rescue hunger
# above 0, we stop the starvation cycle.
func add_hunger(amount: int) -> void:
	hunger = clamp(hunger + amount, 0, max_hunger)
	if hunger > 0 and _starve_timer != null and not _starve_timer.is_stopped():
		_starve_timer.stop()
	bar.value = hunger
	label.text = "%s/%s" % [hunger, max_hunger]
