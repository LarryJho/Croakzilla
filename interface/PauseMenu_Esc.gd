extends Control

# Tiny input handler attached to $CanvasMenu/PauseMenu in Main.tscn.
#
# Esc keyboard shortcut: same behavior as clicking the on-screen PauseButton.
# - Esc in game           -> pause + show PauseMenu
# - Esc with PauseMenu up -> unpause + hide PauseMenu
# - Esc with Settings overlay open over the PauseMenu -> close just the
#   overlay (queue_free), leaving the PauseMenu visible and the game paused.
#   The next Esc then toggles pause normally.
#
# Why this lives here and NOT on Main.gd: _unhandled_input only fires on
# nodes whose process_mode allows them during pause. PauseMenu is parented
# under CanvasMenu, which has process_mode=ALWAYS (3) in Main.tscn, so
# PauseMenu inherits ALWAYS and runs in both paused and unpaused states.
# Putting the handler on Main.gd would either silently break the
# "Esc to unpause" half, or — if we set Main.process_mode=ALWAYS — cascade
# ALWAYS to the player and enemies (Main's grandchildren with INHERIT mode),
# making them keep ticking during pause. This placement avoids both pitfalls.


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_cancel"):
		return
	# Settings overlay open? Close just that, leave PauseMenu + pause alone.
	# Main._on_Settings_pressed adds it as $CanvasMenu/Settings (the scene
	# root name "Settings" by default).
	var canvas_menu := get_parent()
	if canvas_menu != null:
		var settings_overlay = canvas_menu.get_node_or_null("Settings")
		if settings_overlay != null:
			settings_overlay.queue_free()
			get_viewport().set_input_as_handled()
			return
	# Toggle pause via Main's existing handler.
	# Tree: Main -> CanvasMenu -> PauseMenu (self). Grandparent = Main.
	var main = canvas_menu.get_parent() if canvas_menu != null else null
	if main != null and main.has_method("_on_PauseButton_pressed"):
		main._on_PauseButton_pressed()
		get_viewport().set_input_as_handled()
