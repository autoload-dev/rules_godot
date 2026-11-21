extends Node
## Initializes the default Firebase app when the game starts.
##
## Autoloaded as `Firebase`. Other Firebase add-ons need the default app; their autoloads
## run after this one.

## Emitted once at startup; `ok` is false where Firebase is unsupported or not configured.
signal initialized(ok: bool)

var is_initialized := false


func _ready() -> void:
	is_initialized = FirebaseCore.initialize()
	if not is_initialized and FirebaseCore.is_supported():
		push_warning("Firebase: the default app is not configured; see firebase_config in @autoload_firebase//config.")
	initialized.emit(is_initialized)
