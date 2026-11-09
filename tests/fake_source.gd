extends LoadoutSource
## Source backed by fixture folders: { "1.0.0": "res://tests/fixtures/addons/fake_a/1.0.0", ... }.
## Acts like a remote source (cached by the update checker) when remote is true.

var versions: Dictionary[String, String] = {}
var remote := false
var fetched: PackedStringArray = []
## list_releases() behaviour and bookkeeping.
var list_calls := 0
var etag := ""
var last_etag := ""
var not_modified := false
var fail_list := ""
## Frames list_releases() waits before it answers, like a request in flight.
var list_delay_frames := 0
var notes := {}
## Folder name the "package" uses, reported by fetch() like the remote sources do.
var package_folder := ""


func _init(fixture_versions: Dictionary[String, String] = {}) -> void:
	versions = fixture_versions


func describe() -> String:
	return "Fake"


func is_remote() -> bool:
	return remote


func cache_key() -> String:
	return "fake:fake_a"


func list_releases(previous_etag: String = "") -> Dictionary:
	list_calls += 1
	last_etag = previous_etag
	for i in list_delay_frames:
		await (Engine.get_main_loop() as SceneTree).process_frame
	if fail_list != "":
		return { "ok": false, "error": fail_list, "not_modified": false, "etag": "", "releases": [] }
	if not_modified:
		return { "ok": true, "error": "", "not_modified": true, "etag": etag, "releases": [] }
	var list: Array[Dictionary] = []
	for version in versions:
		list.append({ "version": version, "tag": "v" + version, "prerelease": false,
				"notes": notes.get(version, ""), "url": "https://example.com/" + version, "download_url": "" })
	return { "ok": true, "error": "", "not_modified": false, "etag": etag, "releases": list }


func has_version(version: String) -> bool:
	return versions.has(version)


func fetch(version: String, dest_dir: String) -> Dictionary:
	fetched.append(version)
	if not versions.has(version):
		return { "ok": false, "error": "Version %s does not exist." % version, "path": "" }
	var err := Fs.copy_dir(versions[version], dest_dir)
	if err != OK:
		return { "ok": false, "error": error_string(err), "path": "" }
	return { "ok": true, "error": "", "path": dest_dir, "package_folder": package_folder }
