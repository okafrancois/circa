"""Strict product bundle layout checks, shared by unsigned CMake staging and signing."""
import argparse
import json
from pathlib import Path
import plistlib
import shutil

FRAMEWORK = 'Chromium Embedded Framework.framework'
HELPERS = ['Orbit Helper' + suffix + '.app' for suffix in ('', ' (GPU)', ' (Renderer)', ' (Plugin)', ' (Alerts)')]
ORBIT_RESOURCE_FILES = frozenset({
    'README.md', 'sign-color.pdf', 'sign-color.svg',
    'vector-provenance.json', 'wordmark.pdf', 'wordmark.svg',
})
ICON_CATALOG = json.loads((Path(__file__).resolve().parents[1] /
    'native/Sources/BrowserShell/Icons/catalog.json').read_text())
ICON_RESOURCE_FILES = frozenset({'catalog.json'} | {
    f'template/{size}/{name}.pdf' for size in (16, 20, 24) for name in ICON_CATALOG['template']
} | {f'color/24/{name}.svg' for name in ICON_CATALOG['color']})
ICON_RESOURCE_DIRECTORIES = frozenset(str(parent) for name in ICON_RESOURCE_FILES
    for parent in Path(name).parents if str(parent) != '.') | {'', 'template', 'color'}
BRAND_FONT_FILES = frozenset({'intertight.ttf', 'geistmono.ttf', 'gloock.ttf', 'intertight-OFL.txt', 'geistmono-OFL.txt', 'gloock-OFL.txt', 'mark.pdf'})
APP_ICON_IDS = ('stage', 'paper', 'sunset', 'afterglow', 'frost', 'riso', 'ink')
APP_ICON_FILES = frozenset(f'{icon}.{ext}' for icon in APP_ICON_IDS for ext in ('icns', 'png'))
BUILD_SUFFIXES = {'.d', '.o', '.a', '.swiftmodule', '.swiftdoc', '.swiftsourceinfo', '.dia', '.dsym'}


def helper_bundle_identifier(bundle_id, suffix='', synthetic=False):
    """Keep synthetic helper crash reports outside the product's identifier namespace."""
    if synthetic and (bundle_id == 'io.github.okatech.orbit.test.orbit' or bundle_id.startswith('io.github.okatech.orbit.test.orbit.')):
        bundle_id = 'io.github.okatech.orbit.test.orbit-synthetic' + bundle_id[len('io.github.okatech.orbit.test.orbit'):]
    return bundle_id + '.helper' + suffix


def set_helper_bundle_identifiers(bundle):
    """Assign identities and notification branding to staged copies before signing."""
    bundle = Path(bundle)
    info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    for name in HELPERS:
        variant = name[len('Orbit Helper'):-len('.app')].strip(' ()').lower()
        suffix = '.' + variant if variant else ''
        path = bundle / 'Contents/Frameworks' / name / 'Contents/Info.plist'
        helper = plistlib.loads(path.read_bytes())
        helper['CFBundleIdentifier'] = helper_bundle_identifier(
            info['CFBundleIdentifier'], suffix, info.get('OrbitSyntheticBundle', False))
        if variant == 'alerts':
            # The notification service has its own identity but presents the browser's brand.
            helper.update(CFBundleDisplayName=info.get('CFBundleDisplayName', info['CFBundleName']),
                          CFBundleIconFile='Orbit.icns', NSUserNotificationAlertStyle='alert')
            resources = path.parent / 'Resources'
            resources.mkdir(exist_ok=True)
            shutil.copyfile(bundle / 'Contents/Resources/Orbit.icns', resources / 'Orbit.icns')
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
    icon_directories = set()
    app_icon_directories = set()
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
                localized_file = (len(resource) == 2 and resource[0].endswith('.lproj') and
                                  resource[1] in {'Localizable.strings', 'Localizable.stringsdict'})
                allowed = allowed or (len(resource) == 1 and resource[0].endswith('.lproj')) or localized_file
                if resource[:1] == ('AppIcons',):
                    allowed = len(resource) == 1 or (len(resource) == 2 and resource[1] in APP_ICON_FILES)
                    if entry.is_symlink() or (len(resource) == 1 and not entry.is_dir()) or (len(resource) == 2 and not entry.is_file()):
                        raise RuntimeError('Invalid app icon resource type refused: ' + str(relative))
                    if allowed:
                        app_icon_directories.add(entry if len(resource) == 1 else entry.parent)
                if resource[:1] == ('Icons',):
                    icon = '/'.join(resource[1:])
                    icon_file = icon in ICON_RESOURCE_FILES
                    icon_directory = icon in ICON_RESOURCE_DIRECTORIES
                    allowed = icon_file or icon_directory
                    if entry.is_symlink() or (icon_file and not entry.is_file()) or (icon_directory and not entry.is_dir()):
                        raise RuntimeError('Invalid interface icon resource type refused: ' + str(relative))
                    if allowed:
                        icon_directories.add(entry.parents[len(resource) - 2] if len(resource) > 1 else entry)
                if localized_file and (entry.is_symlink() or not entry.is_file()):
                    raise RuntimeError('Invalid shared localization resource type refused: ' + str(relative))
                font_directory = resource == ('BrandFonts',)
                font_file = ((len(resource) == 1 and resource[0] in BRAND_FONT_FILES) or
                             (len(resource) == 2 and resource[0] == 'BrandFonts' and resource[1] in BRAND_FONT_FILES))
                if font_directory or font_file:
                    if entry.is_symlink() or (font_directory and not entry.is_dir()) or (font_file and not entry.is_file()):
                        raise RuntimeError('Invalid onboarding font resource: ' + str(relative))
                    allowed = True
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
                if name == 'Orbit Helper (Alerts).app' and tail in {
                    ('Contents', 'Resources'), ('Contents', 'Resources', 'Orbit.icns')
                }:
                    allowed = True
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

    if len(app_icon_directories) > 1:
        raise RuntimeError('Ambiguous app icon resource layouts refused')
    for directory in app_icon_directories:
        for name in sorted(APP_ICON_FILES):
            resource = directory / name
            if resource.is_symlink() or not resource.is_file():
                raise RuntimeError('Missing or invalid required app icon resource: ' + str(resource.relative_to(bundle)))

    if len(icon_directories) > 1:
        raise RuntimeError('Ambiguous interface icon resource layouts refused')
    for directory in icon_directories:
        for name in sorted(ICON_RESOURCE_FILES):
            resource = directory / name
            if resource.is_symlink() or not resource.is_file():
                raise RuntimeError('Missing or invalid required interface icon resource: ' + str(resource.relative_to(bundle)))

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
