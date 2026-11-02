"""Fetch the pinned CI engine using Python 3.12+ safe archive extraction."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1 << 20), b''):
            digest.update(block)
    return digest.hexdigest()


def install(archive, descriptor, destination):
    if not hasattr(tarfile, 'data_filter'):
        raise RuntimeError('Engine installation requires Python 3.12 or newer')
    if sha256(archive) != descriptor['archive_sha256']:
        raise ValueError('Engine archive checksum mismatch')
    flavor = descriptor['flavor']
    if not flavor.startswith('orbit-engine-extensions-') or '/' in flavor or '\\' in flavor:
        raise ValueError('Invalid engine flavor')
    destination = Path(destination).resolve()
    destination.mkdir(parents=True, exist_ok=True)
    target = destination / flavor
    if target.exists():
        raise ValueError('Refusing to replace an engine distribution')
    with tempfile.TemporaryDirectory(dir=destination) as temporary:
        stage = Path(temporary)
        with tarfile.open(archive) as bundle:
            for member in bundle.getmembers():
                if Path(member.name).parts[:1] != (flavor,):
                    raise ValueError('Unexpected archive root')
            bundle.extractall(stage, filter='data')
        root = stage / flavor
        manifest = json.loads((root / 'manifest.json').read_text())
        cef = Path(manifest['root'])
        if cef.is_absolute() or len(cef.parts) != 1 or cef.name in ('.', '..'):
            raise ValueError('Invalid engine root')
        framework = root / cef / 'Release/Chromium Embedded Framework.framework/Chromium Embedded Framework'
        wrapper = root / 'wrapper/libcef_dll_wrapper/libcef_dll_wrapper.a'
        for name, path in [('framework_sha256', framework), ('wrapper_sha256', wrapper)]:
            actual = sha256(path)
            if actual != descriptor[name] or actual != manifest[name]:
                raise ValueError('Engine binary checksum mismatch: ' + name)
        if manifest['flavor'] != flavor:
            raise ValueError('Engine manifest flavor mismatch')
        manifest['root'] = str((target / cef).resolve())
        (root / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        root.rename(target)
    return target


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--descriptor', type=Path, default=ROOT / 'release/engine.json')
    parser.add_argument('--destination', type=Path, default=ROOT / '.tools/chromium-fork/distrib')
    args = parser.parse_args()
    descriptor = json.loads(args.descriptor.read_text())
    config = json.loads((ROOT / 'release/config.json').read_text())
    if descriptor['flavor'] != config['cef_flavor']:
        raise ValueError('Release engine and descriptor differ')
    prefix = 'https://github.com/' + config['repository'] + '/releases/download/'
    if not descriptor['url'].startswith(prefix):
        raise ValueError('Engine must come from this repository release assets')
    with tempfile.TemporaryDirectory() as temporary:
        archive = Path(temporary) / 'engine.tar.gz'
        with urllib.request.urlopen(descriptor['url'], timeout=120) as response, archive.open('wb') as output:
            shutil.copyfileobj(response, output)
        print('Verified engine:', install(archive, descriptor, args.destination))


if __name__ == '__main__':
    main()
