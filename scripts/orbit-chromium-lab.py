#!/usr/bin/env python3
"""ENG-X1 laboratory runner: build, ad hoc sign and run the hidden OrbitChromium bundle.

Synthetic data only. The fixture binds 127.0.0.1 on an ephemeral port (never 4318), the CEF
root is a fresh private directory in the ignored build tree, `--use-mock-keychain` is always
passed, and every process started is killed and verified gone before returning. Evidence (no
cache, no personal data) is copied to <evidence-root>/artifacts/native-orbit-chromium/<stamp>/.
"""
import argparse
import ctypes
import hashlib
import html
import json
import os
import shutil
import signal
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

REPO = Path(__file__).resolve().parent.parent
LAB = REPO / "native/OrbitChromium"
BUILD = LAB / "build/release"
APP = BUILD / "OrbitChromium.app"
HOST = APP / "Contents/MacOS/OrbitChromium"
WATCH = BUILD / "OrbitWindowWatch"
EXTENSION = REPO / "native/EngineGate/extension"
# The pinned SDK and the evidence directory live in the main checkout (ignored paths that a
# worktree does not contain); resolve it from the shared Git directory.
MAIN = Path(subprocess.run(["git", "-C", str(REPO), "rev-parse", "--path-format=absolute", "--git-common-dir"],
                           capture_output=True, text=True, check=True).stdout.strip()).parent
CEF = MAIN / ".tools/cef"
CEF_ROOT = CEF / "source/cef_binary_156.0.14+g4fa4ab5+chromium-156.0.8078.48_macosarm64"
CEF_WRAPPER = CEF / "build-release-arm64/libcef_dll_wrapper/libcef_dll_wrapper.a"
MARKER = "orbit-chromium-lab-v1\n"
# Valid 16 x 16 RGBA checkerboard; Chromium rejects the former malformed IDAT chunk.
FAVICON = bytes.fromhex(
    "89504e470d0a1a0a0000000d49484452000000100000001008060000001ff3ff610000002c49444154789c6378f3f1ff"
    "7f64ec16f9140513926718060690aa015d7e381830f0b130f0060c7c2c0cb801001d892f2e3effefcc0000000049454e"
    "44ae426082")


def build():
    subprocess.run(["cmake", "-S", str(LAB), "-B", str(BUILD), "-G", "Ninja", "-DCMAKE_BUILD_TYPE=Release",
                    "-DCEF_ROOT=" + str(CEF_ROOT), "-DCEF_WRAPPER_LIBRARY=" + str(CEF_WRAPPER)],
                   check=True, stdout=subprocess.DEVNULL)
    subprocess.run(["cmake", "--build", str(BUILD)], check=True)
    # Ad hoc signature of the private synthetic copy only; never a personal identity.
    subprocess.run(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(APP)],
                   check=True, stderr=subprocess.DEVNULL)
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(APP)], check=True)


def download_size(case):
    return 6 * 1024 * 1024 if case.startswith("slow") else 65536


def download_chunks(case):
    """Deterministic, non-repeating synthetic content: 64 KiB chunks derived from the case."""
    for index in range(download_size(case) // 65536):
        yield hashlib.sha256(("%s:%d" % (case, index)).encode()).digest() * 2048


def download_sha256(case):
    digest = hashlib.sha256()
    for chunk in download_chunks(case):
        digest.update(chunk)
    return digest.hexdigest()


# Viewport probe (EXT-OUTCOME-R1): the document reports its layout viewport in its title on load
# and on every resize, so the hidden smoke compares it with the native host view. Numbers only.
GEOMETRY_SCRIPT = ("<script>function r(){var e=document.documentElement;document.title='geom '+"
                   "innerWidth+' '+e.clientWidth+' '+e.scrollWidth+' '+Math.round(devicePixelRatio*100)}"
                   "addEventListener('resize',r);addEventListener('load',r);r()</script>")


def page(case):
    needles = "<p>needle one, needle two and a final needle.</p>" if case == "find" else ""
    probe = GEOMETRY_SCRIPT if case == "geometry" else ""
    return ("<!doctype html><html lang=en><meta charset=utf-8><link rel=icon href=/favicon.png>"
            "<title>Synthetic " + html.escape(case) + "</title>" + probe + "<body>"
            "<h1>Synthetic " + html.escape(case) + "</h1>" + needles +
            "<input id=field value=''><p><a id=plain href='/page?case=plain-child'>plain</a> "
            "<a id=blank target=_blank href='/page?case=blank-child'>blank</a></p></body></html>").encode()


def handler(run_root, counters):
    class Fixture(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def reply(self, status, body=b"", kind="text/html; charset=utf-8", extra=()):
            self.send_response(status)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            for name, value in extra:
                self.send_header(name, value)
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def do_GET(self):
            parts = urlsplit(self.path)
            query = parse_qs(parts.query)
            case = query.get("case", [""])[0]
            counters[parts.path] = counters.get(parts.path, 0) + 1
            if parts.path == "/page" and case:
                return self.reply(200, page(case))
            if parts.path == "/favicon.png":
                return self.reply(200, FAVICON, "image/png")
            if parts.path == "/blocked":
                return self.reply(200, b'{"synthetic":true}', "application/json")
            if parts.path == "/download-sha256" and case:
                return self.reply(200, download_sha256(case).encode(), "text/plain; charset=utf-8")
            if parts.path == "/download" and case:
                slow = case.startswith("slow")
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Disposition", 'attachment; filename="synthetic-' + case + '.bin"')
                self.send_header("Content-Length", str(download_size(case)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                try:
                    for chunk in download_chunks(case):
                        self.wfile.write(chunk)
                        self.wfile.flush()
                        if slow:
                            time.sleep(0.06)
                except (BrokenPipeError, ConnectionResetError):
                    counters["download-aborted:" + case] = counters.get("download-aborted:" + case, 0) + 1
                return
            return self.reply(404)

        def do_POST(self):
            if self.path != "/report":
                return self.reply(404)
            length = int(self.headers.get("Content-Length", "0") or 0)
            if not 0 < length <= 65536:
                return self.reply(413)
            body = self.rfile.read(length)
            try:
                report = json.loads(body)
                case = str(report.get("case") or "unknown")
            except ValueError:
                return self.reply(400)
            if not case.replace("-", "").isalnum():
                return self.reply(400)
            target = run_root / "reports" / (case + ".json")
            target.write_bytes(json.dumps(report, indent=2, sort_keys=True).encode())
            os.chmod(target, 0o600)
            self.reply(200, b'{"accepted":true}', "application/json")
    return Fixture


def descendants(pid):
    found = []
    out = subprocess.run(["/bin/ps", "-Ao", "pid=,ppid="], capture_output=True, text=True).stdout
    children = {}
    for line in out.splitlines():
        child, parent = line.split()
        children.setdefault(int(parent), []).append(int(child))
    stack = [pid]
    while stack:
        for child in children.get(stack.pop(), []):
            found.append(child)
            stack.append(child)
    return found


def bundle_processes():
    out = subprocess.run(["/bin/ps", "-Ao", "pid=,command="], capture_output=True, text=True).stdout
    return [line.strip() for line in out.splitlines() if str(APP) in line]


def lab_events(run_root):
    path = run_root / "events.jsonl"
    if not path.exists():
        return []
    events = []
    for line in path.read_text(errors="replace").splitlines():
        try:
            events.append(json.loads(line))
        except ValueError:
            pass
    return events


class ProcessIdentityError(RuntimeError):
    def __init__(self, reason, expected, observed):
        self.evidence = {"reason": reason, "expected": expected, "observed": observed}
        super().__init__("Process identity refused: " + reason)


class ProcessBSDInfo(ctypes.Structure):
    # Darwin SDK sys/proc_info.h, PROC_PIDTBSDINFO. No argv or environment is read.
    _fields_ = [(name, ctypes.c_uint32) for name in
                ("flags", "status", "xstatus", "pid", "ppid", "uid", "gid", "ruid", "rgid", "svuid", "svgid", "reserved")]
    _fields_ += [("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32)]
    _fields_ += [(name, ctypes.c_uint32) for name in ("nfiles", "pgid", "jobc", "tdev", "tpgid")]
    _fields_ += [("nice", ctypes.c_int32), ("startSec", ctypes.c_uint64), ("startUsec", ctypes.c_uint64)]


PROC = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
PROC.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
PROC.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]


def process_observation(pid):
    def info():
        value = ProcessBSDInfo()
        count = PROC.proc_pidinfo(pid, 3, 0, ctypes.byref(value), ctypes.sizeof(value))
        if count != ctypes.sizeof(value):
            if not count and ctypes.get_errno() == 3:  # ESRCH, not a live unknown process.
                return None
            raise ProcessIdentityError("kernel-identity-unavailable", {"pid": pid}, {"errno": ctypes.get_errno()})
        return value
    first = info()
    if first is None:
        return None
    buffer = ctypes.create_string_buffer(4096)
    count = PROC.proc_pidpath(pid, buffer, len(buffer))
    second = info()
    if second is None:
        return None
    if (first.startSec, first.startUsec) != (second.startSec, second.startUsec):
        raise ProcessIdentityError("pid-fingerprint-changed", {"pid": pid, "startSec": first.startSec, "startUsec": first.startUsec},
                                   {"pid": pid, "startSec": second.startSec, "startUsec": second.startUsec})
    if second.status == 5:  # SZOMB; kill(pid, 0) would still succeed here.
        return None
    try:
        sid = os.getsid(pid)
    except ProcessLookupError:
        return None
    return {"pid": pid, "ppid": second.ppid, "uid": second.uid, "pgid": second.pgid, "sid": sid,
            "startSec": second.startSec, "startUsec": second.startUsec,
            "path": str(Path(os.fsdecode(buffer.value)).resolve()) if count > 0 else None}


# BL-LAB-WITNESS-CHROMIUM-CHILDREN (CHROMIUM-APP-R2). Two legitimate members of an owned Chromium
# group lie outside the attested bundle path:
#  - `/usr/bin/profiles status -type enrollment`, run once per process at start-up by Chromium
#    itself (base/enterprise_util_mac.mm). Admitted only at that exact path on the sealed system
#    volume, root-owned and not writable by others, as the child of another member of the group.
#  - Chromium's code-signing clone (feature MacAppCodeSignClone, code_sign_clone_manager.h): a
#    copy-on-write clone of the bundle under /private/var/folders/…/<id>.code_sign_clone/ whose main
#    executable is a hard link of the attested one, so the kernel may report the clone's path.
#    Admitted only when that clone's main executable is the attested executable's file (same
#    device and inode). Lab runs disable the feature; the attestation keeps the cleanup correct.
SYSTEM_HELPERS = frozenset({"/usr/bin/profiles"})
CODE_SIGN_CLONE_ROOT = Path("/private/var/folders")


def file_identity(path):
    try:
        info = os.stat(path)
    except OSError:
        return None
    return (info.st_dev, info.st_ino)


def is_system_binary(path):
    try:
        info = os.stat(path)
    except OSError:
        return False
    return info.st_uid == 0 and not info.st_mode & 0o022


def code_sign_clone_bundle(path):
    """The cloned bundle containing `path`, or None outside a code-signing clone."""
    parts = path.parts
    if not path.is_relative_to(CODE_SIGN_CLONE_ROOT):
        return None
    for index, part in enumerate(parts):
        if part.endswith(".code_sign_clone"):
            for end in range(index + 1, len(parts)):
                if parts[end].endswith((".app", ".app.bundle")):
                    return Path(*parts[:end + 1])
            return None
    return None


def member_attestation(observed, leader, executable, application, group):
    """How a live member of the owned group is attested, or None (then it is refused)."""
    if observed.get("path") is None:
        return None
    path = Path(observed["path"])
    helper = observed["pid"] != leader
    if path == executable:
        return "executable"
    if helper and path.is_relative_to(application):
        return "bundle"
    clone = code_sign_clone_bundle(path)
    if clone is not None:
        main = clone / "Contents/MacOS" / executable.name
        identity = file_identity(main)
        if identity is not None and identity == file_identity(executable):
            if path == main:
                return "code-sign-clone-executable"
            if helper:
                return "code-sign-clone-bundle"
    if helper and str(path) in SYSTEM_HELPERS and observed.get("ppid") in group and is_system_binary(path):
        return "system-helper"
    return None


def group_candidate_pids(group):
    output = subprocess.run(["/bin/ps", "-axo", "pid=,pgid="], capture_output=True,
                            text=True, check=True, timeout=2).stdout
    return [int(parts[0]) for line in output.splitlines() if len(parts := line.split()) == 2 and parts[1] == str(group)]


class OwnedProcessRun:
    """A new session per child; cancellation never interrupts its bounded cleanup."""
    child_exit_grace = 1.0
    term_grace = 1.0
    kill_grace = 2.0

    def __init__(self):
        self.processes = []
        self.cancelled = False
        self.forced_signals = []
        self.remaining = []
        self.observations = []
        self.cleanup_errors = []

    def cancellation(self, _signal, _frame):
        self.cancelled = True

    def __enter__(self):
        self.previous_handlers = {sig: signal.signal(sig, self.cancellation)
                                  for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)}
        return self

    def launch(self, command, **kwargs):
        # Handlers are already non-raising; registration precedes all evidence or watcher work.
        process = subprocess.Popen(command, start_new_session=True, **kwargs)
        self.processes.append((process, Path(command[0]).resolve()))
        process.owned_identity = process_observation(process.pid)
        self.observations.append({"event": "launched", "argv": command, "identity": process.owned_identity})
        return process

    @staticmethod
    def members(process, executable, trace=None):
        expected = {"pid": process.pid, "uid": os.getuid(), "pgid": process.pid, "sid": process.pid,
                    "executable": str(executable), "application": str(APP.resolve())}
        result = []
        candidates = group_candidate_pids(process.pid)
        for pid in candidates:
            observed = process_observation(pid)
            if observed is None:
                if trace is not None: trace.append({"event": "candidate-retired", "pid": pid})
                continue
            original = getattr(process, "owned_identity", None)
            fingerprint_changed = pid == process.pid and original is not None and any(
                observed[key] != original[key] for key in ("startSec", "startUsec"))
            attestation = member_attestation(observed, process.pid, executable, APP.resolve(), set(candidates))
            allowed = attestation is not None
            if fingerprint_changed or observed["uid"] != os.getuid() or observed["sid"] != process.pid \
                    or observed["pgid"] != process.pid or not allowed:
                # Reobserve a stale snapshot before classifying it as a live unknown member.
                current = process_observation(pid)
                if current is None:
                    if trace is not None: trace.append({"event": "candidate-retired-on-recheck", "pid": pid})
                    continue
                raise ProcessIdentityError("live-group-member-mismatch", expected, {"first": observed, "rechecked": current})
            if trace is not None: trace.append({"event": "member-admitted", "identity": observed, "attestation": attestation})
            result.append(pid)
        if not result and trace is not None: trace.append({"event": "group-empty", "pgid": process.pid})
        return result

    def clean(self, process, executable):
        # A killed leader cannot reap its Chromium helpers. Give their disconnect handlers a
        # bounded chance to exit before classifying cleanup as forced. Attest on every sample;
        # a dead leader never licenses unknown members, and cancellation skips this grace.
        if process.poll() is not None and not self.cancelled:
            started = time.monotonic()
            deadline = started + self.child_exit_grace
            while self.members(process, executable, self.observations):
                if self.cancelled or time.monotonic() >= deadline:
                    break
                time.sleep(0.02)
            self.observations.append({"event": "child-exit-grace", "seconds": time.monotonic() - started})
        for sig, grace in ((signal.SIGTERM, self.term_grace), (signal.SIGKILL, self.kill_grace)):
            members = self.members(process, executable, self.observations)
            if not members:
                break
            try:
                os.killpg(process.pid, sig)
                self.forced_signals.append({"group": process.pid, "signal": sig.name})
            except ProcessLookupError:
                pass
            deadline = time.monotonic() + grace
            while time.monotonic() < deadline:
                try:
                    process.wait(timeout=min(0.05, max(0.001, deadline - time.monotonic())))
                    # A dead leader is not evidence that its helper group has ended.
                    if not self.members(process, executable, self.observations):
                        break
                    time.sleep(0.02)
                except subprocess.TimeoutExpired:
                    pass
                except KeyboardInterrupt:
                    self.cancelled = True
        self.remaining.extend(self.members(process, executable, self.observations))
        try:
            process.wait(timeout=0.1)
        except subprocess.TimeoutExpired:
            pass
        except KeyboardInterrupt:
            self.cancelled = True

    def __exit__(self, kind, value, traceback):
        if kind is KeyboardInterrupt:
            self.cancelled = True
        try:
            for index, (process, executable) in enumerate(self.processes):
                if index > 0 and not self.cancelled:
                    try:
                        process.wait(timeout=0.5)
                    except subprocess.TimeoutExpired:
                        pass
                    except KeyboardInterrupt:
                        self.cancelled = True
                # SIGTERM/SIGINT/SIGHUP only set a flag throughout cleanup.
                while True:
                    try:
                        self.clean(process, executable)
                        break
                    except KeyboardInterrupt:
                        self.cancelled = True
                    except Exception as error:
                        self.cleanup_errors.append(getattr(error, "evidence", {"reason": str(error)}))
                        break
            if self.cleanup_errors:
                raise RuntimeError("Owned process cleanup refused; see ownership.json")
            if self.remaining:
                raise RuntimeError("Owned process cleanup did not finish")
        finally:
            for sig, handler in self.previous_handlers.items():
                signal.signal(sig, handler)
        return kind is KeyboardInterrupt


def run_owned_host(command, watch_command, run_root, timeout, quit_timeout, after_launch=None):
    """Protect the host before constructing evidence or attempting to launch the witness."""
    started = time.monotonic()
    timed_out = quit_timed_out = False
    process = None
    owner = OwnedProcessRun()
    watcher = None
    primary_error = None
    try:
        with owner:
            with open(run_root / "stdout.log", "wb") as out, open(run_root / "stderr.log", "wb") as err:
                process = owner.launch(command, stdout=out, stderr=err, stdin=subprocess.DEVNULL,
                                       env={**os.environ, "MallocNanoZone": "0"})
                if after_launch:
                    after_launch(process)
                watcher = None
                if not owner.cancelled:
                    argv = watch_command(process)
                    owner.observations.append({"event": "witness-argv", "argv": argv})
                    with (run_root / "witness-stderr.log").open("wb") as witness_err, (run_root / "witness-stdout.log").open("wb") as witness_out:
                        watcher = owner.launch(argv, stdout=witness_out, stderr=witness_err)
                finished_at = None
                while not owner.cancelled and process.poll() is None:
                    if watcher is not None and watcher.poll() is not None:
                        raise RuntimeError("Window witness exited while the owned host was still running")
                    now = time.monotonic()
                    if finished_at is None and any(e.get("event") == "lab-finished" for e in lab_events(run_root)):
                        finished_at = now
                    if finished_at is not None and now - finished_at > quit_timeout:
                        quit_timed_out = True
                    elif now - started > timeout:
                        timed_out = True
                    if timed_out or quit_timed_out:
                        break
                    time.sleep(0.05)
    except BaseException as error:
        primary_error = {"type": type(error).__name__, "reason": str(error), "identity": getattr(error, "evidence", None),
                         "cause": str(error.__context__) if error.__context__ else None,
                         "causeIdentity": getattr(error.__context__, "evidence", None)}
        raise
    finally:
        record = {"primaryFailure": primary_error, "cleanupErrors": owner.cleanup_errors,
                  "observations": owner.observations, "witnessExit": watcher.poll() if watcher else None,
                  "hostExit": process.poll() if process else None, "forcedSignals": owner.forced_signals,
                  "remaining": owner.remaining}
        # Evidence failure must never replace an existing cleanup/launch failure.
        try:
            (run_root / "ownership.json").write_text(json.dumps(record, indent=2) + "\n")
        except OSError:
            if primary_error is None: raise
    return {"code": process.poll(), "timed_out": timed_out, "quit_timed_out": quit_timed_out,
            "cancelled": owner.cancelled, "forced_signals": owner.forced_signals,
            "remaining": owner.remaining}


def visible_input_evidence(results):
    """Admit observed DOM/native evidence, not scenario labels alone."""
    rows = {row["id"]: row for row in results}
    phases = [rows.get("visible.input." + name, {}) for name in ("preconditions", "composition", "commit")]
    if phases[1].get("nativeMarkedText") is not True or phases[2].get("nativeMarkedTextAfterCommit") is not False:
        return False
    if phases[0].get("externalWindowWitnessObserved") is not True:
        return False
    natives = [row.get("native", {}) for row in phases]
    doms = [row.get("dom", {}) for row in phases]
    keys = ("tabID", "windowID", "windowToken", "documentGeneration")
    owner = natives[0]
    if not all(isinstance(owner.get(key), int) and owner[key] > 0 for key in keys):
        return False
    for native, dom in zip(natives, doms):
        if any(native.get(key) != owner[key] for key in keys) or not all(native.get(key) is True for key in
                ("sameOwner", "hosted", "active", "keyWindow", "appActive", "firstResponderInHostView")):
            return False
        if dom.get("active") is not True or dom.get("focus") is not True:
            return False
    if [dom.get("value") for dom in doms] != ["", "か", "漢"]:
        return False
    composing = doms[1].get("events", [])
    committed = doms[2].get("events", [])
    types = {event.get("type") for event in composing if event.get("trusted") is True}
    if not {"compositionstart", "compositionupdate", "beforeinput", "input"}.issubset(types):
        return False
    if committed[:len(composing)] != composing:
        return False
    later = committed[len(composing):]
    if not any(event.get("type") == "compositionend" and event.get("trusted") is True for event in later):
        return False
    if not all(any(event.get("type") == kind and event.get("trusted") is True and event.get("value") == value
                   for event in events) for events, value in ((composing, "か"), (later, "漢")) for kind in ("input",)):
        return False
    if not any(event.get("type") == "beforeinput" and event.get("trusted") is True for event in later):
        return False
    return doms[2].get("start") == 1 and doms[2].get("end") == 1


def validate_run_mode(args):
    """Reject ambiguous modes before allocating a root, server or process."""
    visible = args.visible_input_only
    seconds = args.visible_input_seconds
    if seconds is not None and not visible:
        raise SystemExit("--visible-input-seconds requires --visible-input-only")
    seconds = 30 if seconds is None else seconds
    if not 15 <= seconds <= 60:
        raise SystemExit("Visible input duration must be between 15 and 60 seconds")
    if visible and (args.restore_of or args.async_hold):
        raise SystemExit("Visible input cannot restore a profile or use async holds")
    if visible and args.timeout < seconds + 15:
        raise SystemExit("Visible input timeout must allow its duration plus 15 seconds for shutdown")
    if getattr(args, "quit_stall_only", False) and (visible or args.restore_of or args.async_hold):
        raise SystemExit("--quit-stall-only runs alone")
    return seconds


def verdict(run_root, code, timed_out, quit_timed_out, after, watch_lines, mode="hidden"):
    """Automatic run verdict: hygiene (hidden, quit, processes) is blocking; scenario statuses are reported."""
    events = lab_events(run_root)
    stderr = (run_root / "stderr.log").read_text(errors="replace") if (run_root / "stderr.log").exists() else ""
    results_path = run_root / "results.json"
    results = json.loads(results_path.read_text())["results"] if results_path.exists() else []
    statuses = {entry["id"]: entry["status"] for entry in results}
    hidden = {key: value for key, value in statuses.items() if key.startswith("hidden.")}
    stall_events = [e for e in events if e.get("event") == "runtime-failure"
                    and str(e.get("detail", "")).startswith(("quit-stalled", "quit-forced"))]
    violation_events = [e for e in events if e.get("event") == "hidden-violation"]
    on_screen = [line for line in watch_lines if line.get("event") == "on-screen"]
    watch_summary = next((line for line in watch_lines if line.get("event") == "summary"), None)
    checks = {
        "exitCodeZero": code == 0,
        "noScenarioTimeout": not timed_out,
        "noQuitTimeout": not quit_timed_out,
        "noQuitStall": not stall_events and code != 75,
        "noLiveBrowserAtLoopEnd": code != 76,
        "messageLoopExitedWithoutBrowsers": "acr: message loop exited hosts=0 pending=0" in stderr,
        # Exit 2 without this line: Chromium's MacShutdownWatchdog (CefShutdown > 10 s).
        "cefShutdownReturned": "acr: CefShutdown returned" in stderr,
        "notAborted": code != 3 and "lab.aborted" not in statuses,
        "resultsWritten": bool(results),
        "hiddenMonitorPresent": statuses.get("hidden.monitor") == "proven",
        "hiddenAuditsAllProven": bool(hidden) and all(value == "proven" for value in hidden.values()),
        "noHiddenViolationEvents": not violation_events,
        "externalWitnessRan": bool(watch_summary) and watch_summary.get("samples", 0) > 0,
        "externalWitnessNoOnScreenWindow": not on_screen,
        "noProcessLeft": not after,
    }
    if mode == "visible-input":
        for key in ("hiddenMonitorPresent", "hiddenAuditsAllProven", "noHiddenViolationEvents", "externalWitnessNoOnScreenWindow"):
            checks.pop(key)
        document = json.loads(results_path.read_text()) if results_path.exists() else {}
        summary = watch_summary or {}
        checks.update({
            "visibleModeDeclared": document.get("auditMode") == "visible-input" and document.get("hiddenPassed") is False,
            "noHiddenResults": not hidden,
            "visibleInputScenariosProven": all(statuses.get(key) == "proven" for key in
                ("visible.input.creation", "visible.input.document", "visible.input.activation",
                 "visible.input.preconditions", "visible.input.composition", "visible.input.commit", "visible.input.audit",
                 "lifecycle.engine-shutdown")),
            "nativeInputEvidenceCorrelated": visible_input_evidence(results),
            "noFailedScenarios": not any(value == "failed" for value in statuses.values()),
            "externalWitnessSingleOwnedWindow": summary.get("mode") == "visible-input"
                and summary.get("maxVisibleWindows") == 1 and summary.get("onScreenSamples", 0) > 0
                and summary.get("unexpectedOnScreenSamples") == 0 and summary.get("signalledRoot") is False,
            "visibleDurationBoundRespected": summary.get("durationExceeded") is False,
        })
    elif mode == "quit-stall":
        # CHROMIUM-APP-R2 (review H3): a browser that never confirms its close. The bounded quit
        # must force the loop to end (status 77) and CefShutdown must still return, every process
        # gone, within the runner's quit bound.
        for key in ("exitCodeZero", "noQuitStall", "messageLoopExitedWithoutBrowsers"):
            checks.pop(key)
        forced = [e for e in stall_events if str(e.get("detail", "")).startswith("quit-forced")]
        checks.update({
            "exitCodeForcedQuit": code == 77,
            "quitForcedReported": bool(forced) and "acr: quit-forced" in stderr,
            "loopForcedWithLiveBrowser": "acr: message loop exited hosts=1 " in stderr,
            "quitStallArmed": statuses.get("lifecycle.quit-stall-armed") == "proven",
            "noHardExit": "acr: quit watchdog" not in stderr,
        })
    elif mode != "hidden":
        raise ValueError("Unknown laboratory audit mode")
    counts = {}
    for value in statuses.values():
        counts[value] = counts.get(value, 0) + 1
    return {
        "passed": all(checks.values()), "auditMode": mode,
        "hiddenPassed": mode == "hidden" and all(checks.values())
            and not any(value == "failed" for value in statuses.values()), "checks": checks, "scenarioCounts": counts,
        "failedScenarios": sorted(key for key, value in statuses.items() if value == "failed"),
        "quitStalls": len(stall_events), "hiddenViolationEvents": len(violation_events),
        "externalWitness": watch_summary or {}, "externalOnScreenSamples": len(on_screen),
        "pageClosedBrowserClosedByQuit": statuses.get("lifecycle.page-closed-browser-left-for-quit") == "proven"
            and code == 0 and not stall_events,
    }


def collect_owned_failure(pid, deadline):
    """Keep the fixture alive while collecting only the launched group's final state."""
    result = {"unresolvedGroupPIDs": [], "cancelled": False, "observationError": None}
    with OwnedProcessRun() as cancellation:
        try:
            while pid and not cancellation.cancelled and time.monotonic() < deadline:
                if not group_candidate_pids(pid):
                    break
                try:
                    time.sleep(0.1)
                except KeyboardInterrupt:
                    cancellation.cancelled = True
            result["unresolvedGroupPIDs"] = group_candidate_pids(pid) if pid else []
        except Exception as error:
            result["observationError"] = str(error)
        result["cancelled"] = cancellation.cancelled
    return result


def run_time_limits(args, visible_seconds):
    if args.visible_input_only:
        return min(args.timeout, visible_seconds + 25), min(args.quit_timeout, 10)
    return args.timeout, args.quit_timeout


def run(args):
    visible_seconds = validate_run_mode(args)
    visible = args.visible_input_only
    timeout, quit_timeout = run_time_limits(args, visible_seconds)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    restore_profile = None
    restore_port = 0
    if args.restore_of:
        # Relaunch on the earlier run's own synthetic root and profile identity only.
        run_root = LAB / "build/runs" / args.restore_of
        if (run_root / ".orbit-chromium-lab").read_text() != MARKER or (run_root / "restored").exists():
            raise SystemExit("restore source is not a fresh laboratory run")
        restore_profile = json.loads((run_root / "results.json").read_text())["profileA"]
        # Same origin (scheme, host and port) as the initial phase: localStorage is per origin.
        restore_port = int(json.loads((run_root / "results.json").read_text())["origin"].rsplit(":", 1)[1])
        (run_root / "restored").write_text(stamp)
        for name in ("results.json", "events.jsonl", "stdout.log", "stderr.log"):
            if (run_root / name).exists():
                (run_root / name).rename(run_root / ("initial-" + name))
        stamp = stamp + "-restore-of-" + args.restore_of
    else:
        run_root = LAB / "build/runs" / stamp
        run_root.mkdir(parents=True, mode=0o700)
        os.chmod(run_root, 0o700)
        (run_root / ".orbit-chromium-lab").write_text(MARKER)
        (run_root / "reports").mkdir(mode=0o700)
    counters = {}
    server = ThreadingHTTPServer(("127.0.0.1", restore_port), handler(run_root, counters))
    server.daemon_threads = True
    port = server.server_address[1]
    if port == 4318:
        raise SystemExit("reserved port")
    threading.Thread(target=server.serve_forever, daemon=True).start()
    origin = "http://127.0.0.1:%d" % port
    command = [str(HOST), "--lab-root=" + str(run_root), "--fixture-origin=" + origin, "--use-mock-keychain",
               # Synthetic capture devices only (never real camera/microphone, never auto-accept UI).
               "--use-fake-device-for-media-stream",
               # A lab bundle is never replaced while it runs: no code-signing clone, every
               # process keeps its attested path (member_attestation still admits the clone).
               "--disable-features=MacAppCodeSignClone"]
    if visible:
        command.extend(["--lab-visible-input-only", "--lab-visible-input-seconds=" + str(visible_seconds)])
    quit_stall = getattr(args, "quit_stall_only", False)
    if quit_stall:
        command.append("--lab-quit-stall-only")
    if not args.no_extension:
        command.append("--load-extension=" + str(EXTENSION))
    if args.async_hold:
        command.append("--lab-async-hold")
    if restore_profile:
        command.append("--lab-restore-profile=" + restore_profile)
    before = bundle_processes()
    if before:
        raise SystemExit("A laboratory bundle process is already running; refusing to start")
    started = time.monotonic()
    watch_log = run_root / "window-watch.jsonl"
    def live_identity(process):
        (run_root / "live-process.json").write_text(json.dumps({
            "pid": process.pid, "runnerPID": os.getpid(), "application": str(APP.resolve()),
            "executable": str(HOST.resolve()), "maximumSeconds": timeout,
            "observedAtLaunch": getattr(process, "owned_identity", None)}))

    def witness_command(process):
        result = [str(WATCH), str(process.pid), str(watch_log), "100",
                  "--owned-process", str(run_root / "live-process.json")]
        if visible:
            result.extend(["--visible-owned-window", str(run_root / "visible-window.json"), str(visible_seconds + 15)])
        return result

    runner_error = None
    try:
        owned = run_owned_host(command, witness_command, run_root, timeout, quit_timeout, live_identity)
    except Exception as error:
        runner_error = {"type": type(error).__name__, "reason": str(error)}
        # Keep the fixture available during a bounded failure collection window. No ownership
        # check is relaxed, and no signal is sent to an unknown live group.
        deadline = started + timeout + 5
        failed_live = json.loads((run_root / "live-process.json").read_text()) if (run_root / "live-process.json").exists() else {}
        failed_pid = failed_live.get("pid")
        collection = collect_owned_failure(failed_pid, deadline)
        ownership = json.loads((run_root / "ownership.json").read_text()) if (run_root / "ownership.json").exists() else {}
        unresolved = collection["unresolvedGroupPIDs"]
        ownership["unresolvedGroupPIDs"] = unresolved
        ownership["failureCollectionBoundSeconds"] = timeout + 5
        ownership["failureCollection"] = collection
        (run_root / "ownership.json").write_text(json.dumps(ownership, indent=2) + "\n")
        owned = {"code": ownership.get("hostExit", -1), "timed_out": False, "quit_timed_out": False,
                 "cancelled": False, "forced_signals": ownership.get("forcedSignals", []),
                 "remaining": unresolved}
    finally:
        (run_root / "fixture-final.json").write_text(json.dumps({"requests": counters, "runnerFailure": runner_error}))
        server.shutdown()
        server.server_close()
    code, timed_out, quit_timed_out = owned["code"], owned["timed_out"], owned["quit_timed_out"]
    duration = time.monotonic() - started
    # Cleanup is restricted to the launched sessions; a matching path alone never authorizes a kill.
    leftovers = owned["remaining"]
    after = bundle_processes()

    evidence = Path(args.evidence_root) / "artifacts/native-orbit-chromium" / stamp
    evidence.mkdir(parents=True, mode=0o700)
    watch_lines = []
    if watch_log.exists():
        for line in watch_log.read_text().splitlines():
            try:
                watch_lines.append(json.loads(line))
            except ValueError:
                pass
    audit_mode = "visible-input" if visible else "quit-stall" if quit_stall else "hidden"
    run_verdict = verdict(run_root, code, timed_out, quit_timed_out, after, watch_lines, mode=audit_mode)
    run_verdict["checks"]["noUnresolvedGroupMembers"] = not owned["remaining"]
    run_verdict["checks"]["runnerCompletedWithoutException"] = runner_error is None
    run_verdict["checks"]["runnerNotCancelled"] = not owned["cancelled"]
    run_verdict["checks"]["noForcedCleanupSignals"] = not owned["forced_signals"]
    run_verdict["passed"] = all(run_verdict["checks"].values())
    if not run_verdict["passed"]:
        run_verdict["hiddenPassed"] = False
    if owned["cancelled"]:
        run_verdict["checks"]["runnerNotCancelled"] = False
        run_verdict["passed"] = run_verdict["hiddenPassed"] = False
    for name in ("results.json", "events.jsonl", "stdout.log", "stderr.log", "window-watch.jsonl",
                 "snapshot-hidden-window.png", "snapshot-after-transfer.png", "visible-window.json", "visible-window-observed.json", "live-process.json", "ownership.json",
                 "witness-stderr.log", "witness-stdout.log", "fixture-final.json"):
        if (run_root / name).exists():
            shutil.copy2(run_root / name, evidence / name)
    if (run_root / "reports").is_dir() and any((run_root / "reports").iterdir()) \
            and not (evidence / "reports").exists():
        shutil.copytree(run_root / "reports", evidence / "reports")
    cache = run_root / "cache"
    profile_bytes = {}
    if cache.is_dir():
        for entry in sorted(cache.iterdir()):
            if entry.is_dir() and (entry.name.startswith("profile-") or entry.name == "default"):
                size = sum(f.stat().st_size for f in entry.rglob("*") if f.is_file() and not f.is_symlink())
                profile_bytes["default" if entry.name == "default" else "profile-%d" % len(profile_bytes)] = {
                    "bytes": size, "hasLocalStorage": (entry / "Local Storage").is_dir(),
                    "hasCookies": (entry / "Cookies").is_file(),
                    "hasLocalExtensionSettings": (entry / "Local Extension Settings").is_dir()}
    summary = {
        "auditMode": audit_mode, "visibleInputSeconds": visible_seconds if visible else None,
        "effectiveTimeout": timeout, "effectiveQuitTimeout": quit_timeout,
        "profileDirectories": profile_bytes,
        "stamp": stamp, "origin": origin, "command": [c.replace(str(REPO), "<worktree>") for c in command],
        "exitCode": code, "timedOut": timed_out, "quitTimedOut": quit_timed_out, "seconds": round(duration, 2),
        "verdict": run_verdict,
        "runnerFailure": runner_error, "runnerCancelled": owned["cancelled"], "forcedSignals": owned["forced_signals"],
        "leftoverProcessesKilled": 0, "unresolvedGroupPIDs": leftovers, "processesAfterCleanup": len(after),
        "fixtureRequests": counters,
        "hostSHA256": hashlib.sha256(HOST.read_bytes()).hexdigest(),
        "bridgeSHA256": hashlib.sha256((LAB / "Bridge/OrbitChromiumBridge.mm").read_bytes()).hexdigest(),
        "git": subprocess.run(["git", "-C", str(REPO), "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip(),
        "cacheRoot": "<worktree>/native/OrbitChromium/build/runs/" + stamp + "/cache (not copied)",
    }
    (evidence / "run.json").write_text(json.dumps(summary, indent=2, sort_keys=True))
    print(json.dumps(summary, indent=2, sort_keys=True))
    results = run_root / "results.json"
    if results.exists():
        for entry in json.loads(results.read_text())["results"]:
            print("%-44s %s" % (entry["id"], entry["status"]))
    print("verdict: %s" % ("PASSED" if run_verdict["passed"] else "FAILED"),
          json.dumps({k: v for k, v in run_verdict["checks"].items() if not v}))
    return 0 if run_verdict["passed"] else 1


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("build")
    runner = sub.add_parser("run")
    runner.add_argument("--visible-input-only", action="store_true")
    runner.add_argument("--visible-input-seconds", type=int)
    runner.add_argument("--quit-stall-only", action="store_true",
                        help="only a browser whose close never completes: the bounded quit must force the end (status 77)")
    runner.add_argument("--timeout", type=int, default=330)
    runner.add_argument("--quit-timeout", type=int, default=30,
                        help="seconds allowed between lab-finished and process exit")
    runner.add_argument("--no-extension", action="store_true")
    runner.add_argument("--async-hold", action="store_true")
    runner.add_argument("--restore-of", help="stamp of an earlier run to relaunch on its profile")
    runner.add_argument("--evidence-root", default=str(MAIN))
    args = parser.parse_args()
    if args.command == "build":
        build()
        return 0
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
