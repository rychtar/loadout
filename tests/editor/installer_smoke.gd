@tool
extends RefCounted
## Installer smoke test inside a running editor (real GodotEditorBridge, real res://addons/fake_a).
## Unit tests use a fake editor; this checks the editor-specific parts found in F0.
## Run each mode in its own editor session, in this order:
##   godot --headless -e --path . -- --loadout-smoke=install   # fresh install of fake_a 1.0.0
##   godot --headless -e --path . -- --loadout-smoke=update    # 1.0.0 -> 1.1.0, then broken 1.2.0 rolls back
##   godot --headless -e --path . -- --loadout-smoke=verify    # state after editor restart
##   godot --headless -e --path . -- --loadout-smoke=remove    # uninstall, leaves the project clean
## Dock (GUI, not headless; registry file prepared by the caller with fake_a 1.0.0, auto_install):
##   godot -e --path . -- --loadout-registry=<file> --loadout-smoke=dock
##   startup sync offer -> install -> screenshots in user://loadout_smoke/*.png -> cleanup
## Exit code 0 = passed.

const GodotEditorBridge := preload("res://addons/loadout/editor/godot_editor_bridge.gd")
const Log := preload("res://addons/loadout/util/log.gd")

const FIXTURES := "res://tests/fixtures/addons/fake_a"
const SMOKE_DIR := "user://loadout_smoke"
const AUTOLOAD_NAME := "FakeA"

var _tree: SceneTree
var _installer: LoadoutInstaller
var _entry: LoadoutRegistry.Entry
var _failures: PackedStringArray = []
var _plugin: EditorPlugin


func _init(tree: SceneTree, plugin: EditorPlugin = null) -> void:
	_tree = tree
	_plugin = plugin
	_installer = LoadoutInstaller.new(GodotEditorBridge.new(tree), "res://addons",
			SMOKE_DIR.path_join("backup"), SMOKE_DIR.path_join("staging"))
	_entry = LoadoutRegistry.parse_entry({ "id": "fake_a", "folder": "fake_a",
			"source": { "type": "local", "path": _fixture("1.0.0") } })["entry"]


func run(mode: String) -> bool:
	var filesystem := EditorInterface.get_resource_filesystem()
	while filesystem.is_scanning():
		await _tree.process_frame
	for i in 30:
		await _tree.process_frame
	match mode:
		"install":
			await _run_install()
		"update":
			await _run_update()
		"verify":
			_expect_running("1.1.0", "after restart")
		"remove":
			await _run_remove()
		"dock":
			await _run_dock()
		_:
			_failures.append("unknown mode %s" % mode)
	for failure in _failures:
		Log.write("SMOKE FAIL %s" % failure, Log.Level.ERROR)
	Log.write("SMOKE %s: %s" % [mode, "passed" if _failures.is_empty() else "%d failed" % _failures.size()])
	return _failures.is_empty()


func _run_install() -> void:
	if DirAccess.dir_exists_absolute(_installer.target_dir(_entry)):
		await _installer.uninstall(_entry)
	var result: Dictionary = await _installer.install(_entry, _source("1.0.0"), "1.0.0")
	_expect(result["ok"], "fresh install: %s" % result["error"])
	_expect_running("1.0.0", "fresh install")
	_save_lock("1.0.0", result["hash"])


func _run_update() -> void:
	_expect_running("1.0.0", "baseline from previous session")
	var result: Dictionary = await _installer.install(_entry, _source("1.1.0"), "1.1.0", _lock_entry())
	_expect(result["ok"], "update to 1.1.0: %s" % result["error"])
	_expect(result["restart_recommended"], "removed class FakeALegacy recommends restart")
	_expect_running("1.1.0", "after update")
	_save_lock("1.1.0", result["hash"])
	var broken: Dictionary = await _installer.install(_entry, _source("1.2.0_broken"), "1.2.0", _lock_entry())
	_expect(not broken["ok"] and broken["restored"], "broken 1.2.0 rolls back: %s" % broken["error"])
	_expect_running("1.1.0", "after rollback")


func _run_remove() -> void:
	var result: Dictionary = await _installer.uninstall(_entry)
	_expect(result["ok"], "uninstall: %s" % result["error"])
	_expect(not EditorInterface.is_plugin_enabled("fake_a"), "disabled after uninstall")
	_expect(not ProjectSettings.has_setting("autoload/" + AUTOLOAD_NAME), "autoload removed")
	_expect(not FileAccess.get_file_as_string("res://project.godot").contains("fake_a"), "project.godot clean")


func _run_dock() -> void:
	var manager: LoadoutManager = _plugin.get_manager()
	var dock: Control = _plugin.get_dock()
	_show_dock(dock)
	var confirm: ConfirmationDialog = dock.get("_confirm")
	if not await _wait_until(func() -> bool: return confirm.visible, 15000):
		_failures.append("startup sync did not offer the missing plugin")
		return
	await _screenshot("dock_sync_offer", confirm)
	confirm.get_ok_button().pressed.emit()
	await _wait_until(func() -> bool: return manager.get_state("fake_a") != null and manager.get_state("fake_a").status == LoadoutManager.Status.OK, 30000)
	_expect_running("1.0.0", "installed from dock")
	_expect(FileAccess.file_exists(LoadoutLockfile.DEFAULT_PATH), "project lock written")
	var tree: Tree = dock.get("_tree")
	tree.get_root().get_first_child().select(0)
	await _screenshot("dock_installed")
	var registry_dialog: ConfirmationDialog = dock.get("_registry_dialog")
	registry_dialog.open()
	var path_edit: LineEdit = registry_dialog.get("_path_edit")
	path_edit.text = _fixture("1.1.0")
	path_edit.text_changed.emit(path_edit.text)
	await _screenshot("dock_add_dialog", registry_dialog)
	registry_dialog.hide()
	# Cleanup: leave the project as it was (no fake_a, no lock).
	await _installer.uninstall(_entry)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(LoadoutLockfile.DEFAULT_PATH))


func _show_dock(dock: Control) -> void:
	var child: Node = dock
	while child.get_parent() != null:
		var parent := child.get_parent()
		if parent is TabContainer:
			(parent as TabContainer).current_tab = child.get_index()
			return
		child = parent


## Dialogs are separate OS windows, pass them to capture their own viewport.
func _screenshot(name: String, window: Window = null) -> void:
	for i in 10:
		await _tree.process_frame
	await RenderingServer.frame_post_draw
	var image := (window if window != null else _tree.root).get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(SMOKE_DIR)
	var path := ProjectSettings.globalize_path(SMOKE_DIR.path_join(name + ".png"))
	image.save_png(path)
	Log.write("screenshot %s" % path)


func _wait_until(condition: Callable, timeout_ms: int) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while not condition.call():
		if Time.get_ticks_msec() > deadline:
			return false
		await _tree.process_frame
	return true


## The plugin, its autoload and its class_name scripts all run the expected version.
func _expect_running(version: String, label: String) -> void:
	_expect(_installer.installed_version(_entry) == version, "%s: installed %s" % [label, _installer.installed_version(_entry)])
	_expect(_installer.editor.is_plugin_running("fake_a"), "%s: EditorPlugin running" % label)
	_expect(Engine.get_meta("fake_a_plugin_version", "") == version, "%s: plugin.gd version %s" % [label, Engine.get_meta("fake_a_plugin_version", "")])
	var node := _tree.root.find_child(AUTOLOAD_NAME, true, false)
	var autoload_version: String = node.get_script().get_script_constant_map().get("VERSION", "") if node != null else ""
	_expect(autoload_version == version, "%s: autoload version %s" % [label, autoload_version])
	var util := load("res://addons/fake_a/fake_a_util.gd") as Script
	var util_version: String = util.get_script_constant_map().get("VERSION", "") if util != null else ""
	_expect(util_version == version, "%s: FakeAUtil version %s" % [label, util_version])
	_expect(FileAccess.get_file_as_string("res://project.godot").contains("res://addons/fake_a/plugin.cfg"), "%s: enabled in project.godot on disk" % label)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _fixture(folder: String) -> String:
	return ProjectSettings.globalize_path(FIXTURES.path_join(folder))


func _source(folder: String) -> LoadoutSource:
	return LoadoutLocalSource.new(_fixture(folder))


func _save_lock(version: String, folder_hash: String) -> void:
	var lock := LoadoutLockfile.new()
	lock.set_installed("fake_a", version, folder_hash, Time.get_date_string_from_system())
	lock.save_file(SMOKE_DIR.path_join("loadout.lock.json"))


func _lock_entry() -> LoadoutLockfile.Entry:
	var result := LoadoutLockfile.load_file(SMOKE_DIR.path_join("loadout.lock.json"))
	return (result["lockfile"] as LoadoutLockfile).get_entry("fake_a") if result["ok"] else null
