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
#define ORBIT_CEF_API_VERSION 16u

// Version 8. Callback once after live renderer CSS installation (1), or failure (0).
typedef void (*orbit_boost_ack_t)(void*, uint64_t revision, int32_t installed);

// Version 10. Metadata only, never request body bytes. Unknown outside the
// synchronous popup decision; all strings are borrowed for that call.
// v16: callback once on UI after an accepted operation. Path bytes are borrowed;
// begin reports an empty path. A refused call returns 0 and never calls back.
typedef void (*orbit_trace_callback_t)(void*, int32_t success, const char* path);

typedef struct {
  uint32_t struct_size;
  uint32_t transition_type;
  const char* method;
  int32_t has_body;
} orbit_navigation_metadata_t;

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
// JSON and origin strings are borrowed for the callback only. UI thread.
typedef void (*orbit_json_changed_t)(void*, const char*, uint32_t);
typedef void (*orbit_fullscreen_changed_t)(void*, int32_t entered, const char* origin);

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

// Version 11. Profile password store only. Borrowed strings/arrays are valid only
// during the call/callback; no secret is sent through generic event diagnostics.
// UTF-16 spans preserve embedded NULs. Times are microseconds since 1601 UTC,
// including Chromium's zero (unset). The stable key is the five identity fields
// below, not a local database row number; it changes when those fields change.
typedef struct { const uint16_t* data; uint32_t count; } orbit_password_text_t;
typedef struct {
  uint32_t struct_size;
  const char* signon_realm;
  const char* origin_url;
  const char* action_url;
  orbit_password_text_t username_element;
  orbit_password_text_t username_value;
  orbit_password_text_t password_element;
  orbit_password_text_t password_value;
  int64_t date_created;
  int64_t date_last_used;
  int64_t date_password_modified;
  int32_t blocked_by_user;
  int32_t scheme;
} orbit_password_record_t;
// status: 1 success, -1 backend/verification error, -2 cancelled by close/profile
// teardown, -3 conflict (add existing/update missing/target key occupied).
// Accepted requests complete exactly once on the UI thread. Refused calls
// return 0 and do not invoke completion. Writes return no rows.
typedef void (*orbit_password_result_t)(void*, int32_t status,
    const orbit_password_record_t* records, uint32_t count);
// event: 1 changed, 2 retained (resnapshot in either case), 3 closed.
// Carries no secrets. One subscription per opened handle; close revokes it.
typedef void (*orbit_password_changed_t)(void*, int32_t event);

// Version 12. UI-thread reads and coalesced observation. Unknown PM state
// returns 0 (never an all-safe snapshot). Capture bits:
// video/audio/mirror/tab/window/display.
typedef struct {
  uint32_t struct_size;
  int32_t playing_media, playing_video, audio_context_running, audible, pip;
  uint32_t capturing;
  int32_t had_form_interaction, had_user_edits, web_lock, idb_lock, webrtc;
  int32_t lifecycle;  // 0 running, 1 frozen, 2 discarded
  uint64_t cannot_discard_mask, footprint_kb;
  int32_t renderer_pid;
  uint64_t document_id;
} orbit_page_lifecycle_t;
// event: 0 state changed, 1 about to discard, 2 discarded, 3 closed.
// initiator: 0 none, 1 embedder, 2 native policy. Null state only for closed.
typedef void (*orbit_lifecycle_callback_t)(void*,
                                           int32_t event,
                                           int32_t initiator,
                                           const orbit_page_lifecycle_t*);
typedef struct {
  int32_t x, y, width, height;
} orbit_capture_rect_t;
// status: 1 captured, -1 unavailable, -2 closed, -3 timed out,
// -4 document changed. Borrowed tightly packed premultiplied BGRA, sRGB (1).
typedef void (*orbit_capture_callback_t)(void*,
                                         int32_t status,
                                         int32_t width,
                                         int32_t height,
                                         uint32_t row_bytes,
                                         const uint8_t* bgra,
                                         int32_t color_space);
// status: 1 submitted, 2 document_changed (also superseded activation),
// 3 hidden, 4 closed, 5 timed_out. Ticks are monotonic microseconds, only on
// submitted.
typedef void (*orbit_activation_callback_t)(void*,
                                            int32_t browser_id,
                                            uint64_t activation_id,
                                            uint64_t document_id,
                                            int32_t status,
                                            int64_t submitted_ticks_us);

// JSON is borrowed until return. Status: 1 complete, 2 partial, -1 unavailable.
// Allocator nodes contain native numeric metrics; absent metrics are unknown.
typedef void (*orbit_memory_callback_t)(void*, int32_t status, const char* json, uint32_t length);

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
  // Atomic profile snapshot, omitted IDs are removed; empty list retains a tombstone.
  // Strictly monotonic generations; identical retries are accepted. Private profiles refused.
  int32_t (*boosts_replace)(const char*, const char*, uint64_t, orbit_boost_ack_t, void*);
  // Version 9. Scope browser-initiated automatic video PiP to the embedder's
  // isolated-world request. Clear after completion or failure. No active PiP
  // may exist when setting the flag; manual requests use the default false.
  int32_t (*set_automatic_pip)(int32_t browser_id, int32_t automatic);
  // Version 10. OnBeforePopup only, matched to the opener browser and frame.
  // Returns 1 when known, 0 otherwise. Does not retain or replay the request.
  int32_t (*popup_navigation_metadata)(int32_t browser_id, const char* frame_id,
                                      orbit_navigation_metadata_t* metadata);
  // Version 11. Opens only an already-loaded regular profile, never loads it.
  uint64_t (*password_store_open)(const char* profile_path);
  void (*password_store_close)(uint64_t handle);
  int32_t (*password_store_list)(uint64_t, orbit_password_result_t, void*);
  // operation: 1 add, 2 update, 3 remove. Update uses old_key (required),
  // preserving Chromium metadata outside this API. Remove uses old_key only.
  // Invalid sizes/URLs/schemes and private contexts fail closed.
  int32_t (*password_store_write)(uint64_t, int32_t operation,
      const orbit_password_record_t* record, const orbit_password_record_t* old_key,
      orbit_password_result_t, void*);
  int32_t (*password_store_observe)(uint64_t, orbit_password_changed_t, void*);
  // Version 12. Null observer revokes; accepted async calls complete once on
  // UI.
  int32_t (*page_lifecycle)(int32_t, orbit_page_lifecycle_t*);
  int32_t (*page_lifecycle_observe)(int32_t, orbit_lifecycle_callback_t, void*);
  int32_t (*capture_view)(int32_t,
                          orbit_capture_rect_t,
                          int32_t out_width,
                          int32_t out_height,
                          int32_t timeout_ms,
                          orbit_capture_callback_t,
                          void*);
  // activation_id 0 with null callback announces close and cancels pending work
  // as closed.
  int32_t (*activation_frame)(int32_t,
                              uint64_t activation_id,
                              orbit_activation_callback_t,
                              void*);
  // Version 13. Read-only background global dump, no tracing or forced GC.
  // UI only; returns 0 without callback if refused, 1 with exactly one callback.
  int32_t (*memory_dump)(orbit_memory_callback_t, void*);
  // Version 14. Match an outstanding native prompt by browser and prompt ID.
  // Unsupported one-time permission kinds fail closed (return 0, no grant).
  int32_t (*permission_accept_once)(int32_t browser_id, uint64_t prompt_id);
  // JSON reads return required bytes, -1 unavailable. Write only if capacity > bytes.
  int32_t (*security_state)(int32_t browser_id, char*, uint32_t);
  int32_t (*security_observe)(int32_t, orbit_json_changed_t, void*);
  // scheme: 0 show, 1 omit HTTP/HTTPS, 2 omit cryptographic. Invalid input fails.
  int32_t (*security_display)(const char* url, int32_t scheme, char*, uint32_t);
  int32_t (*committed_url)(int32_t, char*, uint32_t);
  int32_t (*fullscreen_observe)(int32_t, orbit_fullscreen_changed_t, void*);
  int32_t (*navigation_entries)(int32_t, char*, uint32_t);
  int32_t (*navigation_go_index)(int32_t, int32_t index);
  // Version 15. Per-browser native MediaSession. Artwork contains URLs, not pixels.
  int32_t (*media_snapshot)(int32_t, char*, uint32_t);
  int32_t (*media_observe)(int32_t, orbit_json_changed_t, void*);
  // action: 0 play, 1 pause, 2 seek (seconds), 3 next, 4 previous.
  int32_t (*media_action)(int32_t, int32_t action, double seconds);

  // v16. Bitmask: 1 task manager, 2 tracing, 4 extension options, 8 incognito prefs.
  uint32_t (*diagnostic_capabilities)(void);
  int32_t (*task_manager)(int32_t browser_id);
  // Tracing is process-wide; one persistent profile owns a session through completion.
  // Destination must be a new file in an existing directory under that profile.
  int32_t (*trace_begin)(const char* profile_path, const char* categories, orbit_trace_callback_t, void*);
  int32_t (*trace_end)(const char* profile_path, const char* file, orbit_trace_callback_t, void*);
  int32_t (*extension_options_open)(int32_t browser_id, const char* extension_id);
  int32_t (*extension_incognito_set)(const char* profile_path, const char* extension_id, int32_t allowed);
} orbit_cef_api_t;

// Returns the API table for `version`, or NULL when unsupported.
typedef const orbit_cef_api_t* (*orbit_cef_get_api_t)(uint32_t version);

#ifdef __cplusplus
}
#endif

#endif  // CEF_LIBCEF_BROWSER_ORBIT_ORBIT_CEF_API_H_
