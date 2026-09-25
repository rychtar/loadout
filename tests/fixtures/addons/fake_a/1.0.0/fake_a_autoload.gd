@tool
extends Node

const VERSION := "1.0.0"


func _enter_tree() -> void:
	FakeAUtil.record("autoload_enter", VERSION)


func _exit_tree() -> void:
	FakeAUtil.record("autoload_exit", VERSION)
