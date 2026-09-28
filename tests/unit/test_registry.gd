extends "res://tests/test_case.gd"

const Registry := preload("res://addons/loadout/core/registry.gd")

const SAMPLE := """{
	"schema": 1,
	"plugins": [
		{ "id": "gut", "folder": "gut", "source": { "type": "github", "repo": "bitwes/Gut" }, "range": "^9.0.0", "auto_install": true },
		{ "id": "moje_utils", "folder": "moje_utils", "source": { "type": "local", "path": "D:/godot/addons/moje_utils" }, "auto_install": true }
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
	var local := registry.get_entry("moje_utils")
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
	check(FileAccess.file_exists(path + ".1.bak"), "second backup does not overwrite the first")
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
