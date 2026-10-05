extends "res://tests/test_case.gd"
## Regression tests for gaps found by exploratory probing (data loss, cache, backups, tags, limits).

const Fs_ := preload("res://addons/loadout/util/fs.gd")
const JsonStore := preload("res://addons/loadout/util/json_store.gd")
const Checker := preload("res://addons/loadout/core/update_checker.gd")
const GithubSource := preload("res://addons/loadout/sources/github_source.gd")
const StoreSource := preload("res://addons/loadout/sources/store_source.gd")
const FakeHttp := preload("res://tests/fake_http.gd")
const FakeSource := preload("res://tests/fake_source.gd")
const FakeEditor := preload("res://tests/fake_editor.gd")
const Installer := preload("res://addons/loadout/core/installer.gd")
const Registry := preload("res://addons/loadout/core/registry.gd")
const Lockfile := preload("res://addons/loadout/core/lockfile.gd")
const Zip_ := preload("res://addons/loadout/util/zip.gd")

const FIXTURES := "res://tests/fixtures/addons/fake_a"
const DAY := 86400


# --- fs -------------------------------------------------------------------------------------

func test_remove_dir_does_not_follow_symlinks() -> void:
	var root := temp_dir("probe_symlink")
	var outside := root.path_join("outside")
	DirAccess.make_dir_recursive_absolute(outside)
	write_text(outside.path_join("precious.txt"), "keep me")
	var plugin := root.path_join("plugin")
	DirAccess.make_dir_recursive_absolute(plugin)
	write_text(plugin.path_join("plugin.cfg"), "x")
	var rc := OS.execute("ln", ["-s", ProjectSettings.globalize_path(outside), ProjectSettings.globalize_path(plugin.path_join("link"))])
	if rc != 0:
		return  # no symlinks here (Windows without ln)
	Fs_.remove_dir(plugin)
	check(not DirAccess.dir_exists_absolute(plugin), "plugin folder removed")
	check(FileAccess.file_exists(outside.path_join("precious.txt")), "file behind a symlink survived remove_dir")


func test_remove_dir_on_a_symlinked_plugin_folder_keeps_the_target() -> void:
	var root := temp_dir("probe_symlink_top")
	var source := root.path_join("dev_repo")
	DirAccess.make_dir_recursive_absolute(source)
	write_text(source.path_join("plugin.cfg"), "x")
	var link := root.path_join("addons_fake")
	if OS.execute("ln", ["-s", ProjectSettings.globalize_path(source), ProjectSettings.globalize_path(link)]) != 0:
		return
	Fs_.remove_dir(link)
	check(FileAccess.file_exists(source.path_join("plugin.cfg")), "the folder a symlinked addon points to is untouched")
	check(not DirAccess.dir_exists_absolute(link), "the link itself is gone")


func test_copy_dir_skips_symlinked_folders() -> void:
	var root := temp_dir("probe_symloop")
	var a := root.path_join("a")
	DirAccess.make_dir_recursive_absolute(a)
	write_text(a.path_join("f.txt"), "x")
	if OS.execute("ln", ["-s", ProjectSettings.globalize_path(a), ProjectSettings.globalize_path(a.path_join("self"))]) != 0:
		return
	check_eq(Fs_.copy_dir(a, root.path_join("b")), OK, "copy succeeds")
	check_eq(Fs_.list_files(root.path_join("b")), PackedStringArray(["f.txt"]), "symlinked sub folders are not followed")
	check_eq(Fs_.list_files(a), PackedStringArray(["f.txt"]), "nor listed")


# --- json store: backup spam ----------------------------------------------------------------

func test_corrupt_file_read_repeatedly_makes_one_backup() -> void:
	var root := temp_dir("probe_bak")
	var path := root.path_join("loadout.lock.json")
	write_text(path, "{ not json")
	for i in 5:
		JsonStore.read(path, 1)
	var backups := 0
	for f in DirAccess.get_files_at(root):
		if f.ends_with(".bak"):
			backups += 1
	check_eq(backups, 1, "number of .bak files after 5 reads of the same corrupt file")


func test_empty_lock_file_is_not_a_permanent_block() -> void:
	var root := temp_dir("probe_empty")
	var path := root.path_join("loadout.lock.json")
	write_text(path, "")
	var lock := Lockfile.load_file(path)
	# A 0-byte file (e.g. an interrupted write or `touch`) is arguably just "empty".
	check(lock["ok"], "0-byte lock treated as empty, got error: %s" % lock["error"])


# --- update checker -------------------------------------------------------------------------

func _checker(now: Callable, name: String) -> Checker:
	var c := Checker.new(temp_dir("probe_checker_" + name).path_join("loadout_cache.json"), now)
	c.load_cache()
	return c


# --- github source --------------------------------------------------------------------------

const RELEASES_URL := "https://api.github.com/repos/owner/mono/releases?per_page=50"


func _gh_release(tag: String, extra: Dictionary = {}) -> Dictionary:
	var r := { "tag_name": tag, "draft": false, "prerelease": false, "body": "", "html_url": "", "zipball_url": "https://api.github.com/repos/owner/mono/zipball/%s" % tag, "assets": [] }
	r.merge(extra, true)
	return r


# --- zip ------------------------------------------------------------------------------------





# --- installer: backups ---------------------------------------------------------------------

func _install_env(name: String) -> Dictionary:
	var root := temp_dir("probe_inst_" + name)
	var addons := root.path_join("addons")
	DirAccess.make_dir_recursive_absolute(addons)
	var editor := FakeEditor.new(addons)
	var installer := Installer.new(editor, addons, root.path_join("backup"), root.path_join("staging"))
	var source := FakeSource.new({ "1.0.0": FIXTURES.path_join("1.0.0"), "1.1.0": FIXTURES.path_join("1.1.0") })
	var entry: Registry.Entry = Registry.parse_entry({ "id": "fake_a", "folder": "fake_a", "source": { "type": "local", "path": "/x" } })["entry"]
	return { "root": root, "addons": addons, "installer": installer, "source": source, "entry": entry, "editor": editor }




# --- round 2 --------------------------------------------------------------------------------



func test_os_junk_files_do_not_count_as_edits() -> void:
	var root := temp_dir("probe_junk")
	write_text(root.path_join("plugin.cfg"), "x")
	var before := Fs_.hash_dir(root)
	write_text(root.path_join("Thumbs.db"), "windows explorer")
	write_text(root.path_join("desktop.ini"), "windows explorer")
	check_eq(Fs_.hash_dir(root), before, "Thumbs.db / desktop.ini change the folder hash (false 'edited by hand' on Windows)")