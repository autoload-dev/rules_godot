extends VBoxContainer
## Writes, reads and queries Cloud Firestore documents and shows the outcome.
##
## Set the project setting `examples/firestore_emulator` to "host:port" to use the Firestore
## emulator instead of the Firebase project in the placeholder configuration.

const COLLECTION := "demo"

var _writes := 0


func _ready() -> void:
	if not FirebaseFirestore.is_supported():
		for button: Button in [%WriteDocument, %ReadDocument, %QueryDocuments]:
			button.disabled = true
		%FirestoreStatus.text = "Firestore is unavailable on %s." % OS.get_name()
		return
	var emulator: String = ProjectSettings.get_setting("examples/firestore_emulator", "")
	if not emulator.is_empty():
		FirebaseFirestore.use_emulator(emulator.get_slice(":", 0), emulator.get_slice(":", 1).to_int())
		%FirestoreStatus.text = "Firestore emulator at %s." % emulator
	%WriteDocument.pressed.connect(_on_write_pressed)
	%ReadDocument.pressed.connect(_on_read_pressed)
	%QueryDocuments.pressed.connect(_on_query_pressed)


func _document_path() -> String:
	return "%s/%s" % [COLLECTION, OS.get_name().to_lower()]


func _on_write_pressed() -> void:
	_writes += 1
	var data := {
		"platform": OS.get_name(),
		"writes": _writes,
		"updated": Time.get_unix_time_from_system(),
		"tags": ["godot", "bazel"],
	}
	var task := FirebaseFirestore.set_document(_document_path(), data)
	await task.completed
	_show(task, "Wrote %s (writes: %d)." % [_document_path(), _writes])


func _on_read_pressed() -> void:
	var task := FirebaseFirestore.get_document(_document_path())
	await task.completed
	_show(task, "Read %s: %s" % [_document_path(), task.result])


func _on_query_pressed() -> void:
	var task := FirebaseFirestore.query(COLLECTION, [["writes", ">=", 1]], "writes", true, 5)
	await task.completed
	var ids := PackedStringArray()
	if task.error.is_empty():
		for document: Dictionary in task.result:
			ids.append("%s (%d)" % [document.id, document.data.writes])
	_show(task, "Query: %s" % ", ".join(ids))


func _show(task: FirestoreTask, success: String) -> void:
	%FirestoreStatus.text = success if task.error.is_empty() else "Firestore error: %s" % task.error
