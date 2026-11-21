extends GdUnitTestSuite

func test_deliberate_failure() -> void:
	assert_int(2 + 2).is_equal(5)
