extends LoadoutSource
## Source backed by fixture folders: { "1.0.0": "res://tests/fixtures/addons/fake_a/1.0.0", ... }.

const Fs := preload("res://addons/loadout/util/fs.gd")

var versions: Dictionary[String, String] = {}
var fetched: PackedStringArray = []


func _init(fixture_versions: Dictionary[String, String] = {}) -> void:
	versions = fixture_versions


func describe() -> String:
	return "Fake"


func get_latest_version(version_range: String) -> Dictionary:
	var best := LoadoutVersion.max_satisfying(PackedStringArray(versions.keys()), version_range)
	if best == "":
		return { "ok": false, "error": "No version in range %s." % version_range, "version": "" }
	return { "ok": true, "error": "", "version": best }


func has_version(version: String) -> bool:
	return versions.has(version)


func fetch(version: String, dest_dir: String) -> Dictionary:
	fetched.append(version)
	if not versions.has(version):
		return { "ok": false, "error": "Version %s does not exist." % version, "path": "" }
	var err := Fs.copy_dir(versions[version], dest_dir)
	if err != OK:
		return { "ok": false, "error": error_string(err), "path": "" }
	return { "ok": true, "error": "", "path": dest_dir }
