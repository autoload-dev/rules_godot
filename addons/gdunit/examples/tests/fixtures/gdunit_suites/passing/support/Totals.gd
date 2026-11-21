## A helper the suites could share: listed with them, but no suite.
extends RefCounted


static func total(values: Array[int]) -> int:
	var sum: int = 0
	for value: int in values:
		sum += value
	return sum
