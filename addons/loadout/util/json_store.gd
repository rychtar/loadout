@tool
extends RefCounted

## Reads and writes Loadout JSON files (registry, lock, cache).
## - Every file has a "schema" field; an unknown or missing schema is never read or overwritten.
## - A corrupt file is backed up to *.bak (never overwriting an older backup, and not backed up
##   again while an identical backup exists) and never overwritten.
## - An empty file counts as missing: there is nothing in it to lose.
## - Writes go through a temporary file so a crash cannot leave a half-written file. On Windows Godot
##   deletes the old file before it renames the new one into place; a reader in that moment finds the
##   finished temporary file and reads that instead of an empty registry.

const Log := preload("log.gd")

const TMP_SUFFIX := ".tmp"
## A temporary file only stands in for a missing file while it is this fresh (a write in progress,
## not one a crash left behind).
const PENDING_WRITE_S := 10

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
	# One temporary file per editor: two editors saving the shared registry at once must not write into one file.
	var tmp_path := "%s.%d%s" % [path, OS.get_process_id(), TMP_SUFFIX]
	var file := FileAccess.open(tmp_path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(whole_numbers(data), "\t") + "\n")
	err = file.get_error()
	file.close()
	if err != OK:
		DirAccess.remove_absolute(tmp_path)
		return err
	return DirAccess.rename_absolute(tmp_path, path)


## JSON has one number type and Godot reads every number as a float, which it writes back as "5.0".
## Whole numbers become ints again, so fields kept for other Loadout versions do not change.
static func whole_numbers(value: Variant) -> Variant:
	match typeof(value):
		TYPE_FLOAT:
			var number: float = value
			if is_finite(number) and number == floorf(number) and absf(number) < 9.0e15:
				return int(number)
		TYPE_DICTIONARY:
			var converted := {}
			for key: Variant in value:
				converted[key] = whole_numbers(value[key])
			return converted
		TYPE_ARRAY:
			var converted := []
			for item: Variant in value:
				converted.append(whole_numbers(item))
			return converted
	return value


static func _inspect(path: String, schema: int) -> Dictionary:
	if not FileAccess.file_exists(path):
		return _inspect_pending_write(path, schema)
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty() and FileAccess.get_open_error() != OK:
		return { "status": Status.CORRUPT, "error": "File %s cannot be read: %s." % [path, error_string(FileAccess.get_open_error())] }
	return _parse(text, path, schema)


## A missing file whose new version is being renamed into place (see write()): the newest fresh
## temporary file of it when it is complete, otherwise the file counts as missing.
static func _inspect_pending_write(path: String, schema: int) -> Dictionary:
	var dir := path.get_base_dir()
	var prefix := path.get_file() + "."
	var newest := ""
	var newest_time := 0
	if DirAccess.dir_exists_absolute(dir):
		for file_name in DirAccess.get_files_at(dir):
			if file_name.begins_with(prefix) and file_name.ends_with(TMP_SUFFIX):
				var modified := FileAccess.get_modified_time(dir.path_join(file_name))
				if modified > newest_time:
					newest = dir.path_join(file_name)
					newest_time = modified
	if newest == "" or absi(int(Time.get_unix_time_from_system()) - newest_time) > PENDING_WRITE_S:
		return { "status": Status.MISSING }
	var pending := _parse(FileAccess.get_file_as_string(newest), path, schema)
	return pending if pending["status"] == Status.OK else { "status": Status.MISSING }


static func _parse(text: String, path: String, schema: int) -> Dictionary:
	if text.strip_edges().is_empty():
		return { "status": Status.MISSING }
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
	var content_hash := FileAccess.get_sha256(path)
	while FileAccess.file_exists(backup):
		if FileAccess.get_sha256(backup) == content_hash:
			return backup
		backup = "%s.%d.bak" % [path, index]
		index += 1
	if DirAccess.copy_absolute(path, backup) != OK:
		return ""
	return backup
