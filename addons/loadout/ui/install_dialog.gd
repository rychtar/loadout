@tool
extends ConfirmationDialog

## "Install global plugins": missing plugins with a checkbox each (all checked by default) and the
## option to stop offering the unchecked ones in this project.

## ids to install, ids to ignore in this project (empty when the option is off)
signal install_chosen(ids: PackedStringArray, ignore: PackedStringArray)

var _intro: Label
var _rows: VBoxContainer
var _ignore_check: CheckBox
var _checks: Dictionary[String, CheckBox] = {}


func _init() -> void:
	title = "Install global plugins"
	cancel_button_text = "Later"
	var scale := EditorInterface.get_editor_scale()
	min_size = Vector2i(roundi(480 * scale), 0)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	add_child(box)
	_intro = Label.new()
	_intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_intro.custom_minimum_size.x = roundi(460 * scale)
	box.add_child(_intro)
	_rows = VBoxContainer.new()
	box.add_child(_rows)
	box.add_child(HSeparator.new())
	_ignore_check = CheckBox.new()
	_ignore_check.text = "Don't offer the unchecked plugins in this project again"
	_ignore_check.button_pressed = true
	box.add_child(_ignore_check)
	confirmed.connect(_on_confirmed)


## items: [{ "id", "label", "enabled": bool, "tooltip" }]
func open_for(items: Array[Dictionary]) -> void:
	for child in _rows.get_children():
		_rows.remove_child(child)
		child.queue_free()
	_checks.clear()
	_intro.text = "%d global plugin(s) missing in this project. Choose which to install:" % items.size()
	for item in items:
		var check := CheckBox.new()
		check.text = item["label"]
		check.tooltip_text = item.get("tooltip", "")
		check.disabled = not item["enabled"]
		check.button_pressed = item["enabled"]
		check.toggled.connect(func(_on: bool) -> void: _update_ok())
		_rows.add_child(check)
		_checks[item["id"]] = check
	_ignore_check.button_pressed = true
	_update_ok()
	reset_size()
	popup_centered()


func _selected() -> PackedStringArray:
	var ids: PackedStringArray = []
	for id in _checks:
		if _checks[id].button_pressed and not _checks[id].disabled:
			ids.append(id)
	return ids


func _update_ok() -> void:
	var count := _selected().size()
	ok_button_text = "Install selected (%d)" % count if count > 0 else "Don't install"


func _on_confirmed() -> void:
	var selected := _selected()
	var ignore: PackedStringArray = []
	if _ignore_check.button_pressed:
		for id in _checks:
			if not selected.has(id):
				ignore.append(id)
	install_chosen.emit(selected, ignore)
