"""Install release credentials only in an ephemeral GitHub-hosted runner keychain."""
import argparse
import base64
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess

from local_signing import identity, search_list, security

ROOT = Path(__file__).resolve().parents[1]
REQUIRED = ('CIRCA_SIGNING_CERTIFICATE', 'CIRCA_SIGNING_PASSWORD',
            'CIRCA_PROVISIONING_PROFILE', 'CIRCA_SPARKLE_PRIVATE_KEY',
            'CIRCA_NOTARY_CREDENTIALS')


def private_file(path, data):
    with path.open('xb') as stream:
        os.chmod(path, 0o600)
        stream.write(data)


def checked(arguments, *, data=None):
    result = subprocess.run(arguments, input=data, capture_output=True, timeout=180)
    if result.returncode:
        raise RuntimeError('CI credential command failed: ' + Path(arguments[0]).name)


def prepare(directory):
    missing = [name for name in REQUIRED if not os.environ.get(name)]
    if missing:
        raise RuntimeError('Missing repository secrets: ' + ', '.join(missing))
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    keychain = directory / 'release.keychain-db'
    password = secrets.token_urlsafe(48)
    private_file(directory / 'original-keychains.json', json.dumps(search_list()).encode())
    private_file(directory / 'keychain-password', password.encode())
    private_file(directory / 'identity.p12', base64.b64decode(os.environ['CIRCA_SIGNING_CERTIFICATE'], validate=True))
    private_file(directory / 'profile.provisionprofile', base64.b64decode(os.environ['CIRCA_PROVISIONING_PROFILE'], validate=True))
    private_file(directory / 'sparkle-key', os.environ['CIRCA_SPARKLE_PRIVATE_KEY'].encode())
    security(['create-keychain', '-p', password, keychain], 'CI keychain creation')
    security(['list-keychains', '-d', 'user', '-s', keychain,
              *json.loads((directory / 'original-keychains.json').read_text())], 'CI keychain search path')
    security(['set-keychain-settings', '-lut', '21600', keychain], 'CI keychain timeout')
    security(['unlock-keychain', '-p', password, keychain], 'CI keychain unlock')
    security(['import', directory / 'identity.p12', '-k', keychain, '-f', 'pkcs12',
              '-P', os.environ['CIRCA_SIGNING_PASSWORD'], '-T', '/usr/bin/codesign'], 'CI certificate import')
    # This ACL belongs only to the newly created runner keychain, never a user's keychain.
    security(['set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-s',
              '-k', password, keychain], 'CI key access')
    credentials = json.loads(os.environ['CIRCA_NOTARY_CREDENTIALS'])
    command = ['xcrun', 'notarytool', 'store-credentials', 'orbit-notary', '--keychain', str(keychain)]
    if 'key_base64' in credentials:
        private_file(directory / 'notary.p8', base64.b64decode(credentials['key_base64'], validate=True))
        command += ['--key', str(directory / 'notary.p8'), '--key-id', credentials['key_id']]
        if credentials.get('issuer'):
            command += ['--issuer', credentials['issuer']]
        checked(command)
    else:
        command += ['--apple-id', credentials['apple_id'], '--team-id', credentials['team_id']]
        checked(command, data=(credentials['password'] + '\n').encode())
    config = json.loads((ROOT / 'release/config.json').read_text())
    config['provisioning_profile'] = str(directory / 'profile.provisionprofile')
    private_file(directory / 'config.json', (json.dumps(config, indent=2) + '\n').encode())
    # This separate disposable identity is needed for the product build's development admission.
    identity()
    with Path(os.environ['GITHUB_ENV']).open('a') as output:
        output.write('ORBIT_ED_KEY_FILE=' + str(directory / 'sparkle-key') + '\n')
        output.write('CIRCA_RELEASE_CONFIG=' + str(directory / 'config.json') + '\n')
    (directory / 'identity.p12').unlink()
    print('Release credentials configured in an ephemeral keychain.')


def cleanup(directory):
    original = directory / 'original-keychains.json'
    if original.is_file():
        paths = json.loads(original.read_text())
        checked(['security', 'list-keychains', '-d', 'user', '-s', *paths])
    for keychain in [directory / 'release.keychain-db', *Path(os.environ['ORBIT_SIGNING_DIRECTORY']).glob('*-signing.keychain-db')]:
        if keychain.exists():
            checked(['security', 'delete-keychain', str(keychain)])
    shutil.rmtree(directory, ignore_errors=True)
    shutil.rmtree(os.environ['ORBIT_SIGNING_DIRECTORY'], ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cleanup', action='store_true')
    args = parser.parse_args()
    if os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted':
        raise RuntimeError('Credential setup is restricted to ephemeral GitHub-hosted runners')
    directory = Path(os.environ['RUNNER_TEMP']).resolve() / 'circa-release-signing'
    if args.cleanup:
        cleanup(directory)
    else:
        prepare(directory)


if __name__ == '__main__':
    main()
