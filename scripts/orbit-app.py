#!/usr/bin/env python3
"""Package and install a private, persistently signed Chromium Orbit bundle.

Build never launches applications. Install stages beside the destination before checking
running processes. Only --relaunch requests a graceful quit; refusal preserves the old app.
"""
import argparse
import ctypes
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import subprocess
import tempfile
import time

from orbit_bundle_policy import helper_bundle_identifier, reject_build_artifacts, validate_bundle_contents
from product_identity import BUNDLE_ID, PRODUCT_NAME
from local_signing import SIGNING_DIRECTORY, unlocked_identity, sign_chromium_bundle

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / '.tools/orbit-app'
INSTALLER_WORK = Path.home() / 'Library/Application Support/Orbit Installer'
LIVE_BUNDLE_ID = 'io.github.okatech.orbit.test.orbit.live'
PRODUCT_IDS = (BUNDLE_ID, LIVE_BUNDLE_ID)
FRAMEWORK = 'Chromium Embedded Framework.framework'
HELPERS = [('', ''), (' (GPU)', '.gpu'), (' (Renderer)', '.renderer'),
           (' (Plugin)', '.plugin'), (' (Alerts)', '.alerts')]


def run(arguments, **kwargs):
    return subprocess.run(list(map(str, arguments)), check=True, **kwargs)


def bundle_info(version, bundle_id=BUNDLE_ID, principal='ACRApplication'):
    release_config = json.loads((ROOT / 'release/config.json').read_text())
    if re.fullmatch(r'\d+\.\d+\.\d+', version):
        numeric_version = run(['git', '-C', ROOT, 'rev-list', '--count', 'HEAD'], capture_output=True, text=True).stdout.strip()
    else:
        stamp = version.rsplit('.', 1)[-1]
        numeric_version = datetime.strptime(stamp, '%Y%m%dT%H%M%SZ').strftime('%Y%m%d.%H%M%S')
    return {
        'SUFeedURL': 'https://github.com/' + release_config['repository'] + '/releases/latest/download/appcast.xml',
        'SUPublicEDKey': release_config['public_ed_key'],
        'SUEnableAutomaticChecks': True, 'SUAutomaticallyUpdate': True,
        'SUScheduledCheckInterval': 3600,
        'CFBundleIdentifier': bundle_id,
        'CFBundleName': 'Orbit Live' if bundle_id == LIVE_BUNDLE_ID else PRODUCT_NAME,
        'CFBundleDisplayName': 'Orbit Live' if bundle_id == LIVE_BUNDLE_ID else PRODUCT_NAME,
        'CFBundleIconFile': 'Orbit.icns',
        'CFBundleDevelopmentRegion': 'en', 'CFBundleLocalizations': ['en', 'fr'],
        'CFBundleExecutable': PRODUCT_NAME, 'CFBundlePackageType': 'APPL',
        'CFBundleInfoDictionaryVersion': '6.0', 'CFBundleVersion': numeric_version,
        'OrbitBuildRevision': version,
        'CFBundleShortVersionString': version, 'LSMinimumSystemVersion': '15.0',
        'NSPrincipalClass': principal, 'NSHighResolutionCapable': True,
        'NSSupportsAutomaticTermination': False, 'NSSupportsSuddenTermination': False,
        'NSCameraUsageDescription': 'Orbit utilise la caméra uniquement pour les sites que vous autorisez.',
        'NSMicrophoneUsageDescription': 'Orbit utilise le microphone uniquement pour les sites que vous autorisez.',
        'NSLocationUsageDescription': 'Orbit partage votre localisation uniquement avec les sites que vous autorisez.',
        'NSLocationWhenInUseUsageDescription': 'Orbit partage votre localisation uniquement avec les sites que vous autorisez.',
        'NSBluetoothAlwaysUsageDescription': 'Orbit utilise le Bluetooth uniquement pour les sites et les appareils que vous autorisez.',
        'NSBluetoothPeripheralUsageDescription': 'Orbit utilise le Bluetooth uniquement pour les sites et les appareils que vous autorisez.',
        'CFBundleURLTypes': [{'CFBundleURLName': 'Web URLs', 'CFBundleTypeRole': 'Viewer',
                              'CFBundleURLSchemes': ['http', 'https']}],
        'CFBundleDocumentTypes': [{'CFBundleTypeName': 'Web document', 'CFBundleTypeRole': 'Viewer',
                                  'LSHandlerRank': 'Alternate',
                                  'CFBundleTypeExtensions': ['html', 'htm', 'xhtml', 'webloc', 'url'],
                                  'LSItemContentTypes': ['public.html', 'public.xhtml', 'com.apple.web-internet-location',
                                                       'com.microsoft.internet-shortcut']}],
        'LSEnvironment': {'MallocNanoZone': '0'},
    }


def ensure_private_links(source):
    """Allow framework version links only when their target stays within the copied tree."""
    if source.is_symlink():
        raise RuntimeError('The bundle source must be a real directory')
    root = source.resolve()
    for entry in source.rglob('*'):
        if entry.is_symlink() and (not entry.exists() or not entry.resolve().is_relative_to(root)):
            raise RuntimeError('External or broken bundle symlink refused')


def private_copy(source, destination):
    ensure_private_links(source)
    reject_build_artifacts(source)
    if destination.exists():
        raise RuntimeError('Copy destination already exists')
    # APFS clones have independent inodes and copy-on-write bytes, unlike hard links.
    result = subprocess.run(['/bin/cp', '-cR', str(source), str(destination)], capture_output=True)
    if result.returncode:
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(source, destination, symlinks=True)
    ensure_private_links(destination)


def read_info(bundle):
    return plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())


def write_info(bundle, info):
    (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))


def verify(bundle, expected_id=None):
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', bundle], capture_output=True)
    details = run(['/usr/bin/codesign', '-dvv', bundle], capture_output=True, text=True).stderr
    result = run(['/usr/bin/codesign', '-d', '-r-', bundle], capture_output=True, text=True)
    requirement = (result.stdout + result.stderr).lower()
    fingerprint = json.loads((SIGNING_DIRECTORY / 'identity.json').read_text())['fingerprint']
    if 'cdhash' in requirement or ('certificate root = H\"' + fingerprint + '\"').lower() not in requirement:
        raise RuntimeError('Stable local designated requirement is required')
    if 'Signature=adhoc' in details or 'Authority=Orbit Lab Local Development' not in details:
        raise RuntimeError('Stable local signing authority is required')
    if expected_id is not None and read_info(bundle)['CFBundleIdentifier'] != expected_id:
        raise RuntimeError('Unexpected bundle identifier')
    ensure_private_links(bundle)
    return [line for line in details.splitlines() if line.startswith(('Authority=', 'Identifier='))]


def sign(bundle, identity_name="local"):
    validate_bundle_contents(bundle)
    sign_chromium_bundle(bundle, identity_name)
    return verify(bundle) if identity_name == "local" else []


def validate_chromium_executable(executable):
    # This CEF bridge uses CefScopedLibraryLoader/dlopen, so otool -L has no CEF dependency.
    # Require its actual linked host and loader symbols; a neighbouring framework alone is insufficient.
    symbols = run(['/usr/bin/nm', executable], capture_output=True, text=True).stdout
    names = {line.rsplit(None, 1)[-1] for line in symbols.splitlines() if line.strip()}
    if not {'_ACRRun', '_cef_load_library'} <= names:
        raise RuntimeError('Expected the Chromium host and CEF loader symbols; WebKit/stripped input refused')


SYNTHETIC_MARKER = '.orbit-synthetic-root'
LSREGISTER = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'


def synthetic_path(root):
    # Reserve all of Library without inspecting any product or Live data directory.
    personal = (Path.home() / 'Library').resolve()
    reserved = str(personal).casefold()
    def overlaps(path):
        normalized = str(path).casefold()
        return (normalized == reserved or normalized.startswith(reserved + '/')
                or reserved.startswith(normalized.rstrip('/') + '/'))
    if not root.is_absolute() or overlaps(root.absolute()):
        raise RuntimeError('Synthetic root must be absolute and disjoint from the personal Library root')
    resolved = root.resolve()
    if overlaps(resolved):
        raise RuntimeError('Synthetic root must be absolute and disjoint from the personal Library root')
    return resolved


def prepare_synthetic_root(root, bundle_id):
    resolved = synthetic_path(root)
    if root.is_symlink():
        raise RuntimeError('Synthetic root must not be a symbolic link')
    resolved.mkdir(parents=True, mode=0o700, exist_ok=True)
    if resolved.stat().st_uid != os.getuid():
        raise RuntimeError('Synthetic root must be owned by this user')
    marker = resolved / SYNTHETIC_MARKER
    expected = json.dumps({'bundleID': bundle_id, 'owner': os.getuid(), 'version': 1}, sort_keys=True) + '\n'
    if marker.exists() or marker.is_symlink():
        if marker.is_symlink() or not marker.is_file() or marker.stat().st_uid != os.getuid() or marker.read_text() != expected:
            raise RuntimeError('Synthetic root ownership marker mismatch')
    else:
        if any(resolved.iterdir()):
            raise RuntimeError('Synthetic root must be empty or carry its matching ownership marker')
        with marker.open('x') as handle:
            handle.write(expected)
        marker.chmod(0o600)
    return resolved


def clean_stale(repo):
    """Only disable build outputs under the requested Git checkout; preserve their bytes."""
    repo = repo.absolute()
    if repo.is_symlink() or not (repo / '.git').exists():
        raise RuntimeError('clean-stale requires a real Git checkout')
    disabled, running, warnings = [], [], []
    for relative in ('native/OrbitChromium/build', '.tools'):
        base = repo / relative
        if not base.exists():
            continue
        if base.is_symlink() or not base.resolve().is_relative_to(repo.resolve()):
            raise RuntimeError('Build root escapes the checkout')
        for directory, names, _ in os.walk(base, followlinks=False):
            for name in list(names):
                if not name.endswith('.app'):
                    continue
                names.remove(name)  # Never inspect nested framework/helper bundles.
                bundle = Path(directory) / name
                if bundle.is_symlink():
                    continue
                try:
                    info = read_info(bundle)
                except (OSError, ValueError):
                    continue
                identifier = info.get('CFBundleIdentifier', '')
                unconfined = identifier == BUNDLE_ID
                if identifier == 'io.github.okatech.orbit.test.orbit-chromium.app-smoke':
                    # Plist keys cannot attest that an old executable actually consumes them.
                    # Rebuild all legacy smoke outputs; never infer confinement from metadata.
                    unconfined = True
                if not unconfined:
                    continue
                if bundle_pids(bundle):
                    running.append(str(bundle.relative_to(repo)))
                    continue
                # Remove LaunchServices' cached registration before removing the executable bit.
                try:
                    run([LSREGISTER, '-u', bundle], capture_output=True)
                except subprocess.CalledProcessError:
                    # Already unregistered paths can return nonzero. Disable the host regardless.
                    warnings.append('LaunchServices unregister returned nonzero: ' + str(bundle.relative_to(repo)))
                executable = bundle / 'Contents/MacOS' / info.get('CFBundleExecutable', '')
                if executable.is_symlink() or not executable.resolve().is_relative_to(bundle.resolve()):
                    raise RuntimeError('Unsafe stale executable path')
                if executable.is_file():
                    executable.chmod(executable.stat().st_mode & ~0o111)
                target = bundle.with_name(bundle.name + '.disabled')
                if target.exists():
                    target = bundle.with_name(bundle.name + '.' + str(time.time_ns()) + '.disabled')
                bundle.rename(target)
                disabled.append(str(target.relative_to(repo)))
    return {'disabled': disabled, 'runningPreserved': running, 'warnings': warnings}


def assemble(source_app, executable, framework, helpers_dir, output, bundle_id, version, synthetic=False, synthetic_root=None):
    if bundle_id not in PRODUCT_IDS and not re.fullmatch(r'lab\.orbit\.orbit(?:\.[a-z0-9-]+)+', bundle_id):
        raise RuntimeError('Bundle identifier must be the product ID or an explicit laboratory test ID')
    if synthetic and bundle_id in PRODUCT_IDS:
        raise RuntimeError('Synthetic bundles require a test bundle identifier')
    if bundle_id not in PRODUCT_IDS and not synthetic:
        raise RuntimeError('Test bundle identifiers require --synthetic')
    if not synthetic and synthetic_root is not None:
        raise RuntimeError('Synthetic root requires --synthetic')
    if not synthetic and output.suffix == '.app':
        raise RuntimeError('Product build outputs must use a non-.app staging name')
    if output.exists() or output.is_symlink():
        raise RuntimeError('Build output already exists; choose a fresh staging path')
    confined_root = prepare_synthetic_root(
        Path(synthetic_root) if synthetic_root else output.absolute().parent / 'synthetic-data', bundle_id
    ) if synthetic else None
    if source_app:
        if not synthetic and (source_app / 'Contents/Info.plist').is_file() and 'synthetic' in read_info(source_app).get('CFBundleIdentifier', ''):
            raise RuntimeError('A laboratory app may only be packaged with --synthetic')
        if not synthetic and (source_app / 'Contents/Info.plist').is_file() and any(read_info(source_app).get(key) for key in ('OrbitUseMockKeychain', 'OrbitSyntheticBundle')):
            raise RuntimeError('A laboratory app may only be packaged with --synthetic')
        if not synthetic and not (source_app / 'Contents/Resources/OrbitLabNative_BrowserShell.bundle').is_dir():
            raise RuntimeError('BrowserShell localization resource bundle missing')
        private_copy(source_app, output)
        info = read_info(output)
        old_executable = output / 'Contents/MacOS' / info['CFBundleExecutable']
        if old_executable.name != PRODUCT_NAME:
            old_executable.rename(old_executable.with_name(PRODUCT_NAME))
        principal = info.get('NSPrincipalClass', 'ACRApplication')
        if not synthetic and 'synthetic' in info.get('CFBundleIdentifier', ''):
            raise RuntimeError('A laboratory app may only be packaged with --synthetic')
        metadata = {**info, **bundle_info(version, bundle_id, principal)}
        for key in ('LSUIElement', 'LSBackgroundOnly'):
            metadata.pop(key, None)
    else:
        if not (executable and framework and helpers_dir):
            raise RuntimeError('Provide --source-app or --executable, --framework and --helpers-dir')
        resources = list(Path(executable).parent.glob('OrbitLabNative_*.bundle'))
        if not synthetic and not any(resource.name == 'OrbitLabNative_BrowserShell.bundle' for resource in resources):
            raise RuntimeError('BrowserShell localization resource bundle missing')
        (output / 'Contents/MacOS').mkdir(parents=True)
        shutil.copy2(executable, output / 'Contents/MacOS' / PRODUCT_NAME)
        (output / 'Contents/Resources').mkdir(parents=True, exist_ok=True)
        for resource in resources:
            private_copy(resource, output / 'Contents/Resources' / resource.name)
        (output / 'Contents/MacOS' / PRODUCT_NAME).chmod(0o755)
        metadata = bundle_info(version, bundle_id)
    # Keep raw and localized names aligned with the Orbit bundle and executable.
    # Secure storage is explicit and independent of Finder localization.
    branding = ROOT / 'native/OrbitChromium/App/Branding'
    resources = output / 'Contents/Resources'
    resources.mkdir(parents=True, exist_ok=True)
    shutil.copy2(branding / 'Orbit.icns', resources / 'Orbit.icns')
    (resources / 'Orbit.icns').chmod(0o644)
    displayed_name = 'Orbit Live' if bundle_id == LIVE_BUNDLE_ID else PRODUCT_NAME
    for language in ('en', 'fr'):
        localized = resources / (language + '.lproj')
        localized.mkdir(exist_ok=True)
        (localized / 'InfoPlist.strings').write_bytes(plistlib.dumps({
            'CFBundleName': displayed_name, 'CFBundleDisplayName': displayed_name}))
    for key in ('OrbitDataRoot', 'OrbitUseMockKeychain', 'OrbitSyntheticBundle'):
        metadata.pop(key, None)
    if synthetic:
        # Test bundles never claim web URLs or documents: they would otherwise pile up in
        # System Settings > Default web browser and LaunchServices routing.
        for key in ('CFBundleURLTypes', 'CFBundleDocumentTypes'):
            metadata.pop(key, None)
        metadata.update(OrbitDataRoot=str(confined_root), OrbitUseMockKeychain=True, OrbitSyntheticBundle=True)
        metadata['LSUIElement'] = True  # Hidden guard used by X1-R2; not part of the real product.
    frameworks = output / 'Contents/Frameworks'
    frameworks.mkdir(parents=True, exist_ok=True)
    private_framework = frameworks / FRAMEWORK
    if framework:
        if private_framework.exists():
            shutil.rmtree(private_framework)
        private_copy(framework, private_framework)
    if not private_framework.is_dir():
        raise RuntimeError('Private Chromium framework missing')
    source_helpers = helpers_dir or frameworks
    for suffix, identifier_suffix in HELPERS:
        expected_name = PRODUCT_NAME + ' Helper' + suffix
        candidates = [p for p in source_helpers.glob('*Helper' + suffix + '.app') if p.is_dir()]
        if len(candidates) != 1:
            raise RuntimeError('Exactly one helper required for variant ' + repr(suffix))
        source = candidates[0]
        target = frameworks / (expected_name + '.app')
        if source != target:
            if source_helpers == frameworks:
                source.rename(target)
            else:
                if target.exists():
                    shutil.rmtree(target)
                private_copy(source, target)
        helper_info = read_info(target)
        old_name = helper_info['CFBundleExecutable']
        if old_name != expected_name:
            (target / 'Contents/MacOS' / old_name).rename(target / 'Contents/MacOS' / expected_name)
        helper_info.update(CFBundleExecutable=expected_name, CFBundleName=expected_name,
                           CFBundleIdentifier=helper_bundle_identifier(bundle_id, identifier_suffix, synthetic),
                           CFBundleVersion=version, CFBundleShortVersionString=version)
        write_info(target, helper_info)
    if len(list(frameworks.glob('*Helper*.app'))) != 5:
        raise RuntimeError('Unexpected helper bundle remains after assembly')
    validate_chromium_executable(output / 'Contents/MacOS' / PRODUCT_NAME)
    for suffix, _ in HELPERS:
        helper = frameworks / (PRODUCT_NAME + ' Helper' + suffix + '.app')
        info = read_info(helper)
        info['CFBundleVersion'] = metadata['CFBundleVersion']
        write_info(helper, info)
    write_info(output, metadata)
    ensure_private_links(output)
    validate_bundle_contents(output)
    signatures = sign(output)
    for suffix, identifier_suffix in HELPERS:
        signatures.extend(verify(frameworks / (PRODUCT_NAME + ' Helper' + suffix + '.app'),
                                 helper_bundle_identifier(bundle_id, identifier_suffix, synthetic)))
    signatures.extend(verify(private_framework))
    return signatures


CONTROL = r'''
import AppKit
let command = CommandLine.arguments[1]
let path = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL.resolvingSymlinksInPath()
let product = NSRunningApplication.runningApplications(withBundleIdentifier: "__PRODUCT_BUNDLE_ID__")
func isDestination(_ app: NSRunningApplication) -> Bool {
    app.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == path
}
let matches: [NSRunningApplication]
if command == "foreign-status" {
    matches = product.filter { !isDestination($0) }
} else if command == "path-status" || command == "quit" {
    matches = NSWorkspace.shared.runningApplications.filter { isDestination($0) }
} else {
    matches = product
}
if command == "quit" { for app in matches { _ = app.terminate() } }
for app in matches { print(app.processIdentifier) }
'''.replace('__PRODUCT_BUNDLE_ID__', BUNDLE_ID)


def control(command, app):
    WORK.mkdir(parents=True, exist_ok=True)
    # The short helper reads only bundle paths and PIDs; no session or URL data.
    with tempfile.TemporaryDirectory(prefix='control-', dir=WORK) as temporary:
        source = Path(temporary) / 'control.swift'
        source.write_text(CONTROL)
        return run(['swift', source, command, app], capture_output=True, text=True, timeout=45).stdout.strip()


def foreign_instance_running(destination):
    return bool(control('foreign-status', destination))


def refuse_foreign_instance(destination):
    if foreign_instance_running(destination):
        raise RuntimeError('An Orbit instance is running from another bundle path; installation refused without quitting it')


def bundle_pids(app):
    """Also include helper processes and hosts launched directly, outside LaunchServices."""
    needle = str(app.resolve()) + '/Contents/'
    rows = run(['/bin/ps', '-Ao', 'pid=,command='], capture_output=True, text=True).stdout
    return [int(row.split(None, 1)[0]) for row in rows.splitlines() if needle in row]


def exchange(first, second):
    library = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
    if library.renameatx_np(-2, os.fsencode(first), -2, os.fsencode(second), 2):
        raise OSError(ctypes.get_errno(), 'Atomic bundle exchange failed')


def archive_previous(stage, destination):
    """Reserve a unique sibling name without overwriting or pruning any backup."""
    archive = destination.with_name(destination.name + '.previous-' + str(time.time_ns()) + '.noindex')
    archive.mkdir(exist_ok=False)
    try:
        exchange(stage, archive)
    except Exception:
        archive.rmdir()  # Only our empty reservation; stage still holds the old app.
        raise
    try:
        stage.rmdir()  # Empty reservation after exchange.
    except OSError:
        # Archiving already succeeded. A leftover empty stage must not hide its path.
        pass
    return archive


def install(app, destination, relaunch=False):
    app, destination = app.resolve(), destination.expanduser().absolute()
    if destination.is_symlink() or destination == app:
        raise RuntimeError('Destination must be a distinct real bundle path')
    if destination.exists() and read_info(destination).get('CFBundleIdentifier') != BUNDLE_ID:
        raise RuntimeError('Refusing to replace a different application')
    if read_info(app)['CFBundleIdentifier'] != BUNDLE_ID:
        raise RuntimeError('Only the product bundle identifier may be installed')
    validate_chromium_executable(app / 'Contents/MacOS' / read_info(app)['CFBundleExecutable'])
    verify(app, BUNDLE_ID)
    refuse_foreign_instance(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with (destination.parent / '.Orbit-install.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        stage = destination.parent / '.Orbit-staged.pending'
        if stage.is_symlink():
            raise RuntimeError('Symbolic staging path refused')
        if stage.exists():
            if bundle_pids(stage) or control('path-status', stage):
                raise RuntimeError('Existing staging bundle is running; preserved')
            try:
                stage_identifier = read_info(stage).get('CFBundleIdentifier')
            except (OSError, ValueError, plistlib.InvalidFileException):
                stage_identifier = None  # Interrupted copy in this reserved staging location.
            if stage_identifier not in (None, BUNDLE_ID):
                raise RuntimeError('Existing staging bundle is unrelated; preserved')
            # May be the old working version after a crash immediately following exchange.
            # Never delete it, even when it looks like an interrupted incoming copy.
            stage.rename(destination.parent / ('.Orbit-rollback-' + str(time.time_ns()) + '.retained'))
        private_copy(app, stage)
        verify(stage, BUNDLE_ID)
        was_running = bool(bundle_pids(destination) or control('status', destination))
        if was_running and not relaunch:
            return {'installed': False, 'staged': str(stage), 'reason': 'Orbit is running; use --relaunch'}
        if was_running:
            refuse_foreign_instance(destination)
            control('quit', destination)
            deadline = time.monotonic() + 45
            while bundle_pids(destination) or control('status', destination):
                if time.monotonic() >= deadline:
                    raise RuntimeError('Graceful quit refused or timed out; existing bundle preserved; staged at ' + str(stage))
                time.sleep(0.2)
        # Recheck immediately before the atomic exchange, including processes outside NSWorkspace.
        refuse_foreign_instance(destination)
        if bundle_pids(destination) or control('status', destination):
            raise RuntimeError('Orbit restarted during staging; existing bundle preserved')
        replaced = destination.exists()
        if replaced:
            exchange(destination, stage)  # stage now retains the previous working release.
        else:
            stage.rename(destination)
        try:
            verify(destination, BUNDLE_ID)
        except Exception:
            if replaced:
                exchange(destination, stage)
            else:
                destination.rename(stage)
            raise
        previous = None
        warnings = []
        if destination == Path.home() / 'Applications/Orbit.app':
            try:
                run([LSREGISTER, '-f', destination], capture_output=True)
            except (OSError, subprocess.SubprocessError):
                warnings.append('Installation succeeded but LaunchServices registration failed')
        if replaced:
            previous = stage
            try:
                previous = archive_previous(stage, destination)
            except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
                warnings.append('Previous release archiving failed; old release retained in staging')
        relaunched = False
        if relaunch:
            try:
                # CHROMIUM-APP must supply real startup defaults and save-before-quit semantics.
                if foreign_instance_running(destination):
                    warnings.append('Relaunch skipped because another Orbit bundle is running')
                else:
                    if not control('status', destination):
                        run(['/usr/bin/open', destination])  # No -n: LaunchServices reuses an instance.
                    relaunched = True
            except (OSError, subprocess.SubprocessError):
                warnings.append('Installation succeeded but relaunch failed; open Orbit manually')
        return {'installed': True, 'bundle': str(destination),
                'previous': str(previous) if previous else None, 'relaunched': relaunched,
                'warnings': warnings}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    build = sub.add_parser('build')
    build.add_argument('--source-app', type=Path)
    build.add_argument('--executable', type=Path)
    build.add_argument('--framework', type=Path)
    build.add_argument('--helpers-dir', type=Path)
    build.add_argument('--build-command', help='Shell-quoted argv, executed without a shell before assembly')
    build.add_argument('--output', type=Path)
    build.add_argument('--bundle-id')
    build.add_argument('--synthetic-root', type=Path, help='Absolute synthetic root baked into the test plist')
    build.add_argument('--synthetic', action='store_true', help='Hidden test agent; requires a test bundle id')
    installer = sub.add_parser('install')
    installer.add_argument('--app', type=Path, required=True)
    installer.add_argument('--destination', type=Path, default=Path.home() / 'Applications/Orbit.app')
    installer.add_argument('--relaunch', action='store_true')
    cleaner = sub.add_parser('clean-stale', help='Disable unconfined build bundles; never scans installed apps')
    cleaner.add_argument('--repo', type=Path, default=ROOT)
    args = parser.parse_args()
    if args.command == 'build' and args.bundle_id is None:
        args.bundle_id = 'io.github.okatech.orbit.test.orbit.test.orbit-identity' if args.synthetic else BUNDLE_ID
    if args.command == 'clean-stale':
        print(json.dumps(clean_stale(args.repo), indent=2))
        return
    if args.command == 'install':
        result = install(args.app, args.destination, args.relaunch)
        print(json.dumps(result, indent=2))
        raise SystemExit(0 if result['installed'] else 75)
    if args.build_command:
        run(shlex.split(args.build_command), cwd=ROOT)
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    sha = run(['git', '-C', ROOT, 'rev-parse', '--short=12', 'HEAD'], capture_output=True, text=True).stdout.strip()
    version = sha + '.' + stamp
    output = (args.output or WORK / 'build' / stamp / ('Orbit.app' if args.synthetic else 'Orbit.app.staged')).absolute()
    if not args.synthetic and output.suffix == '.app':
        output = output.with_name(output.name + '.staged')
    output.parent.mkdir(parents=True, exist_ok=True)
    if args.source_app is None and args.executable is None:
        args.source_app = ROOT / "native/OrbitChromium/build/app-orbit-engine-extensions-r5/product/Orbit.app"
    signatures = assemble(args.source_app, args.executable, args.framework, args.helpers_dir,
                          output, args.bundle_id, version, args.synthetic, args.synthetic_root)
    report = {'bundle': str(output), 'version': version, 'signatures': signatures,
              'verification': 'codesign --verify --deep --strict passed', 'hardenedRuntime': False}
    (output.parent / 'package.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, subprocess.SubprocessError, OSError) as error:
        # Signing command stderr is intentionally not echoed (never log keychain data).
        raise SystemExit(str(error))
