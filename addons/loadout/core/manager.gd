@tool
class_name LoadoutManager
extends RefCounted

## Ties registry, lock, sources and installer together and keeps the state of every plugin.
## The dock only calls these methods and listens to the signals (core/ never touches UI).

const Fs := preload("../util/fs.gd")
const Log := preload("../util/log.gd")

## Loadout's own folder; replacing it while it runs comes with self-update in F3.
const SELF_FOLDER := "loadout"

## Emitted after refresh() and after every action, the dock rebuilds from `states`.
signal states_changed()
## An installed or updated plugin left stale class_name entries; offer an editor restart.
signal restart_recommended()

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


var registry: LoadoutRegistry
var lockfile: LoadoutLockfile
var installer: LoadoutInstaller
var registry_path: String
var lock_path: String
## Problems loading the registry or the lock, shown in the dock.
var errors: PackedStringArray = []
## Non-fatal problems (skipped registry or lock entries).
var warnings: PackedStringArray = []
var states: Array[PluginState] = []
## True while an install or update runs; other actions are refused meanwhile.
var busy := false

var _source_factory: Callable
var _registry_ok := false
var _lock_ok := false


## source_factory: func(entry: LoadoutRegistry.Entry) -> LoadoutSource, defaults to LoadoutSource.create().
func _init(plugin_installer: LoadoutInstaller, registry_file: String, lock_file: String,
		source_factory: Callable = Callable()) -> void:
	installer = plugin_installer
	registry_path = registry_file
	lock_path = lock_file
	_source_factory = source_factory
	if not _source_factory.is_valid():
		_source_factory = func(entry: LoadoutRegistry.Entry) -> LoadoutSource: return LoadoutSource.create(entry.source)


## Reloads registry and lock from disk and recomputes all states.
func refresh() -> void:
	_load_files()
	var new_states: Array[PluginState] = []
	if _registry_ok and _lock_ok:
		for entry in registry.entries:
			new_states.append(await _compute_state(entry))
		for id in lockfile.plugins:
			if registry.get_entry(id) == null:
				new_states.append(_orphan_state(id))
	states = new_states
	states_changed.emit()


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
## "failed": { id: error }, "restart_recommended": bool }.
func install_missing() -> Dictionary:
	var summary := { "installed": PackedStringArray(), "failed": {}, "restart_recommended": false }
	for id in missing_ids():
		var result := await install(id)
		if result["ok"]:
			summary["installed"].append(id)
			summary["restart_recommended"] = summary["restart_recommended"] or result["restart_recommended"]
		else:
			summary["failed"][id] = result["error"]
	return summary


## Installs or updates the plugin to its target version. Without force a modified, pinned or
## unmanaged folder is left alone and the result has "needs_confirmation" set.
func install(id: String, force: bool = false) -> Dictionary:
	var state := get_state(id)
	var refusal := _refuse_action(state)
	if refusal != "":
		return _error_result(id, refusal)
	if state.target_version == "":
		return _error_result(id, state.message if state.message != "" else "No version to install is known.")
	var source: LoadoutSource = _source_factory.call(state.entry)
	if source == null:
		return _error_result(id, "Source type %s is not supported." % state.entry.source.get("type"))
	busy = true
	var result: Dictionary = await installer.install(state.entry, source, state.target_version, state.lock_entry, force)
	if result["ok"]:
		lockfile.set_installed(id, state.target_version, result["hash"], _today())
		lockfile.set_ignored(id, false)
		_save_lock()
		if result["restart_recommended"]:
			restart_recommended.emit()
	busy = false
	await refresh()
	return result


## Removes the plugin from the project and ignores it here so the sync does not bring it back.
func uninstall(id: String) -> Dictionary:
	var state := get_state(id)
	var refusal := _refuse_action(state)
	if refusal != "":
		return _error_result(id, refusal)
	busy = true
	var result: Dictionary = await installer.uninstall(state.entry)
	if result["ok"]:
		lockfile.remove(id)
		lockfile.set_ignored(id, true)
		_save_lock()
	busy = false
	await refresh()
	return result


## The lock edits below recompute the state (may query the source), always await them.
func set_pinned(id: String, pinned: bool) -> Error:
	if not _lock_ok or not lockfile.set_pinned(id, pinned):
		return ERR_DOES_NOT_EXIST
	return await _save_and_update(id)


func set_ignored(id: String, ignored: bool) -> Error:
	if not _lock_ok:
		return ERR_FILE_CORRUPT
	lockfile.set_ignored(id, ignored)
	return await _save_and_update(id)


## Accepts the current folder content (manual edits or a hand-installed copy) as installed.
func adopt(id: String) -> Error:
	var state := get_state(id)
	if not _lock_ok or state == null or state.entry == null:
		return ERR_DOES_NOT_EXIST
	var dir := installer.target_dir(state.entry)
	if not DirAccess.dir_exists_absolute(dir):
		return ERR_DOES_NOT_EXIST
	lockfile.set_installed(id, installer.installed_version(state.entry), Fs.hash_dir(dir), _today())
	return await _save_and_update(id)


## Drops a lock entry of a plugin that is no longer in the registry (files stay).
func forget(id: String) -> Error:
	if not _lock_ok or not lockfile.remove(id):
		return ERR_DOES_NOT_EXIST
	return await _save_and_update(id)


## Adds a raw entry to the global registry and saves it. Returns "" or an error message.
func add_registry_entry(data: Dictionary) -> String:
	if not _registry_ok:
		return "The registry cannot be read, nothing changed."
	var error := registry.add_entry(data)
	if error != "":
		return error
	var err := registry.save_file(registry_path)
	if err != OK:
		registry.remove_entry(str(data.get("id", "")))
		return "Saving the registry failed: %s" % error_string(err)
	await refresh()
	return ""


## Removes an entry from the global registry (installed files stay, the plugin becomes ORPHAN).
func remove_registry_entry(id: String) -> Error:
	if not _registry_ok or not registry.remove_entry(id):
		return ERR_DOES_NOT_EXIST
	var err := registry.save_file(registry_path)
	await refresh()
	return err


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


func _compute_state(entry: LoadoutRegistry.Entry) -> PluginState:
	var state := PluginState.new()
	state.id = entry.id
	state.entry = entry
	state.lock_entry = lockfile.get_entry(entry.id)
	state.installed_version = installer.installed_version(entry)
	var source: LoadoutSource = _source_factory.call(entry)
	var source_error := ""
	if source == null:
		source_error = "Source type %s is not supported." % entry.source.get("type")
	else:
		state.source_label = source.describe()
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

	var installed := DirAccess.dir_exists_absolute(installer.target_dir(entry))
	if not installed:
		state.status = Status.IGNORED if lockfile.is_ignored(entry.id) else Status.MISSING
		state.target_version = state.latest_version
		if state.lock_entry != null and source != null and await source.has_version(state.lock_entry.version):
			state.target_version = state.lock_entry.version
		elif state.lock_entry != null and state.latest_version != "":
			state.message = "The lock wants version %s, the source offers %s." % [state.lock_entry.version, state.latest_version]
		if source_error != "":
			state.message = source_error
		return state

	match installer.check_overwrite(entry, state.lock_entry):
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
			if source_error != "":
				state.status = Status.UNVERIFIED
				state.message = source_error
			elif _is_newer(state.latest_version, state.installed_version):
				state.status = Status.UPDATE
				state.message = "Version %s is available." % state.latest_version
	# Overwriting (after confirmation) or updating goes to the newest version in range.
	if state.status in [Status.UPDATE, Status.MODIFIED, Status.PINNED, Status.UNMANAGED]:
		state.target_version = state.latest_version
	return state


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
	if state.entry.folder == SELF_FOLDER:
		return "Loadout cannot update itself yet."
	if not _lock_ok:
		return "The lock cannot be read, nothing changed."
	return ""


func _save_and_update(id: String) -> Error:
	var err := _save_lock()
	var state := get_state(id)
	if state != null and state.entry != null:
		var index := states.find(state)
		states[index] = await _compute_state(state.entry)
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
