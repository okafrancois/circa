# Release notes and the public changelog

`release/notes/X.Y.Z.md` is the source for the website, GitHub release body and
announcements. Write readable English Markdown about user-visible behavior. For an
internal-only release, explicitly say that it contains only internal fixes. Never
add measurements or feature claims that have not been verified.

## Format

```markdown
---
date: 2026-11-15
title: Media controls follow you between tabs.
engine: Chromium 158.0.8127.37; maintained engine r23; EasyList / EasyPrivacy pin <commit>
media:
  - file: sidebar-player.mp4
    poster: sidebar-player.jpg
    caption: Pause a background tab from the sidebar.
---

## New

- A player appears in the sidebar when a background tab is playing sound.

## Faster

- Opening the synthetic fixture takes 200 ms → 80 ms.

## Fixed

- Closing the player pauses its tab reliably.

## Smaller

- Idle windows no longer wake a timer to refresh unchanged state.

## Known limits

- The volume control is not available yet.
```

This is a deliberately small **YAML-like** grammar, parsed with Python's standard
library, not general YAML. Fields are single-line plain text or text inside a
matching pair of single/double quotes. Quotes are removed, with no escape
processing. Colons inside values are allowed; inline comments, YAML objects,
anchors and multiline scalars are not supported. Do not add explanatory comments
inside front matter. Unknown and duplicate fields are rejected.

- `date` (required): ISO `YYYY-MM-DD`, the release/tag date. For historical
  backfills use the tag's creator date, retaining its recorded local calendar day.
- `title` (required): one user-facing sentence summarizing the release.
- `engine` (optional): include only when the engine **or a bundled component**
  changes. List the engine version/revision and any changed component version or
  immutable pin, including EasyList/EasyPrivacy and Sparkle when they change.
- `update` (optional, stable only): the single value `critical` publishes a security hotfix
  as a Sparkle critical update that skips the phased stable rollout. Use it only when every
  user must install the fix at once; see `pipeline.md` (Stable phased rollout and critical updates).
- `media` (optional): an indented list with exactly `file`, `poster`, and `caption`
  for each entry. Use lowercase hyphenated basenames, `.mp4` and `.jpg`; no paths
  or URLs. Add one clip per new user-visible feature when footage is available;
  entries cannot outnumber `New` items. Historical notes do not require clips.

Use only `New`, `Faster`, `Fixed`, `Smaller`, `Known limits`, in that reading order.
Omit empty sections. At least one nonempty section is required. Every item starts
with `- `; indented continuation lines are joined with spaces. Each `Faster` item
must contain measured numeric **before → after** values, ideally with units and
the measured operation. Qualitative performance claims belong under `Smaller`
(resource use) or `Fixed` unless measurements are available. No invented timings.

Markdown supports paragraphs as list items, code spans, strong/emphasis and HTTPS
links. HTML is escaped on the website. The existing public-hygiene policy checks
the whole source note, including captions and metadata. Import-specific source
names must stay in the website's dedicated import copy, never generated pages.

## Feature clip specification and hosting

Clips are committed under `web/assets/releases/<version>/` beside their JPEG
posters. The generator and release preflight require every declared file to exist.
The stdlib validator inspects the MP4 container: one H.264 (`avc1`) video track,
no audio track, duration at most 15 seconds, width at most 1440 pixels, at most
3,000,000 bytes. JPEG posters also have a 3,000,000-byte cap. Export MP4 with
fast-start metadata (`-movflags +faststart`), `yuv420p` pixels, and no audio (`-an`).

Capture only synthetic data in our own test window, while holding the shared GUI
slot for at most 60 seconds. Verify window ownership before every input, capture
only that window, and clean up the synthetic bundle/data and registration after.
Never record the owner's browser. Check the result for private content before
committing. Clips are silent, with a short descriptive caption and a JPEG poster.

The website embeds `<video muted loop playsinline controls preload="none">` and a
poster; videos do not autoplay or download until requested. The site CSP permits
same-origin media. GitHub release assets were considered, but the sampled public
MP4 played in Chromium and failed in WebKit, so they are not the playback origin.
There is no media upload step or release mutation in this workflow.

## Generate and validate

```sh
python3 scripts/changelog.py build
python3 scripts/changelog.py check
python3 -m unittest discover -s scripts -p 'test_release.py'
python3 -m unittest discover -s scripts -p 'test_changelog.py'
```

Commit notes and generated files together. `check` compares bytes without writing,
including missing or obsolete generated version pages. Build removes only obsolete
pages bearing the generator marker. The template is
`scripts/templates/changelog.html`; the shared article renderer serves both list
and detail pages. No deployment build or GitHub API request is needed.

Stable notes use `release/notes/X.Y.Z.md`. Optional short nightly notes use
`release/notes/nightly/X.Y.Z-nightly.N.md` with the same format and media directory
convention. No nightly directory is needed until the first nightly note exists.
Versions sort numerically (including the nightly number); previous/next links stay
in the same channel. Older pages link to the latest **stable** release. The index
has a native Stable/Nightly/All filter that also works without JavaScript; search
is an optional local enhancement. Atom includes both channels with categories.
Entry IDs are permanent version URLs and timestamps come from note dates, so
rebuilding does not generate new feed identities or timestamps.

`release.py` validates the entire note collection before downloading or building,
and requires a note for the target version (isolated updater-test builds are exempt). Its GitHub body is rendered as title,
item counts, nonempty sections, and the engine/components line. Front matter is
never sent to GitHub. It still refuses to edit already published release bodies.
The hosted build runs the release tests, changelog tests, and freshness check.

Historical notes summarize user-visible changes from the git history between
adjacent tags, including menu and Settings changes. Omit compare links and generic
release titles. If that history contains no user-visible change, use one `Smaller`
item saying that the release contains only internal fixes. Published GitHub bodies
are left untouched; backfills change only the repository sources and website.
