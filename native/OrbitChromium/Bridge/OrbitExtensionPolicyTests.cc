// Pure native route tests: no application, CEF runtime, personal data or Keychain.
#include "OrbitExtensionPolicy.h"
#include <cassert>
int main() {
  using orbit_bridge::ExtensionManagerRoute;
  assert(!orbit_bridge::ValidExtensionID(nullptr));
  assert(!orbit_bridge::ValidExtensionID(""));
  assert(!orbit_bridge::ValidExtensionID("abcdefghijklmnopabcdefghijklmnox"));
  assert(orbit_bridge::ValidExtensionID("abcdefghijklmnopabcdefghijklmnop"));
  ExtensionManagerRoute route;
  assert(!route.Allow(route.kURL, "https://example.invalid", false, "GET"));
  route.Arm();
  assert(route.Allow(route.kURL, "https://example.invalid", false, "GET"));
  assert(route.Allow(route.kURL, route.kURL, false, "GET")); // Trusted reload.
  assert(!route.Allow("chrome://settings/", route.kURL, false, "GET"));
  assert(!route.Allow(route.kURL, route.kURL, false, "GET")); // Authority revoked.
  for (auto target : {"chrome://extensions/?id=abc", "chrome://extensions.evil/",
                       "chrome://extensions/../settings/", "chrome://extensions/#/",
                       "view-source:chrome://extensions/", "chrome-extension://abc/"}) {
    route.Arm();
    assert(!route.Allow(target, "https://example.invalid", false, "GET"));
    assert(!route.Allow(route.kURL, "https://example.invalid", false, "GET"));
  }
  route.Arm();
  assert(!route.Allow(route.kURL, "https://example.invalid", true, "GET"));
  route.Arm();
  assert(!route.Allow(route.kURL, "https://example.invalid", false, "POST"));
}
