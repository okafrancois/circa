// Resolver policy checks without loading or starting a browser.
#include <cassert>
#include <cstring>
#include <dlfcn.h>
#include <map>
#include <string>
#include <vector>

static std::map<std::string, void*> symbols;
static std::vector<std::string> lookups;
static void* TestLookup(void*, const char* name) {
  lookups.push_back(name);
  const auto found = symbols.find(name);
  return found == symbols.end() ? nullptr : found->second;
}
#define dlsym TestLookup
#include "../Bridge/EngineCompatibility.h"
#undef dlsym

int main() {
  int current_value = 1;
  int legacy_value = 2;
  const std::pair<const char*, const char*> contracts[] = {
      {"orbit_cef_get_api", ORBIT_LEGACY_API_SYMBOL},
      {"orbit_cef_essentials_level", ORBIT_LEGACY_ESSENTIALS_SYMBOL},
      {"orbit_cef_set_unowned_tab_handler", ORBIT_LEGACY_UNOWNED_SYMBOL},
      {"orbit_cef_extension_set_pinned", ORBIT_LEGACY_PINNED_SYMBOL},
      {"orbit_cef_extension_shortcut", ORBIT_LEGACY_SHORTCUT_SYMBOL},
  };
  for (const auto& [current, legacy] : contracts) {
    symbols = {{current, &current_value}, {legacy, &legacy_value}};
    lookups.clear();
    assert(orbit_engine::ResolveSymbol(nullptr, current) == &current_value);
    assert(lookups == std::vector<std::string>{current});
    symbols.erase(current);
    lookups.clear();
    assert(orbit_engine::ResolveSymbol(nullptr, current) == &legacy_value);
    assert((lookups == std::vector<std::string>{current, legacy}));
    symbols.clear();
    assert(orbit_engine::ResolveSymbol(nullptr, current) == nullptr);
  }
  lookups.clear();
  assert(orbit_engine::ResolveSymbol(nullptr, "unknown_engine_symbol") == nullptr);
  assert(lookups.size() == 1);
}
