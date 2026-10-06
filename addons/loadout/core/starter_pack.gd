@tool
class_name LoadoutStarterPack
extends RefCounted

## Plugins Loadout recommends to everyone (data/starter_pack.json). A starter is a registry entry plus
## a title and a description. Nothing from here is added to the registry or installed without a click.

const JsonStore := preload("../util/json_store.gd")

const SCHEMA := 1
const DEFAULT_PATH := "res://addons/loadout/data/starter_pack.json"
const META_KEYS: PackedStringArray = ["title", "description"]


## Reads the pack. Invalid starters are skipped with a warning, like registry entries.
## Returns { "ok", "error", "items": [{ "id", "title", "description", "entry": Dictionary }], "warnings" }.
static func load_file(path: String = DEFAULT_PATH) -> Dictionary:
	var result := { "ok": false, "error": "", "items": [] as Array[Dictionary], "warnings": PackedStringArray() }
	var read := JsonStore.read(path, SCHEMA)
	if not read["ok"] or read["missing"]:
		result["error"] = read["error"] if not read["ok"] else "The starter pack %s is missing." % path
		return result
	var data: Variant = read["data"]
	if typeof(data) != TYPE_DICTIONARY or typeof(data.get("starters", [])) != TYPE_ARRAY:
		result["error"] = "The starter pack is not valid."
		return result
	var seen: Dictionary[String, bool] = {}
	for item: Variant in data.get("starters", []):
		if typeof(item) != TYPE_DICTIONARY:
			result["warnings"].append("A starter was skipped: it is not an object.")
			continue
		var raw: Dictionary = (item as Dictionary).duplicate()
		var title := str(raw.get("title", ""))
		var description := str(raw.get("description", ""))
		for key in META_KEYS:
			raw.erase(key)
		var parsed := LoadoutRegistry.parse_entry(raw)
		if not parsed["ok"]:
			result["warnings"].append(parsed["error"])
			continue
		var entry: LoadoutRegistry.Entry = parsed["entry"]
		if seen.has(entry.id):
			result["warnings"].append("Starter %s is listed twice, the second one was skipped." % entry.id)
			continue
		seen[entry.id] = true
		result["items"].append({
			"id": entry.id,
			"title": title if title != "" else entry.id,
			"description": description,
			"entry": entry.to_dict(),
		})
	result["ok"] = true
	return result
