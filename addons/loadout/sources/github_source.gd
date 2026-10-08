@tool
class_name LoadoutGithubSource
extends LoadoutSource

## Plugin published as GitHub Releases. Versions come from release tags (v1.2.3, 1.2.3, name-1.2.3),
## the package is the release's zip asset (preferably named after the plugin folder) or the
## source zip of the tag. Releases are listed with an ETag; with a token a 304 answer does not
## count against the rate limit (without one it does, the daily check keeps it low). An optional token (Editor Settings) raises the limit; it is sent
## only to api.github.com when listing releases, never with downloads (they redirect to other hosts).

const API := "https://api.github.com"
const PER_PAGE := 50
## Pages of releases read at most (a full page means there may be older releases, e.g. an older
## major version a range like ^1 needs).
const MAX_PAGES := 4
## The version is the end of the tag, after the start or a separator (so "godot4-1.2.3" is 1.2.3, not 4.0.0-1.2.3).
## A Godot-style stage after a dot ("v2.5.stable", "v2.5.1.rc2", "v2.6.dev2") belongs to the version too.
const _TAG_VERSION_PATTERN := "(?:^|[-_/\\s])[vV]?(\\d+(?:\\.\\d+){0,2}(?:-[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*|\\.(?:stable|(?:dev|alpha|beta|rc)\\d*))?)$"

## A tag that is a single big number ("nightly-20260105", "build-2024") is a date or build number.
const MAX_BARE_MAJOR := 1000

static var _tag_regex: RegEx

var repo: String
var folder: String
var _http: LoadoutHttp
var _token_provider: Callable
var _info: Dictionary = {}


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


## The chosen package depends on the plugin folder, so plugins of one repo do not share an entry.
func cache_key() -> String:
	return "github:%s#%s" % [repo, folder]


func get_info() -> Dictionary:
	if not _info.is_empty():
		return _info
	var response: Dictionary = await _http.get_json("%s/repos/%s" % [API, repo], _api_headers())
	if not response["ok"]:
		return info_error(response["error"])
	if response["code"] != 200 or typeof(response["data"]) != TYPE_DICTIONARY:
		return info_error(_status_error(response["code"], response["headers"]))
	var data: Dictionary = response["data"]
	var license: Dictionary = data.get("license", {}) if typeof(data.get("license")) == TYPE_DICTIONARY else {}
	var owner: Dictionary = data.get("owner", {}) if typeof(data.get("owner")) == TYPE_DICTIONARY else {}
	_info = info_result("" if data.get("description") == null else str(data["description"]), str(owner.get("login", "")),
			str(license.get("spdx_id", "")).replace("NOASSERTION", ""), "https://github.com/%s" % repo)
	return _info


func list_releases(etag: String = "") -> Dictionary:
	var headers := _api_headers()
	if etag != "":
		headers.append("If-None-Match: %s" % etag)
	var response: Dictionary = await _http.get_json("%s/repos/%s/releases?per_page=%d" % [API, repo, PER_PAGE], headers)
	if not response["ok"]:
		return listing_error(response["error"])
	var code: int = response["code"]
	var response_headers: Dictionary = response["headers"]
	if code == 304:
		return { "ok": true, "error": "", "not_modified": true, "etag": etag, "releases": [] }
	if code != 200:
		return listing_error(_status_error(code, response_headers))
	var data: Variant = response["data"]
	if typeof(data) != TYPE_ARRAY:
		return listing_error("Unexpected GitHub answer for %s." % repo)
	var list: Array[Dictionary] = []
	_append_releases(list, data)
	var next_url := _next_page_url(response_headers)
	var pages := 1
	while next_url != "" and pages < MAX_PAGES and (data as Array).size() >= PER_PAGE:
		var page: Dictionary = await _http.get_json(next_url, _api_headers())
		if not page["ok"] or page["code"] != 200 or typeof(page["data"]) != TYPE_ARRAY:
			break
		data = page["data"]
		_append_releases(list, data)
		next_url = _next_page_url(page["headers"])
		pages += 1
	return { "ok": true, "error": "", "not_modified": false, "etag": str(response_headers.get("etag", "")), "releases": list }


func _append_releases(list: Array[Dictionary], data: Array) -> void:
	for item: Variant in data:
		if typeof(item) == TYPE_DICTIONARY:
			var release := _parse_release(item)
			if not release.is_empty():
				list.append(release)


## The rel="next" address of a Link header, "" when there is none or it leaves the API host (the
## token must not go anywhere else).
func _next_page_url(headers: Dictionary) -> String:
	for part in str(headers.get("link", "")).split(","):
		if part.contains('rel="next"'):
			var url := part.get_slice(">", 0).get_slice("<", 1).strip_edges()
			return url if url.begins_with(API + "/") else ""
	return ""


func fetch(version: String, dest_dir: String) -> Dictionary:
	var release := get_release(version)
	if release.is_empty():
		return fetch_error("Release %s of %s is unknown, check for updates." % [version, repo])
	var url := str(release.get("download_url", ""))
	if url == "":
		return fetch_error("Release %s of %s has no downloadable package." % [version, repo])
	var response: Dictionary = await _download(_http, url)
	return _save_and_extract(response["body"], folder, dest_dir) if response["ok"] else response


func _parse_release(item: Dictionary) -> Dictionary:
	if item.get("draft", false):
		return {}
	var tag := str(item.get("tag_name", ""))
	if _tag_regex == null:
		_tag_regex = RegEx.create_from_string(_TAG_VERSION_PATTERN)
	var found := _tag_regex.search(tag)
	var version := LoadoutVersion.parse(found.get_string(1)) if found != null else null
	if version == null or (version.precision == 1 and version.major >= MAX_BARE_MAJOR):
		return {}
	return {
		"version": str(version),
		"tag": tag,
		"prerelease": json_bool(item.get("prerelease"), false) or version.is_prerelease(),
		"notes": trim_notes(item.get("body")),
		"url": str(item.get("html_url", "")),
		"download_url": _package_url(item),
	}


## The release's zip asset (one named after the plugin folder wins, a demo project only when there
## is nothing else), else the tag's source zip.
func _package_url(item: Dictionary) -> String:
	var zips: Array[Dictionary] = []
	for asset: Variant in item.get("assets", []):
		if typeof(asset) == TYPE_DICTIONARY and str(asset.get("name", "")).to_lower().ends_with(".zip"):
			zips.append(asset)
	var named: Array[Dictionary] = []
	for asset in zips:
		if str(asset["name"]).to_lower().contains(folder.to_lower()):
			named.append(asset)
	for asset in named:
		if not _is_demo(str(asset["name"])):
			return _text(asset.get("browser_download_url"))
	if not named.is_empty():
		return _text(named[0].get("browser_download_url"))
	if zips.size() == 1:
		return _text(zips[0].get("browser_download_url"))
	return _text(item.get("zipball_url"))


## Whether a zip is a sample project built around the plugin, not the plugin itself.
static func _is_demo(asset_name: String) -> bool:
	var lowered := asset_name.to_lower()
	return lowered.contains("demo") or lowered.contains("example") or lowered.contains("sample")


## A JSON value as text, null becomes "".
static func _text(value: Variant) -> String:
	return "" if value == null else str(value)


func _api_headers() -> PackedStringArray:
	var headers := default_headers()
	headers.append_array(["Accept: application/vnd.github+json", "X-GitHub-Api-Version: 2022-11-28"])
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
