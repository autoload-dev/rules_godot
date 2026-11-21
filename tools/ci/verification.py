"""Select CI work from hk's plan; path policy remains in hk.pkl."""

import argparse
import json
import os
import subprocess
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# Every lane; the profile lanes are opt-in through the hk profile of the same name.
LANES = ("quality", "docs", "host", "source-engine", "android", "ios")
PROFILE_LANES = ("host", "source-engine", "android", "ios")

# The workflow job that runs each lane's tasks, by workflow: CI runs the lanes that Linux
# runners can run, the Apple workflow those that need a macOS runner. The host lane runs on
# both hosts. A workflow's selection job has an output for each of its lanes.
WORKFLOW_JOBS = {
    "ci": {
        "quality": "formatting",
        "docs": "api-docs",
        "host": "tests-linux",
        "android": "android",
    },
    "apple": {
        "host": "tests-macos",
        "source-engine": "source-engine",
        "ios": "ios",
    },
}
# The host each workflow's runners run on: its host lane runs the tasks of that host.
WORKFLOW_HOSTS = {"ci": "linux", "apple": "macos"}
# The job with which CI calls the Apple workflow, and CI's selection output that says
# whether this run calls it.
APPLE_JOB = "apple"
# CI's selection output with the Apple workflow's outputs, as JSON, which it hands the
# Apple workflow; and each workflow's output that says whether its host job needs Android.
APPLE_PLAN = "apple_plan"
HOST_ANDROID = "host_android"


def runs_apple(lanes: dict[str, list[str]], event_name: str) -> bool:
    """Say whether a CI run calls the Apple workflow.

    A pull request's run leaves it out: the merge queue runs it, and the ci:macos label
    starts it for a pull request. Every other event calls it when an Apple lane is selected.
    """
    apple = for_host(lanes, WORKFLOW_HOSTS["apple"])
    return event_name != "pull_request" and any(
        apple[lane] for lane in WORKFLOW_JOBS["apple"]
    )


def selected_tasks(outputs: dict, lane: str) -> list[str]:
    """Read one selection output; a missing or malformed one is not an empty selection."""
    output_name = lane.replace("-", "_")
    if output_name not in outputs:
        raise ValueError(f"missing selection output: {output_name}")
    tasks = json.loads(outputs[output_name])
    if not isinstance(tasks, list) or not all(isinstance(task, str) for task in tasks):
        raise ValueError(f"{lane}: invalid selected task list")
    return tasks


def required_jobs(workflow: str, outputs: dict) -> list[str]:
    """Name the jobs a workflow's selection requires: those of its lanes with tasks."""
    jobs = [
        workflow_job
        for lane, workflow_job in WORKFLOW_JOBS[workflow].items()
        if selected_tasks(outputs, lane)
    ]
    if workflow == "ci":
        if outputs.get(APPLE_JOB) not in {"true", "false"}:
            raise ValueError(f"missing selection output: {APPLE_JOB}")
        if outputs[APPLE_JOB] == "true":
            jobs.append(APPLE_JOB)
    return jobs


def failed_jobs(needs: dict) -> list[str]:
    """Name the jobs that neither succeeded nor were skipped, with their results."""
    return [
        f"{workflow_job}: {result.get('result', 'missing')}"
        for workflow_job, result in needs.items()
        if result.get("result") not in {"success", "skipped"}
    ]


def verify_results(workflow: str, needs: dict) -> None:
    """Require every job that a workflow's selection requires to succeed."""
    selection = needs.get("selection", {})
    if selection.get("result") != "success":
        raise ValueError("selection did not succeed")
    if failures := failed_jobs(needs):
        raise ValueError(f"{failures[0]} verification result")
    for workflow_job in required_jobs(workflow, selection.get("outputs", {})):
        result = needs.get(workflow_job, {}).get("result", "missing")
        if result != "success":
            raise ValueError(
                f"{workflow_job}: {result}; selected verification must succeed"
            )


# Examples whose suites need a lane other than host, as hk.pkl's exampleProfiles says:
# Petri's editor and runtime are built from the engine sources.
EXAMPLE_LANES = {"petri": "source-engine"}


# Tasks named for themselves, by lane.
TASK_LANES = {
    **dict.fromkeys(
        (
            "lint",
            "lint:ci",
            "conventions:code",
            "conventions:docs",
            "test:selection",
            "test:setup",
        ),
        "quality",
    ),
    **{lane: lane for lane in ("docs", "source-engine", "android", "ios")},
    **dict.fromkeys(("test:bazel", "test:regressions", "test:gdextension"), "host"),
}


def _family_lane(task: str) -> str | None:
    """The lane of a task of a family: contracts, examples and add-on modules."""
    if task.startswith("contracts:") and task.removeprefix("contracts:") in PROFILE_LANES:
        return task.removeprefix("contracts:")
    if task.startswith("test:example:"):
        return EXAMPLE_LANES.get(task.removeprefix("test:example:"), "host")
    # The add-on modules' tasks are named <lane>:addon:<module>, and the generator's self-test
    # <lane>:addon-template.
    if (addon := addon_task(task)) is not None:
        return addon[0]
    return None


def addon_task(task: str) -> tuple[str, str | None, tuple[str, ...]] | None:
    """
    Split an add-on task into its lane, its module and the hosts it is limited to, which
    hk.pkl appends to the name: `host:addon:<module>@macos`. The self-test,
    `<lane>:addon-template`, has no module.
    """
    lane, separator, rest = task.partition(":addon")
    if not separator or lane not in PROFILE_LANES:
        return None
    target, _, listed = rest.partition("@")
    hosts = tuple(listed.split(",")) if listed else ()
    if target == "-template":
        return lane, None, hosts
    if not target.startswith(":") or not target[1:]:
        return None
    return lane, target[1:], hosts


def task_command(task: str) -> list[str]:
    """The command of a selected task, as hk.pkl's step for it runs it."""
    addon = addon_task(task)
    if addon is None:
        return ["mise", "run", task]
    lane, module, _ = addon
    if module is None:
        return ["mise", "run", "addon:template", lane]
    return ["mise", "run", f"addon:{lane}", module]


def for_host(lanes: dict[str, list[str]], host: str) -> dict[str, list[str]]:
    """The lanes without the add-on tasks whose host lane excludes this host."""

    def runs_here(task: str) -> bool:
        addon = addon_task(task)
        return addon is None or not addon[2] or host in addon[2]

    return {
        lane: [task for task in tasks if runs_here(task)] for lane, tasks in lanes.items()
    }


def lane_for(task: str) -> str:
    """Assign a selected mise task to its lane."""
    lane = TASK_LANES.get(task) or _family_lane(task)
    if lane is None:
        raise ValueError(f"No lane for selected task: {task}")
    return lane


def lane_plan(plan: dict) -> dict[str, list[str]]:
    """Retain hk's order and fail closed on unfamiliar plan statuses or steps."""
    lanes: dict[str, list[str]] = {name: [] for name in LANES}
    for step in plan["steps"]:
        status = step["status"]
        if status == "skipped":
            continue
        if status != "included":
            raise ValueError(f"Unexpected hk plan status: {status}")
        task = step["name"]
        lanes[lane_for(task)].append(task)
    return lanes


def selection_args(event_name: str, event: dict) -> list[str]:
    """Compare PR merge contents or a merge group; dispatch checks all."""
    if event_name == "workflow_dispatch":
        return ["--all"]
    if event_name == "pull_request":
        return ["--from-ref", event["pull_request"]["base"]["sha"], "--to-ref", "HEAD"]
    if event_name == "merge_group":
        # The group's parent: the base branch, or the group queued before this one.
        return ["--from-ref", event["merge_group"]["base_sha"], "--to-ref", "HEAD"]
    raise ValueError(f"Unsupported verification event: {event_name}")


def run_tasks(tasks: object) -> None:
    """Run the mise tasks of one selection output in order."""
    if not isinstance(tasks, list) or not all(isinstance(task, str) for task in tasks):
        raise ValueError("Expected a JSON array of mise task names")
    for task in tasks:
        lane_for(task)
    for task in tasks:
        subprocess.run(task_command(task), check=True)


def android_tasks(root: Path = ROOT) -> frozenset[str]:
    """The mise tasks that provision the Android SDK first: those of mise.toml's android template."""
    tasks = tomllib.loads((root / "mise.toml").read_text())["tasks"]
    return frozenset(
        name
        for name, task in tasks.items()
        if task.get("extends") == "android" or "android:setup" in task.get("depends", [])
    )


def needs_android(tasks: list[str], android: frozenset[str]) -> bool:
    """Whether a job's tasks need the Android SDK, so that its setup restores it."""
    return any(task_command(task)[2] in android for task in tasks)


def workflow_outputs(
    workflow: str, lanes: dict[str, list[str]], event_name: str
) -> dict[str, object]:
    """
    A workflow's selection outputs: each lane's tasks on the workflow's host, and whether its
    host job needs the Android SDK. CI also says whether it calls the Apple workflow, and
    hands it the Apple plan, so that the Apple workflow does not plan the run again.
    """
    here = for_host(lanes, WORKFLOW_HOSTS[workflow])
    outputs: dict[str, object] = {lane: here[lane] for lane in WORKFLOW_JOBS[workflow]}
    outputs[HOST_ANDROID] = needs_android(here["host"], android_tasks())
    if workflow == "ci":
        outputs[APPLE_JOB] = runs_apple(lanes, event_name)
        outputs[APPLE_PLAN] = json.dumps(workflow_outputs("apple", lanes, event_name))
    return outputs


def write_plan(workflow: str) -> None:
    """Write the tasks of each of a workflow's lanes for this run to GITHUB_OUTPUT."""
    event_name = os.environ["GITHUB_EVENT_NAME"]
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    command = ["hk"]
    for lane in PROFILE_LANES:
        command.extend(["--profile", lane])
    command.extend(["check", "--plan", "--json"])
    command.extend(selection_args(event_name, event))
    result = subprocess.run(command, check=True, stdout=subprocess.PIPE, text=True)
    outputs = workflow_outputs(workflow, lane_plan(json.loads(result.stdout)), event_name)
    with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
        output.writelines(
            f"{name}={value if isinstance(value, str) else json.dumps(value)}\n"
            for name, value in outputs.items()
        )
    print(json.dumps(outputs, indent=2))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    plan = commands.add_parser(
        "plan", help="Write the selected tasks of a workflow's lanes to GITHUB_OUTPUT"
    )
    verify = commands.add_parser(
        "verify", help="Require a workflow's selected jobs to succeed"
    )
    for command in (plan, verify):
        command.add_argument("workflow", choices=sorted(WORKFLOW_JOBS))
    run = commands.add_parser("run", help="Run one selected JSON task array")
    run.add_argument("tasks")
    args = parser.parse_args()
    if args.command == "verify":
        verify_results(args.workflow, json.loads(os.environ["VERIFICATION_NEEDS"]))
    elif args.command == "run":
        run_tasks(json.loads(args.tasks))
    else:
        write_plan(args.workflow)


if __name__ == "__main__":
    main()
