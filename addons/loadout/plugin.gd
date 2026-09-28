@tool
extends EditorPlugin

## Entry point: creates the manager and the dock, runs the startup sync and update check.

const Log := preload("util/log.gd")
const GodotEditorBridge := preload("editor/godot_editor_bridge.gd")
const Dock := preload("ui/dock.gd")

const REGISTRY_FILE := "loadout_registry.json"
## Optional GitHub token (raises the API limit). Editor Settings are per user, never in the project.
const TOKEN_SETTING := "loadout/github_token"
## Development only: use another registry file instead of the one in the editor config dir
## (the update cache then lives next to it).
const REGISTRY_ARG_PREFIX := "--loadout-registry="
## Development only: godot -e --path . -- --loadout-smoke=<mode> runs tests/editor/installer_smoke.gd
## and quits the editor (exit code 0 = passed). Ignored when the tests folder is not present.
const SMOKE_ARG_PREFIX := "--loadout-smoke="
const SMOKE_SCRIPT := "res://tests/editor/installer_smoke.gd"
## Smoke modes that drive the installer themselves and must not see the startup sync.
const SMOKE_INSTALLER_MODES: PackedStringArray = ["install", "update", "verify", "remove"]

var _manager: LoadoutManager
var _dock: Control


func _enter_tree() -> void:
	var installer := LoadoutInstaller.new(GodotEditorBridge.new(get_tree()))
	var registry_path := _registry_path()
	var checker := LoadoutUpdateChecker.new(registry_path.get_base_dir().path_join(LoadoutUpdateChecker.FILE_NAME))
	# HTTPRequest nodes are created under this plugin node (rule: no own threads).
	var http := LoadoutHttp.new(self)
	_register_settings()
	var settings := EditorInterface.get_editor_settings()
	var token := func() -> String: return str(settings.get_setting(TOKEN_SETTING)) if settings.has_setting(TOKEN_SETTING) else ""
	var factory := func(entry: LoadoutRegistry.Entry) -> LoadoutSource: return LoadoutSource.create(entry, http, token)
	_manager = LoadoutManager.new(installer, registry_path, LoadoutLockfile.DEFAULT_PATH, factory, checker)
	_dock = Dock.new()
	_dock.manager = _manager
	var godot_version := "%d.%d" % [Engine.get_version_info()["major"], Engine.get_version_info()["minor"]]
	_dock.assetlib_search = func(query: String) -> Dictionary:
		return await LoadoutAssetlibSource.search(http, query, godot_version)
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _dock)

	var smoke_mode := _cmdline_value(SMOKE_ARG_PREFIX)
	if smoke_mode == "" or not SMOKE_INSTALLER_MODES.has(smoke_mode):
		_startup_sync.call_deferred()
	if smoke_mode != "":
		_run_smoke.call_deferred(smoke_mode)


func _exit_tree() -> void:
	remove_control_from_docks(_dock)
	_dock.queue_free()
	_dock = null
	_manager = null


func get_manager() -> LoadoutManager:
	return _manager


func get_dock() -> Control:
	return _dock


## Loads registry and lock once the editor finished scanning, offers missing plugins and
## announces available updates (remote sources are asked at most once a day).
func _startup_sync() -> void:
	var filesystem := EditorInterface.get_resource_filesystem()
	while filesystem.is_scanning():
		await get_tree().process_frame
	if _manager == null:
		return
	await _manager.refresh()
	if _manager == null or _dock == null:
		return
	var missing := _manager.missing_ids()
	if not missing.is_empty():
		Log.write("Missing in this project: %s" % ", ".join(missing))
		_dock.offer_missing(missing)
	var updates := _manager.update_ids()
	if not updates.is_empty():
		var names: PackedStringArray = []
		for id in updates:
			var state := _manager.get_state(id)
			names.append("%s %s" % [state.display_name, state.target_version])
		Log.write("Updates available: %s" % ", ".join(names))
		EditorInterface.get_editor_toaster().push_toast("Loadout: updates available (%d)" % updates.size(),
				EditorToaster.SEVERITY_INFO, "%s\nUpdate them in the Loadout dock." % ", ".join(names))


func _register_settings() -> void:
	var settings := EditorInterface.get_editor_settings()
	if not settings.has_setting(TOKEN_SETTING):
		settings.set_setting(TOKEN_SETTING, "")
	settings.set_initial_value(TOKEN_SETTING, "", false)
	settings.add_property_info({ "name": TOKEN_SETTING, "type": TYPE_STRING, "hint": PROPERTY_HINT_PASSWORD })


func _registry_path() -> String:
	var override := _cmdline_value(REGISTRY_ARG_PREFIX)
	if override != "":
		return override
	return EditorInterface.get_editor_paths().get_config_dir().path_join(REGISTRY_FILE)


func _run_smoke(mode: String) -> void:
	if not FileAccess.file_exists(SMOKE_SCRIPT):
		Log.write("Smoke test %s not found." % SMOKE_SCRIPT, Log.Level.ERROR)
		get_tree().quit(1)
		return
	var smoke: RefCounted = load(SMOKE_SCRIPT).new(get_tree(), self)
	var passed: bool = await smoke.run(mode)
	get_tree().quit(0 if passed else 1)


func _cmdline_value(prefix: String) -> String:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with(prefix):
			return arg.trim_prefix(prefix)
	return ""
