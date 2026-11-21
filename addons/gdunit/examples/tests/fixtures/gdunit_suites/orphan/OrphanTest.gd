extends GdUnitTestSuite


func test_leaves_an_orphan_node() -> void:
	var orphan: Node = Node.new()
	assert_str(orphan.get_class()).is_equal("Node")
