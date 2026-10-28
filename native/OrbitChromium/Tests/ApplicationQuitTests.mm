#import "../Bridge/OrbitApplicationLifecycle.h"
#import <Carbon/Carbon.h>
#include <functional>
#include <spawn.h>
#include <sys/wait.h>
extern char** environ;
static const char* executablePath;
static const char* syntheticRoot;
#include <sys/stat.h>
#include <unistd.h>
#include <libproc.h>
#include <cstring>

static void Check(bool value, const char* message) {
  if (!value) { fprintf(stderr, "FAIL: %s\n", message); abort(); }
}

// No CEF, files, sites, credentials or windows. This is the product's actual lifecycle class,
// with only the runtime drain request replaced. A failed request is observable and retryable.
@interface QuitApplication : ACRLifecycleApplication
@property int requests;
@property int terminateEntries;
@property BOOL runtimeAccepts;
@end
@implementation QuitApplication
- (void)terminate:(id)sender { ++_terminateEntries; [super terminate:sender]; }
- (BOOL)acrRequestRuntimeQuit { ++_requests; return _runtimeAccepts; }
@end

// Leaves AppKit's real default Quit handler installed, solely to prove its routing with Cancel.
@interface BaselineApplication : NSApplication
@property int requests;
@property int terminateEntries;
@property BOOL runtimeAccepts;
@end
@implementation BaselineApplication
- (void)terminate:(id)sender { ++_terminateEntries; [super terminate:sender]; }
@end

@interface QuitDelegate : NSObject <NSApplicationDelegate>
@property int calls;
@property NSApplicationTerminateReply answer;
@property BOOL reenter;
@property BOOL earlyReply;
@property BOOL throwsException;
@end
@implementation QuitDelegate
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication*)sender {
  ++_calls;
  if (_throwsException) @throw [NSException exceptionWithName:@"SyntheticFailure" reason:nil userInfo:nil];
  if (_reenter) [sender terminate:self];
  if (_earlyReply) [sender replyToApplicationShouldTerminate:YES];
  return _answer;
}
@end

@interface OtherEvents : NSObject
@property int calls;
@end
@implementation OtherEvents
- (void)handle:(NSAppleEventDescriptor*)event reply:(NSAppleEventDescriptor*)reply { ++_calls; }
@end

static void PumpUntil(std::function<bool()> predicate) {
  NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:3];
  while (!predicate() && deadline.timeIntervalSinceNow > 0) {
    @autoreleasepool {
      NSEvent* event = [NSApp nextEventMatchingMask:NSEventMaskAny
                         untilDate:[NSDate dateWithTimeIntervalSinceNow:.005]
                         inMode:NSDefaultRunLoopMode dequeue:YES];
      if (event) [NSApp sendEvent:event];
    }
  }
  Check(predicate(), "bounded hidden Apple Event dispatch completed");
}

// Real Apple Event transport, targeted only at this executable's exact PID. Wait replies use
// an owned sender process so AppKit can dispatch while it waits (in-process AESendMessage
// serializes event dispatch and would prevent this harness from issuing the delayed reply).
struct Sender {
  bool joined = false;
  pid_t child = 0;
  int pipeRead = -1;
  struct Result { OSStatus status; int32_t error; } result{};
  Sender(AEEventClass eventClass, AEEventID eventID, bool wait = false) {
    int pipes[2]; Check(pipe(pipes) == 0, "synthetic sender pipe");
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, pipes[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&actions, pipes[0]);
    posix_spawn_file_actions_addclose(&actions, pipes[1]);
    std::string target = std::to_string(getpid()), cls = std::to_string(eventClass);
    std::string ident = std::to_string(eventID);
    const char* args[] = {executablePath, "--sender", target.c_str(), cls.c_str(), ident.c_str(),
                          wait ? "wait" : "no-reply", "--use-mock-keychain", syntheticRoot, nullptr};
    Check(posix_spawn(&child, executablePath, &actions, nullptr, const_cast<char**>(args), environ) == 0,
          "spawn exact-parent-PID sender");
    posix_spawn_file_actions_destroy(&actions);
    close(pipes[1]); pipeRead = pipes[0];
  }
  bool done() {
    if (joined) return true;
    int status = 0;
    pid_t completed = waitpid(child, &status, WNOHANG);
    if (completed == 0) return false;
    Check(completed == child && WIFEXITED(status) && WEXITSTATUS(status) == 0, "owned sender completed");
    Check(read(pipeRead, &result, sizeof(result)) == sizeof(result), "sender result only, no content");
    close(pipeRead); joined = true;
    return true;
  }
  void finish() {
    PumpUntil([&] { return done(); });
    Check(result.status == noErr, "exact-PID AESendMessage succeeded");
  }
};

static int SendToParent(int argc, char** argv) {
  Check(argc == 8 && std::string(argv[6]) == "--use-mock-keychain", "synthetic sender arguments");
  const pid_t target = std::stoi(argv[2]);
  Check(target == getppid() && target > 1, "sender can address only its own parent PID");
  char ownExecutable[PROC_PIDPATHINFO_MAXSIZE], parentExecutable[PROC_PIDPATHINFO_MAXSIZE];
  Check(proc_pidpath(getpid(), ownExecutable, sizeof(ownExecutable)) > 0
        && proc_pidpath(target, parentExecutable, sizeof(parentExecutable)) > 0
        && strcmp(ownExecutable, parentExecutable) == 0, "sender parent is this same synthetic executable");
  struct stat root;
  Check(lstat(argv[7], &root) == 0 && S_ISDIR(root.st_mode) && root.st_uid == getuid()
        && (root.st_mode & 0777) == 0700, "sender owned private synthetic root");
  AEAddressDesc address = {typeNull, nullptr};
  AppleEvent event = {typeNull, nullptr}, reply = {typeNull, nullptr};
  Sender::Result result{};
  result.status = AECreateDesc(typeKernelProcessID, &target, sizeof(target), &address);
  if (result.status == noErr)
    result.status = AECreateAppleEvent(std::stoul(argv[3]), std::stoul(argv[4]), &address,
                                      kAutoGenerateReturnID, kAnyTransactionID, &event);
  const bool wait = std::string(argv[5]) == "wait";
  if (result.status == noErr)
    result.status = AESendMessage(&event, &reply, (wait ? kAEWaitReply : kAENoReply) | kAENeverInteract, 120);
  if (wait && result.status == noErr) {
    DescType actual; Size size;
    OSStatus read = AEGetParamPtr(&reply, keyErrorNumber, typeSInt32, &actual,
                                  &result.error, sizeof(result.error), &size);
    Check(read == noErr || read == errAEDescNotFound, "read synthetic reply status");
  }
  AEDisposeDesc(&reply); AEDisposeDesc(&event); AEDisposeDesc(&address);
  Check(write(STDOUT_FILENO, &result, sizeof(result)) == sizeof(result), "sender numeric result");
  return 0;
}

int main(int argc, char** argv) {
  @autoreleasepool {
    if (argc > 1 && std::string(argv[1]) == "--sender") return SendToParent(argc, argv);
    // No bundle/default launch mode exists. The runner supplies a fresh private synthetic root.
    Check(argc == 4 && std::string(argv[2]) == "--use-mock-keychain", "explicit synthetic-only invocation");
    struct stat root;
    Check(lstat(argv[3], &root) == 0 && S_ISDIR(root.st_mode) && root.st_uid == getuid()
          && (root.st_mode & 0777) == 0700, "owned private synthetic root");
    executablePath = argv[0]; syntheticRoot = argv[3];
    NSString* scenario = @(argv[1]);
    Check([@[@"default-route-proof", @"delayed", @"cancel-retry", @"early-reply",
             @"runtime-retry", @"delayed-runtime-retry", @"cleanup-wait", @"exception-retry",
             @"menu", @"menu-now", @"event-now"] containsObject:scenario],
          "known synthetic scenario");
    QuitApplication* app = [scenario isEqual:@"default-route-proof"]
        ? (QuitApplication*)[BaselineApplication sharedApplication] : [QuitApplication sharedApplication];
    [app setActivationPolicy:NSApplicationActivationPolicyProhibited];
    Check(app.activationPolicy == NSApplicationActivationPolicyProhibited, "prohibited activation policy");
    app.runtimeAccepts = YES;
    QuitDelegate* delegate = [QuitDelegate new];
    delegate.answer = NSTerminateLater;
    app.delegate = delegate;
    if (![scenario isEqual:@"default-route-proof"]) {
      [app acrInstallQuitHandler];
      [app acrInstallQuitHandler];
    }
    [app finishLaunching];
    Check(!app.active && app.windows.count == 0, "hidden before event transport");
    __block int notifications = 0;
    id observer = [[NSNotificationCenter defaultCenter]
        addObserverForName:NSApplicationWillTerminateNotification object:app queue:nil
        usingBlock:^(NSNotification*) {
          Check(app.requests > 0 && app.runtimeAccepts, "notification follows accepted runtime request");
          ++notifications;
        }];

    if ([scenario isEqual:@"default-route-proof"]) {
      delegate.answer = NSTerminateCancel;
      Sender baseline(kCoreEventClass, kAEQuitApplication, true);
      baseline.finish();
      Check(delegate.calls == 1 && app.terminateEntries == 0 && app.requests == 0,
            "AppKit default Quit asks delegate without entering terminate override");
      Check(baseline.result.error == userCanceledErr, "AppKit baseline cancellation reply");
      Check(!app.active && app.windows.count == 0, "hidden baseline");
      fprintf(stdout, "PASS default-route-proof delegate=1 terminate-override=0 exact-pid=%d windows=0 active=0\n", getpid());
      [[NSNotificationCenter defaultCenter] removeObserver:observer];
      app.delegate = nil;
      return 0;
    } else if ([scenario isEqual:@"menu-now"]) {
      delegate.answer = NSTerminateNow;
      [app terminate:nil];
      Check(delegate.calls == 1, "immediate menu quit asks delegate");
    } else if ([scenario isEqual:@"menu"]) {
      delegate.reenter = YES;
      [app terminate:nil];
      Check(delegate.calls == 1 && app.requests == 0, "menu deferred and reentrant quit deduplicated");
      [app replyToApplicationShouldTerminate:NO];
      [app terminate:nil];
      Check(delegate.calls == 2 && app.requests == 0, "menu cancel then retry");
      [app replyToApplicationShouldTerminate:YES];
    } else {
      BOOL now = [scenario isEqual:@"event-now"];
      if (now) delegate.answer = NSTerminateNow;
      BOOL immediateCancel = [scenario isEqual:@"cancel-retry"];
      BOOL delayedRuntimeRetry = [scenario isEqual:@"delayed-runtime-retry"];
      BOOL cleanupWait = [scenario isEqual:@"cleanup-wait"];
      BOOL runtimeRetry = [scenario isEqual:@"runtime-retry"] || delayedRuntimeRetry;
      BOOL exceptionRetry = [scenario isEqual:@"exception-retry"];
      BOOL early = [scenario isEqual:@"early-reply"];
      if (immediateCancel) delegate.answer = NSTerminateCancel;
      if (runtimeRetry) {
        delegate.answer = delayedRuntimeRetry ? NSTerminateLater : NSTerminateNow;
        app.runtimeAccepts = NO;
      }
      if (exceptionRetry) delegate.throwsException = YES;
      delegate.earlyReply = early;
      Sender first(kCoreEventClass, kAEQuitApplication, true);
      PumpUntil([&] { return delegate.calls == 1; });
      if (delayedRuntimeRetry) {
        Check(app.requests == 0 && !first.done(), "deferred decision precedes runtime refusal");
        [app replyToApplicationShouldTerminate:YES];
      }
      if (cleanupWait) {
        Check(!first.done(), "cleanup starts with suspended sender");
        [app acrRemoveQuitHandler];
        first.finish();
        Check(first.result.error == errAEEventNotHandled && app.requests == 0 && notifications == 0,
              "scope cleanup releases pending reply without accepting runtime quit");
        // The delegate still owes its cancellation, even after the event handler is removed.
        [app replyToApplicationShouldTerminate:NO];
        [app acrInstallQuitHandler];
        Sender retry(kCoreEventClass, kAEQuitApplication, true);
        PumpUntil([&] { return delegate.calls == 2; });
        [app replyToApplicationShouldTerminate:YES];
        retry.finish();
        Check(retry.result.error == noErr, "handler can be reinstalled after pending cleanup");
      } else if (immediateCancel || runtimeRetry || exceptionRetry) {
        first.finish();
        Check(first.result.error == (immediateCancel ? int32_t(userCanceledErr) : int32_t(errAEEventFailed)), "cancel/failure Apple Event reply");
        Check(notifications == 0, "no termination notification before accepted drain");
        delegate.answer = NSTerminateLater;
        delegate.throwsException = NO;
        app.runtimeAccepts = YES;
        Sender retry(kCoreEventClass, kAEQuitApplication, true);
        PumpUntil([&] { return delegate.calls == 2; });
        Check(app.requests == (runtimeRetry ? 1 : 0), "no drain before delegate persistence reply");
        [app replyToApplicationShouldTerminate:YES];
        retry.finish();
        Check(retry.result.error == noErr, "retry accepted reply");
      } else if (early || now) {
        first.finish();
        Check(app.requests == 1, "immediate or synchronous Later reply accepted");
      } else {
        Check(!first.done() && app.requests == 0, "Later holds sender and runtime until persistence reply");
        Sender duplicate(kCoreEventClass, kAEQuitApplication, true);
        // Barrier event ensures the duplicate has actually dispatched, not just been queued.
        auto manager = [NSAppleEventManager sharedAppleEventManager];
        OtherEvents* other = [OtherEvents new];
        [manager setEventHandler:other andSelector:@selector(handle:reply:) forEventClass:kInternetEventClass andEventID:kAEGetURL];
        [manager setEventHandler:other andSelector:@selector(handle:reply:) forEventClass:kCoreEventClass andEventID:kAEOpenDocuments];
        Sender url(kInternetEventClass, kAEGetURL, true); url.finish();
        Sender document(kCoreEventClass, kAEOpenDocuments, true); document.finish();
        Check(other.calls == 2 && delegate.calls == 1, "URL/doc handlers preserved and duplicate quit deduplicated");
        Check(!duplicate.done(), "duplicate wait-reply sender stays suspended with original");
        [app terminate:nil];
        Check(delegate.calls == 1, "menu during Apple Event wait deduplicated");
        [app replyToApplicationShouldTerminate:NO];
        first.finish();
        duplicate.finish();
        Check(first.result.error == userCanceledErr && app.requests == 0, "delayed cancel keeps runtime alive");
        Check(duplicate.result.error == userCanceledErr, "duplicate receives same cancellation decision");
        Sender retry(kCoreEventClass, kAEQuitApplication, true);
        PumpUntil([&] { return delegate.calls == 2; });
        [app replyToApplicationShouldTerminate:YES];
        retry.finish();
        Check(retry.result.error == noErr, "delayed retry succeeded");
        [app acrRemoveQuitHandler];
        Sender preserved(kInternetEventClass, kAEGetURL, true); preserved.finish();
        Check(other.calls == 3, "cleanup preserves other Apple Event registrations");
        [manager removeEventHandlerForEventClass:kInternetEventClass andEventID:kAEGetURL];
        [manager removeEventHandlerForEventClass:kCoreEventClass andEventID:kAEOpenDocuments];
      }
    }
    int acceptedRequests = ([scenario isEqual:@"runtime-retry"] || [scenario isEqual:@"delayed-runtime-retry"]) ? 2 : 1;
    Check(app.requests == acceptedRequests && notifications == 1, "exactly one accepted drain/termination notification");
    [app terminate:nil];
    [app replyToApplicationShouldTerminate:YES];
    Check(app.requests == acceptedRequests && notifications == 1, "late duplicate requests/replies are inert");
    [app acrRemoveQuitHandler]; [app acrRemoveQuitHandler];
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
    Check(!app.active && app.windows.count == 0, "no windows or activation during regression");
    fprintf(stdout, "PASS %s exact-pid=%d windows=0 active=0\n", argv[1], getpid());
    app.delegate = nil;
    return 0;
  }
}
