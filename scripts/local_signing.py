"""Stable, machine-local signing for Orbit (internal Orbit Lab) development builds.

Product renaming preserves this identity and its private signing keychain.

Only a dedicated generated signing keychain is changed. No browser keychain
item, login-keychain ACL, system trust setting or encryption key is changed.
Passwords for this generated keychain travel through stdin, never argv/logs.
"""
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import stat
import subprocess
import threading
import tempfile

def signing_directory(home=None):
    """Reuse the existing private identity across product renames, without copying keys."""
    if os.environ.get('ORBIT_SIGNING_DIRECTORY'):
        return Path(os.environ['ORBIT_SIGNING_DIRECTORY'])
    home = Path.home() if home is None else Path(home)
    preferred = home / '.local/share/orbit/signing'
    if preferred.exists():
        return preferred
    candidates = []
    for metadata in (home / '.local/share').glob('*/signing/identity.json'):
        directory = metadata.parent
        if directory.is_symlink() or metadata.is_symlink() or not metadata.is_file():
            continue
        try:
            record = json.loads(metadata.read_text())
        except (OSError, ValueError):
            continue
        if record.get('version') == 1 and re.fullmatch('[A-F0-9]{40}', record.get('fingerprint', '')):
            candidates.append(directory)
    if len(candidates) > 1:
        raise RuntimeError('Several local signing identities exist; set ORBIT_SIGNING_DIRECTORY explicitly.')
    return candidates[0] if candidates else preferred


SIGNING_DIRECTORY = signing_directory()
SECURITY = '/usr/bin/security'
CODESIGN = '/usr/bin/codesign'


def run(arguments, *, secret_input=None, label='signature locale', include_stderr=False, timeout=90):
    result = subprocess.run(arguments, input=secret_input, capture_output=True,
                            text=secret_input is not None, timeout=timeout)
    if result.returncode:
        # Do not echo arbitrary tool output: a security command can repeat its
        # input. The label is a fixed, non-sensitive diagnostic.
        raise RuntimeError(f'Échec : {label} (code {result.returncode}).')
    return result.stdout + result.stderr if include_stderr else result.stdout


def security(arguments, label):
    def quote(value):
        value = str(value)
        if any(character in value for character in '\r\n\0'):
            raise RuntimeError('Argument de signature invalide.')
        return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'
    return run([SECURITY, '-i'], secret_input=' '.join(map(quote, arguments)) + '\n', label=label)


def private_file(filename, text):
    with os.fdopen(os.open(filename, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w') as handle:
        handle.write(text)


def search_list():
    result = run([SECURITY, 'list-keychains', '-d', 'user'])
    return [line.strip()[1:-1] for line in result.decode().splitlines()
            if line.strip().startswith('"') and line.strip().endswith('"')]


def identity(directory=SIGNING_DIRECTORY):
    directory = Path(directory)
    metadata_file, password_file = directory / 'identity.json', directory / 'keychain-password'
    keychain = directory / 'orbit-signing.keychain-db'
    if metadata_file.exists():
        existing = list(directory.glob('*-signing.keychain-db'))
        if len(existing) == 1:
            keychain = existing[0]
        if any(filename.is_symlink() or not filename.is_file()
               for filename in [metadata_file, password_file, keychain]):
            raise RuntimeError('Identité de signature locale incomplète ; aucune nouvelle identité générée.')
        metadata = json.loads(metadata_file.read_text())
        if not re.fullmatch('[A-F0-9]{40}', metadata.get('fingerprint', '')):
            raise RuntimeError('Identité de signature locale invalide.')
        return keychain, password_file.read_text(), metadata['fingerprint']
    if directory.exists() and any(directory.iterdir()):
        raise RuntimeError('Configuration de signature partielle ; identité conservée pour réparation.')
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    directory.chmod(0o700)
    password = secrets.token_urlsafe(48)
    private_file(password_file, password)
    openssl = shutil.which('openssl')
    if not openssl:
        raise RuntimeError('OpenSSL est nécessaire à la signature locale.')
    try:
        security(['create-keychain', '-p', password, keychain], 'création du trousseau de signature dédié')
        security(['unlock-keychain', '-p', password, keychain], 'ouverture du trousseau de signature dédié')
        run([SECURITY, 'set-keychain-settings', '-l', '-u', '-t', '300', str(keychain)])
        with tempfile.TemporaryDirectory(prefix='identity-', dir=directory) as temporary:
            scratch = Path(temporary)
            private_key, certificate, package = [scratch / name for name in ['key.pem', 'certificate.pem', 'identity.p12']]
            run([openssl, 'req', '-x509', '-newkey', 'rsa:3072', '-nodes', '-sha256',
                 '-days', '3650', '-subj', '/CN=Orbit Lab Local Development/O=Orbit Lab',
                 '-addext', 'basicConstraints=critical,CA:FALSE',
                 '-addext', 'keyUsage=critical,digitalSignature',
                 '-addext', 'extendedKeyUsage=critical,codeSigning',
                 '-keyout', str(private_key), '-out', str(certificate)], label='création du certificat local')
            private_key.chmod(0o600)
            run([openssl, 'pkcs12', '-export', '-inkey', str(private_key), '-in', str(certificate),
                 '-out', str(package), '-keypbe', 'PBE-SHA1-3DES', '-certpbe', 'PBE-SHA1-3DES',
                 '-macalg', 'sha1', '-passout', 'stdin'], secret_input=password + '\n', label='préparation de la clé locale')
            package.chmod(0o600)
            security(['import', package, '-k', keychain, '-f', 'pkcs12', '-P', password,
                      '-x', '-T', CODESIGN], 'import de la clé de signature dédiée')
            security(['set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-s',
                      '-k', password, keychain], 'accès codesign à sa clé dédiée')
            der = run([openssl, 'x509', '-in', str(certificate), '-outform', 'DER'])
            fingerprint = hashlib.sha1(der).hexdigest().upper()
            (directory / 'certificate.der').write_bytes(der)
            private_file(metadata_file, json.dumps({'version': 1, 'fingerprint': fingerprint,
                                                   'purpose': 'Orbit Lab local development signing'}) + '\n')
    finally:
        # create-keychain adds its file to the user search list. Remove only our
        # new entry, preserving all other entries, including concurrent changes.
        current = search_list()
        without_ours = [item for item in current if Path(item) != keychain]
        if current != without_ours:
            run([SECURITY, 'list-keychains', '-d', 'user', '-s', *without_ours])
        # No change is made to the default/login keychain or certificate trust.
    return keychain, password, fingerprint


# This sibling directory is shared by every worktree and does not interfere
# with identity()'s existing detection of partial signing configurations.
_signing_mutex = threading.RLock()
_signing_process = os.getpid()
_active_identity = None


def _open_signing_lock():
    directory = SIGNING_DIRECTORY.with_name('signing-coordination')
    if not directory.is_absolute() or '..' in directory.parts:
        raise RuntimeError('Signing coordination directory must be an absolute path.')
    # Walk using directory descriptors: neither the lock nor any path component
    # may redirect through a symlink. Never repair permissions on existing files.
    descriptor = os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        for component in directory.parts[1:]:
            try:
                os.mkdir(component, mode=0o700, dir_fd=descriptor)
            except FileExistsError:
                pass
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY |
                            os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
            info = os.fstat(descriptor)
            writable_by_others = stat.S_IMODE(info.st_mode) & 0o022
            trusted_temporary_parent = info.st_uid == 0 and info.st_mode & stat.S_ISVTX
            if (info.st_uid not in (0, os.getuid()) or
                    (writable_by_others and not trusted_temporary_parent)):
                raise RuntimeError('Signing coordination path has an unsafe parent directory.')
        info = os.fstat(descriptor)
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise RuntimeError('Signing coordination directory must be private and owned by this user.')
        lock = os.open('identity.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW |
                       os.O_CLOEXEC | os.O_NONBLOCK, 0o600, dir_fd=descriptor)
        try:
            info = os.fstat(lock)
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or
                    stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
                raise RuntimeError('Signing lock must be a private, singly linked regular file owned by this user.')
        except BaseException:
            os.close(lock)
            raise
        return lock
    finally:
        os.close(descriptor)


@contextmanager
def unlocked_identity():
    global _active_identity
    # A fork inside a signing transaction must not reuse the parent's unlocked
    # context or inherited mutex. Normal subprocess/exec callers are unaffected.
    if os.getpid() != _signing_process:
        raise RuntimeError('Signing after fork requires a fresh Python process.')
    with _signing_mutex:
        if _active_identity is not None:
            yield _active_identity
            return
        lock = _open_signing_lock()
        try:
            fcntl.flock(lock, fcntl.LOCK_EX)
            keychain, password, fingerprint = identity()
            security(['unlock-keychain', '-p', password, keychain], 'opening the local signing keychain')
            try:
                _active_identity = keychain, fingerprint
                yield _active_identity
            finally:
                _active_identity = None
                run([SECURITY, 'lock-keychain', str(keychain)], label='locking the local signing keychain')
        finally:
            # Closing releases flock even when identity/unlock/sign/relock fails.
            # Never unlink: waiters must continue locking the same inode.
            os.close(lock)


def sign_bundle(bundle):
    with unlocked_identity() as (keychain, fingerprint):
        run([CODESIGN, '--force', '--deep', '--sign', fingerprint, '--keychain', str(keychain),
             '--timestamp=none', str(bundle)], label='signature stable du bundle')
    run([CODESIGN, '--verify', '--deep', '--strict', str(bundle)], label='vérification du bundle signé')
    requirement = run([CODESIGN, '-d', '-r-', str(bundle)], include_stderr=True)
    expected_root = f'certificate root = H"{fingerprint}"'.encode().lower()
    if b'designated =>' not in requirement or b'cdhash' in requirement or expected_root not in requirement.lower():
        raise RuntimeError('La signature conserve une identité temporaire ; bundle refusé.')


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('--probe', action='store_true')
    arguments = parser.parse_args()
    if not arguments.probe:
        parser.error('Utiliser --probe pour vérifier deux versions synthétiques sans lancer d’application.')
    import plistlib
    with tempfile.TemporaryDirectory(prefix='orbit-signing-probe-') as temporary:
        bundle = Path(temporary) / 'Signing Probe.app'
        executable = bundle / 'Contents/MacOS/Probe'
        resources = bundle / 'Contents/Resources'
        executable.parent.mkdir(parents=True)
        resources.mkdir()
        shutil.copyfile('/usr/bin/true', executable)
        executable.chmod(0o755)
        (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'dev.orbit.signing-probe', 'CFBundleExecutable': 'Probe',
            'CFBundleName': 'Orbit Lab Signing Probe', 'CFBundleVersion': '1'}))
        requirements = []
        for revision in ['one', 'two']:
            (resources / 'revision.txt').write_text(revision)
            sign_bundle(bundle)
            result = subprocess.run([CODESIGN, '-d', '-r-', str(bundle)], capture_output=True, check=True)
            requirements.append(next(line for line in (result.stdout + result.stderr).decode().splitlines()
                                     if 'designated =>' in line))
        if requirements[0] != requirements[1] or 'cdhash' in requirements[0]:
            raise RuntimeError('Identité instable entre deux versions synthétiques.')
        print('Signature locale : deux versions différentes, même identité certifiée, vérifications réussies.')


@contextmanager
def configured_identity(name='local'):
    """Use the existing local identity or a configured Developer ID; never generate a key."""
    if not name or name == 'local':
        if not (SIGNING_DIRECTORY / 'identity.json').is_file():
            raise RuntimeError('Existing stable local signing identity required')
        with unlocked_identity() as (keychain, fingerprint):
            yield ['--sign', fingerprint, '--keychain', str(keychain), '--timestamp=none']
    else:
        # codesign can misinterpret non-ASCII certificate names in a C locale. Resolve the
        # configured common name to its exact public fingerprint before passing it to codesign.
        listing = run([SECURITY, 'find-identity', '-v', '-p', 'codesigning'], label='Developer ID lookup').decode('utf-8')
        matches = [fingerprint for fingerprint, common_name in re.findall(r'([A-F0-9]{40}) \"([^\"]+)\"', listing)
                   if common_name == name or fingerprint == name]
        if len(matches) != 1:
            raise RuntimeError('Configured signing identity is missing or ambiguous')
        yield ['--sign', matches[0], '--timestamp']


def sign_chromium_bundle(bundle, identity_name='local', main_entitlements=None):
    """Sign nested Mach-O code, Sparkle services, helpers, frameworks, then the host."""
    import plistlib
    bundle = Path(bundle)
    if main_entitlements and identity_name == 'local':
        raise ValueError('Local test signatures cannot claim iCloud capabilities')
    with configured_identity(identity_name) as signing, tempfile.TemporaryDirectory(prefix='orbit-entitlements-') as temporary:
        entitlements = Path(temporary) / 'chromium.plist'
        entitlements.write_bytes(plistlib.dumps({
            'com.apple.security.cs.allow-jit': True,
            'com.apple.security.cs.allow-unsigned-executable-memory': True,
            'com.apple.security.cs.disable-library-validation': True,
        }))
        host_entitlements = Path(temporary) / 'host.plist'
        host_values = plistlib.loads(entitlements.read_bytes())
        host_values.update(main_entitlements or {})
        host_entitlements.write_bytes(plistlib.dumps(host_values))
        def sign_one(path, chromium=False, preserve=False):
            arguments = [CODESIGN, '--force', *signing, '--options', 'runtime']
            if chromium:
                arguments += ['--entitlements', str(host_entitlements if path == bundle else entitlements)]
            elif preserve:
                arguments += ['--preserve-metadata=entitlements']
            run([*arguments, str(path)], label='nested code signing', timeout=120)
        frameworks = bundle / 'Contents/Frameworks'
        # rglob does not descend symlink directories. All version links stay inside the bundle.
        for entry in sorted(frameworks.rglob('*'), key=lambda p: len(p.parts), reverse=True):
            if entry.is_symlink():
                continue
            if entry.is_file():
                with entry.open('rb') as handle:
                    magic = handle.read(4)
                if magic in (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'):
                    sign_one(entry, chromium='Helper' in str(entry),
                             preserve='Downloader.xpc' in str(entry))
        for entry in sorted(frameworks.rglob('*'), key=lambda p: len(p.parts), reverse=True):
            if not entry.is_symlink() and entry.is_dir() and entry.suffix in {'.app', '.xpc', '.framework'}:
                sign_one(entry, chromium='Helper' in entry.name, preserve=entry.name == 'Downloader.xpc')
        sign_one(bundle, chromium=True)
    run([CODESIGN, '--verify', '--deep', '--strict', str(bundle)], label='bundle signature verification')
