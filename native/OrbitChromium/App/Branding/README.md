# Orbit application identity

`Orbit.icns` is the Bow default, copied unchanged from
`native/Sources/BrowserShell/AppIcons/stage.icns`. Run
`python3 scripts/orbit-app-icon.py` to synchronize it. CMake, synthetic packaging,
release packaging and the notification helper all use this same file and
`CFBundleIconFile = Orbit.icns`. The release DMG contains the packaged application;
it has no separate icon artwork or background image.

The seven application icon choices ship as complete ICNS files and chooser PNGs.
Their ICNS representations preserve the full master at 128 pixels and above,
the medium master at 32–64 pixels, and the tiny master at 16 pixels.

The selected identifier is stored in application preferences. On every launch,
including the first launch after an automatic update replaces the bundle, Orbit
sets the running Dock image and tries to set the bundle's Finder icon using public
AppKit APIs. If the bundle cannot be changed, the Dock choice and preference still
work; Finder keeps the icon it can read. A later launch retries the bundle write.
Restore Default removes the preference and requests removal of the custom Finder
icon, exposing the shipped Bow icon. Removal can also fail on a non-writable bundle;
the running Dock nevertheless returns to Bow. Finder may refresh its cached icon
asynchronously. Application resources and code signatures are never rewritten.


The displayed product name is Circa. `Orbit.app`, its executable and module names,
bundle identifiers, update identity, data directories and secure-storage names remain
stable for existing installations. `CFBundleName` is Circa. The raw
`CFBundleDisplayName` deliberately remains Orbit: macOS compares that value with
the bundle filename before accepting a localized display name. Both localized
InfoPlist names are Circa, with `LSHasLocalizedDisplayName` enabled. This metadata
exception lets Finder, LaunchServices, Dock and the app switcher display Circa
while updates continue replacing Orbit.app in place. The notification helper uses
the visible product name rather than the raw compatibility display name.

See [Apple's display-name rule](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/CoreFoundationKeys.html#//apple_ref/doc/uid/TP40009249-SW13).
