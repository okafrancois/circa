// Pure resolution rules of the Dock tile plug-in, shared with its tests (Tests/DockTileTests.mm).
// The app stores the chosen icon in its own preferences (OrbitAppIconController); the plug-in
// reads them read-only for the application that contains it and draws the icon from that
// application's resources. Nothing here writes into a bundle.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const OrbitDockTilePreferenceKey;
extern NSString *const OrbitDockTileChangeNotificationSuffix;

// Icon identifiers the plug-in draws. The default icon is absent: the bundle's own icon shows.
NSArray<NSString *> *OrbitDockTileCustomIcons(void);

// <App>.app for <App>.app/Contents/PlugIns/<PlugIn>.docktileplugin, otherwise nil.
NSURL *_Nullable OrbitDockTileContainingApplication(NSURL *plugIn);

// CFBundleIdentifier from the application's Info.plist, otherwise nil.
NSString *_Nullable OrbitDockTileApplicationIdentifier(NSURL *application);

// A custom icon identifier for a stored preference value; nil for the default or anything else.
NSString *_Nullable OrbitDockTileValidatedIcon(id _Nullable value);

// The validated choice stored in the preferences of `applicationIdentifier`.
NSString *_Nullable OrbitDockTileSelectedIcon(NSString *applicationIdentifier);

// <application>/Contents/Resources/OrbitLabNative_BrowserShell.bundle/.../AppIcons/<icon>.icns, a
// regular file inside the application, otherwise nil.
NSURL *_Nullable OrbitDockTileIconResource(NSURL *application, NSString *icon);

// <identifier>.applicationIconChanged, posted by the app when the user picks an icon.
NSString *OrbitDockTileChangeNotificationName(NSString *applicationIdentifier);

NS_ASSUME_NONNULL_END
