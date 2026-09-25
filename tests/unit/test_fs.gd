extends "res://tests/test_case.gd"

const FIXTURE := "res://tests/fixtures/addons/fake_a/1.0.0"


func test_list_files_relative_and_sorted() -> void:
	var dir := temp_dir("fs_list")
	write_text(dir.path_join("b.gd"), "b")
	DirAccess.make_dir_recursive_absolute(dir.path_join("sub"))
	write_text(dir.path_join("sub/a.gd"), "a")
	write_text(dir.path_join(".hidden"), "h")
	check_eq(Fs.list_files(dir), PackedStringArray([".hidden", "b.gd", "sub/a.gd"]), "files")
	check_eq(Fs.list_files(dir.path_join("missing")), PackedStringArray(), "missing dir")


func test_copy_dir_excludes() -> void:
	var src := temp_dir("fs_copy_src")
	write_text(src.path_join("plugin.cfg"), "x")
	DirAccess.make_dir_recursive_absolute(src.path_join(".git/objects"))
	write_text(src.path_join(".git/HEAD"), "ref")
	write_text(src.path_join(".DS_Store"), "junk")
	var dst := temp_dir("fs_copy_dst")
	check_eq(Fs.copy_dir(src, dst, Fs.DEFAULT_EXCLUDE), OK, "copied")
	check_eq(Fs.list_files(dst), PackedStringArray(["plugin.cfg"]), "only plugin files")


func test_hash_is_stable_and_detects_changes() -> void:
	var dir := temp_dir("fs_hash")
	Fs.copy_dir(FIXTURE, dir)
	var first := Fs.hash_dir(dir)
	check(first.begins_with("sha256:") and first.length() == 7 + 64, "sha256 format")
	check_eq(Fs.hash_dir(dir), first, "stable")
	var copy := temp_dir("fs_hash_copy")
	Fs.copy_dir(FIXTURE, copy)
	check_eq(Fs.hash_dir(copy), first, "same content, other location")
	write_text(dir.path_join("plugin.gd"), "changed")
	check(Fs.hash_dir(dir) != first, "content change")
	check_eq(Fs.hash_dir(dir.path_join("missing")), "", "missing dir")


func test_hash_detects_renames_and_new_files() -> void:
	var dir := temp_dir("fs_hash_names")
	write_text(dir.path_join("a.gd"), "x")
	var first := Fs.hash_dir(dir)
	DirAccess.rename_absolute(dir.path_join("a.gd"), dir.path_join("b.gd"))
	check(Fs.hash_dir(dir) != first, "rename")
	DirAccess.rename_absolute(dir.path_join("b.gd"), dir.path_join("a.gd"))
	write_text(dir.path_join("c.gd"), "")
	check(Fs.hash_dir(dir) != first, "new empty file")


func test_hash_ignores_editor_files_and_line_endings() -> void:
	var dir := temp_dir("fs_hash_ignore")
	write_text(dir.path_join("plugin.gd"), "extends Node\nvar a := 1\n")
	var first := Fs.hash_dir(dir)
	write_text(dir.path_join("plugin.gd.uid"), "uid://abc")
	write_text(dir.path_join("icon.png.import"), "[remap]")
	write_text(dir.path_join(".DS_Store"), "junk")
	check_eq(Fs.hash_dir(dir), first, ".uid, .import and .DS_Store ignored")
	write_text(dir.path_join("plugin.gd"), "extends Node\r\nvar a := 1\r\n")
	check_eq(Fs.hash_dir(dir), first, "CRLF equals LF")


func test_hash_binary_untouched() -> void:
	var dir := temp_dir("fs_hash_binary")
	var file := FileAccess.open(dir.path_join("data.bin"), FileAccess.WRITE)
	file.store_buffer(PackedByteArray([0, 13, 10, 1]))
	file.close()
	var first := Fs.hash_dir(dir)
	file = FileAccess.open(dir.path_join("data.bin"), FileAccess.WRITE)
	file.store_buffer(PackedByteArray([0, 10, 1]))
	file.close()
	check(Fs.hash_dir(dir) != first, "CR in binary file matters")
