@tool
class_name FakeAUtil
extends RefCounted

const VERSION := "1.1.0"


# Appends an event to Engine meta so the Loadout prototype can observe lifecycle order.
# util=<VERSION> reveals a stale cached class if it differs from the caller's version.
static func record(event: String, caller_version: String) -> void:
	var events: PackedStringArray = Engine.get_meta("fake_a_events", PackedStringArray())
	events.append("%s caller=%s util=%s" % [event, caller_version, VERSION])
	Engine.set_meta("fake_a_events", events)
