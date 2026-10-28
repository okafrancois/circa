#!/usr/bin/env python3
"""Compile exact production favicon functions against a bounded CEF-shaped fake.

No CEF, app, network or profiles are started. This models callback ownership and
synchronous receiver reentry, not Chromium's actual scheduler or shutdown.
"""
import pathlib
import subprocess
import sys

repo = pathlib.Path(__file__).resolve().parents[4]
source = (repo / 'native/OrbitChromium/Bridge/OrbitChromiumBridge.mm').read_text()
out = repo / 'native/OrbitChromium/build/review-favicon-r1/callback'
out.mkdir(parents=True, exist_ok=True)
callback = source[source.index('void StartFavicon(uint64_t token);'):source.index('class Client final')]
start = source.index('  void OnFaviconURLChange(')
end = source.index('  // ABI 9: element fullscreen.', start)
metadata = source[start:end].replace(' override', '')
harness = pathlib.Path(__file__).with_name('callback_fake.cc').read_text()
(out / 'actual_callback.inc').write_text(callback)
(out / 'actual_metadata.inc').write_text(metadata)
subprocess.run(['clang++', '-std=c++20', '-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-g',
    '-I' + str(out), '-I' + str(repo / 'native/OrbitChromium/Bridge'),
    '-o', str(out / 'callback-test'), '-x', 'c++', '-'], input=harness, text=True, check=True)
result = subprocess.run([str(out / 'callback-test'), *sys.argv[1:]], check=False)
raise SystemExit(result.returncode)
