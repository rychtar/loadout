extends "res://tests/test_case.gd"

const AssetlibSource := preload("res://addons/loadout/sources/assetlib_source.gd")
const FakeHttp := preload("res://tests/fake_http.gd")

const API := "https://godotengine.org/asset-library/api"
const ASSET_URL := API + "/asset/1586"
const ZIP_URL := "https://github.com/owner/fake-a/archive/6a3bfa86.zip"
const FIXTURE := "res://tests/fixtures/addons/fake_a/1.1.0"

var http: FakeHttp
var source: AssetlibSource


func _setup() -> void:
	http = FakeHttp.new()
	source = AssetlibSource.new("1586", "fake_a", http)


func _asset(extra: Dictionary = {}) -> Dictionary:
	var asset := {
		"asset_id": "1586", "type": "addon", "title": "Fake A", "author": "someone", "version": "7",
		"version_string": "1.1", "godot_version": "4.5", "download_provider": "GitHub",
		"download_commit": "6a3bfa86", "download_url": ZIP_URL, "download_hash": "",
		"browse_url": "https://github.com/owner/fake-a", "description": "Popis assetu.",
	}
	asset.merge(extra, true)
	return asset


func _zip_bytes(name: String) -> PackedByteArray:
	var dir := temp_dir("assetlib_zip_" + name)
	make_zip(FIXTURE, dir.path_join("asset.zip"), "fake-a-6a3bfa86/addons/fake_a/")
	return FileAccess.get_file_as_bytes(dir.path_join("asset.zip"))


func test_lists_the_current_version() -> void:
	_setup()
	http.respond_json(ASSET_URL, _asset())
	var result: Dictionary = await source.list_releases()
	check(result["ok"], "ok: %s" % result["error"])
	check_eq(result["releases"].size(), 1, "Asset Library only knows the current version")
	var release: Dictionary = result["releases"][0]
	check_eq(release["version"], "1.1.0", "version_string normalized")
	check_eq(release["tag"], "1.1", "original version string")
	check_eq(release["download_url"], ZIP_URL, "download url")
	check_eq(release["url"], "https://godotengine.org/asset-library/asset/1586", "asset page")
	check_eq(release["title"], "Fake A", "title")
	check(http.header_of(0, "User-Agent") != "", "user agent")


func test_non_semver_version_string_falls_back_to_edit_counter() -> void:
	_setup()
	http.respond_json(ASSET_URL, _asset({ "version_string": "2023 edition", "version": "12" }))
	var result: Dictionary = await source.list_releases()
	check(result["ok"], "still usable")
	check_eq(result["releases"][0]["version"], "0.0.12", "edit counter as version")
	check_eq(result["releases"][0]["tag"], "2023 edition", "original text kept for the dock")


func test_describe_and_name_after_listing() -> void:
	_setup()
	check_eq(source.describe(), "Asset Library · #1586", "before listing")
	http.respond_json(ASSET_URL, _asset())
	source.releases.assign((await source.list_releases())["releases"])
	check_eq(source.describe(), "Asset Library · Fake A", "with title")
	check_eq(source.get_plugin_name(), "Fake A", "plugin name")
	check_eq(source.cache_key(), "assetlib:1586", "cache key")
	check(source.is_remote(), "remote")


func test_errors() -> void:
	_setup()
	http.responses[ASSET_URL] = { "code": 404, "body": "{}" }
	check(not (await source.list_releases())["ok"], "unknown asset")
	http.respond_json(ASSET_URL, _asset({ "download_url": "" }))
	check(not (await source.list_releases())["ok"], "asset without download")
	http.respond_json(ASSET_URL, _asset({ "type": "project" }))
	check(not (await source.list_releases())["ok"], "projects are not plugins")


func test_fetch_extracts_plugin() -> void:
	_setup()
	http.respond_json(ASSET_URL, _asset())
	source.releases.assign((await source.list_releases())["releases"])
	http.responses[ZIP_URL] = { "code": 200, "body": _zip_bytes("fetch") }
	var dest := temp_dir("assetlib_fetch").path_join("staged")
	var result: Dictionary = await source.fetch("1.1.0", dest)
	check(result["ok"], "ok: %s" % result["error"])
	check_eq(Fs.hash_dir(dest), Fs.hash_dir(FIXTURE), "plugin folder from the repository zip")


func test_fetch_checks_download_hash() -> void:
	_setup()
	var bytes := _zip_bytes("hash")
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	var good := context.finish().hex_encode()
	http.responses[ZIP_URL] = { "code": 200, "body": bytes }
	source.releases = [{ "version": "1.1.0", "download_url": ZIP_URL, "sha256": good }]
	check((await source.fetch("1.1.0", temp_dir("assetlib_hash_ok").path_join("staged")))["ok"], "matching hash")
	source.releases = [{ "version": "1.1.0", "download_url": ZIP_URL, "sha256": "00" + good.substr(2) }]
	var bad: Dictionary = await source.fetch("1.1.0", temp_dir("assetlib_hash_bad").path_join("staged"))
	check(not bad["ok"], "hash mismatch refused")
	check(str(bad["error"]).contains("SHA-256"), "explains: %s" % bad["error"])


func test_search() -> void:
	_setup()
	var url := API + "/asset?type=addon&filter=fake%20a&godot_version=4.5&max_results=20"
	http.respond_json(url, { "result": [
		{ "asset_id": "1586", "title": "Fake A", "author": "someone", "version_string": "1.1", "godot_version": "4.5", "category": "Tools" },
	], "page": 0, "pages": 1, "total_items": 1 })
	var result: Dictionary = await AssetlibSource.search(http, "fake a", "4.5")
	check(result["ok"], "ok: %s" % result["error"])
	check_eq(result["results"].size(), 1, "one result")
	check_eq(result["results"][0]["asset_id"], "1586", "id")
	check_eq(result["results"][0]["title"], "Fake A", "title")
	var empty: Dictionary = await AssetlibSource.search(http, "  ", "4.5")
	check(not empty["ok"], "empty query is not sent")
	check_eq(http.requests.size(), 1, "only one request")
