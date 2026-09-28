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
##   startup sync offer -> install -> registry points to 1.1.0 -> update from the dock
##   (confirm with release notes) -> screenshots in user://loadout_smoke/*.png -> cleanup
## Remote sources (needs network; registry with e.g. a GitHub entry, auto_install):
##   godot --headless -e --path <project> -- --loadout-registry=<file> --loadout-smoke=remote
##   forced update check, install of every registry plugin, running check, uninstall
## Self-update (GUI or headless; registry has a "gam" entry pointing to a newer Loadout copy):
##   godot -e --path <project> -- --loadout-registry=<file> --loadout-smoke=self
##   first run updates Loadout from the dock and the editor restarts itself. Godot relaunches it
##   without --headless and without the arguments after "--", so close that editor and run the
##   same command again: the second run checks the new version and writes user://loadout_smoke/self.txt
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
		"remote":
			await _run_remote()
		"self":
			await _run_self()
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

	# A new version appears in the source: the registry now points to the 1.1.0 folder.
	var registry_path := _cmdline_value("--loadout-registry=")
	var original_registry := FileAccess.get_file_as_string(registry_path)
	var registry: LoadoutRegistry = LoadoutRegistry.load_file(registry_path)["registry"]
	(registry.get_entry("fake_a").source as Dictionary)["path"] = _fixture("1.1.0")
	registry.save_file(registry_path)
	await manager.refresh(true)
	_expect(manager.update_ids() == PackedStringArray(["fake_a"]), "update offered in the dock")
	tree.get_root().get_first_child().select(0)
	await _screenshot("dock_update_available")
	var update_button := _find_button(dock, "Update to 1.1.0")
	_expect(update_button != null, "update button in the detail")
	if update_button != null:
		update_button.pressed.emit()
		await _wait_until(func() -> bool: return confirm.visible, 5000)
		await _screenshot("dock_update_confirm", confirm)
		confirm.get_ok_button().pressed.emit()
		await _wait_until(func() -> bool: return manager.get_state("fake_a").status == LoadoutManager.Status.OK, 30000)
		_expect_running("1.1.0", "updated from the dock")
		# FakeALegacy was removed in 1.1.0: the dock offers a restart, decline it.
		if await _wait_until(func() -> bool: return confirm.visible, 5000):
			await _screenshot("dock_restart_offer", confirm)
			confirm.get_cancel_button().pressed.emit()

	var registry_dialog: ConfirmationDialog = dock.get("_registry_dialog")
	registry_dialog.open()
	var repo_edit: LineEdit = registry_dialog.get("_repo_edit")
	repo_edit.text = "bitwes/Gut"
	repo_edit.text_changed.emit(repo_edit.text)
	await _screenshot("dock_add_dialog", registry_dialog)
	# Asset Library tab with a canned search (no network in this smoke test).
	registry_dialog.set("assetlib_search", func(_query: String) -> Dictionary:
		return { "ok": true, "error": "", "results": [
			{ "asset_id": "1709", "title": "Debug Draw 3D", "author": "DmitriySalnikov", "version_string": "1.5.1", "godot_version": "4.5", "category": "Tools" },
			{ "asset_id": "2101", "title": "Debug Menu", "author": "someone", "version_string": "1.2.0", "godot_version": "4.4", "category": "Tools" },
		] })
	var source_option: OptionButton = registry_dialog.get("_source_option")
	source_option.select(source_option.get_item_index(2))
	source_option.item_selected.emit(source_option.selected)
	var query_edit: LineEdit = registry_dialog.get("_query_edit")
	query_edit.text = "debug draw"
	await registry_dialog.call("_search")
	var results: ItemList = registry_dialog.get("_results")
	results.select(0)
	results.item_selected.emit(0)
	_expect((registry_dialog.get("_folder_edit") as LineEdit).text == "debug_draw_3d", "folder suggested from the title")
	await _screenshot("dock_add_assetlib", registry_dialog)
	registry_dialog.hide()
	# Cleanup: leave the project and the registry file as they were (no fake_a, no lock).
	var file := FileAccess.open(registry_path, FileAccess.WRITE)
	file.store_string(original_registry)
	file.close()
	await _installer.uninstall(_entry)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(LoadoutLockfile.DEFAULT_PATH))


func _run_remote() -> void:
	var manager: LoadoutManager = _plugin.get_manager()
	await manager.refresh(true)
	_expect(manager.errors.is_empty(), "registry and lock load: %s" % ", ".join(manager.errors))
	for state in manager.states:
		Log.write("remote %s: %s, latest %s, %d releases, notes %d chars, %s" % [state.id, LoadoutManager.Status.find_key(state.status),
				state.latest_version, manager.get_source(state.id).releases.size() if manager.get_source(state.id) != null else 0,
				state.release_notes.length(), state.message if state.message != "" else state.warning])
		_expect(state.latest_version != "", "%s: latest version known" % state.id)
	var summary: Dictionary = await manager.install_missing()
	_expect(summary["failed"].is_empty(), "install: %s" % summary["failed"])
	for state in manager.states:
		_expect(state.status == LoadoutManager.Status.OK, "%s installed, status %s" % [state.id, LoadoutManager.Status.find_key(state.status)])
		_expect(_installer.editor.is_plugin_running(state.entry.folder), "%s EditorPlugin running" % state.id)
		Log.write("remote %s: installed %s, hash %s" % [state.id, state.installed_version, state.lock_entry.folder_hash.left(19) if state.lock_entry != null else "-"])
	for state in manager.states:
		await manager.uninstall(state.id)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(LoadoutLockfile.DEFAULT_PATH))


func _run_self() -> void:
	var manager: LoadoutManager = _plugin.get_manager()
	var dock: Control = _plugin.get_dock()
	await manager.refresh(true)
	var state := manager.get_state("gam")
	if state == null:
		_failures.append("registry has no gam entry")
		return
	var report := SMOKE_DIR.path_join("self.txt")
	if state.status == LoadoutManager.Status.UPDATE:
		# First session: update through the dock; it restarts the editor by itself.
		DirAccess.remove_absolute(ProjectSettings.globalize_path(report))
		_write_text(report, "updating %s -> %s" % [state.installed_version, state.target_version])
		_show_dock(dock)
		var tree: Tree = dock.get("_tree")
		tree.get_root().get_first_child().select(0)
		var button := _find_button(dock, "Update to")
		_expect(button != null, "update button for Loadout")
		if button == null:
			return
		button.pressed.emit()
		var confirm: ConfirmationDialog = dock.get("_confirm")
		await _wait_until(func() -> bool: return confirm.visible, 5000)
		_expect(confirm.dialog_text.contains("restarts"), "confirmation says the editor restarts")
		confirm.get_ok_button().pressed.emit()
		# The restart quits this session; waiting here keeps the smoke from quitting first.
		await _wait_until(func() -> bool: return false, 30000)
		_failures.append("editor did not restart after the self-update")
		return
	# Second session after the restart.
	var gam_version := _cfg_version("res://addons/loadout/plugin.cfg")
	_expect(state.status == LoadoutManager.Status.OK, "Loadout state after restart: %s" % LoadoutManager.Status.find_key(state.status))
	_expect(gam_version == state.latest_version, "running Loadout %s is the newest %s" % [gam_version, state.latest_version])
	_expect(state.lock_entry != null and state.lock_entry.version == gam_version, "lock records %s" % gam_version)
	_expect(EditorInterface.is_plugin_enabled("loadout") and dock.is_inside_tree(), "Loadout enabled and its dock is up")
	_write_text(report, "passed %s" % gam_version if _failures.is_empty() else "failed: " + "; ".join(_failures))


func _cfg_version(path: String) -> String:
	var cfg := ConfigFile.new()
	cfg.load(path)
	return str(cfg.get_value("plugin", "version", ""))


func _write_text(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


func _find_button(root: Node, text_prefix: String) -> Button:
	for node in root.find_children("*", "Button", true, false):
		if (node as Button).text.begins_with(text_prefix):
			return node
	return null


func _cmdline_value(prefix: String) -> String:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with(prefix):
			return arg.trim_prefix(prefix)
	return ""


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
