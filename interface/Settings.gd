extends Control

# Simple settings: two HSliders 0-100 that adjust the audio buses
# (Master + SFX). The SFX bus lives in default_bus_layout.tres — when
# sound effects are added, assign them bus="SFX" so the slider affects
# them. Changes persist in AudioServer (singleton) for the lifetime of
# the process; there is no disk save yet.
#
# SFX_BASELINE_DB: the SFX bus is set to -6dB in default_bus_layout
# to halve all effects. The SLIDER treats that baseline as "100%"
# so the user does not see the bar at 50% by default — slider 100 = bus at
# -6dB (current half), slider 0 = -80dB (silence).
const SFX_BASELINE_DB: float = -6.0

# When Settings is opened as an overlay (e.g., from the game's PauseMenu),
# is_overlay=true before add_child(). BACK then does queue_free instead
# of changing the scene — so the game session stays intact underneath. When opened
# as a top-level scene from Main_Menu, is_overlay stays false (default).
var is_overlay: bool = false

@onready var master_slider: HSlider = $VBox/MasterRow/MasterSlider
@onready var master_value: Label = $VBox/MasterRow/MasterValue
@onready var sfx_slider: HSlider = $VBox/SfxRow/SfxSlider
@onready var sfx_value: Label = $VBox/SfxRow/SfxValue
@onready var back_button: TextureButton = $BackButton


func _ready() -> void:
	# Initialize the sliders with the current bus values.
	# linear_to_db is undefined at 0, so we show 0% if the bus
	# is at -80 dB (effectively silent) or muted.
	var m_idx = AudioServer.get_bus_index("Master")
	if m_idx >= 0:
		master_slider.value = _bus_db_to_percent(AudioServer.get_bus_volume_db(m_idx))
	master_slider.value_changed.connect(_on_master_changed)
	_update_master_label()

	var s_idx = AudioServer.get_bus_index("SFX")
	if s_idx >= 0:
		# Subtract baseline before mapping to 0-100 — a bus at -6dB shows
		# as 100% (not as ~50%).
		var sfx_db = AudioServer.get_bus_volume_db(s_idx) - SFX_BASELINE_DB
		sfx_slider.value = _bus_db_to_percent(sfx_db)
	else:
		# SFX bus does not exist (default_bus_layout.tres didn't load) — we
		# disable the slider instead of silently failing.
		sfx_slider.editable = false
		sfx_value.text = "N/A"
	sfx_slider.value_changed.connect(_on_sfx_changed)
	_update_sfx_label()

	back_button.pressed.connect(_on_back_pressed)


func _on_master_changed(v: float) -> void:
	var idx = AudioServer.get_bus_index("Master")
	if idx >= 0:
		AudioServer.set_bus_volume_db(idx, _percent_to_bus_db(v))
	_update_master_label()


func _on_sfx_changed(v: float) -> void:
	var idx = AudioServer.get_bus_index("SFX")
	if idx >= 0:
		# Add baseline (-6dB): slider 100% maps to -6dB (not 0dB), slider
		# 50% maps to -12dB, slider 0 to -80dB. This way the user's "100%"
		# matches the project's halved baseline.
		AudioServer.set_bus_volume_db(idx, _percent_to_bus_db(v) + SFX_BASELINE_DB)
	_update_sfx_label()


func _update_master_label() -> void:
	master_value.text = "%d" % int(round(master_slider.value))


func _update_sfx_label() -> void:
	if sfx_slider.editable:
		sfx_value.text = "%d" % int(round(sfx_slider.value))


# 0-100 → dB. 100 = 0 dB (unity), 0 = -80 dB (silent — Godot's
# practical silence floor; linear_to_db(0) is undefined).
func _percent_to_bus_db(percent: float) -> float:
	if percent <= 0.0:
		return -80.0
	return linear_to_db(percent / 100.0)


# dB → 0-100 inverse. -80 dB or less → 0; clamp for safety.
func _bus_db_to_percent(db: float) -> float:
	if db <= -80.0:
		return 0.0
	return clamp(db_to_linear(db) * 100.0, 0.0, 100.0)


func _on_back_pressed() -> void:
	if is_overlay:
		# Overlay mode: just queue_free this Control. The PauseMenu (sibling
		# under CanvasMenu) stays visible underneath, the game stays paused.
		queue_free()
	else:
		# Scene mode: return to Main_Menu (the original path from the menu).
		get_tree().change_scene_to_file("res://interface/Main_Menu.tscn")
