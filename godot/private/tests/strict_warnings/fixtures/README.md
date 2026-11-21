# Fixtures of godot/private/tests/strict_warnings

Each section names a fixture and what it reproduces for the tests of this package.

## project_with_strict_warnings

A project whose `project.godot` treats every GDScript warning as an error, below
`res://addons/` too, and has a feature override. Every GDScript rules_godot stages into a
project runs under these settings: the import, initialization and probe plugins, the
validation, the export and shell plugins, the run logger and the test adapters' case
selection.
