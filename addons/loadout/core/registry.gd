@tool
class_name LoadoutRegistry
extends RefCounted

## Global registry of plugins every project should have (loadout_registry.json in the editor
## config dir). Invalid entries are skipped with a warning instead of failing the whole file.

const JsonStore := preload("../util/json_store.gd")

const SCHEMA := 1
const FILE_NAME := "loadout_registry.json"
const SOURCE_LOCAL := "local"
const SOURCE_GITHUB := "github"
const SOURCE_ASSETLIB := "assetlib"
const _NAME_PATTERN := "^[A-Za-z0-9_][A-Za-z0-9_.-]*$"
const _REPO_PATTERN := "^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$"
const _GITHUB_URL_PREFIX := "https://github.com/"


class Entry:
	var id: String
	var folder: String
	## { "type": "local", "path": String }, { "type": "github", "repo": "owner/name" }
	## or { "type": "assetlib", "asset_id": "1234" }
	var source: Dictionary
	var version_range: String = "*"
	var auto_install: bool = true

	func to_dict() -> Dictionary:
		return {
			"id": id,
			"folder": folder,
			"source": source.duplicate(),
			"range": version_range,
			"auto_install": auto_install,
		}


var entries: Array[Entry] = []
## Problems found while parsing, for the dock.
var warnings: PackedStringArray = []


## Returns { "ok": bool, "error": String, "registry": LoadoutRegistry or null }.
static func from_dict(data: Variant) -> Dictionary:
	if typeof(data) != TYPE_DICTIONARY:
		return { "ok": false, "error": "The registry is not a JSON object.", "registry": null }
	if not JsonStore.has_schema(data, SCHEMA):
		return { "ok": false, "error": "The registry has an unknown schema %s." % JsonStore.describe_schema(data), "registry": null }
	var plugins: Variant = data.get("plugins", [])
	if typeof(plugins) != TYPE_ARRAY:
		return { "ok": false, "error": "\"plugins\" in the registry must be a list.", "registry": null }
	var registry := LoadoutRegistry.new()
	for item: Variant in plugins:
		var error := registry.add_entry(item)
		if error != "":
			registry.warnings.append(error)
	return { "ok": true, "error": "", "registry": registry }


## Returns { "ok", "error", "registry", "missing", "backup_path" }. A missing file is an empty registry.
static func load_file(path: String) -> Dictionary:
	var read := JsonStore.read(path, SCHEMA)
	var result := { "ok": false, "error": read["error"], "registry": null, "missing": read["missing"], "backup_path": read["backup_path"] }
	if not read["ok"]:
		return result
	if read["missing"]:
		result["ok"] = true
		result["registry"] = LoadoutRegistry.new()
		return result
	var parsed := from_dict(read["data"])
	result["ok"] = parsed["ok"]
	result["error"] = parsed["error"]
	result["registry"] = parsed["registry"]
	return result


## Validates a raw entry. Returns { "ok": bool, "error": String, "entry": Entry or null }.
static func parse_entry(data: Variant) -> Dictionary:
	if typeof(data) != TYPE_DICTIONARY:
		return _entry_error("?", "entry is not an object")
	var id: Variant = data.get("id", "")
	if typeof(id) != TYPE_STRING or not _is_valid_name(id):
		return _entry_error(str(id), "invalid id")
	var entry := Entry.new()
	entry.id = id
	var folder: Variant = data.get("folder", id)
	if typeof(folder) != TYPE_STRING or not _is_valid_name(folder):
		return _entry_error(id, "invalid folder %s" % var_to_str(folder))
	entry.folder = folder
	var version_range: Variant = data.get("range", "*")
	if typeof(version_range) != TYPE_STRING or not LoadoutVersion.is_valid_range(version_range):
		return _entry_error(id, "invalid version range %s" % var_to_str(version_range))
	entry.version_range = version_range if version_range != "" else "*"
	var auto_install: Variant = data.get("auto_install", true)
	if typeof(auto_install) != TYPE_BOOL:
		return _entry_error(id, "auto_install must be true or false")
	entry.auto_install = auto_install
	var source := _parse_source(data.get("source"))
	if not source["ok"]:
		return _entry_error(id, source["error"])
	entry.source = source["source"]
	return { "ok": true, "error": "", "entry": entry }


## Saves the registry. Refuses to overwrite a corrupt file or one with an unknown schema.
func save_file(path: String) -> Error:
	return JsonStore.write(path, to_dict(), SCHEMA)


func to_dict() -> Dictionary:
	var plugins: Array[Dictionary] = []
	for entry in entries:
		plugins.append(entry.to_dict())
	return { "schema": SCHEMA, "plugins": plugins }


func get_entry(id: String) -> Entry:
	for entry in entries:
		if entry.id == id:
			return entry
	return null


## Adds a raw entry. Returns "" on success, otherwise an error message.
func add_entry(data: Variant) -> String:
	var parsed := parse_entry(data)
	if not parsed["ok"]:
		return parsed["error"]
	var entry: Entry = parsed["entry"]
	for existing in entries:
		if existing.id == entry.id:
			return "Plugin %s: the id is already in the registry." % entry.id
		if existing.folder.to_lower() == entry.folder.to_lower():
			return "Plugin %s: folder %s is already used by %s." % [entry.id, entry.folder, existing.id]
	entries.append(entry)
	return ""


func remove_entry(id: String) -> bool:
	for i in entries.size():
		if entries[i].id == id:
			entries.remove_at(i)
			return true
	return false


static func _parse_source(data: Variant) -> Dictionary:
	if typeof(data) != TYPE_DICTIONARY:
		return { "ok": false, "error": "source missing" }
	match data.get("type"):
		SOURCE_LOCAL:
			var path: Variant = data.get("path", "")
			if typeof(path) != TYPE_STRING or not path.is_absolute_path() or path.contains("://"):
				return { "ok": false, "error": "a local source needs an absolute path" }
			return { "ok": true, "source": { "type": SOURCE_LOCAL, "path": path } }
		SOURCE_GITHUB:
			var repo: Variant = data.get("repo", "")
			if typeof(repo) != TYPE_STRING:
				return { "ok": false, "error": "invalid GitHub repository" }
			if repo.begins_with("http://"):
				return { "ok": false, "error": "only HTTPS is allowed" }
			var normalized := _normalize_repo(repo)
			if normalized == "":
				return { "ok": false, "error": "invalid GitHub repository %s (expected owner/name)" % repo }
			return { "ok": true, "source": { "type": SOURCE_GITHUB, "repo": normalized } }
		SOURCE_ASSETLIB:
			var asset_id: Variant = data.get("asset_id", "")
			if typeof(asset_id) == TYPE_FLOAT and is_equal_approx(asset_id, roundf(asset_id)):
				asset_id = str(int(asset_id))
			if typeof(asset_id) == TYPE_INT:
				asset_id = str(asset_id)
			if typeof(asset_id) != TYPE_STRING or not asset_id.is_valid_int() or asset_id.to_int() <= 0:
				return { "ok": false, "error": "invalid Asset Library asset id %s" % var_to_str(asset_id) }
			return { "ok": true, "source": { "type": SOURCE_ASSETLIB, "asset_id": asset_id } }
	return { "ok": false, "error": "unknown source type %s" % var_to_str(data.get("type")) }


static func _normalize_repo(repo: String) -> String:
	var text := repo.strip_edges()
	if text.begins_with(_GITHUB_URL_PREFIX):
		text = text.trim_prefix(_GITHUB_URL_PREFIX).trim_suffix("/").trim_suffix(".git")
	elif text.contains("://"):
		return ""
	if RegEx.create_from_string(_REPO_PATTERN).search(text) == null:
		return ""
	return text


static func _is_valid_name(text: String) -> bool:
	return RegEx.create_from_string(_NAME_PATTERN).search(text) != null and not text.contains("..")


static func _entry_error(id: String, message: String) -> Dictionary:
	return { "ok": false, "error": "Plugin %s skipped in the registry: %s." % [id, message], "entry": null }
