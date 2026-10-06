@tool
class_name LoadoutLocalSource
extends LoadoutSource

## Plugin folder on this machine (absolute path to the folder with plugin.cfg).
## It only offers the version currently in its plugin.cfg.

var path: String
## Version to report when the folder's plugin.cfg has none (restoring a backup of such a plugin).
var version_override := ""


func _init(plugin_path: String) -> void:
	path = plugin_path


func describe() -> String:
	return "Local · %s" % path


func list_releases(_etag: String = "") -> Dictionary:
	var version := _current_version()
	if version == "":
		return listing_error(_no_version_error())
	var parsed := LoadoutVersion.parse(version)
	var release := { "version": version, "tag": version, "prerelease": parsed != null and parsed.is_prerelease(),
			"notes": "", "url": "", "download_url": "" }
	return { "ok": true, "error": "", "not_modified": false, "etag": "", "releases": [release] }


func get_latest_version(version_range: String, include_prereleases: bool = false) -> Dictionary:
	var version := _current_version()
	if version == "":
		return { "ok": false, "error": _no_version_error(), "version": "" }
	if LoadoutVersion.parse(version) == null:
		return { "ok": false, "error": "Version \"%s\" in the plugin.cfg of %s is not valid, use major.minor.patch (e.g. 1.2.3)." % [version, path], "version": "" }
	if not LoadoutVersion.satisfies(version, version_range, include_prereleases):
		return { "ok": false, "error": "Local version %s does not match range %s." % [version, version_range], "version": "" }
	return { "ok": true, "error": "", "version": version }


func has_version(version: String) -> bool:
	return version != "" and _current_version() == version


func get_plugin_name() -> String:
	return str(_read_cfg().get_value("plugin", "name", ""))


func fetch(version: String, dest_dir: String) -> Dictionary:
	var current := _current_version()
	if current != version:
		return fetch_error("The local source has version %s, not %s." % [current if current != "" else "?", version])
	var err := Fs.copy_dir(path, dest_dir, Fs.DEFAULT_EXCLUDE)
	if err != OK:
		Fs.remove_dir(dest_dir)
		return fetch_error("Copying from %s failed: %s" % [path, error_string(err)])
	return { "ok": true, "error": "", "path": dest_dir }


func _no_version_error() -> String:
	return "Folder %s has no plugin.cfg with a version." % path


func _current_version() -> String:
	var version := str(_read_cfg().get_value("plugin", "version", ""))
	return version if version != "" else version_override


func _read_cfg() -> ConfigFile:
	var cfg := ConfigFile.new()
	cfg.load(path.path_join("plugin.cfg"))
	return cfg
