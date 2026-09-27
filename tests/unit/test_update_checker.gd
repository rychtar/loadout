extends "res://tests/test_case.gd"

const Checker := preload("res://addons/loadout/core/update_checker.gd")
const FakeSource := preload("res://tests/fake_source.gd")

const DAY := 86400

var now := 1_800_000_000
var source: FakeSource
var checker: Checker
var cache_path: String


func _setup(name: String) -> void:
	cache_path = temp_dir("checker_" + name).path_join("loadout_cache.json")
	source = FakeSource.new({ "1.0.0": "res://tests/fixtures/addons/fake_a/1.0.0" })
	source.remote = true
	checker = _new_checker()


func _new_checker() -> Checker:
	var clock := { "now": now }
	var result := Checker.new(cache_path, func() -> int: return clock["now"])
	result.load_cache()
	return result


func _versions() -> PackedStringArray:
	var versions: PackedStringArray = []
	for release in source.releases:
		versions.append(release["version"])
	versions.sort()
	return versions


func test_first_check_asks_the_source() -> void:
	_setup("first")
	var result: Dictionary = await checker.load_releases(source)
	check(result["ok"] and result["checked"] and not result["from_cache"], "checked online")
	check_eq(source.list_calls, 1, "one request")
	check_eq(_versions(), PackedStringArray(["1.0.0"]), "releases set on the source")


func test_second_check_within_a_day_uses_cache() -> void:
	_setup("throttle")
	await checker.load_releases(source)
	source.versions["1.1.0"] = "res://tests/fixtures/addons/fake_a/1.1.0"
	var fresh := FakeSource.new(source.versions)
	fresh.remote = true
	var result: Dictionary = await checker.load_releases(fresh)
	check(result["ok"] and result["from_cache"], "from cache")
	check_eq(fresh.list_calls, 0, "no request within 24 h")
	check_eq(fresh.releases.size(), 1, "cached releases")


func test_cache_survives_restart() -> void:
	_setup("persist")
	await checker.load_releases(source)
	check_eq(checker.save_cache(), OK, "saved")
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(cache_path))
	check_eq(data["schema"], 1.0, "schema")
	var restarted := _new_checker()
	var other := FakeSource.new({})
	other.remote = true
	var result: Dictionary = await restarted.load_releases(other)
	check(result["from_cache"], "cache used after restart")
	check_eq(other.releases.size(), 1, "cached release")


func test_check_again_after_a_day() -> void:
	_setup("next_day")
	await checker.load_releases(source)
	checker.save_cache()
	now += DAY + 1
	var later := _new_checker()
	await later.load_releases(source)
	check_eq(source.list_calls, 2, "checked again")


func test_force_ignores_throttle() -> void:
	_setup("force")
	await checker.load_releases(source)
	await checker.load_releases(source, true)
	check_eq(source.list_calls, 2, "manual check")


func test_etag_and_not_modified() -> void:
	_setup("etag")
	source.etag = "W/\"1\""
	await checker.load_releases(source)
	source.not_modified = true
	source.versions.clear()
	var result: Dictionary = await checker.load_releases(source, true)
	check_eq(source.last_etag, "W/\"1\"", "stored etag sent back")
	check(result["ok"] and result["checked"], "304 counts as checked")
	check_eq(_versions(), PackedStringArray(["1.0.0"]), "cached releases kept on 304")


func test_offline_falls_back_to_cache() -> void:
	_setup("offline")
	await checker.load_releases(source)
	source.fail_list = "Cannot connect."
	var result: Dictionary = await checker.load_releases(source, true)
	check(result["ok"] and result["from_cache"], "silent fallback")
	check(str(result["warning"]).contains("Cannot connect"), "warning for the dock: %s" % result["warning"])
	check_eq(_versions(), PackedStringArray(["1.0.0"]), "cached releases")


func test_offline_without_cache_fails() -> void:
	_setup("offline_empty")
	source.fail_list = "Cannot connect."
	var result: Dictionary = await checker.load_releases(source)
	check(not result["ok"], "nothing to fall back to")
	var again: Dictionary = await checker.load_releases(source)
	check_eq(source.list_calls, 1, "failed attempt also counts for the daily limit")
	check(not again["ok"], "still no data")


func test_local_sources_are_not_cached() -> void:
	_setup("local")
	source.remote = false
	await checker.load_releases(source)
	await checker.load_releases(source)
	check_eq(source.list_calls, 2, "local sources are read every time")
	checker.save_cache()
	check(not FileAccess.file_exists(cache_path), "nothing to cache")


func test_corrupt_cache_is_backed_up_and_replaced() -> void:
	_setup("corrupt")
	write_text(cache_path, "{ broken")
	var fresh := _new_checker()
	check(not fresh.warnings.is_empty(), "reported")
	check(FileAccess.file_exists(cache_path + ".bak"), "backup")
	await fresh.load_releases(source)
	check_eq(fresh.save_cache(), OK, "cache is rebuilt (it only holds downloaded data)")


func test_in_memory_checker() -> void:
	_setup("memory")
	var memory := Checker.new("")
	memory.load_cache()
	await memory.load_releases(source)
	check_eq(memory.save_cache(), OK, "no file, no error")
