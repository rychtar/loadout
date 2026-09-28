@tool
class_name LoadoutGithubSource
extends LoadoutSource

## Plugin published as GitHub Releases. Versions come from release tags (v1.2.3, 1.2.3, name-1.2.3),
## the package is the release's zip asset (preferably named after the plugin folder) or the
## source zip of the tag. Releases are listed with an ETag, a 304 answer does not count against
## the 60 requests/hour limit. An optional token (Editor Settings) raises the limit; it is sent
## only to api.github.com when listing releases, never with downloads (they redirect to other hosts).

const Zip := preload("../util/zip.gd")
const Fs := preload("../util/fs.gd")

const API := "https://api.github.com"
const PER_PAGE := 50
const MAX_NOTES := 4000
const USER_AGENT := "Loadout (Godot editor plugin)"
const _TAG_VERSION_PATTERN := "(\\d+(?:\\.\\d+){0,2}(?:-[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?)$"

var repo: String
var folder: String
var _http: LoadoutHttp
var _token_provider: Callable


## token_provider: func() -> String, read for every request so a changed setting applies at once.
func _init(repository: String, plugin_folder: String, http: LoadoutHttp, token_provider: Callable = Callable()) -> void:
	repo = repository
	folder = plugin_folder
	_http = http
	_token_provider = token_provider


func describe() -> String:
	return "GitHub · %s" % repo


func is_remote() -> bool:
	return true


func cache_key() -> String:
	return "github:%s" % repo


func list_releases(etag: String = "") -> Dictionary:
	var result := { "ok": false, "error": "", "not_modified": false, "etag": etag, "releases": [] }
	var headers := _api_headers()
	if etag != "":
		headers.append("If-None-Match: %s" % etag)
	var response: Dictionary = await _http.get_request("%s/repos/%s/releases?per_page=%d" % [API, repo, PER_PAGE], headers)
	if not response["ok"]:
		result["error"] = response["error"]
		return result
	var code: int = response["code"]
	var response_headers: Dictionary = response["headers"]
	if code == 304:
		result["ok"] = true
		result["not_modified"] = true
		return result
	if code != 200:
		result["error"] = _status_error(code, response_headers)
		return result
	var data: Variant = JSON.parse_string((response["body"] as PackedByteArray).get_string_from_utf8())
	if typeof(data) != TYPE_ARRAY:
		result["error"] = "Unexpected GitHub answer for %s." % repo
		return result
	var list: Array[Dictionary] = []
	for item: Variant in data:
		if typeof(item) == TYPE_DICTIONARY:
			var release := _parse_release(item)
			if not release.is_empty():
				list.append(release)
	result["ok"] = true
	result["etag"] = str(response_headers.get("etag", ""))
	result["releases"] = list
	return result


func fetch(version: String, dest_dir: String) -> Dictionary:
	var release := get_release(version)
	if release.is_empty():
		return { "ok": false, "error": "Release %s of %s is unknown, check for updates." % [version, repo], "path": "" }
	var url := str(release.get("download_url", ""))
	var response: Dictionary = await _http.get_request(url, PackedStringArray(["User-Agent: %s" % USER_AGENT]))
	if not response["ok"]:
		return { "ok": false, "error": response["error"], "path": "" }
	if response["code"] != 200:
		return { "ok": false, "error": "Download of %s failed: %s" % [url, _status_error(response["code"], response["headers"])], "path": "" }
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
	return { "ok": true, "error": "", "path": dest_dir, "warning": folder_warning(extracted["source_folder"], folder) }


func _parse_release(item: Dictionary) -> Dictionary:
	if item.get("draft", false):
		return {}
	var tag := str(item.get("tag_name", ""))
	var found := RegEx.create_from_string(_TAG_VERSION_PATTERN).search(tag)
	var version := LoadoutVersion.parse(found.get_string(1)) if found != null else null
	if version == null:
		return {}
	var notes := str(item.get("body", "") if item.get("body") != null else "")
	if notes.length() > MAX_NOTES:
		notes = notes.left(MAX_NOTES) + "…"
	return {
		"version": str(version),
		"tag": tag,
		"prerelease": bool(item.get("prerelease", false)) or version.is_prerelease(),
		"notes": notes,
		"url": str(item.get("html_url", "")),
		"download_url": _package_url(item),
	}


## The release's zip asset (one named after the plugin folder wins), else the tag's source zip.
func _package_url(item: Dictionary) -> String:
	var zips: Array[Dictionary] = []
	for asset: Variant in item.get("assets", []):
		if typeof(asset) == TYPE_DICTIONARY and str(asset.get("name", "")).to_lower().ends_with(".zip"):
			zips.append(asset)
	for asset in zips:
		if str(asset["name"]).to_lower().contains(folder.to_lower()):
			return str(asset.get("browser_download_url", ""))
	if zips.size() == 1:
		return str(zips[0].get("browser_download_url", ""))
	return str(item.get("zipball_url", ""))


func _api_headers() -> PackedStringArray:
	var headers := PackedStringArray([
		"User-Agent: %s" % USER_AGENT,
		"Accept: application/vnd.github+json",
		"X-GitHub-Api-Version: 2022-11-28",
	])
	var token := str(_token_provider.call()).strip_edges() if _token_provider.is_valid() else ""
	if token != "":
		headers.append("Authorization: Bearer %s" % token)
	return headers


func _status_error(code: int, headers: Dictionary) -> String:
	if (code == 403 or code == 429) and str(headers.get("x-ratelimit-remaining", "")) == "0":
		return "GitHub API rate limit reached (60 requests per hour), trying again later."
	match code:
		404:
			return "Repository %s or release not found." % repo
		401:
			return "GitHub rejected the token from Editor Settings (loadout/github_token), check it."
		403:
			return "GitHub denied access to %s (code %d)." % [repo, code]
	return "GitHub answered with code %d." % code
