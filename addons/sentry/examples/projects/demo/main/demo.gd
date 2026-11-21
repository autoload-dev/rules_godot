extends Control
## Reports a breadcrumb and a message to Sentry and shows what happened. Lines with the
## SENTRY_DEMO: prefix let a device log be filtered for the demo's output.


func _ready() -> void:
	var enabled := SentrySDK.is_enabled()
	_report("platform=%s enabled=%s" % [OS.get_name(), enabled])
	if not enabled:
		push_error("Sentry did not initialize on %s" % OS.get_name())
	else:
		SentrySDK.add_breadcrumb(SentryBreadcrumb.create("Demo started"))
		var event_id := SentrySDK.capture_message("Hello from the Sentry demo")
		_report("event_id=%s" % event_id)
		if event_id.is_empty():
			push_error("Sentry captured no event")
	# The headless test (BUILD.bazel) passes when the scene runs without engine errors.
	if DisplayServer.get_name() == "headless":
		get_tree().quit()


func _report(line: String) -> void:
	print("SENTRY_DEMO: ", line)
	%Status.text += line + "\n"
