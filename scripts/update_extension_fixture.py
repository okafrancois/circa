"""Installed-extension preservation fixture for scripts/test_update_ux.py (synthetic data only).

Two packaged MV3 extensions live in both synthetic profiles:
  X  enabled and pinned; a content script on the loopback fixture asks its service worker for a
     marker kept in chrome.storage.local, and the worker reports it to the fixture server;
  Y  disabled by the user; it would report the same way if it ever ran.

Before the update, the harness writes a minimal 1.0 record while the previous app is stopped
(Chromium's legacy preference MAC, as a fresh unencrypted profile would carry it). The previous
engine then authenticates that record with its own encrypted hashes, and its extension updater
installs the signed 2.0 CRX3 through Chromium's CrxInstaller from the loopback update URL.
Everything after that point is authored by the engines under test.

The fixture server answers only loopback requests and logs statuses (same, changed, foreign),
never marker values. Store summaries read synthetic profiles after the app quit and report
per-label facts only: presence, version, state, permissions, authenticator kinds.
"""
import base64
import hashlib
import hmac
import io
import json
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import tempfile
import zipfile

NAMES = {'X': 'Circa Preservation Fixture', 'Y': 'Circa Preservation Disabled Fixture'}
HOST_PATTERN = 'http://127.0.0.1/*'
INTERNAL = 1  # mojom::ManifestLocation::kInternal, as for store installs.
DISABLE_USER_ACTION = 1

BACKGROUND = r'''const VERSION = chrome.runtime.getManifest().version;
const LABEL = %(label)s;
async function marker() {
  const stored = await chrome.storage.local.get(['marker', 'created']);
  if (stored.marker) return stored;
  const value = {marker: crypto.randomUUID(), created: VERSION};
  await chrome.storage.local.set(value);
  return value;
}
chrome.runtime.onInstalled.addListener(() => { marker(); });
chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (!message || typeof message.profile !== 'string' || !sender.url) return;
  marker().then(async stored => {
    const page = new URL(sender.url);
    const report = new URL('/ext-report', page.origin);
    const fields = {profile: message.profile, phase: message.phase || '', ext: LABEL,
                    version: VERSION, marker: stored.marker, created: stored.created || ''};
    for (const [key, value] of Object.entries(fields)) report.searchParams.set(key, value);
    await fetch(report.href, {cache: 'no-store'});
    reply({ok: true});
  });
  return true;
});
'''

CONTENT = r'''(() => {
  const params = new URLSearchParams(location.search);
  if (location.pathname !== '/whoami' || !params.get('profile')) return;
  chrome.runtime.sendMessage({profile: params.get('profile'), phase: params.get('phase') || ''}).catch(() => {});
})();
'''


def _varint(value):
    result = bytearray()
    while value > 127:
        result.append((value & 127) | 128)
        value >>= 7
    return bytes(result + bytes([value]))


def _field(number, value):
    return _varint((number << 3) | 2) + _varint(len(value)) + value


def manifest(label, version, public_key, update_url):
    value = {'manifest_version': 3, 'name': NAMES[label], 'version': version,
             'key': base64.b64encode(public_key).decode(), 'update_url': update_url,
             'background': {'service_worker': 'background.js'},
             'content_scripts': [{'matches': [HOST_PATTERN], 'js': ['content.js'], 'run_at': 'document_end'}],
             'permissions': ['storage'], 'host_permissions': [HOST_PATTERN]}
    if label == 'X':
        value['action'] = {'default_title': NAMES[label]}
    return value


def files(label, manifest_value):
    return {'manifest.json': json.dumps(manifest_value, indent=2),
            'background.js': BACKGROUND % {'label': json.dumps(label)}, 'content.js': CONTENT}


def crx3(private_key, public_key, contents):
    """CRX3 with the developer proof (components/crx_file/crx3.proto)."""
    archive = io.BytesIO()
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as zipped:
        for name, text in sorted(contents.items()):
            zipped.writestr(name, text)
    crx_id = hashlib.sha256(public_key).digest()[:16]
    signed = _field(1, crx_id)
    payload = b'CRX3 SignedData\0' + struct.pack('<I', len(signed)) + signed + archive.getvalue()
    signature = subprocess.run(['/usr/bin/openssl', 'dgst', '-sha256', '-sign', str(private_key)],
                               input=payload, check=True, capture_output=True).stdout
    header = _field(2, _field(1, public_key) + _field(2, signature)) + _field(10000, signed)
    return b'Cr24' + struct.pack('<II', 3, len(header)) + header + archive.getvalue()


def extension_id(public_key):
    return ''.join(chr(97 + int(n, 16)) for n in hashlib.sha256(public_key).digest()[:16].hex())


def build(work, origin):
    """Ephemeral keys are deleted once the CRX is signed. Returns the fixture description."""
    directory = work / 'ext'
    directory.mkdir(mode=0o700)
    update_url = origin + '/ext/update.xml'
    fixture = {'update_url': update_url, 'extensions': {}}
    for label in ('X', 'Y'):
        key = directory / ('%s.pem' % label)
        try:
            subprocess.run(['/usr/bin/openssl', 'genrsa', '-out', str(key), '2048'], check=True, capture_output=True)
            key.chmod(0o600)
            public = subprocess.run(['/usr/bin/openssl', 'pkey', '-in', str(key), '-pubout', '-outform', 'DER'],
                                    check=True, capture_output=True).stdout
            first = manifest(label, '1.0', public, update_url)
            if label == 'X':
                second = manifest(label, '2.0', public, update_url)
                (directory / 'x-2.crx').write_bytes(crx3(key, public, files(label, second)))
        finally:
            key.unlink(missing_ok=True)
        fixture['extensions'][label] = {'id': extension_id(public), 'manifest': first}
    (work / 'ext-fixture.json').write_text(json.dumps(fixture, indent=2) + '\n')
    return fixture


def update_response(fixture, origin):
    """gupdate answer: X is offered 2.0 from the loopback codebase, Y never changes."""
    apps = []
    for label, entry in fixture['extensions'].items():
        if label == 'X':
            apps.append('<app appid="%s"><updatecheck codebase="%s/ext/x-2.crx" version="2.0" /></app>'
                        % (entry['id'], origin))
        else:
            apps.append('<app appid="%s"><updatecheck status="noupdate" /></app>' % entry['id'])
    return ('<?xml version="1.0" encoding="UTF-8"?><gupdate xmlns="http://www.google.com/update2/response" '
            'protocol="2.0">%s</gupdate>' % ''.join(apps)).encode()


def record_report(work, query):
    """Logs one extension report as statuses; markers stay in a private file of the run."""
    label, ext, phase = query.get('profile', ''), query.get('ext', ''), query.get('phase', '')
    if label not in ('A', 'B') or ext not in NAMES:
        return False
    markers_file = work / 'ext-markers.json'
    markers = json.loads(markers_file.read_text()) if markers_file.exists() else {}
    key, value = label + ':' + ext, query.get('marker', '')
    others = [stored for name, stored in markers.items() if name != key and name.endswith(':' + ext)]
    if not value:
        status = 'missing'
    elif value in others:
        status = 'foreign'
    elif key not in markers:
        markers[key] = value
        status = 'first'
    else:
        status = 'same' if markers[key] == value else 'changed'
    markers_file.write_text(json.dumps(markers))
    markers_file.chmod(0o600)
    entry = {'phase': phase, 'profile': label, 'ext': ext, 'version': query.get('version', ''),
             'created': query.get('created', ''), 'marker': status}
    with (work / 'ext.log').open('a') as handle:
        handle.write(json.dumps(entry) + '\n')
    return True


def reports(work, phase=None):
    path = work / 'ext.log'
    entries = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
    return [entry for entry in entries if phase is None or entry['phase'] == phase]


def reported(work, phase, version='2.0'):
    """X reported by both profiles in this phase at this version."""
    seen = {(entry['profile'], entry['ext'], entry['version']) for entry in reports(work, phase)}
    return all((label, 'X', version) in seen for label in ('A', 'B'))


def profile_directories(root, second):
    """The two synthetic Orbit profiles: B is the harness's second UUID, A the other one."""
    engine = root / 'Chromium'
    candidates = sorted(path for path in engine.glob('profile-*') if (path / 'Secure Preferences').is_file())
    second_name = 'profile-' + second.lower()
    b = [path for path in candidates if path.name == second_name]
    a = [path for path in candidates if path.name != second_name]
    if len(a) != 1 or len(b) != 1:
        raise RuntimeError('Expected exactly two synthetic profiles, found %d' % len(candidates))
    return {'A': a[0], 'B': b[0]}


def _device_id():
    # Chromium's preference MAC salt on macOS. Read in memory only; never printed or stored.
    platform = plistlib.loads(subprocess.run(['/usr/sbin/ioreg', '-rd1', '-c', 'IOPlatformExpertDevice', '-a'],
                                             check=True, capture_output=True).stdout)
    return platform[0]['IOPlatformUUID']


def _canonical(value):
    # services/preferences/tracked/pref_hash_calculator.cc drops empty containers.
    if isinstance(value, dict):
        return {key: item for key, entry in value.items() if (item := _canonical(entry)) not in ({}, [])}
    if isinstance(value, list):
        return [item for entry in value if (item := _canonical(entry)) not in ({}, [])]
    return value


def legacy_mac(device, path, value):
    """Unbranded builds use an empty seed; JSON matches base::JSONWriter's output."""
    text = json.dumps(_canonical(value), sort_keys=True, separators=(',', ':'), ensure_ascii=False)
    return hmac.new(b'', (device + path + text).encode(), hashlib.sha256).hexdigest().upper()


def seed(root, work, second, device=None):
    """While the previous app is stopped: a 1.0 record of X (enabled, pinned) and Y (disabled)."""
    fixture = json.loads((work / 'ext-fixture.json').read_text())
    device = device or _device_id()
    for profile in profile_directories(root, second).values():
        secure = profile / 'Secure Preferences'
        values = json.loads(secure.read_text())
        settings = values.setdefault('extensions', {}).setdefault('settings', {})
        protection = values.setdefault('protection', {})
        macs = protection.setdefault('macs', {})
        split = macs.setdefault('extensions', {}).setdefault('settings', {})
        for label, entry in fixture['extensions'].items():
            destination = profile / 'Extensions' / entry['id'] / '1.0_0'
            if destination.parent.exists():
                shutil.rmtree(destination.parent)
            destination.mkdir(parents=True)
            for name, text in files(label, entry['manifest']).items():
                (destination / name).write_text(text)
            disabled = label == 'Y'
            permissions = {'api': ['storage'], 'explicit_host': [HOST_PATTERN], 'manifest_permissions': [],
                           'scriptable_host': [HOST_PATTERN]}
            settings[entry['id']] = {
                'state': 0 if disabled else 1, 'disable_reasons': [DISABLE_USER_ACTION] if disabled else [],
                'location': INTERNAL, 'path': str(destination), 'manifest': entry['manifest'],
                'from_webstore': False, 'was_installed_by_default': False, 'was_installed_by_oem': False,
                'creation_flags': 1, 'active_permissions': permissions, 'granted_permissions': permissions,
                'install_time': '13300000000000000'}
            split[entry['id']] = legacy_mac(device, 'extensions.settings.' + entry['id'], settings[entry['id']])
        # A record with only legacy MACs, as an unencrypted profile carries it: the engine's
        # supported fallback authenticates it and stores its own encrypted hashes.
        macs['extensions'].pop('settings_encrypted_hash', None)
        protection.pop('super_encrypted_hash', None)
        protection['super_mac'] = legacy_mac(device, '', macs)
        secure.write_text(json.dumps(values))
        preferences = profile / 'Preferences'
        plain = json.loads(preferences.read_text()) if preferences.exists() else {}
        plain.setdefault('extensions', {})['pinned_extensions'] = [fixture['extensions']['X']['id']]
        preferences.write_text(json.dumps(plain))


def _ciphertext_kind(value):
    try:
        raw = base64.b64decode(value, validate=True)
    except (ValueError, TypeError):
        return 'unreadable'
    return raw[:3].decode('ascii', 'replace') if raw[:1] == b'v' else 'other'


def store_summary(root, work, second):
    """Synthetic profiles only, after the app quit. Labels, never extension IDs or values."""
    fixture = json.loads((work / 'ext-fixture.json').read_text())
    summary = {}
    for label, profile in profile_directories(root, second).items():
        values = json.loads((profile / 'Secure Preferences').read_text())
        plain_path = profile / 'Preferences'
        plain = json.loads(plain_path.read_text()) if plain_path.exists() else {}
        settings = values.get('extensions', {}).get('settings', {})
        macs = values.get('protection', {}).get('macs', {}).get('extensions', {})
        encrypted = macs.get('settings_encrypted_hash', {})
        reset = [path for path in (values.get('prefs', {}).get('tracked_preferences_reset', [])
                                   + plain.get('prefs', {}).get('tracked_preferences_reset', []))]
        pinned = (plain.get('extensions', {}).get('pinned_extensions')
                  or values.get('extensions', {}).get('pinned_extensions') or [])
        profile_summary = {'reset_paths': sorted({path.split('.')[0] + '.' + path.split('.')[1]
                                                  if path.startswith('extensions.settings.') else path
                                                  for path in reset}),
                           'reset_time': bool(values.get('prefs', {}).get('preference_reset_time')
                                              or plain.get('prefs', {}).get('preference_reset_time')),
                           'encrypted_kinds': sorted({_ciphertext_kind(item) for item in encrypted.values()})}
        for ext_label, entry in fixture['extensions'].items():
            record = settings.get(entry['id'])
            storage = profile / 'Local Extension Settings' / entry['id']
            info = {'present': record is not None, 'files': (profile / 'Extensions' / entry['id']).is_dir(),
                    'storage': storage.is_dir(), 'pinned': entry['id'] in pinned,
                    'legacy_mac': entry['id'] in macs.get('settings', {}),
                    'encrypted_hash': _ciphertext_kind(encrypted[entry['id']]) if entry['id'] in encrypted else None,
                    'reset': any(path == 'extensions.settings.' + entry['id'] for path in reset)}
            if record is not None:
                granted = record.get('granted_permissions', {})
                path = Path(record.get('path', ''))
                if not path.is_absolute():
                    path = profile / 'Extensions' / path
                info.update(version=record.get('manifest', {}).get('version'), location=record.get('location'),
                            enabled=not record.get('disable_reasons') and record.get('state', 1) != 0,
                            installed_dir=path.is_dir() and path.parent.name == entry['id'],
                            granted_storage='storage' in granted.get('api', []),
                            granted_host=HOST_PATTERN in granted.get('explicit_host', []))
            profile_summary[ext_label] = info
        summary[label] = profile_summary
    return summary


def backup_summary(root, work, second):
    """Engine migration snapshots written by the candidate (BrowserEngineMigrationBackup)."""
    fixture = json.loads((work / 'ext-fixture.json').read_text())
    directory = root / 'EngineMigrationBackups'
    snapshots = []
    profiles = profile_directories(root, second)
    for snapshot in sorted(directory.glob('*/manifest.json')) if directory.is_dir() else []:
        manifest_value = json.loads(snapshot.read_text())
        mode = snapshot.parent.stat().st_mode & 0o777
        entry = {'from': manifest_value.get('fromBuild'), 'to': manifest_value.get('toBuild'), 'mode': oct(mode),
                 'files': len(manifest_value.get('files', []))}
        for label, profile in profiles.items():
            copy = snapshot.parent / 'Chromium' / profile.name / 'Secure Preferences'
            if copy.is_file():
                settings = json.loads(copy.read_text()).get('extensions', {}).get('settings', {})
                entry[label] = {ext: data['id'] in settings for ext, data in fixture['extensions'].items()}
                entry[label]['cookies'] = (copy.parent / 'Network' / 'Cookies').is_file() or (copy.parent / 'Cookies').is_file()
        snapshots.append(entry)
    return snapshots


def checks(results, expect):
    """Assertions over fixture reports, store summaries and the candidate's inventory."""
    stores, inventory, ext_reports = results.get('extension_stores', {}), results.get('inventory', {}), results.get('ext_reports', [])
    out = {}

    def phase_reports(phase):
        return [entry for entry in ext_reports if entry['phase'] == phase]

    def x_ok(phase, first=False):
        entries = phase_reports(phase)
        allowed = {'first', 'same'} if first else {'same'}
        return all(any(e['profile'] == label and e['ext'] == 'X' and e['version'] == '2.0' for e in entries)
                   for label in ('A', 'B')) and all(
            e['marker'] in allowed for e in entries if e['ext'] == 'X' and e['version'] == '2.0')

    def stored(stage, predicate):
        value = stores.get(stage, {})
        return bool(value) and all(predicate(value[label]) for label in ('A', 'B'))

    out['ext_installed_by_previous_engine'] = x_ok('ext-installed', first=True) and stored(
        'ext-old', lambda p: p['X']['present'] and p['X'].get('version') == '2.0' and p['X'].get('location') == INTERNAL
        and p['X'].get('installed_dir') and p['X'].get('encrypted_hash') is not None and p['Y']['present']
        and not p['Y'].get('enabled'))
    out['ext_old_engine_restart_keeps'] = x_ok('ext-restart')
    out['ext_markers_isolated'] = not any(e['marker'] in ('foreign', 'missing') for e in ext_reports)
    out['ext_disabled_never_runs'] = not any(e['ext'] == 'Y' for e in ext_reports)
    if expect == 'record':
        return out
    candidate = (('auth-update', 'updated'), ('auth-restart', 'new-restart'), ('auth-next', 'next-update'))
    if expect == 'lost':
        stage = 'auth-restart'
        out['ext_lost_after_update'] = stored(stage, lambda p: not p['X']['present'])
        return out
    for stage, phase in candidate:
        out['ext_%s_reports_same_storage' % phase.replace('-', '_')] = x_ok(phase)
        out['ext_%s_store_preserved' % phase.replace('-', '_')] = stored(stage, lambda p: (
            p['X']['present'] and p['X'].get('version') == '2.0' and p['X'].get('enabled') and p['X'].get('installed_dir')
            and p['X'].get('granted_storage') and p['X'].get('granted_host') and p['X']['storage'] and p['X']['pinned']
            and p['Y']['present'] and not p['Y'].get('enabled') and p['Y']['files']
            and not p['X']['reset'] and not p['Y']['reset']))
        listed = inventory.get(phase, {})
        out['ext_%s_inventory' % phase.replace('-', '_')] = all(
            any(item.get('name') == NAMES['X'] and item.get('version') == '2.0' and item.get('enabled') is True
                and item.get('pinned') is True for item in listed.get(label, []))
            and any(item.get('name') == NAMES['Y'] and item.get('enabled') is False for item in listed.get(label, []))
            for label in ('A', 'B'))
    backups = results.get('backups', {}).get('auth-next', [])
    out['migration_backup_restorable'] = any(
        entry.get('mode') == '0o700' and all(entry.get(label, {}).get('X') and entry.get(label, {}).get('Y')
                                             for label in ('A', 'B')) for entry in backups)
    return out


def temporary_copy(path):
    """Copy of a synthetic SQLite/JSON file and its sidecars for offline reads."""
    temp = tempfile.TemporaryDirectory(prefix='ext-summary-')
    for sidecar in ('', '-wal', '-journal'):
        source = Path(str(path) + sidecar)
        if source.exists():
            shutil.copyfile(source, Path(temp.name) / (path.name + sidecar))
    return temp
