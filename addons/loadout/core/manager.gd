@tool
class_name LoadoutManager
extends RefCounted

## Ties registry, lock, sources and installer together and keeps the state of every plugin.
## The dock only calls these methods and listens to the signals (core/ never touches UI).

const Fs := preload("../util/fs.gd")
const Log := preload("../util/log.gd")
const Package := preload("../util/package.gd")

## Loadout's own folder: it can be updated (installer.self_update + editor restart), never removed.
const SELF_FOLDER := "loadout"
## Files listed per kind in changed_files().
const MAX_DIFF_LINES := 15
## Releases the details dialog lists.
const MAX_DETAIL_VERSIONS := 30
const REGISTRY_UNREADABLE := "The registry cannot be read, nothing changed."

## Emitted after refresh() and after every action, the dock rebuilds from `states`.
signal states_changed()
## An installed or updated plugin left stale class_name entries; offer an editor restart.
signal restart_recommended()
## Files of an add-on with native code were put in place and the editor should scan them. Emitted once
## the whole action is over (scanning a new GDExtension reloads every script, which cancels whatever
## is still running).
signal scan_requested()
## Loadout replaced its own files; the editor must restart now (the dock does it).
signal restart_required()

enum Status {
	OK,          ## installed, matches the lock, no newer version in range
	MISSING,     ## in the registry, not in the project
	UPDATE,      ## newer version within the range
	MODIFIED,    ## folder differs from the lock (manual edits)
	PINNED,      ## pinned in this project
	IGNORED,     ## the project opted out of this plugin
	UNMANAGED,   ## folder exists but Loadout did not install it (not in the lock)
	UNVERIFIED,  ## installed, but the source could not be checked
	ORPHAN,      ## in the lock but no longer in the registry
}


class PluginState:
	var id: String
	var display_name: String
	## null for ORPHAN
	var entry: LoadoutRegistry.Entry
	var lock_entry: LoadoutLockfile.Entry
	var status: Status
	var installed_version: String = ""
	## Highest version in range offered by the source, "" if unknown.
	var latest_version: String = ""
	## Version install() would put in place, "" when nothing can be installed.
	var target_version: String = ""
	var source_label: String = ""
	## Why the plugin is in this state, for the dock.
	var message: String = ""
	## Source could not be checked, cached data used (shown in the dock, never blocks).
	var warning: String = ""
	## The folder in the project holds native code (a GDExtension): replaced on disk, active after a restart.
	var native: bool = false
	## Release notes and page of target_version (remote sources only).
	var release_notes: String = ""
	var release_url: String = ""


var registry: LoadoutRegistry
var lockfile: LoadoutLockfile
var installer: LoadoutInstaller
var checker: LoadoutUpdateChecker
var registry_path: String
var lock_path: String
## Problems loading the registry or the lock, shown in the dock.
var errors: PackedStringArray = []
## Non-fatal problems (skipped registry or lock entries).
var warnings: PackedStringArray = []
var states: Array[PluginState] = []
## Plugins in the project's addons folder that the registry does not know (Loadout itself excluded):
## [{ "folder": String, "name": String, "version": String }], sorted by name.
var unregistered: Array[Dictionary] = []
## Folders of unregistered plugins already known (present at the last refresh or announced).
var _seen_addons: Dictionary[String, bool] = {}
## False until the first refresh() has finished (remote sources can take a while), so the dock does
## not claim the registry is empty meanwhile.
var loaded := false
## True while an install or update runs; other actions are refused meanwhile.
var busy := false
var _scan_pending := false
## Add-ons with native code whose files were replaced or deleted while the editor runs: the old
## library stays loaded, so putting files back needs a restart, not a scan.
var _native_changed: Dictionary[String, bool] = {}
## Installs running as one batch (install_missing()): the scan waits for the last one.
var _batch_depth := 0

## Starter pack file (tests use their own).
var starter_pack_path := LoadoutStarterPack.DEFAULT_PATH

var _source_factory: Callable
var _registry_ok := false
var _lock_ok := false
## Source of every registry entry from the last refresh (holds the releases install() needs).
var _sources: Dictionary[String, LoadoutSource] = {}
## Starters of the last starter_offers(): { id: { "item": Dictionary, "entry", "source": LoadoutSource with
## its releases once asked (null before), "version": newest installable, "offer": bool } }.
var _starters: Dictionary[String, Dictionary] = {}


## source_factory: func(entry: LoadoutRegistry.Entry) -> LoadoutSource, defaults to LoadoutSource.create()
## without network. update_checker defaults to an in-memory one.
func _init(plugin_installer: LoadoutInstaller, registry_file: String, lock_file: String,
		source_factory: Callable = Callable(), update_checker: LoadoutUpdateChecker = null) -> void:
	installer = plugin_installer
	registry_path = registry_file
	lock_path = lock_file
	_source_factory = source_factory
	if not _source_factory.is_valid():
		_source_factory = func(entry: LoadoutRegistry.Entry) -> LoadoutSource: return LoadoutSource.create(entry)
	checker = update_checker if update_checker != null else LoadoutUpdateChecker.new("")
	checker.load_cache()


## Reloads registry and lock from disk and recomputes all states. Remote sources are asked at
## most once a day; check_updates forces asking them now.
func refresh(check_updates: bool = false) -> void:
	_load_files()
	var new_states: Array[PluginState] = []
	_sources.clear()
	if _registry_ok and _lock_ok:
		for entry in registry.entries:
			new_states.append(await _compute_state(entry, check_updates))
		for id in lockfile.plugins:
			if registry.get_entry(id) == null:
				new_states.append(_orphan_state(id))
	checker.save_cache()
	warnings.append_array(checker.warnings)
	states = new_states
	unregistered.assign(_scan_unregistered() if _registry_ok else [])
	for info in unregistered:
		_seen_addons[info["folder"]] = true
	loaded = true
	states_changed.emit()


## Plugins that appeared in addons/ since the last check and are not in the registry, e.g.
## installed from Godot's asset store. Each one is reported once. Reads files only.
func detect_new_addons() -> Array[Dictionary]:
	var fresh: Array[Dictionary] = []
	if not _registry_ok or busy:
		return fresh
	var current := _scan_unregistered()
	for info in current:
		if not _seen_addons.has(info["folder"]):
			fresh.append(info)
			_seen_addons[info["folder"]] = true
	if current != unregistered:
		unregistered = current
		states_changed.emit()
	return fresh


## Ids of plugins with a newer version in range (not pinned, not modified).
func update_ids() -> PackedStringArray:
	var ids: PackedStringArray = []
	for state in states:
		if state.status == Status.UPDATE:
			ids.append(state.id)
	return ids


## Source of the plugin from the last refresh (null before the first refresh).
func get_source(id: String) -> LoadoutSource:
	return _sources.get(id)


func get_state(id: String) -> PluginState:
	for state in states:
		if state.id == id:
			return state
	return null


## Plugins the startup sync offers to install (auto_install, missing, not ignored).
func missing_ids() -> PackedStringArray:
	var ids: PackedStringArray = []
	for state in states:
		if state.status == Status.MISSING and state.entry.auto_install:
			ids.append(state.id)
	return ids


## Installs every plugin from missing_ids(). Returns { "installed": PackedStringArray,
## "failed": { id: error }, "folders": { id: package folder } (packages that keep the plugin in
## another folder than the registry, to confirm with use_package_folders()), "restart_recommended": bool }.
func install_missing() -> Dictionary:
	return await _install_all(missing_ids())


## Installs the chosen missing plugins and ignores the ones in ignore (they are not offered in
## this project again). Returns the same summary as install_missing().
func install_selected(ids: PackedStringArray, ignore: PackedStringArray = []) -> Dictionary:
	if not ignore.is_empty() and _lock_ok:
		for id in ignore:
			lockfile.set_ignored(id, true)
		_save_lock()
		await refresh()
	return await _install_all(ids)


## Sets each plugin's registry folder to the folder its package uses ({ id: folder }) and installs it.
## Returns the same summary as install_missing().
func use_package_folders(folders: Dictionary) -> Dictionary:
	var ids: PackedStringArray = []
	var failed := {}
	for id: String in folders:
		var error := await set_registry_folder(id, folders[id])
		if error != "":
			failed[id] = error
		else:
			ids.append(id)
	var summary := await _install_all(ids)
	summary["failed"].merge(failed)
	return summary


func _install_all(ids: PackedStringArray) -> Dictionary:
	var summary := { "installed": PackedStringArray(), "failed": {}, "folders": {}, "restart_recommended": false }
	_batch_depth += 1
	for id in _self_last(ids):
		var result := await install(id)
		if result["ok"]:
			summary["installed"].append(id)
			summary["restart_recommended"] = summary["restart_recommended"] or result["restart_recommended"]
		elif result.get("needs_confirmation", "") == LoadoutInstaller.CONFIRM_FOLDER:
			summary["folders"][id] = result["package_folder"]
		else:
			summary["failed"][id] = result["error"]
			if result.get("fallback_version", "") != "":
				summary["failed"][id] += " An older version (%s) may work: select the plugin and use Install version…." % result["fallback_version"]
	_batch_depth -= 1
	_flush_scan()
	return summary


## ids with Loadout's own entry moved to the end: its update restarts the editor right away, so
## every other plugin must be done by then.
func _self_last(ids: PackedStringArray) -> PackedStringArray:
	var ordered := PackedStringArray()
	var own := PackedStringArray()
	for id in ids:
		var state := get_state(id)
		if state != null and state.entry != null and state.entry.folder == SELF_FOLDER:
			own.append(id)
		else:
			ordered.append(id)
	ordered.append_array(own)
	return ordered


## Updates every plugin from update_ids() (the dock asks for confirmation first). Returns the
## same summary as install_missing().
func install_updates() -> Dictionary:
	return await _install_all(update_ids())


## Versions the plugin's source offers, newest first: [{ "version", "tag", "prerelease",
## "notes", "url", "in_range": bool, "offered": bool (false for a pre-release the source flags
## although its number is a plain version: it is never "the newest", but can be picked) }]. Asset Library and local sources offer one version.
func available_versions(id: String) -> Array[Dictionary]:
	var list: Array[Dictionary] = []
	var state := get_state(id)
	var source: LoadoutSource = _sources.get(id)
	if state == null or state.entry == null or source == null:
		return list
	var parsed: Dictionary[String, LoadoutVersion] = {}
	for release in source.releases:
		var version := str(release.get("version", ""))
		var number := LoadoutVersion.parse(version)
		if number == null:
			continue
		parsed[version] = number
		list.append({
			"version": version, "tag": str(release.get("tag", version)), "prerelease": bool(release.get("prerelease", false)),
			"notes": str(release.get("notes", "")), "url": str(release.get("url", "")),
			"in_range": number.matches(state.entry.version_range, state.entry.prereleases),
			"offered": LoadoutSource.is_offered(release, state.entry.prereleases),
		})
	list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return parsed[a["version"]].compare(parsed[b["version"]]) > 0)
	return list


## Backups of the plugin's earlier files, newest first (see LoadoutInstaller.list_backups()).
func available_backups(id: String) -> Array[Dictionary]:
	var state := get_state(id)
	if state == null or state.entry == null:
		return []
	return installer.list_backups(state.entry)


## Puts one of the plugin's backups back in the project (the current files are backed up first)
## and pins that version unless pin is false. Works for a removed plugin too.
## Returns the installer result.
func restore_backup(id: String, backup_path: String, pin: bool = true) -> Dictionary:
	var result: Dictionary = await _exclusive(id, func(state: PluginState) -> Dictionary: return await _restore_backup(state, backup_path, pin))
	_flush_scan()
	return result


## Which files of the plugin differ from the version Loadout installed (downloads that version again
## to compare). Returns { "ok", "error", "info": text for the user, "diff": { modified, added, removed } }.
func changed_files(id: String) -> Dictionary:
	var state := get_state(id)
	if busy or state == null or state.entry == null or state.lock_entry == null:
		return { "ok": false, "error": "Nothing to compare: the plugin is not installed by Loadout, or another action is running." }
	var source: LoadoutSource = _sources.get(id)
	var version := state.lock_entry.version
	if source == null or not await source.has_version(version):
		return { "ok": false, "error": "The source no longer offers %s %s, so there is nothing to compare with." % [state.display_name, version] }
	var staging := installer.staging_root.path_join("%s_compare" % id)
	Fs.remove_dir(staging)
	var fetched: Dictionary = await source.fetch(version, staging)
	if not fetched["ok"]:
		Fs.remove_dir(staging)
		return { "ok": false, "error": "Downloading %s %s to compare failed: %s" % [state.display_name, version, fetched["error"]] }
	var diff := Fs.diff_dirs(str(fetched["path"]), installer.target_dir(state.entry))
	Fs.remove_dir(staging)
	return { "ok": true, "error": "", "diff": diff, "info": _describe_diff(state, version, diff) }


## Installs or updates the plugin to its target version, or to version when given (an explicit
## choice: a pinned plugin may switch, and pin decides whether it stays pinned afterwards).
## Without force a modified, pinned or unmanaged folder is left alone and the result has
## "needs_confirmation" set.
func install(id: String, force: bool = false, version: String = "", pin: bool = false) -> Dictionary:
	var result: Dictionary = await _exclusive(id, func(state: PluginState) -> Dictionary: return await _install(state, force, version, pin))
	_flush_scan()
	if result.get("needs_confirmation", "") != "":
		# What the caller needs to repeat the action after the user confirms.
		result["version"] = version
		result["pin"] = pin
	return result


## Removes the plugin from the project and ignores it here so the sync does not bring it back.
func uninstall(id: String) -> Dictionary:
	return await _exclusive(id, _uninstall)


## The lock edits below recompute the state (may query the source), always await them.
func set_pinned(id: String, pinned: bool) -> Error:
	var err := _lock_edit_error()
	if err != OK:
		return err
	if not lockfile.set_pinned(id, pinned):
		return ERR_DOES_NOT_EXIST
	return await _save_and_update(id)


func set_ignored(id: String, ignored: bool) -> Error:
	var err := _lock_edit_error()
	if err != OK:
		return err
	lockfile.set_ignored(id, ignored)
	return await _save_and_update(id)


## Accepts the current folder content (manual edits or a hand-installed copy) as installed.
func adopt(id: String) -> Error:
	var err := _lock_edit_error()
	if err != OK:
		return err
	var state := get_state(id)
	if state == null or state.entry == null:
		return ERR_DOES_NOT_EXIST
	var dir := installer.target_dir(state.entry)
	if not installer.is_installed(state.entry):
		return ERR_DOES_NOT_EXIST
	lockfile.set_installed(id, _lockable_version(state.entry), Fs.hash_dir(dir), _today())
	return await _save_and_update(id)


## Drops a lock entry of a plugin that is no longer in the registry (files stay).
func forget(id: String) -> Error:
	var err := _lock_edit_error()
	if err != OK:
		return err
	if not lockfile.remove(id):
		return ERR_DOES_NOT_EXIST
	return await _save_and_update(id)


## Writes the global registry to path (for another machine or a backup).
func export_registry(path: String) -> Error:
	if not _registry_ok:
		return ERR_FILE_CORRUPT
	return registry.save_file(path)


## Adds entries from a registry file whose ids are not in the registry yet; existing ones stay.
## Returns { "ok", "error", "added": PackedStringArray, "skipped": { id: reason },
## "warnings": PackedStringArray (invalid entries in the file) }.
func import_registry(path: String) -> Dictionary:
	var summary := { "ok": false, "error": "", "added": PackedStringArray(), "skipped": {}, "warnings": PackedStringArray() }
	if not _reload_registry():
		summary["error"] = REGISTRY_UNREADABLE
		return summary
	var loaded := LoadoutRegistry.load_file(path)
	if loaded["ok"] and loaded["missing"]:
		loaded = { "ok": false, "error": "File %s does not exist." % path }
	if not loaded["ok"]:
		summary["error"] = loaded["error"]
		return summary
	var other: LoadoutRegistry = loaded["registry"]
	summary["warnings"] = other.warnings
	summary.merge(registry.merge(other), true)
	var error := ""
	if not summary["added"].is_empty():
		error = await _save_registry()
	if error != "":
		summary["error"] = error
		return summary
	summary["ok"] = true
	await refresh()
	return summary


## Adds a raw entry to the global registry and saves it. Returns "" or an error message.
## take_over: the plugin is already in this project's addons folder; its current files are
## recorded in the lock as installed, nothing is copied or toggled.
func add_registry_entry(data: Dictionary, take_over: bool = false) -> String:
	if not _reload_registry():
		return REGISTRY_UNREADABLE
	var error := registry.add_entry(data)
	if error != "":
		return error
	error = await _save_registry()
	if error != "":
		return error
	if take_over:
		_take_over(registry.get_entry(str(data.get("id", ""))))
	await refresh()
	return ""


## Ids of every starter in the starter pack file ([] when it cannot be read).
func starter_pack_ids() -> PackedStringArray:
	var ids: PackedStringArray = []
	var pack := LoadoutStarterPack.load_file(starter_pack_path)
	for item: Dictionary in pack["items"]:
		ids.append(item["id"])
	return ids


## Starters of the starter pack that the registry does not have yet. Reads files only: whether the
## store has a release for this Godot is checked when the user opens a starter's details or adds it.
## Returns { "ok", "error", "items": [{ "id", "title", "description", "entry" }] }.
func starter_offers() -> Dictionary:
	var result := { "ok": false, "error": "", "items": [] as Array[Dictionary] }
	var loaded := LoadoutRegistry.load_file(registry_path)
	if not loaded["ok"]:
		result["error"] = REGISTRY_UNREADABLE
		return result
	var pack := LoadoutStarterPack.load_file(starter_pack_path)
	if not pack["ok"]:
		result["error"] = pack["error"]
		return result
	_starters.clear()
	for item: Dictionary in pack["items"]:
		var parsed := LoadoutRegistry.parse_entry(item["entry"])
		if _in_registry(parsed["entry"], loaded["registry"]):
			continue
		result["items"].append(item)
		_starters[item["id"]] = { "item": item, "entry": parsed["entry"], "source": null, "version": "", "offer": true }
	result["ok"] = true
	return result


## What the details dialog shows about a plugin of the registry or of the last starter_offers() (asks
## the store only now, not when the list was built):
## what it is for (asked from the source) and its releases. Returns { "ok", "error", "id", "title",
## "warning", "meta": source, "summary", "author", "license", "url", "selected": version that would be installed,
## "versions": [{ "version", "prerelease", "notes", "url" }] newest first }.
func plugin_details(id: String) -> Dictionary:
	var result := { "ok": false, "error": "", "warning": "", "id": id, "title": id, "meta": "", "summary": "", "author": "", "license": "",
			"url": "", "selected": "", "versions": [] as Array[Dictionary] }
	var source: LoadoutSource = _sources.get(id)
	var state := get_state(id)
	if state != null:
		result["title"] = state.display_name
		result["selected"] = state.target_version
	elif _starters.has(id):
		await _prepare_starter(id)
		source = _starters[id]["source"]
		result["title"] = _starters[id]["item"]["title"]
		result["summary"] = _starters[id]["item"]["description"]
		result["selected"] = _starters[id]["version"]
		if not _starters[id]["offer"]:
			result["warning"] = "No release of this plugin works with this Godot version."
	if source == null:
		result["error"] = "Nothing is known about this plugin."
		return result
	result["meta"] = source.describe()
	for release in source.releases.slice(0, MAX_DETAIL_VERSIONS):
		result["versions"].append({ "version": release.get("version", ""), "prerelease": release.get("prerelease", false),
				"notes": release.get("notes", ""), "url": release.get("url", "") })
	var info: Dictionary = await source.get_info()
	if info["ok"]:
		if info["summary"] != "":
			result["summary"] = info["summary"]
		result["author"] = info["author"]
		result["license"] = info["license"]
		result["url"] = info["url"]
	elif result["summary"] == "":
		result["error"] = info["error"]
	result["ok"] = true
	return result


## Adds the starters with these ids to the registry (nothing is installed here). A starter whose
## folder is already in the project is taken over like "Add to registry…" does.
## Returns { "ok", "error", "added": PackedStringArray, "skipped": { id: reason } }.
func add_starters(ids: PackedStringArray) -> Dictionary:
	var summary := { "ok": false, "error": "", "added": PackedStringArray(), "skipped": {} }
	if not _reload_registry():
		summary["error"] = REGISTRY_UNREADABLE
		return summary
	var pack := LoadoutStarterPack.load_file(starter_pack_path)
	if not pack["ok"]:
		summary["error"] = pack["error"]
		return summary
	var entries: Dictionary[String, Dictionary] = {}
	for item: Dictionary in pack["items"]:
		entries[item["id"]] = item["entry"]
	for id in ids:
		if not entries.has(id):
			summary["skipped"][id] = "not in the starter pack"
			continue
		var check: Dictionary = await _check_starter(LoadoutRegistry.parse_entry(entries[id])["entry"])
		if not check["offer"]:
			summary["skipped"][id] = "no release for this Godot version"
			continue
		var error := registry.add_entry(entries[id])
		if error != "":
			summary["skipped"][id] = error
		else:
			summary["added"].append(id)
	if not summary["added"].is_empty():
		var error := await _save_registry()
		if error != "":
			summary["error"] = error
			return summary
		for id in summary["added"]:
			_take_over(registry.get_entry(id))
	summary["ok"] = true
	await refresh()
	return summary


## Replaces source, version range and auto_install of a registry entry; id and folder stay (a new
## folder would not move installed copies, see set_registry_folder()). Returns "" or an error message.
func update_registry_entry(id: String, data: Dictionary) -> String:
	if not _reload_registry():
		return REGISTRY_UNREADABLE
	var error := registry.update_entry(id, data)
	if error == "":
		error = await _save_registry()
	if error != "":
		return error
	await refresh()
	return ""


## Changes the plugin folder of a registry entry (e.g. to the folder its package uses).
## Returns "" or an error message.
func set_registry_folder(id: String, folder: String) -> String:
	if not _reload_registry():
		return REGISTRY_UNREADABLE
	var error := registry.set_folder(id, folder)
	if error == "":
		error = await _save_registry()
	if error != "":
		return error
	# Cached download links were picked for the old folder name.
	await refresh(true)
	return ""


## Removes an entry from the global registry (installed files stay, the plugin becomes ORPHAN).
func remove_registry_entry(id: String) -> Error:
	if not _reload_registry() or not registry.remove_entry(id):
		return ERR_DOES_NOT_EXIST
	var err := registry.save_file(registry_path)
	await refresh()
	return err


## The registry file is shared by every project's editor, so each change starts from what is on disk
## now: another editor may have saved since this one last read it, and saving the older copy would
## undo that. Returns false when the file cannot be read.
func _reload_registry() -> bool:
	var loaded := LoadoutRegistry.load_file(registry_path)
	if not loaded["ok"]:
		_registry_ok = false
		return false
	registry = loaded["registry"]
	_registry_ok = true
	return true


## Saves the registry. When that fails the unsaved change is dropped by reloading the file.
## Returns "" or an error message.
func _save_registry() -> String:
	var err := registry.save_file(registry_path)
	if err == OK:
		return ""
	await refresh()
	return "Saving the registry failed: %s" % error_string(err)


func _load_files() -> void:
	errors.clear()
	warnings.clear()
	var registry_result := LoadoutRegistry.load_file(registry_path)
	_registry_ok = registry_result["ok"]
	registry = registry_result["registry"] if _registry_ok else LoadoutRegistry.new()
	if not _registry_ok:
		errors.append(registry_result["error"])
	warnings.append_array(registry.warnings)
	var lock_result := LoadoutLockfile.load_file(lock_path)
	_lock_ok = lock_result["ok"]
	lockfile = lock_result["lockfile"] if _lock_ok else LoadoutLockfile.new()
	if not _lock_ok:
		errors.append(lock_result["error"])
	warnings.append_array(lockfile.warnings)


func _compute_state(entry: LoadoutRegistry.Entry, check_updates: bool = false) -> PluginState:
	var state := PluginState.new()
	state.id = entry.id
	state.entry = entry
	state.lock_entry = lockfile.get_entry(entry.id)
	state.installed_version = installer.installed_version(entry)
	state.native = installer.is_installed(entry) and Package.is_native(installer.target_dir(entry))
	var source: LoadoutSource = _sources.get(entry.id)
	if source == null:
		source = _source_factory.call(entry)
	var source_error := ""
	if source == null:
		source_error = "Source type %s is not supported." % entry.source.get("type")
	else:
		_sources[entry.id] = source
		state.source_label = source.describe()
		var loaded: Dictionary = await checker.load_releases(source, check_updates)
		state.warning = loaded["warning"]
		if not loaded["ok"]:
			source_error = loaded["error"]
		else:
			var latest: Dictionary = await source.get_latest_version(entry.version_range, entry.prereleases)
			if latest["ok"]:
				state.latest_version = latest["version"]
			else:
				source_error = latest["error"]
	state.display_name = _installed_name(entry)
	if state.display_name == "" and source != null:
		state.display_name = source.get_plugin_name()
	if state.display_name == "":
		state.display_name = entry.id

	if installer.is_installed(entry):
		_describe_installed(state, source_error)
	else:
		await _describe_missing(state, source, source_error)
	_add_release_info(state, source)
	return state


func _describe_missing(state: PluginState, source: LoadoutSource, source_error: String) -> void:
	state.status = Status.IGNORED if lockfile.is_ignored(state.id) else Status.MISSING
	state.target_version = state.latest_version
	if state.lock_entry != null and source != null and await source.has_version(state.lock_entry.version):
		state.target_version = state.lock_entry.version
	elif state.lock_entry != null and state.latest_version != "":
		state.message = "The lock wants version %s, the source offers %s." % [state.lock_entry.version, state.latest_version]
	if source_error != "":
		state.message = source_error


func _describe_installed(state: PluginState, source_error: String) -> void:
	var overwrite := installer.check_overwrite(state.entry, state.lock_entry)
	if overwrite == LoadoutInstaller.CONFIRM_UNMANAGED and state.entry.folder == SELF_FOLDER:
		# Loadout itself arrives by the install script, not through the lock.
		overwrite = ""
	match overwrite:
		LoadoutInstaller.CONFIRM_UNMANAGED:
			state.status = Status.UNMANAGED
			state.message = "The folder exists, but Loadout did not install it."
		LoadoutInstaller.CONFIRM_MODIFIED:
			state.status = Status.MODIFIED
			state.message = "The folder does not match the lock (edited by hand). It is not overwritten without confirmation."
		LoadoutInstaller.CONFIRM_PINNED:
			state.status = Status.PINNED
			state.message = "Pinned to %s in this project." % state.installed_version
		_:
			state.status = Status.OK
			# Loadout installed these exact files: the release version counts, plugin.cfg may lag
			# behind (e.g. an Asset Library version string newer than the package's plugin.cfg).
			if state.lock_entry != null and state.lock_entry.folder_hash != "":
				state.installed_version = state.lock_entry.version
			if source_error != "":
				state.status = Status.UNVERIFIED
				state.message = source_error
			elif _is_newer(state.latest_version, state.installed_version):
				state.status = Status.UPDATE
				state.message = "Version %s is available." % state.latest_version
	# Overwriting (after confirmation) or updating goes to the newest version in range.
	if state.status in [Status.UPDATE, Status.MODIFIED, Status.PINNED, Status.UNMANAGED]:
		state.target_version = state.latest_version


func _add_release_info(state: PluginState, source: LoadoutSource) -> void:
	if source == null or state.target_version == "":
		return
	var release := source.get_release(state.target_version)
	state.release_notes = str(release.get("notes", ""))
	state.release_url = str(release.get("url", ""))


func _install(state: PluginState, force: bool, version: String, pin: bool) -> Dictionary:
	var source: LoadoutSource = _sources.get(state.id)
	if source == null:
		return _error_result(state.id, "Source type %s is not supported." % state.entry.source.get("type"))
	var target := state.target_version
	if version != "":
		if not await source.has_version(version):
			return _error_result(state.id, "The source does not offer version %s." % version)
		target = version
		if state.status == Status.PINNED and not _is_modified(state):
			force = true
	if target == "":
		return _error_result(state.id, state.message if state.message != "" else "No version to install is known.")
	if state.entry.folder == SELF_FOLDER:
		return await _self_update(state, source, force, target)
	var result: Dictionary = await installer.install(state.entry, source, target, state.lock_entry, force)
	if result["ok"]:
		_add_integrity_warning(result, state.lock_entry, target)
		lockfile.set_installed(state.id, target, result["hash"], _today())
		if version != "":
			lockfile.set_pinned(state.id, pin)
		lockfile.set_ignored(state.id, false)
		_save_lock()
		_note_native_result(state.id, result)
		if result["restart_recommended"]:
			restart_recommended.emit()
	elif result.get("load_failed", false):
		# The plugin does not run here: the newest release may need another Godot than the older ones.
		result["fallback_version"] = _older_version(state.id, target)
	await refresh()
	return result


## The newest offered version in range that is older than failed, "" when there is none.
func _older_version(id: String, failed: String) -> String:
	var failed_version := LoadoutVersion.parse(failed)
	if failed_version == null:
		return ""
	for release in available_versions(id):
		var number := LoadoutVersion.parse(release["version"])
		if release["in_range"] and release["offered"] and number != null and number.compare(failed_version) < 0:
			return release["version"]
	return ""


func _restore_backup(state: PluginState, backup_path: String, pin: bool) -> Dictionary:
	if state.entry.folder == SELF_FOLDER:
		return _error_result(state.id, "Loadout cannot restore itself this way. Copy the backup folder over addons/loadout by hand.")
	var backup := {}
	for item in installer.list_backups(state.entry):
		if item["path"] == backup_path:
			backup = item
	if backup.is_empty():
		return _error_result(state.id, "That backup no longer exists.")
	var version: String = backup["version"] if backup["version"] != "" else "0.0.0"
	if LoadoutVersion.parse(version) == null:
		return _error_result(state.id, "The backup has no valid version (%s) in its plugin.cfg." % version)
	var source := LoadoutLocalSource.new(ProjectSettings.globalize_path(backup_path))
	source.version_override = version
	var result: Dictionary = await installer.install(state.entry, source, version, state.lock_entry, true)
	if result["ok"]:
		lockfile.set_installed(state.id, version, result["hash"], _today())
		lockfile.set_pinned(state.id, pin)
		lockfile.set_ignored(state.id, false)
		_save_lock()
		_note_native_result(state.id, result)
		if result["restart_recommended"]:
			restart_recommended.emit()
	await refresh()
	return result


func _describe_diff(state: PluginState, version: String, diff: Dictionary) -> String:
	var lines: PackedStringArray = ["Compared with %s %s as Loadout installed it:" % [state.display_name, version]]
	var labels := { "modified": "changed", "added": "added", "removed": "missing" }
	for key in ["modified", "added", "removed"]:
		var files: Array = diff[key]
		for index in mini(files.size(), MAX_DIFF_LINES):
			lines.append("•  %s: %s" % [labels[key], files[index]])
		if files.size() > MAX_DIFF_LINES:
			lines.append("•  … and %d more %s" % [files.size() - MAX_DIFF_LINES, labels[key]])
	if lines.size() == 1:
		lines.append("No file differs (the folder hash changed through files Loadout ignores, or the hash was never recorded).")
	return "\n".join(lines)


func _uninstall(state: PluginState) -> Dictionary:
	if state.entry.folder == SELF_FOLDER:
		return _error_result(state.id, "Loadout cannot remove itself. Disable it in Project Settings → Plugins and delete its folder by hand.")
	var result: Dictionary = await installer.uninstall(state.entry, state.lock_entry)
	if result["ok"]:
		lockfile.remove(state.id)
		lockfile.set_ignored(state.id, true)
		_save_lock()
		_note_native_result(state.id, result)
		if result["restart_recommended"]:
			restart_recommended.emit()
	await refresh()
	return result


func _self_update(state: PluginState, source: LoadoutSource, force: bool, version: String) -> Dictionary:
	if not force:
		var reason := installer.check_overwrite(state.entry, state.lock_entry)
		if reason == LoadoutInstaller.CONFIRM_MODIFIED or reason == LoadoutInstaller.CONFIRM_PINNED:
			var refused := _error_result(state.id, "Loadout is %s in this project." % ("edited by hand" if reason == LoadoutInstaller.CONFIRM_MODIFIED else "pinned"))
			refused["needs_confirmation"] = reason
			return refused
	var result: Dictionary = await installer.self_update(state.entry, source, version)
	if result["ok"]:
		_add_integrity_warning(result, state.lock_entry, version)
		lockfile.set_installed(state.id, version, result["hash"], _today())
		_save_lock()
		restart_required.emit()
	return result


## Decides between a scan and a restart for a native install, and remembers what the editor holds.
## A fresh copy is scanned (Godot loads it), unless an earlier library of the same add-on is still
## loaded from before it was replaced or removed: then only a restart gets the new files running.
func _note_native_result(id: String, result: Dictionary) -> void:
	if not result.get("native", false):
		return
	var scan: bool = result.get("scan_wanted", false)
	if scan and _native_changed.has(id):
		scan = false
		result["restart_recommended"] = true
	if result["restart_recommended"]:
		_native_changed[id] = true
	result["scan_wanted"] = scan
	_scan_pending = _scan_pending or scan


## Asks for the scan once no batch is running.
func _flush_scan() -> void:
	if _scan_pending and _batch_depth == 0:
		_scan_pending = false
		scan_requested.emit()


## Runs an action on one plugin that changes the project. `busy` is set before the first await, so
## a second action cannot start in between; the lock edits and install actions refuse while it is set.
func _exclusive(id: String, action: Callable) -> Dictionary:
	var state := get_state(id)
	var refusal := _refuse_action(state)
	if refusal != "":
		return _error_result(id, refusal)
	busy = true
	var result: Dictionary = await action.call(state)
	busy = false
	return result


## The lock records the files of a version when it was first installed. When the same version
## comes back with other files (another machine, a re-uploaded package), the result gets a warning.
func _add_integrity_warning(result: Dictionary, previous: LoadoutLockfile.Entry, version: String) -> void:
	if previous == null or previous.version != version or previous.folder_hash == "" or previous.folder_hash == result["hash"]:
		return
	var warning := "%s %s has other files than when it was locked (hash differs). Check the plugin before you trust it." % [result["id"], version]
	Log.write(warning, Log.Level.WARNING)
	result["warning"] = "\n".join(PackedStringArray([str(result.get("warning", "")), warning])).strip_edges()


func _scan_unregistered() -> Array[Dictionary]:
	var known := {}
	for entry in registry.entries:
		known[entry.folder.to_lower()] = true
	var found: Array[Dictionary] = []
	for folder in DirAccess.get_directories_at(installer.addons_dir):
		if folder == SELF_FOLDER or known.has(folder.to_lower()):
			continue
		var dir := installer.addons_dir.path_join(folder)
		if not Package.is_addon(dir):
			continue
		# An extension has no plugin.cfg: the missing file leaves the defaults (folder name, no version).
		var cfg := ConfigFile.new()
		cfg.load(dir.path_join("plugin.cfg"))
		found.append({
			"folder": folder,
			"name": str(cfg.get_value("plugin", "name", folder)),
			"version": str(cfg.get_value("plugin", "version", "")),
		})
	found.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["name"].naturalnocasecmp_to(b["name"]) < 0)
	return found


## Records the files already in the project in the lock as installed (nothing is copied or toggled).
func _take_over(entry: LoadoutRegistry.Entry) -> void:
	if _lock_ok and installer.is_installed(entry) and lockfile.get_entry(entry.id) == null:
		lockfile.set_installed(entry.id, _lockable_version(entry), Fs.hash_dir(installer.target_dir(entry)), _today())
		_save_lock()


## Whether the registry has this plugin already: same id, same folder or same source.
func _in_registry(candidate: LoadoutRegistry.Entry, in_registry: LoadoutRegistry = null) -> bool:
	for entry in (in_registry if in_registry != null else registry).entries:
		if entry.id == candidate.id or entry.folder.to_lower() == candidate.folder.to_lower():
			return true
		for key in ["asset", "repo", "path", "asset_id"]:
			if candidate.source.has(key) and entry.source.get("type") == candidate.source.get("type") \
					and entry.source.get(key) == candidate.source[key]:
				return true
	return false


## Asks the source of a starter for its releases once (details dialog).
func _prepare_starter(id: String) -> void:
	var starter: Dictionary = _starters[id]
	if starter["source"] != null:
		return
	var check: Dictionary = await _check_starter(starter["entry"])
	starter["source"] = check["source"]
	starter["version"] = check["version"]
	starter["offer"] = check["offer"]


## { "offer": bool, "version": String, "source": LoadoutSource }: offer is false only when the source
## answers and has no release this entry's range accepts; version is "" when the source cannot be asked.
func _check_starter(entry: LoadoutRegistry.Entry) -> Dictionary:
	var source: LoadoutSource = _source_factory.call(entry)
	if source == null:
		return { "offer": false, "version": "", "source": null }
	var listed: Dictionary = await source.list_releases()
	if not listed["ok"]:
		return { "offer": true, "version": "", "source": source }
	source.releases.assign(listed["releases"])
	var latest: Dictionary = await source.get_latest_version(entry.version_range, entry.prereleases)
	return { "offer": latest["ok"], "version": latest["version"], "source": source }


## Version of the files in the project for the lock. A plugin.cfg without a valid version would
## make the lock entry unreadable (and silently dropped), so it is recorded as 0.0.0.
func _lockable_version(entry: LoadoutRegistry.Entry) -> String:
	var version := installer.installed_version(entry)
	return version if LoadoutVersion.parse(version) != null else "0.0.0"


func _is_modified(state: PluginState) -> bool:
	if state.lock_entry == null or state.lock_entry.folder_hash == "":
		return false
	return Fs.hash_dir(installer.target_dir(state.entry)) != state.lock_entry.folder_hash


func _orphan_state(id: String) -> PluginState:
	var state := PluginState.new()
	state.id = id
	state.display_name = id
	state.status = Status.ORPHAN
	state.lock_entry = lockfile.get_entry(id)
	state.installed_version = state.lock_entry.version
	state.message = "The plugin is in the lock but no longer in the global registry."
	return state


func _installed_name(entry: LoadoutRegistry.Entry) -> String:
	var cfg := ConfigFile.new()
	if cfg.load(installer.target_dir(entry).path_join("plugin.cfg")) != OK:
		return ""
	return str(cfg.get_value("plugin", "name", ""))


func _is_newer(candidate: String, current: String) -> bool:
	var a := LoadoutVersion.parse(candidate)
	var b := LoadoutVersion.parse(current)
	return a != null and b != null and a.compare(b) > 0


func _refuse_action(state: PluginState) -> String:
	if busy:
		return "Another action is running."
	if state == null or state.entry == null:
		return "The plugin is not in the registry."
	if not _lock_ok:
		return "The lock cannot be read, nothing changed."
	return ""


## ERR_BUSY while an action runs, ERR_FILE_CORRUPT when the lock cannot be read, otherwise OK.
func _lock_edit_error() -> Error:
	if busy:
		return ERR_BUSY
	return OK if _lock_ok else ERR_FILE_CORRUPT


func _save_and_update(id: String) -> Error:
	var err := _save_lock()
	var state := get_state(id)
	if state != null and state.entry != null:
		var fresh := await _compute_state(state.entry)
		# A refresh may have replaced the list while the state was computed.
		var index := states.find(state)
		if index >= 0:
			states[index] = fresh
		checker.save_cache()
	elif state != null:
		states.erase(state)
	states_changed.emit()
	return err


func _save_lock() -> Error:
	var err := lockfile.save_file(lock_path)
	if err != OK:
		errors.append("Saving lock %s failed: %s" % [lock_path, error_string(err)])
		Log.write(errors[-1], Log.Level.ERROR)
	return err


func _error_result(id: String, error: String) -> Dictionary:
	return { "ok": false, "error": error, "id": id, "needs_confirmation": "", "restart_recommended": false }


func _today() -> String:
	return Time.get_date_string_from_system()
