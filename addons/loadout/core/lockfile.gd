@tool
class_name LoadoutLockfile
extends RefCounted

## Per-project lock (loadout.lock.json in the project root, committed to git): installed version,
## pin, folder hash and install date of every managed plugin, plus ids ignored in this project.
## Output is deterministic (sorted keys and ids) so diffs stay small.

const JsonStore := preload("../util/json_store.gd")

const SCHEMA := 1
const DEFAULT_PATH := "res://loadout.lock.json"
const HASH_PREFIX := "sha256:"


class Entry:
	var version: String
	var pinned: bool = false
	## "sha256:<hex>" of the plugin folder, "" when unknown.
	var folder_hash: String = ""
	## ISO date (YYYY-MM-DD).
	var installed_at: String = ""

	func to_dict() -> Dictionary:
		return { "version": version, "pinned": pinned, "hash": folder_hash, "installed_at": installed_at }


var plugins: Dictionary[String, Entry] = {}
var ignored: PackedStringArray = []
## Problems found while parsing, for the dock.
var warnings: PackedStringArray = []


## Returns { "ok": bool, "error": String, "lockfile": LoadoutLockfile or null }.
static func from_dict(data: Variant) -> Dictionary:
	if typeof(data) != TYPE_DICTIONARY:
		return { "ok": false, "error": "The lock is not a JSON object.", "lockfile": null }
	if not JsonStore.has_schema(data, SCHEMA):
		return { "ok": false, "error": "The lock has an unknown schema %s." % JsonStore.describe_schema(data), "lockfile": null }
	var raw_plugins: Variant = data.get("plugins", {})
	var raw_ignored: Variant = data.get("ignored", [])
	if typeof(raw_plugins) != TYPE_DICTIONARY:
		return { "ok": false, "error": "\"plugins\" in the lock must be an object.", "lockfile": null }
	if typeof(raw_ignored) != TYPE_ARRAY:
		return { "ok": false, "error": "\"ignored\" in the lock must be a list.", "lockfile": null }
	var lock := LoadoutLockfile.new()
	for id: Variant in raw_plugins:
		var parsed := _parse_entry(str(id), raw_plugins[id])
		if parsed["ok"]:
			lock.plugins[str(id)] = parsed["entry"]
		else:
			lock.warnings.append(parsed["error"])
	for id: Variant in raw_ignored:
		if typeof(id) == TYPE_STRING:
			lock.set_ignored(id, true)
		else:
			lock.warnings.append("Invalid id in \"ignored\": %s." % var_to_str(id))
	return { "ok": true, "error": "", "lockfile": lock }


## Returns { "ok", "error", "lockfile", "missing", "backup_path" }. A missing file is an empty lock.
static func load_file(path: String = DEFAULT_PATH) -> Dictionary:
	var read := JsonStore.read(path, SCHEMA)
	var result := { "ok": false, "error": read["error"], "lockfile": null, "missing": read["missing"], "backup_path": read["backup_path"] }
	if not read["ok"]:
		return result
	if read["missing"]:
		result["ok"] = true
		result["lockfile"] = LoadoutLockfile.new()
		return result
	var parsed := from_dict(read["data"])
	result["ok"] = parsed["ok"]
	result["error"] = parsed["error"]
	result["lockfile"] = parsed["lockfile"]
	return result


## Saves the lock. Refuses to overwrite a corrupt file or one with an unknown schema.
func save_file(path: String = DEFAULT_PATH) -> Error:
	return JsonStore.write(path, to_dict(), SCHEMA)


func to_dict() -> Dictionary:
	var raw_plugins := {}
	for id in plugins:
		raw_plugins[id] = plugins[id].to_dict()
	var sorted_ignored := ignored.duplicate()
	sorted_ignored.sort()
	return { "schema": SCHEMA, "plugins": raw_plugins, "ignored": Array(sorted_ignored) }


func get_entry(id: String) -> Entry:
	return plugins.get(id)


## Records an installed version. Keeps the pin of an existing entry.
func set_installed(id: String, version: String, folder_hash: String, date: String) -> void:
	var entry: Entry = plugins.get(id)
	if entry == null:
		entry = Entry.new()
		plugins[id] = entry
	entry.version = version
	entry.folder_hash = folder_hash
	entry.installed_at = date


## Returns false when the plugin is not in the lock.
func set_pinned(id: String, pinned: bool) -> bool:
	var entry: Entry = plugins.get(id)
	if entry == null:
		return false
	entry.pinned = pinned
	return true


func remove(id: String) -> bool:
	return plugins.erase(id)


func is_ignored(id: String) -> bool:
	return ignored.has(id)


func set_ignored(id: String, value: bool) -> void:
	if value and not ignored.has(id):
		ignored.append(id)
	elif not value:
		ignored.erase(id)


static func _parse_entry(id: String, data: Variant) -> Dictionary:
	if typeof(data) != TYPE_DICTIONARY:
		return _entry_error(id, "entry is not an object")
	var version: Variant = data.get("version")
	if typeof(version) != TYPE_STRING or LoadoutVersion.parse(version) == null:
		return _entry_error(id, "invalid version %s" % var_to_str(version))
	var pinned: Variant = data.get("pinned", false)
	if typeof(pinned) != TYPE_BOOL:
		return _entry_error(id, "pinned must be true or false")
	var folder_hash: Variant = data.get("hash", "")
	if typeof(folder_hash) != TYPE_STRING or (folder_hash != "" and not folder_hash.begins_with(HASH_PREFIX)):
		return _entry_error(id, "invalid hash %s" % var_to_str(folder_hash))
	var installed_at: Variant = data.get("installed_at", "")
	if typeof(installed_at) != TYPE_STRING:
		return _entry_error(id, "invalid install date")
	var entry := Entry.new()
	entry.version = version
	entry.pinned = pinned
	entry.folder_hash = folder_hash
	entry.installed_at = installed_at
	return { "ok": true, "error": "", "entry": entry }


static func _entry_error(id: String, message: String) -> Dictionary:
	return { "ok": false, "error": "Plugin %s skipped in the lock: %s." % [id, message], "entry": null }
