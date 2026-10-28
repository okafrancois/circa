// Native manager routes for one extension's details and the shortcut page (EXT-OUTCOME-R2).
// Pure policy tests; synthetic IDs only.
#include "OrbitExtensionPolicy.h"
#include <cassert>
#include <string>
int main() {
  using orbit_bridge::ExtensionManagerRoute;
  const char* id = "abcdefghijklmnopabcdefghijklmnop";
  const std::string details = std::string(ExtensionManagerRoute::kDetailsPrefix) + id;
  assert(ExtensionManagerRoute::Target(ExtensionManagerRoute::kManager, nullptr) == ExtensionManagerRoute::kURL);
  assert(ExtensionManagerRoute::Target(ExtensionManagerRoute::kDetails, id) == details);
  assert(ExtensionManagerRoute::Target(ExtensionManagerRoute::kShortcuts, nullptr) == ExtensionManagerRoute::kShortcutsURL);
  for (const char* bad : {(const char*)nullptr, "", "abc", "ABCDEFGHIJKLMNOPABCDEFGHIJKLMNOP",
                          "abcdefghijklmnopabcdefghijklmnoq", "abcdefghijklmnopabcdefghijklmnop&x=1"}) {
    assert(!ExtensionManagerRoute::Target(ExtensionManagerRoute::kDetails, bad));
  }
  assert(!ExtensionManagerRoute::Target(7, id));

  ExtensionManagerRoute route;
  // Details: only the armed extension, once; then its trusted reload.
  route.Arm(details);
  assert(!route.Allow(std::string(ExtensionManagerRoute::kDetailsPrefix) + "pbcdefghijklmnopabcdefghijklmnop",
                      "https://example.invalid/", false, "GET"));
  assert(!route.Allow(details, "https://example.invalid/", false, "GET"));  // Consumed by the refusal.
  route.Arm(details);
  assert(route.Allow(details, "https://example.invalid/", false, "GET"));
  assert(route.Allow(details, details, false, "GET"));                 // Trusted reload.
  assert(!route.Allow(ExtensionManagerRoute::kURL, details, false, "GET"));  // Another document needs a grant.
  assert(!route.Allow(details, details, false, "GET"));                // Revoked after leaving.
  // The manager grant does not admit details or shortcuts, nor the reverse.
  route.Arm();
  assert(!route.Allow(details, "https://example.invalid/", false, "GET"));
  route.Arm(ExtensionManagerRoute::kShortcutsURL);
  assert(!route.Allow(ExtensionManagerRoute::kURL, "https://example.invalid/", false, "GET"));
  route.Arm(ExtensionManagerRoute::kShortcutsURL);
  assert(route.Allow(ExtensionManagerRoute::kShortcutsURL, "https://example.invalid/", false, "GET"));
  assert(route.Allow(ExtensionManagerRoute::kShortcutsURL, ExtensionManagerRoute::kShortcutsURL, false, "GET"));
  // Redirects and POST never pass, even armed.
  route.Arm(details);
  assert(!route.Allow(details, "https://example.invalid/", true, "GET"));
  route.Arm(details);
  assert(!route.Allow(details, "https://example.invalid/", false, "POST"));
  for (const std::string& variant : {details + "#x", details + "&y=1", details + "/", std::string("chrome://extensions/shortcuts/"),
                                    std::string("chrome://extensions/shortcuts?x")}) {
    route.Arm(details);
    assert(!route.Allow(variant, "https://example.invalid/", false, "GET"));
  }
}
