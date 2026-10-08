extends "res://tests/test_case.gd"

const Zip := preload("res://addons/loadout/util/zip.gd")
const FIXTURE := "res://tests/fixtures/addons/fake_a/1.1.0"


func _extract(name: String, prefix: String, folder: String = "fake_a") -> Dictionary:
	var dir := temp_dir("zip_" + name)
	var zip_path := dir.path_join("package.zip")
	make_zip(FIXTURE, zip_path, prefix)
	var dest := dir.path_join("out")
	var result := Zip.extract_plugin(zip_path, folder, dest)
	result["dest"] = dest
	return result


func test_release_asset_layout() -> void:
	var result := _extract("asset", "addons/fake_a/")
	check(result["ok"], "ok: %s" % result["error"])
	check_eq(Fs.hash_dir(result["dest"]), Fs.hash_dir(FIXTURE), "plugin folder content only")


func test_github_zipball_layout() -> void:
	var result := _extract("zipball", "owner-fake-a-1a2b3c4/addons/fake_a/")
	check(result["ok"], "ok: %s" % result["error"])
	check_eq(Fs.hash_dir(result["dest"]), Fs.hash_dir(FIXTURE), "nested repository folder skipped")


func test_plugin_folder_at_root() -> void:
	var result := _extract("root_folder", "fake_a/")
	check(result["ok"], "zip of the plugin folder itself")
	check_eq(Fs.hash_dir(result["dest"]), Fs.hash_dir(FIXTURE), "content")


func test_plugin_files_at_root() -> void:
	var result := _extract("root_files", "")
	check(result["ok"], "plugin.cfg directly in the zip root")


func test_folder_name_differs_but_single_plugin() -> void:
	var result := _extract("renamed", "addons/other_name/", "fake_a")
	check(result["ok"], "only one plugin in the package")
	check_eq(result["source_folder"], "other_name", "package folder reported for a warning")
	check_eq(_extract("same_name", "addons/fake_a/")["source_folder"], "fake_a", "same name")


func test_picks_plugin_by_folder_among_several() -> void:
	var dir := temp_dir("zip_several")
	var zip_path := dir.path_join("package.zip")
	var packer := ZIPPacker.new()
	packer.open(zip_path)
	for prefix: String in ["repo/addons/fake_a/", "repo/addons/helper/"]:
		packer.start_file(prefix + "plugin.cfg")
		packer.write_file(("[plugin]\nname=\"%s\"\n" % prefix).to_utf8_buffer())
		packer.close_file()
	packer.close()
	var result := Zip.extract_plugin(zip_path, "fake_a", dir.path_join("out"))
	check(result["ok"], "picked by folder name")
	check(FileAccess.get_file_as_string(dir.path_join("out/plugin.cfg")).contains("addons/fake_a/"), "right plugin")
	var other := Zip.extract_plugin(zip_path, "unknown", dir.path_join("out2"))
	check(not other["ok"], "ambiguous without a matching folder")


func test_no_plugin_cfg() -> void:
	var dir := temp_dir("zip_empty")
	make_raw_zip(dir.path_join("package.zip"), { "README.md": "hi" })
	var result := Zip.extract_plugin(dir.path_join("package.zip"), "fake_a", dir.path_join("out"))
	check(not result["ok"], "no plugin")
	check(not DirAccess.dir_exists_absolute(dir.path_join("out")), "nothing extracted")


func test_zip_slip_is_refused() -> void:
	var dir := temp_dir("zip_slip")
	make_raw_zip(dir.path_join("package.zip"), {
		"addons/fake_a/plugin.cfg": "[plugin]\n",
		"addons/fake_a/../../../escape.gd": "evil",
	})
	var result := Zip.extract_plugin(dir.path_join("package.zip"), "fake_a", dir.path_join("out"))
	check(not result["ok"], "path traversal refused")
	check(not FileAccess.file_exists(dir.path_join("escape.gd")), "nothing written outside")


func test_not_a_zip() -> void:
	var dir := temp_dir("zip_invalid")
	write_text(dir.path_join("package.zip"), "<html>rate limited</html>")
	check(not Zip.extract_plugin(dir.path_join("package.zip"), "fake_a", dir.path_join("out"))["ok"], "invalid archive")


func test_extension_without_plugin_cfg() -> void:
	var dir := temp_dir("zip_extension")
	var source := "res://tests/fixtures/addons/fake_ext/1.0.0"
	make_zip(source, dir.path_join("package.zip"), "pkg-1.0/addons/fake_ext/")
	var result := Zip.extract_plugin(dir.path_join("package.zip"), "fake_ext", dir.path_join("out"))
	check(result["ok"], "ok: %s" % result["error"])
	check_eq(result["source_folder"], "fake_ext", "folder name")
	check_eq(Fs.hash_dir(dir.path_join("out")), Fs.hash_dir(source), "everything below the addon folder")


func test_extension_below_a_bin_folder_still_extracts_the_addon_folder() -> void:
	var dir := temp_dir("zip_extension_bin")
	make_raw_zip(dir.path_join("package.zip"), {
		"addons/fake_ext/bin/fake_ext.gdextension": "[configuration]\n",
		"addons/fake_ext/bin/libfake_ext.so": "x",
		"addons/fake_ext/LICENSE": "MIT",
		"README.md": "outside",
	})
	var result := Zip.extract_plugin(dir.path_join("package.zip"), "fake_ext", dir.path_join("out"))
	check(result["ok"], "ok: %s" % result["error"])
	check(FileAccess.file_exists(dir.path_join("out/LICENSE")), "files next to bin/ come along")
	check(FileAccess.file_exists(dir.path_join("out/bin/fake_ext.gdextension")), "the extension keeps its place")
	check(not FileAccess.file_exists(dir.path_join("out/README.md")), "files outside the addon do not")


func test_plugin_cfg_wins_over_an_extension_elsewhere() -> void:
	var dir := temp_dir("zip_both")
	make_raw_zip(dir.path_join("package.zip"), {
		"addons/fake_a/plugin.cfg": "[plugin]\nname=\"a\"\nversion=\"1.0.0\"\nscript=\"plugin.gd\"\n",
		"addons/fake_a/plugin.gd": "extends EditorPlugin",
		"demo/other/other.gdextension": "[configuration]\n",
	})
	var result := Zip.extract_plugin(dir.path_join("package.zip"), "fake_a", dir.path_join("out"))
	check(result["ok"], "ok: %s" % result["error"])
	check(FileAccess.file_exists(dir.path_join("out/plugin.cfg")), "the plugin is extracted")
	check(not FileAccess.file_exists(dir.path_join("out/other.gdextension")), "not the unrelated extension")
