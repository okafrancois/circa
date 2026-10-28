"""Fetch the pinned official Sparkle binary distribution without touching the Keychain."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def ensure_sparkle(config):
    destination = ROOT / '.tools' / ('sparkle-' + config['sparkle_version'])
    if (destination / '.verified-sha256').is_file() and (
            destination / '.verified-sha256').read_text().strip() == config['sparkle_sha256']:
        return destination
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination.parent) as temporary:
        archive = Path(temporary) / 'Sparkle.tar.xz'
        url = ('https://github.com/sparkle-project/Sparkle/releases/download/' +
               config['sparkle_version'] + '/Sparkle-' + config['sparkle_version'] + '.tar.xz')
        urllib.request.urlretrieve(url, archive)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != config['sparkle_sha256']:
            raise RuntimeError('Sparkle distribution checksum mismatch')
        destination.mkdir(exist_ok=True)
        subprocess.run(['tar', '-xf', str(archive), '-C', str(destination)], check=True)
    (destination / '.verified-sha256').write_text(config['sparkle_sha256'] + '\n')
    return destination


if __name__ == '__main__':
    print(ensure_sparkle(json.loads((ROOT / 'release/config.json').read_text())))
