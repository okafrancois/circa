#!/usr/bin/env python3
"""Build the exact approved detached-dot SVG into deterministic multi-size ICNS, offline.

Build-time tools only: Python standard library, Swift/CoreGraphics/ImageIO and Apple iconutil.
Packaging copies
committed bytes and does not import this generator or require an SVG rendering dependency.
"""
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'tools/orbit-brand/app-icon.svg'
OUTPUT = ROOT / 'native/OrbitChromium/App/Branding'
APPROVED = '592f9024697446674aa46648dd75f324f89faf94b0e6a9d6dfbc65ae1ebaf47b'
REPRESENTATIONS = [('ic04', 16), ('ic11', 32), ('ic05', 32), ('ic12', 64), ('ic07', 128),
                   ('ic13', 256), ('ic08', 256), ('ic14', 512), ('ic09', 512), ('ic10', 1024)]


def encode_argb(rgba):
    """ICNS ARGB planes use premultiplied channels and PackBits-style literals.

    Literal packets (1..128 bytes) deliberately avoid run selection heuristics so
    the small representations have a simple, deterministic lossless encoding.
    """
    encoded = bytearray(b'ARGB')
    for channel in (3, 0, 1, 2):
        plane = rgba[channel::4]
        for offset in range(0, len(plane), 128):
            packet = plane[offset:offset + 128]
            encoded.append(len(packet) - 1)
            encoded.extend(packet)
    return bytes(encoded)


def rasterize(work):
    spec = importlib.util.spec_from_file_location('orbit_vector', ROOT / 'scripts/orbit-vector-resources.py')
    vector = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(vector)
    pdf = vector.convert(SOURCE)
    (work / 'icon.pdf').write_bytes(pdf)
    subprocess.run(['swift', str(ROOT / 'scripts/orbit-icon-raster.swift'), str(work / 'icon.pdf'), str(work)], check=True)
    return pdf


def verify_roundtrip(icon, work):
    candidate = work / 'roundtrip.icns'
    candidate.write_bytes(icon)
    decoded = work / 'roundtrip.iconset'
    subprocess.run(['iconutil', '--convert', 'iconset', '--output', str(decoded), str(candidate)], check=True)
    expected = {f'icon_{size}x{size}{scale}.png'
                for size in (16, 32, 128, 256, 512) for scale in ('', '@2x')}
    assert {path.name for path in decoded.iterdir()} == expected, 'Unexpected decoded representations'
    subprocess.run(['swift', str(ROOT / 'scripts/orbit-icon-pixels.swift'), str(work), str(decoded)], check=True)


def generate():
    assert hashlib.sha256(SOURCE.read_bytes()).hexdigest() == APPROVED, 'Approved SVG changed'
    with tempfile.TemporaryDirectory(prefix='orbit-icon-') as temporary:
        work = Path(temporary)
        pdf = rasterize(work)
        chunks = []
        hashes = {}
        for kind, size in REPRESENTATIONS:
            png = (work / f'{size}.png').read_bytes()
            rgba = (work / f'{size}.rgba').read_bytes()
            # macOS interprets PNG in icp4/icp5 incorrectly at standard 16/32px.
            # Use native ARGB small entries; Retina and larger entries retain PNG.
            data = encode_argb(rgba) if kind in ('ic04', 'ic05') else png
            chunks.append(kind.encode() + struct.pack('>I', len(data) + 8) + data)
            hashes[kind] = {'pixels': size, 'png_sha256': hashlib.sha256(png).hexdigest(),
                            'payload_sha256': hashlib.sha256(data).hexdigest(),
                            'rgba_sha256': hashlib.sha256(rgba).hexdigest(),
                            'encoding': 'ARGB premultiplied, literal RLE planes' if kind in ('ic04', 'ic05') else 'PNG'}
        payload = b''.join(chunks)
        icon = b'icns' + struct.pack('>I', len(payload) + 8) + payload
        verify_roundtrip(icon, work)
    OUTPUT.mkdir(parents=True, exist_ok=True)
    (OUTPUT / 'Orbit.icns').write_bytes(icon)
    provenance = {'source': str(SOURCE.relative_to(ROOT)), 'source_sha256': APPROVED,
                  'pdf_sha256': hashlib.sha256(pdf).hexdigest(), 'icns_sha256': hashlib.sha256(icon).hexdigest(),
                  'representations': hashes, 'renderer': 'CoreGraphics sRGB RGBA8, direct PDF at each size; no fonts',
                  'geometry': 'Original SVG path/currentColor, rounded rect and circle; cubic circle approximation k=0.5522847498307936'}
    (OUTPUT / 'icon-provenance.json').write_text(json.dumps(provenance, indent=2, sort_keys=True) + '\n')


if __name__ == '__main__':
    generate()
