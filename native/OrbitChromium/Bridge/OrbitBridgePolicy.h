// Pure policies of the Orbit Chromium bridge: no CEF, AppKit or browser process, so that they are
// unit-tested on their own (native/OrbitChromium/Tests/BridgePolicyTests.cc).

#ifndef ORBIT_BRIDGE_POLICY_H
#define ORBIT_BRIDGE_POLICY_H

#include <cctype>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <set>
#include <string>
#include <utility>
#include <vector>

namespace orbit_bridge {

// ABI 7 page-first keys (CHROMIUM-APP-R2, review M1). A key down sent to the page as a shortcut
// candidate keeps a receipt until the page's unhandled answer comes back. The page consumes most
// candidates, so receipts are bounded: per surface (a busy page cannot evict another surface's
// receipts) and overall. A candidate whose receipt was evicted is answered "consumed", never
// "default": CEF would otherwise redistribute it to the menu bar without a valid receipt, after
// the selection or the document may have changed.
template <typename Event>
class KeyReceiptLedger {
 public:
  static constexpr size_t kPerSurface = 32;
  static constexpr size_t kTotal = 256;

  void Track(uint64_t id, uint64_t surface, Event event) {
    entries_.push_back({id, surface, std::move(event)});
    if (CountFor(surface) > kPerSurface) EraseOldest(surface);
    while (entries_.size() > kTotal) entries_.pop_front();
  }

  // The receipt of a tracked candidate (removed), or 0.
  uint64_t Take(uint64_t surface, const Event& event) {
    for (auto it = entries_.begin(); it != entries_.end(); ++it) {
      if (it->surface == surface && it->event == event) {
        const uint64_t id = it->id;
        entries_.erase(it);
        return id;
      }
    }
    return 0;
  }

  // A closed surface's receipts can never be answered.
  void ForgetSurface(uint64_t surface) {
    for (auto it = entries_.begin(); it != entries_.end();) {
      if (it->surface == surface) it = entries_.erase(it);
      else ++it;
    }
  }

  void Clear() { entries_.clear(); }
  size_t size() const { return entries_.size(); }
  size_t CountFor(uint64_t surface) const {
    size_t count = 0;
    for (const auto& entry : entries_) count += entry.surface == surface ? 1 : 0;
    return count;
  }

 private:
  struct Entry {
    uint64_t id;
    uint64_t surface;
    Event event;
  };

  void EraseOldest(uint64_t surface) {
    for (auto it = entries_.begin(); it != entries_.end(); ++it) {
      if (it->surface == surface) {
        entries_.erase(it);
        return;
      }
    }
  }

  std::deque<Entry> entries_;
};

enum class UnhandledKeyAnswer {
  kReceipt,   // Return the receipt to the shell; report the key handled to CEF.
  kConsumed,  // A candidate without a valid receipt: report it handled, nothing else.
  kDefault,   // Never a candidate: CEF's ordinary handling.
};

// `was_candidate` is the mark set on the event when it was sent to the page as a candidate.
inline UnhandledKeyAnswer AnswerUnhandledKey(uint64_t receipt, bool was_candidate) {
  if (receipt) return UnhandledKeyAnswer::kReceipt;
  return was_candidate ? UnhandledKeyAnswer::kConsumed : UnhandledKeyAnswer::kDefault;
}

// Bounded quit (CHROMIUM-APP-R2, review H3). ACRRequestQuit closes every browser and waits for
// their OnBeforeClose. The UI-thread check runs every kCheckIntervalMs: it retries the closes and,
// after kForceAfterStalls stalls, forces the message loop to end; CefShutdown then destroys the
// browsers that never confirmed (CefContext::ShutdownOnUIThread -> DestroyAllBrowsers). A
// watchdog off the UI thread ends the process kHardExitSeconds after the quit request in any
// case, including a blocked UI thread or a CefShutdown that does not return. The shell saved its
// session before asking to quit, and the session file survives a hard exit.
struct QuitPolicy {
  static constexpr int kCheckIntervalMs = 5000;
  static constexpr uint32_t kForceAfterStalls = 2;
  // Covers the forced end (10 s) and Chromium's own MacShutdownWatchdog (10 s) with a margin.
  static constexpr int kHardExitSeconds = 40;

  // Exit statuses of ACRRun / the process.
  static constexpr int kStatusStalled = 75;      // Stalled, then every browser closed.
  static constexpr int kStatusLiveAtLoopEnd = 76;
  static constexpr int kStatusForced = 77;       // Forced end, CefShutdown destroyed the rest.
  static constexpr int kStatusHardExit = 78;     // Watchdog _exit.
  static constexpr int kStatusProfileUnpinned = 79;  // Chrome's initial profile is not <root>/Default.

  // Browser cancellation does not cancel asynchronous request-context initialization.
  static bool CanFinish(size_t hosts, size_t pending_browsers, size_t initializing_profiles) {
    return hosts == 0 && pending_browsers == 0 && initializing_profiles == 0;
  }

  enum class Action { kRetryClose, kForceQuit };
  static Action AfterStall(uint32_t stalls) {
    return stalls >= kForceAfterStalls ? Action::kForceQuit : Action::kRetryClose;
  }
};

// Browser process arguments (CHROMIUM-APP-R3, review HIGH 1 / MEDIUM 7). Chromium reads its
// switches from the argv given to CefInitialize, in both "--name" and "-name" forms, and turns some
// into preferences (ChromeCommandLinePrefStore: --disk-cache-dir...). The bridge therefore passes
// Chromium an allow-listed argv, never the process's own: every switch comes from the policy, plus
// in hermetic runs only the laboratory's synthetic inputs (unpacked test extensions, fake capture
// devices, disabled features). Anything else is dropped; the switches that would move or bypass the
// pinned initial profile refuse the run (fail closed), whatever their dash form.
struct ParsedSwitch {
  bool is_switch = false;
  std::string name;
  std::string value;
  bool has_value = false;
};

inline ParsedSwitch ParseSwitch(const std::string& argument) {
  ParsedSwitch parsed;
  size_t start = 0;
  if (argument.starts_with("--")) start = 2;
  else if (argument.starts_with("-") && argument.size() > 1) start = 1;
  else return parsed;
  const std::string body = argument.substr(start);
  if (body.empty()) return parsed;  // "--" ends the switches; nothing after it is kept either.
  parsed.is_switch = true;
  const size_t equals = body.find('=');
  parsed.name = body.substr(0, equals);
  for (auto& c : parsed.name) c = static_cast<char>(tolower(static_cast<unsigned char>(c)));
  if (equals != std::string::npos) {
    parsed.value = body.substr(equals + 1);
    parsed.has_value = true;
  }
  return parsed;
}

inline bool IsFeatureName(const std::string& name) {
  if (name.empty() || name.size() > 128) return false;
  for (const char c : name)
    if (!(isalnum(static_cast<unsigned char>(c)) || c == '_')) return false;
  return true;
}

struct ArgumentFilter {
  std::vector<std::string> kept;               // Normalized "--name[=value]".
  std::vector<std::string> disabled_features;  // Validated names, merged by the bridge.
  size_t dropped = 0;
  bool refused = false;
};

// `extension_path_ok` validates one unpacked test extension directory (real directory, no link,
// a manifest), and is only consulted in hermetic runs.
template <typename PathCheck>
ArgumentFilter FilterBrowserArguments(const std::vector<std::string>& arguments, int policy_is_product,
                                      PathCheck extension_path_ok) {
  ArgumentFilter result;
  bool switches_ended = false;
  for (const auto& argument : arguments) {
    if (argument == "--") { switches_ended = true; continue; }
    const ParsedSwitch parsed = switches_ended ? ParsedSwitch{} : ParseSwitch(argument);
    if (!parsed.is_switch) { ++result.dropped; continue; }
    if (parsed.name == "ignore-profile-directory-if-not-exists" || parsed.name == "profile-directory"
        || parsed.name == "user-data-dir") {
      result.refused = true;
      continue;
    }
    if (!policy_is_product) {
      if (parsed.name == "use-fake-device-for-media-stream" && !parsed.has_value) {
        result.kept.push_back("--use-fake-device-for-media-stream");
        continue;
      }
      if (parsed.name == "disable-features" && parsed.has_value) {
        size_t start = 0;
        while (start <= parsed.value.size()) {
          const size_t end = parsed.value.find(',', start);
          const std::string feature = parsed.value.substr(start, end == std::string::npos ? std::string::npos : end - start);
          if (IsFeatureName(feature)) result.disabled_features.push_back(feature);
          else if (!feature.empty()) ++result.dropped;
          if (end == std::string::npos) break;
          start = end + 1;
        }
        continue;
      }
      if (parsed.name == "load-extension" && parsed.has_value && !parsed.value.empty()) {
        bool every = true;
        size_t start = 0;
        while (start <= parsed.value.size()) {
          const size_t end = parsed.value.find(',', start);
          const std::string path = parsed.value.substr(start, end == std::string::npos ? std::string::npos : end - start);
          every = every && extension_path_ok(path);
          if (end == std::string::npos) break;
          start = end + 1;
        }
        if (every) result.kept.push_back("--load-extension=" + parsed.value);
        else ++result.dropped;
        continue;
      }
    }
    ++result.dropped;
  }
  return result;
}

// Chrome's initial profile backs CEF's global request context and is reserved by the bridge
// (CanonicalChild). It is pinned with --profile-directory=Default (DBG-CH); Chromium ignores the
// pin when --ignore-profile-directory-if-not-exists is given and Default is absent or marked for
// deletion, and falls back to Local State's last_used (startup_browser_creator.cc,
// GetStartupProfilePath). Switches that could move or bypass the pin refuse the run.
inline bool OverridesInitialProfile(const std::string& argument) {
  const ParsedSwitch parsed = ParseSwitch(argument);  // "--name" and "-name", any case.
  return parsed.is_switch && (parsed.name == "ignore-profile-directory-if-not-exists"
                              || parsed.name == "profile-directory" || parsed.name == "user-data-dir");
}

// The initial profile Chrome selected is exactly <root>/Default: `resolved_global` (realpath of
// the global context's cache path) lies directly in `resolved_root` with that exact name, and
// `same_file` is the file identity check of that path against <root>/Default.
inline bool IsPinnedInitialProfile(const std::string& resolved_root, const std::string& resolved_global,
                                   bool same_file) {
  return same_file && !resolved_root.empty() && resolved_global == resolved_root + "/Default";
}

// Browser command line per network policy (CHROMIUM-APP-R2, PM decision; ACRRunOptions
// .network_policy). See docs/native-port/chromium-app-r2-2026-10-25.md for every remaining
// outbound connection category and its source evidence.
// Both modes: no first-run or default-browser prompt, no sync (SyncServiceFactory returns null),
// no crash reporter, basic password store. Metrics/UMA are off in this unbranded build
// (MetricsServiceAccessor), variations never fetch without --variations-server-url, Google
// sign-in is disallowed by CEF (signin.allowed), and no crash_reporter.cfg ships in the bundle.
// kHermetic (default: laboratory, smoke and every automated run): no background networking
// (extension auto-update, Safe Browsing database updates, translate, intranet redirect probes),
// no component updater, no network time queries.
// kProduct (the signed daily build): Chrome's component updater runs (CRLSet, certificate
// transparency logs, Widevine CDM, subresource filter, origin trials and Chrome's other
// registered components, from update.googleapis.com), Web Store extensions update, background
// networking is allowed; autofill crowdsourcing (form signatures uploaded with a placeholder API
// key) is disabled.
enum class NetworkPolicy : int32_t { kHermetic = 0, kProduct = 1 };

struct BrowserSwitch {
  std::string name;
  std::string value;  // Empty: a flag.
};

// CH-ESSENTIALS, both modes. Chrome's own UI for these surfaces is a Views tab-modal dialog,
// which crashes in hosted mode (OrbitBrowserWindow has no WebContentsModalDialogHost:
// constrained_window_views.cc CHECK(dialog_host)):
// - disable-chrome-login-prompt: HTTP authentication reaches CefRequestHandler::GetAuthCredentials
//   instead of LoginHandlerViews (chrome_content_browser_client_cef.cc:695-707);
// - disable-print-preview: print goes to the system print panel (PrintingContextMac,
//   NSPrintPanel runModal) instead of the constrained print preview dialog
//   (print_preview_dialog_controller.cc:462). The pref alone misses window.print()
//   (chrome_browser_delegate.cc:284-286).
inline std::vector<BrowserSwitch> EssentialSurfaceSwitches() {
  return {{"disable-chrome-login-prompt", ""}, {"disable-print-preview", ""}};
}

inline std::vector<BrowserSwitch> BrowserSwitches(NetworkPolicy policy) {
  std::vector<BrowserSwitch> switches;
  if (policy == NetworkPolicy::kHermetic) {
    switches.push_back({"disable-background-networking", ""});
    switches.push_back({"disable-component-update", ""});
  }
  for (const char* name : {"no-first-run", "no-default-browser-check", "disable-sync", "disable-breakpad"})
    switches.push_back({name, ""});
  switches.push_back({"password-store", "basic"});
  for (const auto& item : EssentialSurfaceSwitches()) switches.push_back(item);
  return switches;
}

inline std::vector<std::string> DisabledFeatures(NetworkPolicy policy) {
  if (policy == NetworkPolicy::kHermetic) return {"NetworkTimeServiceQuerying", "AutofillServerCommunication"};
  return {"AutofillServerCommunication"};
}

// One --disable-features value from several comma-separated lists (the command line's own, extra
// switches, the policy's): Chromium keeps only the last value of a repeated switch.
inline std::string MergeFeatureLists(const std::vector<std::string>& lists) {
  std::string merged;
  std::set<std::string> seen;
  for (const auto& list : lists) {
    size_t start = 0;
    while (start <= list.size()) {
      const size_t end = list.find(',', start);
      const std::string feature = list.substr(start, end == std::string::npos ? std::string::npos : end - start);
      if (!feature.empty() && seen.insert(feature).second) merged += (merged.empty() ? "" : ",") + feature;
      if (end == std::string::npos) break;
      start = end + 1;
    }
  }
  return merged;
}

// CH-ESSENTIALS: beforeunload. Chrome style runs beforeunload even for CloseBrowser(true)
// (TabStripModel's UnloadController, chrome_browser_host_impl.cc:737-749). A close the shell already
// decided (tab disposal, quit) or a host the shell no longer knows proceeds at once; only a page
// navigation, reload or `confirmClose()` asks the user.
enum class BeforeUnloadRoute { kProceed, kAsk };
inline BeforeUnloadRoute RouteBeforeUnload(bool host_known, bool quitting, bool closing_by_shell) {
  return host_known && !quitting && !closing_by_shell ? BeforeUnloadRoute::kAsk : BeforeUnloadRoute::kProceed;
}

// CH-ESSENTIALS: a folder chooser (`<input webkitdirectory>`) in a hosted tab is followed by
// Chrome's tab-modal upload confirmation (file_select_helper.cc, chrome::ShowTabModal), which
// crashes without a WebContentsModalDialogHost. The pending CEF patch
// (cef-patches/pending/ch-essentials-*.patch, exported level `orbit_cef_essentials_level` >= 1)
// skips it for windows without one, after Orbit's own confirmation. Until then a hosted folder
// chooser is refused.
inline bool AllowsFolderChooser(bool hosted, uint32_t essentials_level) {
  return !hosted || essentials_level >= 1;
}

// CH-ESSENTIALS: Chrome command names (cef_command_ids.h, resolved at run time with
// cef_id_for_command_id_name) that a page context menu may execute through
// CefRunContextMenuCallback::Continue. Only names in this list and present (enabled) in Chrome's own
// menu model for the request are offered to the shell.
inline const std::vector<const char*>& ContextMenuCommandNames() {
  static const std::vector<const char*> names = {
      "IDC_CONTENT_CONTEXT_UNDO", "IDC_CONTENT_CONTEXT_REDO", "IDC_CONTENT_CONTEXT_CUT",
      "IDC_CONTENT_CONTEXT_COPY", "IDC_CONTENT_CONTEXT_PASTE", "IDC_CONTENT_CONTEXT_PASTE_AND_MATCH_STYLE",
      "IDC_CONTENT_CONTEXT_DELETE", "IDC_CONTENT_CONTEXT_SELECTALL",
      "IDC_SPELLCHECK_SUGGESTION_0", "IDC_SPELLCHECK_SUGGESTION_1", "IDC_SPELLCHECK_SUGGESTION_2",
      "IDC_SPELLCHECK_SUGGESTION_3", "IDC_SPELLCHECK_SUGGESTION_4", "IDC_SPELLCHECK_ADD_TO_DICTIONARY",
      "IDC_CONTENT_CONTEXT_COPYIMAGE", "IDC_CONTENT_CONTEXT_SAVEIMAGEAS", "IDC_CONTENT_CONTEXT_SAVELINKAS",
      "IDC_CONTENT_CONTEXT_SAVEAVAS", "IDC_CONTENT_CONTEXT_PLAYPAUSE", "IDC_CONTENT_CONTEXT_MUTE",
      "IDC_CONTENT_CONTEXT_LOOP", "IDC_CONTENT_CONTEXT_CONTROLS", "IDC_CONTENT_CONTEXT_PICTUREINPICTURE",
      "IDC_CONTENT_CONTEXT_LOOK_UP", "IDC_CONTENT_CONTEXT_INSPECTELEMENT"};
  return names;
}

// CH-ESSENTIALS: a context menu command the shell asks for is executed only when it was offered for
// that very request (present and enabled in Chrome's model); anything else cancels the menu.
inline bool AcceptsContextMenuCommand(int32_t command_id, const std::set<int32_t>& offered) {
  return command_id > 0 && offered.contains(command_id);
}

}  // namespace orbit_bridge

#endif  // ORBIT_BRIDGE_POLICY_H
