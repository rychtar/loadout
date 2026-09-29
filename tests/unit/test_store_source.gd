extends "res://tests/test_case.gd"

const StoreSource := preload("res://addons/loadout/sources/store_source.gd")
const FakeHttp := preload("res://tests/fake_http.gd")

const API := "https://store.godotengine.org/api/v1"
const RELEASES_URL := API + "/releases/rumys/fake-a/?compatibility=4.7"
const ZIP_URL := "https://fra1.digitaloceanspaces.com/asset-store-prod/assets/1/fake-a-1.1.0.zip?X-Amz-Signature=abc"
const FIXTURE := "res://tests/fixtures/addons/fake_a/1.1.0"

var http: FakeHttp
var source: StoreSource


func _setup() -> void:
	http = FakeHttp.new()
	source = StoreSource.new("rumys/fake-a", "fake_a", http, "4.7")


func _release(id: int, version: String, stable: bool = true, url: Variant = ZIP_URL) -> Dictionary:
	return { "id": id, "version": version, "stable": stable, "min_godot_version": "4.5", "max_godot_version": null,
			"notes": "Notes %s" % version, "changes_bbcode": "", "download_url": url }


func _zip_bytes(name: String) -> PackedByteArray:
	var dir := temp_dir("store_zip_" + name)
	make_zip(FIXTURE, dir.path_join("asset.zip"), "fake-a-1.1.0/addons/fake_a/")
	return FileAccess.get_file_as_bytes(dir.path_join("asset.zip"))


func test_lists_releases() -> void:
	_setup()
	http.respond_json(RELEASES_URL, [_release(12, "v1.1.0"), _release(11, "1.0"), _release(13, "v2.0.0-beta", false), _release(10, "nightly build")])
	var result: Dictionary = await source.list_releases()
	check(result["ok"], "ok: %s" % result["error"])
	var versions: PackedStringArray = []
	for release: Dictionary in result["releases"]:
		versions.append(release["version"])
	check_eq(versions, PackedStringArray(["1.1.0", "1.0.0", "2.0.0-beta"]), "versions parsed, free text skipped")
	var first: Dictionary = result["releases"][0]
	check_eq([first["tag"], first["release_id"], first["notes"]], ["v1.1.0", 12, "Notes v1.1.0"], "release data")
	check_eq(first["url"], "https://store.godotengine.org/asset/rumys/fake-a/", "asset page")
	check_eq(first["download_url"], "", "signed download links expire, never cached")
	check(result["releases"][2]["prerelease"], "unstable release is a prerelease")
	check(http.header_of(0, "User-Agent") != "", "user agent")


func test_errors() -> void:
	_setup()
	http.responses[RELEASES_URL] = { "code": 404, "body": "{}" }
	check(not (await source.list_releases())["ok"], "unknown asset")
	http.respond_json(RELEASES_URL, { "detail": "oops" })
	check(not (await source.list_releases())["ok"], "unexpected answer")
	http.respond_json(RELEASES_URL, [])
	var empty: Dictionary = await source.list_releases()
	check(empty["ok"] and empty["releases"].is_empty(), "no compatible release is not an error of the source")


func test_fetch_asks_for_a_fresh_link() -> void:
	_setup()
	http.respond_json(RELEASES_URL, [_release(12, "v1.1.0")])
	source.releases.assign((await source.list_releases())["releases"])
	http.responses[ZIP_URL] = { "code": 200, "body": _zip_bytes("fetch") }
	var dest := temp_dir("store_fetch").path_join("staged")
	var result: Dictionary = await source.fetch("1.1.0", dest)
	check(result["ok"], "ok: %s" % result["error"])
	check_eq(http.requests[1]["url"], RELEASES_URL, "release list asked again for a fresh signed link")
	check_eq(http.requests[2]["url"], ZIP_URL, "then downloaded")
	check_eq(Fs.hash_dir(dest), Fs.hash_dir(FIXTURE), "plugin folder extracted")
	check_eq(result["package_folder"], "fake_a", "package folder reported")


func test_fetch_paid_or_gone() -> void:
	_setup()
	source.releases = [{ "version": "1.1.0", "release_id": 12 }]
	http.respond_json(RELEASES_URL, [_release(12, "v1.1.0", true, null)])
	var paid: Dictionary = await source.fetch("1.1.0", temp_dir("store_paid").path_join("staged"))
	check(not paid["ok"] and str(paid["error"]).contains("download"), "no download link: %s" % paid["error"])
	http.respond_json(RELEASES_URL, [_release(99, "v9.0.0")])
	var gone: Dictionary = await source.fetch("1.1.0", temp_dir("store_gone").path_join("staged"))
	check(not gone["ok"], "release no longer offered")


func test_describe_and_cache_key() -> void:
	_setup()
	check_eq(source.describe(), "Asset Store · rumys/fake-a", "describe")
	check_eq(source.cache_key(), "store:rumys/fake-a", "cache key")
	check(source.is_remote(), "remote")


func test_search() -> void:
	_setup()
	var url := API + "/search/query/?type=0&query=fake%20a&compatibility=4.7&batch_size=20"
	http.respond_json(url, { "count": "2", "hits": [
		{ "asset": { "slug": "fake-a", "name": "Fake A", "price_cent": 0, "publisher": { "slug": "rumys", "name": "Rumys" } } },
		{ "asset": { "slug": "paid", "name": "Paid One", "price_cent": 500, "publisher": { "slug": "x", "name": "X" } } },
	], "scroll": null })
	var result: Dictionary = await StoreSource.search(http, "fake a", "4.7")
	check(result["ok"], "ok: %s" % result["error"])
	check_eq(result["results"].size(), 1, "paid assets left out")
	check_eq(result["results"][0]["asset"], "rumys/fake-a", "publisher/slug")
	check_eq(result["results"][0]["title"], "Fake A", "name")
	check_eq(result["results"][0]["author"], "Rumys", "publisher name")
