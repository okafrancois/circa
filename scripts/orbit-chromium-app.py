#!/usr/bin/env python3
"""CHROMIUM-APP: build the real Orbit application on Chromium and run its hidden smoke.

  build  configures native/OrbitChromium against a CEF flavor and builds, unsigned:
           native/OrbitChromium/build/app-<flavor>/product/Orbit.app   (product, for scripts/orbit-app.py)
           native/OrbitChromium/build/app-<flavor>/smoke/Orbit.app     (hidden smoke build, never installed)
           native/OrbitChromium/build/app-<flavor>/OrbitWindowWatch    (external witness)
  smoke  runs the smoke build hidden, phase after phase, on one synthetic data root:
           fresh (engine conformance, then the app scenarios, normal quit), restore (normal quit),
           crash (SIGKILL after the session save), restore-after-crash (normal quit).
           Fresh adds Chromium tabs to Favorites (selected, background, Peek opened as a tab);
           before each restore phase, Local State names the application's profile as last used,
           as a visible session leaves it (DBG-CH, docs/native-port/dbg-ch-2026-10-25.md).

Flavors are those of scripts/orbit-chromium-x2.py: `orbit` (patched CEF, hosted D-chrome tabs),
`stock` (our unpatched build) and `sdk` (the binary SDK of ENG-X1/X1-R2; Alloy surfaces).

Every run: synthetic marked root under native/OrbitChromium/build/runs, `--use-mock-keychain`, a
loopback fixture (the laboratory's), the laboratory's owned-process launcher and the out-of-process
CGWindowList witness, TERM/KILL with identity checks and a process audit. The laboratory modules
are imported, never modified. Evidence goes to <main>/artifacts/native-orbit-chromium-app/<stamp>-<flavor>/.
"""
import argparse
import base64
import importlib.util
import json
import math
import os
import re
import shutil
import ssl
import sqlite3
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from local_signing import SIGNING_DIRECTORY
from urllib.parse import urlsplit

REPO = Path(__file__).resolve().parent.parent
LAB_DIR = REPO / "native/OrbitChromium"
PHASES = ("fresh", "restore", "crash", "restore-after-crash", "refused-profile")


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


lab = load(REPO / "scripts/orbit-chromium-lab.py", "orbit_chromium_lab")
x2 = load(REPO / "scripts/orbit-chromium-x2.py", "orbit_chromium_x2")
EVIDENCE = x2.MAIN / "artifacts/native-orbit-chromium-app"
MOVE_EVENTS_EXTENSION = LAB_DIR / "Smoke/move-events-extension"


# CH-ESSENTIALS fixture pages (docs/native-port/ch-essentials-2026-10-25.md). Synthetic content and
# credentials only; element positions match the smoke's synthesized right clicks.
ESSENTIALS_USER = "orbit-synthetic-user"
ESSENTIALS_PASSWORD = "orbit-synthetic-password"
ESSENTIALS_PAGES = {
    "password-login": """<!doctype html><title>Login fixture</title>
<form method="post" action="/essentials/password-submit">
<label>Username<input id="username" name="username" autocomplete="username"></label>
<label>Password<input id="password" name="password" type="password" autocomplete="current-password"></label>
<button type="submit">Sign in</button></form>""",
    "password-generate": """<!doctype html><title>Registration fixture</title>
<form method="post" action="/essentials/password-submit">
<label>Username<input id="username" name="username" autocomplete="username"></label>
<label>Password<input id="password" name="password" type="password" autocomplete="new-password"></label>
<button type="submit">Register</button></form>""",
    "suspension": """<!doctype html><title>Synthetic session</title>
<body style="height:5000px">
<form method="POST" action="/essentials/suspension-post"><input id="check" name="choice" type="checkbox"><input name="token" value="synthetic"></form>
<p>Native session history fixture.</p></body>""",
    "dialogs": """<!doctype html><title>essentials-dialogs</title>
<body style="margin:0;font:16px -apple-system">
<a id="link" href="/essentials/linked" style="position:absolute;left:20px;top:20px">Linked page</a>
<input id="field" value="orbit" style="position:absolute;left:20px;top:80px;width:200px;height:24px">
<a id="mail" href="mailto:orbit@example.invalid" style="position:absolute;left:20px;top:130px">Mail</a>
<a id="tel" href="tel:+15550100" style="position:absolute;left:120px;top:130px">Call</a>
<input id="files" type="file" multiple accept="image/*,.txt" style="position:absolute;left:20px;top:170px">
<input id="folder" type="file" webkitdirectory style="position:absolute;left:20px;top:210px">
<div id="box" style="position:absolute;left:20px;top:260px;width:200px;height:100px;background:#0a7"></div>
</body>""",
    "beforeunload": """<!doctype html><title>essentials-beforeunload</title>
<input id="field" value="">
<script>addEventListener('beforeunload', (event) => { event.preventDefault(); event.returnValue = ''; });</script>""",
    "linked": "<!doctype html><title>essentials-linked</title><p>Linked synthetic page.</p>",
    "secure": "<!doctype html><title>essentials-secure</title><p>Synthetic TLS page.</p>",
}


def essentials_handler(run_root, counters):
    """The laboratory fixture plus /essentials/ pages: dialogs, beforeunload, Basic auth (two realms)."""
    base = lab.handler(run_root, counters)
    expected = "Basic " + base64.b64encode((ESSENTIALS_USER + ":" + ESSENTIALS_PASSWORD).encode()).decode()

    class Essentials(base):
        def do_POST(self):
            if urlsplit(self.path).path == "/essentials/password-submit":
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= 4096: return self.reply(413)
                self.rfile.read(length)  # Synthetic credentials are never logged or echoed.
                return self.reply(200, b'<!doctype html><title>Signed in</title><p>Fixture submission accepted.</p>')
            if urlsplit(self.path).path != "/essentials/suspension-post":
                return super().do_POST()
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 1024: return self.reply(413)
            self.rfile.read(length)
            counters["suspension-post"] = counters.get("suspension-post", 0) + 1
            return self.reply(200, b'<!doctype html><title>Synthetic POST</title><p>Posted once.</p>')

        def do_GET(self):
            path = urlsplit(self.path).path
            if path.startswith("/boosts/"):
                counters[path] = counters.get(path, 0) + 1
                port = self.server.server_port
                if path == "/boosts/probe.js":
                    body = (LAB_DIR / "Smoke/boosts-fixture/probe.js").read_bytes()
                    return self.reply(200, body, "application/javascript")
                if path == "/boosts/middle":
                    body = ('<!doctype html><iframe src="http://localhost:%d/boosts/child"></iframe>' % port).encode()
                else:
                    body = ('<!doctype html><title>Boost fixture</title><div id="zap">Hidden by registration</div><p>Document start fixture</p><script src="/boosts/probe.js"></script>' + ('<iframe src="/boosts/middle"></iframe>' if path == "/boosts/main" else '')).encode()
                return self.reply(200, body, extra=[("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'none'; frame-src http://127.0.0.1:%d http://localhost:%d; require-trusted-types-for 'script'" % (port, port))])
            if path == "/essentials/daily-pending":
                time.sleep(2)
                return self.reply(200, lab.page("daily-pending"))
            if path == "/essentials/suspension-post-count":
                return self.reply(200, str(counters.get("suspension-post", 0)).encode(), "text/plain")
            if not path.startswith("/essentials/"):
                return super().do_GET()
            counters[path] = counters.get(path, 0) + 1
            name = path[len("/essentials/"):]
            if name in ("auth", "auth-cancel"):
                # The cancel case expects other credentials: Chrome resends the cached ones of
                # /essentials/auth preemptively for the same directory.
                wanted = expected if name == "auth" else expected + "-never"
                if self.headers.get("Authorization") == wanted:
                    return self.reply(200, b"<!doctype html><title>essentials-auth-ok</title><p>Signed in.</p>")
                realm = "Orbit Lab" if name == "auth" else "Orbit Lab Cancel"
                return self.reply(401, b"<!doctype html><title>essentials-auth-required</title><p>401</p>",
                                  extra=[("WWW-Authenticate", 'Basic realm="%s"' % realm)])
            page = ESSENTIALS_PAGES.get(name)
            return self.reply(200, page.encode()) if page else self.reply(404)

    return Essentials


class SecureFixture(BaseHTTPRequestHandler):
    """Self-signed loopback HTTPS: Chrome must show its certificate interstitial."""

    def log_message(self, *_):
        pass

    def do_GET(self):
        body = ESSENTIALS_PAGES["secure"].encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def start_tls_fixture(run):
    """A self-signed certificate for 127.0.0.1 in the run root (never trusted), served on a free port."""
    key, cert = run / "tls-key.pem", run / "tls-cert.pem"
    subprocess.run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                    "-subj", "/CN=127.0.0.1", "-addext", "subjectAltName=IP:127.0.0.1",
                    "-keyout", str(key), "-out", str(cert)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    os.chmod(key, 0o600)
    server = ThreadingHTTPServer(("127.0.0.1", 0), SecureFixture)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(str(cert), str(key))
    server.socket = context.wrap_socket(server.socket, server_side=True)
    server.daemon_threads = True
    if server.server_address[1] in (4317, 4318, 4330):
        raise SystemExit("Refusing a reserved port")
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, "https://127.0.0.1:%d" % server.server_address[1]
def stable_signing_root():
    """SHA-1 of the stable local signing certificate (public metadata of scripts/local_signing.py),
    built into the product admission (CHROMIUM-APP-R3); empty when this machine has no identity,
    and then the product build refuses product mode. Never reads the key or its password."""
    metadata = SIGNING_DIRECTORY / "identity.json"
    try:
        fingerprint = json.loads(metadata.read_text()).get("fingerprint", "")
    except (OSError, ValueError):
        return ""
    return fingerprint if len(fingerprint) == 40 and all(c in "0123456789ABCDEF" for c in fingerprint) else ""


def build_dir(flavor):
    return LAB_DIR / ("build/app-" + flavor)


def build(args):
    from sparkle_setup import ensure_sparkle
    sparkle = ensure_sparkle(json.loads((REPO / 'release/config.json').read_text()))
    root, wrapper, expected, _ = x2.flavor_paths(args.flavor)
    wrapper_hash = expected or x2.sha256(wrapper)
    source_pins = []
    if args.flavor == "sdk":
        framework_hash = "9c81eb633abb7c1ebd5058f939061b4ece215d8f56e053114dac7073204800e8"
    else:
        manifest = json.loads((x2.distribution_dir(args.flavor) / "manifest.json").read_text())
        framework_hash = manifest["framework_sha256"]
        if wrapper_hash != manifest["wrapper_sha256"]:
            raise SystemExit("Distribution wrapper differs from its manifest")
        header = root / "include/cef_version.h"
        commits = re.findall(r'^#define CEF_COMMIT_HASH "([0-9a-f]{40})"$', header.read_text(), re.MULTILINE)
        if len(commits) != 1:
            raise SystemExit("Distribution must export exactly one CEF version commit")
        source_pins = ["-DCEF_SOURCE_COMMIT=" + commits[0],
                       "-DCEF_VERSION_HEADER_SHA256=" + x2.sha256(header)]
    build = build_dir(args.flavor)
    subprocess.run(["cmake", "-S", str(LAB_DIR), "-B", str(build), "-G", "Ninja", "-DCMAKE_BUILD_TYPE=Release",
                    "-DCEF_ROOT=" + str(root), "-DCEF_WRAPPER_LIBRARY=" + str(wrapper),
                    "-DCEF_WRAPPER_SHA256=" + wrapper_hash, "-DCEF_FRAMEWORK_SHA256=" + framework_hash,
                    "-DORBIT_STABLE_SIGNING_ROOT=" + stable_signing_root(), "-DSPARKLE_ROOT=" + str(sparkle), *source_pins],
                   check=True, stdout=subprocess.DEVNULL)
    subprocess.run(["nice", "-n", "10", "cmake", "--build", str(build), "--target",
                    "package_orbit_app", "package_orbit_app_smoke", "OrbitWindowWatch"], check=True)
    # The synthetic smoke bundle is signed ad hoc like the laboratory's (an unsigned bundle runs
    # from a system code-signing clone, outside its attested path). The product stays unsigned:
    # scripts/orbit-app.py signs it with the stable identity.
    smoke_app = build / "smoke/Orbit.app"
    subprocess.run(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(smoke_app)], check=True,
                   stderr=subprocess.DEVNULL)
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(smoke_app)], check=True)
    for variant in ("product", "smoke"):
        app = build / variant / "Orbit.app"
        print(json.dumps({"variant": variant, "app": str(app), "executable": str(app / "Contents/MacOS/Orbit"),
                          "framework": str(app / "Contents/Frameworks/Chromium Embedded Framework.framework"),
                          "frameworkSHA256": framework_hash, "flavor": args.flavor, "signed": False}))
    return 0


def mark(directory):
    directory.mkdir(parents=True, mode=0o700)
    os.chmod(directory, 0o700)
    (directory / ".orbit-chromium-lab").write_text(lab.MARKER)


def watch_lines(path):
    if not path.exists():
        return []
    lines = []
    for line in path.read_text(errors="replace").splitlines():
        try:
            lines.append(json.loads(line))
        except ValueError:
            pass
    return lines


def reap_bundle_processes():
    """Last resort after a refused cleanup: TERM, then KILL, only processes whose kernel executable
    path is inside this build's smoke bundle (never another bundle or an unknown process).
    Returns the reaped pids; a run that needed it has failed."""
    application = str(lab.APP.resolve()) + "/"
    def owned():
        output = subprocess.run(["/bin/ps", "-axo", "pid="], capture_output=True, text=True, check=True).stdout
        pids = []
        for line in output.split():
            try:
                observation = lab.process_observation(int(line))
            except Exception:
                continue
            if observation and observation["uid"] == os.getuid() and (observation.get("path") or "").startswith(application):
                pids.append(observation["pid"])
        return pids
    reaped = owned()
    for signal_number, grace in ((15, 3.0), (9, 2.0)):
        for pid in owned():
            try:
                os.kill(pid, signal_number)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + grace
        while owned() and time.monotonic() < deadline:
            time.sleep(0.1)
    return reaped


def seed_last_used_profile(data):
    """DAILY-1 P1 (restore SIGTRAP): Chrome records the profile of the last activated Browser as
    Local State's `profile.last_used`, and without `--profile-directory` that profile becomes the
    initial one, CEF's global context, at the next launch. A hidden run never activates a window,
    so the restore phases write what a visible session leaves: the application's own profile
    (named in the session file) as last used and last active. Returns the record for the verdict."""
    local_state = data / "Chromium" / "Local State"
    session = (data / "session.json").read_text().lower() if (data / "session.json").exists() else ""
    candidates = sorted(p.name for p in (data / "Chromium").glob("profile-*")
                        if p.is_dir() and not p.is_symlink() and p.name[len("profile-"):] in session)
    if not local_state.is_file() or local_state.is_symlink() or not candidates:
        return {"seeded": False, "candidates": len(candidates)}
    state = json.loads(local_state.read_text())
    profile = state.setdefault("profile", {})
    profile["last_used"] = candidates[0]
    profile["last_active_profiles"] = [candidates[0]]
    local_state.write_text(json.dumps(state))
    return {"seeded": True, "candidates": len(candidates)}


def refusal_error(error):
    """Structured diagnostics; a cleanup/evidence exception must not replace the body error."""
    cause = error.__context__
    return {"type": type(error).__name__, "reason": str(error),
            "identity": getattr(error, "evidence", None),
            "causeType": type(cause).__name__ if cause else None,
            "causeReason": str(cause) if cause else None,
            "causeIdentity": getattr(cause, "evidence", None)}


def refusal_launch(data, run, origin, timeout=30):
    """CHROMIUM-APP-R3 (review MEDIUM 7): a single-dash bypass of the pinned initial profile refuses
    the run in the bridge, before CEF starts (exit 64 and the bridge's own message), on the same
    synthetic root; nothing is left running."""
    root = run / "refusal"
    mark(root)
    (root / "reports").mkdir(mode=0o700)
    command = [str(lab.HOST), "--use-mock-keychain", "--orbit-data-root=" + str(data),
               "--orbit-smoke-run=" + str(root), "--orbit-smoke-fixture=" + origin, "--orbit-smoke-phase=fresh",
               "-ignore-profile-directory-if-not-exists"]
    started = time.monotonic()
    owner = lab.OwnedProcessRun()
    process = None
    timed_out = False
    failure = None
    primary_exception = None
    primary_failure = cleanup_failure = None
    observation_errors, evidence_errors = [], []
    try:
        if not 0 < timeout <= 30:
            raise ValueError("Refusal timeout must be within (0, 30] seconds")
        # No witness or browser instrumentation: admission must refuse before CEF starts.
        # The same attested ownership helper protects launch, wait, cancellation and cleanup.
        with owner:
            with (root / "stdout.log").open("wb") as out, (root / "stderr.log").open("wb") as err:
                try:
                    process = owner.launch(command, stdin=subprocess.DEVNULL, stdout=out, stderr=err,
                                           env={**os.environ, "MallocNanoZone": "0"})
                    while not owner.cancelled and process.poll() is None:
                        remaining = timeout - (time.monotonic() - started)
                        if remaining <= 0:
                            timed_out = True
                            break
                        try:
                            process.wait(timeout=min(0.05, remaining))
                        except subprocess.TimeoutExpired:
                            pass
                except BaseException as error:
                    # Capture inside the owner and file contexts, before either exit can raise.
                    primary_exception = error
                    primary_failure = refusal_error(error)
                    raise
    except BaseException as error:
        failure = refusal_error(error)
        if owner.cleanup_errors:
            cleanup_failure = failure
        elif primary_exception is None:
            primary_failure = failure
        elif error is not primary_exception:
            evidence_errors.append({"operation": "stream-close", **failure})
    # KeyboardInterrupt may be suppressed by the existing cancellation-safe owner.
    if failure is None:
        failure = primary_failure
    # launch() registers before taking its first identity sample: an exception there still
    # belongs to this owner and must not lose its wait/reap and cleanup evidence.
    if process is None and owner.processes:
        process = owner.processes[0][0]

    def observe(operation, action, fallback):
        try:
            return action()
        except Exception as error:
            observation_errors.append({"operation": operation, **refusal_error(error)})
            return fallback

    code = observe("host-exit", lambda: process.poll() if process else None, None)
    stderr_path = root / "stderr.log"
    stderr = observe("stderr-read", lambda: stderr_path.read_text(errors="replace") if stderr_path.exists() else "", "")
    ownership = {"primaryFailure": primary_failure, "cleanupFailure": cleanup_failure,
                 "failure": failure, "cleanupErrors": owner.cleanup_errors,
                 "observationErrors": observation_errors, "evidenceErrors": evidence_errors,
                 "observations": owner.observations, "hostExit": code,
                 "forcedSignals": owner.forced_signals, "remaining": owner.remaining,
                 "cancelled": owner.cancelled}
    clean = not (failure or primary_failure or timed_out or owner.cancelled or owner.cleanup_errors
                 or owner.remaining or owner.forced_signals or observation_errors or evidence_errors)
    unknown_membership = bool(owner.cleanup_errors or any(error["operation"] == "host-exit" for error in observation_errors))
    record = {"exitCode": code, "seconds": round(time.monotonic() - started, 2),
              "processesLeft": None if unknown_membership else len(owner.remaining),
              "cleanupComplete": not owner.cleanup_errors and not owner.remaining and (process is None or code is not None),
              "timedOut": timed_out, "cancelled": owner.cancelled,
              "failure": failure, "primaryFailure": primary_failure, "cleanupFailure": cleanup_failure,
              "cleanupErrors": owner.cleanup_errors, "forcedSignals": owner.forced_signals,
              "observationErrors": observation_errors, "evidenceErrors": evidence_errors,
              "bridgeRefused": "acr: refused a command-line option" in stderr,
              "passed": code == 64 and clean and "acr: refused a command-line option" in stderr,
              "stderrTail": stderr[-300:]}
    for name, document in (("ownership.json", ownership), ("verdict.json", record)):
        try:
            (root / name).write_text(json.dumps(document, indent=2) + "\n")
        except Exception as error:
            # Return the complete in-memory verdict to smoke even if neither file is writable.
            detail = {"operation": "write-" + name, **refusal_error(error)}
            evidence_errors.append(detail)
            record["passed"] = False
            if record["failure"] is None:
                record["failure"] = detail
    return record


def refuse_profiles(data):
    """CHROMIUM-APP-R2: replace every synthetic profile directory by a regular file (moved aside
    inside the data root), which the bridge's CanonicalChild refuses. Returns the count."""
    moved = data / "moved-profiles"
    moved.mkdir(mode=0o700, exist_ok=True)
    count = 0
    for directory in sorted((data / "Chromium").glob("profile-*")):
        if directory.is_dir() and not directory.is_symlink():
            directory.rename(moved / directory.name)
            directory.write_text("synthetic refused profile\n")
            os.chmod(directory, 0o600)
            count += 1
    return count


def application_checks(document, events, require_extension, require_quit):
    """Product gates beyond the laboratory's process/visibility hygiene verdict."""
    statuses = {item["id"]: item["status"] for item in document.get("results", [])}
    checks = {"applicationScenariosNoFailures": bool(statuses)
              and not any(status == "failed" for status in statuses.values())}
    if require_extension:
        checks["extensionProbes19Of19"] = statuses.get("extensions.mv3-probes") == "proven"
    quit_seconds = None
    if require_quit:
        began = next((event.get("t") for event in events if event.get("event") == "lab-finished"), None)
        ended = next((event.get("t") for event in events if event.get("event") == "runtime-shutdown"), None)
        if isinstance(began, (int, float)) and isinstance(ended, (int, float)):
            elapsed = ended - began
            if math.isfinite(elapsed) and elapsed >= 0:
                quit_seconds = elapsed
        checks["gracefulQuitUnderFiveSeconds"] = quit_seconds is not None and quit_seconds < 5
    return checks, quit_seconds


def resource_snapshot():
    return {"observedAt": datetime.now(timezone.utc).isoformat(),
            "loadAverage": list(os.getloadavg()), "logicalCPUs": os.cpu_count()}


def run_phase(phase, run, data, origin, args, tls_origin=None):
    """One owned, witnessed, hidden launch of the smoke build. Returns its verdict record."""
    root = run / phase
    mark(root)
    (root / "reports").mkdir(mode=0o700)
    seeded = seed_last_used_profile(data) if phase.startswith("restore") else None
    refused = refuse_profiles(data) if phase == "refused-profile" else None
    command = [str(lab.HOST), "--use-mock-keychain", "--orbit-data-root=" + str(data),
               "--orbit-smoke-run=" + str(root), "--orbit-smoke-fixture=" + origin,
               "--orbit-smoke-phase=" + ("restore" if phase.startswith("restore") else phase),
               # Synthetic capture devices only, as in the laboratory.
               "--use-fake-device-for-media-stream"]
    if tls_origin and phase == "fresh":
        command.append("--orbit-smoke-tls-fixture=" + tls_origin)
    if getattr(args, "boosts_only", False):
        command += ["--orbit-smoke-boosts", "--load-extension=" + str((LAB_DIR / "Smoke/boosts-extension").resolve())]
    if getattr(args, "passwords_only", False):
        command.append("--orbit-smoke-passwords")
    if getattr(args, "engine_r5_only", False):
        command.append("--orbit-smoke-engine-r5")
        command.append("--orbit-smoke-resource-tabs=" + str(args.resource_tabs))
    if getattr(args, "engine_r4_only", False):
        command.append("--orbit-smoke-engine-r4")
    if args.extension_only:
        command.append("--orbit-smoke-extension-only")
    if getattr(args, "private_domain_only", False):
        command.append("--orbit-smoke-private-domain")
    if getattr(args, "profiles_only", False):
        command.append("--orbit-smoke-profiles")
    if getattr(args, "daily_qa", None):
        command.append("--orbit-smoke-daily-qa=" + args.daily_qa)
    if getattr(args, "relaunch_only", False):
        command.append("--orbit-smoke-relaunch")
    if getattr(args, "archive_auto_only", False):
        command.append("--orbit-smoke-archive-auto")
    if getattr(args, "space_profile_only", False):
        command.append("--orbit-smoke-space-profile")
    command.append("--orbit-smoke-extension-timeout=" + str(getattr(args, "extension_timeout", 25)))
    if phase == "restore-after-crash":
        command.append("--orbit-smoke-expect-crash-tab")
    escaped = run / "escaped-disk-cache"
    if phase == "fresh":
        # CHROMIUM-APP-R3 (review HIGH 1 / MEDIUM 7): hostile switches on the process command line
        # must never reach Chromium: no cache outside the root, no variations fetch, no metrics.
        command += ["--disk-cache-dir=" + str(escaped), "-disk-cache-dir=" + str(escaped),
                    "--variations-server-url=" + origin + "/variations", "-force-enable-metrics-reporting",
                    "--crash-dumps-dir=" + str(escaped)]
    if not args.no_extension:
        # The EngineGate MV3 probes, and the tab move event recorder (CHROMIUM-APP-R2).
        extensions = [str(lab.EXTENSION)]
        if getattr(args, "engine_r4_only", False):
            extensions.append(str(LAB_DIR / "Smoke/runtime-state-extension"))
        if not args.extension_only:
            extensions.append(str(MOVE_EVENTS_EXTENSION))
        command.append("--load-extension=" + ",".join(extensions))
    timeout = args.timeout

    # The witness and the cleanup attest Chromium's start-up `/usr/bin/profiles` helper and its
    # code-signing clone themselves (orbit-chromium-lab.py `member_attestation`): no pre-wait.
    def live_identity(process):
        (root / "live-process.json").write_text(json.dumps({
            "pid": process.pid, "runnerPID": os.getpid(), "application": str(lab.APP.resolve()),
            "executable": str(lab.HOST.resolve()), "maximumSeconds": timeout,
            "observedAtLaunch": process.owned_identity}))
        os.chmod(root / "live-process.json", 0o600)

    def witness(process):
        return [str(build_dir(args.flavor) / "OrbitWindowWatch"), str(process.pid), str(root / "window-watch.jsonl"),
                "100", "--owned-process", str(root / "live-process.json")]

    resources_before = resource_snapshot()
    error = None
    owned = {"code": None, "timed_out": False, "quit_timed_out": False, "cancelled": False,
             "forced_signals": [], "remaining": []}
    try:
        owned = lab.run_owned_host(command, witness, root, timeout, args.quit_timeout, live_identity)
    except Exception as failure:  # The ownership record keeps the details.
        error = {"type": type(failure).__name__, "reason": str(failure)}
    after = lab.bundle_processes()
    reaped = reap_bundle_processes() if after else []
    lines = watch_lines(root / "window-watch.jsonl")
    verdict = lab.verdict(root, owned["code"], owned["timed_out"], owned["quit_timed_out"], after, lines, "hidden")
    checks = verdict["checks"]
    if getattr(args, "boosts_only", False):
        checks["boostWorldNetworkBlocked"] = args.fixture_counters.get("/boosts/forbidden", 0) == 0
    if getattr(args, "passwords_only", False) and phase == "fresh":
        # Read only after normal engine teardown. Never emit credential values.
        rows = []
        for database in data.rglob("Login Data"):
            connection = sqlite3.connect("file:" + str(database) + "?mode=ro", uri=True)
            try:
                rows += connection.execute("SELECT username_value, blacklisted_by_user, length(password_value) FROM logins").fetchall()
            finally:
                connection.close()
        checks["passwordSavedEncrypted"] = any(u == "fixture-save" and b == 0 and n > 3 for u, b, n in rows)
        checks["passwordNotNowDiscarded"] = not any(u in ("fixture-decline", "fixture-pending") for u, _, _ in rows)
        checks["passwordNeverBlocked"] = any(b == 1 for _, b, _ in rows)
    checks.update(noUnresolvedGroupMembers=not owned["remaining"], runnerCompletedWithoutException=error is None,
                  runnerNotCancelled=not owned["cancelled"], noForcedCleanupSignals=not owned["forced_signals"])
    checks["noReapNeeded"] = not reaped
    verdict["reapedPids"] = reaped
    events = lab.lab_events(root)
    if phase == "crash":
        # The smoke kills itself after its save: no quit, no CefShutdown, by design.
        for key in ("exitCodeZero", "messageLoopExitedWithoutBrowsers", "cefShutdownReturned", "noQuitTimeout"):
            checks.pop(key)
        checks["killedBySIGKILL"] = owned["code"] == -9
        checks["crashKillReached"] = any(e.get("event") == "crash-kill" for e in events)
    else:
        checks["terminationRoutedThroughDelegate"] = any(e.get("event") == "will-terminate" for e in events)
        checks["sessionFileWritten"] = (data / "session.json").exists()
    if phase == "fresh":
        checks["hostileSwitchesIgnored"] = not escaped.exists() and not any(
            path.startswith("/variations") for path in getattr(args, "fixture_counters", {}))
    if refused is not None:
        checks["profilesReplacedByFiles"] = refused > 0
        verdict["refusedProfiles"] = refused
    if seeded is not None:
        checks["lastUsedProfileSeeded"] = seeded["seeded"]
        verdict["lastUsedProfile"] = seeded
    results = json.loads((root / "results.json").read_text()) if (root / "results.json").exists() else {}
    product_checks, quit_seconds = application_checks(
        results, events, require_extension=phase == "fresh" and not args.no_extension,
        require_quit=phase != "crash")
    checks.update(product_checks)
    if getattr(args, "daily_qa", None) == "downloads":
        checks["downloadStagingCleaned"] = not any(root.glob(".orbit-download-*"))
        checks["downloadQuitAcceptedWhileActive"] = any(
            event.get("event") == "result" and event.get("id") == "daily.download-quit-accepted"
            for event in events)
    if getattr(args, "private_domain_only", False):
        statuses = {entry["id"]: entry["status"] for entry in results.get("results", [])}
        required = ("normal-ready", "same-origin-isolated", "memory-services", "no-profile-directory",
                    "last-owner-release", "fresh-context", "normal-survives", "no-session-sentinel")
        checks["privateDomainAllResultsProven"] = all(statuses.get("private." + item) == "proven" for item in required)
    verdict["resources"] = {"before": resources_before, "after": resource_snapshot()}
    verdict["quitSeconds"] = quit_seconds
    verdict["passed"] = all(checks.values())
    verdict["hiddenPassed"] = verdict["passed"]
    verdict["phase"] = phase
    verdict["runnerError"] = error
    verdict["scenarios"] = {entry["id"]: entry["status"] for entry in results.get("results", [])}
    (root / "verdict.json").write_text(json.dumps(verdict, indent=2, sort_keys=True) + "\n")
    return verdict


def smoke(args):
    build = build_dir(args.flavor)
    lab.APP = build / "smoke/Orbit.app"        # members()/bundle_processes(): helpers under this bundle
    lab.HOST = lab.APP / "Contents/MacOS/Orbit"
    if not lab.HOST.exists() or not (build / "OrbitWindowWatch").exists():
        raise SystemExit("Build the %s smoke first: scripts/orbit-chromium-app.py build --flavor %s" % (args.flavor, args.flavor))
    if lab.bundle_processes():
        raise SystemExit("An Orbit smoke bundle of this build is already running")
    if not 30 <= args.timeout <= 360:
        raise SystemExit("--timeout must be 30..360 seconds (witness bound)")
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    run = LAB_DIR / "build/runs" / (stamp + "-orbit-app")
    mark(run)
    data = run / "data"
    counters = {}
    server = ThreadingHTTPServer(("127.0.0.1", 0), essentials_handler(run / "fresh", counters))
    server.daemon_threads = True
    if server.server_address[1] in (4317, 4318, 4330):
        raise SystemExit("Refusing a reserved port")
    origin = "http://127.0.0.1:%d" % server.server_address[1]
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()
    tls_server, tls_origin = None, None
    verdicts = []
    args.fixture_counters = counters
    refusal = {"passed": False, "failure": {"type": "PreflightNotCompleted"}}
    try:
        try:
            refusal = refusal_launch(data, run, origin)
        except Exception as error:
            # Evidence/file errors in the preflight also stop the lane before any next phase.
            refusal = {"passed": False, "failure": {"type": type(error).__name__, "reason": str(error)}}
        if refusal.get("passed") is True:
            if not args.extension_only:
                tls_server, tls_origin = start_tls_fixture(run)
            for phase in PHASES[: 1 if args.fresh_only else 2 if args.relaunch_only else len(PHASES)]:
                # Extension reports land in the current phase directory.
                server.RequestHandlerClass = essentials_handler(run / phase, counters)
                verdicts.append(run_phase(phase, run, data, origin, args, tls_origin))
                if not verdicts[-1]["passed"] and not args.keep_going:
                    break
    finally:
        server.shutdown()
        server.server_close()
        server_thread.join(timeout=2)
        if tls_server is not None:
            tls_server.shutdown()
            tls_server.server_close()
    left = lab.bundle_processes()
    fixture_stopped = not server_thread.is_alive()
    summary = {"flavor": args.flavor, "stamp": stamp, "phases": [
        {"phase": v["phase"], "passed": v["passed"], "failedChecks": sorted(k for k, ok in v["checks"].items() if not ok),
         "scenarios": v["scenarios"]} for v in verdicts],
        "allPhasesPassed": len(verdicts) == (1 if args.fresh_only else 2 if args.relaunch_only else len(PHASES)) and all(v["passed"] for v in verdicts)
            and refusal.get("passed") is True and fixture_stopped,
        "fixtureThreadStopped": fixture_stopped,
        "argumentRefusal": refusal, "processesLeft": len(left), "fixtureRequests": counters}
    (run / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    export(run, stamp, args.flavor)
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["allPhasesPassed"] and not left else 1


def export(run, stamp, flavor):
    """Copies the evidence without the data root (synthetic profiles, caches, session)."""
    destination = EVIDENCE / (stamp + "-" + flavor)
    destination.mkdir(parents=True)
    shutil.copy2(run / "summary.json", destination / "summary.json")
    for phase_root in sorted(p for p in run.iterdir() if p.is_dir() and p.name in PHASES + ("refusal",)):
        target = destination / phase_root.name
        target.mkdir()
        for name in ("verdict.json", "results.json", "events.jsonl", "window-watch.jsonl", "ownership.json",
                     "stderr.log", "witness-stderr.log", "archive-session.json",
                     "runtime-page.png", "boost-applied.png", "native-save.html"):
            if (phase_root / name).exists():
                shutil.copy2(phase_root / name, target / name)
        reports = phase_root / "reports"
        if reports.is_dir() and any(reports.iterdir()):
            shutil.copytree(reports, target / "reports")
    print("evidence:", destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    builder = sub.add_parser("build")
    builder.add_argument("--flavor", choices=x2.FLAVORS, default="orbit-engine-extensions-r12")
    runner = sub.add_parser("smoke")
    runner.add_argument("--flavor", choices=x2.FLAVORS, default="orbit-engine-extensions-r12")
    runner.add_argument("--evidence-root", type=Path, default=EVIDENCE)
    runner.add_argument("--timeout", type=int, default=180)
    runner.add_argument("--quit-timeout", type=int, default=30)
    runner.add_argument("--no-extension", action="store_true")
    runner.add_argument("--fresh-only", action="store_true")
    runner.add_argument("--keep-going", action="store_true")
    runner.add_argument("--boosts-only", action="store_true", help="Hermetic document registration probes")
    runner.add_argument("--passwords-only", action="store_true", help="Hermetic native password controller probes")
    runner.add_argument("--engine-r5-only", action="store_true", help="Hermetic native discard/history/POST scenarios")
    runner.add_argument("--resource-tabs", type=int, choices=(0, 20, 50, 100), default=0)
    runner.add_argument("--engine-r4-only", action="store_true",
                        help="Hermetic native action/audio/color/save API scenarios")
    runner.add_argument("--extension-only", action="store_true",
                        help="Fresh real-shell MV3 and normal quit gate, without unrelated scenarios")
    runner.add_argument("--private-domain-only", action="store_true",
                        help="Hidden mock-only private domain coexistence/release probe on approved EssentialsR2")
    runner.add_argument("--daily-qa", choices=("overlays", "downloads", "archive"), help="Synthetic daily ownership, download quit and archive undo probes")
    runner.add_argument("--relaunch-only", action="store_true", help="Regular windows and Little across normal quit and relaunch")
    runner.add_argument("--profiles-only", action="store_true",
                        help="Two persistent product profiles across normal and crash relaunches, without extensions")
    runner.add_argument("--archive-auto-only", action="store_true",
                        help="Synthetic accelerated-clock archiving on real Chromium surfaces")
    runner.add_argument("--space-profile-only", action="store_true",
                        help="Synthetic Space profile move hook and real Chromium cookie isolation, without UI")
    runner.add_argument("--extension-timeout", type=int, default=25,
                        help="Bounded wait for an extension report (25..180 seconds; does not alter probe deadlines)")
    args = parser.parse_args()
    if args.command == "smoke" and args.daily_qa:
        if any((args.relaunch_only, args.boosts_only, args.passwords_only, args.engine_r5_only,
                args.engine_r4_only, args.extension_only, args.private_domain_only, args.profiles_only,
                args.archive_auto_only, args.space_profile_only)):
            parser.error("--daily-qa excludes other focused probes")
        args.no_extension = True
        args.fresh_only = True
    if args.command == "smoke" and args.relaunch_only:
        if any((args.fresh_only, args.boosts_only, args.passwords_only, args.engine_r5_only,
                args.engine_r4_only, args.extension_only, args.private_domain_only, args.profiles_only,
                args.archive_auto_only, args.space_profile_only)):
            parser.error("--relaunch-only excludes other focused probes")
        args.no_extension = True
    if args.command == "smoke" and args.archive_auto_only:
        if args.extension_only or args.private_domain_only or args.profiles_only or args.space_profile_only:
            parser.error("--archive-auto-only excludes other focused probes")
        args.no_extension = True
    if args.command == "smoke" and args.boosts_only:
        args.no_extension = True
        args.fresh_only = True
    if args.command == "smoke" and args.passwords_only:
        args.no_extension = True
        args.fresh_only = True
    if args.command == "smoke" and args.engine_r5_only:
        args.no_extension = True
        args.fresh_only = True
    if args.command == "smoke" and args.engine_r4_only:
        args.extension_only = True
        args.fresh_only = True
    if args.command == "smoke" and args.space_profile_only:
        if args.extension_only or args.private_domain_only or args.profiles_only:
            parser.error("--space-profile-only excludes other focused probes")
        args.no_extension = True
        args.fresh_only = True
    if args.command == "smoke" and args.profiles_only:
        if args.extension_only or args.private_domain_only:
            parser.error("--profiles-only excludes extension and private-domain probes")
        args.no_extension = True
    if args.command == "smoke" and args.private_domain_only:
        if args.flavor not in ("orbit-essentials-r2", "orbit-engine-extensions", "orbit-engine-extensions-r2",
                               "orbit-engine-extensions-r3", "orbit-engine-extensions-r4", "orbit-engine-extensions-r5", "orbit-engine-extensions-r6", "orbit-engine-extensions-r7", "orbit-engine-extensions-r8", "orbit-engine-extensions-r9", "orbit-engine-extensions-r10", "orbit-engine-extensions-r11", "orbit-engine-extensions-r12") or args.extension_only:
            parser.error("--private-domain-only requires a product engine and excludes --extension-only")
        args.no_extension = True
        args.fresh_only = True
    if args.command == "smoke" and not 25 <= args.extension_timeout <= 180:
        parser.error("--extension-timeout must be 25..180 seconds")
    if args.command == "smoke" and args.extension_only:
        if args.no_extension:
            parser.error("--extension-only requires the extension")
        args.fresh_only = True
    if args.command == "smoke":
        globals()["EVIDENCE"] = args.evidence_root
    return build(args) if args.command == "build" else smoke(args)


if __name__ == "__main__":
    sys.exit(main())
