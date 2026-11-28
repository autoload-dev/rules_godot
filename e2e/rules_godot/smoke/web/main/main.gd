extends Node

# Quits with code 7 after a few frames: a quit in the first frames can hang the page's audio
# driver before the page reports the exit.
var _frames := 0


func _ready() -> void:
	print("web smoke started on %s" % OS.get_name())


func _process(_delta: float) -> void:
	_frames += 1
	if _frames == 5:
		print("web smoke quits")
		get_tree().quit(7)
