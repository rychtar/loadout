@tool
extends RefCounted

## Reads and writes Loadout JSON files (registry, lock, cache).
## - Every file has a "schema" field; an unknown or missing schema is never read or overwritten.
## - A corrupt file is backed up to *.bak (never overwriting an older backup) and never overwritten.
## - Writes go through a temporary file so a crash cannot leave a half-written file.

const Log := preload("log.gd")

enum Status { OK, MISSING, CORRUPT, UNKNOWN_SCHEMA }


## Returns { "ok": bool, "error": String, "data": Dictionary, "missing": bool, "backup_path": String }.
## A missing file is ok with empty data.
static func read(path: String, schema: int) -> Dictionary:
	var result := { "ok": false, "error": "", "data": {}, "missing": false, "backup_path": "" }
	var parsed := _inspect(path, schema)
	match parsed["status"]:
		Status.OK:
			result["ok"] = true
			result["data"] = parsed["data"]
		Status.MISSING:
			result["ok"] = true
			result["missing"] = true
		Status.CORRUPT:
			var backup := _backup(path)
			result["backup_path"] = backup
			result["error"] = "%s Backup: %s" % [parsed["error"], backup if backup != "" else "not created"]
		Status.UNKNOWN_SCHEMA:
			result["error"] = parsed["error"]
	if result["error"] != "":
		Log.write(result["error"], Log.Level.WARNING)
	return result


## Writes data as tab-indented JSON with sorted keys. Refuses to replace a file that is corrupt
## or has an unknown schema.
static func write(path: String, data: Dictionary, schema: int) -> Error:
	var existing := _inspect(path, schema)
	if existing["status"] == Status.CORRUPT or existing["status"] == Status.UNKNOWN_SCHEMA:
		Log.write("Not overwriting %s: %s" % [path, existing["error"]], Log.Level.ERROR)
		return ERR_FILE_CORRUPT
	var err := DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if err != OK:
		return err
	var tmp_path := path + ".tmp"
	var file := FileAccess.open(tmp_path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(data, "\t") + "\n")
	err = file.get_error()
	file.close()
	if err != OK:
		DirAccess.remove_absolute(tmp_path)
		return err
	return DirAccess.rename_absolute(tmp_path, path)


static func _inspect(path: String, schema: int) -> Dictionary:
	if not FileAccess.file_exists(path):
		return { "status": Status.MISSING }
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty() and FileAccess.get_open_error() != OK:
		return { "status": Status.CORRUPT, "error": "File %s cannot be read: %s." % [path, error_string(FileAccess.get_open_error())] }
	var json := JSON.new()
	if json.parse(text) != OK:
		return { "status": Status.CORRUPT, "error": "Damaged JSON in %s (line %d: %s)." % [path, json.get_error_line() + 1, json.get_error_message()] }
	if typeof(json.data) != TYPE_DICTIONARY:
		return { "status": Status.CORRUPT, "error": "File %s does not contain a JSON object." % path }
	var data: Dictionary = json.data
	if not has_schema(data, schema):
		return { "status": Status.UNKNOWN_SCHEMA, "error": "File %s has an unknown schema %s (supported: %d), not reading it." % [path, describe_schema(data), schema] }
	return { "status": Status.OK, "data": data }


## Human readable schema value for error messages ("2", "missing").
static func describe_schema(data: Dictionary) -> String:
	var value: Variant = data.get("schema")
	if value == null:
		return "missing"
	if typeof(value) == TYPE_FLOAT and is_equal_approx(value, roundf(value)):
		return str(int(value))
	return var_to_str(value)


static func has_schema(data: Dictionary, schema: int) -> bool:
	var value: Variant = data.get("schema")
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return false
	return float(value) == float(schema)


static func _backup(path: String) -> String:
	var backup := path + ".bak"
	var index := 1
	while FileAccess.file_exists(backup):
		backup = "%s.%d.bak" % [path, index]
		index += 1
	if DirAccess.copy_absolute(path, backup) != OK:
		return ""
	return backup
