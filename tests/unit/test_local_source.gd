extends "res://tests/test_case.gd"

const LocalSource := preload("res://addons/loadout/sources/local_source.gd")
const FIXTURE := "res://tests/fixtures/addons/fake_a/1.1.0"


func _source(path: String) -> LocalSource:
	return LocalSource.new(ProjectSettings.globalize_path(path))


func test_latest_version_reads_plugin_cfg() -> void:
	var result: Dictionary = await _source(FIXTURE).get_latest_version("^1.0.0")
	check(result["ok"], "ok: %s" % result["error"])
	check_eq(result["version"], "1.1.0", "version")


func test_latest_version_outside_range() -> void:
	var result: Dictionary = await _source(FIXTURE).get_latest_version("^2.0.0")
	check(not result["ok"], "1.1.0 is not ^2.0.0")
	check(str(result["error"]).contains("1.1.0"), "error names the version")


func test_missing_plugin_cfg() -> void:
	var dir := temp_dir("local_empty")
	var result: Dictionary = await _source(dir).get_latest_version("*")
	check(not result["ok"], "no plugin.cfg")
	var missing: Dictionary = await _source(dir.path_join("nope")).get_latest_version("*")
	check(not missing["ok"], "missing folder")


func test_fetch_copies_plugin() -> void:
	var dest := temp_dir("local_fetch").path_join("staged")
	var result: Dictionary = await _source(FIXTURE).fetch("1.1.0", dest)
	check(result["ok"], "fetched: %s" % result["error"])
	check_eq(result["path"], dest, "path")
	check_eq(Fs.hash_dir(dest), Fs.hash_dir(FIXTURE), "same files")


func test_fetch_skips_git_folder() -> void:
	var plugin := temp_dir("local_git")
	Fs.copy_dir(FIXTURE, plugin)
	DirAccess.make_dir_recursive_absolute(plugin.path_join(".git"))
	write_text(plugin.path_join(".git/HEAD"), "ref")
	var dest := temp_dir("local_git_dest").path_join("staged")
	var result: Dictionary = await _source(plugin).fetch("1.1.0", dest)
	check(result["ok"], "fetched")
	check(not DirAccess.dir_exists_absolute(dest.path_join(".git")), ".git not copied")


func test_fetch_other_version_fails() -> void:
	var dest := temp_dir("local_wrong").path_join("staged")
	var result: Dictionary = await _source(FIXTURE).fetch("1.0.0", dest)
	check(not result["ok"], "local source only has its current version")
	check(not DirAccess.dir_exists_absolute(dest), "nothing copied")


func test_trim_notes_cuts_long_text_and_accepts_null() -> void:
	check_eq(LocalSource.trim_notes(null), "", "null is empty")
	check_eq(LocalSource.trim_notes("short"), "short", "short text is kept")
	check_eq(LocalSource.trim_notes("abcdef", 3), "abc…", "long text is cut")



func test_info_reads_description_and_author_from_plugin_cfg() -> void:
	var info: Dictionary = await _source(FIXTURE).get_info()
	check(info["ok"], "ok")
	check_eq(info["summary"], "Test plugin for Loadout (fixture).", "description")
	check_eq(info["author"], "Loadout", "author")
