extends "res://tests/test_case.gd"
## Manager behaviour found by reading the dock and the manager: two editors sharing one registry,
## and the details a confirmation dialog needs to repeat an action.

const Manager := preload("res://addons/loadout/core/manager.gd")
const Installer := preload("res://addons/loadout/core/installer.gd")
const Registry := preload("res://addons/loadout/core/registry.gd")
const FakeEditor := preload("res://tests/fake_editor.gd")
const FakeSource := preload("res://tests/fake_source.gd")

const FIXTURES := "res://tests/fixtures/addons/fake_a"

var root: String
var addons: String
var editor: FakeEditor
var fake_sources: Dictionary[String, LoadoutSource] = {}
## Editor of the last manager made by _manager().
var last_editor: FakeEditor


func _setup(name: String, plugins: Array) -> void:
	root = temp_dir("manager_gaps_" + name)
	addons = root.path_join("addons")
	DirAccess.make_dir_recursive_absolute(addons)
	editor = FakeEditor.new(addons)
	var registry := Registry.from_dict({ "schema": 1, "plugins": plugins })["registry"] as Registry
	check_eq(registry.save_file(_registry_path()), OK, "registry saved")


## Another editor with its own project (addons, lock) but the same global registry file.
func _manager(project: String) -> Manager:
	var project_addons := root.path_join(project).path_join("addons")
	DirAccess.make_dir_recursive_absolute(project_addons)
	last_editor = FakeEditor.new(project_addons)
	var installer := Installer.new(last_editor, project_addons, root.path_join(project + "_backup"), root.path_join(project + "_staging"))
	var overrides := fake_sources
	var factory := func(entry: LoadoutRegistry.Entry) -> LoadoutSource:
		return overrides[entry.id] if overrides.has(entry.id) else LoadoutSource.create(entry)
	return Manager.new(installer, _registry_path(), root.path_join(project).path_join("loadout.lock.json"), factory)


func _registry_path() -> String:
	return root.path_join("config/loadout_registry.json")


func _local(id: String, version_folder: String) -> Dictionary:
	return { "id": id, "folder": id, "source": { "type": "local", "path": ProjectSettings.globalize_path(FIXTURES.path_join(version_folder)) } }


func _ids_in_registry_file() -> PackedStringArray:
	var ids: PackedStringArray = []
	for entry in Registry.load_file(_registry_path())["registry"].entries:
		ids.append(entry.id)
	ids.sort()
	return ids


func test_registry_change_in_another_editor_is_not_lost() -> void:
	_setup("lost_update", [])
	var a := _manager("project_a")
	var b := _manager("project_b")
	await a.refresh()
	await b.refresh()
	check_eq(await b.add_registry_entry(_local("plugin_b", "1.0.0")), "", "editor B adds a plugin")
	# Editor A still holds the registry it read before B saved.
	check_eq(await a.add_registry_entry(_local("plugin_a", "1.1.0")), "", "editor A adds another plugin")
	check_eq(_ids_in_registry_file(), PackedStringArray(["plugin_a", "plugin_b"]), "both plugins are in the global registry")


func test_removal_in_another_editor_is_not_undone() -> void:
	_setup("lost_removal", [_local("one", "1.0.0"), _local("two", "1.0.0")])
	var a := _manager("project_a")
	var b := _manager("project_b")
	await a.refresh()
	await b.refresh()
	check_eq(await b.remove_registry_entry("one"), OK, "B removes one")
	check_eq(await a.update_registry_entry("two", { "source": _local("two", "1.1.0")["source"], "range": "*" }), "", "A edits two")
	check_eq(_ids_in_registry_file(), PackedStringArray(["two"]), "the removal of one is kept")


func test_confirmation_result_carries_the_chosen_version_and_pin() -> void:
	_setup("confirm_version", [_local("fake_a", "1.0.0")])
	var source := FakeSource.new({ "1.0.0": FIXTURES.path_join("1.0.0"), "1.1.0": FIXTURES.path_join("1.1.0") })
	fake_sources["fake_a"] = source
	var manager := _manager("project")
	await manager.refresh()
	await manager.install("fake_a", false, "1.1.0", false)
	write_text(root.path_join("project/addons/fake_a/plugin.gd"), "# edited by hand")
	await manager.refresh()
	var refused: Dictionary = await manager.install("fake_a", false, "1.0.0", true)
	check_eq(refused["needs_confirmation"], Installer.CONFIRM_MODIFIED, "needs confirmation")
	# The dock repeats the action after "Overwrite" with exactly what the user chose.
	check_eq(refused.get("version"), "1.0.0", "result names the version the user chose")
	check_eq(refused.get("pin"), true, "and the pin choice")


func test_local_plugin_with_an_invalid_version_says_so() -> void:
	_setup("bad_local_version", [])
	var plugin := root.path_join("plugin_src")
	DirAccess.make_dir_recursive_absolute(plugin)
	write_text(plugin.path_join("plugin.cfg"), "[plugin]\nname=\"X\"\nscript=\"p.gd\"\nversion=\"1.2.3.4\"\n")
	var source := LoadoutLocalSource.new(ProjectSettings.globalize_path(plugin))
	var latest := await source.get_latest_version("*")
	check(not latest["ok"], "not installable")
	check(not latest["error"].contains("does not match range"), "the message blames the version, not the range: %s" % latest["error"])


func test_manager_reports_when_the_first_refresh_is_done() -> void:
	_setup("loaded", [_local("fake_a", "1.0.0")])
	var manager := _manager("project")
	check(not manager.loaded, "not loaded before the first refresh (the dock must not say 'registry is empty')")
	await manager.refresh()
	check(manager.loaded, "loaded after it")



func _fake_source(versions: Dictionary) -> FakeSource:
	var typed: Dictionary[String, String] = {}
	for version: String in versions:
		typed[version] = FIXTURES.path_join(versions[version])
	var source := FakeSource.new(typed)
	fake_sources["fake_a"] = source
	return source


func test_a_version_that_does_not_start_suggests_an_older_one() -> void:
	_setup("fallback", [_local("fake_a", "1.0.0")])
	_fake_source({ "1.0.0": "1.0.0", "1.1.0": "1.1.0" })
	var manager := _manager("project")
	last_editor.not_starting_versions.append("1.1.0")
	await manager.refresh()
	var result: Dictionary = await manager.install("fake_a")
	check(not result["ok"] and result["load_failed"], "the newest version does not start")
	check_eq(result.get("fallback_version"), "1.0.0", "the next older release is suggested")
	var again: Dictionary = await manager.install("fake_a", false, "1.0.0", true)
	check(again["ok"], "and it works: %s" % again["error"])
	check_eq(again.get("fallback_version", ""), "", "nothing older to suggest after a success")


func test_install_missing_reports_the_older_version() -> void:
	_setup("fallback_all", [_local("fake_a", "1.0.0")])
	_fake_source({ "1.0.0": "1.0.0", "1.1.0": "1.1.0" })
	var manager := _manager("project")
	last_editor.not_starting_versions.append("1.1.0")
	await manager.refresh()
	var summary: Dictionary = await manager.install_missing()
	check(summary["failed"].has("fake_a") and summary["failed"]["fake_a"].contains("1.0.0"), "the failure text names the older version: %s" % summary["failed"])


func test_download_failure_is_not_a_load_failure() -> void:
	_setup("fallback_download", [_local("fake_a", "1.0.0")])
	var source := _fake_source({ "1.0.0": "1.0.0", "1.1.0": "1.1.0" })
	var manager := _manager("project")
	await manager.refresh()
	source.versions.erase("1.1.0")
	source.releases.append({ "version": "1.1.0", "tag": "v1.1.0", "prerelease": false, "notes": "", "url": "", "download_url": "" })
	var result: Dictionary = await manager.install("fake_a")
	check(not result["ok"] and not result["load_failed"], "a failed download says nothing about the Godot version")


func test_prereleases_are_offered_only_when_asked() -> void:
	_setup("prereleases", [_local("fake_a", "1.0.0")])
	_fake_source({ "1.0.0": "1.0.0", "1.1.0-beta.1": "1.1.0" })
	var manager := _manager("project")
	await manager.refresh()
	check_eq(manager.get_state("fake_a").latest_version, "1.0.0", "stable by default")
	check_eq(await manager.update_registry_entry("fake_a", { "source": _local("fake_a", "1.0.0")["source"], "range": "*", "prereleases": true }), "", "opted in")
	check_eq(manager.get_state("fake_a").latest_version, "1.1.0-beta.1", "the pre-release is now the newest")
	check(Registry.load_file(_registry_path())["registry"].get_entry("fake_a").prereleases, "saved in the registry")
	var listed := manager.available_versions("fake_a")
	check(listed[0]["in_range"] and listed[0]["offered"], "listed as in range")
