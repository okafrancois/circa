#!/usr/bin/env python3
"""Build signed Orbit releases locally; remote mutations require --publish."""
import argparse
import base64
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
from urllib.parse import urlsplit

from sparkle_setup import ROOT, ensure_sparkle
from orbit_bundle_policy import set_helper_bundle_identifiers, validate_bundle_contents
from local_signing import configured_identity
from product_identity import BUNDLE_ID, PRODUCT_NAME


def run(*arguments, **kwargs):
    return subprocess.run(list(map(str, arguments)), check=True, **kwargs)


def load_packager():
    spec = importlib.util.spec_from_file_location('orbit_app', ROOT / 'scripts/orbit-app.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def release_version(tag=None):
    if tag is None:
        tag = os.environ.get('GITHUB_REF_NAME')
    if tag is None:
        result = subprocess.run(['git', '-C', str(ROOT), 'describe', '--tags', '--exact-match'], capture_output=True, text=True)
        tag = result.stdout.strip() if result.returncode == 0 else 'v0.1.0'
    if not re.fullmatch(r'v\d+\.\d+\.\d+', tag):
        raise ValueError('Release tag must have the form vX.Y.Z')
    return tag[1:]


def update_info(info, config, version, build, local_test_root=None, feed_url=None):
    key = config['public_ed_key']
    if key and len(base64.b64decode(key, validate=True)) != 32:
        raise ValueError('public_ed_key must be a base64 Ed25519 public key')
    info.update(CFBundleIdentifier=config['bundle_id'], CFBundleName=config['name'],
                CFBundleDisplayName=config['name'], CFBundleShortVersionString=version,
                CFBundleVersion=str(build), OrbitDeveloperTeamID=config.get('team_id', ''), SUFeedURL=feed_url or
                f"https://github.com/{config['repository']}/releases/latest/download/appcast.xml",
                SUPublicEDKey=key, SUEnableAutomaticChecks=True, SUAutomaticallyUpdate=True,
                SUScheduledCheckInterval=3600)
    for name in ('OrbitSyntheticBundle', 'OrbitDataRoot', 'OrbitUseMockKeychain', 'OrbitUpdaterLocalTest',
                 'LSUIElement', 'LSBackgroundOnly'):
        info.pop(name, None)
    if local_test_root:
        url = urlsplit(feed_url or '')
        if (url.scheme != 'http' or url.hostname != '127.0.0.1' or not url.port
                or config['bundle_id'] != 'io.github.okatech.orbit.test.update'):
            raise ValueError('Updater E2E requires its dedicated identity and a loopback feed')
        info.update(OrbitSyntheticBundle=True, OrbitUseMockKeychain=True,
                    OrbitDataRoot=str(local_test_root), OrbitUpdaterLocalTest=True,
                    NSAppTransportSecurity={'NSAllowsLocalNetworking': True})
    elif feed_url:
        raise ValueError('Feed overrides are confined to the isolated updater E2E')
    return info


ICLOUD_CONTAINER = 'iCloud.io.github.okatech.orbit'


def cloud_entitlements(profile, config, now=None):
    """Admit only an unexpired Developer ID profile for this exact production app."""
    from datetime import datetime, timezone
    now = now or datetime.now(timezone.utc)
    expiration = profile.get('ExpirationDate')
    if not expiration or expiration.replace(tzinfo=timezone.utc) <= now:
        raise ValueError('Provisioning profile is expired or has no expiration')
    team = config['team_id']
    values = profile.get('Entitlements', {})
    expected = {
        'com.apple.developer.icloud-services': ['CloudKit'],
        'com.apple.developer.icloud-container-identifiers': [ICLOUD_CONTAINER],
        'com.apple.developer.icloud-container-environment': 'Production',
        'com.apple.application-identifier': team + '.' + config['bundle_id'],
        'com.apple.developer.team-identifier': team,
    }
    if profile.get('TeamIdentifier') != [team] or not profile.get('ProvisionsAllDevices') or values.get('get-task-allow'):
        raise ValueError('Expected a Developer ID distribution provisioning profile')
    for key, value in expected.items():
        allowed = values.get(key)
        if isinstance(value, list):
            matches = isinstance(allowed, list) and all(item in allowed for item in value)
        elif isinstance(allowed, list):
            matches = value in allowed
        else:
            matches = value == allowed
        if not matches:
            raise ValueError('Provisioning profile does not authorize ' + key)
    push = values.get('com.apple.developer.aps-environment')
    if push is not None:
        if push != 'production':
            raise ValueError('CloudKit requires production push environment')
        expected['com.apple.developer.aps-environment'] = push
    return expected


def embed_cloud_profile(bundle, config, local_test_root=None):
    path = config.get('provisioning_profile')
    if not path or local_test_root:
        return None
    path = Path(path).expanduser()
    # An explicitly configured missing file is an error, never a silent loss of sync.
    decoded = run('security', 'cms', '-D', '-i', path, capture_output=True).stdout
    profile = plistlib.loads(decoded)
    entitlements = cloud_entitlements(profile, config)
    if not profile.get('DeveloperCertificates'):
        raise ValueError('Provisioning profile has no signing certificates')
    shutil.copyfile(path, bundle / 'Contents/embedded.provisionprofile')
    return entitlements


def verify_cloud_signature(bundle, expected):
    signed = run('codesign', '-d', '--entitlements', ':-', bundle, capture_output=True).stdout
    actual = plistlib.loads(signed)
    if any(actual.get(key) != value for key, value in expected.items()):
        raise RuntimeError('Signed iCloud entitlements do not match the profile')
    decoded = run('security', 'cms', '-D', '-i', bundle / 'Contents/embedded.provisionprofile', capture_output=True).stdout
    profile = plistlib.loads(decoded)
    with tempfile.TemporaryDirectory(prefix='orbit-profile-verify-') as temporary:
        prefix = str(Path(temporary) / 'certificate')
        run('codesign', '-d', '--extract-certificates=' + prefix, bundle, capture_output=True)
        if Path(prefix + '0').read_bytes() not in profile['DeveloperCertificates']:
            raise RuntimeError('Developer ID signer is not authorized by the provisioning profile')
    run('codesign', '--verify', '--strict', bundle)


def prepare_bundle(source, destination, config, version, build, local_test_root=None, feed_url=None):
    packager = load_packager()
    if local_test_root:
        local_test_root = packager.prepare_synthetic_root(local_test_root, config['bundle_id'])
    source_info = packager.read_info(source)
    if not local_test_root and (source_info.get('OrbitSyntheticBundle') or source_info.get('OrbitUseMockKeychain')):
        raise ValueError('A synthetic source bundle cannot become a production release')
    packager.private_copy(source, destination)
    info = update_info(packager.read_info(destination), config, version, build, local_test_root, feed_url)
    packager.write_info(destination, info)
    # Finder's localized names must follow the configured product name as well.
    resources = destination / 'Contents/Resources'
    for localized in resources.glob('*.lproj/InfoPlist.strings'):
        localized.write_bytes(plistlib.dumps({'CFBundleName': config['name'], 'CFBundleDisplayName': config['name']}))
    set_helper_bundle_identifiers(destination)
    for helper in (destination / 'Contents/Frameworks').glob('*Helper*.app'):
        values = packager.read_info(helper)
        values.update(CFBundleVersion=str(build), CFBundleShortVersionString=version)
        packager.write_info(helper, values)
    packager.validate_chromium_executable(destination / 'Contents/MacOS' / info['CFBundleExecutable'])
    if not (destination / 'Contents/Frameworks/Sparkle.framework').is_dir():
        raise RuntimeError('Rebuild the Chromium product with Sparkle before releasing')
    validate_bundle_contents(destination)
    identity = config.get('identity') or 'local'
    if identity == 'local' and not local_test_root:
        raise ValueError('The local identity is reserved for isolated test bundles')
    entitlements = embed_cloud_profile(destination, config, local_test_root)
    if entitlements:
        from local_signing import sign_chromium_bundle
        sign_chromium_bundle(destination, identity, main_entitlements=entitlements)
        verify_cloud_signature(destination, entitlements)
    else:
        packager.sign(destination, identity)
    if identity != 'local':
        details = run('codesign', '-dv', '--verbose=4', destination, capture_output=True, text=True).stderr
        if 'TeamIdentifier=' + config['team_id'] not in details.splitlines():
            raise RuntimeError('Signed application does not belong to the configured Developer ID team')


def require_notary_profile(config):
    profile = config.get('notarytool_profile')
    if not profile:
        return
    if config.get('identity', 'local') == 'local':
        raise ValueError('Notarization requires a Developer ID Application identity')
    result = subprocess.run(['xcrun', 'notarytool', 'history', '--keychain-profile', profile,
                             '--output-format', 'json'], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f"Notarization profile '{profile}' is missing or unavailable. "
                           "Configure it with xcrun notarytool store-credentials " + profile +
                           " --apple-id <Apple-ID> --team-id " + config['team_id'])


def notarize_archive(archive, profile, evidence):
    result = run('xcrun', 'notarytool', 'submit', archive, '--keychain-profile', profile,
                 '--wait', '--output-format', 'json', capture_output=True, text=True)
    submission = json.loads(result.stdout)
    evidence.write_text(json.dumps(submission, indent=2) + '\n')
    print('notarization id=' + submission.get('id', 'unknown') + ' status=' + submission.get('status', 'unknown'), flush=True)
    if submission.get('status') != 'Accepted':
        raise RuntimeError('Notarization rejected; inspect submission ' + submission.get('id', 'unknown'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=ROOT / 'release/config.json')
    parser.add_argument('--tag')
    parser.add_argument('--build-number', type=int)
    parser.add_argument('--output', type=Path, default=ROOT / 'dist/release')
    parser.add_argument('--ed-key-file', type=Path, default=os.environ.get('ORBIT_ED_KEY_FILE'))
    parser.add_argument('--publish', action='store_true')
    parser.add_argument('--test-notarize-app-only', action='store_true', help='Isolated E2E only: submit the app, skip the DMG submission')
    parser.add_argument('--skip-build', action='store_true', help='Reuse the already compiled Chromium product')
    parser.add_argument('--source-app', type=Path)
    parser.add_argument('--local-test-root', type=Path)
    parser.add_argument('--feed-url')
    args = parser.parse_args()
    config = json.loads(args.config.read_text())
    if config.get('provisioning_profile'):
        config['provisioning_profile'] = str((args.config.parent / Path(config['provisioning_profile']).expanduser()).resolve())
    if args.test_notarize_app_only and not args.local_test_root:
        raise ValueError('--test-notarize-app-only requires an isolated test bundle')
    if not args.local_test_root and (config['name'] != PRODUCT_NAME or config['bundle_id'] != BUNDLE_ID):
        raise ValueError('Release name and bundle_id must match BrowserCore/ProductIdentity.swift')
    version = release_version(args.tag)
    require_notary_profile(config)
    if not config['public_ed_key']:
        raise ValueError('Configure public_ed_key before preparing signed update releases')
    build = args.build_number or int(run('git', '-C', ROOT, 'rev-list', '--count', 'HEAD', capture_output=True, text=True).stdout)
    if build <= 0:
        raise ValueError('Build number must be positive and increase for every published version')
    if args.publish and (args.local_test_root or args.feed_url or not config['public_ed_key']):
        raise ValueError('Publishing requires the production feed and configured public key')
    sparkle = ensure_sparkle(config)
    if not args.skip_build:
        run('python3', ROOT / 'scripts/orbit-chromium-app.py', 'build', '--flavor', config['cef_flavor'])
    product_directory = ROOT / 'native/OrbitChromium/build' / ('app-' + config['cef_flavor']) / 'product'
    source = args.source_app
    if source is None:
        preferred = product_directory / (PRODUCT_NAME + '.app')
        candidates = [preferred] if preferred.is_dir() else sorted(product_directory.glob('*.app'))
        if len(candidates) != 1:
            raise ValueError('Expected one compiled product bundle; pass --source-app explicitly')
        source = candidates[0]
    output = args.output.resolve()
    archives = output / 'archives'
    archives.mkdir(parents=True, exist_ok=True)
    archive = archives / f"{config['name']}-{version}.zip"
    dmg = output / f"{config['name']}-{version}.dmg"
    if archive.exists() or dmg.exists():
        raise ValueError('Version artifacts already exist; choose a new version or output directory')
    with tempfile.TemporaryDirectory(prefix='orbit-release-', dir=output) as temporary:
        app = Path(temporary) / (config['name'] + '.app')
        prepare_bundle(source, app, config, version, build, args.local_test_root, args.feed_url)
        profile = config.get('notarytool_profile')
        if profile:
            if config.get('identity', 'local') == 'local':
                raise ValueError('Notarization requires a Developer ID Application identity')
            submission = Path(temporary) / 'notary.zip'
            run('ditto', '-c', '-k', '--keepParent', app, submission)
            notarize_archive(submission, profile, output / ('notarization-app-' + version + '.json'))
            run('xcrun', 'stapler', 'staple', app)
            run('xcrun', 'stapler', 'validate', app)
        run('ditto', '-c', '-k', '--keepParent', app, archive)
        image = Path(temporary) / 'image'
        image.mkdir()
        packager = load_packager()
        packager.private_copy(app, image / app.name)
        (image / 'Applications').symlink_to('/Applications')
        run('hdiutil', 'create', '-quiet', '-volname', config['name'], '-srcfolder', image, '-format', 'UDZO', dmg)
        with configured_identity(config.get('identity') or 'local') as signing:
            run('codesign', '--force', *signing, dmg, capture_output=True)
        if profile and not args.test_notarize_app_only:
            notarize_archive(dmg, profile, output / ('notarization-dmg-' + version + '.json'))
            run('xcrun', 'stapler', 'staple', dmg)
            run('xcrun', 'stapler', 'validate', dmg)
    signing = ['--ed-key-file', str(args.ed_key_file)] if args.ed_key_file else ['--account', config['keychain_account']]
    # An explicit file bypasses the Keychain entirely during local E2E.
    signed = run(sparkle / 'bin/sign_update', *signing, archive, capture_output=True, text=True).stdout
    signature = re.search(r'edSignature="([^"]+)"', signed)
    if not signature or not config['public_ed_key']:
        raise ValueError('Configure public_ed_key before generating an update feed')
    run('swift', ROOT / 'scripts/sparkle_verify.swift', config['public_ed_key'], signature[1], archive)
    prefix = args.feed_url.rsplit('/', 1)[0] + '/' if args.feed_url else f"https://github.com/{config['repository']}/releases/download/v{version}/"
    run(sparkle / 'bin/generate_appcast', *signing, '--versions', str(build), '--download-url-prefix', prefix,
        '--delta-compression', 'lzfse', archives)
    if args.publish:
        repo, tag = config['repository'], 'v' + version
        existing = subprocess.run(['gh', 'release', 'view', tag, '--repo', repo, '--json', 'isDraft'], capture_output=True, text=True)
        if existing.returncode:
            run('gh', 'release', 'create', tag, '--repo', repo, '--verify-tag', '--draft', '--title', f"{config['name']} {version}", '--generate-notes')
        elif not json.loads(existing.stdout)['isDraft']:
            raise ValueError('Refusing to mutate an already published release')
        run('gh', 'release', 'upload', tag, '--repo', repo, '--clobber', archive, dmg, archives / 'appcast.xml', *sorted(archives.glob('*.delta')))
        run('gh', 'release', 'edit', tag, '--repo', repo, '--draft=false', '--latest')
    print(json.dumps({'version': version, 'build': build, 'zip': str(archive), 'dmg': str(dmg), 'appcast': str(archives / 'appcast.xml'), 'published': args.publish}))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, RuntimeError) as error:
        raise SystemExit('release: ' + str(error))
