@tool
class_name LoadoutEditorBridge
extends RefCounted

## Editor operations the installer needs. The real implementation lives in
## editor/godot_editor_bridge.gd, tests use a fake. Methods may await.
## folder = plugin folder name under res://addons, dir = full path of that folder.


func is_plugin_enabled(_folder: String) -> bool:
	return false


func set_plugin_enabled(_folder: String, _enabled: bool) -> void:
	pass


## True when the plugin's EditorPlugin instance really runs (is_plugin_enabled() is not enough,
## it stays true when the script failed to load).
func is_plugin_running(_folder: String) -> bool:
	return false


## Rescans the project filesystem and waits for it. False on timeout.
func scan() -> bool:
	return true


## Reloads already loaded scripts under dir from disk (scan() does not do that headless).
func refresh_scripts(_dir: String) -> Error:
	return OK


## Checks that the plugin's entry script (plugin.cfg "script") compiles.
func validate_plugin(_dir: String) -> Error:
	return OK


## Checks that every script under dir compiles, for code that is not loaded yet (a staged Loadout
## update). Unlike validate_plugin() it also covers scripts the entry script does not preload.
func validate_scripts(_dir: String) -> Error:
	return OK


## set_plugin_enabled() only queues the project.godot save, this writes it now.
func save_project_settings() -> Error:
	return OK


## Global class names whose script under dir no longer exists (they stay until editor restart).
func stale_classes(_dir: String) -> PackedStringArray:
	return []
