#!/usr/bin/env python3
"""Register only the installed Orbit Lab bundle; never select a default app.

The CLI and installer share this helper. Public Launch Services queries are
filtered to Orbit Lab before reporting; other handler IDs remain private.
"""
import argparse
import ctypes
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys

BUNDLE_ID = 'dev.orbit.experiment'
INSTALLED = Path.home() / 'Applications' / 'Orbit Lab.app'
LSREGISTER = Path('/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister')


class RegistrationError(RuntimeError):
    pass


def run(arguments, label, timeout=60):
    try:
        result = subprocess.run([str(value) for value in arguments], capture_output=True,
                                text=True, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise RegistrationError(label + ' : commande indisponible ou délai dépassé.') from error
    if result.returncode:
        raise RegistrationError(label + f' : échec (code {result.returncode}).')
    return result.stdout + '\n' + result.stderr


def validate_installed_signature():
    for component in [*reversed(INSTALLED.parents), INSTALLED]:
        if component.is_symlink():
            raise RegistrationError('Un chemin symbolique inattendu est refusé.')
    info_path = INSTALLED / 'Contents' / 'Info.plist'
    for component in [INSTALLED / 'Contents', info_path]:
        if component.is_symlink():
            raise RegistrationError('Métadonnées symboliques refusées.')
    try:
        info = plistlib.loads(info_path.read_bytes())
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        raise RegistrationError('Le bundle installé est indisponible ou son plist est invalide.') from error
    if not isinstance(info, dict) or info.get('CFBundleIdentifier') != BUNDLE_ID or info.get('CFBundlePackageType') != 'APPL':
        raise RegistrationError('Seule la copie installée de dev.orbit.experiment peut être enregistrée.')
    schemes = {scheme for entry in info.get('CFBundleURLTypes', [])
               if isinstance(entry, dict) and entry.get('CFBundleTypeRole') in ('Viewer', 'Editor')
               for scheme in entry.get('CFBundleURLSchemes', [])}
    if not {'http', 'https'} <= schemes:
        raise RegistrationError('Les déclarations HTTP/HTTPS sont absentes.')
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', INSTALLED], 'Vérification de la signature')
    public = run(['/usr/bin/codesign', '--display', '--verbose=4', '--requirements', '-', INSTALLED], 'Lecture de la signature publique')
    requirements = re.findall(r'^designated => (.+)$', public, re.MULTILINE)
    identifiers = re.findall(r'^Identifier=(.+)$', public, re.MULTILINE)
    hashes = tuple(re.findall(r'^CDHash=([0-9a-fA-F]+)$', public, re.MULTILINE))
    if len(requirements) != 1 or identifiers != [BUNDLE_ID] or not hashes or 'cdhash' in requirements[0].lower() or 'certificate' not in requirements[0]:
        raise RegistrationError('Une identité signée persistante est nécessaire.')
    return requirements[0].strip(), hashes


class LaunchServices:
    """Small read/register bridge to public CoreServices and CoreFoundation."""
    def __init__(self):
        pointer = ctypes.c_void_p
        try:
            self.cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
            self.ls = ctypes.CDLL('/System/Library/Frameworks/CoreServices.framework/CoreServices')
            self.cf.CFStringCreateWithCString.argtypes = [pointer, ctypes.c_char_p, ctypes.c_uint32]
            self.cf.CFStringCreateWithCString.restype = pointer
            self.cf.CFStringGetCString.argtypes = [pointer, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
            self.cf.CFStringGetCString.restype = ctypes.c_bool
            self.cf.CFArrayGetCount.argtypes = [pointer]
            self.cf.CFArrayGetCount.restype = ctypes.c_long
            self.cf.CFArrayGetValueAtIndex.argtypes = [pointer, ctypes.c_long]
            self.cf.CFArrayGetValueAtIndex.restype = pointer
            self.cf.CFRelease.argtypes = [pointer]
            self.cf.CFURLCopyFileSystemPath.argtypes = [pointer, ctypes.c_int]
            self.cf.CFURLCopyFileSystemPath.restype = pointer
            self.cf.CFURLCreateWithFileSystemPath.argtypes = [pointer, pointer, ctypes.c_int, ctypes.c_ubyte]
            self.cf.CFURLCreateWithFileSystemPath.restype = pointer
            self.ls.LSCopyAllHandlersForURLScheme.argtypes = [pointer]
            self.ls.LSCopyAllHandlersForURLScheme.restype = pointer
            self.ls.LSCopyDefaultHandlerForURLScheme.argtypes = [pointer]
            self.ls.LSCopyDefaultHandlerForURLScheme.restype = pointer
            self.ls.LSCopyApplicationURLsForBundleIdentifier.argtypes = [pointer, ctypes.POINTER(pointer)]
            self.ls.LSCopyApplicationURLsForBundleIdentifier.restype = pointer
            self.ls.LSRegisterURL.argtypes = [pointer, ctypes.c_ubyte]
            self.ls.LSRegisterURL.restype = ctypes.c_int32
        except (OSError, AttributeError) as error:
            raise RegistrationError('Les API Launch Services nécessaires sont indisponibles.') from error

    def string(self, text):
        result = self.cf.CFStringCreateWithCString(None, text.encode('utf-8'), 0x08000100)
        if not result:
            raise RegistrationError('Chaîne Launch Services indisponible.')
        return result

    def text(self, value):
        if not value:
            return None
        buffer = ctypes.create_string_buffer(32768)
        if not self.cf.CFStringGetCString(value, buffer, len(buffer), 0x08000100):
            raise RegistrationError('Réponse Launch Services trop longue.')
        return buffer.value.decode('utf-8')

    def scheme(self, scheme):
        key = self.string(scheme)
        try:
            handlers = self.ls.LSCopyAllHandlersForURLScheme(key)
            default = self.ls.LSCopyDefaultHandlerForURLScheme(key)
        finally:
            self.cf.CFRelease(key)
        try:
            own = sum(self.text(self.cf.CFArrayGetValueAtIndex(handlers, index)) == BUNDLE_ID
                      for index in range(self.cf.CFArrayGetCount(handlers))) if handlers else 0
            return own, self.text(default)
        finally:
            if handlers:
                self.cf.CFRelease(handlers)
            if default:
                self.cf.CFRelease(default)

    def own_paths(self):
        key = self.string(BUNDLE_ID)
        error = ctypes.c_void_p()
        try:
            urls = self.ls.LSCopyApplicationURLsForBundleIdentifier(key, ctypes.byref(error))
        finally:
            self.cf.CFRelease(key)
        paths = []
        try:
            for index in range(self.cf.CFArrayGetCount(urls) if urls else 0):
                value = self.cf.CFURLCopyFileSystemPath(self.cf.CFArrayGetValueAtIndex(urls, index), 0)
                try:
                    text = self.text(value)
                    if text:
                        paths.append(Path(text))
                finally:
                    if value:
                        self.cf.CFRelease(value)
        finally:
            if urls:
                self.cf.CFRelease(urls)
            if error:
                self.cf.CFRelease(error)
        return paths

    def snapshot(self):
        claims, defaults = {}, []
        for scheme in ('http', 'https'):
            own, default = self.scheme(scheme)
            claims[scheme] = own
            defaults.append(default)
        own_paths = self.own_paths()
        return {'claims': claims, 'ownRegisteredPaths': len(own_paths),
                'installedPathClaims': sum(value.resolve() == INSTALLED.resolve() for value in own_paths),
                '_defaults': tuple(defaults)}

    def register(self):
        key = self.string(str(INSTALLED))
        try:
            url = self.cf.CFURLCreateWithFileSystemPath(None, key, 0, 1)
        finally:
            self.cf.CFRelease(key)
        if not url:
            raise RegistrationError('URL du bundle installé indisponible.')
        try:
            status = self.ls.LSRegisterURL(url, 1)
        finally:
            self.cf.CFRelease(url)
        if status:
            raise RegistrationError(f'LSRegisterURL a refusé ce bundle (code {status}).')


def public_snapshot(value):
    return {key: item for key, item in value.items() if not key.startswith('_')}


def register_installed(*, dry_run=False, api=None, verify=None, runner=None):
    if sys.platform != 'darwin':
        raise RegistrationError('L’enregistrement est réservé à macOS.')
    verify = verify or validate_installed_signature
    signature = verify()
    api = api or LaunchServices()
    before = api.snapshot()
    if dry_run:
        return {'mode': 'read-only', 'catalogue': public_snapshot(before), 'signatureValid': True}
    if LSREGISTER.is_file() and os.access(LSREGISTER, os.X_OK):
        (runner or run)([str(LSREGISTER), '-f', str(INSTALLED)], 'Enregistrement ciblé Launch Services')
        method = 'lsregister -f exact-installed-path'
    else:
        api.register()
        method = 'LSRegisterURL exact-installed-path (fallback)'
    if verify() != signature:
        raise RegistrationError('La signature ou le contenu signé a changé pendant l’enregistrement.')
    after = api.snapshot()
    if before['_defaults'] != after['_defaults']:
        raise RegistrationError('Le choix système a changé pendant le contrôle ; ce script ne définit aucun navigateur par défaut.')
    if after['installedPathClaims'] < 1 or any(after['claims'][scheme] < 1 for scheme in ('http', 'https')):
        raise RegistrationError('La copie installée n’est pas confirmée comme candidate HTTP/HTTPS dans le catalogue.')
    return {'mode': 'registered', 'method': method, 'before': public_snapshot(before),
            'after': public_snapshot(after), 'signatureUnchanged': True,
            'defaultChoiceUnchanged': True, 'settingsMenuVisibilityVerified': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dry-run', action='store_true', help='vérifier signature/catalogue sans modifier Launch Services')
    arguments = parser.parse_args()
    try:
        print(json.dumps(register_installed(dry_run=arguments.dry_run), ensure_ascii=False, indent=2))
    except (RegistrationError, OSError) as error:
        print('Enregistrement refusé : ' + str(error), file=sys.stderr)
        sys.exit(1)
