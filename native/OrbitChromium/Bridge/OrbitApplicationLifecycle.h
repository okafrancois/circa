#import <AppKit/AppKit.h>

// Shared by the CEF application and the CEF-free AppKit regression executable.
// Owns only the core/quit handler; URL and document handlers belong to the shell.
@interface ACRLifecycleApplication : NSApplication
- (void)acrInstallQuitHandler;
- (void)acrRemoveQuitHandler;
// The CEF subclass supplies the runtime operation. NO leaves the app retryable.
- (BOOL)acrRequestRuntimeQuit;
@end
