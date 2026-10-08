@tool
class_name LoadoutInstaller
extends RefCounted

## The only code that changes res://addons/. Installs, replaces and removes plugin folders.
##
## Replacing a plugin (findings from F0, see CLAUDE.md):
##   1. disable  2. backup  3. replace files  4. scan, refresh loaded scripts, validate entry script
##   5. enable and check the EditorPlugin really runs, save project.godot
##   6. on failure restore the backup; if even that fails, recommend an editor restart.
## A folder that differs from the lock (manual edits), is pinned, or is not in the lock at all
## is never overwritten without force (the dock asks the user first).

const Fs := preload("../util/fs.gd")
const Log := preload("../util/log.gd")
const Package := preload("../util/package.gd")

const CONFIRM_MODIFIED := "modified"
const CONFIRM_PINNED := "pinned"
const CONFIRM_UNMANAGED := "unmanaged"
## First install of a package that keeps the plugin in another folder than the registry entry.
const CONFIRM_FOLDER := "folder"
## Backups kept per plugin (the newest ones); older folders are deleted when a new backup is made.
const MAX_BACKUPS := 10

signal plugin_installed(id: String, version: String)
signal plugin_updated(id: String, from_version: String, to_version: String)
signal plugin_removed(id: String)
signal install_failed(id: String, error: String)

static var _backup_suffix_regex: RegEx

var editor: LoadoutEditorBridge
var addons_dir: String
var backup_root: String
var staging_root: String


func _init(editor_bridge: LoadoutEditorBridge, addons: String = "res://addons",
		backups: String = "user://loadout_backup", staging: String = "user://loadout_staging") -> void:
	editor = editor_bridge
	addons_dir = addons
	backup_root = backups
	staging_root = staging


func target_dir(entry: LoadoutRegistry.Entry) -> String:
	return addons_dir.path_join(entry.folder)


## Whether the plugin folder holds files. A leftover empty folder counts as not installed.
func is_installed(entry: LoadoutRegistry.Entry) -> bool:
	return Fs.has_files(target_dir(entry))


## Version from the installed plugin.cfg, "" when the plugin is not installed.
func installed_version(entry: LoadoutRegistry.Entry) -> String:
	var cfg := ConfigFile.new()
	if cfg.load(target_dir(entry).path_join("plugin.cfg")) != OK:
		return ""
	return str(cfg.get_value("plugin", "version", ""))


## Why installing over the current folder needs the user's confirmation, "" when it does not.
func check_overwrite(entry: LoadoutRegistry.Entry, lock_entry: LoadoutLockfile.Entry) -> String:
	if not is_installed(entry):
		return ""
	if lock_entry == null:
		return CONFIRM_UNMANAGED
	# Manual edits are the stronger reason: they would be lost, a pin only delays updates.
	if lock_entry.folder_hash != "" and Fs.hash_dir(target_dir(entry)) != lock_entry.folder_hash:
		return CONFIRM_MODIFIED
	if lock_entry.pinned:
		return CONFIRM_PINNED
	return ""


## Installs version of the plugin from source, replacing an installed version.
## Returns { "ok", "error", "id", "from", "to", "hash", "backup_path", "restored",
## "restart_recommended", "needs_confirmation", "load_failed", "native" }. The caller records "hash" in the lock.
## load_failed: the files were fine but the plugin did not compile or start (often written for
## another Godot version), so an older release may work.
## native: the package holds a GDExtension. Nothing is enabled, disabled or scanned here.
## - installed over files already there (an update): the library may be loaded and cannot be swapped
##   in a running editor, so "restart_recommended" is set.
## - installed fresh: "scan_wanted" is set. The caller scans once it has nothing else running, and
##   Godot then loads the new extension itself.
## "from" is the version in the lock when the folder has no plugin.cfg to say.
func install(entry: LoadoutRegistry.Entry, source: LoadoutSource, version: String,
		lock_entry: LoadoutLockfile.Entry = null, force: bool = false, enable: bool = true) -> Dictionary:
	var result := _new_result(entry, version, lock_entry)
	if not force:
		var reason := check_overwrite(entry, lock_entry)
		if reason != "":
			result["needs_confirmation"] = reason
			result["error"] = _confirmation_message(entry, reason)
			return result

	var staging := staging_root.path_join(entry.id)
	var fetched: Dictionary = await _stage(entry, source, version)
	if not fetched["ok"]:
		return _fail(result, fetched["error"])
	var staged: String = fetched["path"]
	result["package_folder"] = str(fetched.get("package_folder", ""))
	if not is_installed(entry) and result["package_folder"] != "" \
			and result["package_folder"] != entry.folder:
		# Plugins often use fixed res://addons/<folder>/ paths: ask before installing under another name.
		Fs.remove_dir(staging)
		result["needs_confirmation"] = CONFIRM_FOLDER
		result["error"] = "The package keeps the plugin in addons/%s, the registry says addons/%s." % [result["package_folder"], entry.folder]
		return result
	result["warning"] = str(fetched.get("warning", ""))
	if result["warning"] != "":
		Log.write(result["warning"], Log.Level.WARNING)
	_preserve_uids(target_dir(entry), staged)

	if Package.is_native(staged):
		await _install_native(entry, staged, result)
	elif is_installed(entry):
		await _replace(entry, staged, result)
	else:
		await _install_fresh(entry, staged, enable, result)
	Fs.remove_dir(staging)

	if not result["ok"]:
		return _fail(result, result["error"])
	result["hash"] = Fs.hash_dir(target_dir(entry))
	if result["from"] == "":
		Log.write("Installed %s %s." % [entry.id, version])
		plugin_installed.emit(entry.id, version)
	else:
		Log.write("Updated %s %s -> %s." % [entry.id, result["from"], version])
		plugin_updated.emit(entry.id, result["from"], version)
	return result


## Replaces Loadout's own folder. Loadout cannot disable itself (that would stop this very code), so the
## files are swapped while it runs, without scan or reload: the running scripts stay in memory and
## the new version loads after the editor restart that must follow right away.
## Returns the same dictionary as install() plus "restart_required": true on success.
func self_update(entry: LoadoutRegistry.Entry, source: LoadoutSource, version: String) -> Dictionary:
	var result := _new_result(entry, version)
	result["restart_required"] = false
	var staging := staging_root.path_join(entry.id)
	var fetched: Dictionary = await _stage(entry, source, version)
	if not fetched["ok"]:
		return _fail(result, fetched["error"])
	var staged: String = fetched["path"]
	var target := target_dir(entry)
	# Loadout cannot repair itself after a restart, so the new scripts must compile before the swap.
	var invalid := editor.validate_scripts(staged)
	if invalid != OK:
		Fs.remove_dir(staging)
		return _fail(result, "The new version of Loadout has a broken script (%s), nothing was changed." % error_string(invalid))
	_preserve_uids(target, staged)
	var backup := _backup_path(entry, result["from"])
	var err := _copy_fresh(target, backup)
	if err != OK:
		Fs.remove_dir(staging)
		return _fail(result, "Backup of Loadout failed: %s" % error_string(err))
	result["backup_path"] = backup
	err = Fs.remove_dir(target)
	if err == OK:
		err = Fs.copy_dir(staged, target)
	Fs.remove_dir(staging)
	if err != OK:
		var restored := Fs.remove_dir(target) == OK and Fs.copy_dir(backup, target) == OK
		result["restored"] = restored
		result["restart_recommended"] = not restored
		return _fail(result, "Replacing Loadout files failed (%s). %s" % [error_string(err),
				"Version %s restored." % result["from"] if restored else "Restore the backup from %s and restart the editor." % backup])
	result["ok"] = true
	result["restart_required"] = true
	result["hash"] = Fs.hash_dir(target)
	Log.write("Loadout updated %s -> %s, restarting the editor." % [result["from"], version])
	plugin_updated.emit(entry.id, result["from"], version)
	return result


## Backups of the plugin, newest first: [{ "path", "name" (folder name), "version" (from its
## plugin.cfg, else from the folder name, "" when neither is a version), "modified" (unix time) }].
func list_backups(entry: LoadoutRegistry.Entry) -> Array[Dictionary]:
	var list: Array[Dictionary] = []
	var root := backup_root.path_join(entry.id)
	if not DirAccess.dir_exists_absolute(root):
		return list
	for name in DirAccess.get_directories_at(root):
		var path := root.path_join(name)
		if not Fs.has_files(path):
			continue
		var cfg := ConfigFile.new()
		var version := ""
		if cfg.load(path.path_join("plugin.cfg")) == OK:
			version = str(cfg.get_value("plugin", "version", ""))
		if version == "":
			version = _version_from_backup_name(name)
		list.append({ "path": path, "name": name, "version": version, "modified": FileAccess.get_modified_time(path) })
	list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["name"].naturalnocasecmp_to(b["name"]) > 0 if a["modified"] == b["modified"] else a["modified"] > b["modified"])
	return list


## Disables and removes the plugin folder (a backup is kept). A folder with native code is only
## deleted, the loaded library goes away with the next editor restart ("restart_recommended").
## Returns { "ok", "error", "id", "backup_path", "native", "restart_recommended" }.
func uninstall(entry: LoadoutRegistry.Entry, lock_entry: LoadoutLockfile.Entry = null) -> Dictionary:
	var result := { "ok": false, "error": "", "id": entry.id, "backup_path": "", "native": false, "restart_recommended": false }
	var target := target_dir(entry)
	if not DirAccess.dir_exists_absolute(target):
		result["error"] = "Plugin %s is not installed." % entry.id
		return result
	var native := Package.is_native(target)
	if editor.is_plugin_enabled(entry.folder):
		await editor.set_plugin_enabled(entry.folder, false)
	var backup := _backup_path(entry, _new_result(entry, "", lock_entry)["from"])
	var err := _copy_fresh(target, backup)
	if err == OK:
		err = Fs.remove_dir(target)
	if err != OK:
		result["error"] = "Removing %s failed: %s" % [entry.id, error_string(err)]
		Log.write(result["error"], Log.Level.ERROR)
		return result
	if native:
		# No scan, see _install_native(); the library stays loaded until the editor restarts.
		result["native"] = true
		result["restart_recommended"] = true
	else:
		await editor.scan()
		editor.save_project_settings()
	result["ok"] = true
	result["backup_path"] = backup
	Log.write("Removed %s, backup in %s." % [entry.id, backup])
	plugin_removed.emit(entry.id)
	return result


## Downloads version into a clean staging folder and checks that it holds a plugin or an extension.
## Returns the fetch() result; on failure "error" is the message and the staging folder is gone.
func _stage(entry: LoadoutRegistry.Entry, source: LoadoutSource, version: String) -> Dictionary:
	var staging := staging_root.path_join(entry.id)
	Fs.remove_dir(staging)
	var fetched: Dictionary = await source.fetch(version, staging)
	if not fetched["ok"]:
		Fs.remove_dir(staging)
		fetched["error"] = "Download of %s %s failed: %s" % [entry.id, version, fetched["error"]]
		return fetched
	if not Package.is_addon(str(fetched["path"])):
		Fs.remove_dir(staging)
		return { "ok": false, "error": "Package %s %s has no plugin.cfg or .gdextension." % [entry.id, version], "path": "" }
	return fetched


func _install_fresh(entry: LoadoutRegistry.Entry, staged: String, enable: bool, result: Dictionary) -> void:
	var target := target_dir(entry)
	var err := Fs.copy_dir(staged, target)
	if err != OK:
		Fs.remove_dir(target)
		result["error"] = "Copying to %s failed: %s" % [target, error_string(err)]
		return
	var problem := await _check_new_files(target, "Plugin %s" % entry.id, result)
	if problem != "":
		await _discard(entry)
		result["error"] = problem
		return
	if enable:
		await editor.set_plugin_enabled(entry.folder, true)
		if not editor.is_plugin_running(entry.folder):
			await editor.set_plugin_enabled(entry.folder, false)
			await _discard(entry)
			result["load_failed"] = true
			result["error"] = "Plugin %s could not be enabled.%s" % [entry.id, _godot_hint()]
			return
	editor.save_project_settings()
	result["restart_recommended"] = not editor.stale_classes(target).is_empty()
	result["ok"] = true


## A package with a GDExtension: back up the old files and swap the folder. Nothing is enabled,
## disabled, scanned or compiled here. Scanning a new .gdextension makes Godot load it and reload all
## scripts, which cancels every coroutine in flight (this one and the manager's included), so a fresh
## install only reports "scan_wanted" and the caller scans when it is done. A library that is already
## loaded stays in memory (the old one keeps running), so a replacement is not scanned at all and
## reports "restart_recommended": Godot would deinitialize it under the running editor.
## On failure the old files come back. On Windows a loaded library is locked and cannot be replaced.
func _install_native(entry: LoadoutRegistry.Entry, staged: String, result: Dictionary) -> void:
	result["native"] = true
	var target := target_dir(entry)
	var backup := ""
	if is_installed(entry):
		backup = _backup_path(entry, result["from"])
		var backup_error := _copy_fresh(target, backup)
		if backup_error != OK:
			result["error"] = "Backup of %s failed: %s" % [entry.id, error_string(backup_error)]
			return
		result["backup_path"] = backup
	var err := Fs.remove_dir(target)
	if err == OK:
		err = Fs.copy_dir(staged, target)
	if err != OK:
		result["error"] = "Replacing the files in %s failed: %s." % [target, error_string(err)]
		result["restored"] = _restore_native(entry, backup)
		if result["restored"]:
			result["error"] += " Version %s restored." % result["from"]
		elif backup != "":
			result["error"] += " A loaded native library may be locked. Close the editor and copy the backup %s over the folder by hand." % backup
		return
	if backup == "":
		result["scan_wanted"] = true
	else:
		result["restart_recommended"] = true
	result["ok"] = true


## Puts the backup back after a failed native install; a fresh install (no backup) is removed. The
## backup is copied over what is left, so files that could not be deleted do not stop the restore.
func _restore_native(entry: LoadoutRegistry.Entry, backup: String) -> bool:
	var target := target_dir(entry)
	Fs.remove_dir(target)
	if backup == "":
		return false
	var err := Fs.copy_dir(backup, target)
	if err != OK:
		Log.write("Restoring %s from %s failed: %s" % [entry.id, backup, error_string(err)], Log.Level.ERROR)
	return err == OK


func _replace(entry: LoadoutRegistry.Entry, staged: String, result: Dictionary) -> void:
	var target := target_dir(entry)
	var was_enabled := editor.is_plugin_enabled(entry.folder)
	# 1. Disable
	if was_enabled:
		await editor.set_plugin_enabled(entry.folder, false)
	# 2. Backup
	var backup := _backup_path(entry, result["from"])
	var err := _copy_fresh(target, backup)
	if err != OK:
		if was_enabled:
			await editor.set_plugin_enabled(entry.folder, true)
		result["error"] = "Backup of %s failed: %s" % [entry.id, error_string(err)]
		return
	result["backup_path"] = backup
	# 3. Replace
	err = Fs.remove_dir(target)
	if err == OK:
		err = Fs.copy_dir(staged, target)
	if err != OK:
		await _fail_and_restore(entry, backup, was_enabled, result, "Copying to %s failed: %s" % [target, error_string(err)])
		return
	# 4. Scan, refresh stale scripts, validate before enabling
	var problem := await _check_new_files(target, "The new version of %s" % entry.id, result)
	if problem != "":
		await _fail_and_restore(entry, backup, was_enabled, result, problem)
		return
	# 5. Enable and check it runs
	if was_enabled:
		await editor.set_plugin_enabled(entry.folder, true)
		if not editor.is_plugin_running(entry.folder):
			result["load_failed"] = true
			await _fail_and_restore(entry, backup, was_enabled, result, "The new version of %s could not be enabled.%s" % [entry.id, _godot_hint()])
			return
	editor.save_project_settings()
	result["restart_recommended"] = not editor.stale_classes(target).is_empty()
	result["ok"] = true


## Step 4: scans the new files in, reloads stale scripts and validates the entry script. Returns ""
## or the problem; subject names what was installed ("Plugin x").
func _check_new_files(target: String, subject: String, result: Dictionary) -> String:
	if not await editor.scan():
		return "The filesystem scan did not finish in time."
	var err := editor.refresh_scripts(target)
	if err == OK:
		err = editor.validate_plugin(target)
	if err != OK:
		result["load_failed"] = true
		return "%s has a broken script (%s).%s" % [subject, error_string(err), _godot_hint()]
	return ""


# 6. Restore the backup after a failed replace.
func _fail_and_restore(entry: LoadoutRegistry.Entry, backup: String, enable: bool, result: Dictionary, error: String) -> void:
	result["error"] = error
	result["restored"] = await _restore(entry, backup, enable)
	if result["restored"]:
		result["error"] += " Version %s restored." % result["from"]
	else:
		result["restart_recommended"] = true
		result["error"] += " Restoring the backup failed, restart the editor. Backup: %s" % backup


func _restore(entry: LoadoutRegistry.Entry, backup: String, enable: bool) -> bool:
	var target := target_dir(entry)
	if editor.is_plugin_enabled(entry.folder):
		await editor.set_plugin_enabled(entry.folder, false)
	var err := Fs.remove_dir(target)
	if err == OK:
		err = Fs.copy_dir(backup, target)
	if err != OK:
		Log.write("Restoring %s from %s failed: %s" % [entry.id, backup, error_string(err)], Log.Level.ERROR)
		return false
	if not await editor.scan():
		return false
	if editor.refresh_scripts(target) != OK:
		return false
	var ok := true
	if enable:
		await editor.set_plugin_enabled(entry.folder, true)
		ok = editor.is_plugin_running(entry.folder)
	editor.save_project_settings()
	return ok


## Removes a half-installed folder after a failed fresh install.
func _discard(entry: LoadoutRegistry.Entry) -> void:
	Fs.remove_dir(target_dir(entry))
	await editor.scan()


## Keeps the UIDs of files that exist in both versions when the package ships no .uid for them,
## so references by uid:// (autoloads, scenes) survive the update.
func _preserve_uids(target: String, staged: String) -> void:
	if not DirAccess.dir_exists_absolute(target):
		return
	for relative in Fs.list_files(target):
		if relative.get_extension() != "uid":
			continue
		if FileAccess.file_exists(staged.path_join(relative)):
			continue
		if not FileAccess.file_exists(staged.path_join(relative.trim_suffix(".uid"))):
			continue
		DirAccess.copy_absolute(target.path_join(relative), staged.path_join(relative))


## The version a backup folder is named after ("1.0.0", "1.0.0-2" for a second backup of it), "" when
## the name is not a version. Used for a package that has no plugin.cfg to say.
func _version_from_backup_name(folder_name: String) -> String:
	if _backup_suffix_regex == null:
		_backup_suffix_regex = RegEx.create_from_string("-\\d+$")
	for candidate in [_backup_suffix_regex.sub(folder_name, ""), folder_name]:
		if LoadoutVersion.parse(candidate) != null:
			return candidate
	return ""


## A folder for the backup of version that does not exist yet, so an earlier backup of the same
## version (e.g. with other manual edits) is never replaced: "1.0.0", "1.0.0-2", "1.0.0-3", ...
func _backup_path(entry: LoadoutRegistry.Entry, version: String) -> String:
	var base := backup_root.path_join(entry.id).path_join(version if version != "" else "unknown")
	var path := base
	var index := 2
	while DirAccess.dir_exists_absolute(path):
		path = "%s-%d" % [base, index]
		index += 1
	return path


func _copy_fresh(src: String, dst: String) -> Error:
	var err := Fs.remove_dir(dst)
	if err != OK:
		return err
	err = Fs.copy_dir(src, dst)
	if err == OK:
		_prune_backups(dst.get_base_dir(), dst)
	return err


## Deletes the oldest backup folders of a plugin beyond MAX_BACKUPS. keep (the backup just made)
## is never deleted.
func _prune_backups(plugin_backups: String, keep: String) -> void:
	var folders: Array[String] = []
	folders.assign(DirAccess.get_directories_at(plugin_backups))
	if folders.size() <= MAX_BACKUPS:
		return
	# Oldest first; folders made within one second compare by name ("1.0.0-2" before "1.0.0-10").
	folders.sort_custom(func(a: String, b: String) -> bool:
		var time_a := FileAccess.get_modified_time(plugin_backups.path_join(a))
		var time_b := FileAccess.get_modified_time(plugin_backups.path_join(b))
		return a.naturalnocasecmp_to(b) < 0 if time_a == time_b else time_a < time_b)
	var excess := folders.size() - MAX_BACKUPS
	for folder in folders:
		if excess <= 0:
			break
		var path := plugin_backups.path_join(folder)
		if path != keep and Fs.remove_dir(path) == OK:
			excess -= 1


## A plugin that fails to load is often written for another Godot version (a newer API, or one
## that was removed), and the release does not say which it needs.
func _godot_hint() -> String:
	var version := Engine.get_version_info()
	return " It may not support Godot %d.%d, which is running now." % [version["major"], version["minor"]]


## lock_entry names the installed version when the folder has no plugin.cfg to say (an extension).
func _new_result(entry: LoadoutRegistry.Entry, version: String, lock_entry: LoadoutLockfile.Entry = null) -> Dictionary:
	var installed := installed_version(entry)
	if installed == "" and lock_entry != null and is_installed(entry):
		installed = lock_entry.version
	return {
		"ok": false, "error": "", "id": entry.id, "from": installed, "to": version,
		"hash": "", "backup_path": "", "restored": false, "restart_recommended": false, "needs_confirmation": "",
		"warning": "", "package_folder": "", "load_failed": false, "native": false, "scan_wanted": false,
	}


func _fail(result: Dictionary, error: String) -> Dictionary:
	result["ok"] = false
	result["error"] = error
	Log.write(error, Log.Level.ERROR)
	install_failed.emit(result["id"], error)
	return result


func _confirmation_message(entry: LoadoutRegistry.Entry, reason: String) -> String:
	match reason:
		CONFIRM_MODIFIED:
			return "Folder %s was edited by hand (does not match the lock)." % target_dir(entry)
		CONFIRM_PINNED:
			return "Plugin %s is pinned in this project." % entry.id
		CONFIRM_UNMANAGED:
			return "Folder %s already exists, but Loadout did not install it." % target_dir(entry)
	return ""
