#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#include "OrbitChromiumBridge.h"
#import "OrbitApplicationLifecycle.h"
#include "OrbitBridgeFiles.h"
#include "OrbitBridgePolicy.h"
#include "OrbitCefApi.h"
#include "EngineCompatibility.h"
#include "OrbitExtensionPolicy.h"
#include "OrbitUnownedTabsApi.h"
#include "OrbitClientWrap.h"
#include "OrbitNetworkQoS.h"
#include "OrbitFaviconPolicy.h"
#include "OrbitAuthenticationFiles.h"
#include "OrbitAuthenticationCEF.h"
#include <thread>
#include "include/cef_image.h"

#include <dlfcn.h>
#include <unistd.h>

#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_auth_callback.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_context_menu_handler.h"
#include "include/cef_cookie.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_dialog_handler.h"
#include "include/cef_download_handler.h"
#include "include/cef_find_handler.h"
#include "include/cef_focus_handler.h"
#include "include/cef_id_mappers.h"
#include "include/cef_jsdialog_handler.h"
#include "include/cef_load_handler.h"
#include "include/cef_keyboard_handler.h"
#include "include/cef_unresponsive_process_callback.h"
#include "include/cef_values.h"
#include "include/cef_parser.h"
#include "include/cef_permission_handler.h"
#include "include/cef_request_context.h"
#include "include/cef_request_context_handler.h"
#include "include/cef_resource_request_handler.h"
#include "include/cef_task.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"

#include <sys/stat.h>


#include <atomic>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <functional>
#include <map>
#include <set>
#include <string>
#include <vector>
#include <utility>

@interface ACRApplication : ACRLifecycleApplication <CefAppProtocol> {
  BOOL handlingSendEvent_;
}
@end

@implementation ACRApplication
- (BOOL)isHandlingSendEvent { return handlingSendEvent_; }
- (void)setHandlingSendEvent:(BOOL)value { handlingSendEvent_ = value; }
- (void)sendEvent:(NSEvent*)event {
  CefScopedSendingEvent scope;
  [super sendEvent:event];
}
- (BOOL)acrRequestRuntimeQuit { return ACRRequestQuit() != 0; }

@end

namespace {

class FunctionTask final : public CefTask {
 public:
  explicit FunctionTask(std::function<void()> function) : function_(std::move(function)) {}
  void Execute() override { function_(); }
 private:
  std::function<void()> function_;
  IMPLEMENT_REFCOUNTING(FunctionTask);
};

bool PostUI(std::function<void()> function) {
  return CefPostTask(TID_UI, new FunctionTask(std::move(function)));
}

struct Host {
  orbit_bridge::FaviconReceipt favicon;
  uint64_t token = 0;
  uint64_t profile = 0;
  CefRefPtr<CefBrowser> browser;
  CefRefPtr<CefRegistration> devtools;
  CefRefPtr<CefBrowser> developer_browser;
  std::string developer_panel;
  uint64_t generation = 0;
  bool closing_by_shell = false;
  bool close_requested = false;
  uint64_t window = 0;  // ABI 6: shell window of a hosted Chrome tab, 0 for Alloy.
  // ABI 7: OnLoadStart of the main frame was reported in the current DidFinishNavigation; an
  // OnAddressChange without it is a same-document navigation (fragment, History API).
  int32_t logical_window_id = -1;  // Last logical Browser assigned by this bridge.
  bool load_start_reported = false;
  // ABI 9: ACRRequestClose is waiting for the page (beforeunload); a Stay answer is reported.
  bool close_confirm = false;
  orbit_bridge::ExtensionManagerRoute extension_manager_route;
  uint64_t extension_invocation = 0;
  __weak NSView* extension_anchor = nil;
};

// ABI 9 (CH-ESSENTIALS): page-initiated requests waiting for the shell.
struct PendingDialog {
  CefRefPtr<CefJSDialogCallback> callback;
  uint64_t surface = 0;
  bool before_unload = false;
};

struct PendingAuth {
  CefRefPtr<CefAuthCallback> callback;
  uint64_t surface = 0;
};

struct PendingFileDialog {
  CefRefPtr<CefFileDialogCallback> callback;
  uint64_t surface = 0;
};

struct PendingMenu {
  CefRefPtr<CefRunContextMenuCallback> callback;
  uint64_t surface = 0;
  std::set<int32_t> offered;
};

struct QueuedHostedCreation {
  std::string url;
  int32_t index = -1;
  std::chrono::steady_clock::time_point deadline;
  bool drain_reported = false;
};

struct PendingDownload {
  uint64_t surface = 0;
  uint64_t profile = 0;
  CefRefPtr<CefBeforeDownloadCallback> callback;
};

struct PendingPermission {
  CefRefPtr<CefMediaAccessCallback> media;
  CefRefPtr<CefPermissionPromptCallback> prompt;
  uint32_t mask = 0;
  uint64_t surface = 0;
  uint64_t prompt_id = 0;
};

struct PendingPolicy {
  CefRefPtr<CefCallback> callback;
  uint64_t surface = 0;
};

// Answers a permission request that will never reach the shell (closed browser, quit).
void CancelPermission(const PendingPermission& pending) {
  if (pending.media) pending.media->Cancel();
  if (pending.prompt) pending.prompt->Continue(CEF_PERMISSION_RESULT_DISMISS);
}

class Client;

uint64_t NextExtensionRuntimeLifetime() {
  static uint64_t next = 1; // CEF runtime construction is main-thread only.
  return next++;
}

struct State {
  const uint64_t extension_lifetime = NextExtensionRuntimeLifetime();
  unsigned favicon_outstanding = 0;
  ACRCallbacks callbacks {};
  void* context = nullptr;
  std::string root;
  std::vector<std::string> switches;
  int32_t secure_storage = ACR_SECURE_STORAGE_MOCK;
  int32_t network_policy = ACR_NETWORK_HERMETIC;
  // CHROMIUM-APP-R3: the engine root, opened once (descriptor-anchored profile operations), and
  // the allow-listed browser arguments actually given to Chromium.
  std::unique_ptr<orbit_bridge::AnchoredRoot> anchor;
  std::vector<std::string> browser_arguments;
  std::vector<std::string> disabled_features;
  size_t dropped_arguments = 0;
  // ABI 7: page-first key downs sent to the page, until their unhandled answer. The NSEvent is
  // retained so that its address cannot be reused while it identifies the key; receipts are
  // bounded per surface and overall (orbit_bridge::KeyReceiptLedger).
  orbit_bridge::KeyReceiptLedger<NSEvent*> key_receipts;
  uint64_t next_key = 1;
  bool initialized = false;
  bool quitting = false;
  bool async_hold = false;
  bool loop_quit = false;
  bool quit_stalled = false;
  // The bounded quit ended the loop although browsers had not confirmed their close.
  bool quit_forced = false;
  // Chrome's initial profile was not <root>/Default: the run stopped before READY.
  bool profile_unpinned = false;
  uint32_t quit_stalls = 0;
  uint32_t aborted_creations = 0;
  std::map<uint64_t, Host> hosts;                       // by surface token
  size_t developer_tool_count = 0;
  std::map<uint64_t, uint64_t> pending_profiles;        // surface token -> profile token
  std::map<uint64_t, NSView*> pending_parents;          // retained until the browser exists
  std::set<uint64_t> closed_before_creation;
  // Popups allowed in OnBeforePopup, keyed by (opener browser id, popup_id) as the SDK
  // requires (cef_life_span_handler.h: OnBeforePopupAborted).
  std::map<std::pair<int, int>, uint64_t> pending_popups;
  // Popups whose opener closed during creation: CEF may still create them (closed at once in
  // OnAfterCreated) or drop them silently; they no longer block quit.
  std::set<uint64_t> abandoned_popups;
  std::map<uint64_t, CefRefPtr<CefRequestContext>> profiles;
  std::set<uint64_t> ready_profiles;
  // Synthetic authenticated-import lane: no surface/extension route ever opens these targets.
  std::map<uint64_t, std::shared_ptr<orbit_auth::FreshDirectory>> auth_targets;
  std::map<uint64_t, std::shared_ptr<orbit_auth::Operation>> auth_operations;
  std::set<uint64_t> auth_used_profiles;
  std::set<uint64_t> auth_used_operations;
  orbit_auth::CreationGate auth_creation;
  bool auth_synthetic = false;
  std::map<uint64_t, std::pair<std::string, std::string>> profile_paths;  // (canonical, as given)
  std::map<uint64_t, PendingPolicy> policies;
  std::map<uint64_t, PendingPermission> permissions;
  std::map<uint64_t, PendingDownload> destinations;
  std::map<std::pair<uint64_t, uint32_t>, CefRefPtr<CefDownloadItemCallback>> downloads;
  // ABI 9 (CH-ESSENTIALS).
  std::map<uint64_t, PendingDialog> js_dialogs;
  std::map<uint64_t, PendingAuth> auths;
  std::map<uint64_t, PendingFileDialog> file_dialogs;
  std::map<uint64_t, PendingMenu> menus;
  std::map<uint64_t, CefRefPtr<CefUnresponsiveProcessCallback>> unresponsive;  // by surface token
  uint32_t essentials_level = 0;
  uint64_t next_request = 1;
  // ABI 6: patched CEF side API (null on stock CEF), registered windows, and
  // the window of each hosted tab until OnAfterCreated.
  const orbit_cef_api_t* orbit = nullptr;
  int32_t (*extension_set_pinned)(const char*, const char*, int32_t) = nullptr;
  int32_t (*extension_shortcut)(int32_t, int32_t, uint32_t, char*, uint32_t) = nullptr;
  // EXT-OUTCOME-R1: optional registration of the unowned-tabs patch (NULL on the shipped framework).
  orbit_cef_set_unowned_tab_handler_t set_unowned_tab_handler = nullptr;
  // Changes whenever that registration is installed or cleared (EXT-OUTCOME-R2).
  uint64_t unowned_handler_generation = 0;
  std::set<uint64_t> windows;
  std::map<uint64_t, void*> shell_window_handles;  // Borrowed until ACRCloseWindow.
  std::map<uint64_t, uint64_t> pending_windows;
  std::map<uint64_t, QueuedHostedCreation> queued_hosted_creations;

  struct ExtensionSelection {
    uint64_t surface = 0, profile = 0, epoch = 0;
  };
  std::map<uint64_t, ExtensionSelection> extension_selections;

  bool HasExtensionLeases() const {
    return orbit && orbit->version >= 4u && orbit->extension_selection_changed && orbit->extension_cancel;
  }
  void CancelExtensionAction(Host& host) {
    const auto invocation = std::exchange(host.extension_invocation, 0);
    if (invocation && HasExtensionLeases()) orbit->extension_cancel(invocation);
  }
  void ExtensionSelectionChanged(uint64_t window, Host* selected = nullptr) {
    if (!HasExtensionLeases() || !window) return;
    auto& selection = extension_selections[window];
    if (selected && selection.surface == selected->token && selection.profile == selected->profile) return;
    selection = {selected ? selected->token : 0, selected ? selected->profile : 0, next_request++};
    // The CEF service revokes every lease in this window before callbacks.
    // Clear old IDs first; a reentrant new invocation must never be overwritten.
    for (auto& [token, host] : hosts) if (host.window == window) host.extension_invocation = 0;
    orbit->extension_selection_changed(window, selected ? selected->browser->GetIdentifier() : -1,
        selection.surface, selection.profile, selection.epoch);
  }
  void RevokeExtensionSurface(Host& host) {
    const auto window = host.window, token = host.token;
    CancelExtensionAction(host);
    const auto selection = extension_selections.find(window);
    if (selection != extension_selections.end() && selection->second.surface == token)
      ExtensionSelectionChanged(window);
  }

  // OnBeforeClose precedes the asynchronous deletion of an empty logical Browser. The
  // side API still counts it, but no live tab represents it. CEF's Create reuses that Browser,
  // AddTabAt refuses IsDeleteScheduled(), then CHECK(web_contents) traps (DBG-CH4).
  bool HostedBrowsersRepresented(uint64_t window) {
    std::set<int32_t> represented;
    for (const auto& [token, host] : hosts) {
      if (host.window != window || host.closing_by_shell || !host.browser) continue;
      orbit_tab_info_t info {};
      info.struct_size = sizeof(info);
      if (orbit->get_tab_info(host.browser->GetIdentifier(), &info) == 1
          && info.hosted && info.window_token == window && info.index >= 0 && info.window_id >= 0
          && info.window_id == host.logical_window_id)
        represented.insert(info.window_id);
    }
    const int count = orbit->window_browser_count(window);
    return count >= 0 && static_cast<size_t>(count) == represented.size();
  }

  // OnAfterCreated runs before insertion into TabStripModel. Capture once after that stack
  // unwinds; later native moves must never rewrite this expected identity implicitly.
  void CaptureHostedIdentity(uint64_t token) {
    auto found = hosts.find(token);
    if (found == hosts.end() || found->second.logical_window_id >= 0 || !orbit) return;
    auto& host = found->second;
    if (!host.window || host.closing_by_shell || !host.browser) return;
    orbit_tab_info_t info {};
    info.struct_size = sizeof(info);
    if (orbit->get_tab_info(host.browser->GetIdentifier(), &info) == 1 && info.hosted
        && info.window_token == host.window && info.index >= 0 && info.window_id >= 0)
      host.logical_window_id = info.window_id;
  }

  // The page consumes most candidates: their unhandled answer never comes, and the ledger evicts
  // the oldest. The event itself stays marked as a candidate, so that a late answer after the
  // eviction is consumed instead of reaching CEF's menu redistribution without a receipt.
  void TrackKey(uint64_t id, uint64_t surface, NSEvent* event) {
    objc_setAssociatedObject(event, &kKeyCandidateMark, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    key_receipts.Track(id, surface, event);
  }

  uint64_t TakeTrackedKey(uint64_t surface, NSEvent* event) {
    return event ? key_receipts.Take(surface, event) : 0;
  }

  static bool WasKeyCandidate(NSEvent* event) {
    return event && objc_getAssociatedObject(event, &kKeyCandidateMark) != nil;
  }
  static inline char kKeyCandidateMark = 0;

  ACREvent Event(ACREventKind kind, uint64_t surface) {
    ACREvent event {};
    event.struct_size = sizeof(event);
    event.kind = kind;
    event.surface_token = surface;
    const auto found = hosts.find(surface);
    if (found != hosts.end()) {
      event.profile_token = found->second.profile;
      event.browser_id = found->second.browser ? found->second.browser->GetIdentifier() : 0;
      event.document_generation = found->second.generation;
    } else {
      const auto pending = pending_profiles.find(surface);
      if (pending != pending_profiles.end()) event.profile_token = pending->second;
    }
    return event;
  }

  void Send(const ACREvent& event) { callbacks.event(context, &event); }

  void Simple(ACREventKind kind, uint64_t surface, int32_t value = 0, const char* detail = nullptr) {
    auto event = Event(kind, surface);
    event.value = value;
    event.detail = detail;
    Send(event);
  }

  Host* Find(uint64_t surface) {
    const auto found = hosts.find(surface);
    if (found == hosts.end() || !found->second.browser) return nullptr;
    return &found->second;
  }

  void MaybeFinishQuit() {
    // Cancelled browser creations can leave request contexts initializing asynchronously.
    // Keep them alive and keep pumping until their completion callbacks arrive; releasing
    // them before that point lets late Profile initialization run during CefShutdown.
    const size_t initializing = std::count_if(profiles.begin(), profiles.end(),
        [this](const auto& item) { return !ready_profiles.contains(item.first); });
    if (quitting && !loop_quit && hosts.empty() && pending_profiles.empty() && initializing)
      fprintf(stderr, "acr: quit waiting for request context initialization count=%zu\n", initializing);
    if (quitting && !loop_quit && orbit_bridge::QuitPolicy::CanFinish(
            hosts.size() + developer_tool_count, pending_profiles.size(), initializing)) {
      loop_quit = true;
      CefQuitMessageLoop();
    }
  }

  void DestroyNativeView(CefRefPtr<CefBrowser> browser) {
    // Returning true from DoClose keeps CEF from closing the shell's NSWindow.
    // The browser is destroyed when its host NSView is released.
    NSView* view = (__bridge NSView*)browser->GetHost()->GetWindowHandle();
    if (view) [view removeFromSuperview];
  }

  // Shell-initiated close. A page-requested close (window.close) already went through DoClose,
  // which returned true: CEF then waits for the client to destroy the view, and a second
  // CloseBrowser alone never reaches OnBeforeClose.
  void CloseHost(Host& host) {
    host.closing_by_shell = true;
    auto browser = host.browser;
    const bool close_requested = host.close_requested;
    RevokeExtensionSurface(host);
    if (!browser) return;
    if (host.developer_browser) host.developer_browser->GetHost()->CloseBrowser(true);
    browser->GetHost()->CloseBrowser(true);
    if (close_requested) DestroyNativeView(browser);
  }

  // Tells the shell that the surface it made for a target will never get a browser, without
  // touching the bookkeeping of any other creation that uses the token.
  void NotifyAborted(uint64_t token, uint64_t profile, const char* reason) {
    ++aborted_creations;
    ACREvent event {};
    event.struct_size = sizeof(event);
    event.kind = ACR_EVENT_CREATE_ABORTED;
    event.surface_token = token;
    event.profile_token = profile;
    event.detail = reason;
    Send(event);
  }

  // A pending creation that will never produce OnAfterCreated.
  void AbortPending(uint64_t token, const char* reason) {
    const auto pending = pending_profiles.find(token);
    if (pending == pending_profiles.end()) return;
    const uint64_t profile = pending->second;
    pending_profiles.erase(token);
    pending_parents.erase(token);
    pending_windows.erase(token);
    queued_hosted_creations.erase(token);
    closed_before_creation.erase(token);
    for (auto it = pending_popups.begin(); it != pending_popups.end();) {
      if (it->second == token) it = pending_popups.erase(it);
      else ++it;
    }
    // Drain before callbacks: the shell may re-enter window/surface close.
    NotifyAborted(token, profile, reason);
    MaybeFinishQuit();
  }

  // Requests that can no longer be answered once their browser is gone.
  void CancelRequestsOf(uint64_t surface) {
    for (auto it = permissions.begin(); it != permissions.end();) {
      if (it->second.surface == surface) { CancelPermission(it->second); it = permissions.erase(it); }
      else ++it;
    }
    for (auto it = policies.begin(); it != policies.end();) {
      if (it->second.surface == surface) { it->second.callback->Cancel(); it = policies.erase(it); }
      else ++it;
    }
    CancelPageRequestsOf(surface);
  }

  // ABI 9: dialogs, credentials, choosers and menus of a closing browser or of the whole run.
  // surface 0 cancels every one. A JavaScript dialog callback released unanswered is cancelled
  // by CEF itself (CefJSDialogCallbackImpl).
  void CancelPageRequestsOf(uint64_t surface) {
    const auto matches = [surface](uint64_t owner) { return surface == 0 || owner == surface; };
    for (auto it = js_dialogs.begin(); it != js_dialogs.end();)
      it = matches(it->second.surface) ? js_dialogs.erase(it) : std::next(it);
    for (auto it = auths.begin(); it != auths.end();) {
      if (matches(it->second.surface)) { it->second.callback->Cancel(); it = auths.erase(it); }
      else ++it;
    }
    for (auto it = file_dialogs.begin(); it != file_dialogs.end();) {
      if (matches(it->second.surface)) { it->second.callback->Cancel(); it = file_dialogs.erase(it); }
      else ++it;
    }
    for (auto it = menus.begin(); it != menus.end();) {
      if (matches(it->second.surface)) { it->second.callback->Cancel(); it = menus.erase(it); }
      else ++it;
    }
    for (auto it = unresponsive.begin(); it != unresponsive.end();)
      it = matches(it->first) ? unresponsive.erase(it) : std::next(it);
  }

  std::string QuitDetail() const {
    std::string detail = "hosts=" + std::to_string(hosts.size())
        + " pending=" + std::to_string(pending_profiles.size())
        + " popups=" + std::to_string(pending_popups.size());
    for (const auto& [token, host] : hosts)
      detail += " host:" + std::to_string(token) + (host.close_requested ? ":page-close" : "")
          + (host.browser && host.browser->GetHost()->GetWindowHandle() ? ":view" : ":noview");
    for (const auto& [token, profile] : pending_profiles) detail += " pending:" + std::to_string(token);
    return detail;
  }
};

State* g_state = nullptr;  // Main/UI thread only.

void StopAuthenticationOperations(bool before_shutdown = false, bool after_shutdown = false) {
  if (!g_state) return;
  std::vector<std::shared_ptr<orbit_auth::Operation>> operations;
  for (const auto& [id, operation] : g_state->auth_operations) operations.push_back(operation);
  for (auto& operation : operations) {
    if (after_shutdown) operation->ShutdownComplete();
    else if (before_shutdown) operation->BeforeShutdown();
    else operation->Cancel();
  }
}

// CHROMIUM-APP-R3 (review MEDIUM 8): Safe Browsing cannot work without a Google API key (none is
// compiled in; the placeholder key is refused), yet Chromium keeps safebrowsing.enabled true. The
// preference is turned off in every profile, so that nothing claims a protection that does not
// exist; the shell shows Safe Browsing as unavailable. Pending the user's decision on a key.
void DisableSafeBrowsing(CefRefPtr<CefRequestContext> context) {
  if (!context) return;
  for (const char* name : {"safebrowsing.enabled", "safebrowsing.enhanced"}) {
    if (!context->HasPreference(name) || !context->CanSetPreference(name)) continue;
    CefRefPtr<CefValue> value = CefValue::Create();
    value->SetBool(false);
    CefString error;
    context->SetPreference(name, value, error);
  }
}

class ProfileHandler final : public CefRequestContextHandler {
 public:
  explicit ProfileHandler(uint64_t token) : token_(token) {}
  void OnRequestContextInitialized(CefRefPtr<CefRequestContext> context) override {
    CEF_REQUIRE_UI_THREAD();
    if (!g_state) return;
    g_state->ready_profiles.insert(token_);
    DisableSafeBrowsing(context);
    ACREvent event {};
    event.struct_size = sizeof(event);
    event.kind = ACR_EVENT_PROFILE_READY;
    event.profile_token = token_;
    g_state->Send(event);
    g_state->MaybeFinishQuit();
  }
 private:
  const uint64_t token_;
  IMPLEMENT_REFCOUNTING(ProfileHandler);
};

// Main-frame navigations only. The decision is asynchronous: CEF waits on the
// callback, the shell answers with ACRResolveNavigationPolicy on main.
class PolicyHandler final : public CefResourceRequestHandler {
 public:
  explicit PolicyHandler(uint64_t token) : token_(token) {}
  ReturnValue OnBeforeResourceLoad(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                                   CefRefPtr<CefRequest> request,
                                   CefRefPtr<CefCallback> callback) override {
    if (!frame || !frame->IsMain() || request->GetResourceType() != RT_MAIN_FRAME) return RV_CONTINUE;
    const std::string url = request->GetURL();
    const int32_t transition = request->GetTransitionType();
    const uint64_t token = token_;
    PostUI([token, url, callback, transition] {
      if (!g_state || g_state->quitting) { callback->Cancel(); return; }
      if (!g_state->hosts.contains(token)) { callback->Cancel(); return; }
      const uint64_t id = g_state->next_request++;
      g_state->policies[id] = {callback, token};
      auto event = g_state->Event(ACR_EVENT_NAVIGATION_POLICY, token);
      event.request_id = id;
      event.url = url.c_str();
      event.is_main_frame = 1;
      event.user_gesture = -1;  // Not exposed to resource handlers.
      event.value = transition;
      g_state->Send(event);
    });
    return RV_CONTINUE_ASYNC;
  }
 private:
  const uint64_t token_;
  IMPLEMENT_REFCOUNTING(PolicyHandler);
};

class DevToolsObserver final : public CefDevToolsMessageObserver {
 public:
  explicit DevToolsObserver(uint64_t token) : token_(token) {}
  void OnDevToolsEvent(CefRefPtr<CefBrowser>, const CefString& method,
                      const void* params, size_t params_size) override {
    CEF_REQUIRE_UI_THREAD();
    const std::string name = method;
    if (!g_state || (name != "WebAudio.contextCreated" && name != "WebAudio.contextChanged"
                     && name != "WebAudio.contextWillBeDestroyed" && name != "Media.playerEventsAdded"
                     && name != "Media.playerPropertiesChanged" && name != "Media.playersCreated")) return;
    auto event = g_state->Event(ACR_EVENT_MEDIA_ACTIVITY, token_);
    event.detail = name.c_str();
    event.payload = params;
    event.payload_size = params_size;
    g_state->Send(event);
  }
  void OnDevToolsMethodResult(CefRefPtr<CefBrowser>, int message_id, bool success,
                              const void* result, size_t result_size) override {
    CEF_REQUIRE_UI_THREAD();
    if (!g_state) return;
    // Browser-side methods can answer inside ExecuteDevToolsMethod. Deliver on the next UI
    // turn, after Swift has recorded that call's returned message ID and continuation.
    std::string bytes;
    if (result && result_size) bytes.assign(static_cast<const char*>(result), result_size);
    const uint64_t token = token_;
    PostUI([token, message_id, success, bytes = std::move(bytes)] {
      if (!g_state || !g_state->hosts.contains(token)) return;
      auto event = g_state->Event(ACR_EVENT_DEVTOOLS_RESULT, token);
      event.request_id = static_cast<uint64_t>(message_id);
      event.value = success ? 1 : 0;
      event.payload = bytes.data();
      event.payload_size = bytes.size();
      g_state->Send(event);
    });
  }
 private:
  const uint64_t token_;
  IMPLEMENT_REFCOUNTING(DevToolsObserver);
};

int32_t CreateBrowserIn(uint64_t token, uint64_t profile, void* parent, const std::string& url,
                        uint64_t window = 0, int32_t index = -1);

// ABI 6: window of an existing or pending surface (0 for Alloy).
uint64_t SurfaceWindow(uint64_t token) {
  const auto host = g_state->hosts.find(token);
  if (host != g_state->hosts.end()) return host->second.window;
  const auto pending = g_state->pending_windows.find(token);
  return pending == g_state->pending_windows.end() ? 0 : pending->second;
}

ACRKeyEvent MakeKeyEvent(uint64_t surface, uint64_t id, const CefKeyEvent& event, CefEventHandle os_event) {
  ACRKeyEvent key {};
  key.struct_size = sizeof(key);
  key.surface_token = surface;
  key.key_id = id;
  key.ns_event = os_event;  // NSEvent* (cef_event_handle_t is void* on macOS)
  key.type = event.type;
  key.modifiers = event.modifiers;
  key.windows_key_code = event.windows_key_code;
  key.native_key_code = event.native_key_code;
  key.focus_on_editable_field = event.focus_on_editable_field ? 1 : 0;
  return key;
}

std::string WriteJSON(CefRefPtr<CefDictionaryValue> dictionary) {
  auto value = CefValue::Create();
  value->SetDictionary(dictionary);
  return CefWriteJSON(value, JSON_WRITER_DEFAULT).ToString();
}

CefRefPtr<CefListValue> StringList(const std::vector<CefString>& strings) {
  auto list = CefListValue::Create();
  for (size_t index = 0; index < strings.size(); ++index) list->SetString(index, strings[index]);
  return list;
}

// Enabled command ids of Chrome's context menu model, submenus included.
void CollectEnabledCommands(CefRefPtr<CefMenuModel> model, std::set<int32_t>* ids, int depth = 0) {
  if (!model || depth > 4) return;
  for (size_t index = 0; index < model->GetCount(); ++index) {
    if (model->GetTypeAt(index) == MENUITEMTYPE_SUBMENU) {
      CollectEnabledCommands(model->GetSubMenuAt(index), ids, depth + 1);
      continue;
    }
    const int id = model->GetCommandIdAt(index);
    if (id > 0 && model->IsEnabledAt(index)) ids->insert(id);
  }
}

// Preserve Chrome's extension menu labels, nesting and native command IDs. Chromium reserves
// 1000 IDs from IDC_EXTENSIONS_CONTEXT_CUSTOM_FIRST (context_menu_matcher.cc).
CefRefPtr<CefListValue> ExtensionMenuItems(CefRefPtr<CefMenuModel> model,
                                         std::set<int32_t>* offered,
                                         bool ancestor_enabled = true, int depth = 0) {
  auto rows = CefListValue::Create();
  if (!model || depth > 6) return rows;
  const int first = cef_id_for_command_id_name("IDC_EXTENSIONS_CONTEXT_CUSTOM_FIRST");
  if (first <= 0) return rows;
  for (size_t index = 0; index < model->GetCount(); ++index) {
    if (!model->IsVisibleAt(index)) continue;
    const int id = model->GetCommandIdAt(index);
    const auto type = model->GetTypeAt(index);
    const bool enabled = ancestor_enabled && model->IsEnabledAt(index);
    const bool separator = type == MENUITEMTYPE_SEPARATOR;
    auto children = type == MENUITEMTYPE_SUBMENU
        ? ExtensionMenuItems(model->GetSubMenuAt(index), offered, enabled, depth + 1)
        : CefListValue::Create();
    if (type == MENUITEMTYPE_SUBMENU && children->GetSize() == 0) continue;
    if (children->GetSize() == 0 && (id < first || id > first + 1000) && !separator) continue;
    // Keep separators only inside an extension's subtree, never the surrounding Chrome groups.
    if (separator && depth == 0) continue;
    auto row = CefDictionaryValue::Create();
    row->SetInt("commandID", id);
    row->SetString("title", model->GetLabelAt(index));
    row->SetBool("isEnabled", enabled);
    row->SetBool("isChecked", model->IsCheckedAt(index));
    row->SetBool("isSeparator", separator);
    row->SetList("children", children);
    rows->SetDictionary(rows->GetSize(), row);
    if (enabled && !separator && type != MENUITEMTYPE_SUBMENU) offered->insert(id);
  }
  bool has_extension = false;
  for (size_t i = 0; i < rows->GetSize(); ++i)
    has_extension = has_extension || !rows->GetDictionary(i)->GetBool("isSeparator");
  if (!has_extension) rows->Clear();
  while (rows->GetSize() && rows->GetDictionary(0)->GetBool("isSeparator")) rows->Remove(0);
  while (rows->GetSize() && rows->GetDictionary(rows->GetSize() - 1)->GetBool("isSeparator"))
    rows->Remove(rows->GetSize() - 1);
  return rows;
}

void StartFavicon(uint64_t token);
void PumpFavicons();

class FaviconDownload final : public CefDownloadImageCallback {
 public:
  FaviconDownload(uint64_t lifetime, uint64_t token, uint64_t profile, uint64_t generation,
                  uint64_t epoch, int browser, std::string url)
      : lifetime_(lifetime), token_(token), profile_(profile), generation_(generation),
        epoch_(epoch), browser_(browser), url_(std::move(url)) {}
  void OnDownloadImageFinished(const CefString& image_url, int status, CefRefPtr<CefImage> image) override {
    CEF_REQUIRE_UI_THREAD();
    if (finished_.exchange(true)) return;
    if (!g_state || g_state->extension_lifetime != lifetime_) return;
    if (g_state->favicon_outstanding) --g_state->favicon_outstanding;
    auto* host = g_state->Find(token_);
    if (!host || host->profile != profile_ || host->browser->GetIdentifier() != browser_) {
      PumpFavicons();
      return;
    }
    host->favicon.active = false;
    if (host->closing_by_shell || g_state->quitting || IsTerminal(lifetime_) || !g_state->profiles.contains(profile_)) {
      PumpFavicons();
      return;
    }
    if (host->generation != generation_ || !host->favicon.Accept(epoch_, url_)) {
      PumpFavicons();  // At most one live request per browser, including obsolete requests.
      return;
    }
    auto bytes = orbit_bridge::ExtractFaviconPNG(image, image_url.ToString() == url_, status);
    if (!bytes.empty()) {
      auto event = g_state->Event(ACR_EVENT_FAVICON, token_);
      event.url = url_.c_str();
      event.request_id = epoch_;
      event.payload = bytes.data();
      event.payload_size = bytes.size();
      // Complete before Send: the receiver may navigate or close reentrantly.
      host->favicon.candidates.clear();
      host = nullptr;
      g_state->Send(event);
      if (g_state && g_state->extension_lifetime == lifetime_) PumpFavicons();
      return;
    }
    host->favicon.candidates.erase(host->favicon.candidates.begin());
    ++host->favicon.epoch;
    const auto next = host->favicon.candidates.empty() ? std::string() : host->favicon.candidates.front();
    const auto generation = host->generation;
    const auto revision = host->favicon.epoch;
    auto event = g_state->Event(ACR_EVENT_FAVICON, token_);
    event.url = next.empty() ? nullptr : next.c_str();
    event.request_id = revision;
    host = nullptr;
    g_state->Send(event);
    // Send may replace the runtime, Host, document or candidate synchronously.
    if (!g_state || g_state->extension_lifetime != lifetime_) return;
    const auto* current = g_state->Find(token_);
    if (!current || current->profile != profile_ || current->browser->GetIdentifier() != browser_ ||
        current->generation != generation || current->favicon.epoch != revision) return;
    PumpFavicons();
  }
 private:
  ~FaviconDownload() override {
    if (finished_.exchange(true)) return;
    auto release = [lifetime = lifetime_, token = token_, profile = profile_, browser = browser_] {
      if (!g_state || g_state->extension_lifetime != lifetime) return;
      if (g_state->favicon_outstanding) --g_state->favicon_outstanding;
      auto* host = g_state->Find(token);
      if (host && host->profile == profile && host->browser->GetIdentifier() == browser)
        host->favicon.active = false;
    };
    // Construction is UI-only. Its thread identity allows immediate slot release without
    // depending on a task runner that may already be shutting down. Pump remains deferred
    // so callback destruction cannot synchronously reenter DownloadImage's caller.
    if (std::this_thread::get_id() == ui_thread_) {
      release();
      if (!PostUI([lifetime = lifetime_] {
        if (g_state && g_state->extension_lifetime == lifetime) PumpFavicons();
      })) MarkTerminal(lifetime_);
    } else if (!PostUI([release = std::move(release), lifetime = lifetime_] {
      if (!g_state || g_state->extension_lifetime != lifetime) return;
      release();
      PumpFavicons();
    })) {
      // No foreign-thread g_state access. A failed UI post makes this receipt runtime
      // terminal: outstanding accounting is abandoned until State teardown, never reused.
      MarkTerminal(lifetime_);
    }
  }
 public:
  static bool IsTerminal(uint64_t lifetime) { return failed_post_lifetime_.load() == lifetime; }
 private:
  static void MarkTerminal(uint64_t lifetime) {
    auto previous = failed_post_lifetime_.load();
    while (previous < lifetime && !failed_post_lifetime_.compare_exchange_weak(previous, lifetime)) {}
  }
  inline static std::atomic<uint64_t> failed_post_lifetime_ {0};
  const std::thread::id ui_thread_ = std::this_thread::get_id();
  std::atomic<bool> finished_ {false};
  const uint64_t lifetime_, token_, profile_, generation_, epoch_;
  const int browser_;
  const std::string url_;
  IMPLEMENT_REFCOUNTING(FaviconDownload);
};

void StartFavicon(uint64_t token) {
  if (!g_state || g_state->quitting || FaviconDownload::IsTerminal(g_state->extension_lifetime)) return;
  auto* host = g_state->Find(token);
  if (!host || host->closing_by_shell || !host->favicon.CanStart(g_state->favicon_outstanding) ||
      !g_state->profiles.contains(host->profile)) return;
  const auto url = host->favicon.candidates.front();
  auto callback = new FaviconDownload(g_state->extension_lifetime, token, host->profile,
      host->generation, host->favicon.epoch, host->browser->GetIdentifier(), url);
  host->favicon.active = true;
  ++host->favicon.requests;
  ++g_state->favicon_outstanding;
  host->browser->GetHost()->DownloadImage(url, true, 64, false, callback);
}

void PumpFavicons() {
  if (!g_state || g_state->quitting) return;
  const auto lifetime = g_state->extension_lifetime;
  std::vector<uint64_t> tokens;
  for (const auto& [token, host] : g_state->hosts) tokens.push_back(token);
  for (const auto token : tokens) {
    if (!g_state || g_state->extension_lifetime != lifetime || g_state->favicon_outstanding >= 8) return;
    StartFavicon(token);
  }
}

class Client final : public CefClient, public CefLifeSpanHandler, public CefDisplayHandler,
                     public CefLoadHandler, public CefRequestHandler, public CefFindHandler,
                     public CefDownloadHandler, public CefPermissionHandler,
                     public CefKeyboardHandler, public CefJSDialogHandler, public CefDialogHandler,
                     public CefContextMenuHandler, public CefFocusHandler {
 public:
  Client(uint64_t token, uint64_t profile) : token_(token), profile_(profile) {}
  // EXT-OUTCOME-R2: an adopted Chrome-created tab's client that the framework releases without
  // creating its browser (it refused the offer after the shell answered) aborts its own pending
  // surface once, in its own runtime, after the framework's call returned. AbortPending acts only
  // while that token is still pending, so a created tab or another token is never touched.
  ~Client() override {
    if (!adopted_lifetime_ || browser_created_) return;
    const uint64_t token = token_, lifetime = adopted_lifetime_;
    PostUI([token, lifetime] {
      if (g_state && g_state->extension_lifetime == lifetime) g_state->AbortPending(token, "unowned-tab-not-created");
    });
  }
  void MarkAdopted(uint64_t lifetime) { adopted_lifetime_ = lifetime; }

  // ABI 9 (CH-ESSENTIALS): Chrome draws these with Views, absent in hosted mode.
  CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }
  CefRefPtr<CefDialogHandler> GetDialogHandler() override { return this; }
  CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return this; }

  // JavaScript dialogs. Chrome's default tab-modal dialog crashes in hosted mode
  // (JavaScriptTabModalDialogViewViews → CHECK(dialog_host)); every dialog goes to the shell, which
  // applies the dialog rules and answers once. Suppression answers the callback (never
  // suppress_message with a true return, which CEF CHECKs).
  bool OnJSDialog(CefRefPtr<CefBrowser>, const CefString& origin_url, JSDialogType dialog_type,
                  const CefString& message_text, const CefString& default_prompt_text,
                  CefRefPtr<CefJSDialogCallback> callback, bool& suppress_message) override {
    CEF_REQUIRE_UI_THREAD();
    if (!g_state || g_state->quitting || !g_state->hosts.contains(token_)) {
      suppress_message = true;
      return false;
    }
    const uint64_t id = g_state->next_request++;
    g_state->js_dialogs[id] = {callback, token_, false};
    const std::string origin = origin_url;
    const std::string message = message_text;
    const std::string prompt = default_prompt_text;
    auto event = g_state->Event(ACR_EVENT_JS_DIALOG, token_);
    event.request_id = id;
    event.value = dialog_type == JSDIALOGTYPE_CONFIRM ? 1 : dialog_type == JSDIALOGTYPE_PROMPT ? 2 : 0;
    event.url = origin.empty() ? nullptr : origin.c_str();
    event.detail = message.c_str();
    event.title = prompt.c_str();
    g_state->Send(event);
    return true;
  }

  // Navigation, reload and ACRRequestClose ask the user; a close the shell decided proceeds at once
  // (orbit_bridge::RouteBeforeUnload). Chrome's own beforeunload dialog would be an NSAlert sheet for
  // no window (alert.mm:223).
  bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser>, const CefString&, bool is_reload,
                            CefRefPtr<CefJSDialogCallback> callback) override {
    CEF_REQUIRE_UI_THREAD();
    Host* host = g_state ? g_state->Find(token_) : nullptr;
    if (orbit_bridge::RouteBeforeUnload(host != nullptr, g_state && g_state->quitting, host && host->closing_by_shell)
        == orbit_bridge::BeforeUnloadRoute::kProceed) {
      callback->Continue(true, CefString());
      return true;
    }
    const uint64_t id = g_state->next_request++;
    g_state->js_dialogs[id] = {callback, token_, true};
    auto event = g_state->Event(ACR_EVENT_JS_DIALOG, token_);
    event.request_id = id;
    event.value = 3;
    event.flags = is_reload ? 1 : 0;
    g_state->Send(event);
    return true;
  }

  void OnResetDialogState(CefRefPtr<CefBrowser>) override {
    CEF_REQUIRE_UI_THREAD();
    if (!g_state) return;
    bool dropped_close_question = false;
    for (auto it = g_state->js_dialogs.begin(); it != g_state->js_dialogs.end();) {
      if (it->second.surface != token_) { ++it; continue; }
      dropped_close_question |= it->second.before_unload;
      it = g_state->js_dialogs.erase(it);
    }
    g_state->Simple(ACR_EVENT_JS_DIALOG_RESET, token_);
    auto host = g_state->hosts.find(token_);
    if (dropped_close_question && host != g_state->hosts.end() && host->second.close_confirm) {
      host->second.close_confirm = false;
      g_state->Simple(ACR_EVENT_CLOSE_CANCELED, token_);
    }
  }

  // File choosers (all styles: CEF replaces Chrome's SelectFileDialog factory). A hosted folder
  // chooser is refused without the essentials patch: Chrome's upload confirmation that follows it
  // is a Views tab-modal dialog (file_select_helper.cc, chrome::ShowTabModal).
  bool OnFileDialog(CefRefPtr<CefBrowser>, FileDialogMode mode, const CefString& title,
                    const CefString& default_file_path, const std::vector<CefString>& accept_filters,
                    const std::vector<CefString>& accept_extensions, const std::vector<CefString>&,
                    CefRefPtr<CefFileDialogCallback> callback) override {
    CEF_REQUIRE_UI_THREAD();
    Host* host = g_state && !g_state->quitting ? g_state->Find(token_) : nullptr;
    if (!host) {
      callback->Cancel();
      return true;
    }
    if (mode == FILE_DIALOG_OPEN_FOLDER
        && !orbit_bridge::AllowsFolderChooser(host->window != 0, g_state->essentials_level)) {
      fprintf(stderr, "acr: folder chooser refused in a hosted tab (CEF essentials patch absent)\n");
      callback->Cancel();
      return true;
    }
    const uint64_t id = g_state->next_request++;
    g_state->file_dialogs[id] = {callback, token_};
    auto payload = CefDictionaryValue::Create();
    payload->SetInt("mode", mode == FILE_DIALOG_OPEN_MULTIPLE ? 1 : mode == FILE_DIALOG_OPEN_FOLDER ? 2
                            : mode == FILE_DIALOG_SAVE ? 3
                            // FILE_DIALOG_OPEN_EXISTING_FOLDER (4) exists only in the patched union SDK;
                            // compared numerically so this bridge still compiles on approved R2.
                            : static_cast<int>(mode) == 4 ? 4 : 0);
    payload->SetString("title", title);
    payload->SetString("defaultPath", default_file_path);
    payload->SetList("acceptTypes", StringList(accept_filters));
    payload->SetList("acceptExtensions", StringList(accept_extensions));
    const std::string json = WriteJSON(payload);
    auto event = g_state->Event(ACR_EVENT_FILE_DIALOG, token_);
    event.request_id = id;
    event.payload = json.data();
    event.payload_size = json.size();
    g_state->Send(event);
    return true;
  }

  // Page context menus. Chrome's RenderViewContextMenuMacCocoa needs a Views widget and shows
  // nothing in hosted mode; the shell builds an AppKit menu from these parameters and executes
  // Chrome commands it was offered through ACRResolveContextMenu.
  bool RunContextMenu(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, CefRefPtr<CefContextMenuParams> params,
                      CefRefPtr<CefMenuModel> model, CefRefPtr<CefRunContextMenuCallback> callback) override {
    CEF_REQUIRE_UI_THREAD();
    if (!g_state || g_state->quitting || !g_state->hosts.contains(token_)) {
      callback->Cancel();
      return true;
    }
    // One open menu per surface: a newer request replaces an unanswered one.
    for (auto it = g_state->menus.begin(); it != g_state->menus.end();) {
      if (it->second.surface == token_) { it->second.callback->Cancel(); it = g_state->menus.erase(it); }
      else ++it;
    }
    std::set<int32_t> enabled;
    CollectEnabledCommands(model, &enabled);
    PendingMenu pending {callback, token_, {}};
    auto commands = CefDictionaryValue::Create();
    for (const char* name : orbit_bridge::ContextMenuCommandNames()) {
      const int id = cef_id_for_command_id_name(name);
      if (id > 0 && enabled.contains(id)) {
        commands->SetInt(name, id);
        pending.offered.insert(id);
      }
    }
    std::vector<CefString> suggestions;
    params->GetDictionarySuggestions(suggestions);
    auto payload = CefDictionaryValue::Create();
    payload->SetInt("x", params->GetXCoord());
    payload->SetInt("y", params->GetYCoord());
    payload->SetInt("typeFlags", params->GetTypeFlags());
    payload->SetString("linkURL", params->GetLinkUrl());
    payload->SetString("sourceURL", params->GetSourceUrl());
    payload->SetString("pageURL", params->GetPageUrl());
    payload->SetString("frameURL", params->GetFrameUrl());
    payload->SetBool("hasImageContents", params->HasImageContents());
    payload->SetString("titleText", params->GetTitleText());
    payload->SetInt("mediaType", params->GetMediaType());
    payload->SetInt("mediaFlags", params->GetMediaStateFlags());
    payload->SetString("selectionText", params->GetSelectionText());
    payload->SetString("misspelledWord", params->GetMisspelledWord());
    payload->SetList("suggestions", StringList(suggestions));
    payload->SetBool("isEditable", params->IsEditable());
    payload->SetInt("editFlags", params->GetEditStateFlags());
    payload->SetDictionary("commands", commands);
    payload->SetList("extensionItems", ExtensionMenuItems(model, &pending.offered));
    const std::string json = WriteJSON(payload);
    const uint64_t id = g_state->next_request++;
    g_state->menus[id] = std::move(pending);
    auto event = g_state->Event(ACR_EVENT_CONTEXT_MENU, token_);
    event.request_id = id;
    event.payload = json.data();
    event.payload_size = json.size();
    g_state->Send(event);
    return true;
  }

  // ABI 7: only when the shell routes page-first keys; otherwise CEF's default handling.
  CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override {
    return g_state && g_state->callbacks.decide_key ? this : nullptr;
  }

  // Keyboard (ABI 7). Raw key downs reach the shell before the renderer; a tracked candidate
  // the page declines comes back once, through unhandled_key, and is then reported handled so
  // that CEF performs no second dispatch on a target that may have changed.
  bool OnPreKeyEvent(CefRefPtr<CefBrowser>, const CefKeyEvent& event, CefEventHandle os_event,
                     bool* is_keyboard_shortcut) override {
    CEF_REQUIRE_UI_THREAD();
    if (!g_state || g_state->quitting || !g_state->callbacks.decide_key
        || event.type != KEYEVENT_RAWKEYDOWN || !g_state->hosts.contains(token_)) return false;
    if (g_state->extension_shortcut) {
      const auto& host = g_state->hosts.at(token_);
      char action_id[33] = {};
      const int32_t answer = host.browser ? g_state->extension_shortcut(host.browser->GetIdentifier(),
          event.windows_key_code, event.modifiers, action_id, sizeof(action_id)) : 0;
      if (answer == 1) return true;
      if (answer == 2 && g_state && g_state->hosts.contains(token_)) {
        NSView* anchor = g_state->hosts.at(token_).extension_anchor;
        // Re-publish a restored visible tab before creating its popup lease.
        if (anchor && ACRActivateSurface(token_) == 1 && ACRPerformExtensionAction(token_, action_id, (__bridge void*)anchor) == 1) return true;
      }
    }
    auto key = MakeKeyEvent(token_, g_state->next_key++, event, os_event);
    int32_t track = 0;
    if (g_state->callbacks.decide_key(g_state->context, &key, &track) == 1) return true;
    if (track == 1 && os_event) {
      g_state->TrackKey(key.key_id, token_, (__bridge NSEvent*)os_event);
      *is_keyboard_shortcut = true;
    }
    return false;
  }
  bool OnKeyEvent(CefRefPtr<CefBrowser>, const CefKeyEvent& event, CefEventHandle os_event) override {
    CEF_REQUIRE_UI_THREAD();
    if (!g_state || (event.type != KEYEVENT_RAWKEYDOWN && event.type != KEYEVENT_KEYDOWN)) return false;
    NSEvent* ns_event = (__bridge NSEvent*)os_event;
    const uint64_t id = g_state->TakeTrackedKey(token_, ns_event);
    switch (orbit_bridge::AnswerUnhandledKey(id, State::WasKeyCandidate(ns_event))) {
      case orbit_bridge::UnhandledKeyAnswer::kDefault:
        return false;
      case orbit_bridge::UnhandledKeyAnswer::kConsumed:
        return true;  // Evicted receipt or closed surface: never redistributed without one.
      case orbit_bridge::UnhandledKeyAnswer::kReceipt:
        break;
    }
    if (!g_state->quitting && g_state->callbacks.unhandled_key) {
      auto key = MakeKeyEvent(token_, id, event, os_event);
      g_state->callbacks.unhandled_key(g_state->context, &key);
    }
    return true;
  }

  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return this; }
  CefRefPtr<CefFocusHandler> GetFocusHandler() override { return this; }
  bool OnSetFocus(CefRefPtr<CefBrowser>, FocusSource source) override {
    if (source == FOCUS_SOURCE_SYSTEM && g_state && !g_state->quitting && g_state->hosts.contains(token_))
      g_state->Simple(ACR_EVENT_ACTIVATION_REQUEST, token_);
    return false;
  }

  // Life span.
  bool OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame>, int popup_id,
                     const CefString& target_url, const CefString&, WindowOpenDisposition disposition,
                     bool user_gesture, const CefPopupFeatures&, CefWindowInfo& info,
                     CefRefPtr<CefClient>& client, CefBrowserSettings&, CefRefPtr<CefDictionaryValue>&,
                     bool*) override {
    CEF_REQUIRE_UI_THREAD();
    if (!g_state || g_state->quitting || !g_state->callbacks.decide_new_surface) return true;
    if (!g_state->hosts.contains(token_)) return true;  // Opener already closing on the shell side.
    const std::string url = target_url;
    uint64_t token = 0;
    void* parent = g_state->callbacks.decide_new_surface(g_state->context, token_, url.c_str(),
                                                         disposition, user_gesture, 1, &token);
    if (!parent || !token) return true;
    if (g_state->hosts.contains(token) || g_state->pending_profiles.contains(token)) {
      // The shell made a surface for this request: tell it that no browser will follow.
      g_state->NotifyAborted(token, profile_, "duplicate-token");
      return true;
    }
    NSView* view = (__bridge NSView*)parent;
    info.SetAsChild(parent, CefRect(0, 0, static_cast<int>(view.bounds.size.width),
                                    static_cast<int>(view.bounds.size.height)));
    info.runtime_style = CEF_RUNTIME_STYLE_CHROME;  // Observed override: parent view forces Alloy.
    // ABI 6: the popup of a hosted tab is a hosted tab of the same window.
    const uint64_t window = SurfaceWindow(token_);
    if (window) {
      if (!g_state->orbit || !g_state->windows.contains(window)
          || g_state->orbit->prepare_hosted_tab(parent, window, -1) != 1) {
        g_state->NotifyAborted(token, profile_, "hosted-popup-window-unavailable");
        return true;
      }
      g_state->pending_windows[token] = window;
    }
    client = new Client(token, profile_);
    g_state->pending_profiles[token] = profile_;
    g_state->pending_parents[token] = view;
    g_state->pending_popups[{browser->GetIdentifier(), popup_id}] = token;
    return false;
  }

  // Popup creation failed after OnBeforePopup allowed it (S: cef_life_span_handler.h). The
  // opener may already be closed, in which case IsValid() is false.
  void OnBeforePopupAborted(CefRefPtr<CefBrowser> browser, int popup_id) override {
    CEF_REQUIRE_UI_THREAD();
    if (!g_state) return;
    const auto found = g_state->pending_popups.find({browser->GetIdentifier(), popup_id});
    if (found == g_state->pending_popups.end()) return;
    const uint64_t token = found->second;
    g_state->pending_popups.erase(found);
    g_state->AbortPending(token, browser->IsValid() ? "popup-aborted" : "popup-aborted-opener-closed");
  }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD();
    browser_created_ = true;
    if (!g_state) return;
    g_state->pending_profiles.erase(token_);
    g_state->pending_parents.erase(token_);
    for (auto it = g_state->pending_popups.begin(); it != g_state->pending_popups.end();) {
      if (it->second == token_) it = g_state->pending_popups.erase(it);
      else ++it;
    }
    if (g_state->abandoned_popups.erase(token_)) {
      // The shell was told this popup would never exist (opener closed during creation).
      Host host;
      host.token = token_;
      host.profile = profile_;
      host.browser = browser;
      host.closing_by_shell = true;
      g_state->hosts[token_] = host;
      browser->GetHost()->CloseBrowser(true);
      return;
    }
    Host host;
    host.token = token_;
    host.profile = profile_;
    host.browser = browser;
    const auto pending_window = g_state->pending_windows.find(token_);
    if (pending_window != g_state->pending_windows.end()) {
      host.window = pending_window->second;
      g_state->pending_windows.erase(pending_window);
    }
    host.devtools = browser->GetHost()->AddDevToolsMessageObserver(new DevToolsObserver(token_));
    g_state->hosts[token_] = host;
    NSView* view = (__bridge NSView*)browser->GetHost()->GetWindowHandle();
    if (view) view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    auto created = g_state->Event(ACR_EVENT_CREATED, token_);
    created.value = browser->GetHost()->GetRuntimeStyle() == CEF_RUNTIME_STYLE_ALLOY ? 1 : 2;
    // ABI 6: extension tabId of a hosted tab (-1 otherwise).
    orbit_tab_info_t tab {};
    tab.struct_size = sizeof(tab);
    const bool has_tab = g_state->orbit && g_state->orbit->get_tab_info(browser->GetIdentifier(), &tab) == 1;
    created.detail_code = has_tab ? tab.tab_id : -1;
    PostUI([token = token_] { if (g_state) g_state->CaptureHostedIdentity(token); });
    g_state->Send(created);
    if (g_state->quitting || g_state->closed_before_creation.erase(token_)) {
      auto found = g_state->hosts.find(token_);
      if (found != g_state->hosts.end()) g_state->CloseHost(found->second);
    }
  }

  bool DoClose(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD();
    if (!g_state) return true;
    auto found = g_state->hosts.find(token_);
    if (found != g_state->hosts.end() && found->second.close_confirm) found->second.closing_by_shell = true;
    if (found != g_state->hosts.end() && !found->second.closing_by_shell) {
      // A page-initiated close (window.close). The shell decides; the browser
      // stays alive until the shell disposes the surface.
      if (!found->second.close_requested) {
        found->second.close_requested = true;
        g_state->Simple(ACR_EVENT_CLOSE_REQUEST, token_);
      }
      return true;
    }
    g_state->DestroyNativeView(browser);
    return true;
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD();
    if (!g_state) return;
    if (auto* host = g_state->Find(token_)) g_state->RevokeExtensionSurface(*host);
    g_state->CancelRequestsOf(token_);
    // Popups still being created by this opener: per the SDK, their state is cleared here
    // when OnBeforePopupAborted can no longer be delivered to a live opener.
    const int opener = browser->GetIdentifier();
    std::vector<uint64_t> orphaned;
    for (const auto& [key, token] : g_state->pending_popups)
      if (key.first == opener) orphaned.push_back(token);
    for (const uint64_t token : orphaned) {
      g_state->abandoned_popups.insert(token);
      g_state->AbortPending(token, "opener-closed");
    }
    g_state->key_receipts.ForgetSurface(token_);
    g_state->Simple(ACR_EVENT_CLOSED, token_);
    auto found = g_state->hosts.find(token_);
    if (found != g_state->hosts.end()) {
      if (found->second.developer_browser)
        found->second.developer_browser->GetHost()->CloseBrowser(true);
      found->second.devtools = nullptr;
      g_state->hosts.erase(found);
    }
    g_state->pending_profiles.erase(token_);
    g_state->pending_parents.erase(token_);
    g_state->pending_windows.erase(token_);
    g_state->MaybeFinishQuit();
  }

  // Display.
  // CEF calls OnLoadStart then OnAddressChange in the same DidFinishNavigation for a new document,
  // and only OnAddressChange for a same-document navigation (browser_contents_delegate.cc).
  void OnAddressChange(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, const CefString& url) override {
    if (!g_state || !frame->IsMain()) return;
    const std::string value = url;
    auto event = g_state->Event(ACR_EVENT_ADDRESS, token_);
    event.url = value.c_str();
    auto found = g_state->hosts.find(token_);
    if (found != g_state->hosts.end()) {
      event.value = found->second.load_start_reported ? 0 : 1;
      found->second.load_start_reported = false;
    }
    g_state->Send(event);
  }
  void OnTitleChange(CefRefPtr<CefBrowser>, const CefString& title) override {
    if (!g_state) return;
    const std::string value = title;
    auto event = g_state->Event(ACR_EVENT_TITLE, token_);
    event.title = value.c_str();
    g_state->Send(event);
  }
  void OnFaviconURLChange(CefRefPtr<CefBrowser> browser, const std::vector<CefString>& urls) override {
    if (!g_state || g_state->quitting) return;
    auto* host = g_state->Find(token_);
    if (!host || host->closing_by_shell || host->profile != profile_ ||
        host->browser->GetIdentifier() != browser->GetIdentifier()) return;
    std::vector<std::string> values;
    for (size_t i = 0; i < urls.size() && i < 16; ++i) {
      if (urls[i].length() <= 8192) values.push_back(urls[i].ToString());
    }
    host->favicon.Announce(values);
    const auto value = host->favicon.candidates.empty() ? std::string() : host->favicon.candidates.front();
    auto event = g_state->Event(ACR_EVENT_FAVICON, token_);
    event.url = value.empty() ? nullptr : value.c_str();
    event.request_id = host->favicon.epoch;
    const auto lifetime = g_state->extension_lifetime;
    const auto generation = host->generation;
    const auto revision = host->favicon.epoch;
    const auto browser_id = host->browser->GetIdentifier();
    const auto token = token_;
    const auto profile = profile_;
    host = nullptr;
    g_state->Send(event);
    if (!g_state || g_state->extension_lifetime != lifetime) return;
    const auto* current = g_state->Find(token);
    if (!current || current->profile != profile || current->browser->GetIdentifier() != browser_id ||
        current->generation != generation || current->favicon.epoch != revision) return;
    StartFavicon(token);
  }
  // ABI 9: element fullscreen. Chrome style sizes the element to the tab's view; the shell gives
  // that view the screen. Leaving needs the logical Browser to report fullscreen (native window
  // fullscreen, or the essentials patch): fullscreen_controller.cc:290-292.
  void OnFullscreenModeChange(CefRefPtr<CefBrowser>, bool fullscreen) override {
    if (g_state) g_state->Simple(ACR_EVENT_FULLSCREEN, token_, fullscreen ? 1 : 0);
  }
  void OnMediaAccessChange(CefRefPtr<CefBrowser>, bool video, bool audio) override {
    if (!g_state) return;
    auto event = g_state->Event(ACR_EVENT_AUDIO, token_);
    event.value = -1;  // Audibility is not exposed by the stock API.
    event.flags = (video ? 1 : 0) | (audio ? 2 : 0);
    g_state->Send(event);
  }

  // Load.
  void OnLoadingStateChange(CefRefPtr<CefBrowser>, bool loading, bool back, bool forward) override {
    if (!g_state) return;
    auto event = g_state->Event(ACR_EVENT_LOADING, token_);
    event.value = loading ? 1 : 0;
    event.flags = (back ? 1 : 0) | (forward ? 2 : 0);
    g_state->Send(event);
  }
  void OnLoadStart(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, TransitionType transition) override {
    if (!g_state || !frame->IsMain()) return;
    auto found = g_state->hosts.find(token_);
    if (found != g_state->hosts.end()) {
      ++found->second.generation;
      found->second.favicon.Reset();
      found->second.load_start_reported = true;
    }
    const std::string url = frame->GetURL();
    auto event = g_state->Event(ACR_EVENT_DOCUMENT, token_);
    event.url = url.c_str();
    event.value = transition;
    g_state->Send(event);
  }
  void OnLoadEnd(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, int status) override {
    if (!g_state || !frame->IsMain()) return;
    g_state->Simple(ACR_EVENT_LOAD_END, token_, status);
  }
  void OnLoadError(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, ErrorCode code,
                   const CefString&, const CefString& failed) override {
    if (!g_state || !frame->IsMain()) return;
    const std::string url = failed;
    auto event = g_state->Event(ACR_EVENT_LOAD_ERROR, token_);
    event.value = code;
    event.url = url.c_str();
    g_state->Send(event);
  }

  // Requests.
  bool OnOpenURLFromTab(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, const CefString& target_url,
                        WindowOpenDisposition disposition, bool user_gesture) override {
    CEF_REQUIRE_UI_THREAD();
    if (disposition == CEF_WOD_CURRENT_TAB) return false;
    if (!g_state || g_state->quitting || !g_state->callbacks.decide_new_surface) return true;
    const std::string url = target_url;
    uint64_t token = 0;
    void* parent = g_state->callbacks.decide_new_surface(g_state->context, token_, url.c_str(),
                                                         disposition, user_gesture, 2, &token);
    // Stock CEF cannot hand over the pending navigation here: the new browser
    // issues a fresh request without opener or POST body.
    if (parent && token && CreateBrowserIn(token, profile_, parent, url, SurfaceWindow(token_), -1) == 0)
      g_state->NotifyAborted(token, profile_, "create-failed");  // The shell made a surface already.
    return true;
  }
  bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefRefPtr<CefRequest> request,
                      bool user_gesture, bool is_redirect) override {
    CEF_REQUIRE_UI_THREAD();
    if (!g_state || g_state->quitting) return true;
    if (!g_state->callbacks.decide_navigation) return false;
    const std::string url = request->GetURL();
    const std::string method = request->GetMethod();
    if (frame && frame->IsMain()) {
      Host* host = g_state->Find(token_);
      if (host && host->extension_manager_route.Allow(url, frame->GetURL().ToString(),
                                                     is_redirect, method)) return false;
    }
    ACRNavigationInfo info {};
    info.struct_size = sizeof(info);
    info.url = url.c_str();
    info.is_main_frame = frame && frame->IsMain() ? 1 : 0;
    info.user_gesture = user_gesture ? 1 : 0;
    info.is_redirect = is_redirect ? 1 : 0;
    info.transition_type = static_cast<uint32_t>(request->GetTransitionType());
    info.method = method.empty() ? nullptr : method.c_str();
    info.has_body = request->GetPostData() ? 1 : 0;
    const int32_t policy = g_state->callbacks.decide_navigation(g_state->context, token_, &info);
    if (policy == ACR_POLICY_DOWNLOAD) {
      // Replay as a download: a new GET, POST bodies and the navigation are lost.
      browser->GetHost()->StartDownload(url);
      return true;
    }
    if (policy == ACR_POLICY_ALLOW && frame && frame->IsMain()) {
      if (auto* host = g_state ? g_state->Find(token_) : nullptr) {
        ++host->favicon.epoch;
        host->favicon.candidates.clear();
      }
    }
    return policy != ACR_POLICY_ALLOW;
  }
  CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(
      CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, CefRefPtr<CefRequest>, bool is_navigation,
      bool is_download, const CefString&, bool&) override {
    // Installing a resource handler routes requests through CEF's browser-bound
    // proxy; keep it to the explicit laboratory measurement.
    if (!g_state || !g_state->async_hold || !is_navigation || is_download || !frame || !frame->IsMain())
      return nullptr;
    return new PolicyHandler(token_);
  }
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser>, TerminationStatus status, int,
                                 const CefString&) override {
    if (!g_state) return;
    g_state->unresponsive.erase(token_);
    g_state->Simple(ACR_EVENT_RENDER_TERMINATED, token_, status);
  }

  // ABI 9: Chrome's hung-renderer dialog is Views (hung_renderer_view.cc) and crashes in hosted
  // mode; the shell shows its own and answers with ACRResolveUnresponsive.
  bool OnRenderProcessUnresponsive(CefRefPtr<CefBrowser>,
                                   CefRefPtr<CefUnresponsiveProcessCallback> callback) override {
    CEF_REQUIRE_UI_THREAD();
    if (!g_state || g_state->quitting || !g_state->hosts.contains(token_)) {
      callback->Wait();
      return true;
    }
    g_state->unresponsive[token_] = callback;
    g_state->Simple(ACR_EVENT_UNRESPONSIVE, token_, 1);
    return true;
  }
  void OnRenderProcessResponsive(CefRefPtr<CefBrowser>) override {
    if (!g_state || !g_state->unresponsive.erase(token_)) return;
    g_state->Simple(ACR_EVENT_UNRESPONSIVE, token_, 0);
  }

  // ABI 9: HTTP authentication, IO thread (requires --disable-chrome-login-prompt: Chrome's
  // LoginHandlerViews crashes in hosted mode). The question moves to the UI thread.
  bool GetAuthCredentials(CefRefPtr<CefBrowser>, const CefString& origin_url, bool is_proxy,
                          const CefString& host, int port, const CefString& realm, const CefString& scheme,
                          CefRefPtr<CefAuthCallback> callback) override {
    const uint64_t token = token_;
    const std::string origin = origin_url, server = host, realm_value = realm, scheme_value = scheme;
    PostUI([token, origin, server, port, realm_value, scheme_value, is_proxy, callback] {
      if (!g_state || g_state->quitting || !g_state->hosts.contains(token)) { callback->Cancel(); return; }
      const uint64_t id = g_state->next_request++;
      g_state->auths[id] = {callback, token};
      auto payload = CefDictionaryValue::Create();
      payload->SetString("origin", origin);
      payload->SetString("host", server);
      payload->SetInt("port", port);
      payload->SetString("realm", realm_value);
      payload->SetString("scheme", scheme_value);
      payload->SetBool("proxy", is_proxy);
      const std::string json = WriteJSON(payload);
      auto event = g_state->Event(ACR_EVENT_AUTH, token);
      event.request_id = id;
      event.payload = json.data();
      event.payload_size = json.size();
      g_state->Send(event);
    });
    return true;
  }

  // Find.
  void OnFindResult(CefRefPtr<CefBrowser>, int identifier, int count, const CefRect&,
                    int ordinal, bool final_update) override {
    if (!g_state) return;
    auto event = g_state->Event(ACR_EVENT_FIND_RESULT, token_);
    event.request_id = static_cast<uint64_t>(identifier);
    event.value = count;
    event.flags = ordinal;
    event.detail_code = final_update ? 1 : 0;
    g_state->Send(event);
  }

  // Downloads. Item objects are never retained beyond the callback.
  // Every download the framework offers reaches the shell. CefDownloadItem exposes no native
  // owner, so no public URL/MIME/document shape may hide one here: the Web Store installer's own
  // transfer (DownloadSource::EXTENSION_INSTALLER) is kept away from the client by the patched
  // framework itself (cef-patches/installer-downloads-r1), never by a bridge heuristic.
  bool OnBeforeDownload(CefRefPtr<CefBrowser>, CefRefPtr<CefDownloadItem> item, const CefString& suggested,
                        CefRefPtr<CefBeforeDownloadCallback> callback) override {
    CEF_REQUIRE_UI_THREAD();
    if (!g_state || g_state->quitting) return true;  // Destroyed callback cancels.
    const uint64_t id = g_state->next_request++;
    g_state->destinations[id] = {token_, profile_, callback};
    SendDownload(item, id, suggested);
    return true;
  }
  void OnDownloadUpdated(CefRefPtr<CefBrowser>, CefRefPtr<CefDownloadItem> item,
                         CefRefPtr<CefDownloadItemCallback> callback) override {
    CEF_REQUIRE_UI_THREAD();
    // After ACRBeginQuit cancelled and dropped every item callback, a late update must neither
    // re-retain a callback nor reach a shell that is tearing its windows down.
    if (!g_state || g_state->quitting) return;
    const auto key = std::make_pair(profile_, item->GetId());
    if (item->IsComplete() || item->IsCanceled()) g_state->downloads.erase(key);
    else g_state->downloads[key] = callback;
    SendDownload(item, 0, item->GetSuggestedFileName());
  }

  // Permissions.
  bool OnRequestMediaAccessPermission(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                                      const CefString& origin, uint32_t mask,
                                      CefRefPtr<CefMediaAccessCallback> callback) override {
    if (!g_state || g_state->quitting || !g_state->hosts.contains(token_)) return false;
    const uint64_t id = g_state->next_request++;
    g_state->permissions[id] = {callback, nullptr, mask, token_, 0};
    SendPermission(id, origin, mask, frame && frame->IsMain(), 1);
    return true;
  }
  bool OnShowPermissionPrompt(CefRefPtr<CefBrowser>, uint64_t prompt_id, const CefString& origin,
                              uint32_t mask, CefRefPtr<CefPermissionPromptCallback> callback) override {
    if (!g_state || g_state->quitting || !g_state->hosts.contains(token_)) return false;
    const uint64_t id = g_state->next_request++;
    g_state->permissions[id] = {nullptr, callback, mask, token_, prompt_id};
    SendPermission(id, origin, mask, 1, 2);
    return true;
  }
  // CEF dismissed the prompt itself (navigation, close): the callback is no longer answerable.
  void OnDismissPermissionPrompt(CefRefPtr<CefBrowser>, uint64_t prompt_id,
                                 cef_permission_request_result_t) override {
    if (!g_state) return;
    for (auto it = g_state->permissions.begin(); it != g_state->permissions.end(); ++it) {
      if (it->second.prompt && it->second.surface == token_ && it->second.prompt_id == prompt_id) {
        g_state->permissions.erase(it);
        return;
      }
    }
  }

 private:
  void SendDownload(CefRefPtr<CefDownloadItem> item, uint64_t request, const CefString& suggested) {
    const std::string url = item->GetOriginalUrl();
    const std::string path = item->GetFullPath();
    const std::string name = suggested;
    auto event = g_state->Event(ACR_EVENT_DOWNLOAD, token_);
    event.profile_token = profile_;
    event.request_id = request;
    event.url = url.c_str();
    event.download_id = item->GetId();
    event.download_status = item->IsComplete() ? ACR_DOWNLOAD_COMPLETE
        : item->IsCanceled() ? ACR_DOWNLOAD_CANCELED
        : item->IsInterrupted() ? ACR_DOWNLOAD_INTERRUPTED
        : item->IsInProgress() ? ACR_DOWNLOAD_IN_PROGRESS : ACR_DOWNLOAD_PENDING;
    event.download_paused = item->IsPaused() ? 1 : 0;
    event.download_interrupt_reason = item->GetInterruptReason();
    event.received_bytes = item->GetReceivedBytes();
    event.total_bytes = item->GetTotalBytes();
    event.download_path = path.empty() ? nullptr : path.c_str();
    event.suggested_name = name.c_str();
    g_state->Send(event);
  }

  void SendPermission(uint64_t id, const CefString& origin, uint32_t mask, int main, int code) {
    const std::string value = origin;
    auto event = g_state->Event(ACR_EVENT_PERMISSION, token_);
    event.request_id = id;
    event.url = value.c_str();
    event.permission_mask = mask;
    event.is_main_frame = main;
    event.detail_code = code;  // 1 media access, 2 permission prompt.
    g_state->Send(event);
  }

  const uint64_t token_;
  const uint64_t profile_;
  uint64_t adopted_lifetime_ = 0;
  bool browser_created_ = false;
  IMPLEMENT_REFCOUNTING(Client);
};

// EXT-OUTCOME-R1: the profile token of a Chrome-created tab's logical Browser: an admitted,
// ready, persistent or ephemeral request context of this runtime, never the global context or
// a synthetic authenticated-import target. 0 when none matches.
uint64_t UnownedTabProfile(const char* path) {
  if (!path || !*path) return 0;
  const std::string value(path);
  for (const auto& [token, paths] : g_state->profile_paths) {
    if (paths.first == "@global" || (paths.first != value && paths.second != value)) continue;
    const auto context = g_state->profiles.find(token);
    if (!g_state->ready_profiles.contains(token) || g_state->auth_targets.contains(token) ||
        context == g_state->profiles.end() || !context->second || context->second->IsGlobal()) return 0;
    return token;
  }
  return 0;
}

// EXT-OUTCOME-R1/R2 (patched framework, OrbitUnownedTabsApi.h): Chrome is creating a tab by
// itself in an Orbit logical Browser. The shell records a pending surface for it; the tab gets
// that surface's client and parent view, exactly like a popup accepted in OnBeforePopup.
// The shell callback can close the window, remove or unready the profile, clear the handler or
// quit: every authority checked before it is captured and verified again afterwards, and a
// refusal after the shell answered aborts that surface exactly once.
struct _cef_client_t* AdoptUnownedTab(void*, const orbit_unowned_tab_t* tab, void** parent_nsview) {
  if (parent_nsview) *parent_nsview = nullptr;
  if (!NSThread.isMainThread || !g_state || !g_state->initialized || g_state->quitting || !tab ||
      !parent_nsview || tab->struct_size < sizeof(orbit_unowned_tab_t) ||
      !g_state->callbacks.adopt_engine_tab || !g_state->windows.contains(tab->window_token)) return nullptr;
  auto* const runtime = g_state;
  const uint64_t lifetime = runtime->extension_lifetime;
  const uint64_t registration = runtime->unowned_handler_generation;
  const auto adopt = runtime->callbacks.adopt_engine_tab;
  const uint64_t window = tab->window_token;
  const auto handle = runtime->shell_window_handles.find(window);
  if (handle == runtime->shell_window_handles.end() || !handle->second) return nullptr;
  void* const native_window = handle->second;
  const std::string path = tab->profile_path ? tab->profile_path : "";
  const uint64_t profile = UnownedTabProfile(path.c_str());
  if (!profile) return nullptr;
  const CefRefPtr<CefRequestContext> context = runtime->profiles.at(profile);
  uint64_t token = 0;
  void* parent = adopt(runtime->context, window, profile, tab->url ? tab->url : "",
                       tab->active == 1 ? 1 : 0, &token);
  if (!parent || !token) return nullptr;
  const auto authority_unchanged = [&] {
    if (g_state != runtime || runtime->extension_lifetime != lifetime || !runtime->initialized ||
        runtime->quitting || runtime->unowned_handler_generation != registration ||
        runtime->callbacks.adopt_engine_tab != adopt || !runtime->windows.contains(window)) return false;
    const auto current = runtime->shell_window_handles.find(window);
    if (current == runtime->shell_window_handles.end() || current->second != native_window) return false;
    if (UnownedTabProfile(path.c_str()) != profile) return false;
    const auto now = runtime->profiles.find(profile);
    return now != runtime->profiles.end() && now->second && now->second->IsSame(context);
  };
  // A view already shown elsewhere is never this window's new tab (a detached view is placed
  // by the shell when it presents the tab).
  NSView* const view = (__bridge NSView*)parent;
  const bool view_ok = [view isKindOfClass:[NSView class]] &&
      (!view.window || (__bridge void*)view.window == native_window);
  if (runtime->hosts.contains(token) || runtime->pending_profiles.contains(token)) {
    // A token already in use belongs to another surface: never abort or reuse it.
    return nullptr;
  }
  if (!authority_unchanged() || !view_ok) {
    if (g_state == runtime && runtime->extension_lifetime == lifetime) {
      runtime->NotifyAborted(token, profile, "unowned-tab-authority-revoked");
    }
    return nullptr;
  }
  CefRefPtr<Client> client = new Client(token, profile);
  client->MarkAdopted(lifetime);
  runtime->pending_profiles[token] = profile;
  runtime->pending_parents[token] = view;
  runtime->pending_windows[token] = window;
  *parent_nsview = parent;
  return orbit_bridge::WrapClientForFramework(client);
}

// Keep hosted requests in the bridge until their profile and logical Browser are usable. CEF's
// asynchronous CreateBrowser would capture the request now and bypass the drain guard later.
// The retained parent and the immutable window/profile remain in the existing pending maps.
int32_t RunHostedCreation(uint64_t token) {
  if (!g_state || !g_state->queued_hosted_creations.contains(token)) return 0;
  const uint64_t window = g_state->pending_windows.at(token);
  const uint64_t profile = g_state->pending_profiles.at(token);
  if (g_state->quitting || !g_state->windows.contains(window) || g_state->closed_before_creation.contains(token)) {
    g_state->AbortPending(token, "hosted-creation-cancelled");
    return 0;
  }
  auto& queued = g_state->queued_hosted_creations.at(token);
  const bool ready = g_state->ready_profiles.contains(profile);
  const bool represented = g_state->HostedBrowsersRepresented(window);
  if (!ready || !represented) {
    if (!represented && !queued.drain_reported) {
      queued.drain_reported = true;
      fprintf(stderr, "acr: hosted creation deferred token=%llu window=%llu profile=%llu logical=%d\n",
              token, window, profile, g_state->orbit->window_browser_count(window));
    }
    if (std::chrono::steady_clock::now() >= queued.deadline
        || !CefPostDelayedTask(TID_UI, new FunctionTask([token] { RunHostedCreation(token); }), 10)) {
      g_state->AbortPending(token, ready ? "hosted-browser-drain-timeout" : "hosted-profile-not-ready");
      return 0;
    }
    return 1;
  }
  const auto request = queued;
  NSView* view = g_state->pending_parents.at(token);
  g_state->queued_hosted_creations.erase(token);
  if (g_state->orbit->prepare_hosted_tab((__bridge void*)view, window, request.index) != 1) {
    g_state->AbortPending(token, "hosted-window-unavailable");
    return 0;
  }
  CefWindowInfo info;
  info.SetAsChild((__bridge void*)view, CefRect(0, 0, static_cast<int>(view.bounds.size.width),
                                                static_cast<int>(view.bounds.size.height)));
  info.runtime_style = CEF_RUNTIME_STYLE_CHROME;
  CefBrowserSettings settings;
  const auto context = g_state->profiles.at(profile);
  const auto browser = CefBrowserHost::CreateBrowserSync(
      info, new Client(token, profile), request.url, settings, nullptr, context);
  if (!browser) {
    g_state->orbit->cancel_hosted_tab((__bridge void*)view);
    g_state->AbortPending(token, "hosted-create-refused");
    return 0;
  }
  g_state->CaptureHostedIdentity(token);
  return 2;
}

int32_t CreateBrowserIn(uint64_t token, uint64_t profile, void* parent, const std::string& url,
                        uint64_t window, int32_t index) {
  CEF_REQUIRE_UI_THREAD();
  if (!g_state || g_state->quitting || !parent || !token || g_state->hosts.contains(token)
      || g_state->pending_profiles.contains(token)) return 0;
  if (g_state->auth_targets.contains(profile)) return 0;
  const auto context = g_state->profiles.find(profile);
  if (context == g_state->profiles.end()) return 0;
  if (window) {
    if (!g_state->orbit || !g_state->windows.contains(window)) return 0;
    g_state->pending_windows[token] = window;
    g_state->pending_profiles[token] = profile;
    g_state->pending_parents[token] = (__bridge NSView*)parent;
    g_state->queued_hosted_creations[token] = {url, index,
        std::chrono::steady_clock::now() + std::chrono::seconds(10), false};
    return RunHostedCreation(token);
  }
  NSView* view = (__bridge NSView*)parent;
  CefWindowInfo info;
  info.SetAsChild(parent, CefRect(0, 0, static_cast<int>(view.bounds.size.width),
                                  static_cast<int>(view.bounds.size.height)));
  info.runtime_style = CEF_RUNTIME_STYLE_CHROME;  // Measured: parent_view overrides it to Alloy.
  CefBrowserSettings settings;
  CefRefPtr<Client> client = new Client(token, profile);
  g_state->pending_profiles[token] = profile;
  g_state->pending_parents[token] = view;  // CEF keeps only a raw parent pointer until creation.
  auto browser = CefBrowserHost::CreateBrowserSync(info, client, url, settings, nullptr, context->second);
  if (browser) return 2;
  // CreateBrowserSync refuses a context whose initialization is still pending.
  if (CefBrowserHost::CreateBrowser(info, client, url, settings, nullptr, context->second)) return 1;
  g_state->pending_profiles.erase(token);
  g_state->pending_parents.erase(token);
  g_state->pending_windows.erase(token);
  return 0;
}

// ABI 6: the patched CEF exports one symbol, orbit_cef_get_api. The wrapper's
// library loader keeps its dlopen handle private; take a second reference to
// the already loaded framework (RTLD_NOLOAD) at the loader's own path.
const orbit_cef_api_t* ResolveOrbitApi() {
  NSString* executable = [[NSBundle mainBundle] executablePath];
  NSString* path = [[[executable stringByDeletingLastPathComponent]
      stringByAppendingPathComponent:@"../Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework"]
      stringByStandardizingPath];
  void* handle = dlopen(path.fileSystemRepresentation, RTLD_LAZY | RTLD_LOCAL | RTLD_NOLOAD);
  if (!handle) return nullptr;
  const auto get = reinterpret_cast<orbit_cef_get_api_t>(orbit_engine::ResolveSymbol(handle, "orbit_cef_get_api"));
  // The newest side API the framework has: v3 (transfer holds), v2 (move_tab, profile_loaded) or
  // v1. Each version's layout is the prefix of the next; a function beyond the resolved version
  // is never called.
  const orbit_cef_api_t* api = nullptr;
  const std::pair<uint32_t, size_t> versions[] = {{4u, sizeof(orbit_cef_api_t)},
                                                   {3u, offsetof(orbit_cef_api_t, extensions_snapshot)},
                                                   {2u, offsetof(orbit_cef_api_t, hold_window)},
                                                   {1u, offsetof(orbit_cef_api_t, move_tab)}};
  for (const auto& [version, size] : versions) {
    const orbit_cef_api_t* candidate = get ? get(version) : nullptr;
    if (candidate && candidate->version == version && candidate->struct_size >= size) {
      api = candidate;
      break;
    }
  }
  dlclose(handle);  // The loader's reference keeps the framework loaded.
  return api;
}

// ABI 9: the CEF essentials patch (cef-patches/pending/ch-essentials-*.patch) exports its level
// beside the side API, independently of the side API version (owned by other lots).
uint32_t ResolveEssentialsLevel() {
  NSString* executable = [[NSBundle mainBundle] executablePath];
  NSString* path = [[[executable stringByDeletingLastPathComponent]
      stringByAppendingPathComponent:@"../Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework"]
      stringByStandardizingPath];
  void* handle = dlopen(path.fileSystemRepresentation, RTLD_LAZY | RTLD_LOCAL | RTLD_NOLOAD);
  if (!handle) return 0;
  using LevelFunction = uint32_t (*)();
  const auto level = reinterpret_cast<LevelFunction>(orbit_engine::ResolveSymbol(handle, "orbit_cef_essentials_level"));
  const uint32_t value = level ? level() : 0;
  dlclose(handle);
  return value;
}

// EXT-OUTCOME-R1: the unowned-tabs patch exports its registration beside the side API.
orbit_cef_set_unowned_tab_handler_t ResolveUnownedTabRegistration() {
  NSString* executable = [[NSBundle mainBundle] executablePath];
  NSString* path = [[[executable stringByDeletingLastPathComponent]
      stringByAppendingPathComponent:@"../Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework"]
      stringByStandardizingPath];
  void* handle = dlopen(path.fileSystemRepresentation, RTLD_LAZY | RTLD_LOCAL | RTLD_NOLOAD);
  if (!handle) return nullptr;
  const auto set = reinterpret_cast<orbit_cef_set_unowned_tab_handler_t>(
      orbit_engine::ResolveSymbol(handle, "orbit_cef_set_unowned_tab_handler"));
  dlclose(handle);  // The loader keeps its own reference for the process lifetime.
  return set;
}

template <typename Function>
Function ResolveExtensionToolbarFunction(const char* name) {
  NSString* executable = [[NSBundle mainBundle] executablePath];
  NSString* path = [[[executable stringByDeletingLastPathComponent]
      stringByAppendingPathComponent:@"../Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework"]
      stringByStandardizingPath];
  void* handle = dlopen(path.fileSystemRepresentation, RTLD_LAZY | RTLD_LOCAL | RTLD_NOLOAD);
  if (!handle) return nullptr;
  const auto function = reinterpret_cast<Function>(orbit_engine::ResolveSymbol(handle, name));
  dlclose(handle);
  return function;
}

// Chrome's default profile directory (chrome::kInitialProfile), reserved by CanonicalChild.
constexpr char kInitialProfileDirectory[] = "Default";
bool SameDirectory(const std::string& a, const std::string& b);

class App final : public CefApp, public CefBrowserProcessHandler {
 public:
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }
  void OnBeforeCommandLineProcessing(const CefString&, CefRefPtr<CefCommandLine> command) override {
    // ABI 7: the mock Keychain only for runs configured with it (every automated run); the
    // product build uses its real Keychain item instead, never both.
    if (!g_state || g_state->secure_storage != ACR_SECURE_STORAGE_KEYCHAIN)
      command->AppendSwitch("use-mock-keychain");
    // ABI 8: the network policy chooses the switches (orbit_bridge::NetworkPolicy); hermetic
    // unless the run asked for the product policy.
    const auto policy = g_state && g_state->network_policy == ACR_NETWORK_PRODUCT
        ? orbit_bridge::NetworkPolicy::kProduct : orbit_bridge::NetworkPolicy::kHermetic;
    for (const auto& item : orbit_bridge::BrowserSwitches(policy)) {
      if (item.value.empty()) command->AppendSwitch(item.name);
      else command->AppendSwitchWithValue(item.name, item.value);
    }
    // Disabled features of the allow-listed arguments, the extra switches and the policy, as one
    // value (the filtered argv carries none itself).
    std::vector<std::string> disabled = {command->GetSwitchValue("disable-features").ToString()};
    if (g_state) disabled.insert(disabled.end(), g_state->disabled_features.begin(), g_state->disabled_features.end());
    if (g_state) {
      for (const auto& value : g_state->switches) {
        const auto separator = value.find('=');
        const std::string name = value.substr(2, separator == std::string::npos ? std::string::npos : separator - 2);
        if (name == "disable-features") {
          if (separator != std::string::npos) disabled.push_back(value.substr(separator + 1));
          continue;
        }
        if (separator == std::string::npos) command->AppendSwitch(name);
        else command->AppendSwitchWithValue(name, value.substr(separator + 1));
      }
    }
    if (g_state && g_state->auth_synthetic) {
      command->RemoveSwitch("load-extension");
      command->AppendSwitch("disable-extensions");
      command->AppendSwitch("disable-component-extensions-with-background-pages");
    }
    // EXT-UPDATE-VERIFY: retain mock storage, profile confinement and disabled components.
    // All non-loopback HTTP(S) goes to the smoke server, which rejects proxy requests;
    // DNS also fails closed (including requests from contexts that bypass the proxy).
    const std::string update_test_port = command->GetSwitchValue("orbit-test-extension-updates").ToString();
    if (policy == orbit_bridge::NetworkPolicy::kHermetic && g_state &&
        g_state->secure_storage == ACR_SECURE_STORAGE_MOCK && !g_state->auth_synthetic &&
        orbit_bridge::IsExtensionUpdateTestPort(update_test_port)) {
      command->RemoveSwitch("disable-background-networking");
      command->AppendSwitchWithValue("proxy-server", "http://127.0.0.1:" + update_test_port);
      command->AppendSwitchWithValue("proxy-bypass-list", "127.0.0.1");
      command->AppendSwitchWithValue("host-resolver-rules", "MAP * ~NOTFOUND, EXCLUDE 127.0.0.1");
      command->AppendSwitch("disable-quic");
    }
    for (const auto& feature : orbit_bridge::DisabledFeatures(policy)) disabled.push_back(feature);
    const std::string merged = orbit_bridge::MergeFeatureLists(disabled);
    if (!merged.empty()) command->AppendSwitchWithValue("disable-features", merged);
    if (!g_state) return;
    // Last, so that it wins: Chrome's initial profile, whose directory backs CEF's global request
    // context, is otherwise Local State's `profile.last_used`. Chrome sets it to the profile of
    // the last activated Browser, an Orbit profile-<uuid> context in a visible run; at the next
    // launch the global context then owned that directory and ACRCreateProfile refused it
    // (DAILY-1 restore SIGTRAP, `ChromiumBrowserEngine.profile(for:)` precondition).
    command->AppendSwitchWithValue("profile-directory", kInitialProfileDirectory);
  }
  void OnContextInitialized() override {
    CEF_REQUIRE_UI_THREAD();
    if (!g_state) return;
    // Fail closed when Chrome's initial profile (the global context) is not <root>/Default: the
    // shell would otherwise create Orbit profiles next to a profile it does not know.
    if (!InitialProfileIsPinned()) {
      fprintf(stderr, "acr: initial profile is not the pinned Default; refusing to start\n");
      g_state->profile_unpinned = true;
      g_state->Simple(ACR_EVENT_FAILURE, 0, 0, "initial-profile-unpinned");
      g_state->loop_quit = true;
      CefQuitMessageLoop();
      return;
    }
    g_state->orbit = ResolveOrbitApi();
    g_state->extension_set_pinned = ResolveExtensionToolbarFunction<decltype(g_state->extension_set_pinned)>(
        "orbit_cef_extension_set_pinned");
    g_state->extension_shortcut = ResolveExtensionToolbarFunction<decltype(g_state->extension_shortcut)>(
        "orbit_cef_extension_shortcut");
    g_state->essentials_level = ResolveEssentialsLevel();
    // Only hosted Chrome style has logical Browsers whose tabs Chrome can create by itself.
    g_state->set_unowned_tab_handler = g_state->orbit ? ResolveUnownedTabRegistration() : nullptr;
    if (g_state->set_unowned_tab_handler && g_state->callbacks.adopt_engine_tab) {
      ++g_state->unowned_handler_generation;
      if (g_state->set_unowned_tab_handler(&AdoptUnownedTab, nullptr) != 1) g_state->set_unowned_tab_handler = nullptr;
    }
    DisableSafeBrowsing(CefRequestContext::GetGlobalContext());
    g_state->Simple(ACR_EVENT_READY, 0);
  }

  static bool InitialProfileIsPinned() {
    const std::string global = CefRequestContext::GetGlobalContext()->GetCachePath();
    char resolved_root[PATH_MAX], resolved_global[PATH_MAX];
    if (global.empty() || !realpath(g_state->root.c_str(), resolved_root)
        || !realpath(global.c_str(), resolved_global)) return false;
    const std::string expected = g_state->root + "/" + kInitialProfileDirectory;
    struct stat entry {};
    const bool real_directory = lstat(expected.c_str(), &entry) == 0 && S_ISDIR(entry.st_mode);
    return orbit_bridge::IsPinnedInitialProfile(resolved_root, resolved_global,
                                               real_directory && SameDirectory(global, expected));
  }
 private:
  IMPLEMENT_REFCOUNTING(App);
};

// Quit check (orbit_bridge::QuitPolicy). Reports each stall and retries the close of every
// remaining view (a page-closed browser needs its view destroyed). After a bounded number of
// stalls it ends the loop anyway: CefShutdown then destroys the browsers that never confirmed.
void ScheduleQuitCheck() {
  using orbit_bridge::QuitPolicy;
  CefPostDelayedTask(TID_UI, new FunctionTask([] {
    if (!g_state || g_state->loop_quit) return;
    g_state->quit_stalled = true;
    ++g_state->quit_stalls;
    if (QuitPolicy::AfterStall(g_state->quit_stalls) == QuitPolicy::Action::kForceQuit) {
      const std::string detail = "quit-forced " + g_state->QuitDetail();
      fprintf(stderr, "acr: %s\n", detail.c_str());
      g_state->Simple(ACR_EVENT_FAILURE, 0, 0, detail.c_str());
      g_state->quit_forced = true;
      g_state->loop_quit = true;
      CefQuitMessageLoop();
      return;
    }
    const std::string detail = "quit-stalled " + g_state->QuitDetail();
    g_state->Simple(ACR_EVENT_FAILURE, 0, 0, detail.c_str());
    for (auto& [token, host] : g_state->hosts) {
      host.closing_by_shell = true;
      if (host.browser) g_state->DestroyNativeView(host.browser);
    }
    g_state->MaybeFinishQuit();
    ScheduleQuitCheck();
  }), QuitPolicy::kCheckIntervalMs);
}

// Last resort of the bounded quit, independent of the UI thread: ends the process if ACRRun has
// not returned kHardExitSeconds after the quit request (blocked UI thread, CefShutdown that does
// not return). The shell saved its session before requesting the quit.
std::atomic<bool> g_quit_watchdog_disarmed{false};
std::atomic<bool> g_quit_watchdog_armed{false};

void ArmQuitWatchdog() {
  using orbit_bridge::QuitPolicy;
  if (g_quit_watchdog_armed.exchange(true)) return;
  g_quit_watchdog_disarmed.store(false);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, int64_t(QuitPolicy::kHardExitSeconds) * NSEC_PER_SEC),
                 dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    if (g_quit_watchdog_disarmed.load()) return;
    static const char message[] = "acr: quit watchdog: runtime did not end, exiting\n";
    (void)write(STDERR_FILENO, message, sizeof(message) - 1);
    _exit(QuitPolicy::kStatusHardExit);
  });
}

// A disk context must live in its own direct child of the root: never an alias of the global
// (Chrome initial) profile directory, of a reserved Chrome directory or of another context.
// Run 20261025T100520Z: a context on "<root>/default" while Chrome's initial profile is
// "<root>/Default" (same directory on a case-insensitive volume, different FilePath) loaded a
// second Profile on one directory. CHROMIUM-APP-R3: decided on the root descriptor opened at
// start-up, never on a realpath of the root recomputed later, and refused once the root's name no
// longer designates that directory. `*name` receives the child name. A creation requires an absent
// entry or a real directory; a removal accepts any entry (a file left in place of a profile).
bool CanonicalChild(const std::string& path, std::string* canonical, std::string* child, bool for_removal = false) {
  if (!g_state || !g_state->anchor || !g_state->anchor->StillAtPath()) return false;
  const std::string& root = g_state->anchor->path();
  if (!path.starts_with(root + "/")) return false;
  const std::string name = path.substr(root.size() + 1);
  if (name.empty() || name.size() > 128 || name.front() == '.') return false;
  for (const char c : name)
    if (!(isalnum(static_cast<unsigned char>(c)) || c == '-' || c == '_' || c == '.')) return false;
  std::string lowered;
  for (const char c : name) lowered.push_back(static_cast<char>(tolower(static_cast<unsigned char>(c))));
  for (const char* reserved : {"default", "system profile", "guest profile", "crashpad", "safe browsing"})
    if (lowered == reserved) return false;
  const auto entry = g_state->anchor->Inspect(name);
  if (entry == orbit_bridge::AnchoredRoot::Entry::kError) return false;
  if (!for_removal && entry == orbit_bridge::AnchoredRoot::Entry::kOther) return false;  // Links, files.
  *canonical = root + "/" + lowered;
  if (child) *child = name;
  return true;
}

// An unpacked synthetic test extension (hermetic runs only): an absolute real directory, reached
// without any symbolic link, holding a regular manifest.json.
bool ExtensionPathOk(const std::string& path) {
  char resolved[PATH_MAX];
  if (path.empty() || path[0] != '/' || !realpath(path.c_str(), resolved) || path != resolved) return false;
  const int fd = open(path.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0) return false;
  struct stat manifest {};
  const bool ok = fstatat(fd, "manifest.json", &manifest, AT_SYMLINK_NOFOLLOW) == 0 && S_ISREG(manifest.st_mode);
  close(fd);
  return ok;
}

bool SameDirectory(const std::string& a, const std::string& b) {
  struct stat first {}, second {};
  if (stat(a.c_str(), &first) != 0 || stat(b.c_str(), &second) != 0) return false;
  return first.st_dev == second.st_dev && first.st_ino == second.st_ino;
}

}  // namespace

extern "C" int32_t ACRRun(int argc, char* argv[], const ACRRunOptions* options,
                          const ACRCallbacks* callbacks, void* context) {
  if (!NSThread.isMainThread || g_state || !options || options->struct_size != sizeof(ACRRunOptions)
      || !options->root_cache_path || !callbacks || callbacks->abi_version != ACR_ABI_VERSION
      || callbacks->struct_size != sizeof(ACRCallbacks) || !callbacks->event) return 64;
  CefScopedLibraryLoader loader;
  orbit_bridge::ConfigureBrowserQoS();
  @autoreleasepool {
    if (!loader.LoadInMain()) return 69;
    State state;
    state.callbacks = *callbacks;
    state.context = context;
    state.root = options->root_cache_path;
    state.async_hold = options->async_navigation_hold != 0;
    std::vector<std::string> extra;
    for (size_t index = 0; index < options->extra_switch_count; ++index) {
      const std::string value = options->extra_switches[index] ? options->extra_switches[index] : "";
      if (!value.starts_with("--") || value.size() < 3) return 64;
      extra.push_back(value);
    }
    state.switches = extra;  // Raw, for the Keychain check below; replaced by the filtered list.
    // ABI 7: a run uses either the mock Keychain or one real Keychain item, never both.
    state.secure_storage = options->secure_storage;
    // ABI 8: an ACRNetworkPolicy value.
    if (options->network_policy != ACR_NETWORK_HERMETIC && options->network_policy != ACR_NETWORK_PRODUCT) return 64;
    state.network_policy = options->network_policy;
    if (state.secure_storage == ACR_SECURE_STORAGE_KEYCHAIN) {
      if (!options->keychain_service_name || !*options->keychain_service_name
          || !options->keychain_account_name || !*options->keychain_account_name) return 64;
      auto is_mock = [](const std::string& value) {
        return value == "--use-mock-keychain" || value.starts_with("--use-mock-keychain=");
      };
      for (int index = 0; index < argc; ++index)
        if (argv[index] && is_mock(argv[index])) return 64;
      for (const auto& value : state.switches)
        if (is_mock(value)) return 64;
    } else if (state.secure_storage != ACR_SECURE_STORAGE_MOCK) {
      return 64;
    }
    // CHROMIUM-APP-R3: Chromium gets an allow-listed argv (OrbitBridgePolicy.h), never the
    // process's own; the switches that would move or bypass the pinned initial profile refuse the
    // run in any dash form (R2).
    {
      const bool product = state.network_policy == ACR_NETWORK_PRODUCT;
      std::vector<std::string> process_arguments;
      for (int index = 1; index < argc; ++index)
        if (argv[index]) process_arguments.push_back(argv[index]);
      const auto from_process = orbit_bridge::FilterBrowserArguments(process_arguments, product, ExtensionPathOk);
      const auto from_shell = orbit_bridge::FilterBrowserArguments(extra, product, ExtensionPathOk);
      if (from_process.refused || from_shell.refused) {
        fprintf(stderr, "acr: refused a command-line option that would move or bypass the initial profile\n");
        return 64;
      }
      state.browser_arguments = from_process.kept;
      state.switches = from_shell.kept;
      state.disabled_features = from_process.disabled_features;
      state.disabled_features.insert(state.disabled_features.end(), from_shell.disabled_features.begin(),
                                     from_shell.disabled_features.end());
      state.dropped_arguments = from_process.dropped + from_shell.dropped;
      if (state.dropped_arguments)
        fprintf(stderr, "acr: %zu command-line option(s) not given to Chromium\n", state.dropped_arguments);
    }
    // CHROMIUM-APP-R3: the root is anchored before anything uses it; a root reached through a
    // symbolic link is refused.
    state.anchor = orbit_bridge::AnchoredRoot::Open(state.root);
    if (!state.anchor) return 64;
    state.auth_synthetic = state.secure_storage == ACR_SECURE_STORAGE_MOCK && state.network_policy == ACR_NETWORK_HERMETIC
        && orbit_auth::FreshDirectory::SyntheticRoot(*state.anchor);
    [ACRApplication sharedApplication];
    if (![NSApp isKindOfClass:[ACRApplication class]]) return 70;
    // The application owns only core/quit registration, for exactly this runtime lifetime.
    struct QuitHandlerScope {
      ~QuitHandlerScope() { [(ACRLifecycleApplication*)NSApp acrRemoveQuitHandler]; }
    } quit_handler_scope;
    [(ACRLifecycleApplication*)NSApp acrInstallQuitHandler];
    if (options->hidden_accessory_app)
      [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    CefRefPtr<CefApp> app = new App();
    CefSettings settings;
    settings.no_sandbox = false;
    settings.log_severity = LOGSEVERITY_DISABLE;
    settings.persist_session_cookies = false;
    CefString(&settings.root_cache_path) = state.root;
    // The exact name of the pinned initial profile (--profile-directory), also on a
    // case-sensitive volume.
    CefString(&settings.cache_path) = state.root + "/" + kInitialProfileDirectory;
    if (state.secure_storage == ACR_SECURE_STORAGE_KEYCHAIN) {
      CefString(&settings.keychain_service_name) = options->keychain_service_name;
      CefString(&settings.keychain_account_name) = options->keychain_account_name;
    }
    g_state = &state;
    std::vector<char*> browser_argv;
    std::string program = argc > 0 && argv[0] ? argv[0] : "Orbit";
    browser_argv.push_back(program.data());
    for (auto& argument : state.browser_arguments) browser_argv.push_back(argument.data());
    browser_argv.push_back(nullptr);
    if (!CefInitialize(CefMainArgs(static_cast<int>(browser_argv.size()) - 1, browser_argv.data()), settings, app,
                       nullptr)) {
      g_state = nullptr;
      return CefGetExitCode();
    }
    state.initialized = true;
    CefRunMessageLoop();
    fprintf(stderr, "acr: message loop exited hosts=%zu pending=%zu\n", state.hosts.size(),
            state.pending_profiles.size());
    if (!state.quit_forced && (!state.hosts.empty() || !state.pending_profiles.empty())) {
      // Never shut CEF down under a live browser; leave the process to exit.
      const std::string detail = "loop-ended-with-live-browsers " + state.QuitDetail();
      StopAuthenticationOperations(/*before_shutdown=*/true); // No final barrier/cleanup acknowledgement on this exit path.
      state.Simple(ACR_EVENT_FAILURE, 0, 0, detail.c_str());
      g_state = nullptr;
      g_quit_watchdog_disarmed.store(true);
      return orbit_bridge::QuitPolicy::kStatusLiveAtLoopEnd;
    }
    state.hosts.clear();
    state.pending_parents.clear();
    state.policies.clear();
    state.permissions.clear();
    state.destinations.clear();
    state.downloads.clear();
    state.js_dialogs.clear();
    state.auths.clear();
    state.file_dialogs.clear();
    state.menus.clear();
    state.unresponsive.clear();
    for (const auto& [token, context] : state.profiles) ACRObserveExtensions(token, 0);
    StopAuthenticationOperations(/*before_shutdown=*/true);
    state.profiles.clear();
    state.windows.clear();
    state.pending_windows.clear();
    state.key_receipts.Clear();
    app = nullptr;
    // Chromium's MacShutdownWatchdog (in the stock framework) exits with 2 (RESULT_CODE_HUNG)
    // if this takes longer than 10 s; observed only under heavy machine load. After a forced
    // quit, CefShutdown also destroys the browsers that never confirmed their close.
    const CFAbsoluteTime shutdown_started = CFAbsoluteTimeGetCurrent();
    orbit_bridge::BeginBrowserShutdownQoS();
    CefShutdown();
    StopAuthenticationOperations(/*before_shutdown=*/false, /*after_shutdown=*/true);
    orbit_bridge::EndBrowserShutdownQoS();
    fprintf(stderr, "acr: CefShutdown returned after %.2f s\n", CFAbsoluteTimeGetCurrent() - shutdown_started);
    ACREvent event {};
    event.struct_size = sizeof(event);
    event.kind = ACR_EVENT_SHUTDOWN;
    callbacks->event(context, &event);
    g_state = nullptr;
    g_quit_watchdog_disarmed.store(true);
    using orbit_bridge::QuitPolicy;
    if (state.profile_unpinned) return QuitPolicy::kStatusProfileUnpinned;
    return state.quit_forced ? QuitPolicy::kStatusForced : state.quit_stalled ? QuitPolicy::kStatusStalled : 0;
  }
}

extern "C" int32_t ACRRequestQuit() {
  if (!NSThread.isMainThread || !g_state || !g_state->initialized) return 0;
  if (g_state->quitting) return 1;
  orbit_bridge::BeginBrowserShutdownQoS();
  g_state->quitting = true;
  // No Chrome-created tab is offered to a quitting shell.
  ++g_state->unowned_handler_generation;
  if (g_state->set_unowned_tab_handler) g_state->set_unowned_tab_handler(nullptr, nullptr);
  StopAuthenticationOperations(/*before_shutdown=*/true);
  std::vector<uint64_t> extension_surfaces;
  for (const auto& [token, host] : g_state->hosts) extension_surfaces.push_back(token);
  for (auto token : extension_surfaces) if (auto* host = g_state->Find(token)) g_state->RevokeExtensionSurface(*host);
  std::vector<uint64_t> queued;
  for (const auto& [token, request] : g_state->queued_hosted_creations) queued.push_back(token);
  for (const uint64_t token : queued) g_state->AbortPending(token, "hosted-creation-cancelled-by-quit");
  for (auto& [id, pending] : g_state->policies) pending.callback->Cancel();
  g_state->policies.clear();
  for (auto& [id, pending] : g_state->permissions) CancelPermission(pending);
  g_state->permissions.clear();
  g_state->destinations.clear();  // Destroyed callbacks cancel.
  for (auto& [key, callback] : g_state->downloads) callback->Cancel();
  g_state->downloads.clear();
  g_state->CancelPageRequestsOf(0);
  std::vector<uint64_t> tokens;
  for (const auto& [token, host] : g_state->hosts) tokens.push_back(token);
  for (const uint64_t token : tokens) {
    auto found = g_state->hosts.find(token);  // A close may complete synchronously.
    if (found != g_state->hosts.end()) g_state->CloseHost(found->second);
  }
  ArmQuitWatchdog();
  g_state->MaybeFinishQuit();
  ScheduleQuitCheck();
  return 1;
}

extern "C" int32_t ACRCreateProfile(uint64_t token, const char* cache_path, int32_t persist) {
  if (!NSThread.isMainThread || !g_state || !g_state->initialized || g_state->quitting || !token
      || g_state->profiles.contains(token)) return 0;
  if (!g_state->auth_creation.Enter(token)) return 0;
  const bool auth_creation = g_state->auth_creation.Owns(token);
  const std::string path = cache_path ? cache_path : "";
  if (g_state->auth_targets.contains(token) && (!auth_creation || path != g_state->auth_targets.at(token)->path())) return 0;
  for (const auto& [protected_token, directory] : g_state->auth_targets)
    if (!(auth_creation && token == protected_token) && (path == directory->path() || SameDirectory(path, directory->path()))) return 0;
  const bool global = path == "@global";
  std::string canonical;
  if (!path.empty() && !global) {
    std::string name;
    if (!CanonicalChild(path, &canonical, &name)) return 0;
    const std::string global_path = CefRequestContext::GetGlobalContext()->GetCachePath();
    const auto child = g_state->anchor->IdentityOf(name);
    const auto global_identity = orbit_bridge::IdentityOfPath(global_path);
    if (child && global_identity && *child == *global_identity) return 0;
    if (!global_path.empty() && SameDirectory(path, global_path)) return 0;
    std::string lowered_global;
    for (const char c : global_path) lowered_global.push_back(static_cast<char>(tolower(static_cast<unsigned char>(c))));
    if (lowered_global == canonical) return 0;
    // The identical path is the same CEF browser context (FromCachePath shares it); any other
    // spelling of an existing context's directory would load a second Profile on it.
    for (const auto& [other, other_path] : g_state->profile_paths)
      if (other_path.second != path && (other_path.first == canonical || SameDirectory(path, other_path.second)))
        return 0;
  }
  CefRequestContextSettings settings;
  CefString(&settings.cache_path) = path;
  settings.persist_session_cookies = persist ? 1 : 0;
  // "@global" (laboratory): the already initialized global context, where the
  // stock SDK applies command-line extensions.
  auto context = global ? CefRequestContext::GetGlobalContext()
                        : CefRequestContext::CreateContext(settings, new ProfileHandler(token));
  if (!context) return 0;
  g_state->profiles[token] = context;
  if (!canonical.empty()) g_state->profile_paths[token] = {canonical, path};
  // A context sharing the already initialized global store gets no second
  // OnRequestContextInitialized; report readiness explicitly.
  if (global) {
    g_state->ready_profiles.insert(token);
    PostUI([token] {
      if (!g_state) return;
      ACREvent event {};
      event.struct_size = sizeof(event);
      event.kind = ACR_EVENT_PROFILE_READY;
      event.profile_token = token;
      event.value = 2;  // Shares the global store.
      g_state->Send(event);
    });
  }
  return 1;
}

extern "C" int32_t ACRCreateSurface(uint64_t token, uint64_t profile, void* parent, const char* url) {
  if (!NSThread.isMainThread || !g_state || !g_state->initialized) return 0;
  return CreateBrowserIn(token, profile, parent, url ? url : "");
}

// ABI 8: profile removal (CHROMIUM-APP-R2, BrowserEngine.removeProfile).
extern "C" int32_t ACRProfileBrowserCount(uint64_t profile) {
  if (!NSThread.isMainThread || !g_state) return -1;
  int32_t count = 0;
  for (const auto& [token, host] : g_state->hosts) count += host.profile == profile ? 1 : 0;
  for (const auto& [token, pending] : g_state->pending_profiles) count += pending == profile ? 1 : 0;
  return count;
}

extern "C" int32_t ACRReleaseProfile(uint64_t profile) {
  if (!NSThread.isMainThread || !g_state) return 0;
  // Conservatively serialize release across the lane's at-most-eight profiles.
  if (!g_state->auth_operations.empty() && g_state->auth_targets.contains(profile)) return 0;
  if (ACRProfileBrowserCount(profile) != 0) return 0;
  for (auto& [token, host] : g_state->hosts) if (host.profile == profile) g_state->RevokeExtensionSurface(host);
  ACRObserveExtensions(profile, 0);
  g_state->profiles.erase(profile);  // The last reference: CEF shuts its browser context down.
  g_state->ready_profiles.erase(profile);
  g_state->profile_paths.erase(profile);
  return 1;
}

extern "C" int32_t ACRProfileLoaded(const char* path) {
  if (!NSThread.isMainThread || !g_state || !g_state->initialized || !path || !g_state->orbit
      || g_state->orbit->version < 2u) return -1;
  return g_state->orbit->profile_loaded(path);
}

extern "C" int32_t ACRRemoveProfileDirectory(const char* cache_path) {
  if (!NSThread.isMainThread || !g_state || !g_state->initialized || !cache_path || !g_state->anchor) return 0;
  // CHROMIUM-APP-R3: every step on the root descriptor opened at start-up.
  if (!g_state->anchor->StillAtPath()) return -5;
  const std::string path = cache_path;
  for (const auto& [profile, directory] : g_state->auth_targets)
    if (path == directory->path() || SameDirectory(path, directory->path())) return 0;
  std::string canonical, name;
  // Only a direct, non-aliased, non-reserved child of the root (never the global profile); any
  // entry type, so that a file left in place of a refused profile is cleaned up.
  if (!CanonicalChild(path, &canonical, &name, /*for_removal=*/true)) return 0;
  const std::string global_path = CefRequestContext::GetGlobalContext()->GetCachePath();
  const auto child = g_state->anchor->IdentityOf(name);
  const auto global_identity = orbit_bridge::IdentityOfPath(global_path);
  if (child && global_identity && *child == *global_identity) return 0;
  for (const auto& [other, other_path] : g_state->profile_paths) {
    const auto other_identity = orbit_bridge::IdentityOfPath(other_path.second);
    if (other_path.first == canonical || (child && other_identity && *child == *other_identity)) return 0;  // In use.
  }
  // Chrome must have unloaded the Profile: it would otherwise keep writing into the directory.
  if (ACRProfileLoaded(path.c_str()) != 0) return 0;
  switch (g_state->anchor->RemoveChild(name)) {
    case orbit_bridge::AnchoredRoot::Removal::kRemoved: return 2;
    case orbit_bridge::AnchoredRoot::Removal::kAbsent: return 1;
    case orbit_bridge::AnchoredRoot::Removal::kRefused: return -5;
    case orbit_bridge::AnchoredRoot::Removal::kFailed: return -1;
  }
  return -1;
}

#define ACR_HOST(token) \
  if (!NSThread.isMainThread || !g_state) return 0; \
  Host* host = g_state->Find(token); \
  if (!host) return 0

extern "C" int32_t ACRNavigate(uint64_t token, const char* url) {
  ACR_HOST(token);
  if (!url) return 0;
  host->browser->GetMainFrame()->LoadURL(url);
  return 1;
}
extern "C" int32_t ACRGoBack(uint64_t token) {
  ACR_HOST(token);
  if (!host->browser->CanGoBack()) return 0;
  host->browser->GoBack();
  return 1;
}
extern "C" int32_t ACRGoForward(uint64_t token) {
  ACR_HOST(token);
  if (!host->browser->CanGoForward()) return 0;
  host->browser->GoForward();
  return 1;
}
extern "C" int32_t ACRReload(uint64_t token) { ACR_HOST(token); host->browser->Reload(); return 1; }
extern "C" int32_t ACRReloadIgnoringCache(uint64_t token) { ACR_HOST(token); host->browser->ReloadIgnoreCache(); return 1; }
extern "C" int32_t ACRStopLoad(uint64_t token) { ACR_HOST(token); host->browser->StopLoad(); return 1; }
extern "C" int32_t ACRSetFocus(uint64_t token, int32_t focus) {
  ACR_HOST(token);
  host->browser->GetHost()->SetFocus(focus != 0);
  return 1;
}
extern "C" int32_t ACRNotifyHostChanged(uint64_t token, int32_t hidden) {
  ACR_HOST(token);
  // A hosted tab's content NSView follows its superview and window like any
  // AppKit view; ChromeBrowserHostImpl does not implement WasResized/WasHidden.
  if (host->window) {
    if (hidden) g_state->RevokeExtensionSurface(*host);
    return 1;
  }
  auto browser_host = host->browser->GetHost();
  browser_host->NotifyMoveOrResizeStarted();
  browser_host->WasResized();
  browser_host->WasHidden(hidden != 0);
  return 1;
}
extern "C" int32_t ACRCloseSurface(uint64_t token) {
  if (!NSThread.isMainThread || !g_state) return 0;
  auto found = g_state->hosts.find(token);
  if (found == g_state->hosts.end()) {
    if (!g_state->pending_profiles.contains(token)) return 0;
    if (g_state->queued_hosted_creations.contains(token)) {
      g_state->AbortPending(token, "hosted-creation-cancelled-by-surface-close");
      return 1;
    }
    g_state->closed_before_creation.insert(token);  // Closed in OnAfterCreated.
    return 1;
  }
  g_state->CloseHost(found->second);
  return 1;
}

namespace {
class HistoryVisitor final : public CefNavigationEntryVisitor {
 public:
  bool Visit(CefRefPtr<CefNavigationEntry> entry, bool current, int index, int) override {
    urls.push_back(entry->GetURL());
    if (current) current_index = index;
    return true;
  }
  std::vector<std::string> urls;
  int current_index = -1;
 private:
  IMPLEMENT_REFCOUNTING(HistoryVisitor);
};
}  // namespace

extern "C" int32_t ACRHistoryURL(uint64_t token, int32_t offset, char* buffer, size_t capacity) {
  if (!NSThread.isMainThread || !g_state || !buffer || !capacity) return -1;
  Host* host = g_state->Find(token);
  if (!host) return -1;
  CefRefPtr<HistoryVisitor> visitor = new HistoryVisitor();
  host->browser->GetHost()->GetNavigationEntries(visitor, false);
  const int target = visitor->current_index + offset;
  if (visitor->current_index < 0 || target < 0 || target >= static_cast<int>(visitor->urls.size())) return -1;
  const auto& url = visitor->urls[static_cast<size_t>(target)];
  if (url.size() + 1 > capacity) return -1;
  memcpy(buffer, url.c_str(), url.size() + 1);
  return static_cast<int32_t>(url.size());
}

extern "C" int32_t ACRSetSitePermission(uint64_t profile, const char* origin, int32_t kind, int32_t setting) {
  if (!CefCurrentlyOn(TID_UI) || !g_state || g_state->quitting || !origin || !*origin) return 0;
  const auto context = g_state->profiles.find(profile);
  if (context == g_state->profiles.end() || !g_state->ready_profiles.contains(profile)) return 0;
  CefURLParts parts;
  if (!CefParseURL(origin, parts)) return 0;
  const auto scheme = CefString(&parts.scheme).ToString();
  if ((scheme != "http" && scheme != "https") || CefString(&parts.host).empty() ||
      !CefString(&parts.username).empty() || !CefString(&parts.password).empty()) return 0;
  cef_content_setting_types_t type;
  switch (kind) {
    case 0: type = CEF_CONTENT_SETTING_TYPE_NOTIFICATIONS; break;
    case 1: type = CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_CAMERA; break;
    case 2: type = CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_MIC; break;
    case 3: type = CEF_CONTENT_SETTING_TYPE_GEOLOCATION; break;
    default: return 0;
  }
  cef_content_setting_values_t value;
  switch (setting) {
    case 0: value = CEF_CONTENT_SETTING_VALUE_ASK; break;
    case 1: value = CEF_CONTENT_SETTING_VALUE_ALLOW; break;
    case 2: value = CEF_CONTENT_SETTING_VALUE_BLOCK; break;
    default: return 0;
  }
  context->second->SetContentSetting(origin, origin, type, value);
  return 1;
}

extern "C" int32_t ACRNavigationHistory(uint64_t token, char* buffer, size_t capacity) {
  if (!NSThread.isMainThread || !g_state) return -1;
  Host* host = g_state->Find(token);
  if (!host) return -1;
  CefRefPtr<HistoryVisitor> visitor = new HistoryVisitor();
  host->browser->GetHost()->GetNavigationEntries(visitor, false);
  if (visitor->current_index < 0) return -1;
  auto value = CefDictionaryValue::Create();
  value->SetInt("currentIndex", visitor->current_index);
  auto entries = CefListValue::Create();
  for (size_t i = 0; i < visitor->urls.size(); ++i) entries->SetString(i, visitor->urls[i]);
  value->SetList("entries", entries);
  const auto json = WriteJSON(value);
  if (buffer && capacity > json.size()) memcpy(buffer, json.c_str(), json.size() + 1);
  return static_cast<int32_t>(json.size());
}

extern "C" int32_t ACRFind(uint64_t token, const char* text, int32_t forward, int32_t match_case,
                           int32_t find_next) {
  ACR_HOST(token);
  if (!text || !*text) return 0;
  host->browser->GetHost()->Find(text, forward != 0, match_case != 0, find_next != 0);
  return 1;
}
extern "C" int32_t ACRStopFinding(uint64_t token, int32_t clear) {
  ACR_HOST(token);
  host->browser->GetHost()->StopFinding(clear != 0);
  return 1;
}

extern "C" int32_t ACRZoom(uint64_t token, int32_t command, double* level) {
  ACR_HOST(token);
  auto browser_host = host->browser->GetHost();
  if (command >= 1 && command <= 3) {
    const cef_zoom_command_t native = command == 1 ? CEF_ZOOM_COMMAND_IN
        : command == 2 ? CEF_ZOOM_COMMAND_OUT : CEF_ZOOM_COMMAND_RESET;
    if (!browser_host->CanZoom(native)) {
      if (level) *level = browser_host->GetZoomLevel();
      return -1;
    }
    browser_host->Zoom(native);
  }
  if (level) *level = browser_host->GetZoomLevel();
  return 1;
}
extern "C" int32_t ACRSetZoomLevel(uint64_t token, double level) {
  ACR_HOST(token);
  host->browser->GetHost()->SetZoomLevel(level);
  return 1;
}

extern "C" int32_t ACRSetAudioMuted(uint64_t token, int32_t muted) {
  ACR_HOST(token);
  host->browser->GetHost()->SetAudioMuted(muted != 0);
  return 1;
}
extern "C" int32_t ACRIsAudioMuted(uint64_t token) {
  if (!NSThread.isMainThread || !g_state) return -1;
  Host* host = g_state->Find(token);
  if (!host) return -1;
  return host->browser->GetHost()->IsAudioMuted() ? 1 : 0;
}

extern "C" int32_t ACRExecuteDevToolsMethod(uint64_t token, const char* method, const char* params) {
  ACR_HOST(token);
  if (!method) return 0;
  CefRefPtr<CefDictionaryValue> dictionary;
  if (params && *params) {
    auto value = CefParseJSON(params, JSON_PARSER_RFC);
    if (!value || value->GetType() != VTYPE_DICTIONARY) return 0;
    dictionary = value->GetDictionary();
  }
  return host->browser->GetHost()->ExecuteDevToolsMethod(0, method, dictionary);
}

extern "C" int32_t ACRRuntimeStyle(uint64_t token) {
  ACR_HOST(token);
  return host->browser->GetHost()->GetRuntimeStyle() == CEF_RUNTIME_STYLE_ALLOY ? 1 : 2;
}
extern "C" int32_t ACRBrowserID(uint64_t token) {
  ACR_HOST(token);
  return host->browser->GetIdentifier();
}
extern "C" void* ACRBrowserNSView(uint64_t token) {
  if (!NSThread.isMainThread || !g_state) return nullptr;
  Host* host = g_state->Find(token);
  return host ? host->browser->GetHost()->GetWindowHandle() : nullptr;
}
extern "C" int32_t ACRProfilesShareStorage(uint64_t first, uint64_t second) {
  if (!NSThread.isMainThread || !g_state) return -1;
  const auto a = g_state->profiles.find(first);
  const auto b = g_state->profiles.find(second);
  if (a == g_state->profiles.end() || b == g_state->profiles.end()) return -1;
  return a->second->IsSharingWith(b->second) ? 1 : 0;
}
extern "C" int32_t ACRProfileCachePath(uint64_t token, char* buffer, size_t capacity) {
  if (!NSThread.isMainThread || !g_state || !buffer) return -1;
  const auto found = g_state->profiles.find(token);
  if (found == g_state->profiles.end()) return -1;
  const std::string path = found->second->GetCachePath();
  if (path.size() + 1 > capacity) return -1;
  memcpy(buffer, path.c_str(), path.size() + 1);
  return static_cast<int32_t>(path.size());
}

extern "C" int32_t ACRGetDiagnostics(ACRDiagnostics* out) {
  if (!NSThread.isMainThread || !g_state || !out || out->struct_size != sizeof(ACRDiagnostics)) return 0;
  out->hosts = static_cast<uint32_t>(g_state->hosts.size());
  out->pending_creations = static_cast<uint32_t>(g_state->pending_profiles.size());
  out->pending_popups = static_cast<uint32_t>(g_state->pending_popups.size());
  out->abandoned_popups = static_cast<uint32_t>(g_state->abandoned_popups.size());
  uint32_t page_closes = 0;
  for (const auto& [token, host] : g_state->hosts) page_closes += host.close_requested ? 1 : 0;
  out->page_close_requests = page_closes;
  out->policies = static_cast<uint32_t>(g_state->policies.size());
  out->permissions = static_cast<uint32_t>(g_state->permissions.size());
  out->destinations = static_cast<uint32_t>(g_state->destinations.size());
  out->downloads = static_cast<uint32_t>(g_state->downloads.size());
  out->aborted_creations = g_state->aborted_creations;
  out->quit_stalls = g_state->quit_stalls;
  return 1;
}

extern "C" int32_t ACRResolveNavigationPolicy(uint64_t request, ACRNavigationPolicy policy) {
  if (!NSThread.isMainThread || !g_state) return 0;
  const auto found = g_state->policies.find(request);
  if (found == g_state->policies.end()) return 0;
  auto callback = found->second.callback;
  g_state->policies.erase(found);
  if (policy == ACR_POLICY_ALLOW) callback->Continue();
  else callback->Cancel();
  return 1;
}

extern "C" int32_t ACRResolvePermission(uint64_t request, ACRPermissionDecision decision) {
  if (!NSThread.isMainThread || !g_state) return 0;
  const auto found = g_state->permissions.find(request);
  if (found == g_state->permissions.end()) return 0;
  const auto pending = found->second;
  g_state->permissions.erase(found);
  if (pending.media) {
    // Default for Alloy is deny; grant only the requested device types.
    if (decision == ACR_PERMISSION_GRANT) pending.media->Continue(pending.mask);
    else pending.media->Cancel();
  } else if (pending.prompt) {
    pending.prompt->Continue(decision == ACR_PERMISSION_GRANT ? CEF_PERMISSION_RESULT_ACCEPT
        : decision == ACR_PERMISSION_DENY ? CEF_PERMISSION_RESULT_DENY : CEF_PERMISSION_RESULT_IGNORE);
  }
  return 1;
}

extern "C" int32_t ACRResolveDownloadDestination(uint64_t request, const char* path) {
  if (!NSThread.isMainThread || !g_state) return 0;
  const auto found = g_state->destinations.find(request);
  if (found == g_state->destinations.end()) return 0;
  auto callback = found->second.callback;
  g_state->destinations.erase(found);
  if (!path || !*path) return 1;  // Releasing the callback cancels the download.
  callback->Continue(path, false);
  return 1;
}

extern "C" int32_t ACRDownloadCommand(uint64_t profile, uint32_t id, ACRDownloadAction action) {
  if (!NSThread.isMainThread || !g_state) return 0;
  const auto found = g_state->downloads.find({profile, id});
  if (found == g_state->downloads.end()) return 0;
  auto callback = found->second;
  if (action == ACR_DOWNLOAD_CANCEL) callback->Cancel();
  else if (action == ACR_DOWNLOAD_PAUSE) callback->Pause();
  else if (action == ACR_DOWNLOAD_RESUME) callback->Resume();
  else return 0;
  return 1;
}

namespace {
void CookieResult(uint64_t request, bool success, const std::string* value) {
  if (!g_state) return;
  ACREvent event {};
  event.struct_size = sizeof(event);
  event.kind = ACR_EVENT_COOKIE_RESULT;
  event.request_id = request;
  event.value = success ? 1 : 0;
  event.detail = value ? value->c_str() : nullptr;
  g_state->Send(event);
}

class SetCookieResult final : public CefSetCookieCallback {
 public:
  explicit SetCookieResult(uint64_t request) : request_(request) {}
  void OnComplete(bool success) override {
    const uint64_t request = request_;
    PostUI([request, success] { CookieResult(request, success, nullptr); });
  }
 private:
  const uint64_t request_;
  IMPLEMENT_REFCOUNTING(SetCookieResult);
};

// The visit ends when CEF releases the visitor, including when no cookie matched.
class CookieReader final : public CefCookieVisitor {
 public:
  CookieReader(uint64_t request, std::string name) : request_(request), name_(std::move(name)) {}
  ~CookieReader() override {
    const uint64_t request = request_;
    const bool found = found_;
    const std::string value = value_;
    PostUI([request, found, value] { CookieResult(request, true, found ? &value : nullptr); });
  }
  bool Visit(const CefCookie& cookie, int, int, bool&) override {
    if (CefString(&cookie.name).ToString() == name_) {
      found_ = true;
      value_ = CefString(&cookie.value).ToString();
    }
    return true;
  }
 private:
  const uint64_t request_;
  const std::string name_;
  bool found_ = false;
  std::string value_;
  IMPLEMENT_REFCOUNTING(CookieReader);
};
}  // namespace

extern "C" uint64_t ACRCookieSet(uint64_t token, const char* url, const char* name, const char* value) {
  if (!NSThread.isMainThread || !g_state || !url || !name || !value) return 0;
  Host* host = g_state->Find(token);
  if (!host) return 0;
  auto manager = host->browser->GetHost()->GetRequestContext()->GetCookieManager(nullptr);
  if (!manager) return 0;
  CefCookie cookie;
  CefString(&cookie.name) = name;
  CefString(&cookie.value) = value;
  CefString(&cookie.path) = "/";
  const uint64_t request = g_state->next_request++;
  return manager->SetCookie(url, cookie, new SetCookieResult(request)) ? request : 0;
}

extern "C" uint64_t ACRCookieRead(uint64_t token, const char* url, const char* name) {
  if (!NSThread.isMainThread || !g_state || !url || !name) return 0;
  Host* host = g_state->Find(token);
  if (!host) return 0;
  auto manager = host->browser->GetHost()->GetRequestContext()->GetCookieManager(nullptr);
  if (!manager) return 0;
  const uint64_t request = g_state->next_request++;
  return manager->VisitUrlCookies(url, true, new CookieReader(request, name)) ? request : 0;
}

// Dedicated, source-only synthetic authentication lane. No generic ACREvent payload is used.
namespace {
int64_t AuthenticationClock() {
  return std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::system_clock::now().time_since_epoch()).count()
      + 11644473600000000LL;
}
bool AuthenticationConfiguration() {
  if (!g_state || !g_state->initialized || g_state->quitting || !g_state->anchor || !g_state->auth_synthetic
      || g_state->secure_storage != ACR_SECURE_STORAGE_MOCK || g_state->network_policy != ACR_NETWORK_HERMETIC) return false;
  for (const auto& flag : g_state->switches)
    if (flag.find("extension") != std::string::npos) return false;
  return true;
}
}
extern "C" int32_t ACRAuthCreateFreshProfile(uint64_t profile, ACRAuthBytes child_name, int32_t persist) {
  if (!NSThread.isMainThread || !AuthenticationConfiguration() || !profile || (persist != 0 && persist != 1)
      || g_state->auth_creation.active() || g_state->profiles.contains(profile)
      || g_state->auth_targets.contains(profile) || g_state->auth_targets.size() >= 8) return 0;
  std::string name;
  if (!orbit_auth::CopyBytes(child_name, 80, name)) return 0;
  auto directory = orbit_auth::FreshDirectory::Create(*g_state->anchor, name);
  if (!directory) return 0;
  g_state->auth_targets[profile] = directory; // Quarantine is installed before CEF context creation.
  if (!g_state->auth_creation.Begin(profile)) return 0;
  const int result = ACRCreateProfile(profile, directory->path().c_str(), persist);
  g_state->auth_creation.End();
  // On failure keep the owned directory quarantined; never reuse or remove uncertain state.
  return result;
}
extern "C" int32_t ACRAuthInstall(const ACRAuthBatch* batch, ACRAuthCallback callback, void* context) {
  if (!NSThread.isMainThread || !AuthenticationConfiguration() || !callback || !batch
      || batch->struct_size != sizeof(*batch) || batch->version != ACR_AUTH_VERSION
      || g_state->auth_operations.size() >= 8 || g_state->auth_used_operations.size() >= 64
      || g_state->auth_used_operations.contains(batch->operation) || g_state->auth_used_profiles.contains(batch->profile)
      || !g_state->ready_profiles.contains(batch->profile)) return 0;
  const uint64_t profile = batch->profile, id = batch->operation;
  const auto native = orbit_auth::ResolveContext(profile, g_state->profiles, g_state->auth_targets,
      g_state->ready_profiles, CefRequestContext::GetGlobalContext());
  if (!native) return 0;
  std::vector<orbit_auth::Cookie> rows;
  if (!orbit_auth::CopyBatch(batch, AuthenticationClock(), rows)) return 0;
  auto* runtime = g_state;
  const uint64_t lifetime = runtime->extension_lifetime;
  auto directory = g_state->auth_targets.at(profile);
  auto dispatch = [](std::function<void()> task) {
    if (NSThread.isMainThread) task(); else PostUI(std::move(task)); // Failure quarantines until shutdown.
  };
  auto retained = std::make_shared<CefRefPtr<CefRequestContext>>(native);
  auto transport = std::make_shared<orbit_auth::CEFTransport>(retained,
      [retained](CefRefPtr<CefCompletionCallback> ready) { return (*retained)->GetCookieManager(ready); }, dispatch);
  auto operation = std::make_shared<orbit_auth::Operation>(id, profile, std::move(rows), transport,
      [runtime, lifetime, profile, directory, expected = native.get()] {
        if (g_state != runtime || g_state->extension_lifetime != lifetime || g_state->quitting || !directory->Anchored()) return false;
        const auto current = g_state->profiles.find(profile);
        return current != g_state->profiles.end() && current->second.get() == expected && g_state->ready_profiles.contains(profile);
      }, AuthenticationClock, [callback, context](const ACRAuthNotice& result) { callback(context, &result); },
      [runtime, lifetime, id] { if (g_state == runtime && g_state->extension_lifetime == lifetime) g_state->auth_operations.erase(id); });
  g_state->auth_used_operations.insert(id); g_state->auth_used_profiles.insert(profile);
  g_state->auth_operations[id] = operation;
  std::weak_ptr<orbit_auth::Operation> weak = operation;
  // Failure to schedule a deadline refuses admission before any native write/callback.
  if (!CefPostDelayedTask(TID_UI, new FunctionTask([weak] { if (auto operation = weak.lock()) operation->Timeout(); }), batch->timeout_ms)) {
    g_state->auth_operations.erase(id); return 0;
  }
  operation->Start();
  return 1;
}
extern "C" int32_t ACRAuthCancel(uint64_t id) {
  if (!NSThread.isMainThread || !g_state) return 0;
  const auto found = g_state->auth_operations.find(id);
  if (found == g_state->auth_operations.end()) return 0;
  auto operation = found->second; operation->Cancel(); return 1;
}

// ---------------------------------------------------------------------------
// ABI 6 — hosted Chrome mode (patched CEF, ENG-X2.1).

extern "C" uint32_t ACRPatchLevel(void) {
  if (!NSThread.isMainThread || !g_state || !g_state->orbit) return 0;
  return g_state->orbit->version;
}

extern "C" int32_t ACRCreateWindow(uint64_t window, void* nswindow, ACRWindowType type) {
  if (!NSThread.isMainThread || !g_state || !g_state->initialized || g_state->quitting || !g_state->orbit
      || !window || !nswindow || type != ACR_WINDOW_NORMAL || g_state->windows.contains(window)) return 0;
  if (g_state->orbit->window_created(window, nswindow) != 1) return 0;
  g_state->windows.insert(window);
  g_state->shell_window_handles[window] = nswindow;
  return 1;
}

extern "C" int32_t ACRCloseWindow(uint64_t window) {
  if (!NSThread.isMainThread || !g_state || !g_state->orbit || !g_state->windows.erase(window)) return 0;
  g_state->shell_window_handles.erase(window);
  g_state->ExtensionSelectionChanged(window);
  g_state->extension_selections.erase(window);
  const int32_t result = g_state->orbit->window_destroyed(window);
  std::vector<uint64_t> cancelled;
  for (const auto& [token, owner] : g_state->pending_windows)
    if (owner == window) cancelled.push_back(token);
  for (const auto token : cancelled) {
    // CEF may already own a pending popup WebContents. Keep a late-created
    // browser in the native-close path without delivering CREATED to the shell.
    for (const auto& [key, popup] : g_state->pending_popups)
      if (popup == token) { g_state->abandoned_popups.insert(token); break; }
    g_state->AbortPending(token, "hosted-window-closed-before-creation");
  }
  return result >= 0 ? 1 : 0;
}

extern "C" int32_t ACRWindowKeyChanged(uint64_t window, int32_t is_key) {
  if (!NSThread.isMainThread || !g_state || !g_state->orbit || !g_state->windows.contains(window)) return 0;
  return g_state->orbit->window_activation_changed(window, is_key ? 1 : 0);
}

extern "C" int32_t ACRWindowBoundsChanged(uint64_t window) {
  if (!NSThread.isMainThread || !g_state || !g_state->orbit || !g_state->windows.contains(window)) return 0;
  return g_state->orbit->window_bounds_changed(window);
}

extern "C" int32_t ACRCreateTabSurface(uint64_t token, uint64_t profile, uint64_t window, int32_t index,
                                       void* parent, const char* url) {
  if (!NSThread.isMainThread || !g_state || !g_state->initialized || !g_state->orbit || !window) return 0;
  return CreateBrowserIn(token, profile, parent, url ? url : "", window, index < 0 ? -1 : index);
}

extern "C" int32_t ACRAttachSurfaceView(uint64_t token, void* nsview) {
  ACR_HOST(token);
  if (!host->window || !g_state->orbit || !nsview) return 0;
  return g_state->orbit->attach_view(host->browser->GetIdentifier(), nsview);
}

extern "C" int32_t ACRMoveSurfaceToWindow(uint64_t token, uint64_t window, int32_t index, void* nsview) {
  ACR_HOST(token);
  if (!host->window || !g_state->orbit || g_state->orbit->version < 2u || !window
      || !g_state->windows.contains(window)) return 0;
  auto browser = host->browser;
  g_state->RevokeExtensionSurface(*host);
  host = g_state ? g_state->Find(token) : nullptr;
  if (!host || host->browser != browser || host->closing_by_shell) return 0;
  if (g_state->orbit->move_tab(browser->GetIdentifier(), window, index < 0 ? -1 : index, nsview) != 1)
    return 0;
  host = g_state ? g_state->Find(token) : nullptr;
  if (!host || host->browser != browser || host->closing_by_shell) return 0;
  host->window = window;
  orbit_tab_info_t tab {};
  tab.struct_size = sizeof(tab);
  host->logical_window_id = g_state->orbit->get_tab_info(host->browser->GetIdentifier(), &tab) == 1
      ? tab.window_id : -1;
  return 1;
}

extern "C" int32_t ACRHoldWindow(uint64_t window) {
  if (!NSThread.isMainThread || !g_state || !g_state->orbit || g_state->orbit->version < 3u
      || !g_state->windows.contains(window)) return -1;
  return g_state->orbit->hold_window(window);
}

extern "C" int32_t ACRReleaseWindow(uint64_t window) {
  if (!NSThread.isMainThread || !g_state || !g_state->orbit || g_state->orbit->version < 3u) return -1;
  return g_state->orbit->release_window(window);
}

extern "C" int32_t ACRSafeBrowsingEnabled(uint64_t profile) {
  if (!NSThread.isMainThread || !g_state || !g_state->initialized) return -1;
  CefRefPtr<CefRequestContext> context;
  if (profile == 0) context = CefRequestContext::GetGlobalContext();
  else if (const auto found = g_state->profiles.find(profile); found != g_state->profiles.end()) context = found->second;
  if (!context) return -1;
  const CefRefPtr<CefValue> value = context->GetPreference("safebrowsing.enabled");
  if (!value || value->GetType() != VTYPE_BOOL) return -1;
  return value->GetBool() ? 1 : 0;
}

extern "C" int32_t ACRActivateSurface(uint64_t token) {
  ACR_HOST(token);
  if (!host->window || !g_state->orbit) return 0;
  const auto window = host->window;
  auto browser = host->browser;
  const auto result = g_state->orbit->activate_tab(browser->GetIdentifier());
  if (result == 1 && g_state) {
    auto* live = g_state->Find(token);
    if (live && live->window == window && live->browser == browser && !live->closing_by_shell)
      g_state->ExtensionSelectionChanged(window, live);
  }
  return result;
}

extern "C" int32_t ACRGetTabInfo(uint64_t token, ACRTabInfo* info) {
  if (!NSThread.isMainThread || !g_state || !g_state->orbit || !info || info->struct_size < sizeof(ACRTabInfo))
    return 0;
  Host* host = g_state->Find(token);
  if (!host) return 0;
  orbit_tab_info_t tab {};
  tab.struct_size = sizeof(tab);
  if (g_state->orbit->get_tab_info(host->browser->GetIdentifier(), &tab) != 1) return 0;
  info->tab_id = tab.tab_id;
  info->window_id = tab.window_id;
  info->index = tab.index;
  info->active = tab.active;
  info->hosted = tab.hosted;
  info->window_token = tab.window_token;
  return 1;
}

extern "C" int32_t ACRWindowBrowserCount(uint64_t window) {
  if (!NSThread.isMainThread || !g_state || !g_state->orbit) return -1;
  return g_state->orbit->window_browser_count(window);
}

extern "C" int32_t ACRSetAccessibility(uint64_t token, int32_t enabled) {
  ACR_HOST(token);
  host->browser->GetHost()->SetAccessibilityState(enabled > 0 ? STATE_ENABLED
                                                  : enabled == 0 ? STATE_DISABLED : STATE_DEFAULT);
  return 1;
}

// ---------------------------------------------------------------------------
// ABI 9 — page-initiated browser surfaces (CH-ESSENTIALS).

extern "C" int32_t ACRResolveJSDialog(uint64_t request, int32_t accept, const char* text) {
  if (!NSThread.isMainThread || !g_state) return 0;
  const auto found = g_state->js_dialogs.find(request);
  if (found == g_state->js_dialogs.end()) return 0;
  const auto pending = found->second;
  g_state->js_dialogs.erase(found);
  pending.callback->Continue(accept != 0, text ? CefString(text) : CefString());
  if (pending.before_unload && accept == 0) {
    auto host = g_state->hosts.find(pending.surface);
    if (host != g_state->hosts.end() && host->second.close_confirm) {
      host->second.close_confirm = false;
      g_state->Simple(ACR_EVENT_CLOSE_CANCELED, pending.surface);
    }
  }
  return 1;
}

extern "C" int32_t ACRResolveAuth(uint64_t request, const char* user, const char* password) {
  if (!NSThread.isMainThread || !g_state) return 0;
  const auto found = g_state->auths.find(request);
  if (found == g_state->auths.end()) return 0;
  auto callback = found->second.callback;
  g_state->auths.erase(found);
  if (user) callback->Continue(user, password ? password : "");
  else callback->Cancel();
  return 1;
}

extern "C" int32_t ACRResolveFileDialog(uint64_t request, const char* const* paths, size_t count) {
  if (!NSThread.isMainThread || !g_state) return 0;
  const auto found = g_state->file_dialogs.find(request);
  if (found == g_state->file_dialogs.end()) return 0;
  auto callback = found->second.callback;
  g_state->file_dialogs.erase(found);
  std::vector<CefString> files;
  for (size_t index = 0; paths && index < count; ++index)
    if (paths[index] && *paths[index]) files.emplace_back(paths[index]);
  if (files.empty()) callback->Cancel();
  else callback->Continue(files);
  return 1;
}

extern "C" int32_t ACRResolveContextMenu(uint64_t request, int32_t command_id) {
  if (!NSThread.isMainThread || !g_state) return 0;
  const auto found = g_state->menus.find(request);
  if (found == g_state->menus.end()) return 0;
  const auto pending = found->second;
  g_state->menus.erase(found);
  if (orbit_bridge::AcceptsContextMenuCommand(command_id, pending.offered)) {
    pending.callback->Continue(command_id, EVENTFLAG_NONE);
    return 1;
  }
  pending.callback->Cancel();
  return command_id < 0 ? 1 : 0;
}

extern "C" int32_t ACRResolveUnresponsive(uint64_t token, int32_t terminate) {
  if (!NSThread.isMainThread || !g_state) return 0;
  const auto found = g_state->unresponsive.find(token);
  if (found == g_state->unresponsive.end()) return 0;
  auto callback = found->second;
  g_state->unresponsive.erase(found);
  if (terminate) callback->Terminate();
  else callback->Wait();
  return 1;
}

extern "C" int32_t ACRExitFullscreen(uint64_t token) {
  ACR_HOST(token);
  host->browser->GetHost()->ExitFullscreen(true);
  return 1;
}

extern "C" int32_t ACRIsFullscreen(uint64_t token) {
  if (!NSThread.isMainThread || !g_state) return -1;
  Host* host = g_state->Find(token);
  if (!host) return -1;
  return host->browser->GetHost()->IsFullscreen() ? 1 : 0;
}

namespace {
// Chrome resolves the target of window-level commands (DevTools opener, Chrome commands) from the
// active tab of the logical Browser (chrome_browser_delegate.cc:65-66).
void ActivateHosted(Host* host) {
  if (host->window && g_state->orbit) g_state->orbit->activate_tab(host->browser->GetIdentifier());
}

void SelectDeveloperPanel(Host* host) {
  if (!host->developer_browser || host->developer_panel.empty()) return;
  auto frame = host->developer_browser->GetMainFrame();
  if (!frame || !frame->GetURL().ToString().starts_with("devtools://devtools/")) return;
  // This is Chromium's own frontend, never a remote document. The panel name is a closed enum
  // validated by ACRShowDevToolsPanel; no page-provided text enters this script.
  // Chrome creates the frontend renderer before CEF adopts its WebContents. Use its native
  // DevTools session rather than relying on a CEF renderer-side frame bridge in that process.
  auto parameters = CefDictionaryValue::Create();
  parameters->SetString("expression", "import('devtools://devtools/bundled/ui/legacy/legacy.js').then(m => "
      "m.InspectorView.InspectorView.instance().showPanel('" + host->developer_panel + "'))");
  parameters->SetBool("awaitPromise", true);
  host->developer_browser->GetHost()->ExecuteDevToolsMethod(0, "Runtime.evaluate", parameters);
}

class DeveloperPanelClient final : public CefClient, public CefLifeSpanHandler, public CefLoadHandler {
 public:
  explicit DeveloperPanelClient(uint64_t token) : token_(token) {}
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD();
    if (!g_state) { browser->GetHost()->CloseBrowser(true); return; }
    ++g_state->developer_tool_count;
    counted_ = true;
    if (auto* host = g_state->Find(token_)) host->developer_browser = browser;
    else browser->GetHost()->CloseBrowser(true);
  }
  void OnLoadEnd(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, int) override {
    CEF_REQUIRE_UI_THREAD();
    if (g_state && frame->IsMain()) {
      if (auto* host = g_state->Find(token_)) SelectDeveloperPanel(host);
    }
  }
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD();
    if (!g_state) return;
    if (auto* host = g_state->Find(token_); host && host->developer_browser == browser) {
      host->developer_browser = nullptr;
      host->developer_panel.clear();
    }
    if (counted_) { --g_state->developer_tool_count; counted_ = false; }
    g_state->MaybeFinishQuit();
  }
 private:
  uint64_t token_;
  bool counted_ = false;
  IMPLEMENT_REFCOUNTING(DeveloperPanelClient);
};
}  // namespace

extern "C" int32_t ACRShowDevTools(uint64_t token, int32_t inspect, int32_t x, int32_t y) {
  ACR_HOST(token);
  ActivateHosted(host);
  // An empty CefWindowInfo: Chrome's own undocked DevTools window. A parent view makes a hosted
  // opener reset the DevTools browser to Alloy and CHECK (chrome_browser_delegate.cc:143-161).
  CefWindowInfo window;
  CefBrowserSettings settings;
  host->browser->GetHost()->ShowDevTools(window, new DeveloperPanelClient(token), settings,
                                       inspect ? CefPoint(x, y) : CefPoint());
  return 1;
}

extern "C" int32_t ACRCloseDevTools(uint64_t token) {
  ACR_HOST(token);
  host->browser->GetHost()->CloseDevTools();
  return 1;
}

extern "C" int32_t ACRShowDevToolsPanel(uint64_t token, const char* panel) {
  ACR_HOST(token);
  const std::string name = panel ? panel : "";
  if (name != "console" && name != "network" && name != "elements") return 0;
  if (host->developer_browser) {
    if (host->developer_panel == name) return ACRCloseDevTools(token);
    host->developer_panel = name;
    SelectDeveloperPanel(host);
    return ACRShowDevTools(token, 0, 0, 0);
  }
  host->developer_panel = name;
  auto context = host->browser->GetHost()->GetRequestContext();
  if (context->CanSetPreference("devtools.preferences")) {
    auto value = context->GetPreference("devtools.preferences");
    auto settings = value && value->GetType() == VTYPE_DICTIONARY
        ? value->GetDictionary()->Copy(false) : CefDictionaryValue::Create();
    settings->SetString("panel-selected-tab", "\"" + name + "\"");
    auto next = CefValue::Create(); next->SetDictionary(settings);
    CefString error; context->SetPreference("devtools.preferences", next, error);
  }
  return ACRShowDevTools(token, 0, 0, 0);
}

extern "C" int32_t ACRHasDevTools(uint64_t token) {
  if (!NSThread.isMainThread || !g_state) return -1;
  Host* host = g_state->Find(token);
  if (!host) return -1;
  return host->browser->GetHost()->HasDevTools() ? 1 : 0;
}

extern "C" int32_t ACRExecuteChromeCommand(uint64_t token, const char* name) {
  ACR_HOST(token);
  if (!host->window || !name) return 0;
  const int id = cef_id_for_command_id_name(name);
  if (id <= 0) return 0;
  ActivateHosted(host);
  auto browser_host = host->browser->GetHost();
  if (!browser_host->CanExecuteChromeCommand(id)) return 0;
  browser_host->ExecuteChromeCommand(id, CEF_WOD_CURRENT_TAB);
  return 1;
}

extern "C" int32_t ACRPrint(uint64_t token) {
  ACR_HOST(token);
  ActivateHosted(host);
  host->browser->GetHost()->Print();
  return 1;
}

extern "C" int32_t ACRRequestClose(uint64_t token) {
  ACR_HOST(token);
  if (host->closing_by_shell) return 2;
  host->close_confirm = true;
  auto browser = host->browser;  // The close may complete synchronously and erase the host.
  return browser->GetHost()->TryCloseBrowser() ? 2 : 1;
}

extern "C" int32_t ACRRequestDownloadSourceClose(uint64_t token) {
  ACR_HOST(token);
  auto frame = host->browser->GetMainFrame();
  if (!frame) return 0;
  host->close_confirm = true;
  frame->LoadURL("about:blank");
  return 3;
}

extern "C" uint32_t ACREssentialsLevel(void) {
  if (!NSThread.isMainThread || !g_state) return 0;
  return g_state->essentials_level;
}

// ABI 10: native extension services. No renderer IPC endpoints are added.
namespace {
const char* ExtensionProfilePath(uint64_t token) {
  if (!NSThread.isMainThread || !g_state || !g_state->initialized || g_state->quitting ||
      !g_state->orbit || g_state->orbit->version < 4u || !g_state->ready_profiles.contains(token)
      || g_state->auth_targets.contains(token)) return nullptr;
  const auto found = g_state->profile_paths.find(token);
  if (found == g_state->profile_paths.end() || found->second.first.empty() ||
      found->second.first == "@global") return nullptr;
  return found->second.second.c_str();
}
void ExtensionRegistryChanged(void* context) {
  const uint64_t token = reinterpret_cast<uintptr_t>(context);
  if (!ExtensionProfilePath(token)) return;
  auto event = g_state->Event(ACR_EVENT_EXTENSIONS_CHANGED, 0);
  event.profile_token = token;
  g_state->Send(event);
}
}
extern "C" int32_t ACRExtensionsAvailable(void) {
  return NSThread.isMainThread && g_state && g_state->initialized && !g_state->quitting &&
      g_state->orbit && g_state->orbit->version >= 4u && g_state->orbit->extensions_snapshot &&
      g_state->orbit->extension_set_enabled && g_state->orbit->extension_remove &&
      g_state->orbit->extensions_observe && g_state->orbit->extension_action &&
      g_state->orbit->extension_selection_changed && g_state->orbit->extension_cancel ? 1 : 0;
}
extern "C" int32_t ACRExtensionsSnapshot(uint64_t token, char* output, uint32_t capacity) {
  const char* path = ExtensionProfilePath(token);
  return path && ACRExtensionsAvailable() ? g_state->orbit->extensions_snapshot(path, output, capacity) : -1;
}
extern "C" int32_t ACRExtensionSetEnabled(uint64_t token, const char* id, int32_t enabled) {
  const char* path = ExtensionProfilePath(token);
  return path && ACRExtensionsAvailable() && orbit_bridge::ValidExtensionID(id) ?
      g_state->orbit->extension_set_enabled(path, id, enabled) : 0;
}
extern "C" int32_t ACRExtensionPinningAvailable(void) {
  return ACRExtensionsAvailable() && g_state->extension_set_pinned ? 1 : 0;
}
extern "C" int32_t ACRExtensionSetPinned(uint64_t token, const char* id, int32_t pinned) {
  const char* path = ExtensionProfilePath(token);
  return path && ACRExtensionPinningAvailable() && orbit_bridge::ValidExtensionID(id) ?
      g_state->extension_set_pinned(path, id, pinned) : 0;
}
extern "C" int32_t ACRSetExtensionActionAnchor(uint64_t token, void* anchor_nsview) {
  if (!NSThread.isMainThread || !g_state || !g_state->hosts.contains(token)) return 0;
  auto& host = g_state->hosts.at(token);
  NSView* anchor = (__bridge NSView*)anchor_nsview;
  const auto window = g_state->shell_window_handles.find(host.window);
  if (!anchor || ![anchor isKindOfClass:[NSView class]] ||
      window == g_state->shell_window_handles.end() || (__bridge void*)anchor.window != window->second) {
    host.extension_anchor = nil;
    return 0;
  }
  host.extension_anchor = anchor;
  return 1;
}
extern "C" int32_t ACRExtensionRemove(uint64_t token, const char* id) {
  const char* path = ExtensionProfilePath(token);
  return path && ACRExtensionsAvailable() && orbit_bridge::ValidExtensionID(id) ?
      g_state->orbit->extension_remove(path, id) : 0;
}
extern "C" int32_t ACRObserveExtensions(uint64_t token, int32_t observe) {
  // Unsubscription must work during shutdown, after quitting becomes true.
  if (!NSThread.isMainThread || !g_state || !g_state->orbit || g_state->orbit->version < 4u ||
      !g_state->orbit->extensions_observe) return 0;
  auto found = g_state->profile_paths.find(token);
  if (found == g_state->profile_paths.end() || found->second.first.empty() ||
      found->second.first == "@global") return 0;
  if (observe && !ExtensionProfilePath(token)) return 0;
  return g_state->orbit->extensions_observe(found->second.second.c_str(),
      observe ? &ExtensionRegistryChanged : nullptr, reinterpret_cast<void*>(static_cast<uintptr_t>(token)));
}
extern "C" int32_t ACRExtensionManagementAvailable(void) {
  // Version 3 ends immediately before extensions_snapshot (120 bytes on arm64).
  // Do not inspect any v4 member, even to test whether it is null.
  return NSThread.isMainThread && g_state && g_state->initialized && !g_state->quitting &&
      g_state->orbit && g_state->orbit->version >= 3u &&
      g_state->orbit->struct_size >= offsetof(orbit_cef_api_t, extensions_snapshot) &&
      g_state->orbit->get_tab_info && g_state->orbit->activate_tab ? 1 : 0;
}
namespace {
Host* ExtensionManagerHost(uint64_t token) {
  if (!ACRExtensionManagementAvailable()) return nullptr;
  Host* host = g_state->Find(token);
  if (!host || !host->browser->IsValid() || !host->window ||
      !g_state->windows.contains(host->window) || host->closing_by_shell || host->close_requested ||
      !g_state->ready_profiles.contains(host->profile)) return nullptr;
  const auto path = g_state->profile_paths.find(host->profile);
  const auto profile = g_state->profiles.find(host->profile);
  if (path == g_state->profile_paths.end() || path->second.first.empty() ||
      path->second.first == "@global" || path->second.second.empty() ||
      profile == g_state->profiles.end() || !profile->second || profile->second->IsGlobal() ||
      profile->second->GetCachePath().empty() ||
      profile->second->GetCachePath().ToString() != path->second.second) return nullptr;
  auto browser_host = host->browser->GetHost();
  if (!browser_host || !browser_host->GetRequestContext() ||
      !browser_host->GetRequestContext()->IsSame(profile->second)) return nullptr;
  NSView* view = (__bridge NSView*)browser_host->GetWindowHandle();
  // The transfer holding window is hidden; detached surfaces have no window.
  const auto window = g_state->shell_window_handles.find(host->window);
  if (!view || !view.window || !view.window.isVisible ||
      window == g_state->shell_window_handles.end() ||
      window->second != (__bridge void*)view.window) return nullptr;
  orbit_tab_info_t info{};
  info.struct_size = sizeof(info);
  if (g_state->orbit->get_tab_info(host->browser->GetIdentifier(), &info) != 1 ||
      !info.hosted || info.window_token != host->window || info.window_id < 0 ||
      info.tab_id < 0 || info.index < 0) return nullptr;
  return host;
}
}
namespace {
int32_t OpenExtensionManagerDocument(uint64_t token, const std::string& target);
}
extern "C" int32_t ACROpenExtensionManager(uint64_t token) {
  return OpenExtensionManagerDocument(token, orbit_bridge::ExtensionManagerRoute::kURL);
}
// EXT-OUTCOME-R2: one extension's details or the keyboard-shortcut page of the genuine manager,
// through the same exact-surface authority and a grant naming only that document.
extern "C" int32_t ACROpenExtensionManagerPage(uint64_t token, int32_t page, const char* extension_id) {
  const auto target = orbit_bridge::ExtensionManagerRoute::Target(page, extension_id);
  return target ? OpenExtensionManagerDocument(token, *target) : 0;
}
namespace {
int32_t OpenExtensionManagerDocument(uint64_t token, const std::string& target) {
  Host* host = ExtensionManagerHost(token);
  if (!host) return 0;
  auto* const runtime = g_state;
  const uint64_t lifetime = runtime->extension_lifetime;
  const uint64_t window = host->window, profile = host->profile, generation = host->generation;
  auto browser = host->browser;
  NSWindow* const source_window = ((__bridge NSView*)browser->GetHost()->GetWindowHandle()).window;
  // Activation can synchronously reenter shell/extension callbacks. Keep no borrowed authority.
  const int activated = runtime->orbit->activate_tab(browser->GetIdentifier());
  host = nullptr;
  if (activated != 1 || g_state != runtime || g_state->extension_lifetime != lifetime) return 0;
  host = ExtensionManagerHost(token);
  if (!host || host->browser != browser || host->window != window || host->profile != profile ||
      host->generation != generation ||
      ((__bridge NSView*)browser->GetHost()->GetWindowHandle()).window != source_window) return 0;
  orbit_tab_info_t info{};
  info.struct_size = sizeof(info);
  if (runtime->orbit->get_tab_info(browser->GetIdentifier(), &info) != 1 || !info.active) return 0;
  auto frame = browser->GetMainFrame();
  if (!frame) return 0;
  host->extension_manager_route.Arm(target);
  frame->LoadURL(target.c_str());
  return 1;
}
}  // namespace

namespace {
// Retain the native anchor across synchronous cancellation, but never retain a
// closed window or accept the same view after it moved to a different window.
class ExtensionActionAnchor {
 public:
  explicit ExtensionActionAnchor(void* anchor) : anchor_((__bridge NSView*)anchor) {
    if ([anchor_ isKindOfClass:[NSView class]]) window_ = anchor_.window;
    else anchor_ = nil;
  }
  bool IsValidFor(CefRefPtr<CefBrowser> browser) const {
    if (!browser || !browser->IsValid()) return false;
    auto browser_host = browser->GetHost();
    if (!browser_host) return false;
    NSWindow* window = window_;
    NSView* source = (__bridge NSView*)browser_host->GetWindowHandle();
    return anchor_ && window && window.isVisible && source && source.window == window &&
        anchor_.window == window && !anchor_.isHiddenOrHasHiddenAncestor && !NSIsEmptyRect(anchor_.visibleRect);
  }
  void* get() const { return (__bridge void*)anchor_; }
 private:
  NSView* __strong anchor_ = nil;
  NSWindow* __weak window_ = nil;
};
}

extern "C" int32_t ACRPerformExtensionAction(uint64_t token, const char* id, void* anchor) {
  ACR_HOST(token);
  const bool diagnostics = std::getenv("ORBIT_EXTENSION_DIAGNOSTICS") != nullptr;
  auto unavailable = [diagnostics](const char* stage) {
    if (diagnostics) fprintf(stderr, "acr: extension action unavailable at %s\n", stage);
    return 0;
  };
  if (!ACRExtensionsAvailable() || !host->window || !ExtensionProfilePath(host->profile) ||
      host->closing_by_shell || host->close_requested || !orbit_bridge::ValidExtensionID(id) || !anchor) return unavailable("host");
  auto* const runtime = g_state;
  const uint64_t lifetime = runtime->extension_lifetime;
  const uint64_t window = host->window, profile = host->profile;
  auto browser = host->browser;
  const std::string extension_id(id);
  ExtensionActionAnchor owned_anchor(anchor);
  if (!owned_anchor.IsValidFor(browser)) return unavailable("anchor");
  uint64_t epoch = 0;
  {
    const auto selection = g_state->extension_selections.find(window);
    if (selection == g_state->extension_selections.end() || selection->second.surface != token ||
        selection->second.profile != profile) return unavailable("selection");
    epoch = selection->second.epoch;
  }
  g_state->CancelExtensionAction(*host);
  // Cancellation is external/reentrant. No borrowed Host or map iterator may
  // authorize the new invocation, and a successor started by cancellation wins.
  host = nullptr;
  if (g_state != runtime || g_state->extension_lifetime != lifetime || !ACRExtensionsAvailable() || !ExtensionProfilePath(profile)) return unavailable("runtime-after-cancel");
  host = g_state->Find(token);
  if (!host || host->browser != browser || host->window != window || host->profile != profile ||
      host->closing_by_shell || host->close_requested || host->extension_invocation ||
      !owned_anchor.IsValidFor(browser)) return unavailable("host-after-cancel");
  {
    const auto selection = g_state->extension_selections.find(window);
    if (selection == g_state->extension_selections.end() || selection->second.surface != token ||
        selection->second.profile != profile || selection->second.epoch != epoch) return unavailable("selection-after-cancel");
  }
  const uint64_t invocation = g_state->next_request++;
  host->extension_invocation = invocation;
  const auto result = g_state->orbit->extension_action(browser->GetIdentifier(), extension_id.c_str(),
      owned_anchor.get(), invocation, token, profile, epoch);
  if (result != 1 && g_state == runtime && g_state->extension_lifetime == lifetime) {
    if (auto* live = g_state->Find(token); live && live->extension_invocation == invocation)
      live->extension_invocation = 0;
    // Revoke only this call's ID, even when native dispatch started a successor.
    // Clear ownership before the external callback and do not access it afterward.
    if (g_state->HasExtensionLeases()) g_state->orbit->extension_cancel(invocation);
  }
  if (diagnostics) fprintf(stderr, "acr: native extension dispatch returned %d\n", result);
  return result;
}

extern "C" int32_t ACRCancelExtensionAction(uint64_t token) {
  ACR_HOST(token);
  g_state->CancelExtensionAction(*host);
  return 1;
}
