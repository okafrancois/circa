# Default keyboard shortcuts

These are Circa's shipped macOS bindings, grouped by menu. They assume no saved shortcut overrides. A command can be disabled when its target is unavailable (for example, Go Back without page history, or Close this Split Pane outside a split). Hidden aliases that still accept keys are included; unavailable catalog entries are not presented as working shortcuts.

## Key legend

| Symbol | Key |
|---|---|
| ⌘ | Command |
| ⌃ | Control |
| ⌥ | Option (Alt) |
| ⇧ | Shift |
| ↑ ↓ ← → | Arrow keys |
| ⇥ | Tab |
| ␣ | Space |
| ⎋ | Escape |
| ⌫ | Delete (backspace, not forward delete) |
| ↩ | Return (or keypad Enter where noted) |
| F12 | Function key F12; your Mac may require Fn/🌐 |

Hold the modifiers together and press the final key. Capital letters below name keys; Shift is required only where ⇧ is shown. Punctuation names the character (`+`, `=`, `-`, `[`, `]`, `:`, `;`, `,`, `.`, or the backtick `` ` ``). AppKit adapts default menu equivalents to the keyboard layout and writing direction; use the equivalent shown in your menu. Number bindings support the number row and keypad, including layouts with shifted digits.

## Circa

| Shortcut | Command |
|---|---|
| ⌘, | Preferences… (opens Settings) |
| ⌘H | Hide Circa |
| ⌥⌘H | Hide Other Windows |
| ⌘Q | Quit Circa |

## File

| Shortcut | Command / behavior |
|---|---|
| ⌘T | New Tab… — opens the Command Bar for a new tab |
| ⌘N | New Window |
| ⇧⌘N | New Incognito Window |
| ⌥⌘N | New Little Circa Window |
| ⇧⌘T | Restore Last Closed Tab — can also reopen the most recently closed Peek |
| ⌘L | Open Command Bar — edits the current tab's URL |
| ⇧⌘W | Close Window |
| ⌘W | Archive Tab — closes/archives the selected sidebar tabs, or the current tab |
| ⇧⌘2 | Capture… |
| ⇧⌘S | Save Page As |
| ⌘P | Print |

With Peek or Library open, ⌘W closes the preview or Library before the underlying tab; an Archive preview closes while keeping Library open. In Settings and other native auxiliary windows, ⌘W closes that window.

Open File…, New Profile, Share…, and Capture Full Page have no default shortcut. New Folder is under Tabs and has no shipped binding; ⇧⌘N is reserved for New Incognito Window.

## Edit

Text-editing commands depend on the focused field, editable page, or native responder. Formatting and spelling shortcuts apply only where supported; they do not format arbitrary web page content.

| Shortcut | Command |
|---|---|
| ⌘Z | Undo |
| ⇧⌘Z | Redo |
| ⌘X | Cut |
| ⌘C | Copy |
| ⇧⌘C | Copy URL |
| ⌥⇧⌘C | Copy URL as Markdown |
| ⌘V | Paste |
| ⇧⌘V | Paste and Match Style |
| ⌘A | Select All |

### Edit › Find

| Shortcut | Command |
|---|---|
| ⌘F | Find… |
| ⌥⌘F | Find and Replace (supported native text editors) |
| ⌘G | Find Next |
| ⇧⌘G | Find Previous |
| ⌘J | Jump to Selection (supported native text editors) |

Use Selection to Find has no default shortcut.

### Edit › Spelling and Grammar

| Shortcut | Command |
|---|---|
| ⌘: | Show Spelling and Grammar |
| ⌘; | Check Document Now |

### Edit › Format › Font

| Shortcut | Command |
|---|---|
| ⌘B | Bold |
| ⌘I | Italic |
| ⌘U | Underline |

Delete, the remaining spelling toggles, Substitutions, Transformations, and Speech commands have no default menu shortcut. Ordinary text-editing keys still belong to the focused editor.

## View

| Shortcut | Command / behavior |
|---|---|
| ⌘S | Show/Hide Sidebar |
| ⌃␣ | Reveal Current Tab in the sidebar (hidden menu binding) |
| ⌘. | Stop Loading |
| ⌘R | Refresh the Page |
| ⇧⌘R | Force Refresh the Page (alternate menu item) |
| ⌃⇧= | Add Split View |
| ⌃⇧- | Close this Split Pane |
| ⌘0 | Zoom to Actual Size |
| ⌘+ or ⌘= | Zoom In (the `=` equivalent is a hidden alias) |
| ⌘- or ⇧⌘- | Zoom Out (the shifted equivalent is a hidden alias) |
| ⌃⌘F | Enter/Exit Full Screen |
| ⎋ | Exit the current Library, Peek, or full-screen context when applicable |

Escape also stops a loading page when no text editor or Library owns the key. Fields, dialogs, and overlays may handle Escape first. It is not a general Quit shortcut.

Appearance choices, Separate Page from Split View, and Expand Current Split have no default shortcut. Additional split layout and pane-focus actions in the Command Bar/context menus also have no default binding.

### View › Developer

| Shortcut | Command |
|---|---|
| ⌥⌘U | View Source |
| ⌥⌘I or F12 | Developer Tools (F12 is a hidden alias, with no modifiers) |
| ⌥⌘C | Inspect Elements |
| ⌥⌘J | JavaScript Console |
| ⌃D | Toggle Developer Mode for the current site |

Network Inspector has no default shortcut.

## Spaces

| Shortcut | Command |
|---|---|
| ⌥⌘→ | Next Space |
| ⌥⌘← | Previous Space |
| ⌃1 … ⌃9 | Select Space 1 … 9, if that position exists (not available in private windows) |

Numbered selection is a supplemental binding, not a row in the Spaces menu. New Space…, Edit Theme…, Rename Space, Change Profile, and Manage Spaces… have no default shortcut. The dynamic Change Profile submenu does not assign shortcuts to individual profiles.

## Tabs

| Shortcut | Command / behavior |
|---|---|
| ⌘T | New Tab… (also in File) |
| ⌘D | Pin/Unpin Tab |
| ⌘O | Open Little Circa or Peek in… — promotes an existing Little Circa or Peek into a tab; does not create a Little Circa window |
| ⌥⌘V | Paste as New Tab (hidden menu binding) |
| ⌥⌘↓ | Next Tab in sidebar order |
| ⌥⌘↑ | Previous Tab in sidebar order |
| ⌃⌘→ | Cycle Tab Forward in sidebar order (hidden menu binding) |
| ⌃⌘← | Cycle Tab Backward in sidebar order (hidden menu binding) |
| ⌃⇥ | Tab Switcher (forward; hidden menu binding) |
| ⌃⇧⇥ or ⌃\` | Tab Switcher (backward; hidden/supplemental bindings) |
| ⇧⌘K | Clear Unpinned Tabs |
| ⌘1 … ⌘8 | Select tab 1 … 8 in sidebar order, if present (supplemental bindings) |
| ⌘9 | Select the last tab (supplemental binding) |

Numbered tab selection includes Favorites by default. Settings › Shortcuts can exclude Favorites from this ordering or make ⌘9 select the ninth tab instead. Next/Previous Tab and Cycle Tab move through sidebar tabs and wrap around; Tab Switcher is a separate recent-tab picker. Hold Control while cycling the default switcher bindings, then release it to select. In the switcher, ⌃W closes the highlighted tab, ↩ or keypad Enter selects it, and ⎋ cancels.

New Folder…, Duplicate, Rename Current Item, Collapse/Expand All Folders, Reveal Tab in Sidebar, Reset all tabs in this Space, and Reset Tab to Original URL have no default shortcut. Some of these actions are hidden menu entries or available through the Command Bar/context menus.

## Archive

| Shortcut | Command |
|---|---|
| ⌘[ or ⌘← | Go Back (arrow equivalent is a hidden alias) |
| ⌘] or ⌘→ | Go Forward (arrow equivalent is a hidden alias) |
| ⌘Y | View History |

In native text fields, ⌘←/⌘→ move the insertion point instead of navigating. View Archive and Clear Archive have no default shortcut. The page-history popup assigns no keys to individual history entries.

## Extensions

| Shortcut | Behavior |
|---|---|
| ⌘E | Cycle pinned extensions when available (supplemental binding); release Command to open the selected extension, or Escape to cancel |

When the optional AI assistant is enabled, ⌘E toggles the assistant first. Add Extension… and Manage Extensions… have no default shortcut. Extension-defined bindings are separate: see Settings › Shortcuts › Extension Shortcuts… .

## Window

| Shortcut | Command |
|---|---|
| ⌘M | Minimize Window |
| ⇧⌘L | View Library |
| ⇧⌘J | View Downloads |

Zoom, View Media, and Bring All to Front have no default shortcut. Window Zoom resizes a window; page zoom is under View.

## Help

No Circa-defined default keyboard shortcuts. Help › Essential Keyboard Shortcuts opens Settings › Shortcuts. Any shortcuts inserted by macOS (for example, Services or Help menu behavior) depend on the system configuration and are outside this reference.

## Contextual bindings

These bindings require the named surface; they are not additional always-visible menu commands.

| Context | Shortcut | Behavior |
|---|---|---|
| Command Bar | ⌥⌘⌫ | Remove the selected suggestion, if it can be deleted |
| Little Circa › File | ⌘W | Close Little Circa |
| Little Circa › File | ⌘L or ⌘T | Focus its search/URL field |
| Little Circa › View | ⌘R | Reload its page |
| Little Circa › Tabs | ⌘O | Move into the selected main window’s current Space when its profile matches; otherwise use Little Circa’s source Space |
| Little Circa › Tabs | ⇧⌘O | Choose a Space to open in |
| Peek › Tabs | ⎋ | Close Peek, unless a native text field owns the key |
| Share popup | ⇧⌘C | Copy Link (same URL-copy binding as Edit) |
| Settings toolbar/overflow menu | ⌘1 … ⌘7 | General, Profiles, Shortcuts, Links, AI, Advanced, About, respectively |

Little Circa also routes supported page commands to its own page, including back/forward, find, zoom, copy URL, stop, print, force refresh, and developer tools. Navigation, reload, stop, copy URL, find, and zoom target Peek when it has page focus.

## Customizing shortcuts

Open Circa › Preferences… (⌘,) and choose **Shortcuts**, or use Help › Essential Keyboard Shortcuts. Search for an exposed command, click its shortcut, and press the replacement keys. Escape cancels recording; Delete removes the binding. The command's options menu also provides **Remove Shortcut** and **Reset to Default**; **Reset All** restores the default bindings and shortcut preferences. Not every contextual or native responder binding is exposed in this pane.

The options menu can choose **Prefer Circa**, **Prefer Websites**, or **Use Both** for shortcut conflicts with websites. The **Open Little Circa from other apps** toggle enables a global shortcut using New Little Circa Window's current binding (⌥⌘N by default); this toggle is off by default.

## Scope and maintenance

This reference covers the default command bindings and their active menu aliases, plus the contextual bindings above. Text entry, ordinary dialog navigation, website shortcuts, and extension-defined shortcuts are not an exhaustive part of this list. Saved overrides, keyboard layout, focus, private browsing, and macOS shortcut reservations can change what is available.

A declaration in the catalog alone does not make a shortcut available. Blank Window, Show/Hide Toolbar, Join Meeting, and Peek Email have declarations but no installed command handler. New Note, New Note (in Split), New Easel, New ChatGPT Message, and Copy URL as Quote are hidden from command surfaces. Their declared keys are deliberately not listed as usable defaults.

To update this document, compare [the command catalog](../native/Sources/Orbit/Commands/OrbitCommandCatalog.swift) with [the menu tree](../native/Sources/Orbit/Commands/OrbitMenuTree.swift), [menu construction](../native/Sources/Orbit/Commands/BrowserCommandMenus.swift), and [shortcut preferences](../native/Sources/Orbit/Commands/BrowserShortcutPreferences.swift). Check installed handlers and scoped overrides starting at [application menu setup](../native/Sources/Orbit/App/OrbitApplication+Menus.swift). Preserve hidden active aliases, normalize uppercase letters to explicit Shift, and check dynamic menus and commands without bindings rather than copying every catalog row.
