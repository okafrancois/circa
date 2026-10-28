#ifndef ORBIT_HELPER_WEB_STORE_COMPATIBILITY_H_
#define ORBIT_HELPER_WEB_STORE_COMPATIBILITY_H_

#include "include/cef_app.h"
#include "include/cef_parser.h"
#include "include/cef_render_process_handler.h"

namespace orbit_bridge {

// The Store's October 2026 client uses the server's Chrome-brand eligibility
// bit on Chromium >= 142, even when its real native installation APIs exist.
// Supply the embedder's capability for that bit, without impersonating Chrome
// in HTTP headers or changing version, extension policy, or install prompts.
inline constexpr char kWebStoreCompatibilityScript[] = R"ORBITJS(
(() => {
  let values;
  Object.defineProperty(window, 'IJ_values', {
    configurable: true,
    enumerable: true,
    get() { return values; },
    set(next) {
      values = next;
      const api = window.chrome;
      if (Array.isArray(next) && next.length === 56 &&
          typeof next[24] === 'boolean' &&
          next[6] === 'chromewebstore.google.com' &&
          api && api.management && api.webstorePrivate &&
          typeof api.webstorePrivate.beginInstallWithManifest3 === 'function' &&
          typeof api.webstorePrivate.completeInstall === 'function') {
        next[24] = true;
      }
    }
  });
})();
)ORBITJS";

class RendererApp final : public CefApp, public CefRenderProcessHandler {
 public:
  CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override { return this; }

  void OnContextCreated(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                        CefRefPtr<CefV8Context> context) override {
    if (!frame || !frame->IsMain()) return;
    CefURLParts parts;
    if (!CefParseURL(frame->GetURL(), parts) ||
        CefString(&parts.scheme) != "https" ||
        CefString(&parts.host) != "chromewebstore.google.com" ||
        (!CefString(&parts.port).empty() && CefString(&parts.port) != "443")) return;
    CefRefPtr<CefV8Value> result;
    CefRefPtr<CefV8Exception> exception;
    context->Eval(kWebStoreCompatibilityScript, frame->GetURL(), 0, result, exception);
  }

 private:
  IMPLEMENT_REFCOUNTING(RendererApp);
};

}  // namespace orbit_bridge

#endif  // ORBIT_HELPER_WEB_STORE_COMPATIBILITY_H_
