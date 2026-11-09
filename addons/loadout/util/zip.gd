@tool
extends RefCounted

const Fs := preload("fs.gd")
const Package := preload("package.gd")

## Extracts one plugin folder (the one with plugin.cfg, or with a .gdextension when no plugin has a
## plugin.cfg) from a downloaded zip.
## Handles release assets (addons/<folder>/...), GitHub source zips (<repo>-<sha>/addons/<folder>/...)
## and zips of the plugin folder itself. Entries escaping the target (../) are refused, and so is
## a zip that unpacks to more than MAX_UNPACKED_BYTES (zip bomb): ZIPReader unpacks a whole entry into
## memory, so the sizes the zip declares are checked before anything is unpacked, and the bytes
## actually unpacked are counted too (a declared size can lie).

const MAX_UNPACKED_BYTES := 512 * 1024 * 1024
const MAX_FILES := 20000
## Zip records (little-endian signatures) and the longest zip comment, after which the end record sits.
const _END_RECORD := 0x06054b50
const _CENTRAL_RECORD := 0x02014b50
const _END_RECORD_SIZE := 22
const _CENTRAL_RECORD_SIZE := 46
const _MAX_COMMENT := 65535
## A size field with this value means the real size is in a ZIP64 record (an entry of 4 GB or more).
const _ZIP64_SIZE := 0xFFFFFFFF
## "Made by" host of an entry whose external attributes are Unix file modes, and the symlink mode.
const _HOST_UNIX := 3
const _MODE_TYPE_MASK := 0xF000
const _MODE_SYMLINK := 0xA000


## Returns { "ok": bool, "error": String, "source_folder": String }. dest_dir receives the plugin
## folder content; source_folder is the folder name the package uses ("" when the zip root is it).
## max_bytes is for tests.
static func extract_plugin(zip_path: String, folder: String, dest_dir: String, max_bytes: int = MAX_UNPACKED_BYTES) -> Dictionary:
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
	if wanted.size() > MAX_FILES:
		reader.close()
		return { "ok": false, "error": "The package has too many files (%d)." % wanted.size() }
	var central := central_directory(zip_path)
	var declared_total := 0
	for path in wanted:
		declared_total += int(central.get(path, {}).get("size", 0))
	if declared_total > max_bytes:
		reader.close()
		return { "ok": false, "error": _too_large(max_bytes) }
	# Symlinks (a macOS framework's Versions/Current) are made again when they stay inside the plugin;
	# one that points out of it, or a file written through one, refuses the package.
	var links := {}
	for path in wanted:
		if central.get(path, {}).get("link", false):
			var relative := path.trim_prefix(root)
			var link_target := reader.read_file(path).get_string_from_utf8()
			if not Fs.link_stays_inside(relative, link_target):
				reader.close()
				return { "ok": false, "error": "The zip contains a link that points out of the plugin: %s -> %s" % [path, link_target] }
			links[relative] = link_target
	for path in wanted:
		for link: String in links:
			if path.trim_prefix(root).begins_with(link + "/"):
				reader.close()
				return { "ok": false, "error": "The zip writes through a link: %s" % path }
	var unpacked := 0
	var err := DirAccess.make_dir_recursive_absolute(dest_dir)
	for path in wanted:
		if err != OK:
			break
		var target := dest_dir.path_join(path.trim_prefix(root))
		err = DirAccess.make_dir_recursive_absolute(target.get_base_dir())
		if err == OK and links.has(path.trim_prefix(root)) and _make_link(links[path.trim_prefix(root)], target):
			continue
		if err == OK:
			var file := FileAccess.open(target, FileAccess.WRITE)
			if file == null:
				err = FileAccess.get_open_error()
			else:
				var content := reader.read_file(path)
				unpacked += content.size()
				if unpacked > max_bytes:
					file.close()
					reader.close()
					return { "ok": false, "error": _too_large(max_bytes) }
				file.store_buffer(content)
				file.close()
	reader.close()
	if err != OK:
		return { "ok": false, "error": "Extracting failed: %s" % error_string(err) }
	return { "ok": true, "error": "", "source_folder": root.trim_suffix("/").get_file() }


## Unpacked sizes the zip's central directory declares, { entry name: bytes }; {} when it cannot be
## read (the bytes unpacked are still counted). A ZIP64 entry counts as larger than any limit.
static func declared_sizes(zip_path: String) -> Dictionary:
	var sizes := {}
	var central := central_directory(zip_path)
	for entry_name: String in central:
		sizes[entry_name] = central[entry_name]["size"]
	return sizes


## A symlink at path pointing to target. False when the system cannot make one (Windows without the
## right), then the link's text is written as a file, as before: it is a macOS part that is not loaded there.
static func _make_link(target: String, path: String) -> bool:
	var global := ProjectSettings.globalize_path(path)
	var dir := DirAccess.open(global.get_base_dir())
	return dir != null and dir.create_link(target, global) == OK


## What the zip's central directory says about each entry: { name: { "size": unpacked bytes,
## "link": a Unix symlink } }; {} when it cannot be read.
static func central_directory(zip_path: String) -> Dictionary:
	var sizes := {}
	var file := FileAccess.open(zip_path, FileAccess.READ)
	if file == null or file.get_length() < _END_RECORD_SIZE:
		return sizes
	var tail_start := maxi(0, file.get_length() - _END_RECORD_SIZE - _MAX_COMMENT)
	file.seek(tail_start)
	var tail := file.get_buffer(file.get_length() - tail_start)
	var end := tail.size() - _END_RECORD_SIZE
	while end >= 0 and tail.decode_u32(end) != _END_RECORD:
		end -= 1
	if end < 0:
		return sizes
	var count := tail.decode_u16(end + 10)
	var directory_size := tail.decode_u32(end + 12)
	var directory_offset := tail.decode_u32(end + 16)
	if directory_offset + directory_size > file.get_length():
		return sizes
	file.seek(directory_offset)
	var directory := file.get_buffer(directory_size)
	var at := 0
	for i in count:
		if at + _CENTRAL_RECORD_SIZE > directory.size() or directory.decode_u32(at) != _CENTRAL_RECORD:
			return {}
		var host := directory.decode_u8(at + 5)
		var size := directory.decode_u32(at + 24)
		var name_length := directory.decode_u16(at + 28)
		var skip := name_length + directory.decode_u16(at + 30) + directory.decode_u16(at + 32)
		var mode := directory.decode_u32(at + 38) >> 16
		var entry_name := directory.slice(at + _CENTRAL_RECORD_SIZE, at + _CENTRAL_RECORD_SIZE + name_length).get_string_from_utf8()
		sizes[entry_name] = {
			"size": MAX_UNPACKED_BYTES + 1 if size == _ZIP64_SIZE else size,
			"link": host == _HOST_UNIX and (mode & _MODE_TYPE_MASK) == _MODE_SYMLINK,
		}
		at += _CENTRAL_RECORD_SIZE + skip
	return sizes


static func _too_large(max_bytes: int) -> String:
	return "The package unpacks to more than %d MB, refusing it." % (max_bytes / 1048576)


## Folder prefix inside the zip ("" = zip root) holding the plugin.cfg (or, in a package of native
## code only, the .gdextension) of the wanted plugin.
static func _plugin_prefix(files: PackedStringArray, folder: String) -> Dictionary:
	var candidates: PackedStringArray = []
	for path in files:
		if path.get_file() == "plugin.cfg":
			candidates.append(path.get_base_dir())
	if candidates.is_empty():
		candidates = Package.extension_roots(files)
	if candidates.is_empty():
		return { "prefix": "", "error": "The package has no plugin.cfg or .gdextension." }
	var chosen := ""
	if candidates.size() == 1:
		chosen = candidates[0]
	else:
		# A repo may carry copies of the plugin (demo or test projects): the shallowest one is the plugin.
		for candidate in candidates:
			if candidate.get_file() == folder and (chosen == "" or candidate.count("/") < chosen.count("/")):
				chosen = candidate
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
