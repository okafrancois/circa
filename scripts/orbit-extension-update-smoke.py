#!/usr/bin/env python3
"""Real-engine startup/manual update smoke. No CEF build and no Web Store access.

Requires the packaged synthetic *smoke* app, built with orbit-chromium-app.py then
orbit-app.py build --synthetic --source-app <build>/smoke/Orbit.app.
Each app session holds the shared GUI slot for at most 55 seconds.
"""
import argparse
import base64
import hashlib
import hmac
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit
import zipfile

REPO = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("orbit_update_lab", REPO / "scripts/orbit-chromium-lab.py")
lab = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lab)


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def varint(value):
    result = bytearray()
    while value > 127:
        result.append((value & 127) | 128)
        value >>= 7
    return bytes(result + bytes([value]))


def field(number, value):
    return varint((number << 3) | 2) + varint(len(value)) + value


def fixtures(root, origin):
    """CRX3 developer proof, matching components/crx_file/crx3.proto. Ephemeral key only."""
    key = root / "fixture-key.pem"
    subprocess.run(["/usr/bin/openssl", "genrsa", "-out", str(key), "2048"], check=True, capture_output=True)
    key.chmod(0o600)
    public = subprocess.run(["/usr/bin/openssl", "pkey", "-in", str(key), "-pubout", "-outform", "DER"],
                            check=True, capture_output=True).stdout
    digest = hashlib.sha256(public).digest()[:16]
    extension_id = "".join(chr(97 + int(n, 16)) for n in digest.hex())
    manifests = {}
    try:
        for version in (1, 2):
            manifest = {"manifest_version": 3, "name": "Orbit Update Fixture", "version": f"{version}.0",
                        "key": base64.b64encode(public).decode(), "update_url": origin + "/update.xml"}
            manifests[version] = manifest
            directory = root / f"v{version}"
            directory.mkdir()
            write_json(directory / "manifest.json", manifest)
            archive = io.BytesIO()
            with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as zipped:
                zipped.writestr("manifest.json", json.dumps(manifest))
            signed = field(1, digest)
            payload = b"CRX3 SignedData\0" + struct.pack("<I", len(signed)) + signed + archive.getvalue()
            signature = subprocess.run(["/usr/bin/openssl", "dgst", "-sha256", "-sign", str(key)],
                                       input=payload, check=True, capture_output=True).stdout
            header = field(2, field(1, public) + field(2, signature)) + field(10000, signed)
            (root / f"v{version}.crx").write_bytes(b"Cr24" + struct.pack("<II", 3, len(header)) + header + archive.getvalue())
    finally:
        key.unlink(missing_ok=True)
    return extension_id, manifests


class FixtureServer(ThreadingHTTPServer):
    daemon_threads = True


def handler(root, state):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def reply(self, code, body=b"", content_type="text/html"):
            self.send_response(code)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def event(self, kind):
            # Only loopback fixture data or blocked public service hosts; no real profile.
            with (root / "server.jsonl").open("a") as output:
                output.write(json.dumps({"time": time.time(), "phase": state["phase"], "kind": kind,
                                         "method": self.command, "path": self.path}) + "\n")

        def do_CONNECT(self):
            self.event("blocked-proxy")
            self.reply(403)

        def do_POST(self):
            if self.path != "/offer2":
                return self.do_CONNECT()
            state["offer"] = 2
            self.event("offer-v2")
            self.reply(200)

        def do_GET(self):
            parsed = urlsplit(self.path)
            if parsed.scheme or self.headers.get("Host") != state["host"]:
                return self.do_CONNECT()
            self.event("fixture")
            if parsed.path == "/update.xml":
                version = state["offer"]
                body = (f'<?xml version="1.0"?><gupdate xmlns="http://www.google.com/update2/response" protocol="2.0">'
                        f'<app appid="{state["id"]}"><updatecheck codebase="{state["origin"]}/v{version}.crx" '
                        f'version="{version}.0" /></app></gupdate>').encode()
                return self.reply(200, body, "application/xml")
            if parsed.path in ("/v1.crx", "/v2.crx"):
                return self.reply(200, (root / parsed.path[1:]).read_bytes(), "application/x-chrome-extension")
            self.reply(200, b"<!doctype html><title>Orbit update fixture</title><p>Synthetic loopback fixture.</p>")
    return Handler


def phase(args):
    root = args.output.resolve()
    directory = root / args.phase
    directory.mkdir()
    (directory / ".orbit-chromium-lab").write_text(lab.MARKER)
    origin = f"http://127.0.0.1:{args.port}"
    command = [str(args.app / "Contents/MacOS/Orbit"), "--use-mock-keychain", f"--orbit-data-root={root}/data",
               f"--orbit-smoke-run={directory}", f"--orbit-smoke-fixture={origin}", "--orbit-smoke-phase=fresh",
               "--orbit-smoke-extension-only", "--orbit-smoke-extension-update"]
    if args.phase == "seed":
        command.append("--orbit-smoke-extension-update-seed")
    elif args.phase == "baseline":
        command.append("--orbit-smoke-extension-update-baseline")
    else:
        command.append(f"--orbit-test-extension-updates={args.port}")
    if args.phase == "manual":
        command.append("--orbit-smoke-extension-update-manual")
    with lab.OwnedProcessRun() as owner:
        with (directory / "stdout.log").open("w") as out, (directory / "stderr.log").open("w") as err:
            process = owner.launch(command, stdout=out, stderr=err, stdin=subprocess.DEVNULL)
            try:
                process.wait(timeout=50)
            except subprocess.TimeoutExpired:
                pass  # Identity-checked bounded cleanup in OwnedProcessRun.__exit__.
    write_json(directory / "ownership.json", {"observations": owner.observations, "remaining": owner.remaining,
                                              "forcedSignals": owner.forced_signals})
    results = json.loads((directory / "results.json").read_text())
    assert process.returncode == 0, process.returncode
    assert not results["aborted"] and not owner.remaining and not owner.forced_signals
    assert all(item["status"] != "failed" for item in results["results"]), results
    if args.phase not in ("seed", "baseline"):
        assert any(item["id"] == "update.loaded-v2" and item["status"] == "proven" for item in results["results"])
    print(f"{args.phase}: PASS", flush=True)


def seed(root, extension_id, manifest, profile_id, name):
    profile = root / "data/Chromium" / ("profile-" + profile_id)
    preferences = profile / "Secure Preferences"
    values = json.loads(preferences.read_text())
    # Restore only our fixture's installed state while the app is stopped; no unpacked loader.
    extensions = profile / "Extensions" / extension_id
    if extensions.exists():
        shutil.rmtree(extensions)
    destination = extensions / "1.0_0"
    destination.mkdir(parents=True)
    write_json(destination / "manifest.json", manifest)
    values.setdefault("extensions", {}).setdefault("settings", {})[extension_id] = {
        "state": 1, "disable_reasons": [], "location": 1, "path": str(destination), "manifest": manifest,
        "from_webstore": False, "was_installed_by_default": False, "was_installed_by_oem": False,
        "creation_flags": 0, "active_permissions": {"api": [], "explicit_host": [], "scriptable_host": []}}
    # Chromium's unbranded build uses an empty HMAC seed and the platform UUID salt.
    # Read that salt only in memory, never print/store it or read any personal profile.
    # Match services/preferences/tracked/pref_hash_calculator.cc's canonicalization.
    platform = plistlib.loads(subprocess.run(["/usr/sbin/ioreg", "-rd1", "-c", "IOPlatformExpertDevice", "-a"],
                                            check=True, capture_output=True).stdout)
    device = platform[0]["IOPlatformUUID"]
    def canonical(value):
        if isinstance(value, dict):
            return {key: item for key, entry in value.items() if (item := canonical(entry)) not in ({}, [])}
        if isinstance(value, list):
            return [item for entry in value if (item := canonical(entry)) not in ({}, [])]
        return value
    def mac(path, value):
        text = json.dumps(canonical(value), sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        return hmac.new(b"", (device + path + text).encode(), hashlib.sha256).hexdigest().upper()
    protection = values.setdefault("protection", {})
    macs = protection.setdefault("macs", {})
    # Use Chromium's supported legacy-hash migration for this offline synthetic seed.
    # The next launch regenerates the encrypted authenticators with the mock keychain.
    macs.setdefault("extensions", {}).pop("settings_encrypted_hash", None)
    protection.pop("super_encrypted_hash", None)
    macs.setdefault("extensions", {}).setdefault("settings", {})[extension_id] = mac(
        "extensions.settings." + extension_id, values["extensions"]["settings"][extension_id])
    protection["super_mac"] = mac("", macs)
    write_json(preferences, values)
    write_json(root / f"{name}-before.json", {"id": extension_id, "version": "1.0", "location": "internal",
                                             "profile": profile_id, "update_url": manifest["update_url"]})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=Path("/tmp/ext-update-verify/run"))
    parser.add_argument("--phase", choices=("seed", "baseline", "startup", "manual"), help=argparse.SUPPRESS)
    parser.add_argument("--port", type=int, help=argparse.SUPPRESS)
    args = parser.parse_args()
    args.app = args.app.resolve()
    info = plistlib.loads((args.app / "Contents/Info.plist").read_bytes())
    assert info.get("OrbitSyntheticBundle") and info.get("OrbitUseMockKeychain")
    if args.phase:
        return phase(args)
    root = args.output.resolve()
    assert str(root).startswith("/private/tmp/") and not root.exists(), "Use a fresh /tmp output directory"
    root.mkdir(parents=True, mode=0o700)
    (root / ".orbit-chromium-lab").write_text(lab.MARKER)
    state = {"phase": "seed", "offer": 1}
    server = FixtureServer(("127.0.0.1", 0), handler(root, state))
    port = server.server_address[1]
    state["host"] = f"127.0.0.1:{port}"
    state["origin"] = "http://" + state["host"]
    state["id"], manifests = fixtures(root, state["origin"])
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        for name in ("seed", "baseline", "startup", "manual"):
            state["phase"], state["offer"] = name, 2 if name == "startup" else 1
            if name in ("baseline", "manual"):
                seed(root, state["id"], manifests[1], profile_id, name)
            subprocess.run(["/usr/bin/lockf", "-k", "/tmp/orbit-gui-slot.lock", sys.executable, str(Path(__file__).resolve()),
                            "--app", str(args.app), "--output", str(root), "--phase", name, "--port", str(port)], check=True)
            if name == "seed":
                results = json.loads((root / "seed/results.json").read_text())
                profile_id = next(item["evidence"]["id"] for item in results["results"] if item["id"] == "update.profile")
        requests = [json.loads(line) for line in (root / "server.jsonl").read_text().splitlines()]
        for name in ("startup", "manual"):
            entries = [item for item in requests if item["phase"] == name]
            if name == "manual":
                offer = next(item["time"] for item in entries if item["kind"] == "offer-v2")
                entries = [item for item in entries if item["time"] >= offer]
            assert any(item["path"].startswith("/update.xml?") and "%3D1.0" in item["path"] for item in entries)
            assert any(item["path"] == "/v2.crx" for item in entries)
        write_json(root / "summary.json", {"status": "partial-periodic-unverified", "startup": "1.0 -> 2.0", "manual": "1.0 -> 2.0",
                   "periodic": "Blocked: Chromium 156 hard-codes five hours with +/-20% jitter; no interval switch/policy",
                   "extensionID": state["id"], "externalTraffic": "rejecting loopback proxy and fail-closed DNS"})
    finally:
        server.shutdown()
        server.server_close()
        lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        for command in ([lsregister, "-u", str(args.app)], ["/usr/bin/defaults", "delete", info["CFBundleIdentifier"]],
                        ["/usr/bin/tccutil", "reset", "All", info["CFBundleIdentifier"]]):
            subprocess.run(command, capture_output=True)


if __name__ == "__main__":
    main()
