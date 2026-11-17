// Dock tile plug-in (NSDockTilePlugIn in the app's Info.plist): while the app is not running and
// is kept in the Dock, the Dock draws its tile with this plug-in. It shows the icon chosen in
// Settings, read from the containing app's preferences and resources, and follows changes posted
// by the app. It never writes into the signed bundle.
#import <AppKit/AppKit.h>
#import <os/log.h>

#import "OrbitDockTileResolver.h"

@interface OrbitDockTilePlugIn : NSObject <NSDockTilePlugIn>
@end

@implementation OrbitDockTilePlugIn {
  NSDockTile *_tile;
  NSURL *_application;
  NSString *_identifier;
  NSString *_observedName;
  os_log_t _log;
}

- (instancetype)init {
  if ((self = [super init])) _log = os_log_create("io.github.okatech.orbit.docktile", "tile");
  return self;
}

- (void)dealloc {
  [self stopObserving];
}

- (void)stopObserving {
  if (_observedName) {
    [NSDistributedNotificationCenter.defaultCenter removeObserver:self name:_observedName object:nil];
    _observedName = nil;
  }
}

- (void)setDockTile:(NSDockTile *)dockTile {
  [self stopObserving];
  _tile = dockTile;
  if (!dockTile) return;  // Removed from the Dock.
  NSBundle *plugIn = [NSBundle bundleForClass:self.class];
  _application = OrbitDockTileContainingApplication(plugIn.bundleURL);
  _identifier = _application ? OrbitDockTileApplicationIdentifier(_application) : nil;
  if (!_identifier) {
    os_log_error(_log, "dock tile plug-in outside an application bundle");
    return;
  }
  _observedName = OrbitDockTileChangeNotificationName(_identifier);
  [NSDistributedNotificationCenter.defaultCenter addObserver:self selector:@selector(iconChanged:)
      name:_observedName object:nil suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
  [self refresh];
}

- (void)iconChanged:(NSNotification *)notification {
  // Distributed notifications may arrive on any thread; the tile is drawn on the main thread.
  dispatch_async(dispatch_get_main_queue(), ^{ [self refresh]; });
}

- (void)refresh {
  if (!_tile || !_application || !_identifier) return;
  NSString *icon = OrbitDockTileSelectedIcon(_identifier);
  NSURL *resource = icon ? OrbitDockTileIconResource(_application, icon) : nil;
  NSImage *image = resource ? [[NSImage alloc] initWithContentsOfURL:resource] : nil;
  if (image) {
    NSSize size = _tile.size;
    NSImageView *view = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
    view.image = image;
    view.imageScaling = NSImageScaleProportionallyUpOrDown;
    _tile.contentView = view;
  } else {
    _tile.contentView = nil;  // The bundle's own icon.
  }
  [_tile display];
  os_log(_log, "dock tile icon %{public}@ for %{public}@", image ? icon : @"default", _identifier);
}

@end
