extends SceneTree

## A test adapter with only what adapter_test gives every adapter: its main script at the
## test's main path, its case list at CASES and rules_godot's case selection. A case is a
## listed file named *_case.txt, which holds "pass", "fail" or "error"; an error case reports
## an engine error and passes, because the exit code alone decides the test.

@warning_ignore("inferred_declaration")
const Cases := preload("res://addons/rules_godot_test/cases.gd")

## The `res://` paths of the listed files, one per line, written by adapter_test.
const CASES: String = "res://addons/fake_adapter/cases.txt"


func _initialize() -> void:
	var selected: Variant = Cases.select(CASES, "case", _is_case)
	if selected is int:
		var code: int = selected
		quit(code)
		return
	var cases: PackedStringArray = selected
	var failed: int = 0
	for case: String in cases:
		var outcome: String = FileAccess.get_file_as_string(case).strip_edges()
		print("fake_adapter: %s %s" % [case, outcome])
		if outcome == "error":
			push_error("fake_adapter: a deliberate engine error")
		elif outcome != "pass":
			failed += 1
	quit(1 if failed > 0 else 0)


static func _is_case(path: String) -> bool:
	return path.ends_with("_case.txt")
