@tool
class_name LoadoutLocalSource
extends LoadoutSource

## Plugin folder on this machine (absolute path to the folder with plugin.cfg).
## It only offers the version currently in its plugin.cfg.

const Fs := preload("../util/fs.gd")

var path: String


func _init(plugin_path: String) -> void:
	path = plugin_path


func describe() -> String:
	return "Local · %s" % path


func list_releases(_etag: String = "") -> Dictionary:
	var version := _current_version()
	if version == "":
		return { "ok": false, "error": "Folder %s has no plugin.cfg with a version." % path, "not_modified": false, "etag": "", "releases": [] }
	var release := { "version": version, "tag": version, "prerelease": LoadoutVersion.parse(version) != null and LoadoutVersion.parse(version).is_prerelease(),
			"notes": "", "url": "", "download_url": "" }
	return { "ok": true, "error": "", "not_modified": false, "etag": "", "releases": [release] }


func get_latest_version(version_range: String) -> Dictionary:
	var version := _current_version()
	if version == "":
		return { "ok": false, "error": "Folder %s has no plugin.cfg with a version." % path, "version": "" }
	if not LoadoutVersion.satisfies(version, version_range):
		return { "ok": false, "error": "Local version %s does not match range %s." % [version, version_range], "version": "" }
	return { "ok": true, "error": "", "version": version }


func has_version(version: String) -> bool:
	return version != "" and _current_version() == version


func get_plugin_name() -> String:
	return str(_read_cfg().get_value("plugin", "name", ""))


func fetch(version: String, dest_dir: String) -> Dictionary:
	var current := _current_version()
	if current != version:
		return { "ok": false, "error": "The local source has version %s, not %s." % [current if current != "" else "?", version], "path": "" }
	var err := Fs.copy_dir(path, dest_dir, Fs.DEFAULT_EXCLUDE)
	if err != OK:
		Fs.remove_dir(dest_dir)
		return { "ok": false, "error": "Copying from %s failed: %s" % [path, error_string(err)], "path": "" }
	return { "ok": true, "error": "", "path": dest_dir }


func _current_version() -> String:
	return str(_read_cfg().get_value("plugin", "version", ""))


func _read_cfg() -> ConfigFile:
	var cfg := ConfigFile.new()
	cfg.load(path.path_join("plugin.cfg"))
	return cfg
