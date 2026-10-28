#!/usr/bin/env python3
"""Deterministic SVG path-to-PDF conversion of the approved Orbit vectors (no fonts)."""
from pathlib import Path
import hashlib
import json
import re
import shutil
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'tools/orbit-mockup/brand/elan-dot'
OUTPUT = ROOT / 'native/Sources/BrowserShell/Resources/Orbit'
APPROVED = {
    'wordmark.svg': 'b61ca7cefec100c7893ab046c2a30c6b90dfa7c9b9a5f7a0046c0664d3bb020a',
    'sign-color.svg': 'c9842273b5e432d25143eb0b434cc7a59953f62cac5159cbf069c322626f3ec6',
}


def number(value):
    return format(float(value), '.10g')


def color(value):
    return ' '.join(number(int(value[i:i+2], 16) / 255) for i in (1, 3, 5)) + ' rg'


def convert(source):
    root = ET.fromstring(source.read_bytes())
    width, height = map(float, (root.attrib['width'], root.attrib['height']))
    operations = ['q', f'1 0 0 -1 0 {number(height)} cm']
    for element in root:
        kind = element.tag.split('}')[-1]
        if kind not in ('path', 'circle', 'rect'):
            continue
        fill = element.attrib.get('fill', 'currentColor')
        operations.append(color(root.attrib['color'] if fill == 'currentColor' else fill))
        if kind == 'path':
            tokens = re.findall(r'[MLVHCZ]|-?\d+(?:\.\d+)?', element.attrib['d'])
            # Fail closed if an asset introduces an unsupported command or syntax.
            assert ''.join(tokens) == re.sub(r'[\s,]', '', element.attrib['d'])
            index = 0
            x = y = 0
            while index < len(tokens):
                command = tokens[index]
                index += 1
                count = {'M': 2, 'L': 2, 'V': 1, 'H': 1, 'C': 6, 'Z': 0}[command]
                values = tokens[index:index+count]
                index += count
                if command in ('M', 'L'):
                    x, y = values
                    operations.append(f'{x} {y} ' + ('m' if command == 'M' else 'l'))
                elif command == 'H':
                    x = values[0]
                    operations.append(f'{x} {y} l')
                elif command == 'V':
                    y = values[0]
                    operations.append(f'{x} {y} l')
                elif command == 'C':
                    x, y = values[-2:]
                    operations.append(' '.join(values) + ' c')
                else:
                    operations.append('h')
        elif kind == 'rect':
            x, y = (float(element.attrib.get(key, 0)) for key in ('x', 'y'))
            w, h = (float(element.attrib[key]) for key in ('width', 'height'))
            r = float(element.attrib.get('rx', 0))
            assert 0 < r <= min(w, h) / 2 and 'ry' not in element.attrib
            k = r * 0.5522847498307936
            operations.append(f'{number(x+r)} {number(y)} m')
            for line, curve in [((x+w-r,y), (x+w-r+k,y,x+w,y+r-k,x+w,y+r)),
                                ((x+w,y+h-r), (x+w,y+h-r+k,x+w-r+k,y+h,x+w-r,y+h)),
                                ((x+r,y+h), (x+r-k,y+h,x,y+h-r+k,x,y+h-r)),
                                ((x,y+r), (x,y+r-k,x+r-k,y,x+r,y))]:
                operations.append(' '.join(map(number, line)) + ' l')
                operations.append(' '.join(map(number, curve)) + ' c')
            operations.append('h')
        else:
            x, y, radius = (float(element.attrib[key]) for key in ('cx', 'cy', 'r'))
            k = radius * 0.5522847498307936
            operations.append(f'{number(x+radius)} {number(y)} m')
            for values in [(x+radius,y+k,x+k,y+radius,x,y+radius),
                           (x-k,y+radius,x-radius,y+k,x-radius,y),
                           (x-radius,y-k,x-k,y-radius,x,y-radius),
                           (x+k,y-radius,x+radius,y-k,x+radius,y)]:
                operations.append(' '.join(map(number, values)) + ' c')
            operations.append('h')
        operations.append('f*' if element.attrib.get('fill-rule') == 'evenodd' else 'f')
    operations.append('Q')
    stream = ('\n'.join(operations) + '\n').encode('ascii')
    objects = [b'<< /Type /Catalog /Pages 2 0 R >>', b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
               f'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {number(width)} {number(height)}] /Contents 4 0 R /Resources << >> >>'.encode(),
               f'<< /Length {len(stream)} >>\nstream\n'.encode() + stream + b'endstream']
    pdf = bytearray(b'%PDF-1.4\n%\xe2\xe3\xcf\xd3\n')
    offsets = [0]
    for index, obj in enumerate(objects, 1):
        offsets.append(len(pdf))
        pdf.extend(f'{index} 0 obj\n'.encode() + obj + b'\nendobj\n')
    offset = len(pdf)
    pdf.extend(b'xref\n0 5\n0000000000 65535 f \n')
    for value in offsets[1:]:
        pdf.extend(f'{value:010} 00000 n \n'.encode())
    pdf.extend(f'trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n{offset}\n%%EOF\n'.encode())
    return pdf


if __name__ == '__main__':
    OUTPUT.mkdir(parents=True, exist_ok=True)
    hashes = {}
    for name in ('wordmark', 'sign-color'):
        source = SOURCE / (name + '.svg')
        if hashlib.sha256(source.read_bytes()).hexdigest() != APPROVED[source.name]:
            raise SystemExit('Approved vector hash mismatch: ' + source.name)
        shutil.copyfile(source, OUTPUT / source.name)
        target = OUTPUT / (name + '.pdf')
        target.write_bytes(convert(source))
        hashes[source.name] = hashlib.sha256(source.read_bytes()).hexdigest()
        hashes[target.name] = hashlib.sha256(target.read_bytes()).hexdigest()
    (OUTPUT / 'vector-provenance.json').write_text(json.dumps(hashes, indent=2, sort_keys=True) + '\n')
