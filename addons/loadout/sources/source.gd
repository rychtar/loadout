@tool
class_name LoadoutSource
extends RefCounted

## Where a plugin comes from. Subclasses may await (network); callers always await the methods.
## Only sources/ talks to the network, core/ never does.
##
const Zip := preload("../util/zip.gd")
const Fs := preload("../util/fs.gd")

const USER_AGENT := "Loadout (Godot editor plugin)"

## Remote sources list their releases with list_releases(); LoadoutUpdateChecker caches that list
## (once a day, ETag) and puts it into `releases`, which the other methods then use.

## Known releases, newest first: [{ "version": "1.2.0", "tag": "v1.2.0", "prerelease": bool,
## "notes": String, "url": String (release page), "download_url": String }]
var releases: Array[Dictionary] = []


## Human readable description for the dock, e.g. "GitHub · bitwes/Gut".
func describe() -> String:
	return ""


## Remote sources are cached and throttled by the update checker, local ones are read every time.
func is_remote() -> bool:
	return false


## Key of this source in loadout_cache.json, e.g. "github:bitwes/Gut".
func cache_key() -> String:
	return ""


## Lists available releases. etag of the previous answer allows a cheap "not modified" reply.
## Returns { "ok", "error", "not_modified": bool, "etag": String, "releases": Array[Dictionary] }.
func list_releases(_etag: String = "") -> Dictionary:
	return { "ok": false, "error": "The source cannot list versions.", "not_modified": false, "etag": "", "releases": [] }


## Highest known version within version_range.
## Returns { "ok": bool, "error": String, "version": String }.
func get_latest_version(version_range: String) -> Dictionary:
	var versions: PackedStringArray = []
	for release in releases:
		versions.append(str(release.get("version", "")))
	var best := LoadoutVersion.max_satisfying(versions, version_range)
	if best == "":
		var error := "The source has no version." if versions.is_empty() else "No version matches range %s." % version_range
		return { "ok": false, "error": error, "version": "" }
	return { "ok": true, "error": "", "version": best }


## Whether fetch(version) can deliver exactly this version (used to reinstall the locked version).
func has_version(version: String) -> bool:
	return not get_release(version).is_empty()


## Release record of version from `releases`, {} when unknown.
func get_release(version: String) -> Dictionary:
	for release in releases:
		if release.get("version", "") == version:
			return release
	return {}


## Plugin name from the source's plugin.cfg, "" when the source does not know it without fetching.
func get_plugin_name() -> String:
	return ""


## Puts the plugin folder content of version into dest_dir (created by the source).
## Returns { "ok": bool, "error": String, "path": String, "package_folder": String (optional, the
## plugin's folder name inside the package), "warning": String (optional) } where path holds plugin.cfg.
func fetch(_version: String, _dest_dir: String) -> Dictionary:
	return { "ok": false, "error": "The source cannot download.", "path": "" }


## Headers every request to a remote source carries.
static func default_headers() -> PackedStringArray:
	return PackedStringArray(["User-Agent: %s" % USER_AGENT])


## Shared by the remote sources: saves a downloaded zip, extracts the plugin folder into dest_dir and
## returns the fetch() result.
func _save_and_extract(body: PackedByteArray, plugin_folder: String, dest_dir: String) -> Dictionary:
	var zip_path := dest_dir.trim_suffix("/") + ".zip"
	DirAccess.make_dir_recursive_absolute(zip_path.get_base_dir())
	var file := FileAccess.open(zip_path, FileAccess.WRITE)
	if file == null:
		return { "ok": false, "error": "Cannot save the zip: %s" % error_string(FileAccess.get_open_error()), "path": "" }
	file.store_buffer(body)
	var write_error := file.get_error()
	file.close()
	if write_error != OK:
		DirAccess.remove_absolute(zip_path)
		return { "ok": false, "error": "Cannot save the zip: %s" % error_string(write_error), "path": "" }
	var extracted := Zip.extract_plugin(zip_path, plugin_folder, dest_dir)
	DirAccess.remove_absolute(zip_path)
	if not extracted["ok"]:
		Fs.remove_dir(dest_dir)
		return { "ok": false, "error": extracted["error"], "path": "" }
	return { "ok": true, "error": "", "path": dest_dir, "package_folder": extracted["source_folder"],
			"warning": folder_warning(extracted["source_folder"], plugin_folder) }


## Warning when the package keeps the plugin in another folder than the registry entry: plugins
## with hard-coded res://addons/<name>/ paths break when installed under a different name.
static func folder_warning(package_folder: String, registry_folder: String) -> String:
	if package_folder == "" or package_folder == registry_folder:
		return ""
	return "The package keeps the plugin in folder '%s', the registry says '%s'. If the plugin uses fixed paths like res://addons/%s/, fix the folder in the registry." % [package_folder, registry_folder, package_folder]


## Source for a registry entry, null for types not supported yet. Remote sources need http;
## github_token: func() -> String (optional); godot_version "4.7" limits store releases.
static func create(entry: LoadoutRegistry.Entry, http: LoadoutHttp = null, github_token: Callable = Callable(),
		godot_version: String = "") -> LoadoutSource:
	match entry.source.get("type"):
		LoadoutRegistry.SOURCE_LOCAL:
			return LoadoutLocalSource.new(entry.source["path"])
		LoadoutRegistry.SOURCE_GITHUB:
			if http != null:
				return LoadoutGithubSource.new(entry.source["repo"], entry.folder, http, github_token)
		LoadoutRegistry.SOURCE_STORE:
			if http != null:
				return LoadoutStoreSource.new(entry.source["asset"], entry.folder, http, godot_version)
		LoadoutRegistry.SOURCE_ASSETLIB:
			if http != null:
				return LoadoutAssetlibSource.new(entry.source["asset_id"], entry.folder, http)
	return null
