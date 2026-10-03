@tool
extends RefCounted

## Extracts one plugin folder (the one with plugin.cfg) from a downloaded zip.
## Handles release assets (addons/<folder>/...), GitHub source zips (<repo>-<sha>/addons/<folder>/...)
## and zips of the plugin folder itself. Entries escaping the target (../) are refused.


## Returns { "ok": bool, "error": String, "source_folder": String }. dest_dir receives the plugin
## folder content; source_folder is the folder name the package uses ("" when the zip root is it).
static func extract_plugin(zip_path: String, folder: String, dest_dir: String) -> Dictionary:
	var reader := ZIPReader.new()
	if reader.open(zip_path) != OK:
		return { "ok": false, "error": "The downloaded file is not a valid zip." }
	var files := reader.get_files()
	var prefix := _plugin_prefix(files, folder)
	if prefix["error"] != "":
		reader.close()
		return { "ok": false, "error": prefix["error"] }
	var root: String = prefix["prefix"]
	var wanted: PackedStringArray = []
	for path in files:
		if path.begins_with(root) and not path.ends_with("/"):
			if not _is_safe(path.trim_prefix(root)):
				reader.close()
				return { "ok": false, "error": "The zip contains an unsafe path: %s" % path }
			wanted.append(path)
	var err := DirAccess.make_dir_recursive_absolute(dest_dir)
	for path in wanted:
		if err != OK:
			break
		var target := dest_dir.path_join(path.trim_prefix(root))
		err = DirAccess.make_dir_recursive_absolute(target.get_base_dir())
		if err == OK:
			var file := FileAccess.open(target, FileAccess.WRITE)
			if file == null:
				err = FileAccess.get_open_error()
			else:
				file.store_buffer(reader.read_file(path))
				file.close()
	reader.close()
	if err != OK:
		return { "ok": false, "error": "Extracting failed: %s" % error_string(err) }
	return { "ok": true, "error": "", "source_folder": root.trim_suffix("/").get_file() }


## Folder prefix inside the zip ("" = zip root) holding the plugin.cfg of the wanted plugin.
static func _plugin_prefix(files: PackedStringArray, folder: String) -> Dictionary:
	var candidates: PackedStringArray = []
	for path in files:
		if path.get_file() == "plugin.cfg":
			candidates.append(path.get_base_dir())
	if candidates.is_empty():
		return { "prefix": "", "error": "The package has no plugin.cfg." }
	var chosen := ""
	if candidates.size() == 1:
		chosen = candidates[0]
	else:
		for candidate in candidates:
			if candidate.get_file() == folder:
				chosen = candidate
				break
	if chosen == "" and not candidates.has(""):
		return { "prefix": "", "error": "The package has several plugins (%s) and none is called %s." % [", ".join(candidates), folder] }
	return { "prefix": chosen + "/" if chosen != "" else "", "error": "" }


static func _is_safe(relative: String) -> bool:
	if relative.is_empty() or relative.begins_with("/") or relative.contains("\\") or relative.contains(":"):
		return false
	for part in relative.split("/"):
		if part == "..":
			return false
	return true
