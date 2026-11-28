"""
Options, process handling and install policy shared by the launchers of every platform.

The launcher runs on the host with the host's python3 and only the standard library,
because it drives the host's devices whatever platform executed the build. It keeps
to Python 3.9, the python3 of macOS's command line tools.

Sections: Options, Running.
"""

from __future__ import annotations

import argparse
import dataclasses
import os
import signal
import subprocess
import sys
from collections.abc import Callable, Collection, Mapping, Sequence
from typing import NoReturn, TypeVar

INTERRUPTED = 130

_T = TypeVar("_T")


class LaunchError(Exception):
    """A failure the launcher reports as one message, without a traceback."""


# ==== Options =================================================================


@dataclasses.dataclass(frozen=True)
class Options:
    """The launcher options of one `bazel run`."""

    device: str | None = None
    list_devices: bool = False
    start_device: bool = True
    headless: bool = False
    fresh: bool = False
    on_conflict: str = "uninstall"
    install_only: bool = False
    no_install: bool = False
    detach: bool = False
    env: Mapping[str, str] = dataclasses.field(default_factory=dict)
    emulator_args: Sequence[str] = ()
    grant_permissions: bool = False
    logcat: str | None = None
    simulator_type: str | None = None
    os_version: str | None = None
    port: int | None = None
    godot_args: Sequence[str] = ()


def _add_target_options(parser: argparse.ArgumentParser) -> None:
    target = parser.add_argument_group("target")
    target.add_argument(
        "--device",
        help="Android serial or AVD name, iOS UDID or name, or a browser's name or path; defaults to ANDROID_SERIAL, BAZEL_APPLE_DEVICE_UDID or the system's browser",
    )
    target.add_argument(
        "--list-devices",
        action="store_true",
        help="list running and startable devices and exit",
    )
    target.add_argument(
        "--no-start-device",
        dest="start_device",
        action="store_false",
        help="fail instead of starting an emulator or simulator when none runs",
    )
    target.add_argument(
        "--headless",
        action="store_true",
        help="no window: Godot --headless, emulator -no-window, no Simulator window, a Chromium browser without a window",
    )


def _add_install_options(parser: argparse.ArgumentParser) -> None:
    install = parser.add_argument_group("install")
    install.add_argument(
        "--fresh",
        action="store_true",
        help="start without the application's data: uninstall first, or a new user directory on desktop",
    )
    install.add_argument(
        "--on-conflict",
        choices=("uninstall", "fail"),
        default="uninstall",
        help="when the installed application blocks the install (other signature, newer version, no space): uninstall it and its data, or fail (default: uninstall)",
    )
    mode = install.add_mutually_exclusive_group()
    mode.add_argument(
        "--install-only", action="store_true", help="install without launching"
    )
    mode.add_argument(
        "--no-install", action="store_true", help="launch the installed application"
    )
    launch = parser.add_argument_group("launch")
    launch.add_argument(
        "--detach",
        action="store_true",
        help="return once the application started instead of streaming its log",
    )
    launch.add_argument(
        "--env",
        action="append",
        default=[],
        metavar="NAME=VALUE",
        help="environment variable of the application (desktop and iOS)",
    )


def _add_platform_options(parser: argparse.ArgumentParser) -> None:
    android = parser.add_argument_group("Android")
    android.add_argument(
        "--emulator-arg",
        dest="emulator_args",
        action="append",
        default=[],
        metavar="ARG",
        help="argument of the emulator command that starts an AVD",
    )
    android.add_argument(
        "--grant-permissions",
        action="store_true",
        help="grant the manifest's runtime permissions on install (adb install -g)",
    )
    android.add_argument(
        "--logcat",
        metavar="FILTERSPEC|all",
        help="logcat filterspecs for the application's process, or all for the whole device log",
    )
    ios = parser.add_argument_group("iOS Simulator")
    ios.add_argument(
        "--simulator-type",
        metavar="NAME",
        help="device type of a simulator to start or create, such as 'iPhone 17 Pro'",
    )
    ios.add_argument(
        "--os",
        dest="os_version",
        metavar="VERSION",
        help="iOS version of a simulator to start or create, such as 26.4",
    )
    web = parser.add_argument_group("web")
    web.add_argument(
        "--port",
        type=int,
        metavar="NUMBER",
        help="port of the local server on 127.0.0.1 (default: 8060, or the next free one)",
    )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="bazel run <app> --",
        usage="bazel run <app> -- [options] [-- <Godot arguments>]",
        description="Install and launch a Godot application, then stream its log until it exits.",
        allow_abbrev=False,
    )
    _add_target_options(parser)
    _add_install_options(parser)
    _add_platform_options(parser)
    return parser


def _environment(assignments: Sequence[str]) -> dict[str, str]:
    """Return the variables of the --env assignments."""
    env = {}
    for assignment in assignments:
        name, separator, value = assignment.partition("=")
        if not separator or not name:
            raise LaunchError(f"--env takes NAME=VALUE, not {assignment!r}")
        env[name] = value
    return env


def _reject_unaccepted_options(
    options: Options,
    parser: argparse.ArgumentParser,
    platform: str,
    accepted: Collection[str],
) -> None:
    """Reject the options a user set that the platform does not accept."""
    flags = {action.dest: action.option_strings[0] for action in parser._actions}
    defaults = Options()
    for field in dataclasses.fields(Options):
        if field.name in accepted or field.name == "godot_args":
            continue
        if getattr(options, field.name) != getattr(defaults, field.name):
            raise LaunchError(
                f"{flags[field.name]} does not apply to {platform} applications"
            )


def parse_options(
    argv: Sequence[str], platform: str, accepted: Collection[str]
) -> Options:
    """
    Parse `[options] [-- <Godot arguments>]` for a platform that accepts some options.

    Raises:
        LaunchError: An option is malformed or the platform does not accept it.
    """
    argv = list(argv)
    godot_args: list[str] = []
    if "--" in argv:
        split = argv.index("--")
        argv, godot_args = argv[:split], argv[split + 1 :]
    parser = _parser()
    values, unknown = parser.parse_known_args(argv)
    if unknown:
        raise LaunchError(
            f"unknown launcher arguments {' '.join(unknown)}; pass Godot arguments "
            f"after a second --, as in: bazel run <app> -- -- {' '.join(unknown)}"
        )
    options = Options(
        device=values.device,
        list_devices=values.list_devices,
        start_device=values.start_device,
        headless=values.headless,
        fresh=values.fresh,
        on_conflict=values.on_conflict,
        install_only=values.install_only,
        no_install=values.no_install,
        detach=values.detach,
        env=_environment(values.env),
        emulator_args=tuple(values.emulator_args),
        grant_permissions=values.grant_permissions,
        logcat=values.logcat,
        simulator_type=values.simulator_type,
        os_version=values.os_version,
        port=values.port,
        godot_args=tuple(godot_args),
    )
    _reject_unaccepted_options(options, parser, platform, accepted)
    return options


# ==== Running =================================================================


def log(message: str) -> None:
    """Report launcher progress on stderr, apart from the application's log on stdout."""
    print("rules_godot: " + message, file=sys.stderr, flush=True)


def _name(command: Sequence[str]) -> str:
    return " ".join(
        os.path.basename(part) if index == 0 else part
        for index, part in enumerate(command[:3])
    )


def run(
    command: Sequence[str],
    *,
    check: bool = True,
    timeout: float | None = None,
    env: Mapping[str, str] | None = None,
    stdin: str | None = None,
) -> subprocess.CompletedProcess[str]:
    """
    Run a host tool to completion and capture its output.

    Raises:
        LaunchError: check is set and the tool failed or timed out, or it is missing.
    """
    try:
        result = subprocess.run(
            list(command),
            input=stdin,
            stdin=None if stdin is not None else subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            errors="replace",
            timeout=timeout,
            env=None if env is None else dict(env),
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        raise LaunchError(
            f"{_name(command)} did not finish within {timeout} seconds"
        ) from error
    except FileNotFoundError as error:
        raise LaunchError(f"{command[0]} is not installed") from error
    if check and result.returncode != 0:
        raise LaunchError(
            f"{_name(command)} failed with exit code {result.returncode}:\n"
            + result.stdout.strip()
        )
    return result


def single(
    candidates: Sequence[_T], noun: str, describe: Callable[[_T], str], variable: str
) -> _T | None:
    """
    The one candidate, or None without any.

    Raises:
        LaunchError: Several candidates need a choice.
    """
    if len(candidates) > 1:
        raise LaunchError(
            f"several {noun} run: {', '.join(describe(c) for c in candidates)}; "
            f"choose one with --device=<id> or {variable}"
        )
    return candidates[0] if candidates else None


def install_resolving_conflicts(
    application: str,
    target: str,
    options: Options,
    *,
    install: Callable[[], str | None],
    uninstall: Callable[[], object],
    installed: Callable[[], bool],
    conflict: Callable[[str], str | None],
    describe: Callable[[str], str] = lambda failure: failure,
) -> None:
    """
    Install, resolving a conflict with the installed copy as --on-conflict says.

    install returns None or its failure; conflict names why a failure is one an
    installed copy causes, or returns None for others, which no uninstall resolves.

    Raises:
        LaunchError: The install failed.
    """
    if options.fresh:
        log(f"--fresh: uninstalling {application} and its data")
        uninstall()
    failure = install()
    reason = conflict(failure) if failure else None
    if reason and installed():
        if options.on_conflict != "uninstall":
            raise LaunchError(
                f"{application} on {target} blocks the install, because {reason}; "
                "pass --on-conflict=uninstall to replace it and lose its data"
            )
        log(
            f"warning: uninstalling {application} from {target}, because {reason}; its data is lost"
        )
        uninstall()
        failure = install()
    if failure:
        raise LaunchError(
            f"installing {application} on {target} failed: {describe(failure)}"
        )


def end(process: subprocess.Popen, *, group: bool = False) -> None:
    """End a process, or its process group: SIGTERM, then SIGKILL after two seconds."""
    for sig, grace in ((signal.SIGTERM, 2), (signal.SIGKILL, None)):
        if process.poll() is not None:
            return
        try:
            if group:
                os.killpg(process.pid, sig)
            else:
                process.send_signal(sig)
        except ProcessLookupError:
            return
        try:
            process.wait(timeout=grace)
            return
        except subprocess.TimeoutExpired:
            continue


def foreground(
    command: Sequence[str],
    *,
    env: Mapping[str, str] | None = None,
    stop: Callable[[], object] | None = None,
    new_session: bool = False,
    inherit_stdin: bool = False,
) -> int:
    """
    Run a command that streams the application's log until it ends; return its exit code.

    Ctrl-C or SIGTERM calls stop, which ends the application, ends the command and
    returns 130. new_session runs the command in its own process group, which ending
    it stops as a whole; inherit_stdin hands it the terminal's input.
    """
    process = subprocess.Popen(
        list(command),
        stdin=None if inherit_stdin else subprocess.DEVNULL,
        env=None if env is None else dict(env),
        start_new_session=new_session,
    )
    try:
        code = process.wait()
    except KeyboardInterrupt:
        if stop:
            stop()
        end(process, group=new_session)
        return INTERRUPTED
    return 128 - code if code < 0 else code


def run_on_host(command: Sequence[str], env: Mapping[str, str], *, detach: bool) -> int:
    """
    Run an application process on this host in its own process group.

    It streams its output until it exits, or with detach returns once it started. Its own
    group lets stopping it reach the engine's child processes, and it keeps the terminal's
    input for Godot's command line debugger (-d).
    """
    if detach:
        process = subprocess.Popen(
            list(command), env=dict(env), stdin=subprocess.DEVNULL, start_new_session=True
        )
        log(f"started {os.path.basename(command[0])}, process {process.pid}")
        return 0
    return foreground(command, env=env, new_session=True, inherit_stdin=True)


def interrupt_on_terminate() -> None:
    """Handle SIGTERM like Ctrl-C, so both end the application."""

    def handler(_signum: int, _frame: object) -> NoReturn:
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, handler)
