#include "../Bridge/OrbitNativeCommandScope.h"
#include <cassert>
#include <deque>
#include <iostream>
#include <string>
#include <vector>

bool SelectionOrdering() {
  for (bool nested_pump : {false, true}) {
    orbit_bridge::NativeCommandScope scope;
    std::deque<std::function<void()>> loop;
    auto post = [&](std::function<void()> f) { loop.push_back(std::move(f)); return true; };
    auto turn = [&] { auto f = std::move(loop.front()); loop.pop_front(); f(); };
    int selected = 0;
    {
      orbit_bridge::NativeCommandScope::Command command(scope);
      scope.ActivateOrDefer([&] { selected = 1; return 1; }, post, 42);
      if (nested_pump) turn();
    }
    scope.ActivateOrDefer([&] { selected = 2; return 1; }, post, 42);
    while (!loop.empty()) turn();
    if (selected != 2) return false;
  }
  for (bool refuse_newer : {false, true}) {
    orbit_bridge::NativeCommandScope scope;
    std::deque<std::function<void()>> loop;
    auto post = [&](std::function<void()> f) { loop.push_back(std::move(f)); return true; };
    int first = 0, second = 0;
    {
      orbit_bridge::NativeCommandScope::Command command(scope);
      scope.ActivateOrDefer([&] { first = 1; return 1; }, post, 42);
      if (refuse_newer) {
        if (scope.ActivateOrDefer([&] { first = 2; return 1; }, [](auto) { return false; }, 42) != 0) return false;
      } else {
        scope.ActivateOrDefer([&] { second = 1; return 1; }, post, 43);
      }
    }
    while (!loop.empty()) { auto f = std::move(loop.front()); loop.pop_front(); f(); }
    if (first != 1 || second != (refuse_newer ? 0 : 1)) return false;
  }
  return true;
}

bool TicketDiagnostics() {
  orbit_bridge::NativeCommandScope scope;
  std::deque<std::function<void()>> loop;
  std::vector<std::pair<uint64_t, std::string>> outcomes;
  auto trace = [&](uint64_t ticket, const char* outcome) { outcomes.emplace_back(ticket, outcome); };
  auto post = [&](std::function<void()> task) { loop.push_back(std::move(task)); return true; };
  auto run = [] { return int32_t{1}; };
  {
    orbit_bridge::NativeCommandScope::Command command(scope);
    scope.ActivateOrDefer(run, post, 42, trace);
  }
  scope.ActivateOrDefer(run, post, 42, trace);
  while (!loop.empty()) { auto task = std::move(loop.front()); loop.pop_front(); task(); }
  return outcomes == std::vector<std::pair<uint64_t, std::string>>{{1, "deferred"}, {2, "applied"}, {1, "superseded"}};
}

int main() {
  assert(TicketDiagnostics());
  if (!SelectionOrdering()) return 1;
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
  std::cout << "Native command activation regression: 11 scenarios passed\n";
}
