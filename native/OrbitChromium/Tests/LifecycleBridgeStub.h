#ifndef ORBIT_LIFECYCLE_BRIDGE_STUB_H
#define ORBIT_LIFECYCLE_BRIDGE_STUB_H
#include <stdint.h>
#include <stddef.h>
void ACRStubAbortCreation(uint64_t token);
/* The next ACRCreateProfile is refused; surfaces of that profile token are refused too. */
void ACRStubRefuseNextProfile(void);
void ACRStubPopupMetadata(int32_t known, uint32_t transition, const char *method, int32_t has_body);
/* Advertise a synthetic side API version without loading a CEF framework. */
void ACRStubSetPatchLevel(uint32_t version);
/* ABI 9 (CH-ESSENTIALS): synthesized page events and the last recorded answer. */
typedef struct {
  int32_t kind;          /* the ACREventKind of the request answered */
  uint64_t request_id;   /* request id (surface token for unresponsive / close / fullscreen) */
  int32_t value;         /* accept, command id, file count, provided credential, terminate... */
  int32_t has_text;
  char text[256];        /* prompt text, user name or first path */
  char second[256];      /* password or second path */
  uint32_t count;        /* answers recorded so far */
} ACRStubResolution;
const ACRStubResolution *ACRStubLastResolution(void);
void ACRStubEmit(int32_t kind, uint64_t token, uint64_t request, int32_t value, int32_t flags,
                 const char *url, const char *detail, const char *title, const char *payload);
void ACRStubEmitFavicon(uint64_t surface, uint64_t profile, int32_t browser, uint64_t generation,
                        uint64_t revision, const char *url, const void *bytes, size_t size);
/* Result of the next ACRRequestClose calls (2 proceeds, 1 pending, 0 unknown). */
void ACRStubSetRequestCloseResult(int32_t result);
/* ABI 10 synthetic native fixtures. No framework or filesystem is accessed. */
void ACRStubReadyProfile(uint64_t profile);
void ACRStubExtensionsSnapshot(const char *json, int32_t reported_size, int32_t read_size);
void ACRStubExtensionsReenter(int32_t flags); /* 1 observe, 2 unobserve, 4 remove */
void ACRStubExtensionsChanged(uint64_t profile);
uint64_t ACRStubLastExtensionProfile(void);
int32_t ACRStubExtensionObserverCount(void);
int32_t ACRStubExtensionUnregisterCount(void);

/* ABI 11: what the bridge does when a patched framework offers a Chrome-created tab. Returns
 * the parent view the adapter answered, with its surface token. */
void *ACRStubAdoptEngineTab(uint64_t window_token, uint64_t profile_token, const char *url,
                            int32_t foreground, uint64_t *token);

/* Hidden hosted-tab creation fixtures; no CEF or native browser is created. */
void ACRStubHostedMode(int32_t enabled);
uint64_t ACRStubPublishedSurface(void);
int32_t ACRStubActivationCount(void);
const char *ACRStubDownloadPath(void);
uint64_t ACRStubDownloadRequest(void);
void ACRStubDownload(uint64_t token, uint64_t request, int32_t status, int64_t bytes);
void ACRStubDevToolsMode(int32_t enabled);
int32_t ACRStubDevToolsID(void);
void ACRStubRetirementMode(int32_t result);
#endif
