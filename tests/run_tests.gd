extends SceneTree
## Runs all test suites in tests/unit (files test_*.gd, methods test_*):
## godot --headless --path . --script res://tests/run_tests.gd

const UNIT_DIR := "res://tests/unit"

var _started := false


## A runtime error in a test (bad call, wrong type) ends the test method early without failing a
## check, so the test would pass. This collects such errors; _run() turns them into failures.
## Parse errors are left out: tests of broken plugins cause them on purpose.
class ScriptErrorLogger extends Logger:
	var errors: PackedStringArray = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String,
			_editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		var message := rationale if rationale != "" else code
		if error_type == ERROR_TYPE_SCRIPT and not message.begins_with("Parse Error"):
			errors.append("script error in %s (%s:%d): %s" % [function, file.get_file(), line, message])


## Starts on the first frame, when the tree is live and added nodes get _ready().
## Tests may await (installer, sources); _run() quits when everything has finished.
func _process(_delta: float) -> bool:
	if not _started:
		_started = true
		_run()
	return false


func _run() -> void:
	var total := 0
	var failed := 0
	var error_logger := ScriptErrorLogger.new()
	OS.add_logger(error_logger)
	for suite_path in _suite_paths():
		var suite_script := load(suite_path) as GDScript
		print(suite_path.get_file())
		if suite_script == null or not suite_script.can_instantiate():
			failed += 1
			print("  FAIL suite does not load")
			continue
		for method in suite_script.get_script_method_list():
			var test_name: String = method.name
			if not test_name.begins_with("test_"):
				continue
			var suite: Variant = suite_script.new()
			error_logger.errors.clear()
			await suite.call(test_name)
			for message in error_logger.errors:
				suite.failures.append(message)
			total += 1
			if suite.failures.is_empty():
				print("  ok   ", test_name)
			else:
				failed += 1
				print("  FAIL ", test_name)
				for failure: String in suite.failures:
					print("       ", failure)
	OS.remove_logger(error_logger)
	print("%d tests, %d failed" % [total, failed])
	quit(1 if failed > 0 else 0)


func _suite_paths() -> PackedStringArray:
	var paths: PackedStringArray = []
	for file_name in DirAccess.get_files_at(UNIT_DIR):
		if file_name.begins_with("test_") and file_name.get_extension() == "gd":
			paths.append(UNIT_DIR.path_join(file_name))
	paths.sort()
	return paths
