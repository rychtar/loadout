extends "res://tests/test_case.gd"

const Package := preload("res://addons/loadout/util/package.gd")

const PLUGIN := "res://tests/fixtures/addons/fake_a/1.0.0"
const EXTENSION := "res://tests/fixtures/addons/fake_ext/1.0.0"


func test_plugin_folder() -> void:
	check(Package.has_plugin_cfg(PLUGIN), "plugin.cfg found")
	check(not Package.has_extension(PLUGIN), "no extension in a plain plugin")
	check(Package.is_addon(PLUGIN), "a plugin is an addon")
	check(not Package.is_native(PLUGIN), "a plain plugin is not native")


func test_extension_folder_without_plugin_cfg() -> void:
	check(not Package.has_plugin_cfg(EXTENSION), "no plugin.cfg")
	check(Package.has_extension(EXTENSION), ".gdextension found")
	check(Package.is_addon(EXTENSION), "an extension is an addon")
	check(Package.is_native(EXTENSION), "native code cannot be reloaded")


func test_extension_in_a_sub_folder() -> void:
	var dir := temp_dir("package_sub")
	DirAccess.make_dir_recursive_absolute(dir.path_join("bin"))
	write_text(dir.path_join("bin/thing.gdextension"), "[configuration]\n")
	check(Package.has_extension(dir), "found below the folder")


func test_plugin_with_an_extension_is_native() -> void:
	var dir := temp_dir("package_both")
	write_text(dir.path_join("plugin.cfg"), "[plugin]\nname=\"x\"\nversion=\"1.0.0\"\nscript=\"plugin.gd\"\n")
	write_text(dir.path_join("x.gdextension"), "[configuration]\n")
	check(Package.has_plugin_cfg(dir) and Package.has_extension(dir), "both")
	check(Package.is_native(dir), "the native part decides")


func test_neither() -> void:
	var dir := temp_dir("package_none")
	write_text(dir.path_join("readme.md"), "hi")
	check(not Package.is_addon(dir), "just files")
	check(not Package.is_addon(dir.path_join("missing")), "missing folder")
	check(not Package.has_extension(dir.path_join("missing")), "no extension in a missing folder")


func test_extension_roots_in_a_list_of_zip_entries() -> void:
	# Used for zips, where only the entry names are known.
	check_eq(Package.extension_roots(PackedStringArray(["README.md", "addons/orchestrator/orchestrator.gdextension", "addons/orchestrator/a.so"])),
			PackedStringArray(["addons/orchestrator"]), "addons/<folder> of the extension")
	check_eq(Package.extension_roots(PackedStringArray(["pkg-1.0/addons/foo/bin/foo.gdextension"])),
			PackedStringArray(["pkg-1.0/addons/foo"]), "an extension in bin/ belongs to the addons folder")
	check_eq(Package.extension_roots(PackedStringArray(["foo/foo.gdextension"])), PackedStringArray(["foo"]), "no addons folder: its own folder")
	check_eq(Package.extension_roots(PackedStringArray(["foo.gdextension"])), PackedStringArray([""]), "zip root")
	check_eq(Package.extension_roots(PackedStringArray(["readme.md"])), PackedStringArray(), "no extension")
	check_eq(Package.extension_roots(PackedStringArray(["addons/a/a.gdextension", "addons/a/bin/b.gdextension", "addons/c/c.gdextension"])),
			PackedStringArray(["addons/a", "addons/c"]), "each folder once")
