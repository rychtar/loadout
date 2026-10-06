@tool
extends RefCounted

## Filesystem helpers. Accepts res://, user:// and absolute paths.

## Names never copied out of a plugin source folder.
const DEFAULT_EXCLUDE: PackedStringArray = [".git", ".DS_Store"]
## Files the editor generates or the OS adds; they do not count as changes of a plugin.
const HASH_IGNORED_EXTENSIONS: PackedStringArray = ["uid", "import"]
const HASH_IGNORED_NAMES: PackedStringArray = [".ds_store", "thumbs.db", "desktop.ini"]
## Files with a NUL byte in this prefix are binary (same heuristic as git).
const BINARY_SNIFF_BYTES := 8000


## Recursively copies the contents of src into dst (dst is created if missing).
## Files and folders whose name is in exclude are skipped at any depth. Symlinked sub folders are
## skipped (they could point outside the plugin or loop); src itself may be a symlink.
static func copy_dir(src: String, dst: String, exclude: PackedStringArray = []) -> Error:
	var dir := _open(src)
	if dir == null:
		return DirAccess.get_open_error()
	var err := DirAccess.make_dir_recursive_absolute(dst)
	if err != OK:
		return err
	for file_name: String in dir.get_files():
		if exclude.has(file_name):
			continue
		err = DirAccess.copy_absolute(src.path_join(file_name), dst.path_join(file_name))
		if err != OK:
			return err
	for sub_dir: String in dir.get_directories():
		if exclude.has(sub_dir) or dir.is_link(sub_dir):
			continue
		err = copy_dir(src.path_join(sub_dir), dst.path_join(sub_dir), exclude)
		if err != OK:
			return err
	return OK


## Recursively deletes path. A missing path is not an error. A symlink is only unlinked, what it
## points to stays.
static func remove_dir(path: String) -> Error:
	if not DirAccess.dir_exists_absolute(path):
		return OK
	if is_link(path):
		return DirAccess.remove_absolute(path)
	var dir := _open(path)
	if dir == null:
		return DirAccess.get_open_error()
	var err: Error = OK
	for file_name: String in dir.get_files():
		err = DirAccess.remove_absolute(path.path_join(file_name))
		if err != OK:
			return err
	for sub_dir: String in dir.get_directories():
		err = remove_dir(path.path_join(sub_dir))
		if err != OK:
			return err
	return DirAccess.remove_absolute(path)


## Whether path is a symbolic link.
static func is_link(path: String) -> bool:
	var parent := DirAccess.open(path.trim_suffix("/").get_base_dir())
	return parent != null and parent.is_link(path.trim_suffix("/").get_file())


## Whether path is a folder with at least one file in it (an empty leftover folder is not).
static func has_files(path: String) -> bool:
	return DirAccess.dir_exists_absolute(path) and not list_files(path).is_empty()


## All files under root (hidden included) as sorted paths relative to root.
static func list_files(root: String) -> PackedStringArray:
	var files: PackedStringArray = []
	_collect_files(root, "", files)
	files.sort()
	return files


## "sha256:<hex>" of the folder content, "" if the folder does not exist.
## Covers relative paths and file contents. Ignores editor-generated files (.uid, .import) and
## treats CRLF as LF in text files so a git checkout on Windows does not look like a change.
static func hash_dir(path: String) -> String:
	if not DirAccess.dir_exists_absolute(path):
		return ""
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	var hashes := file_hashes(path)
	var relatives: Array = hashes.keys()
	relatives.sort()
	for relative: String in relatives:
		context.update(("%s\n%s\n" % [relative, hashes[relative]]).to_utf8_buffer())
	return "sha256:" + context.finish().hex_encode()


## { relative path: sha256 hex of the content } of the files hash_dir() looks at (same ignore and
## CRLF rules), for finding out which files differ.
static func file_hashes(path: String) -> Dictionary:
	var hashes := {}
	for relative in list_files(path):
		var file_name := relative.get_file()
		if HASH_IGNORED_NAMES.has(file_name.to_lower()) or HASH_IGNORED_EXTENSIONS.has(file_name.get_extension()):
			continue
		var content := _normalized_bytes(path.path_join(relative))
		var content_hash := HashingContext.new()
		content_hash.start(HashingContext.HASH_SHA256)
		if not content.is_empty():
			content_hash.update(content)
		hashes[relative] = content_hash.finish().hex_encode()
	return hashes


## How folder `current` differs from `baseline`: { "modified": [...], "added": [...], "removed": [...] }
## with sorted relative paths (added = only in current, removed = only in baseline).
static func diff_dirs(baseline: String, current: String) -> Dictionary:
	var before := file_hashes(baseline)
	var after := file_hashes(current)
	var diff := { "modified": [], "added": [], "removed": [] }
	for relative: String in after:
		if not before.has(relative):
			diff["added"].append(relative)
		elif before[relative] != after[relative]:
			diff["modified"].append(relative)
	for relative: String in before:
		if not after.has(relative):
			diff["removed"].append(relative)
	for key in diff:
		diff[key].sort()
	return diff


## Directory handle that lists hidden files and no "." or "..", null when it cannot be opened.
static func _open(path: String) -> DirAccess:
	var dir := DirAccess.open(path)
	if dir != null:
		dir.include_hidden = true
		dir.include_navigational = false
	return dir


static func _collect_files(root: String, relative: String, files: PackedStringArray) -> void:
	var dir := _open(root.path_join(relative))
	if dir == null:
		return
	for file_name: String in dir.get_files():
		files.append(relative.path_join(file_name) if relative != "" else file_name)
	for sub_dir: String in dir.get_directories():
		if dir.is_link(sub_dir):
			continue
		_collect_files(root, relative.path_join(sub_dir) if relative != "" else sub_dir, files)


static func _normalized_bytes(path: String) -> PackedByteArray:
	var bytes := FileAccess.get_file_as_bytes(path)
	if not bytes.has(13) or bytes.slice(0, BINARY_SNIFF_BYTES).has(0):
		return bytes
	# Text file with CR: drop every CR that precedes LF (byte level, works for any encoding).
	var out := PackedByteArray()
	out.resize(bytes.size())
	var size := 0
	var last := bytes.size() - 1
	for i in bytes.size():
		if bytes[i] == 13 and i < last and bytes[i + 1] == 10:
			continue
		out[size] = bytes[i]
		size += 1
	out.resize(size)
	return out
