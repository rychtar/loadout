@tool
extends VBoxContainer

## Dock "Loadout": state of every global plugin in this project and its actions.
## Talks only to LoadoutManager (methods and signals). Built in code, colors and icons come from
## the editor theme so it fits light and dark themes.

const RegistryDialog := preload("registry_dialog.gd")
const Status := LoadoutManager.Status

const STATUS_TEXT := {
	Status.OK: "Up to date",
	Status.MISSING: "Missing",
	Status.UPDATE: "Update",
	Status.MODIFIED: "Modified",
	Status.PINNED: "Pinned",
	Status.IGNORED: "Ignored",
	Status.UNMANAGED: "Not managed",
	Status.UNVERIFIED: "Unverified",
	Status.ORPHAN: "Not in registry",
}

var manager: LoadoutManager

var _info_label: Label
var _problems_label: Label
var _install_missing_button: Button
var _tree: Tree
var _detail_title: Label
var _detail_message: Label
var _detail_grid: GridContainer
var _detail_actions: HFlowContainer
var _busy_label: Label
var _confirm: ConfirmationDialog
var _alert: AcceptDialog
var _registry_dialog: RegistryDialog
var _on_confirm: Callable
var _selected_id := ""
var _busy := false


func _ready() -> void:
	name = "Loadout"
	custom_minimum_size = Vector2(280, 0)
	add_theme_constant_override("separation", 6)
	_build()
	manager.states_changed.connect(_rebuild)
	manager.restart_recommended.connect(_offer_restart)
	_rebuild()


func _exit_tree() -> void:
	for dialog: Window in [_confirm, _alert, _registry_dialog]:
		if is_instance_valid(dialog):
			dialog.queue_free()


## Called after the startup sync: offers to install plugins missing in this project.
func offer_missing(ids: PackedStringArray) -> void:
	var lines: PackedStringArray = []
	for id in ids:
		var state := manager.get_state(id)
		var version := state.target_version if state.target_version != "" else "?"
		lines.append("•  %s %s  (%s)" % [state.display_name, version, _short_source(state.source_label)])
	_ask("%d global plugin(s) missing in this project:\n\n%s\n\nInstall them now?" % [ids.size(), "\n".join(lines)],
			"Install all", _install_missing, "Later")


func _build() -> void:
	var header := HBoxContainer.new()
	add_child(header)
	_info_label = Label.new()
	_info_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_info_label.clip_text = true
	header.add_child(_info_label)
	header.add_child(_icon_button("Reload", "Reload the registry and the lock", func() -> void: _run(manager.refresh)))
	header.add_child(_icon_button("Add", "Add a plugin to the global registry", func() -> void: _registry_dialog.open()))

	_problems_label = Label.new()
	_problems_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_problems_label.add_theme_color_override("font_color", _theme_color("error_color", Color(1, 0.47, 0.42)))
	add_child(_problems_label)

	_install_missing_button = Button.new()
	_install_missing_button.pressed.connect(func() -> void: _run(_install_missing))
	add_child(_install_missing_button)

	_tree = Tree.new()
	_tree.columns = 3
	_tree.hide_root = true
	_tree.select_mode = Tree.SELECT_ROW
	_tree.column_titles_visible = true
	_tree.set_column_title(0, "Plugin")
	_tree.set_column_title(1, "Status")
	_tree.set_column_title(2, "Version")
	_tree.set_column_expand(1, false)
	_tree.set_column_expand(2, false)
	var scale := EditorInterface.get_editor_scale()
	_tree.set_column_custom_minimum_width(1, roundi(84 * scale))
	_tree.set_column_custom_minimum_width(2, roundi(64 * scale))
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.custom_minimum_size = Vector2(0, 160)
	_tree.item_selected.connect(_on_item_selected)
	add_child(_tree)

	add_child(HSeparator.new())
	_detail_title = Label.new()
	_detail_title.add_theme_font_override("font", _theme_font("bold"))
	_detail_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_detail_title)
	_detail_message = Label.new()
	_detail_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_detail_message)
	_detail_grid = GridContainer.new()
	_detail_grid.columns = 2
	_detail_grid.add_theme_constant_override("h_separation", 12)
	add_child(_detail_grid)
	_detail_actions = HFlowContainer.new()
	add_child(_detail_actions)
	_busy_label = Label.new()
	_busy_label.text = "Working…"
	_busy_label.visible = false
	add_child(_busy_label)

	var base := EditorInterface.get_base_control()
	var dialog_size := Vector2i(roundi(480 * scale), 0)
	_confirm = ConfirmationDialog.new()
	_confirm.dialog_autowrap = true
	_confirm.min_size = dialog_size
	_confirm.cancel_button_text = "Cancel"
	_confirm.confirmed.connect(func() -> void:
		if _on_confirm.is_valid():
			_run(_on_confirm))
	base.add_child(_confirm)
	_alert = AcceptDialog.new()
	_alert.dialog_autowrap = true
	_alert.min_size = dialog_size
	base.add_child(_alert)
	_registry_dialog = RegistryDialog.new()
	_registry_dialog.entry_submitted.connect(func(data: Dictionary) -> void:
		_run(func() -> String: return await manager.add_registry_entry(data)))
	base.add_child(_registry_dialog)


func _rebuild() -> void:
	_tree.clear()
	var root := _tree.create_item()
	for state in manager.states:
		var item := _tree.create_item(root)
		item.set_text(0, state.display_name)
		item.set_tooltip_text(0, "%s\n%s" % [state.id, state.source_label])
		item.set_tooltip_text(1, state.message)
		item.set_metadata(0, state.id)
		item.set_text(1, STATUS_TEXT[state.status])
		item.set_custom_color(1, _status_color(state.status))
		item.set_text(2, _version_text(state))
		if state.id == _selected_id:
			item.select(0)
	_info_label.text = "Registry: %d · %s" % [manager.registry.entries.size() if manager.registry != null else 0, manager.lock_path.get_file()]
	var problems := manager.errors.duplicate()
	problems.append_array(manager.warnings)
	_problems_label.text = "\n".join(problems)
	_problems_label.visible = not problems.is_empty()
	var missing := manager.missing_ids()
	_install_missing_button.text = "Install missing (%d)" % missing.size()
	_install_missing_button.visible = not missing.is_empty()
	_update_detail()


func _update_detail() -> void:
	for container: Container in [_detail_grid, _detail_actions]:
		for child in container.get_children():
			container.remove_child(child)
			child.queue_free()
	var state := manager.get_state(_selected_id)
	if state == null:
		_detail_title.text = ""
		_detail_message.text = "The registry is empty. Add a plugin with the + button." if manager.states.is_empty() and manager.errors.is_empty() else "Select a plugin in the list."
		return
	var folder := state.entry.folder if state.entry != null else state.id
	_detail_title.text = "%s  (addons/%s)" % [state.display_name, folder]
	_detail_message.text = state.message
	_detail_message.visible = state.message != ""
	if state.entry != null:
		_add_row("Source", _short_source(state.source_label), state.source_label)
		_add_row("Range", state.entry.version_range)
	_add_row("In project", state.installed_version if state.installed_version != "" else "—")
	_add_row("Latest", state.latest_version if state.latest_version != "" else "—")
	if state.lock_entry != null:
		var lock := state.lock_entry
		_add_row("Lock", "%s%s · %s · %s" % [lock.version, " (pin)" if lock.pinned else "", lock.folder_hash.substr(7, 8) if lock.folder_hash != "" else "no hash", lock.installed_at])
	_add_actions(state)


func _add_actions(state: LoadoutManager.PluginState) -> void:
	var id := state.id
	var target := state.target_version
	match state.status:
		Status.MISSING:
			var install := _action("Install %s" % target, func() -> Dictionary: return await manager.install(id), true)
			install.disabled = target == ""
			_action("Ignore in this project", func() -> Error: return await manager.set_ignored(id, true))
		Status.IGNORED:
			_action("Stop ignoring", func() -> Error: return await manager.set_ignored(id, false))
		Status.UPDATE:
			_action("Update to %s…" % target, func() -> void: _confirm_update(state), true)
			_action("Pin to %s" % state.installed_version, func() -> Error: return await manager.set_pinned(id, true))
			_remove_action(state)
		Status.OK, Status.UNVERIFIED:
			_action("Pin to %s" % state.installed_version, func() -> Error: return await manager.set_pinned(id, true))
			_remove_action(state)
		Status.PINNED:
			_action("Unpin", func() -> Error: return await manager.set_pinned(id, false))
			_remove_action(state)
		Status.MODIFIED:
			_action("Accept changes", func() -> Error: return await manager.adopt(id))
			_overwrite_action(state)
			_remove_action(state)
		Status.UNMANAGED:
			_action("Take over", func() -> Error: return await manager.adopt(id))
			_overwrite_action(state)
		Status.ORPHAN:
			_action("Forget (remove from lock)", func() -> Error: return await manager.forget(id))
	if state.entry != null:
		_action("Remove from registry…", func() -> void:
			_ask("Remove %s from the global registry? This affects all projects. Files in this project stay." % state.display_name,
					"Remove from registry", func() -> Error: return await manager.remove_registry_entry(id)))


func _confirm_update(state: LoadoutManager.PluginState) -> void:
	var backup := "user://loadout_backup/%s/%s/" % [state.id, state.installed_version]
	_ask("Update %s %s → %s?\n\nThe plugin is disabled, the old version is backed up to %s, the files are replaced and the plugin is enabled again. If the new version does not start, Loadout restores %s."
			% [state.display_name, state.installed_version, state.target_version, backup, state.installed_version],
			"Update", func() -> Dictionary: return await manager.install(state.id))


func _overwrite_action(state: LoadoutManager.PluginState) -> void:
	if state.target_version == "":
		return
	_action("Overwrite with %s…" % state.target_version, func() -> void:
		_ask("Overwrite folder %s with version %s? The current content is backed up to user://loadout_backup/%s/." % [state.entry.folder, state.target_version, state.id],
				"Overwrite", func() -> Dictionary: return await manager.install(state.id, true)))


func _remove_action(state: LoadoutManager.PluginState) -> void:
	_action("Remove from project…", func() -> void:
		_ask("Remove %s from this project? The folder is backed up to user://loadout_backup/%s/ and Loadout stops installing it here." % [state.display_name, state.id],
				"Remove", func() -> Dictionary: return await manager.uninstall(state.id)))


func _install_missing() -> Dictionary:
	var summary: Dictionary = await manager.install_missing()
	var failed: Dictionary = summary["failed"]
	if failed.is_empty():
		return { "ok": true }
	var lines: PackedStringArray = []
	for id: String in failed:
		lines.append("•  %s: %s" % [id, failed[id]])
	return { "ok": false, "error": "Some plugins could not be installed:\n\n" + "\n".join(lines) }


## Runs an action (may await), keeps the dock disabled meanwhile and reports the result.
func _run(action: Callable) -> void:
	if _busy:
		return
	_set_busy(true)
	var result: Variant = await action.call()
	_set_busy(false)
	_handle_result(result)


func _handle_result(result: Variant) -> void:
	match typeof(result):
		TYPE_DICTIONARY:
			if result.get("ok", false):
				return
			if result.get("needs_confirmation", "") != "":
				var id: String = result["id"]
				_ask(result["error"] + "\n\nOverwrite anyway? The current content is backed up.", "Overwrite",
						func() -> Dictionary: return await manager.install(id, true))
			elif result.get("error", "") != "":
				_show_alert(result["error"])
		TYPE_INT:
			if result != OK:
				_show_alert("Action failed: %s" % error_string(result))
		TYPE_STRING:
			if result != "":
				_show_alert(result)


func _offer_restart() -> void:
	_ask("The new version removed some classes (class_name). The editor keeps listing them until it restarts. Restart now?",
			"Restart editor", func() -> void: EditorInterface.restart_editor(true))


func _set_busy(busy: bool) -> void:
	_busy = busy
	_busy_label.visible = busy
	_install_missing_button.disabled = busy
	for child in _detail_actions.get_children():
		if child is Button:
			child.disabled = busy


func _ask(text: String, ok_text: String, on_confirm: Callable, cancel_text: String = "Cancel") -> void:
	_confirm.dialog_text = text
	_confirm.ok_button_text = ok_text
	_confirm.cancel_button_text = cancel_text
	_on_confirm = on_confirm
	_confirm.reset_size()
	_confirm.popup_centered()


func _show_alert(text: String) -> void:
	_alert.dialog_text = text
	_alert.reset_size()
	_alert.popup_centered()


func _on_item_selected() -> void:
	var item := _tree.get_selected()
	_selected_id = item.get_metadata(0) if item != null else ""
	_update_detail()


func _action(text: String, callable: Callable, primary: bool = false) -> Button:
	var button := Button.new()
	button.text = text
	button.disabled = _busy
	if primary:
		button.add_theme_color_override("font_color", _theme_color("accent_color", Color(0.44, 0.73, 0.98)))
	button.pressed.connect(func() -> void: _run(callable))
	_detail_actions.add_child(button)
	return button


func _add_row(caption: String, value: String, tooltip: String = "") -> void:
	var key := Label.new()
	key.text = caption
	key.modulate = Color(1, 1, 1, 0.7)
	_detail_grid.add_child(key)
	var val := Label.new()
	val.text = value
	val.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	val.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	val.tooltip_text = tooltip
	val.mouse_filter = Control.MOUSE_FILTER_PASS if tooltip != "" else Control.MOUSE_FILTER_IGNORE
	_detail_grid.add_child(val)


## "Local · /very/long/path/addons/x" -> "Local · …/addons/x" (full text in the tooltip).
func _short_source(label: String) -> String:
	var parts := label.split(" · ", true, 1)
	if parts.size() < 2 or parts[1].count("/") < 3:
		return label
	var segments := parts[1].trim_suffix("/").split("/")
	return "%s · …/%s" % [parts[0], "/".join(segments.slice(-2))]


func _icon_button(icon: String, tooltip: String, callable: Callable) -> Button:
	var button := Button.new()
	button.flat = true
	button.tooltip_text = tooltip
	button.icon = EditorInterface.get_editor_theme().get_icon(icon, "EditorIcons")
	button.pressed.connect(callable)
	return button


func _version_text(state: LoadoutManager.PluginState) -> String:
	match state.status:
		Status.MISSING, Status.IGNORED:
			return "—" if state.target_version == "" else "→ " + state.target_version
		Status.UPDATE:
			return "%s → %s" % [state.installed_version, state.latest_version]
		Status.PINNED:
			return state.installed_version + " (pin)"
	return state.installed_version


func _status_color(status: int) -> Color:
	match status:
		Status.OK:
			return _theme_color("success_color", Color(0.45, 0.82, 0.55))
		Status.UPDATE, Status.UNVERIFIED:
			return _theme_color("warning_color", Color(0.94, 0.72, 0.4))
		Status.MODIFIED, Status.ORPHAN:
			return _theme_color("error_color", Color(0.94, 0.57, 0.54))
		Status.MISSING, Status.PINNED, Status.UNMANAGED:
			return _theme_color("accent_color", Color(0.55, 0.76, 0.95))
	return _theme_color("font_disabled_color", Color(0.6, 0.6, 0.6))


func _theme_color(color_name: String, fallback: Color) -> Color:
	var theme := EditorInterface.get_editor_theme()
	return theme.get_color(color_name, "Editor") if theme.has_color(color_name, "Editor") else fallback


func _theme_font(font_name: String) -> Font:
	return EditorInterface.get_editor_theme().get_font(font_name, "EditorFonts")
