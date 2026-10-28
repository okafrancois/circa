#ifndef AL_CHROMIUM_BRIDGE_H
#define AL_CHROMIUM_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define AL_CHROMIUM_ABI_VERSION 3u

typedef enum {
  AL_EVENT_READY = 1,
  AL_EVENT_CREATED,
  AL_EVENT_ADDRESS,
  AL_EVENT_TITLE,
  AL_EVENT_LOADING,
  AL_EVENT_FOCUS,
  AL_EVENT_WINDOW,
  AL_EVENT_CLOSED,
  AL_EVENT_COMMAND,
  AL_EVENT_QUIT_REQUESTED,
  AL_EVENT_WATCHDOG_REQUIRED,
  AL_EVENT_SHUTDOWN,
  AL_EVENT_FAILURE,
  AL_EVENT_DOCUMENT,
  AL_EVENT_FIND_RESULT,
  AL_EVENT_FIND_STOPPED,
  AL_EVENT_PAGE_TOOLS_REJECTED,
  AL_EVENT_ZOOM,
  AL_EVENT_HIDDEN_AUDIT,
  AL_EVENT_DOWNLOAD,
  AL_EVENT_DOWNLOAD_COMMAND,
  AL_EVENT_DOWNLOAD_REJECTED
} ALChromiumEventKind;

/* Native IDs are scoped by profile/context. The immutable identity is the
 * first three fields; revision changes on every observation/accepted command.
 * source host lifetime is separate: downloads can outlive their WebContents. */
typedef struct {
  uint64_t profile_token;
  uint32_t native_id;
  uint64_t download_lifetime;
  uint64_t revision;
} ALChromiumDownloadHandle;

typedef enum {
  AL_DOWNLOAD_PENDING = 0,
  AL_DOWNLOAD_PROGRESS,
  AL_DOWNLOAD_COMPLETE,
  AL_DOWNLOAD_CANCELED,
  AL_DOWNLOAD_INTERRUPTED
} ALChromiumDownloadStatus;

typedef enum {
  AL_DOWNLOAD_CANCEL = 1,
  AL_DOWNLOAD_PAUSE,
  AL_DOWNLOAD_RESUME
} ALChromiumDownloadAction;

typedef enum {
  AL_DOWNLOAD_NORMAL = 1,
  AL_DOWNLOAD_DUPLICATE_FIRST,
  AL_DOWNLOAD_DUPLICATE_SECOND,
  AL_DOWNLOAD_PAUSE_RESUME,
  AL_DOWNLOAD_CANCEL_PROGRESS,
  AL_DOWNLOAD_INTERRUPT_RESUME,
  AL_DOWNLOAD_SOURCE_CLOSE,
  AL_DOWNLOAD_PROFILE_B
} ALChromiumDownloadCase;

/* Borrowed payload, valid only during the callback. Copy strings immediately.
 * browser_id is an opaque CEF host ID, not an extension tabId.
 * window_token is a laboratory association, never an extension windowId.
 * FOCUS is a focus observation, never an authoritative active-tab event.
 * Lifetime/document apply to host events. Query/operation apply to page-tool
 * events. Native ID/count/ordinal/final are meaningful only for FIND_RESULT;
 * zoom fields only for ZOOM. STOPPED is an acknowledgement, not a find result.
 * Rejections echo the requested lifetime/document/tokens, with no association
 * to a replacement host. No event contains query text. */
typedef struct {
  uint32_t struct_size;
  ALChromiumEventKind kind;
  int32_t browser_id;
  uint64_t profile_token;
  uint64_t window_token;
  int32_t value;
  const char *detail;
  const char *url;
  const char *title;
  uint64_t host_lifetime;
  uint64_t document_generation;
  uint64_t query_token;
  uint64_t operation_token;
  int32_t native_find_id;
  int32_t match_count;
  int32_t active_ordinal;
  int32_t final_update;
  double zoom_level;
  double default_zoom_level;
  int32_t can_zoom_in;
  int32_t can_zoom_out;
  int32_t can_zoom_reset;
  ALChromiumDownloadHandle download_handle;
  int32_t source_browser_id;
  uint64_t source_host_lifetime;
  int64_t received_bytes;
  int64_t total_bytes;
  ALChromiumDownloadStatus download_status;
  int32_t download_paused;
  int32_t interrupt_reason;
  /* CEF exposes no CanResume readback: -1 means unknown with native callback
   * available, 0 means unavailable. Never infer successful resume from this. */
  int32_t can_resume;
  uint64_t download_command_token;
  ALChromiumDownloadCase download_case;
  /* Borrowed internal metadata only; copy during callback, never log. The
   * generated destination ignores all suggested filenames. total_bytes=-1
   * means unknown (native total <=0 before completion). download_path is null
   * until native FullPath exactly matches the chosen generated destination and
   * its private regular file has been checked. No payload crosses ABI. */
  const char *download_path;
  const char *download_filename;
} ALChromiumEvent;

typedef enum {
  AL_ZOOM_READ = 0,
  AL_ZOOM_IN,
  AL_ZOOM_OUT,
  AL_ZOOM_RESET
} ALChromiumZoomCommand;

typedef struct {
  uint32_t abi_version;
  uint32_t struct_size;
  void (*event)(void *context, const ALChromiumEvent *event);
} ALChromiumCallbacks;

/* Main thread only. Blocking native CEF loop; call before NSApplication.shared.
 * The caller owns context and must retain it until this function returns,
 * including CefShutdown. No CEF/C++ object crosses this ABI. */
int32_t ALChromiumRun(int argc, char *argv[],
                      const ALChromiumCallbacks *callbacks, void *context);

/* Main thread only; 1 means queued, not completed. All mutations are posted to
 * TID_UI. IDs address living hosts, not visual tab indices. New windows keep
 * the source host's request context; there is no profile-switch operation. */
int32_t ALChromiumCreateWindow(int32_t source_browser_id);
int32_t ALChromiumNewTab(int32_t source_browser_id);
int32_t ALChromiumSelect(int32_t target_browser_id);
int32_t ALChromiumClose(int32_t target_browser_id);
int32_t ALChromiumSplit(int32_t target_browser_id);
int32_t ALChromiumRequestQuit(void);

/* Ephemeral native-only query. Never put it in a URL, page message, preference,
 * detail string or log. Tokens must be nonzero and strictly increase per host
 * (query token increases on replacement/stop, operation token on every call).
 * Expected lifetime/document are required; stale queued calls are rejected.
 * find_next=0 counts/highlights without selecting. Next/previous use 1, after
 * the initial final callback. Busy continuations are rejected, never rebound.
 * Coordinator MUST exclusively own find; stock CEF exposes no allocation hook
 * that can correlate an independent DevTools/native caller. */
int32_t ALChromiumFind(int32_t browser_id, uint64_t host_lifetime,
    uint64_t document_generation, uint64_t query_token, uint64_t operation_token,
    const char *text, int32_t forward, int32_t match_case, int32_t find_next);
int32_t ALChromiumStopFinding(int32_t browser_id, uint64_t host_lifetime,
    uint64_t document_generation, uint64_t query_token, uint64_t operation_token,
    int32_t clear_selection);
/* Zoom commands target the exact WebContents. Factors are pow(1.2, level).
 * Profile/site persistence remains owned by Chromium. READ changes nothing. */
int32_t ALChromiumZoom(int32_t browser_id, uint64_t host_lifetime,
    uint64_t document_generation, uint64_t operation_token,
    ALChromiumZoomCommand command);
/* Explicit hidden-test mode only: navigate the target to its original fixture
 * URL. No script or page command bridge. Default visible gate rejects this. */
int32_t ALChromiumPageToolsReload(int32_t browser_id, uint64_t host_lifetime,
    uint64_t document_generation, uint64_t operation_token);

/* Explicit --download-test only. Fixed loopback fixture cases, no caller URL or
 * destination. 1 means queued, never completed. Commands require the latest
 * exact context/lifetime/revision and a strictly increasing command token.
 * Cancel/quit revoke callbacks before invoking cancellation. Resume uses only
 * CefDownloadItemCallback::Resume; it never starts a replacement URL request. */
int32_t ALChromiumStartDownload(int32_t browser_id, uint64_t host_lifetime,
    uint64_t profile_token, uint64_t command_token, ALChromiumDownloadCase fixture_case);
int32_t ALChromiumDownloadCommand(ALChromiumDownloadHandle handle,
    uint64_t command_token, ALChromiumDownloadAction action);

#ifdef __cplusplus
}
#endif
#endif
