extends GdUnitTestSuite

func test_deliberate_skip(_do_skip := true, _skip_reason := "fixture proves zero executed tests are rejected") -> void:
	assert_bool(false).is_true()
