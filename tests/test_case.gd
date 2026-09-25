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
