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
## Self-update (GUI or headless; registry has a "loadout" entry pointing to a newer Loadout copy):
##   godot -e --path <project> -- --loadout-registry=<file> --loadout-smoke=self
##   first run updates Loadout from the dock and the editor restarts itself. Godot relaunches it
##   without --headless and without the arguments after "--", so close that editor and run the
##   same command again: the second run checks the new version and writes user://loadout_smoke/self.txt
## Self-update validation, headless, one session, works on a copy under user:// (no restart):
##   godot --headless -e --path . -- --loadout-smoke=selfnew
##   a package that adds a class_name used by another script is accepted, one with a script error is refused
## Exit code 0 = passed.

const GodotEditorBridge := preload("res://addons/loadout/editor/godot_editor_bridge.gd")
const Log := preload("res://addons/loadout/util/log.gd")
const Fs := preload("res://addons/loadout/util/fs.gd")

const FIXTURES := "res://tests/fixtures/addons/fake_a"
const SMOKE_DIR := "user://loadout_smoke"
const AUTOLOAD_NAME := "FakeA"

var _tree: SceneTree
var _installer: LoadoutInstaller
var _entry: LoadoutRegistry.Entry
var _failures: PackedStringArray = []
var _plugin: EditorPlugin
# Dock smoke state, shared by the _dock_* steps.
var _manager: LoadoutManager
var _dock: Control
var _confirm: ConfirmationDialog
var _registry_dialog: ConfirmationDialog
var _registry_path := ""
var _original_registry := ""


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
		"selfnew":
			await _run_selfnew()
		"search":
			await _run_search()
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
	_manager = _plugin.get_manager()
	_dock = _plugin.get_dock()
	_confirm = _dock.get("_confirm")
	_registry_dialog = _dock.get("_registry_dialog")
	_registry_path = _cmdline_value("--loadout-registry=")
	_original_registry = FileAccess.get_file_as_string(_registry_path)
	_show_dock(_dock)
	if not await _dock_install():
		return
	await _dock_versions()
	await _dock_update()
	await _dock_changes()
	await _dock_restore()
	await _dock_edit()
	await _dock_add_dialogs()
	await _dock_new_addon()
	# Cleanup: leave the project and the registry file as they were (no fake_a, no lock).
	_write_text(_registry_path, _original_registry)
	Fs.remove_dir("res://addons/fake_a")
	await _installer.editor.scan()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(LoadoutLockfile.DEFAULT_PATH))


## Startup offer with checkboxes, install of fake_a 1.0.0.
func _dock_install() -> bool:
	var install_dialog: ConfirmationDialog = _dock.get("_install_dialog")
	if not await _wait_until(func() -> bool: return install_dialog.visible, 15000):
		_failures.append("startup sync did not offer the missing plugin")
		return false
	await _screenshot("dock_sync_offer", install_dialog)
	install_dialog.get_ok_button().pressed.emit()
	await _wait_until(func() -> bool: return _status_of("fake_a") == LoadoutManager.Status.OK, 30000)
	_expect_running("1.0.0", "installed from dock")
	_expect(FileAccess.file_exists(LoadoutLockfile.DEFAULT_PATH), "project lock written")
	_select_first_plugin()
	await _screenshot("dock_installed")
	return true


## Version choice: a source with several releases (extra ones only listed, never installed here).
func _dock_versions() -> void:
	var local_source: LoadoutSource = _manager.get_source("fake_a")
	local_source.releases.append({ "version": "0.9.0", "tag": "v0.9.0", "prerelease": false, "notes": "First public version.", "url": "" })
	local_source.releases.append({ "version": "2.0.0-beta.1", "tag": "v2.0.0-beta.1", "prerelease": true, "notes": "Preview of 2.0.", "url": "" })
	_dock.call("_update_detail")
	var version_button := _find_button(_dock, "Install version")
	_expect(version_button != null, "version choice offered for a source with several releases")
	if version_button == null:
		return
	version_button.pressed.emit()
	var version_dialog: ConfirmationDialog = _dock.get("_version_dialog")
	await _wait_until(func() -> bool: return version_dialog.visible, 5000)
	var listed := (version_dialog.get("_list") as ItemList).item_count
	_expect(listed == 3, "all versions listed (%d)" % listed)
	await _screenshot("dock_version_dialog", version_dialog)
	version_dialog.hide()
	await _dialog_closed(version_dialog)


## A new version appears in the source (registry points to 1.1.0): update from the dock.
func _dock_update() -> void:
	var registry: LoadoutRegistry = LoadoutRegistry.load_file(_registry_path)["registry"]
	(registry.get_entry("fake_a").source as Dictionary)["path"] = _fixture("1.1.0")
	registry.save_file(_registry_path)
	await _manager.refresh(true)
	var updates := _manager.update_ids()
	_expect(updates == PackedStringArray(["fake_a"]), "update offered in the dock (%s)" % updates)
	_select_first_plugin()
	await _screenshot("dock_update_available")
	var update_button := _find_button(_dock, "Update to 1.1.0")
	_expect(update_button != null, "update button in the detail")
	if update_button == null:
		return
	update_button.pressed.emit()
	await _wait_until(func() -> bool: return _confirm.visible, 5000)
	await _screenshot("dock_update_confirm", _confirm)
	_confirm.get_ok_button().pressed.emit()
	await _wait_until(func() -> bool: return _status_of("fake_a") == LoadoutManager.Status.OK, 30000)
	_expect_running("1.1.0", "updated from the dock")
	# FakeALegacy was removed in 1.1.0: the dock offers a restart, decline it.
	if await _wait_until(func() -> bool: return _confirm.visible, 5000):
		await _screenshot("dock_restart_offer", _confirm)
		_confirm.get_cancel_button().pressed.emit()
		await _dialog_closed(_confirm)


## A file added by hand makes the plugin Modified; "Show changes…" lists it.
func _dock_changes() -> void:
	var notes := "res://addons/fake_a/notes.txt"
	_write_text(notes, "mine")
	await _manager.refresh()
	_expect(_status_of("fake_a") == LoadoutManager.Status.MODIFIED, "an added file makes the plugin Modified")
	_select_first_plugin()
	var button := _find_button(_dock, "Show changes")
	_expect(button != null, "Show changes offered for a modified plugin")
	if button != null:
		var alert: AcceptDialog = _dock.get("_alert")
		button.pressed.emit()
		await _wait_until(func() -> bool: return alert.visible, 10000)
		_expect(alert.dialog_text.contains("added: notes.txt"), "the changes name the added file (%s)" % alert.dialog_text)
		await _screenshot("dock_changes", alert)
		alert.hide()
		await _dialog_closed(alert)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(notes))
	await _manager.refresh()
	_expect(_status_of("fake_a") == LoadoutManager.Status.OK, "back to OK without the file")


## Restore the backup the update made (1.0.0, pinned), then the newer files again from the next backup.
func _dock_restore() -> void:
	var dialog: ConfirmationDialog = _dock.get("_backup_dialog")
	for expected in ["1.0.0", "1.1.0"]:
		_select_first_plugin()
		var button := _find_button(_dock, "Restore backup")
		_expect(button != null, "Restore backup offered once a backup exists")
		if button == null:
			return
		button.pressed.emit()
		await _wait_until(func() -> bool: return dialog.visible, 5000)
		var list: ItemList = dialog.get("_list")
		_expect(list.item_count >= 1 and list.get_item_text(0).begins_with(expected), "newest backup is %s (%s)" % [expected, list.get_item_text(0) if list.item_count > 0 else "none"])
		await _screenshot("dock_restore_%s" % expected, dialog)
		(dialog.get("_pin_check") as CheckBox).button_pressed = expected == "1.0.0"
		dialog.get_ok_button().pressed.emit()
		await _wait_until(func() -> bool: return not _dock.get("_busy") and _installed_version() == expected, 30000)
		_expect_running(expected, "restored %s from the dock" % expected)
		if await _wait_until(func() -> bool: return _confirm.visible, 3000):
			_confirm.get_cancel_button().pressed.emit()
			await _dialog_closed(_confirm)
		await _dialog_closed(dialog)
	_expect(_status_of("fake_a") == LoadoutManager.Status.OK, "back at 1.1.0, not pinned")


func _installed_version() -> String:
	return _cfg_version("res://addons/fake_a/plugin.cfg")


## Edit the entry: a narrower range, saved to the registry; id and folder stay fixed.
func _dock_edit() -> void:
	_select_first_plugin()
	var edit_button := _find_button(_dock, "Edit")
	_expect(edit_button != null, "edit action in the detail")
	if edit_button == null:
		return
	edit_button.pressed.emit()
	await _wait_until(func() -> bool: return _registry_dialog.visible, 5000)
	var id_edit: LineEdit = _registry_dialog.get("_id_edit")
	var id_fixed := id_edit.text == "fake_a" and not id_edit.editable
	_expect(id_fixed, "id fixed while editing")
	var range_edit: LineEdit = _registry_dialog.get("_range_edit")
	range_edit.text = "~1.1.0"
	range_edit.text_changed.emit(range_edit.text)
	await _screenshot("dock_edit_dialog", _registry_dialog)
	_registry_dialog.get_ok_button().pressed.emit()
	await _wait_until(func() -> bool: return not _dock.get("_busy"), 10000)
	await _dialog_closed(_registry_dialog)
	var saved_range: String = LoadoutRegistry.load_file(_registry_path)["registry"].get_entry("fake_a").version_range
	_expect(saved_range == "~1.1.0", "edited range saved to the registry (%s)" % saved_range)


## The add dialog with a GitHub repository and with an Asset Store search (canned, no network).
func _dock_add_dialogs() -> void:
	_registry_dialog.open()
	var repo_edit: LineEdit = _registry_dialog.get("_repo_edit")
	repo_edit.text = "bitwes/Gut"
	repo_edit.text_changed.emit(repo_edit.text)
	await _screenshot("dock_add_dialog", _registry_dialog)
	_registry_dialog.set("store_search", func(_query: String) -> Dictionary:
		return { "ok": true, "error": "", "results": [
			{ "asset": "dmitriysalnikov/debug-draw-3d", "title": "Debug Draw 3D", "author": "DmitriySalnikov" },
			{ "asset": "someone/debug-menu", "title": "Debug Menu", "author": "someone" },
		] })
	_select_source(2)
	(_registry_dialog.get("_query_edit") as LineEdit).text = "debug draw"
	await _registry_dialog.call("_search")
	var results: ItemList = _registry_dialog.get("_results")
	results.select(0)
	results.item_selected.emit(0)
	var folder := (_registry_dialog.get("_folder_edit") as LineEdit).text
	_expect(folder == "debug_draw_3d", "folder suggested from the title (%s)" % folder)
	await _screenshot("dock_add_store", _registry_dialog)
	_registry_dialog.hide()
	await _dialog_closed(_registry_dialog)
	await _installer.uninstall(_entry)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(LoadoutLockfile.DEFAULT_PATH))


## A plugin installed outside Loadout (like from Godot's Asset Store): offered, added, taken over.
func _dock_new_addon() -> void:
	_write_text(_registry_path, JSON.stringify({ "schema": 1, "plugins": [] }))
	await _manager.refresh()
	_registry_dialog.set("store_search", func(_query: String) -> Dictionary:
		return { "ok": true, "error": "", "results": [
			{ "asset": "someone/fake-a", "title": "Fake A", "author": "someone" },
			{ "asset": "someone/fake-a-extras", "title": "Fake A Extras", "author": "someone" },
		] })
	Fs.copy_dir(FIXTURES.path_join("1.0.0"), "res://addons/fake_a")
	await _installer.editor.scan()
	var offered: bool = await _wait_until(func() -> bool:
		return _confirm.visible and _confirm.dialog_text.contains("New plugin Fake A"), 5000)
	_expect(offered, "new plugin offered after the filesystem change")
	var listed := _unregistered_folders()
	_expect(listed == PackedStringArray(["fake_a"]), "new addon listed (%s)" % listed)
	await _screenshot("dock_new_addon_offer", _confirm)
	await _screenshot("dock_unregistered")
	var add_button: Button = _confirm.get_ok_button() if offered else _find_button(_dock, "Add to registry")
	_expect(add_button != null, "a way to add the new addon")
	if add_button == null:
		return
	add_button.pressed.emit()
	await _wait_until(func() -> bool: return _registry_dialog.visible, 5000)
	var picked: String = _registry_dialog.get("_store_asset")
	_expect(picked == "someone/fake-a", "exact Asset Store name match picked (%s)" % picked)
	var folder_edit: LineEdit = _registry_dialog.get("_folder_edit")
	var folder_fixed := folder_edit.text == "fake_a" and not folder_edit.editable
	_expect(folder_fixed, "folder fixed to the existing one")
	await _screenshot("dock_add_existing", _registry_dialog)
	_select_source(1)
	var path_edit: LineEdit = _registry_dialog.get("_path_edit")
	path_edit.text = _fixture("1.0.0")
	path_edit.text_changed.emit(path_edit.text)
	_expect(folder_edit.text == "fake_a", "local path does not rename the folder")
	_registry_dialog.get_ok_button().pressed.emit()
	await _wait_until(func() -> bool: return _status_of("fake_a") == LoadoutManager.Status.OK, 10000)
	_expect(_status_of("fake_a") == LoadoutManager.Status.OK, "existing addon taken over")
	_expect(_manager.unregistered.is_empty(), "no longer listed")


func _status_of(id: String) -> int:
	var state := _manager.get_state(id)
	return state.status if state != null else -1


func _unregistered_folders() -> PackedStringArray:
	var folders: PackedStringArray = []
	for info: Dictionary in _manager.unregistered:
		folders.append(info["folder"])
	return folders


func _select_first_plugin() -> void:
	(_dock.get("_tree") as Tree).get_root().get_first_child().select(0)


func _select_source(id: int) -> void:
	var option: OptionButton = _registry_dialog.get("_source_option")
	option.select(option.get_item_index(id))
	option.item_selected.emit(option.selected)


## A dialog hides at the end of the frame; opening the next one earlier makes Godot refuse it.
func _dialog_closed(dialog: Window) -> void:
	await _wait_until(func() -> bool: return not dialog.visible, 2000)
	await _tree.process_frame


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
	var state := manager.get_state("loadout")
	if state == null:
		_failures.append("registry has no loadout entry")
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
	var loadout_version := _cfg_version("res://addons/loadout/plugin.cfg")
	_expect(state.status == LoadoutManager.Status.OK, "Loadout state after restart: %s" % LoadoutManager.Status.find_key(state.status))
	_expect(loadout_version == state.latest_version, "running Loadout %s is the newest %s" % [loadout_version, state.latest_version])
	_expect(state.lock_entry != null and state.lock_entry.version == loadout_version, "lock records %s" % loadout_version)
	_expect(EditorInterface.is_plugin_enabled("loadout") and dock.is_inside_tree(), "Loadout enabled and its dock is up")
	_write_text(report, "passed %s" % loadout_version if _failures.is_empty() else "failed: " + "; ".join(_failures))


## Self-update validation in the real editor, on a copy under user:// (res://addons/loadout is not
## touched): a package that adds a class_name used by another script must be accepted (the new class
## is not registered yet), a package with a real script error must be refused and change nothing.
func _run_selfnew() -> void:
	var base := SMOKE_DIR.path_join("selfnew")
	Fs.remove_dir(base)
	var addons := base.path_join("addons")
	var installed := addons.path_join("loadout")
	_expect(Fs.copy_dir("res://addons/loadout", installed, Fs.DEFAULT_EXCLUDE) == OK, "copy of the running Loadout")
	var installer := LoadoutInstaller.new(GodotEditorBridge.new(_tree), addons, base.path_join("backup"), base.path_join("staging"))
	var entry: LoadoutRegistry.Entry = LoadoutRegistry.parse_entry({ "id": "loadout", "folder": "loadout",
			"source": { "type": "local", "path": ProjectSettings.globalize_path(installed) } })["entry"]

	var good := _selfnew_package(base.path_join("package_new_class"), "9.9.9", false)
	var updated: Dictionary = await installer.self_update(entry, LoadoutLocalSource.new(ProjectSettings.globalize_path(good)), "9.9.9")
	_expect(updated["ok"], "a package adding a class_name is accepted: %s" % updated["error"])
	_expect(installer.installed_version(entry) == "9.9.9", "the new files are in place: %s" % installer.installed_version(entry))
	_expect(FileAccess.file_exists(installed.path_join("core/smoke_new_class.gd")), "the new class file was copied")

	var bad := _selfnew_package(base.path_join("package_broken"), "9.9.10", true)
	var refused: Dictionary = await installer.self_update(entry, LoadoutLocalSource.new(ProjectSettings.globalize_path(bad)), "9.9.10")
	_expect(not refused["ok"], "a package with a script error is refused")
	_expect(installer.installed_version(entry) == "9.9.9", "nothing changed after the refusal: %s" % installer.installed_version(entry))
	_expect(not FileAccess.file_exists(installed.path_join("core/smoke_broken.gd")), "the broken script was not copied")
	Fs.remove_dir(base)


## The running Loadout plus a new class and a script that uses it; broken adds a script with an error.
func _selfnew_package(dir: String, version: String, broken: bool) -> String:
	Fs.copy_dir("res://addons/loadout", dir, Fs.DEFAULT_EXCLUDE)
	var cfg := ConfigFile.new()
	cfg.load(dir.path_join("plugin.cfg"))
	cfg.set_value("plugin", "version", version)
	cfg.save(dir.path_join("plugin.cfg"))
	_write_text(dir.path_join("core/smoke_new_class.gd"), "@tool\nclass_name LoadoutSmokeNewClass\nextends RefCounted\n")
	_write_text(dir.path_join("core/smoke_new_user.gd"),
			"@tool\nextends RefCounted\nfunc make() -> Variant:\n\tvar thing: LoadoutSmokeNewClass = LoadoutSmokeNewClass.new()\n\treturn thing\n")
	if broken:
		_write_text(dir.path_join("core/smoke_broken.gd"), "@tool\nextends RefCounted\nfunc f() -> int:\n\treturn missing_name\n")
	return dir


## Asset Store search through the real dialog and network (read-only request).
func _run_search() -> void:
	var dock: Control = _plugin.get_dock()
	var dialog: ConfirmationDialog = dock.get("_registry_dialog")
	dialog.open()
	var option: OptionButton = dialog.get("_source_option")
	option.select(option.get_item_index(2))
	option.item_selected.emit(option.selected)
	(dialog.get("_query_edit") as LineEdit).text = "debug"
	await dialog.call("_search")
	var results: ItemList = dialog.get("_results")
	Log.write("search: %d results, status: %s" % [results.item_count, (dialog.get("_search_status") as Label).text])
	_expect(results.item_count > 0, "search found something")
	dialog.hide()


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
