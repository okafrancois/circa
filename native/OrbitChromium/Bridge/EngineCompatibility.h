#pragma once
// Legacy engine ABI names; remove at next engine rebuild.
// Kept in one file so source patches and product identifiers use the current names.
#define ORBIT_LEGACY_API_SYMBOL "orbit_cef_get_api"
#define ORBIT_LEGACY_ESSENTIALS_SYMBOL "orbit_cef_essentials_level"
#define ORBIT_LEGACY_UNOWNED_SYMBOL "orbit_cef_set_unowned_tab_handler"
#define ORBIT_LEGACY_PINNED_SYMBOL "orbit_cef_extension_set_pinned"
#define ORBIT_LEGACY_SHORTCUT_SYMBOL "orbit_cef_extension_shortcut"
#define ORBIT_LEGACY_DISTRIBUTION "orbit-engine-extensions-r3"
#define ORBIT_LEGACY_PATCH_MARKER "ORBIT_CEF_PATCHES"
#define ORBIT_LEGACY_OWNER_MARKER "orbit-chromium-source-v1"
#ifdef __cplusplus
#include <cstring>
#include <dlfcn.h>
namespace orbit_engine {
inline void* ResolveSymbol(void* handle, const char* current) {
  if (void* symbol = dlsym(handle, current)) return symbol;
  struct Entry { const char* current; const char* legacy; };
  constexpr Entry entries[] = {
      {"orbit_cef_get_api", ORBIT_LEGACY_API_SYMBOL},
      {"orbit_cef_essentials_level", ORBIT_LEGACY_ESSENTIALS_SYMBOL},
      {"orbit_cef_set_unowned_tab_handler", ORBIT_LEGACY_UNOWNED_SYMBOL},
      {"orbit_cef_extension_set_pinned", ORBIT_LEGACY_PINNED_SYMBOL},
      {"orbit_cef_extension_shortcut", ORBIT_LEGACY_SHORTCUT_SYMBOL},
  };
  for (const auto& entry : entries)
    if (std::strcmp(entry.current, current) == 0) return dlsym(handle, entry.legacy);
  return nullptr;
}
}  // namespace orbit_engine
#endif
