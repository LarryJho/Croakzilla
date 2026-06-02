extends Control

const MAX_AMMO := 50
const RECHARGE_DELAY := 3.0       # s since the last shot before recharging
const recharge_interval_DEFAULT := 0.5    # s between +1 recharge (2 shots/sec)
const recharge_interval_HARD := 1.0       # Hell + Nonsense: 1 shot/sec
# Set in _ready according to GameState.difficulty.
var recharge_interval: float = recharge_interval_DEFAULT

var max_ammo: int = MAX_AMMO
var ammo: int = MAX_AMMO

var _time_since_shot: float = 0.0
var _recharge_acc: float = 0.0

@onready var bar: TextureProgressBar = $AmmoBar
@onready var label: Label = $AmmoLabel


func _ready() -> void:
	# Same reason as HungerMenu: CanvasMenu is PROCESS_MODE_ALWAYS, so
	# without this override the recharge would keep counting during pause.
	process_mode = Node.PROCESS_MODE_PAUSABLE
	# Difficulty: Hell and Nonsense slow the recharge down to 1 shot/sec.
	if GameState.difficulty == "Hell" or GameState.difficulty == "This doesn't make any sense":
		recharge_interval = recharge_interval_HARD
	bar.max_value = max_ammo
	bar.value = ammo
	label.text = "%s/%s" % [ammo, max_ammo]


func _process(delta: float) -> void:
	if ammo >= max_ammo:
		return
	_time_since_shot += delta
	if _time_since_shot < RECHARGE_DELAY:
		return
	_recharge_acc += delta
	while _recharge_acc >= recharge_interval and ammo < max_ammo:
		_recharge_acc -= recharge_interval
		ammo += 1
		_refresh()


# Called by Character when shooting. Returns true if there was ammo and it
# was consumed; false if empty (the shot must not occur).
func consume(amount: int = 1) -> bool:
	if ammo < amount:
		return false
	ammo -= amount
	_time_since_shot = 0.0
	_recharge_acc = 0.0
	_refresh()
	return true


func _refresh() -> void:
	bar.value = ammo
	label.text = "%s/%s" % [ammo, max_ammo]


# Restores `amount` of ammo, clamped to max_ammo. Called by the battery
# pickup. Semantic mirror of HungerMenu.add_hunger. Does NOT reset
# _time_since_shot — passive recharge keeps its normal cycle.
func add_ammo(amount: int) -> void:
	ammo = clamp(ammo + amount, 0, max_ammo)
	_refresh()
