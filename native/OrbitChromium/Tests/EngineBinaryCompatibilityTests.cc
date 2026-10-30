// Read-only API-table check; never initializes CEF, a profile, or a browser.
#include <cassert>
#include <cstddef>
#include <initializer_list>
#include <dlfcn.h>
#include "../Bridge/OrbitCefApi.h"
int main(int argc, char** argv) {
  assert(argc == 2);
  void* handle = dlopen(argv[1], RTLD_LAZY | RTLD_LOCAL);
  assert(handle);
  auto get = reinterpret_cast<orbit_cef_get_api_t>(dlsym(handle, "orbit_cef_get_api"));
  assert(get);
  const auto* api = get(16);
  assert(api && api->version == 16 && api->struct_size >= sizeof(orbit_cef_api_t));
  assert(api->window_created && api->move_tab && api->hold_window && api->extension_selection_changed);
  for (const char* name : {"orbit_cef_essentials_level", "orbit_cef_set_unowned_tab_handler",
                           "orbit_cef_extension_set_pinned", "orbit_cef_extension_shortcut"})
    assert(dlsym(handle, name));
  assert(api->extension_action_snapshot && api->browser_state && api->browser_state_observe);
  assert(api->discard_tab && api->restore_discarded_tab);
  assert(api->password_prompt_observe && api->password_prompt_snapshot && api->password_prompt_decide && api->password_prompt_reopen);
  assert(api->boosts_replace && api->set_automatic_pip);
  assert(get(8) && get(8)->version == 8 && get(8)->struct_size == offsetof(orbit_cef_api_t, set_automatic_pip));
  assert(get(7) && get(7)->version == 7 && get(7)->struct_size == offsetof(orbit_cef_api_t, boosts_replace));
  const size_t prefixes[] = {
      offsetof(orbit_cef_api_t, move_tab), offsetof(orbit_cef_api_t, hold_window),
      offsetof(orbit_cef_api_t, extensions_snapshot), offsetof(orbit_cef_api_t, extension_action_snapshot),
      offsetof(orbit_cef_api_t, discard_tab), offsetof(orbit_cef_api_t, password_prompt_observe),
      offsetof(orbit_cef_api_t, boosts_replace), offsetof(orbit_cef_api_t, set_automatic_pip)};
  for (uint32_t version = 1; version <= 8; ++version) {
    const auto* prefix = get(version);
    assert(prefix && prefix->version == version && prefix->struct_size >= prefixes[version - 1]);
    assert(prefix->window_created == api->window_created && prefix->get_tab_info == api->get_tab_info);
  }
  assert(get(9)->struct_size == offsetof(orbit_cef_api_t, popup_navigation_metadata));
  assert(get(10)->version == 10 && get(10)->struct_size == offsetof(orbit_cef_api_t, password_store_open));
  assert(api->popup_navigation_metadata && api->password_store_open && api->password_store_close);
  assert(api->password_store_list && api->password_store_write && api->password_store_observe);
  assert(get(11)->version == 11 && get(11)->struct_size == offsetof(orbit_cef_api_t, page_lifecycle));
  assert(api->page_lifecycle && api->page_lifecycle_observe && api->capture_view && api->activation_frame);
  assert(get(12)->version == 12 && get(12)->struct_size == offsetof(orbit_cef_api_t, memory_dump));
  assert(api->memory_dump);
  assert(get(13)->struct_size == offsetof(orbit_cef_api_t, permission_accept_once));
  assert(get(14)->struct_size == offsetof(orbit_cef_api_t, media_snapshot));
  assert(get(15)->struct_size == offsetof(orbit_cef_api_t, diagnostic_capabilities));
  assert(api->permission_accept_once && api->security_state && api->navigation_entries && api->media_action);
  assert(api->diagnostic_capabilities && api->task_manager && api->trace_begin && api->trace_end);
  assert(api->extension_options_open && api->extension_incognito_set);
  assert(!get(0) && !get(17));
  dlclose(handle);
}
