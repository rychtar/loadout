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


func test_hash_cache_waits_for_old_files_and_sees_changes() -> void:
	var dir := temp_dir("fs_hash_cache")
	write_text(dir.path_join("a.gd"), "extends Node\r\nvar a := 1\r\n")
	var fresh := Fs.hash_dir(dir)
	check(not Fs.is_hash_cached(dir), "a file from this second is not trusted for the cache")
	if OS.get_name() == "Windows":
		return # touch -t sets the file time below
	var global := ProjectSettings.globalize_path(dir.path_join("a.gd"))
	OS.execute("touch", ["-t", "202601010000", global])
	check_eq(Fs.hash_dir(dir), fresh, "same hash")
	check(Fs.is_hash_cached(dir), "older files are cached")
	write_text(dir.path_join("a.gd"), "extends Node\r\nvar b := 2\r\n")
	check(not Fs.is_hash_cached(dir), "an edit invalidates the cache")
	check(Fs.hash_dir(dir) != fresh, "and is seen")
	write_text(dir.path_join("b.gd"), "x")
	OS.execute("touch", ["-t", "202601010000", global, ProjectSettings.globalize_path(dir.path_join("b.gd"))])
	var with_new_file := Fs.hash_dir(dir)
	check(Fs.is_hash_cached(dir), "cached again")
	DirAccess.remove_absolute(dir.path_join("b.gd"))
	check(Fs.hash_dir(dir) != with_new_file, "a removed file is seen")


func test_crlf_normalization() -> void:
	var dir := temp_dir("fs_crlf")
	write_text(dir.path_join("a.txt"), "one\r\ntwo\rthree\r\n\r\nend\r")
	write_text(dir.path_join("b.txt"), "one\ntwo\rthree\n\nend\r")
	var hashes := Fs.file_hashes(dir)
	check_eq(hashes["a.txt"], hashes["b.txt"], "only a CR before LF is dropped")


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


func test_link_stays_inside() -> void:
	check(Fs.link_stays_inside("lib.framework/Versions/Current", "A"), "a sibling folder")
	check(Fs.link_stays_inside("lib.framework/lib", "Versions/Current/lib"), "down the tree")
	check(Fs.link_stays_inside("a/b/c", "../x"), "up and back down inside")
	check(not Fs.link_stays_inside("a/b", "../../x"), "out of the folder")
	check(not Fs.link_stays_inside("a", "/etc/passwd"), "absolute")
	check(not Fs.link_stays_inside("a", "C:/Windows"), "a drive")
	check(not Fs.link_stays_inside("a", ""), "empty")
	check(not Fs.link_stays_inside("a/b", ".."), "the folder itself")


func test_copy_keeps_links_inside_and_drops_links_out() -> void:
	if OS.get_name() == "Windows":
		return # making symlinks needs a right Windows does not give by default
	var root := temp_dir("fs_links")
	var src := root.path_join("src")
	DirAccess.make_dir_recursive_absolute(src.path_join("Versions/A"))
	write_text(src.path_join("Versions/A/lib"), "binary")
	write_text(root.path_join("outside.txt"), "outside")
	DirAccess.make_dir_recursive_absolute(root.path_join("outside_dir"))
	var global := ProjectSettings.globalize_path(src)
	DirAccess.open(global.path_join("Versions")).create_link("A", global.path_join("Versions/Current"))
	var top := DirAccess.open(global)
	top.create_link("Versions/Current/lib", global.path_join("lib"))
	top.create_link("../outside.txt", global.path_join("out_file"))
	top.create_link("../outside_dir", global.path_join("out_dir"))
	var dst := root.path_join("dst")
	check_eq(Fs.copy_dir(src, dst), OK, "copied")
	var copied := DirAccess.open(ProjectSettings.globalize_path(dst))
	check(copied.is_link("lib") and copied.read_link("lib") == "Versions/Current/lib", "a link inside stays a link")
	check(DirAccess.open(ProjectSettings.globalize_path(dst.path_join("Versions"))).is_link("Current"), "so does a folder link")
	check_eq(FileAccess.get_file_as_string(dst.path_join("lib")), "binary", "and it works")
	check(not copied.is_link("out_file") and FileAccess.get_file_as_string(dst.path_join("out_file")) == "outside", "a file link out is copied as the file")
	check(not DirAccess.dir_exists_absolute(dst.path_join("out_dir")), "a folder link out is left out")
	check_eq(Fs.copy_dir(src, dst), OK, "copying again over the same links works")
