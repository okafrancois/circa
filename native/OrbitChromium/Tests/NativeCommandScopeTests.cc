#include "../Bridge/OrbitNativeCommandScope.h"
#include <cassert>
#include <deque>
#include <iostream>

int main() {
  orbit_bridge::NativeCommandScope scope;
  std::deque<std::function<void()>> loop;
  int activations = 0;
  auto post = [&](std::function<void()> task) { loop.push_back(std::move(task)); return true; };
  auto activate = [&] { ++activations; return int32_t{1}; };
  auto turn = [&] { auto task = std::move(loop.front()); loop.pop_front(); task(); };
  assert(scope.ActivateOrDefer(activate, post) == 1 && activations == 1);
  {
    orbit_bridge::NativeCommandScope::Command duplicate(scope);
    {
      orbit_bridge::NativeCommandScope::Command nested(scope);
      // Models OnAfterCreated -> hostedTabDidCreate -> activation inside duplicate.
      assert(scope.ActivateOrDefer(activate, post) == 1 && activations == 1);
    }
    assert(activations == 1 && loop.size() == 1);
    turn();  // A nested message pump must still not activate reentrantly.
    assert(activations == 1 && loop.empty());
    // A nested drain can now return instead of finding another copy of its work.
    assert(scope.ActivateOrDefer(activate, [](auto) { return false; }) == 0);
  }
  assert(activations == 1);
  turn();
  assert(activations == 2 && loop.empty());
  bool live = true;
  {
    orbit_bridge::NativeCommandScope::Command duplicate(scope);
    scope.ActivateOrDefer([&] { if (live) ++activations; return int32_t{live}; }, post);
  }
  live = false;  // Closing a surface before the next turn revokes activation.
  turn();
  assert(activations == 2 && loop.empty());
  bool accept = true;
  auto flaky = [&](std::function<void()> task) {
    if (!accept) return false;
    loop.push_back(std::move(task)); return true;
  };
  {
    orbit_bridge::NativeCommandScope::Command duplicate(scope);
    scope.ActivateOrDefer(activate, flaky);
    turn();
    assert(loop.empty());
    accept = false;
  }
  assert(loop.empty() && activations == 2);
  accept = true;
  scope.ActivateOrDefer(activate, post);
  assert(activations == 3 && loop.size() == 1);
  turn();
  assert(activations == 4 && loop.empty());
  {
    orbit_bridge::NativeCommandScope::Command duplicate(scope);
    scope.ActivateOrDefer(activate, post);
    turn();
    assert(loop.empty());
    scope.Cancel();
  }
  assert(loop.empty() && activations == 4);
  assert(scope.ActivateOrDefer(activate, post) == 0);
  std::cout << "Native command activation regression: 6 scenarios passed\n";
}
