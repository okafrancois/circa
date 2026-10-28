"""Strict product bundle layout checks, shared by unsigned CMake staging and signing."""
import argparse
from pathlib import Path
import plistlib

FRAMEWORK = 'Chromium Embedded Framework.framework'
HELPERS = ['Orbit Helper' + suffix + '.app' for suffix in ('', ' (GPU)', ' (Renderer)', ' (Plugin)', ' (Alerts)')]
ORBIT_RESOURCE_FILES = frozenset({
    'README.md', 'sign-color.pdf', 'sign-color.svg',
    'vector-provenance.json', 'wordmark.pdf', 'wordmark.svg',
})
BUILD_SUFFIXES = {'.d', '.o', '.a', '.swiftmodule', '.swiftdoc', '.swiftsourceinfo', '.dia', '.dsym'}


def helper_bundle_identifier(bundle_id, suffix='', synthetic=False):
    """Keep synthetic helper crash reports outside the product's identifier namespace."""
    if synthetic and (bundle_id == 'io.github.okatech.orbit.test.orbit' or bundle_id.startswith('io.github.okatech.orbit.test.orbit.')):
        bundle_id = 'io.github.okatech.orbit.test.orbit-synthetic' + bundle_id[len('io.github.okatech.orbit.test.orbit'):]
    return bundle_id + '.helper' + suffix


def set_helper_bundle_identifiers(bundle):
    """Assign identities to staged copies before signing, including CMake smoke bundles."""
    bundle = Path(bundle)
    info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    for name in HELPERS:
        variant = name[len('Orbit Helper'):-len('.app')].strip(' ()').lower()
        suffix = '.' + variant if variant else ''
        path = bundle / 'Contents/Frameworks' / name / 'Contents/Info.plist'
        helper = plistlib.loads(path.read_bytes())
        helper['CFBundleIdentifier'] = helper_bundle_identifier(
            info['CFBundleIdentifier'], suffix, info.get('OrbitSyntheticBundle', False))
        path.write_bytes(plistlib.dumps(helper))


def reject_build_artifacts(bundle):
    for entry in Path(bundle).rglob('*'):
        if any(Path(part).suffix.lower() in BUILD_SUFFIXES for part in entry.relative_to(bundle).parts):
            raise RuntimeError('Build artifact refused in bundle: ' + str(entry.relative_to(bundle)))


def validate_bundle_contents(bundle):
    """Reject unknown paths before codesign; vendor runtime resources have a bounded allow-list."""
    bundle = Path(bundle)
    reject_build_artifacts(bundle)
    orbit_directories = set()
    for entry in bundle.rglob('*'):
        relative = entry.relative_to(bundle)
        parts = relative.parts
        if any(Path(part).suffix.lower() in BUILD_SUFFIXES for part in parts):
            raise RuntimeError('Build artifact refused in bundle: ' + str(relative))
        if parts == ('Contents',):
            continue
        if not parts or parts[0] != 'Contents' or len(parts) < 2:
            raise RuntimeError('Unexpected bundle content: ' + str(relative))
        path = '/'.join(parts[1:])
        allowed = path in {'Info.plist', 'PkgInfo', 'MacOS', 'MacOS/Orbit', 'MacOS/Orbit', 'Resources', 'Frameworks', '_CodeSignature', '_CodeSignature/CodeResources'}
        if parts[1] == 'Resources' and len(parts) > 2:
            tail = parts[2:]
            allowed = len(tail) == 1 and tail[0] in {'LICENSE.txt', 'Orbit.icns', 'OrbitLabNative_BrowserShell.bundle'}
            if tail[0] in {'en.lproj', 'fr.lproj'}:
                allowed = len(tail) == 1 or (len(tail) == 2 and tail[1] == 'InfoPlist.strings')
                if entry.is_symlink() or (len(tail) == 1 and not entry.is_dir()) or (len(tail) == 2 and not entry.is_file()):
                    raise RuntimeError('Invalid app localization resource type refused: ' + str(relative))
            if tail[0] == 'OrbitLabNative_BrowserShell.bundle' and len(tail) > 1:
                resource = tail[1:]
                if resource[:1] == ('Contents',):
                    resource = resource[1:]
                allowed = resource in {(), ('Info.plist',), ('Resources',)}
                if resource[:1] == ('Resources',):
                    resource = resource[1:]
                allowed = allowed or (len(resource) == 1 and resource[0].endswith('.lproj')) or (
                    len(resource) == 2 and resource[0].endswith('.lproj') and resource[1] == 'Localizable.strings')
                # CMake retains Orbit/; SwiftPM flattens processed resource filenames.
                # Admit only this exact group, never arbitrary SVG/PDF/JSON/Markdown files.
                orbit_directory = resource == ('Orbit',)
                orbit_file = ((len(resource) == 1 and resource[0] in ORBIT_RESOURCE_FILES) or
                            (len(resource) == 2 and resource[0] == 'Orbit' and resource[1] in ORBIT_RESOURCE_FILES))
                if orbit_directory or orbit_file:
                    # New brand resources are concrete files/directories. In particular, rglob
                    # must not skip the contents of an aliased directory. Existing contained
                    # framework symlinks keep their original policy below.
                    if entry.is_symlink() or (orbit_directory and not entry.is_dir()) or (orbit_file and not entry.is_file()):
                        raise RuntimeError('Invalid Orbit resource type refused: ' + str(relative))
                    orbit_directories.add(entry if orbit_directory else entry.parent)
                    allowed = True
        if parts[1] == 'Frameworks' and len(parts) > 2:
            name, tail = parts[2], parts[3:]
            if name == 'libOrbitNetworkQoS.dylib' and not tail:
                allowed = True
            elif name in HELPERS:
                executable = name[:-4]
                allowed = '/'.join(tail) in {'', 'Contents', 'Contents/Info.plist', 'Contents/PkgInfo',
                    'Contents/MacOS', 'Contents/MacOS/' + executable,
                    'Contents/_CodeSignature', 'Contents/_CodeSignature/CodeResources'}
            elif name == 'Sparkle.framework':
                # Pinned upstream runtime: version links, locales, headers and nested signed code.
                allowed = True
            elif name == FRAMEWORK:
                # CEF runtime layout: current version links plus a single private version.
                if tail[:2] == ('Versions', 'A'):
                    tail = tail[2:]
                elif tail == ('Versions',) or tail == ('Versions', 'Current'):
                    tail = ()
                allowed = '/'.join(tail) in {'', 'Chromium Embedded Framework', 'Resources', 'Libraries',
                    '_CodeSignature', '_CodeSignature/CodeResources'}
                if tail and tail[0] == 'Resources' and len(tail) > 1:
                    allowed = (len(tail) == 2 and (Path(tail[-1]).suffix in {'.pak', '.dat', '.bin', '.plist', '.png', '.icns'}
                               or tail[-1].endswith('.lproj'))) or (
                        len(tail) == 3 and tail[1].endswith('.lproj') and Path(tail[2]).suffix in {'.pak', '.strings'})
                if tail and tail[0] == 'Libraries' and len(tail) == 2:
                    allowed = Path(tail[-1]).suffix == '.dylib' or tail[-1] == 'vk_swiftshader_icd.json'
        if not allowed:
            raise RuntimeError('Unexpected bundle content: ' + str(relative))
        if entry.is_symlink() and (not entry.exists() or not entry.resolve().is_relative_to(bundle.resolve())):
            raise RuntimeError('External or broken bundle symlink refused: ' + str(relative))

    # Legacy bundles without Orbit remain valid. Once present, all six resources are required
    # together in one layout; partial, split and duplicate groups cannot silently ship.
    if len(orbit_directories) > 1:
        raise RuntimeError('Ambiguous Orbit resource layouts refused')
    for directory in orbit_directories:
        for name in sorted(ORBIT_RESOURCE_FILES):
            resource = directory / name
            if resource.is_symlink() or not resource.is_file():
                raise RuntimeError('Missing or invalid required Orbit resource: ' + str(resource.relative_to(bundle)))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    parser.add_argument('--reject-build-artifacts', action='store_true')
    parser.add_argument('--set-helper-identifiers', action='store_true')
    args = parser.parse_args()
    try:
        if args.set_helper_identifiers:
            set_helper_bundle_identifiers(args.bundle)
        elif args.reject_build_artifacts:
            reject_build_artifacts(args.bundle)
        else:
            validate_bundle_contents(args.bundle)
    except RuntimeError as error:
        raise SystemExit(str(error))
