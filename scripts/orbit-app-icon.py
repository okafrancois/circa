#!/usr/bin/env python3
"""Synchronize the shipped default with the complete, approved application icon."""
from pathlib import Path
import shutil
import struct

ROOT = Path(__file__).resolve().parents[1]


def generate():
    source = ROOT / 'native/Sources/BrowserShell/AppIcons/stage.icns'
    data = source.read_bytes()
    if data[:4] != b'icns' or struct.unpack('>I', data[4:8])[0] != len(data):
        raise RuntimeError('Invalid default application icon')
    shutil.copyfile(source, ROOT / 'native/OrbitChromium/App/Branding/Orbit.icns')


if __name__ == '__main__':
    generate()
