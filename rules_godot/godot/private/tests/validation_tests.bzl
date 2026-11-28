"""
What a unit's validation reads, and that no producing action reads it (FR-031, D7).

The fixture's `level` unit has a script extending the global class of `thing`, a scene using
both, the UID sidecar of `thing` in its closure and the extension `hello` among the add-ons
it uses; `outside` is a unit of the same pack outside its closure.
"""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test")
load("@rules_testing//lib:test_suite.bzl", "test_suite")
load(":action_inputs.bzl", "GodotActionsInfo", "actions_of", "godot_actions", "input_paths")

visibility("private")

_FIXTURE = "//godot/private/tests/validation"

def _validation_of(target, unit):
    return [
        entry.action
        for entry in target[GodotActionsInfo].actions.to_list()
        if entry.action.mnemonic == "GodotValidate" and entry.owner.endswith(":" + unit)
    ]

def _test_validation_reads_its_closure(name):
    analysis_test(
        name = name,
        target = _FIXTURE + ":pack",
        impl = _validation_reads_its_closure,
        extra_target_under_test_aspects = [godot_actions],
    )

def _validation_reads_its_closure(env, target):
    validations = _validation_of(target, "level")
    env.expect.where(unit = "level").that_collection(validations).has_size(1)
    inputs = input_paths(validations[0])
    for path in [
        # The unit's scripts and scenes, and the closure's interface and its script's UID
        # sidecar.
        "fixtures/unit/level.gd",
        "fixtures/unit/level.tscn",
        "validation/thing.interface",
        "fixtures/closure/thing.gd.uid",
        # The class fragments of the unit and of its closure.
        "validation/level.classes.json",
        "validation/thing.classes.json",
        # The unit's own import result.
        "validation/level.import",
    ]:
        env.expect.where(unit = "level", input = path).that_bool(
            bool([each for each in inputs if each.endswith("/" + path)]),
        ).equals(True)

    # The closure's script and import result reach the validation through the interface
    # only (#158).
    for path in ["fixtures/closure/thing.gd", "validation/thing.import"]:
        env.expect.where(unit = "level", input = path).that_bool(
            bool([each for each in inputs if each.endswith("/" + path)]),
        ).equals(False)

    # The used extension's tool configuration, which the editor binary loads.
    env.expect.where(unit = "level", input = "extension descriptor").that_bool(
        bool([each for each in inputs if each.endswith("project_with_native_extension/hello.tool.gdextension")]),
    ).equals(True)

    # A script of the pack outside the unit's closure is no input.
    env.expect.where(unit = "level", input = "outside.gd").that_bool(
        bool([each for each in inputs if each.endswith("fixtures/outside/outside.gd")]),
    ).equals(False)

    # The unit with no dependency validates over its own files only.
    outside = _validation_of(target, "outside")
    env.expect.where(unit = "outside").that_collection(outside).has_size(1)
    env.expect.where(unit = "outside", input = "thing.gd").that_bool(
        bool([each for each in input_paths(outside[0]) if each.endswith("fixtures/closure/thing.gd")]),
    ).equals(False)

def _test_no_producing_action_reads_a_validation(name):
    analysis_test(
        name = name,
        target = _FIXTURE + ":pack",
        impl = _no_producing_action_reads_a_validation,
        extra_target_under_test_aspects = [godot_actions],
    )

def _no_producing_action_reads_a_validation(env, target):
    validations = {
        output: True
        for action in actions_of(target, "GodotValidate")
        for output in action.outputs.to_list()
    }
    env.expect.where(field = "validations").that_int(len(validations)).is_greater_than(1)
    for entry in target[GodotActionsInfo].every.to_list():
        env.expect.where(action = entry.action.mnemonic, owner = entry.owner).that_collection(
            [file.short_path for file in entry.action.inputs.to_list() if file in validations],
        ).contains_exactly([])

    # The pack's _validation output group holds them, so building it runs them.
    env.expect.where(field = "_validation").that_collection(
        target[OutputGroupInfo]._validation.to_list(),
    ).contains_at_least(validations.keys())

def _test_dependents_read_interfaces(name):
    analysis_test(
        name = name,
        target = _FIXTURE + ":interface_validations",
        impl = _dependents_read_interfaces,
        extra_target_under_test_aspects = [godot_actions],
    )

def _dependents_read_interfaces(env, target):
    # A function body or an asset's pixels change no input of a dependent's validation
    # (#158): the base's scripts, imported assets, their .import files and the import result
    # reach it as the base's interface, while its scenes stay inputs.
    validations = _validation_of(target, "interface_user")
    env.expect.where(unit = "interface_user").that_collection(validations).has_size(1)
    inputs = input_paths(validations[0])
    for path, read in [
        ("validation/interface_base.interface", True),
        ("fixtures/interface/base/badge.tscn", True),
        ("fixtures/interface/base/base.gd", False),
        ("fixtures/interface/base/badge.png", False),
        ("fixtures/interface/base/badge.png.import", False),
        ("validation/interface_base.import", False),
        # A unit with no interface to derive passes on its import result.
        ("validation/interface_plain.import", True),
        ("fixtures/interface/plain/plain.png", True),
    ]:
        env.expect.where(unit = "interface_user", input = path).that_bool(
            bool([each for each in inputs if each.endswith("/" + path)]),
        ).equals(read)

    # The base validates against its own sources and import result.
    base = input_paths(_validation_of(target, "interface_base")[0])
    for path in ["fixtures/interface/base/base.gd", "validation/interface_base.import"]:
        env.expect.where(unit = "interface_base", input = path).that_bool(
            bool([each for each in base if each.endswith("/" + path)]),
        ).equals(True)

    # The interface reads the base's scripts, its imported assets with their .import files
    # and its import result, nothing else of the closure.
    interfaces = [
        entry.action
        for entry in target[GodotActionsInfo].actions.to_list()
        if entry.action.mnemonic == "GodotUnitInterface" and entry.owner.endswith(":interface_base")
    ]
    env.expect.where(action = "GodotUnitInterface").that_collection(interfaces).has_size(1)
    env.expect.where(action = "GodotUnitInterface").that_collection([
        path.removeprefix("godot/private/tests/validation/")
        for path in input_paths(interfaces[0])
        if path.startswith("godot/private/tests/validation/") and not path.endswith(".interface.json")
    ]).contains_exactly([
        "fixtures/interface/base/badge.png",
        "fixtures/interface/base/badge.png.import",
        "fixtures/interface/base/base.gd",
        "fixtures/interface/base/beep.wav",
        "fixtures/interface/base/beep.wav.import",
        "fixtures/interface/base/body_error.gd",
        "interface_base.import",
    ])

def _absent_direct_modes(target):
    """The modes of the validation manifests of the unit that uses an absent extension."""
    return [
        json.decode(entry.action.content)["mode"]
        for entry in target[GodotActionsInfo].every.to_list()
        if entry.action.mnemonic == "FileWrite" and
           entry.owner.endswith(":platform_probe_absent_direct") and
           entry.action.outputs.to_list()[0].basename.endswith(".validate.json")
    ]

def _test_missing_extension_libraries_report_relaxes_validation(name):
    for case, value, mode in [("report", "report", "report"), ("default", "", "fail")]:
        analysis_test(
            name = name + "_" + case,
            target = _FIXTURE + ":platform_probe_validations",
            impl = _validation_mode_is,
            attrs = {"mode": attr.string()},
            attr_values = {"mode": mode},
            config_settings = {str(Label("//godot:missing_extension_libraries")): value},
            extra_target_under_test_aspects = [godot_actions],
        )
    native.test_suite(name = name, tests = [name + "_report", name + "_default"])

# An application that builds without missing libraries relaxes the validation of the units
# where such an extension is absent; every other build keeps failing on them.
def _validation_mode_is(env, target):
    modes = _absent_direct_modes(target)
    env.expect.that_collection(modes, expr = "validation modes").has_size(1)
    env.expect.that_collection(modes).contains_exactly([env.ctx.attr.mode])

def validation_test_suite(name):
    test_suite(
        name = name,
        tests = [
            _test_no_producing_action_reads_a_validation,
            _test_validation_reads_its_closure,
            _test_dependents_read_interfaces,
            _test_missing_extension_libraries_report_relaxes_validation,
        ],
    )
