@tool
class_name LoadoutAssetlibSource
extends LoadoutSource

## Plugin from the Godot Asset Library (godotengine.org/asset-library). The library only offers
## the asset's current version; its version_string is used as the version (lenient semver), with
## the edit counter "0.0.<version>" as fallback for free-form strings. The download is usually a
## repository zip, the plugin folder is picked from it like for GitHub source zips.

const API := "https://godotengine.org/asset-library/api"
const ASSET_PAGE := "https://godotengine.org/asset-library/asset/%s"
const USER_AGENT := "Loadout (Godot editor plugin)"
const MAX_NOTES := 4000
const SEARCH_RESULTS := 20

var asset_id: String
var folder: String
var _http: LoadoutHttp


func _init(id: String, plugin_folder: String, http: LoadoutHttp) -> void:
	asset_id = id
	folder = plugin_folder
	_http = http


func describe() -> String:
	var title := get_plugin_name()
	return "Asset Library · %s" % (title if title != "" else "#" + asset_id)


func get_plugin_name() -> String:
	return str(releases[0].get("title", "")) if not releases.is_empty() else ""


func is_remote() -> bool:
	return true


func cache_key() -> String:
	return "assetlib:%s" % asset_id


func list_releases(_etag: String = "") -> Dictionary:
	var result := { "ok": false, "error": "", "not_modified": false, "etag": "", "releases": [] }
	var response: Dictionary = await _http.get_request("%s/asset/%s" % [API, asset_id], _headers())
	if not response["ok"]:
		result["error"] = response["error"]
		return result
	if response["code"] != 200:
		result["error"] = "Asset #%s not found in the Asset Library (code %d)." % [asset_id, response["code"]] \
				if response["code"] == 404 else "The Asset Library answered with code %d." % response["code"]
		return result
	var asset: Variant = JSON.parse_string((response["body"] as PackedByteArray).get_string_from_utf8())
	if typeof(asset) != TYPE_DICTIONARY:
		result["error"] = "Unexpected Asset Library answer for #%s." % asset_id
		return result
	if str(asset.get("type", "addon")) != "addon":
		result["error"] = "Asset #%s is a project, not a plugin." % asset_id
		return result
	var download_url := str(asset.get("download_url", ""))
	if download_url == "":
		result["error"] = "Asset #%s has no download link." % asset_id
		return result
	var version_text := str(asset.get("version_string", ""))
	var version := LoadoutVersion.parse(version_text)
	var version_string := str(version) if version != null else "0.0.%d" % str(asset.get("version", "0")).to_int()
	var notes := str(asset.get("description", ""))
	if notes.length() > MAX_NOTES:
		notes = notes.left(MAX_NOTES) + "…"
	result["ok"] = true
	result["releases"] = [{
		"version": version_string,
		"tag": version_text,
		"prerelease": version != null and version.is_prerelease(),
		"notes": notes,
		"url": ASSET_PAGE % asset_id,
		"download_url": download_url,
		"sha256": str(asset.get("download_hash", "")).to_lower(),
		"title": str(asset.get("title", "")),
		"godot_version": str(asset.get("godot_version", "")),
	}]
	return result


func fetch(version: String, dest_dir: String) -> Dictionary:
	var release := get_release(version)
	if release.is_empty():
		return { "ok": false, "error": "The Asset Library only offers the current version of asset #%s, not %s." % [asset_id, version], "path": "" }
	var url := str(release.get("download_url", ""))
	var response: Dictionary = await _http.get_request(url, _headers())
	if not response["ok"]:
		return { "ok": false, "error": response["error"], "path": "" }
	if response["code"] != 200:
		return { "ok": false, "error": "Download of %s failed (code %d)." % [url, response["code"]], "path": "" }
	var body: PackedByteArray = response["body"]
	var expected := str(release.get("sha256", ""))
	if expected != "":
		var context := HashingContext.new()
		context.start(HashingContext.HASH_SHA256)
		context.update(body)
		if context.finish().hex_encode() != expected:
			return { "ok": false, "error": "The download does not match the SHA-256 listed in the Asset Library.", "path": "" }
	return _save_and_extract(body, folder, dest_dir)


## Searches add-ons for the given Godot version ("4.5"). Returns { "ok", "error",
## "results": [{ "asset_id", "title", "author", "version_string", "godot_version", "category" }] }.
static func search(http: LoadoutHttp, query: String, godot_version: String) -> Dictionary:
	var text := query.strip_edges()
	if text == "":
		return { "ok": false, "error": "Enter what to search for.", "results": [] }
	var url := "%s/asset?type=addon&filter=%s&godot_version=%s&max_results=%d" % [API, text.uri_encode(), godot_version, SEARCH_RESULTS]
	var response: Dictionary = await http.get_request(url, PackedStringArray(["User-Agent: %s" % USER_AGENT]))
	if not response["ok"]:
		return { "ok": false, "error": response["error"], "results": [] }
	if response["code"] != 200:
		return { "ok": false, "error": "The Asset Library answered with code %d." % response["code"], "results": [] }
	var data: Variant = JSON.parse_string((response["body"] as PackedByteArray).get_string_from_utf8())
	if typeof(data) != TYPE_DICTIONARY or typeof(data.get("result")) != TYPE_ARRAY:
		return { "ok": false, "error": "Unexpected Asset Library answer.", "results": [] }
	var results: Array[Dictionary] = []
	for item: Variant in data["result"]:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var entry := {}
		for key in ["asset_id", "title", "author", "version_string", "godot_version", "category"]:
			entry[key] = str(item.get(key, ""))
		results.append(entry)
	return { "ok": true, "error": "", "results": results }


func _headers() -> PackedStringArray:
	return PackedStringArray(["User-Agent: %s" % USER_AGENT])
