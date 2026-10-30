#!/usr/bin/env python3
"""Run real Apple Events against an explicitly confined, offscreen test bundle only."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import time

LSREGISTER = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'


def run_session(args):
    app = args.app.resolve(strict=True)
    root = args.root.resolve(strict=True)
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    identifier = info['CFBundleIdentifier']
    assert identifier == args.bundle_id and identifier.startswith('lab.orbit.'), 'Explicit test identity required'
    assert info.get('OrbitSyntheticBundle') and info.get('OrbitUseMockKeychain'), 'Synthetic bundle required'
    assert Path(info['OrbitDataRoot']).resolve() == root and (root / '.orbit-synthetic-root').is_file()
    assert not str(app).startswith(('/Applications/', str(Path.home() / 'Applications') + '/'))
    subprocess.run([LSREGISTER, '-f', str(app)], check=True, capture_output=True)
    process = None
    try:
        with (root / 'scripting-process.log').open('w') as output:
            process = subprocess.Popen([str(app / 'Contents/MacOS' / info['CFBundleExecutable']),
                                        '--ephemeral', '--scripting-test-offscreen'],
                                       stdout=output, stderr=output, start_new_session=True)
            time.sleep(3)
            assert process.poll() is None, 'Test bundle exited at startup'
            target = json.dumps(str(app))
            script = f'''tell application {target}
log "stage: list tabs"
set initialCount to count tabs of window 1
set listedURLs to URL of tabs of window 1
log "stage: make tab"
set createdTab to make new tab at end of tabs of window 1 with properties {{URL:"about:blank#created"}}
set createdID to id of createdTab
if (count tabs of window 1) is not initialCount + 1 then error "Create failed"
log "stage: set URL"
set URL of createdTab to "about:blank#changed"
if URL of createdTab is not "about:blank#changed" then error "Set URL failed"
log "stage: JavaScript gate"
try
    execute createdTab javascript "1+1"
    error "JavaScript unexpectedly allowed" number 999
on error messageText number errorNumber
    if errorNumber is not -1743 then error messageText number errorNumber
    if messageText does not contain "Allow JavaScript" then error "Automation permission denied; stop without interacting with TCC" number 998
end try
log "stage: close tab"
close createdTab
if (count tabs of window 1) is not initialCount then error "Close failed"
return "PASS: list, make, set URL, default JavaScript refusal, close"
end tell'''
            try:
                result = subprocess.run(['/usr/bin/osascript', '-'], input=script, text=True,
                                        capture_output=True, timeout=15)
            except subprocess.TimeoutExpired as error:
                if error.stderr:
                    print(error.stderr.decode() if isinstance(error.stderr, bytes) else error.stderr, file=sys.stderr)
                raise RuntimeError('Apple Events timed out; possible Automation TCC prompt. Stop without clicking it.')
            if result.returncode:
                raise RuntimeError(result.stderr.strip())
            print(result.stdout.strip())
            jxa = f'''const app = Application({target});
const windows = app.windows();
if (!windows.length || !windows[0].tabs().length) throw Error("JXA inventory failed");
JSON.stringify({{windows: windows.length, tabs: windows[0].tabs().length}});'''
            result = subprocess.run(['/usr/bin/osascript', '-l', 'JavaScript', '-'], input=jxa,
                                    text=True, capture_output=True, timeout=10, check=True)
            print('PASS: JXA ' + result.stdout.strip())
            print(json.dumps({'checks': 6, 'pid': process.pid, 'bundleID': identifier, 'offscreen': True}))
    finally:
        if process and process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
        subprocess.run(['/usr/bin/defaults', 'delete', identifier], capture_output=True)
        subprocess.run(['/usr/bin/tccutil', 'reset', 'AppleEvents', identifier], capture_output=True)
        subprocess.run([LSREGISTER, '-u', str(app)], capture_output=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--bundle-id', required=True)
    parser.add_argument('--locked-session', action='store_true', help=argparse.SUPPRESS)
    args = parser.parse_args()
    if not args.locked_session:
        return subprocess.run(['/usr/bin/lockf', '-k', '/tmp/orbit-gui-slot.lock', sys.executable,
                               str(Path(__file__).resolve()), *sys.argv[1:], '--locked-session'], timeout=59).returncode
    try:
        run_session(args)
    except (RuntimeError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
