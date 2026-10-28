// Independent review regressions. Pure C++; no CEF, GUI, profiles or Keychain.
#include "OrbitCefApi.h"
#include "OrbitExtensionPolicy.h"
#include <cassert>
#include <cstddef>
#include <string>
#include <type_traits>

int main() {
  static_assert(std::is_standard_layout_v<orbit_cef_api_t>);
  // The approved arm64 v3 table ends immediately after release_window.
  static_assert(offsetof(orbit_cef_api_t, extensions_snapshot) == 120);
  static_assert(offsetof(orbit_cef_api_t, hold_window) == 104);
  static_assert(offsetof(orbit_cef_api_t, move_tab) == 88);
  static_assert(sizeof(orbit_cef_api_t) == 176);
  using orbit_bridge::ExtensionManagerRoute;
  // Every rejected main-frame attempt must revoke a previous trusted manager,
  // even if the old frame's URL is still chrome://extensions/ after cancellation.
  for (const char* target : {"https://example.invalid/", "chrome://settings/",
                            "view-source:chrome://extensions/", "chrome://extensions/?x=1"}) {
    ExtensionManagerRoute route;
    route.Arm();
    assert(route.Allow(route.kURL, "https://example.invalid/", false, "GET"));
    assert(!route.Allow(target, route.kURL, false, "GET"));
    for (int retry = 0; retry != 3; ++retry)
      assert(!route.Allow(route.kURL, route.kURL, false, "GET"));
  }
  for (bool redirect : {false, true}) {
    for (const char* method : {"GET", "POST", "HEAD", "get", ""}) {
      ExtensionManagerRoute route;
      route.Arm();
      const bool allowed = !redirect && std::string(method) == "GET";
      assert(route.Allow(route.kURL, "https://example.invalid/", redirect, method) == allowed);
      // A trusted flag cannot be reused from an unrelated current document.
      assert(!route.Allow(route.kURL, "https://example.invalid/", false, "GET"));
    }
  }
  for (int length = 0; length < 65; ++length) {
    std::string id(length, 'a');
    assert(orbit_bridge::ValidExtensionID(id.c_str()) == (length == 32));
  }
  for (int position = 0; position < 32; ++position) {
    std::string id(32, 'p');
    id[position] = '/';
    assert(!orbit_bridge::ValidExtensionID(id.c_str()));
  }
}
