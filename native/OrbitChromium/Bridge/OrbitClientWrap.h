// Copyright 2026 Orbit. BSD-style license; see LICENSE.
#ifndef ORBIT_CLIENT_WRAP_H_
#define ORBIT_CLIENT_WRAP_H_
#include "include/cef_client.h"

struct _cef_client_t;

namespace orbit_bridge {
// EXT-OUTCOME-R1: the C structure of |client| for a framework entry point that adopts it (a
// new reference), as the wrapper itself does when it passes a client to CreateBrowser.
struct _cef_client_t* WrapClientForFramework(CefRefPtr<CefClient> client);
}  // namespace orbit_bridge

#endif
