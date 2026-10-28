// Copyright 2026 Orbit. BSD-style license; see LICENSE.
// EXT-OUTCOME-R1: tabs that Chrome creates by itself in an Orbit logical Browser
// (an extension's tabs.create, an options page opened in a tab, onboarding).
// Shared C contract between the patched CEF framework
// (libcef/browser/orbit/orbit_unowned_tabs_api.h, cef-patches/unowned-tabs-r1)
// and the bridge. The bridge resolves the single exported symbol
// `orbit_cef_set_unowned_tab_handler` optionally: frameworks without the patch
// keep such tabs without client or view. UI thread only.
#ifndef ORBIT_UNOWNED_TABS_API_H_
#define ORBIT_UNOWNED_TABS_API_H_
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct _cef_client_t;

typedef struct {
  uint32_t struct_size;
  uint64_t window_token;     // Orbit window of the logical Browser.
  const char* profile_path;  // Its profile directory (never NULL or empty).
  const char* url;           // The document being loaded; may be empty.
  int32_t index;             // Tab strip index, -1 when unknown.
  int32_t active;            // 1 foreground, 0 background, -1 unknown.
} orbit_unowned_tab_t;

// Called synchronously before the tab's CEF host is created. Returns a client
// (a new reference that the framework adopts) and, through |parent_nsview|,
// the embedder view the tab is placed in. NULL keeps the tab without client or
// view. Never called after the handler is cleared.
typedef struct _cef_client_t* (*orbit_unowned_tab_handler_t)(
    void* context, const orbit_unowned_tab_t* tab, void** parent_nsview);

// Installs |handler| (NULL clears it). Returns 1 on the UI thread, 0 otherwise.
typedef int32_t (*orbit_cef_set_unowned_tab_handler_t)(
    orbit_unowned_tab_handler_t handler, void* context);

#ifdef __cplusplus
}
#endif

#endif  // ORBIT_UNOWNED_TABS_API_H_
