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
	var installer := Installer.new(FakeEditor.new(project_addons), project_addons, root.path_join(project + "_backup"), root.path_join(project + "_staging"))
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
