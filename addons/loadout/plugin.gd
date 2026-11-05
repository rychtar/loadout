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
const REGISTRY_ENV := "LOADOUT_REGISTRY"
## Development only: godot -e --path . -- --loadout-smoke=<mode> runs tests/editor/installer_smoke.gd
## and quits the editor (exit code 0 = passed). Ignored when the tests folder is not present.
const SMOKE_ARG_PREFIX := "--loadout-smoke="
const SMOKE_SCRIPT := "res://tests/editor/installer_smoke.gd"
## Smoke modes that drive the installer themselves and must not see the startup sync.
const SMOKE_INSTALLER_MODES: PackedStringArray = ["install", "update", "verify", "remove"]
## Dock tab icon: three plugin slots, the top one being loaded. FONT and ACCENT become the editor
## theme's colors; it is drawn at the editor scale, so it stays sharp.
const DOCK_ICON_SVG := """<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">
<rect x="1.5" y="1.5" width="13" height="3.5" rx="1" fill="#ACCENT"/>
<rect x="1.5" y="6.25" width="13" height="3.5" rx="1" fill="#FONT" fill-opacity=".8"/>
<rect x="1.5" y="11" width="13" height="3.5" rx="1" fill="#FONT" fill-opacity=".8"/>
</svg>"""

## How often the startup waits check whether the editor's first scan is over.
const STARTUP_POLL_S := 0.5

var _manager: LoadoutManager
## The dock's content; _editor_dock is the editor's dock around it (title, icon, place).
var _dock: Control
var _editor_dock: EditorDock
## Polls in a row that found the filesystem idle (the startup sync waits for two).
var _idle_polls := 0


func _enter_tree() -> void:
	var installer := LoadoutInstaller.new(GodotEditorBridge.new(get_tree()))
	var registry_path := _registry_path()
	var checker := LoadoutUpdateChecker.new(registry_path.get_base_dir().path_join(LoadoutUpdateChecker.FILE_NAME))
	# HTTPRequest nodes are created under this plugin node (rule: no own threads).
	var http := LoadoutHttp.new(self)
	_register_settings()
	var settings := EditorInterface.get_editor_settings()
	var token := func() -> String: return str(settings.get_setting(TOKEN_SETTING)) if settings.has_setting(TOKEN_SETTING) else ""
	var version_info := Engine.get_version_info()
	var godot_version := "%d.%d" % [version_info["major"], version_info["minor"]]
	var factory := func(entry: LoadoutRegistry.Entry) -> LoadoutSource: return LoadoutSource.create(entry, http, token, godot_version)
	_manager = LoadoutManager.new(installer, registry_path, LoadoutLockfile.DEFAULT_PATH, factory, checker)
	_dock = Dock.new()
	_dock.manager = _manager
	_dock.store_search = func(query: String) -> Dictionary:
		return await LoadoutStoreSource.search(http, query, godot_version)
	_editor_dock = EditorDock.new()
	_editor_dock.name = "Loadout"
	_editor_dock.title = "Loadout"
	# The same key the old add_control_to_dock() layout used (the control's name), so the dock stays put.
	_editor_dock.layout_key = "Loadout"
	_editor_dock.default_slot = EditorDock.DOCK_SLOT_RIGHT_UL
	_editor_dock.dock_icon = _dock_icon()
	_editor_dock.add_child(_dock)
	add_dock(_editor_dock)

	var smoke_mode := _cmdline_value(SMOKE_ARG_PREFIX)
	if smoke_mode == "" or not SMOKE_INSTALLER_MODES.has(smoke_mode):
		_wait_for_first_scan.call_deferred()
	if smoke_mode != "":
		_run_smoke.call_deferred(smoke_mode)


func _exit_tree() -> void:
	var filesystem := EditorInterface.get_resource_filesystem()
	if filesystem.filesystem_changed.is_connected(_on_filesystem_changed):
		filesystem.filesystem_changed.disconnect(_on_filesystem_changed)
	remove_dock(_editor_dock)
	_editor_dock.queue_free()
	_editor_dock = null
	_dock = null
	_manager = null


func _dock_icon() -> Texture2D:
	var theme := EditorInterface.get_editor_theme()
	var font := theme.get_color("font_color", "Editor") if theme.has_color("font_color", "Editor") else Color("e0e0e0")
	var accent := theme.get_color("accent_color", "Editor") if theme.has_color("accent_color", "Editor") else Color("70bafa")
	var image := Image.new()
	var svg := DOCK_ICON_SVG.replace("#FONT", "#" + font.to_html(false)).replace("#ACCENT", "#" + accent.to_html(false))
	if image.load_svg_from_string(svg, EditorInterface.get_editor_scale()) != OK:
		return null
	return ImageTexture.create_from_image(image)


func get_manager() -> LoadoutManager:
	return _manager


func get_dock() -> Control:
	return _dock


## Starts the startup sync once the editor's first scan is over. A timer polls instead of a coroutine
## waiting: when an extension did not load at startup, the first scan tries it again and reloads every
## script, which would cancel the wait (and the sync with it). Two idle polls in a row let that reload
## pass first.
func _wait_for_first_scan() -> void:
	if _manager == null or not is_inside_tree():
		return
	_idle_polls = 0 if EditorInterface.get_resource_filesystem().is_scanning() else _idle_polls + 1
	if _idle_polls < 2:
		get_tree().create_timer(STARTUP_POLL_S).timeout.connect(_wait_for_first_scan, CONNECT_ONE_SHOT)
		return
	_startup_sync()


## Loads registry and lock once the editor finished scanning, offers missing plugins and
## announces available updates (remote sources are asked at most once a day).
func _startup_sync() -> void:
	var filesystem := EditorInterface.get_resource_filesystem()
	if _manager == null:
		return
	await _manager.refresh()
	if _manager == null or _dock == null:
		return
	# From now on, plugins added to addons/ (e.g. from Godot's asset store) are offered to Loadout.
	filesystem.filesystem_changed.connect(_on_filesystem_changed)
	var missing := _manager.missing_ids()
	if not missing.is_empty():
		Log.write("Missing in this project: %s" % ", ".join(missing))
		_dock.offer_missing(missing)
	elif _manager.errors.is_empty() and _dock.has_new_starters():
		# A new Loadout (or a first start) with starters this editor was never offered.
		Log.write("The starter pack has plugins you were not offered yet.")
		_dock.offer_starters(true)
	var updates := _manager.update_ids()
	if not updates.is_empty():
		var names: PackedStringArray = []
		for id in updates:
			var state := _manager.get_state(id)
			names.append("%s %s" % [state.display_name, state.target_version])
		Log.write("Updates available: %s" % ", ".join(names))
		EditorInterface.get_editor_toaster().push_toast("Loadout: updates available (%d)" % updates.size(),
				EditorToaster.SEVERITY_INFO, "%s\nUpdate them in the Loadout dock." % ", ".join(names))


func _on_filesystem_changed() -> void:
	if _manager == null or _dock == null:
		return
	var fresh := _manager.detect_new_addons()
	if not fresh.is_empty():
		Log.write("New plugin in addons/: %s" % ", ".join(PackedStringArray(fresh.map(func(info: Dictionary) -> String: return info["folder"]))))
		_dock.offer_new_addons(fresh)


func _register_settings() -> void:
	var settings := EditorInterface.get_editor_settings()
	if not settings.has_setting(TOKEN_SETTING):
		settings.set_setting(TOKEN_SETTING, "")
	settings.set_initial_value(TOKEN_SETTING, "", false)
	settings.add_property_info({ "name": TOKEN_SETTING, "type": TYPE_STRING, "hint": PROPERTY_HINT_PASSWORD })
	if not settings.has_setting(Dock.SHOW_STARTERS_SETTING):
		settings.set_setting(Dock.SHOW_STARTERS_SETTING, true)
	settings.set_initial_value(Dock.SHOW_STARTERS_SETTING, true, false)
	settings.add_property_info({ "name": Dock.SHOW_STARTERS_SETTING, "type": TYPE_BOOL })
	# The starters already offered; clear it to be offered the starter pack again.
	if not settings.has_setting(Dock.STARTERS_SEEN_SETTING):
		settings.set_setting(Dock.STARTERS_SEEN_SETTING, PackedStringArray())
	settings.set_initial_value(Dock.STARTERS_SEEN_SETTING, PackedStringArray(), false)
	settings.add_property_info({ "name": Dock.STARTERS_SEEN_SETTING, "type": TYPE_PACKED_STRING_ARRAY })


## Development only: LOADOUT_REGISTRY=<file> does the same as --loadout-registry, and unlike that
## argument it survives an editor restart (Godot relaunches the editor without the arguments after "--").
func _registry_path() -> String:
	var override := _cmdline_value(REGISTRY_ARG_PREFIX)
	if override == "":
		override = OS.get_environment(REGISTRY_ENV)
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
