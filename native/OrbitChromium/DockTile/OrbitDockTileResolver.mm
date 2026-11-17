#import "OrbitDockTileResolver.h"

NSString *const OrbitDockTilePreferenceKey = @"orbit.applicationIcon";
NSString *const OrbitDockTileChangeNotificationSuffix = @".applicationIconChanged";

NSArray<NSString *> *OrbitDockTileCustomIcons(void) {
  return @[ @"paper", @"sunset", @"afterglow", @"frost", @"riso", @"ink" ];
}

NSURL *OrbitDockTileContainingApplication(NSURL *plugIn) {
  if (!plugIn.isFileURL || ![plugIn.pathExtension isEqualToString:@"docktileplugin"]) return nil;
  NSURL *plugIns = plugIn.URLByStandardizingPath.URLByDeletingLastPathComponent;
  NSURL *contents = plugIns.URLByDeletingLastPathComponent;
  NSURL *application = contents.URLByDeletingLastPathComponent;
  if (![plugIns.lastPathComponent isEqualToString:@"PlugIns"] ||
      ![contents.lastPathComponent isEqualToString:@"Contents"] ||
      ![application.pathExtension isEqualToString:@"app"]) {
    return nil;
  }
  return application;
}

NSString *OrbitDockTileApplicationIdentifier(NSURL *application) {
  NSURL *info = [application URLByAppendingPathComponent:@"Contents/Info.plist"];
  NSDictionary *values = [NSDictionary dictionaryWithContentsOfURL:info error:nil];
  id identifier = values[@"CFBundleIdentifier"];
  return [identifier isKindOfClass:NSString.class] && [identifier length] ? identifier : nil;
}

NSString *OrbitDockTileValidatedIcon(id value) {
  if (![value isKindOfClass:NSString.class]) return nil;
  return [OrbitDockTileCustomIcons() containsObject:value] ? value : nil;
}

NSString *OrbitDockTileSelectedIcon(NSString *applicationIdentifier) {
  CFStringRef domain = (__bridge CFStringRef)applicationIdentifier;
  // Drop the cached value: the app writes from its own process.
  CFPreferencesAppSynchronize(domain);
  id value = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)OrbitDockTilePreferenceKey, domain));
  return OrbitDockTileValidatedIcon(value);
}

static BOOL RegularFileInside(NSURL *file, NSURL *root) {
  NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:file.path error:nil];
  if (![attributes[NSFileType] isEqualToString:NSFileTypeRegular]) return NO;
  NSString *resolved = file.URLByResolvingSymlinksInPath.path;
  NSString *prefix = [root.URLByResolvingSymlinksInPath.path stringByAppendingString:@"/"];
  return [resolved hasPrefix:prefix];
}

NSURL *OrbitDockTileIconResource(NSURL *application, NSString *icon) {
  if (!OrbitDockTileValidatedIcon(icon)) return nil;
  NSURL *shell = [application URLByAppendingPathComponent:
      @"Contents/Resources/OrbitLabNative_BrowserShell.bundle" isDirectory:YES];
  NSString *file = [icon stringByAppendingPathExtension:@"icns"];
  // CMake keeps the bundle's Contents/Resources layout; SwiftPM resource bundles are flat.
  for (NSString *directory in @[ @"Contents/Resources/AppIcons", @"AppIcons" ]) {
    NSURL *candidate = [[shell URLByAppendingPathComponent:directory isDirectory:YES]
        URLByAppendingPathComponent:file isDirectory:NO];
    if (RegularFileInside(candidate, application)) return candidate;
  }
  return nil;
}

NSString *OrbitDockTileChangeNotificationName(NSString *applicationIdentifier) {
  return [applicationIdentifier stringByAppendingString:OrbitDockTileChangeNotificationSuffix];
}
