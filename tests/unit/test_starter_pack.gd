extends "res://tests/test_case.gd"
## The starter pack: reading the file, which starters are offered, adding them to the registry.

const Manager := preload("res://addons/loadout/core/manager.gd")
const Installer := preload("res://addons/loadout/core/installer.gd")
const Registry := preload("res://addons/loadout/core/registry.gd")
const FakeEditor := preload("res://tests/fake_editor.gd")
const FakeSource := preload("res://tests/fake_source.gd")

const FIXTURES := "res://tests/fixtures/addons/fake_a"

var root: String
var fake_sources: Dictionary[String, LoadoutSource] = {}


func _starter(id: String, asset: String = "") -> Dictionary:
	return {
		"id": id,
		"folder": id,
		"source": { "type": "store", "asset": asset if asset != "" else "pub/%s" % id },
		"title": id.capitalize(),
		"description": "About %s." % id,
	}


func _write_pack(name: String, starters: Array) -> String:
	var path := root.path_join(name + ".json")
	write_text(path, JSON.stringify({ "schema": 1, "starters": starters }))
	return path


## A manager whose sources are the fakes in fake_sources (by id), nothing installed yet.
func _manager(starters: Array, registry_plugins: Array = []) -> Manager:
	root = temp_dir("starter_pack")
	DirAccess.make_dir_recursive_absolute(root.path_join("addons"))
	var registry := Registry.from_dict({ "schema": 1, "plugins": registry_plugins })["registry"] as Registry
	check_eq(registry.save_file(root.path_join("registry.json")), OK, "registry saved")
	var installer := Installer.new(FakeEditor.new(root.path_join("addons")), root.path_join("addons"), root.path_join("backup"), root.path_join("staging"))
	var factory := func(entry: LoadoutRegistry.Entry) -> LoadoutSource:
		return fake_sources.get(entry.id, LoadoutSource.create(entry))
	var manager := Manager.new(installer, root.path_join("registry.json"), root.path_join("loadout.lock.json"), factory)
	manager.starter_pack_path = _write_pack("pack", starters)
	return manager


func _offering(id: String) -> FakeSource:
	var source := FakeSource.new({ "1.0.0": FIXTURES.path_join("1.0.0") })
	fake_sources[id] = source
	return source


func _registry_ids(manager: Manager) -> PackedStringArray:
	var ids: PackedStringArray = []
	for entry in Registry.load_file(manager.registry_path)["registry"].entries:
		ids.append(entry.id)
	ids.sort()
	return ids


func _offer_ids(offers: Dictionary) -> PackedStringArray:
	var ids: PackedStringArray = []
	for item: Dictionary in offers["items"]:
		ids.append(item["id"])
	return ids


func test_pack_keeps_title_and_description_out_of_the_registry_entry() -> void:
	root = temp_dir("starter_pack")
	var result := LoadoutStarterPack.load_file(_write_pack("pack", [_starter("one")]))
	check(result["ok"], "the pack loads: %s" % result["error"])
	var item: Dictionary = result["items"][0]
	check_eq(item["title"], "One", "title")
	check_eq(item["description"], "About one.", "description")
	check(not item["entry"].has("title") and not item["entry"].has("description"), "the entry has no starter fields")
	check_eq(item["entry"]["source"], { "type": "store", "asset": "pub/one" }, "source")
	check(LoadoutRegistry.parse_entry(item["entry"])["ok"], "the entry is a valid registry entry")


func test_pack_skips_invalid_and_duplicate_starters() -> void:
	root = temp_dir("starter_pack")
	var bad_source := _starter("bad")
	bad_source["source"] = { "type": "store", "asset": "not a slug" }
	var result := LoadoutStarterPack.load_file(_write_pack("pack", [_starter("one"), bad_source, _starter("one", "other/one"), "text"]))
	check(result["ok"], "the pack still loads")
	check_eq(result["items"].size(), 1, "only the valid starter stays")
	check_eq(result["warnings"].size(), 3, "each skipped starter is reported")


func test_pack_problems_are_reported() -> void:
	root = temp_dir("starter_pack")
	check(not LoadoutStarterPack.load_file(root.path_join("none.json"))["ok"], "a missing file is an error")
	write_text(root.path_join("broken.json"), "{ not json")
	check(not LoadoutStarterPack.load_file(root.path_join("broken.json"))["ok"], "damaged JSON is an error")
	write_text(root.path_join("schema.json"), JSON.stringify({ "schema": 99, "starters": [] }))
	check(not LoadoutStarterPack.load_file(root.path_join("schema.json"))["ok"], "an unknown schema is not read")


func test_bundled_pack_is_valid() -> void:
	var result := LoadoutStarterPack.load_file()
	check(result["ok"], "the bundled pack loads: %s" % result["error"])
	check(result["warnings"].is_empty(), "no starter is skipped: %s" % ", ".join(result["warnings"]))
	check(not result["items"].is_empty(), "it has starters")
	for item: Dictionary in result["items"]:
		check_eq(item["entry"]["source"]["type"], "store", "%s comes from the Asset Store" % item["id"])
		check(item["description"] != "", "%s has a description" % item["id"])


func test_offers_leave_out_what_the_registry_has() -> void:
	var manager := _manager([_starter("one"), _starter("two"), _starter("three"), _starter("four")], [
		{ "id": "one", "folder": "one", "source": { "type": "store", "asset": "pub/one" } },
		# Same asset under another id and folder.
		{ "id": "mine", "folder": "mine", "source": { "type": "store", "asset": "pub/two" } },
		# Same folder, other asset.
		{ "id": "x", "folder": "three", "source": { "type": "store", "asset": "pub/x" } },
	])
	for id in ["one", "two", "three", "four"]:
		_offering(id)
	var offers: Dictionary = manager.starter_offers()
	check(offers["ok"], "offers: %s" % offers["error"])
	check_eq(_offer_ids(offers), PackedStringArray(["four"]), "only the starter the registry does not cover")


func test_offers_do_not_ask_any_source() -> void:
	var manager := _manager([_starter("one"), _starter("two")])
	var one := _offering("one")
	var two := _offering("two")
	var offers: Dictionary = manager.starter_offers()
	check_eq(_offer_ids(offers), PackedStringArray(["one", "two"]), "both are listed")
	check_eq(one.list_calls + two.list_calls, 0, "building the list costs no request, the details are fetched on click")


func test_offers_report_a_missing_pack() -> void:
	var manager := _manager([])
	manager.starter_pack_path = root.path_join("none.json")
	var offers: Dictionary = manager.starter_offers()
	check(not offers["ok"], "no pack, no offers")
	check(offers["error"] != "", "with a reason")


func test_adding_starters_fills_the_registry_and_leaves_them_missing() -> void:
	var manager := _manager([_starter("one"), _starter("two"), _starter("three")])
	for id in ["one", "two", "three"]:
		_offering(id)
	await manager.refresh()
	var summary: Dictionary = await manager.add_starters(PackedStringArray(["one", "three"]))
	check(summary["ok"], "added: %s" % summary["error"])
	check_eq(summary["added"], PackedStringArray(["one", "three"]), "both are added")
	check_eq(_registry_ids(manager), PackedStringArray(["one", "three"]), "they are in the registry file")
	check_eq(manager.get_state("one").status, Manager.Status.MISSING, "not installed yet, the user installs next")
	check_eq(manager.missing_ids(), PackedStringArray(["one", "three"]), "the install dialog offers them")
	check(not DirAccess.dir_exists_absolute(root.path_join("addons/one")), "nothing was copied")


func test_adding_a_starter_twice_or_an_unknown_one_is_skipped() -> void:
	var manager := _manager([_starter("one")])
	_offering("one")
	await manager.refresh()
	await manager.add_starters(PackedStringArray(["one"]))
	var summary: Dictionary = await manager.add_starters(PackedStringArray(["one", "ghost"]))
	check(summary["ok"], "the call itself works")
	check(summary["added"].is_empty(), "nothing new")
	check(summary["skipped"].has("one") and summary["skipped"].has("ghost"), "both are reported: %s" % var_to_str(summary["skipped"]))
	check_eq(_registry_ids(manager), PackedStringArray(["one"]), "the registry has it once")


func test_a_starter_already_in_the_project_is_taken_over() -> void:
	var manager := _manager([_starter("fake_a")])
	_offering("fake_a")
	check_eq(Fs.copy_dir(FIXTURES.path_join("1.0.0"), root.path_join("addons/fake_a")), OK, "the plugin is in the project")
	await manager.refresh()
	var summary: Dictionary = await manager.add_starters(PackedStringArray(["fake_a"]))
	check(summary["ok"], "added: %s" % summary["error"])
	var state := manager.get_state("fake_a")
	check(state.lock_entry != null, "the current files are recorded in the lock")
	check_eq(state.installed_version, "1.0.0", "the installed version is kept")
	check(manager.missing_ids().is_empty(), "nothing is offered for install")


func test_adding_starters_does_not_touch_a_registry_that_cannot_be_read() -> void:
	var manager := _manager([_starter("one")])
	_offering("one")
	write_text(manager.registry_path, "{ not json")
	var summary: Dictionary = await manager.add_starters(PackedStringArray(["one"]))
	check(not summary["ok"], "refused")
	check_eq(FileAccess.get_file_as_string(manager.registry_path), "{ not json", "the damaged file is not overwritten")



func test_details_of_a_starter_name_what_it_is_for_and_its_releases() -> void:
	var manager := _manager([_starter("one")])
	var source := _offering("one")
	source.notes = { "1.0.0": "First release." }
	manager.starter_offers()
	check_eq(source.list_calls, 0, "nothing was asked yet")
	var details: Dictionary = await manager.plugin_details("one")
	check(details["ok"], "details: %s" % details["error"])
	check_eq(details["title"], "One", "title from the pack")
	check_eq(details["summary"], "About one.", "the pack's description when the source has none")
	check_eq(details["selected"], "1.0.0", "the version that would be installed")
	check_eq(details["versions"].size(), 1, "one release")
	check_eq(details["versions"][0]["notes"], "First release.", "release notes of that version")
	check_eq(source.list_calls, 1, "the source was asked when the details opened")


func test_details_of_a_registry_plugin_use_its_source() -> void:
	var manager := _manager([], [{ "id": "fake_a", "folder": "fake_a", "source": { "type": "store", "asset": "pub/fake_a" } }])
	var source := _offering("fake_a")
	source.notes = { "1.0.0": "Registry notes." }
	await manager.refresh()
	var details: Dictionary = await manager.plugin_details("fake_a")
	check(details["ok"], "details: %s" % details["error"])
	check_eq(details["selected"], "1.0.0", "target version")
	check_eq(details["versions"][0]["notes"], "Registry notes.", "notes")


func test_details_of_an_unknown_plugin_are_an_error() -> void:
	var manager := _manager([])
	await manager.refresh()
	var details: Dictionary = await manager.plugin_details("ghost")
	check(not details["ok"] and details["error"] != "", "nothing is known about it")


func test_details_of_a_starter_without_a_release_say_so() -> void:
	var manager := _manager([_starter("old")])
	fake_sources["old"] = FakeSource.new({})
	manager.starter_offers()
	var details: Dictionary = await manager.plugin_details("old")
	check(details["ok"], "details still open")
	check(details["warning"] != "", "with a warning that no release fits this Godot")
	check_eq(details["selected"], "", "nothing to install")


func test_adding_skips_a_starter_without_a_release_for_this_godot() -> void:
	var manager := _manager([_starter("old"), _starter("current")])
	fake_sources["old"] = FakeSource.new({})
	_offering("current")
	await manager.refresh()
	var summary: Dictionary = await manager.add_starters(PackedStringArray(["old", "current"]))
	check(summary["ok"], "added: %s" % summary["error"])
	check_eq(summary["added"], PackedStringArray(["current"]), "only the installable one")
	check(summary["skipped"].has("old"), "the other one is reported")
	check_eq(_registry_ids(manager), PackedStringArray(["current"]), "and stays out of the registry")


func test_adding_a_starter_offline_still_works() -> void:
	var manager := _manager([_starter("one")])
	var source := _offering("one")
	source.fail_list = "offline"
	await manager.refresh()
	var summary: Dictionary = await manager.add_starters(PackedStringArray(["one"]))
	check_eq(summary["added"], PackedStringArray(["one"]), "offline is no reason to refuse, the install reports it")


func test_pack_ids_list_every_starter_even_those_in_the_registry() -> void:
	var manager := _manager([_starter("one"), _starter("two")], [
		{ "id": "one", "folder": "one", "source": { "type": "store", "asset": "pub/one" } },
	])
	check_eq(manager.starter_pack_ids(), PackedStringArray(["one", "two"]), "the whole pack, so a later addition can be told from what was offered")
	manager.starter_pack_path = root.path_join("none.json")
	check(manager.starter_pack_ids().is_empty(), "an unreadable pack lists nothing")
