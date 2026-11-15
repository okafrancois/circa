"""Strict, dependency-free release note format shared by publishing and the website."""
from dataclasses import dataclass
from datetime import date
import html
import importlib.util
from pathlib import Path
import re
import struct

ROOT = Path(__file__).resolve().parents[1]
SECTIONS = ('New', 'Faster', 'Fixed', 'Smaller', 'Known limits')
VERSION = re.compile(r'(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-nightly\.(0|[1-9]\d*))?')
MAX_MEDIA_BYTES = 3_000_000
_spec = importlib.util.spec_from_file_location('public_hygiene', ROOT / 'scripts/check-public-hygiene.py')
_hygiene = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_hygiene)


@dataclass
class Media:
    file: str
    poster: str
    caption: str


@dataclass
class Note:
    version: str
    date: str
    title: str
    sections: dict
    engine: str = ''
    media: tuple = ()

    @property
    def channel(self):
        return 'nightly' if '-nightly.' in self.version else 'stable'

    @property
    def counts(self):
        return ' · '.join(f'{len(self.sections[name])} {name.lower()}' for name in SECTIONS
                          if name in self.sections and name != 'Known limits')


def version_key(version):
    match = VERSION.fullmatch(version)
    if not match:
        raise ValueError(f'Invalid version: {version}')
    major, minor, patch, nightly = match.groups()
    return (int(major), int(minor), int(patch), nightly is None, int(nightly or 0))


def scalar(value):
    # Deliberately not YAML: plain single-line text, or a matching pair of quotes.
    value = value.strip()
    if value.startswith(('"', "'")):
        if len(value) < 2 or value[-1] != value[0]:
            raise ValueError('Unclosed front matter quote')
        value = value[1:-1]
    if not value or any(ord(c) < 32 for c in value):
        raise ValueError('Expected nonempty single-line text')
    return value


def parse(text, version):
    version_key(version)
    findings = _hygiene.check_text('release/notes/' + version + '.md', text)
    if findings:
        raise ValueError('Release note violates public neutrality policy: ' + str(findings))
    lines = text.splitlines()
    if not lines or lines[0] != '---':
        raise ValueError('Expected front matter')
    try:
        end = lines.index('---', 1)
    except ValueError:
        raise ValueError('Unclosed front matter') from None
    fields, media, entry = {}, [], None
    media_mode = False
    for line in lines[1:end]:
        if not line.strip():
            continue
        item = re.fullmatch(r'  - file: (.+)', line)
        detail = re.fullmatch(r'    (poster|caption): (.+)', line)
        top = re.fullmatch(r'(date|title|engine|media):(?: (.+))?', line)
        if item and media_mode:
            entry = {'file': scalar(item[1])}
            media.append(entry)
        elif detail and entry is not None:
            if detail[1] in entry:
                raise ValueError('Duplicate media field')
            entry[detail[1]] = scalar(detail[2])
        elif top:
            key, value = top.groups()
            if key in fields or (key == 'media' and value is not None):
                raise ValueError('Duplicate field or invalid media list')
            if key != 'media' and value is None:
                raise ValueError('Empty front matter field: ' + key)
            fields[key] = scalar(value) if value else ''
            media_mode = key == 'media'
            entry = None
        else:
            raise ValueError('Invalid front matter line: ' + line)
    if not fields.get('title') or not re.fullmatch(r'\d{4}-\d{2}-\d{2}', fields.get('date', '')):
        raise ValueError('Title and ISO date are required')
    date.fromisoformat(fields['date'])
    sections, current = {}, None
    for line in lines[end + 1:]:
        if not line.strip():
            continue
        if line.startswith('## '):
            current = line[3:]
            if current not in SECTIONS or current in sections:
                raise ValueError('Unknown or duplicate section: ' + current)
            sections[current] = []
        elif line.startswith('- ') and current:
            sections[current].append(scalar(line[2:]))
        elif line.startswith('  ') and current and sections[current]:
            sections[current][-1] += ' ' + scalar(line)
        else:
            raise ValueError('Expected section or bullet: ' + line)
    if not sections or any(not items for items in sections.values()):
        raise ValueError('At least one nonempty section is required; omit empty sections')
    for item in sections.get('Faster', []):
        if not re.search(r'\d+(?:\.\d+)?[^\n]*→[^\n]*\d+(?:\.\d+)?', item):
            raise ValueError('Every Faster item needs measured before → after numbers')
    if 'media' in fields and not media:
        raise ValueError('Omit an empty media list')
    names = set()
    for item in media:
        if set(item) != {'file', 'poster', 'caption'}:
            raise ValueError('Media needs file, poster and caption')
        for key, suffix in [('file', '.mp4'), ('poster', '.jpg')]:
            if not re.fullmatch(r'[a-z0-9][a-z0-9-]*' + re.escape(suffix), item[key]):
                raise ValueError('Media must use a plain lowercase filename: ' + item[key])
            if item[key] in names:
                raise ValueError('Duplicate media filename')
            names.add(item[key])
    if len(media) > len(sections.get('New', [])):
        raise ValueError('Media entries must correspond to New items')
    return Note(version, fields['date'], fields['title'], sections, fields.get('engine', ''),
                tuple(Media(**item) for item in media))


def boxes(data, start=0, end=None):
    end = len(data) if end is None else end
    while start < end:
        if end - start < 8:
            raise ValueError('Truncated MP4 box')
        size, kind = struct.unpack_from('>I4s', data, start)
        header = 8
        if size == 1:
            if end - start < 16:
                raise ValueError('Truncated MP4 box')
            size = struct.unpack_from('>Q', data, start + 8)[0]
            header = 16
        if size == 0:
            size = end - start
        if size < header or start + size > end:
            raise ValueError('Invalid MP4 box size')
        yield kind, data[start + header:start + size]
        start += size


def validate_clip(path):
    if not path.is_file() or not 0 < path.stat().st_size <= MAX_MEDIA_BYTES:
        raise ValueError(f'Media must exist and be at most 3 MB: {path}')
    try:
        top = dict(boxes(path.read_bytes()))
        if b'ftyp' not in top:
            raise ValueError('Missing MP4 type')
        movie = list(boxes(top[b'moov']))
        mvhd = dict(movie)[b'mvhd']
        offset = 20 if mvhd[0] == 1 else 12
        scale = struct.unpack_from('>I', mvhd, offset)[0]
        duration = struct.unpack_from('>Q' if mvhd[0] == 1 else '>I', mvhd, offset + 4)[0]
        if not scale or not 0 < duration / scale <= 15:
            raise ValueError('Clip must last at most 15 seconds')
        video_count = 0
        for kind, track in movie:
            if kind != b'trak':
                continue
            parts = dict(boxes(track))
            mdia = dict(boxes(parts[b'mdia']))
            handler = mdia[b'hdlr'][8:12]
            if handler == b'soun':
                raise ValueError('Clip must be silent (no audio track)')
            if handler == b'vide':
                video_count += 1
                tkhd = parts[b'tkhd']
                width, height = struct.unpack_from('>II', tkhd, len(tkhd) - 8)
                if not 0 < width / 65536 <= 1440 or height == 0:
                    raise ValueError('Clip width must be at most 1440 pixels')
                stbl = dict(boxes(dict(boxes(mdia[b'minf']))[b'stbl']))
                samples = list(boxes(stbl[b'stsd'], 8))
                if not samples or any(codec != b'avc1' for codec, _ in samples):
                    raise ValueError('Clip must use H.264 (avc1)')
        if video_count != 1:
            raise ValueError('Clip must contain one video track')
    except (KeyError, IndexError, struct.error) as error:
        raise ValueError('Malformed MP4: ' + str(path)) from error


def load(path, root=ROOT):
    note = parse(path.read_text(encoding='utf-8'), path.stem)
    directory = root / 'web/assets/releases' / note.version
    for media in note.media:
        validate_clip(directory / media.file)
        poster = directory / media.poster
        if not poster.is_file() or not 0 < poster.stat().st_size <= MAX_MEDIA_BYTES:
            raise ValueError('JPEG poster must exist and be at most 3 MB: ' + str(poster))
        data = poster.read_bytes()
        if not data.startswith(b'\xff\xd8\xff') or not data.endswith(b'\xff\xd9'):
            raise ValueError('Poster must be JPEG: ' + str(poster))
    return note


def load_all(root=ROOT):
    directory = root / 'release/notes'
    paths = list(directory.glob('*.md')) + list((directory / 'nightly').glob('*.md'))
    notes = []
    for path in paths:
        note = load(path, root)
        if (path.parent.name == 'nightly') != (note.channel == 'nightly'):
            raise ValueError('Nightly notes must live in release/notes/nightly')
        notes.append(note)
    if not any(note.channel == 'stable' for note in notes):
        raise ValueError('At least one stable release is required')
    return sorted(notes, key=lambda note: version_key(note.version), reverse=True)


def github_body(note):
    lines = [note.title, '', note.counts or 'Known limits', '']
    for name in SECTIONS:
        if name in note.sections:
            lines += ['## ' + name, ''] + ['- ' + item for item in note.sections[name]] + ['']
    if note.engine:
        lines += ['Engine / bundled components: ' + note.engine, '']
    return '\n'.join(lines)


def inline(text):
    # Small, safe Markdown subset: code, emphasis, strong, links and bare HTTPS URLs.
    pattern = r'`([^`]+)`|\*\*([^*]+)\*\*|\*([^*]+)\*|\[([^\]]+)\]\((https://[^\s)]+)\)|(https://[^\s<>]+)'
    parts, start = [], 0
    for match in re.finditer(pattern, text):
        parts.append(html.escape(text[start:match.start()]))
        code, strong, em, label, href, bare = match.groups()
        if code is not None:
            parts.append('<code>' + html.escape(code) + '</code>')
        elif strong is not None:
            parts.append('<strong>' + html.escape(strong) + '</strong>')
        elif em is not None:
            parts.append('<em>' + html.escape(em) + '</em>')
        else:
            url = href or bare.rstrip('.,;')
            suffix = '' if href else bare[len(url):]
            parts.append('<a href="' + html.escape(url, quote=True) + '">' + html.escape(label or url) + '</a>' + suffix)
        start = match.end()
    parts.append(html.escape(text[start:]))
    return ''.join(parts)
