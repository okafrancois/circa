#import <Cocoa/Cocoa.h>

#include <algorithm>
#include <cerrno>
#include <fcntl.h>
#include <filesystem>
#include <fstream>
#include <functional>
#include <set>
#include <sys/stat.h>
#include <unistd.h>
#include <string>
#include <vector>
#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_command_line.h"
#include "include/cef_display_handler.h"
#include "include/cef_frame.h"
#include "include/cef_id_mappers.h"
#include "include/cef_request_context.h"
#include "include/cef_request_context_handler.h"
#include "include/base/cef_bind.h"
#include "include/base/cef_callback.h"
#include "include/views/cef_browser_view.h"
#include "include/views/cef_window.h"
#include "include/wrapper/cef_closure_task.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"

namespace {
bool had_failure = false;
bool native_visible_slot = false;
bool store_probe = false;
pid_t foreground_process = 0;

bool NativeStyle(const std::string& style) {
  return style == "chrome-native-tabs" || style == "chrome-native-split" || style == "chrome-native-store";
}

bool StoreNavigationAllowed(const std::string& value) {
  if (!store_probe) return false;
  NSURLComponents* url = [NSURLComponents componentsWithString:[NSString stringWithUTF8String:value.c_str()]];
  if (url.user || url.password) return false;
  if ([url.scheme isEqualToString:@"chrome"] && [url.host isEqualToString:@"extensions"]) return true;
  if (![url.scheme isEqualToString:@"https"]) return false;
  if (url.port && url.port.integerValue != 443) return false;
  if ([url.host isEqualToString:@"consent.google.com"]
      && ([url.path isEqualToString:@"/m"] || [url.path isEqualToString:@"/save"])) {
    NSUInteger continuations = 0;
    for (NSURLQueryItem* item in url.queryItems) {
      if (![item.name isEqualToString:@"continue"]) continue;
      ++continuations;
      if (!item.value) return false;
      NSURLComponents* target = [NSURLComponents componentsWithString:item.value];
      if (target.user || target.password || ![target.scheme isEqualToString:@"https"]
          || ![target.host isEqualToString:@"chromewebstore.google.com"]
          || ![target.path isEqualToString:@"/detail/ublock-origin-lite/ddkjiahejlhfcafbddmgiahcphecmpfh"]
          || (target.port && target.port.integerValue != 443)) return false;
    }
    return continuations <= 1;
  }
  return ([url.host isEqualToString:@"chromewebstore.google.com"]
      && [url.path isEqualToString:@"/detail/ublock-origin-lite/ddkjiahejlhfcafbddmgiahcphecmpfh"])
    || ([url.host isEqualToString:@"ublockorigin.github.io"] && [url.path hasPrefix:@"/uBOL-home/"]);
}

void Record(NSString* event, NSDictionary* fields) {
  NSMutableDictionary* value = [fields mutableCopy];
  value[@"event"] = event;
  NSData* data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nullptr];
  if (data) {
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
  }
}

bool NoVisibleWindows() {
  if (NSApp.active) return false;
  for (NSWindow* window in NSApp.windows) {
    if (window.visible) return false;
  }
  return true;
}

bool ForegroundInSlot() {
  if (!native_visible_slot) return true;
  const pid_t current = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
  return current == foreground_process || current == getpid();
}

bool WindowStateAllowed() {
  if (!native_visible_slot) return NoVisibleWindows();
  if (NSApp.activationPolicy == NSApplicationActivationPolicyProhibited) return false;
  NSUInteger visible = 0;
  for (NSWindow* window in NSApp.windows) if (window.visible) ++visible;
  return visible <= (store_probe ? 4 : 1);
}

bool SyntheticRoot(const std::string& value, const std::string& phase) {
  namespace fs = std::filesystem;
  std::error_code error;
  const fs::path root(value);
  const fs::path base = fs::path(ENGINE_GATE_REPO_ROOT) / "artifacts/native-engine-gate";
  if (!root.is_absolute() || root.lexically_normal() != root || root.parent_path() != base) return false;
  fs::path current;
  for (const auto& component : root) {
    current /= component;
    if (fs::is_symlink(fs::symlink_status(current, error)) || error) return false;
  }
  struct stat info;
  if (lstat(root.c_str(), &info) || !S_ISDIR(info.st_mode) || info.st_uid != geteuid()
      || (info.st_mode & (S_IRWXG | S_IRWXO))) return false;
  for (const char* child : {"userdata", "chromium.log", "chromium-restore.log",
                           "native-command.ready", "native-command.ready.tmp", "store-close.request",
                           "store-open.request", "store-inspect.request"}) {
    error.clear();
    const auto status = fs::symlink_status(root / child, error);
    if (status.type() != fs::file_type::not_found) {
      if (std::string(child) == "userdata") {
        if (!fs::is_directory(status) || (phase == "initial" && !fs::is_empty(root / child, error))
            || error) return false;
      } else if (std::string(child) == "chromium.log" && phase == "restore") {
        if (!fs::is_regular_file(status)) return false;
      } else return false;
      struct stat child_info;
      if (lstat((root / child).c_str(), &child_info) || child_info.st_uid != geteuid()
          || (std::string(child) == "userdata"
              && (child_info.st_mode & (S_IRWXG | S_IRWXO)))) return false;
    }
  }
  if (phase == "restore") {
    const fs::path data = root / "userdata";
    const std::vector<const char*> profiles = store_probe ? std::vector<const char*>{"Default"}
      : std::vector<const char*>{"profile-a", "profile-b"};
    for (const char* name : profiles) {
      struct stat profile_info;
      if (lstat((data / name).c_str(), &profile_info) || !S_ISDIR(profile_info.st_mode)
          || profile_info.st_uid != geteuid() || (profile_info.st_mode & (S_IRWXG | S_IRWXO))) return false;
    }
    for (fs::recursive_directory_iterator entry(data, fs::directory_options::none, error), end;
         !error && entry != end; entry.increment(error)) {
      struct stat child_info;
      if (lstat(entry->path().c_str(), &child_info) || child_info.st_uid != geteuid()
          || !(S_ISDIR(child_info.st_mode) || S_ISREG(child_info.st_mode))
          || (S_ISDIR(child_info.st_mode) && (child_info.st_mode & (S_IRWXG | S_IRWXO)))
          || (S_ISREG(child_info.st_mode) && child_info.st_nlink != 1)) return false;
    }
    if (error) return false;
  }
  const fs::path marker = root / ".synthetic-fixture";
  if (lstat(marker.c_str(), &info) || !S_ISREG(info.st_mode) || info.st_nlink != 1
      || info.st_uid != geteuid() || info.st_size > 100) return false;
  std::ifstream input(marker);
  std::string content;
  std::getline(input, content);
  return content == "orbit-synthetic-engine-gate-v1";
}

class GateHandler : public CefClient,
                    public CefLifeSpanHandler,
                    public CefLoadHandler,
                    public CefDisplayHandler,
                    public CefRequestHandler {
 public:
  GateHandler(std::string origin, std::string style, std::string root)
      : origin_(origin), style_(style), root_(root) {}
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD();
    browsers_.push_back(browser);
    ++created_;
    if (created_ == 1) primary_browser_id_ = browser->GetIdentifier();
    if (closing_) {
      had_failure = true;
      Record(@"late-browser-created", @{@"browserID": @(browser->GetIdentifier())});
      browser->GetHost()->CloseBrowser(true);
      return;
    }
    browser->GetHost()->SetAudioMuted(true);
    const auto runtime = browser->GetHost()->GetRuntimeStyle();
    const bool hidden = NoVisibleWindows();
    Record(@"browser-created", @{@"browserID": @(browser->GetIdentifier()),
      @"runtime": runtime == CEF_RUNTIME_STYLE_CHROME ? @"chrome" : @"alloy",
      @"hidden": @(hidden), @"foregroundInSlot": @(ForegroundInSlot()),
      @"nativeVisibleAllowed": @(native_visible_slot),
      @"cachePathPresent": @(!browser->GetHost()->GetRequestContext()->GetCachePath().empty())});
    if (!WindowStateAllowed() || (NativeStyle(style_) && created_ > (store_probe ? 8 : 2))) {
      had_failure = true;
      CloseAll();
      return;
    }
    if (NativeStyle(style_) && created_ == 2) {
      browser->GetMainFrame()->LoadURL(origin_ + "/page?case=" + style_ + "-b");
      Record(@"native-second-navigation", @{@"browserID": @(browser->GetIdentifier())});
    }
  }

  bool OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int,
      const CefString&, const CefString&, WindowOpenDisposition, bool,
      const CefPopupFeatures&, CefWindowInfo&, CefRefPtr<CefClient>&,
      CefBrowserSettings&, CefRefPtr<CefDictionaryValue>&, bool*) override {
    Record(@"popup-rejected", @{});
    return true;
  }

  bool OnBeforeBrowse(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
      CefRefPtr<CefRequest> request, bool, bool) override {
    const std::string url = request->GetURL();
    const bool allowed = url.starts_with(origin_ + "/") || url.starts_with("chrome-extension://")
      || url == "about:blank" || StoreNavigationAllowed(url);
    if (store_probe && !allowed) {
      NSURLComponents* parsed = [NSURLComponents componentsWithString:[NSString stringWithUTF8String:url.c_str()]];
      Record(@"store-navigation-rejected", @{@"mainFrame": @(frame->IsMain()),
        @"storeHost": @([parsed.host isEqualToString:@"chromewebstore.google.com"]),
        @"storePathExact": @([parsed.path isEqualToString:@"/detail/ublock-origin-lite/ddkjiahejlhfcafbddmgiahcphecmpfh"]),
        @"storeIDInPath": @([parsed.path containsString:@"ddkjiahejlhfcafbddmgiahcphecmpfh"]),
        @"https": @([parsed.scheme isEqualToString:@"https"]),
        @"googleConsent": @([parsed.host isEqualToString:@"consent.google.com"]),
        @"googleSearch": @([parsed.host isEqualToString:@"www.google.com"]),
        @"legacyStore": @([parsed.host isEqualToString:@"chrome.google.com"]),
        @"hasCredentials": @(parsed.user != nil || parsed.password != nil)});
    }
    return !allowed;
  }

  bool OnConsoleMessage(CefRefPtr<CefBrowser> browser, cef_log_severity_t,
      const CefString& message, const CefString& source, int) override {
    const std::string text = message;
    const std::string prefix = "ORBIT_ENGINE_STORE_REPORT:";
    if (!store_probe || !text.starts_with(prefix) || text.size() > 2048
        || !browser->GetMainFrame()->GetURL().ToString().starts_with("chrome://extensions/")
        || !source.ToString().starts_with("chrome://extensions/")) return false;
    NSString* payload = [NSString stringWithUTF8String:text.substr(prefix.size()).c_str()];
    if (!payload) return true;
    id value = [NSJSONSerialization JSONObjectWithData:[payload dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nullptr];
    if (![value isKindOfClass:[NSDictionary class]] || [value count] != 5
        || ![value[@"extensionID"] isEqual:@"ddkjiahejlhfcafbddmgiahcphecmpfh"]
        || ![value[@"present"] isKindOfClass:[NSNumber class]]
        || ![value[@"enabled"] isKindOfClass:[NSNumber class]]
        || ![value[@"fromWebStore"] isKindOfClass:[NSNumber class]]) return true;
    id version = value[@"version"];
    if (version != NSNull.null && (![version isKindOfClass:[NSString class]] || [version length] > 64)) return true;
    Record(@"store-extension-observed", @{@"extensionID": value[@"extensionID"],
      @"version": version == NSNull.null ? @"" : version, @"present": @([value[@"present"] boolValue]),
      @"enabled": @([value[@"enabled"] boolValue]), @"fromWebStore": @([value[@"fromWebStore"] boolValue])});
    return true;
  }

  void OnLoadEnd(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int status) override {
    if (!frame->IsMain()) return;
    const std::string url = frame->GetURL();
    if (NativeStyle(style_) && !url.starts_with(origin_ + "/page?case=" + style_ + "-")) {
      if (store_probe && StoreNavigationAllowed(url)) {
        Record(@"store-page-loaded", @{@"browserID": @(browser->GetIdentifier()), @"status": @(status),
          @"storePage": @(url.starts_with("https://chromewebstore.google.com/"))});
        if (status != 200) had_failure = true;
        if (url.starts_with("chrome://extensions/")) {
          const char* inspection = R"JS((()=>{
            const extensionID = 'ddkjiahejlhfcafbddmgiahcphecmpfh';
            const emit = (item) => console.log('ORBIT_ENGINE_STORE_REPORT:' + JSON.stringify({extensionID,
              present:!!item, enabled:item?.state==='ENABLED', version:item?.version??null,
              fromWebStore:item?.location==='FROM_STORE'}));
            try { chrome.developerPrivate.getExtensionsInfo({includeDisabled:true,includeTerminated:true},
              (items)=>emit(items?.find((item)=>item.id===extensionID))); } catch { emit(null); }
          })();)JS";
          frame->ExecuteJavaScript(inspection, url, 1);
        }
      }
      return;
    }
    Record(@"page-loaded", @{@"browserID": @(browser->GetIdentifier()), @"status": @(status),
      @"hidden": @(NoVisibleWindows())});
    if (status == 200) loaded_.insert(browser->GetIdentifier());
    else had_failure = true;
    if (status == 200 && browser->GetHost()->GetRuntimeStyle() == CEF_RUNTIME_STYLE_CHROME) {
      const int new_tab = cef_id_for_command_id_name("IDC_NEW_TAB");
      const int split_tab = cef_id_for_command_id_name("IDC_NEW_SPLIT_TAB");
      Record(@"chrome-command-probe", @{@"browserID": @(browser->GetIdentifier()),
        @"newTabMapped": @(new_tab > 0), @"newTabEnabled": @(new_tab > 0 && browser->GetHost()->CanExecuteChromeCommand(new_tab)),
        @"splitTabMapped": @(split_tab > 0), @"splitTabEnabled": @(split_tab > 0 && browser->GetHost()->CanExecuteChromeCommand(split_tab))});
    }
    if (NativeStyle(style_)) {
      id handle = (__bridge id)browser->GetHost()->GetWindowHandle();
      NSWindow* window = [handle isKindOfClass:[NSWindow class]] ? (NSWindow*)handle :
        [handle isKindOfClass:[NSView class]] ? ((NSView*)handle).window : nil;
      if (!primary_window_) primary_window_ = window;
      Record(@"native-window-probe", @{@"browserID": @(browser->GetIdentifier()),
        @"windowPresent": @(window != nil), @"sameWindow": @(window != nil && window == primary_window_),
        @"visible": @(window.visible), @"windowWidth": @((int)window.contentLayoutRect.size.width),
        @"foregroundInSlot": @(ForegroundInSlot())});
      if (!native_command_scheduled_) {
        native_command_scheduled_ = true;
        CefPostDelayedTask(TID_UI, base::BindOnce(&GateHandler::WaitForNativeCommand,
          CefRefPtr<GateHandler>(this), browser), 100);
      }
      if (loaded_.size() == 2 && !native_layout_scheduled_) {
        native_layout_scheduled_ = true;
        CefPostDelayedTask(TID_UI, base::BindOnce(&GateHandler::CaptureNativeLayout,
          CefRefPtr<GateHandler>(this)), 3000);
      }
    }
    if (!WindowStateAllowed()) had_failure = true;
  }

  void CaptureNativeLayout() {
    CEF_REQUIRE_UI_THREAD();
    if (closing_ || !WindowStateAllowed()) return;
    const char* script = R"JS((()=>{
      const report = {kind:'native-layout', case:new URL(location.href).searchParams.get('case'),
        visibility:document.visibilityState, viewportWidth:Math.floor(innerWidth), viewportHeight:Math.floor(innerHeight)};
      fetch('/layout-report', {method:'POST', credentials:'same-origin', headers:{'Content-Type':'application/json'},
        body:JSON.stringify(report)}).catch(()=>{});
    })();)JS";
    for (const auto& browser : browsers_) {
      auto frame = browser->GetMainFrame();
      const std::string url = frame->GetURL();
      if (url.starts_with(origin_ + "/page?case=" + style_ + "-")) frame->ExecuteJavaScript(script, url, 1);
    }
    Record(@"native-layout-requested", @{@"count": @(browsers_.size())});
  }

  void WaitForNativeCommand(CefRefPtr<CefBrowser> browser) {
    CEF_REQUIRE_UI_THREAD();
    if (closing_ || native_command_requested_) return;
    if (!WindowStateAllowed()) {
      had_failure = true;
      CloseAll();
      return;
    }
    const std::string path = root_ + "/native-command.ready";
    const int descriptor = open(path.c_str(), O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    if (descriptor < 0 && errno == ENOENT) {
      CefPostDelayedTask(TID_UI, base::BindOnce(&GateHandler::WaitForNativeCommand,
        CefRefPtr<GateHandler>(this), browser), 250);
      return;
    }
    struct stat info;
    char content[64];
    const bool valid = descriptor >= 0 && fstat(descriptor, &info) == 0
      && S_ISREG(info.st_mode) && info.st_uid == geteuid() && info.st_nlink == 1
      && !(info.st_mode & (S_IRWXG | S_IRWXO));
    const ssize_t size = valid ? read(descriptor, content, sizeof(content)) : -1;
    if (descriptor >= 0) close(descriptor);
    if (!valid || size < 0 || std::string(content, static_cast<size_t>(size)) != "orbit-engine-gate-native-command-v1") {
      had_failure = true;
      Record(@"native-command-ready-rejected", @{});
      CloseAll();
      return;
    }
    IssueNativeCommand(browser);
  }

  void IssueNativeCommand(CefRefPtr<CefBrowser> browser) {
    CEF_REQUIRE_UI_THREAD();
    if (closing_) return;
    const bool split = style_ == "chrome-native-split";
    const int command = cef_id_for_command_id_name(split ? "IDC_NEW_SPLIT_TAB" : "IDC_NEW_TAB");
    const bool enabled = command > 0 && browser->GetHost()->CanExecuteChromeCommand(command);
    Record(@"native-command", @{@"split": @(split), @"enabled": @(enabled),
      @"foregroundInSlot": @(ForegroundInSlot())});
    if (!enabled || !WindowStateAllowed()) {
      had_failure = true;
      CloseAll();
      return;
    }
    native_command_requested_ = true;
    browser->GetHost()->ExecuteChromeCommand(command, CEF_WOD_CURRENT_TAB);
  }

  void OnLoadError(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
      ErrorCode error, const CefString&, const CefString& failed_url) override {
    if (frame->IsMain()) {
      const std::string url = failed_url;
      if (NativeStyle(style_) && native_command_requested_ && created_ == 2 && !closing_
          && browser->GetIdentifier() != primary_browser_id_ && !loaded_.contains(browser->GetIdentifier()) && error == ERR_ABORTED
          && (url == "chrome://newtab/" || url == "chrome://new-tab-page/")) {
        Record(@"internal-navigation-cancelled", @{@"browserID": @(browser->GetIdentifier())});
        return;
      }
      if (!(closing_ && error == ERR_ABORTED)) had_failure = true;
      Record(@"page-error", @{@"browserID": @(browser->GetIdentifier()), @"code": @(error)});
    }
  }

  static void DetachNativeParent(CefRefPtr<CefBrowser> browser) {
    NSView* view = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
    NSWindow* parent = view.window;
    [view removeFromSuperview];
    parent.contentView = nil;
    [parent close];
  }

  bool DoClose(CefRefPtr<CefBrowser> browser) override {
    if (browser->GetHost()->GetRuntimeStyle() == CEF_RUNTIME_STYLE_ALLOY) {
      CefPostTask(TID_UI, base::BindOnce(&GateHandler::DetachNativeParent, browser));
      return true;
    }
    return false;
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    std::erase_if(browsers_, [&](const auto& item) { return item->IsSame(browser); });
    ++closed_;
    if (!closing_ && !store_probe) had_failure = true;
    Record(@"browser-closed", @{@"browserID": @(browser->GetIdentifier())});
    if (browsers_.empty()) {
      if (NativeStyle(style_)) {
        CefPostDelayedTask(TID_UI, base::BindOnce(&GateHandler::FinishNativeClose,
          CefRefPtr<GateHandler>(this), 0), 100);
      } else {
        Record(@"all-closed", @{@"hidden": @(NoVisibleWindows())});
        CefQuitMessageLoop();
      }
    }
  }

  void FinishNativeClose(int attempt) {
    CEF_REQUIRE_UI_THREAD();
    if (!browsers_.empty() || !native_window_closed_ || !NoVisibleWindows()) {
      if (attempt < 20) {
        CefPostDelayedTask(TID_UI, base::BindOnce(&GateHandler::FinishNativeClose,
          CefRefPtr<GateHandler>(this), attempt + 1), 100);
        return;
      }
      had_failure = true;
    }
    audit_finished_ = true;
    Record(@"all-closed", @{@"hidden": @(NoVisibleWindows()), @"foregroundInSlot": @(ForegroundInSlot())});
    CefQuitMessageLoop();
  }

  void NativeWindowClosing(NSWindow* window) {
    if (window == primary_window_) {
      native_window_closed_ = true;
      Record(@"native-window-closed", @{@"primaryWindow": @YES});
      [NSApp hide:nil];
    }
  }

  void CloseAll() {
    CEF_REQUIRE_UI_THREAD();
    closing_ = true;
    if ((store_probe ? created_ < 2 || created_ > 8 : created_ != 2)
        || loaded_.size() != 2 || !WindowStateAllowed()) had_failure = true;
    Record(@"closing", @{@"count": @(browsers_.size()), @"hidden": @(NoVisibleWindows())});
    const auto retiring = browsers_;
    for (const auto& browser : retiring) browser->GetHost()->CloseBrowser(true);
    if (browsers_.empty()) CefQuitMessageLoop();
  }

  void AuditWindowState() {
    if (audit_finished_ || (closing_ && !NativeStyle(style_))) return;
    if (!WindowStateAllowed()) {
      had_failure = true;
      Record(@"visibility-violation", @{@"hidden": @(NoVisibleWindows()),
        @"foregroundInSlot": @(ForegroundInSlot())});
      if (!closing_) CloseAll();
    }
    if (store_probe && !closing_) {
      HandleStoreNavigation("store-open.request", store_opened_,
        "https://chromewebstore.google.com/detail/ublock-origin-lite/ddkjiahejlhfcafbddmgiahcphecmpfh");
      HandleStoreNavigation("store-inspect.request", store_inspected_, "chrome://extensions/");
      const std::string request = root_ + "/store-close.request";
      struct stat info;
      if (lstat(request.c_str(), &info) == 0) {
        if (S_ISREG(info.st_mode) && info.st_uid == geteuid() && info.st_nlink == 1
            && !(info.st_mode & (S_IRWXG | S_IRWXO)) && info.st_size == 0) CloseAll();
        else { had_failure = true; CloseAll(); }
      }
    }
    CefPostDelayedTask(TID_UI, base::BindOnce(&GateHandler::AuditWindowState, this), 100);
  }

  void HandleStoreNavigation(const char* name, bool& consumed, const char* destination) {
    if (consumed || closing_) return;
    const std::string path = root_ + "/" + name;
    struct stat info;
    if (lstat(path.c_str(), &info) != 0) return;
    consumed = true;
    const bool valid = S_ISREG(info.st_mode) && info.st_uid == geteuid() && info.st_nlink == 1
      && !(info.st_mode & (S_IRWXG | S_IRWXO)) && info.st_size == 0 && loaded_.size() == 2;
    auto target = std::find_if(browsers_.begin(), browsers_.end(), [&](const auto& browser) {
      return browser->GetIdentifier() != primary_browser_id_ && loaded_.contains(browser->GetIdentifier());
    });
    if (!valid || target == browsers_.end()) {
      had_failure = true;
      CloseAll();
      return;
    }
    (*target)->GetMainFrame()->LoadURL(destination);
    Record(@"store-navigation-requested", @{@"storePage": @(std::string(name) == "store-open.request")});
  }

  bool LifecycleComplete() const {
    return (store_probe ? created_ >= 2 && created_ <= 8 : created_ == 2)
      && closed_ == created_ && loaded_.size() == 2 && browsers_.empty();
  }

 private:
  const std::string origin_;
  const std::string style_;
  const std::string root_;
  __weak NSWindow* primary_window_ = nil;
  bool native_command_scheduled_ = false;
  bool native_command_requested_ = false;
  bool native_layout_scheduled_ = false;
  bool native_window_closed_ = false;
  bool audit_finished_ = false;
  bool store_opened_ = false;
  bool store_inspected_ = false;
  int primary_browser_id_ = 0;
  std::vector<CefRefPtr<CefBrowser>> browsers_;
  std::set<int> loaded_;
  int created_ = 0;
  int closed_ = 0;
  bool closing_ = false;
  IMPLEMENT_REFCOUNTING(GateHandler);
};

class HiddenWindowDelegate : public CefWindowDelegate {
 public:
  explicit HiddenWindowDelegate(CefRefPtr<CefBrowserView> view) : view_(view) {}
  void OnWindowCreated(CefRefPtr<CefWindow> window) override {
    window->AddChildView(view_);
    id nativeHandle = (__bridge id)window->GetWindowHandle();
    const bool isWindow = [nativeHandle isKindOfClass:[NSWindow class]];
    const bool isView = [nativeHandle isKindOfClass:[NSView class]];
    NSWindow* nativeWindow = isWindow ? (NSWindow*)nativeHandle :
      isView ? ((NSView*)nativeHandle).window : nil;
    NSSearchField* nativeControl = [[NSSearchField alloc] initWithFrame:NSMakeRect(8, 8, 180, 24)];
    nativeControl.stringValue = @"Synthetic AppKit control";
    if (nativeWindow.contentView) {
      [nativeWindow.contentView addSubview:nativeControl positioned:NSWindowAbove relativeTo:nil];
    }
    Record(@"appkit-control-probe", @{@"attached": @(nativeControl.window == nativeWindow && nativeWindow != nil),
      @"windowHandleIsWindow": @(isWindow), @"windowHandleIsView": @(isView),
      @"hidden": @(NoVisibleWindows())});
    Record(@"window-created", @{@"visible": @(window->IsVisible()), @"hidden": @(NoVisibleWindows())});
  }
  void OnWindowDestroyed(CefRefPtr<CefWindow>) override { view_ = nullptr; }
  bool CanClose(CefRefPtr<CefWindow>) override {
    auto browser = view_ ? view_->GetBrowser() : nullptr;
    return !browser || browser->GetHost()->TryCloseBrowser();
  }
  CefSize GetPreferredSize(CefRefPtr<CefView>) override { return CefSize(800, 600); }
  cef_show_state_t GetInitialShowState(CefRefPtr<CefWindow>) override { return CEF_SHOW_STATE_HIDDEN; }
  cef_runtime_style_t GetWindowRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }
 private:
  CefRefPtr<CefBrowserView> view_;
  IMPLEMENT_REFCOUNTING(HiddenWindowDelegate);
};

class GateViewDelegate : public CefBrowserViewDelegate {
 public:
  cef_runtime_style_t GetBrowserRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }
 private:
  IMPLEMENT_REFCOUNTING(GateViewDelegate);
};

class ProfileContextHandler : public CefRequestContextHandler {
 public:
  explicit ProfileContextHandler(std::function<void(CefRefPtr<CefRequestContext>)> ready)
      : ready_(std::move(ready)) {}
  void OnRequestContextInitialized(CefRefPtr<CefRequestContext> context) override {
    CEF_REQUIRE_UI_THREAD();
    auto ready = std::move(ready_);
    if (ready) ready(context);
  }
 private:
  std::function<void(CefRefPtr<CefRequestContext>)> ready_;
  IMPLEMENT_REFCOUNTING(ProfileContextHandler);
};

class GateApp : public CefApp, public CefBrowserProcessHandler {
 public:
  GateApp(std::string origin, std::string style, std::string root, std::string phase, int duration)
      : origin_(origin), style_(style), root_(root), phase_(phase), duration_(duration) {}
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }
  CefRefPtr<CefClient> GetDefaultClient() override { return handler_; }
  bool LifecycleComplete() const { return handler_ && handler_->LifecycleComplete(); }
  void NativeWindowClosing(NSWindow* window) { if (handler_) handler_->NativeWindowClosing(window); }

  void CloseAll() {
    CEF_REQUIRE_UI_THREAD();
    profile_creation_closed_ = true;
    handler_->CloseAll();
    profile_contexts_.clear();
  }

  void CreateProfileBrowser(int index, CefRefPtr<CefRequestContext> context) {
    CEF_REQUIRE_UI_THREAD();
    if (profile_creation_closed_) return;
    const std::string url = origin_ + "/page?case=" + style_ + (index == 0 ? "-a" : "-b")
      + (style_ == "chrome-profiles" ? "&phase=" + phase_ : "");
    CefBrowserSettings settings;
    auto view = CefBrowserView::CreateBrowserView(handler_, url, settings, nullptr, context, new GateViewDelegate());
    if (!view) {
      had_failure = true;
      Record(@"creation-rejected", @{@"case": @(index)});
      return;
    }
    CefWindow::CreateTopLevelWindow(new HiddenWindowDelegate(view));
  }

  void OnBeforeCommandLineProcessing(const CefString&, CefRefPtr<CefCommandLine> command) override {
    if (store_probe) command->AppendSwitch("force-renderer-accessibility");
    for (const char* flag : {"use-mock-keychain", "disable-background-networking", "disable-component-update",
          "no-first-run", "no-default-browser-check", "disable-sync"}) command->AppendSwitch(flag);
  }

  void OnContextInitialized() override {
    CEF_REQUIRE_UI_THREAD();
    [NSApp setActivationPolicy:native_visible_slot ? NSApplicationActivationPolicyAccessory : NSApplicationActivationPolicyProhibited];
    handler_ = new GateHandler(origin_, style_, root_);
    handler_->AuditWindowState();
    if (!WindowStateAllowed()) return;
    CefBrowserSettings settings;
    for (int index = 0; index < 2; ++index) {
      if (NativeStyle(style_) && index == 1) break;
      const std::string url = origin_ + "/page?case=" + style_ + (index == 0 ? "-a" : "-b")
        + (style_ == "chrome-profiles" ? "&phase=" + phase_ : "");
      CefRefPtr<CefRequestContext> context;
      if (style_ == "chrome-profiles") {
        CefRequestContextSettings context_settings;
        CefString(&context_settings.cache_path) = root_ + "/userdata/profile-" + (index == 0 ? "a" : "b");
        context_settings.persist_session_cookies = true;
        CefRefPtr<GateApp> owner(this);
        context = CefRequestContext::CreateContext(context_settings,
          new ProfileContextHandler([owner, index](CefRefPtr<CefRequestContext> ready) {
            owner->CreateProfileBrowser(index, ready);
          }));
        profile_contexts_.push_back(context);
        continue;
      } else {
        context = CefRequestContext::GetGlobalContext();
      }
      if (NativeStyle(style_)) {
        CefWindowInfo info;
        info.runtime_style = CEF_RUNTIME_STYLE_CHROME;
        info.bounds = CefRect(100, 100, 1100, 750);
        CefString(&info.window_name) = "EngineGate Synthetic Native Window";
        if (!CefBrowserHost::CreateBrowser(info, handler_, url, settings, nullptr, context)) {
          had_failure = true;
          Record(@"creation-rejected", @{@"case": @(index)});
        }
      } else if (style_ == "chrome-views" || style_ == "chrome-workers") {
        auto view = CefBrowserView::CreateBrowserView(handler_, url, settings, nullptr, context, new GateViewDelegate());
        CefWindow::CreateTopLevelWindow(new HiddenWindowDelegate(view));
      } else {
        NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 600)
          styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        window.releasedWhenClosed = NO;
        [parents_ addObject:window];
        CefWindowInfo info;
        info.SetAsChild((__bridge CefWindowHandle)window.contentView, CefRect(0, 0, 800, 600));
        info.hidden = true;
        // Observe the documented parent-view override instead of asserting a requested style.
        info.runtime_style = CEF_RUNTIME_STYLE_CHROME;
        if (!CefBrowserHost::CreateBrowser(info, handler_, url, settings, nullptr, context)) {
          had_failure = true;
          Record(@"creation-rejected", @{@"case": @(index)});
        }
      }
    }
    if (style_ == "chrome-profiles" && profile_contexts_.size() == 2) {
      const std::string first = profile_contexts_[0]->GetCachePath();
      const std::string second = profile_contexts_[1]->GetCachePath();
      Record(@"profile-contexts", @{@"sharing": @(profile_contexts_[0]->IsSharingWith(profile_contexts_[1])),
        @"distinctPaths": @(!first.empty() && !second.empty() && first != second),
        @"underRoot": @(first.starts_with(root_ + "/userdata/") && second.starts_with(root_ + "/userdata/"))});
    }
    Record(@"context-ready", @{@"style": [NSString stringWithUTF8String:style_.c_str()],
      @"hidden": @(NoVisibleWindows()), @"nativeVisibleAllowed": @(native_visible_slot),
      @"foregroundInSlot": @(ForegroundInSlot()), @"mockKeychainRequested": @YES});
    CefPostDelayedTask(TID_UI, base::BindOnce(&GateApp::CloseAll, CefRefPtr<GateApp>(this)), duration_);
  }

 private:
  const std::string origin_;
  const std::string style_;
  const std::string root_;
  const std::string phase_;
  const int duration_;
  CefRefPtr<GateHandler> handler_;
  std::vector<CefRefPtr<CefRequestContext>> profile_contexts_;
  bool profile_creation_closed_ = false;
  NSMutableArray<NSWindow*>* parents_ = [NSMutableArray array];
  IMPLEMENT_REFCOUNTING(GateApp);
};
}  // namespace

@interface GateApplication : NSApplication <CefAppProtocol> {
  BOOL handlingSendEvent_;
}
@end
@implementation GateApplication
- (BOOL)isHandlingSendEvent { return handlingSendEvent_; }
- (void)setHandlingSendEvent:(BOOL)value { handlingSendEvent_ = value; }
- (void)sendEvent:(NSEvent*)event {
  CefScopedSendingEvent sendingEventScoper;
  [super sendEvent:event];
}
@end

int main(int argc, char* argv[]) {
  CefScopedLibraryLoader loader;
  if (!loader.LoadInMain()) return 70;
  @autoreleasepool {
    [GateApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    auto command = CefCommandLine::CreateCommandLine();
    command->InitFromArgv(argc, argv);
    const std::string root = command->GetSwitchValue("gate-root");
    const std::string origin = command->GetSwitchValue("gate-origin");
    const std::string style = command->GetSwitchValue("gate-style");
    store_probe = style == "chrome-native-store";
    const std::string phase = command->GetSwitchValue("gate-phase");
    native_visible_slot = NativeStyle(style);
    const std::string duration_string = command->GetSwitchValue("gate-duration-ms");
    NSURLComponents* parsed = [NSURLComponents componentsWithString:[NSString stringWithUTF8String:origin.c_str()]];
    if (!command->HasSwitch("use-mock-keychain") || command->HasSwitch("no-sandbox")
        || (phase != "initial" && phase != "restore")
        || (phase == "restore" && style != "chrome-profiles" && !store_probe)
        || command->HasSwitch("gate-native-visible") != native_visible_slot
        || !SyntheticRoot(root, phase)
        || ![parsed.scheme isEqualToString:@"http"] || ![parsed.host isEqualToString:@"127.0.0.1"]
        || !parsed.port || parsed.user || parsed.password || parsed.query || parsed.fragment
        || !(parsed.path.length == 0 || [parsed.path isEqualToString:@"/"])
        || (style != "chrome-views" && style != "alloy-appkit" && style != "chrome-profiles"
            && style != "chrome-workers" && !native_visible_slot)) {
      Record(@"preflight-rejected", @{});
      return 64;
    }
    if (native_visible_slot) {
      NSRunningApplication* foreground = NSWorkspace.sharedWorkspace.frontmostApplication;
      foreground_process = foreground.processIdentifier;
      [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    }
    int duration = 20000;
    if (!duration_string.empty() && duration_string.find_first_not_of("0123456789") == std::string::npos
        && duration_string.length() <= 6) duration = std::stoi(duration_string);
    if (duration < 1000 || duration > (store_probe ? 180000 : style == "chrome-workers" ? 90000 : 45000)) return 64;
    CefSettings settings;
    settings.no_sandbox = false;
    CefString(&settings.root_cache_path) = root + "/userdata";
    CefString(&settings.cache_path) = root + "/userdata";
    CefString(&settings.log_file) = root + (phase == "restore" ? "/chromium-restore.log" : "/chromium.log");
    CefString(&settings.keychain_service_name) = "EngineGate Synthetic Safe Storage";
    CefString(&settings.keychain_account_name) = "EngineGate Synthetic";
    settings.log_severity = LOGSEVERITY_WARNING;
    CefRefPtr<GateApp> app = new GateApp(origin, style, root, phase, duration);
    Record(@"initializing", @{@"mockKeychainRequested": @YES, @"sandboxRequested": @YES,
      @"nativeVisibleAllowed": @(native_visible_slot), @"foregroundInSlot": @(ForegroundInSlot()),
      @"hidden": @(NoVisibleWindows())});
    NSMutableArray* observers = [NSMutableArray array];
    for (NSNotificationName name in @[NSApplicationDidBecomeActiveNotification, NSWindowDidBecomeKeyNotification, NSWindowDidExposeNotification]) {
      id observer = [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification*) {
        if (!WindowStateAllowed()) {
          had_failure = true;
          Record(@"visibility-violation", @{@"hidden": @(NoVisibleWindows()),
            @"foregroundInSlot": @(ForegroundInSlot())});
        }
      }];
      [observers addObject:observer];
    }
    if (native_visible_slot) {
      id observer = [NSNotificationCenter.defaultCenter addObserverForName:NSWindowWillCloseNotification
        object:nil queue:nil usingBlock:^(NSNotification* notification) {
          app->NativeWindowClosing(notification.object);
        }];
      [observers addObject:observer];
    }
    if (!CefInitialize(CefMainArgs(argc, argv), settings, app, nullptr)) {
      Record(@"initialization-failed", @{@"exitCode": @(CefGetExitCode())});
      return CefGetExitCode() ?: 70;
    }
    CefRunMessageLoop();
    if (!app->LifecycleComplete() || !NoVisibleWindows()) had_failure = true;
    CefShutdown();
    if (!NoVisibleWindows() || !WindowStateAllowed()) had_failure = true;
    for (id observer in observers) [NSNotificationCenter.defaultCenter removeObserver:observer];
    Record(@"shutdown", @{@"hidden": @(NoVisibleWindows()), @"failed": @(had_failure)});
  }
  return had_failure ? 1 : 0;
}
