// Copyright 2026 Orbit. Portions copyright The Chromium Embedded Framework
// Authors. Use of this source code is governed by a BSD-style license that can
// be found in the LICENSE file.
// Orbit side API of the patched CEF (branch orbit/8078). This header is plain C
// and is copied verbatim into the Orbit bridge; it is not part of the public
// CEF API (cef/include is unchanged, so no translator.py and no API hash).
// The bridge resolves the single exported symbol `orbit_cef_get_api` with
// dlsym() on the loaded framework. A stock CEF build does not export it, which
// is how the bridge tells the two apart (ACRPatchLevel() == 0).
// Threading: every function must be called on the CEF UI thread (the main
// thread on macOS) after CefInitialize() and before CefShutdown().

#ifndef CEF_LIBCEF_BROWSER_ORBIT_ORBIT_CEF_API_H_
#define CEF_LIBCEF_BROWSER_ORBIT_ORBIT_CEF_API_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Version 1 (ENG-X2.1): one logical Chrome Browser per (Orbit window, profile),
// Chrome-style tabs whose content NSView is placed by Orbit.
// Version 2 (CHROMIUM-APP-R2): additive, move_tab. A table requested as version
// 1 reports version 1 and keeps the version 1 layout as its prefix.
// Version 3 (CHROMIUM-APP-R3): additive, hold_window/release_window. Earlier
// versions keep their layout as the prefix of the table.
// Version 4 (EXTENSIONS-PRODUCT-R1): additive, native per-profile extension services.
#define ORBIT_CEF_API_VERSION 7u

typedef struct {
  uint32_t struct_size;
  int32_t audible;
  int32_t muted;
  uint32_t colors;  // bit 0 theme, bit 1 background; colors are unpremultiplied ARGB.
  uint32_t theme_color;
  uint32_t background_color;
} orbit_browser_state_t;

typedef struct {
  uint32_t struct_size;
  // Extension tab id (SessionTabHelper), -1 when the tab has none.
  int32_t tab_id;
  // Extension window id (SessionID of the logical Browser), -1 when the tab is
  // not in a Browser.
  int32_t window_id;
  // Index in the Browser's TabStripModel, -1 when absent.
  int32_t index;
  // 1 when the tab is the active tab of its Browser.
  int32_t active;
  // 1 when the browser is an Orbit hosted Chrome-style tab.
  int32_t hosted;
  // Orbit window token of the Browser, 0 when none.
  uint64_t window_token;
} orbit_tab_info_t;

// Version 7. Dedicated password metadata, borrowed for the callback/query only.
// Password bytes are never exposed. Generations are unique for the runtime.
typedef struct {
  uint32_t struct_size;
  uint32_t version;
  int32_t browser_id;
  int32_t state;  // 0 none, 1 pending save, 2 pending update, 3 generated autosave.
  uint64_t generation;
  const char* profile_path;
  const char* origin;
  const char* username;
  int32_t password_masked;
  int32_t can_reopen;
} orbit_password_prompt_t;
// event: 1 show, 2 hide, 3 state changed. Never sent through generic events.
typedef void (*orbit_password_prompt_callback_t)(void*, int32_t, const orbit_password_prompt_t*);

typedef struct {
  uint32_t struct_size;
  uint32_t version;

  // Registers an Orbit window. `nswindow` is a borrowed NSWindow* that must
  // outlive the registration (call window_destroyed before releasing it).
  // Returns 1 on success, 0 if the token is in use or invalid.
  int32_t (*window_created)(uint64_t window_token, void* nswindow);
  // Unregisters an Orbit window. Logical Browsers that still own tabs lose
  // their native window and close when their last tab closes. Returns the
  // number of logical Browsers that were still alive, or -1 if unknown.
  int32_t (*window_destroyed)(uint64_t window_token);
  // Key-window state: DidBecomeActive/DidBecomeInactive on every logical
  // Browser of the window (windows.onFocusChanged). Returns 1 if known.
  int32_t (*window_activation_changed)(uint64_t window_token, int32_t active);
  // Notifies extension listeners of new window bounds
  // (windows.onBoundsChanged). Returns 1 if known.
  int32_t (*window_bounds_changed)(uint64_t window_token);

  // Marks `parent_nsview` so that the next CefBrowserHost::CreateBrowser[Sync]
  // or OnBeforePopup whose CefWindowInfo.parent_view equals it creates a
  // Chrome-style tab at `index` (-1 appends) in the logical Browser of
  // (window_token, request context profile). The mark is consumed by that
  // creation. Returns 1 when registered.
  int32_t (*prepare_hosted_tab)(void* parent_nsview,
                                uint64_t window_token,
                                int32_t index);
  // Removes a mark that was not consumed. Returns 1 if a mark was removed.
  int32_t (*cancel_hosted_tab)(void* parent_nsview);

  // Moves the content NSView of a hosted tab under `parent_nsview` (same
  // logical Browser). Returns 1 on success.
  int32_t (*attach_view)(int32_t browser_id, void* parent_nsview);
  // Activates a hosted tab in its TabStripModel (tabs.onActivated).
  int32_t (*activate_tab)(int32_t browser_id);
  // Fills `info` for any CEF browser id. Returns 1 when the browser exists.
  int32_t (*get_tab_info)(int32_t browser_id, orbit_tab_info_t* info);

  // Diagnostics: live logical Browsers of a window (all profiles), or -1.
  int32_t (*window_browser_count)(uint64_t window_token);

  // Version 2. Moves a hosted tab to `index` (-1 or past the end appends) of
  // the logical Browser of (window_token, the tab's profile), created when
  // needed, through TabStripModel::DetachTabAtForInsertion and
  // InsertDetachedTabAt (the path of tabs.move and of Chrome's tab dragging).
  // The WebContents, CEF browser and browser id, extension tab id, opener,
  // history, form and script state are kept; extensions see tabs.onDetached
  // and tabs.onAttached. The source logical Browser closes with its last tab.
  // When the tab already is in that Browser, it is reordered to `index`
  // instead (tabs.onMoved). Then, when `parent_nsview` is not NULL, the
  // content NSView is placed under it. Never activates the tab. Returns 1 on
  // success; 0, with nothing changed, when the browser is not a hosted tab of
  // a logical Browser, is closing, or the window is unknown.
  int32_t (*move_tab)(int32_t browser_id,
                      uint64_t window_token,
                      int32_t index,
                      void* parent_nsview);
  // Version 2. 1 while Chrome's ProfileManager still has a loaded Profile for
  // the absolute profile directory `path` (it unloads it after the last
  // CefRequestContext and browser of the profile are gone), 0 when none is
  // loaded, -1 when unknown. Never loads a profile. Lets a profile directory be
  // removed only once Chrome no longer writes to it.
  int32_t (*profile_loaded)(const char* path);

  // Version 3. Holds the logical Browsers of an Orbit window for a tab transfer:
  // while held, a Browser whose last tab moved away stays alive (same window
  // id) so that a rollback can return the tab to it; releasing the last hold
  // closes those still empty. Returns the hold count after the call, -1 for an
  // unknown (or, for release, unheld) window. Destroying the window releases
  // every hold.
  int32_t (*hold_window)(uint64_t window_token);
  int32_t (*release_window)(uint64_t window_token);
  // Version 4 (EXTENSIONS-PRODUCT-R1). Paths come only from the embedder's
  // admitted request contexts. Never loads a Profile; refuses off-the-record.
  // Snapshot: UTF-8 JSON, returns required bytes excluding NUL, -1 unavailable.
  // A buffer is written only when capacity exceeds the returned size.
  int32_t (*extensions_snapshot)(const char* profile_path, char* json, uint32_t capacity);
  // enabled must be 0 or 1. Chrome's registrar enforces policy/permission state.
  int32_t (*extension_set_enabled)(const char* profile_path, const char* id, int32_t enabled);
  // Caller must obtain a native user confirmation first. 1 means accepted,
  // not completion of asynchronous site data removal.
  int32_t (*extension_remove)(const char* profile_path, const char* id);
  // One subscription per profile path; callback is synchronous on the UI thread.
  // Null callback unregisters. Shutdown of the registry revokes observation.
  int32_t (*extensions_observe)(const char* profile_path,
                               void (*changed)(void*), void* context);
  // Version 4. Native user action only. Anchor must belong to this hosted
  // tab's shell window; no URLs or script supplied by the caller. 1 accepted,
  // 0 refused, -2 side panel requested (not yet hosted by this adapter).
  int32_t (*extension_action)(int32_t browser_id, const char* id, void* anchor_nsview,
                              uint64_t invocation, uint64_t surface_token,
                              uint64_t profile_token, uint64_t selection_epoch);
  // Unpublished v4, R2: publish exact shell selection before invoking an action.
  // browser_id -1 revokes selection. Epochs never repeat during this runtime.
  int32_t (*extension_selection_changed)(uint64_t window_token, int32_t browser_id,
                                        uint64_t surface_token, uint64_t profile_token,
                                        uint64_t selection_epoch);
  // Idempotent; revokes before notifying the popup, including before first load.
  void (*extension_cancel)(uint64_t invocation);
  // Version 5. Effective per-tab action values plus defaults, using the inventory JSON schema.
  int32_t (*extension_action_snapshot)(int32_t browser_id, char* json, uint32_t capacity);
  // Snapshot and one UI-thread subscription per browser. Null callback unregisters.
  int32_t (*browser_state)(int32_t browser_id, orbit_browser_state_t* state);
  int32_t (*browser_state_observe)(int32_t browser_id, void (*changed)(void*, const orbit_browser_state_t*), void* context);
  // Version 6. In-place WebContents discard preserves NavigationController and page state.
  // Returns 1 when accepted, 0 on an invalid/busy tab. Restore loads only if necessary;
  // Chromium's history navigation uses cache-only recovery for POST entries.
  int32_t (*discard_tab)(int32_t browser_id);
  int32_t (*restore_discarded_tab)(int32_t browser_id);
  // Version 7. Exact admitted profile path is required; off-record is refused.
  // Null callback disables presentation without declining a pending credential.
  int32_t (*password_prompt_observe)(int32_t, const char*, orbit_password_prompt_callback_t, void*);
  int32_t (*password_prompt_snapshot)(int32_t, const char*, orbit_password_prompt_t*);
  // One shot per generation. 1 save/update, 2 never (save only), 3 not now/nope update.
  int32_t (*password_prompt_decide)(int32_t, const char*, uint64_t, int32_t);
  int32_t (*password_prompt_reopen)(int32_t, const char*, uint64_t);
} orbit_cef_api_t;

// Returns the API table for `version`, or NULL when unsupported.
typedef const orbit_cef_api_t* (*orbit_cef_get_api_t)(uint32_t version);

#ifdef __cplusplus
}
#endif

#endif  // CEF_LIBCEF_BROWSER_ORBIT_ORBIT_CEF_API_H_
