extends "res://tests/test_case.gd"

const Registry := preload("res://addons/loadout/core/registry.gd")

const SAMPLE := """{
	"schema": 1,
	"plugins": [
		{ "id": "gut", "folder": "gut", "source": { "type": "github", "repo": "bitwes/Gut" }, "range": "^9.0.0", "auto_install": true },
		{ "id": "my_utils", "folder": "my_utils", "source": { "type": "local", "path": "D:/godot/addons/my_utils" }, "auto_install": true }
	]
}"""


func _entry(overrides: Dictionary) -> Dictionary:
	var data := { "id": "a", "folder": "a", "source": { "type": "local", "path": "/plugins/a" } }
	data.merge(overrides, true)
	return data


func _from_entries(entries: Array) -> Registry:
	var result := Registry.from_dict({ "schema": 1, "plugins": entries })
	check(result["ok"], "registry parses: %s" % result["error"])
	return result["registry"]


func test_parse_sample() -> void:
	var result := Registry.from_dict(JSON.parse_string(SAMPLE))
	check(result["ok"], "sample is valid")
	var registry: Registry = result["registry"]
	check_eq(registry.entries.size(), 2, "two entries")
	var gut := registry.get_entry("gut")
	check(gut != null, "gut found")
	if gut != null:
		check_eq(gut.folder, "gut", "folder")
		check_eq(gut.source, { "type": "github", "repo": "bitwes/Gut" }, "source")
		check_eq(gut.version_range, "^9.0.0", "range")
		check_eq(gut.auto_install, true, "auto_install")
	var local := registry.get_entry("my_utils")
	check(local != null and local.version_range == "*", "missing range means any version")
	check(registry.warnings.is_empty(), "no warnings")


func test_defaults() -> void:
	var registry := _from_entries([{ "id": "tool", "source": { "type": "local", "path": "/x/tool" } }])
	var entry := registry.get_entry("tool")
	check(entry != null, "entry kept")
	if entry != null:
		check_eq(entry.folder, "tool", "folder defaults to id")
		check_eq(entry.version_range, "*", "range defaults to *")
		check_eq(entry.auto_install, true, "auto_install defaults to true")


func test_schema_required() -> void:
	check(not Registry.from_dict({ "plugins": [] })["ok"], "missing schema")
	check(not Registry.from_dict({ "schema": 2, "plugins": [] })["ok"], "unknown schema")
	check(not Registry.from_dict({ "schema": "1", "plugins": [] })["ok"], "schema must be a number")
	check(not Registry.from_dict({ "schema": 1, "plugins": {} })["ok"], "plugins must be an array")
	check(not Registry.from_dict([])["ok"], "root must be an object")


func test_github_sources() -> void:
	var registry := _from_entries([
		_entry({ "id": "a", "folder": "a", "source": { "type": "github", "repo": "https://github.com/owner/repo.git" } }),
		_entry({ "id": "b", "folder": "b", "source": { "type": "github", "repo": "http://github.com/owner/repo" } }),
		_entry({ "id": "c", "folder": "c", "source": { "type": "github", "repo": "https://gitlab.com/owner/repo" } }),
		_entry({ "id": "d", "folder": "d", "source": { "type": "github", "repo": "owner" } }),
	])
	var a := registry.get_entry("a")
	check(a != null and a.source["repo"] == "owner/repo", "https URL normalized to owner/repo")
	check(registry.get_entry("b") == null, "http rejected")
	check(registry.get_entry("c") == null, "other hosts rejected")
	check(registry.get_entry("d") == null, "repo needs owner/name")
	check_eq(registry.warnings.size(), 3, "warning per skipped entry")


func test_invalid_entries_are_skipped() -> void:
	var registry := _from_entries([
		_entry({ "id": "ok" , "folder": "ok" }),
		_entry({ "id": "", "folder": "x1" }),
		_entry({ "id": "bad_folder", "folder": "../escape" }),
		_entry({ "id": "nested_folder", "folder": "a/b" }),
		_entry({ "id": "bad_type", "folder": "t", "source": { "type": "ftp", "url": "x" } }),
		_entry({ "id": "relative", "folder": "r", "source": { "type": "local", "path": "addons/r" } }),
		_entry({ "id": "bad_range", "folder": "br", "range": ">=1.0" }),
		_entry({ "id": "bad_flag", "folder": "bf", "auto_install": "yes" }),
		"not an object",
	])
	check_eq(registry.entries.size(), 1, "only the valid entry stays")
	check(registry.get_entry("ok") != null, "valid entry kept")
	check_eq(registry.warnings.size(), 8, "warning per skipped entry")


func test_duplicates_are_skipped() -> void:
	var registry := _from_entries([
		_entry({ "id": "a", "folder": "a" }),
		_entry({ "id": "a", "folder": "other" }),
		_entry({ "id": "b", "folder": "a" }),
	])
	check_eq(registry.entries.size(), 1, "first wins")
	check_eq(registry.warnings.size(), 2, "duplicate id and duplicate folder reported")


func test_unreadable_entries_survive_a_save() -> void:
	var dir := temp_dir("registry_unreadable")
	var path := dir.path_join("loadout_registry.json")
	var newer := { "id": "b", "folder": "b_folder", "source": { "type": "gitlab", "project": "x/y" }, "release_id": 7 }
	var new_range := _entry({ "id": "c", "folder": "c", "range": ">=1.2 <2" })
	write_text(path, JSON.stringify({ "schema": 1, "count": 5, "plugins": [_entry({ "id": "a", "folder": "a" }), newer, new_range, "not an object"] }))
	var registry: Registry = Registry.load_file(path)["registry"]
	check_eq(registry.entries.size(), 1, "only the readable entry is used")
	check_eq(registry.warnings.size(), 3, "warning per unreadable entry")
	check(registry.warnings[0].contains("stays in the file"), "the warning says nothing is lost: %s" % registry.warnings[0])
	check(registry.add_entry(_entry({ "id": "b", "folder": "other" })) != "", "the id of an unreadable entry is taken")
	check(registry.add_entry(_entry({ "id": "other", "folder": "B_folder" })) != "", "so is its folder")
	check(registry.set_folder("a", "c") != "", "set_folder respects it too")
	check_eq(registry.add_entry(_entry({ "id": "d", "folder": "d" })), "", "other entries can be added")
	check_eq(registry.save_file(path), OK, "saved")
	var text := FileAccess.get_file_as_string(path)
	var saved: Dictionary = JSON.parse_string(text)
	var plugins: Array = saved["plugins"]
	check_eq(plugins.size(), 5, "nothing dropped")
	check(plugins.has(JSON.parse_string(JSON.stringify(newer))), "the newer source type is written back unchanged")
	check(plugins.has(JSON.parse_string(JSON.stringify(new_range))), "and so is the unknown range")
	check(plugins.has("not an object"), "and the broken item")
	check(text.contains("\"count\": 5,") and text.contains("\"release_id\": 7"), "whole numbers stay whole: %s" % text)


func test_add_and_remove() -> void:
	var registry := _from_entries([])
	check_eq(registry.add_entry(_entry({ "id": "a", "folder": "a" })), "", "add valid")
	check(registry.add_entry(_entry({ "id": "a", "folder": "b" })) != "", "duplicate id refused")
	check(registry.add_entry(_entry({ "id": "x", "folder": "../x" })) != "", "invalid refused")
	check_eq(registry.entries.size(), 1, "one entry")
	check(registry.remove_entry("a"), "remove existing")
	check(not registry.remove_entry("a"), "remove missing")
	check(registry.entries.is_empty(), "empty again")


func test_missing_file_is_empty_registry() -> void:
	var dir := temp_dir("registry_missing")
	var result := Registry.load_file(dir.path_join("loadout_registry.json"))
	check(result["ok"], "missing file is fine")
	check(result["missing"], "reported as missing")
	check((result["registry"] as Registry).entries.is_empty(), "no entries")


func test_save_and_load_roundtrip() -> void:
	var dir := temp_dir("registry_roundtrip")
	var path := dir.path_join("loadout_registry.json")
	var registry: Registry = Registry.from_dict(JSON.parse_string(SAMPLE))["registry"]
	check_eq(registry.save_file(path), OK, "saved")
	var result := Registry.load_file(path)
	check(result["ok"], "loads back")
	var loaded: Registry = result["registry"]
	check_eq(loaded.to_dict(), registry.to_dict(), "same content")
	check(not FileAccess.file_exists(path + ".tmp"), "no temp file left")


func test_corrupt_file_is_backed_up_not_overwritten() -> void:
	var dir := temp_dir("registry_corrupt")
	var path := dir.path_join("loadout_registry.json")
	write_text(path, "{ \"schema\": 1, \"plugins\": [ ")
	var result := Registry.load_file(path)
	check(not result["ok"], "corrupt file fails")
	check(str(result["error"]) != "", "error message")
	check(FileAccess.file_exists(path + ".bak"), "backup created")
	check_eq(FileAccess.get_file_as_string(path + ".bak"), "{ \"schema\": 1, \"plugins\": [ ", "backup has original content")
	Registry.load_file(path)
	check(not FileAccess.file_exists(path + ".1.bak"), "reading the same damaged file again does not add a backup")
	write_text(path, "{ \"schema\": 1, ")
	Registry.load_file(path)
	check_eq(FileAccess.get_file_as_string(path + ".bak"), "{ \"schema\": 1, \"plugins\": [ ", "other damaged content does not overwrite the first backup")
	check(FileAccess.file_exists(path + ".1.bak"), "it gets its own backup")
	write_text(path, "{ \"schema\": 1, \"plugins\": [ ")
	var empty: Registry = Registry.from_dict({ "schema": 1, "plugins": [] })["registry"]
	check(empty.save_file(path) != OK, "save refuses to overwrite a corrupt file")
	check_eq(FileAccess.get_file_as_string(path), "{ \"schema\": 1, \"plugins\": [ ", "original untouched")


func test_unknown_schema_file_is_not_overwritten() -> void:
	var dir := temp_dir("registry_schema")
	var path := dir.path_join("loadout_registry.json")
	write_text(path, "{ \"schema\": 99, \"plugins\": [] }")
	var result := Registry.load_file(path)
	check(not result["ok"], "unknown schema fails")
	check(not FileAccess.file_exists(path + ".bak"), "valid JSON is not backed up")
	var empty: Registry = Registry.from_dict({ "schema": 1, "plugins": [] })["registry"]
	check(empty.save_file(path) != OK, "save refuses to overwrite unknown schema")


func test_assetlib_sources() -> void:
	var registry := _from_entries([
		_entry({ "id": "a", "folder": "a", "source": { "type": "assetlib", "asset_id": "1586" } }),
		_entry({ "id": "b", "folder": "b", "source": { "type": "assetlib", "asset_id": 1709 } }),
		_entry({ "id": "c", "folder": "c", "source": { "type": "assetlib", "asset_id": "abc" } }),
		_entry({ "id": "d", "folder": "d", "source": { "type": "assetlib" } }),
	])
	check_eq(registry.get_entry("a").source, { "type": "assetlib", "asset_id": "1586" }, "string id")
	check(registry.get_entry("b") != null and registry.get_entry("b").source["asset_id"] == "1709", "number id from JSON becomes a string")
	check(registry.get_entry("c") == null and registry.get_entry("d") == null, "invalid ids skipped")


func test_store_sources() -> void:
	var registry := _from_entries([
		_entry({ "id": "a", "folder": "a", "source": { "type": "store", "asset": "rumys/gdscript-templates" } }),
		_entry({ "id": "b", "folder": "b", "source": { "type": "store", "asset": "https://store.godotengine.org/asset/rumys/gdscript-templates/" } }),
		_entry({ "id": "c", "folder": "c", "source": { "type": "store", "asset": "no-slash" } }),
		_entry({ "id": "d", "folder": "d", "source": { "type": "store", "asset": "http://store.godotengine.org/asset/a/b/" } }),
	])
	check_eq(registry.get_entry("a").source, { "type": "store", "asset": "rumys/gdscript-templates" }, "publisher/slug")
	check(registry.get_entry("b") != null and registry.get_entry("b").source["asset"] == "rumys/gdscript-templates", "store URL normalized")
	check(registry.get_entry("c") == null and registry.get_entry("d") == null, "invalid ones skipped")


func test_update_entry_keeps_id_and_folder() -> void:
	var registry := _from_entries([_entry({ "range": "^1.0.0" })])
	var error := registry.update_entry("a", { "id": "other", "folder": "other",
			"source": { "type": "github", "repo": "owner/name" }, "range": "~2.1.0", "auto_install": false })
	check_eq(error, "", "updated")
	var entry := registry.get_entry("a")
	check_eq(entry.folder, "a", "folder stays")
	check_eq(entry.source, { "type": "github", "repo": "owner/name" }, "source replaced")
	check_eq(entry.version_range, "~2.1.0", "range replaced")
	check_eq(entry.auto_install, false, "auto_install replaced")
	check(registry.get_entry("other") == null, "id cannot change")


func test_update_entry_rejects_invalid_data_and_keeps_the_entry() -> void:
	var registry := _from_entries([_entry({})])
	check(registry.update_entry("a", { "source": { "type": "ftp" } }) != "", "invalid source refused")
	check(registry.update_entry("a", { "source": { "type": "local", "path": "/x" }, "range": "nonsense" }) != "", "invalid range refused")
	check_eq(registry.get_entry("a").source.get("path"), "/plugins/a", "entry unchanged")
	check(registry.update_entry("missing", {}) != "", "unknown id")


func test_set_folder() -> void:
	var registry := _from_entries([_entry({}), _entry({ "id": "b", "folder": "b" })])
	check_eq(registry.set_folder("a", "renamed"), "", "changed")
	check_eq(registry.get_entry("a").folder, "renamed", "folder")
	check(registry.set_folder("a", "B") != "", "folder of another entry (any case) refused")
	check(registry.set_folder("a", "../outside") != "", "invalid folder refused")
	check_eq(registry.get_entry("a").folder, "renamed", "unchanged after refusals")


func test_merge_adds_only_new_ids() -> void:
	var registry := _from_entries([_entry({}), _entry({ "id": "e", "folder": "d" })])
	var other := _from_entries([_entry({}), _entry({ "id": "c", "folder": "c" }), _entry({ "id": "d", "folder": "d" })])
	var summary := registry.merge(other)
	check_eq(summary["added"], PackedStringArray(["c"]), "new id added")
	check(summary["skipped"].has("a"), "existing id skipped")
	check(summary["skipped"].has("d"), "folder clash skipped")
	check_eq(registry.entries.size(), 3, "entries")


func test_prereleases_flag() -> void:
	var entry: Registry.Entry = Registry.parse_entry({ "id": "x", "source": { "type": "github", "repo": "a/b" }, "prereleases": true })["entry"]
	check(entry.prereleases, "read")
	check_eq(entry.to_dict().get("prereleases"), true, "written when on")
	var plain: Registry.Entry = Registry.parse_entry({ "id": "x", "source": { "type": "github", "repo": "a/b" } })["entry"]
	check(not plain.to_dict().has("prereleases"), "not written when off")
	check(not Registry.parse_entry({ "id": "x", "source": { "type": "github", "repo": "a/b" }, "prereleases": "yes" })["ok"], "must be a boolean")
