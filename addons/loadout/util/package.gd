@tool
extends RefCounted

## What an add-on folder is made of. A plugin has a plugin.cfg; a GDExtension has a .gdextension file
## and no EditorPlugin to enable (it may have both). Code loaded from a native library stays in the
## editor's memory until it restarts, so such an add-on is only replaced on disk, never toggled.

const Fs := preload("fs.gd")

const EXTENSION_SUFFIX := ".gdextension"


static func has_plugin_cfg(dir: String) -> bool:
	return FileAccess.file_exists(dir.path_join("plugin.cfg"))


## Whether a .gdextension file is anywhere in the folder (it may sit in a bin/ folder).
static func has_extension(dir: String) -> bool:
	if not DirAccess.dir_exists_absolute(dir):
		return false
	for relative in Fs.list_files(dir):
		if relative.ends_with(EXTENSION_SUFFIX):
			return true
	return false


## An add-on Loadout can manage: a plugin or an extension.
static func is_addon(dir: String) -> bool:
	return has_plugin_cfg(dir) or has_extension(dir)


## Contains native code: it is copied but not enabled or disabled, and needs an editor restart.
static func is_native(dir: String) -> bool:
	return has_extension(dir)


## Folders (inside a zip, from its entry names) that hold an extension: the folder below "addons/"
## when there is one (the .gdextension may be in a bin/ folder), otherwise the file's own folder.
## "" is the zip root. Each folder is listed once.
static func extension_roots(files: PackedStringArray) -> PackedStringArray:
	var roots: PackedStringArray = []
	for path in files:
		if not path.ends_with(EXTENSION_SUFFIX):
			continue
		var root := _addon_folder(path.get_base_dir())
		if not roots.has(root):
			roots.append(root)
	return roots


static func _addon_folder(dir: String) -> String:
	var parts := dir.split("/", false)
	for index in parts.size() - 1:
		if parts[index] == "addons":
			return "/".join(parts.slice(0, index + 2))
	return dir
