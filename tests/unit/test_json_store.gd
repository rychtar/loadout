extends "res://tests/test_case.gd"

const JsonStore := preload("res://addons/loadout/util/json_store.gd")


func _write_pending(path: String, text: String) -> void:
	write_text("%s.4242%s" % [path, JsonStore.TMP_SUFFIX], text)


func test_a_write_being_renamed_is_read_from_its_temporary_file() -> void:
	var path := temp_dir("json_pending").path_join("loadout_registry.json")
	# On Windows the old file is gone for a moment before the new one is renamed into place.
	_write_pending(path, '{ "schema": 1, "plugins": [{ "id": "a" }] }')
	var read := JsonStore.read(path, 1)
	check(read["ok"] and not read["missing"], "not an empty registry: %s" % read["error"])
	check_eq(read["data"].get("plugins"), [{ "id": "a" }], "the new content")
	check(not FileAccess.file_exists(path), "nothing written")


func test_an_unfinished_temporary_file_does_not_count() -> void:
	var path := temp_dir("json_pending_broken").path_join("loadout_lock.json")
	_write_pending(path, '{ "schema": 1, "plug')
	var read := JsonStore.read(path, 1)
	check(read["ok"] and read["missing"], "missing, not corrupt")
	check_eq(read["backup_path"], "", "no backup of a file that is not there")


func test_the_file_itself_wins_over_a_temporary_file() -> void:
	var path := temp_dir("json_pending_both").path_join("loadout_cache.json")
	write_text(path, '{ "schema": 1, "value": "file" }')
	_write_pending(path, '{ "schema": 1, "value": "temporary" }')
	check_eq(JsonStore.read(path, 1)["data"].get("value"), "file", "the file is read")


func test_write_leaves_no_temporary_file() -> void:
	var dir := temp_dir("json_write")
	var path := dir.path_join("loadout.lock.json")
	check_eq(JsonStore.write(path, { "schema": 1, "count": 3 }, 1), OK, "written")
	check_eq(DirAccess.get_files_at(dir), PackedStringArray(["loadout.lock.json"]), "only the file")
	check(FileAccess.get_file_as_string(path).contains("\"count\": 3,"), "whole number stays whole")
