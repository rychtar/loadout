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

const CONFIRM_MODIFIED := "modified"
const CONFIRM_PINNED := "pinned"
const CONFIRM_UNMANAGED := "unmanaged"
## First install of a package that keeps the plugin in another folder than the registry entry.
const CONFIRM_FOLDER := "folder"

signal plugin_installed(id: String, version: String)
signal plugin_updated(id: String, from_version: String, to_version: String)
signal plugin_removed(id: String)
signal install_failed(id: String, error: String)

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
## "restart_recommended", "needs_confirmation" }. The caller records "hash" in the lock.
func install(entry: LoadoutRegistry.Entry, source: LoadoutSource, version: String,
		lock_entry: LoadoutLockfile.Entry = null, force: bool = false, enable: bool = true) -> Dictionary:
	var result := _new_result(entry, version)
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

	if is_installed(entry):
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


## Disables and removes the plugin folder (a backup is kept).
## Returns { "ok", "error", "id", "backup_path" }.
func uninstall(entry: LoadoutRegistry.Entry) -> Dictionary:
	var result := { "ok": false, "error": "", "id": entry.id, "backup_path": "" }
	var target := target_dir(entry)
	if not DirAccess.dir_exists_absolute(target):
		result["error"] = "Plugin %s is not installed." % entry.id
		return result
	if editor.is_plugin_enabled(entry.folder):
		await editor.set_plugin_enabled(entry.folder, false)
	var backup := _backup_path(entry, installed_version(entry))
	var err := _copy_fresh(target, backup)
	if err == OK:
		err = Fs.remove_dir(target)
	if err != OK:
		result["error"] = "Removing %s failed: %s" % [entry.id, error_string(err)]
		Log.write(result["error"], Log.Level.ERROR)
		return result
	await editor.scan()
	editor.save_project_settings()
	result["ok"] = true
	result["backup_path"] = backup
	Log.write("Removed %s, backup in %s." % [entry.id, backup])
	plugin_removed.emit(entry.id)
	return result


## Downloads version into a clean staging folder and checks that it holds a plugin. Returns the
## fetch() result; on failure "error" is the message and the staging folder is gone.
func _stage(entry: LoadoutRegistry.Entry, source: LoadoutSource, version: String) -> Dictionary:
	var staging := staging_root.path_join(entry.id)
	Fs.remove_dir(staging)
	var fetched: Dictionary = await source.fetch(version, staging)
	if not fetched["ok"]:
		Fs.remove_dir(staging)
		fetched["error"] = "Download of %s %s failed: %s" % [entry.id, version, fetched["error"]]
		return fetched
	if not FileAccess.file_exists(str(fetched["path"]).path_join("plugin.cfg")):
		Fs.remove_dir(staging)
		return { "ok": false, "error": "Package %s %s has no plugin.cfg." % [entry.id, version], "path": "" }
	return fetched


func _install_fresh(entry: LoadoutRegistry.Entry, staged: String, enable: bool, result: Dictionary) -> void:
	var target := target_dir(entry)
	var err := Fs.copy_dir(staged, target)
	if err != OK:
		Fs.remove_dir(target)
		result["error"] = "Copying to %s failed: %s" % [target, error_string(err)]
		return
	var problem := await _check_new_files(target, "Plugin %s" % entry.id)
	if problem != "":
		await _discard(entry)
		result["error"] = problem
		return
	if enable:
		await editor.set_plugin_enabled(entry.folder, true)
		if not editor.is_plugin_running(entry.folder):
			await editor.set_plugin_enabled(entry.folder, false)
			await _discard(entry)
			result["error"] = "Plugin %s could not be enabled." % entry.id
			return
	editor.save_project_settings()
	result["restart_recommended"] = not editor.stale_classes(target).is_empty()
	result["ok"] = true


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
	var problem := await _check_new_files(target, "The new version of %s" % entry.id)
	if problem != "":
		await _fail_and_restore(entry, backup, was_enabled, result, problem)
		return
	# 5. Enable and check it runs
	if was_enabled:
		await editor.set_plugin_enabled(entry.folder, true)
		if not editor.is_plugin_running(entry.folder):
			await _fail_and_restore(entry, backup, was_enabled, result, "The new version of %s could not be enabled." % entry.id)
			return
	editor.save_project_settings()
	result["restart_recommended"] = not editor.stale_classes(target).is_empty()
	result["ok"] = true


## Step 4: scans the new files in, reloads stale scripts and validates the entry script. Returns ""
## or the problem; subject names what was installed ("Plugin x").
func _check_new_files(target: String, subject: String) -> String:
	if not await editor.scan():
		return "The filesystem scan did not finish in time."
	var err := editor.refresh_scripts(target)
	if err == OK:
		err = editor.validate_plugin(target)
	if err != OK:
		return "%s has a broken script (%s)." % [subject, error_string(err)]
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
	return Fs.copy_dir(src, dst)


func _new_result(entry: LoadoutRegistry.Entry, version: String) -> Dictionary:
	return {
		"ok": false, "error": "", "id": entry.id, "from": installed_version(entry), "to": version,
		"hash": "", "backup_path": "", "restored": false, "restart_recommended": false, "needs_confirmation": "",
		"warning": "", "package_folder": "",
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
