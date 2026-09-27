extends "res://tests/test_case.gd"

const Setup := preload("res://tools/loadout_project_setup.gd")

const PLUGIN := "res://addons/loadout/plugin.cfg"
const NEW_PROJECT := """; Engine configuration file.
; It's best edited using the editor UI and not directly,
; since the parameters that go here are not all obvious.
;
; Format:
;   [section] ; section goes between []
;   param=value ; assign values to parameters

config_version=5

[application]

config/name="Nova hra"
config/features=PackedStringArray("4.5", "Forward Plus")
config/icon="res://icon.svg"
"""


func _enabled(text: String) -> String:
	var result := Setup.with_plugin_enabled(text, PLUGIN)
	check(result["ok"], "ok: %s" % result["error"])
	return result["text"]


func _project(name: String, text: String = NEW_PROJECT) -> String:
	var dir := temp_dir("setup_" + name)
	write_text(dir.path_join("project.godot"), text)
	return dir


func _fake_gam(name: String, version: String) -> String:
	var dir := temp_dir("setup_gam_" + name).path_join("loadout")
	DirAccess.make_dir_recursive_absolute(dir)
	write_text(dir.path_join("plugin.cfg"), "[plugin]\n\nname=\"Loadout\"\nversion=\"%s\"\nscript=\"plugin.gd\"\n" % version)
	write_text(dir.path_join("plugin.gd"), "@tool\nextends EditorPlugin\n")
	return dir


func test_enable_adds_section_and_keeps_the_rest() -> void:
	var text := _enabled(NEW_PROJECT)
	check(text.begins_with(NEW_PROJECT.strip_edges(false, true)), "original content untouched")
	check(text.ends_with("\n[editor_plugins]\n\nenabled=PackedStringArray(\"%s\")\n" % PLUGIN), "section appended")


func test_enable_appends_to_existing_list_sorted() -> void:
	var text := "config_version=5\n\n[editor_plugins]\n\nenabled=PackedStringArray(\"res://addons/zzz/plugin.cfg\", \"res://addons/aaa/plugin.cfg\")\n\n[rendering]\n\nx=1\n"
	var result := _enabled(text)
	check(result.contains("enabled=PackedStringArray(\"res://addons/aaa/plugin.cfg\", \"%s\", \"res://addons/zzz/plugin.cfg\")" % PLUGIN), "added and sorted: %s" % result)
	check(result.ends_with("[rendering]\n\nx=1\n"), "next section untouched")


func test_enable_is_idempotent() -> void:
	var once := _enabled(NEW_PROJECT)
	check_eq(_enabled(once), once, "second run changes nothing")


func test_enable_inserts_line_into_section_without_list() -> void:
	var text := "config_version=5\n\n[editor_plugins]\n\nother=true\n"
	var result := _enabled(text)
	check_eq(result, "config_version=5\n\n[editor_plugins]\n\nenabled=PackedStringArray(\"%s\")\nother=true\n" % PLUGIN, "inserted")


func test_enable_rejects_unreadable_list() -> void:
	var result := Setup.with_plugin_enabled("[editor_plugins]\n\nenabled=garbage(\n", PLUGIN)
	check(not result["ok"], "malformed value refused")


func test_install_into_new_project() -> void:
	var project := _project("new")
	var result := Setup.install(_fake_gam("new", "0.1.0"), project)
	check(result["ok"], "ok: %s" % result["error"])
	check_eq(result["action"], Setup.ACTION_INSTALLED, "installed")
	check(FileAccess.file_exists(project.path_join("addons/loadout/plugin.gd")), "files copied")
	check(FileAccess.get_file_as_string(project.path_join("project.godot")).contains(PLUGIN), "enabled")


func test_install_twice_is_unchanged() -> void:
	var project := _project("twice")
	var gam := _fake_gam("twice", "0.1.0")
	Setup.install(gam, project)
	var before := FileAccess.get_file_as_string(project.path_join("project.godot"))
	var result := Setup.install(gam, project)
	check(result["ok"], "ok")
	check_eq(result["action"], Setup.ACTION_UNCHANGED, "unchanged")
	check_eq(FileAccess.get_file_as_string(project.path_join("project.godot")), before, "project.godot not rewritten")


func test_unchanged_still_enables_a_disabled_gam() -> void:
	var project := _project("reenable")
	var gam := _fake_gam("reenable", "0.1.0")
	Setup.install(gam, project)
	write_text(project.path_join("project.godot"), NEW_PROJECT)
	var result := Setup.install(gam, project)
	check_eq(result["action"], Setup.ACTION_UNCHANGED, "files unchanged")
	check(FileAccess.get_file_as_string(project.path_join("project.godot")).contains(PLUGIN), "enabled again")


func test_other_version_needs_force() -> void:
	var project := _project("force")
	Setup.install(_fake_gam("force_old", "0.1.0"), project)
	var newer := _fake_gam("force_new", "0.2.0")
	var refused := Setup.install(newer, project)
	check(not refused["ok"], "refused without force")
	check(str(refused["error"]).contains("0.1.0") and str(refused["error"]).contains("--force"), "explains: %s" % refused["error"])
	check_eq(_installed_version(project), "0.1.0", "untouched")
	var forced := Setup.install(newer, project, true)
	check(forced["ok"], "ok with force")
	check_eq([forced["action"], forced["previous"], forced["version"]], [Setup.ACTION_UPDATED, "0.1.0", "0.2.0"], "updated")
	check_eq(_installed_version(project), "0.2.0", "new version")


func test_force_removes_files_of_old_version() -> void:
	var project := _project("stale")
	var old := _fake_gam("stale_old", "0.1.0")
	write_text(old.path_join("old_only.gd"), "# removed in 0.2.0")
	Setup.install(old, project)
	Setup.install(_fake_gam("stale_new", "0.2.0"), project, true)
	check(not FileAccess.file_exists(project.path_join("addons/loadout/old_only.gd")), "stale file removed")


func test_not_a_godot4_project() -> void:
	var gam := _fake_gam("invalid", "0.1.0")
	var empty := temp_dir("setup_no_project")
	check(not Setup.install(gam, empty)["ok"], "no project.godot")
	var godot3 := _project("godot3", "config_version=4\n\n[application]\n")
	check(not Setup.install(gam, godot3)["ok"], "Godot 3 project refused")
	check(not DirAccess.dir_exists_absolute(godot3.path_join("addons")), "nothing copied")


func test_refuses_to_install_into_itself() -> void:
	var project := _project("self")
	Setup.install(_fake_gam("self", "0.1.0"), project)
	var result := Setup.install(project.path_join("addons/loadout"), project, true)
	check(not result["ok"], "source is the target")


func _installed_version(project: String) -> String:
	var cfg := ConfigFile.new()
	cfg.load(project.path_join("addons/loadout/plugin.cfg"))
	return str(cfg.get_value("plugin", "version", ""))
