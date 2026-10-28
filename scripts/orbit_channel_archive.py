"""Explicit, reversible channel-backup archival; defaults to a read-only plan.

No registry reset, process termination, permission changes or bundle edits.
Callers must coordinate with publishers before applying a reviewed plan.
"""
import argparse
import ctypes
import json
import hashlib
import stat
import uuid
from contextlib import contextmanager, ExitStack
import os
from pathlib import Path
import plistlib
import re
import subprocess

LSREGISTER = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
IDENTITIES = {'daily': 'io.github.okatech.orbit.test.orbit', 'live': 'io.github.okatech.orbit.test.orbit.live'}


def safe_path(path):
    path = Path(path).expanduser().absolute()
    if '..' in path.parts:
        raise RuntimeError('Parent traversal refused')
    if any(part.is_symlink() for part in (path, *path.parents)):
        raise RuntimeError('Symbolic path refused')
    return path


def running(path):
    # Read only command paths; never expose the process listing in reports.
    rows = subprocess.run(['/bin/ps', '-Ao', 'command='], check=True,
                          capture_output=True, text=True).stdout
    return str(path) + '/Contents/' in rows


def identity(path, channel):
    safe_path(path)
    with directory(path) as root:
        if os.fstat(root).st_uid != os.getuid():
            raise RuntimeError('Bundle is not owned by this user')
        contents = os.open('Contents', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=root)
        try:
            fd = os.open('Info.plist', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=contents)
            with os.fdopen(fd, 'rb') as handle:
                if not stat.S_ISREG(os.fstat(handle.fileno()).st_mode):
                    raise RuntimeError('Bundle plist must be a regular file')
                info = plistlib.load(handle)
        finally:
            os.close(contents)
    if info.get('CFBundleIdentifier') != IDENTITIES[channel]:
        raise RuntimeError('Unrelated bundle identity refused')
    if running(path):
        raise RuntimeError('Running host or helper refused')


@contextmanager
def directory(path):
    """Open each ancestor without following links, retaining the final directory."""
    path = safe_path(path)
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for name in path.parts[1:]:
            child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
        yield fd
    finally:
        os.close(fd)


def outside_bundles(path):
    # Cover app, framework, plug-in and retained/extensionless bundle layouts.
    suffixes = {'.app', '.framework', '.xpc', '.appex', '.bundle', '.plugin',
                '.prefpane', '.qlgenerator', '.saver', '.mdimporter', '.service',
                '.kext', '.component', '.vst', '.vst3'}
    markers = ('Contents/Info.plist', 'Resources/Info.plist', 'Info.plist',
               '_CodeSignature', 'Contents/_CodeSignature', 'Resources/_CodeSignature')
    for parent in Path(path).parents:
        if parent.suffix.lower() in suffixes or any(os.path.lexists(parent / marker) for marker in markers):
            raise RuntimeError('Operation inside an enclosing bundle refused')


def snapshot_at(parent_fd, name):
    """Hash regular bytes and link text; never traverse bundle symlinks."""
    root = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)
    digest = hashlib.sha256()
    def visit(fd):
        for entry in sorted(os.listdir(fd)):
            before = os.stat(entry, dir_fd=fd, follow_symlinks=False)
            digest.update(json.dumps([entry, before.st_mode, before.st_uid, before.st_gid]).encode())
            if stat.S_ISLNK(before.st_mode):
                digest.update(json.dumps(['link', os.readlink(entry, dir_fd=fd)]).encode())
            elif stat.S_ISDIR(before.st_mode):
                child = os.open(entry, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                try:
                    if os.fstat(child).st_ino != before.st_ino:
                        raise RuntimeError('Directory changed during inventory')
                    digest.update(b'directory-start')
                    visit(child)
                    digest.update(b'directory-end')
                finally:
                    os.close(child)
            elif stat.S_ISREG(before.st_mode):
                child = os.open(entry, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
                try:
                    opened = os.fstat(child)
                    if (opened.st_dev, opened.st_ino, opened.st_mode) != (before.st_dev, before.st_ino, before.st_mode):
                        raise RuntimeError('File changed during inventory')
                    content = hashlib.sha256()
                    while True:
                        data = os.read(child, 1024 * 1024)
                        if not data:
                            break
                        content.update(data)
                    digest.update(json.dumps(['file', opened.st_size, content.hexdigest()]).encode())
                    after = os.fstat(child)
                    if (after.st_size, after.st_mtime_ns, after.st_ctime_ns) != (opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns):
                        raise RuntimeError('File changed during inventory')
                finally:
                    os.close(child)
            else:
                raise RuntimeError('Special bundle object refused')
            after = os.stat(entry, dir_fd=fd, follow_symlinks=False)
            if (before.st_ino, before.st_mtime_ns, before.st_ctime_ns) != (after.st_ino, after.st_mtime_ns, after.st_ctime_ns):
                raise RuntimeError('Bundle changed during inventory')
    try:
        info = os.fstat(root)
        visit(root)
        after = os.fstat(root)
        if (info.st_mtime_ns, info.st_ctime_ns) != (after.st_mtime_ns, after.st_ctime_ns):
            raise RuntimeError('Bundle root changed during inventory')
        return {'device': info.st_dev, 'inode': info.st_ino, 'mode': info.st_mode,
                'uid': info.st_uid, 'gid': info.st_gid, 'sha256': digest.hexdigest()}
    finally:
        os.close(root)


def snapshot(path):
    with directory(path.parent) as fd:
        return snapshot_at(fd, path.name)


def parent_identity(fd):
    value = os.fstat(fd)
    if value.st_uid != os.getuid():
        raise RuntimeError('Operation parent is not owned by this user')
    return {'device': value.st_dev, 'inode': value.st_ino, 'uid': value.st_uid, 'mode': value.st_mode}


def unique_json_object(pairs):
    """Reject ambiguous objects before any member can overwrite another."""
    result = {}
    for key, value in pairs:
        if key in result:
            # Do not expose document keys or values in diagnostics.
            raise RuntimeError('Duplicate JSON member refused')
        result[key] = value
    return result


def read_json(path):
    path = safe_path(path)
    with directory(path.parent) as fd:
        handle = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
        with os.fdopen(handle) as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                raise RuntimeError('JSON input must be a regular file')
            return json.load(stream, object_pairs_hook=unique_json_object)


def supported(source, channel):
    allowed = channel == 'live' and re.fullmatch(r'\.Orbit Live-\d{8}T\d{12}Z\.app', source.name)
    allowed = allowed or (channel == 'daily' and source.name == 'Orbit.app' and source.parent.name == '.Trash')
    if not allowed:
        raise RuntimeError('Not an explicitly supported historical channel backup')


def metadata_references(source, archive, metadata):
    references = []
    path_keys = {'previous', 'source', 'archive', 'destination', 'bundle', 'bundlePath',
                 'app', 'appPath', 'path', 'executable', 'executablePath'}
    def visit(value, pointer, file, key=None):
        if isinstance(value, dict):
            for child_key, child in value.items():
                visit(child, pointer + '/' + child_key.replace('~', '~0').replace('/', '~1'), file, child_key)
        elif isinstance(value, list):
            for index, child in enumerate(value):
                visit(child, pointer + '/' + str(index), file, key)
        elif isinstance(value, str):
            if value == str(archive) or value.startswith(str(archive) + '/'):
                return
            if value == str(source) or value.startswith(str(source) + '/'):
                if key not in path_keys:
                    raise RuntimeError('Unknown runtime metadata reference requires explicit classification')
                references.append({'file': str(file), 'pointer': pointer, 'replace': value,
                                   'with': str(archive) + value[len(str(source)):]})
    for item in metadata:
        item = safe_path(item)
        # Only supplied operational JSON is accepted. Historical prose stays immutable.
        if item.suffix != '.json':
            raise RuntimeError('Only classified operational JSON metadata is supported')
        visit(read_json(item), '', item)
    return references


def plan(source, channel, metadata=()):
    source = safe_path(source)
    supported(source, channel)
    identity(source, channel)
    archive = safe_path(source.with_name(source.name + '.retained.noindex'))
    if os.path.lexists(archive):
        raise RuntimeError('Archive collision refused')
    with directory(source.parent) as fd:
        parent = parent_identity(fd)
    return {'version': 2, 'parent': parent, 'channel': channel, 'source': str(source), 'archive': str(archive),
            'object': snapshot(source), 'metadata': [str(safe_path(item)) for item in metadata],
            'metadataMigrationRequired': metadata_references(source, archive, metadata),
            'rollback': {'source': str(archive), 'destination': str(source)}, 'status': 'planned'}


def validate_journal(journal, source):
    journal = safe_path(journal)
    outside_bundles(journal)
    outside_bundles(source)
    if journal.parent != source.parent or journal.suffix != '.json':
        raise RuntimeError('Journal must be a sibling JSON file outside the bundle')


def write_record(path, record, parent_fd=None):
    path = safe_path(path)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
    fd = os.open(path.name if parent_fd is not None else path, flags, 0o600, dir_fd=parent_fd)
    with os.fdopen(fd, 'w') as handle:
        json.dump(record, handle, indent=2)
        handle.write('\n')
        handle.flush()
        os.fsync(handle.fileno())
    if parent_fd is not None:
        os.fsync(parent_fd)


def rename_exclusive(source, destination, source_fd=-2, destination_fd=-2):
    library = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
    if library.renameatx_np(source_fd, os.fsencode(source), destination_fd, os.fsencode(destination), 4):
        raise OSError(ctypes.get_errno(), 'Exclusive archive rename failed')


def ensure_object(fd, name, expected):
    if snapshot_at(fd, name) != expected:
        raise RuntimeError('Reviewed filesystem object changed')


def entry_identity(fd, name):
    value = os.stat(name, dir_fd=fd, follow_symlinks=False)
    return (value.st_dev, value.st_ino, value.st_mode, value.st_uid, value.st_gid)


def restore_entry(stage_fd, origin_fd, name):
    """Restore the staged entry itself, then validate its no-follow identity."""
    before = entry_identity(stage_fd, 'bundle')
    rename_exclusive('bundle', name, stage_fd, origin_fd)
    if entry_identity(origin_fd, name) != before:
        raise RuntimeError('Restored entry changed; manual reconciliation required')
    os.fsync(stage_fd)
    os.fsync(origin_fd)


def transfer(record, origin, destination, journal, status, unregister=False):
    validate_journal(journal, Path(record['source']))
    expected = record.get('object')
    if record.get('version') != 2 or not expected:
        raise RuntimeError('A version 2 object-bound intent is required')
    parent = destination.parent
    if origin.parent != parent and not (origin.name == 'bundle' and origin.parent.parent == parent
            and re.fullmatch(r'\.orbit-archive-stage-[0-9a-f]{32}\.noindex', origin.parent.name)):
        raise RuntimeError('Transfer must stay in the reviewed parent or its private stage')
    with ExitStack() as stack:
        fd = stack.enter_context(directory(parent))
        origin_fd = stack.enter_context(directory(origin.parent))
        if parent_identity(fd) != record.get('parent'):
            raise RuntimeError('Reviewed parent changed')
        if os.path.lexists(destination):
            raise RuntimeError('Transfer destination collision refused')
        ensure_object(origin_fd, origin.name, expected)
        stage_name = '.orbit-archive-stage-' + uuid.uuid4().hex + '.noindex'
        intent = {**record, 'status': status, 'staging': str(parent / stage_name),
                  'transferSource': str(origin), 'transferDestination': str(destination)}
        write_record(journal, intent, fd)
        if unregister:
            subprocess.run([LSREGISTER, '-u', str(origin)], check=True, capture_output=True)
        identity(origin, record['channel'])
        ensure_object(origin_fd, origin.name, expected)
        # Anchor all subsequent writes/moves to this parent; a substituted ancestor
        # cannot redirect the operations. No compare-inode rename API is available.
        with directory(parent) as visible:
            if (os.fstat(visible).st_dev, os.fstat(visible).st_ino) != (os.fstat(fd).st_dev, os.fstat(fd).st_ino):
                raise RuntimeError('Parent changed before transfer')
        with directory(origin.parent) as visible:
            if (os.fstat(visible).st_dev, os.fstat(visible).st_ino) != (os.fstat(origin_fd).st_dev, os.fstat(origin_fd).st_ino):
                raise RuntimeError('Origin parent changed before transfer')
        os.mkdir(stage_name, mode=0o700, dir_fd=fd)
        stage_fd = os.open(stage_name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
        try:
            rename_exclusive(origin.name, 'bundle', origin_fd, stage_fd)
            try:
                ensure_object(stage_fd, 'bundle', expected)
            except (RuntimeError, OSError) as error:
                # Restore exactly the staged entry, without following it. Collision
                # leaves both objects and the immutable intent for reconciliation.
                try:
                    restore_entry(stage_fd, origin_fd, origin.name)
                except OSError as restore_error:
                    raise RuntimeError('Staged mismatch; restoration collided; inspect immutable intent') from restore_error
                raise RuntimeError('Staged mismatch restored to original slot') from error
            rename_exclusive('bundle', destination.name, stage_fd, fd)
            ensure_object(fd, destination.name, expected)
            os.fsync(stage_fd)
            os.fsync(fd)
        finally:
            os.close(stage_fd)
    return {**intent, 'status': 'archived' if unregister else 'restored-unregistered', 'journal': str(journal)}


def apply(record, journal):
    current = plan(record['source'], record['channel'], record.get('metadata', ()))
    if (current['archive'] != record['archive'] or current['object'] != record.get('object')
            or current['parent'] != record.get('parent')
            or current['metadataMigrationRequired'] or record['metadataMigrationRequired']):
        raise RuntimeError('Resolve object or publisher metadata migration before archival')
    return transfer(current, Path(current['source']), Path(current['archive']), journal, 'planned', True)


def rollback(record, journal):
    source, archive = safe_path(record['source']), safe_path(record['archive'])
    supported(source, record['channel'])
    if os.path.lexists(source):
        raise RuntimeError('Rollback source collision refused')
    if archive != source.with_name(source.name + '.retained.noindex'):
        raise RuntimeError('Rollback mapping mismatch')
    return transfer(record, archive, source, journal, 'rollback-intent')


def inspect_intent(record):
    """Read-only reconciliation; ambiguous states are never automatically repaired."""
    source, archive = safe_path(record['source']), safe_path(record['archive'])
    supported(source, record['channel'])
    if archive != source.with_name(source.name + '.retained.noindex'):
        raise RuntimeError('Intent mapping mismatch')
    paths = {'source': source, 'archive': archive}
    if record.get('staging'):
        stage = safe_path(record['staging'])
        if stage.parent != source.parent or not re.fullmatch(r'\.orbit-archive-stage-[0-9a-f]{32}\.noindex', stage.name):
            raise RuntimeError('Invalid staging mapping')
        paths['staged'] = stage / 'bundle'
    result = {}
    for key, path in paths.items():
        outside_bundles(path if key != 'staged' else path.parent)
        if not os.path.lexists(path):
            result[key] = 'absent'
        else:
            try:
                result[key] = 'verified' if snapshot(path) == record['object'] else 'mismatch'
            except (OSError, RuntimeError):
                result[key] = 'unsafe'
    return {'states': result, 'automaticRecovery': False}


def recover_staged(record, journal):
    """Explicitly restore only a sole verified staged object, using a new intent."""
    states = inspect_intent(record)['states']
    if states != {'source': 'absent', 'archive': 'absent', 'staged': 'verified'}:
        raise RuntimeError('Ambiguous recovery state; preserve all objects for review')
    return transfer(record, Path(record['staging']) / 'bundle', Path(record['source']),
                    journal, 'staged-recovery-intent')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inspect-intent', type=Path, help='Read-only reconciliation of an intent')
    parser.add_argument('--recover-staged', type=Path, help='Explicit restoration of a sole verified staged object')
    parser.add_argument('--plan-file', type=Path, help='Saved reviewed version 2 plan, required for --apply')
    parser.add_argument('--source', type=Path)
    parser.add_argument('--channel', choices=IDENTITIES)
    parser.add_argument('--metadata', type=Path, action='append', default=[])
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--rollback', type=Path, help='Original archive intent journal')
    parser.add_argument('--journal', type=Path)
    args = parser.parse_args()
    if args.inspect_intent or args.recover_staged:
        if args.rollback or args.apply or args.source or args.plan_file or (args.inspect_intent and args.recover_staged):
            parser.error('Choose a single intent operation')
        if args.recover_staged and not args.journal:
            parser.error('--recover-staged requires a new --journal')
        record = read_json(args.inspect_intent or args.recover_staged)
        result = inspect_intent(record) if args.inspect_intent else recover_staged(record, args.journal)
    elif args.rollback:
        if not args.journal or args.apply or args.source or args.plan_file:
            parser.error('rollback requires a new --journal and no --apply/--source')
        result = rollback(read_json(args.rollback), args.journal)
    elif args.apply:
        if not args.plan_file or not args.journal or args.source or args.channel or args.metadata:
            parser.error('--apply requires --plan-file and a new --journal; no new source or metadata')
        result = apply(read_json(args.plan_file), args.journal)
    else:
        if not args.source or not args.channel or args.plan_file:
            parser.error('Read-only planning requires --source and --channel')
        result = plan(args.source, args.channel, args.metadata)
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
