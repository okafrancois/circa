#!/usr/bin/env python3
"""Package a local engine distribution as the prerelease archive that `ci_engine.py` installs.

The archive holds `<flavor>/manifest.json` with a relative engine root, the complete CEF
binary distribution except Bazel files, and only the wrapper static library. Owner names and IDs are cleared.
Prints the `release/engine.json` descriptor; nothing is uploaded.
"""
import argparse
import hashlib
import json
from pathlib import Path
import tarfile

ROOT = Path(__file__).resolve().parents[1]
WRAPPER = Path('wrapper/libcef_dll_wrapper/libcef_dll_wrapper.a')
FRAMEWORK = Path('Release/Chromium Embedded Framework.framework/Chromium Embedded Framework')
# Bazel project files at the engine root are not used by the CMake product build.
BAZEL = {'.bazelrc', '.bazelversion', 'BUILD.bazel', 'MODULE.bazel', 'WORKSPACE', 'bazel'}


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1 << 20), b''):
            digest.update(block)
    return digest.hexdigest()


def neutral(member):
    member.uid = member.gid = 0
    member.uname = member.gname = ''
    return member


def package(distribution, archive, repository):
    distribution = Path(distribution).resolve()
    manifest = json.loads((distribution / 'manifest.json').read_text())
    flavor = manifest['flavor']
    if distribution.name != flavor or not flavor.startswith('orbit-engine-extensions-'):
        raise ValueError('Distribution directory and manifest flavor differ')
    engine = Path(manifest['root']).resolve()
    if engine.parent != distribution:
        raise ValueError('Engine root is outside the distribution')
    framework, wrapper = engine / FRAMEWORK, distribution / WRAPPER
    hashes = {'framework_sha256': sha256(framework), 'wrapper_sha256': sha256(wrapper)}
    for name, actual in hashes.items():
        if manifest[name] != actual:
            raise ValueError('Distribution binary differs from its manifest: ' + name)
    portable = dict(manifest, root=engine.name)
    staged = Path(archive).resolve()
    if staged.exists():
        raise ValueError('Refusing to replace an existing archive')
    staged.parent.mkdir(parents=True, exist_ok=True)
    manifest_copy = staged.with_suffix('.manifest.json')
    manifest_copy.write_text(json.dumps(portable, indent=2) + '\n')
    try:
        with tarfile.open(staged, 'w:gz') as bundle:
            bundle.add(manifest_copy, flavor + '/manifest.json', filter=neutral)
            for item in sorted(engine.iterdir()):
                if item.name not in BAZEL:
                    bundle.add(item, '%s/%s/%s' % (flavor, engine.name, item.name), filter=neutral)
            bundle.add(wrapper, flavor + '/' + str(WRAPPER), filter=neutral)
    finally:
        manifest_copy.unlink()
    return {
        'flavor': flavor,
        'url': 'https://github.com/%s/releases/download/engine-%s/%s.tar.gz'
               % (repository, flavor.rsplit('-', 1)[1], flavor),
        'archive_sha256': sha256(staged),
        **hashes,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('distribution', type=Path, help='Local distrib/<flavor> directory')
    parser.add_argument('--output', type=Path, required=True, help='New .tar.gz path outside the repository')
    args = parser.parse_args()
    if ROOT in args.output.resolve().parents:
        parser.error('Write the archive outside the repository')
    repository = json.loads((ROOT / 'release/config.json').read_text())['repository']
    print(json.dumps(package(args.distribution, args.output, repository), indent=2))


if __name__ == '__main__':
    main()
