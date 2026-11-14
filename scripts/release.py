#!/usr/bin/env python3
"""Build signed Orbit releases locally; remote mutations require --publish.

Every publishing run, and every non-isolated build, first passes the update preservation gate:
the latest public release, downloaded from the public feed and verified (feed and archive
EdDSA signatures, Developer ID team, older build), is installed in a synthetic data root and
updated to the candidate through the signed loopback update qualification of
scripts/test_update_ux.py (auth-transition: site sign-ins and installed extensions, two
profiles, restart, update and next update). Any failure, missing evidence, mismatched input or
unavailable GUI session stops the release before anything is signed, notarized or published.
"""
import argparse
import base64
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import xml.etree.ElementTree as ET
from urllib.parse import urlsplit

from sparkle_setup import ROOT, ensure_sparkle
from orbit_bundle_policy import set_helper_bundle_identifiers, validate_bundle_contents
from local_signing import configured_identity
from product_identity import BUNDLE_ID, DISPLAY_NAME, PRODUCT_NAME
from update_feed import update_feed_url


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
                CFBundleDisplayName=config['name'], LSHasLocalizedDisplayName=True, CFBundleShortVersionString=version,
                CFBundleVersion=str(build), OrbitDeveloperTeamID=config.get('team_id', ''),
                OrbitRepository=config['repository'], SUFeedURL=feed_url or update_feed_url(config['repository']),
                SUPublicEDKey=key, SUEnableAutomaticChecks=True, SUAllowsAutomaticUpdates=True,
                SUVerifyUpdateBeforeExtraction=True, SURequireSignedFeed=True, SUAutomaticallyUpdate=True,
                SUScheduledCheckInterval=3600, LSFileQuarantineEnabled=True)
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
    if (profile.get('TeamIdentifier') != [team] or not profile.get('ProvisionsAllDevices')
            or values.get('get-task-allow') or values.get('com.apple.security.get-task-allow')):
        raise ValueError('Expected a Developer ID distribution provisioning profile')
    for key, value in expected.items():
        allowed = values.get(key)
        # Apple's Developer ID profiles may authorize every iCloud service. Keep the
        # signed request narrow; wildcards never relax app, team or container admission.
        if key == 'com.apple.developer.icloud-services' and (allowed == '*' or allowed == ['*']):
            matches = True
        elif isinstance(value, list):
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


def verify_cloud_launch(bundle):
    """Fail before packaging if macOS refuses the restricted signature at execution."""
    info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    executable = bundle / 'Contents/MacOS' / info['CFBundleExecutable']
    result = run(executable, '--orbit-verify-icloud', capture_output=True, text=True, timeout=30)
    if json.loads(result.stdout) != {'icloudAvailable': True, 'storageInitialized': False}:
        raise RuntimeError('Release launch verification did not admit iCloud capabilities')


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
        verify_cloud_launch(destination)
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


FEED_SIGNATURE = re.compile(rb'<!-- sparkle-signatures:\nedSignature: ([A-Za-z0-9+/=]+)\nlength: ([0-9]+)\n-->\s*\Z')


def feed_signature(data):
    """Return (signed bytes, base64 signature) for a feed signed by sign_update or generate_appcast."""
    match = FEED_SIGNATURE.search(data)
    if not match:
        raise ValueError('Appcast requires an embedded Sparkle feed signature')
    signed = data[:match.start()]
    if int(match[2]) != len(signed) or len(base64.b64decode(match[1], validate=True)) != 64:
        raise ValueError('Appcast feed signature does not cover the published feed')
    return signed, match[1].decode()


def verify_feed_signature(path, public_key):
    signed, signature = feed_signature(Path(path).read_bytes())
    with tempfile.NamedTemporaryFile(prefix='appcast-signed-', suffix='.xml') as content:
        content.write(signed)
        content.flush()
        run('swift', ROOT / 'scripts/sparkle_verify.swift', public_key, signature, content.name)


def validate_appcast(path, build):
    """A publishable feed must offer this build as a full update, regardless of deltas, and be signed."""
    feed_signature(Path(path).read_bytes())
    namespace = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
    items = ET.parse(path).findall('./channel/item')
    versions = [int(item.findtext(namespace + 'version') or
                    item.find('enclosure').get(namespace + 'version', '0')) for item in items]
    if not versions or max(versions) != build:
        raise ValueError('Appcast does not point directly to the release being published')
    latest = items[versions.index(build)].find('enclosure')
    if latest is None or not latest.get('url') or not latest.get(namespace + 'edSignature'):
        raise ValueError('Latest release requires a signed full archive, independent of delta coverage')


SPARKLE = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
# The gate fails unless every one of these ran and passed (a narrower harness cannot pass).
REQUIRED_PRESERVATION_CHECKS = (
    'profiles_isolated', 'login_sets_persistent_session_and_httponly', 'old_engine_restart_keeps_persistent',
    'update_keeps_persistent', 'new_login_after_update', 'restart_keeps_old_and_new', 'next_update_keeps_old_and_new',
    'ext_installed_by_previous_engine', 'ext_old_engine_restart_keeps', 'ext_markers_isolated', 'ext_disabled_never_runs',
    'ext_updated_reports_same_storage', 'ext_updated_store_preserved', 'ext_updated_inventory',
    'ext_new_restart_reports_same_storage', 'ext_new_restart_store_preserved', 'ext_new_restart_inventory',
    'ext_next_update_reports_same_storage', 'ext_next_update_store_preserved', 'ext_next_update_inventory',
    'migration_backup_restorable')


def latest_feed_item(feed_path):
    """The newest full archive offered by a signed feed: (build, short version, url, length, signature)."""
    items = []
    for item in ET.parse(feed_path).findall('./channel/item'):
        enclosure = item.find('enclosure')
        if enclosure is None:
            continue
        build = item.findtext(SPARKLE + 'version') or enclosure.get(SPARKLE + 'version')
        short = item.findtext(SPARKLE + 'shortVersionString') or enclosure.get(SPARKLE + 'shortVersionString')
        if build and build.isdigit() and enclosure.get('url') and enclosure.get(SPARKLE + 'edSignature'):
            items.append((int(build), short or '', enclosure.get('url'), int(enclosure.get('length') or 0),
                          enclosure.get(SPARKLE + 'edSignature')))
    if not items:
        raise ValueError('The public feed offers no signed full archive')
    return max(items)


def download(url, destination):
    if urlsplit(url).scheme != 'https':
        raise ValueError('Release downloads must use HTTPS')
    with urllib.request.urlopen(url, timeout=120) as response, open(destination, 'wb') as output:
        shutil.copyfileobj(response, output)


def previous_release(config, work, candidate_build, fetch=download):
    """Downloads and verifies the release that installed copies run today."""
    feed = work / 'appcast.xml'
    fetch(update_feed_url(config['repository']), feed)
    verify_feed_signature(feed, config['public_ed_key'])
    build, short, url, length, signature = latest_feed_item(feed)
    expected_prefix = 'https://github.com/%s/releases/download/' % config['repository']
    if not url.startswith(expected_prefix) or not url.endswith('.zip'):
        raise ValueError('The public feed points outside this repository\'s releases')
    if build >= candidate_build:
        raise ValueError('The candidate build must be newer than the published build %d' % build)
    archive = work / 'previous.zip'
    fetch(url, archive)
    if length and archive.stat().st_size != length:
        raise ValueError('The published archive does not have the length its feed declares')
    run('swift', ROOT / 'scripts/sparkle_verify.swift', config['public_ed_key'], signature, archive)
    extracted = work / 'previous'
    extracted.mkdir()
    run('ditto', '-x', '-k', archive, extracted)
    apps = sorted(extracted.glob('*.app'))
    if len(apps) != 1:
        raise ValueError('The published archive must contain exactly one application')
    run('codesign', '--verify', '--strict', '--deep', apps[0])
    if config.get('team_id'):
        details = run('codesign', '-dv', '--verbose=4', apps[0], capture_output=True, text=True).stderr
        if 'TeamIdentifier=' + config['team_id'] not in details.splitlines():
            raise ValueError('The published application is not signed by the configured team')
    info = plistlib.loads((apps[0] / 'Contents/Info.plist').read_bytes())
    if str(info.get('CFBundleVersion')) != str(build):
        raise ValueError('The published application does not match its feed entry')
    return apps[0], {'build': build, 'version': short, 'url': url}


def bundle_identity(app):
    spec = importlib.util.spec_from_file_location('update_ux', ROOT / 'scripts/test_update_ux.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.input_identity(Path(app))


def check_preservation_summary(summary, run_id, previous, candidate):
    """Accepts only this run's complete, passing result for exactly these inputs."""
    checks = summary.get('checks') or {}
    missing = [name for name in REQUIRED_PRESERVATION_CHECKS if name not in checks]
    failed = sorted(name for name, value in checks.items() if value is not True)
    if summary.get('run_id') != run_id or summary.get('case') != 'auth-transition':
        raise RuntimeError('Preservation evidence does not belong to this release run')
    if summary.get('expect') != 'kept' or summary.get('extensions_expect') != 'kept':
        raise RuntimeError('Preservation qualification did not require kept data')
    if missing or failed or summary.get('passed') is not True:
        raise RuntimeError('Preservation qualification failed: missing %s, failed %s' % (missing, failed))
    inputs = summary.get('inputs') or {}
    if inputs.get('previous') != previous or inputs.get('candidate') != candidate:
        raise RuntimeError('Preservation qualification ran on different application bundles')


def qualify_preservation(config, candidate, build, output):
    """Mandatory gate: the published build updates to the candidate without losing sign-ins or
    installed extensions. Raises on any failure; there is no skip or degraded mode."""
    evidence = output / ('preservation-' + str(build))
    if evidence.exists():
        shutil.rmtree(evidence)
    evidence.mkdir(parents=True)
    with tempfile.TemporaryDirectory(prefix='circa-preservation-') as temporary:
        work = Path(temporary)
        previous, published = previous_release(config, work, build)
        print('preservation gate: published build %d (%s) -> candidate build %d' % (
            published['build'], published['version'], build), flush=True)
        run_id = secrets.token_hex(16)
        previous_identity, candidate_identity = bundle_identity(previous), bundle_identity(candidate)
        result = subprocess.run([sys.executable, str(ROOT / 'scripts/test_update_ux.py'), '--cases', 'auth-transition',
                                 '--previous-app', str(previous), '--source-app', str(candidate),
                                 '--evidence', str(evidence), '--run-id', run_id, '--auth-expect', 'kept',
                                 '--extensions-expect', 'kept'])
        summary_file = evidence / 'preservation-summary.json'
        if result.returncode or not summary_file.is_file():
            raise RuntimeError('Preservation qualification did not pass (exit %d); see %s' % (result.returncode, evidence))
        summary = json.loads(summary_file.read_text())
        check_preservation_summary(summary, run_id, previous_identity, candidate_identity)
    (evidence / 'gate.json').write_text(json.dumps({'published': published, 'candidateBuild': build, 'runID': run_id,
                                                    'checks': len(summary['checks'])}, indent=2) + '\n')
    print('preservation gate: passed %d checks' % len(summary['checks']), flush=True)
    return summary


def release_notes_path(version):
    release_version('v' + version)
    path = ROOT / 'release' / 'notes' / (version + '.md')
    return path if path.is_file() else None


def publish_release(config, version, archive, dmg, appcast, deltas=(), stable_dmg=None):
    # stable_dmg is an unversioned copy, so releases/latest/download/<name>.dmg stays a fixed download link.
    repo, tag = config['repository'], 'v' + version
    notes = release_notes_path(version)
    existing = subprocess.run(['gh', 'release', 'view', tag, '--repo', repo, '--json', 'isDraft'], capture_output=True, text=True)
    if existing.returncode:
        run('gh', 'release', 'create', tag, '--repo', repo, '--verify-tag', '--draft', '--title', f"{config['name']} {version}",
            *(['--notes-file', notes] if notes else ['--generate-notes']))
    elif not json.loads(existing.stdout)['isDraft']:
        raise ValueError('Refusing to mutate an already published release')
    elif notes:
        run('gh', 'release', 'edit', tag, '--repo', repo, '--notes-file', notes)
    run('gh', 'release', 'upload', tag, '--repo', repo, '--clobber', archive, dmg, *([stable_dmg] if stable_dmg else []), appcast, *sorted(deltas))
    run('gh', 'release', 'edit', tag, '--repo', repo, '--draft=false', '--latest')
    feed = subprocess.run(['gh', 'release', 'view', 'update-feed', '--repo', repo, '--json', 'isDraft,isPrerelease'], capture_output=True, text=True)
    if feed.returncode:
        run('gh', 'release', 'create', 'update-feed', '--repo', repo, '--verify-tag', '--prerelease', '--latest=false', '--title', 'Circa update feed', '--notes', 'Stable Sparkle update feed.')
    else:
        feed_info = json.loads(feed.stdout)
        if feed_info['isDraft'] or not feed_info['isPrerelease']:
            run('gh', 'release', 'edit', 'update-feed', '--repo', repo, '--draft=false', '--prerelease', '--latest=false')
    run('gh', 'release', 'upload', 'update-feed', '--repo', repo, '--clobber', appcast)


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
    parser.add_argument('--qualify-only', action='store_true',
                        help='Run only the update preservation gate against the compiled product')
    args = parser.parse_args()
    config = json.loads(args.config.read_text())
    if config.get('provisioning_profile'):
        config['provisioning_profile'] = str((args.config.parent / Path(config['provisioning_profile']).expanduser()).resolve())
    if args.test_notarize_app_only and not args.local_test_root:
        raise ValueError('--test-notarize-app-only requires an isolated test bundle')
    if not args.local_test_root and (config['name'] != DISPLAY_NAME or config['bundle_id'] != BUNDLE_ID):
        raise ValueError('Release name and bundle_id must match BrowserCore/ProductIdentity.swift')
    # A qualification-only run publishes nothing; outside a tag it carries no version.
    version = release_version(args.tag) if args.tag or not args.qualify_only else '0.0.0'
    if args.qualify_only and (args.publish or args.local_test_root):
        raise ValueError('--qualify-only neither publishes nor uses an isolated test root')
    if not args.qualify_only:
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
    output.mkdir(parents=True, exist_ok=True)
    # Isolated updater E2E builds (--local-test-root, never published) are the only exemption.
    if args.publish or args.qualify_only or not args.local_test_root:
        qualify_preservation(config, source, build, output)
    if args.qualify_only:
        print(json.dumps({'version': version, 'build': build, 'qualified': True, 'published': False}))
        return
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
        '--full-release-notes-url', 'https://circabrowser.com/changelog',
        '--delta-compression', 'lzfse', '--maximum-versions', '3', '--maximum-deltas', '5', archives)
    feed = archives / 'appcast.xml'
    # generate_appcast signs the feed when the new archive requires it; signing again is idempotent
    # and also covers an older feed in the archive directory.
    run(sparkle / 'bin/sign_update', *signing, feed, capture_output=True)
    validate_appcast(feed, build)
    verify_feed_signature(feed, config['public_ed_key'])
    if args.publish:
        stable_dmg = Path(dmg).with_name(config['name'] + '.dmg')
        shutil.copyfile(dmg, stable_dmg)
        publish_release(config, version, archive, dmg, archives / 'appcast.xml', archives.glob('*.delta'), stable_dmg)
    print(json.dumps({'version': version, 'build': build, 'zip': str(archive), 'dmg': str(dmg), 'appcast': str(archives / 'appcast.xml'), 'published': args.publish}))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, RuntimeError) as error:
        raise SystemExit('release: ' + str(error))
