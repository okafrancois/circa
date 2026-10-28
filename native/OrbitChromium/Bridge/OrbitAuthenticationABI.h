#ifndef ORBIT_AUTHENTICATION_ABI_H
#define ORBIT_AUTHENTICATION_ABI_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
#define ACR_AUTH_VERSION 1u
#define ACR_AUTH_MAX_ROWS 64u
typedef struct { const uint8_t *bytes; uint32_t length; } ACRAuthBytes;
typedef struct {
  uint32_t struct_size, version;
  ACRAuthBytes host, name, path, value; /* privileged borrow, copied before return; never an event */
  int32_t host_only, secure, http_only, same_site, priority, has_expiry;
  int64_t expiry_us; /* integer microseconds since 1601; zero for session cookies */
  /* Explicit subset declaration. No partition identity can be flattened into this API.
   * Source times regenerate, source_type becomes Other (3); scheme/port/type/update are
   * unobservable in public readback. They are validated, never claimed verified there. */
  int32_t partitioned, source_scheme, source_port, source_type;
  int64_t creation_us, last_access_us, last_update_us;
} ACRAuthCookie;
typedef struct {
  uint32_t struct_size, version;
  uint64_t operation, profile;
  const ACRAuthCookie *rows;
  uint32_t row_count, timeout_ms;
} ACRAuthBatch;
enum ACRAuthStatus {
  ACR_AUTH_SUBSET_MATCH = 0, ACR_AUTH_INVALID = 1, ACR_AUTH_CONTEXT_GONE = 2,
  ACR_AUTH_NOT_EMPTY = 3, ACR_AUTH_CEF_REFUSED = 4, ACR_AUTH_MISMATCH = 5,
  ACR_AUTH_AMBIGUOUS = 6, ACR_AUTH_CANCELLED = 7, ACR_AUTH_TIMEOUT = 8,
  ACR_AUTH_SHUTDOWN = 9, ACR_AUTH_ABANDONED = 10
};
typedef struct {
  uint32_t struct_size, version;
  uint64_t operation, profile;
  uint32_t kind; /* 1: exactly one terminal; 2: later drain acknowledgement, never success */
  int32_t status;
  uint32_t requested, installed, observed, pending;
} ACRAuthNotice;
typedef void (*ACRAuthCallback)(void *context, const ACRAuthNotice *notice);
/* Main/UI thread only. Synthetic root marker + mock/hermetic configuration required.
 * Exclusively creates a direct child; even an existing empty directory is refused.
 * Fresh profiles remain quarantined from browsing/extensions for this source-only lane. */
int32_t ACRAuthCreateFreshProfile(uint64_t profile, ACRAuthBytes child_name, int32_t persist_session);
/* 0 = refused synchronously, no callback or retained context. 1 = admitted, including early
 * callbacks before return. Borrowed input/callback notice pointers expire at return.
 * Result is public projection equality, never full canonical inventory/auth/durability proof.
 * A terminal with pending > 0 forbids release/cleanup until kind 2 or engine shutdown barrier.
 * Cancellation after a write awaits its callback and a flush barrier. Refused/abandoned flush
 * or context loss remains quarantined through final CEF shutdown; no media durability claim.
 * callback context must survive that drain acknowledgement. No callback carries values. */
int32_t ACRAuthInstall(const ACRAuthBatch *batch, ACRAuthCallback callback, void *context);
int32_t ACRAuthCancel(uint64_t operation);
#ifdef __cplusplus
}
#endif
#endif
