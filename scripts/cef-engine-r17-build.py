#!/usr/bin/env python3
"""Build and stage the frozen r17 CEF additions in one locked Ninja batch."""
import argparse
from contextlib import nullcontext, redirect_stderr, redirect_stdout
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from types import SimpleNamespace

REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "engine_build", REPO / "scripts/cef-engine-extensions-build.py")
build = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(build)
x2 = build.x2
PATCHES = REPO / "native/OrbitChromium/cef-patches"
PATCH_DIR = PATCHES / "engine-r17"
FLAVOR = "orbit-engine-extensions-r17"
CODEC_OUT = "out/Release_GN_arm64_codecs"


def output(root, *command):
    return subprocess.check_output(command, cwd=root, text=True).strip()


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def verify_or_apply_patch(root, patch):
    reverse = subprocess.run(["git", "apply", "--reverse", "--check", str(patch)], cwd=root,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if reverse.returncode == 0:
        return False
    subprocess.run(["git", "apply", "--check", str(patch)], cwd=root, check=True)
    subprocess.run(["git", "apply", str(patch)], cwd=root, check=True)
    return True


def verify_baseline(pins, baseline_dir):
    if output(x2.SRC, "git", "rev-parse", "HEAD") != pins["chromium_commit"]:
        raise SystemExit("Chromium HEAD differs from the r17 source pin")
    for name, expected in pins["dependencies"].items():
        actual = output(x2.SRC / name, "git", "rev-parse", "HEAD")
        if actual != expected:
            raise SystemExit("Security dependency revision mismatch: " + name)

    popup = PATCHES / pins["popup_patch"]
    if sha256(popup.read_bytes()) != pins["popup_patch_sha256"]:
        raise SystemExit("The preserved popup patch hash changed")
    verify_or_apply_patch(x2.SRC, popup)

    source_diff = subprocess.check_output(
        ["git", "diff", "--binary", "--full-index", "--ignore-submodules=all", "HEAD"], cwd=x2.SRC)
    if sha256(source_diff) != pins["chromium_baseline_diff_sha256"]:
        raise SystemExit("The intentional r16 source diff differs from its preserved snapshot")
    untracked = output(x2.SRC, "git", "ls-files", "--others", "--exclude-standard")
    expected_untracked = (baseline_dir / "src-untracked.txt").read_text().strip()
    if "\n".join(sorted(untracked.splitlines())) != "\n".join(sorted(expected_untracked.splitlines())):
        raise SystemExit("The intentional r16 untracked source list changed")

    cef_head = output(x2.CEF_REPO, "git", "rev-parse", "HEAD")
    cef_branch = output(x2.CEF_REPO, "git", "branch", "--show-current")
    if cef_head != pins["cef_commit"] or cef_branch != pins["cef_branch"]:
        raise SystemExit("CEF is not on the pinned r17 patch commit")
    if output(x2.CEF_REPO, "git", "rev-parse", "HEAD^") != pins["cef_parent_commit"]:
        raise SystemExit("The r17 CEF patch parent differs from the recorded r16 commit")
    if subprocess.check_output(["git", "status", "--porcelain"], cwd=x2.CEF_REPO).strip():
        raise SystemExit("CEF source has uncommitted changes")
    # The exact parent SHA is the clean proof that the r14 patch commit is
    # preserved; reverse-applying r14's overlapping header/API hunks onto r17
    # would correctly fail after these additive edits.
    if pins["cef_parent_commit"] != pins["cef_r14_commit"]:
        raise SystemExit("The r17 CEF parent is not the verified engine-r14 commit")
    r17 = PATCH_DIR / pins["cef_patch"]
    if sha256(r17.read_bytes()) != pins["cef_patch_sha256"]:
        raise SystemExit("The r17 CEF patch hash changed")
    if subprocess.run(["git", "apply", "--reverse", "--check", str(r17)], cwd=x2.CEF_REPO,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
        raise SystemExit("The committed r17 CEF patch is not present")


def make_environment():
    source_lab = x2.load(x2.MAIN / "scripts/chromium-source-lab.py", "engine_r17_source_lab")
    env = dict(source_lab.ENV, ORBIT_CEF_PATCHES="1", NINJA_STATUS="[%f/%t %es] ")
    env.pop("LIBRARY_PATH", None)
    # Apple's /usr/bin/python3 launcher fails with Rust's relative SDKROOT.
    env["PATH"] = str(Path(sys.executable).resolve().parent) + os.pathsep + env["PATH"]
    return env


def ninja_command(jobs):
    return ["/usr/bin/sandbox-exec", "-f", str(x2.FORK / "build-codecs-isolation.sb"),
            "nice", "-n", "10", str(x2.SRC / "third_party/ninja/ninja"),
            "-C", CODEC_OUT, "-j", str(jobs), "cef"]


def regenerate_and_dry_run(command, env, logs):
    with (logs / "gn-regeneration.log").open("w") as stream:
        subprocess.run(command[:-1] + ["build.ninja"], cwd=x2.SRC, env=env,
                       stdout=stream, stderr=subprocess.STDOUT, check=True)
    dry = subprocess.run(command + ["-n", "-d", "explain"], cwd=x2.SRC, env=env,
                         capture_output=True, text=True, check=True)
    payload = dry.stdout + dry.stderr
    (logs / "post-change-dry-run.log").write_text(payload)
    task_lines = [line for line in payload.splitlines() if re.match(r"^\[\d+/\d+\s", line)]
    tasks = max((int(match.group(2)) for line in task_lines
                 if (match := re.match(r"^\[(\d+)/(\d+)\s", line))), default=0)
    (logs / "post-change-dry-run.json").write_text(json.dumps({
        "tasks": tasks,
        "task_lines": len(task_lines),
        "first_tasks": task_lines[:12],
        "explain_excerpt": payload.splitlines()[:80],
    }, indent=2) + "\n")
    print("Incremental Ninja tasks:", tasks, flush=True)
    for line in task_lines[:12]:
        print(line, flush=True)
    return tasks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jobs", type=int, choices=range(1, 9), default=8)
    parser.add_argument("--logs", type=Path, default=Path("/tmp/engine-r17/build"))
    parser.add_argument("--dry-run", action="store_true", help="Regenerate GN and report tasks (default)")
    parser.add_argument("--run-build", action="store_true", help="Run one batch and stage the r17 distribution")
    parser.add_argument("--expected-tasks", type=int,
                        help="Abort before Ninja if the fresh dry-run count differs")
    parser.add_argument("--lock-held", action="store_true",
                        help="Use only when an external x2.source_tree_lock holder spans this command")
    parser.add_argument("--announced-start-utc", help="UTC start time already posted to both owner threads")
    parser.add_argument("--use-recorded-dry-run", action="store_true",
                        help="Use the fresh post-change dry-run after rechecking pinned sources")
    parser.add_argument("--wait-for-start", action="store_true",
                        help="After preflight, wait for START on stdin so the owner can announce the Ninja time")
    args = parser.parse_args()
    if args.dry_run and args.run_build:
        parser.error("choose --dry-run or --run-build")
    if args.run_build and args.expected_tasks is None:
        parser.error("--run-build requires --expected-tasks from the posted dry-run")
    if args.use_recorded_dry_run and not args.run_build:
        parser.error("--use-recorded-dry-run requires --run-build")
    if args.wait_for_start and not args.run_build:
        parser.error("--wait-for-start requires --run-build")
    args.logs.mkdir(parents=True, exist_ok=True)
    baseline_dir = Path("/tmp/engine-r17/baseline")
    lock = nullcontext() if args.lock_held else x2.source_tree_lock()
    with lock:
        x2.guard()
        if build.chromium_build_active():
            raise SystemExit("Another Chromium build is active")
        if (x2.DISTRIB / FLAVOR).exists():
            raise SystemExit("Preserve any existing r17 distribution; refusing replacement")
        pins = json.loads((PATCH_DIR / "source.json").read_text())
        verify_baseline(pins, baseline_dir)
        env = make_environment()
        command = ninja_command(args.jobs)
        if args.use_recorded_dry_run:
            record_path = args.logs / "post-change-dry-run.json"
            if not record_path.is_file() or time.time() - record_path.stat().st_mtime > 900:
                raise SystemExit("The recorded post-change dry-run is missing or older than 15 minutes")
            tasks = json.loads(record_path.read_text())["tasks"]
            print("Using fresh recorded dry-run:", tasks, "tasks", flush=True)
        else:
            with (args.logs / "version.log").open("w") as stream:
                subprocess.run([sys.executable, "tools/make_version_header.py",
                                str(x2.SRC / CODEC_OUT / "gen/cef/include/cef_version.h")],
                               cwd=x2.CEF_REPO, env=env, stdout=stream, stderr=subprocess.STDOUT,
                               check=True)
            tasks = regenerate_and_dry_run(command, env, args.logs)
        if not args.run_build:
            print("Dry run only; the engine build did not start.", flush=True)
            return 0
        if tasks != args.expected_tasks:
            raise SystemExit("Fresh dry-run count differs from the posted count; refusing to build")
        if not args.announced_start_utc and not args.wait_for_start:
            raise SystemExit("Post the actual start time to both owner threads before building")
        if args.wait_for_start:
            print("Preflight complete. Waiting for START before Ninja.", flush=True)
            start_command = input().strip()
            if not start_command.startswith("START "):
                raise SystemExit("Ninja start was not authorized")
            args.announced_start_utc = start_command.removeprefix("START ").strip()
        os.environ["CMAKE_BUILD_PARALLEL_LEVEL"] = "4"
        started_wall = datetime.now(timezone.utc)
        started = time.monotonic()
        print("Ninja batch started:", started_wall.isoformat(), flush=True)
        build.build_cef(command, env, args.logs)
        build_seconds = time.monotonic() - started
        (args.logs / "build-summary.json").write_text(json.dumps({
            "tasks": tasks,
            "jobs": args.jobs,
            "nice": 10,
            "announced_start_utc": args.announced_start_utc,
            "ninja_start_utc": started_wall.isoformat(),
            "ninja_seconds": round(build_seconds, 1),
        }, indent=2) + "\n")
        x2.PATCHED_FLAVORS += (FLAVOR,)
        distribution_started = time.monotonic()
        with (args.logs / "distribution.log").open("w") as stream, \
                redirect_stdout(stream), redirect_stderr(stream):
            x2.distrib(SimpleNamespace(flavor=FLAVOR, replace=False,
                                       build_dir_suffix="_GN_arm64_codecs",
                                       incremental_build_completed=True))
        (args.logs / "distribution-summary.json").write_text(json.dumps({
            "path": str(x2.DISTRIB / FLAVOR),
            "seconds": round(time.monotonic() - distribution_started, 1),
        }, indent=2) + "\n")
        print("Distribution:", x2.DISTRIB / FLAVOR, flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
