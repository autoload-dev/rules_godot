extends GdUnitTestSuite

func test_addition() -> void:
	assert_int(2 + 2).is_equal(4)

func test_expected_engine_error() -> void:
	await assert_error(func(): push_error("deliberately checked by GdUnit")).is_push_error("deliberately checked by GdUnit")
