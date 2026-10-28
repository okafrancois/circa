#!/usr/bin/env python3
"""Replay coordinator assertions without loading CEF; demonstrate the Release assert gap."""
import argparse
import json
from pathlib import Path
import shlex
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("--build", type=Path, required=True, help="Private configured CMake build with test dependencies built")
parser.add_argument("--scratch", type=Path, required=True)
args = parser.parse_args()
build = args.build.resolve()
scratch = args.scratch.resolve()
scratch.mkdir(parents=True, exist_ok=True)
tests = Path(__file__).resolve().parent
original = tests / "AuthenticationCoordinatorTests.swift"
text = original.read_text()
marker = '        print("PASS authentication coordinator:'
assert text.count(marker) == 1
extra = (tests / "AuthenticationCoordinatorIndependentReview.inc.swift").read_text()
expanded = scratch / "CoordinatorExpanded.swift"
expanded.write_text(text.replace(marker, extra + "\n" + marker))
sentinel = scratch / "CoordinatorSentinel.swift"
entry = "@MainActor static func main() throws {"
assert text.count(entry) == 1
sentinel.write_text(text.replace(entry, entry + "\n        assert({ () -> Bool in exit(86) }())"))
commands = subprocess.check_output(["ninja", "-C", str(build), "-t", "commands", "AuthenticationCoordinatorTests"], text=True)
command = shlex.split(commands.splitlines()[-1])
assert command[:2] == [":", "&&"] and command[-2:] == ["&&", ":"]
command = command[2:-2]

def replay(source, name, assertions):
    output = scratch / name
    filtered = []
    index = 0
    while index < len(command):
        arg = command[index]
        if arg in ("-j", "-num-threads", "-output-file-map", "-o"):
            index += 2
            continue
        if arg == "-emit-dependencies":
            index += 1
            continue
        filtered.append(str(source) if arg == str(original) else arg)
        index += 1
    filtered += ["-j", "2", "-num-threads", "2", "-o", str(output)]
    if assertions:
        filtered += ["-assert-config", "Debug"]
    with (scratch / (name + ".build.log")).open("w") as log:
        subprocess.run(filtered, cwd=build, check=True, stdout=log, stderr=subprocess.STDOUT)
    with (scratch / (name + ".run.log")).open("w") as log:
        return subprocess.run([str(output)], check=False, stdout=log, stderr=subprocess.STDOUT).returncode

results = {
    "release_assert_sentinel_exit": replay(sentinel, "sentinel-release", False),
    "debug_assert_sentinel_exit": replay(sentinel, "sentinel-debug", True),
    "actual_original_and_independent_assertions_exit": replay(expanded, "coordinator-assertions-enabled", True),
}
print(json.dumps(results, sort_keys=True))
assert results == {"release_assert_sentinel_exit": 0, "debug_assert_sentinel_exit": 86,
                   "actual_original_and_independent_assertions_exit": 0}
