"""
Run one lane of an add-on module, with the same commands for every module in addons/.

Each lane runs in the module's examples/, which consumes the module like an application:

- host: the module's tests and every target of its examples but the projects' apps, for
  the editor and this desktop host, on the hosts its addon.pkl names;
- android and ios: each example project's `app`, for Android and the iOS Simulator.
"""

import argparse
import platform
import subprocess
import sys

from tools.addons.modules import LANES, ROOT, AddonModule, module_path

# The Bazel configuration of each mobile lane, from addons/examples.bazelrc.
APP_CONFIGS = {"android": "--config=android", "ios": "--config=ios_sim"}
# `bazel test` with no test among the targets exits with 4 after a successful build.
NO_TESTS = 4


def host() -> str:
    """This machine as addon.pkl names hosts."""
    return {"Darwin": "macos", "Linux": "linux"}.get(platform.system(), platform.system())


def command(lane: str, module: AddonModule) -> list[str]:
    """The Bazel command of one lane, run in the module's examples/."""
    if not module.projects:
        raise ValueError(f"{module.path}: no example project in examples/projects/")
    if lane == "host":
        apps = [f"-//projects/{project}:app" for project in module.projects]
        return ["bazel", "test", "--", f"@{module.name}//...", "//...", *apps]
    apps = [f"//projects/{project}:app" for project in module.projects]
    return ["bazel", "build", APP_CONFIGS[lane], *apps]


def run(lane: str, module: AddonModule) -> None:
    if lane == "host" and host() not in module.hosts:
        print(
            f"{module.path}: its host lane runs on {', '.join(module.hosts)}, not {host()}"
        )
        return
    argv = command(lane, module)
    print("+", " ".join(argv), flush=True)
    examples = ROOT / module.path / "examples"
    status = subprocess.run(argv, cwd=examples, check=False).returncode
    if status not in ({0, NO_TESTS} if lane == "host" else {0}):
        sys.exit(status)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("lane", choices=LANES)
    parser.add_argument("module", help="the module's directory below addons/")
    args = parser.parse_args()
    run(args.lane, AddonModule.load(module_path(args.module)))


if __name__ == "__main__":
    main()
