#!/usr/bin/env python3
"""Compile actual manager/availability bodies with a guard-page v3 ABI fixture; no runtime."""
from pathlib import Path
import subprocess
import sys
root = Path(__file__).resolve().parents[4]
out = root / 'native/OrbitChromium/build/extension-manager-v3'
out.mkdir(parents=True, exist_ok=True)
baseline = sys.argv[1:] == ['--baseline']
if sys.argv[1:] and not baseline:
    raise SystemExit('Usage: run.py [--baseline]')
source = (root / 'native/OrbitChromium/Bridge/OrbitChromiumBridge.mm').read_text()
if baseline:
    source = subprocess.check_output(['git', '-C', str(root), 'show',
        'c47cb8398bdacc45fd1cb0dbcb5f06006efc1eda:native/OrbitChromium/Bridge/OrbitChromiumBridge.mm'], text=True)
start = source.index('// ABI 10: native extension services.')
end = source.index('\nnamespace {\n// Retain the native anchor', start)
(out / 'actual.inc').write_text(source[start:end])
browse_start = source.index('    if (frame && frame->IsMain()) {', source.index('  bool OnBeforeBrowse('))
browse_end = source.index('    ACRNavigationInfo info', browse_start)
(out / 'browse.inc').write_text(source[browse_start:browse_end])
native_fixture = Path(__file__).with_name('fixture.mm').read_text()
if baseline:
    native_fixture = native_fixture[:native_fixture.index(' auto refuse =')] + '\n}\n'
(out / 'fixture.mm').write_text(native_fixture)
subprocess.run(['clang++', '-std=c++20', '-fobjc-arc', '-UNDEBUG', '-fsanitize=address,undefined',
    '-I' + str(root / 'native/OrbitChromium/Bridge'), '-I' + str(out),
    str(out / 'fixture.mm'), '-framework', 'AppKit', '-o', str(out / 'manager')], check=True)
if baseline:
    result = subprocess.run([str(out / 'manager')], capture_output=True, text=True)
    assert result.returncode != 0 and 'ACROpenExtensionManager(1)==1' in result.stderr, result
    print('EXPECTED RED c47cb839: actual manager body refuses admitted hosted v3')
    sys.exit(0)
subprocess.run([str(out / 'manager')], check=True)
engine = (root / 'native/OrbitChromium/ChromiumEngine/ChromiumBrowserEngine.swift').read_text()
start = engine.index('    private lazy var extensionManager')
end = engine.index('\n    public let persistence:', start)
properties = engine[start:end]
adapter = (root / 'native/OrbitChromium/ChromiumEngine/ChromiumExtensionHost.swift').read_text()
adapter = adapter[adapter.index('@MainActor\nfinal class ChromiumExtensionManagement:'):]
fixture = Path(__file__).with_name('adapter.swift').read_text().replace('/* PROPERTIES */', properties).replace('/* ADAPTER */', adapter)
(out / 'adapter.swift').write_text(fixture)
subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', str(out / 'adapter.swift'), '-o', str(out / 'adapter')], check=True)
subprocess.run([str(out / 'adapter')], check=True)
subprocess.run(['clang++', '-std=c++20', '-UNDEBUG', '-fsanitize=address,undefined',
    '-I' + str(root / 'native/OrbitChromium/Bridge'),
    str(root / 'native/OrbitChromium/Bridge/OrbitExtensionPolicyTests.cc'), '-o', str(out / 'route')], check=True)
subprocess.run([str(out / 'route')], check=True)
commands = (root / 'native/Sources/Orbit/Commands/BrowserDailyCommands.swift').read_text()
commands = '\n'.join(line for line in commands.splitlines() if not line.startswith('import '))
fixture = Path(__file__).with_name('commands.swift').read_text().replace('/* COMMANDS */', commands)
(out / 'commands.swift').write_text(fixture)
subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', str(out / 'commands.swift'), '-o', str(out / 'commands')], check=True)
subprocess.run([str(out / 'commands')], check=True)
