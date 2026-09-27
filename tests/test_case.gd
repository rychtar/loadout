extends RefCounted
## Minimal assertions for the headless test runner.

const Fs := preload("res://addons/loadout/util/fs.gd")
const TEMP_ROOT := "user://loadout_test"

var failures: PackedStringArray = []


func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func check_eq(actual: Variant, expected: Variant, message: String) -> void:
	if typeof(actual) != typeof(expected) or actual != expected:
		failures.append("%s: expected %s, got %s" % [message, var_to_str(expected), var_to_str(actual)])


## Returns an empty directory under user://loadout_test/, never res://.
func temp_dir(name: String) -> String:
	var path := TEMP_ROOT.path_join(name)
	Fs.remove_dir(path)
	DirAccess.make_dir_recursive_absolute(path)
	return path


func write_text(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)


## Zips every file under src_dir into zip_path, each stored as prefix + relative path.
func make_zip(src_dir: String, zip_path: String, prefix: String) -> void:
	var packer := ZIPPacker.new()
	packer.open(zip_path)
	for relative in Fs.list_files(src_dir):
		packer.start_file(prefix + relative)
		packer.write_file(FileAccess.get_file_as_bytes(src_dir.path_join(relative)))
		packer.close_file()
	packer.close()


## Adds one file with raw content to a new zip (for malformed archives).
func make_raw_zip(zip_path: String, files: Dictionary) -> void:
	var packer := ZIPPacker.new()
	packer.open(zip_path)
	for name: String in files:
		packer.start_file(name)
		packer.write_file(str(files[name]).to_utf8_buffer())
		packer.close_file()
	packer.close()
