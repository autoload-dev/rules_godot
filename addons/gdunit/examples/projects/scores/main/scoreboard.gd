class_name Scoreboard
extends RefCounted

## Keeps the best score of each player.

var _best: Dictionary[String, int] = {}


## Records a score; only a better one replaces the player's best.
func record(player: String, score: int) -> void:
	_best[player] = maxi(score, _best.get(player, score))


## The player's best score, or 0 before the first.
func best(player: String) -> int:
	return _best.get(player, 0)
