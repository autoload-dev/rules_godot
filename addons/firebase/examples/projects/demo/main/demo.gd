extends Control
## Logs Google Analytics for Firebase events and shows what happened. The Firestore part is
## firestore_demo.gd.

var _count := 0


func _ready() -> void:
	%Platform.text = "Firebase · %s" % OS.get_name()
	# The headless test (BUILD.bazel) checks the add-ons where Firebase is unsupported.
	if DisplayServer.get_name() == "headless":
		await _check_unsupported()
		get_tree().quit()
		return
	if not FirebaseAnalytics.is_supported():
		%LogEvent.disabled = true
		%Status.text = "Firebase is unavailable on %s." % OS.get_name()
		return
	Firebase.initialized.connect(_on_initialized)
	_on_initialized(Firebase.is_initialized)
	%LogEvent.pressed.connect(_on_log_event_pressed)


func _on_initialized(ok: bool) -> void:
	%Status.text = "Firebase app initialized." if ok else "Firebase app not configured."


func _on_log_event_pressed() -> void:
	_count += 1
	FirebaseAnalytics.log_event("demo_button", {"count": _count, "source": "godot"})
	%Status.text = "Logged demo_button #%d." % _count


## Every add-on loads and does nothing: calls succeed quietly, Firestore tasks fail.
func _check_unsupported() -> void:
	if Firebase.is_initialized or FirebaseCore.is_supported() or FirebaseAnalytics.is_supported():
		push_error("Firebase reports support on %s." % OS.get_name())
	FirebaseAnalytics.log_event("headless", {"nothing": null, "vector": Vector2.ONE})
	var task := FirebaseFirestore.get_document("demo/headless")
	await task.completed
	if not task.done or task.error.is_empty():
		push_error("The Firestore task did not fail: %s" % task.error)
	print("Firebase does nothing on %s; Firestore: %s" % [OS.get_name(), task.error])
