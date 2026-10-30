#include "OrbitChromiumBridge.h"
#include "LifecycleBridgeStub.h"

#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <assert.h>
#include <stdlib.h>

/* Source-only authenticated-import coordinator tests inject their transport. Other lifecycle
 * targets compile the same adapter without enabling synthetic target admission. */
int32_t ACRAuthCreateFreshProfile(uint64_t profile, ACRAuthBytes child, int32_t persist) { return 0; }
int32_t ACRAuthInstall(const ACRAuthBatch *batch, ACRAuthCallback callback, void *context) { return 0; }
int32_t ACRAuthCancel(uint64_t operation) { return 0; }

/* No CEF, application, filesystem, network or keychain is initialized by this bridge. */
static ACRCallbacks test_callbacks;
static void *test_context;

int32_t ACRRun(int argc, char *argv[], const ACRRunOptions *options,
               const ACRCallbacks *callbacks, void *context) {
  test_callbacks = *callbacks;
  test_context = context;
  ACREvent event = {.struct_size = sizeof(ACREvent), .kind = ACR_EVENT_READY};
  test_callbacks.event(test_context, &event);
  return 0;
}

void *ACRStubAdoptEngineTab(uint64_t window_token, uint64_t profile_token, const char *url,
                            int32_t foreground, uint64_t *token) {
  *token = 0;
  return test_callbacks.adopt_engine_tab
      ? test_callbacks.adopt_engine_tab(test_context, window_token, profile_token, url ? url : "", foreground, token)
      : 0;
}

void ACRStubAbortCreation(uint64_t token) {
  ACREvent event = {.struct_size = sizeof(ACREvent), .kind = ACR_EVENT_CREATE_ABORTED,
                   .surface_token = token, .detail = "synthetic pending creation aborted"};
  test_callbacks.event(test_context, &event);
}

static int refuse_next_profile;
static uint64_t refused_profile;
typedef struct { uint64_t token; int persistent, ready, observed; } StubProfile;
static StubProfile extension_profiles[256];
static int extension_profile_count;
static StubProfile *stub_profile(uint64_t token) {
  for (int i = 0; i < extension_profile_count; ++i)
    if (extension_profiles[i].token == token) return &extension_profiles[i];
  return 0;
}

void ACRStubRefuseNextProfile(void) { refuse_next_profile = 1; }

int32_t ACRRequestQuit(void) { return 1; }
int32_t ACRCreateProfile(uint64_t token, const char *path, int32_t persistent) {
  if (!refuse_next_profile) {
    if (extension_profile_count >= 256) return 0;
    extension_profiles[extension_profile_count++] = (StubProfile){.token = token, .persistent = persistent};
    return 1;
  }
  refuse_next_profile = 0;
  refused_profile = token;
  return 0;
}
int32_t ACRCreateSurface(uint64_t token, uint64_t profile, void *view, const char *url) {
  return profile && profile == refused_profile ? 0 : 1;
}
int32_t ACRCloseSurface(uint64_t token) { return 1; }
static int popup_metadata_known;
static orbit_navigation_metadata_t popup_metadata;
static char popup_method[16];
void ACRStubPopupMetadata(int32_t known, uint32_t transition, const char *method, int32_t has_body) {
  popup_metadata_known = known;
  snprintf(popup_method, sizeof(popup_method), "%s", method ? method : "");
  popup_metadata = (orbit_navigation_metadata_t){sizeof(popup_metadata), transition, method ? popup_method : NULL, has_body};
}
int32_t ACRPopupNavigationMetadata(uint64_t source, orbit_navigation_metadata_t *metadata) {
  if (!popup_metadata_known || !metadata || metadata->struct_size < sizeof(*metadata)) return 0;
  *metadata = popup_metadata;
  return 1;
}
int32_t ACRNavigate(uint64_t token, const char *url) { return 1; }
int32_t ACRGoBack(uint64_t token) { return 0; }
int32_t ACRGoForward(uint64_t token) { return 0; }
int32_t ACRReload(uint64_t token) { return 1; }
int32_t ACRReloadIgnoringCache(uint64_t token) { return 1; }
int32_t ACRStopLoad(uint64_t token) { return 1; }
int32_t ACRSetFocus(uint64_t token, int32_t focus) { return 0; }
int32_t ACRNotifyHostChanged(uint64_t token, int32_t hidden) { return 1; }
int32_t ACRHistoryURL(uint64_t token, int32_t offset, char *buffer, size_t capacity) { return -1; }
int32_t ACRFind(uint64_t token, const char *text, int32_t forward, int32_t match, int32_t next) { return 0; }
int32_t ACRStopFinding(uint64_t token, int32_t clear) { return 1; }
int32_t ACRZoom(uint64_t token, int32_t command, double *level) { *level = 0; return 1; }
int32_t ACRSetZoomLevel(uint64_t token, double level) { return 1; }
int32_t ACRSetAudioMuted(uint64_t token, int32_t muted) { return 1; }
int32_t ACRIsAudioMuted(uint64_t token) { return 0; }
static int32_t devtools_id = 0;
static int32_t devtools_enabled = 0;
void ACRStubDevToolsMode(int32_t enabled) { devtools_enabled = enabled; devtools_id = 0; }
int32_t ACRStubDevToolsID(void) { return devtools_id; }
int32_t ACRExecuteDevToolsMethod(uint64_t token, const char *method, const char *params) {
  return devtools_enabled && strcmp(method, "Page.captureScreenshot") == 0 ? ++devtools_id : 0;
}
int32_t ACRRuntimeStyle(uint64_t token) { return 0; }
int32_t ACRBrowserID(uint64_t token) { return 0; }
void *ACRBrowserNSView(uint64_t token) { return 0; }
int32_t ACRProfilesShareStorage(uint64_t first, uint64_t second) { return 0; }
int32_t ACRProfileCachePath(uint64_t token, char *buffer, size_t capacity) { return -1; }
uint64_t ACRCookieSet(uint64_t token, const char *url, const char *name, const char *value) { return 0; }
uint64_t ACRCookieRead(uint64_t token, const char *url, const char *name) { return 0; }
int32_t ACRGetDiagnostics(ACRDiagnostics *diagnostics) { return 0; }
int32_t ACRResolveNavigationPolicy(uint64_t request, ACRNavigationPolicy policy) { return 1; }
int32_t ACRResolvePermission(uint64_t request, ACRPermissionDecision decision) { return 1; }
static char download_path[4096];
static uint64_t download_request;
int32_t ACRResolveDownloadDestination(uint64_t request, const char *path) {
  download_request = request;
  snprintf(download_path, sizeof(download_path), "%s", path ? path : "");
  return 1;
}
const char *ACRStubDownloadPath(void) { return download_path; }
uint64_t ACRStubDownloadRequest(void) { return download_request; }
void ACRStubDownload(uint64_t token, uint64_t request, int32_t status, int64_t bytes) {
  ACREvent event = {.struct_size = sizeof(ACREvent), .kind = ACR_EVENT_DOWNLOAD,
                   .surface_token = token, .request_id = request, .download_id = 42,
                   .download_status = status, .received_bytes = bytes, .total_bytes = 128,
                   .suggested_name = "synthetic.bin"};
  test_callbacks.event(test_context, &event);
}
int32_t ACRDownloadCommand(uint64_t profile, uint32_t download, ACRDownloadAction action) { return 1; }

static int hosted_mode, activation_count;
static uint64_t published_surface;
typedef struct { uint64_t token, profile, window; int active; } StubTab;
static StubTab tabs[256];
static int tab_count;
static StubTab *stub_tab(uint64_t token) {
  for (int i = 0; i < tab_count; ++i) if (tabs[i].token == token) return &tabs[i];
  return 0;
}
void ACRStubHostedMode(int32_t enabled) { hosted_mode = enabled; activation_count = 0; published_surface = 0; tab_count = 0; }
uint64_t ACRStubPublishedSurface(void) { return published_surface; }
int32_t ACRStubActivationCount(void) { return activation_count; }

/* ABI 6: no CEF; tests may advertise a side API version, but hosted calls still fail. */
static uint32_t patch_level;
void ACRStubSetPatchLevel(uint32_t version) { patch_level = version; }
uint32_t ACRPatchLevel(void) { return patch_level; }
int32_t ACRCreateWindow(uint64_t window, void *nswindow, ACRWindowType type) { return hosted_mode; }
int32_t ACRCloseWindow(uint64_t window) { return 0; }
int32_t ACRWindowKeyChanged(uint64_t window, int32_t is_key) { return 0; }
int32_t ACRWindowBoundsChanged(uint64_t window) { return 0; }
int32_t ACRCreateTabSurface(uint64_t token, uint64_t profile, uint64_t window, int32_t index,
                            void *parent, const char *url) {
  if (!hosted_mode || tab_count >= 256) return 0;
  for (int i = 0; i < tab_count; ++i)
    if (tabs[i].window == window && tabs[i].profile == profile) tabs[i].active = 0;
  tabs[tab_count++] = (StubTab){token, profile, window, 1}; // Chrome inserts it logically active.
  return 1;
}
int32_t ACRAttachSurfaceView(uint64_t token, void *nsview) { return 0; }
int32_t ACRActivateSurface(uint64_t token) {
  StubTab *tab = stub_tab(token);
  if (!hosted_mode || !tab) return 0;
  published_surface = token;
  ++activation_count;
  tab->active = 1;
  return 1;
}
int32_t ACRMoveSurfaceToWindow(uint64_t token, uint64_t window, int32_t index, void *nsview) { return 0; }
int32_t ACRHoldWindow(uint64_t window) { return -1; }
int32_t ACRReleaseWindow(uint64_t window) { return -1; }
int32_t ACRSafeBrowsingEnabled(uint64_t profile) { return -1; }
int32_t ACRProfileBrowserCount(uint64_t profile) { return 0; }
int32_t ACRReleaseProfile(uint64_t profile) {
  StubProfile *entry = stub_profile(profile);
  if (entry) { entry->ready = 0; entry->observed = 0; }
  return 1;
}
int32_t ACRProfileLoaded(const char *path) { return -1; }
int32_t ACRRemoveProfileDirectory(const char *path) { return 1; }
static int32_t retirement_result = 2, retirement_pending = 0;
void ACRStubRetirementMode(int32_t result) { retirement_result = result; retirement_pending = 1; }
int32_t ACRRetireProfileDirectory(const char *path, uint64_t *retirement) {
  *retirement = retirement_pending ? 1 : 0;
  retirement_pending = 0;
  return *retirement ? 2 : 1;
}
int32_t ACRFinishProfileRemoval(uint64_t retirement) {
  assert(!pthread_main_np());
  usleep(100000);
  return retirement_result;
}
int32_t ACRGetTabInfo(uint64_t token, ACRTabInfo *info) {
  StubTab *tab = stub_tab(token);
  if (!hosted_mode || !tab) return 0;
  info->active = tab->active; info->hosted = 1; info->tab_id = (int32_t)token;
  info->window_id = (int32_t)tab->window; info->window_token = tab->window; info->index = 0;
  return 1;
}
int32_t ACRWindowBrowserCount(uint64_t window) { return -1; }
int32_t ACRSetAccessibility(uint64_t token, int32_t enabled) { return 0; }

/* ABI 9 (CH-ESSENTIALS): page requests are synthesized by the tests and their answers recorded. */
static ACRStubResolution last_resolution;

const ACRStubResolution *ACRStubLastResolution(void) { return &last_resolution; }

static void record(int32_t kind, uint64_t request, int32_t value, const char *text, const char *second) {
  last_resolution.kind = kind;
  last_resolution.request_id = request;
  last_resolution.value = value;
  snprintf(last_resolution.text, sizeof(last_resolution.text), "%s", text ? text : "");
  snprintf(last_resolution.second, sizeof(last_resolution.second), "%s", second ? second : "");
  last_resolution.has_text = text != 0;
  ++last_resolution.count;
}

void ACRStubEmit(int32_t kind, uint64_t token, uint64_t request, int32_t value, int32_t flags,
                 const char *url, const char *detail, const char *title, const char *payload) {
  ACREvent event = {.struct_size = sizeof(ACREvent), .kind = (ACREventKind)kind, .surface_token = token,
                    .request_id = request, .value = value, .flags = flags, .url = url, .detail = detail,
                    .title = title, .payload = payload, .payload_size = payload ? strlen(payload) : 0};
  test_callbacks.event(test_context, &event);
}

int32_t ACRResolveJSDialog(uint64_t request, int32_t accept, const char *text) {
  record(ACR_EVENT_JS_DIALOG, request, accept, text, 0);
  return 1;
}
int32_t ACRResolveAuth(uint64_t request, const char *user, const char *password) {
  record(ACR_EVENT_AUTH, request, user ? 1 : 0, user, password);
  return 1;
}
int32_t ACRResolveFileDialog(uint64_t request, const char *const *paths, size_t count) {
  record(ACR_EVENT_FILE_DIALOG, request, (int32_t)count, count ? paths[0] : 0, count > 1 ? paths[1] : 0);
  return 1;
}
int32_t ACRResolveContextMenu(uint64_t request, int32_t command_id) {
  record(ACR_EVENT_CONTEXT_MENU, request, command_id, 0, 0);
  return 1;
}
int32_t ACRResolveUnresponsive(uint64_t token, int32_t terminate) {
  record(ACR_EVENT_UNRESPONSIVE, token, terminate, 0, 0);
  return 1;
}
int32_t ACRExitFullscreen(uint64_t token) { record(ACR_EVENT_FULLSCREEN, token, 0, 0, 0); return 1; }
int32_t ACRIsFullscreen(uint64_t token) { return -1; }
int32_t ACRShowDevTools(uint64_t token, int32_t inspect, int32_t x, int32_t y) { return 0; }
int32_t ACRCloseDevTools(uint64_t token) { return 0; }
int32_t ACRHasDevTools(uint64_t token) { return -1; }
int32_t ACRExecuteChromeCommand(uint64_t token, const char *name) { return 0; }
int32_t ACRPrint(uint64_t token) { return 0; }
static int32_t request_close_result = 2;
void ACRStubSetRequestCloseResult(int32_t result) { request_close_result = result; }
int32_t ACRRequestClose(uint64_t token) {
  record(ACR_EVENT_CLOSE_CANCELED, token, request_close_result, 0, 0);
  return request_close_result;
}
int32_t ACRRequestDownloadSourceClose(uint64_t token) { return 3; }
int32_t ACRNavigationHistory(uint64_t token, char* buffer, size_t capacity) { return -1; }
int32_t ACRSetSitePermission(uint64_t profile, const char* origin, int32_t kind, int32_t setting) { return 0; }
int32_t ACRExtensionPinningAvailable(void) { return 0; }
int32_t ACRExtensionSetPinned(uint64_t profile, const char* extension, int32_t pinned) { return 0; }
int32_t ACRSetExtensionActionAnchor(uint64_t token, void* anchor) { return 0; }
uint32_t ACREssentialsLevel(void) { return 0; }

/* ABI 10: controllable native responses exercise the actual Swift adapter. */
static char extension_json[8192] = "[]";
static int32_t extension_reported_size = -2, extension_read_size = -2;
static int32_t extension_reentry, extension_unregisters;
static uint64_t last_extension_profile;
void ACRStubReadyProfile(uint64_t token) {
  StubProfile *entry = stub_profile(token);
  if (!entry) return;
  entry->ready = 1;
  ACREvent event = {.struct_size = sizeof(ACREvent), .kind = ACR_EVENT_PROFILE_READY, .profile_token = token};
  test_callbacks.event(test_context, &event);
}
void ACRStubExtensionsSnapshot(const char *json, int32_t reported_size, int32_t read_size) {
  snprintf(extension_json, sizeof(extension_json), "%s", json ? json : "[]");
  extension_reported_size = reported_size;
  extension_read_size = read_size;
}
void ACRStubExtensionsReenter(int32_t flags) { extension_reentry = flags; }
void ACRStubExtensionsChanged(uint64_t profile) {
  ACREvent event = {.struct_size = sizeof(ACREvent), .kind = ACR_EVENT_EXTENSIONS_CHANGED, .profile_token = profile};
  test_callbacks.event(test_context, &event);
}
uint64_t ACRStubLastExtensionProfile(void) { return last_extension_profile; }
int32_t ACRStubExtensionUnregisterCount(void) { return extension_unregisters; }
int32_t ACRStubExtensionObserverCount(void) {
  int count = 0;
  for (int i = 0; i < extension_profile_count; ++i) count += extension_profiles[i].observed;
  return count;
}
static int usable_extension_profile(uint64_t token) {
  StubProfile *entry = stub_profile(token);
  return patch_level >= 4 && entry && entry->persistent && entry->ready;
}
int32_t ACRExtensionsAvailable(void) { return patch_level >= 4; }
int32_t ACRExtensionsSnapshot(uint64_t token, char *json, uint32_t capacity) {
  if (!usable_extension_profile(token)) return -1;
  last_extension_profile = token;
  const int32_t actual = (int32_t)strlen(extension_json);
  const int32_t result = json ? extension_read_size : extension_reported_size;
  if (json && capacity > (uint32_t)actual) memcpy(json, extension_json, (size_t)actual + 1);
  return result == -2 ? actual : result;
}
int32_t ACRExtensionSetEnabled(uint64_t token, const char *id, int32_t enabled) {
  if (!usable_extension_profile(token) || !id || (enabled != 0 && enabled != 1)) return 0;
  last_extension_profile = token;
  return 1;
}
int32_t ACRExtensionRemove(uint64_t token, const char *id) {
  if (!usable_extension_profile(token) || !id) return 0;
  last_extension_profile = token;
  if (extension_reentry & 4) ACRStubExtensionsChanged(token);
  return 1;
}
int32_t ACRObserveExtensions(uint64_t token, int32_t observe) {
  if (patch_level < 4) return 0;
  StubProfile *entry = stub_profile(token);
  if (!entry || (observe && !usable_extension_profile(token))) return 0;
  entry->observed = observe != 0;
  if (!observe) ++extension_unregisters;
  const int32_t trigger = observe ? 1 : 2;
  if (extension_reentry & trigger) ACRStubExtensionsChanged(token);
  return 1;
}
int32_t ACRExtensionManagementAvailable(void) { return 0; }
int32_t ACROpenExtensionManager(uint64_t surface) { return 0; }
int32_t ACROpenExtensionManagerPage(uint64_t surface, int32_t page, const char *extension_id) { return 0; }
int32_t ACRPerformExtensionAction(uint64_t surface, const char *id, void *anchor) { return 0; }
int32_t ACRCancelExtensionAction(uint64_t surface) { return patch_level >= 4; }
int32_t ACRShowDevToolsPanel(uint64_t surface, const char *panel) { return 0; }

void ACRStubEmitFavicon(uint64_t surface, uint64_t profile, int32_t browser, uint64_t generation,
                        uint64_t revision, const char *url, const void *bytes, size_t size) {
  ACREvent event = {.struct_size = sizeof(ACREvent), .kind = ACR_EVENT_FAVICON,
    .surface_token = surface, .profile_token = profile, .browser_id = browser,
    .document_generation = generation, .request_id = revision, .url = url,
    .payload = bytes, .payload_size = size};
  test_callbacks.event(test_context, &event);
}

int32_t ACRBrowserStateAvailable(void) { return 0; }
int32_t ACRExtensionActionSnapshot(uint64_t token, char* json, uint32_t capacity) { return -1; }

int32_t ACRDiscardTab(uint64_t token) { return 0; }
int32_t ACRRestoreDiscardedTab(uint64_t token) { return 0; }

/* Optional engine services are absent in this source-only navigation fixture. */
int32_t ACRBoostsAvailable(void) { return 0; }
int32_t ACRBoostsReplace(uint64_t profile, const char *json, uint64_t revision,
                       orbit_boost_ack_t callback, void *context) { return 0; }
int32_t ACRPasswordPromptObserve(uint64_t surface, uint64_t profile,
                               orbit_password_prompt_callback_t callback, void *context) { return 0; }
int32_t ACRPasswordPromptSnapshot(uint64_t surface, uint64_t profile,
                                orbit_password_prompt_t *snapshot) { return 0; }
int32_t ACRPasswordPromptDecide(uint64_t surface, uint64_t profile, uint64_t generation, int32_t decision) { return 0; }
int32_t ACRPasswordPromptReopen(uint64_t surface, uint64_t profile, uint64_t generation) { return 0; }
int32_t ACRSetAutomaticPiP(uint64_t surface, int32_t automatic) { return 0; }

int32_t ACRPasswordStoreAvailable(void) { return 0; }
uint64_t ACRPasswordStoreOpen(uint64_t profile) { return 0; }
void ACRPasswordStoreClose(uint64_t handle) {}
int32_t ACRPasswordStoreList(uint64_t handle, orbit_password_result_t cb, void* context) { return 0; }
int32_t ACRPasswordStoreWrite(uint64_t handle, int32_t operation, const orbit_password_record_t* record,
    const orbit_password_record_t* old_key, orbit_password_result_t cb, void* context) { return 0; }
int32_t ACRPasswordStoreObserve(uint64_t handle, orbit_password_changed_t cb, void* context) { return 0; }

/* Native readback fixture: completion remains pending until explicitly released by the test. */
static int32_t capture_enabled, capture_count, capture_width, capture_height;
static orbit_capture_callback_t capture_callback;
static void *capture_context;
void ACRStubCaptureMode(int32_t enabled) { capture_enabled = enabled; capture_count = 0; }
int32_t ACRStubCaptureCount(void) { return capture_count; }
int32_t ACRPagePerformanceAvailable(void) { return capture_enabled; }
int32_t ACRPageLifecycle(uint64_t token, orbit_page_lifecycle_t *state) { return 0; }
int32_t ACRPageLifecycleObserve(uint64_t token, orbit_lifecycle_callback_t cb, void *context) { return 0; }
void ACRPagePerformanceClosing(uint64_t token) {}
int32_t ACRActivationFrame(uint64_t token, uint64_t activation, orbit_activation_callback_t cb, void *context) { return 0; }
int32_t ACRCaptureView(uint64_t token, orbit_capture_rect_t rect, int32_t width, int32_t height,
                     int32_t timeout, orbit_capture_callback_t cb, void *context) {
  if (!capture_enabled) return 0;
  assert(!capture_callback);
  ++capture_count; capture_width = width; capture_height = height;
  capture_callback = cb; capture_context = context;
  return 1;
}
void ACRStubCaptureFinish(int32_t status) {
  orbit_capture_callback_t cb = capture_callback; void *context = capture_context;
  capture_callback = NULL; capture_context = NULL;
  if (!cb) return;
  size_t size = (size_t)capture_width * capture_height * 4;
  uint8_t *pixels = calloc(1, size);
  cb(context, status, capture_width, capture_height, capture_width * 4, pixels, 1);
  free(pixels);
}

/* Optional native services are unavailable in this lifecycle-only fixture. */
int32_t ACRMemoryDump(orbit_memory_callback_t callback, void *context) { return 0; }
int32_t ACRNativePageServicesVersion(void) { return 0; }
int32_t ACRNativePageRead(uint64_t token, int32_t kind, char *output, uint32_t capacity) { return 0; }
int32_t ACRSecurityDisplay(const char *url, int32_t scheme, char *output, uint32_t capacity) { return 0; }
int32_t ACRSecurityObserve(uint64_t token, orbit_json_changed_t callback, void *context) { return 0; }
int32_t ACRFullscreenObserve(uint64_t token, orbit_fullscreen_changed_t callback, void *context) { return 0; }
int32_t ACRNavigationGoIndex(uint64_t token, int32_t index) { return 0; }
int32_t ACRMediaObserve(uint64_t token, orbit_json_changed_t callback, void *context) { return 0; }
int32_t ACRMediaAction(uint64_t token, int32_t action, double seconds) { return 0; }
void ACRNativePageServicesClosing(uint64_t token) {}
