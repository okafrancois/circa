#import <AppKit/AppKit.h>
#include "ChromiumBridge.h"

#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_find_handler.h"
#include "include/cef_download_handler.h"
#include "include/cef_command_ids.h"
#include "include/cef_id_mappers.h"
#include "include/cef_parser.h"
#include "include/cef_request_context.h"
#include "include/cef_task.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"
#include "include/views/cef_browser_view.h"
#include "include/views/cef_browser_view_delegate.h"
#include "include/views/cef_window.h"
#include "include/views/cef_window_delegate.h"

#include <algorithm>
#include <chrono>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <functional>
#include <map>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

@interface ALChromiumApplication : NSApplication <CefAppProtocol> {
  BOOL handlingSendEvent_;
}
@end

@implementation ALChromiumApplication
- (BOOL)isHandlingSendEvent { return handlingSendEvent_; }
- (void)setHandlingSendEvent:(BOOL)value { handlingSendEvent_ = value; }
- (void)sendEvent:(NSEvent*)event {
  CefScopedSendingEvent scope;
  [super sendEvent:event];
}
- (void)terminate:(id)sender { ALChromiumRequestQuit(); }
@end

namespace {
using Clock = std::chrono::steady_clock;
constexpr const char* kMarker = "chromium-shell-synthetic-v1\n";
constexpr int kMaximumSeconds = 75;

bool NoVisibleWindows() {
  for (NSWindow* window in NSApp.windows) if (window.visible) return false;
  return true;
}
// Chromium d0c02bf, chrome/common/webui_url_constants.h:321-322.
constexpr const char* kSplitNewTabPageURL =
    "chrome://tab-search.top-chrome/split_new_tab_page.html";

class FunctionTask final : public CefTask {
 public:
  explicit FunctionTask(std::function<void()> function) : function_(std::move(function)) {}
  void Execute() override { function_(); }
 private:
  std::function<void()> function_;
  IMPLEMENT_REFCOUNTING(FunctionTask);
};

bool Post(std::function<void()> function, int delay_ms = 0) {
  CefRefPtr<CefTask> task = new FunctionTask(std::move(function));
  return delay_ms ? CefPostDelayedTask(TID_UI, task, delay_ms) : CefPostTask(TID_UI, task);
}

struct Options {
  std::string root;
  std::string origin;
  int seconds = kMaximumSeconds;
  bool controlled_creation = false;
  bool page_tools_test = false;
  bool download_test = false;
  bool Hidden() const { return page_tools_test || download_test; }
};

bool PrivateFile(int directory, const char* name, const std::string& expected) {
  const int fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
  if (fd < 0) return false;
  struct stat info {};
  char content[128];
  const bool valid = fstat(fd, &info) == 0 && S_ISREG(info.st_mode)
      && info.st_uid == geteuid() && (info.st_mode & 0777) == 0600 && info.st_nlink == 1;
  const ssize_t size = valid ? read(fd, content, sizeof(content)) : -1;
  close(fd);
  return size >= 0 && std::string(content, static_cast<size_t>(size)) == expected;
}

// Refuse symlink components, reused roots, non-private permissions and roots
// outside the fixed laboratory. This gate never imports or opens real data.
bool ClaimRoot(const std::string& root) {
  const std::string base = std::string(AL_SHELL_REPO_ROOT) + "/artifacts/native-chromium-shell/";
  if (!root.starts_with(base) || root.size() <= base.size() || root.back() == '/') return false;
  NSString* path = [NSString stringWithUTF8String:root.c_str()];
  if (!path || ![path.stringByStandardizingPath isEqualToString:path]) return false;
  std::string partial;
  for (NSString* component in path.pathComponents) {
    const std::string part = component.UTF8String;
    partial = partial.empty() ? part : partial + (partial == "/" ? "" : "/") + part;
    struct stat info {};
    if (lstat(partial.c_str(), &info) != 0 || !S_ISDIR(info.st_mode)) return false;
  }
  const int directory = open(root.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
  if (directory < 0) return false;
  struct stat info {};
  NSArray<NSString*>* entries = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:nil];
  const bool fresh = fstat(directory, &info) == 0 && info.st_uid == geteuid()
      && (info.st_mode & 0777) == 0700 && entries.count == 1
      && [entries.firstObject isEqualToString:@".chromium-shell-owned"]
      && PrivateFile(directory, ".chromium-shell-owned", kMarker);
  const int claim = fresh ? openat(directory, ".chromium-shell-claimed",
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600) : -1;
  bool valid = claim >= 0;
  if (valid) {
    const char* value = "claimed-once\n";
    valid = write(claim, value, strlen(value)) == static_cast<ssize_t>(strlen(value));
    close(claim);
    valid = valid && mkdirat(directory, "cache", 0700) == 0;
  }
  close(directory);
  return valid;
}

bool PrivateDirectory(int directory) {
  struct stat info {};
  return directory >= 0 && fstat(directory, &info) == 0 && S_ISDIR(info.st_mode)
      && info.st_uid == geteuid() && (info.st_mode & 0777) == 0700;
}

int OpenLabDirectory(const std::string& root, const std::vector<std::string>& components,
                     bool create = false, bool exclusive_last = false) {
  int directory = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
  if (directory < 0) return -1;
  NSString* path = [NSString stringWithUTF8String:root.c_str()];
  for (NSString* part in path.pathComponents) {
    if ([part isEqualToString:@"/"]) continue;
    const int next = openat(directory, part.UTF8String, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    close(directory);
    directory = next;
    if (directory < 0) return -1;
  }
  if (!PrivateDirectory(directory)) { close(directory); return -1; }
  for (size_t index = 0; index < components.size(); ++index) {
    const auto& name = components[index];
    if (name.empty() || name == "." || name == ".." || name.find('/') != std::string::npos) {
      close(directory); return -1;
    }
    if (create && mkdirat(directory, name.c_str(), 0700) != 0
        && ((exclusive_last && index + 1 == components.size()) || errno != EEXIST)) {
      close(directory); return -1;
    }
    const int next = openat(directory, name.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    close(directory);
    directory = next;
    if (!PrivateDirectory(directory)) {
      if (directory >= 0) close(directory);
      return -1;
    }
  }
  return directory;
}

// Process-local synthetic environment, installed before framework loading and
// restored after shutdown. Pinned macOS GetTempDir reads MAC_CHROMIUM_TMPDIR.
// Pinned Chromium d0c02bf ReplaceFileWithPermissions
// (components/download/public/common/download_file_utils.cc:18-40) renames the
// private initial file over a placeholder created by base::WriteFile, which
// uses creat(0666) (base/files/file_util_posix.cc:1453), then chmods it to that
// placeholder's mode. The final mode is therefore 0666 & ~umask; a private
// umask, set before any CEF thread exists, makes Chromium itself produce 0600.
class DownloadEnvironment {
 public:
  bool Prepare(const Options& options) {
    if (!options.download_test) return true;
    previous_umask_ = umask(077);
    umask_installed_ = true;
    const int directory = OpenLabDirectory(options.root, {"cache", "download-temp"}, true, true);
    if (directory < 0) return false;
    close(directory);
    const std::string path = options.root + "/cache/download-temp";
    for (const char* name : {"MAC_CHROMIUM_TMPDIR", "TMPDIR"}) {
      const char* previous = getenv(name);
      entries_.push_back({name, previous ? previous : "", previous != nullptr});
      if (setenv(name, path.c_str(), 1) != 0) return false;
    }
    return true;
  }
  ~DownloadEnvironment() {
    for (const auto& entry : entries_) {
      if (entry.existed) setenv(entry.name.c_str(), entry.value.c_str(), 1);
      else unsetenv(entry.name.c_str());
    }
    if (umask_installed_) umask(previous_umask_);
  }
 private:
  struct Entry { std::string name; std::string value; bool existed; };
  std::vector<Entry> entries_;
  mode_t previous_umask_ = 0;
  bool umask_installed_ = false;
};

bool ParseOptions(int argc, char* argv[], Options& options) {
  bool mock = false;
  std::map<std::string, bool> seen;
  for (int i = 1; i < argc; ++i) {
    const std::string argument(argv[i]);
    const auto separator = argument.find('=');
    const std::string name = argument.substr(0, separator);
    const std::string value = separator == std::string::npos ? "" : argument.substr(separator + 1);
    if (seen[name]) return false;
    seen[name] = true;
    if (name == "--use-mock-keychain" && separator == std::string::npos) mock = true;
    else if (name == "--synthetic-root") options.root = value;
    else if (name == "--fixture-origin") options.origin = value;
    else if (name == "--controlled-creation" && separator == std::string::npos)
      options.controlled_creation = true;
    else if (name == "--page-tools-test" && separator == std::string::npos)
      options.page_tools_test = true;
    else if (name == "--download-test" && separator == std::string::npos)
      options.download_test = true;
    else if (name == "--auto-exit-seconds" && !value.empty() && value.size() <= 2
             && value.find_first_not_of("0123456789") == std::string::npos)
      options.seconds = atoi(value.c_str());
    else return false;
  }
  // Exact textual origin prevents credentials, path tricks, alternate hosts,
  // implicit ports and command-line options capable of choosing real profiles.
  const std::string prefix = "http://127.0.0.1:";
  if (!mock || !options.origin.starts_with(prefix)) return false;
  const auto port = options.origin.substr(prefix.size());
  if (port.empty() || port.size() > 5 || port.front() == '0'
      || port.find_first_not_of("0123456789") != std::string::npos) return false;
  const int number = atoi(port.c_str());
  return !(options.Hidden() && options.controlled_creation)
      && !(options.page_tools_test && options.download_test)
      && number > 0 && number <= 65535 && number != 4318 && options.seconds > 0
      && options.seconds <= kMaximumSeconds && ClaimRoot(options.root);
}

bool EngineNavigation(const std::string& url) {
  return url == "about:blank" || url == "chrome://newtab/"
      || url == "chrome://new-tab-page/" || url == kSplitNewTabPageURL;
}

bool SplitResourcePath(const std::string& path) {
  // Pinned tab_search/BUILD.gn and split_view/app's import/CSS closure.
  // The ordinary tab-search document and unrelated top-chrome pages stay denied.
  for (const char* allowed : {"/split_new_tab_page.js", "/strings.m.js",
      "/split_view/app.js", "/split_view/app.css.js", "/split_view/app.html.js",
      "/tab_search_item.js", "/tab_search_item.css.js", "/tab_search_item.html.js",
      "/icons.html.js", "/selectable_lazy_list.js", "/selectable_lazy_list.css.js",
      "/tab_data.js", "/tab_search_utils.js", "/tab_search_api_proxy.js",
      "/tab_search.mojom-webui.js", "/tabs.mojom-webui.js", "/tab_group_types.mojom-webui.js",
      "/tab_group_shared/tab_group_dot.js", "/tab_group_shared/tab_group_dot.css.js",
      "/tab_group_shared/tab_group_dot.html.js", "/tab_group_shared/tab_group_color_helper.js",
      "/tab_group_shared/tab_group_shared_vars.css.js", "/tab_group_shared/tab_group_types.mojom-webui.js",
      "/alert_indicators/tab_media_recording.svg", "/alert_indicators/tab_audio_rounded_old.svg",
      "/alert_indicators/tab_audio_muting_rounded_old.svg", "/alert_indicators/tab_media_glic_active.svg",
      "/alert_indicators/tab_audio_muting_rounded.svg", "/alert_indicators/tab_audio_rounded.svg"})
    if (path == allowed) return true;
  return false;
}

bool SplitFaviconResource(const std::string& url, const std::string& origin) {
  // tab_search_utils.ts calls getFaviconForPageURL(page, false). The pinned
  // icon.ts generates exactly these parameters and desktop 1x/2x image sets.
  // Do not enable the favicon service's remote/Google fallback or arbitrary URLs.
  NSURLComponents* components = [NSURLComponents componentsWithString:
      [NSString stringWithUTF8String:url.c_str()]];
  if (!components || ![components.path isEqualToString:@"/"] || components.queryItems.count != 4)
    return false;
  bool page = false, size = false, scale = false, fallback = false;
  for (NSURLQueryItem* item in components.queryItems) {
    if ([item.name isEqualToString:@"pageUrl"] && !page && item.value) {
      const std::string target = item.value.UTF8String;
      page = target.starts_with(origin + "/") || EngineNavigation(target) || target == "chrome://newtab";
      if (!page) return false;
    } else if ([item.name isEqualToString:@"size"] && !size && [item.value isEqualToString:@"16"])
      size = true;
    else if ([item.name isEqualToString:@"scaleFactor"] && !scale
        && ([item.value isEqualToString:@"1x"] || [item.value isEqualToString:@"2x"])) scale = true;
    else if ([item.name isEqualToString:@"allowGoogleServerFallback"] && !fallback
        && [item.value isEqualToString:@"0"]) fallback = true;
    else return false;
  }
  return page && size && scale && fallback;
}

bool AllowedURL(const std::string& url, const std::string& origin, bool resource = false) {
  if (EngineNavigation(url)) return true;
  // All network traffic exposed through CEF hooks stays on one explicit fixture.
  // This also rejects userinfo, alternate loopback ports, file:, data:, blob:,
  // external protocols and remote WebSocket endpoints.
  if (url.starts_with(origin + "/")) return true;
  if (!resource) return false;
  CefURLParts parts;
  if (!CefParseURL(url, parts)) return false;
  const std::string scheme = CefString(&parts.scheme);
  const std::string host = CefString(&parts.host);
  if (scheme == "chrome" && (host == "tab-search.top-chrome" || host == "favicon2")) {
    if (!CefString(&parts.username).empty() || !CefString(&parts.password).empty()
        || !CefString(&parts.port).empty()) return false;
    return host == "tab-search.top-chrome" ? SplitResourcePath(CefString(&parts.path))
        : SplitFaviconResource(url, origin);
  }
  if (scheme == "chrome") return host == "resources" || host == "theme"
      || host == "new-tab-page" || host == "newtab";
  return scheme == "chrome-untrusted" && host == "new-tab-page";
}

struct State;
State* active_state = nullptr;  // Accessed only on the main/UI thread.
CefRefPtr<CefClient> ContextClient(State* state, CefRefPtr<CefRequestContext> context);

const char* DownloadCaseName(ALChromiumDownloadCase fixture_case) {
  switch (fixture_case) {
    case AL_DOWNLOAD_NORMAL: return "normal";
    case AL_DOWNLOAD_DUPLICATE_FIRST: return "duplicate-first";
    case AL_DOWNLOAD_DUPLICATE_SECOND: return "duplicate-second";
    case AL_DOWNLOAD_PAUSE_RESUME: return "pause-resume";
    case AL_DOWNLOAD_CANCEL_PROGRESS: return "cancel-progress";
    case AL_DOWNLOAD_INTERRUPT_RESUME: return "interrupt-resume";
    case AL_DOWNLOAD_SOURCE_CLOSE: return "source-close";
    case AL_DOWNLOAD_PROFILE_B: return "profile-b";
  }
  return nullptr;
}

bool DownloadURL(const std::string& url, const std::string& origin) {
  for (int value = AL_DOWNLOAD_NORMAL; value <= AL_DOWNLOAD_PROFILE_B; ++value)
    if (url == origin + "/download?case=" + DownloadCaseName(static_cast<ALChromiumDownloadCase>(value)))
      return true;
  return false;
}

// Copy everything before calling Swift; never retain CefDownloadItem, which is
// detached by CEF immediately after its handler returns.
struct DownloadSnapshot {
  uint32_t native_id = 0;
  int64_t received = 0;
  int64_t total = -1;
  ALChromiumDownloadStatus status = AL_DOWNLOAD_PENDING;
  bool paused = false;
  int reason = 0;
  std::string original_url;
  std::string url;
  std::string path;
  std::string filename;
};

DownloadSnapshot CopyDownload(CefRefPtr<CefDownloadItem> item) {
  DownloadSnapshot copy;
  copy.native_id = item->GetId();
  copy.received = item->GetReceivedBytes();
  copy.total = item->GetTotalBytes();
  copy.status = item->IsComplete() ? AL_DOWNLOAD_COMPLETE
      : item->IsCanceled() ? AL_DOWNLOAD_CANCELED
      : item->IsInterrupted() ? AL_DOWNLOAD_INTERRUPTED
      : item->IsInProgress() ? AL_DOWNLOAD_PROGRESS : AL_DOWNLOAD_PENDING;
  if (copy.total <= 0 && copy.status != AL_DOWNLOAD_COMPLETE) copy.total = -1;
  copy.paused = item->IsPaused();
  copy.reason = item->GetInterruptReason();
  copy.original_url = item->GetOriginalUrl();
  copy.url = item->GetURL();
  copy.path = item->GetFullPath();
  copy.filename = item->GetSuggestedFileName();
  return copy;
}

struct DownloadAdmission {
  uint64_t profile;
  int source;
  uint64_t source_lifetime;
  uint64_t command;
  ALChromiumDownloadCase fixture_case;
  CefRefPtr<CefRequestContext> context;
};

struct Download {
  ALChromiumDownloadHandle handle;
  DownloadAdmission admission;
  DownloadSnapshot snapshot;
  CefRefPtr<CefDownloadItemCallback> callback;
  uint64_t last_command = 0;
  bool continued = false;
  bool revoked = false;
  bool destination_ready = false;
  std::string destination;
};

struct Host {
  CefRefPtr<CefBrowser> browser;
  uint64_t profile = 0;
  uint64_t window = 0;
  uint64_t lifetime = 0;
  uint64_t document = 0;
  uint64_t last_operation = 0;
  uint64_t query = 0;
  uint64_t find_operation = 0;
  uint64_t find_document = 0;
  int observed_find_id = -1;
  int pending_find_id = -1;
  int previous_find_id = -1;
  bool finding = false;
  bool find_pending = false;
  bool match_case = false;
  bool navigation_pending = false;
  bool closing = false;
  std::string find_text;  // Ephemeral only; never forwarded in an event.
  std::string fixture_url;
};
struct Window {
  uint64_t token;
  __weak NSWindow* object;
  bool closing = false;
};
enum class Operation { Window, Tab, Select, Close, Split, Quit };

// Hidden test only. No Show, Activate, SetFocus or regular activation policy.
// This follows EngineGate's verified chrome-views creation path.
class HiddenViewDelegate final : public CefBrowserViewDelegate {
 public:
  cef_runtime_style_t GetBrowserRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }
 private:
  IMPLEMENT_REFCOUNTING(HiddenViewDelegate);
};

class HiddenWindowDelegate final : public CefWindowDelegate {
 public:
  HiddenWindowDelegate(CefRefPtr<CefBrowserView> view, std::function<void(bool)> audit,
                       std::function<void()> destroyed)
      : view_(view), audit_(std::move(audit)), destroyed_(std::move(destroyed)) {}
  void OnWindowCreated(CefRefPtr<CefWindow> window) override {
    window->AddChildView(view_);
    audit_(window->IsVisible() || window->IsActive());
  }
  void OnWindowDestroyed(CefRefPtr<CefWindow>) override {
    view_ = nullptr;
    destroyed_();
  }
  bool CanClose(CefRefPtr<CefWindow>) override {
    auto browser = view_ ? view_->GetBrowser() : nullptr;
    return !browser || browser->GetHost()->TryCloseBrowser();
  }
  CefSize GetPreferredSize(CefRefPtr<CefView>) override { return CefSize(800, 600); }
  cef_show_state_t GetInitialShowState(CefRefPtr<CefWindow>) override { return CEF_SHOW_STATE_HIDDEN; }
  cef_runtime_style_t GetWindowRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }
 private:
  CefRefPtr<CefBrowserView> view_;
  std::function<void(bool)> audit_;
  std::function<void()> destroyed_;
  IMPLEMENT_REFCOUNTING(HiddenWindowDelegate);
};

NSWindow* CurrentNativeWindow(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  if (!browser) return nil;
  // The native Chrome path exposes an ordinary NSView handle. Never infer
  // current membership from the previously cached weak-window association.
  id handle = (__bridge id)browser->GetHost()->GetWindowHandle();
  if ([handle isKindOfClass:[NSWindow class]]) return (NSWindow*)handle;
  if (![handle isKindOfClass:[NSView class]]) return nil;
  return ((NSView*)handle).window;
}

struct State {
  Options options;
  ALChromiumCallbacks callbacks;
  void* callback_context;
  Clock::time_point deadline;
  std::map<int, Host> hosts;
  std::vector<Window> windows;
  std::vector<CefRefPtr<CefRequestContext>> profiles;
  CefRefPtr<CefRequestContext> primary;
  CefRefPtr<CefClient> client;
  CefRefPtr<CefRequestContextHandler> policy;
  bool initialized = false;
  bool quitting = false;
  bool finished = false;
  bool failed = false;
  bool split_issued = false;
  bool controlled_used = false;
  int pending_windows = 0;
  int initial_id = 0;
  int expected_source = 0;
  int expected_candidate = 0;
  uint64_t expected_window = 0;
  bool candidate_ambiguous = false;
  bool issuing_creation = false;
  uint64_t creation_generation = 0;
  uint64_t expected_generation = 0;
  uint64_t next_window = 1;
  uint64_t next_lifetime = 1;
  int hidden_windows = 0;
  int hidden_created = 0;
  bool hidden_primary_started = false;
  bool hidden_secondary_started = false;
  bool hidden_violation = false;
  bool shutting_down = false;
  std::map<std::pair<uint64_t, uint32_t>, Download> downloads;
  std::map<std::pair<uint64_t, int>, DownloadAdmission> download_admissions;
  std::map<int, bool> download_cases;
  std::map<uint64_t, uint64_t> download_start_tokens;
  uint64_t next_download_lifetime = 1;
  std::map<uint64_t, std::string> download_staging;
  bool download_failure_reported = false;

  void DownloadFailure(const char* detail, CefRefPtr<CefDownloadItemCallback> callback = nullptr) {
    if (download_failure_reported) return;
    download_failure_reported = true;
    failed = true;
    RevokeDownloads();  // Revoke every control before an external callback.
    if (callback) callback->Cancel();
    Post([this] { Quit(); });  // Unwind the native item callback before closing.
    Emit(AL_EVENT_FAILURE, 0, detail);
  }

  bool DownloadStorageReady(CefRefPtr<CefRequestContext> context, uint64_t profile) {
    const auto found = download_staging.find(profile);
    if (found == download_staging.end()) return false;
    const int directory = OpenLabDirectory(options.root,
        {"cache", "download-staging", std::to_string(profile)});
    if (directory < 0) return false;
    close(directory);
    auto value = context->GetPreference("download.default_directory");
    const std::string temporary = options.root + "/cache/download-temp";
    const char* native_temp = getenv("MAC_CHROMIUM_TMPDIR");
    const char* generic_temp = getenv("TMPDIR");
    return value && value->GetType() == VTYPE_STRING && value->GetString() == found->second
        && native_temp && native_temp == temporary && generic_temp && generic_temp == temporary;
  }

  bool ConfigureDownloadStorage(CefRefPtr<CefRequestContext> context) {
    if (!options.download_test) return true;
    const uint64_t profile = Profile(context);
    if (download_staging.contains(profile)) return DownloadStorageReady(context, profile);
    const int directory = OpenLabDirectory(options.root,
        {"cache", "download-staging", std::to_string(profile)}, true, true);
    if (directory < 0) return false;
    close(directory);
    const std::string path = options.root + "/cache/download-staging/" + std::to_string(profile);
    auto value = CefValue::Create();
    value->SetString(path);
    CefString error;
    if (!context->CanSetPreference("download.default_directory")
        || !context->SetPreference("download.default_directory", value, error)) return false;
    download_staging.emplace(profile, path);
    if (!DownloadStorageReady(context, profile)) return false;
    auto event = PageEvent(AL_EVENT_COMMAND, 0, "download-profile-storage-ready", 0, 0);
    event.profile_token = profile;
    event.value = 1;
    callbacks.event(callback_context, &event);
    return true;
  }

  void DownloadEvent(ALChromiumEventKind kind, const Download& download,
                     const char* detail, uint64_t command = 0, int value = 0) {
    ALChromiumEvent event {};
    event.struct_size = sizeof(event);
    event.kind = kind;
    event.detail = detail;
    event.value = value;
    event.profile_token = download.admission.profile;
    event.download_handle = download.handle;
    event.source_browser_id = download.admission.source;
    event.source_host_lifetime = download.admission.source_lifetime;
    event.received_bytes = download.snapshot.received;
    event.total_bytes = download.snapshot.total;
    event.download_status = download.snapshot.status;
    event.download_paused = download.snapshot.paused;
    event.interrupt_reason = download.snapshot.reason;
    event.can_resume = !download.revoked && download.callback
        && (download.snapshot.paused || download.snapshot.status == AL_DOWNLOAD_INTERRUPTED) ? -1 : 0;
    event.download_command_token = command;
    event.download_case = download.admission.fixture_case;
    event.download_path = download.destination_ready ? download.destination.c_str() : nullptr;
    event.download_filename = download.snapshot.filename.c_str();
    callbacks.event(callback_context, &event);
  }

  void DownloadReject(ALChromiumDownloadHandle handle, uint64_t command,
                      const char* detail, int value = 0) {
    ALChromiumEvent event {};
    event.struct_size = sizeof(event);
    event.kind = AL_EVENT_DOWNLOAD_REJECTED;
    event.detail = detail;
    event.value = value;
    event.download_handle = handle;  // Echo only; never bind to another context.
    event.download_command_token = command;
    event.total_bytes = -1;
    callbacks.event(callback_context, &event);
  }

  void StartDownload(int id, uint64_t lifetime, uint64_t profile, uint64_t command,
                     ALChromiumDownloadCase fixture_case) {
    CEF_REQUIRE_UI_THREAD();
    if (quitting || finished || download_failure_reported) {
      // Distinguish stopped admission before duplicate-case/host validation so
      // the post-quit probe cannot pass for an unrelated rejection reason.
      DownloadReject({profile, 0, 0, 0}, command, "download-admission-stopped");
      return;
    }
    const auto found = hosts.find(id);
    if (!options.download_test || !DownloadCaseName(fixture_case)
        || found == hosts.end() || found->second.closing || found->second.lifetime != lifetime
        || found->second.profile != profile || !command || command <= download_start_tokens[profile]
        || download_cases[fixture_case]) {
      DownloadReject({profile, 0, 0, 0}, command, "download-admission-rejected");
      return;
    }
    download_start_tokens[profile] = command;
    download_cases[fixture_case] = true;
    // Capture ownership before starting: an update can precede OnBeforeDownload.
    auto context = found->second.browser->GetHost()->GetRequestContext();
    if (!DownloadStorageReady(context, profile)) {
      DownloadFailure("download-storage-policy-rejected");
      return;
    }
    download_admissions.emplace(std::make_pair(profile, static_cast<int>(fixture_case)),
        DownloadAdmission {profile, id, lifetime, command, fixture_case, context});
    found->second.browser->GetHost()->StartDownload(
        options.origin + "/download?case=" + DownloadCaseName(fixture_case));
  }

  bool AdmitDownload(CefRefPtr<CefBrowser> browser, uint64_t profile,
                     const std::string& url) {
    if (!options.download_test || quitting || finished || download_failure_reported || !browser) return false;
    const auto host = hosts.find(browser->GetIdentifier());
    if (host == hosts.end() || host->second.profile != profile || host->second.closing) return false;
    for (const auto& [key, admission] : download_admissions)
      if (key.first == profile && admission.source == browser->GetIdentifier()
          && admission.source_lifetime == host->second.lifetime
          && url == options.origin + "/download?case=" + DownloadCaseName(admission.fixture_case)) return true;
    return false;
  }

  Download* DownloadRecord(CefRefPtr<CefBrowser> browser, uint64_t profile,
                           const DownloadSnapshot& copy) {
    if (!options.download_test || !profile || !copy.native_id) return nullptr;
    auto found = downloads.find({profile, copy.native_id});
    if (found != downloads.end()) {
      const auto& admission = found->second.admission;
      const auto expected = options.origin + "/download?case=" + DownloadCaseName(admission.fixture_case);
      if (copy.original_url == expected && copy.url == expected
          && (!browser || browser->GetIdentifier() == admission.source)) return &found->second;
      return nullptr;  // Never treat a native ID as global or rebind a live item.
    }
    if (!browser || quitting) return nullptr;
    const auto host = hosts.find(browser->GetIdentifier());
    if (host == hosts.end() || host->second.closing || host->second.profile != profile) return nullptr;
    for (auto admission = download_admissions.begin(); admission != download_admissions.end(); ++admission) {
      const auto expected = options.origin + "/download?case="
          + DownloadCaseName(admission->second.fixture_case);
      if (admission->first.first != profile || admission->second.source != browser->GetIdentifier()
          || admission->second.source_lifetime != host->second.lifetime
          || !admission->second.context->IsSame(browser->GetHost()->GetRequestContext())
          || copy.original_url != expected || copy.url != expected) continue;
      Download download {{profile, copy.native_id, next_download_lifetime++, 0},
          admission->second, copy};
      download.last_command = admission->second.command;
      download_admissions.erase(admission);
      return &downloads.emplace(std::make_pair(profile, copy.native_id), std::move(download)).first->second;
    }
    return nullptr;
  }

  bool ReserveDestination(Download& download) {
    // Reserve the private directory, not an empty payload: Chromium's pinned
    // intermediate RenameAndUniquify treats an existing leaf as a collision.
    const std::vector<std::string> components {"downloads", std::to_string(download.handle.profile_token),
        std::to_string(download.handle.download_lifetime)};
    const int directory = OpenLabDirectory(options.root, components, true, true);
    if (directory < 0) return false;
    struct stat info {};
    const bool absent = fstatat(directory, "payload.bin", &info, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT;
    close(directory);
    if (absent) download.destination = options.root + "/downloads/" + components[1]
        + "/" + components[2] + "/payload.bin";
    return absent;
  }

  bool PrivateDownloadFile(const Download& download) {
    const int directory = OpenLabDirectory(options.root,
        {"downloads", std::to_string(download.handle.profile_token),
         std::to_string(download.handle.download_lifetime)});
    if (directory < 0) return false;
    const int file = openat(directory, "payload.bin", O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    close(directory);
    if (file < 0) return false;
    struct stat info {};
    const bool valid = fstat(file, &info) == 0 && S_ISREG(info.st_mode)
        && info.st_uid == geteuid() && (info.st_mode & 0777) == 0600 && info.st_nlink == 1;
    close(file);
    return valid;
  }

  // A resumed item keeps its private partial file at the exact destination, or
  // Chromium has deleted it before a restart. Anything else is rejected.
  bool ResumableDestination(const Download& download, const DownloadSnapshot& copy) {
    if (download.destination.empty() || (!copy.path.empty() && copy.path != download.destination)) return false;
    const int directory = OpenLabDirectory(options.root,
        {"downloads", std::to_string(download.handle.profile_token),
         std::to_string(download.handle.download_lifetime)});
    if (directory < 0) return false;
    struct stat info {};
    const bool absent = fstatat(directory, "payload.bin", &info, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT;
    close(directory);
    return absent || PrivateDownloadFile(download);
  }

  bool BeforeDownload(CefRefPtr<CefBrowser> browser, uint64_t profile, DownloadSnapshot copy,
                      const std::string& suggested, CefRefPtr<CefBeforeDownloadCallback> callback) {
    CEF_REQUIRE_UI_THREAD();
    auto* download = DownloadRecord(browser, profile, copy);
    // Pinned Chromium d0c02bf DownloadItemImpl repeats target determination for
    // every resumption (download_item_impl.cc:1779-1811) and cancels on an
    // empty target (1832-1836). Reconfirm only the same generated destination
    // for the same owned, unrevoked item; suggested names still never matter.
    if (download && download->continued && !download->revoked && !quitting
        && ResumableDestination(*download, copy)) {
      copy.filename = suggested;
      download->snapshot = std::move(copy);
      ++download->handle.revision;
      const auto destination = download->destination;
      callback->Continue(destination, false);
      DownloadEvent(AL_EVENT_DOWNLOAD, *download, "download-destination-reconfirmed");
      return true;
    }
    if (!download || quitting || download->revoked || download->continued
        || !ReserveDestination(*download)) {
      // Return true without Continue: destruction cancels, no Chrome fallback.
      if (download) download->revoked = true;
      return true;
    }
    copy.filename = suggested;
    download->snapshot = std::move(copy);
    download->continued = true;
    ++download->handle.revision;
    const auto destination = download->destination;
    callback->Continue(destination, false);
    DownloadEvent(AL_EVENT_DOWNLOAD, *download, "download-destination-reserved");
    return true;
  }

  void UpdatedDownload(CefRefPtr<CefBrowser> browser, uint64_t profile, DownloadSnapshot copy,
                       CefRefPtr<CefDownloadItemCallback> callback) {
    CEF_REQUIRE_UI_THREAD();
    auto* download = DownloadRecord(browser, profile, copy);
    if (download_failure_reported) { callback->Cancel(); return; }
    if (!download) { callback->Cancel(); return; }
    if (download->continued && !copy.path.empty()) {
      const bool exact = copy.path == download->destination;
      if (!exact || !PrivateDownloadFile(*download)) {
        download->snapshot = std::move(copy);
        ++download->handle.revision;
        download->revoked = true;
        download->callback = nullptr;
        DownloadFailure(exact ? "download-native-file-rejected" : "download-native-path-rejected", callback);
        return;
      }
      download->destination_ready = true;
    }
    download->snapshot = std::move(copy);
    ++download->handle.revision;
    const bool terminal = download->snapshot.status == AL_DOWNLOAD_COMPLETE
        || download->snapshot.status == AL_DOWNLOAD_CANCELED;
    if (!download->revoked && !quitting && !terminal) download->callback = callback;
    else download->callback = nullptr;
    if (terminal) download->revoked = true;
    DownloadEvent(AL_EVENT_DOWNLOAD, *download, "download-native-update");
  }

  void ControlDownload(ALChromiumDownloadHandle handle, uint64_t command, ALChromiumDownloadAction action) {
    CEF_REQUIRE_UI_THREAD();
    auto found = downloads.find({handle.profile_token, handle.native_id});
    if (!options.download_test || quitting || download_failure_reported || found == downloads.end()
        || found->second.handle.download_lifetime != handle.download_lifetime) {
      DownloadReject(handle, command, "download-owner-rejected", action); return;
    }
    auto& download = found->second;
    if (download.handle.revision != handle.revision || !command || command <= download.last_command) {
      DownloadReject(handle, command, "download-revision-rejected", action); return;
    }
    if (download.revoked || !download.callback
        || (action == AL_DOWNLOAD_PAUSE && (download.snapshot.status != AL_DOWNLOAD_PROGRESS
            || download.snapshot.paused || !download.continued))
        || (action == AL_DOWNLOAD_RESUME && !download.snapshot.paused
            && download.snapshot.status != AL_DOWNLOAD_INTERRUPTED)) {
      DownloadReject(handle, command, "download-control-unavailable", action); return;
    }
    auto callback = download.callback;
    download.last_command = command;
    ++download.handle.revision;
    const bool interrupted_cancel = action == AL_DOWNLOAD_CANCEL
        && download.snapshot.status == AL_DOWNLOAD_INTERRUPTED;
    if (action == AL_DOWNLOAD_CANCEL) {
      download.revoked = true;  // Revoke before calling native asynchronous code.
      download.callback = nullptr;
      callback->Cancel();
    } else if (action == AL_DOWNLOAD_PAUSE) callback->Pause();
    else callback->Resume();
    DownloadEvent(AL_EVENT_DOWNLOAD_COMMAND, download,
        interrupted_cancel ? "download-interrupted-control-revoked-native-cancel-unsupported"
                           : "download-native-command-posted", command, action);
  }

  void RevokeDownloads() {
    std::vector<CefRefPtr<CefDownloadItemCallback>> callbacks_to_cancel;
    download_admissions.clear();
    for (auto& [key, download] : downloads) {
      download.revoked = true;
      if (download.callback) callbacks_to_cancel.push_back(download.callback);
      download.callback = nullptr;
    }
    // Revoke the entire registry before any native cancellation can run.
    for (const auto& callback : callbacks_to_cancel) callback->Cancel();
  }

  void Emit(ALChromiumEventKind kind, int id = 0, const char* detail = "",
            int value = 0, const std::string* url = nullptr, const std::string* title = nullptr) {
    CEF_REQUIRE_UI_THREAD();
    const auto found = hosts.find(id);
    ALChromiumEvent event {sizeof(ALChromiumEvent), kind, id,
      found == hosts.end() ? 0 : found->second.profile,
      found == hosts.end() ? 0 : found->second.window, value, detail,
      url ? url->c_str() : nullptr, title ? title->c_str() : nullptr};
    if (found != hosts.end()) {
      event.host_lifetime = found->second.lifetime;
      event.document_generation = found->second.document;
    }
    callbacks.event(callback_context, &event);
  }

  ALChromiumEvent PageEvent(ALChromiumEventKind kind, int id, const char* detail,
                           uint64_t query, uint64_t operation) {
    ALChromiumEvent event {};
    event.struct_size = sizeof(event);
    event.kind = kind;
    event.browser_id = id;
    event.detail = detail;
    event.query_token = query;
    event.operation_token = operation;
    const auto found = hosts.find(id);
    if (found != hosts.end()) {
      event.profile_token = found->second.profile;
      event.window_token = found->second.window;
      event.host_lifetime = found->second.lifetime;
      event.document_generation = found->second.document;
    }
    return event;
  }

  void Reject(int id, uint64_t lifetime, uint64_t document, uint64_t query,
              uint64_t operation, const char* detail) {
    auto event = PageEvent(AL_EVENT_PAGE_TOOLS_REJECTED, id, detail, query, operation);
    // A stale request retains its original context; never rebind it to a new host/document.
    event.host_lifetime = lifetime;
    event.document_generation = document;
    event.profile_token = event.window_token = 0;
    callbacks.event(callback_context, &event);
  }

  Host* Target(int id, uint64_t lifetime, uint64_t document, uint64_t query, uint64_t operation) {
    CEF_REQUIRE_UI_THREAD();
    const auto found = hosts.find(id);
    if (found == hosts.end() || found->second.lifetime != lifetime
        || !document || found->second.document != document || quitting
        || found->second.navigation_pending || found->second.closing) {
      Reject(id, lifetime, document, query, operation, "stale-target-context");
      return nullptr;
    }
    if (!operation || operation <= found->second.last_operation) {
      Reject(id, lifetime, document, query, operation, "stale-operation-token");
      return nullptr;
    }
    found->second.last_operation = operation;
    return &found->second;
  }

  void InvalidateFind(Host& host) {
    // Invalidate before StopFinding: Stop is not required to produce a final reply.
    host.finding = false;
    host.find_pending = false;
    host.find_operation = 0;
    host.pending_find_id = -1;
    host.find_text.clear();
    host.browser->GetHost()->StopFinding(true);
  }

  void Document(CefRefPtr<CefBrowser> browser) {
    CEF_REQUIRE_UI_THREAD();
    const int id = browser->GetIdentifier();
    auto found = hosts.find(id);
    if (found == hosts.end() || !found->second.browser->IsSame(browser)) return;
    auto& host = found->second;
    ++host.document;
    host.navigation_pending = false;
    InvalidateFind(host);
    Emit(AL_EVENT_DOCUMENT, id, "main-document-committed");
  }

  void Find(int id, uint64_t lifetime, uint64_t document, uint64_t query, uint64_t operation,
            const std::string& text, bool forward, bool match_case, bool next) {
    auto* host = Target(id, lifetime, document, query, operation);
    if (!host) return;
    if (!query || query < host->query || (query == host->query
        && (!host->finding || host->find_text != text || host->match_case != match_case))) {
      Reject(id, lifetime, document, query, operation, "stale-query-token");
      return;
    }
    if (query == host->query && (host->find_pending || !next)) {
      Reject(id, lifetime, document, query, operation, "find-continuation-not-ready");
      return;
    }
    if (query > host->query) {
      InvalidateFind(*host);
      host->query = query;
      host->find_text = text;
      host->match_case = match_case;
    }
    // Bind the context before issuing on UI. IDs are learned only from replies;
    // never inferred from a call counter. Completed IDs cannot finish a later op.
    host->finding = true;
    host->find_pending = true;
    host->find_document = document;
    host->find_operation = operation;
    host->previous_find_id = host->observed_find_id;
    host->pending_find_id = -1;
    host->browser->GetHost()->Find(text, forward, match_case, next);
  }

  void FindResult(CefRefPtr<CefBrowser> browser, int identifier, int count,
                  int ordinal, bool final_update) {
    CEF_REQUIRE_UI_THREAD();
    const int id = browser->GetIdentifier();
    auto found = hosts.find(id);
    if (found == hosts.end() || !found->second.browser->IsSame(browser)) return;
    auto& host = found->second;
    if (!host.finding || !host.find_operation || host.navigation_pending
        || host.find_document != host.document || identifier <= host.previous_find_id
        || (host.pending_find_id >= 0 && identifier != host.pending_find_id)) return;
    host.pending_find_id = identifier;
    host.observed_find_id = std::max(host.observed_find_id, identifier);
    auto event = PageEvent(AL_EVENT_FIND_RESULT, id, "native-find-result", host.query, host.find_operation);
    event.native_find_id = identifier;
    event.match_count = count;
    event.active_ordinal = ordinal;  // Zero is valid when matches exist.
    event.final_update = final_update;
    if (final_update) host.find_pending = false;
    callbacks.event(callback_context, &event);
  }

  void StopFind(int id, uint64_t lifetime, uint64_t document, uint64_t query,
                uint64_t operation, bool clear) {
    auto* host = Target(id, lifetime, document, query, operation);
    if (!host) return;
    if (!query || query <= host->query) {
      Reject(id, lifetime, document, query, operation, "stale-query-token");
      return;
    }
    host->finding = false;
    host->find_pending = false;
    host->find_operation = 0;
    host->find_text.clear();
    host->query = query;
    host->browser->GetHost()->StopFinding(clear);
    auto event = PageEvent(AL_EVENT_FIND_STOPPED, id, "native-find-stopped", query, operation);
    callbacks.event(callback_context, &event);
  }

  void Zoom(int id, uint64_t lifetime, uint64_t document, uint64_t operation,
            ALChromiumZoomCommand command) {
    auto* target = Target(id, lifetime, document, 0, operation);
    if (!target) return;
    auto host = target->browser->GetHost();
    cef_zoom_command_t native = CEF_ZOOM_COMMAND_RESET;
    if (command == AL_ZOOM_IN) native = CEF_ZOOM_COMMAND_IN;
    else if (command == AL_ZOOM_OUT) native = CEF_ZOOM_COMMAND_OUT;
    if (command != AL_ZOOM_READ && !host->CanZoom(native)) {
      Reject(id, lifetime, document, 0, operation, "native-zoom-unavailable");
      return;
    }
    if (command != AL_ZOOM_READ) host->Zoom(native);
    auto event = PageEvent(AL_EVENT_ZOOM, id, "native-zoom-readback", 0, operation);
    event.zoom_level = host->GetZoomLevel();
    event.default_zoom_level = host->GetDefaultZoomLevel();
    event.can_zoom_in = host->CanZoom(CEF_ZOOM_COMMAND_IN);
    event.can_zoom_out = host->CanZoom(CEF_ZOOM_COMMAND_OUT);
    event.can_zoom_reset = host->CanZoom(CEF_ZOOM_COMMAND_RESET);
    callbacks.event(callback_context, &event);
  }

  void AuditHidden(bool views_violation = false, const char* detail = "hidden-window-audit") {
    // AppKit observers remain installed through CefShutdown, after CEF thread
    // IDs cease to exist. This audit and its POD callbacks need only main thread.
    if (!NSThread.isMainThread) return;
    if (!options.Hidden()) return;
    int flags = (NoVisibleWindows() ? 0 : 1) | (NSApp.active ? 2 : 0)
        | (NSApp.keyWindow ? 4 : 0) | (NSApp.mainWindow ? 8 : 0) | (views_violation ? 16 : 0);
    for (NSWindow* window in NSApp.windows) if (window.keyWindow || window.mainWindow) flags |= 32;
    if (flags && !hidden_violation) {
      hidden_violation = failed = true;
      auto failure = PageEvent(AL_EVENT_FAILURE, 0, "hidden-window-activation-violation", 0, 0);
      failure.value = flags;
      callbacks.event(callback_context, &failure);
      if (initialized && !shutting_down && !finished) Post([this] { Quit(); });
    }
    auto event = PageEvent(AL_EVENT_HIDDEN_AUDIT, 0, detail, 0, 0);
    event.value = flags;
    callbacks.event(callback_context, &event);
  }

  void PollHidden() {
    if (finished) return;
    AuditHidden();
    Post([this] { PollHidden(); }, 100);
  }

  void CreateHidden(CefRefPtr<CefRequestContext> context, const char* fixture_case) {
    CEF_REQUIRE_UI_THREAD();
    if (quitting) return;
    ++pending_windows;
    CefBrowserSettings settings;
    auto view = CefBrowserView::CreateBrowserView(ContextClient(this, context),
        options.origin + "/page?case=" + fixture_case, settings, nullptr, context, new HiddenViewDelegate());
    if (!view) {
      --pending_windows;
      failed = true;
      Emit(AL_EVENT_FAILURE, 0, "hidden-view-creation-rejected");
      Quit();
      return;
    }
    ++hidden_windows;
    auto window = CefWindow::CreateTopLevelWindow(new HiddenWindowDelegate(view,
        [this](bool violation) { AuditHidden(violation); }, [this] {
          --hidden_windows;
          AuditHidden();
          if (quitting) Post([this] { FinishClose(0); }, 100);
        }));
    if (!window) {
      --hidden_windows;
      failed = true;
      Emit(AL_EVENT_FAILURE, 0, "hidden-window-creation-rejected");
      Quit();
    }
  }

  uint64_t Profile(CefRefPtr<CefRequestContext> context) {
    for (size_t i = 0; i < profiles.size(); ++i)
      if (context->IsSame(profiles[i])) return i + 1;
    profiles.push_back(context);
    return profiles.size();
  }

  CefRefPtr<CefBrowser> Browser(int id) {
    const auto found = hosts.find(id);
    return found == hosts.end() ? nullptr : found->second.browser;
  }

  void Create(CefRefPtr<CefRequestContext> context) {
    CEF_REQUIRE_UI_THREAD();
    if (quitting || pending_windows) return;
    CefWindowInfo window;
    window.runtime_style = CEF_RUNTIME_STYLE_CHROME;
    // No parent_view, BrowserView, OSR or custom content NSWindow.
    window.bounds = CefRect(100, 100, 1100, 760);
    CefBrowserSettings settings;
    ++pending_windows;
    if (!CefBrowserHost::CreateBrowser(window, client,
        options.origin + "/page?case=swift-chromium-a", settings, nullptr, context)) {
      --pending_windows;
      failed = true;
      Emit(AL_EVENT_FAILURE, 0, "window-creation-rejected");
      Quit();
    }
  }

  void Created(CefRefPtr<CefBrowser> browser) {
    CEF_REQUIRE_UI_THREAD();
    const int id = browser->GetIdentifier();
    ++creation_generation;
    hosts.emplace(id, Host {browser, Profile(browser->GetHost()->GetRequestContext()), 0, next_lifetime++});
    if (options.Hidden()) {
      ++hidden_created;
    }
    if (pending_windows) --pending_windows;
    if (!initial_id) initial_id = id;
    Emit(AL_EVENT_CREATED, id, "host-created");
    if (expected_source) {
      if (expected_candidate) candidate_ambiguous = true;
      else expected_candidate = id;
    }
    Post([this, id] { Associate(id, 0); });
    if (quitting) Post([this, id] { if (auto item = Browser(id)) item->GetHost()->CloseBrowser(false); });
  }

  void Associate(int id, int attempt) {
    CEF_REQUIRE_UI_THREAD();
    auto browser = Browser(id);
    if (!browser) return;
    NSWindow* window = CurrentNativeWindow(browser);
    if (!window) {
      if (attempt < 40) Post([this, id, attempt] { Associate(id, attempt + 1); }, 50);
      else {
        Emit(AL_EVENT_WINDOW, id, "native-window-unassociated");
        if (options.Hidden()) {
          failed = true;
          Emit(AL_EVENT_FAILURE, id, "hidden-window-unassociated");
          Quit();
        }
      }
      return;
    }
    auto found = std::find_if(windows.begin(), windows.end(),
        [window](const Window& item) { return item.object == window; });
    if (found == windows.end()) {
      windows.push_back(Window {next_window++, window, false});
      found = windows.end() - 1;
    }
    hosts.at(id).window = found->token;
    Emit(AL_EVENT_WINDOW, id, "native-window-associated", window.visible ? 1 : 0);
  }

  void Closed(CefRefPtr<CefBrowser> browser) {
    CEF_REQUIRE_UI_THREAD();
    const int id = browser->GetIdentifier();
    if (options.Hidden()) {
      // Each hidden host owns one Views window. Retire that exact window after
      // this browser callback unwinds, even if Chrome leaves an empty container.
      auto view = CefBrowserView::GetForBrowser(browser);
      CefRefPtr<CefWindow> window = view ? view->GetWindow() : nullptr;
      if (window) Post([window] { if (!window->IsClosed()) window->Close(); });
    }
    auto found = hosts.find(id);
    if (found != hosts.end()) {
      // The native session has ended; do not call StopFinding on a closing host.
      found->second.finding = found->second.find_pending = false;
      found->second.find_text.clear();
    }
    Emit(AL_EVENT_CLOSED, id, "host-before-close");
    hosts.erase(id);  // Never infer that the containing native window closed.
    if (hosts.empty() && !pending_windows) {
      quitting = true;
      RevokeDownloads();
      Post([this] { FinishClose(0); }, 100);
    }
  }

  void WindowClosing(NSWindow* object) {
    for (auto& window : windows) if (window.object == object) window.closing = true;
  }

  void FinishClose(int attempt) {
    CEF_REQUIRE_UI_THREAD();
    if (finished || !hosts.empty() || pending_windows) return;
    if (options.Hidden()) AuditHidden();
    const bool tracked_closed = std::all_of(windows.begin(), windows.end(), [](const Window& item) {
      NSWindow* window = item.object;
      return !window || (item.closing && !window.visible && ![NSApp.windows containsObject:window]);
    });
    // This process owns no controller window. Check also a creation/association
    // race; never close or force another application's windows or processes.
    // AppKit can retain an invisible utility window after every tracked Chrome
    // NSWindow has deallocated. It must not keep the CEF loop alive indefinitely.
    if (!tracked_closed || !NoVisibleWindows() || hidden_windows) {
      if (attempt < 50) Post([this, attempt] { FinishClose(attempt + 1); }, 100);
      else {
        failed = true;
        for (const auto& item : windows) {
          NSWindow* window = item.object;
          const int flags = (window ? 1 : 0) | (item.closing ? 2 : 0)
            | (window.visible ? 4 : 0) | (window && [NSApp.windows containsObject:window] ? 8 : 0);
          Emit(AL_EVENT_COMMAND, 0, "tracked-window-close-state", flags);
        }
        int visible = 0;
        for (NSWindow* window in NSApp.windows) if (window.visible) ++visible;
        Emit(AL_EVENT_COMMAND, 0, "remaining-app-window-count", static_cast<int>(NSApp.windows.count));
        Emit(AL_EVENT_COMMAND, 0, "remaining-visible-window-count", visible);
        Emit(AL_EVENT_WATCHDOG_REQUIRED, 0, "native-window-teardown-incomplete");
      }
      return;
    }
    finished = true;
    int retained = 0;
    for (const auto& window : windows) if (window.object) ++retained;
    Emit(AL_EVENT_COMMAND, 0, "tracked-native-window-retained-count", retained);
    Emit(AL_EVENT_COMMAND, 0, "owned-hosts-and-windows-retired");
    CefQuitMessageLoop();
  }

  void Quit() {
    CEF_REQUIRE_UI_THREAD();
    if (finished || (options.download_test && quitting)) return;
    quitting = true;
    RevokeDownloads();
    expected_source = 0;
    Emit(AL_EVENT_QUIT_REQUESTED, 0, "orderly-close-requested");
    std::vector<CefRefPtr<CefBrowser>> living;
    for (auto& [id, host] : hosts) {
      InvalidateFind(host);
      living.push_back(host.browser);
    }
    for (const auto& browser : living) browser->GetHost()->CloseBrowser(false);
    if (hosts.empty() && !pending_windows) Post([this] { FinishClose(0); }, 100);
    Post([this] {
      if (!finished && (!hosts.empty() || pending_windows)) {
        failed = true;
        Emit(AL_EVENT_WATCHDOG_REQUIRED, 0, "close-cancelled-or-stalled-keepalive");
        // A real beforeunload cancellation keeps the loop alive. Root's external
        // watchdog must classify this as failure and clean up this owned run.
      }
    }, 5000);
  }

  void ControlledCandidate(uint64_t generation) {
    CEF_REQUIRE_UI_THREAD();
    if (quitting || !expected_source || generation != expected_generation) return;
    auto source = Browser(expected_source);
    auto candidate = Browser(expected_candidate);
    NSWindow* source_window = CurrentNativeWindow(source);
    NSWindow* candidate_window = CurrentNativeWindow(candidate);
    const auto tracked_window = std::find_if(windows.begin(), windows.end(),
        [this, source_window](const Window& window) {
          return window.token == expected_window && window.object == source_window;
        });
    bool matches = source && candidate && !candidate_ambiguous && hosts.size() == 2
        && creation_generation == generation + 1
        && hosts.at(expected_source).window == expected_window
        && hosts.at(expected_candidate).window == expected_window && expected_window != 0
        && source_window && source_window == candidate_window
        && tracked_window != windows.end() && !tracked_window->closing
        && [NSApp.windows containsObject:source_window]
        && source->GetHost()->GetRequestContext()->IsSame(candidate->GetHost()->GetRequestContext());
    const std::string url = candidate && candidate->GetMainFrame()
        ? candidate->GetMainFrame()->GetURL().ToString() : "";
    matches = matches && (url == "chrome://newtab/" || url == "chrome://new-tab-page/");
    expected_source = 0;
    // Do not call Swift between the current-window check and the navigation.
    if (matches) candidate->GetMainFrame()->LoadURL(options.origin + "/page?case=swift-chromium-b");
    Emit(AL_EVENT_COMMAND, expected_candidate,
        matches ? "controlled-candidate-routed" : "controlled-candidate-unproven");
  }

  void Execute(Operation operation, int id) {
    CEF_REQUIRE_UI_THREAD();
    if (operation == Operation::Quit) { Quit(); return; }
    if (options.Hidden() && operation != Operation::Close) {
      Emit(AL_EVENT_COMMAND, id, "visible-command-denied-in-hidden-mode");
      return;
    }
    auto browser = Browser(id);
    if (!browser || quitting || pending_windows || expected_source) {
      Emit(AL_EVENT_COMMAND, id, "command-rejected");
      return;
    }
    auto host = browser->GetHost();
    if (operation == Operation::Window) {
      Create(host->GetRequestContext());
      return;
    }
    if (operation == Operation::Close) {
      InvalidateFind(hosts.at(id));
      host->CloseBrowser(false);
      Emit(AL_EVENT_COMMAND, id, "target-close-issued");
      return;
    }
    if (operation == Operation::Select) {
      host->SetFocus(true);
      Emit(AL_EVENT_COMMAND, id, "target-focus-issued-selection-unproven");
      return;
    }
    const bool split = operation == Operation::Split;
    if (split && split_issued) {
      Emit(AL_EVENT_COMMAND, id, "additional-split-outside-gate");
      return;
    }
    if (split) {
      host->SetFocus(true);
      // Select and issue Split in separate queued tasks, after the focus stack
      // unwinds. SDK focus semantics remain subject to independent validation.
      Post([this, id] { IssueCreation(id, true); });
    } else IssueCreation(id, false);
  }

  void IssueCreation(int id, bool split) {
    CEF_REQUIRE_UI_THREAD();
    auto browser = Browser(id);
    if (!browser || quitting || expected_source || pending_windows || (split && split_issued)) return;
    const int command = cef_id_for_command_id_name(split ? "IDC_NEW_SPLIT_TAB" : "IDC_NEW_TAB");
    auto host = browser->GetHost();
    // Another queued action may have changed focus since Execute's first
    // selection. Reassert the target in the command task itself.
    if (split) host->SetFocus(true);
    if (command <= 0 || !host->CanExecuteChromeCommand(command)) {
      Emit(AL_EVENT_COMMAND, id, "chrome-command-unavailable");
      return;
    }
    if (options.controlled_creation && !controlled_used && hosts.size() == 1
        && id == initial_id && hosts.at(id).window != 0) {
      // Explicit synthetic first-request assumption only. Public CEF supplies
      // no request correlation; root must exclude concurrent user creations.
      controlled_used = true;
      expected_source = id;
      expected_window = hosts.at(id).window;
      expected_candidate = 0;
      candidate_ambiguous = false;
      expected_generation = creation_generation;
      Post([this, generation = expected_generation] { ControlledCandidate(generation); }, 1000);
    }
    if (split) split_issued = true;
    issuing_creation = true;
    host->ExecuteChromeCommand(command, CEF_WOD_CURRENT_TAB);
    issuing_creation = false;
    Emit(AL_EVENT_COMMAND, id, split ? "two-page-split-issued" : "new-tab-issued");
  }
};

// Immutable origin policy is safe on CEF's IO thread. It never calls Swift.
class ContextPolicy final : public CefRequestContextHandler,
                            public CefResourceRequestHandler {
 public:
  explicit ContextPolicy(State* state) : state_(state), origin_(state->options.origin),
      download_test_(state->options.download_test) {}
  void OnRequestContextInitialized(CefRefPtr<CefRequestContext> context) override {
    CEF_REQUIRE_UI_THREAD();
    state_->Profile(context);
    if (!state_->ConfigureDownloadStorage(context)) {
      state_->DownloadFailure("download-storage-policy-rejected");
      return;
    }
    if (state_->options.Hidden()) {
      const bool primary = state_->primary && context->IsSame(state_->primary);
      if (primary && !state_->hidden_primary_started) {
        state_->hidden_primary_started = true;
        Post([state = state_, context] {
          state->CreateHidden(context, state->options.download_test ? "download-a" : "page-tools-a");
          state->CreateHidden(context, state->options.download_test ? "download-a2" : "page-tools-a2");
        });
      } else if (!primary && !state_->hidden_secondary_started) {
        state_->hidden_secondary_started = true;
        Post([state = state_, context] {
          state->CreateHidden(context, state->options.download_test ? "download-b" : "page-tools-b");
        });
      }
    } else if (state_->primary && context->IsSame(state_->primary)) {
      Post([state = state_, context] { if (!state->quitting) state->Create(context); });
    }
  }
  CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(
      CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, CefRefPtr<CefRequest> request,
      bool, bool download, const CefString&, bool& disable_default_handling) override {
    if ((download && !(download_test_ && DownloadURL(request->GetURL(), origin_)))
        || !AllowedURL(request->GetURL(), origin_, true)) disable_default_handling = true;
    return this;
  }
  ReturnValue OnBeforeResourceLoad(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>,
      CefRefPtr<CefRequest> request, CefRefPtr<CefCallback>) override {
    return AllowedURL(request->GetURL(), origin_, true) ? RV_CONTINUE : RV_CANCEL;
  }
  void OnResourceRedirect(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, CefRefPtr<CefRequest>,
      CefRefPtr<CefResponse>, CefString& url) override {
    if (!AllowedURL(url, origin_, true)) url = "about:blank";
  }
  void OnProtocolExecution(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, CefRefPtr<CefRequest>,
      bool& allow_os_execution) override { allow_os_execution = false; }
 private:
  State* const state_;
  const std::string origin_;
  const bool download_test_;
  IMPLEMENT_REFCOUNTING(ContextPolicy);
};

bool AllowedCommand(int command) {
  for (const char* name : {"IDC_NEW_TAB", "IDC_NEW_SPLIT_TAB", "IDC_CLOSE_TAB", "IDC_CLOSE_WINDOW",
      "IDC_EXIT", "IDC_BACK", "IDC_FORWARD", "IDC_RELOAD", "IDC_RELOAD_BYPASSING_CACHE", "IDC_STOP",
      "IDC_SELECT_NEXT_TAB", "IDC_SELECT_PREVIOUS_TAB", "IDC_FOCUS_LOCATION",
      "IDC_SELECT_TAB_0", "IDC_SELECT_TAB_1", "IDC_SELECT_TAB_2", "IDC_SELECT_TAB_3",
      "IDC_SELECT_TAB_4", "IDC_SELECT_TAB_5", "IDC_SELECT_TAB_6", "IDC_SELECT_TAB_7", "IDC_SELECT_LAST_TAB"})
    if (command > 0 && command == cef_id_for_command_id_name(name)) return true;
  return false;
}

class Client final : public CefClient, public CefLifeSpanHandler, public CefDisplayHandler,
                     public CefLoadHandler, public CefFocusHandler, public CefRequestHandler,
                     public CefCommandHandler, public CefDialogHandler, public CefDownloadHandler,
                     public CefJSDialogHandler, public CefFindHandler {
 public:
  explicit Client(State* state, CefRefPtr<CefRequestContext> context = nullptr)
      : state_(state), download_profile_(context ? state->Profile(context) : 0) {}
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefFocusHandler> GetFocusHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefCommandHandler> GetCommandHandler() override { return this; }
  CefRefPtr<CefDialogHandler> GetDialogHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
  CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }
  CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }
  void OnFindResult(CefRefPtr<CefBrowser> browser, int identifier, int count,
      const CefRect&, int ordinal, bool final_update) override {
    state_->FindResult(browser, identifier, count, ordinal, final_update);
  }
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override { state_->Created(browser); }
  bool DoClose(CefRefPtr<CefBrowser> browser) override {
    auto found = state_->hosts.find(browser->GetIdentifier());
    if (found != state_->hosts.end()) {
      found->second.closing = true;
      state_->InvalidateFind(found->second);
    }
    return false;
  }
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override { state_->Closed(browser); }
  void OnAddressChange(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
      const CefString& value) override {
    if (!frame->IsMain()) return;
    const std::string url = value;
    state_->Emit(AL_EVENT_ADDRESS, browser->GetIdentifier(), "main-address-changed", 0, &url);
  }
  void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& value) override {
    const std::string title = value;
    state_->Emit(AL_EVENT_TITLE, browser->GetIdentifier(), "title-changed", 0, nullptr, &title);
  }
  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool loading, bool, bool) override {
    auto found = state_->hosts.find(browser->GetIdentifier());
    if (found != state_->hosts.end()) {
      found->second.navigation_pending = loading;
      if (loading) state_->InvalidateFind(found->second);
    }
    state_->Emit(AL_EVENT_LOADING, browser->GetIdentifier(), "loading-changed", loading);
  }
  void OnLoadStart(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, TransitionType) override {
    // Pinned cef_load_handler.h: committed navigation, excludes same-document changes.
    if (frame->IsMain()) state_->Document(browser);
  }
  void OnLoadEnd(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int status) override {
    if (frame->IsMain()) {
      if (state_->options.Hidden()) {
        auto found = state_->hosts.find(browser->GetIdentifier());
        if (found != state_->hosts.end()) found->second.fixture_url = frame->GetURL();
      }
      state_->Emit(AL_EVENT_LOADING, browser->GetIdentifier(), "main-load-ended", status);
    }
  }
  void OnLoadError(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
      ErrorCode code, const CefString&, const CefString&) override {
    if (frame->IsMain()) state_->Emit(AL_EVENT_LOADING, browser->GetIdentifier(), "main-load-error", code);
  }
  void OnGotFocus(CefRefPtr<CefBrowser> browser) override {
    state_->Emit(AL_EVENT_FOCUS, browser->GetIdentifier(), "focus-observed");
  }
  bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
      CefRefPtr<CefRequest> request, bool, bool) override {
    if (!AllowedURL(request->GetURL(), state_->options.origin)) return true;
    if (frame->IsMain()) {
      auto found = state_->hosts.find(browser->GetIdentifier());
      if (found != state_->hosts.end()) state_->InvalidateFind(found->second);
    }
    return false;
  }
  bool OnOpenURLFromTab(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, const CefString& url,
      WindowOpenDisposition disposition, bool) override {
    if (state_->pending_windows && disposition != CEF_WOD_CURRENT_TAB) return true;
    if (state_->expected_source && !state_->issuing_creation && disposition != CEF_WOD_CURRENT_TAB)
      state_->candidate_ambiguous = true;
    return !AllowedURL(url, state_->options.origin);
  }
  bool OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int, const CefString& url,
      const CefString&, WindowOpenDisposition, bool, const CefPopupFeatures&, CefWindowInfo& info,
      CefRefPtr<CefClient>& client, CefBrowserSettings&, CefRefPtr<CefDictionaryValue>&, bool*) override {
    if (state_->options.Hidden()) return true;
    state_->candidate_ambiguous = true;
    if (state_->quitting || state_->pending_windows || !AllowedURL(url, state_->options.origin)) return true;
    info.runtime_style = CEF_RUNTIME_STYLE_CHROME;
    client = this;
    return false;
  }
  bool OnChromeCommand(CefRefPtr<CefBrowser>, int command, cef_window_open_disposition_t) override {
    if (state_->options.Hidden()) return true;
    if (command == cef_id_for_command_id_name("IDC_EXIT")) {
      ALChromiumRequestQuit();
      return true;
    }
    if (state_->expected_source && !state_->issuing_creation
        && (command == cef_id_for_command_id_name("IDC_NEW_TAB")
            || command == cef_id_for_command_id_name("IDC_NEW_SPLIT_TAB"))) {
      state_->candidate_ambiguous = true;
      return true;
    }
    if (state_->pending_windows && (command == cef_id_for_command_id_name("IDC_NEW_TAB")
        || command == cef_id_for_command_id_name("IDC_NEW_SPLIT_TAB"))) return true;
    return !AllowedCommand(command) || (state_->quitting
        && (command == cef_id_for_command_id_name("IDC_NEW_TAB")
            || command == cef_id_for_command_id_name("IDC_NEW_SPLIT_TAB")));
  }
  bool IsChromeAppMenuItemEnabled(CefRefPtr<CefBrowser>, int command) override {
    return !state_->options.Hidden() && AllowedCommand(command);
  }
  bool OnConsoleMessage(CefRefPtr<CefBrowser>, cef_log_severity_t, const CefString&,
      const CefString&, int) override { return true; }
  bool OnFileDialog(CefRefPtr<CefBrowser>, FileDialogMode, const CefString&, const CefString&,
      const std::vector<CefString>&, const std::vector<CefString>&, const std::vector<CefString>&,
      CefRefPtr<CefFileDialogCallback> callback) override {
    callback->Cancel();
    return true;
  }
  bool CanDownload(CefRefPtr<CefBrowser> browser, const CefString& url,
      const CefString& method) override {
    return method == "GET" && state_->AdmitDownload(browser, download_profile_, url);
  }
  bool OnBeforeDownload(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDownloadItem> item,
      const CefString& suggested, CefRefPtr<CefBeforeDownloadCallback> callback) override {
    if (!item || !item->IsValid()) return true;
    return state_->BeforeDownload(browser, download_profile_, CopyDownload(item), suggested, callback);
  }
  void OnDownloadUpdated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDownloadItem> item,
      CefRefPtr<CefDownloadItemCallback> callback) override {
    if (!item || !item->IsValid()) { callback->Cancel(); return; }
    state_->UpdatedDownload(browser, download_profile_, CopyDownload(item), callback);
  }
  bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser> browser, const CefString&, bool,
      CefRefPtr<CefJSDialogCallback> callback) override {
    if (state_->options.Hidden()) {
      callback->Continue(true, CefString());
      return true;
    }
    state_->Emit(AL_EVENT_COMMAND, browser->GetIdentifier(), "native-beforeunload-dialog");
    return false;  // Preserve the real native confirm/cancel path.
  }
 private:
  State* const state_;
  const uint64_t download_profile_;
  IMPLEMENT_REFCOUNTING(Client);
};

CefRefPtr<CefClient> ContextClient(State* state, CefRefPtr<CefRequestContext> context) {
  return new Client(state, context);
}

class App final : public CefApp, public CefBrowserProcessHandler {
 public:
  explicit App(State* state) : state_(state) {}
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }
  CefRefPtr<CefClient> GetDefaultClient() override { return state_->client; }
  CefRefPtr<CefRequestContextHandler> GetDefaultRequestContextHandler() override { return state_->policy; }
  void OnBeforeCommandLineProcessing(const CefString&, CefRefPtr<CefCommandLine> command) override {
    for (const char* name : {"use-mock-keychain", "disable-background-networking",
        "disable-component-update", "no-first-run", "no-default-browser-check", "disable-sync",
        "disable-breakpad", "disable-logging", "force-renderer-accessibility"}) command->AppendSwitch(name);
    command->AppendSwitchWithValue("password-store", "basic");
    // The on-device model manifest component is installed on demand despite
    // disable-component-update and fetched into TMPDIR (r5b left
    // <bundle>.chromium_chrome_url_fetcher_.* in download-temp). Pinned
    // chrome/browser/optimization_guide/model_execution/
    // optimization_guide_global_state.cc:51-59 selects the override delegate
    // for this switch; /dev/null parses as no manifest and RequestUpdate is a
    // no-op, so no component fetch or temporary directory is requested.
    if (state_->options.download_test)
      command->AppendSwitchWithValue("optimization-guide-manifest-override", "/dev/null");
  }
  void OnContextInitialized() override {
    CEF_REQUIRE_UI_THREAD();
    if (state_->options.Hidden() && state_->failed) {
      if (state_->initialized) Post([state = state_] { state->Quit(); });
      return;
    }
    state_->Emit(AL_EVENT_READY, 0, "context-ready");
    CefRequestContextSettings settings;
    CefString(&settings.cache_path) = state_->options.root + "/cache/profile-a";
    state_->primary = CefRequestContext::CreateContext(settings, state_->policy);
    if (!state_->primary) {
      state_->failed = true;
      state_->Emit(AL_EVENT_FAILURE, 0, "profile-creation-rejected");
      Post([state = state_] { state->Quit(); });
    }
    if (state_->options.Hidden() && state_->primary) {
      CefString(&settings.cache_path) = state_->options.root + "/cache/profile-b";
      auto secondary = CefRequestContext::CreateContext(settings, state_->policy);
      if (secondary) state_->Profile(secondary);
      else {
        state_->failed = true;
        state_->Emit(AL_EVENT_FAILURE, 0, "secondary-profile-creation-rejected");
        Post([state = state_] { state->Quit(); });
      }
      Post([state = state_] { state->PollHidden(); });
    }
  }
 private:
  State* const state_;
  IMPLEMENT_REFCOUNTING(App);
};

int Queue(Operation operation, int id) {
  if (!NSThread.isMainThread || !active_state || !active_state->initialized) return 0;
  State* state = active_state;
  return Post([state, operation, id] { if (!state->finished) state->Execute(operation, id); }) ? 1 : 0;
}
}  // namespace

extern "C" int32_t ALChromiumCreateWindow(int32_t id) { return Queue(Operation::Window, id); }
extern "C" int32_t ALChromiumNewTab(int32_t id) { return Queue(Operation::Tab, id); }
extern "C" int32_t ALChromiumSelect(int32_t id) { return Queue(Operation::Select, id); }
extern "C" int32_t ALChromiumClose(int32_t id) { return Queue(Operation::Close, id); }
extern "C" int32_t ALChromiumSplit(int32_t id) { return Queue(Operation::Split, id); }
extern "C" int32_t ALChromiumRequestQuit() { return Queue(Operation::Quit, 0); }

extern "C" int32_t ALChromiumFind(int32_t id, uint64_t lifetime, uint64_t document,
    uint64_t query, uint64_t operation, const char* text, int32_t forward,
    int32_t match_case, int32_t next) {
  if (!NSThread.isMainThread || !active_state || !active_state->initialized || !text
      || (forward != 0 && forward != 1) || (match_case != 0 && match_case != 1)
      || (next != 0 && next != 1)) return 0;
  const size_t size = strnlen(text, 4097);
  if (size > 4096) return 0;
  if (!size) return ALChromiumStopFinding(id, lifetime, document, query, operation, 1);
  const std::string copy(text, size);
  // Chromium removes CR before comparing queries; reject ambiguous input here.
  if (![[NSString alloc] initWithBytes:text length:size encoding:NSUTF8StringEncoding]
      || copy.find('\r') != std::string::npos) return 0;
  State* state = active_state;
  return Post([state, id, lifetime, document, query, operation, copy, forward, match_case, next] {
    if (!state->finished) state->Find(id, lifetime, document, query, operation, copy, forward, match_case, next);
  });
}

extern "C" int32_t ALChromiumStopFinding(int32_t id, uint64_t lifetime, uint64_t document,
    uint64_t query, uint64_t operation, int32_t clear) {
  if (!NSThread.isMainThread || !active_state || !active_state->initialized || (clear != 0 && clear != 1)) return 0;
  State* state = active_state;
  return Post([state, id, lifetime, document, query, operation, clear] {
    if (!state->finished) state->StopFind(id, lifetime, document, query, operation, clear);
  });
}

extern "C" int32_t ALChromiumZoom(int32_t id, uint64_t lifetime, uint64_t document,
    uint64_t operation, ALChromiumZoomCommand command) {
  if (!NSThread.isMainThread || !active_state || !active_state->initialized
      || command < AL_ZOOM_READ || command > AL_ZOOM_RESET) return 0;
  State* state = active_state;
  return Post([state, id, lifetime, document, operation, command] {
    if (!state->finished) state->Zoom(id, lifetime, document, operation, command);
  });
}

extern "C" int32_t ALChromiumPageToolsReload(int32_t id, uint64_t lifetime,
    uint64_t document, uint64_t operation) {
  if (!NSThread.isMainThread || !active_state || !active_state->initialized) return 0;
  State* state = active_state;
  return Post([state, id, lifetime, document, operation] {
    if (state->finished) return;
    auto* host = state->Target(id, lifetime, document, 0, operation);
    if (!host) return;
    if (!state->options.page_tools_test || host->fixture_url.empty()
        || !host->fixture_url.starts_with(state->options.origin + "/page?case=page-tools-")) {
      state->Reject(id, lifetime, document, 0, operation, "test-navigation-unavailable");
      return;
    }
    state->InvalidateFind(*host);
    host->navigation_pending = true;
    host->browser->GetMainFrame()->LoadURL(host->fixture_url);
    auto event = state->PageEvent(AL_EVENT_COMMAND, id, "page-tools-navigation-issued", 0, operation);
    state->callbacks.event(state->callback_context, &event);
  });
}

extern "C" int32_t ALChromiumStartDownload(int32_t id, uint64_t lifetime,
    uint64_t profile, uint64_t command, ALChromiumDownloadCase fixture_case) {
  if (!NSThread.isMainThread || !active_state || !DownloadCaseName(fixture_case)) return 0;
  auto* state = active_state;
  return Post([state, id, lifetime, profile, command, fixture_case] {
    if (!state->finished) state->StartDownload(id, lifetime, profile, command, fixture_case);
  });
}

extern "C" int32_t ALChromiumDownloadCommand(ALChromiumDownloadHandle handle,
    uint64_t command, ALChromiumDownloadAction action) {
  if (!NSThread.isMainThread || !active_state || action < AL_DOWNLOAD_CANCEL
      || action > AL_DOWNLOAD_RESUME) return 0;
  auto* state = active_state;
  return Post([state, handle, command, action] {
    if (!state->finished) state->ControlDownload(handle, command, action);
  });
}

extern "C" int32_t ALChromiumRun(int argc, char* argv[],
    const ALChromiumCallbacks* callbacks, void* context) {
  if (!NSThread.isMainThread || active_state || !callbacks || !context
      || callbacks->abi_version != AL_CHROMIUM_ABI_VERSION
      || callbacks->struct_size != sizeof(ALChromiumCallbacks) || !callbacks->event) return 64;
  // Keep framework code loaded until the inner Objective-C autorelease pool drains.
  CefScopedLibraryLoader loader;
  @autoreleasepool {
    Options options;
    if (!ParseOptions(argc, argv, options)) {
      fputs("chromium-shell preflight=rejected\n", stderr);
      return 64;
    }
    DownloadEnvironment download_environment;
    if (!download_environment.Prepare(options)) {
      fputs("chromium-shell preflight=download-storage-rejected\n", stderr);
      return 64;
    }
    const auto deadline = Clock::now() + std::chrono::seconds(options.seconds);
    if (!loader.LoadInMain()) return 69;
    State state {options, *callbacks, context, deadline};
    State* pointer = &state;
    if (options.download_test) {
      ALChromiumEvent event {};
      event.struct_size = sizeof(event);
      event.kind = AL_EVENT_COMMAND;
      event.detail = "download-temp-storage-ready";
      event.value = 1;
      callbacks->event(context, &event);
    }
    // Install before sharedApplication/CefInitialize: initialization itself may
    // create or activate windows. AuditHidden uses no CEF thread/task API here.
    id close_observer = [NSNotificationCenter.defaultCenter addObserverForName:NSWindowWillCloseNotification
        object:nil queue:nil usingBlock:^(NSNotification* notification) {
          pointer->WindowClosing(notification.object);
        }];
    NSMutableArray* audit_observers = [NSMutableArray array];
    if (options.Hidden()) {
      for (NSNotificationName name in @[NSWindowDidBecomeKeyNotification, NSWindowDidBecomeMainNotification,
          NSWindowDidExposeNotification, NSWindowDidUpdateNotification, NSWindowDidChangeOcclusionStateNotification,
          NSApplicationDidBecomeActiveNotification]) {
        id observer = [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil
            usingBlock:^(NSNotification*) { pointer->AuditHidden(); }];
        [audit_observers addObject:observer];
      }
      state.AuditHidden();
    }
    [ALChromiumApplication sharedApplication];
    if (![NSApp isKindOfClass:[ALChromiumApplication class]]) {
      [NSNotificationCenter.defaultCenter removeObserver:close_observer];
      for (id observer in audit_observers) [NSNotificationCenter.defaultCenter removeObserver:observer];
      return 70;
    }
    if (options.Hidden()) [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    state.AuditHidden();
    state.client = new Client(&state);
    state.policy = new ContextPolicy(&state);
    CefRefPtr<CefApp> app = new App(&state);
    CefSettings settings;
    settings.no_sandbox = false;
    settings.log_severity = LOGSEVERITY_DISABLE;
    settings.persist_session_cookies = false;
    settings.use_views_default_popup = false;
    CefString(&settings.root_cache_path) = options.root + "/cache";
    CefString(&settings.cache_path) = options.root + "/cache/default";
    CefString(&settings.keychain_service_name) = "Chromium Shell Synthetic Safe Storage";
    CefString(&settings.keychain_account_name) = "Chromium Shell Synthetic";
    active_state = &state;
    if (!CefInitialize(CefMainArgs(argc, argv), settings, app, nullptr)) {
      const int code = CefGetExitCode();
      active_state = nullptr;
      state.AuditHidden();
      [NSNotificationCenter.defaultCenter removeObserver:close_observer];
      for (id observer in audit_observers) [NSNotificationCenter.defaultCenter removeObserver:observer];
      return code;
    }
    state.initialized = true;
    state.AuditHidden();
    if (options.Hidden() && state.failed) Post([pointer] { pointer->Quit(); });
    const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - Clock::now()).count();
    Post([pointer] {
      if (pointer->options.Hidden() && !pointer->quitting) {
        pointer->failed = true;
        pointer->Emit(AL_EVENT_FAILURE, 0, pointer->options.download_test
            ? "download-deadline-expired" : "page-tools-deadline-expired");
      }
      pointer->Quit();
    }, static_cast<int>(std::max<int64_t>(1, remaining)));
    CefRunMessageLoop();
    active_state = nullptr;
    const bool clean = state.finished && state.hosts.empty() && !state.pending_windows && NoVisibleWindows();
    state.failed = state.failed || !clean;
    // No owning browser/context references survive into shutdown. The callback
    // context and State remain valid until CefShutdown has released all clients.
    state.hosts.clear();
    state.RevokeDownloads();
    state.downloads.clear();
    state.primary = nullptr;
    state.profiles.clear();
    state.client = nullptr;
    state.policy = nullptr;
    app = nullptr;
    state.shutting_down = true;
    CefShutdown();
    state.AuditHidden(false, "post-cef-shutdown-hidden-audit");
    state.failed = state.failed || !NoVisibleWindows() || (options.Hidden()
        && (NSApp.active || NSApp.keyWindow || NSApp.mainWindow || state.hidden_windows));
    [NSNotificationCenter.defaultCenter removeObserver:close_observer];
    for (id observer in audit_observers) [NSNotificationCenter.defaultCenter removeObserver:observer];
    // CEF thread IDs cease to exist after shutdown; deliver this final value
    // directly on the same main thread, without calling CEF thread helpers.
    ALChromiumEvent event {sizeof(ALChromiumEvent), AL_EVENT_SHUTDOWN, 0, 0, 0,
      state.failed ? 1 : 0, "cef-shutdown-returned", nullptr, nullptr};
    callbacks->event(context, &event);
    return state.failed ? 1 : 0;
  }
}
