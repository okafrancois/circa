// Delayed-load authorization regressions. Pure native lease, no CEF/GUI/runtime.
#include "OrbitExtensionLease.h"
#include <cassert>
#include <functional>
#include <memory>
using orbit_extensions::InvocationIdentity;
using orbit_extensions::InvocationLease;
struct DeferredPresentation {
  InvocationLease lease;
  int presentations = 0, browser_accesses = 0;
  explicit DeferredPresentation(InvocationIdentity id) : lease(id) {}
  void LoadCompleted(const InvocationIdentity& current, const std::function<void()>& safety = {}) {
    if (!lease.Authorizes(current)) return;
    ++browser_accesses;
    if (safety) safety();
    if (!lease.Authorizes(current)) return; // A safety callback can cancel synchronously.
    ++presentations;
  }
};
int main() {
  const InvocationIdentity a{1, 10, 11, 12, 13, 14, 15};
  for (auto changed : {InvocationIdentity{1,10,21,22,23,24,25}, // Profile A -> B, same NSWindow.
                       InvocationIdentity{1,10,11,12,14,14,15}, // Selection ABA, new epoch.
                       InvocationIdentity{2,20,11,12,13,14,15}, // Live tab transfer.
                       InvocationIdentity{1,11,11,12,13,14,15}, // Reused window token, new generation.
                       InvocationIdentity{1,10,11,12,13,14,16}}) { // Replaced WebContents.
    DeferredPresentation delayed(a);
    delayed.LoadCompleted(changed);
    assert(delayed.presentations == 0 && delayed.browser_accesses == 0);
  }
  for (int edge = 0; edge != 9; ++edge) { // hide, detach, move, close, profile, shutdown, contents, model, Browser close
    DeferredPresentation delayed(a);
    assert(delayed.lease.Revoke());
    assert(!delayed.lease.Revoke());
    delayed.LoadCompleted(a); // Native parent can still be alive; it grants no authority.
    assert(delayed.presentations == 0 && delayed.browser_accesses == 0);
  }
  DeferredPresentation during_safety(a);
  during_safety.LoadCompleted(a, [&] { during_safety.lease.Revoke(); });
  assert(during_safety.browser_accesses == 1 && during_safety.presentations == 0);
  DeferredPresentation healthy(a);
  healthy.LoadCompleted(a);
  assert(healthy.presentations == 1);
  // A callback queued before destruction holds no raw native owner.
  auto owner = std::make_shared<DeferredPresentation>(a);
  std::weak_ptr<DeferredPresentation> weak = owner;
  int late_accesses = 0;
  auto late = [weak, a, &late_accesses] {
    if (auto live = weak.lock()) { live->LoadCompleted(a); ++late_accesses; }
  };
  owner->lease.Revoke(); owner.reset(); late();
  assert(late_accesses == 0);
}
