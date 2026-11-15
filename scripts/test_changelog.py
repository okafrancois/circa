"""Offline format, publishing renderer, media and generated-site regressions."""
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).parent))
import changelog
import release_notes as notes

FIXTURES = Path(__file__).parent / 'fixtures/release-notes'
SOURCE = (FIXTURES / '1.2.3.md').read_text()


class FormatTests(unittest.TestCase):
    def test_format_and_markdown_rendering(self):
        note = notes.parse(SOURCE, '1.2.3')
        self.assertEqual(note.date, '2026-11-15')
        self.assertEqual(note.counts, '1 new · 1 faster · 1 fixed')
        body = notes.github_body(note)
        self.assertTrue(body.startswith('A user-facing change.\n\n1 new'))
        self.assertNotIn('date:', body)
        self.assertTrue(body.endswith('Engine / bundled components: Chromium 158.0.8127.37; Example component 2\n'))
        html = changelog.article(note)
        for expected in ('<strong>new feature</strong>', '<code>code</code>',
                         'href="https://example.test/guide"', '&lt;script&gt;', 'id="v1.2.3"',
                         'datetime="2026-11-15"', '<h4>Known limits</h4>'):
            self.assertIn(expected, html)
        self.assertNotIn('<script>', html)

    def test_rejects_missing_fields_unknown_sections_and_invalid_dates(self):
        for source in [SOURCE.replace('title: A user-facing change.\n', ''),
                       SOURCE.replace('date: 2026-11-15\n', ''), SOURCE.replace('2026-11-15', '2026-02-30'),
                       SOURCE.replace('## New', '## Improvements'), SOURCE.replace('## Fixed', '## New'),
                       SOURCE.replace('---\n', '', 1), SOURCE.replace('engine:', 'unknown:'),
                       SOURCE.replace('engine: Chromium 158.0.8127.37; Example component 2', 'engine:'),
                       SOURCE.replace('title:', 'date: 2026-11-16\ntitle:'),
                       '---\ndate: 2026-11-15\ntitle: Empty.\n---\n',
                       SOURCE + '\n## Smaller\n', SOURCE + '\nUnstructured prose.\n']:
            with self.subTest(source=source), self.assertRaises(ValueError):
                notes.parse(source, '1.2.3')
        for version in ['../1.2.3', '1.2', '01.2.3', '1.2.3-nightly.bad']:
            with self.subTest(version=version), self.assertRaises(ValueError):
                notes.parse(SOURCE, version)

    def test_faster_requires_two_measured_numbers_and_direction(self):
        for claim in ['Much faster.', 'About 20% faster.', '200 ms to 80 ms.', 'before → 80 ms']:
            with self.subTest(claim=claim), self.assertRaisesRegex(ValueError, 'before → after'):
                notes.parse(SOURCE.replace('Opening the synthetic fixture takes 200 ms → 80 ms.', claim), '1.2.3')

    def test_reuses_public_neutrality_policy_for_all_text(self):
        for source in [SOURCE.replace('A user-facing change.', notes._hygiene.SOURCE_NAME + ' behavior.'),
                       SOURCE + '\n  ' + notes._hygiene.SOURCE_NAME]:
            with self.assertRaisesRegex(ValueError, 'neutrality'):
                notes.parse(source, '1.2.3')

    def test_quotes_colons_and_continuations(self):
        source = SOURCE.replace('title: A user-facing change.', 'title: "A change: with context."')
        source = source.replace('- One documented limitation.', '- One documented\n  limitation.')
        note = notes.parse(source, '1.2.3')
        self.assertEqual(note.title, 'A change: with context.')
        self.assertEqual(note.sections['Known limits'], ['One documented limitation.'])
        self.assertIn('&lt;img', notes.inline('<img src=x onerror=alert(1)>'))
        self.assertNotIn('<a', notes.inline('[unsafe](javascript:alert(1))'))

    def test_media_schema_is_strict(self):
        source = (FIXTURES / 'nightly/1.2.4-nightly.2.md').read_text()
        for invalid in [source.replace('    poster: preview.jpg\n', ''),
                        source.replace('preview.mp4', '../preview.mp4'),
                        source.replace('preview.jpg', 'https://example.test/poster.jpg'),
                        source.replace('    caption:', '    unknown:'),
                        source.replace('    poster:', '    caption: duplicate\n    poster:'),
                        source.replace('## New', '## Fixed'),
                        SOURCE.replace('---\n\n## New', 'media:\n---\n\n## New')]:
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                notes.parse(invalid, '1.2.4-nightly.2')


class SiteTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        target = self.root / 'release/notes'
        target.mkdir(parents=True)
        shutil.copy(FIXTURES / '1.2.3.md', target)
        (target / 'nightly').mkdir()
        shutil.copy(FIXTURES / 'nightly/1.2.4-nightly.2.md', target / 'nightly')
        media = self.root / 'web/assets/releases/1.2.4-nightly.2'
        shutil.copytree(FIXTURES / 'media', media)
        template = self.root / 'scripts/templates'
        template.mkdir(parents=True)
        shutil.copy(notes.ROOT / 'scripts/templates/changelog.html', template)

    def test_index_details_channels_and_relative_assets(self):
        all_notes = notes.load_all(self.root)
        self.assertEqual([note.channel for note in all_notes], ['nightly', 'stable'])
        files = changelog.outputs(self.root)
        index = files['web/changelog.html']
        self.assertIn('data-channel="nightly"', index)
        self.assertIn('id="channel-stable"', index)
        self.assertIn('id="channel-nightly"', index)
        self.assertIn('type="application/atom+xml"', index)
        self.assertNotIn('api.github.com', index)
        detail = files['web/changelog/1.2.4-nightly.2/index.html']
        for expected in ['Latest is 1.2.3', 'href="../../assets/changelog.css"',
                         '<video muted loop playsinline controls preload="none"',
                         'poster="../../assets/releases/1.2.4-nightly.2/preview.jpg"',
                         'Preview controls with synthetic data.']:
            self.assertIn(expected, detail)
        self.assertNotIn('data-latest="true"', detail)
        self.assertNotIn('{{', detail)
        stable = files['web/changelog/1.2.3/index.html']
        self.assertNotIn('Latest is', stable)

    def test_previous_next_are_numeric_and_stay_in_channel(self):
        directory = self.root / 'release/notes'
        for version in ['1.2.2','1.2.10']:
            (directory / (version + '.md')).write_text(SOURCE)
        for version in ['1.2.4-nightly.1', '1.2.4-nightly.10']:
            source = SOURCE.replace('date: 2026-11-15', 'date: 2026-11-16')
            (directory / 'nightly' / (version + '.md')).write_text(source)
        files = changelog.outputs(self.root)
        stable = files['web/changelog/1.2.3/index.html']
        self.assertIn('rel="prev" href="../1.2.2/"', stable)
        self.assertIn('rel="next" href="../1.2.10/"', stable)
        nightly = files['web/changelog/1.2.4-nightly.2/index.html']
        self.assertIn('rel="prev" href="../1.2.4-nightly.1/"', nightly)
        self.assertIn('rel="next" href="../1.2.4-nightly.10/"', nightly)
        self.assertIn('Latest is 1.2.10', nightly)

    def test_atom_is_valid_complete_and_deterministic(self):
        output = changelog.outputs(self.root)['web/changelog.xml']
        feed = ET.fromstring(output)
        ns = {'a': changelog.ATOM}
        entries = feed.findall('a:entry', ns)
        self.assertEqual(len(entries), 2)
        self.assertEqual(feed.find('a:updated', ns).text, '2026-11-16T00:00:00Z')
        self.assertEqual([e.find('a:category', ns).attrib['term'] for e in entries], ['nightly', 'stable'])
        self.assertEqual(entries[1].find('a:id', ns).text, 'https://circabrowser.com/changelog/1.2.3/')
        self.assertIn('<strong>new feature</strong>', entries[1].find('a:content', ns).text)
        self.assertIn('https://circabrowser.com/assets/releases/', entries[0].find('a:content', ns).text)
        self.assertTrue(output.startswith("<?xml version='1.0' encoding='utf-8'?>\n"))
        self.assertEqual(output, changelog.outputs(self.root)['web/changelog.xml'])

    def test_check_detects_stale_missing_and_obsolete_outputs_without_writing(self):
        changelog.generate(self.root)
        changelog.generate(self.root, check=True)
        path = self.root / 'web/changelog/1.2.3/index.html'
        before = path.read_bytes()
        path.write_text('stale')
        with self.assertRaisesRegex(ValueError, 'out of date'):
            changelog.generate(self.root, check=True)
        self.assertEqual(path.read_text(), 'stale')
        path.write_bytes(before)
        path.unlink()
        with self.assertRaises(ValueError):
            changelog.generate(self.root, check=True)
        changelog.generate(self.root)
        old = self.root / 'web/changelog/0.0.1/index.html'
        old.parent.mkdir()
        old.write_text(changelog.GENERATED)
        manual = self.root / 'web/changelog/manual/index.html'
        manual.parent.mkdir()
        manual.write_text('Manually authored.')
        with self.assertRaises(ValueError):
            changelog.generate(self.root, check=True)
        changelog.generate(self.root)
        self.assertFalse(old.exists())
        self.assertTrue(manual.exists())
        changelog.generate(self.root, check=True)

    def test_stable_only_and_nightly_directory_policy(self):
        nightly = self.root / 'release/notes/nightly'
        shutil.rmtree(nightly)
        self.assertEqual(len(notes.load_all(self.root)), 1)
        self.assertEqual(len(changelog.outputs(self.root)), 3)
        (self.root / 'release/notes/1.2.4-nightly.1.md').write_text(SOURCE)
        with self.assertRaisesRegex(ValueError, 'must live'):
            notes.load_all(self.root)

    def test_media_requires_existing_files_and_size_cap(self):
        path = self.root / 'web/assets/releases/1.2.4-nightly.2/preview.mp4'
        path.unlink()
        with self.assertRaisesRegex(ValueError, 'must exist'):
            notes.load_all(self.root)
        path.write_bytes(b'0' * (notes.MAX_MEDIA_BYTES + 1))
        with self.assertRaisesRegex(ValueError, '3 MB'):
            notes.load_all(self.root)
        shutil.copy(FIXTURES / 'media/preview.mp4', path)
        poster = path.with_suffix('.jpg')
        poster.write_text('not a JPEG')
        with self.assertRaisesRegex(ValueError, 'JPEG'):
            notes.load_all(self.root)

    def test_mp4_validation_rejects_duration_width_codec_and_audio(self):
        path = self.root / 'web/assets/releases/1.2.4-nightly.2/preview.mp4'
        source = path.read_bytes()
        notes.validate_clip(path)
        variants = [source.replace(b'avc1', b'vp09'), source.replace(b'vide', b'soun'), b'truncated']
        data = bytearray(source)
        position = data.index(b'mvhd') + 4
        struct.pack_into('>I', data, position + 16, 16000)  # timescale is 1000
        variants.append(bytes(data))
        data = bytearray(source)
        position = data.index(b'tkhd')
        size = struct.unpack_from('>I', data, position - 4)[0]
        struct.pack_into('>I', data, position - 4 + size - 8, 1441 * 65536)
        variants.append(bytes(data))
        for data in variants:
            path.write_bytes(data)
            with self.subTest(data=data[:12]), self.assertRaises(ValueError):
                notes.validate_clip(path)

    def test_repository_outputs_are_current(self):
        result = subprocess.run([sys.executable, str(notes.ROOT / 'scripts/changelog.py'), 'check'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
