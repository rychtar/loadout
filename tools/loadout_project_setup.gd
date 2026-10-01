extends RefCounted

## Installs Loadout into another Godot 4 project: copies addons/loadout and enables
## the plugin in project.godot. Used by tools/install_loadout.gd, tested in tests/unit.
## project.godot is edited as text (one line) so comments and formatting stay as they are.

const Fs := preload("res://addons/loadout/util/fs.gd")

const LOADOUT_FOLDER := "loadout"
const PLUGIN_CFG := "res://addons/loadout/plugin.cfg"
const SECTION := "[editor_plugins]"
const ENABLED_KEY := "enabled="

const ACTION_INSTALLED := "installed"
const ACTION_UPDATED := "updated"
const ACTION_UNCHANGED := "unchanged"


## loadout_dir: the Loadout folder to copy, project_dir: folder with project.godot (absolute paths).
## Returns { "ok", "error", "action", "version", "previous" }.
static func install(loadout_dir: String, project_dir: String, force: bool = false) -> Dictionary:
	var result := { "ok": false, "error": "", "action": "", "version": _version(loadout_dir), "previous": "" }
	var project_file := project_dir.path_join("project.godot")
	if not FileAccess.file_exists(project_file):
		result["error"] = "Folder %s has no project.godot." % project_dir
		return result
	var project_text := FileAccess.get_file_as_string(project_file)
	if not project_text.contains("config_version=5"):
		result["error"] = "%s is not a Godot 4 project (config_version=5 missing)." % project_file
		return result
	if result["version"] == "":
		result["error"] = "Folder %s has no Loadout plugin.cfg." % loadout_dir
		return result
	var target := project_dir.path_join("addons").path_join(LOADOUT_FOLDER)
	if _same_dir(loadout_dir, target):
		result["error"] = "Source and target are the same folder."
		return result
	var enabled := with_plugin_enabled(project_text, PLUGIN_CFG)
	if not enabled["ok"]:
		result["error"] = enabled["error"]
		return result

	result["previous"] = _version(target)
	if DirAccess.dir_exists_absolute(target):
		if result["previous"] == result["version"] and Fs.hash_dir(target) == Fs.hash_dir(loadout_dir):
			result["action"] = ACTION_UNCHANGED
		elif not force:
			result["error"] = "The project already has Loadout %s. Replace it with %s using --force (close the project's editor first)." % [
				result["previous"] if result["previous"] != "" else "?", result["version"]]
			return result
		else:
			var removed := Fs.remove_dir(target)
			if removed != OK:
				result["error"] = "Cannot delete the old version: %s" % error_string(removed)
				return result
			result["action"] = ACTION_UPDATED
	else:
		result["action"] = ACTION_INSTALLED

	if result["action"] != ACTION_UNCHANGED:
		var err := Fs.copy_dir(loadout_dir, target, Fs.DEFAULT_EXCLUDE)
		if err != OK:
			result["error"] = "Copying to %s failed: %s" % [target, error_string(err)]
			return result
	if enabled["text"] != project_text:
		var file := FileAccess.open(project_file, FileAccess.WRITE)
		if file == null:
			result["error"] = "Cannot write project.godot: %s" % error_string(FileAccess.get_open_error())
			return result
		file.store_string(enabled["text"])
	result["ok"] = true
	return result


## Adds plugin_path to [editor_plugins] enabled. Returns { "ok", "error", "text" }.
static func with_plugin_enabled(text: String, plugin_path: String) -> Dictionary:
	var lines := text.split("\n")
	var section := -1
	for i in lines.size():
		if lines[i].strip_edges() == SECTION:
			section = i
			break
	var line := ENABLED_KEY + var_to_str(PackedStringArray([plugin_path]))
	if section == -1:
		return { "ok": true, "error": "", "text": text.rstrip("\n") + "\n\n%s\n\n%s\n" % [SECTION, line] }
	var i := section + 1
	while i < lines.size() and not lines[i].strip_edges().begins_with("["):
		if lines[i].begins_with(ENABLED_KEY):
			var value: Variant = str_to_var(lines[i].trim_prefix(ENABLED_KEY).strip_edges())
			if typeof(value) != TYPE_PACKED_STRING_ARRAY and typeof(value) != TYPE_ARRAY:
				return { "ok": false, "error": "Cannot read line %d of project.godot: %s" % [i + 1, lines[i]], "text": text }
			var plugins := PackedStringArray(value)
			if plugins.has(plugin_path):
				return { "ok": true, "error": "", "text": text }
			plugins.append(plugin_path)
			plugins.sort()
			lines[i] = ENABLED_KEY + var_to_str(plugins)
			return { "ok": true, "error": "", "text": "\n".join(lines) }
		i += 1
	var insert_at := section + 2 if section + 1 < lines.size() and lines[section + 1].strip_edges() == "" else section + 1
	lines.insert(insert_at, line)
	return { "ok": true, "error": "", "text": "\n".join(lines) }


static func _version(dir: String) -> String:
	var cfg := ConfigFile.new()
	if cfg.load(dir.path_join("plugin.cfg")) != OK:
		return ""
	return str(cfg.get_value("plugin", "version", ""))


static func _same_dir(a: String, b: String) -> bool:
	return ProjectSettings.globalize_path(a).simplify_path().trim_suffix("/") \
			== ProjectSettings.globalize_path(b).simplify_path().trim_suffix("/")
