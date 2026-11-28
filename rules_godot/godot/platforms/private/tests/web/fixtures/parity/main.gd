extends Node

# Quits with the code its user arguments name, as code=<n>, after a few frames, so the page
# reports the exit: a quit in the first frames can hang the web audio driver.
var _frames := 0


func _ready() -> void:
	print("web parity ready")


func _process(_delta: float) -> void:
	_frames += 1
	if _frames < 10:
		return
	var code := 0
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("code="):
			code = int(argument.trim_prefix("code="))
	print("web parity exits with %d" % code)
	get_tree().quit(code)
