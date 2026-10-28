// Copyright 2026 Orbit. BSD-style license; see LICENSE.
#ifndef ORBIT_EXTENSION_LEASE_H_
#define ORBIT_EXTENSION_LEASE_H_
#include <cstdint>
namespace orbit_extensions {
// Immutable identity of a single native invocation, never just an NSWindow.
struct InvocationIdentity {
  uint64_t window = 0, generation = 0, surface = 0, profile = 0, epoch = 0;
  int32_t browser = 0;
  uintptr_t contents = 0;
  bool operator==(const InvocationIdentity&) const = default;
};
class InvocationLease {
 public:
  explicit InvocationLease(InvocationIdentity identity) : identity_(identity) {}
  bool Authorizes(const InvocationIdentity& current) const {
    return !revoked_ && identity_ == current;
  }
  // Revocation precedes all cancellation callbacks and cannot be undone by ABA.
  bool Revoke() { const bool first = !revoked_; revoked_ = true; return first; }
  const InvocationIdentity& identity() const { return identity_; }
 private:
  const InvocationIdentity identity_;
  bool revoked_ = false;
};
}
#endif
