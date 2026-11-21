extends GdUnitTestSuite


func test_keeps_the_best_score() -> void:
	var board: Scoreboard = Scoreboard.new()
	board.record("ada", 12)
	board.record("ada", 7)
	assert_int(board.best("ada")).is_equal(12)


func test_a_new_player_has_no_score() -> void:
	assert_int(Scoreboard.new().best("bo")).is_equal(0)
