// Copyright 2026 Orbit. BSD-style license; see LICENSE.
// Included inside orbit_cef_api.mm before its anonymous namespace.
#include <cstring>
#include <limits>
#include <map>
#include <memory>
#include <string>
#include <vector>
#include "base/no_destructor.h"
#include "base/json/json_writer.h"
#include "base/callback_list.h"
#include "base/functional/bind.h"
#include "base/values.h"
#include "base/scoped_observation.h"
#include "chrome/browser/profiles/profile.h"
#include "extensions/browser/disable_reason.h"
#include "extensions/browser/extension_action_manager.h"
#include "extensions/browser/extension_registrar.h"
#include "extensions/browser/extension_prefs.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/browser/extension_registry_observer.h"
#include "extensions/common/extension.h"

namespace {
bool OnValidUIThread();
CefRefPtr<ChromeBrowserHostImpl> GetChromeHost(int32_t browser_id);
Profile* ExtensionProfile(const char* path) {
  if (!OnValidUIThread() || !path || path[0] != '/' || !g_browser_process ||
      !g_browser_process->profile_manager()) return nullptr;
  Profile* profile = g_browser_process->profile_manager()->GetProfileByPath(base::FilePath(path));
  return profile && !profile->IsOffTheRecord() ? profile : nullptr;
}

int32_t ExtensionsSnapshot(const char* path, char* output, uint32_t capacity) {
  Profile* profile = ExtensionProfile(path);
  if (!profile) return -1;
  auto* registry = extensions::ExtensionRegistry::Get(profile);
  auto* actions = extensions::ExtensionActionManager::Get(profile);
  if (!registry || !actions) return -1;
  base::ListValue rows;
  for (const auto& extension : registry->GenerateInstalledExtensionsSet()) {
    // Component extensions are not user-managed products.
    if (extensions::Manifest::IsComponentLocation(extension->location())) continue;
    base::DictValue row;
    row.Set("id", extension->id());
    row.Set("name", extension->name());
    row.Set("version", extension->version().GetString());
    row.Set("isEnabled", registry->enabled_extensions().Contains(extension->id()));
    row.Set("hasAction", actions->GetExtensionAction(*extension) != nullptr);
    rows.Append(std::move(row));
  }
  const auto json = base::WriteJson(rows);
  if (!json || json->size() > static_cast<size_t>(std::numeric_limits<int32_t>::max())) return -1;
  if (output && capacity > json->size()) std::memcpy(output, json->c_str(), json->size() + 1);
  return static_cast<int32_t>(json->size());
}

int32_t ExtensionSetEnabled(const char* path, const char* id, int32_t enabled) {
  Profile* profile = ExtensionProfile(path);
  if (!profile || !id || (enabled != 0 && enabled != 1)) return 0;
  auto* registry = extensions::ExtensionRegistry::Get(profile);
  auto* registrar = extensions::ExtensionRegistrar::Get(profile);
  const auto* extension = registry ? registry->GetInstalledExtension(id) : nullptr;
  if (!extension || !registrar || extensions::Manifest::IsComponentLocation(extension->location())) return 0;
  // Never grant additional permissions or clear security/policy disable reasons here.
  if (enabled) {
    if (registry->enabled_extensions().Contains(id)) return 1;
    auto* prefs = extensions::ExtensionPrefs::Get(profile);
    if (!prefs || !prefs->HasOnlyDisableReason(id, extensions::disable_reason::DISABLE_USER_ACTION)) return 0;
    registrar->EnableExtension(id);
  }
  else registrar->DisableExtension(id, {extensions::disable_reason::DISABLE_USER_ACTION});
  return registry->enabled_extensions().Contains(id) == (enabled == 1) ? 1 : 0;
}

int32_t ExtensionRemove(const char* path, const char* id) {
  Profile* profile = ExtensionProfile(path);
  if (!profile || !id) return 0;
  auto* registry = extensions::ExtensionRegistry::Get(profile);
  auto* registrar = extensions::ExtensionRegistrar::Get(profile);
  const auto* extension = registry ? registry->GetInstalledExtension(id) : nullptr;
  if (!extension || !registrar || extensions::Manifest::IsComponentLocation(extension->location())) return 0;
  std::u16string error;
  return registrar->UninstallExtension(id, extensions::UNINSTALL_REASON_USER_INITIATED, &error) ? 1 : 0;
}

class OrbitExtensionObservation final : public extensions::ExtensionRegistryObserver,
                                       public std::enable_shared_from_this<OrbitExtensionObservation> {
 public:
  OrbitExtensionObservation(extensions::ExtensionRegistry* registry,
                          void (*changed)(void*), void* context)
      : changed_(changed), context_(context) { observation_.Observe(registry); }
  void OnExtensionLoaded(content::BrowserContext*, const extensions::Extension*) override { Notify(); }
  void OnExtensionReady(content::BrowserContext*, const extensions::Extension*) override { Notify(); }
  void OnExtensionUnloaded(content::BrowserContext*, const extensions::Extension*,
                           extensions::UnloadedExtensionReason) override { Notify(); }
  void OnExtensionInstalled(content::BrowserContext*, const extensions::Extension*, bool) override { Notify(); }
  void OnExtensionUninstalled(content::BrowserContext*, const extensions::Extension*,
                              extensions::UninstallReason) override { Notify(); }
  void OnShutdown(extensions::ExtensionRegistry*) override { observation_.Reset(); }
 private:
  void Notify() {
    // A synchronous observer may unregister/remove its profile or shut down.
    auto keep_alive = shared_from_this();
    const auto callback = changed_;
    void* context = context_;
    if (callback) callback(context);
  }
  void (*changed_)(void*);
  void* context_;
  base::ScopedObservation<extensions::ExtensionRegistry, extensions::ExtensionRegistryObserver> observation_{this};
};

using ExtensionObservationMap =
    std::map<std::string, std::shared_ptr<OrbitExtensionObservation>>;
ExtensionObservationMap& GetExtensionObservations() {
  static base::NoDestructor<ExtensionObservationMap> observations;
  return *observations;
}
int32_t ExtensionsObserve(const char* path, void (*changed)(void*), void* context) {
  if (!OnValidUIThread() || !path) return 0;
  GetExtensionObservations().erase(path);
  if (!changed) return 1;
  Profile* profile = ExtensionProfile(path);
  auto* registry = profile ? extensions::ExtensionRegistry::Get(profile) : nullptr;
  if (!registry) return 0;
  GetExtensionObservations()[path] = std::make_shared<OrbitExtensionObservation>(registry, changed, context);
  return 1;
}
}  // namespace

#include "chrome/browser/extensions/extension_action_runner.h"
#include "chrome/browser/extensions/extension_view_host_factory.h"
#include "chrome/browser/extensions/extension_view_host.h"
#include "chrome/browser/ui/views/extensions/extension_popup.h"
#include "extensions/browser/extension_action.h"
#include "ui/gfx/mac/coordinate_conversion.h"

#include "cef/libcef/browser/orbit/orbit_extension_lease.h"
#include "content/public/browser/web_contents_observer.h"

namespace {
struct ExtensionSelection {
  int32_t browser;
  uint64_t surface, profile, epoch;
};
using ExtensionSelectionMap = std::map<uint64_t, ExtensionSelection>;
ExtensionSelectionMap& GetExtensionSelections() {
  static base::NoDestructor<ExtensionSelectionMap> selections;
  return *selections;
}
class OrbitNativePopupLease;
using ExtensionInvocationMap =
    std::map<uint64_t, std::weak_ptr<OrbitNativePopupLease>>;
ExtensionInvocationMap& GetExtensionInvocations() {
  static base::NoDestructor<ExtensionInvocationMap> invocations;
  return *invocations;
}

// No retained embedder callbacks or opaque Swift pointers. The popup owns this
// native context; every engine object is observed and nulled before cancellation.
class OrbitNativePopupLease final : public ExtensionPopup::NativeInvocation,
                                  public content::WebContentsObserver,
                                  public TabStripModelObserver,
                                  public extensions::ExtensionRegistryObserver,
                                  public std::enable_shared_from_this<OrbitNativePopupLease> {
 public:
  uint64_t window() const { return lease_.identity().window; }
  OrbitNativePopupLease(orbit_extensions::InvocationIdentity identity, Browser* browser,
                      content::WebContents* contents, NSView* anchor, const char* extension_id)
      : content::WebContentsObserver(contents), lease_(identity), browser_(browser),
        model_(browser->tab_strip_model()), profile_(browser->GetProfile()), anchor_(anchor), extension_id_(extension_id) {
    model_->AddObserver(this);
    registry_.Observe(extensions::ExtensionRegistry::Get(profile_));
  }
  ~OrbitNativePopupLease() override { Detach(); }
  void ObserveBrowserClose() {
    browser_close_ = browser_->RegisterBrowserDidClose(base::BindRepeating(
        [](std::weak_ptr<OrbitNativePopupLease> weak, BrowserWindowInterface*) {
          if (auto lease = weak.lock()) lease->Cancel();
        }, weak_from_this()));
  }
  bool IsValid() override {
    if (!browser_ || !model_ || !profile_ || !web_contents()) return false;
    const auto& id = lease_.identity();
    const auto generation = orbit::GetWindowGeneration(id.window);
    const auto selection = GetExtensionSelections().find(id.window);
    if (!generation || selection == GetExtensionSelections().end()) return false;
    const auto& current = selection->second;
    auto host = GetChromeHost(id.browser);
    if (!host || host->browser() != browser_ || host->GetWebContents() != web_contents()) return false;
    orbit_extensions::InvocationIdentity live{id.window, *generation, current.surface,
        current.profile, current.epoch, current.browser,
        reinterpret_cast<uintptr_t>(host->GetWebContents())};
    if (!lease_.Authorizes(live) || browser_->IsDeleteScheduled() || browser_->GetProfile() != profile_ ||
        model_->GetActiveWebContents() != web_contents()) return false;
    NSView* anchor = anchor_.GetNativeNSView();
    NSWindow* window = orbit::GetNativeWindow(id.window).GetNativeNSWindow();
    NSView* source = web_contents()->GetNativeView().GetNativeNSView();
    return anchor && window && window.isVisible && anchor.window == window &&
        !anchor.isHiddenOrHasHiddenAncestor && !NSIsEmptyRect(anchor.visibleRect) &&
        source && source.window == window && !source.isHiddenOrHasHiddenAncestor;
  }
  void SetCancellation(base::RepeatingClosure callback) override {
    cancellation_ = std::move(callback);
    if (!IsValid()) {
      auto notification = std::move(cancellation_);
      Cancel();
      if (notification) notification.Run();
    }
  }
  void Cancel() override {
    auto keep_alive = shared_from_this();
    if (!lease_.Revoke()) return;
    // No Browser, Profile, source contents or model access is possible from a
    // later callback, even if destroying a widget is deferred by AppKit.
    Detach();
    auto callback = std::move(cancellation_);
    if (callback) callback.Run();
  }
  void WebContentsDestroyed() override { Cancel(); }
  void OnTabStripModelChanged(TabStripModel*, const TabStripModelChange&,
                              const TabStripSelectionChange&) override { Cancel(); }
  void OnTabStripModelDestroyed(TabStripModel*) override {
    model_ = nullptr;
    browser_ = nullptr;
    Cancel();
  }
  void OnShutdown(extensions::ExtensionRegistry*) override { registry_.Reset(); Cancel(); }
  void OnExtensionUnloaded(content::BrowserContext*, const extensions::Extension* extension,
                           extensions::UnloadedExtensionReason) override {
    if (extension->id() == extension_id_) Cancel();
  }
  void OnExtensionUninstalled(content::BrowserContext*, const extensions::Extension* extension,
                              extensions::UninstallReason) override {
    if (extension->id() == extension_id_) Cancel();
  }
 private:
  void Detach() {
    browser_close_ = {};
    browser_ = nullptr;
    profile_ = nullptr;
    if (model_) { model_->RemoveObserver(this); model_ = nullptr; }
    Observe(nullptr);
    registry_.Reset();
  }
  orbit_extensions::InvocationLease lease_;
  raw_ptr<Browser> browser_;
  raw_ptr<TabStripModel> model_;
  raw_ptr<Profile> profile_;
  gfx::NativeView anchor_;
  const std::string extension_id_;
  base::RepeatingClosure cancellation_;
  base::CallbackListSubscription browser_close_;
  base::ScopedObservation<extensions::ExtensionRegistry, extensions::ExtensionRegistryObserver> registry_{this};
};

void ExtensionCancel(uint64_t invocation) {
  if (!OnValidUIThread()) return;
  auto found = GetExtensionInvocations().find(invocation);
  if (found == GetExtensionInvocations().end()) return;
  auto lease = found->second.lock();
  GetExtensionInvocations().erase(found);
  if (lease) lease->Cancel();
}
int32_t ExtensionSelectionChanged(uint64_t window, int32_t browser, uint64_t surface,
                                 uint64_t profile, uint64_t epoch) {
  if (!OnValidUIThread()) return 0;
  auto existing = GetExtensionSelections().find(window);
  if (existing != GetExtensionSelections().end() && existing->second.epoch >= epoch) return 0;
  GetExtensionSelections()[window] = {-1, 0, 0, epoch}; // Revoke before cancellation.
  std::vector<std::shared_ptr<OrbitNativePopupLease>> cancelled;
  for (auto it = GetExtensionInvocations().begin(); it != GetExtensionInvocations().end();) {
    auto lease = it->second.lock();
    if (!lease || lease->window() == window) {
      if (lease) cancelled.push_back(std::move(lease));
      it = GetExtensionInvocations().erase(it);
    } else { ++it; }
  }
  for (auto& lease : cancelled) lease->Cancel();
  const auto final = GetExtensionSelections().find(window);
  if (final != GetExtensionSelections().end() && final->second.epoch == epoch) {
    if (browser >= 0 && surface && profile && epoch && orbit::IsKnownWindow(window))
      final->second = {browser, surface, profile, epoch};
    else GetExtensionSelections().erase(final);
  }
  return 1;
}
int32_t ExtensionAction(int32_t browser_id, const char* id, void* anchor_nsview,
                        uint64_t invocation, uint64_t surface, uint64_t profile, uint64_t epoch) {
  if (!OnValidUIThread() || !id || !anchor_nsview || !invocation) return 0;
  auto* delegate = CefBrowserPlatformDelegateChromeHosted::FromBrowserId(browser_id);
  auto host = GetChromeHost(browser_id);
  if (!delegate || !host || !host->browser() || !host->GetWebContents()) return 0;
  Browser* browser = host->browser();
  auto* contents = host->GetWebContents();
  if (browser->GetProfile()->IsOffTheRecord() ||
      browser->tab_strip_model()->GetActiveWebContents() != contents) return 0;
  NSView* anchor = (__bridge NSView*)anchor_nsview;
  if (![anchor isKindOfClass:[NSView class]]) return 0;
  const uint64_t window = delegate->window_token();
  const auto generation = orbit::GetWindowGeneration(window);
  if (!generation) return 0;
  auto lease = std::make_shared<OrbitNativePopupLease>(
      orbit_extensions::InvocationIdentity{window, *generation, surface, profile, epoch,
                                         browser_id, reinterpret_cast<uintptr_t>(contents)},
      browser, contents, anchor, id);
  lease->ObserveBrowserClose();
  if (!lease->IsValid()) return 0;
  GetExtensionInvocations()[invocation] = lease;
  auto* registry = extensions::ExtensionRegistry::Get(browser->GetProfile());
  auto* manager = extensions::ExtensionActionManager::Get(browser->GetProfile());
  scoped_refptr<const extensions::Extension> extension = registry ? registry->enabled_extensions().GetByID(id) : nullptr;
  auto* action = extension && manager ? manager->GetExtensionAction(*extension) : nullptr;
  auto* runner = extensions::ExtensionActionRunner::GetForWebContents(contents);
  const int tab_id = extensions::ExtensionTabUtil::GetTabId(contents);
  if (!action || !runner || !action->GetIsVisible(tab_id)) { ExtensionCancel(invocation); return 0; }
  const auto result = runner->RunAction(extension.get(), /*grant_tab_permissions=*/true);
  if (!lease->IsValid()) { ExtensionCancel(invocation); return 0; }
  if (result != extensions::ExtensionAction::ShowAction::kShowPopup) {
    ExtensionCancel(invocation);
    return result == extensions::ExtensionAction::ShowAction::kToggleSidePanel ? -2 : 1;
  }
  if (registry->enabled_extensions().GetByID(id) != extension.get()) { ExtensionCancel(invocation); return 0; }
  action = manager->GetExtensionAction(*extension);
  if (!action || !action->HasPopup(tab_id)) { ExtensionCancel(invocation); return 0; }
  auto popup = extensions::ExtensionViewHostFactory::CreatePopupHost(*extension, action->GetPopupUrl(tab_id), browser);
  if (!popup || !lease->IsValid()) { ExtensionCancel(invocation); return 0; }
  const NSRect screen_rect = [anchor.window convertRectToScreen:[anchor convertRect:anchor.bounds toView:nil]];
  ExtensionPopup::ShowPopupWithNativeParent(browser, std::move(popup),
      gfx::NativeView(anchor.window.contentView), gfx::ScreenRectFromNSRect(screen_rect), lease);
  return 1;
}
}  // namespace
