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
	check(result["ok"], "only one plugin in the package, folder name does not matter")


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
