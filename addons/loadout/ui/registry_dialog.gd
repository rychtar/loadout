@tool
extends ConfirmationDialog

## "Add plugin to registry" for a local plugin folder (GitHub and Asset Library come in F2/F3).
## Emits the raw registry entry; LoadoutManager validates and saves it.

signal entry_submitted(data: Dictionary)

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

	box.add_child(_caption("Local plugin folder (contains plugin.cfg)"))
	var path_row := HBoxContainer.new()
	box.add_child(path_row)
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
	box.add_child(_info_label)
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
	_id_edit.text_changed.connect(func(_text: String) -> void: _validate())
	_folder_edit.text_changed.connect(func(_text: String) -> void: _validate())
	_range_edit.text_changed.connect(func(_text: String) -> void: _validate())

	_auto_check = CheckBox.new()
	_auto_check.text = "Install automatically in every project"
	_auto_check.button_pressed = true
	box.add_child(_auto_check)

	var note := _caption("GitHub Releases and the Asset Library come in later versions. The registry applies to all projects on this computer.")
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
	_path_edit.text = ""
	_id_edit.text = ""
	_folder_edit.text = ""
	_range_edit.text = "*"
	_auto_check.button_pressed = true
	_update_from_path()
	reset_size()
	popup_centered()


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
	var folder := path.trim_suffix("/").get_file()
	if _folder_edit.text == "":
		_folder_edit.text = folder
	if _id_edit.text == "":
		_id_edit.text = folder
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
	var has_plugin := _plugin_dir(_path_edit.text.strip_edges()) != ""
	var parsed := LoadoutRegistry.parse_entry(_entry_data())
	_error_label.text = parsed["error"] if has_plugin and not parsed["ok"] else ""
	get_ok_button().disabled = not has_plugin or not parsed["ok"]


func _entry_data() -> Dictionary:
	return {
		"id": _id_edit.text.strip_edges(),
		"folder": _folder_edit.text.strip_edges(),
		"source": { "type": LoadoutRegistry.SOURCE_LOCAL, "path": _path_edit.text.strip_edges() },
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
