extends Control

# Victory screen: twin of GameOver.gd but without the "Died to X" logic
# (there is no damage source to report — the player won). Shows the final
# score, a per-difficulty star rating (1-5), and the two RETRY/MENU buttons.
# Loaded from Enemy._do_win_transition when a mob with triggers_win=true
# dies (Croakzilla).

@onready var score_label: Label = $ScoreLabel
@onready var retry_button: TextureButton = $RetryButton
@onready var menu_button: TextureButton = $MenuButton
@onready var star_row: HBoxContainer = $StarRow

# Star sprite (also the "Prize/Power_Up" sprite — same asset). Loaded
# preload so _populate_stars doesn't disk-hit per star instance.
const STAR_TEX := preload("res://assets/Power_Up_Prize.png")
# Display size per star. The source PNG is small (16-32 px range); we
# upscale via custom_minimum_size + STRETCH_KEEP_ASPECT_CENTERED so
# they read clearly without changing the asset.
const STAR_PX := 64
# We always render the full 5-slot scale (rating UX). Slots beyond the
# earned count get a dim/gray modulate so the player sees what's possible
# at a glance. The earned slots stay at default Color.WHITE.
const STAR_COUNT_TOTAL := 5
const STAR_GRAY_MODULATE := Color(0.25, 0.25, 0.25, 0.6)
# Pop-in animation: each star starts at scale=0, then tweens to scale=1
# in sequence (left-to-right). Stagger = delay before the next star
# starts; duration = how long each star's pop lasts. Uses TRANS_BACK
# EASE_OUT for a slight overshoot that reads as "celebratory".
const STAR_POP_DURATION := 0.6
const STAR_POP_STAGGER := 0.20


func _ready() -> void:
	score_label.text = "SCORE: %d" % GameState.last_score
	_populate_stars(_star_count_for(GameState.last_score))
	retry_button.pressed.connect(_on_retry_pressed)
	menu_button.pressed.connect(_on_menu_pressed)


# Per-difficulty score → star count (1..5). Thresholds match the spec
# the player asked for:
#   Normal       : 175 / 250 / 325 / 400 (1..5)
#   Baby         : halved, rounded up — 88 / 125 / 163 / 200.
#                  175/2=87.5→88, 250/2=125, 325/2=162.5→163, 400/2=200.
#   Hell / Insane: 200 / 280 / 360 / 440.
# Each tier is "<= boundary" inclusive (e.g. score=175 -> 1 star on Normal,
# 176 -> 2 stars).
func _star_count_for(score: int) -> int:
	var d: String = GameState.difficulty
	if d == "Baby":
		if score <= 88: return 1
		elif score <= 125: return 2
		elif score <= 163: return 3
		elif score <= 200: return 4
		return 5
	elif d == "Hell" or d == "This doesn't make any sense":
		if score <= 200: return 1
		elif score <= 280: return 2
		elif score <= 360: return 3
		elif score <= 440: return 4
		return 5
	# Normal (and any unrecognized difficulty falls back here).
	if score <= 175: return 1
	elif score <= 250: return 2
	elif score <= 325: return 3
	elif score <= 400: return 4
	return 5


# Builds 5 TextureRect children under StarRow — always 5, with the
# slots beyond `n` (the earned count) modulated to STAR_GRAY_MODULATE.
# Animation strategy after multiple failed multi-tween attempts (5 separate
# tweens / 1 parallel with set_delay / fire-and-forget coroutines / single
# coroutine with sequential awaits): only ONE star animates — specifically
# the LAST EARNED star (stars[n-1]). All other stars (earned and gray)
# appear at full size immediately. The single pop-in is enough to draw the
# eye to the rating without depending on Godot's flaky multi-tween code path.
func _populate_stars(n: int) -> void:
	if star_row == null:
		return
	for child in star_row.get_children():
		child.queue_free()
	var stars: Array = []
	for i in range(STAR_COUNT_TOTAL):
		var star := TextureRect.new()
		star.texture = STAR_TEX
		star.custom_minimum_size = Vector2(STAR_PX, STAR_PX)
		star.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		star.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		# Unearned slots: dim gray.
		if i >= n:
			star.modulate = STAR_GRAY_MODULATE
		# Pivot center so the eventual scale-up grows outward.
		star.pivot_offset = Vector2(STAR_PX, STAR_PX) / 2.0
		# Only the LAST earned star starts at scale 0; everyone else is
		# at full size immediately.
		if i == n - 1:
			star.scale = Vector2.ZERO
		star_row.add_child(star)
		stars.append(star)
	# Single tween on the last earned star (skipped if n==0, defensive —
	# _star_count_for always returns >= 1 in practice).
	if n > 0 and n <= STAR_COUNT_TOTAL:
		var s = stars[n - 1]
		if is_instance_valid(s):
			var tw = s.create_tween()
			tw.tween_property(s, "scale", Vector2.ONE, STAR_POP_DURATION) \
				.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _on_retry_pressed() -> void:
	# Same flow as GameOver: reload Main.tscn directly. GameState.difficulty
	# is preserved (it's a static var); player buffs and stats reset because
	# Character is re-instantiated.
	get_tree().change_scene_to_file("res://Main.tscn")


func _on_menu_pressed() -> void:
	get_tree().change_scene_to_file("res://interface/Main_Menu.tscn")
