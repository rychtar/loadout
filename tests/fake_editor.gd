extends LoadoutEditorBridge
## Editor stand-in for headless installer tests. Records calls instead of touching the editor.

## Versions (plugin.cfg) whose entry script "fails to compile".
var broken_versions: PackedStringArray = []
## Versions that compile but whose EditorPlugin never starts after enabling.
var not_starting_versions: PackedStringArray = []
var scan_ok := true
var stale: PackedStringArray = []
var calls: PackedStringArray = []

var _enabled: Dictionary[String, bool] = {}
var _addons_dir: String


func _init(addons_dir: String) -> void:
	_addons_dir = addons_dir


func is_plugin_enabled(folder: String) -> bool:
	return _enabled.get(folder, false)


func set_plugin_enabled(folder: String, enabled: bool) -> void:
	calls.append("%s %s" % ["enable" if enabled else "disable", folder])
	_enabled[folder] = enabled


func is_plugin_running(folder: String) -> bool:
	return is_plugin_enabled(folder) and not not_starting_versions.has(_version(_addons_dir.path_join(folder)))


func scan() -> bool:
	calls.append("scan")
	return scan_ok


func refresh_scripts(_dir: String) -> Error:
	calls.append("refresh")
	return OK


func validate_plugin(dir: String) -> Error:
	calls.append("validate")
	return ERR_PARSE_ERROR if broken_versions.has(_version(dir)) else OK


func validate_scripts(dir: String) -> Error:
	calls.append("validate_scripts")
	return ERR_PARSE_ERROR if broken_versions.has(_version(dir)) else OK


func save_project_settings() -> Error:
	calls.append("save")
	return OK


func stale_classes(_dir: String) -> PackedStringArray:
	return stale


func _version(dir: String) -> String:
	var cfg := ConfigFile.new()
	if cfg.load(dir.path_join("plugin.cfg")) != OK:
		return ""
	return str(cfg.get_value("plugin", "version", ""))
