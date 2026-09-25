@tool
extends EditorPlugin

const VERSION := "1.2.0"
const AUTOLOAD_NAME := "FakeA"
const AUTOLOAD_PATH := "res://addons/fake_a/fake_a_autoload.gd"
const MENU_ITEM := "Fake A 1.2.0"
const EXTRA_VERSION := FakeAExtra.VERSION


func _enable_plugin() -> void:
	FakeAUtil.record("enable_plugin", VERSION)
	add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)


func _disable_plugin() -> void:
	FakeAUtil.record("disable_plugin", VERSION)
	remove_autoload_singleton(AUTOLOAD_NAME)


func _enter_tree() -> void
	this is not valid gdscript
	FakeAUtil.record("plugin_enter", VERSION)
	Engine.set_meta("fake_a_plugin_version", VERSION)
	Engine.set_meta("fake_a_extra_version", EXTRA_VERSION)
	add_tool_menu_item(MENU_ITEM, func() -> void: pass)


func _exit_tree() -> void:
	FakeAUtil.record("plugin_exit", VERSION)
	remove_tool_menu_item(MENU_ITEM)
	if Engine.get_meta("fake_a_plugin_version", "") == VERSION:
		Engine.remove_meta("fake_a_plugin_version")
