@tool
extends ConfirmationDialog

## "Install plugins": one window with two lists. On the left what is available: your global plugins that
## are missing in this project and the starter pack (tagged, and a checkbox hides it for good). On the
## right what gets installed. Plugins stay on the left, not installed, until the user moves them. Unchecked
## global plugins can be ignored in this project; chosen starters are added to the registry and installed here.

const TransferList := preload("transfer_list.gd")
const DetailDialog := preload("detail_dialog.gd")

const GLOBAL := "global"
const STARTER := "starter"

## ids of global plugins to install, ids of starters to add and install, ids of global plugins to ignore
## in this project (empty when the option is off)
signal install_chosen(ids: PackedStringArray, starters: PackedStringArray, ignore: PackedStringArray)
## The dialog was closed with "Hide the starter pack" ticked.
signal starters_hidden()

## func(id: String) -> Dictionary (LoadoutManager.plugin_details), set by the dock.
var details_provider: Callable

var _intro: Label
var _list: TransferList
var _ignore_check: CheckBox
var _hide_starters_check: CheckBox
var _detail_dialog: DetailDialog
var _titles: Dictionary[String, String] = {}


func _init() -> void:
	title = "Install plugins"
	cancel_button_text = "Later"
	var scale := EditorInterface.get_editor_scale()
	min_size = Vector2i(roundi(860 * scale), 0)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	add_child(box)
	_intro = Label.new()
	_intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_intro.custom_minimum_size.x = roundi(840 * scale)
	_intro.text = "Move the plugins you want in this project to the right. What stays on the left is not installed."
	box.add_child(_intro)
	_list = TransferList.new()
	_list.selection_changed.connect(_update_ok)
	_list.details_requested.connect(_on_details_requested)
	box.add_child(_list)
	_ignore_check = CheckBox.new()
	_ignore_check.text = "Ignore the global plugins I don't install in this project"
	box.add_child(_ignore_check)
	_hide_starters_check = CheckBox.new()
	_hide_starters_check.text = "Hide the starter pack from now on"
	_hide_starters_check.tooltip_text = "Starter plugins are recommendations. This stops offering them. Bring it back with ⋮ → Starter plugins… or in Editor Settings → Loadout."
	# Ticking hides the starters still on the left at once; the ones already moved to the right stay.
	_hide_starters_check.toggled.connect(func(on: bool) -> void: _list.set_section_hidden(STARTER, on))
	box.add_child(_hide_starters_check)
	# A child of this dialog, so it can open on top of it (two exclusive windows of one parent are refused).
	_detail_dialog = DetailDialog.new()
	add_child(_detail_dialog)
	confirmed.connect(_on_confirmed)
	canceled.connect(_apply_hide_starters)


## global_items: missing registry plugins (they start on the right). starter_items: the starter pack
## (they start on the left, tagged), null when the user hid the pack. starter_focus: show the starter
## section first. Cards are described in TransferList.set_section().
func open_for(global_items: Array[Dictionary], starter_items: Variant = null, starter_focus: bool = false) -> void:
	_titles.clear()
	_list.remove_section(GLOBAL)
	_list.remove_section(STARTER)
	_list.set_section(GLOBAL, global_items)
	if starter_items != null:
		var starters: Array[Dictionary] = []
		for item: Dictionary in starter_items:
			var copy := item.duplicate()
			copy["checked"] = false
			copy["tag"] = "Starter"
			starters.append(copy)
		_list.set_section(STARTER, starters)
		for item in starters:
			_titles[item["id"]] = item["title"]
	for item in global_items:
		_titles[item["id"]] = item["title"]
	if starter_focus and starter_items != null:
		_list.show_section(STARTER)
	_ignore_check.visible = not global_items.is_empty()
	_ignore_check.button_pressed = true
	_hide_starters_check.visible = starter_items != null
	_hide_starters_check.button_pressed = false
	_update_ok()
	reset_size()
	popup_centered()
	_fit_list.call_deferred()


## The cards only have their real height after the first layout: fit the lists to them and re-center.
func _fit_list() -> void:
	await get_tree().process_frame
	if visible and _list.fit_height():
		reset_size()
		move_to_center()


## Closing the dialog (install or Later) with the box ticked turns the starter pack off.
func _apply_hide_starters() -> void:
	if _hide_starters_check.visible and _hide_starters_check.button_pressed:
		starters_hidden.emit()


func _update_ok() -> void:
	var count := _list.selected().size()
	ok_button_text = "Install selected (%d)" % count if count > 0 else "Don't install"


func _on_details_requested(id: String) -> void:
	if details_provider.is_valid():
		_detail_dialog.open_for(id, _titles.get(id, id), details_provider)


func _on_confirmed() -> void:
	# Cards that cannot be installed right now (offline, source error) are not a choice of the user,
	# so the list leaves them out of the ignored ones.
	var ignore: PackedStringArray = _list.left_out(GLOBAL) if _ignore_check.visible and _ignore_check.button_pressed else PackedStringArray()
	install_chosen.emit(_list.selected(GLOBAL), _list.selected(STARTER), ignore)
	_apply_hide_starters()
