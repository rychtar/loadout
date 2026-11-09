extends "res://tests/test_case.gd"

const Dock := preload("res://addons/loadout/ui/dock.gd")

const MIN_COLUMN := 48
const MIN_NAME := 96
const TOTAL := 400


func _resize(status: int, version: int, boundary: int, delta: int) -> Vector2i:
	return Dock.resize_columns(status, version, boundary, delta, TOTAL, MIN_COLUMN, MIN_NAME)


func test_first_border_changes_only_the_status_column() -> void:
	check_eq(_resize(100, 80, 1, -30), Vector2i(130, 80), "border to the left widens Status")
	check_eq(_resize(100, 80, 1, 20), Vector2i(80, 80), "border to the right narrows Status")


func test_first_border_stops_at_the_limits() -> void:
	check_eq(_resize(100, 80, 1, 500), Vector2i(MIN_COLUMN, 80), "Status keeps its minimum")
	check_eq(_resize(100, 80, 1, -500), Vector2i(TOTAL - 80 - MIN_NAME, 80), "the Plugin column keeps its minimum")


func test_second_border_moves_width_between_status_and_version() -> void:
	check_eq(_resize(100, 80, 2, 25), Vector2i(125, 55), "border to the right: Status wider, Version narrower")
	check_eq(_resize(100, 80, 2, -25), Vector2i(75, 105), "border to the left: the other way")


func test_second_border_keeps_the_sum_and_the_minimums() -> void:
	var widest := _resize(100, 80, 2, 500)
	check_eq(widest, Vector2i(180 - MIN_COLUMN, MIN_COLUMN), "Version keeps its minimum")
	var narrowest := _resize(100, 80, 2, -500)
	check_eq(narrowest, Vector2i(MIN_COLUMN, 180 - MIN_COLUMN), "Status keeps its minimum")
	check_eq(widest.x + widest.y, 180, "the sum does not change")


func test_tiny_tree_never_goes_below_the_minimum() -> void:
	check_eq(Dock.resize_columns(60, 60, 1, -100, 100, MIN_COLUMN, MIN_NAME), Vector2i(MIN_COLUMN, 60), "narrow dock")


func test_fit_keeps_the_text_widths_when_there_is_room() -> void:
	check_eq(Dock.fit_widths(120, 100, TOTAL, MIN_COLUMN, MIN_NAME), Vector2i(120, 100), "wide enough")
	check_eq(Dock.fit_widths(120, 100, 0, MIN_COLUMN, MIN_NAME), Vector2i(120, 100), "not laid out yet, no limit")


func test_fit_leaves_the_plugin_column_its_minimum() -> void:
	var widths := Dock.fit_widths(200, 180, 440, MIN_COLUMN, MIN_NAME)
	check_eq(widths.x + widths.y, 440 - MIN_NAME, "the other two share what is left")
	check(widths.x > widths.y, "in proportion to their text")


func test_fit_never_goes_below_the_column_minimum() -> void:
	check_eq(Dock.fit_widths(200, 180, 120, MIN_COLUMN, MIN_NAME), Vector2i(MIN_COLUMN, MIN_COLUMN), "tiny dock")


func test_status_summary_counts_in_status_order() -> void:
	var counts := { LoadoutManager.Status.MISSING: 1, LoadoutManager.Status.OK: 3, LoadoutManager.Status.UPDATE: 2 }
	check_eq(Dock.status_summary(counts), "Up to date 3 · Missing 1 · Update 2", "enum order, states with no plugin left out")
	check_eq(Dock.status_summary({}), "", "nothing to count")


func test_time_ago() -> void:
	var now := 1_800_000_000
	check_eq(Dock.time_ago(now - 30, now), "just now", "seconds")
	check_eq(Dock.time_ago(now + 500, now), "just now", "a time in the future (wrong clock)")
	check_eq(Dock.time_ago(now - 5 * 60, now), "5 min ago", "minutes")
	check_eq(Dock.time_ago(now - 3 * 3600, now), "3 h ago", "hours")
	check_eq(Dock.time_ago(now - 47 * 3600, now), "47 h ago", "up to two days in hours")
	check_eq(Dock.time_ago(now - 5 * 86400, now), "5 days ago", "days")
