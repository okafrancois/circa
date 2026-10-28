#import "OrbitApplicationLifecycle.h"

#include <optional>
#include <vector>
#include <utility>

namespace {
enum class QuitPhase { Idle, Consulting, Waiting, Finishing };
}

@interface ACRLifecycleApplication () {
  QuitPhase quitPhase_;
  std::optional<BOOL> earlyReply_;
  BOOL quitHandlerInstalled_;
  std::vector<NSAppleEventManagerSuspensionID> quitEvents_;
}
@end

@implementation ACRLifecycleApplication
- (void)finishLaunching {
  [super finishLaunching];
  // AppKit installs its default handlers during launch. Replace only Quit afterwards, before
  // normal event dispatch. Unlike AppKit's _handleAEQuit, this entry uses our terminate:.
  [self acrInstallQuitHandler];
}
- (void)acrInstallQuitHandler {
  // Reassert after launch even if installed before CEF initialization: AppKit may replace
  // default handlers while launching. Registration replaces the same key, never accumulates.
  [[NSAppleEventManager sharedAppleEventManager]
      setEventHandler:self andSelector:@selector(acrHandleQuit:withReplyEvent:)
      forEventClass:kCoreEventClass andEventID:kAEQuitApplication];
  quitHandlerInstalled_ = YES;
}
- (void)acrRemoveQuitHandler {
  if (!quitHandlerInstalled_) return;
  // This class is the exclusive Quit-handler owner during ACRRun. Never remove URL/document
  // handlers. ACRRun's scope guard releases this registration even when initialization fails.
  quitHandlerInstalled_ = NO;
  [[NSAppleEventManager sharedAppleEventManager]
      removeEventHandlerForEventClass:kCoreEventClass andEventID:kAEQuitApplication];
  [self acrCompleteQuitEvents:errAEEventNotHandled];
}
- (void)acrHandleQuit:(NSAppleEventDescriptor*)event
       withReplyEvent:(NSAppleEventDescriptor*)reply {
  if (quitPhase_ == QuitPhase::Finishing) return;
  // Hold every request (including duplicates) until the delegate's save/drain decision. Use
  // the manager's suspension API, not AppKit's nested _shouldTerminate loop or exit() path.
  auto suspension = [[NSAppleEventManager sharedAppleEventManager] suspendCurrentAppleEvent];
  if (!suspension) {
    [reply setParamDescriptor:[NSAppleEventDescriptor descriptorWithInt32:errAEEventFailed]
                  forKeyword:keyErrorNumber];
    return;
  }
  quitEvents_.push_back(suspension);
  [self terminate:self];
}
- (void)terminate:(id)sender {
  if (quitPhase_ != QuitPhase::Idle) return;
  // Set before calling the delegate: confirmation sheets/modal loops may dispatch another Quit,
  // and a delegate may reply synchronously before returning NSTerminateLater.
  quitPhase_ = QuitPhase::Consulting;
  earlyReply_.reset();
  NSApplicationTerminateReply reply = NSTerminateNow;
  @try {
    id<NSApplicationDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(applicationShouldTerminate:)])
      reply = [delegate applicationShouldTerminate:self];
  } @catch (NSException* exception) {
    quitPhase_ = QuitPhase::Idle;
    earlyReply_.reset();
    [self acrCompleteQuitEvents:errAEEventFailed];
    return;
  }
  if (reply == NSTerminateLater) {
    quitPhase_ = QuitPhase::Waiting;
    if (earlyReply_) [self replyToApplicationShouldTerminate:*earlyReply_];
    return;
  }
  earlyReply_.reset();
  if (reply == NSTerminateNow) {
    [self acrFinishTermination];
  } else {
    quitPhase_ = QuitPhase::Idle;
    [self acrCompleteQuitEvents:userCanceledErr];
  }
}
- (void)replyToApplicationShouldTerminate:(BOOL)shouldTerminate {
  if (quitPhase_ == QuitPhase::Consulting) {
    if (!earlyReply_) earlyReply_ = shouldTerminate;
    return;
  }
  if (quitPhase_ != QuitPhase::Waiting) return;
  earlyReply_.reset();
  if (shouldTerminate) {
    [self acrFinishTermination];
  } else {
    quitPhase_ = QuitPhase::Idle;
    [self acrCompleteQuitEvents:userCanceledErr];
  }
}
- (void)acrFinishTermination {
  quitPhase_ = QuitPhase::Finishing;
  if (![self acrRequestRuntimeQuit]) {
    quitPhase_ = QuitPhase::Idle;
    [self acrCompleteQuitEvents:errAEEventFailed];
    return;
  }
  [[NSNotificationCenter defaultCenter] postNotificationName:NSApplicationWillTerminateNotification
                                                      object:self];
  [self acrCompleteQuitEvents:noErr];
}
- (void)acrCompleteQuitEvents:(int32_t)error {
  auto events = std::move(quitEvents_);
  quitEvents_.clear();
  auto manager = [NSAppleEventManager sharedAppleEventManager];
  for (auto suspension : events) {
    if (error != noErr) {
      [[manager replyAppleEventForSuspensionID:suspension]
          setParamDescriptor:[NSAppleEventDescriptor descriptorWithInt32:error]
                  forKeyword:keyErrorNumber];
    }
    [manager resumeWithSuspensionID:suspension];
  }
}
- (BOOL)acrRequestRuntimeQuit { return NO; }
@end
