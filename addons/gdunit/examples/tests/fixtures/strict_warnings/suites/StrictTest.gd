extends GdUnitTestSuite


func test_runs_under_strict_warnings() -> void:
	var _checked: GdUnitBoolAssert = assert_bool(true).is_true()
