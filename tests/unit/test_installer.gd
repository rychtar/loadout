extends "res://tests/test_case.gd"

const Installer := preload("res://addons/loadout/core/installer.gd")
const Registry := preload("res://addons/loadout/core/registry.gd")
const Lockfile := preload("res://addons/loadout/core/lockfile.gd")
const FakeEditor := preload("res://tests/fake_editor.gd")
const FakeSource := preload("res://tests/fake_source.gd")

const FIXTURES := "res://tests/fixtures/addons/fake_a"

var root: String
var addons: String
var editor: FakeEditor
var source: FakeSource
var installer: Installer
var entry: Registry.Entry
var events: Array[String] = []


func _setup(name: String) -> void:
	root = temp_dir("installer_" + name)
	addons = root.path_join("addons")
	DirAccess.make_dir_recursive_absolute(addons)
	editor = FakeEditor.new(addons)
	source = FakeSource.new({
		"1.0.0": FIXTURES.path_join("1.0.0"),
		"1.1.0": FIXTURES.path_join("1.1.0"),
		"1.2.0": FIXTURES.path_join("1.2.0_broken"),
	})
	installer = Installer.new(editor, addons, root.path_join("backup"), root.path_join("staging"))
	# Lambdas capture only this local log, capturing self would make a cycle suite <-> installer.
	var log: Array[String] = []
	events = log
	installer.plugin_installed.connect(func(id: String, version: String) -> void: log.append("installed %s %s" % [id, version]))
	installer.plugin_updated.connect(func(id: String, from: String, to: String) -> void: log.append("updated %s %s %s" % [id, from, to]))
	installer.plugin_removed.connect(func(id: String) -> void: log.append("removed %s" % id))
	installer.install_failed.connect(func(id: String, _error: String) -> void: log.append("failed %s" % id))
	entry = Registry.parse_entry({ "id": "fake_a", "folder": "fake_a", "source": { "type": "local", "path": "/fixtures/fake_a" } })["entry"]


func _target() -> String:
	return addons.path_join("fake_a")


func _installed_version() -> String:
	return installer.installed_version(entry)


## Installs 1.0.0 and returns a lock entry matching it.
func _install_base() -> Lockfile.Entry:
	var result: Dictionary = await installer.install(entry, source, "1.0.0")
	check(result["ok"], "base install: %s" % result["error"])
	var lock := Lockfile.new()
	lock.set_installed("fake_a", "1.0.0", result["hash"], "2026-10-01")
	editor.calls.clear()
	events.clear()
	return lock.get_entry("fake_a")


func test_fresh_install() -> void:
	_setup("fresh")
	var result: Dictionary = await installer.install(entry, source, "1.0.0")
	check(result["ok"], "ok: %s" % result["error"])
	check_eq(_installed_version(), "1.0.0", "installed")
	check_eq(result["hash"], Fs.hash_dir(_target()), "hash of installed folder")
	check(editor.is_plugin_enabled("fake_a"), "enabled")
	check_eq(editor.calls, PackedStringArray(["scan", "refresh", "validate", "enable fake_a", "save"]), "editor steps")
	check_eq(events, ["installed fake_a 1.0.0"] as Array[String], "signal")
	check(not DirAccess.dir_exists_absolute(root.path_join("staging/fake_a")), "staging cleaned")


func test_fresh_install_without_enabling() -> void:
	_setup("fresh_disabled")
	var result: Dictionary = await installer.install(entry, source, "1.0.0", null, false, false)
	check(result["ok"], "ok")
	check(not editor.is_plugin_enabled("fake_a"), "left disabled")


func test_update_enabled_plugin() -> void:
	_setup("update")
	var lock_entry: Lockfile.Entry = await _install_base()
	var result: Dictionary = await installer.install(entry, source, "1.1.0", lock_entry)
	check(result["ok"], "ok: %s" % result["error"])
	check_eq([result["from"], result["to"]], ["1.0.0", "1.1.0"], "versions")
	check_eq(_installed_version(), "1.1.0", "new version on disk")
	check(not FileAccess.file_exists(_target().path_join("fake_a_legacy.gd")), "removed file is gone")
	check(editor.is_plugin_enabled("fake_a"), "enabled again")
	check_eq(editor.calls, PackedStringArray(["disable fake_a", "scan", "refresh", "validate", "enable fake_a", "save"]), "editor steps")
	var backup := root.path_join("backup/fake_a/1.0.0")
	check_eq(result["backup_path"], backup, "backup path")
	check_eq(Fs.hash_dir(backup), lock_entry.folder_hash, "backup holds the old version")
	check_eq(events, ["updated fake_a 1.0.0 1.1.0"] as Array[String], "signal")


func test_update_disabled_plugin_stays_disabled() -> void:
	_setup("update_disabled")
	var lock_entry: Lockfile.Entry = await _install_base()
	editor.set_plugin_enabled("fake_a", false)
	editor.calls.clear()
	var result: Dictionary = await installer.install(entry, source, "1.1.0", lock_entry)
	check(result["ok"], "ok")
	check(not editor.is_plugin_enabled("fake_a"), "still disabled")
	check(not editor.calls.has("enable fake_a"), "never enabled")


func test_broken_version_is_rolled_back() -> void:
	_setup("broken")
	var lock_entry: Lockfile.Entry = await _install_base()
	editor.broken_versions = ["1.2.0"]
	var result: Dictionary = await installer.install(entry, source, "1.2.0", lock_entry)
	check(not result["ok"], "fails")
	check(result["restored"], "restored")
	check_eq(_installed_version(), "1.0.0", "old version back")
	check_eq(Fs.hash_dir(_target()), lock_entry.folder_hash, "old files back")
	check(editor.is_plugin_enabled("fake_a"), "old version enabled again")
	check(not editor.calls.slice(0, editor.calls.find("validate") + 1).has("enable fake_a"), "broken version never enabled")
	check_eq(events, ["failed fake_a"] as Array[String], "signal")


func test_plugin_that_does_not_start_is_rolled_back() -> void:
	_setup("not_starting")
	var lock_entry: Lockfile.Entry = await _install_base()
	editor.not_starting_versions = ["1.1.0"]
	var result: Dictionary = await installer.install(entry, source, "1.1.0", lock_entry)
	check(not result["ok"], "fails")
	check(result["restored"], "restored")
	check_eq(_installed_version(), "1.0.0", "old version back")
	check(editor.is_plugin_running("fake_a"), "old version running")


func test_scan_failure_is_rolled_back() -> void:
	_setup("scan_fail")
	var lock_entry: Lockfile.Entry = await _install_base()
	editor.scan_ok = false
	var result: Dictionary = await installer.install(entry, source, "1.1.0", lock_entry)
	check(not result["ok"], "fails")
	check(result["restart_recommended"], "restore could not finish the scan either, restart offered")
	check_eq(_installed_version(), "1.0.0", "old files back on disk")


func test_broken_fresh_install_leaves_nothing() -> void:
	_setup("broken_fresh")
	editor.broken_versions = ["1.2.0"]
	var result: Dictionary = await installer.install(entry, source, "1.2.0")
	check(not result["ok"], "fails")
	check(not DirAccess.dir_exists_absolute(_target()), "folder removed")
	check(not editor.is_plugin_enabled("fake_a"), "not enabled")


func test_missing_version_changes_nothing() -> void:
	_setup("missing_version")
	var lock_entry: Lockfile.Entry = await _install_base()
	var result: Dictionary = await installer.install(entry, source, "9.9.9", lock_entry)
	check(not result["ok"], "fails")
	check_eq(Fs.hash_dir(_target()), lock_entry.folder_hash, "untouched")
	check(editor.calls.is_empty(), "editor not touched")


func test_package_without_plugin_cfg() -> void:
	_setup("no_cfg")
	var empty := temp_dir("installer_no_cfg_pkg")
	write_text(empty.path_join("readme.txt"), "x")
	source.versions["3.0.0"] = empty
	var result: Dictionary = await installer.install(entry, source, "3.0.0")
	check(not result["ok"], "fails")
	check(not DirAccess.dir_exists_absolute(_target()), "nothing installed")


func test_modified_folder_needs_confirmation() -> void:
	_setup("modified")
	var lock_entry: Lockfile.Entry = await _install_base()
	write_text(_target().path_join("plugin.gd"), "# my local change")
	var result: Dictionary = await installer.install(entry, source, "1.1.0", lock_entry)
	check(not result["ok"], "refused")
	check_eq(result["needs_confirmation"], Installer.CONFIRM_MODIFIED, "reason")
	check_eq(FileAccess.get_file_as_string(_target().path_join("plugin.gd")), "# my local change", "change kept")
	check(editor.calls.is_empty(), "editor not touched")
	var forced: Dictionary = await installer.install(entry, source, "1.1.0", lock_entry, true)
	check(forced["ok"], "force overwrites")
	check(FileAccess.get_file_as_string(forced["backup_path"].path_join("plugin.gd")) == "# my local change", "local change is in the backup")


func test_pinned_needs_confirmation() -> void:
	_setup("pinned")
	var lock_entry: Lockfile.Entry = await _install_base()
	lock_entry.pinned = true
	var result: Dictionary = await installer.install(entry, source, "1.1.0", lock_entry)
	check_eq(result["needs_confirmation"], Installer.CONFIRM_PINNED, "pinned")
	check_eq(_installed_version(), "1.0.0", "unchanged")


func test_unmanaged_folder_needs_confirmation() -> void:
	_setup("unmanaged")
	Fs.copy_dir(FIXTURES.path_join("1.0.0"), _target())
	var result: Dictionary = await installer.install(entry, source, "1.1.0")
	check_eq(result["needs_confirmation"], Installer.CONFIRM_UNMANAGED, "installed by hand, not in lock")
	check_eq(_installed_version(), "1.0.0", "unchanged")


func test_uid_files_are_preserved() -> void:
	_setup("uids")
	var lock_entry: Lockfile.Entry = await _install_base()
	# The editor generates .uid files after the first install.
	write_text(_target().path_join("fake_a_util.gd.uid"), "uid://util")
	write_text(_target().path_join("fake_a_legacy.gd.uid"), "uid://legacy")
	var result: Dictionary = await installer.install(entry, source, "1.1.0", lock_entry)
	check(result["ok"], "ok")
	check_eq(FileAccess.get_file_as_string(_target().path_join("fake_a_util.gd.uid")), "uid://util", "uid of kept file preserved")
	check(not FileAccess.file_exists(_target().path_join("fake_a_legacy.gd.uid")), "uid of removed file dropped")


func test_shipped_uid_wins() -> void:
	_setup("shipped_uid")
	var lock_entry: Lockfile.Entry = await _install_base()
	write_text(_target().path_join("plugin.gd.uid"), "uid://old")
	var package := temp_dir("installer_shipped_uid_pkg")
	Fs.copy_dir(FIXTURES.path_join("1.1.0"), package)
	write_text(package.path_join("plugin.gd.uid"), "uid://shipped")
	source.versions["1.1.0"] = package
	await installer.install(entry, source, "1.1.0", lock_entry)
	check_eq(FileAccess.get_file_as_string(_target().path_join("plugin.gd.uid")), "uid://shipped", "package uid kept")


func test_restart_recommended_for_stale_classes() -> void:
	_setup("stale")
	var lock_entry: Lockfile.Entry = await _install_base()
	editor.stale = ["FakeALegacy"]
	var result: Dictionary = await installer.install(entry, source, "1.1.0", lock_entry)
	check(result["ok"] and result["restart_recommended"], "restart recommended")


func test_uninstall() -> void:
	_setup("uninstall")
	await _install_base()
	var result: Dictionary = await installer.uninstall(entry)
	check(result["ok"], "ok: %s" % result["error"])
	check(not DirAccess.dir_exists_absolute(_target()), "folder removed")
	check(not editor.is_plugin_enabled("fake_a"), "disabled")
	check(FileAccess.file_exists(root.path_join("backup/fake_a/1.0.0/plugin.cfg")), "backup kept")
	check_eq(editor.calls, PackedStringArray(["disable fake_a", "scan", "save"]), "editor steps")
	check_eq(events, ["removed fake_a"] as Array[String], "signal")
	var again: Dictionary = await installer.uninstall(entry)
	check(not again["ok"], "nothing to remove")


func test_installer_stays_in_addons_dir() -> void:
	_setup("paths")
	check_eq(installer.target_dir(entry), addons.path_join("fake_a"), "target under the configured addons dir")


func _gam_package(version: String) -> String:
	var dir := temp_dir("installer_gam_pkg_" + version)
	write_text(dir.path_join("plugin.cfg"), "[plugin]\n\nname=\"Loadout\"\nversion=\"%s\"\nscript=\"plugin.gd\"\n" % version)
	write_text(dir.path_join("plugin.gd"), "@tool\nextends EditorPlugin\n# %s\n" % version)
	return dir


func test_self_update_replaces_files_without_touching_the_editor() -> void:
	_setup("self_update")
	var gam: Registry.Entry = Registry.parse_entry({ "id": "gam", "folder": "loadout", "source": { "type": "local", "path": "/x" } })["entry"]
	Fs.copy_dir(_gam_package("0.0.1"), addons.path_join("loadout"))
	write_text(addons.path_join("loadout/plugin.gd.uid"), "uid://gam")
	source.versions["0.0.2"] = _gam_package("0.0.2")
	var result: Dictionary = await installer.self_update(gam, source, "0.0.2")
	check(result["ok"], "ok: %s" % result["error"])
	check(result["restart_required"], "editor restart required")
	check_eq(installer.installed_version(gam), "0.0.2", "new files on disk")
	check(editor.calls.is_empty(), "never disabled, scanned or enabled (it would stop Loadout itself)")
	check(FileAccess.file_exists(root.path_join("backup/gam/0.0.1/plugin.cfg")), "backup of the running version")
	check_eq(FileAccess.get_file_as_string(addons.path_join("loadout/plugin.gd.uid")), "uid://gam", "uid preserved")
	check_eq(result["hash"], Fs.hash_dir(addons.path_join("loadout")), "hash")
	check_eq(events, ["updated gam 0.0.1 0.0.2"] as Array[String], "signal")


func test_self_update_failed_download_changes_nothing() -> void:
	_setup("self_update_fail")
	var gam: Registry.Entry = Registry.parse_entry({ "id": "gam", "folder": "loadout", "source": { "type": "local", "path": "/x" } })["entry"]
	Fs.copy_dir(_gam_package("0.0.1"), addons.path_join("loadout"))
	var before := Fs.hash_dir(addons.path_join("loadout"))
	var result: Dictionary = await installer.self_update(gam, source, "9.9.9")
	check(not result["ok"], "fails")
	check_eq(Fs.hash_dir(addons.path_join("loadout")), before, "untouched")
