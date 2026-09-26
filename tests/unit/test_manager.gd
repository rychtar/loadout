extends "res://tests/test_case.gd"

const Manager := preload("res://addons/loadout/core/manager.gd")
const Installer := preload("res://addons/loadout/core/installer.gd")
const Registry := preload("res://addons/loadout/core/registry.gd")
const Lockfile := preload("res://addons/loadout/core/lockfile.gd")
const FakeEditor := preload("res://tests/fake_editor.gd")
const FakeSource := preload("res://tests/fake_source.gd")

const FIXTURES := "res://tests/fixtures/addons/fake_a"

var root: String
var addons: String
var editor: FakeEditor
var manager: Manager
## Per-test override: plugin id -> FakeSource. Others use the real source from the registry.
var fake_sources: Dictionary[String, LoadoutSource] = {}


func _setup(name: String, plugins: Array) -> void:
	root = temp_dir("manager_" + name)
	addons = root.path_join("addons")
	DirAccess.make_dir_recursive_absolute(addons)
	editor = FakeEditor.new(addons)
	var registry := Registry.from_dict({ "schema": 1, "plugins": plugins })["registry"] as Registry
	check_eq(registry.save_file(_registry_path()), OK, "registry saved")
	_create_manager()


func _create_manager() -> void:
	var installer := Installer.new(editor, addons, root.path_join("backup"), root.path_join("staging"))
	# Only captures the dictionary, not self (no reference cycle suite <-> manager).
	var overrides := fake_sources
	var factory := func(entry: LoadoutRegistry.Entry) -> LoadoutSource:
		return overrides[entry.id] if overrides.has(entry.id) else LoadoutSource.create(entry.source)
	manager = Manager.new(installer, _registry_path(), _lock_path(), factory)


func _registry_path() -> String:
	return root.path_join("config/loadout_registry.json")


func _lock_path() -> String:
	return root.path_join("project/loadout.lock.json")


func _local(id: String, version_folder: String, extra: Dictionary = {}) -> Dictionary:
	var data := { "id": id, "folder": id, "source": { "type": "local", "path": ProjectSettings.globalize_path(FIXTURES.path_join(version_folder)) } }
	data.merge(extra, true)
	return data


func _fake(id: String, folders: Array[String]) -> FakeSource:
	var versions: Dictionary[String, String] = {}
	for folder in folders:
		versions[folder.trim_suffix("_broken")] = FIXTURES.path_join(folder)
	var source := FakeSource.new(versions)
	fake_sources[id] = source
	return source


func _status(id: String) -> int:
	var state := manager.get_state(id)
	return state.status if state != null else -1


func _saved_lock() -> Lockfile:
	var result := Lockfile.load_file(_lock_path())
	check(result["ok"] and not result["missing"], "lock file exists")
	return result["lockfile"]


func test_empty_registry() -> void:
	_setup("empty", [])
	await manager.refresh()
	check(manager.states.is_empty(), "no states")
	check(manager.errors.is_empty(), "no errors")
	check(not FileAccess.file_exists(_lock_path()), "no lock written for nothing")


func test_missing_plugin() -> void:
	_setup("missing", [_local("fake_a", "1.0.0")])
	await manager.refresh()
	check_eq(_status("fake_a"), Manager.Status.MISSING, "missing")
	var state := manager.get_state("fake_a")
	check_eq([state.latest_version, state.target_version], ["1.0.0", "1.0.0"], "versions")
	check_eq(state.display_name, "Fake A", "name from source plugin.cfg")
	check_eq(manager.missing_ids(), PackedStringArray(["fake_a"]), "offered for install")


func test_install_missing_writes_lock() -> void:
	_setup("install_missing", [_local("fake_a", "1.0.0")])
	await manager.refresh()
	var summary: Dictionary = await manager.install_missing()
	check_eq(summary["installed"], PackedStringArray(["fake_a"]), "installed")
	check(summary["failed"].is_empty(), "no failures")
	check_eq(_status("fake_a"), Manager.Status.OK, "ok after install")
	check(editor.is_plugin_enabled("fake_a"), "enabled")
	var entry := _saved_lock().get_entry("fake_a")
	check(entry != null and entry.version == "1.0.0", "locked version")
	check(entry != null and entry.folder_hash == Fs.hash_dir(addons.path_join("fake_a")), "locked hash")
	check(entry != null and entry.installed_at != "", "install date")
	check(manager.missing_ids().is_empty(), "nothing missing")


func test_auto_install_false_is_not_offered() -> void:
	_setup("manual", [_local("fake_a", "1.0.0", { "auto_install": false })])
	await manager.refresh()
	check_eq(_status("fake_a"), Manager.Status.MISSING, "still shown as missing")
	check(manager.missing_ids().is_empty(), "not part of install all")


func test_lock_version_wins_for_missing_folder() -> void:
	_setup("lock_wins", [_local("fake_a", "1.0.0")])
	_fake("fake_a", ["1.0.0", "1.1.0"])
	var lock := Lockfile.new()
	lock.set_installed("fake_a", "1.0.0", "sha256:x", "2026-09-01")
	lock.save_file(_lock_path())
	await manager.refresh()
	var state := manager.get_state("fake_a")
	check_eq([state.status, state.latest_version, state.target_version], [Manager.Status.MISSING, "1.1.0", "1.0.0"], "fresh clone installs the locked version")


func test_update_available_and_install() -> void:
	_setup("update", [_local("fake_a", "1.0.0", { "range": "^1.0.0" })])
	var source := _fake("fake_a", ["1.0.0"])
	await manager.refresh()
	await manager.install_missing()
	source.versions["1.1.0"] = FIXTURES.path_join("1.1.0")
	await manager.refresh()
	check_eq(_status("fake_a"), Manager.Status.UPDATE, "update found")
	check_eq(manager.get_state("fake_a").target_version, "1.1.0", "target")
	var result: Dictionary = await manager.install("fake_a")
	check(result["ok"], "updated: %s" % result["error"])
	check_eq(_status("fake_a"), Manager.Status.OK, "ok after update")
	check_eq(_saved_lock().get_entry("fake_a").version, "1.1.0", "lock updated")


func test_range_limits_updates() -> void:
	_setup("range", [_local("fake_a", "1.0.0", { "range": "~1.0.0" })])
	var source := _fake("fake_a", ["1.0.0"])
	await manager.refresh()
	await manager.install_missing()
	source.versions["1.1.0"] = FIXTURES.path_join("1.1.0")
	await manager.refresh()
	check_eq(_status("fake_a"), Manager.Status.OK, "1.1.0 is outside ~1.0.0")


func test_pinned() -> void:
	_setup("pinned", [_local("fake_a", "1.0.0")])
	var source := _fake("fake_a", ["1.0.0"])
	await manager.refresh()
	await manager.install_missing()
	check_eq(await manager.set_pinned("fake_a", true), OK, "pin")
	check(_saved_lock().get_entry("fake_a").pinned, "pin saved")
	source.versions["1.1.0"] = FIXTURES.path_join("1.1.0")
	await manager.refresh()
	check_eq(_status("fake_a"), Manager.Status.PINNED, "pinned wins over update")
	check_eq(manager.get_state("fake_a").latest_version, "1.1.0", "latest still shown")
	var result: Dictionary = await manager.install("fake_a")
	check_eq(result["needs_confirmation"], Installer.CONFIRM_PINNED, "needs confirmation")
	check_eq(await manager.set_pinned("fake_a", false), OK, "unpin")
	await manager.refresh()
	check_eq(_status("fake_a"), Manager.Status.UPDATE, "update after unpin")


func test_modified_and_adopt() -> void:
	_setup("modified", [_local("fake_a", "1.0.0")])
	await manager.refresh()
	await manager.install_missing()
	write_text(addons.path_join("fake_a/plugin.gd"), "# edited")
	await manager.refresh()
	check_eq(_status("fake_a"), Manager.Status.MODIFIED, "modified")
	var result: Dictionary = await manager.install("fake_a")
	check_eq(result["needs_confirmation"], Installer.CONFIRM_MODIFIED, "overwrite needs confirmation")
	check_eq(await manager.adopt("fake_a"), OK, "adopt")
	await manager.refresh()
	check_eq(_status("fake_a"), Manager.Status.OK, "accepted as installed")
	check_eq(_saved_lock().get_entry("fake_a").folder_hash, Fs.hash_dir(addons.path_join("fake_a")), "new hash locked")


func test_force_overwrite_modified() -> void:
	_setup("force", [_local("fake_a", "1.0.0")])
	await manager.refresh()
	await manager.install_missing()
	write_text(addons.path_join("fake_a/plugin.gd"), "# edited")
	await manager.refresh()
	var result: Dictionary = await manager.install("fake_a", true)
	check(result["ok"], "forced")
	check_eq(_status("fake_a"), Manager.Status.OK, "clean again")


func test_unmanaged_folder() -> void:
	_setup("unmanaged", [_local("fake_a", "1.0.0")])
	Fs.copy_dir(FIXTURES.path_join("1.0.0"), addons.path_join("fake_a"))
	await manager.refresh()
	check_eq(_status("fake_a"), Manager.Status.UNMANAGED, "installed by hand")
	check(manager.missing_ids().is_empty(), "not offered as missing")
	check_eq(await manager.adopt("fake_a"), OK, "adopt")
	await manager.refresh()
	check_eq(_status("fake_a"), Manager.Status.OK, "managed now")


func test_uninstall_ignores_plugin_in_project() -> void:
	_setup("uninstall", [_local("fake_a", "1.0.0")])
	await manager.refresh()
	await manager.install_missing()
	var result: Dictionary = await manager.uninstall("fake_a")
	check(result["ok"], "removed: %s" % result["error"])
	check(not DirAccess.dir_exists_absolute(addons.path_join("fake_a")), "folder gone")
	var lock := _saved_lock()
	check(lock.get_entry("fake_a") == null, "lock entry removed")
	check(lock.is_ignored("fake_a"), "ignored so the next sync does not bring it back")
	check_eq(_status("fake_a"), Manager.Status.IGNORED, "ignored")
	check(manager.missing_ids().is_empty(), "not offered")
	check_eq(await manager.set_ignored("fake_a", false), OK, "unignore")
	await manager.refresh()
	check_eq(manager.missing_ids(), PackedStringArray(["fake_a"]), "offered again")


func test_orphan_lock_entry() -> void:
	_setup("orphan", [])
	var lock := Lockfile.new()
	lock.set_installed("gone", "1.0.0", "", "2026-09-01")
	lock.save_file(_lock_path())
	await manager.refresh()
	check_eq(_status("gone"), Manager.Status.ORPHAN, "in lock, not in registry")
	check_eq(await manager.forget("gone"), OK, "forget")
	check(_saved_lock().get_entry("gone") == null, "removed from lock")


func test_source_errors() -> void:
	var gone_b := { "type": "local", "path": "/nonexistent/fake_b" }
	_setup("source_error", [_local("fake_a", "1.0.0"), _local("fake_b", "1.0.0", { "source": gone_b })])
	await manager.refresh()
	var missing := manager.get_state("fake_b")
	check_eq([missing.status, missing.target_version], [Manager.Status.MISSING, ""], "missing without a version")
	check(missing.message != "", "explains why")
	var summary: Dictionary = await manager.install_missing()
	check_eq(summary["installed"], PackedStringArray(["fake_a"]), "others still installed")
	check(summary["failed"].has("fake_b"), "failure reported")
	# Installed plugin whose source disappears is unverified, not broken.
	var registry := Registry.from_dict({ "schema": 1, "plugins": [
		_local("fake_a", "1.0.0", { "source": { "type": "local", "path": "/nonexistent/fake_a" } }),
	] })["registry"] as Registry
	registry.save_file(_registry_path())
	await manager.refresh()
	check_eq(_status("fake_a"), Manager.Status.UNVERIFIED, "unverified")


func test_corrupt_registry_is_reported() -> void:
	_setup("corrupt", [])
	write_text(_registry_path(), "{ broken")
	await manager.refresh()
	check(not manager.errors.is_empty(), "error for the dock")
	check(manager.states.is_empty(), "no states")
	check_eq(await manager.add_registry_entry(_local("fake_a", "1.0.0")), "The registry cannot be read, nothing changed.", "registry is not overwritten")
	check_eq(FileAccess.get_file_as_string(_registry_path()), "{ broken", "file untouched")


func test_registry_edits_are_saved() -> void:
	_setup("registry_edit", [])
	await manager.refresh()
	check_eq(await manager.add_registry_entry(_local("fake_a", "1.0.0")), "", "added")
	check_eq(_status("fake_a"), Manager.Status.MISSING, "state refreshed")
	var saved := Registry.load_file(_registry_path())
	check((saved["registry"] as Registry).get_entry("fake_a") != null, "saved to file")
	check(await manager.add_registry_entry(_local("fake_a", "1.0.0")) != "", "duplicate refused")
	check_eq(await manager.remove_registry_entry("fake_a"), OK, "removed")
	check(manager.get_state("fake_a") == null, "gone from states")


func test_actions_refuse_while_busy() -> void:
	_setup("busy", [_local("fake_a", "1.0.0")])
	await manager.refresh()
	manager.busy = true
	var result: Dictionary = await manager.install("fake_a")
	check(not result["ok"], "refused while another action runs")
	manager.busy = false
