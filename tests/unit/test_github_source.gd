extends "res://tests/test_case.gd"

const GithubSource := preload("res://addons/loadout/sources/github_source.gd")
const FakeHttp := preload("res://tests/fake_http.gd")

const RELEASES_URL := "https://api.github.com/repos/owner/fake-a/releases?per_page=50"
const ASSET_URL := "https://github.com/owner/fake-a/releases/download/v1.1.0/fake_a-1.1.0.zip"
const FIXTURE := "res://tests/fixtures/addons/fake_a/1.1.0"

var http: FakeHttp
var source: GithubSource


func _setup() -> void:
	http = FakeHttp.new()
	source = GithubSource.new("owner/fake-a", "fake_a", http)


func _release(tag: String, extra: Dictionary = {}) -> Dictionary:
	var release := {
		"tag_name": tag, "name": tag, "draft": false, "prerelease": false, "body": "Notes for %s" % tag,
		"html_url": "https://github.com/owner/fake-a/releases/tag/%s" % tag,
		"zipball_url": "https://api.github.com/repos/owner/fake-a/zipball/%s" % tag, "assets": [],
	}
	release.merge(extra, true)
	return release


func _list(etag: String = "") -> Dictionary:
	return await source.list_releases(etag)


func test_lists_releases() -> void:
	_setup()
	http.respond_json(RELEASES_URL, [
		_release("v1.1.0", { "assets": [{ "name": "fake_a-1.1.0.zip", "browser_download_url": ASSET_URL }] }),
		_release("1.0.0"),
		_release("v2.0.0-beta.1", { "prerelease": true }),
		_release("v3.0.0", { "draft": true }),
		_release("nightly"),
	], { "etag": "W/\"abc\"" })
	var result := await _list()
	check(result["ok"], "ok: %s" % result["error"])
	check_eq(result["etag"], "W/\"abc\"", "etag kept")
	var versions: PackedStringArray = []
	for release: Dictionary in result["releases"]:
		versions.append(release["version"])
	check_eq(versions, PackedStringArray(["1.1.0", "1.0.0", "2.0.0-beta.1"]), "drafts and non-version tags skipped")
	var first: Dictionary = result["releases"][0]
	check_eq(first["tag"], "v1.1.0", "tag")
	check_eq(first["download_url"], ASSET_URL, "zip asset preferred")
	check_eq(first["notes"], "Notes for v1.1.0", "notes")
	check_eq(first["url"], "https://github.com/owner/fake-a/releases/tag/v1.1.0", "page")
	check_eq((result["releases"][1] as Dictionary)["download_url"], "https://api.github.com/repos/owner/fake-a/zipball/1.0.0", "zipball fallback")
	check(result["releases"][2]["prerelease"], "prerelease flag")


func test_request_headers() -> void:
	_setup()
	http.respond_json(RELEASES_URL, [])
	await _list("W/\"old\"")
	check(http.header_of(0, "User-Agent") != "", "GitHub requires a User-Agent")
	check_eq(http.header_of(0, "Accept"), "application/vnd.github+json", "accept")
	check_eq(http.header_of(0, "If-None-Match"), "W/\"old\"", "conditional request")
	await _list()
	check_eq(http.header_of(1, "If-None-Match"), "", "no etag, no header")


func test_not_modified() -> void:
	_setup()
	http.responses[RELEASES_URL] = { "code": 304, "headers": { "etag": "W/\"abc\"" } }
	var result := await _list("W/\"abc\"")
	check(result["ok"] and result["not_modified"], "304 is fine")
	check_eq(result["etag"], "W/\"abc\"", "etag")


func test_picks_asset_by_folder_name() -> void:
	_setup()
	http.respond_json(RELEASES_URL, [_release("v1.1.0", { "assets": [
		{ "name": "demo-project.zip", "browser_download_url": "https://example.com/demo.zip" },
		{ "name": "fake_a-addon.zip", "browser_download_url": "https://example.com/addon.zip" },
		{ "name": "checksums.txt", "browser_download_url": "https://example.com/sums.txt" },
	] })])
	var result := await _list()
	check_eq(result["releases"][0]["download_url"], "https://example.com/addon.zip", "asset named after the folder")


func test_rate_limit() -> void:
	_setup()
	http.responses[RELEASES_URL] = { "code": 403, "headers": { "x-ratelimit-remaining": "0" }, "body": "{}" }
	var result := await _list()
	check(not result["ok"], "fails")
	check(str(result["error"]).contains("limit"), "explains the rate limit: %s" % result["error"])


func test_not_found_and_offline() -> void:
	_setup()
	http.responses[RELEASES_URL] = { "code": 404, "body": "{}" }
	check(not (await _list())["ok"], "404")
	http.responses[RELEASES_URL] = "Cannot connect."
	var offline := await _list()
	check(not offline["ok"] and str(offline["error"]).contains("Cannot connect"), "network error passed on")
	http.respond_json(RELEASES_URL, { "message": "not a list" })
	check(not (await _list())["ok"], "unexpected JSON")


func test_latest_version_uses_known_releases() -> void:
	_setup()
	source.releases = [
		{ "version": "1.0.0", "prerelease": false }, { "version": "1.1.0", "prerelease": false },
		{ "version": "2.0.0", "prerelease": false },
	]
	var latest: Dictionary = await source.get_latest_version("^1.0.0")
	check_eq(latest["version"], "1.1.0", "highest in range")
	check(await source.has_version("1.0.0"), "has older release")
	check(not await source.has_version("1.2.0"), "unknown release")
	var none: Dictionary = await source.get_latest_version("^5.0.0")
	check(not none["ok"], "nothing in range")


func test_fetch_downloads_and_extracts() -> void:
	_setup()
	var zip_dir := temp_dir("github_fetch_zip")
	make_zip(FIXTURE, zip_dir.path_join("asset.zip"), "fake_a/")
	http.responses[ASSET_URL] = { "code": 200, "body": FileAccess.get_file_as_bytes(zip_dir.path_join("asset.zip")) }
	source.releases = [{ "version": "1.1.0", "tag": "v1.1.0", "prerelease": false, "download_url": ASSET_URL }]
	var dest := temp_dir("github_fetch").path_join("staged")
	var result: Dictionary = await source.fetch("1.1.0", dest)
	check(result["ok"], "ok: %s" % result["error"])
	check_eq(Fs.hash_dir(result["path"]), Fs.hash_dir(FIXTURE), "plugin extracted")
	check(not FileAccess.file_exists(dest + ".zip"), "downloaded zip removed")


func test_fetch_unknown_version() -> void:
	_setup()
	var result: Dictionary = await source.fetch("9.9.9", temp_dir("github_unknown").path_join("staged"))
	check(not result["ok"], "unknown release")
	check(http.requests.is_empty(), "no download attempted")


func test_fetch_http_error() -> void:
	_setup()
	http.responses[ASSET_URL] = { "code": 500, "body": "oops" }
	source.releases = [{ "version": "1.1.0", "download_url": ASSET_URL }]
	var result: Dictionary = await source.fetch("1.1.0", temp_dir("github_500").path_join("staged"))
	check(not result["ok"], "server error")


func test_only_https() -> void:
	_setup()
	source.releases = [{ "version": "1.1.0", "download_url": "http://example.com/plain.zip" }]
	var result: Dictionary = await source.fetch("1.1.0", temp_dir("github_http").path_join("staged"))
	check(not result["ok"], "plain http refused")
	check(str(result["error"]).contains("HTTPS"), "explains: %s" % result["error"])


func test_describe_and_cache_key() -> void:
	_setup()
	check_eq(source.describe(), "GitHub · owner/fake-a", "describe")
	check_eq(source.cache_key(), "github:owner/fake-a", "cache key")
	check(source.is_remote(), "remote")
