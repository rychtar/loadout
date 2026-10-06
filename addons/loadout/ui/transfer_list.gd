@tool
extends HBoxContainer

## The lists in the install dialog: what is available on the left (your global plugins, then the starter
## pack, tagged), what gets installed on the right. A card moves between them with its button or a
## double-click. Each card shows name, version, an optional description and a Details button. Cards that
## cannot be chosen (offline, no version) stay on the left, dimmed, with the reason.

signal selection_changed()
signal details_requested(id: String)

const CARD_HEIGHT := 88
const CARD_GAP := 6
## Height the lists never get below, so moving cards does not make the dialog jump, and the most they
## take (also capped to this part of the screen).
const MIN_HEIGHT := 260
const MAX_HEIGHT := 520
const MAX_SCREEN_SHARE := 0.6

var _left_scroll: ScrollContainer
var _left: VBoxContainer
var _left_title: Label
var _left_empty: Label
var _add_all_button: Button
var _right_scroll: ScrollContainer
var _right: VBoxContainer
var _right_title: Label
var _right_empty: Label
var _clear_button: Button
## section key -> number of cards it was given
var _totals: Dictionary[String, int] = {}
var _cards: Dictionary[String, PanelContainer] = {}
var _buttons: Dictionary[String, Button] = {}
var _on: Dictionary[String, bool] = {}
var _enabled: Dictionary[String, bool] = {}
var _section_of: Dictionary[String, String] = {}
var _order := 0
## Sections whose cards are hidden on the left (the ones already on the right stay).
var _hidden: Dictionary[String, bool] = {}


func _init() -> void:
	var scale := EditorInterface.get_editor_scale()
	add_theme_constant_override("separation", roundi(12 * scale))
	var left_box := _column("Available")
	_left_title = left_box.get_node("Header/Title")
	_left_scroll = left_box.get_node("Frame/Scroll")
	_left = _left_scroll.get_node("Content")
	_add_all_button = _link("Add all", func() -> void: set_all("", true))
	left_box.get_node("Header").add_child(_add_all_button)
	_left_empty = _line("Nothing left to add: everything is on the install list or already in your registry.", scale)
	_left.add_child(_left_empty)
	var right_box := _column("To install in this project")
	_right_title = right_box.get_node("Header/Title")
	_right_scroll = right_box.get_node("Frame/Scroll")
	_right = _right_scroll.get_node("Content")
	_clear_button = _link("Remove all", func() -> void: set_all("", false))
	right_box.get_node("Header").add_child(_clear_button)
	_right_empty = _line("Nothing yet. Add plugins from the list on the left.", scale)
	_right.add_child(_right_empty)
	_update_lists()


## Builds or replaces the cards of a section (cards of one section stay together, in the order the sections
## were set). items: [{ "id", "title", "version" (optional), "description", "note" (why it cannot be
## chosen), "tag" (a small label like "Starter"), "enabled": bool (default true), "checked": bool (default
## true, the card starts on the right) }]
func set_section(key: String, items: Array[Dictionary]) -> void:
	remove_section(key)
	_totals[key] = items.size()
	var scale := EditorInterface.get_editor_scale()
	for item in items:
		_add_card(key, item, scale)
	_update_lists()
	_fit_estimate()


## Hides (or shows again) the cards of a section on the left. Cards already on the right stay there.
func set_section_hidden(key: String, hidden: bool) -> void:
	_hidden[key] = hidden
	for id in _cards:
		if _section_of[id] == key:
			_cards[id].visible = _is_shown(id)
	_update_lists()


## Drops the cards of a section (also from the install list).
func remove_section(key: String) -> void:
	_totals.erase(key)
	_hidden.erase(key)
	for id in _section_of.keys():
		if _section_of[id] == key:
			_cards[id].get_parent().remove_child(_cards[id])
			_cards[id].queue_free()
			for map: Dictionary in [_cards, _buttons, _on, _enabled, _section_of]:
				map.erase(id)
	_update_lists()


## Scrolls the left list to the first card of a section (after the first layout).
func show_section(key: String) -> void:
	await get_tree().process_frame
	for id in _cards:
		if _section_of[id] == key and not _on[id]:
			_left_scroll.ensure_control_visible(_cards[id])
			return


func has_items(key: String) -> bool:
	return _totals.get(key, 0) > 0


## Sizes the lists to the cards as laid out now (call a frame after the dialog is shown). Returns true
## when the height changed.
func fit_height() -> bool:
	var wanted := _left.get_combined_minimum_size().y + _right.get_combined_minimum_size().y
	return _apply_height(wanted)


## Ids on the right, of one section or (without a key) of all.
func selected(section: String = "") -> PackedStringArray:
	return _ids(section, true)


## Ids that can be chosen but stayed on the left.
func left_out(section: String = "") -> PackedStringArray:
	return _ids(section, false)


## Moves every card that can move (of one section, or all) to the right or back. Hidden cards stay.
func set_all(section: String, on: bool) -> void:
	for id in _cards.keys():
		if (section == "" or _section_of[id] == section) and _is_shown(id):
			_move(id, on)


func set_checked(id: String, on: bool) -> void:
	_move(id, on)


## False for a card of a hidden section that is on the left.
func _is_shown(id: String) -> bool:
	return _on[id] or not _hidden.get(_section_of[id], false)


func _ids(section: String, on: bool) -> PackedStringArray:
	var ids: PackedStringArray = []
	for id in _cards:
		if _enabled[id] and _on[id] == on and (section == "" or _section_of[id] == section):
			ids.append(id)
	return ids


## A titled column: a header row (title, then the caller's link) above a framed scrolling list.
func _column(title: String) -> VBoxContainer:
	var scale := EditorInterface.get_editor_scale()
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", roundi(6 * scale))
	add_child(box)
	var header := HBoxContainer.new()
	header.name = "Header"
	box.add_child(header)
	var label := Label.new()
	label.name = "Title"
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_override("font", EditorInterface.get_editor_theme().get_font("bold", "EditorFonts"))
	header.add_child(label)
	var frame := PanelContainer.new()
	frame.name = "Frame"
	frame.add_theme_stylebox_override("panel", _frame_style(scale))
	box.add_child(frame)
	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(roundi(380 * scale), roundi(MIN_HEIGHT * scale))
	frame.add_child(scroll)
	var content := VBoxContainer.new()
	content.name = "Content"
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", roundi(CARD_GAP * scale))
	scroll.add_child(content)
	return box


func _add_card(section: String, item: Dictionary, scale: float) -> void:
	var id: String = item["id"]
	var enabled: bool = item.get("enabled", true)
	var on: bool = enabled and item.get("checked", true)
	var card := PanelContainer.new()
	card.set_meta("order", _order)
	_order += 1
	if not enabled:
		card.modulate = Color(1, 1, 1, 0.55)
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if enabled else Control.CURSOR_ARROW
	card.tooltip_text = "Double-click to move"
	card.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed and event.double_click and event.button_index == MOUSE_BUTTON_LEFT:
			_move(id, not _on[id]))

	var text := VBoxContainer.new()
	text.add_theme_constant_override("separation", 2)
	text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(text)
	var heading := HBoxContainer.new()
	heading.add_theme_constant_override("separation", roundi(8 * scale))
	heading.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text.add_child(heading)
	var title := Label.new()
	title.text = item["title"]
	title.add_theme_font_override("font", EditorInterface.get_editor_theme().get_font("bold", "EditorFonts"))
	heading.add_child(title)
	if item.get("version", "") != "":
		var version := Label.new()
		version.text = item["version"]
		version.add_theme_color_override("font_color", _color("accent_color", Color(0.55, 0.76, 0.95)))
		heading.add_child(version)
	if item.get("tag", "") != "":
		heading.add_child(_tag(item["tag"], scale))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	heading.add_child(spacer)
	var details := _link("Details…", func() -> void: details_requested.emit(id))
	details.tooltip_text = "What the plugin is for and the release notes"
	heading.add_child(details)
	var button := Button.new()
	button.disabled = not enabled
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(func() -> void: _move(id, not _on[id]))
	heading.add_child(button)
	if item.get("description", "") != "":
		text.add_child(_line(item["description"], scale, _color("font_color", Color(0.85, 0.85, 0.85)), 0.8))
	if item.get("note", "") != "":
		text.add_child(_line(item["note"], scale, _color("warning_color", Color(1, 0.87, 0.4))))

	_cards[id] = card
	_buttons[id] = button
	_on[id] = on
	_enabled[id] = enabled
	_section_of[id] = section
	_place(id)


## Puts the card where its state says (the right list or the left one), in the order the cards were
## added, and styles it.
func _place(id: String) -> void:
	var card := _cards[id]
	var target: Control = _right if _on[id] else _left
	if card.get_parent() != target:
		if card.get_parent() != null:
			card.reparent(target, false)
		else:
			target.add_child(card)
	var index := 0
	for sibling in target.get_children():
		if sibling != card and sibling is PanelContainer and sibling.get_meta("order", -1) < card.get_meta("order"):
			index += 1
	target.move_child(card, index)
	card.add_theme_stylebox_override("panel", _card_style(_on[id], EditorInterface.get_editor_scale()))
	card.visible = _is_shown(id)
	_buttons[id].text = "‹ Remove" if _on[id] else "Add ›"


func _move(id: String, on: bool) -> void:
	if not _cards.has(id) or not _enabled[id] or _on[id] == on:
		return
	_on[id] = on
	_place(id)
	_update_lists()
	selection_changed.emit()


## Titles with counts, the "Add all" / "Remove all" links and the notes of an empty list.
func _update_lists() -> void:
	var left := 0
	var movable := 0
	for id in _cards:
		if not _on[id] and _is_shown(id):
			left += 1
			if _enabled[id]:
				movable += 1
	var right := _cards.size() - left
	_left_title.text = "Available (%d)" % left
	_add_all_button.visible = movable > 0
	_left_empty.visible = left == 0
	_right_title.text = "To install in this project (%d)" % right
	_clear_button.visible = right > 0
	_right_empty.visible = right == 0


## Before the first layout: room for the cards by estimate.
func _fit_estimate() -> void:
	_apply_height(_cards.size() * (CARD_HEIGHT + CARD_GAP) * EditorInterface.get_editor_scale())


func _apply_height(wanted: float) -> bool:
	var scale := EditorInterface.get_editor_scale()
	var screen_cap := DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen()).size.y * MAX_SCREEN_SHARE
	var height := clampf(wanted, MIN_HEIGHT * scale, minf(MAX_HEIGHT * scale, screen_cap))
	var changed := not is_equal_approx(_left_scroll.custom_minimum_size.y, height)
	_left_scroll.custom_minimum_size.y = height
	_right_scroll.custom_minimum_size.y = height
	return changed


## A small tinted label next to the name ("Starter").
func _tag(text: String, scale: float) -> PanelContainer:
	var tag := PanelContainer.new()
	var style := StyleBoxFlat.new()
	var accent := _color("accent_color", Color(0.55, 0.76, 0.95))
	style.bg_color = Color(accent, 0.15)
	style.set_corner_radius_all(roundi(8 * scale))
	style.content_margin_left = roundi(7 * scale)
	style.content_margin_right = roundi(7 * scale)
	style.content_margin_top = roundi(1 * scale)
	style.content_margin_bottom = roundi(1 * scale)
	tag.add_theme_stylebox_override("panel", style)
	tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", accent)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tag.add_child(label)
	return tag


func _line(text: String, scale: float, color: Color = Color(0, 0, 0, 0), alpha: float = 1.0) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size.x = roundi(240 * scale)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var tint := color if color.a > 0.0 else _color("font_disabled_color", Color(0.6, 0.6, 0.6))
	label.add_theme_color_override("font_color", Color(tint, tint.a * alpha))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


## The frame of a list: darker than the dialog, so an empty list still reads as a list.
func _frame_style(scale: float) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = _color("dark_color_1", Color(0.1, 0.1, 0.1, 0.6))
	style.set_corner_radius_all(roundi(4 * scale))
	style.set_border_width_all(maxi(1, roundi(scale)))
	style.border_color = _color("dark_color_3", Color(0.2, 0.2, 0.2))
	style.set_content_margin_all(roundi(6 * scale))
	return style


func _card_style(chosen: bool, scale: float) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = _color("dark_color_3", Color(0.17, 0.17, 0.17))
	style.set_corner_radius_all(roundi(4 * scale))
	style.set_border_width_all(maxi(1, roundi(scale)))
	var accent := _color("accent_color", Color(0.55, 0.76, 0.95))
	style.border_color = Color(accent, 0.8) if chosen else Color(1, 1, 1, 0.1)
	style.content_margin_left = roundi(10 * scale)
	style.content_margin_right = roundi(10 * scale)
	style.content_margin_top = roundi(6 * scale)
	style.content_margin_bottom = roundi(8 * scale)
	return style


func _link(text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.flat = true
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_color_override("font_color", _color("accent_color", Color(0.55, 0.76, 0.95)))
	button.pressed.connect(action)
	return button


func _color(color_name: String, fallback: Color) -> Color:
	var theme := EditorInterface.get_editor_theme()
	return theme.get_color(color_name, "Editor") if theme.has_color(color_name, "Editor") else fallback
