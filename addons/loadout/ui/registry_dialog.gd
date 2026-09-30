@tool
extends ConfirmationDialog

## "Add plugin to registry" for a GitHub repository (Releases), a Godot Asset Store asset (search)
## or a local plugin folder. Emits the raw registry entry; LoadoutManager validates and saves it.

## take_over: the plugin is already in the project and Loadout should adopt its current files.
signal entry_submitted(data: Dictionary, take_over: bool)
## Edit mode: the changed entry (id and folder stay, see LoadoutManager.update_registry_entry()).
signal entry_edited(id: String, data: Dictionary)

const SOURCE_GITHUB := 0
const SOURCE_LOCAL := 1
const SOURCE_STORE := 2

## func(query: String) -> Dictionary (LoadoutStoreSource.search), set by the dock.
var store_search: Callable

var _source_option: OptionButton
var _github_box: VBoxContainer
var _local_box: VBoxContainer
var _store_box: VBoxContainer
var _query_edit: LineEdit
var _search_button: Button
var _results: ItemList
var _search_status: Label
## "publisher/slug" of the selected Asset Store result.
var _store_asset := ""
var _existing_label: Label
var _take_over := false
## Id of the entry being edited, "" when adding.
var _editing_id := ""
## Source of an edited entry that the dialog cannot show (the old Asset Library); kept unless replaced.
var _legacy_source := {}
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

	_existing_label = _caption("")
	_existing_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_existing_label.custom_minimum_size.x = width
	box.add_child(_existing_label)
	var source_row := HBoxContainer.new()
	box.add_child(source_row)
	source_row.add_child(_caption("Source"))
	_source_option = OptionButton.new()
	_source_option.add_item("GitHub Releases", SOURCE_GITHUB)
	_source_option.add_item("Asset Store", SOURCE_STORE)
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

	_store_box = VBoxContainer.new()
	box.add_child(_store_box)
	var search_row := HBoxContainer.new()
	_store_box.add_child(search_row)
	_query_edit = LineEdit.new()
	_query_edit.placeholder_text = "Search the Godot Asset Store"
	_query_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_query_edit.text_submitted.connect(func(_text: String) -> void: _search())
	search_row.add_child(_query_edit)
	_search_button = Button.new()
	_search_button.text = "Search"
	_search_button.pressed.connect(_search)
	search_row.add_child(_search_button)
	_results = ItemList.new()
	_results.custom_minimum_size = Vector2(0, roundi(160 * EditorInterface.get_editor_scale()))
	_results.item_selected.connect(_on_result_selected)
	_store_box.add_child(_results)
	_search_status = _caption("Free add-ons compatible with your Godot version.")
	_search_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_search_status.custom_minimum_size.x = width
	_store_box.add_child(_search_status)

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

	var note := _caption("The registry applies to all projects on this computer.")
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
	title = "Add a plugin to the global registry"
	ok_button_text = "Add to registry"
	_take_over = false
	_editing_id = ""
	_legacy_source = {}
	_existing_label.visible = false
	_id_edit.editable = true
	_folder_edit.editable = true
	_auto_names = true
	_repo_edit.text = ""
	_path_edit.text = ""
	_query_edit.text = ""
	_results.clear()
	_store_asset = ""
	_id_edit.text = ""
	_folder_edit.text = ""
	_range_edit.text = "*"
	_auto_check.button_pressed = true
	_on_source_changed()
	reset_size()
	popup_centered()


## Opens the dialog for a plugin already in the project's addons folder: its folder is fixed,
## the Asset Store is searched for its name and Loadout takes over the current files.
func open_existing(info: Dictionary) -> void:
	open()
	title = "Add an existing plugin to the registry"
	_take_over = true
	_auto_names = false
	_set_names(info["folder"])
	_folder_edit.editable = false
	_existing_label.text = "%s %s is already in addons/%s. Loadout keeps the current files; choose where updates come from." % [info["name"], info["version"], info["folder"]]
	_existing_label.visible = true
	_source_option.select(_source_option.get_item_index(SOURCE_STORE))
	_on_source_changed()
	_query_edit.text = info["name"]
	reset_size()
	_search()


## Opens the dialog for an entry already in the registry: source, allowed versions and automatic
## install can change, id and folder cannot (installed copies would not move).
func open_edit(entry: LoadoutRegistry.Entry, display_name: String) -> void:
	open()
	title = "Edit %s" % display_name
	ok_button_text = "Save"
	_editing_id = entry.id
	_auto_names = false
	_set_names(entry.id)
	_folder_edit.text = entry.folder
	_id_edit.editable = false
	_folder_edit.editable = false
	_range_edit.text = entry.version_range
	_auto_check.button_pressed = entry.auto_install
	_existing_label.text = "Registry id %s, installed in addons/%s. Id and folder stay the same." % [entry.id, entry.folder]
	_existing_label.visible = true
	var search_now := false
	match entry.source.get("type"):
		LoadoutRegistry.SOURCE_GITHUB:
			_source_option.select(_source_option.get_item_index(SOURCE_GITHUB))
			_repo_edit.text = entry.source["repo"]
		LoadoutRegistry.SOURCE_LOCAL:
			_source_option.select(_source_option.get_item_index(SOURCE_LOCAL))
			_path_edit.text = entry.source["path"]
		LoadoutRegistry.SOURCE_STORE:
			_source_option.select(_source_option.get_item_index(SOURCE_STORE))
			_store_asset = entry.source["asset"]
		_:
			_legacy_source = entry.source.duplicate()
			_source_option.select(_source_option.get_item_index(SOURCE_STORE))
			search_now = true
	_on_source_changed()
	if _source_option.get_selected_id() == SOURCE_STORE:
		_query_edit.text = display_name
		_search_status.text = ("Now from the old Asset Library (#%s). Pick an Asset Store result to switch, or save to keep it."
				% _legacy_source.get("asset_id", "?")) if search_now else "Now %s. Search to switch to another asset." % _store_asset
	reset_size()
	if search_now:
		_search()


func _on_source_changed() -> void:
	var selected := _source_option.get_selected_id()
	_github_box.visible = selected == SOURCE_GITHUB
	_store_box.visible = selected == SOURCE_STORE
	_local_box.visible = selected == SOURCE_LOCAL
	match selected:
		SOURCE_GITHUB:
			_on_repo_changed()
		SOURCE_LOCAL:
			_update_from_path()
		_:
			_validate()
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


func _search() -> void:
	if not store_search.is_valid():
		_search_status.text = "Search is not available."
		return
	_search_button.disabled = true
	_search_status.text = "Searching…"
	_results.clear()
	_store_asset = ""
	var result: Dictionary = await store_search.call(_query_edit.text)
	_search_button.disabled = false
	if not result["ok"]:
		_search_status.text = result["error"]
		_validate()
		return
	for asset: Dictionary in result["results"]:
		var index := _results.add_item("%s  ·  %s" % [asset["title"], asset["author"]])
		_results.set_item_metadata(index, asset)
	_search_status.text = "Found: %d. Select a plugin." % _results.item_count if _results.item_count > 0 else "Nothing found."
	if _take_over:
		_pick_exact_match()
	_validate()


## For an existing plugin, a result with exactly its name is selected right away.
func _pick_exact_match() -> void:
	var wanted := _normalized(_query_edit.text)
	var matches: Array[int] = []
	for index in _results.item_count:
		if _normalized(str((_results.get_item_metadata(index) as Dictionary)["title"])) == wanted:
			matches.append(index)
	if matches.size() == 1:
		_results.select(matches[0])
		_on_result_selected(matches[0])


func _normalized(text: String) -> String:
	return RegEx.create_from_string("[^a-z0-9]+").sub(text.to_lower(), "", true)


func _on_result_selected(index: int) -> void:
	var asset: Dictionary = _results.get_item_metadata(index)
	_store_asset = asset["asset"]
	if _auto_names:
		# "Debug Draw 3D" -> "debug_draw_3d"; check it matches the folder inside the package.
		var name := RegEx.create_from_string("[^a-z0-9]+").sub(str(asset["title"]).to_lower(), "_", true)
		_set_names(name.trim_prefix("_").trim_suffix("_"))
	_search_status.text = "%s. If the package uses another folder, Loadout asks on the first install." % _store_asset
	_validate()


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
	var has_source := false
	match _source_option.get_selected_id():
		SOURCE_GITHUB:
			has_source = _repo_edit.text.strip_edges() != ""
		SOURCE_STORE:
			has_source = _store_asset != "" or not _legacy_source.is_empty()
		SOURCE_LOCAL:
			has_source = _plugin_dir(_path_edit.text.strip_edges()) != ""
	var parsed := LoadoutRegistry.parse_entry(_entry_data())
	_error_label.text = parsed["error"] if has_source and not parsed["ok"] else ""
	_error_label.visible = _error_label.text != ""
	get_ok_button().disabled = not has_source or not parsed["ok"]


func _entry_data() -> Dictionary:
	return {
		"id": _id_edit.text.strip_edges(),
		"folder": _folder_edit.text.strip_edges(),
		"source": _source_data(),
		"range": _range_edit.text.strip_edges(),
		"auto_install": _auto_check.button_pressed,
	}


func _source_data() -> Dictionary:
	match _source_option.get_selected_id():
		SOURCE_GITHUB:
			return { "type": LoadoutRegistry.SOURCE_GITHUB, "repo": _repo_edit.text.strip_edges() }
		SOURCE_STORE:
			if _store_asset == "" and not _legacy_source.is_empty():
				return _legacy_source
			return { "type": LoadoutRegistry.SOURCE_STORE, "asset": _store_asset }
	return { "type": LoadoutRegistry.SOURCE_LOCAL, "path": _path_edit.text.strip_edges() }


func _on_confirmed() -> void:
	if _editing_id != "":
		entry_edited.emit(_editing_id, _entry_data())
	else:
		entry_submitted.emit(_entry_data(), _take_over)


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
