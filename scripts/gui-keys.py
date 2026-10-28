#!/usr/bin/env python3
"""Send a shortcut by character using the current macOS input layout.

Example: gui-keys.py a --modifiers command --expect-front io.github.okatech.orbit.test.orbit
Product example: gui-keys.py t --expect-front <production-bundle-id> --allow-product
The expected frontmost bundle is checked in the same AppleScript before sending.
"""
import argparse
from product_identity import BUNDLE_ID
import subprocess
import re

MODIFIERS = {'command', 'shift', 'option', 'control'}


def send_shortcut(character, modifiers, expect_front, *, allow_product=False):
    if not re.fullmatch(r'[A-Za-z]', character):
        raise ValueError('Only ASCII letters are supported on the current keyboard layout')
    if not (re.fullmatch(r'io\.github\.okatech\.orbit\.test(?:\.[a-z0-9-]+)*', expect_front)
            or expect_front == 'io.github.okatech.orbit.test.orbit-chromium.app-smoke'
            or (allow_product and expect_front == BUNDLE_ID)):
        raise ValueError('Expected frontmost bundle must be an explicit laboratory test identifier or the product ID with --allow-product')
    if not modifiers or any(modifier not in MODIFIERS for modifier in modifiers):
        raise ValueError('Use command, shift, option or control modifiers')
    # Only validated modifier keywords enter the source; the character is a literal argv value.
    script = ('on run argv\n tell application "System Events"\n'
              '  set frontBundle to bundle identifier of first application process whose frontmost is true\n'
              '  considering case\n'
              '   if frontBundle is not (item 2 of argv) then error "Unexpected frontmost bundle; shortcut refused"\n'
              '  end considering\n'
              '  keystroke (item 1 of argv) using {' + ', '.join(m + ' down' for m in modifiers) + '}\n'
              ' end tell\nend run')
    subprocess.run(['/usr/bin/osascript', '-e', script, '--', character, expect_front], check=True, timeout=10)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('character')
    parser.add_argument('--modifiers', nargs='+', choices=sorted(MODIFIERS), default=['command'])
    parser.add_argument('--expect-front', required=True)
    parser.add_argument('--allow-product', action='store_true',
                        help='Allow the exact configured product bundle; still require it to be frontmost')
    args = parser.parse_args()
    send_shortcut(args.character, args.modifiers, args.expect_front, allow_product=args.allow_product)


if __name__ == '__main__':
    main()
