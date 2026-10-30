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
    assert(activations == 1 && loop.size() == 1);
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
  std::cout << "Native command activation regression: 4 scenarios passed\n";
}
