"""Read Godot export preset options, which godot_pack holds as Godot literals."""

visibility(["//godot/..."])

_FIELDS = ["key", "owner", "authored", "placement", "when", "derive"]

# Each policy field the vocabulary bounds, its allowed values and the diagnostic, in check order.
_VOCABULARY = [
    ("authored", ["reject", "match", "live"], "unknown authored mode or placement"),
    ("placement", ["pack", "preset", "prelude"], "unknown authored mode or placement"),
    (
        "when",
        [
            "always",
            "application_identity",
            "macos_application",
            "ios_application",
            "android_application",
        ],
        "unknown applicability guard",
    ),
]
_LIVE_EXCEPTION = {"key": "binary_format/embed_pck", "derive": "constant", "placement": "prelude"}
_IOS_FAMILY_CHOICES = ["ipad", "ipad,iphone", "iphone"]

def _policy_error(where, message):
    fail("Godot %s / %s / %s: %s" % (where.version, where.operating_system, where.key, message))

def _application_value(application_values, source, expected_type, where):
    if source not in application_values or type(application_values[source]) != expected_type:
        _policy_error(where, "missing or invalid application context value " + source)
    return application_values[source]

def _constant_problem(row, _scope):
    if type(row["value"]) not in ["bool", "int", "string"]:
        return "constant must be a typed scalar"
    return None

def _constant_value(row, _context, _profile, _where):
    return row["value"]

def _first_cpu_problem(_row, scope):
    if scope.operating_system not in ["linux", "macos"]:
        return "first_cpu requires a desktop exporter"
    return None

def _first_cpu_value(_row, context, _profile, where):
    if len(context.cpus) != 1:
        _policy_error(where, "desktop CPU selection must be a singleton")
    return context.cpus[0]

def _cpu_member_problem(row, scope):
    profile = scope.profile
    cpus = {
        "android": profile["android"]["abis"],
        "ios": profile["ios"]["cpus"],
    }.get(scope.operating_system, [])
    if type(row["cpu"]) != "string" or row["cpu"] not in cpus:
        return "cpu must name a profile CPU tag"
    return None

def _cpu_member_value(row, context, _profile, _where):
    return row["cpu"] in context.cpus

def _application_value_problem(row, _scope):
    sources = ["application_id", "macos_minimum_os_version", "ios_minimum_os_version"]
    if row["source"] not in sources:
        return "unsupported application context value"
    return None

def _application_value_value(row, context, _profile, where):
    return _application_value(context.application_context, row["source"], "string", where)

def _is_family_choices(choices):
    if type(choices) != "dict" or any([type(choice) != "string" for choice in choices]):
        return False
    values = choices.values()
    return sorted(choices) == _IOS_FAMILY_CHOICES and all([type(value) == "int" for value in values])

def _application_enum_problem(row, _scope):
    if row["source"] != "ios_families" or not _is_family_choices(row["choices"]):
        return "expected normalized iOS family choices with integer values"
    return None

def _application_enum_value(row, context, _profile, where):
    families = _application_value(context.application_context, row["source"], "list", where)
    if any([type(family) != "string" for family in families]):
        _policy_error(where, "invalid iOS family set")
    normalized = ",".join(sorted(families))
    if normalized not in row["choices"]:
        _policy_error(where, "invalid iOS family set")
    return row["choices"][normalized]

def _android_sdk_problem(row, scope):
    if scope.operating_system != "android" or row["sdk"] not in ["min", "target"]:
        return "a derived SDK value requires android and min or target"
    return None

def _android_sdk_value(row, context, profile, where):
    application_values = context.application_context
    minimum = _application_value(application_values, "android_min_sdk_version", "int", where)
    target = _application_value(application_values, "android_target_sdk_version", "int", where)
    minimum = minimum or int(profile["android"]["min_sdk"])
    target = target or int(profile["android"]["target_sdk"])
    if target < minimum or minimum < int(profile["android"]["min_sdk"]):
        _policy_error(
            where,
            "Android target SDK must be >= minimum SDK, and minimum must support the selected engine",
        )
    return str(minimum if row["sdk"] == "min" else target)

def _web_threads_problem(_row, scope):
    return None if scope.operating_system == "web" else "web_threads requires the web exporter"

def _web_threads_value(_row, context, _profile, _where):
    return context.threads

# Each derivation's operands, the policy check of its row and the value it derives.
_OPERATIONS = {
    "constant": struct(operands = ["value"], problem = _constant_problem, value = _constant_value),
    "web_threads": struct(operands = [], problem = _web_threads_problem, value = _web_threads_value),
    "first_cpu": struct(operands = [], problem = _first_cpu_problem, value = _first_cpu_value),
    "cpu_member": struct(
        operands = ["cpu"],
        problem = _cpu_member_problem,
        value = _cpu_member_value,
    ),
    "application_value": struct(
        operands = ["source"],
        problem = _application_value_problem,
        value = _application_value_value,
    ),
    "application_enum": struct(
        operands = ["source", "choices"],
        problem = _application_enum_problem,
        value = _application_enum_value,
    ),
    "android_sdk": struct(
        operands = ["sdk"],
        problem = _android_sdk_problem,
        value = _android_sdk_value,
    ),
}

def _field_problem(row, _scope):
    if any([field not in row for field in _FIELDS]):
        return "missing required policy fields"
    if any([type(row[field]) != "string" or not row[field] for field in _FIELDS]):
        return "policy fields must be nonempty strings"
    return None

def _identity_problem(row, scope):
    if row["key"] in scope.seen:
        return "duplicate owned option"
    if row["owner"] not in scope.owners:
        return "unknown diagnostic owner"
    return None

def _vocabulary_problem(row, _scope):
    for field, allowed, problem in _VOCABULARY:
        if row[field] not in allowed:
            return problem
    if row["derive"] not in _OPERATIONS:
        return "unknown derivation"
    return None

def _is_reason(value):
    return type(value) == "string" and bool(value.strip())

def _operand_problem(row, _scope):
    operands = _OPERATIONS[row["derive"]].operands
    allowed = _FIELDS + operands + ["exception"]
    missing = [field for field in operands if field not in row]
    if missing or any([field not in allowed for field in row]):
        return "missing or unexpected operation operands"
    if "exception" in row and not _is_reason(row["exception"]):
        return "exception must document its reason and removal condition"
    return None

def _is_live_exception(row, operating_system):
    if operating_system != "macos" or "exception" not in row:
        return False
    return all([row[field] == value for field, value in _LIVE_EXCEPTION.items()])

def _placement_problem(row, scope):
    if row["authored"] == "match" and row["placement"] != "pack":
        return "matched mirrors must be pack values"
    if row["authored"] == "live" and not _is_live_exception(row, scope.operating_system):
        return "a live derived value requires a documented prelude exception"
    if row["derive"] in ["first_cpu", "cpu_member"] and row["placement"] == "pack":
        return "derived CPU values cannot be pack mirrors"
    return None

def _operation_problem(row, scope):
    return _OPERATIONS[row["derive"]].problem(row, scope)

def _overlap_problem(row, scope):
    if row["key"] in scope.rejected:
        return "overlap with the rejected export options"
    return None

# The checks of an owned option row, in diagnostic order; each returns the first problem or None.
_ROW_CHECKS = [
    _field_problem,
    _identity_problem,
    _vocabulary_problem,
    _operand_problem,
    _placement_problem,
    _operation_problem,
    _overlap_problem,
]

def _row_problem(row, scope):
    if type(row) != "dict":
        return "missing required policy fields"
    for check in _ROW_CHECKS:
        problem = check(row, scope)
        if problem:
            return problem
    return None

def _validate_policy(profile, operating_system, version):
    rows = profile.get("owned_export_options", {}).get(operating_system)
    if type(rows) != "list":
        _policy_error(
            struct(version = version, operating_system = operating_system, key = "<policy>"),
            "expected an owned option row list",
        )
    scope = struct(
        operating_system = operating_system,
        profile = profile,
        seen = {},
        rejected = dict(profile["rejected_export_options"].get(operating_system, {})),
        owners = profile["option_owners"],
    )
    for row in rows:
        key = row.get("key", "<missing>") if type(row) == "dict" else "<row>"
        problem = _row_problem(row, scope)
        if problem:
            where = struct(version = version, operating_system = operating_system, key = key)
            _policy_error(where, problem)
        scope.seen[key] = True
        if row["authored"] == "reject":
            scope.rejected[key] = row["owner"]
    return rows, scope.rejected

def _active(guard, application_values):
    if guard == "application_identity":
        return bool(application_values.get("application_id", ""))
    if guard == "macos_application":
        return "macos_minimum_os_version" in application_values
    if guard == "ios_application":
        return "ios_families" in application_values
    if guard == "android_application":
        return "android_min_sdk_version" in application_values
    return True

def _conflicts_with_authored(row, authored, value):
    key = row["key"]
    if row["authored"] != "match" or key not in authored:
        return False
    return json.decode(authored[key]) != value

def resolve_export_options(authored, context, profile, version):
    """
    Resolve the owned export options of the engine profile into the option sets of a pack.

    Args:
        authored: Original option-to-Godot-literal map.
        context: Configured context with the operating system, CPUs and application context.
        profile: Selected engine profile, including owned and rejected options.
        version: Editor version for policy diagnostics.

    Returns:
        Fresh pack_options, preset_options, preset_prelude and rejected_options maps.
    """
    rows, rejected = _validate_policy(profile, context.operating_system, version)
    _validate_supported_options(authored, rejected, profile["option_owners"])
    option_sets = {"pack": dict(authored), "preset": {}, "prelude": {}}
    for row in rows:
        if not _active(row["when"], context.application_context):
            continue
        key = row["key"]
        where = struct(version = version, operating_system = context.operating_system, key = key)
        value = _OPERATIONS[row["derive"]].value(row, context, profile, where)
        literal = json.encode(value)
        if _conflicts_with_authored(row, authored, value):
            _policy_error(
                where,
                "authored %s conflicts with authoritative godot_app value %s; %s owns it: %s" % (
                    authored[key],
                    literal,
                    row["owner"],
                    profile["option_owners"][row["owner"]],
                ),
            )
        option_sets[row["placement"]][key] = literal
    return struct(
        pack_options = option_sets["pack"],
        preset_options = option_sets["pack"] | option_sets["preset"],
        preset_prelude = option_sets["prelude"],
        rejected_options = rejected,
    )

def string_option(options, name):
    """
    Return a string export option the pack sets, or an empty string.

    Analysis reads only the options that decide which files a rule declares;
    Godot reports every other option to the build tools.

    Args:
        options: GodotPackInfo.export_options.
        name: Option name, such as application/liquid_glass_icon.

    Returns:
        The option's string.
    """
    literal = options.get(name, '""').strip()
    if not literal.startswith('"'):
        fail("Export option %s must be a quoted string, got %r" % (name, literal))

    # Godot keeps line breaks and tabs of multiline text unescaped.
    for character, escape in [("\n", "\\n"), ("\r", "\\r"), ("\t", "\\t")]:
        literal = literal.replace(character, escape)
    return json.decode(literal)

def _validate_supported_options(options, rejected, owners):
    """
    Reject unsupported or Bazel-owned authored options before executing Godot.

    Args:
        options: Authored option-to-literal map.
        rejected: The selected exporter's rejected options, by owner ID.
        owners: Consumer-facing alternatives for the owner IDs Bazel provides.
    """
    for key in options:
        if key in rejected:
            owner = rejected[key]
            fail("Export option %s is %s; %s owns it: %s" % (
                key,
                "bazel-owned" if owner in owners else "unsupported",
                owner,
                owners.get(owner, "unsupported in this workflow"),
            ))
