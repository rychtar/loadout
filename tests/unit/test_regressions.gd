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


# --- registry -------------------------------------------------------------------------------

func test_registry_rejects_dot_dot_repo() -> void:
	var parsed := Registry.parse_entry({ "id": "x", "source": { "type": "github", "repo": "owner/.." } })
	check(not parsed["ok"], "owner/.. is not a valid repository")


func test_registry_trims_dot_git_suffix_without_url() -> void:
	var parsed := Registry.parse_entry({ "id": "x", "source": { "type": "github", "repo": "owner/name.git" } })
	check(parsed["ok"] and parsed["entry"].source["repo"] == "owner/name", "owner/name.git normalized, got %s" % [parsed["entry"].source if parsed["ok"] else parsed["error"]])




func test_registry_windows_reserved_folder() -> void:
	var parsed := Registry.parse_entry({ "id": "x", "folder": "con", "source": { "type": "github", "repo": "a/b" } })
	check(not parsed["ok"], "folder 'con' is reserved on Windows")


func test_registry_folder_trailing_dot() -> void:
	var parsed := Registry.parse_entry({ "id": "x", "folder": "foo.", "source": { "type": "github", "repo": "a/b" } })
	check(not parsed["ok"], "folder with a trailing dot is not portable (Windows strips it)")


func test_registry_reserved_folder_with_extension() -> void:
	check(not Registry.parse_entry({ "id": "x", "folder": "NUL.txt", "source": { "type": "github", "repo": "a/b" } })["ok"], "reserved device name with extension")
	check(Registry.parse_entry({ "id": "x", "folder": "console", "source": { "type": "github", "repo": "a/b" } })["ok"], "names that only start like one are fine")


# --- version --------------------------------------------------------------------------------

func test_version_overflowing_numbers() -> void:
	var v := LoadoutVersion.parse("1.99999999999999999999.0")
	check(v == null, "a number that would overflow an int is not a version")




func test_leading_zero_numeric_prerelease() -> void:
	var a := LoadoutVersion.parse("1.0.0-01")
	check(a == null, "semver forbids leading zeros in numeric prerelease identifiers")


# --- update checker -------------------------------------------------------------------------

func _checker(now: Callable, name: String) -> Checker:
	var c := Checker.new(temp_dir("probe_checker_" + name).path_join("loadout_cache.json"), now)
	c.load_cache()
	return c


func test_first_failure_is_retried_soon() -> void:
	var clock := { "now": 1_800_000_000 }
	var checker := _checker(func() -> int: return clock["now"], "firstfail")
	var source := FakeSource.new({ "1.0.0": FIXTURES.path_join("1.0.0") })
	source.remote = true
	source.fail_list = "Connection failed"
	await checker.load_releases(source)
	clock["now"] += 300
	var soon := await checker.load_releases(source)
	check(not soon["ok"] and source.list_calls == 1, "an offline editor does not ask again within minutes")
	clock["now"] += 700  # 16 minutes after the failure, network is back
	source.fail_list = ""
	var again := await checker.load_releases(source)
	check(again["ok"], "after the retry interval a failed first check (nothing cached) asks the source again (err=%s)" % again["error"])


func test_clock_in_the_past_does_not_freeze_updates() -> void:
	var clock := { "now": 1_800_000_000 }
	var checker := _checker(func() -> int: return clock["now"], "clock")
	var source := FakeSource.new({ "1.0.0": FIXTURES.path_join("1.0.0") })
	source.remote = true
	await checker.load_releases(source)
	clock["now"] -= 365 * DAY  # the clock was wrong when the cache was written
	check(checker.is_due(source.cache_key()), "a checked_at a year in the future counts as due")


func test_cache_with_wrong_types_does_not_crash() -> void:
	var root := temp_dir("probe_cachetypes")
	var path := root.path_join("loadout_cache.json")
	write_text(path, JSON.stringify({ "schema": 1, "sources": { "fake:fake_a": { "checked_at": 1, "releases": "oops" } } }))
	var checker := Checker.new(path)
	checker.load_cache()
	var source := FakeSource.new({ "1.0.0": FIXTURES.path_join("1.0.0") })
	source.remote = true
	var result: Dictionary = await checker.load_releases(source, true)
	check(result.get("ok", false), "hand-damaged cache entry is ignored")
	check_eq(source.list_calls, 1, "and the source is asked instead")


# --- github source --------------------------------------------------------------------------

const RELEASES_URL := "https://api.github.com/repos/owner/mono/releases?per_page=50"


func _gh_release(tag: String, extra: Dictionary = {}) -> Dictionary:
	var r := { "tag_name": tag, "draft": false, "prerelease": false, "body": "", "html_url": "", "zipball_url": "https://api.github.com/repos/owner/mono/zipball/%s" % tag, "assets": [] }
	r.merge(extra, true)
	return r


func test_github_prerelease_flag_is_not_offered_as_latest() -> void:
	var http := FakeHttp.new()
	var source := GithubSource.new("owner/mono", "mono", http)
	http.respond_json(RELEASES_URL, [_gh_release("v2.0.0", { "prerelease": true }), _gh_release("v1.0.0")])
	var listed := await source.list_releases()
	source.releases.assign(listed["releases"])
	var latest := await source.get_latest_version("*")
	check_eq(latest["version"], "1.0.0", "a release GitHub flags as pre-release (tag v2.0.0) is not the default latest")


func test_github_date_tag_is_not_a_version() -> void:
	var http := FakeHttp.new()
	var source := GithubSource.new("owner/mono", "mono", http)
	http.respond_json(RELEASES_URL, [_gh_release("nightly-20260105"), _gh_release("v1.4.0")])
	var listed := await source.list_releases()
	source.releases.assign(listed["releases"])
	var latest := await source.get_latest_version("*")
	check_eq(latest["version"], "1.4.0", "build/date tags (nightly-20260105 -> 20260105.0.0) do not outrank real versions")


func test_github_monorepo_entries_share_cache_but_pick_different_assets() -> void:
	var http := FakeHttp.new()
	http.respond_json(RELEASES_URL, [_gh_release("v1.0.0", { "assets": [
		{ "name": "alpha-1.0.0.zip", "browser_download_url": "https://dl/alpha.zip" },
		{ "name": "beta-1.0.0.zip", "browser_download_url": "https://dl/beta.zip" }] })])
	var a := GithubSource.new("owner/mono", "alpha", http)
	var b := GithubSource.new("owner/mono", "beta", http)
	check_eq(a.cache_key() == b.cache_key(), false, "two plugins of one repo with different folders need different cache keys (both are '%s')" % a.cache_key())


func test_github_release_without_any_package_url() -> void:
	var http := FakeHttp.new()
	var source := GithubSource.new("owner/mono", "mono", http)
	http.respond_json(RELEASES_URL, [_gh_release("v1.0.0", { "zipball_url": null })])
	var listed := await source.list_releases()
	source.releases.assign(listed["releases"])
	var dest := temp_dir("probe_nourl").path_join("d")
	var fetched := await source.fetch("1.0.0", dest)
	check(not fetched["ok"] and fetched["error"].contains("no downloadable package"), "no package url gives a clear message, got: %s" % fetched["error"])


# --- store source ---------------------------------------------------------------------------

func test_store_prerelease_flag_respected() -> void:
	var http := FakeHttp.new()
	var source := StoreSource.new("pub/slug", "slug", http, "4.7")
	http.respond_json("https://store.godotengine.org/api/v1/releases/pub/slug/?compatibility=4.7", [
		{ "id": 2, "version": "2.0.0", "stable": false }, { "id": 1, "version": "1.0.0", "stable": true }])
	var listed := await source.list_releases()
	source.releases.assign(listed["releases"])
	var latest := await source.get_latest_version("*")
	check_eq(latest["version"], "1.0.0", "an unstable store release (stable=false) is not the default latest")


# --- zip ------------------------------------------------------------------------------------





func test_zip_bomb_is_limited() -> void:
	var root := temp_dir("probe_zipbomb")
	var zip := root.path_join("a.zip")
	var packer := ZIPPacker.new()
	packer.open(zip)
	packer.start_file("p/plugin.cfg")
	packer.write_file("x".to_utf8_buffer())
	packer.close_file()
	var chunk := PackedByteArray()
	chunk.resize(64 * 1024 * 1024)
	for i in 9:  # 576 MB of zeros, a few hundred KB zipped
		packer.start_file("p/blob%d.bin" % i)
		packer.write_file(chunk)
		packer.close_file()
	packer.close()
	var result := Zip_.extract_plugin(zip, "p", root.path_join("out"))
	check(not result["ok"] and result["error"].contains("more than"), "an oversized package is refused: %s" % result["error"])
	Fs_.remove_dir(root)


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


func test_force_reinstall_same_version_keeps_earlier_backup() -> void:
	var env := _install_env("backup_overwrite")
	var installer: Installer = env["installer"]
	var entry: Registry.Entry = env["entry"]
	var source: FakeSource = env["source"]
	var first: Dictionary = await installer.install(entry, source, "1.0.0")
	var target: String = env["addons"].path_join("fake_a")
	write_text(target.path_join("my_edit_1.txt"), "edit one")
	var lock := Lockfile.new()
	lock.set_installed("fake_a", "1.0.0", first["hash"], "2026-10-01")
	var second: Dictionary = await installer.install(entry, source, "1.0.0", lock.get_entry("fake_a"), true)
	check(second["ok"], "force reinstall ok")
	var backup_one: String = second["backup_path"]
	check(FileAccess.file_exists(backup_one.path_join("my_edit_1.txt")), "first backup holds edit one")
	write_text(target.path_join("my_edit_2.txt"), "edit two")
	var third: Dictionary = await installer.install(entry, source, "1.0.0", lock.get_entry("fake_a"), true)
	check(third["ok"], "second force reinstall ok")
	check(FileAccess.file_exists(backup_one.path_join("my_edit_1.txt")), "the earlier backup (edit one) is not destroyed by the next overwrite of the same version")
	check(FileAccess.file_exists(String(third["backup_path"]).path_join("my_edit_2.txt")), "the newest backup holds edit two")
	check(third["backup_path"] != backup_one, "backups of one version get different folders")


func test_empty_leftover_folder_is_treated_as_missing() -> void:
	var env := _install_env("empty_folder")
	var installer: Installer = env["installer"]
	var entry: Registry.Entry = env["entry"]
	DirAccess.make_dir_recursive_absolute(env["addons"].path_join("fake_a"))
	var reason := installer.check_overwrite(entry, null)
	check_eq(reason, "", "an empty addons/fake_a (no files) needs no confirmation to install into")
	var result: Dictionary = await installer.install(entry, env["source"], "1.0.0")
	check(result["ok"] and result["from"] == "", "installs as a fresh install: %s" % result["error"])
	check(FileAccess.file_exists(env["addons"].path_join("fake_a/plugin.cfg")), "files are in place")




# --- round 2 --------------------------------------------------------------------------------



func test_os_junk_files_do_not_count_as_edits() -> void:
	var root := temp_dir("probe_junk")
	write_text(root.path_join("plugin.cfg"), "x")
	var before := Fs_.hash_dir(root)
	write_text(root.path_join("Thumbs.db"), "windows explorer")
	write_text(root.path_join("desktop.ini"), "windows explorer")
	check_eq(Fs_.hash_dir(root), before, "Thumbs.db / desktop.ini change the folder hash (false 'edited by hand' on Windows)")


func test_staging_is_cleaned_after_a_rolled_back_update() -> void:
	var env := _install_env("staging")
	var installer: Installer = env["installer"]
	var source: FakeSource = env["source"]
	source.versions["1.2.0"] = FIXTURES.path_join("1.2.0_broken")
	await installer.install(env["entry"], source, "1.0.0")
	(env["editor"] as FakeEditor).broken_versions.append("1.2.0")
	var result: Dictionary = await installer.install(env["entry"], source, "1.2.0", null, true)
	check(not result["ok"] and result["restored"], "rolled back")
	check(not DirAccess.dir_exists_absolute(env["root"].path_join("staging/fake_a")), "staging folder removed after rollback")


func test_self_update_validates_the_new_scripts_before_swapping() -> void:
	var env := _install_env("selfupdate")
	var installer: Installer = env["installer"]
	var source: FakeSource = env["source"]
	source.versions["1.2.0"] = FIXTURES.path_join("1.2.0_broken")
	await installer.install(env["entry"], source, "1.0.0")
	(env["editor"] as FakeEditor).broken_versions.append("1.2.0")
	var result: Dictionary = await installer.self_update(env["entry"], source, "1.2.0")
	check(not result["ok"], "self_update refuses a staged copy whose scripts do not compile (otherwise Loadout is broken after the restart and cannot repair itself)")
	check_eq(installer.installed_version(env["entry"]), "1.0.0", "the running files are untouched")


func test_project_setup_crlf_and_no_trailing_newline() -> void:
	var setup := load("res://tools/loadout_project_setup.gd")
	var text := "config_version=5\r\n\r\n[editor_plugins]\r\n\r\nenabled=PackedStringArray(\"res://addons/a/plugin.cfg\")"
	var out: Dictionary = setup.with_plugin_enabled(text, "res://addons/loadout/plugin.cfg")
	check(out["ok"], "ok")
	check(out["text"].contains("res://addons/a/plugin.cfg") and out["text"].contains("res://addons/loadout/plugin.cfg"), "both plugins listed: %s" % out["text"])
	var cfg := ConfigFile.new()
	check_eq(cfg.parse(out["text"]), OK, "result still parses as a Godot config")


func test_project_setup_section_with_other_keys_only() -> void:
	var setup := load("res://tools/loadout_project_setup.gd")
	var text := "config_version=5\n\n[editor_plugins]\n\nfoo=1\n\n[rendering]\n\nx=1\n"
	var out: Dictionary = setup.with_plugin_enabled(text, "res://addons/loadout/plugin.cfg")
	var cfg := ConfigFile.new()
	check_eq(cfg.parse(out["text"]), OK, "parses")
	check(cfg.get_value("editor_plugins", "enabled", PackedStringArray()).has("res://addons/loadout/plugin.cfg"), "enabled added in the right section")
	check_eq(cfg.get_value("editor_plugins", "foo"), 1, "other key kept")
	check_eq(cfg.get_value("rendering", "x"), 1, "other section kept")


func test_manager_does_not_announce_addon_installed_while_busy() -> void:
	var m_script := load("res://addons/loadout/core/manager.gd")
	var root := temp_dir("probe_busy_addon")
	var addons := root.path_join("addons")
	DirAccess.make_dir_recursive_absolute(addons)
	var installer := Installer.new(FakeEditor.new(addons), addons, root.path_join("b"), root.path_join("s"))
	Registry.new().save_file(root.path_join("reg.json"))
	var manager = m_script.new(installer, root.path_join("reg.json"), root.path_join("lock.json"))
	await manager.refresh()
	manager.busy = true
	DirAccess.make_dir_recursive_absolute(addons.path_join("hand_installed"))
	write_text(addons.path_join("hand_installed/plugin.cfg"), "[plugin]\nname=\"H\"\nscript=\"p.gd\"\nversion=\"1.0.0\"\n")
	check_eq(manager.detect_new_addons().size(), 0, "not announced while busy")
	manager.busy = false
	var later: Array = manager.detect_new_addons()
	check_eq(later.size(), 1, "announced once the action is over (the plugin was added by the user, not by Loadout)")


func test_old_backups_are_pruned() -> void:
	var env := _install_env("prune")
	var installer: Installer = env["installer"]
	var entry: Registry.Entry = env["entry"]
	var source: FakeSource = env["source"]
	var first: Dictionary = await installer.install(entry, source, "1.0.0")
	var lock := Lockfile.new()
	lock.set_installed("fake_a", "1.0.0", first["hash"], "2026-10-01")
	var last := ""
	for i in Installer.MAX_BACKUPS + 4:
		var again: Dictionary = await installer.install(entry, source, "1.0.0", lock.get_entry("fake_a"), true)
		last = again["backup_path"]
	var kept := DirAccess.get_directories_at(env["root"].path_join("backup/fake_a"))
	check_eq(kept.size(), Installer.MAX_BACKUPS, "only the newest backups are kept")
	check(DirAccess.dir_exists_absolute(last), "the backup just made survives")


func test_zip_prefers_the_shallowest_copy_of_the_plugin() -> void:
	var root := temp_dir("zip_demo_copy")
	var zip := root.path_join("a.zip")
	# A demo project inside the repo ships its own copy of the plugin; here it is listed first.
	make_raw_zip(zip, {
		"repo-1/Demo/addons/foo/plugin.cfg": "demo copy", "repo-1/Demo/addons/foo/a.gd": "demo",
		"repo-1/addons/foo/plugin.cfg": "real", "repo-1/addons/foo/a.gd": "real" })
	var result := Zip_.extract_plugin(zip, "foo", root.path_join("out"))
	check(result["ok"], "extracts: %s" % result["error"])
	check_eq(FileAccess.get_file_as_string(root.path_join("out/plugin.cfg")), "real", "the plugin at addons/foo, not the demo's copy")