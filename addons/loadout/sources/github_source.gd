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
## The version is the end of the tag, after the start or a separator (so "godot4-1.2.3" is 1.2.3, not 4.0.0-1.2.3).
const _TAG_VERSION_PATTERN := "(?:^|[-_/\\s])[vV]?(\\d+(?:\\.\\d+){0,2}(?:-[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?)$"

## A tag that is a single big number ("nightly-20260105", "build-2024") is a date or build number.
const MAX_BARE_MAJOR := 1000

static var _tag_regex: RegEx

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


## The chosen package depends on the plugin folder, so plugins of one repo do not share an entry.
func cache_key() -> String:
	return "github:%s#%s" % [repo, folder]


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
	for item: Variant in data:
		if typeof(item) == TYPE_DICTIONARY:
			var release := _parse_release(item)
			if not release.is_empty():
				list.append(release)
	return { "ok": true, "error": "", "not_modified": false, "etag": str(response_headers.get("etag", "")), "releases": list }


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


## The release's zip asset (one named after the plugin folder wins), else the tag's source zip.
func _package_url(item: Dictionary) -> String:
	var zips: Array[Dictionary] = []
	for asset: Variant in item.get("assets", []):
		if typeof(asset) == TYPE_DICTIONARY and str(asset.get("name", "")).to_lower().ends_with(".zip"):
			zips.append(asset)
	for asset in zips:
		if str(asset["name"]).to_lower().contains(folder.to_lower()):
			return _text(asset.get("browser_download_url"))
	if zips.size() == 1:
		return _text(zips[0].get("browser_download_url"))
	return _text(item.get("zipball_url"))


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
