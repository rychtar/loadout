@tool
class_name LoadoutManager
extends RefCounted

## Ties registry, lock, sources and installer together and keeps the state of every plugin.
## The dock only calls these methods and listens to the signals (core/ never touches UI).

const Fs := preload("../util/fs.gd")
const Log := preload("../util/log.gd")

## Loadout's own folder: it can be updated (installer.self_update + editor restart), never removed.
const SELF_FOLDER := "loadout"
const REGISTRY_UNREADABLE := "The registry cannot be read, nothing changed."

## Emitted after refresh() and after every action, the dock rebuilds from `states`.
signal states_changed()
## An installed or updated plugin left stale class_name entries; offer an editor restart.
signal restart_recommended()
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
## True while an install or update runs; other actions are refused meanwhile.
var busy := false

var _source_factory: Callable
var _registry_ok := false
var _lock_ok := false
## Source of every registry entry from the last refresh (holds the releases install() needs).
var _sources: Dictionary[String, LoadoutSource] = {}


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
	for id in ids:
		var result := await install(id)
		if result["ok"]:
			summary["installed"].append(id)
			summary["restart_recommended"] = summary["restart_recommended"] or result["restart_recommended"]
		elif result.get("needs_confirmation", "") == LoadoutInstaller.CONFIRM_FOLDER:
			summary["folders"][id] = result["package_folder"]
		else:
			summary["failed"][id] = result["error"]
	return summary


## Updates every plugin from update_ids() (the dock asks for confirmation first). Returns the
## same summary as install_missing().
func install_updates() -> Dictionary:
	return await _install_all(update_ids())


## Versions the plugin's source offers, newest first: [{ "version", "tag", "prerelease",
## "notes", "url", "in_range": bool }]. Asset Library and local sources offer one version.
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
			"in_range": number.matches(state.entry.version_range),
		})
	list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return parsed[a["version"]].compare(parsed[b["version"]]) > 0)
	return list


## Installs or updates the plugin to its target version, or to version when given (an explicit
## choice: a pinned plugin may switch, and pin decides whether it stays pinned afterwards).
## Without force a modified, pinned or unmanaged folder is left alone and the result has
## "needs_confirmation" set.
func install(id: String, force: bool = false, version: String = "", pin: bool = false) -> Dictionary:
	return await _exclusive(id, func(state: PluginState) -> Dictionary: return await _install(state, force, version, pin))


## Removes the plugin from the project and ignores it here so the sync does not bring it back.
func uninstall(id: String) -> Dictionary:
	return await _exclusive(id, _uninstall)


## The lock edits below recompute the state (may query the source), always await them.
func set_pinned(id: String, pinned: bool) -> Error:
	if busy:
		return ERR_BUSY
	if not _lock_ok or not lockfile.set_pinned(id, pinned):
		return ERR_DOES_NOT_EXIST
	return await _save_and_update(id)


func set_ignored(id: String, ignored: bool) -> Error:
	if busy:
		return ERR_BUSY
	if not _lock_ok:
		return ERR_FILE_CORRUPT
	lockfile.set_ignored(id, ignored)
	return await _save_and_update(id)


## Accepts the current folder content (manual edits or a hand-installed copy) as installed.
func adopt(id: String) -> Error:
	if busy:
		return ERR_BUSY
	var state := get_state(id)
	if not _lock_ok or state == null or state.entry == null:
		return ERR_DOES_NOT_EXIST
	var dir := installer.target_dir(state.entry)
	if not DirAccess.dir_exists_absolute(dir):
		return ERR_DOES_NOT_EXIST
	lockfile.set_installed(id, _lockable_version(state.entry), Fs.hash_dir(dir), _today())
	return await _save_and_update(id)


## Drops a lock entry of a plugin that is no longer in the registry (files stay).
func forget(id: String) -> Error:
	if busy:
		return ERR_BUSY
	if not _lock_ok or not lockfile.remove(id):
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
	if not _registry_ok:
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
	if not _registry_ok:
		return REGISTRY_UNREADABLE
	var error := registry.add_entry(data)
	if error != "":
		return error
	error = await _save_registry()
	if error != "":
		return error
	var entry := registry.get_entry(str(data.get("id", "")))
	if take_over and _lock_ok and DirAccess.dir_exists_absolute(installer.target_dir(entry)) and lockfile.get_entry(entry.id) == null:
		lockfile.set_installed(entry.id, _lockable_version(entry), Fs.hash_dir(installer.target_dir(entry)), _today())
		_save_lock()
	await refresh()
	return ""


## Replaces source, version range and auto_install of a registry entry; id and folder stay (a new
## folder would not move installed copies, see set_registry_folder()). Returns "" or an error message.
func update_registry_entry(id: String, data: Dictionary) -> String:
	if not _registry_ok:
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
	if not _registry_ok:
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
	if not _registry_ok or not registry.remove_entry(id):
		return ERR_DOES_NOT_EXIST
	var err := registry.save_file(registry_path)
	await refresh()
	return err


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
			var latest: Dictionary = await source.get_latest_version(entry.version_range)
			if latest["ok"]:
				state.latest_version = latest["version"]
			else:
				source_error = latest["error"]
	state.display_name = _installed_name(entry)
	if state.display_name == "" and source != null:
		state.display_name = source.get_plugin_name()
	if state.display_name == "":
		state.display_name = entry.id

	if DirAccess.dir_exists_absolute(installer.target_dir(entry)):
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
		if result["restart_recommended"]:
			restart_recommended.emit()
	await refresh()
	return result


func _uninstall(state: PluginState) -> Dictionary:
	if state.entry.folder == SELF_FOLDER:
		return _error_result(state.id, "Loadout cannot remove itself. Disable it in Project Settings → Plugins and delete its folder by hand.")
	var result: Dictionary = await installer.uninstall(state.entry)
	if result["ok"]:
		lockfile.remove(state.id)
		lockfile.set_ignored(state.id, true)
		_save_lock()
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
		var cfg := ConfigFile.new()
		if cfg.load(installer.addons_dir.path_join(folder).path_join("plugin.cfg")) != OK:
			continue
		found.append({
			"folder": folder,
			"name": str(cfg.get_value("plugin", "name", folder)),
			"version": str(cfg.get_value("plugin", "version", "")),
		})
	found.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["name"].naturalnocasecmp_to(b["name"]) < 0)
	return found


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
