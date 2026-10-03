@tool
extends ConfirmationDialog

## "Install a version": every version the plugin's source offers, newest first, with release
## notes and a pin option (on for anything but the newest version in range, otherwise Loadout would
## offer the update right back).

signal version_chosen(id: String, version: String, pin: bool)

const NOTES_PREVIEW := 600

var _id := ""
var _versions: Array[Dictionary] = []
var _newest_in_range := ""
var _list: ItemList
var _notes: Label
var _pin_check: CheckBox


func _init() -> void:
	cancel_button_text = "Cancel"
	var scale := EditorInterface.get_editor_scale()
	min_size = Vector2i(roundi(460 * scale), 0)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	add_child(box)
	_list = ItemList.new()
	_list.custom_minimum_size = Vector2(0, roundi(150 * scale))
	_list.item_selected.connect(_on_selected)
	box.add_child(_list)
	_notes = Label.new()
	_notes.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_notes.custom_minimum_size.x = roundi(440 * scale)
	_notes.modulate = Color(1, 1, 1, 0.8)
	box.add_child(_notes)
	_pin_check = CheckBox.new()
	_pin_check.text = "Pin to this version (no update offers in this project)"
	box.add_child(_pin_check)
	confirmed.connect(_on_confirmed)


func open_for(state: LoadoutManager.PluginState, versions: Array[Dictionary]) -> void:
	_id = state.id
	_versions = versions
	_newest_in_range = ""
	for release in versions:
		if release["in_range"]:
			_newest_in_range = release["version"]
			break
	title = "Install a version of %s" % state.display_name
	_list.clear()
	var selected := 0
	for index in versions.size():
		var release: Dictionary = versions[index]
		var marks: PackedStringArray = []
		if release["version"] == _newest_in_range:
			marks.append("newest" if index == 0 else "newest in range")
		if release["version"] == state.installed_version:
			marks.append("installed")
			selected = index
		if release["prerelease"]:
			marks.append("prerelease")
		if not release["in_range"]:
			marks.append("outside the range %s" % state.entry.version_range)
		_list.add_item(release["version"] + ("  (%s)" % ", ".join(marks) if not marks.is_empty() else ""))
	if not versions.is_empty():
		_list.select(selected)
		_on_selected(selected)
	reset_size()
	popup_centered()


func _on_selected(index: int) -> void:
	var release: Dictionary = _versions[index]
	var notes := LoadoutSource.trim_notes(str(release["notes"]).strip_edges(), NOTES_PREVIEW)
	_notes.text = notes if notes != "" else "No release notes."
	_pin_check.button_pressed = release["version"] != _newest_in_range
	ok_button_text = "Install %s" % release["version"]


func _on_confirmed() -> void:
	var selected := _list.get_selected_items()
	if selected.is_empty():
		return
	version_chosen.emit(_id, _versions[selected[0]]["version"], _pin_check.button_pressed)
