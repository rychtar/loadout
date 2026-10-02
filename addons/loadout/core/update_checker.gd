@tool
class_name LoadoutUpdateChecker
extends RefCounted

## Decides when remote sources are asked for releases and caches the answers in loadout_cache.json
## (editor config dir, not in git). Each remote source is asked at most once a day unless the
## user forces a check; the ETag of the last answer is sent back so an unchanged list is a short
## 304 answer (free of the GitHub rate limit when a token is set). When a source fails, the cached releases are used and a warning goes to the dock.
## Local sources are cheap and read every time.

const JsonStore := preload("../util/json_store.gd")

const SCHEMA := 1
const FILE_NAME := "loadout_cache.json"
const CHECK_INTERVAL_S := 24 * 60 * 60

var path: String
## Problems with the cache file itself (shown in the dock, the cache is then rebuilt).
var warnings: PackedStringArray = []

var _now: Callable
## { key: { "checked_at": int, "etag": String, "releases": Array, "last_error": String } }
var _sources: Dictionary = {}
var _dirty := false
## The file has a schema from another Loadout version: use memory only, never overwrite it.
var _read_only := false


## cache_path "" keeps the cache in memory only. now: func() -> int (unix time), for tests.
func _init(cache_path: String, now: Callable = Callable()) -> void:
	path = cache_path
	_now = now if now.is_valid() else func() -> int: return int(Time.get_unix_time_from_system())


func load_cache() -> void:
	warnings.clear()
	_sources = {}
	_dirty = false
	_read_only = false
	if path == "":
		return
	var read := JsonStore.read(path, SCHEMA)
	if not read["ok"]:
		warnings.append(read["error"])
		if read["backup_path"] != "":
			# Corrupt: the cache only holds downloaded data, after the backup it is rebuilt.
			DirAccess.remove_absolute(path)
		else:
			_read_only = true
		return
	var sources: Variant = read["data"].get("sources", {})
	if typeof(sources) == TYPE_DICTIONARY:
		_sources = sources


func save_cache() -> Error:
	if path == "" or _read_only or not _dirty:
		return OK
	var err := JsonStore.write(path, { "schema": SCHEMA, "sources": _sources }, SCHEMA)
	if err == OK:
		_dirty = false
	return err


## True when the source has not been asked within the last day.
func is_due(key: String) -> bool:
	var entry: Dictionary = _sources.get(key, {})
	return _now.call() - int(entry.get("checked_at", 0)) >= CHECK_INTERVAL_S


## Fills source.releases from the cache or the source. Returns { "ok": bool, "error": String,
## "warning": String, "from_cache": bool, "checked": bool }. ok is false only when no releases
## are known at all.
func load_releases(source: LoadoutSource, force: bool = false) -> Dictionary:
	var result := { "ok": false, "error": "", "warning": "", "from_cache": false, "checked": false }
	if not source.is_remote():
		var local: Dictionary = await source.list_releases()
		source.releases.assign(local["releases"] if local["ok"] else [])
		result["ok"] = local["ok"]
		result["error"] = local["error"]
		result["checked"] = true
		return result

	var key := source.cache_key()
	var entry: Dictionary = _sources.get(key, {})
	var cached: Array = entry.get("releases", [])
	if not force and not is_due(key) and entry.has("checked_at"):
		source.releases.assign(cached)
		result["from_cache"] = true
		result["ok"] = not cached.is_empty()
		result["error"] = "" if result["ok"] else str(entry.get("last_error", "The source has no releases."))
		return result

	var answer: Dictionary = await source.list_releases(str(entry.get("etag", "")))
	entry["checked_at"] = _now.call()
	_dirty = true
	_sources[key] = entry
	if answer["ok"]:
		if not answer["not_modified"]:
			entry["releases"] = answer["releases"]
			cached = answer["releases"]
		entry["etag"] = answer["etag"]
		entry["updated_at"] = entry["checked_at"]
		entry["last_error"] = ""
		result["checked"] = true
		result["error"] = "" if not cached.is_empty() else "The source has no releases."
	else:
		entry["last_error"] = answer["error"]
		result["error"] = answer["error"]
		# Stale data beats none: the releases from the last good answer, with a warning.
		if not cached.is_empty():
			result["from_cache"] = true
			result["warning"] = "%s Using data from %s." % [answer["error"], Time.get_date_string_from_unix_time(int(entry.get("updated_at", 0)))]
			result["error"] = ""
	source.releases.assign(cached)
	result["ok"] = not cached.is_empty()
	return result
