#!/usr/bin/env python3
"""Rasterize the checked-in Orbit SVG at every native ICNS size on macOS."""
import importlib.util
from pathlib import Path
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BRANDING = ROOT / 'native/OrbitChromium/App/Branding'


def generate():
    # Reuse the existing lossless small-icon encoder and decoded pixel comparison.
    spec = importlib.util.spec_from_file_location('icon_codec', ROOT / 'scripts/orbit-app-icon.py')
    codec = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(codec)
    with tempfile.TemporaryDirectory(prefix='orbit-icon-') as temporary:
        work = Path(temporary)
        subprocess.run(['swift', ROOT / 'scripts/orbit-icon-raster.swift', BRANDING / 'Orbit.svg', work], check=True)
        chunks = []
        for kind, size in codec.REPRESENTATIONS:
            data = codec.encode_argb((work / f'{size}.rgba').read_bytes()) if kind in ('ic04', 'ic05') else (work / f'{size}.png').read_bytes()
            chunks.append(kind.encode() + struct.pack('>I', len(data) + 8) + data)
        payload = b''.join(chunks)
        icon = b'icns' + struct.pack('>I', len(payload) + 8) + payload
        codec.verify_roundtrip(icon, work)
        (BRANDING / 'Orbit.icns').write_bytes(icon)
        # A PNG is useful for reviewing the source independently from Finder's cache.
        (BRANDING / 'Orbit.png').write_bytes((work / '1024.png').read_bytes())


if __name__ == '__main__':
    generate()
