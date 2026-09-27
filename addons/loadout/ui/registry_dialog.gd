@tool
extends ConfirmationDialog

## "Add plugin to registry" for a GitHub repository (Releases) or a local plugin folder
## (Asset Library comes in F3). Emits the raw registry entry; LoadoutManager validates and saves it.

signal entry_submitted(data: Dictionary)

const SOURCE_GITHUB := 0
const SOURCE_LOCAL := 1

var _source_option: OptionButton
var _github_box: VBoxContainer
var _local_box: VBoxContainer
var _repo_edit: LineEdit
var _auto_names := true
var _setting_names := false
var _path_edit: LineEdit
var _info_label: Label
var _error_label: Label
var _id_edit: LineEdit
var _folder_edit: LineEdit
var _range_edit: LineEdit
var _auto_check: CheckBox
var _file_dialog: EditorFileDialog


func _init() -> void:
	title = "Add a plugin to the global registry"
	ok_button_text = "Add to registry"
	cancel_button_text = "Cancel"
	min_size = Vector2i(roundi(560 * EditorInterface.get_editor_scale()), 0)
	var width := roundi(540 * EditorInterface.get_editor_scale())
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	add_child(box)

	var source_row := HBoxContainer.new()
	box.add_child(source_row)
	source_row.add_child(_caption("Source"))
	_source_option = OptionButton.new()
	_source_option.add_item("GitHub Releases", SOURCE_GITHUB)
	_source_option.add_item("Local folder", SOURCE_LOCAL)
	_source_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_source_option.item_selected.connect(func(_index: int) -> void: _on_source_changed())
	source_row.add_child(_source_option)

	_github_box = VBoxContainer.new()
	box.add_child(_github_box)
	_github_box.add_child(_caption("Repository (owner/name or https://github.com/owner/name)"))
	_repo_edit = LineEdit.new()
	_repo_edit.placeholder_text = "bitwes/Gut"
	_repo_edit.text_changed.connect(func(_text: String) -> void: _on_repo_changed())
	_github_box.add_child(_repo_edit)
	var github_note := _caption("Loadout installs the release's zip asset (or the tag's source zip). The folder below must match the plugin's folder in addons/ inside the release.")
	github_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	github_note.custom_minimum_size.x = width
	_github_box.add_child(github_note)

	_local_box = VBoxContainer.new()
	box.add_child(_local_box)
	_local_box.add_child(_caption("Local plugin folder (contains plugin.cfg)"))
	var path_row := HBoxContainer.new()
	_local_box.add_child(path_row)
	_path_edit = LineEdit.new()
	_path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_path_edit.placeholder_text = "/cesta/k/addons/muj_plugin"
	_path_edit.text_changed.connect(func(_text: String) -> void: _update_from_path())
	path_row.add_child(_path_edit)
	var browse := Button.new()
	browse.text = "Browse…"
	browse.pressed.connect(_on_browse_pressed)
	path_row.add_child(browse)

	# Wrapping labels need a width up front, otherwise the dialog grows to one word per line.
	_info_label = Label.new()
	_info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info_label.custom_minimum_size.x = width
	_local_box.add_child(_info_label)
	_error_label = Label.new()
	_error_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_error_label.custom_minimum_size.x = width
	_error_label.add_theme_color_override("font_color", Color(0.94, 0.57, 0.54))
	box.add_child(_error_label)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	box.add_child(grid)
	_id_edit = _labeled_edit(grid, "Registry id", "")
	_folder_edit = _labeled_edit(grid, "Folder in addons/", "")
	_range_edit = _labeled_edit(grid, "Allowed versions", "*")
	_range_edit.tooltip_text = "* = always the newest, ^1.2.0 = minor and patch updates, ~1.2.0 = patch updates only"
	_id_edit.text_changed.connect(func(_text: String) -> void: _on_name_edited())
	_folder_edit.text_changed.connect(func(_text: String) -> void: _on_name_edited())
	_range_edit.text_changed.connect(func(_text: String) -> void: _validate())

	_auto_check = CheckBox.new()
	_auto_check.text = "Install automatically in every project"
	_auto_check.button_pressed = true
	box.add_child(_auto_check)

	var note := _caption("The registry applies to all projects on this computer. The Asset Library comes in a later version.")
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.custom_minimum_size.x = width
	box.add_child(note)

	_file_dialog = EditorFileDialog.new()
	_file_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_DIR
	_file_dialog.access = EditorFileDialog.ACCESS_FILESYSTEM
	_file_dialog.title = "Select the plugin folder"
	_file_dialog.dir_selected.connect(_on_dir_selected)
	add_child(_file_dialog)

	confirmed.connect(_on_confirmed)


func open() -> void:
	_auto_names = true
	_repo_edit.text = ""
	_path_edit.text = ""
	_id_edit.text = ""
	_folder_edit.text = ""
	_range_edit.text = "*"
	_auto_check.button_pressed = true
	_on_source_changed()
	reset_size()
	popup_centered()


func _on_source_changed() -> void:
	var github := _is_github()
	_github_box.visible = github
	_local_box.visible = not github
	if github:
		_on_repo_changed()
	else:
		_update_from_path()
	reset_size()


func _on_repo_changed() -> void:
	if _auto_names:
		# Suggest names from the repository: "owner/godot-dialogue-manager" -> "godot_dialogue_manager".
		var name := _repo_edit.text.strip_edges().trim_suffix("/").trim_suffix(".git").get_file().to_lower().replace("-", "_")
		_set_names(name)
	_validate()


func _on_name_edited() -> void:
	if not _setting_names:
		_auto_names = false
	_validate()



func _set_names(name: String) -> void:
	_setting_names = true
	_id_edit.text = name
	_folder_edit.text = name
	_setting_names = false


func _is_github() -> bool:
	return _source_option.get_selected_id() == SOURCE_GITHUB


func _on_browse_pressed() -> void:
	_file_dialog.popup_file_dialog()


func _on_dir_selected(dir: String) -> void:
	_path_edit.text = dir
	_update_from_path()


func _update_from_path() -> void:
	var path := _plugin_dir(_path_edit.text.strip_edges())
	var cfg := ConfigFile.new()
	if path == "" or cfg.load(path.path_join("plugin.cfg")) != OK:
		_info_label.text = "Select a folder that contains plugin.cfg." if _path_edit.text.strip_edges() != "" else ""
		_validate()
		return
	if path != _path_edit.text.strip_edges():
		_path_edit.text = path
	_info_label.text = "Found plugin %s, version %s." % [cfg.get_value("plugin", "name", "?"), cfg.get_value("plugin", "version", "?")]
	if _auto_names:
		_set_names(path.trim_suffix("/").get_file())
	_validate()


## Accepts the plugin folder itself or a project folder with exactly one plugin in addons/.
func _plugin_dir(path: String) -> String:
	if path == "" or not DirAccess.dir_exists_absolute(path):
		return ""
	if FileAccess.file_exists(path.path_join("plugin.cfg")):
		return path
	var addons := path.path_join("addons")
	var found: PackedStringArray = []
	for sub_dir in DirAccess.get_directories_at(addons):
		if FileAccess.file_exists(addons.path_join(sub_dir).path_join("plugin.cfg")):
			found.append(addons.path_join(sub_dir))
	return found[0] if found.size() == 1 else ""


func _validate() -> void:
	var has_source := _repo_edit.text.strip_edges() != "" if _is_github() else _plugin_dir(_path_edit.text.strip_edges()) != ""
	var parsed := LoadoutRegistry.parse_entry(_entry_data())
	_error_label.text = parsed["error"] if has_source and not parsed["ok"] else ""
	_error_label.visible = _error_label.text != ""
	get_ok_button().disabled = not has_source or not parsed["ok"]


func _entry_data() -> Dictionary:
	return {
		"id": _id_edit.text.strip_edges(),
		"folder": _folder_edit.text.strip_edges(),
		"source": { "type": LoadoutRegistry.SOURCE_GITHUB, "repo": _repo_edit.text.strip_edges() } if _is_github()
				else { "type": LoadoutRegistry.SOURCE_LOCAL, "path": _path_edit.text.strip_edges() },
		"range": _range_edit.text.strip_edges(),
		"auto_install": _auto_check.button_pressed,
	}


func _on_confirmed() -> void:
	entry_submitted.emit(_entry_data())


func _caption(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.modulate = Color(1, 1, 1, 0.75)
	return label


func _labeled_edit(grid: GridContainer, caption: String, value: String) -> LineEdit:
	var label := Label.new()
	label.text = caption
	grid.add_child(label)
	var edit := LineEdit.new()
	edit.text = value
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(edit)
	return edit
