#!/usr/bin/env python3
"""Record the iCloud sync privacy switches in a confined synthetic bundle.

Build the product app as a synthetic bundle with the bundle id lab.orbit.orbit.sync-privacy and
`--synthetic-root <output>/data`, then:
  python3 scripts/orbit-sync-privacy-smoke.py --app <bundle> --output <output>
The bundle runs the local-only sync seam (ORBIT_SYNTHETIC_SYNC_SETTINGS=1: no CloudKit container).
Settings > General turns sync on (password sync stays off for a new setup), then password sync
on and off. The Settings window is recorded by window ID after its owner PID is verified.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('sync_privacy_validation', REPO / 'scripts/orbit-password-store-smoke.py')
validation = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(validation)
lab = validation.lab

VERIFY_WINDOW = ('import AppKit\nimport CoreGraphics\n'
                 'if CommandLine.arguments.count == 1 { exit((CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true ? 2 : 0) }\n'
                 'let pid = Int32(CommandLine.arguments[1])!\nlet id = UInt32(CommandLine.arguments[2])!\n'
                 'let entries = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]] ?? []\n'
                 'guard entries.contains(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowNumber as String] as? UInt32) == id }) else { exit(1) }\n')


def read_json(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def clip_phase(args):
    root = args.output.resolve()
    validation.validate_bundle(args.app, root)
    if subprocess.run([str(root / 'verify-window')], check=False).returncode != 0:
        raise RuntimeError('The GUI session is locked; no test bundle was launched')
    lab.APP = args.app.resolve()
    data = root / 'data'
    state, control = data / 'perf-state.json', data / 'perf-command.json'
    for name in ['perf-state.json', 'sync-privacy-window.txt']:
        (data / name).unlink(missing_ok=True)
    (root / 'sync-privacy.mov').unlink(missing_ok=True)

    def expired(*_):
        raise TimeoutError('Sync privacy GUI lease expired')
    signal.signal(signal.SIGALRM, expired)
    signal.alarm(55)
    started = time.monotonic()
    recording, checks = None, None
    environment = dict(os.environ, ORBIT_SYNTHETIC_SYNC_SETTINGS='1')
    with lab.OwnedProcessRun() as owner:
        with (root / 'clip-stdout.log').open('w') as out, (root / 'clip-stderr.log').open('w') as err:
            process = owner.launch([str(args.app / 'Contents/MacOS/Orbit'), '--use-mock-keychain', '--perf-probe',
                                    f'--orbit-data-root={data}', '-AppleLanguages', '(en)', '-AppleLocale', 'en_US'],
                                   stdout=out, stderr=err, stdin=subprocess.DEVNULL, env=environment)
            try:
                deadline = time.monotonic() + 14
                while True:
                    assert process.poll() is None, 'Synthetic process exited before readiness'
                    ready = read_json(state)
                    if ready.get('interactiveUptime') and ready.get('windowNumber') and ready.get('pid') == process.pid:
                        break
                    if time.monotonic() > deadline:
                        raise TimeoutError('Synthetic startup')
                    time.sleep(.05)
                window = int(ready['windowNumber'])
                subprocess.run([str(root / 'verify-window'), str(process.pid), str(window)], check=True)
                # PID-scoped Accessibility activation, after live window-owner validation.
                subprocess.run(['/usr/bin/osascript', '-e', 'tell application "System Events" to set frontmost of '
                                f'first application process whose unix id is {process.pid} to true'],
                               check=True, timeout=4, stdout=out, stderr=err)
                nonce = str(time.monotonic_ns())
                control.write_text(json.dumps({'command': 'sync-privacy', 'nonce': nonce}))
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline:
                    assert process.poll() is None
                    window_file = data / 'sync-privacy-window.txt'
                    if recording is None and window_file.exists():
                        settings = int(window_file.read_text())
                        subprocess.run([str(root / 'verify-window'), str(process.pid), str(settings)], check=True)
                        recording = subprocess.Popen(['/usr/sbin/screencapture', '-x', '-v', '-V', '11', '-l', str(settings),
                                                      str(root / 'sync-privacy.mov')], stdout=out, stderr=err)
                    result = read_json(state)
                    if result.get('commandNonce') == nonce and 'syncPrivacy' in result:
                        checks = result['syncPrivacy']
                        break
                    time.sleep(.05)
                else:
                    raise TimeoutError('Sync privacy flow')
                if recording is not None:
                    assert recording.wait(timeout=12) == 0, 'Window recording failed'
            finally:
                if recording is not None and recording.poll() is None:
                    recording.terminate()
                    recording.wait(timeout=3)
                control.write_text('{"command":"quit"}')
                process.wait(timeout=5)
    signal.alarm(0)
    report = {'result': checks, 'guiSeconds': time.monotonic() - started,
              'cleanShutdown': process.returncode == 0 and not owner.remaining and not owner.forced_signals}
    (root / 'clip-verification.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    assert checks and checks.get('passed') and report['cleanShutdown'], report


def encode_clip(root):
    source = root / 'sync-privacy.mov'
    if not source.exists():
        return
    clip, poster = root / 'sync-privacy.mp4', root / 'sync-privacy.jpg'
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', str(source), '-an', '-t', '15',
                    '-vf', "scale='min(1440,iw)':-2", '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-crf', '26',
                    '-preset', 'slow', '-movflags', '+faststart', str(clip)], check=True)
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-ss', '6', '-i', str(clip), '-frames:v', '1',
                    '-q:v', '3', str(poster)], check=True)
    print(f'clip {clip} ({clip.stat().st_size} bytes), poster {poster}')


def cleanup_registration(app):
    import plistlib
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    identifier = info['CFBundleIdentifier']
    if info.get('OrbitSyntheticBundle') is True and identifier.startswith('lab.orbit.orbit.'):
        for command in [['/usr/bin/tccutil', 'reset', 'All', identifier], ['/usr/bin/defaults', 'delete', identifier],
                        ['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister',
                         '-u', str(app)]]:
            subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True,
                        help='Bundle must be baked with --synthetic-root <output>/data')
    parser.add_argument('--phase', action='store_true')
    args = parser.parse_args()
    if args.phase:
        clip_phase(args)
        return
    root = args.output.resolve()
    validation.validate_bundle(args.app.resolve(), root)
    helper = root / 'verify-window.swift'
    helper.write_text(VERIFY_WINDOW)
    subprocess.run(['/usr/bin/swiftc', str(helper), '-o', str(root / 'verify-window')], check=True)
    try:
        subprocess.run(['/usr/bin/caffeinate', '-d', '-i', '/usr/bin/lockf', '-k', '/tmp/orbit-gui-slot.lock',
                        sys.executable, __file__, '--app', str(args.app.resolve()), '--output', str(root), '--phase'],
                       check=True)
        encode_clip(root)
    finally:
        cleanup_registration(args.app.resolve())


if __name__ == '__main__':
    main()
