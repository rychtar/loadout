extends "res://tests/test_case.gd"

const Lockfile := preload("res://addons/loadout/core/lockfile.gd")

const SAMPLE := """{
	"schema": 1,
	"plugins": {
		"gut": { "version": "9.3.0", "pinned": false, "hash": "sha256:abc", "installed_at": "2026-10-01" }
	},
	"ignored": []
}"""


func _sample() -> Lockfile:
	var result := Lockfile.from_dict(JSON.parse_string(SAMPLE))
	check(result["ok"], "sample parses: %s" % result["error"])
	return result["lockfile"]


func test_parse_sample() -> void:
	var lock := _sample()
	var entry := lock.get_entry("gut")
	check(entry != null, "gut entry")
	if entry != null:
		check_eq(entry.version, "9.3.0", "version")
		check_eq(entry.pinned, false, "pinned")
		check_eq(entry.folder_hash, "sha256:abc", "hash")
		check_eq(entry.installed_at, "2026-10-01", "installed_at")
	check(lock.get_entry("other") == null, "unknown id")
	check(lock.ignored.is_empty(), "nothing ignored")


func test_schema_required() -> void:
	check(not Lockfile.from_dict({ "plugins": {} })["ok"], "missing schema")
	check(not Lockfile.from_dict({ "schema": 2, "plugins": {} })["ok"], "unknown schema")
	check(not Lockfile.from_dict({ "schema": 1, "plugins": [] })["ok"], "plugins must be an object")


func test_optional_fields() -> void:
	var result := Lockfile.from_dict({ "schema": 1, "plugins": { "a": { "version": "1.0.0" } } })
	check(result["ok"], "minimal entry")
	var entry: Lockfile.Entry = (result["lockfile"] as Lockfile).get_entry("a")
	check(entry != null and not entry.pinned and entry.folder_hash == "" and entry.installed_at == "", "defaults")


func test_invalid_entries_are_skipped() -> void:
	var result := Lockfile.from_dict({ "schema": 1, "plugins": {
		"ok": { "version": "1.0.0" },
		"no_version": { "pinned": true },
		"bad_version": { "version": "latest" },
		"bad_pin": { "version": "1.0.0", "pinned": "yes" },
		"bad_hash": { "version": "1.0.0", "hash": "md5:123" },
		"not_object": "1.0.0",
	}, "ignored": ["x", 5] })
	check(result["ok"], "file still loads")
	var lock: Lockfile = result["lockfile"]
	check_eq(lock.plugins.keys(), ["ok"], "only valid entry kept")
	check_eq(lock.ignored, PackedStringArray(["x"]), "non-string ignored ids dropped")
	check_eq(lock.warnings.size(), 6, "warning per problem")


func test_set_installed_keeps_pin() -> void:
	var lock := _sample()
	check(lock.set_pinned("gut", true), "pin existing")
	lock.set_installed("gut", "9.4.0", "sha256:def", "2026-10-02")
	var entry := lock.get_entry("gut")
	check_eq([entry.version, entry.pinned, entry.folder_hash, entry.installed_at], ["9.4.0", true, "sha256:def", "2026-10-02"], "updated, still pinned")
	lock.set_installed("new", "1.0.0", "sha256:1", "2026-10-02")
	check(lock.get_entry("new") != null and not lock.get_entry("new").pinned, "new entry not pinned")


func test_pin_unknown_plugin() -> void:
	check(not _sample().set_pinned("missing", true), "cannot pin a plugin that is not installed")


func test_remove() -> void:
	var lock := _sample()
	check(lock.remove("gut"), "remove existing")
	check(not lock.remove("gut"), "remove again")
	check(lock.plugins.is_empty(), "empty")


func test_ignored() -> void:
	var lock := _sample()
	lock.set_ignored("debug_draw_3d", true)
	lock.set_ignored("debug_draw_3d", true)
	check(lock.is_ignored("debug_draw_3d"), "ignored")
	check_eq(lock.ignored.size(), 1, "no duplicates")
	lock.set_ignored("debug_draw_3d", false)
	check(not lock.is_ignored("debug_draw_3d"), "unignored")


func test_save_is_deterministic() -> void:
	var dir := temp_dir("lock_save")
	var path := dir.path_join("loadout.lock.json")
	var lock := _sample()
	lock.set_installed("aaa", "1.0.0", "sha256:1", "2026-10-02")
	lock.set_ignored("zzz", true)
	lock.set_ignored("bbb", true)
	check_eq(lock.save_file(path), OK, "saved")
	var first := FileAccess.get_file_as_string(path)
	var result := Lockfile.load_file(path)
	check(result["ok"], "loads back")
	var loaded: Lockfile = result["lockfile"]
	check_eq(loaded.to_dict(), lock.to_dict(), "same content")
	check_eq(loaded.ignored, PackedStringArray(["bbb", "zzz"]), "ignored sorted")
	check_eq(loaded.save_file(path), OK, "saved again")
	check_eq(FileAccess.get_file_as_string(path), first, "identical bytes for git")
	check(first.find("\"aaa\"") < first.find("\"gut\""), "plugins sorted by id")
	check(first.ends_with("\n"), "trailing newline")


func test_missing_file() -> void:
	var dir := temp_dir("lock_missing")
	var result := Lockfile.load_file(dir.path_join("loadout.lock.json"))
	check(result["ok"] and result["missing"], "missing lock is an empty lock")
	check((result["lockfile"] as Lockfile).plugins.is_empty(), "no plugins")


func test_corrupt_file() -> void:
	var dir := temp_dir("lock_corrupt")
	var path := dir.path_join("loadout.lock.json")
	write_text(path, "not json")
	var result := Lockfile.load_file(path)
	check(not result["ok"], "fails")
	check(FileAccess.file_exists(path + ".bak"), "backup created")
	check(_sample().save_file(path) != OK, "corrupt lock is not overwritten")
	check_eq(FileAccess.get_file_as_string(path), "not json", "original untouched")
