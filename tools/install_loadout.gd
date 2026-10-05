extends SceneTree

## Installs Loadout into a Godot 4 project (copy + enable in project.godot).
##   godot --headless --path <this repo> --script res://tools/install_loadout.gd -- <project folder> [--force]
## tools/install_loadout.sh does the same and finds Godot by itself. Close the target project's
## editor first when replacing an older Loadout (--force).

const Setup := preload("res://tools/loadout_project_setup.gd")
const Log := preload("res://addons/loadout/util/log.gd")

const LOADOUT_DIR := "res://addons/loadout"


func _initialize() -> void:
	var force := false
	var project := ""
	for arg in OS.get_cmdline_user_args():
		if arg == "--force":
			force = true
		elif not arg.begins_with("--") and project == "":
			project = arg
	if project == "":
		print("Usage: godot --headless --path <Loadout> --script res://tools/install_loadout.gd -- <project folder> [--force]")
		quit(2)
		return
	if not project.is_absolute_path():
		# Godot changes its working directory to --path, only the shell's PWD knows where the user was.
		var start_dir := OS.get_environment("PWD")
		if start_dir == "":
			Log.write("Give the project folder as an absolute path (this shell does not tell Godot where it started).", Log.Level.ERROR)
			quit(2)
			return
		project = start_dir.path_join(project)
	project = project.simplify_path()

	var result := Setup.install(ProjectSettings.globalize_path(LOADOUT_DIR), project, force)
	if not result["ok"]:
		Log.write(result["error"], Log.Level.ERROR)
		quit(1)
		return
	match result["action"]:
		Setup.ACTION_INSTALLED:
			Log.write("Loadout %s installed into %s." % [result["version"], project])
		Setup.ACTION_UPDATED:
			if result["previous"] == result["version"]:
				Log.write("Loadout %s in %s replaced with the current files (same version number)." % [result["version"], project])
			else:
				Log.write("Loadout in %s updated %s -> %s." % [project, result["previous"], result["version"]])
		Setup.ACTION_UNCHANGED:
			Log.write("Loadout %s is already in %s, nothing changed." % [result["version"], project])
	Log.write("Open the project in Godot, Loadout offers the missing global plugins.")
	quit(0)
