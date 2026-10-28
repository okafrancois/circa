// Pure native policy tests: no CEF, AppKit, browser process or user data.
#include <cassert>
#include "orbit_hosted_intent.h"

int main() {
  orbit::HostedCreationPolicy policy;
  int parent = 0;
  assert(policy.RegisterWindow(10));
  assert(policy.RegisterWindow(20));
  assert(policy.Prepare(&parent, 10, 2));
  // A second request cannot replace the first request's window or tab index.
  assert(!policy.Prepare(&parent, 20, 7));
  auto pending_a = policy.Take(&parent);
  assert(pending_a && pending_a->window_token == 10 && pending_a->index == 2);
  assert(policy.IsLive(*pending_a));

  // Closing after acceptance cancels the captured request, even if a different
  // profile reuses this parent address for its own immutable request.
  policy.UnregisterWindow(10);
  assert(!policy.IsLive(*pending_a));
  assert(policy.Prepare(&parent, 20, 7));
  auto pending_b = policy.Take(&parent);
  assert(pending_b && pending_b->window_token == 20 && policy.IsLive(*pending_b));
  assert(!policy.IsLive(*pending_a));
  assert(policy.RegisterWindow(10));
  assert(!policy.IsLive(*pending_a));  // Recycled token does not resurrect A.
  assert(policy.IsLive(*pending_b));

  // Closing before acceptance preserves a cancelled mark, rather than making
  // a subsequent Take look like an ordinary unhosted/Alloy creation.
  assert(policy.Prepare(&parent, 10, -1));
  policy.UnregisterWindow(10);
  assert(!policy.Prepare(&parent, 20, -1));
  auto cancelled = policy.Take(&parent);
  assert(cancelled && cancelled->window_token == 10);
  assert(!policy.IsLive(*cancelled));
  assert(!policy.Take(&parent));
  assert(!policy.Prepare(&parent, 10, -1));  // Closed destination refused.
  assert(policy.Prepare(&parent, 20, -1));
  assert(policy.Cancel(&parent));
  assert(!policy.Cancel(&parent));
  assert(!policy.Take(&parent));
  return 0;
}
