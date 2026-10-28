#!/usr/bin/env python3
"""Check tracked paths and working-tree bytes before publishing a lot.

Run from any directory: python3 scripts/check-public-hygiene.py
The full Swift suite runs this check and its policy regression tests.
"""
from pathlib import Path
import json
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
SOURCE_NAME = "A" + "rc"
SOURCE_BUNDLE_ID = "company.the" + "browser.Browser"


def expand(value):
    return value.format(source=SOURCE_NAME, lower=SOURCE_NAME.lower(), upper=SOURCE_NAME.upper(), source_bundle=SOURCE_BUNDLE_ID)


# Only the importer, its synthetic tool and its tests may name the source browser freely.
IMPORT_ROOTS = tuple(expand(path) for path in (
    "native/Sources/BrowserCore/Import/{source}/",
    "native/Sources/Orbit/Import/{source}/",
    "native/Sources/OrbitImportSynthetic/Import/{source}/",
    "native/Sources/OrbitImportTool/Import/{source}/",
    "native/Tests/BrowserCoreTests/Import/{source}/",
    "native/Tests/OrbitTests/Import/{source}/",
))

# Mixed-purpose files allow only these exact import identifiers/strings. The compatibility
# header retains the documented prebuilt engine ABI. Shared locks must keep their names
# across worktrees until all callers migrate together.
ALLOWED_TEXT = {path: tuple(expand(value) for value in values) for path, values in {'AGENTS.md': ['/tmp/{lower}y-gui-slot.lock', '/tmp/{lower}y-native-full-suite.lock'],
 'native/OrbitChromium/App/EngineComposition+Chromium.swift': ['{source}ImportError',
                                                               '{source}SiteSessionFixtureKeys',
                                                               '{source}SiteSessionImport',
                                                               '{source}SiteSessionKeyProviding',
                                                               '{source}SiteSessionKeychain',
                                                               '{source}SiteSessionRequest',
                                                               '{source}SiteSessionResult',
                                                               '{source}SourceSnapshot',
                                                               '{source_bundle}',
                                                               '{lower}IsRunning'],
 'native/OrbitChromium/Bridge/EngineCompatibility.h': ['{upper}Y_CEF_PATCHES',
                                                       '{lower}-lab-chromium-source-v1',
                                                       '{lower}y-engine-extensions-r3',
                                                       '{lower}y_cef_essentials_level',
                                                       '{lower}y_cef_extension_set_pinned',
                                                       '{lower}y_cef_extension_shortcut',
                                                       '{lower}y_cef_get_api',
                                                       '{lower}y_cef_set_unowned_tab_handler'],
 'native/OrbitChromium/ChromiumEngine/ChromiumAuthenticationImport.swift': ['{source}PreparedSyntheticCookie'],
 'native/OrbitChromium/Tests/AuthenticationCoordinatorTests.swift': ['{source}AuthenticationError',
                                                                     '{source}ChromiumSecretDecoder',
                                                                     '{source}PreparedSyntheticCookie',
                                                                     '{source}SyntheticCookieRow',
                                                                     '{source}SyntheticSourceSecret'],
 'native/OrbitChromium/Tests/SiteSessionFixture.swift': ['{source}ChromiumCookieCipher',
                                                         '{source}ProfileKey'],
 'native/OrbitChromium/Tests/run_root_registration_session_lock_review.py': ['{source}ImportError'],
 'native/README.md': ['/tmp/{lower}y-native-full-suite.lock'],
 'native/Sources/BrowserCore/History/BrowserHistoryStore.swift': ['{source}ImportError'],
 'native/Sources/BrowserCore/Themes/BrowserStore+Themes.swift': ['{source}SpaceThemeImport'],
 'native/Sources/Orbit/App/EngineComposition.swift': ['{source}SiteSessionResult'],
 'native/Sources/Orbit/App/OrbitApplication+Menus.swift': ['import{source}Connections',
                                                           'importFrom{source}',
                                                           'restore{source}Connections',
                                                           'start{source}Import',
                                                           'start{source}SiteSessionImport'],
 'native/Sources/Orbit/App/OrbitApplication.swift': ['{source}ImportAlertPresenter',
                                                     '{source}ImportCoordinator',
                                                     '{source}ImportError',
                                                     '{source}SiteSessionRequest',
                                                     'offer{source}ImportIfFirstRun'],
 'native/Sources/Orbit/Commands/BrowserCommandMenus.swift': ['importFrom{source}'],
 'native/Sources/Orbit/Commands/BrowserDailyCommands.swift': ['importFrom{source}',
                                                              'Import from {source}'],
 'native/Sources/Orbit/Commands/OrbitCommandCatalog.swift': ['{source}ImportCommands',
                                                             'import{source}Connections',
                                                             'importFrom{source}',
                                                             'restore{source}Connections'],
 'native/Sources/Orbit/Environment/BrowserEnvironment+SpaceProfile.swift': ['{source}ImportBackups',
                                                                            '{source}ImportDataLocation'],
 'native/Sources/Orbit/Environment/BrowserEnvironment+Themes.swift': ['{source}ImportDataLocation'],
 'native/Sources/Orbit/Environment/BrowserEnvironment.swift': ['{source}ImportBackups',
                                                               '{source}ImportDataLocation'],
 'native/Sources/Orbit/Sidebar/SidebarRows.swift': ['append{source}'],
 'native/Sources/Orbit/Sidebar/SpaceCreationEdgeView.swift': ['append{source}'],
 'native/Tests/BrowserCoreTests/BrowserSpaceProfileTests.swift': ['{source}ImportBackups',
                                                                  '{source}ImportDataLocation'],
 'native/Tests/BrowserCoreTests/BrowserSpaceThemeTests.swift': ['{source}ImportDataLocation',
                                                                '{source}SpaceAppearance',
                                                                '{source}SpaceThemeImport'],
 'native/Tests/OrbitTests/CommandBarTests.swift': ['importFrom{source}'],
 'native/Tests/OrbitTests/Fixtures/localization-lint-exceptions.json': ['Import/{source}/{source}ImportAlertPresenter.swift',
                                                                        'Import/{source}/{source}ImportText.swift'],
 'native/Tests/OrbitTests/LocalizationTests.swift': ['{source}ImportCommands'],
 'native/Tests/OrbitTests/NativeCommandTests.swift': ['import{source}Connections',
                                                      'importFrom{source}',
                                                      'restore{source}Connections',
                                                      'Import from {source}…'],
 'native/Tests/OrbitTests/NativePrivateDomainTests.swift': ['{source}ImportLiveTarget'],
 'scripts/orbit-extension-update-smoke.py': ['/tmp/{lower}y-gui-slot.lock']}.items()}

LOCALIZED_IMPORT_KEYS = frozenset(expand(key) for key in ['{source} is open. Quit {source}, then try again.',
 'Orbit can copy your Spaces, profiles, Favorites, pinned tabs and folders, Today tabs and history from '
 '{source}. {source} must be closed during the copy; Orbit never quits it.',
 'Orbit reads a consistent copy of your {source} data, which requires {source} to be closed. Quit '
 '{source} (⌘Q), then choose Check Again. Orbit never quits {source} for you.',
 '{source}’s Spaces and tabs would make Orbit’s session too large to open (%@ of %@ allowed). Nothing '
 'was imported.',
 '{source}’s data changed while Orbit was reading it. Quit {source}, then try again.',
 '{source}’s data folder and Orbit’s data folder overlap. Choose a separate copy of {source}’s data.',
 'Bring Your {source} Spaces to Orbit?',
 'Choose {source}’s data folder, or a copy of it.',
 'Copying {source} data…',
 'Import from {source}',
 'Import from {source} Failed',
 'Import from {source}?',
 'Import from {source}…',
 'No {source} data was found in this folder. Choose {source}’s data folder (Library › Application '
 'Support › {source}).',
 'Quit {source}',
 'Quit {source} to Import',
 'This version of {source}’s data could not be read. Nothing was imported.',
 '{source} must be closed to copy its connections. Orbit will then save your tabs and restart. Allow '
 'access to {source} Safe Storage when macOS asks. Existing Orbit connections are backed up before '
 'importing.',
 'Orbit will save your tabs and restart. Allow access to {source} Safe Storage when macOS asks. '
 '{source} connections replace matching cookies and site storage in the corresponding profiles. A '
 'backup lets you undo the import.',
 'Import Connections from {source}?',
 'Import Connections from {source}…',
 'Quit {source} to Import Your Connections',
 'Your existing connections were kept. Check that {source} is closed and allow Keychain access, then '
 'try again.'])

# Language/runtime names describe geometry and automatic reference counting.
TECHNICAL_TEXT = ("-fobjc-" + SOURCE_NAME.lower(), "append" + SOURCE_NAME)
# Numeric constants with defined API semantics, never code locations.
ALLOWED_HEX = {
    "native/OrbitChromium/Bridge/OrbitChromiumBridge.h":
        ("01000000", "02000000", "40000000", "80000000"),  # Navigation qualifier flags.
    "native/Sources/Orbit/Commands/BrowserGlobalQuickWindowShortcut.swift":
        ("4E494153",),  # EventHotKeyID four-character signature.
    "scripts/launch_services.py": ("08000100",),  # kCFStringEncodingUTF8.
}
ADDRESS = re.compile(r"(?i)\b0x[0-9a-f]{8,}\b")
LOWER_NAME = re.escape(SOURCE_NAME.lower())
MENTION = re.compile(
    r"(?i:(?<![A-Za-z0-9])" + LOWER_NAME + r"(?![A-Za-z0-9])|" + LOWER_NAME + r"y\w*|" + LOWER_NAME + r"lab\w*|"
    + LOWER_NAME + r"[-_]|company\.thebrowser\.Browser|\b" + LOWER_NAME + r"\.net\b)"
    + "|" + SOURCE_NAME + r"(?=[A-Z]|\b)|\b" + LOWER_NAME + r"(?=[A-Z])|"
    + SOURCE_NAME.upper() + r"(?=[_-])"
)
PROVENANCE = re.compile(r"(?i)\bparity\b")
LOCALIZATION_PATH = "native/Sources/BrowserShell/Resources/en.lproj/Localizable.strings"


def mask_literals(line, literals):
    for value in sorted(literals, key=len, reverse=True):
        # Do not allow an approved identifier as a substring of a new identifier.
        line = re.sub(r"(?<![\w])" + re.escape(value) + r"(?![\w])", " ", line)
    return line


def check_text(path, text):
    findings = []
    imported = path.startswith(IMPORT_ROOTS)
    for number, line in enumerate(text.splitlines(), 1):
        for match in ADDRESS.finditer(line):
            if match[0][2:].upper() not in ALLOWED_HEX.get(path, ()):
                findings.append((path, number, "binary address pattern"))
        if PROVENANCE.search(line):
            findings.append((path, number, "private provenance or comparison wording"))
        if imported:
            continue
        if path == LOCALIZATION_PATH:
            # A known import lookup key and its identical English default only.
            match = re.fullmatch(r'("(?:[^"\\]|\\.)*") = ("(?:[^"\\]|\\.)*");', line)
            if match and json.loads(match[1]) in LOCALIZED_IMPORT_KEYS and match[1] == match[2]:
                continue
        scrubbed = mask_literals(line, (*TECHNICAL_TEXT, *ALLOWED_TEXT.get(path, ())))
        if MENTION.search(scrubbed):
            findings.append((path, number, "source-browser mention outside the import allowlist"))
    return findings


def check_path(path):
    if "lab" in Path(path).parts:
        return [(path, 0, "tracked local lab material")]
    if path.startswith(IMPORT_ROOTS):
        return []
    if MENTION.search(path):
        return [(path, 0, "source-browser name in a tracked path")]
    return []


def check_repository(root):
    # The index defines what can be published. Read current bytes so edits are checked
    # before staging too; staged deletions disappear naturally from this list.
    paths = subprocess.check_output(["git", "-C", str(root), "ls-files", "-z", "--cached"],
                                    ).decode("utf-8").split("\0")
    findings = []
    for path in sorted(set(paths) - {""}):
        findings.extend(check_path(path))
        file = root / path
        if not file.exists() and not file.is_symlink():
            continue  # Unstaged removal; it cannot introduce content.
        if file.is_symlink():
            text = str(file.readlink())
        elif file.is_file():
            data = file.read_bytes()
            try:
                text = data.decode("utf-8")
            except UnicodeDecodeError:
                # Inspect printable metadata in binary resources, excluding random compressed
                # byte fragments that happen to spell a three-character word.
                text = "\n".join(part.decode("ascii") for part in
                                 re.findall(rb"[\x09\x20-\x7e]{8,}", data))
        else:
            continue
        findings.extend(check_text(path, text))
    return findings


def main():
    findings = check_repository(ROOT)
    for path, line, reason in findings:
        print(f"{path}:{line}: {reason}", file=sys.stderr)
    if findings:
        print(f"Public hygiene: {len(findings)} finding(s)", file=sys.stderr)
        return 1
    print("Public hygiene: zero findings")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
