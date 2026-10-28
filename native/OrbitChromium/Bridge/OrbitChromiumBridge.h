#ifndef ORBIT_CHROMIUM_BRIDGE_H
#define ORBIT_CHROMIUM_BRIDGE_H

#include <stddef.h>
#include <stdint.h>
#include "OrbitAuthenticationABI.h"
#include "OrbitCefApi.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ABI 9 (CH-ESSENTIALS) is additive over ABI 8: page-initiated browser surfaces that Chrome
 * would otherwise draw with Views (absent in hosted mode, where its defaults crash or show
 * nothing): JavaScript dialogs and beforeunload, HTTP authentication, file choosers, page context
 * menus, element fullscreen, unresponsive and terminated renderers, plus DevTools, print and a
 * beforeunload-aware close. See the "ABI 9" section at the end and
 * docs/native-port/ch-essentials-2026-10-25.md.
 *
 * ABI 8 (CHROMIUM-APP-R2) is additive over ABI 7: ACRRunOptions.network_policy chooses the
 * browser switches (hermetic for automated runs, product for the signed daily build), and the
 * patched CEF side API v2 adds ACRMoveSurfaceToWindow.
 *
 * ABI 7 (CHROMIUM-APP) is additive over ABI 6 for the product build of Orbit:
 * secure storage chosen by configuration (ACRRunOptions.secure_storage),
 * navigation metadata in decide_navigation (ACRNavigationInfo), page-first
 * keyboard callbacks (decide_key / unhandled_key, CefKeyboardHandler) and an
 * application termination that asks the NSApplication delegate before quitting
 * the runtime (see ACRRun). ABI 6 and ABI 5 semantics are unchanged otherwise.
 *
 * ABI 6 adds, without changing ABI 5 semantics, the hosted Chrome mode of the
 * patched CEF (ENG-X2, branch orbit/8078): see the "ABI 6" section at the end.
 *
 * ABI 5: surface-oriented bridge for the stock (unpatched) CEF 156 SDK.
 *
 * Every browser is an Alloy-style child of an AppKit NSView supplied by the
 * shell (CefWindowInfo::SetAsChild forces Alloy, see cef_types_mac.h). The
 * shell owns windows and layout; the bridge never creates or closes NSWindows.
 *
 * Threading: on macOS the CEF UI thread is the main thread. Every function is
 * main-thread only and executes synchronously on it; callbacks arrive on the
 * main thread. Tokens are chosen by the shell and are opaque to CEF:
 * browser_id is a CEF host identifier, never an extension tabId. */
#define ACR_ABI_VERSION 11u

typedef enum {
  ACR_EVENT_READY = 1,          /* OnContextInitialized: profiles/surfaces may be created */
  ACR_EVENT_PROFILE_READY,      /* request context initialized (profile_token) */
  ACR_EVENT_CREATED,            /* browser attached; value = runtime style (1 alloy, 2 chrome) */
  ACR_EVENT_ADDRESS,            /* main-frame address; url; (ABI 7) value 1 for a same-document navigation */
  ACR_EVENT_TITLE,              /* title */
  ACR_EVENT_LOADING,            /* value = loading; flags bit0 back, bit1 forward */
  ACR_EVENT_DOCUMENT,           /* main frame committed (OnLoadStart); url, generation */
  ACR_EVENT_LOAD_END,           /* main frame finished; value = HTTP status */
  ACR_EVENT_LOAD_ERROR,         /* main frame failed; value = net error code */
  ACR_EVENT_FAVICON,            /* exact metadata URL or null; optional bounded owned PNG payload */
  ACR_EVENT_AUDIO,              /* value = audible (media access/audio state); flags bit0 video, bit1 audio capture */
  ACR_EVENT_CLOSE_REQUEST,      /* DoClose for a browser the shell did not close (window.close) */
  ACR_EVENT_CLOSED,             /* OnBeforeClose: the browser no longer exists */
  ACR_EVENT_FIND_RESULT,        /* request_id = native find id; value = count; flags = ordinal; final in detail_code */
  ACR_EVENT_NAVIGATION_POLICY,  /* laboratory hold (async_navigation_hold): request_id must be answered
                                 * with ACRResolveNavigationPolicy; network-backed main-frame loads only */
  ACR_EVENT_PERMISSION,         /* request_id must be answered with ACRResolvePermission */
  ACR_EVENT_DOWNLOAD,           /* download_* fields; request_id nonzero when a destination is needed */
  ACR_EVENT_DEVTOOLS_RESULT,    /* request_id = message id; value = success; payload = JSON bytes */
  ACR_EVENT_RENDER_TERMINATED,  /* value = termination status */
  ACR_EVENT_SHUTDOWN,
  ACR_EVENT_FAILURE,
  ACR_EVENT_COOKIE_RESULT,      /* request_id; value = success; detail = cookie value or null */
  ACR_EVENT_CREATE_ABORTED,     /* (ABI 5) a pending browser will never exist: popup creation failed
                                 * (OnBeforePopupAborted), its opener closed during creation, or the
                                 * bridge refused it; detail = reason. No CREATED or CLOSED follows. */
  /* ABI 9 (CH-ESSENTIALS). Requests carry a request_id answered once with their ACRResolve*
   * function; the bridge drops them, unanswered, when their browser closes or the run quits. */
  ACR_EVENT_JS_DIALOG,          /* request_id; value = 0 alert, 1 confirm, 2 prompt, 3 beforeunload;
                                 * url = origin URL (alert/confirm/prompt) or NULL; detail = message;
                                 * title = default prompt text; flags bit0 = beforeunload for a reload */
  ACR_EVENT_JS_DIALOG_RESET,    /* OnResetDialogState: pending dialogs of the surface were dropped */
  ACR_EVENT_AUTH,               /* request_id; payload = JSON {origin, host, port, realm, scheme, proxy} */
  ACR_EVENT_FILE_DIALOG,        /* request_id; payload = JSON {mode, title, defaultPath, acceptTypes,
                                 * acceptExtensions} (mode 0 open, 1 multiple, 2 folder, 3 save) */
  ACR_EVENT_CONTEXT_MENU,       /* request_id; payload = JSON of CefContextMenuParams and the Chrome
                                 * commands offered for it ({name: command id}) */
  ACR_EVENT_FULLSCREEN,         /* value = 1 entered, 0 left element fullscreen (OnFullscreenModeChange) */
  ACR_EVENT_UNRESPONSIVE,       /* value = 1 renderer unresponsive (answer with ACRResolveUnresponsive),
                                 * 0 responsive again */
  ACR_EVENT_CLOSE_CANCELED,     /* the user stayed on a page asked to close by ACRRequestClose */
  ACR_EVENT_EXTENSIONS_CHANGED, /* ABI 10: profile_token only */
  ACR_EVENT_ACTIVATION_REQUEST, /* CefFocusHandler FOCUS_SOURCE_SYSTEM; exact surface_token */
  ACR_EVENT_MEDIA_ACTIVITY,     /* method in detail; CDP WebAudio/Media metadata in payload */
  ACR_EVENT_BROWSER_STATE       /* orbit_browser_state_t payload: native audibility, mute and page colors */
} ACREventKind;

typedef enum {
  ACR_POLICY_ALLOW = 0,
  ACR_POLICY_CANCEL = 1,
  /* Cancels the navigation and asks Chromium to download the same URL with
   * StartDownload: a new GET request, not a conversion of the navigation. */
  ACR_POLICY_DOWNLOAD = 2
} ACRNavigationPolicy;

typedef enum {
  ACR_PERMISSION_DEFAULT = 0,
  ACR_PERMISSION_GRANT = 1,
  ACR_PERMISSION_DENY = 2
} ACRPermissionDecision;

typedef enum {
  ACR_DOWNLOAD_CANCEL = 1,
  ACR_DOWNLOAD_PAUSE,
  ACR_DOWNLOAD_RESUME
} ACRDownloadAction;

typedef enum {
  ACR_DOWNLOAD_PENDING = 0,
  ACR_DOWNLOAD_IN_PROGRESS,
  ACR_DOWNLOAD_COMPLETE,
  ACR_DOWNLOAD_CANCELED,
  ACR_DOWNLOAD_INTERRUPTED
} ACRDownloadStatus;

/* Borrowed payload, valid only during the callback. Copy immediately. */
typedef struct {
  uint32_t struct_size;
  ACREventKind kind;
  uint64_t surface_token;
  uint64_t profile_token;
  int32_t browser_id;
  int32_t value;
  int32_t flags;
  int32_t detail_code;
  uint64_t request_id;
  uint64_t document_generation;
  const char *url;
  const char *title;
  const char *detail;
  /* Navigation policy / popup / permission metadata. */
  int32_t is_main_frame;
  int32_t user_gesture;
  int32_t disposition;
  uint32_t permission_mask;
  /* Download metadata (ACR_EVENT_DOWNLOAD). */
  uint32_t download_id;
  ACRDownloadStatus download_status;
  int32_t download_paused;
  int32_t download_interrupt_reason;
  int64_t received_bytes;
  int64_t total_bytes;
  const char *download_path;
  const char *suggested_name;
  /* DevTools result bytes, or owned PNG bytes for ACR_EVENT_FAVICON. Copied during callback. */
  const void *payload;
  size_t payload_size;
} ACREvent;

/* Synchronous decision used by OnBeforePopup. Return the NSView (bridged
 * pointer) that will parent the new browser and set *surface_token, or return
 * NULL to refuse. The popup keeps its opener and its source request context. */
/* source_kind: 1 = OnBeforePopup (CEF creates the browser, opener kept),
 * 2 = OnOpenURLFromTab (the bridge creates a new browser: fresh request, no opener). */
typedef void *(*ACRDecideNewSurface)(void *context, uint64_t source_surface_token,
                                     const char *url, int32_t disposition,
                                     int32_t user_gesture, int32_t source_kind,
                                     uint64_t *surface_token);

/* (ABI 7) The request of an OnBeforeBrowse question. Borrowed, valid during
 * the callback only. */
typedef struct {
  uint32_t struct_size;
  const char *url;
  int32_t is_main_frame;
  int32_t user_gesture;
  int32_t is_redirect;
  /* CefRequest::GetTransitionType(): source in the low byte (TT_LINK 0,
   * TT_EXPLICIT 1, TT_AUTO_SUBFRAME 3, TT_MANUAL_SUBFRAME 4, TT_FORM_SUBMIT 7,
   * TT_RELOAD 8) and qualifier flags (TT_FORWARD_BACK_FLAG 0x01000000,
   * TT_DIRECT_LOAD_FLAG 0x02000000, TT_CLIENT_REDIRECT_FLAG 0x40000000,
   * TT_SERVER_REDIRECT_FLAG 0x80000000). */
  uint32_t transition_type;
  /* CefRequest::GetMethod(), upper case; NULL when empty. */
  const char *method;
  /* 1 when the request carries post data, 0 when it carries none. */
  int32_t has_body;
} ACRNavigationInfo;

/* Synchronous navigation decision from CefRequestHandler::OnBeforeBrowse
 * (UI thread, cef_request_handler.h:80). Return an ACRNavigationPolicy. The
 * stock SDK cannot suspend this callback; an asynchronous shell decision
 * would deadlock the UI thread or require cancel-and-replay. */
typedef int32_t (*ACRDecideNavigation)(void *context, uint64_t surface_token,
                                       const ACRNavigationInfo *info);

/* (ABI 7) A key event of a surface, from CefKeyboardHandler. Borrowed, valid
 * during the callback only. */
typedef struct {
  uint32_t struct_size;
  uint64_t surface_token;
  /* Bridge correlation id of one key down, the same in decide_key and
   * unhandled_key; never reused. */
  uint64_t key_id;
  /* The NSEvent (CefEventHandle), borrowed; NULL when CEF has none. */
  void *ns_event;
  int32_t type;             /* cef_key_event_type_t */
  uint32_t modifiers;       /* cef_event_flags_t */
  int32_t windows_key_code;
  int32_t native_key_code;
  int32_t focus_on_editable_field;
} ACRKeyEvent;

/* (ABI 7) CefKeyboardHandler::OnPreKeyEvent, before the renderer, for raw key
 * downs only. Return 1 when the browser consumes the key (the page never sees
 * it). Return 0 to send it to the page; set *track to 1 to receive
 * unhandled_key if the page does not handle it (a page-first shortcut
 * candidate: CEF is told is_keyboard_shortcut). */
typedef int32_t (*ACRDecideKey)(void *context, const ACRKeyEvent *event, int32_t *track);

/* (ABI 7) CefKeyboardHandler::OnKeyEvent for a tracked key the page declined.
 * Return 1 when the shell handled it. Either way the bridge reports the key as
 * handled to CEF, so that no second dispatch (the Alloy or OrbitBrowserWindow
 * fallback to [NSApp mainMenu] performKeyEquivalent:) runs on a target that may
 * have changed meanwhile. Untracked keys keep CEF's default handling. */
typedef int32_t (*ACRUnhandledKey)(void *context, const ACRKeyEvent *event);

/* (ABI 11, EXT-OUTCOME-R1) A tab Chrome creates by itself in the logical Browser of
 * (window_token, profile_token): an extension's tabs.create, an options page opened in a tab,
 * onboarding after an install. Called synchronously on the main thread, before the tab's CEF
 * browser exists, only with a patched framework that offers such tabs. Return the parent NSView
 * of a new pending surface whose token is written to *token (the bridge gives that surface the
 * tab's client), or NULL to leave the tab without client or view. url may be empty. */
typedef void *(*ACRAdoptEngineTab)(void *context, uint64_t window_token, uint64_t profile_token,
                                   const char *url, int32_t foreground, uint64_t *token);

typedef struct {
  uint32_t abi_version;
  uint32_t struct_size;
  void (*event)(void *context, const ACREvent *event);
  ACRDecideNewSurface decide_new_surface;
  ACRDecideNavigation decide_navigation;
  /* ABI 7: optional (NULL keeps CEF's default keyboard handling). */
  ACRDecideKey decide_key;
  ACRUnhandledKey unhandled_key;
  /* ABI 11: optional (NULL declines every Chrome-created tab). */
  ACRAdoptEngineTab adopt_engine_tab;
} ACRCallbacks;

/* (ABI 7) Where Chromium's OSCrypt keeps its key. */
typedef enum {
  /* --use-mock-keychain: no Keychain access; keychain names are ignored. The
   * default (zero) value, used by every automated run. */
  ACR_SECURE_STORAGE_MOCK = 0,
  /* The real macOS Keychain item keychain_service_name / keychain_account_name
   * (both required). Refused when the process arguments or extra switches
   * contain --use-mock-keychain: a run is never both. */
  ACR_SECURE_STORAGE_KEYCHAIN = 1
} ACRSecureStorage;

/* (ABI 8) Background network services of Chromium (orbit_bridge::NetworkPolicy). */
typedef enum {
  /* Default (zero): no background networking, component updater or network time queries.
   * Every automated run (laboratory, smoke, tests). */
  ACR_NETWORK_HERMETIC = 0,
  /* The signed daily build: component updater (CRLSet, CT logs, Widevine...), extension
   * updates and background networking on; sync, metrics, crash upload, variations, sign-in
   * and autofill crowdsourcing stay off. */
  ACR_NETWORK_PRODUCT = 1
} ACRNetworkPolicy;

/* Main thread only. Blocking CefRunMessageLoop; call before NSApplication is
 * created. root_cache_path must be an existing private directory; every
 * persistent profile path must be a child of it. Extra switches are appended
 * verbatim to the browser command line (laboratory: --load-extension=...).
 *
 * (ABI 7; Quit Apple Event routing repaired without an ABI change)
 * The Quit menu and the owned core/quit handler both use -terminate:, which asks the delegate's
 * applicationShouldTerminate: first. Cancel keeps running; Later waits for
 * replyToApplicationShouldTerminate:. Apple Event replies remain suspended until that decision.
 * Now or a positive reply requests ACRRequestQuit() and, if accepted, posts
 * NSApplicationWillTerminateNotification: the loop
 * ends, CefShutdown runs and ACRRun returns its status to the caller, which
 * exits. The shell therefore saves and releases everything before replying. */
typedef struct {
  uint32_t struct_size;
  const char *root_cache_path;
  const char *keychain_service_name;
  const char *keychain_account_name;
  const char *const *extra_switches;
  size_t extra_switch_count;
  int32_t hidden_accessory_app;
  /* Laboratory measurement: also hold main-frame network requests in
   * CefResourceRequestHandler::OnBeforeResourceLoad (IO thread, RV_CONTINUE_ASYNC). */
  int32_t async_navigation_hold;
  /* ABI 7: an ACRSecureStorage value. */
  int32_t secure_storage;
  /* ABI 8: an ACRNetworkPolicy value (other values refuse the run). */
  int32_t network_policy;
} ACRRunOptions;

/* (ABI 8) Chrome's initial profile, which backs CEF's global request context, is pinned to
 * <root_cache_path>/Default: ACRRun refuses (64) process arguments or extra switches with
 * --ignore-profile-directory-if-not-exists, --profile-directory or --user-data-dir, and, should
 * Chrome still select another initial profile, sends ACR_EVENT_FAILURE "initial-profile-unpinned"
 * instead of ACR_EVENT_READY, ends the loop and returns 79. */
/* (ABI 8, CHROMIUM-APP-R3) Chromium never sees the process arguments: it gets an allow-listed argv
 * (hermetic runs: --load-extension of real synthetic extension directories,
 * --use-fake-device-for-media-stream, --disable-features of valid names; product: nothing), in
 * every dash form; the rest is dropped (stderr count). root_cache_path must be an existing directory
 * reached without any symbolic link (64 otherwise); it is anchored by descriptor for the run. */
int32_t ACRRun(int argc, char *argv[], const ACRRunOptions *options,
               const ACRCallbacks *callbacks, void *context);

/* Closes every browser (including page-closed ones still held by the shell), waits for every
 * OnBeforeClose and every pending creation, then quits the loop. The quit is bounded
 * (CHROMIUM-APP-R2): after 5 s without completion an ACR_EVENT_FAILURE ("quit-stalled ...") is
 * sent and the close is retried; at the second stall (10 s) "quit-forced ..." is sent, the loop
 * ends anyway and CefShutdown destroys the remaining browsers (ACRRun returns 77). ACRRun returns
 * 75 when every browser closed after a stall, and 76, without CefShutdown, if the loop ended with
 * live browsers without a forced quit. A watchdog independent of the main thread ends the
 * process with status 78 if ACRRun has not returned 40 s after the request; the shell saves its
 * session before requesting the quit. */
int32_t ACRRequestQuit(void);

/* Creates a CefRequestContext. Empty cache_path gives an in-memory
 * (incognito) context; otherwise a *direct* child of root_cache_path (a deeper path
 * is not persistent with the Chrome bootstrap). Never shares storage with another
 * context except through the identical path (CEF then shares one browser context): the name must be [A-Za-z0-9._-], not start with '.', and must not alias
 * (case-insensitively, through symlinks or by file identity) the global profile
 * directory, a Chrome reserved directory or another context's directory.
 * Returns 1 when created, 0 when refused. */
int32_t ACRCreateProfile(uint64_t profile_token, const char *cache_path,
                         int32_t persist_session_cookies);

/* Creates an Alloy browser as a child of parent_nsview. Tries
 * CreateBrowserSync first; returns 2 when the browser exists on return, 1 when
 * creation is pending , 0 on failure. */
int32_t ACRCreateSurface(uint64_t surface_token, uint64_t profile_token,
                         void *parent_nsview, const char *url);

int32_t ACRNavigate(uint64_t surface_token, const char *url);
int32_t ACRGoBack(uint64_t surface_token);
int32_t ACRGoForward(uint64_t surface_token);
int32_t ACRReload(uint64_t surface_token);
int32_t ACRReloadIgnoringCache(uint64_t surface_token);
int32_t ACRStopLoad(uint64_t surface_token);
int32_t ACRSetFocus(uint64_t surface_token, int32_t focus);
/* Chrome content settings in one request context. kind: 0 notifications, 1 camera,
 * 2 microphone, 3 geolocation. setting: 0 ask, 1 allow, 2 block. UI thread only. */
int32_t ACRSetSitePermission(uint64_t profile_token, const char* origin, int32_t kind, int32_t setting);
/* Notifies CEF after the shell moved/resized/hid the parent view. */
int32_t ACRNotifyHostChanged(uint64_t surface_token, int32_t hidden);
/* Force-closes the browser (no beforeunload); CLOSED follows. */
int32_t ACRCloseSurface(uint64_t surface_token);

/* Back/forward entry URL relative to the current entry, written to buffer
 * (NUL-terminated). offset -1 back, +1 forward. Returns length or -1. */
int32_t ACRHistoryURL(uint64_t surface_token, int32_t offset, char *buffer, size_t capacity);
/* Native CEF navigation entries, JSON {currentIndex, entries:[URL]}. Returns required bytes;
 * writes a NUL-terminated result only when capacity exceeds that count. -1 unavailable. */
int32_t ACRDiscardTab(uint64_t token);
int32_t ACRRestoreDiscardedTab(uint64_t token);
int32_t ACRNavigationHistory(uint64_t surface_token, char *buffer, size_t capacity);

/* find_next = 0 starts a new query (counts and highlights), 1 continues. */
int32_t ACRFind(uint64_t surface_token, const char *text, int32_t forward,
                int32_t match_case, int32_t find_next);
int32_t ACRStopFinding(uint64_t surface_token, int32_t clear_selection);

/* command: 0 read, 1 in, 2 out, 3 reset. Returns 1 and writes the native
 * zoom level (factor = pow(1.2, level)) after applying the command. */
int32_t ACRZoom(uint64_t surface_token, int32_t command, double *level);
int32_t ACRSetZoomLevel(uint64_t surface_token, double level);

int32_t ACRSetAudioMuted(uint64_t surface_token, int32_t muted);
int32_t ACRIsAudioMuted(uint64_t surface_token);

/* Runs native beforeunload by navigating a download's source to about:blank, keeping its
 * browser alive for download callbacks. Returns 3 when submitted; DOCUMENT or CLOSE_CANCELED
 * answers it. Used instead of TryCloseBrowser while the source owns active transfers. */
int32_t ACRRequestDownloadSourceClose(uint64_t surface_token);

/* DevTools protocol call on the browser; result in ACR_EVENT_DEVTOOLS_RESULT
 * with the returned message id. Returns the message id or 0. */
int32_t ACRExecuteDevToolsMethod(uint64_t surface_token, const char *method,
                                 const char *params_json);

/* Runtime introspection used by the laboratory. */
int32_t ACRRuntimeStyle(uint64_t surface_token);
int32_t ACRBrowserID(uint64_t surface_token);
void *ACRBrowserNSView(uint64_t surface_token);
int32_t ACRProfilesShareStorage(uint64_t first_profile, uint64_t second_profile);
/* Copies the context cache path; returns length or -1. */
int32_t ACRProfileCachePath(uint64_t profile_token, char *buffer, size_t capacity);

/* Site-data probe through the browser's own request context cookie manager
 * (GetHost()->GetRequestContext()->GetCookieManager). Returns a request id
 * answered by ACR_EVENT_COOKIE_RESULT, or 0. */
uint64_t ACRCookieSet(uint64_t surface_token, const char *url, const char *name, const char *value);
uint64_t ACRCookieRead(uint64_t surface_token, const char *url, const char *name);

typedef struct {
  uint32_t struct_size;
  uint32_t hosts;              /* browsers between OnAfterCreated and OnBeforeClose */
  uint32_t pending_creations;  /* CreateBrowser or popup requests without OnAfterCreated yet */
  uint32_t pending_popups;     /* subset of pending_creations allowed in OnBeforePopup */
  uint32_t abandoned_popups;   /* popups whose opener closed during creation */
  uint32_t page_close_requests;/* hosts whose page called window.close() */
  uint32_t policies;
  uint32_t permissions;
  uint32_t destinations;
  uint32_t downloads;
  uint32_t aborted_creations;  /* total ACR_EVENT_CREATE_ABORTED sent */
  uint32_t quit_stalls;        /* total quit-stalled reports */
} ACRDiagnostics;

/* Laboratory introspection of the bridge bookkeeping. Returns 1 when filled. */
int32_t ACRGetDiagnostics(ACRDiagnostics *diagnostics);

int32_t ACRResolveNavigationPolicy(uint64_t request_id, ACRNavigationPolicy policy);
int32_t ACRResolvePermission(uint64_t request_id, ACRPermissionDecision decision);
/* Empty or NULL path cancels the download. */
int32_t ACRResolveDownloadDestination(uint64_t request_id, const char *path);
int32_t ACRDownloadCommand(uint64_t profile_token, uint32_t download_id, ACRDownloadAction action);

/* ---------------------------------------------------------------------------
 * ABI 6 — hosted Chrome mode (ENG-X2.1, variant D-chrome). Additive.
 *
 * On the patched CEF, each shell window x profile owns one invisible logical
 * Chrome Browser (TYPE_NORMAL) whose BrowserWindow is an AppKit, Views-free
 * OrbitBrowserWindow. A "tab surface" is a Chrome-style browser in that
 * Browser's TabStripModel; its content NSView is placed in the shell view
 * passed at creation. Extension APIs then see real tabs and windows (tabId,
 * windowId, tabs.query, runtime.sender). The logical Browser is created
 * lazily with the window's first tab and closes with its last tab; it is
 * never shown and never restored by Chrome.
 *
 * On the stock SDK ACRPatchLevel() is 0 and every function below fails (0);
 * ABI 5 surfaces (Alloy) are unaffected in both builds.
 * ------------------------------------------------------------------------ */

/* Version of the patched CEF side API (orbit_cef_get_api), 0 on stock CEF.
 * Valid after ACR_EVENT_READY. */
uint32_t ACRPatchLevel(void);

typedef enum {
  ACR_WINDOW_NORMAL = 0  /* TYPE_NORMAL logical Browsers. Popup windows: X2.3. */
} ACRWindowType;

/* Registers a shell window. nswindow is a borrowed NSWindow* that must stay
 * alive until ACRCloseWindow. Returns 1 when registered. */
int32_t ACRCreateWindow(uint64_t window_token, void *nswindow, ACRWindowType type);
/* Unregisters a window. Tab surfaces still alive keep working but report no
 * native window; close them first. Returns 1 if the window was known. */
int32_t ACRCloseWindow(uint64_t window_token);
/* Key-window state (windows.onFocusChanged, BrowserActiveStateManager). */
int32_t ACRWindowKeyChanged(uint64_t window_token, int32_t is_key);
/* Frame change (windows.onBoundsChanged). */
int32_t ACRWindowBoundsChanged(uint64_t window_token);

/* Creates a Chrome-style tab surface at index (-1 appends) in the logical
 * Browser of (window_token, profile), its content NSView a child of
 * parent_nsview. Same return codes as ACRCreateSurface; CREATED carries
 * value = 2 (Chrome style) and detail_code = extension tabId. */
int32_t ACRCreateTabSurface(uint64_t surface_token, uint64_t profile_token, uint64_t window_token,
                            int32_t index, void *parent_nsview, const char *url);
/* Moves a tab surface's content NSView under nsview (same window). */
int32_t ACRAttachSurfaceView(uint64_t surface_token, void *nsview);
/* Makes the tab surface the active tab of its logical Browser (tabs.onActivated). */
int32_t ACRActivateSurface(uint64_t surface_token);
/* (ABI 8, side API v2: ACRPatchLevel() >= 2) Moves a tab surface to index (-1 or past the end
 * appends) of the logical Browser of (window_token, its profile), keeping its WebContents,
 * browser, extension tabId, history and form state (tabs.onDetached/onAttached), or reorders it
 * within its Browser when it already is there (tabs.onMoved); then places its content NSView under
 * nsview when not NULL. Never activates it. Returns 1 on success; 0, with nothing changed, for an
 * unknown or unregistered window, a closing tab or a version 1 framework. */
int32_t ACRMoveSurfaceToWindow(uint64_t surface_token, uint64_t window_token, int32_t index, void *nsview);
/* (ABI 8, side API v3: ACRPatchLevel() >= 3) Transfer holds: while a window is held, its logical
 * Browser whose last tab moved away stays alive (same extension window id) so that a rollback can
 * return the tab there; releasing the last hold closes those still empty. Return the hold count
 * after the call, -1 when unavailable or unknown. */
int32_t ACRHoldWindow(uint64_t window_token);
int32_t ACRReleaseWindow(uint64_t window_token);
/* (ABI 8) safebrowsing.enabled of a profile context (0: the global context): 1, 0, or -1 when
 * unknown. The bridge turns it off in every profile (no Google API key: Safe Browsing cannot
 * work). */
int32_t ACRSafeBrowsingEnabled(uint64_t profile_token);

typedef struct {
  uint32_t struct_size;
  int32_t tab_id;        /* extension tabId, -1 when none */
  int32_t window_id;     /* extension windowId (logical Browser SessionID), -1 when none */
  int32_t index;         /* TabStripModel index, -1 when none */
  int32_t active;        /* 1 when active in its logical Browser */
  int32_t hosted;        /* 1 for a tab surface (hosted Chrome style) */
  uint64_t window_token; /* shell window token of the logical Browser, 0 when none */
} ACRTabInfo;

/* Extension identity of any surface (Alloy surfaces report -1 ids). Returns 1
 * when filled; 0 on stock CEF or for an unknown surface. */
int32_t ACRGetTabInfo(uint64_t surface_token, ACRTabInfo *info);
/* Diagnostics: live logical Browsers of a window (all profiles), or -1. */
int32_t ACRWindowBrowserCount(uint64_t window_token);

/* (ABI 8) Profile removal (BrowserEngine.removeProfile). Browsers, live or being created, of a
 * profile context (-1 when unknown). */
int32_t ACRProfileBrowserCount(uint64_t profile_token);
/* Releases a profile context that has no browser (1, also for an unknown token; 0 while browsers
 * remain). CEF then shuts its browser context down; Chrome unloads the Profile afterwards. */
int32_t ACRReleaseProfile(uint64_t profile_token);
/* (side API v2) 1 while Chrome still has a Profile loaded for the profile directory, 0 when not,
 * -1 when unknown (stock CEF, version 1). */
int32_t ACRProfileLoaded(const char *cache_path);
/* Removes the directory of a released persistent profile: only a direct, non-aliased child of
 * root_cache_path that no context uses, not the global profile, and that Chrome no longer has
 * loaded. (ABI 8, CHROMIUM-APP-R3) Every step goes through the root descriptor opened by ACRRun: a
 * directory is renamed to a private tombstone in the root, then removed without following links;
 * any other entry (a file left in place of a refused profile, a link) is unlinked itself. Returns 2
 * when something was removed now, 1 when already absent, 0 when refused for now (in use, loaded or
 * loading state unknown), -1 when removal failed, -5 when the root's name no longer designates the
 * directory ACRRun anchored (replaced root or link in its path: nothing is touched). */
int32_t ACRRemoveProfileDirectory(const char *cache_path);

/* Native accessibility tree of a surface (CefBrowserHost::SetAccessibilityState,
 * public API: works on both builds and both styles). enabled: 1 on, 0 off,
 * -1 default (command line). The shell enables it when an assistive
 * technology is active (AXEnhancedUserInterface, VoiceOver). */
int32_t ACRSetAccessibility(uint64_t surface_token, int32_t enabled);

/* ---------------------------------------------------------------------------
 * ABI 9 — page-initiated browser surfaces (CH-ESSENTIALS). Additive.
 *
 * Every request event is answered exactly once by its resolve function, on the main thread; a
 * second answer, an unknown id or an id dropped with its browser returns 0. Strings are copied.
 * ------------------------------------------------------------------------ */

/* accept 1: OK / Leave (text = prompt input, may be NULL); accept 0: Cancel / Stay, or a dialog the
 * shell suppressed (the page sees false / null; a suppressed beforeunload is answered 1). */
int32_t ACRResolveJSDialog(uint64_t request_id, int32_t accept, const char *text);
/* user NULL cancels (the page shows the server's 401/407 response). Never logged. */
int32_t ACRResolveAuth(uint64_t request_id, const char *user, const char *password);
/* count 0 (or paths NULL) cancels the chooser. */
int32_t ACRResolveFileDialog(uint64_t request_id, const char *const *paths, size_t count);
/* Executes one Chrome command offered by ACR_EVENT_CONTEXT_MENU for this request (command id from
 * its payload); a negative id, or one not offered, cancels the menu. */
int32_t ACRResolveContextMenu(uint64_t request_id, int32_t command_id);
/* terminate 1 ends the unresponsive renderer (the surface then reports RENDER_TERMINATED), 0 keeps
 * waiting. Returns 0 when the surface has no pending unresponsive question. */
int32_t ACRResolveUnresponsive(uint64_t surface_token, int32_t terminate);

/* Element fullscreen (Fullscreen API). Leaving needs a logical Browser that reports fullscreen:
 * the NSWindow in native fullscreen, or the pending CEF essentials patch. */
int32_t ACRExitFullscreen(uint64_t surface_token);
/* 1 in element fullscreen, 0 not, -1 unknown surface. */
int32_t ACRIsFullscreen(uint64_t surface_token);

/* DevTools in Chrome's own undocked window (Views; CEF disables docking). The tab becomes the
 * active tab of its logical Browser first (Chrome resolves the inspected tab from it). inspect 1
 * inspects the element at (x, y), view coordinates. Never pass a parent view: hosted openers
 * reset it to Alloy and CHECK (chrome_browser_delegate.cc:143-161). */
int32_t ACRShowDevTools(uint64_t surface_token, int32_t inspect, int32_t x, int32_t y);
int32_t ACRShowDevToolsPanel(uint64_t surface_token, const char* panel);
int32_t ACRCloseDevTools(uint64_t surface_token);
/* 1 when the surface has DevTools open, 0 when not, -1 unknown surface. */
int32_t ACRHasDevTools(uint64_t surface_token);
/* Executes a Chrome command by name (cef_command_ids.h) on the surface's tab, made active first,
 * when Chrome reports it enabled (CanExecuteChromeCommand). Hosted tabs only. */
int32_t ACRExecuteChromeCommand(uint64_t surface_token, const char *name);
/* Prints the current document: with --disable-print-preview (always set), the system print
 * panel (app-modal NSPrintPanel). */
int32_t ACRPrint(uint64_t surface_token);
/* Asks the page whether it may close (TryCloseBrowser: beforeunload, and its dialog through
 * ACR_EVENT_JS_DIALOG). 2: the close proceeds now; 1: pending — CLOSED follows when the page agrees,
 * CLOSE_CANCELED when the user stays; 0: unknown surface. A proceeding close is native: CLOSED
 * follows without ACRCloseSurface. */
int32_t ACRRequestClose(uint64_t surface_token);
/* Level of the CEF essentials patch (exported `orbit_cef_essentials_level`), 0 when absent. */
uint32_t ACREssentialsLevel(void);

/* ABI 10: inventory/custom actions. 1 on API v4; never a general Store
 * compatibility claim. Every operation refuses unknown, ephemeral or global profiles. */
int32_t ACRExtensionsAvailable(void);
int32_t ACRExtensionsSnapshot(uint64_t profile_token, char *json, uint32_t capacity);
int32_t ACRExtensionSetEnabled(uint64_t profile_token, const char *extension_id, int32_t enabled);
int32_t ACRExtensionPinningAvailable(void);
int32_t ACRExtensionSetPinned(uint64_t profile_token, const char *extension_id, int32_t pinned);
/* Borrowed weak anchor, validated against the surface's shell window. */
int32_t ACRSetExtensionActionAnchor(uint64_t surface_token, void *anchor_nsview);
int32_t ACRExtensionRemove(uint64_t profile_token, const char *extension_id);
int32_t ACRObserveExtensions(uint64_t profile_token, int32_t observe);
int32_t ACRPerformExtensionAction(uint64_t surface_token, const char *extension_id, void *anchor_nsview);
/* Revokes pending or visible extension UI of this exact surface. */
int32_t ACRCancelExtensionAction(uint64_t surface_token);
/* Manager-only availability on admitted persistent hosted v3+; no inventory/action claim. */
int32_t ACRExtensionManagementAvailable(void);
/* Native-only exact internal route. Does not change ACRNavigate or the ordinary validator. */
int32_t ACROpenExtensionManager(uint64_t surface_token);
/* (EXT-OUTCOME-R2) The same exact-surface manager route for one document of the genuine manager:
 * page 0 the manager, 1 the details of extension_id (32 letters a-p), 2 keyboard shortcuts.
 * 1 on success, 0 when refused (including an invalid page or ID). */
int32_t ACROpenExtensionManagerPage(uint64_t surface_token, int32_t page, const char *extension_id);

int32_t ACRBrowserStateAvailable(void);
int32_t ACRExtensionActionSnapshot(uint64_t surface_token, char* json, uint32_t capacity);

#ifdef __cplusplus
}
#endif
#endif
