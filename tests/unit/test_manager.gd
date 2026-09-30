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
		return overrides[entry.id] if overrides.has(entry.id) else LoadoutSource.create(entry)
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


## A second project on the same machine: same registry and update cache, own addons and lock.
func _second_project(source: FakeSource) -> Manager:
	var other_addons := root.path_join("project_b/addons")
	DirAccess.make_dir_recursive_absolute(other_addons)
	var other_editor := FakeEditor.new(other_addons)
	var installer := Installer.new(other_editor, other_addons, root.path_join("backup_b"), root.path_join("staging_b"))
	var factory := func(_entry: LoadoutRegistry.Entry) -> LoadoutSource: return source
	return Manager.new(installer, _registry_path(), root.path_join("project_b/loadout.lock.json"), factory)


func test_pin_applies_per_project() -> void:
	_setup("two_projects", [_local("fake_a", "1.0.0")])
	var source := _fake("fake_a", ["1.0.0"])
	var other := _second_project(source)
	await manager.refresh()
	await manager.install_missing()
	await other.refresh()
	await other.install_missing()
	check_eq(await manager.set_pinned("fake_a", true), OK, "pinned in project A")
	source.versions["1.1.0"] = FIXTURES.path_join("1.1.0")
	await manager.refresh(true)
	await other.refresh(true)
	check_eq(_status("fake_a"), Manager.Status.PINNED, "project A keeps its pin")
	check_eq(other.get_state("fake_a").status, Manager.Status.UPDATE, "project B is offered the update")
	var result: Dictionary = await other.install("fake_a")
	check(result["ok"], "project B updated: %s" % result["error"])
	await manager.refresh()
	check_eq(manager.installer.installed_version(manager.registry.get_entry("fake_a")), "1.0.0", "project A untouched")
	check_eq(_status("fake_a"), Manager.Status.PINNED, "still pinned")


func test_update_ids_and_release_notes() -> void:
	_setup("notes", [_local("fake_a", "1.0.0")])
	var source := _fake("fake_a", ["1.0.0"])
	await manager.refresh()
	await manager.install_missing()
	check(manager.update_ids().is_empty(), "no updates")
	source.versions["1.1.0"] = FIXTURES.path_join("1.1.0")
	source.notes["1.1.0"] = "Bug fixes."
	await manager.refresh(true)
	check_eq(manager.update_ids(), PackedStringArray(["fake_a"]), "update found")
	var state := manager.get_state("fake_a")
	check_eq(state.release_notes, "Bug fixes.", "notes of the target release")
	check_eq(state.release_url, "https://example.com/1.1.0", "release page")


func test_remote_source_is_checked_once_a_day() -> void:
	_setup("remote_daily", [_local("fake_a", "1.0.0")])
	var source := _fake("fake_a", ["1.0.0"])
	source.remote = true
	await manager.refresh()
	await manager.refresh()
	check_eq(source.list_calls, 1, "second refresh uses the cache")
	await manager.refresh(true)
	check_eq(source.list_calls, 2, "manual check asks again")


func test_offline_keeps_state_with_warning() -> void:
	_setup("offline", [_local("fake_a", "1.0.0")])
	var source := _fake("fake_a", ["1.0.0", "1.1.0"])
	source.remote = true
	await manager.refresh()
	source.fail_list = "Cannot connect."
	await manager.refresh(true)
	var state := manager.get_state("fake_a")
	check_eq([state.status, state.target_version], [Manager.Status.MISSING, "1.1.0"], "cached releases still usable")
	check(state.warning.contains("Cannot connect"), "warning for the dock: %s" % state.warning)


func test_install_uses_releases_from_refresh() -> void:
	_setup("remote_install", [_local("fake_a", "1.0.0")])
	var source := _fake("fake_a", ["1.0.0"])
	source.remote = true
	await manager.refresh()
	var result: Dictionary = await manager.install("fake_a")
	check(result["ok"], "installed: %s" % result["error"])
	check_eq(source.fetched, PackedStringArray(["1.0.0"]), "fetched once from the same source")


func test_install_updates() -> void:
	_setup("update_all", [_local("fake_a", "1.0.0"), _local("fake_b", "1.0.0")])
	var source_a := _fake("fake_a", ["1.0.0"])
	var source_b := _fake("fake_b", ["1.0.0"])
	await manager.refresh()
	await manager.install_missing()
	check_eq(await manager.set_pinned("fake_b", true), OK, "b pinned")
	source_a.versions["1.1.0"] = FIXTURES.path_join("1.1.0")
	source_b.versions["1.1.0"] = FIXTURES.path_join("1.1.0")
	await manager.refresh(true)
	var summary: Dictionary = await manager.install_updates()
	check_eq(summary["installed"], PackedStringArray(["fake_a"]), "only the unpinned plugin")
	check_eq(_status("fake_a"), Manager.Status.OK, "a updated")
	check_eq(_status("fake_b"), Manager.Status.PINNED, "b untouched")


func _gam_package(version: String) -> String:
	var dir := temp_dir("manager_gam_pkg_" + version)
	write_text(dir.path_join("plugin.cfg"), "[plugin]\n\nname=\"Loadout\"\nversion=\"%s\"\nscript=\"plugin.gd\"\n" % version)
	write_text(dir.path_join("plugin.gd"), "@tool\nextends EditorPlugin\n# %s\n" % version)
	return dir


func _setup_gam(name: String) -> FakeSource:
	_setup(name, [{ "id": "gam", "folder": "loadout", "source": { "type": "local", "path": "/gam" } }])
	Fs.copy_dir(_gam_package("0.0.1"), addons.path_join("loadout"))
	var source := FakeSource.new({ "0.0.1": _gam_package("0.0.1") })
	fake_sources["gam"] = source
	return source


func test_gam_is_managed_without_lock_entry() -> void:
	var source := _setup_gam("self_state")
	await manager.refresh()
	check_eq(_status("gam"), Manager.Status.OK, "Loadout copied by the install script is not 'unmanaged'")
	source.versions["0.0.2"] = _gam_package("0.0.2")
	await manager.refresh(true)
	check_eq(_status("gam"), Manager.Status.UPDATE, "self update offered")


func test_self_update_requests_restart() -> void:
	var source := _setup_gam("self_update")
	source.versions["0.0.2"] = _gam_package("0.0.2")
	await manager.refresh()
	var restarts := [0]
	manager.restart_required.connect(func() -> void: restarts[0] += 1)
	var result: Dictionary = await manager.install("gam")
	check(result["ok"], "ok: %s" % result["error"])
	check_eq(restarts[0], 1, "restart requested")
	check(editor.calls.is_empty(), "Loadout never disabled itself")
	check_eq(_saved_lock().get_entry("gam").version, "0.0.2", "lock updated before the restart")


func test_gam_cannot_be_uninstalled() -> void:
	_setup_gam("self_uninstall")
	await manager.refresh()
	var result: Dictionary = await manager.uninstall("gam")
	check(not result["ok"], "refused")
	check(DirAccess.dir_exists_absolute(addons.path_join("loadout")), "still there")


func test_export_registry() -> void:
	_setup("export", [_local("fake_a", "1.0.0")])
	await manager.refresh()
	var path := root.path_join("export/registry.json")
	check_eq(manager.export_registry(path), OK, "exported")
	var exported := Registry.load_file(path)
	check(exported["ok"], "valid registry file")
	check_eq((exported["registry"] as Registry).to_dict(), manager.registry.to_dict(), "same content")


func test_import_registry_adds_new_entries_only() -> void:
	_setup("import", [_local("fake_a", "1.0.0")])
	await manager.refresh()
	var path := root.path_join("import/registry.json")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	write_text(path, JSON.stringify({ "schema": 1, "plugins": [
		_local("fake_a", "1.1.0"),
		{ "id": "gut", "folder": "gut", "source": { "type": "github", "repo": "bitwes/Gut" } },
		{ "id": "bad", "folder": "../bad", "source": { "type": "local", "path": "/x" } },
	] }))
	var summary: Dictionary = await manager.import_registry(path)
	check(summary["ok"], "ok: %s" % summary["error"])
	check_eq(summary["added"], PackedStringArray(["gut"]), "new entry added")
	check(summary["skipped"].has("fake_a"), "existing id kept, not overwritten")
	check_eq(manager.registry.get_entry("fake_a").source["path"], _local("fake_a", "1.0.0")["source"]["path"], "local entry unchanged")
	check(Registry.load_file(_registry_path())["registry"].get_entry("gut") != null, "saved")
	check_eq(summary["warnings"].size(), 1, "invalid entry reported")


func test_import_invalid_file() -> void:
	_setup("import_invalid", [])
	await manager.refresh()
	var path := root.path_join("import/not_registry.json")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	write_text(path, "{ \"schema\": 1, \"plugins\": {} }")
	check(not (await manager.import_registry(path))["ok"], "not a registry")
	check(not (await manager.import_registry(root.path_join("missing.json")))["ok"], "missing file")


func _unregistered_folders() -> PackedStringArray:
	var folders: PackedStringArray = []
	for info: Dictionary in manager.unregistered:
		folders.append(info["folder"])
	return folders


func test_lists_project_addons_not_in_the_registry() -> void:
	_setup("unregistered", [_local("fake_a", "1.0.0")])
	Fs.copy_dir(FIXTURES.path_join("1.0.0"), addons.path_join("existing"))
	Fs.copy_dir(_gam_package("0.0.1"), addons.path_join("loadout"))
	DirAccess.make_dir_recursive_absolute(addons.path_join("no_plugin_cfg"))
	await manager.refresh()
	check_eq(_unregistered_folders(), PackedStringArray(["existing"]), "only plugins Loadout does not know")
	var info: Dictionary = manager.unregistered[0]
	check_eq([info["name"], info["version"]], ["Fake A", "1.0.0"], "name and version from plugin.cfg")
	await manager.install_missing()
	check_eq(_unregistered_folders(), PackedStringArray(["existing"]), "registered plugins never listed")


func test_add_existing_addon_takes_it_over() -> void:
	_setup("take_over", [])
	Fs.copy_dir(FIXTURES.path_join("1.0.0"), addons.path_join("fake_a"))
	await manager.refresh()
	check_eq(_unregistered_folders(), PackedStringArray(["fake_a"]), "listed before")
	check_eq(await manager.add_registry_entry(_local("fake_a", "1.0.0"), true), "", "added")
	check_eq(_status("fake_a"), Manager.Status.OK, "managed right away")
	var entry := _saved_lock().get_entry("fake_a")
	check(entry != null and entry.version == "1.0.0", "version locked")
	check(entry != null and entry.folder_hash == Fs.hash_dir(addons.path_join("fake_a")), "current files locked")
	check(manager.unregistered.is_empty(), "no longer listed")
	check(editor.calls.is_empty(), "files untouched, plugin not toggled")


func test_take_over_older_copy_offers_update() -> void:
	_setup("take_over_old", [])
	Fs.copy_dir(FIXTURES.path_join("1.0.0"), addons.path_join("fake_a"))
	_fake("fake_a", ["1.0.0", "1.1.0"])
	await manager.refresh()
	check_eq(await manager.add_registry_entry(_local("fake_a", "1.0.0"), true), "", "added")
	check_eq(_status("fake_a"), Manager.Status.UPDATE, "the source has a newer version")


func test_take_over_without_folder_just_adds() -> void:
	_setup("take_over_missing", [])
	await manager.refresh()
	check_eq(await manager.add_registry_entry(_local("fake_a", "1.0.0"), true), "", "added")
	check_eq(_status("fake_a"), Manager.Status.MISSING, "nothing to take over")
	check(not FileAccess.file_exists(_lock_path()), "no lock entry written")


func _new_folders(found: Array[Dictionary]) -> PackedStringArray:
	var folders: PackedStringArray = []
	for info in found:
		folders.append(info["folder"])
	return folders


func test_detects_addons_added_after_start() -> void:
	_setup("detect", [_local("fake_a", "1.0.0")])
	Fs.copy_dir(FIXTURES.path_join("1.0.0"), addons.path_join("before_start"))
	await manager.refresh()
	check(manager.detect_new_addons().is_empty(), "plugins present at start are not announced")
	Fs.copy_dir(FIXTURES.path_join("1.0.0"), addons.path_join("from_store"))
	check_eq(_new_folders(manager.detect_new_addons()), PackedStringArray(["from_store"]), "new plugin announced")
	check(manager.detect_new_addons().is_empty(), "announced only once")
	check_eq(_unregistered_folders(), PackedStringArray(["before_start", "from_store"]), "listed in the dock section")


func test_plugins_installed_by_gam_are_not_announced() -> void:
	_setup("detect_gam", [_local("fake_a", "1.0.0")])
	await manager.refresh()
	await manager.install_missing()
	check(manager.detect_new_addons().is_empty(), "registered plugin installed by Loadout")
	Fs.copy_dir(_gam_package("0.0.2"), addons.path_join("loadout"))
	DirAccess.make_dir_recursive_absolute(addons.path_join("not_a_plugin"))
	check(manager.detect_new_addons().is_empty(), "Loadout itself and folders without plugin.cfg ignored")


func test_removed_registry_entry_is_not_announced() -> void:
	_setup("detect_removed", [_local("fake_a", "1.0.0")])
	await manager.refresh()
	await manager.install_missing()
	await manager.remove_registry_entry("fake_a")
	check(manager.detect_new_addons().is_empty(), "the user removed it from the registry on purpose")


func test_available_versions() -> void:
	_setup("versions", [_local("fake_a", "1.0.0", { "range": "^1.0.0" })])
	var source := _fake("fake_a", ["1.0.0", "1.1.0"])
	source.versions["2.0.0"] = FIXTURES.path_join("1.1.0")
	await manager.refresh()
	var versions: PackedStringArray = []
	var in_range: Array[bool] = []
	for release in manager.available_versions("fake_a"):
		versions.append(release["version"])
		in_range.append(release["in_range"])
	check_eq(versions, PackedStringArray(["2.0.0", "1.1.0", "1.0.0"]), "newest first")
	check_eq(in_range, [false, true, true] as Array[bool], "range marked")
	check(manager.available_versions("unknown").is_empty(), "unknown plugin")


func test_install_chosen_version_and_pin() -> void:
	_setup("install_version", [_local("fake_a", "1.0.0")])
	_fake("fake_a", ["1.0.0", "1.1.0"])
	await manager.refresh()
	var result: Dictionary = await manager.install("fake_a", false, "1.0.0", true)
	check(result["ok"], "installed: %s" % result["error"])
	check_eq(_saved_lock().get_entry("fake_a").version, "1.0.0", "chosen version locked")
	check(_saved_lock().get_entry("fake_a").pinned, "pinned as asked")
	check_eq(_status("fake_a"), Manager.Status.PINNED, "no update offered")
	var switched: Dictionary = await manager.install("fake_a", false, "1.1.0", false)
	check(switched["ok"], "a pinned plugin can switch versions on explicit choice: %s" % switched["error"])
	check_eq(_status("fake_a"), Manager.Status.OK, "unpinned at the newest version")


func test_chosen_version_never_overwrites_manual_edits() -> void:
	_setup("version_modified", [_local("fake_a", "1.0.0")])
	_fake("fake_a", ["1.0.0", "1.1.0"])
	await manager.refresh()
	await manager.install("fake_a", false, "1.0.0", true)
	write_text(addons.path_join("fake_a/plugin.gd"), "# edited")
	await manager.refresh()
	var result: Dictionary = await manager.install("fake_a", false, "1.1.0", true)
	check_eq(result["needs_confirmation"], Installer.CONFIRM_MODIFIED, "edited files still need confirmation")


func test_unknown_version_refused() -> void:
	_setup("bad_version", [_local("fake_a", "1.0.0")])
	_fake("fake_a", ["1.0.0"])
	await manager.refresh()
	check(not (await manager.install("fake_a", false, "9.9.9"))["ok"], "version the source does not have")


func test_package_folder_mismatch_on_first_install() -> void:
	_setup("folder_mismatch", [_local("fake_a", "1.0.0", { "folder": "fake_a_wrong" })])
	var source := _fake("fake_a", ["1.0.0"])
	source.package_folder = "fake_a"
	await manager.refresh()
	var result: Dictionary = await manager.install("fake_a")
	check_eq(result["needs_confirmation"], Installer.CONFIRM_FOLDER, "asks before installing under another name")
	check_eq(result["package_folder"], "fake_a", "folder used by the package")
	check(not DirAccess.dir_exists_absolute(addons.path_join("fake_a_wrong")), "nothing installed")
	check_eq(await manager.set_registry_folder("fake_a", "fake_a"), "", "registry fixed")
	check_eq(Registry.load_file(_registry_path())["registry"].get_entry("fake_a").folder, "fake_a", "saved")
	var retry: Dictionary = await manager.install("fake_a")
	check(retry["ok"], "installed into the right folder: %s" % retry["error"])
	check(DirAccess.dir_exists_absolute(addons.path_join("fake_a")), "right folder")


func test_install_missing_reports_folder_mismatch() -> void:
	_setup("missing_folder", [_local("fake_a", "1.0.0", { "folder": "fake_a_wrong" })])
	var source := _fake("fake_a", ["1.0.0"])
	source.package_folder = "fake_a"
	await manager.refresh()
	var summary: Dictionary = await manager.install_missing()
	check(summary["failed"].is_empty(), "not a failure")
	check_eq(summary["folders"], { "fake_a": "fake_a" }, "package folder to confirm")
	var fixed: Dictionary = await manager.use_package_folders(summary["folders"])
	check_eq(fixed["installed"], PackedStringArray(["fake_a"]), "installed after fixing the folder")
	check(DirAccess.dir_exists_absolute(addons.path_join("fake_a")), "right folder")
