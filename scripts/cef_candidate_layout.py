#!/usr/bin/env python3
"""Stage a flat SDK candidate from an immutable versioned CEF payload; never build CEF."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat

BINARY = 'Chromium Embedded Framework'
PAYLOAD_NAMES = {BINARY, 'Resources', 'Libraries'}


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for data in iter(lambda: stream.read(1048576), b''):
            digest.update(data)
    return digest.hexdigest()


def no_link_ancestors(path):
    path = Path(path)
    if not path.is_absolute() or path != path.resolve():
        raise ValueError('Path must be absolute, canonical and without symbolic-link ancestors')
    return path


def regular_tree(root):
    """Reject links and special files before copying a payload or SDK scaffolding."""
    no_link_ancestors(root)
    result = {}
    for path in sorted(root.rglob('*')):
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode) or not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
            raise ValueError('Non-regular payload entry: ' + str(path.relative_to(root)))
        if path.is_file():
            result[str(path.relative_to(root))] = sha256(path)
    return result


def flatten_framework(source, destination, expected_binary):
    source = no_link_ancestors(source)
    destination = no_link_ancestors(destination)
    if destination.exists():
        raise ValueError('Destination must be unused')
    if {p.name for p in source.iterdir()} != PAYLOAD_NAMES | {'Versions'}:
        raise ValueError('Unexpected versioned framework root')
    versions = source / 'Versions'
    no_link_ancestors(versions)
    if {p.name for p in versions.iterdir()} != {'A', 'Current'}:
        raise ValueError('Expected exactly one framework version')
    current = versions / 'Current'
    if not current.is_symlink() or os.readlink(current) != 'A':
        raise ValueError('Unexpected Current link')
    payload = no_link_ancestors(versions / 'A')
    if {p.name for p in payload.iterdir()} != PAYLOAD_NAMES:
        raise ValueError('Unexpected framework payload content')
    for name in PAYLOAD_NAMES:
        path = source / name
        if not path.is_symlink() or os.readlink(path) not in ('Versions/Current/' + name, 'Versions/A/' + name) or path.resolve() != payload / name:
            raise ValueError('Unexpected framework root link: ' + name)
    before = regular_tree(payload)
    if sha256(payload / BINARY) != expected_binary:
        raise ValueError('Pinned binary mismatch')
    shutil.copytree(payload, destination, symlinks=False)
    after = regular_tree(destination)
    if after != before:
        raise ValueError('Flattening changed payload bytes')
    for path in destination.rglob('*'):
        if path.is_file() and path.stat().st_ino == (payload / path.relative_to(destination)).stat().st_ino:
            raise ValueError('Payload copy must not use hard links')
    return {'files': before, 'payload_files_sha256': hashlib.sha256(json.dumps(before, sort_keys=True).encode()).hexdigest(), 'framework_sha256': expected_binary}
