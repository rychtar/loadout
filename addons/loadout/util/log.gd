@tool
extends RefCounted

## Single logging entry point for Loadout. Everything goes out with the [Loadout] prefix.

enum Level { INFO, WARNING, ERROR }

const PREFIX := "[Loadout]"


static func write(message: String, level: Level = Level.INFO) -> void:
	var line := "%s %s" % [PREFIX, message]
	match level:
		Level.WARNING:
			push_warning(line)
		Level.ERROR:
			push_error(line)
		_:
			print(line)
