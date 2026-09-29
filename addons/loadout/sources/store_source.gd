@tool
class_name LoadoutStoreSource
extends LoadoutSource

## Plugin from the Godot Asset Store (store.godotengine.org, public API v1), the store of Godot 4.7+.
## Releases are listed for the running Godot version. Download links are signed and expire after
## a few minutes, so they are never cached: fetch() asks for the release list again right before
## downloading. Paid assets (no public download link) are not supported.

const Zip := preload("../util/zip.gd")
const Fs := preload("../util/fs.gd")

const API := "https://store.godotengine.org/api/v1"
const ASSET_PAGE := "https://store.godotengine.org/asset/%s/"
const USER_AGENT := "Loadout (Godot editor plugin)"
const MAX_NOTES := 4000
const SEARCH_RESULTS := 20

## "publisher/slug"
var asset: String
var folder: String
var _http: LoadoutHttp
var _godot_version: String


func _init(asset_path: String, plugin_folder: String, http: LoadoutHttp, godot_version: String = "") -> void:
	asset = asset_path
	folder = plugin_folder
	_http = http
	_godot_version = godot_version


func describe() -> String:
	return "Asset Store · %s" % asset


func is_remote() -> bool:
	return true


func cache_key() -> String:
	return "store:%s" % asset


func list_releases(_etag: String = "") -> Dictionary:
	var result := { "ok": false, "error": "", "not_modified": false, "etag": "", "releases": [] }
	var answer := await _fetch_release_data()
	if not answer["ok"]:
		result["error"] = answer["error"]
		return result
	var list: Array[Dictionary] = []
	for item: Dictionary in answer["data"]:
		var tag := str(item.get("version", ""))
		var version := LoadoutVersion.parse(tag)
		if version == null:
			continue
		var notes := str(item.get("notes", "") if item.get("notes") != null else "")
		if notes == "" and item.get("changes_bbcode") != null:
			notes = str(item.get("changes_bbcode"))
		if notes.length() > MAX_NOTES:
			notes = notes.left(MAX_NOTES) + "…"
		list.append({
			"version": str(version),
			"tag": tag,
			"prerelease": not bool(item.get("stable", true)) or version.is_prerelease(),
			"notes": notes,
			"url": ASSET_PAGE % asset,
			"download_url": "",
			"release_id": int(item.get("id", 0)),
		})
	result["ok"] = true
	result["releases"] = list
	return result


func fetch(version: String, dest_dir: String) -> Dictionary:
	var release := get_release(version)
	if release.is_empty():
		return { "ok": false, "error": "Release %s of %s is unknown, check for updates." % [version, asset], "path": "" }
	# Signed links expire, ask for a fresh one.
	var answer := await _fetch_release_data()
	if not answer["ok"]:
		return { "ok": false, "error": answer["error"], "path": "" }
	var url := ""
	var found := false
	for item: Dictionary in answer["data"]:
		if int(item.get("id", -1)) == int(release.get("release_id", -2)):
			found = true
			url = str(item.get("download_url", "")) if item.get("download_url") != null else ""
	if not found:
		return { "ok": false, "error": "The Asset Store no longer offers %s %s." % [asset, version], "path": "" }
	if url == "":
		return { "ok": false, "error": "%s %s has no public download (paid assets are not supported)." % [asset, version], "path": "" }
	var response: Dictionary = await _http.get_request(url, _headers())
	if not response["ok"]:
		return { "ok": false, "error": response["error"], "path": "" }
	if response["code"] != 200:
		return { "ok": false, "error": "Download of %s %s failed (code %d)." % [asset, version, response["code"]], "path": "" }
	var zip_path := dest_dir.trim_suffix("/") + ".zip"
	DirAccess.make_dir_recursive_absolute(zip_path.get_base_dir())
	var file := FileAccess.open(zip_path, FileAccess.WRITE)
	if file == null:
		return { "ok": false, "error": "Cannot save the zip: %s" % error_string(FileAccess.get_open_error()), "path": "" }
	file.store_buffer(response["body"])
	file.close()
	var extracted := Zip.extract_plugin(zip_path, folder, dest_dir)
	DirAccess.remove_absolute(zip_path)
	if not extracted["ok"]:
		Fs.remove_dir(dest_dir)
		return { "ok": false, "error": extracted["error"], "path": "" }
	return { "ok": true, "error": "", "path": dest_dir, "package_folder": extracted["source_folder"],
			"warning": folder_warning(extracted["source_folder"], folder) }


## Searches free add-ons for the given Godot version ("4.7"). Returns { "ok", "error",
## "results": [{ "asset": "publisher/slug", "title", "author" }] }.
static func search(http: LoadoutHttp, query: String, godot_version: String) -> Dictionary:
	var text := query.strip_edges()
	if text == "":
		return { "ok": false, "error": "Enter what to search for.", "results": [] }
	var url := "%s/search/query/?type=0&query=%s" % [API, text.uri_encode()]
	if godot_version != "":
		url += "&compatibility=%s" % godot_version
	url += "&batch_size=%d" % SEARCH_RESULTS
	var response: Dictionary = await http.get_request(url, PackedStringArray(["User-Agent: %s" % USER_AGENT]))
	if not response["ok"]:
		return { "ok": false, "error": response["error"], "results": [] }
	if response["code"] != 200:
		return { "ok": false, "error": "The Asset Store answered with code %d." % response["code"], "results": [] }
	var data: Variant = JSON.parse_string((response["body"] as PackedByteArray).get_string_from_utf8())
	if typeof(data) != TYPE_DICTIONARY or typeof(data.get("hits")) != TYPE_ARRAY:
		return { "ok": false, "error": "Unexpected Asset Store answer.", "results": [] }
	var results: Array[Dictionary] = []
	for hit: Variant in data["hits"]:
		if typeof(hit) != TYPE_DICTIONARY or typeof(hit.get("asset")) != TYPE_DICTIONARY:
			continue
		var item: Dictionary = hit["asset"]
		if int(item.get("price_cent", 0)) > 0:
			continue
		var publisher: Dictionary = item.get("publisher", {}) if typeof(item.get("publisher")) == TYPE_DICTIONARY else {}
		results.append({
			"asset": "%s/%s" % [publisher.get("slug", ""), item.get("slug", "")],
			"title": str(item.get("name", "")),
			"author": str(publisher.get("name", "")),
		})
	return { "ok": true, "error": "", "results": results }


func _fetch_release_data() -> Dictionary:
	var url := "%s/releases/%s/" % [API, asset]
	if _godot_version != "":
		url += "?compatibility=%s" % _godot_version
	var response: Dictionary = await _http.get_request(url, _headers())
	if not response["ok"]:
		return { "ok": false, "error": response["error"] }
	if response["code"] == 404:
		return { "ok": false, "error": "Asset %s not found in the Asset Store." % asset }
	if response["code"] != 200:
		return { "ok": false, "error": "The Asset Store answered with code %d." % response["code"] }
	var data: Variant = JSON.parse_string((response["body"] as PackedByteArray).get_string_from_utf8())
	if typeof(data) != TYPE_ARRAY:
		return { "ok": false, "error": "Unexpected Asset Store answer for %s." % asset }
	var items: Array[Dictionary] = []
	for item: Variant in data:
		if typeof(item) == TYPE_DICTIONARY:
			items.append(item)
	return { "ok": true, "error": "", "data": items }


func _headers() -> PackedStringArray:
	return PackedStringArray(["User-Agent: %s" % USER_AGENT])
