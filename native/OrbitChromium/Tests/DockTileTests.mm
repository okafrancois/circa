// Dock tile plug-in resolution (DockTile/OrbitDockTileResolver.mm) against a synthetic application
// layout and a throwaway file-backed preference domain: `cmake --build <dir> --target OrbitDockTileTests`.
#import <Foundation/Foundation.h>

#include <cstdio>
#include <cstdlib>

#import "OrbitDockTileResolver.h"

static int failures = 0;
#define CHECK(condition)                                                    \
  do {                                                                      \
    if (!(condition)) {                                                     \
      std::fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #condition); \
      ++failures;                                                           \
    }                                                                       \
  } while (0)

static NSURL *Make(NSURL *root, NSString *path, BOOL directory) {
  NSURL *url = [root URLByAppendingPathComponent:path isDirectory:directory];
  NSFileManager *files = NSFileManager.defaultManager;
  [files createDirectoryAtURL:directory ? url : url.URLByDeletingLastPathComponent
      withIntermediateDirectories:YES attributes:nil error:nil];
  if (!directory) [[NSData dataWithBytes:"icns" length:4] writeToURL:url atomically:NO];
  return url;
}

int main() {
  @autoreleasepool {
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *root = [files.temporaryDirectory URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    NSURL *app = Make(root, @"Test.app", YES);
    NSString *identifier = [@"lab.orbit.orbit.docktile-test." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSURL *plugIn = Make(app, @"Contents/PlugIns/OrbitDockTile.docktileplugin", YES);
    [@{@"CFBundleIdentifier" : identifier} writeToURL:[app URLByAppendingPathComponent:@"Contents/Info.plist"] error:nil];

    // Containing application and its identifier.
    CHECK([OrbitDockTileContainingApplication(plugIn).path isEqualToString:app.URLByStandardizingPath.path]);
    CHECK(OrbitDockTileContainingApplication(Make(root, @"Loose.docktileplugin", YES)) == nil);
    CHECK(OrbitDockTileContainingApplication(Make(app, @"Contents/Frameworks/X.docktileplugin", YES)) == nil);
    CHECK(OrbitDockTileContainingApplication(Make(root, @"Folder/Contents/PlugIns/X.docktileplugin", YES)) == nil);
    CHECK(OrbitDockTileContainingApplication(Make(app, @"Contents/PlugIns/X.bundle", YES)) == nil);
    CHECK([OrbitDockTileApplicationIdentifier(app) isEqualToString:identifier]);
    CHECK(OrbitDockTileApplicationIdentifier(root) == nil);

    // Only the non-default icons the app can store.
    CHECK([OrbitDockTileValidatedIcon(@"ink") isEqualToString:@"ink"]);
    CHECK([OrbitDockTileValidatedIcon(@"paper") isEqualToString:@"paper"]);
    CHECK(OrbitDockTileValidatedIcon(@"stage") == nil);
    CHECK(OrbitDockTileValidatedIcon(@"../ink") == nil);
    CHECK(OrbitDockTileValidatedIcon(@"INK") == nil);
    CHECK(OrbitDockTileValidatedIcon(@42) == nil);
    CHECK(OrbitDockTileValidatedIcon(nil) == nil);

    // Icons come from the containing application's own resources, as regular files inside it.
    CHECK(OrbitDockTileIconResource(app, @"ink") == nil);
    NSURL *cmake = Make(app, @"Contents/Resources/OrbitLabNative_BrowserShell.bundle/Contents/Resources/AppIcons/ink.icns", NO);
    CHECK([OrbitDockTileIconResource(app, @"ink").path isEqualToString:cmake.path]);
    NSURL *flat = Make(app, @"Contents/Resources/OrbitLabNative_BrowserShell.bundle/AppIcons/frost.icns", NO);
    CHECK([OrbitDockTileIconResource(app, @"frost").path isEqualToString:flat.path]);
    CHECK(OrbitDockTileIconResource(app, @"stage") == nil);
    NSURL *outside = Make(root, @"outside.icns", NO);
    NSURL *link = [app URLByAppendingPathComponent:
        @"Contents/Resources/OrbitLabNative_BrowserShell.bundle/AppIcons/riso.icns"];
    [files createSymbolicLinkAtURL:link withDestinationURL:outside error:nil];
    CHECK(OrbitDockTileIconResource(app, @"riso") == nil);
    Make(app, @"Contents/Resources/OrbitLabNative_BrowserShell.bundle/AppIcons/sunset.icns", YES);
    CHECK(OrbitDockTileIconResource(app, @"sunset") == nil);

    // The choice is read from the containing application's preference domain only. An absolute
    // path is a preference domain backed by that file, so the user's preferences are never touched.
    NSString *preferences = [root URLByAppendingPathComponent:@"preferences"].path;
    CFStringRef domain = (__bridge CFStringRef)preferences;
    CFStringRef key = (__bridge CFStringRef)OrbitDockTilePreferenceKey;
    CHECK([OrbitDockTilePreferenceKey isEqualToString:@"orbit.applicationIcon"]);
    CHECK(OrbitDockTileSelectedIcon(preferences) == nil);
    CFPreferencesSetAppValue(key, CFSTR("afterglow"), domain);
    CFPreferencesAppSynchronize(domain);
    CHECK([OrbitDockTileSelectedIcon(preferences) isEqualToString:@"afterglow"]);
    CHECK(OrbitDockTileSelectedIcon([preferences stringByAppendingString:@"-other"]) == nil);
    CFPreferencesSetAppValue(key, CFSTR("unknown"), domain);
    CFPreferencesAppSynchronize(domain);
    CHECK(OrbitDockTileSelectedIcon(preferences) == nil);
    CFPreferencesSetAppValue(key, NULL, domain);
    CFPreferencesAppSynchronize(domain);
    CHECK(OrbitDockTileSelectedIcon(preferences) == nil);

    CHECK([OrbitDockTileChangeNotificationName(identifier)
        isEqualToString:[identifier stringByAppendingString:@".applicationIconChanged"]]);

    [files removeItemAtURL:root error:nil];
  }
  if (failures) return EXIT_FAILURE;
  std::puts("OrbitDockTileTests: PASS");
  return EXIT_SUCCESS;
}
