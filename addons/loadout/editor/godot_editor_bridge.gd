@tool
extends LoadoutEditorBridge

## LoadoutEditorBridge backed by the running Godot editor (behaviour verified in F0, see CLAUDE.md).

const Fs := preload("../util/fs.gd")
const Log := preload("../util/log.gd")

const ADDONS_DIR := "res://addons"
const SCAN_TIMEOUT_MS := 30000
const SETTLE_FRAMES := 10
const TEMP_VALIDATE_DIR := "user://loadout_validate"

var _tree: SceneTree


func _init(tree: SceneTree) -> void:
	_tree = tree


func is_plugin_enabled(folder: String) -> bool:
	return EditorInterface.is_plugin_enabled(folder)


func set_plugin_enabled(folder: String, enabled: bool) -> void:
	EditorInterface.set_plugin_enabled(folder, enabled)
	await _settle()


func is_plugin_running(folder: String) -> bool:
	var path := _entry_script_path(ADDONS_DIR.path_join(folder))
	if path == "":
		return false
	for node: Node in _tree.root.find_children("*", "EditorPlugin", true, false):
		var script := node.get_script() as Script
		if script != null and script.resource_path == path:
			return true
	return false


func scan() -> bool:
	var filesystem := EditorInterface.get_resource_filesystem()
	var deadline := Time.get_ticks_msec() + SCAN_TIMEOUT_MS
	while filesystem.is_scanning() and Time.get_ticks_msec() < deadline:
		await _tree.process_frame
	var state := { "changed": false }
	var on_changed := func() -> void: state["changed"] = true
	filesystem.filesystem_changed.connect(on_changed)
	filesystem.scan()
	while (not state["changed"] or filesystem.is_scanning()) and Time.get_ticks_msec() < deadline:
		await _tree.process_frame
	filesystem.filesystem_changed.disconnect(on_changed)
	var ok: bool = state["changed"] and not filesystem.is_scanning()
	if not ok:
		Log.write("The filesystem scan did not finish within %d s." % (SCAN_TIMEOUT_MS / 1000), Log.Level.WARNING)
	return ok


func refresh_scripts(dir: String) -> Error:
	var result: Error = OK
	for relative in Fs.list_files(dir):
		var path := dir.path_join(relative)
		if relative.get_extension() != "gd" or not ResourceLoader.has_cached(path):
			continue
		var script := load(path) as Script
		if script == null:
			continue
		script.source_code = FileAccess.get_file_as_string(path)
		var err := script.reload(true)
		if err != OK:
			Log.write("Script %s cannot be loaded: %s" % [path, error_string(err)], Log.Level.WARNING)
			result = err
	return result


## Must run after refresh_scripts(): GDScript keeps its own script cache, so CACHE_MODE_IGNORE
## still returns the old (valid) script while a stale copy is loaded.
func validate_plugin(dir: String) -> Error:
	var path := _entry_script_path(dir)
	if path == "" or not FileAccess.file_exists(path):
		return ERR_FILE_NOT_FOUND
	var script := ResourceLoader.load(path, "Script", ResourceLoader.CACHE_MODE_IGNORE) as Script
	if script == null or not script.can_instantiate():
		return ERR_PARSE_ERROR
	return OK


## Scripts with a class_name cannot be loaded from a second place ("hides a global script class"),
## so the check runs on a temporary copy with the class_name lines removed.
func validate_scripts(dir: String) -> Error:
	var copy := TEMP_VALIDATE_DIR.path_join(str(Time.get_ticks_usec()))
	if Fs.copy_dir(dir, copy) != OK:
		Fs.remove_dir(copy)
		return ERR_CANT_CREATE
	var class_name_line := RegEx.create_from_string("(?m)^class_name\\s+\\w+.*$")
	var scripts: PackedStringArray = []
	for relative in Fs.list_files(copy):
		if relative.get_extension() == "gd":
			var path := copy.path_join(relative)
			var file := FileAccess.open(path, FileAccess.WRITE)
			if file == null:
				continue
			file.store_string(class_name_line.sub(FileAccess.get_file_as_string(dir.path_join(relative)), "", true))
			file.close()
			scripts.append(path)
	var result: Error = OK
	for path in scripts:
		var script := ResourceLoader.load(path, "Script", ResourceLoader.CACHE_MODE_IGNORE) as Script
		if script == null or not script.can_instantiate():
			Log.write("Script %s does not compile." % path.trim_prefix(copy + "/"), Log.Level.WARNING)
			result = ERR_PARSE_ERROR
	Fs.remove_dir(copy)
	return result


func save_project_settings() -> Error:
	return ProjectSettings.save()


func stale_classes(dir: String) -> PackedStringArray:
	var stale: PackedStringArray = []
	for info: Dictionary in ProjectSettings.get_global_class_list():
		var path := str(info["path"])
		if path.begins_with(dir + "/") and not FileAccess.file_exists(path):
			stale.append(str(info["class"]))
	return stale


func _settle() -> void:
	for i in SETTLE_FRAMES:
		await _tree.process_frame


func _entry_script_path(dir: String) -> String:
	var cfg := ConfigFile.new()
	if cfg.load(dir.path_join("plugin.cfg")) != OK:
		return ""
	return dir.path_join(str(cfg.get_value("plugin", "script", "")))
