@tool
class_name LoadoutAssetlibSource
extends LoadoutSource

## Plugin from the Godot Asset Library (godotengine.org/asset-library). The library only offers
## the asset's current version; its version_string is used as the version (lenient semver), with
## the edit counter "0.0.<version>" as fallback for free-form strings. The download is usually a
## repository zip, the plugin folder is picked from it like for GitHub source zips.

const API := "https://godotengine.org/asset-library/api"
const ASSET_PAGE := "https://godotengine.org/asset-library/asset/%s"
const SEARCH_RESULTS := 20

var asset_id: String
var folder: String
var _http: LoadoutHttp
var _info: Dictionary = {}


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
	var response: Dictionary = await _http.get_json("%s/asset/%s" % [API, asset_id], default_headers())
	if not response["ok"]:
		return listing_error(response["error"])
	if response["code"] == 404:
		return listing_error("Asset #%s not found in the Asset Library (code 404)." % asset_id)
	if response["code"] != 200:
		return listing_error("The Asset Library answered with code %d." % response["code"])
	var asset: Variant = response["data"]
	if typeof(asset) != TYPE_DICTIONARY:
		return listing_error("Unexpected Asset Library answer for #%s." % asset_id)
	if str(asset.get("type", "addon")) != "addon":
		return listing_error("Asset #%s is a project, not a plugin." % asset_id)
	var download_url := str(asset.get("download_url", ""))
	if download_url == "":
		return listing_error("Asset #%s has no download link." % asset_id)
	var version_text := str(asset.get("version_string", ""))
	var version := LoadoutVersion.parse(version_text)
	var version_string := str(version) if version != null else "0.0.%d" % str(asset.get("version", "0")).to_int()
	return { "ok": true, "error": "", "not_modified": false, "etag": "", "releases": [{
		"version": version_string,
		"tag": version_text,
		"prerelease": version != null and version.is_prerelease(),
		"notes": trim_notes(asset.get("description")),
		"url": ASSET_PAGE % asset_id,
		"download_url": download_url,
		"sha256": str(asset.get("download_hash", "")).to_lower(),
		"title": str(asset.get("title", "")),
		"godot_version": str(asset.get("godot_version", "")),
	}] }


func get_info() -> Dictionary:
	if not _info.is_empty():
		return _info
	var response: Dictionary = await _http.get_json("%s/asset/%s" % [API, asset_id], default_headers())
	if not response["ok"]:
		return info_error(response["error"])
	if response["code"] != 200 or typeof(response["data"]) != TYPE_DICTIONARY:
		return info_error("The Asset Library answered with code %d." % response["code"])
	var data: Dictionary = response["data"]
	_info = info_result(str(data.get("description", "")), str(data.get("author", "")), str(data.get("cost", "")), ASSET_PAGE % asset_id)
	return _info


func fetch(version: String, dest_dir: String) -> Dictionary:
	var release := get_release(version)
	if release.is_empty():
		return fetch_error("The Asset Library only offers the current version of asset #%s, not %s." % [asset_id, version])
	var response: Dictionary = await _download(_http, str(release.get("download_url", "")))
	if not response["ok"]:
		return response
	var body: PackedByteArray = response["body"]
	var expected := str(release.get("sha256", ""))
	if expected != "":
		var context := HashingContext.new()
		context.start(HashingContext.HASH_SHA256)
		context.update(body)
		if context.finish().hex_encode() != expected:
			return fetch_error("The download does not match the SHA-256 listed in the Asset Library.")
	return _save_and_extract(body, folder, dest_dir)


## Searches add-ons for the given Godot version ("4.5"). Returns { "ok", "error",
## "results": [{ "asset_id", "title", "author", "version_string", "godot_version", "category" }] }.
static func search(http: LoadoutHttp, query: String, godot_version: String) -> Dictionary:
	var text := query.strip_edges()
	if text == "":
		return search_error("Enter what to search for.")
	var url := "%s/asset?type=addon&filter=%s&godot_version=%s&max_results=%d" % [API, text.uri_encode(), godot_version, SEARCH_RESULTS]
	var response: Dictionary = await http.get_json(url, default_headers())
	if not response["ok"]:
		return search_error(response["error"])
	if response["code"] != 200:
		return search_error("The Asset Library answered with code %d." % response["code"])
	var data: Variant = response["data"]
	if typeof(data) != TYPE_DICTIONARY or typeof(data.get("result")) != TYPE_ARRAY:
		return search_error("Unexpected Asset Library answer.")
	var results: Array[Dictionary] = []
	for item: Variant in data["result"]:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var entry := {}
		for key in ["asset_id", "title", "author", "version_string", "godot_version", "category"]:
			entry[key] = str(item.get(key, ""))
		results.append(entry)
	return { "ok": true, "error": "", "results": results }

