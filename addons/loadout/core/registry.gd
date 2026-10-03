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
## Legacy Asset Library (godotengine.org/asset-library); existing entries keep working.
const SOURCE_ASSETLIB := "assetlib"
## Godot Asset Store (store.godotengine.org), the store of Godot 4.7+.
const SOURCE_STORE := "store"
const _STORE_URL_PREFIX := "https://store.godotengine.org/asset/"
const _STORE_ASSET_PATTERN := "^[a-z0-9][a-z0-9_-]*/[a-z0-9][a-z0-9_.-]*$"
const _NAME_PATTERN := "^[A-Za-z0-9_][A-Za-z0-9_.-]*$"
const _REPO_PATTERN := "^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$"
const _GITHUB_URL_PREFIX := "https://github.com/"


class Entry:
	var id: String
	var folder: String
	## { "type": "local", "path": String }, { "type": "github", "repo": "owner/name" }
	## { "type": "store", "asset": "publisher/slug" } or { "type": "assetlib", "asset_id": "1234" }
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


static var _regex_cache: Dictionary[String, RegEx] = {}

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
	if read["ok"]:
		result.merge({ "ok": true, "error": "", "registry": LoadoutRegistry.new() } if read["missing"] else from_dict(read["data"]), true)
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
	if source["error"] != "":
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


## Replaces source, version range and auto_install of an entry; id and folder stay (a new folder
## would not move installed copies, see set_folder()). Returns "" or an error message.
func update_entry(id: String, data: Dictionary) -> String:
	var entry := get_entry(id)
	if entry == null:
		return "The plugin is not in the registry."
	var merged := data.duplicate()
	merged["id"] = entry.id
	merged["folder"] = entry.folder
	var parsed := parse_entry(merged)
	if not parsed["ok"]:
		return parsed["error"]
	var updated: Entry = parsed["entry"]
	entry.source = updated.source
	entry.version_range = updated.version_range
	entry.auto_install = updated.auto_install
	return ""


## Changes the plugin folder of an entry. Returns "" or an error message.
func set_folder(id: String, folder: String) -> String:
	var entry := get_entry(id)
	if entry == null:
		return "The plugin is not in the registry."
	var data := entry.to_dict()
	data["folder"] = folder
	var parsed := parse_entry(data)
	if not parsed["ok"]:
		return parsed["error"]
	for other in entries:
		if other != entry and other.folder.to_lower() == folder.to_lower():
			return "Folder %s is already used by %s." % [folder, other.id]
	entry.folder = folder
	return ""


## Adds the entries of other whose id is new; existing ones stay.
## Returns { "added": PackedStringArray, "skipped": { id: reason } }.
func merge(other: LoadoutRegistry) -> Dictionary:
	var summary := { "added": PackedStringArray(), "skipped": {} }
	for entry in other.entries:
		if get_entry(entry.id) != null:
			summary["skipped"][entry.id] = "already in the registry"
			continue
		var error := add_entry(entry.to_dict())
		if error != "":
			summary["skipped"][entry.id] = error
		else:
			summary["added"].append(entry.id)
	return summary


func remove_entry(id: String) -> bool:
	for i in entries.size():
		if entries[i].id == id:
			entries.remove_at(i)
			return true
	return false


## Returns { "error": String, "source": Dictionary } (source only when error is "").
static func _parse_source(data: Variant) -> Dictionary:
	if typeof(data) != TYPE_DICTIONARY:
		return { "error": "source missing" }
	match data.get("type"):
		SOURCE_LOCAL:
			var path: Variant = data.get("path", "")
			if typeof(path) != TYPE_STRING or not path.is_absolute_path() or path.contains("://"):
				return { "error": "a local source needs an absolute path" }
			return { "error": "", "source": { "type": SOURCE_LOCAL, "path": path } }
		SOURCE_GITHUB:
			var repo: Variant = data.get("repo", "")
			if typeof(repo) != TYPE_STRING:
				return { "error": "invalid GitHub repository" }
			if repo.begins_with("http://"):
				return { "error": "only HTTPS is allowed" }
			var normalized := _normalize_repo(repo)
			if normalized == "":
				return { "error": "invalid GitHub repository %s (expected owner/name)" % repo }
			return { "error": "", "source": { "type": SOURCE_GITHUB, "repo": normalized } }
		SOURCE_ASSETLIB:
			var asset_id: Variant = data.get("asset_id", "")
			if typeof(asset_id) == TYPE_FLOAT and is_equal_approx(asset_id, roundf(asset_id)):
				asset_id = str(int(asset_id))
			if typeof(asset_id) == TYPE_INT:
				asset_id = str(asset_id)
			if typeof(asset_id) != TYPE_STRING or not asset_id.is_valid_int() or asset_id.to_int() <= 0:
				return { "error": "invalid Asset Library asset id %s" % var_to_str(asset_id) }
			return { "error": "", "source": { "type": SOURCE_ASSETLIB, "asset_id": asset_id } }
		SOURCE_STORE:
			var asset: Variant = data.get("asset", "")
			if typeof(asset) != TYPE_STRING:
				return { "error": "invalid Asset Store asset" }
			var text: String = asset.strip_edges()
			if text.begins_with(_STORE_URL_PREFIX):
				text = text.trim_prefix(_STORE_URL_PREFIX).trim_suffix("/")
			if not _matches(_STORE_ASSET_PATTERN, text):
				return { "error": "invalid Asset Store asset %s (expected publisher/slug)" % asset }
			return { "error": "", "source": { "type": SOURCE_STORE, "asset": text } }
	return { "error": "unknown source type %s" % var_to_str(data.get("type")) }


static func _normalize_repo(repo: String) -> String:
	var text := repo.strip_edges()
	if text.begins_with(_GITHUB_URL_PREFIX):
		text = text.trim_prefix(_GITHUB_URL_PREFIX).trim_suffix("/").trim_suffix(".git")
	elif text.contains("://"):
		return ""
	if not _matches(_REPO_PATTERN, text):
		return ""
	return text


static func _is_valid_name(text: String) -> bool:
	return _matches(_NAME_PATTERN, text) and not text.contains("..")


static func _matches(pattern: String, text: String) -> bool:
	if not _regex_cache.has(pattern):
		_regex_cache[pattern] = RegEx.create_from_string(pattern)
	return _regex_cache[pattern].search(text) != null


static func _entry_error(id: String, message: String) -> Dictionary:
	return { "ok": false, "error": "Plugin %s skipped in the registry: %s." % [id, message], "entry": null }
