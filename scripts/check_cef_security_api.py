#!/usr/bin/env python3
"""Check the real framework's additive side-API table without starting CEF or a window."""
import argparse
import ctypes
import json
from pathlib import Path
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--framework', type=Path, required=True, help='Framework binary, not its directory')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    boundaries = ['move_tab', 'hold_window', 'extensions_snapshot', 'extension_action_snapshot',
                  'discard_tab', 'password_prompt_observe', 'boosts_replace', 'set_automatic_pip',
                  'popup_navigation_metadata', 'password_store_open', 'page_lifecycle', 'memory_dump',
                  'permission_accept_once', 'media_snapshot']
    header = REPO / 'native/OrbitChromium/Bridge/OrbitCefApi.h'
    with tempfile.TemporaryDirectory(prefix='orbit-security-abi-') as directory:
        root = Path(directory)
        source = root / 'layout.c'; executable = root / 'layout'
        expressions = ['offsetof(orbit_cef_api_t, ' + name + ')' for name in boundaries] + ['sizeof(orbit_cef_api_t)']
        source.write_text('#include <stddef.h>\n#include <stdio.h>\n#include "' + str(header) + '"\nint main(void) {\n' +
            '\n'.join('printf("%zu\\n", ' + expression + ');' for expression in expressions) + '\nreturn 0; }\n')
        subprocess.run(['clang', str(source), '-o', str(executable)], check=True)
        sizes = list(map(int, subprocess.check_output([str(executable)], text=True).splitlines()))
    class Prefix(ctypes.Structure):
        _fields_ = [('struct_size', ctypes.c_uint32), ('version', ctypes.c_uint32)]
    framework = ctypes.CDLL(str(args.framework.resolve()))
    get = framework.orbit_cef_get_api
    get.argtypes = [ctypes.c_uint32]; get.restype = ctypes.POINTER(Prefix)
    assert not get(0) and not get(16), 'Unsupported side API accepted'
    latest = get(15)
    assert latest and latest.contents.struct_size == sizes[-1]
    report = []
    for version, size in enumerate(sizes, 1):
        table = get(version)
        assert table and table.contents.version == version and table.contents.struct_size >= size, (version, size)
        assert ctypes.string_at(table, size)[8:] == ctypes.string_at(latest, size)[8:], version
        report.append({'version': version, 'size': table.contents.struct_size, 'requiredPrefix': size})
    args.output.write_text(json.dumps({'accepted': report, 'refused': [0, 16]}, indent=2) + '\n')
    print('ABI passed: v1-v15 accepted with preserved callable prefixes; v0/v16 refused')


if __name__ == '__main__':
    main()
