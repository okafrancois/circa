// Copyright 2026 Orbit. BSD-style license; see LICENSE.
// The only bridge translation unit on the wrapper side of the C API: it converts a client
// exactly as libcef_dll_wrapper does for cef_browser_host_create_browser.
#define WRAPPING_CEF_SHARED
#include "OrbitClientWrap.h"
#include "libcef_dll/cpptoc/client_cpptoc.h"

namespace orbit_bridge {
struct _cef_client_t* WrapClientForFramework(CefRefPtr<CefClient> client) {
  return client ? CefClientCppToC_Wrap(client) : nullptr;
}
}  // namespace orbit_bridge
