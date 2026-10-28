// Pure bridge policy tests (OrbitBridgePolicy.h): no CEF, AppKit, browser process or user data.
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <set>
#include <string>
#include <vector>

#include "OrbitBridgeFiles.h"
#include "OrbitBridgePolicy.h"

#include <fstream>

namespace {

int failures = 0;

void Check(bool condition, const char* what) {
  if (!condition) {
    std::fprintf(stderr, "FAIL: %s\n", what);
    ++failures;
  }
}

using Ledger = orbit_bridge::KeyReceiptLedger<std::shared_ptr<int>>;
using orbit_bridge::AnswerUnhandledKey;
using orbit_bridge::NetworkPolicy;
using orbit_bridge::QuitPolicy;
using orbit_bridge::UnhandledKeyAnswer;

void KeyReceiptsAreBoundedPerSurface() {
  Ledger ledger;
  auto first = std::make_shared<int>(0);
  ledger.Track(1, 10, first);
  for (uint64_t id = 2; id <= Ledger::kPerSurface + 1; ++id) ledger.Track(id, 10, std::make_shared<int>(0));
  Check(ledger.CountFor(10) == Ledger::kPerSurface, "a surface keeps at most kPerSurface receipts");
  // The evicted candidate's late answer has no receipt and must be consumed, not redistributed.
  const uint64_t late = ledger.Take(10, first);
  Check(late == 0, "the oldest receipt of the surface was evicted");
  Check(AnswerUnhandledKey(late, /*was_candidate=*/true) == UnhandledKeyAnswer::kConsumed,
        "an evicted candidate is consumed");
  Check(AnswerUnhandledKey(0, /*was_candidate=*/false) == UnhandledKeyAnswer::kDefault,
        "a key that was never a candidate keeps CEF's default handling");
}

void OneSurfaceCannotEvictAnother() {
  Ledger ledger;
  auto quiet = std::make_shared<int>(0);
  ledger.Track(1, 20, quiet);
  for (uint64_t id = 2; id < 2 + 4 * Ledger::kPerSurface; ++id) ledger.Track(id, 30, std::make_shared<int>(0));
  Check(ledger.CountFor(30) == Ledger::kPerSurface, "the busy surface is bounded");
  const uint64_t receipt = ledger.Take(20, quiet);
  Check(receipt == 1, "the quiet surface keeps its receipt");
  Check(AnswerUnhandledKey(receipt, true) == UnhandledKeyAnswer::kReceipt, "a valid receipt is returned");
  Check(ledger.Take(20, quiet) == 0, "a receipt is used once");
}

void ReceiptsMatchSurfaceAndEvent() {
  Ledger ledger;
  auto event = std::make_shared<int>(0);
  ledger.Track(7, 40, event);
  Check(ledger.Take(41, event) == 0, "another surface cannot take the receipt");
  Check(ledger.Take(40, std::make_shared<int>(0)) == 0, "another event cannot take the receipt");
  ledger.ForgetSurface(40);
  Check(ledger.Take(40, event) == 0, "a closed surface's receipts are gone");
  Check(ledger.size() == 0, "nothing left after the surface closed");
}

void TotalIsBounded() {
  Ledger ledger;
  uint64_t id = 1;
  for (uint64_t surface = 1; surface <= 2 * Ledger::kTotal / Ledger::kPerSurface; ++surface)
    for (size_t index = 0; index < Ledger::kPerSurface; ++index) ledger.Track(id++, surface, std::make_shared<int>(0));
  Check(ledger.size() == Ledger::kTotal, "the ledger keeps at most kTotal receipts");
}

void QuitIsBounded() {
  Check(QuitPolicy::AfterStall(1) == QuitPolicy::Action::kRetryClose, "the first stall retries the closes");
  Check(QuitPolicy::AfterStall(QuitPolicy::kForceAfterStalls) == QuitPolicy::Action::kForceQuit,
        "the loop is forced to end after kForceAfterStalls stalls");
  Check(QuitPolicy::AfterStall(QuitPolicy::kForceAfterStalls + 5) == QuitPolicy::Action::kForceQuit,
        "a later stall never waits again");
  const int forced_after_ms = QuitPolicy::kCheckIntervalMs * static_cast<int>(QuitPolicy::kForceAfterStalls);
  // Forced end + CefShutdown under Chromium's 10 s MacShutdownWatchdog stay below the hard exit.
  Check(forced_after_ms + 10000 < QuitPolicy::kHardExitSeconds * 1000, "the hard exit comes after a forced shutdown");
  Check(QuitPolicy::kHardExitSeconds <= 60, "the quit is bounded to one minute");
}

bool HasSwitch(NetworkPolicy policy, const std::string& name, const std::string& value = "") {
  const auto switches = orbit_bridge::BrowserSwitches(policy);
  return std::any_of(switches.begin(), switches.end(),
                     [&](const auto& item) { return item.name == name && item.value == value; });
}

bool DisablesFeature(NetworkPolicy policy, const std::string& feature) {
  const auto features = orbit_bridge::DisabledFeatures(policy);
  return std::find(features.begin(), features.end(), feature) != features.end();
}

void NetworkSwitchesPerPolicy() {
  // Every automated run stays hermetic.
  Check(HasSwitch(NetworkPolicy::kHermetic, "disable-background-networking"), "hermetic: no background networking");
  Check(HasSwitch(NetworkPolicy::kHermetic, "disable-component-update"), "hermetic: no component updater");
  Check(DisablesFeature(NetworkPolicy::kHermetic, "NetworkTimeServiceQuerying"), "hermetic: no network time");
  // The signed daily build updates its security components and extensions.
  Check(!HasSwitch(NetworkPolicy::kProduct, "disable-component-update"), "product: component updater (CRLSet, Widevine)");
  Check(!HasSwitch(NetworkPolicy::kProduct, "disable-background-networking"), "product: extension updates");
  Check(!DisablesFeature(NetworkPolicy::kProduct, "NetworkTimeServiceQuerying"), "product: Chrome's network time");
  for (const auto policy : {NetworkPolicy::kHermetic, NetworkPolicy::kProduct}) {
    Check(HasSwitch(policy, "disable-sync"), "sync stays off in every mode");
    Check(HasSwitch(policy, "no-first-run") && HasSwitch(policy, "no-default-browser-check"), "no first-run prompt");
    Check(HasSwitch(policy, "disable-breakpad"), "no crash reporter");
    Check(HasSwitch(policy, "password-store", "basic"), "basic password store");
    Check(DisablesFeature(policy, "AutofillServerCommunication"), "no autofill crowdsourcing upload");
    Check(!HasSwitch(policy, "variations-server-url") && !HasSwitch(policy, "enable-crash-reporter"),
          "no variations server or crash upload");
    // CH-ESSENTIALS: Chrome's Views login prompt and print preview crash in hosted mode.
    Check(HasSwitch(policy, "disable-chrome-login-prompt"), "HTTP auth reaches GetAuthCredentials");
    Check(HasSwitch(policy, "disable-print-preview"), "print uses the system print panel");
  }
}

void EssentialSurfacePolicies() {
  using orbit_bridge::BeforeUnloadRoute;
  using orbit_bridge::RouteBeforeUnload;
  Check(RouteBeforeUnload(true, false, false) == BeforeUnloadRoute::kAsk,
        "a navigation, reload or confirmed close asks the user");
  Check(RouteBeforeUnload(true, false, true) == BeforeUnloadRoute::kProceed,
        "a close the shell decided (dispose) never asks");
  Check(RouteBeforeUnload(true, true, false) == BeforeUnloadRoute::kProceed, "quitting never asks");
  Check(RouteBeforeUnload(false, false, false) == BeforeUnloadRoute::kProceed, "an unknown host never asks");
  Check(orbit_bridge::AllowsFolderChooser(false, 0), "an Alloy folder chooser has no tab-modal confirmation");
  Check(!orbit_bridge::AllowsFolderChooser(true, 0), "a hosted folder chooser is refused without the patch");
  Check(orbit_bridge::AllowsFolderChooser(true, 1), "the essentials patch allows a hosted folder chooser");
  const auto& names = orbit_bridge::ContextMenuCommandNames();
  std::set<std::string> unique(names.begin(), names.end());
  Check(unique.size() == names.size(), "context menu command names are unique");
  Check(unique.contains("IDC_CONTENT_CONTEXT_INSPECTELEMENT") && unique.contains("IDC_SPELLCHECK_SUGGESTION_0"),
        "inspect and spelling suggestions are offered");
  Check(!unique.contains("IDC_VIEW_SOURCE") && !unique.contains("IDC_CONTENT_CONTEXT_OPENLINKNEWTAB"),
        "commands that would add tabs Orbit does not own are never executed by Chrome");
  const std::set<int32_t> offered = {50150, 50162};
  Check(orbit_bridge::AcceptsContextMenuCommand(50150, offered), "an offered command is executed");
  Check(!orbit_bridge::AcceptsContextMenuCommand(50151, offered), "a command not offered for this request cancels");
  Check(!orbit_bridge::AcceptsContextMenuCommand(-1, offered), "a negative id cancels");
}

void InitialProfileStaysPinned() {
  using orbit_bridge::IsPinnedInitialProfile;
  using orbit_bridge::OverridesInitialProfile;
  for (const char* argument : {"--ignore-profile-directory-if-not-exists", "--profile-directory=profile-x",
                               "--profile-directory", "--user-data-dir=/private/tmp/other"})
    Check(OverridesInitialProfile(argument), "a switch that moves or bypasses the pin refuses the run");
  for (const char* argument : {"--profile-directory-hint", "--orbit-data-root=/private/tmp/x", "--use-mock-keychain"})
    Check(!OverridesInitialProfile(argument), "unrelated arguments are accepted");
  const std::string root = "/private/tmp/orbit-run/data/Chromium";
  Check(IsPinnedInitialProfile(root, root + "/Default", true), "the pinned Default is accepted");
  Check(!IsPinnedInitialProfile(root, root + "/default", true), "another spelling (case-sensitive volume) fails closed");
  Check(!IsPinnedInitialProfile(root, root + "/profile-1234", true), "last_used's Orbit profile fails closed");
  Check(!IsPinnedInitialProfile(root, root + "/Default", false), "a Default that is another file fails closed");
  Check(!IsPinnedInitialProfile(root, "/private/tmp/elsewhere/Default", true), "a Default outside the root fails closed");
  Check(!IsPinnedInitialProfile("", "/Default", true), "an unresolved root fails closed");
}

void FeatureListsMerge() {
  Check(orbit_bridge::MergeFeatureLists({"MacAppCodeSignClone", "", "A,B", "B,NetworkTimeServiceQuerying"})
            == "MacAppCodeSignClone,A,B,NetworkTimeServiceQuerying",
        "argument, extra and policy features become one value without duplicates");
  Check(orbit_bridge::MergeFeatureLists({",,", ""}).empty(), "empty lists stay empty");
}

// --- CHROMIUM-APP-R3: allow-listed browser arguments (review HIGH 1, MEDIUM 7) ---

std::string TemporaryDirectory(const char* name) {
  std::string pattern = "/private/tmp/orbit-bridge-" + std::string(name) + "-XXXXXX";
  char* created = mkdtemp(pattern.data());
  char resolved[PATH_MAX];
  return created && realpath(created, resolved) ? std::string(resolved) : std::string();
}

void WriteFile(const std::string& path, const std::string& content) { std::ofstream(path) << content; }

bool Exists(const std::string& path) {
  struct stat info {};
  return lstat(path.c_str(), &info) == 0;
}

bool ExtensionOk(const std::string& path) {
  char resolved[PATH_MAX];
  struct stat manifest {};
  return !path.empty() && path[0] == '/' && realpath(path.c_str(), resolved) && path == resolved
         && lstat((path + "/manifest.json").c_str(), &manifest) == 0 && S_ISREG(manifest.st_mode);
}

void ArgumentsAreAllowListed() {
  const std::string base = TemporaryDirectory("arguments");
  Check(!base.empty(), "temporary directory");
  const std::string extension = base + "/extension";
  mkdir(extension.c_str(), 0700);
  WriteFile(extension + "/manifest.json", "{}");
  const std::string linked = base + "/linked-extension";
  symlink(extension.c_str(), linked.c_str());
  const std::vector<std::string> arguments = {
      "--disk-cache-dir=" + base + "/escaped", "-disk-cache-dir=" + base + "/escaped2", "--crash-dumps-dir=/private/tmp/x",
      "--variations-server-url=http://127.0.0.1:1/v", "-force-enable-metrics-reporting", "--remote-debugging-port=9222",
      "--proxy-server=http://127.0.0.1:1", "--use-fake-device-for-media-stream", "--disable-features=MacAppCodeSignClone,B;C,Feature_2",
      "--load-extension=" + extension, "--load-extension=" + linked, "--orbit-data-root=/private/tmp/y", "positional",
      "--", "--use-fake-device-for-media-stream"};
  const auto hermetic = orbit_bridge::FilterBrowserArguments(arguments, /*product=*/0, ExtensionOk);
  Check(!hermetic.refused, "no profile switch: not refused");
  const std::vector<std::string> expected_kept = {"--use-fake-device-for-media-stream", "--load-extension=" + extension};
  Check(hermetic.kept == expected_kept, "hermetic keeps only fake devices and a real synthetic extension");
  const std::vector<std::string> expected_features = {"MacAppCodeSignClone", "Feature_2"};
  Check(hermetic.disabled_features == expected_features, "valid disabled features only");
  Check(hermetic.dropped >= 11, "path-bearing, network-policy and unknown switches are dropped");
  const auto product = orbit_bridge::FilterBrowserArguments(arguments, /*product=*/1, ExtensionOk);
  Check(product.kept.empty() && product.disabled_features.empty() && !product.refused,
        "the product gives Chromium none of the process's switches");
  for (const char* argument : {"-ignore-profile-directory-if-not-exists", "--ignore-profile-directory-if-not-exists",
                               "--PROFILE-DIRECTORY=profile-x", "-user-data-dir=/private/tmp/other", "-profile-directory"}) {
    Check(orbit_bridge::FilterBrowserArguments({argument}, 1, ExtensionOk).refused, "profile pin bypass refuses (any dash form)");
    Check(orbit_bridge::FilterBrowserArguments({argument}, 0, ExtensionOk).refused, "also in hermetic runs");
    Check(orbit_bridge::OverridesInitialProfile(argument), "single-dash and case variants are recognized");
  }
}

// --- CHROMIUM-APP-R3: descriptor-anchored root (review HIGH 2, MEDIUM 5, MEDIUM 6) ---

void AnchoredRootRemovesOnlyItsOwnChildren() {
  using orbit_bridge::AnchoredRoot;
  const std::string base = TemporaryDirectory("root");
  const std::string root = base + "/Chromium";
  mkdir(root.c_str(), 0700);
  const std::string outside = base + "/outside-file";
  WriteFile(outside, "keep");
  // A profile with nested content and a link to a file outside the root.
  mkdir((root + "/profile-a").c_str(), 0700);
  mkdir((root + "/profile-a/Local Storage").c_str(), 0700);
  WriteFile(root + "/profile-a/Local Storage/leveldb", "data");
  WriteFile(root + "/profile-a/Preferences", "{}");
  symlink(outside.c_str(), (root + "/profile-a/Cookies").c_str());
  // A file left where a refused profile directory was.
  WriteFile(root + "/profile-refused", "file");

  const std::string linked_root = base + "/linked-root";
  symlink(root.c_str(), linked_root.c_str());
  Check(!AnchoredRoot::Open(linked_root), "a root reached through a symbolic link is refused");
  Check(!AnchoredRoot::Open(root + "/profile-refused"), "a root that is not a directory is refused");
  const auto anchor = AnchoredRoot::Open(root);
  Check(anchor && anchor->StillAtPath(), "the real root is anchored");
  if (!anchor) return;
  Check(anchor->Inspect("profile-a") == AnchoredRoot::Entry::kDirectory, "directory child");
  Check(anchor->Inspect("profile-refused") == AnchoredRoot::Entry::kOther, "file child");
  Check(anchor->Inspect("../outside-file") == AnchoredRoot::Entry::kError, "never a path outside the root");
  Check(anchor->RemoveChild("..") == AnchoredRoot::Removal::kRefused, "invalid child names are refused");

  Check(anchor->RemoveChild("profile-a") == AnchoredRoot::Removal::kRemoved, "a profile directory is removed");
  Check(!Exists(root + "/profile-a"), "nothing left under its name");
  Check(Exists(outside), "a link inside the profile is removed, never followed");
  Check(anchor->RemoveChild("profile-a") == AnchoredRoot::Removal::kAbsent, "removed then absent: distinct statuses");
  Check(anchor->RemoveChild("profile-refused") == AnchoredRoot::Removal::kRemoved, "a file in place of a profile is cleaned up");
  Check(anchor->RemoveChild("profile-refused") == AnchoredRoot::Removal::kAbsent, "then absent");

  // Review HIGH 2 repro: after start-up, the root's name is replaced by a link to another
  // directory holding a same-named profile. Nothing is removed, here or there.
  const std::string elsewhere = base + "/elsewhere";
  mkdir(elsewhere.c_str(), 0700);
  mkdir((elsewhere + "/profile-b").c_str(), 0700);
  WriteFile(elsewhere + "/profile-b/marker", "foreign");
  mkdir((root + "/profile-b").c_str(), 0700);
  rename(root.c_str(), (base + "/Chromium.old").c_str());
  symlink(elsewhere.c_str(), root.c_str());
  Check(!anchor->StillAtPath(), "the replaced root is detected");
  Check(anchor->RemoveChild("profile-b") == AnchoredRoot::Removal::kRefused, "a replaced root refuses every removal");
  Check(Exists(elsewhere + "/profile-b/marker"), "the same-named profile elsewhere is untouched");
  Check(Exists(base + "/Chromium.old/profile-b"), "and so is the anchored directory's own");
}

}  // namespace

int main() {
  KeyReceiptsAreBoundedPerSurface();
  OneSurfaceCannotEvictAnother();
  ReceiptsMatchSurfaceAndEvent();
  TotalIsBounded();
  QuitIsBounded();
  Check(!QuitPolicy::CanFinish(0, 0, 2),
        "cancelled browser creations must not let quit release initializing profiles");
  Check(!QuitPolicy::CanFinish(0, 0, 1),
        "one profile completion must not release another initializing profile");
  Check(QuitPolicy::CanFinish(0, 0, 0),
        "the final profile completion permits an otherwise drained shutdown");
  Check(!QuitPolicy::CanFinish(1, 0, 0) && !QuitPolicy::CanFinish(0, 1, 0),
        "profile readiness does not bypass browser close and creation barriers");
  NetworkSwitchesPerPolicy();
  FeatureListsMerge();
  InitialProfileStaysPinned();
  EssentialSurfacePolicies();
  ArgumentsAreAllowListed();
  AnchoredRootRemovesOnlyItsOwnChildren();
  if (failures) return EXIT_FAILURE;
  std::printf("BridgePolicyTests: PASS\n");
  return EXIT_SUCCESS;
}
