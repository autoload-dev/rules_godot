"""An adapter_test whose adapter is the fake adapter of fixtures/fake_adapter."""

load("//godot/private:adapter.bzl", "adapter_test")

visibility("//godot/private/tests/...")

def fake_adapter_test(name, cases, project, **kwargs):
    """
    Declare an adapter_test of the fake adapter over cases.

    Args:
        name: Name of the test target.
        cases: godot_resources targets whose own files the adapter lists.
        project: The godot_project the test runs.
        **kwargs: Further godot_test arguments, such as size and tags.
    """
    adapter_test(
        name = name,
        deps = cases,
        adapter = Label("//godot/private/tests/adapter/fixtures/fake_adapter:run.gd"),
        main = "addons/fake_adapter/run.gd",
        cases = "addons/fake_adapter/cases.txt",
        kwargs = dict(kwargs, project = project),
    )
