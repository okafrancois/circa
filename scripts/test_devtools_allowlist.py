"""H-S7: the bridge's DevTools method allowlist matches the methods the Swift sources send.

Every `"Domain.method"` literal of a DevTools protocol domain in the shell and engine sources is
either a protocol event the shell observes or a method listed in OrbitBridgePolicy.h. Product
code (engine adapter and shell) may only use product methods; laboratory probes, smoke scenarios
and CMake tests may also use laboratory methods. Unused entries fail too, so the list stays exact.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parent.parent
NATIVE = ROOT / 'native'
POLICY = NATIVE / 'OrbitChromium' / 'Bridge' / 'OrbitBridgePolicy.h'
DOMAINS = {
    'Accessibility', 'Animation', 'Audits', 'Browser', 'CSS', 'CacheStorage', 'Cast', 'DOM', 'DOMDebugger',
    'DOMSnapshot', 'DOMStorage', 'Debugger', 'DeviceOrientation', 'Emulation', 'Fetch', 'HeapProfiler',
    'IO', 'IndexedDB', 'Input', 'Inspector', 'LayerTree', 'Log', 'Media', 'Memory', 'Network', 'Overlay',
    'Page', 'Performance', 'Preload', 'Profiler', 'Runtime', 'Security', 'ServiceWorker', 'Storage',
    'SystemInfo', 'Target', 'Tracing', 'WebAudio', 'WebAuthn',
}
# Protocol events the shell receives (never sent as methods).
EVENTS = {
    'Media.playerEventsAdded', 'Media.playerPropertiesChanged', 'Media.playersCreated',
    'Page.frameNavigated', 'Page.lifecycleEvent', 'Runtime.bindingCalled', 'Tracing.dataCollected',
    'WebAudio.audioNodeCreated', 'WebAudio.contextChanged', 'WebAudio.contextCreated',
    'WebAudio.contextWillBeDestroyed',
}
# The bridge-hardening probe sends these on purpose to check that they are refused.
REFUSAL_PROBE = 'OrbitBridgeHardeningProbe.swift'
INTENTIONALLY_REFUSED = {'Browser.close', 'Browser.grantPermissions', 'Network.setCookies', 'Target.createTarget'}
LITERAL = re.compile(r'"([A-Z][A-Za-z]*)\.([a-z][A-Za-z]*)"')
CHROMIUM = NATIVE / 'OrbitChromium'
# The app target ships product launch code next to synthetic probes: only its `*Probe.swift`
# files are laboratory code.
APP = CHROMIUM / 'App'
# Code that ships and runs in product mode, and laboratory-only code.
PRODUCT = [NATIVE / 'Sources', CHROMIUM / 'ChromiumEngine', APP]
LABORATORY = [APP, CHROMIUM / 'Smoke', CHROMIUM / 'Tests', CHROMIUM / 'Lab']
# Swift tools that never talk to the engine.
UNRELATED = [CHROMIUM / 'WindowWatch']


def listed(name):
    text = POLICY.read_text()
    block = re.search(r'%s\[\] = \{(.*?)\};' % name, text, re.S)
    return set(re.findall(r'"([^"]+)"', block.group(1)))


def swift_files(directories):
    laboratory = directories is LABORATORY
    for directory in directories:
        for path in directory.rglob('*.swift'):
            if '/.build' in str(path):
                continue
            if directory == APP and path.name.endswith('Probe.swift') != laboratory:
                continue
            yield path


def used(directories):
    found = {}
    for path in swift_files(directories):
        for domain, method in LITERAL.findall(path.read_text(errors='replace')):
            name = f'{domain}.{method}'
            if path.name == REFUSAL_PROBE and name in INTENTIONALLY_REFUSED:
                continue
            if domain in DOMAINS and name not in EVENTS:
                found.setdefault(name, set()).add(str(path.relative_to(ROOT)))
    return found


class DevToolsAllowlistTests(unittest.TestCase):
    def test_refusal_probe_methods_are_not_allowed(self):
        allowed = listed('kDevToolsProductMethods') | listed('kDevToolsLaboratoryMethods')
        self.assertFalse(INTENTIONALLY_REFUSED & allowed)

    def test_product_code_uses_only_product_methods(self):
        product = listed('kDevToolsProductMethods')
        stray = {name: sorted(paths) for name, paths in used(PRODUCT).items() if name not in product}
        self.assertEqual(stray, {})

    def test_laboratory_code_uses_only_listed_methods(self):
        allowed = listed('kDevToolsProductMethods') | listed('kDevToolsLaboratoryMethods')
        stray = {name: sorted(paths) for name, paths in used(LABORATORY).items() if name not in allowed}
        self.assertEqual(stray, {})

    def test_every_engine_swift_file_is_classified(self):
        classified = set(swift_files(PRODUCT)) | set(swift_files(LABORATORY))
        everything = {path for path in CHROMIUM.rglob('*.swift') if '/.build' not in str(path)}
        unrelated = {path for directory in UNRELATED for path in directory.rglob('*.swift')}
        stray = sorted(str(path.relative_to(ROOT)) for path in everything - classified - unrelated)
        self.assertEqual(stray, [])
        both = sorted(str(path.relative_to(ROOT)) for path in set(swift_files(PRODUCT)) & set(swift_files(LABORATORY)))
        self.assertEqual(both, [])

    def test_lists_are_exact(self):
        product, laboratory = listed('kDevToolsProductMethods'), listed('kDevToolsLaboratoryMethods')
        self.assertFalse(product & laboratory)
        product_used, laboratory_used = set(used(PRODUCT)), set(used(LABORATORY))
        # The bridge's own DevTools frontend call.
        product_used.add('Runtime.evaluate')
        self.assertEqual(product - product_used - laboratory_used, set(), 'unused product methods')
        self.assertEqual(laboratory - laboratory_used, set(), 'unused laboratory methods')
        self.assertEqual(laboratory & product_used, set(), 'product code needs a laboratory method')


if __name__ == '__main__':
    unittest.main()
