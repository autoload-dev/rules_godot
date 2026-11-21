extends GdUnitTestSuite

func test_concatenation() -> void:
	assert_str("rules" + "_godot").is_equal("rules_godot")
