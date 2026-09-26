@tool
class_name LoadoutSource
extends RefCounted

## Where a plugin comes from. Subclasses may await (network); callers always await the methods.
## Only sources/ talks to the network, core/ never does.


## Human readable description for the dock, e.g. "GitHub · bitwes/Gut".
func describe() -> String:
	return ""


## Highest available version within version_range.
## Returns { "ok": bool, "error": String, "version": String }.
func get_latest_version(_version_range: String) -> Dictionary:
	return { "ok": false, "error": "The source cannot tell its version.", "version": "" }


## Whether fetch(version) can deliver exactly this version (used to reinstall the locked version).
func has_version(_version: String) -> bool:
	return true


## Plugin name from the source's plugin.cfg, "" when the source does not know it without fetching.
func get_plugin_name() -> String:
	return ""


## Puts the plugin folder content of version into dest_dir (created by the source).
## Returns { "ok": bool, "error": String, "path": String } where path holds plugin.cfg.
func fetch(_version: String, _dest_dir: String) -> Dictionary:
	return { "ok": false, "error": "The source cannot download.", "path": "" }


## Source for a validated registry source dictionary, null for types not supported yet.
static func create(source: Dictionary) -> LoadoutSource:
	match source.get("type"):
		LoadoutRegistry.SOURCE_LOCAL:
			return LoadoutLocalSource.new(source["path"])
	return null
