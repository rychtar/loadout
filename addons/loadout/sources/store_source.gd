@tool
class_name LoadoutStoreSource
extends LoadoutSource

## Plugin from the Godot Asset Store (store.godotengine.org, public API v1), the store of Godot 4.7+.
## Releases are listed for the running Godot version. Download links are signed and expire after
## a few minutes, so they are never cached: fetch() asks for the release list again right before
## downloading. Paid assets (no public download link) are not supported.

const API := "https://store.godotengine.org/api/v1"
const ASSET_PAGE := "https://store.godotengine.org/asset/%s/"
const SEARCH_RESULTS := 20

## "publisher/slug"
var asset: String
var folder: String
var _http: LoadoutHttp
var _godot_version: String
var _info: Dictionary = {}


func _init(asset_path: String, plugin_folder: String, http: LoadoutHttp, godot_version: String = "") -> void:
	asset = asset_path
	folder = plugin_folder
	_http = http
	_godot_version = godot_version


func describe() -> String:
	return "Asset Store · %s" % asset


func is_remote() -> bool:
	return true


## The release list depends on the Godot version (compatibility filter).
func cache_key() -> String:
	return "store:%s" % asset if _godot_version == "" else "store:%s@%s" % [asset, _godot_version]


func list_releases(_etag: String = "") -> Dictionary:
	var answer := await _fetch_release_data()
	if not answer["ok"]:
		return listing_error(answer["error"])
	var list: Array[Dictionary] = []
	for item: Dictionary in answer["data"]:
		var tag := str(item.get("version", ""))
		var version := LoadoutVersion.parse(tag)
		if version == null:
			continue
		var notes := trim_notes(item.get("notes"))
		if notes == "":
			notes = trim_notes(bbcode_to_text(item.get("changes_bbcode")))
		list.append({
			"version": str(version),
			"tag": tag,
			"prerelease": not json_bool(item.get("stable"), true) or version.is_prerelease(),
			"notes": notes,
			"url": ASSET_PAGE % asset,
			"download_url": "",
			"release_id": json_int(item.get("id"), 0),
		})
	return { "ok": true, "error": "", "not_modified": false, "etag": "", "releases": list }


func get_info() -> Dictionary:
	if not _info.is_empty():
		return _info
	var response: Dictionary = await _http.get_json("%s/assets/%s/" % [API, asset], default_headers())
	if not response["ok"]:
		return info_error(response["error"])
	if response["code"] != 200 or typeof(response["data"]) != TYPE_DICTIONARY:
		return info_error("The Asset Store answered with code %d." % response["code"])
	var data: Dictionary = response["data"]
	var publisher: Dictionary = data.get("publisher", {}) if typeof(data.get("publisher")) == TYPE_DICTIONARY else {}
	_info = info_result(str(data.get("description", "") if data.get("description") != null else ""),
			str(publisher.get("name", "")), str(data.get("license_type", "") if data.get("license_type") != null else ""),
			ASSET_PAGE % asset)
	return _info


func fetch(version: String, dest_dir: String) -> Dictionary:
	var release := get_release(version)
	if release.is_empty():
		return fetch_error("Release %s of %s is unknown, check for updates." % [version, asset])
	# Signed links expire, ask for a fresh one.
	var answer := await _fetch_release_data()
	if not answer["ok"]:
		return fetch_error(answer["error"])
	var current: Dictionary = {}
	for item: Dictionary in answer["data"]:
		if json_int(item.get("id"), -1) == json_int(release.get("release_id"), -2):
			current = item
			break
	if current.is_empty():
		return fetch_error("The Asset Store no longer offers %s %s." % [asset, version])
	var url := "" if current.get("download_url") == null else str(current["download_url"])
	if url == "":
		return fetch_error("%s %s has no public download (paid assets are not supported)." % [asset, version])
	var response: Dictionary = await _download(_http, url)
	return _save_and_extract(response["body"], folder, dest_dir) if response["ok"] else response


## The store writes release notes as BBCode ([ul], [code], [url=…]). Plain text for the dock: list
## items get a bullet, links keep their address, other tags are dropped.
static func bbcode_to_text(value: Variant) -> String:
	var text := "" if value == null else str(value)
	var tags := RegEx.create_from_string("(?i)\\[/?(?:ul|ol|b|i|u|s|code|codeblock|center|color|font|size|h[1-6]|quote|img)(?:=[^\\]]*)?\\]")
	var links := RegEx.create_from_string("(?is)\\[url=([^\\]]+)\\](.*?)\\[/url\\]")
	var bare_links := RegEx.create_from_string("(?is)\\[url\\](.*?)\\[/url\\]")
	text = links.sub(text, "$2 ($1)", true)
	text = bare_links.sub(text, "$1", true)
	text = text.replace("[li]", "• ").replace("[/li]", "")
	text = tags.sub(text, "", true)
	var blank_lines := RegEx.create_from_string("\\n{3,}")
	return blank_lines.sub(text, "\n\n", true).strip_edges()


## Searches free add-ons for the given Godot version ("4.7"). Returns { "ok", "error",
## "results": [{ "asset": "publisher/slug", "title", "author" }] }.
static func search(http: LoadoutHttp, query: String, godot_version: String) -> Dictionary:
	var text := query.strip_edges()
	if text == "":
		return search_error("Enter what to search for.")
	var url := "%s/search/query/?type=0&query=%s" % [API, text.uri_encode()]
	if godot_version != "":
		url += "&compatibility=%s" % godot_version
	url += "&batch_size=%d" % SEARCH_RESULTS
	var response: Dictionary = await http.get_json(url, default_headers())
	if not response["ok"]:
		return search_error(response["error"])
	if response["code"] != 200:
		return search_error("The Asset Store answered with code %d." % response["code"])
	var data: Variant = response["data"]
	if typeof(data) != TYPE_DICTIONARY or typeof(data.get("hits")) != TYPE_ARRAY:
		return search_error("Unexpected Asset Store answer.")
	var results: Array[Dictionary] = []
	for hit: Variant in data["hits"]:
		if typeof(hit) != TYPE_DICTIONARY or typeof(hit.get("asset")) != TYPE_DICTIONARY:
			continue
		var item: Dictionary = hit["asset"]
		if json_int(item.get("price_cent"), 0) > 0:
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
	var response: Dictionary = await _http.get_json(url, default_headers())
	if not response["ok"]:
		return { "ok": false, "error": response["error"] }
	if response["code"] == 404:
		return { "ok": false, "error": "Asset %s not found in the Asset Store." % asset }
	if response["code"] != 200:
		return { "ok": false, "error": "The Asset Store answered with code %d." % response["code"] }
	var data: Variant = response["data"]
	if typeof(data) != TYPE_ARRAY:
		return { "ok": false, "error": "Unexpected Asset Store answer for %s." % asset }
	var items: Array[Dictionary] = []
	for item: Variant in data:
		if typeof(item) == TYPE_DICTIONARY:
			items.append(item)
	return { "ok": true, "error": "", "data": items }

