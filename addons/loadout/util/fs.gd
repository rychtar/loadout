@tool
extends RefCounted

## Filesystem helpers. Accepts res://, user:// and absolute paths.

## Names never copied out of a plugin source folder.
const DEFAULT_EXCLUDE: PackedStringArray = [".git", ".DS_Store"]
## Files the editor generates or the OS adds; they do not count as changes of a plugin.
const HASH_IGNORED_EXTENSIONS: PackedStringArray = ["uid", "import"]
const HASH_IGNORED_NAMES: PackedStringArray = [".DS_Store"]
## Files with a NUL byte in this prefix are binary (same heuristic as git).
const BINARY_SNIFF_BYTES := 8000


## Recursively copies the contents of src into dst (dst is created if missing).
## Files and folders whose name is in exclude are skipped at any depth.
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
		if exclude.has(sub_dir):
			continue
		err = copy_dir(src.path_join(sub_dir), dst.path_join(sub_dir), exclude)
		if err != OK:
			return err
	return OK


## Recursively deletes path. A missing path is not an error.
static func remove_dir(path: String) -> Error:
	if not DirAccess.dir_exists_absolute(path):
		return OK
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
	for relative in list_files(path):
		var file_name := relative.get_file()
		if HASH_IGNORED_NAMES.has(file_name) or HASH_IGNORED_EXTENSIONS.has(file_name.get_extension()):
			continue
		var content := _normalized_bytes(path.path_join(relative))
		var content_hash := HashingContext.new()
		content_hash.start(HashingContext.HASH_SHA256)
		if not content.is_empty():
			content_hash.update(content)
		context.update(("%s\n%s\n" % [relative, content_hash.finish().hex_encode()]).to_utf8_buffer())
	return "sha256:" + context.finish().hex_encode()


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
