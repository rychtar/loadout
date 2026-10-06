@tool
extends AcceptDialog

## Details of one plugin: what it is for (summary from its source) and the release notes of a
## version picked from a list. Opens at once and fills in when the source has answered.

var _title: Label
var _meta: Label
var _summary: Label
var _version_pick: OptionButton
var _notes: Label
var _page_button: LinkButton
var _versions: Array[Dictionary] = []
## Which plugin the dialog was opened for last, so a slow answer for an earlier one is dropped.
var _current_id := ""


func _init() -> void:
	title = "Plugin details"
	ok_button_text = "Close"
	var scale := EditorInterface.get_editor_scale()
	min_size = Vector2i(roundi(500 * scale), 0)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	add_child(box)
	_title = Label.new()
	_title.add_theme_font_override("font", EditorInterface.get_editor_theme().get_font("bold", "EditorFonts"))
	_title.add_theme_font_size_override("font_size", roundi(EditorInterface.get_editor_theme().get_font_size("main_size", "EditorFonts") * 1.3))
	box.add_child(_title)
	_meta = _wrapped(box, scale, true)
	_summary = _wrapped(box, scale, false)
	box.add_child(HSeparator.new())
	var picker := HBoxContainer.new()
	picker.add_theme_constant_override("separation", roundi(8 * scale))
	box.add_child(picker)
	var caption := Label.new()
	caption.text = "Release notes of"
	picker.add_child(caption)
	_version_pick = OptionButton.new()
	_version_pick.item_selected.connect(_show_notes)
	picker.add_child(_version_pick)
	_page_button = LinkButton.new()
	_page_button.text = "Open the page"
	_page_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL | Control.SIZE_SHRINK_END
	_page_button.pressed.connect(func() -> void: OS.shell_open(_page_button.uri))
	picker.add_child(_page_button)
	# Long notes scroll instead of growing the dialog past the screen.
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(0, roundi(180 * scale))
	box.add_child(scroll)
	_notes = Label.new()
	_notes.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_notes.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_notes.custom_minimum_size.x = roundi(300 * scale)
	_notes.modulate = Color(1, 1, 1, 0.85)
	scroll.add_child(_notes)


## provider: func(id: String) -> Dictionary (LoadoutManager.plugin_details), may await.
func open_for(id: String, plugin_title: String, provider: Callable) -> void:
	_current_id = id
	_title.text = plugin_title
	_meta.text = ""
	_summary.text = "Loading…"
	_versions.clear()
	_version_pick.clear()
	_notes.text = ""
	_page_button.visible = false
	reset_size()
	popup_centered()
	var details: Dictionary = await provider.call(id)
	if _current_id == id and visible:
		_fill(details)


func _fill(details: Dictionary) -> void:
	_title.text = details["title"]
	var meta: PackedStringArray = []
	for key in ["meta", "author", "license"]:
		if details.get(key, "") != "":
			meta.append(details[key])
	_meta.text = " · ".join(meta)
	if details["summary"] != "":
		_summary.text = details["summary"]
	else:
		_summary.text = "The source has no description of this plugin." if details["error"] == "" \
				else "No description available: %s" % details["error"]
	_page_button.visible = details["url"] != ""
	_page_button.uri = details["url"]
	_versions.assign(details["versions"])
	_version_pick.clear()
	var selected := 0
	for index in _versions.size():
		var release: Dictionary = _versions[index]
		_version_pick.add_item("%s%s" % [release["version"], "  (pre-release)" if release["prerelease"] else ""])
		if release["version"] == details["selected"]:
			selected = index
	_version_pick.disabled = _versions.is_empty()
	if _versions.is_empty():
		_notes.text = "The source lists no releases."
	else:
		_version_pick.select(selected)
		_show_notes(selected)
	reset_size()
	move_to_center()


func _show_notes(index: int) -> void:
	var notes := str(_versions[index]["notes"]).strip_edges()
	_notes.text = notes if notes != "" else "No release notes for this version."


func _wrapped(parent: Control, scale: float, muted: bool) -> Label:
	var label := Label.new()
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size.x = roundi(480 * scale)
	if muted:
		var theme := EditorInterface.get_editor_theme()
		label.add_theme_color_override("font_color", theme.get_color("font_disabled_color", "Editor"))
	parent.add_child(label)
	return label
