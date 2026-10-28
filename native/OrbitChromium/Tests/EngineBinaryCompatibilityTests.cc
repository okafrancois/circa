// Read-only API-table check; never initializes CEF, a profile, or a browser.
#include <cassert>
#include <initializer_list>
#include <dlfcn.h>
#include "../Bridge/EngineCompatibility.h"
#include "../Bridge/OrbitCefApi.h"
int main(int argc, char** argv) {
  assert(argc == 2);
  void* handle = dlopen(argv[1], RTLD_LAZY | RTLD_LOCAL);
  assert(handle);
  auto get = reinterpret_cast<orbit_cef_get_api_t>(orbit_engine::ResolveSymbol(handle, "orbit_cef_get_api"));
  assert(get);
  const auto* api = get(4);
  assert(api && api->version == 4 && api->struct_size >= sizeof(orbit_cef_api_t));
  assert(api->window_created && api->move_tab && api->hold_window && api->extension_selection_changed);
  for (const char* name : {"orbit_cef_essentials_level", "orbit_cef_set_unowned_tab_handler",
                           "orbit_cef_extension_set_pinned", "orbit_cef_extension_shortcut"})
    assert(orbit_engine::ResolveSymbol(handle, name));
  dlclose(handle);
}
