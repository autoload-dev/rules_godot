extends SceneTree

## Runs GdUnit for the suites listed in SUITES under Bazel's test contract.
##
##     godot --headless --script res://addons/autoload_gdunit/run.gd \
##         -- [<GdUnit options>]
##
## A suite is a listed script whose base chain ends at GdUnit's GdUnitTestSuite, as GdUnit
## itself defines one; other listed files, such as helper scripts and sidecars, are none.
## Shards and --test_filter then select suites with rules_godot's
## res://addons/rules_godot_test/cases.gd.
## The JUnit report goes to XML_OUTPUT_FILE, all GdUnit reports to
## TEST_UNDECLARED_OUTPUTS_DIR. The run fails when GdUnit fails or runs no test. Orphan
## nodes fail no run, as GdUnit's command line judges them; the log names the tests that
## left them.

@warning_ignore("inferred_declaration")
const Cases := preload("res://addons/rules_godot_test/cases.gd")

const REPORTS: String = "res://.godot/autoload_gdunit"
## The `res://` paths of the suites, one per line, written by gdunit_test.
const SUITES: String = "res://addons/autoload_gdunit/suites.txt"
## The script every GdUnit suite extends.
const SUITE_BASE: String = "res://addons/gdUnit4/src/GdUnitTestSuite.gd"

## The `res://` path of the suite GdUnit runs.
var _suite: String = ""
## The tests and suite hooks that left orphan nodes, as `<suite> > <test>: <count>`.
var _orphans: PackedStringArray = PackedStringArray()


class BazelRunner extends GdUnitTestCIRunner:
	var finish: Callable

	func quit(code: int) -> void:
		var exit_code: int = finish.call(code)
		await super(exit_code)


func _initialize() -> void:
	var selected: Variant = Cases.select(SUITES, "suite", _is_suite)
	if selected is int:
		var code: int = selected
		quit(code)
		return
	var suites: PackedStringArray = selected
	var command: PackedStringArray = PackedStringArray(
		["GdUnitCmdTool.gd", "--ignoreHeadlessMode", "-c", "-rd", REPORTS, "-rc", "1"]
	)
	for suite: String in suites:
		command.append_array(["-a", suite])
	command.append_array(OS.get_cmdline_user_args())
	var _connected: int = GdUnitSignals.instance().gdunit_event.connect(_on_gdunit_event)
	var runner: BazelRunner = BazelRunner.new()
	runner.finish = _finish
	runner._debug_cmd_args = command
	root.add_child(runner)


## Whether the listed file is a GdUnit suite: a script extending GdUnitTestSuite. A
## script that does not load counts, so GdUnit reports why and the run fails.
static func _is_suite(path: String) -> bool:
	if not path.ends_with(".gd"):
		return false
	var script: Script = load(path) as Script
	if script == null:
		return true
	while script != null:
		if script.resource_path == SUITE_BASE:
			return true
		script = script.get_base_script()
	return false


## Records the tests and suite hooks that left orphan nodes. Suites run one at a time,
## so a test's event belongs to the suite that started last.
func _on_gdunit_event(event: GdUnitEvent) -> void:
	match event.type():
		GdUnitEvent.TESTSUITE_BEFORE:
			_suite = event.resource_path()
		GdUnitEvent.TESTCASE_AFTER, GdUnitEvent.TESTSUITE_AFTER:
			if event.orphan_nodes() > 0:
				var _appended: bool = _orphans.append("%s > %s: %d" % [_suite, event.test_name(), event.orphan_nodes()])


## Publishes GdUnit's reports and returns the exit code of the run.
func _finish(code: int) -> int:
	var reports: String = ProjectSettings.globalize_path(REPORTS)
	var outputs: String = OS.get_environment("TEST_UNDECLARED_OUTPUTS_DIR")
	if outputs:
		_copy_tree(reports, outputs.path_join("gdunit"))
	var results: String = _find(reports, "results.xml")
	if results.is_empty():
		printerr("autoload_gdunit: GdUnit wrote no JUnit report (exit %d)" % code)
		return code if code != 0 else 1
	var xml_output: String = OS.get_environment("XML_OUTPUT_FILE")
	if xml_output:
		var error: Error = DirAccess.copy_absolute(results, xml_output)
		if error != OK:
			printerr("autoload_gdunit: cannot write %s: %s" % [xml_output, error_string(error)])
			return 1
	var summary: Dictionary[String, int] = _summarize(results)
	print("autoload_gdunit: GdUnit ran %d tests, %d skipped, %d failed" % [
		summary["tests"], summary["skipped"], summary["failed"]
	])
	if summary["failed"] > 0:
		return code if code != 0 else 1
	if summary["tests"] - summary["skipped"] < 1:
		printerr("autoload_gdunit: GdUnit executed no test")
		return 1
	# GdUnit's warning code: orphan nodes in an otherwise passing run.
	if code == GdUnitTestCIRunner.RETURN_WARNING:
		print("autoload_gdunit: warning: GdUnit detected possible orphan nodes, which fail no test:")
		for orphan: String in _orphans:
			print("autoload_gdunit:   " + orphan)
		if _orphans.is_empty():
			print("autoload_gdunit:   see the WARNING reports of the tests above")
		return 0
	return code


func _summarize(path: String) -> Dictionary[String, int]:
	var summary: Dictionary[String, int] = {"tests": 0, "skipped": 0, "failed": 0}
	var parser: XMLParser = XMLParser.new()
	if parser.open(path) != OK:
		return summary
	while parser.read() == OK:
		if parser.get_node_type() != XMLParser.NODE_ELEMENT:
			continue
		match parser.get_node_name():
			"testcase":
				summary["tests"] += 1
			"skipped":
				summary["skipped"] += 1
			"failure", "error":
				summary["failed"] += 1
	return summary


func _find(directory: String, file_name: String) -> String:
	var entries: DirAccess = DirAccess.open(directory)
	if entries == null:
		return ""
	for child: String in entries.get_directories():
		var found: String = _find(directory.path_join(child), file_name)
		if found:
			return found
	return directory.path_join(file_name) if entries.file_exists(file_name) else ""


func _copy_tree(source: String, destination: String) -> void:
	var entries: DirAccess = DirAccess.open(source)
	if entries == null:
		return
	var _made: Error = DirAccess.make_dir_recursive_absolute(destination)
	for child: String in entries.get_directories():
		_copy_tree(source.path_join(child), destination.path_join(child))
	for file: String in entries.get_files():
		var _copied: Error = DirAccess.copy_absolute(source.path_join(file), destination.path_join(file))
