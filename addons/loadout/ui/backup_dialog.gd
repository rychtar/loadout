@tool
extends ConfirmationDialog

## "Restore a backup": the backups Loadout made of a plugin before it replaced or removed it, newest
## first. Restoring puts those files back (the current ones are backed up first) and pins that
## version, otherwise the update would be offered right back.

signal backup_chosen(id: String, path: String, pin: bool)

var _id := ""
var _backups: Array[Dictionary] = []
var _list: ItemList
var _pin_check: CheckBox


func _init() -> void:
	title = "Restore a backup"
	ok_button_text = "Restore"
	cancel_button_text = "Cancel"
	var scale := EditorInterface.get_editor_scale()
	min_size = Vector2i(roundi(460 * scale), 0)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	add_child(box)
	_list = ItemList.new()
	_list.custom_minimum_size = Vector2(0, roundi(150 * scale))
	_list.item_selected.connect(func(_index: int) -> void: _update_ok())
	box.add_child(_list)
	_pin_check = CheckBox.new()
	_pin_check.text = "Pin to the restored version (no update offers in this project)"
	_pin_check.button_pressed = true
	box.add_child(_pin_check)
	var note := Label.new()
	note.text = "The files in the project now are backed up first, so the restore can be undone the same way."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.custom_minimum_size.x = roundi(440 * scale)
	note.modulate = Color(1, 1, 1, 0.75)
	box.add_child(note)
	confirmed.connect(_on_confirmed)


func open_for(state: LoadoutManager.PluginState, backups: Array[Dictionary]) -> void:
	_id = state.id
	_backups = backups
	title = "Restore a backup of %s" % state.display_name
	_list.clear()
	for backup in backups:
		_list.add_item(label_for(backup))
	if not backups.is_empty():
		_list.select(0)
	_pin_check.button_pressed = true
	_update_ok()
	reset_size()
	popup_centered()


## "1.0.0  ·  2026-10-05 21:30" (the folder name when the version is unknown).
static func label_for(backup: Dictionary) -> String:
	var local := int(backup["modified"]) + int(Time.get_time_zone_from_system()["bias"]) * 60
	var when := Time.get_datetime_string_from_unix_time(local, true).substr(0, 16)
	var version: String = backup["version"] if backup["version"] != "" else str(backup["name"])
	return "%s  ·  %s" % [version, when]


func _update_ok() -> void:
	get_ok_button().disabled = _list.get_selected_items().is_empty()


func _on_confirmed() -> void:
	var selected := _list.get_selected_items()
	if not selected.is_empty():
		backup_chosen.emit(_id, _backups[selected[0]]["path"], _pin_check.button_pressed)
