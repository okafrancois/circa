#!/usr/bin/env python3
"""ENG-X2 laboratory driver: CEF from our sources (stock and Orbit-patched) under the X1 lab.

Flavors of the CEF the OrbitChromium bundle is linked against:
  sdk    the pinned binary SDK of ENG-X1 (default of scripts/orbit-chromium-lab.py);
  stock  make_distrib of our build of CEF 4fa4ab5 without Orbit patches (X2.0);
  orbit   make_distrib of our build of CEF branch orbit/8078 with ORBIT_CEF_PATCHES (X2.1+).

Subcommands:
  apply-orbit    copy the orbit/8078 branch state into the build tree and apply orbit_*.patch;
  build-cef     incremental `autoninja cef` (nice 10, -j 12, sandboxed away from node_modules,
                80 GiB free-space guard), detached unless --wait, timed in a JSON record;
  distrib       make_distrib --minimal + libcef_dll_wrapper for a flavor;
  build         the lab bundle against a flavor (build dir native/OrbitChromium/build/x2-<flavor>);
  run           the hidden lab run of scripts/orbit-chromium-lab.py on that bundle; evidence goes
                to <main>/artifacts/native-orbit-chromium-x2/<stamp>-<flavor>/;
  export        orbit_*.patch, the libcef diff and a manifest into native/OrbitChromium/cef-patches;
  check         Bridge/OrbitCefApi.h is identical to the branch's orbit_cef_api.h.

The X1 runner is reused unchanged (imported), so its hygiene (synthetic root, loopback fixture,
--use-mock-keychain, process cleanup) applies to every flavor.
"""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import importlib.util
import json
import os
import re
import stat
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LAB_DIR = REPO / "native/OrbitChromium"
MAIN = Path(subprocess.run(["git", "-C", str(REPO), "rev-parse", "--path-format=absolute", "--git-common-dir"],
                           capture_output=True, text=True, check=True).stdout.strip()).parent
FORK = MAIN / ".tools/chromium-fork"
SRC = FORK / "chromium/src"
CEF_REPO = SRC / "cef"
OUT = "out/Release_GN_arm64"
DISTRIB = FORK / "distrib"


def distribution_dir(flavor):
    current = DISTRIB / flavor
    if current.exists() or flavor != "orbit-engine-extensions-r3":
        return current
    # Retain the previous distribution under its original on-disk directory name.
    previous = list(DISTRIB.glob("*-engine-extensions-r3"))
    return previous[0] if len(previous) == 1 else current

EVIDENCE = MAIN / "artifacts/native-orbit-chromium-x2"
STAGE = LAB_DIR / "build/cef-stage"          # clone of the CEF repo holding branch orbit/8078
PATCH_EXPORT = LAB_DIR / "cef-patches"
BASE_CEF = "4fa4ab516dacf6c49fc7e6e70d2b7ebce29fa35f"
CHROMIUM_TAG = "156.0.8078.48"
SDK_WRAPPER_SHA256 = "5b85d48f3caf9069cb2ebf794722dc356925c3dcba0b7ad800065cdc57686e85"
FREE_GIB_GUARD = 80


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def guard():
    free = shutil.disk_usage(FORK).free / 2**30
    if free < FREE_GIB_GUARD:
        raise SystemExit("Free space %.1f GiB below the %d GiB guard" % (free, FREE_GIB_GUARD))
    return round(free, 1)


def baseline_idle():
    status = json.loads((MAIN / "artifacts/native-chromium-source/status.json").read_text())
    completed = status.get("state") == "build_complete" and status.get("compilation") == "completed"
    # A completed JSON record can outlive its worker. The shared flock below is
    # authoritative for source-tree mutation and must cover the entire operation.
    return completed and status.get("child_pid") is None, status


@contextmanager
def source_tree_lock():
    if (FORK / ".owner").read_text() not in ("orbit-chromium-source-v1",):
        raise SystemExit("Source laboratory owner marker mismatch")
    with (FORK / ".lock").open("a") as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit("Source laboratory is busy; refusing a concurrent operation")
        try:
            yield
        finally:
            fcntl.flock(stream, fcntl.LOCK_UN)


def preserve_baseline():
    """Preserve the completed stock build's provenance before any Orbit patch."""
    ok, status = baseline_idle()
    if not ok:
        raise SystemExit("Baseline worker has not completed")
    head = subprocess.check_output(["git", "-C", str(CEF_REPO), "rev-parse", "HEAD"], text=True).strip()
    dirty = subprocess.check_output(["git", "-C", str(CEF_REPO), "status", "--porcelain"], text=True)
    if head != BASE_CEF or dirty:
        raise SystemExit("Stock preservation requires the clean pinned CEF checkout")
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    destination = EVIDENCE / ("baseline-preservation-" + stamp)
    destination.mkdir(parents=True, exist_ok=False)
    original = MAIN / "artifacts/native-chromium-source"
    for name in ("status.json", "build-baseline.log", "commands.jsonl", "dependency-heads.json"):
        shutil.copy2(original / name, destination / name)
    shutil.copy2(SRC / OUT / "args.gn", destination / "args.gn")
    hashes = {}
    framework = SRC / OUT / "Chromium Embedded Framework.framework"
    for path in sorted(framework.rglob("*")):
        if path.is_file() and not path.is_symlink():
            hashes[str(path.relative_to(framework))] = {"sha256": sha256(path), "bytes": path.stat().st_size}
    manifest = {"completed_at": status["updated_at"], "preserved_at": datetime.now(timezone.utc).isoformat(),
                "verified_checkouts": status["verified_checkouts"], "gn_defines": status["gn_defines"],
                "framework_files": hashes,
                "evidence_hashes": {p.name: sha256(p) for p in sorted(destination.iterdir())}}
    (destination / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print("preserved baseline:", destination, flush=True)
    return destination


# A patched build may be published side by side under distrib/orbit-next while distrib/orbit is in
# use (packaging of the daily build); promotion to `orbit` is a separate, reviewed step.
# Candidate only: admission and source/build ownership remain separate PM gates.
PATCHED_FLAVORS = ("orbit", "orbit-next", "orbit-r3", "orbit-essentials-r2", "orbit-engine-extensions-r1",
                   "orbit-engine-extensions-toolbar-r1")
PATCHED_FLAVORS += ("orbit-engine-extensions-product",)
PATCHED_FLAVORS += ("orbit-engine-extensions-hosted",)
PATCHED_FLAVORS += ("orbit-engine-extensions-sidebar",)
PATCHED_FLAVORS += ("orbit-engine-extensions",)
PATCHED_FLAVORS += ("orbit-engine-extensions-r2",)
PATCHED_FLAVORS += ("orbit-engine-extensions-r3", "orbit-engine-extensions-r4", "orbit-engine-extensions-r5", "orbit-engine-extensions-r6", "orbit-engine-extensions-r7", "orbit-engine-extensions-r8", "orbit-engine-extensions-r9", "orbit-engine-extensions-r10", "orbit-engine-extensions-r11", "orbit-engine-extensions-r12", "orbit-engine-extensions-r13", "orbit-engine-extensions-r14")
FLAVORS = ("sdk", "stock") + PATCHED_FLAVORS


def flavor_paths(flavor):
    """(CEF_ROOT, wrapper library, expected wrapper hash or None, bundle build dir)."""
    if flavor == "sdk":
        lab = load(REPO / "scripts/orbit-chromium-lab.py", "orbit_chromium_lab")
        return lab.CEF_ROOT, lab.CEF_WRAPPER, SDK_WRAPPER_SHA256, LAB_DIR / "build/release"
    root = distribution_dir(flavor)
    candidates = sorted(root.glob("cef_binary_*_macosarm64_minimal")) if root.is_dir() else []
    if not candidates:
        raise SystemExit("No %s distribution under %s; run `distrib --flavor %s`" % (flavor, root, flavor))
    wrapper = root / "wrapper/libcef_dll_wrapper/libcef_dll_wrapper.a"
    return candidates[-1], wrapper, None, LAB_DIR / ("build/x2-" + flavor)


# --- CEF tree -----------------------------------------------------------------------------

def apply_orbit(args):
    ok, status = baseline_idle()
    if not ok:
        raise SystemExit("Baseline build not complete (%s); refusing to touch the tree" % status.get("state"))
    guard()
    if subprocess.check_output(["git", "-C", str(STAGE), "status", "--porcelain"], text=True):
        raise SystemExit("Commit the staged CEF patch before applying it")
    if check(args):
        raise SystemExit("CEF side API header mismatch")
    branch = subprocess.run(["git", "-C", str(STAGE), "rev-parse", "orbit/8078"], capture_output=True,
                            text=True, check=True).stdout.strip()
    manifest = json.loads((PATCH_EXPORT / "manifest.json").read_text())
    if manifest.get("cef_branch_sha") != branch or manifest.get("cef_base") != BASE_CEF or \
            sha256(PATCH_EXPORT / "libcef-orbit-8078.diff") != manifest.get("libcef_diff_sha256"):
        raise SystemExit("Exported patch manifest does not match the staged source")
    exported = {row["name"]: row["sha256"] for row in manifest["orbit_patches"]}
    actual = {Path(name).name: hashlib.sha256(data).hexdigest() for name, data in patch_contents(STAGE, branch)}
    if exported != actual or any(sha256(PATCH_EXPORT / name) != digest for name, digest in exported.items()):
        raise SystemExit("Exported Chromium patches do not match the staged source")
    approved, registry = admit_source_build(branch)
    with tempfile.TemporaryDirectory(prefix="orbit-patch-transition-") as temporary:
        desired = materialize_transition(Path(temporary), approved, registry, branch)
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
        journal = EVIDENCE / ("apply-transition-" + stamp + ".json")
        record = {"stage": "prepared", "approved_source": approved["source_head"],
                  "approved_framework": approved["framework_sha256"], "desired_source": branch,
                  "targets": {name: {"before": sha256(SRC / name),
                                     "after": hashlib.sha256(data).hexdigest()}
                              for name, data in desired.items()}}
        atomic_json(journal, record)
        try:
            checkout_staged_branch(STAGE, CEF_REPO, branch)
            record["stage"] = "cef-checked-out"
            atomic_json(journal, record)
            for name, data in desired.items():
                target = SRC / name
                # Only exact known states survived materialize_transition.
                if sha256(target) != record["targets"][name]["before"]:
                    raise SystemExit("Source changed during transition: " + name)
                atomic_bytes(target, data, stat.S_IMODE(target.stat().st_mode))
                record["targets"][name]["written"] = True
                atomic_json(journal, record)
            if git_output(CEF_REPO, "rev-parse", "HEAD") != branch or git_output(CEF_REPO, "status", "--porcelain"):
                raise SystemExit("CEF identity changed during transition")
            require_clean_chromium_index()
            exclusions = [":(exclude)" + name for name in registry["patch_targets"]]
            unrelated = subprocess.check_output(["git", "-C", str(SRC), "diff", "--binary", "HEAD", "--", ".", *exclusions])
            if hashlib.sha256(unrelated).hexdigest() != approved["unaffected_diff_sha256"]:
                raise SystemExit("Chromium changed outside owned targets during transition")
            if any(sha256(SRC / name) != row["after"] for name, row in record["targets"].items()):
                raise SystemExit("Chromium transition output mismatch")
            record["stage"] = "completed"
            atomic_json(journal, record)
        except BaseException as error:
            record.update(stage="failed", error=str(error))
            atomic_json(journal, record)
            raise
    print(json.dumps({"branch": branch, "journal": str(journal), "stage": "completed"}))
    return 0


def atomic_bytes(path, data, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    try:
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        # This exact temporary file is owned by this write; never clean up a
        # caller's existing source or an unrelated staging directory.
        temporary.unlink(missing_ok=True)


def atomic_json(path, record):
    atomic_bytes(path, (json.dumps(record, indent=2) + "\n").encode())


def git_output(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()


def require_clean_chromium_index():
    # CEF's reviewed baseline patches are working-tree changes, never staged.
    # Reject staged deltas even when the working file has been restored to a
    # known state, so the index cannot conceal or preserve an unknown source.
    result = subprocess.run(["git", "-C", str(SRC), "diff", "--cached", "--quiet", "HEAD", "--"],
                            capture_output=True)
    if result.returncode != 0:
        raise SystemExit("Chromium index has unapproved staged changes or cannot be verified")


def checked_proof(proof):
    path = EVIDENCE / proof["path"]
    if not path.resolve().is_relative_to(EVIDENCE.resolve()) or path.is_symlink() or not path.is_file():
        raise SystemExit("Missing or unsafe approved build proof")
    if sha256(path) != proof["sha256"]:
        raise SystemExit("Approved build proof was modified: " + proof["path"])
    return path


def admit_source_build(desired):
    """Trust only reviewed, versioned pins, never a worker/distribution JSON alone."""
    registry_path = PATCH_EXPORT / "approved-builds.json"
    relative = str(registry_path.relative_to(REPO))
    committed = subprocess.check_output(["git", "-C", str(REPO), "show", "HEAD:" + relative])
    if registry_path.read_bytes() != committed:
        raise SystemExit("Uncommitted approval registry cannot authorize a source transition")
    registry = json.loads(committed)
    if registry.get("schema") != 1 or git_output(SRC, "rev-parse", "HEAD") != registry["chromium_head"]:
        raise SystemExit("Unapproved Chromium source identity")
    checked_proof(registry["baseline_diff"])
    framework = SRC / OUT / "Chromium Embedded Framework.framework/Chromium Embedded Framework"
    digest = sha256(framework)
    approved = next((row for row in registry["builds"] if row["framework_sha256"] == digest), None)
    if approved is None:
        raise SystemExit("Framework has no reviewed build provenance")
    proofs = {name: checked_proof(proof) for name, proof in approved["proofs"].items()}
    if approved["kind"] == "orbit":
        terminal = json.loads(proofs["terminal"].read_text())
        preflight = json.loads(proofs["source_preflight"].read_text())
        verified = json.loads(proofs["build_verified"].read_text())
        # Two reviewed preflight layouts: the initial apply's `cef_stage_head` and the later
        # transitions' `pins.stage` (reader-detach-apply-20261025T142715Z).
        staged = preflight.get("cef_stage_head") or (preflight.get("pins") or {}).get("stage")
        if terminal.get("exit") != 0 or terminal.get("framework_sha256") != digest or \
                staged != approved["source_head"] or \
                verified.get("cef_head") != approved["source_head"]:
            raise SystemExit("Approved build proof identity mismatch")
    elif approved["kind"] != "stock" or approved["source_head"] != BASE_CEF:
        raise SystemExit("Invalid stock build provenance")
    if sha256(SRC / OUT / "args.gn") != approved["gn_args_sha256"]:
        raise SystemExit("Build configuration changed since the approved build")
    if git_output(CEF_REPO, "status", "--porcelain"):
        raise SystemExit("CEF target has uncommitted changes")
    current = git_output(CEF_REPO, "rev-parse", "HEAD")
    # Admission stays read-only. Every accepted current revision must already
    # be in the reviewed staging ancestry; fetching belongs to the later
    # journaled checkout, after all source states have been validated.
    for before, after in ((approved["source_head"], current), (current, desired)):
        if subprocess.run(["git", "-C", str(STAGE), "merge-base", "--is-ancestor", before, after],
                          capture_output=True).returncode:
            raise SystemExit("CEF source diverges from approved build/staging")
    require_clean_chromium_index()
    exclusions = [":(exclude)" + name for name in registry["patch_targets"]]
    diff = subprocess.check_output(["git", "-C", str(SRC), "diff", "--binary", "HEAD", "--", ".", *exclusions])
    if hashlib.sha256(diff).hexdigest() != approved["unaffected_diff_sha256"]:
        raise SystemExit("Chromium has unowned changes outside the reviewed patch targets")
    return approved, registry


def patch_contents(repo, revision):
    names = git_output(repo, "ls-tree", "-r", "--name-only", revision, "patch/patches").splitlines()
    return [(name, subprocess.check_output(["git", "-C", str(repo), "show", revision + ":" + name]))
            for name in names if Path(name).name.startswith("orbit_") and name.endswith(".patch")]


def materialize_transition(directory, approved, registry, desired):
    """Reconstruct base/previous/desired files offline; refuse every unknown state."""
    directory.mkdir(parents=True, exist_ok=True)
    base, previous, updated = (directory / name for name in ("base", "previous", "desired"))
    base.mkdir()
    targets = registry["patch_targets"]
    for name in targets:
        path = base / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(subprocess.check_output(["git", "-C", str(SRC), "show", registry["chromium_head"] + ":" + name]))
    subprocess.run(["git", "init", "-q", str(base)], check=True)
    baseline = checked_proof(registry["baseline_diff"]).read_bytes()
    # The saved baseline diff includes the ordinary CEF patches (a/b prefixes).
    if baseline:
        subprocess.run(["git", "-C", str(base), "apply", "-p1", "--allow-empty",
                        *["--include=" + name for name in targets], "-"], input=baseline, check=True)
    shutil.copytree(base, previous)
    shutil.copytree(base, updated)
    for repository, revision, tree in ((CEF_REPO, approved["source_head"], previous), (STAGE, desired, updated)):
        for name, data in patch_contents(repository, revision):
            changed = [line[4:] for line in data.decode().splitlines() if line.startswith("+++ ")]
            if any(path not in targets for path in changed):
                raise SystemExit("Patch target requires an updated provenance review: " + name)
            subprocess.run(["git", "-C", str(tree), "apply", "-p0", "-"], input=data, check=True)
    result = {}
    for name in targets:
        target = SRC / name
        if target.is_symlink() or not target.is_file():
            raise SystemExit("Unsafe Chromium patch target: " + name)
        states = [(tree / name).read_bytes() for tree in (base, previous, updated)]
        if hashlib.sha256(states[1]).hexdigest() != approved["chromium_files"][name]:
            raise SystemExit("Previous source patch identity disagrees with its reviewed proof")
        if target.read_bytes() not in states:
            raise SystemExit("Unowned Chromium patch target change: " + name)
        result[name] = states[2]
    return result


def checkout_staged_branch(stage, target, desired):
    """Resume after checkout/patch interruption without fetching into HEAD's ref."""
    def git(*arguments, check=True):
        return subprocess.run(["git", "-C", str(target), *arguments], capture_output=True,
                              text=True, check=check)
    if git("status", "--porcelain").stdout:
        raise SystemExit("CEF target has uncommitted changes; refusing to replace them")
    current = git("rev-parse", "HEAD").stdout.strip()
    existing = git("rev-parse", "--verify", "refs/heads/orbit/8078", check=False)
    existing_sha = existing.stdout.strip() if existing.returncode == 0 else None
    # Fetch only an incoming ref, never a possibly checked-out local branch.
    if existing_sha != desired or current != desired:
        git("fetch", "-q", str(stage), "orbit/8078:refs/orbit/incoming-8078")
        if git("rev-parse", "refs/orbit/incoming-8078").stdout.strip() != desired:
            raise SystemExit("Staged branch changed during fetch")
        for candidate in (current, existing_sha):
            if candidate and candidate != desired:
                if git("merge-base", "--is-ancestor", candidate, desired, check=False).returncode:
                    raise SystemExit("CEF checkout or local Orbit branch diverges from the staged patch")
        if existing_sha:
            git("checkout", "-q", "orbit/8078")
            if existing_sha != desired:
                git("merge", "--ff-only", "refs/orbit/incoming-8078")
        else:
            git("checkout", "-q", "-b", "orbit/8078", "refs/orbit/incoming-8078")
    elif git("branch", "--show-current").stdout.strip() != "orbit/8078":
        git("checkout", "-q", "orbit/8078")


def build_cef(args):
    ok, status = baseline_idle()
    if not ok:
        raise SystemExit("Baseline build not complete (%s)" % status.get("state"))
    free = guard()
    source_lab = load(MAIN / "scripts/chromium-source-lab.py", "chromium_source_lab")
    profile = FORK / "build-isolation.sb"
    if not profile.is_file() or profile.is_symlink():
        raise SystemExit("Missing build isolation profile; run the source lab once")
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    log = EVIDENCE / ("build-cef-%s-%s.log" % (stamp, args.label))
    targets = args.targets or ["cef"]
    command = ["/usr/bin/sandbox-exec", "-f", str(profile), "nice", "-n", "10",
               str(FORK / "depot_tools/autoninja"), "-C", OUT, "-j", "12"] + targets
    env = dict(source_lab.ENV, NINJA_STATUS="[%f/%t %es] ")
    wrapper = [sys.executable, str(Path(__file__).resolve()), "_timed", str(log)] + command
    record = {"stamp": stamp, "label": args.label, "command": command, "log": str(log), "free_gib": free}
    if args.wait:
        code = subprocess.run(wrapper, cwd=SRC, env=env).returncode
        print((log.with_suffix(".json")).read_text())
        return code
    process = subprocess.Popen(wrapper, cwd=SRC, env=env, stdin=subprocess.DEVNULL,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    record["pid"] = process.pid
    print(json.dumps(record, indent=2))
    return 0


def timed(log, command):
    started = time.time()
    with open(log, "ab") as stream:
        code = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT).returncode
    record = {"command": command, "exit": code, "seconds": round(time.time() - started, 1),
              "finished": datetime.now(timezone.utc).isoformat(),
              "framework_sha256": None}
    framework = SRC / OUT / "Chromium Embedded Framework.framework/Chromium Embedded Framework"
    if framework.exists():
        record["framework_sha256"] = sha256(framework)
    Path(log).with_suffix(".json").write_text(json.dumps(record, indent=2))
    return code


def distrib(args):
    # A joined incremental build in the locked caller establishes completion directly.
    # Older standalone exports still require their original baseline status.
    if not getattr(args, "incremental_build_completed", False):
        ok, status = baseline_idle()
        if not ok:
            raise SystemExit("Baseline build not complete (%s)" % status.get("state"))
    guard()
    head = subprocess.check_output(["git", "-C", str(CEF_REPO), "rev-parse", "HEAD"], text=True).strip()
    if args.flavor == "stock" and head != BASE_CEF:
        raise SystemExit("Stock distribution requires the pinned unpatched CEF commit")
    if args.flavor in PATCHED_FLAVORS and head == BASE_CEF:
        raise SystemExit("Orbit distribution requires a built patched CEF checkout")
    target = DISTRIB / args.flavor
    if target.exists():
        if not args.replace:
            raise SystemExit("%s exists; pass --replace" % target)
        shutil.rmtree(target)
    target.mkdir(parents=True)
    if args.flavor == "stock":
        preserve_baseline()
    source_lab = load(MAIN / "scripts/chromium-source-lab.py", "chromium_source_lab")
    started = time.time()
    distributor = ["tools/make_distrib.py"]
    build_suffix = getattr(args, "build_dir_suffix", None)
    if build_suffix:
        # CEF's distributor hardcodes its output configuration. Select our separate
        # codec cache in this process, without renaming either shared build tree.
        distributor = ["-c", "import runpy, sys; sys.path.insert(0, 'tools'); "
                       "m = runpy.run_path('tools/make_distrib.py'); "
                       "suffix = sys.argv.pop(1); "
                       "m['main'].__globals__['get_architecture'] = "
                       "lambda options: ('arm64', 'arm64', suffix); "
                       "sys.exit(m['main']())", build_suffix]
    command = ["nice", "-n", "10", sys.executable, *distributor, "--output-dir", str(target),
               "--ninja-build", "--arm64-build", "--minimal", "--allow-partial", "--no-docs", "--no-archive",
               "--no-symbols", "--no-format"]
    subprocess.run(command, cwd=CEF_REPO, env=source_lab.ENV, check=True)
    root = sorted(target.glob("cef_binary_*_macosarm64_minimal"))[-1]
    wrapper_dir = target / "wrapper"
    subprocess.run(["cmake", "-S", str(root), "-B", str(wrapper_dir), "-G", "Ninja",
                    "-DCMAKE_BUILD_TYPE=Release", "-DPROJECT_ARCH=arm64"], check=True,
                   stdout=subprocess.DEVNULL)
    subprocess.run(["nice", "-n", "10", "cmake", "--build", str(wrapper_dir), "--target", "libcef_dll_wrapper"],
                   check=True)
    framework = root / "Release/Chromium Embedded Framework.framework/Chromium Embedded Framework"
    manifest = {"flavor": args.flavor, "root": str(root), "seconds": round(time.time() - started, 1),
                "framework_sha256": sha256(framework), "framework_bytes": framework.stat().st_size,
                "wrapper_sha256": sha256(wrapper_dir / "libcef_dll_wrapper/libcef_dll_wrapper.a"),
                "cef_head": subprocess.run(["git", "-C", str(CEF_REPO), "rev-parse", "HEAD"], capture_output=True,
                                           text=True).stdout.strip(),
                "exports_orbit_cef_get_api": "orbit_cef_get_api" in subprocess.run(
                    ["nm", "-gU", str(framework)], capture_output=True, text=True).stdout}
    if manifest["exports_orbit_cef_get_api"] != (args.flavor in PATCHED_FLAVORS):
        raise SystemExit("Framework exports disagree with the requested distribution flavor; build it first")
    (target / "manifest.json").write_text(json.dumps(manifest, indent=2))
    print(json.dumps(manifest, indent=2))
    return 0


# --- Lab bundle -----------------------------------------------------------------------------

def build_bundle(args):
    root, wrapper, expected, build = flavor_paths(args.flavor)
    wrapper_hash = expected or sha256(wrapper)
    framework = root / "Release/Chromium Embedded Framework.framework/Chromium Embedded Framework"
    if args.flavor == "sdk":
        framework_hash = "9c81eb633abb7c1ebd5058f939061b4ece215d8f56e053114dac7073204800e8"
    else:
        manifest = json.loads((distribution_dir(args.flavor) / "manifest.json").read_text())
        framework_hash = manifest["framework_sha256"]
        if wrapper_hash != manifest["wrapper_sha256"]:
            raise SystemExit("Distribution wrapper differs from its manifest")
    subprocess.run(["cmake", "-S", str(LAB_DIR), "-B", str(build), "-G", "Ninja", "-DCMAKE_BUILD_TYPE=Release",
                    "-DCEF_ROOT=" + str(root), "-DCEF_WRAPPER_LIBRARY=" + str(wrapper),
                    "-DCEF_WRAPPER_SHA256=" + wrapper_hash,
                    "-DCEF_FRAMEWORK_SHA256=" + framework_hash], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(["nice", "-n", "10", "cmake", "--build", str(build)], check=True)
    app = build / "OrbitChromium.app"
    if not args.no_sign:
        subprocess.run(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(app)], check=True,
                       stderr=subprocess.DEVNULL)
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    return 0


def run_lab(args):
    if args.visible_input_only and args.x2_only:
        raise SystemExit("--visible-input-only cannot be combined with --x2-only")
    if args.visible_input_seconds is not None and (not args.visible_input_only or not 15 <= args.visible_input_seconds <= 60):
        raise SystemExit("Visible input duration requires its mode and must be 15 to 60 seconds")
    root, _, _, build = flavor_paths(args.flavor)
    lab = load(REPO / "scripts/orbit-chromium-lab.py", "orbit_chromium_lab")
    lab.BUILD = build
    lab.APP = build / "OrbitChromium.app"
    lab.HOST = lab.APP / "Contents/MacOS/OrbitChromium"
    if hasattr(lab, "WATCH"):
        lab.WATCH = build / "OrbitWindowWatch"
    if not lab.HOST.exists():
        raise SystemExit("Build the %s bundle first" % args.flavor)
    if args.x2_only:
        os.environ["ORBIT_LAB_X2_ONLY"] = "1"
    temporary = Path(tempfile.mkdtemp(prefix="orbit-x2-evidence-"))
    argv = ["orbit-chromium-lab.py", "run", "--evidence-root", str(temporary), "--timeout", str(args.timeout)]
    if args.visible_input_only:
        argv.append("--visible-input-only")
        if args.visible_input_seconds is not None:
            argv.extend(["--visible-input-seconds", str(args.visible_input_seconds)])
    if args.no_extension:
        argv.append("--no-extension")
    sys.argv = argv
    code = lab.main()
    produced = sorted((temporary / "artifacts/native-orbit-chromium").iterdir())
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    framework = root / "Release/Chromium Embedded Framework.framework/Chromium Embedded Framework"
    for directory in produced:
        destination = EVIDENCE / (directory.name + "-" + args.flavor + ("-visible-input" if args.visible_input_only else "-x2only" if args.x2_only else ""))
        shutil.move(str(directory), destination)
        context = {"flavor": args.flavor, "cefRoot": str(root).replace(str(MAIN), "<main>"),
                   "frameworkSHA256": sha256(framework), "bundleBuildDir": str(build).replace(str(REPO), "<worktree>"),
                   "x2Only": args.x2_only, "auditMode": "visible-input" if args.visible_input_only else "hidden",
                   "labExit": code}
        manifest = PATCH_EXPORT / "manifest.json"
        if args.flavor in PATCHED_FLAVORS and manifest.exists():
            context["patchManifest"] = json.loads(manifest.read_text())
        (destination / "x2.json").write_text(json.dumps(context, indent=2))
        print("evidence:", destination)
    shutil.rmtree(temporary, ignore_errors=True)
    return code


# --- Distribution comparison (X2.0) -----------------------------------------------------------

def header_tokens(value):
    """Compare C/C++ header tokens while preserving literals and ignoring formatting."""
    tokens = re.findall(r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|//[^\n]*|/\*[\s\S]*?\*/|[A-Za-z0-9_]+|[^\s]', value)
    return [token for token in tokens if not token.startswith(("//", "/*"))]


def describe(root):
    framework_dir = root / "Release/Chromium Embedded Framework.framework"
    binary = framework_dir / "Chromium Embedded Framework"
    files = {}
    for path in sorted(framework_dir.rglob("*")):
        if path.is_file() and not path.is_symlink():
            files[str(path.relative_to(framework_dir))] = path.stat().st_size
    includes = hashlib.sha256()
    normalized_includes = hashlib.sha256()
    for path in sorted((root / "include").rglob("*.h")):
        if path.name != "cef_version.h":
            includes.update(str(path.relative_to(root)).encode() + b"\0" + path.read_bytes())
            normalized_includes.update(str(path.relative_to(root)).encode() + b"\0" +
                                       json.dumps(header_tokens(path.read_text())).encode())
    exports = subprocess.run(["nm", "-gU", str(binary)], capture_output=True, text=True).stdout.split("\n")
    exported = sorted(line.split()[-1] for line in exports if line.strip())
    plist = subprocess.run(["/usr/libexec/PlistBuddy", "-c", "Print", str(framework_dir / "Resources/Info.plist")],
                           capture_output=True, text=True).stdout
    version = (root / "include/cef_version.h").read_text()
    return {
        "binaryBytes": binary.stat().st_size, "binarySHA256": sha256(binary),
        "frameworkFiles": len(files), "frameworkBytes": sum(files.values()), "files": files,
        "includeTreeSHA256WithoutVersionHeader": includes.hexdigest(),
        "includeTokensSHA256WithoutVersionHeader": normalized_includes.hexdigest(),
        "exportedSymbols": len(exported), "exportedCefSymbols": len([s for s in exported if s.startswith("_cef_")]),
        "exportedSymbolNames": exported,
        "exportsOrbit": "_orbit_cef_get_api" in exported,
        "linkedLibraries": subprocess.run(["otool", "-L", str(binary)], capture_output=True,
                                          text=True).stdout.splitlines()[1:],
        "versionDefines": [line for line in version.splitlines() if line.startswith("#define CEF_") or
                           line.startswith("#define CHROME_VERSION")],
        "infoPlist": plist,
    }


def compare(args):
    left, _, _, _ = flavor_paths(args.left)
    right, _, _, _ = flavor_paths(args.right)
    a, b = describe(left), describe(right)
    files = sorted(set(a["files"]) | set(b["files"]))
    deltas = [{"file": f, args.left: a["files"].get(f), args.right: b["files"].get(f)} for f in files
              if a["files"].get(f) != b["files"].get(f)]
    result = {"left": args.left, "right": args.right,
              "summary": {k: [a[k], b[k]] for k in ("binaryBytes", "frameworkFiles", "frameworkBytes",
                                                    "exportedSymbols", "exportedCefSymbols", "exportsOrbit",
                                                    "includeTreeSHA256WithoutVersionHeader")},
              "sameIncludeTree": a["includeTreeSHA256WithoutVersionHeader"] == b["includeTreeSHA256WithoutVersionHeader"],
              "sameIncludeTokens": a["includeTokensSHA256WithoutVersionHeader"] == b["includeTokensSHA256WithoutVersionHeader"],
              "sameExportedSymbols": a["exportedSymbolNames"] == b["exportedSymbolNames"],
              "versionDefines": {args.left: a["versionDefines"], args.right: b["versionDefines"]},
              "linkedLibraries": {args.left: a["linkedLibraries"], args.right: b["linkedLibraries"]},
              "infoPlistEqual": a["infoPlist"] == b["infoPlist"],
              "infoPlist": {args.left: a["infoPlist"], args.right: b["infoPlist"]},
              "fileDeltas": deltas}
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    out = EVIDENCE / ("compare-%s-%s.json" % (args.left, args.right))
    out.write_text(json.dumps(result, indent=2))
    print(json.dumps({k: v for k, v in result.items() if k not in ("infoPlist", "fileDeltas")}, indent=2))
    print("file deltas:", len(deltas), "->", out)
    return 0


# --- Patch export ---------------------------------------------------------------------------

def export(args):
    repo = Path(args.cef_repo) if args.cef_repo else STAGE
    head = subprocess.run(["git", "-C", str(repo), "rev-parse", "orbit/8078"], capture_output=True, text=True,
                          check=True).stdout.strip()
    PATCH_EXPORT.mkdir(parents=True, exist_ok=True)
    for old in PATCH_EXPORT.glob("*.patch"):
        old.unlink()
    patches = sorted((repo / "patch/patches").glob("orbit_*.patch"))
    names = []
    for patch in patches:
        shutil.copy2(patch, PATCH_EXPORT / patch.name)
        names.append({"name": patch.name, "sha256": sha256(patch)})
    # The libcef side (new files and hooks) as one reviewable diff against the base commit.
    diff = subprocess.run(["git", "-C", str(repo), "diff", "--binary", BASE_CEF, "orbit/8078", "--",
                           ".", ":(exclude)patch/patches"], capture_output=True, text=True, check=True).stdout
    (PATCH_EXPORT / "libcef-orbit-8078.diff").write_text(diff)
    log = subprocess.run(["git", "-C", str(repo), "log", "--format=%H %s", BASE_CEF + "..orbit/8078"],
                         capture_output=True, text=True, check=True).stdout.strip().splitlines()
    stat = subprocess.run(["git", "-C", str(repo), "diff", "--numstat", BASE_CEF, "orbit/8078"],
                          capture_output=True, text=True, check=True).stdout.strip().splitlines()
    chromium_lines = 0
    chromium_files = set()
    for patch in patches:
        for line in patch.read_text().splitlines():
            if line.startswith("+++ "):
                chromium_files.add(line[4:])
            elif (line.startswith("+") or line.startswith("-")) and not line.startswith(("+++", "---")):
                chromium_lines += 1
    manifest = {
        "cef_branch": "orbit/8078", "cef_branch_sha": head, "cef_base": BASE_CEF, "chromium_tag": CHROMIUM_TAG,
        "patch_cfg_sha256": sha256(repo / "patch/patch.cfg"), "patch_condition": "ORBIT_CEF_PATCHES",
        "orbit_patches": names, "commits": log,
        "chromium_patch_files": sorted(chromium_files), "chromium_changed_lines": chromium_lines,
        "libcef_numstat": stat, "libcef_diff_sha256": sha256(PATCH_EXPORT / "libcef-orbit-8078.diff"),
        "side_api_header": "libcef/browser/orbit/orbit_cef_api.h (copied as native/OrbitChromium/Bridge/OrbitCefApi.h)",
    }
    (PATCH_EXPORT / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(manifest, indent=2))
    return check(args)


def check(args):
    repo = Path(getattr(args, "cef_repo", None) or STAGE)
    branch = subprocess.run(["git", "-C", str(repo), "show", "orbit/8078:libcef/browser/orbit/orbit_cef_api.h"],
                            capture_output=True, text=True, check=True).stdout
    copy = (LAB_DIR / "Bridge/OrbitCefApi.h").read_text()
    if branch != copy:
        print("Bridge/OrbitCefApi.h differs from orbit/8078:libcef/browser/orbit/orbit_cef_api.h")
        return 1
    print("OrbitCefApi.h identical to the branch header")
    return 0


def main():
    if len(sys.argv) > 2 and sys.argv[1] == "_timed":
        with source_tree_lock():
            return timed(sys.argv[2], sys.argv[3:])
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("apply-orbit")
    builder = sub.add_parser("build-cef")
    builder.add_argument("--label", default="incremental")
    builder.add_argument("--wait", action="store_true")
    builder.add_argument("targets", nargs="*")
    distributor = sub.add_parser("distrib")
    distributor.add_argument("--flavor", choices=["stock", *PATCHED_FLAVORS], required=True)
    distributor.add_argument("--replace", action="store_true")
    bundle = sub.add_parser("build")
    bundle.add_argument("--flavor", choices=FLAVORS, required=True)
    bundle.add_argument("--no-sign", action="store_true", help="Compile and package only; do not sign or execute")
    runner = sub.add_parser("run")
    runner.add_argument("--flavor", choices=FLAVORS, required=True)
    runner.add_argument("--visible-input-only", action="store_true")
    runner.add_argument("--visible-input-seconds", type=int)
    runner.add_argument("--x2-only", action="store_true")
    runner.add_argument("--no-extension", action="store_true")
    runner.add_argument("--timeout", type=int, default=330)
    exporter = sub.add_parser("export")
    exporter.add_argument("--cef-repo")
    comparer = sub.add_parser("compare")
    comparer.add_argument("--left", choices=FLAVORS, default="sdk")
    comparer.add_argument("--right", choices=FLAVORS, default="stock")
    checker = sub.add_parser("check")
    checker.add_argument("--cef-repo")
    args = parser.parse_args()
    action = {"apply-orbit": apply_orbit, "build-cef": build_cef, "distrib": distrib, "build": build_bundle,
              "run": run_lab, "export": export, "check": check, "compare": compare}[args.command]
    if args.command in ("apply-orbit", "distrib"):
        with source_tree_lock():
            return action(args)
    return action(args)


if __name__ == "__main__":
    sys.exit(main())
